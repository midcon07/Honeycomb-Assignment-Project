using System.Runtime.InteropServices;
using System.Text.Json;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

namespace HoneycombLauncher;

/// <summary>
/// Borderless by design, matching CommPanel and ClaudeSoundtrack. The window
/// IS the panel - a Windows title bar sitting above a drawn instrument panel
/// breaks the illusion the whole visual language depends on. Dragging,
/// minimising and closing are handled by the page's own chrome.
/// </summary>
internal sealed partial class MainForm : Form
{
    private const int WM_NCLBUTTONDOWN = 0x00A1;
    private const int HTCAPTION = 0x2;
    private const int HTBOTTOMRIGHT = 17;

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool ReleaseCapture();

    [LibraryImport("user32.dll", EntryPoint = "SendMessageW")]
    private static partial IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);

    // Windows broadcasts this to every top-level window when the device tree
    // changes, so no registration is needed to hear about a USB plug or unplug.
    private const int WM_DEVICECHANGE = 0x0219;
    private const int DBT_DEVNODES_CHANGED = 0x0007;
    private const int WM_NCCALCSIZE = 0x0083;
    private const int WS_THICKFRAME = 0x00040000;
    private const int WS_MAXIMIZEBOX = 0x00010000;
    private const int WS_MINIMIZEBOX = 0x00020000;

    // Two "drag" presses within the double-click time are a double-click on
    // the title bar. The page cannot see it: the first press hands the mouse
    // to Windows for the native drag, so the page's own dblclick never fires.
    private DateTime _lastDragPress = DateTime.MinValue;

    /// <summary>
    /// A borderless window that Windows still treats as a real one: the
    /// maximise and thick-frame styles are what make drag-to-the-top-edge
    /// snap it to full screen and let it be maximised at all. The frame
    /// those styles would draw is removed in WndProc (WM_NCCALCSIZE), so
    /// nothing changes on screen.
    /// </summary>
    protected override CreateParams CreateParams
    {
        get
        {
            var cp = base.CreateParams;
            cp.Style |= WS_THICKFRAME | WS_MAXIMIZEBOX | WS_MINIMIZEBOX;
            return cp;
        }
    }

    /// <summary>
    /// With a thick frame, a maximised window is sized by Windows to the
    /// screen plus the (now invisible) frame, so its edges would hang off
    /// the monitor. Pinning the maximised bounds to the work area of
    /// whichever monitor the window is on keeps it exact and clear of the
    /// taskbar.
    /// </summary>
    protected override void OnMove(EventArgs e)
    {
        base.OnMove(e);
        try { MaximizedBounds = Screen.FromControl(this).WorkingArea; } catch { }
    }

    // Not readonly: when the browser process behind the page dies, the page
    // is gone for good and the only recovery is a new control (see
    // RecreateWebAsync). Measured 2026-09-05: a launcher went black with the
    // process alive and no page process left under it.
    private WebView2 _web = new() { Dock = DockStyle.Fill };
    private bool _recreating;
    private AppConfig _cfg;
    private string _cfgProblem;

    /// <summary>
    /// A device change arrives as a burst of messages, so re-checking is
    /// deferred until they stop rather than run once per message.
    /// </summary>
    private readonly System.Windows.Forms.Timer _deviceSettle = new() { Interval = 1200 };

    /// <summary>
    /// Safety net for anything that is not a device change - FSUIPC being
    /// started or stopped, the network coming back. Slow on purpose: the gate
    /// takes a few seconds and there is no need to run it often.
    /// </summary>
    private readonly System.Windows.Forms.Timer _slowPoll = new() { Interval = 30000 };

    // Test mode: the checklist overlay on the map. The automatic steps are
    // re-evaluated on this timer while the mode is on; the manual ticks live
    // in a small file so they survive a restart and can be read afterwards.
    private readonly System.Windows.Forms.Timer _testPoll = new() { Interval = 4000 };
    private bool _testMode;
    private bool _testPollWired;
    private bool _testChecking;
    private static readonly string TestTicksPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "HoneycombAssignment", "test-status.json");

    private bool _checking;

    /// <summary>
    /// Starting the simulator enumerates devices, which fires a long run of
    /// WM_DEVICECHANGE messages. Without a floor between runs the gate would
    /// re-run continuously for the whole of a sim launch.
    /// </summary>
    private DateTime _lastCheck = DateTime.MinValue;
    private static readonly TimeSpan MinBetweenChecks = TimeSpan.FromSeconds(15);

    public MainForm()
    {
        Text = "Honeycomb Preflight";
        FormBorderStyle = FormBorderStyle.None;
        Width = 1400;
        Height = 980;
        MinimumSize = new Size(1000, 700);
        StartPosition = FormStartPosition.CenterScreen;
        BackColor = Color.FromArgb(10, 12, 13);
        // Where it was last left, if that place is still on a screen.
        try
        {
            var lb = AppConfig.Load(out _)?.LauncherBounds;
            if (lb != null && lb.Length == 4 && lb[2] >= MinimumSize.Width && lb[3] >= MinimumSize.Height)
            {
                var rb = new Rectangle(lb[0], lb[1], lb[2], lb[3]);
                foreach (var sc in Screen.AllScreens)
                    if (sc.WorkingArea.IntersectsWith(rb)) { StartPosition = FormStartPosition.Manual; Bounds = rb; break; }
            }
        }
        catch (Exception ex) { Program.LogError("launcher place", ex); }
        // Keeps a taskbar entry and Alt-Tab behaviour despite having no frame.
        ShowInTaskbar = true;
        Controls.Add(_web);

        // The remedy text promises "this screen will notice on its own - there
        // is nothing to press". It has to be true. Unplugging the quadrant and
        // still being told it is connected is worse than no check at all.
        _deviceSettle.Tick += async (_, _) =>
        {
            _deviceSettle.Stop();
            Program.Log("device change settled - re-checking");
            try { await PushPreflightAsync(); }
            catch (Exception ex) { Program.LogError("device re-check", ex); }
        };
        _slowPoll.Tick += async (_, _) =>
        {
            try { await PushPreflightAsync(); }
            catch (Exception ex) { Program.LogError("slow poll", ex); }
        };

        // An exception inside an async void handler takes the whole process
        // down with no window and no message. Everything the startup does is
        // caught and reported instead.
        Shown += async (_, _) =>
        {
            try { await StartAsync(); }
            catch (Exception ex)
            {
                Program.LogError("StartAsync", ex);
                MessageBox.Show(
                    "The panel could not start.\n\n" + ex.GetType().Name + ": " + ex.Message +
                    "\n\nDetails: " + Program.LogPath,
                    "Honeycomb Preflight", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        };
    }

    private async Task StartAsync()
    {
        // FSUIPC7 starts with the program. It is what makes the levers work,
        // it sits harmlessly in the tray waiting for the simulator, and
        // starting it now means its device scan is finished by the time the
        // preflight gate reads [JoyNames]. Nothing else launches FSUIPC on
        // this machine - neither EXE.xml does - so this is the only place.
        //
        // The one thing that must NOT happen while it runs is writing lever
        // assignments: FSUIPC rewrites its ini on exit and would undo them.
        // When the app gains that step it has to stop FSUIPC first; the
        // assignment tool refuses, loudly, if it does not.
        //
        // Read straight from the config file rather than from _cfg, so this
        // does not depend on when the rest of startup loads it.
        try
        {
            var cfg = AppConfig.Load(out _) ?? new AppConfig();

            // Learn where FSUIPC is on THIS machine, once, and write it down.
            // Without this a fresh machine has an empty fsuipcRoot, so nothing
            // starts FSUIPC and the planned-aircraft check cannot find the ini.
            if (string.IsNullOrWhiteSpace(cfg.FsuipcRoot))
            {
                var found = Runner.FindFsuipcRoot();
                if (!string.IsNullOrWhiteSpace(found))
                {
                    cfg.FsuipcRoot = found;
                    cfg.Save();
                    Program.Log("found FSUIPC7 at " + found + " and recorded it");
                }
                else Program.Log("FSUIPC7 not found on this computer");
            }

            Program.Log("FSUIPC7 at startup: " + Runner.LaunchFsuipc(cfg.FsuipcRoot));
        }
        catch (Exception ex)
        {
            // Not fatal. The gate will report FSUIPC missing or not run, in
            // words, which is better than a crash here would be.
            Program.LogError("LaunchFsuipc at startup", ex);
        }

        await InitWebAsync();
    }

    /// <summary>
    /// Creates the browser behind the page and loads the page. Called once
    /// at start and again by RecreateWebAsync after the browser process dies.
    /// </summary>
    private async Task InitWebAsync()
    {
        var userData = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "HoneycombAssignment", "webview");
        Directory.CreateDirectory(userData);

        // GPU compositing off. Embedded Chromium windows are known to go
        // black - and stay black - under remote-desktop sessions and after
        // display changes when the GPU process is lost; this page is a
        // panel of text and a small drawing, and needs none of it.
        var opts = new CoreWebView2EnvironmentOptions
        {
            AdditionalBrowserArguments = "--disable-gpu-compositing"
        };
        var env = await CoreWebView2Environment.CreateAsync(null, userData, opts);
        await _web.EnsureCoreWebView2Async(env);

        var s = _web.CoreWebView2.Settings;
        s.AreDefaultContextMenusEnabled = false;
        s.IsStatusBarEnabled = false;
        s.AreBrowserAcceleratorKeysEnabled = false;
        s.IsZoomControlEnabled = false;

        _web.DefaultBackgroundColor = Color.FromArgb(10, 12, 13);
        _web.CoreWebView2.WebMessageReceived += OnMessage;

        // When the browser process behind the page dies, CoreWebView2 goes
        // null and every push afterwards fails with a NullReferenceException
        // that names no cause. This is the event that carries the cause; log
        // it so the failure reads as what it is.
        _web.CoreWebView2.ProcessFailed += async (_, ev) =>
        {
            Program.Log($"WebView2 process failed: {ev.ProcessFailedKind}, reason {ev.Reason}, exit code {ev.ExitCode}" +
                        (string.IsNullOrEmpty(ev.ProcessDescription) ? "" : $", {ev.ProcessDescription}"));
            // A dead browser or renderer means a black window until the
            // program is restarted. Rebuild the page instead; the state it
            // shows is re-read from disk and the tools, so nothing is lost.
            if (ev.ProcessFailedKind is CoreWebView2ProcessFailedKind.BrowserProcessExited
                                    or CoreWebView2ProcessFailedKind.RenderProcessExited
                                    or CoreWebView2ProcessFailedKind.RenderProcessUnresponsive)
            {
                try { await RecreateWebAsync(); }
                catch (Exception ex) { Program.LogError("RecreateWeb", ex); }
            }
        };
        _web.CoreWebView2.NavigationCompleted += async (_, _) =>
        {
            try { await RefreshAllAsync(); }
            catch (Exception ex) { Program.LogError("RefreshAll", ex); }
            _slowPoll.Start();
            // Seen at start too, so it is read before the flight rather than
            // discovered over the runway; "not now" holds it until the sim starts.
            try { WatchSimSettings(); WatchProcesses(); await PushSimStateAsync(); ShowTrafficReminderIfNeeded("program started"); } catch (Exception ex) { Program.LogError("traffic reminder", ex); }
        };

        var ui = Path.Combine(AppContext.BaseDirectory, "ui", "index.html");
        _web.CoreWebView2.Navigate(new Uri(ui).AbsoluteUri);
    }

    /// <summary>
    /// Throws the dead browser control away and builds a new one. Serialised:
    /// a browser death raises several failure events in a row.
    /// </summary>
    private async Task RecreateWebAsync()
    {
        if (_recreating) return;
        _recreating = true;
        try
        {
            Program.Log("page process lost - rebuilding the page");
            _slowPoll.Stop();
            var old = _web;
            _web = new WebView2 { Dock = DockStyle.Fill };
            Controls.Add(_web);
            _web.BringToFront();
            try { Controls.Remove(old); old.Dispose(); } catch (Exception ex) { Program.LogError("dispose old page", ex); }
            _webGoneLogged = false;
            await InitWebAsync();
            Program.Log("page rebuilt");
        }
        finally { _recreating = false; }
    }

    protected override void WndProc(ref Message m)
    {
        // No non-client area at all: the page draws its own title bar.
        if (m.Msg == WM_NCCALCSIZE && m.WParam != IntPtr.Zero)
        {
            m.Result = IntPtr.Zero;
            return;
        }
        if (m.Msg == 0x0232 /* WM_EXITSIZEMOVE */ && WindowState == FormWindowState.Normal)
        {
            // Moved or resized by hand: remembered, so the next start opens here.
            try
            {
                _cfg ??= new AppConfig();
                _cfg.LauncherBounds = new[] { Left, Top, Width, Height };
                _cfg.Save();
            }
            catch (Exception ex) { Program.LogError("save launcher place", ex); }
        }
        if (m.Msg == WM_DEVICECHANGE && (int)m.WParam == DBT_DEVNODES_CHANGED)
        {
            // Restart the timer on every message so the burst collapses into
            // one re-check once the device tree has settled.
            _deviceSettle.Stop();
            _deviceSettle.Start();
        }
        base.WndProc(ref m);
    }

    // ---- messages from the page -------------------------------------------

    /// <summary>
    /// async void, because that is what an event handler must be - so it has to
    /// swallow nothing and catch everything. An exception escaping here kills
    /// the process outright: no window, no message, nothing written down. That
    /// is almost certainly what made the window disappear when a button was
    /// pressed.
    /// </summary>
    private async void OnMessage(object sender, CoreWebView2WebMessageReceivedEventArgs e)
    {
        try { await HandleMessageAsync(e); }
        catch (Exception ex)
        {
            Program.LogError("OnMessage", ex);
            try
            {
                await Send(new { kind = "hostError", message = ex.Message });
            }
            catch { /* the page may be gone; the log already has it */ }
        }
    }

    private async Task HandleMessageAsync(CoreWebView2WebMessageReceivedEventArgs e)
    {
        JsonElement msg;
        try { msg = JsonDocument.Parse(e.WebMessageAsJson).RootElement; } catch { return; }
        var action = msg.TryGetProperty("action", out var a) ? a.GetString() : null;
        Program.Log("message: " + (action ?? "(none)"));

        switch (action)
        {
            // --- window chrome, since there is no title bar ---
            case "drag":
                {
                    var now = DateTime.UtcNow;
                    var dbl = (now - _lastDragPress).TotalMilliseconds <= SystemInformation.DoubleClickTime;
                    _lastDragPress = dbl ? DateTime.MinValue : now;
                    if (dbl)
                    {
                        WindowState = WindowState == FormWindowState.Maximized
                            ? FormWindowState.Normal : FormWindowState.Maximized;
                        break;
                    }
                    ReleaseCapture();
                    SendMessage(Handle, WM_NCLBUTTONDOWN, (IntPtr)HTCAPTION, IntPtr.Zero);
                }
                break;
            case "resize":
                ReleaseCapture();
                SendMessage(Handle, WM_NCLBUTTONDOWN, (IntPtr)HTBOTTOMRIGHT, IntPtr.Zero);
                break;
            case "minimise":
                WindowState = FormWindowState.Minimized;
                break;
            case "maximise":
                WindowState = WindowState == FormWindowState.Maximized
                    ? FormWindowState.Normal : FormWindowState.Maximized;
                break;
            case "close":
                Close();
                break;

            // --- application ---
            case "refresh":
                await RefreshAllAsync();
                break;

            case "refreshPlan":
                await PushPlanAsync();
                break;

            case "selectAircraft":
                {
                    var id = msg.TryGetProperty("id", out var v) ? v.GetString() : null;
                    if (!string.IsNullOrEmpty(id))
                    {
                        _cfg ??= new AppConfig();
                        _cfg.LastAircraftId = id;
                        _cfg.AircraftUse.TryGetValue(id, out var n);
                        _cfg.AircraftUse[id] = n + 1;
                        _cfg.Save();
                    }
                    break;
                }

            case "confirmCaps":
                {
                    var layout = msg.TryGetProperty("layout", out var v) ? v.GetString() : null;
                    if (!string.IsNullOrEmpty(layout))
                    {
                        _cfg ??= new AppConfig();
                        _cfg.CapsSetForLayout = layout;
                        _cfg.Save();
                        await PushConfigAsync();
                    }
                    break;
                }

            case "setEra":
                {
                    var era = msg.TryGetProperty("era", out var eraEl) ? (eraEl.GetString() ?? "") : "";
                    _cfg ??= new AppConfig();
                    _cfg.UiEra = era == "modern" ? "modern" : "80s";
                    try { _cfg.Save(); } catch (Exception ex) { Program.LogError("save era", ex); }
                    Program.Log("window face: " + _cfg.UiEra);
                    break;
                }

            case "setTrafficMode":
                {
                    var mode = msg.TryGetProperty("mode", out var mv) ? (mv.GetString() ?? "") : "";
                    if (mode != "BATC" && mode != "FSLTL" && mode != "MSFS") mode = "";
                    _cfg ??= new AppConfig();
                    _cfg.TrafficMode = mode;
                    _cfg.Save();
                    Program.Log("traffic mode: " + (mode == "" ? "(none)" : mode));
                    await PushConfigAsync();
                    _trafficReminderDismissed = false;   // a new choice deserves a fresh reminder
                    ShowTrafficReminderIfNeeded("mode chosen");
                    break;
                }

            case "showTrafficReminder":
                // The Printout button toggles: a sheet that is put away winds
                // back down; an open sheet winds up into its square at the
                // anchor (Mark, 2026-09-12: "hitting it again should take it
                // back to the dock"). No sheet yet: print one for the current
                // state, needed or not.
                _trafficReminderDismissed = false;
                if (_trafficReminder != null && !_trafficReminder.IsDisposed)
                {
                    if (_trafficReminder.IsMinimised) _trafficReminder.Restore();
                    else _trafficReminder.Minimise();
                }
                else if (string.IsNullOrWhiteSpace(_cfg?.TrafficMode))
                    await Send(new { kind = "printout", message = "Choose a traffic mode first - BATC, FSLTL or MSFS - and the printout prints for it." });
                else PrintTrafficSheet("asked for");
                break;

            case "setPilotId":
                {
                    var id = msg.TryGetProperty("id", out var v) ? v.GetString() : null;
                    _cfg ??= new AppConfig();
                    _cfg.SimBriefPilotId = (id ?? "").Trim();
                    _cfg.Save();
                    await PushConfigAsync();
                    await PushPlanAsync();
                    break;
                }

            case "setupLevers":
                {
                    var id = msg.TryGetProperty("id", out var v) ? v.GetString() : null;
                    if (string.IsNullOrWhiteSpace(id))
                    {
                        await SetupDone(false, "No aircraft chosen.", "Set up levers in FSUIPC");
                        break;
                    }
                    await SetupLeversAsync(id);
                    break;
                }

            case "confirmBravoProfile":
                {
                    // Records that a person has looked. Nothing here can verify
                    // it - MSFS keeps controller profiles in a cloud-synced
                    // binary container - so the tool stores who and when, and
                    // the check says plainly that it is not re-checked.
                    var res = await Runner.PowerShellAsync(
                        Path.Combine(Runner.ToolsDir, "Confirm-SimBravoProfile.ps1"));
                    var said = (res.StdOut + "\n" + res.StdErr).Trim();
                    Program.Log($"confirmBravoProfile exit {res.ExitCode}");
                    await SetupDone(res.ExitCode == 0, said, "MSFS is on the empty Bravo profile");
                    await PushPreflightAsync(true);
                    break;
                }

            case "setupButtons":
                await SetupButtonsAsync();
                break;

            case "recalibrateAlpha":
                await RecalibrateAlphaAsync();
                break;

            case "startTest":
                await EnterTestModeAsync();
                break;

            case "endTest":
                LeaveTestMode();
                await Send(new { kind = "testStatus", active = false });
                break;

            case "testWrite":
                {
                    // The write-and-restart that used to be a hand sequence of
                    // "close FSUIPC, wait, start it again". Both setup routines
                    // close and restart FSUIPC themselves; running them here, in
                    // order, is the whole point of test mode.
                    var id = msg.TryGetProperty("id", out var v) ? v.GetString() : null;
                    _batching = true; _batchErrors.Clear();
                    await SetupButtonsAsync();
                    // Each lever write only touches its own aircraft, so a stale
                    // below-detent section on a piston (left by the first, wrong
                    // write) survives a King Air write. The pistons_clean row
                    // promises this button removes them, so rewrite them too.
                    foreach (var piston in new[] { "da62", "be36" })
                        if (!string.Equals(piston, id, StringComparison.OrdinalIgnoreCase))
                            await SetupLeversAsync(piston);
                    if (!string.IsNullOrWhiteSpace(id)) await SetupLeversAsync(id);
                    _batching = false;
                    await SetupDone(_batchErrors.Count == 0,
                        _batchErrors.Count == 0 ? "Button map and lever settings written. FSUIPC has been restarted."
                                                : string.Join("\n\n", _batchErrors),
                        "Write and restart FSUIPC");
                    await PushTestStatusAsync();
                    break;
                }

            case "tickStep":
                {
                    var id   = msg.TryGetProperty("id",   out var v) ? v.GetString() : null;
                    var done = msg.TryGetProperty("done", out var d) && d.ValueKind == JsonValueKind.True;
                    if (!string.IsNullOrWhiteSpace(id))
                    {
                        var ticks = LoadTicks();
                        if (done) ticks[id] = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ");
                        else ticks.Remove(id);
                        SaveTicks(ticks);
                        Program.Log($"test step {(done ? "ticked" : "unticked")}: {id}");
                    }
                    await PushTestStatusAsync();
                    break;
                }

            case "aircraftTitles":
                await PushAircraftTitlesAsync();
                break;

            case "addAircraft":
                await AddAircraftAsync(msg);
                break;

            case "weather":
                {
                    // Departure or destination weather. The tool asks
                    // aviationweather.gov and handles the nearest-station
                    // fallback; the page shows whatever it answers, including
                    // "could not be reached", in a window.
                    var icao  = msg.TryGetProperty("icao",  out var wi) ? wi.GetString() : null;
                    var label = msg.TryGetProperty("label", out var wl) ? wl.GetString() : "Weather";
                    var inv   = System.Globalization.CultureInfo.InvariantCulture;
                    var lat   = msg.TryGetProperty("lat", out var wla) && wla.ValueKind == JsonValueKind.Number ? wla.GetDouble().ToString(inv) : null;
                    var lon   = msg.TryGetProperty("lon", out var wlo) && wlo.ValueKind == JsonValueKind.Number ? wlo.GetDouble().ToString(inv) : null;
                    if (string.IsNullOrWhiteSpace(icao)) break;
                    var wargs = new List<string> { "-Icao", icao, "-Label", label ?? "Weather" };
                    if (lat != null && lon != null) wargs.AddRange(new[] { "-Lat", lat, "-Lon", lon });
                    var (wx, wraw) = await Runner.JsonToolAsync(
                        Path.Combine(Runner.ToolsDir, "Get-AirportWeather.ps1"), wargs.ToArray());
                    if (wx is null)
                    {
                        Program.Log("weather tool returned nothing: " + (wraw.StdErr + wraw.StdOut).Trim());
                        await Send(new { kind = "weather", data = new { Status = "Unavailable", Label = label, Requested = icao,
                            Note = "The weather tool returned nothing. See launcher.log." } });
                        break;
                    }
                    await SendRaw("weather", wx.Value);
                    break;
                }

            case "openSimBrief":
                Runner.OpenUrl("https://dispatch.simbrief.com/options/new");
                break;

            case "launch":
                await LaunchAsync();
                break;
        }
    }

    // ---- pushing state to the page ----------------------------------------

    private async Task RefreshAllAsync()
    {
        _cfg = AppConfig.Load(out _cfgProblem);
        await PushConfigAsync();
        // Forced: RefreshAll is either the first load or the user pressing
        // refresh, and neither should be silently skipped by the throttle.
        await PushPreflightAsync(true);
        await PushPlanAsync();
    }

    private Task PushConfigAsync()
    {
        // The page colours its buttons from these: amber until the thing is
        // done, green after. "Done" is read from FSUIPC's own file, not from
        // a note the app made, so a hand-edit or a reinstall shows truthfully.
        var (levers, buttons, templates) = ReadFsuipcState();
        // The page's aircraft list. It used to be typed into the page by
        // hand and drifted from the table; now there is one source, and an
        // aircraft added on this machine appears without a new build.
        var fleet = AircraftTable.LoadMerged()
            .Select(e => new { id = e.Id, name = e.Name, type = e.Icao ?? "", layout = e.Layout, local = e.Local })
            .ToArray();
        // The layouts and cap labels the page draws from: the same file, so
        // the page's own copy (which drifted) is gone.
        var (layouts, capLabels) = AircraftTable.LoadLayouts();
        return Send(new
        {
            kind = "config",
            layouts,
            capLabels,
            exists = _cfg != null,
            problem = _cfgProblem,
            pilotId = _cfg?.SimBriefPilotId ?? "",
            lastAircraftId = _cfg?.LastAircraftId ?? "",
            capsSetForLayout = _cfg?.CapsSetForLayout ?? "",
            aircraftUse = _cfg?.AircraftUse ?? new Dictionary<string, int>(),
            bravoProfileConfirmed = !string.IsNullOrWhiteSpace(_cfg?.MsfsBravoProfileConfirmedUtc),
            trafficMode = _cfg?.TrafficMode ?? "",
            trafficRequired = AppConfig.TrafficTypeRequiredFor(_cfg?.TrafficMode ?? "") ?? "",
            trafficRecorded = _cfg?.TrafficTypeRecorded ?? "",
            trafficRecordedBy = _cfg?.TrafficTypeRecordedBy ?? "",
            trafficRecordedUtc = _cfg?.TrafficTypeRecordedUtc ?? "",
            trafficGfx = TrafficGraphicsForPage(),
            uiEra = string.IsNullOrWhiteSpace(_cfg?.UiEra) ? "80s" : _cfg.UiEra,
            leversWrittenIds = levers,
            buttonsWritten = buttons,
            fleet,
            // Every aircraft the lever table knows. The page's own fleet list
            // is a hand copy and has drifted (it listed a 737-800 the table
            // did not have), so "is there a template" is answered from here.
            templateIcao = templates
        });
    }

    /// <summary>
    /// What FSUIPC's ini already holds: which curated aircraft (by ICAO) have
    /// a written [Axes.&lt;profile&gt;] section, and whether the global
    /// [Buttons] section carries the Bravo map (30+ numbered lines; the
    /// writer produces 45, a hand-made section a handful).
    /// </summary>
    private (string[] levers, bool buttons, string[] templates) ReadFsuipcState()
    {
        // The table first: it exists whether or not FSUIPC does. "templates"
        // are ICAO types, for matching a plan's aircraft; "levers" are ids.
        var table = AircraftTable.LoadMerged();
        var known = table.Where(e => !string.IsNullOrWhiteSpace(e.Icao))
                         .Select(e => e.Icao.Trim().ToUpperInvariant()).Distinct().ToList();
        try
        {
            var root = _cfg?.FsuipcRoot;
            if (string.IsNullOrWhiteSpace(root)) root = Runner.FindFsuipcRoot();
            if (string.IsNullOrWhiteSpace(root)) return (Array.Empty<string>(), false, known.ToArray());
            var ini = Path.Combine(root, "FSUIPC7.ini");
            if (!File.Exists(ini)) return (Array.Empty<string>(), false, known.ToArray());

            var filled = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            // Title fragments each [Profile.<name>] lists - FSUIPC applies a
            // profile only to titles containing one of them.
            var profileFrags = new Dictionary<string, List<string>>(StringComparer.OrdinalIgnoreCase);
            var cur = ""; var globalButtons = 0;
            foreach (var raw in File.ReadAllLines(ini))
            {
                var l = raw.Trim();
                if (l.StartsWith('[') && l.EndsWith(']')) { cur = l[1..^1]; continue; }
                if (l.Length == 0 || !char.IsDigit(l[0]) || !l.Contains('=')) continue;
                filled.Add(cur);
                if (cur.Equals("Buttons", StringComparison.OrdinalIgnoreCase)) globalButtons++;
                if (cur.StartsWith("Profile.", StringComparison.OrdinalIgnoreCase))
                {
                    var frag = l[(l.IndexOf('=') + 1)..].Trim();
                    if (!profileFrags.TryGetValue(cur, out var list)) profileFrags[cur] = list = new List<string>();
                    list.Add(frag);
                }
            }

            // "Written" for an aircraft means BOTH: its profile's [Axes] section
            // has lines, AND the profile lists this aircraft's own title
            // fragment. A family (the four 737s) shares one profile, so the
            // 800's levers are only set up once "737-800" is in that list -
            // an [Axes] section alone would have shown green with FSUIPC
            // matching nothing for it.
            var written = table.Where(e =>
            {
                if (string.IsNullOrWhiteSpace(e.Match) || !filled.Contains("Axes." + e.Match)) return false;
                var frag = string.IsNullOrWhiteSpace(e.TitleMatch) ? e.Match : e.TitleMatch;
                return profileFrags.TryGetValue("Profile." + e.Match, out var frags) &&
                       frags.Any(x => string.Equals(x, frag.Trim(), StringComparison.OrdinalIgnoreCase));
            }).Select(e => e.Id).ToArray();
            return (written, globalButtons >= 30, known.ToArray());
        }
        catch (Exception ex)
        {
            Program.LogError("read FSUIPC state", ex);
            return (Array.Empty<string>(), false, known.ToArray());
        }
    }

    // ---- adding an aircraft on this machine ---------------------------------

    /// <summary>
    /// The aircraft titles the simulator has loaded that no template covers
    /// yet - the candidates for "which aircraft is it?". Read from FSUIPC's
    /// log, which is the only place the sim's own name for an aircraft is
    /// written down on disk.
    /// </summary>
    private async Task PushAircraftTitlesAsync()
    {
        var root = _cfg?.FsuipcRoot;
        if (string.IsNullOrWhiteSpace(root)) root = Runner.FindFsuipcRoot();
        var logFound = !string.IsNullOrWhiteSpace(root) && File.Exists(Path.Combine(root, "FSUIPC7.log"));
        var all = string.IsNullOrWhiteSpace(root) ? new List<string>() : AircraftTable.LoggedTitles(root);
        var table = AircraftTable.LoadMerged();
        var open = all.Where(t => !table.Any(e =>
        {
            var m = string.IsNullOrWhiteSpace(e.TitleMatch) ? e.Match : e.TitleMatch;
            return !string.IsNullOrWhiteSpace(m) && t.Contains(m, StringComparison.OrdinalIgnoreCase);
        })).ToArray();
        await Send(new { kind = "aircraftTitles", logFound, titles = open, covered = all.Count - open.Length });
    }

    /// <summary>
    /// Writes one aircraft into this machine's own table from the window's
    /// answers, then makes it the chosen aircraft. Nothing is guessed: the
    /// title came from FSUIPC's log, the layout from the answers, and the
    /// entry records both so a later reader knows where it came from.
    /// </summary>
    private async Task AddAircraftAsync(JsonElement msg)
    {
        string Str(string k) => msg.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String ? (v.GetString() ?? "").Trim() : "";
        bool Yes(string k) => msg.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.True;
        async Task Refuse(string why) => await Send(new { kind = "aircraftAdded", ok = false, message = why });

        var title = Str("title");
        var name = Str("name");
        var icao = Str("icao").ToUpperInvariant();
        var category = Str("category");
        var engines = msg.TryGetProperty("engines", out var en) && en.ValueKind == JsonValueKind.Number && en.TryGetInt32(out var n) ? n : 1;
        var prop = Yes("propLever");
        var mix = Yes("mixtureLever");

        if (string.IsNullOrWhiteSpace(title)) { await Refuse("Pick the aircraft from the list first."); return; }
        if (icao != "" && !AircraftTable.ValidIcao(icao)) { await Refuse("The type code should be letters and digits, like C172 or B736 - or left blank."); return; }

        var titleMatch = AircraftTable.TitleMatchFor(title);
        var match = AircraftTable.ProfileNameFor(titleMatch);
        if (string.IsNullOrWhiteSpace(match)) { await Refuse("That name has nothing in it a profile could be named after."); return; }
        if (string.IsNullOrWhiteSpace(name)) name = titleMatch;
        var layout = AircraftTable.LayoutFor(category, engines, prop, mix);

        var e = new AircraftEntry
        {
            Name = name, Icao = icao, Match = match, TitleMatch = titleMatch, Layout = layout,
            Verified = $"added in the launcher on {Environment.MachineName} {DateTime.Now:yyyy-MM-dd}; " +
                       $"title measured from FSUIPC7.log: {title}; not yet flown"
        };
        var cat = category == "" || category == "piston" ? "prop" : category;
        e.Facts["category"] = JsonSerializer.SerializeToElement(cat);
        e.Facts["engines"] = JsonSerializer.SerializeToElement(Math.Clamp(engines, 1, 4));
        if (cat == "prop")
        {
            e.Facts["propControl"] = JsonSerializer.SerializeToElement(prop);
            e.Facts["mixtureControl"] = JsonSerializer.SerializeToElement(mix);
        }
        if (cat == "turboprop") e.Facts["conditionLever"] = JsonSerializer.SerializeToElement(true);

        try { AircraftTable.AddLocal(e); }
        catch (Exception ex)
        {
            Program.LogError("write local aircraft table", ex);
            await Refuse("The aircraft file could not be written: " + ex.Message);
            return;
        }
        Program.Log($"aircraft added: {e.Id} \"{name}\" title \"{title}\" -> match \"{titleMatch}\" layout {layout}");

        _cfg ??= new AppConfig();
        _cfg.LastAircraftId = e.Id;
        _cfg.Save();
        await PushConfigAsync();
        await Send(new
        {
            kind = "aircraftAdded", ok = true, id = e.Id,
            message = $"{name} is added. It matches any aircraft whose name contains \"{titleMatch}\", so other paint schemes work too. " +
                      $"Next: press \"Set up levers in FSUIPC\"."
        });
        await PushPreflightAsync(true);
    }

    // ---- setup progress and outcome -------------------------------------

    public static string SetupLogPath { get; } =
        Path.Combine(Path.GetDirectoryName(Program.LogPath)!, "setup-errors.log");

    private Task Progress(int pct, string text) => Send(new { kind = "setupProgress", pct, text });

    // Several writes in a row (the test's write-and-restart) report once, at
    // the end, rather than popping a window per step.
    private bool _batching;
    private readonly List<string> _batchErrors = new();

    /// <summary>
    /// The end of a setup action. Failures go to the setup error log in full,
    /// and the page gets a short outcome to show in a window: the tool's own
    /// words and, on failure, where the log is.
    /// </summary>
    private async Task SetupDone(bool ok, string said, string what)
    {
        if (_batching)
        {
            if (!ok) _batchErrors.Add(what + ":\n" + said);
            return;
        }
        string logPath = null;
        if (!ok)
        {
            try
            {
                File.AppendAllText(SetupLogPath,
                    $"==== {DateTime.Now:yyyy-MM-dd HH:mm:ss}  {what}\r\n{said}\r\n\r\n");
                logPath = SetupLogPath;
            }
            catch (Exception ex) { Program.LogError("setup error log", ex); }
        }
        await Send(new { kind = "setupResult", ok, what, message = said, logPath });
        await PushConfigAsync();
    }

    private Task PushPreflightAsync() => PushPreflightAsync(false);

    /// <param name="force">
    /// True when the user asked directly. Their refresh button must never be
    /// ignored because a timer happened to run a moment earlier.
    /// </param>
    private async Task PushPreflightAsync(bool force)
    {
        // The gate takes a few seconds and shells out; overlapping runs would
        // just queue up behind each other during a burst of device changes.
        if (_checking) { Program.Log("preflight already running - skipped"); return; }

        if (!force && DateTime.UtcNow - _lastCheck < MinBetweenChecks)
        {
            Program.Log("preflight throttled - checked recently");
            return;
        }

        _checking = true;
        try { await RunPreflightAsync(); }
        finally { _checking = false; _lastCheck = DateTime.UtcNow; }
    }

    private async Task RunPreflightAsync()
    {
        await Send(new { kind = "preflightBusy" });
        var (json, raw) = await Runner.PreflightAsync();
        if (json is null)
        {
            await Send(new
            {
                kind = "preflight",
                data = new
                {
                    verdict = "CANNOT RUN",
                    error = string.IsNullOrWhiteSpace(raw.StdErr) ? raw.StdOut : raw.StdErr,
                    results = Array.Empty<object>()
                }
            });
            return;
        }
        await SendRaw("preflight", json.Value);
    }

    private async Task PushPlanAsync()
    {
        var pid = _cfg?.SimBriefPilotId;
        if (string.IsNullOrWhiteSpace(pid))
        {
            await Send(new { kind = "plan", data = new { Status = "NoPilotId" } });
            return;
        }
        await Send(new { kind = "planBusy" });
        var (json, _) = await Runner.SimBriefAsync(pid);
        if (json is null)
        {
            await Send(new { kind = "plan", data = new { Status = "Unavailable" } });
            return;
        }
        await SendRaw("plan", json.Value);
    }

    /// <summary>
    /// Writes this aircraft's lever settings into FSUIPC, on this machine.
    ///
    /// It has to happen here rather than being prepared in advance, because
    /// the settings depend on facts only this computer knows: which letter
    /// FSUIPC gave the quadrant (B on one machine, C on another), and where
    /// FSUIPC is installed. Assignments authored elsewhere would point at
    /// whatever device holds that letter here - silently.
    ///
    /// FSUIPC is stopped first and started again after. It rewrites its whole
    /// ini when it exits, so a write underneath a running copy is undone with
    /// no error; the tool refuses in that case, and this makes the refusal
    /// unnecessary rather than something the user has to work around.
    /// </summary>
    private async Task SetupLeversAsync(string aircraftId)
    {
        Program.Log("setupLevers: " + aircraftId);
        const string what = "Set up levers in FSUIPC";
        await Progress(10, "Closing FSUIPC so its settings file can be written…");

        var wasRunning = System.Diagnostics.Process.GetProcessesByName("FSUIPC7").Length > 0;
        if (!Runner.StopFsuipc(TimeSpan.FromSeconds(10)))
        {
            await SetupDone(false, "FSUIPC7 would not close, so nothing was written.\n" +
                                   "Close it from its icon near the clock, then try again.", what);
            return;
        }

        await Progress(40, "Writing the lever settings…");
        var res = await Runner.PowerShellAsync(
            Path.Combine(Runner.ToolsDir, "Set-LeverAssignments.ps1"),
            "-Aircraft", aircraftId);

        // The tool's own words are better than anything paraphrased here: it
        // names the aircraft, the layout, the quadrant it resolved and every
        // line it wrote, and its refusals already read as plain instructions.
        var said = (res.StdOut + "\n" + res.StdErr).Trim();
        var ok = res.ExitCode == 0;

        var root = _cfg?.FsuipcRoot;
        if (string.IsNullOrWhiteSpace(root)) root = Runner.FindFsuipcRoot();
        await Progress(85, "Starting FSUIPC again…");
        if (wasRunning && !string.IsNullOrWhiteSpace(root))
            Program.Log("FSUIPC7 restarted after setup: " + Runner.LaunchFsuipc(root));

        Program.Log($"setupLevers finished, exit {res.ExitCode}");
        await Progress(100, ok ? "Done." : "Nothing was written.");
        await SetupDone(ok, said, what);

        // The gate reports lever assignments and profiles, so it is now stale.
        await PushPreflightAsync(true);
    }

    /// <summary>
    /// Writes the Bravo's button map - trim wheel, autopilot panel, gear,
    /// switches, flaps, TOGA - into FSUIPC's global [Buttons] section on this
    /// machine. Same shape as SetupLeversAsync and for the same reasons: the
    /// quadrant's letter is this machine's, and FSUIPC must be closed to write.
    /// The tool refuses any control that has not been measured, so a machine
    /// with an unmeasured map gets a plain refusal, not a guess.
    /// </summary>
    private async Task SetupButtonsAsync()
    {
        Program.Log("setupButtons");
        const string what = "Set up Bravo buttons in FSUIPC";
        await Progress(10, "Closing FSUIPC so its settings file can be written…");

        var wasRunning = System.Diagnostics.Process.GetProcessesByName("FSUIPC7").Length > 0;
        if (!Runner.StopFsuipc(TimeSpan.FromSeconds(10)))
        {
            await SetupDone(false, "FSUIPC7 would not close, so nothing was written.\n" +
                                   "Close it from its icon near the clock, then try again.", what);
            return;
        }

        await Progress(40, "Writing the button map…");
        var res = await Runner.PowerShellAsync(
            Path.Combine(Runner.ToolsDir, "Set-BravoButtons.ps1"));
        var said = (res.StdOut + "\n" + res.StdErr).Trim();
        var ok = res.ExitCode == 0;

        var root = _cfg?.FsuipcRoot;
        if (string.IsNullOrWhiteSpace(root)) root = Runner.FindFsuipcRoot();
        await Progress(85, "Starting FSUIPC again…");
        if (wasRunning && !string.IsNullOrWhiteSpace(root))
            Program.Log("FSUIPC7 restarted after button setup: " + Runner.LaunchFsuipc(root));

        Program.Log($"setupButtons finished, exit {res.ExitCode}");
        await Progress(100, ok ? "Done." : "Nothing was written.");
        await SetupDone(ok, said, what);
        await PushPreflightAsync(true);
    }

    /// <summary>
    /// Recalibrates the Alpha yoke: tools/Set-AlphaCalibration.ps1 in a
    /// console window of its own, because it talks the person through three
    /// measurements (hands off, turn, push/pull) and needs their keyboard.
    /// It writes Windows' calibration store for the yoke, which anything
    /// that already has the yoke open keeps ignoring until it opens the yoke
    /// again - so FSUIPC is closed first and started again after, the same
    /// dance as the lever and button writes. The gate's "Alpha yoke centred"
    /// check is what says whether it worked.
    /// </summary>
    private async Task RecalibrateAlphaAsync()
    {
        Program.Log("recalibrateAlpha");
        var wasRunning = System.Diagnostics.Process.GetProcessesByName("FSUIPC7").Length > 0;
        if (wasRunning && !Runner.StopFsuipc(TimeSpan.FromSeconds(10)))
        {
            await Send(new { kind = "alphaCal", ok = false,
                             message = "FSUIPC7 would not close, so the yoke was not recalibrated. Close it from its icon near the clock, then try again." });
            return;
        }

        int exit = -1;
        try
        {
            var psi = new System.Diagnostics.ProcessStartInfo
            {
                FileName = "powershell.exe",
                UseShellExecute = true     // its own window, with a keyboard
            };
            psi.ArgumentList.Add("-NoProfile");
            psi.ArgumentList.Add("-ExecutionPolicy");
            psi.ArgumentList.Add("Bypass");
            psi.ArgumentList.Add("-File");
            psi.ArgumentList.Add(Path.Combine(Runner.ToolsDir, "Set-AlphaCalibration.ps1"));
            using var p = System.Diagnostics.Process.Start(psi);
            if (p != null) { await p.WaitForExitAsync(); exit = p.ExitCode; }
        }
        catch (Exception ex)
        {
            Program.Log("recalibrateAlpha failed to start: " + ex.Message);
        }

        var root = _cfg?.FsuipcRoot;
        if (string.IsNullOrWhiteSpace(root)) root = Runner.FindFsuipcRoot();
        if (wasRunning && !string.IsNullOrWhiteSpace(root))
            Program.Log("FSUIPC7 restarted after recalibration: " + Runner.LaunchFsuipc(root));

        Program.Log($"recalibrateAlpha finished, exit {exit}");
        await Send(new { kind = "alphaCal", ok = exit == 0, exit });
        // The gate re-reads the yoke's centre, which is the verdict.
        await PushPreflightAsync(true);
    }

    // ---- test mode ----------------------------------------------------------

    private async Task EnterTestModeAsync()
    {
        _testMode = true;
        if (!_testPollWired)
        {
            _testPollWired = true;
            _testPoll.Tick += async (_, _) =>
            {
                if (!_testMode) return;
                try { await PushTestStatusAsync(); }
                catch (Exception ex) { Program.LogError("test poll", ex); }
            };
        }
        Program.Log("test mode: on");
        await PushTestStatusAsync();
        _testPoll.Start();
    }

    private void LeaveTestMode()
    {
        _testMode = false;
        _testPoll.Stop();
        Program.Log("test mode: off");
    }

    /// <summary>
    /// Evaluates the automatic steps (tools/Get-TestStatus.ps1), merges the
    /// person's ticks for the manual ones, and sends the lot to the overlay.
    /// The tool embeds the plan, so one message carries everything the page
    /// needs to draw the checklist.
    /// </summary>
    private async Task PushTestStatusAsync()
    {
        if (_testChecking) return;
        _testChecking = true;
        try
        {
            var (json, raw) = await Runner.JsonToolAsync(Path.Combine(Runner.ToolsDir, "Get-TestStatus.ps1"));
            if (json is null)
            {
                Program.Log("test status tool returned nothing: " + (raw.StdErr + raw.StdOut).Trim());
                await Send(new { kind = "testStatus", active = _testMode, error = "The test status tool did not answer. Details: " + Program.LogPath });
                return;
            }
            var ticks = LoadTicks();
            var payload = $"{{\"kind\":\"testStatus\",\"active\":{(_testMode ? "true" : "false")},\"data\":{json.Value.GetRawText()},\"manual\":{JsonSerializer.Serialize(ticks)}}}";
            if (!PageIsAlive()) return;
            await _web.CoreWebView2.ExecuteScriptAsync($"window.APP && window.APP.receive({payload});");
        }
        finally { _testChecking = false; }
    }

    private static Dictionary<string, string> LoadTicks()
    {
        try
        {
            if (File.Exists(TestTicksPath))
                return JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(TestTicksPath)) ?? new();
        }
        catch (Exception ex) { Program.LogError("LoadTicks", ex); }
        return new();
    }

    private static void SaveTicks(Dictionary<string, string> ticks)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(TestTicksPath));
            File.WriteAllText(TestTicksPath, JsonSerializer.Serialize(ticks, new JsonSerializerOptions { WriteIndented = true }));
        }
        catch (Exception ex) { Program.LogError("SaveTicks", ex); }
    }

    private async Task LaunchAsync()
    {
        // FSUIPC normally started with the program; this is the safety net if
        // it was closed since. Already running is the expected answer here.
        Program.Log("FSUIPC7 at launch step: " + Runner.LaunchFsuipc(_cfg?.FsuipcRoot));

        Runner.LaunchSimulator();
        _launchPressedUtc = DateTime.UtcNow;
        await Send(new { kind = "launched" });
        WatchProcesses();
        // The one setting only a person can change, and only inside the sim:
        // the reminder goes up now, on top of the sim, so it is seen there.
        _trafficReminderDismissed = false;
        ShowTrafficReminderIfNeeded("simulator started");
    }

    // ---- the processes, watched ---------------------------------------------
    // The simulator and the traffic engines, checked every three seconds by
    // name. The page's button used to say "Simulator Starting" for ever after
    // the sim was closed (Mark, 2026-09-12); now it follows the process. The
    // sheet is told when an engine comes up or goes, and prints a fresh sheet
    // when the sim comes up (Mark: "once sim is running again, printout
    // didn't auto pop").
    private readonly System.Windows.Forms.Timer _procClock = new() { Interval = 3000 };
    private bool _procWatching, _simRunning, _batcRunning, _fsltlRunning;
    private DateTime _launchPressedUtc = DateTime.MinValue;

    private static bool ProcessUp(string name) { try { return System.Diagnostics.Process.GetProcessesByName(name).Length > 0; } catch { return false; } }
    private bool LaunchPending => (DateTime.UtcNow - _launchPressedUtc) < TimeSpan.FromMinutes(3);

    private void WatchProcesses()
    {
        if (_procWatching) return;
        _procWatching = true;
        _simRunning = ProcessUp("FlightSimulator2024");
        _batcRunning = ProcessUp("BeyondATC");
        _fsltlRunning = ProcessUp("fsltl-trafficinjector");
        _procClock.Tick += async (_, __) =>
        {
            bool sim = ProcessUp("FlightSimulator2024"), batc = ProcessUp("BeyondATC"), fsltl = ProcessUp("fsltl-trafficinjector");
            bool simChanged = sim != _simRunning;
            if (simChanged) { _simRunning = sim; Program.Log("simulator process " + (sim ? "up" : "gone")); }
            if (batc != _batcRunning) { _batcRunning = batc; Program.Log("BeyondATC process " + (batc ? "up" : "gone")); EngineChanged("BATC", batc); }
            if (fsltl != _fsltlRunning) { _fsltlRunning = fsltl; Program.Log("FSLTL injector process " + (fsltl ? "up" : "gone")); EngineChanged("FSLTL", fsltl); }
            if (simChanged || (LaunchPending && !sim))
            {
                try { await PushSimStateAsync(); } catch (Exception ex) { Program.LogError("push sim state", ex); }
                if (simChanged && sim) OnSimAppeared();
            }
        };
        _procClock.Start();
    }

    private Task PushSimStateAsync() => Send(new { kind = "simState", simRunning = _simRunning, launchPending = LaunchPending && !_simRunning });

    /// <summary>An engine's process came up or went: the sheet says so, in the way its mode wants.</summary>
    private void EngineChanged(string engineMode, bool running)
    {
        var mode = _cfg?.TrafficMode ?? "";
        if (_trafficReminder == null || _trafficReminder.IsDisposed)
        {
            // No sheet: an engine the mode does not want, coming up, is a new occasion.
            if (running && mode != "" && mode != engineMode) { _trafficReminderDismissed = false; ShowTrafficReminderIfNeeded(engineMode + " started"); }
            return;
        }
        if (mode == engineMode) _trafficReminder.EngineNow(running);
        else if (running) { _trafficReminderDismissed = false; PrintTrafficSheet(engineMode + " started"); }
    }

    /// <summary>The simulator's process has appeared: a sheet for the moment, unless the one up still wants something.</summary>
    private void OnSimAppeared()
    {
        if (string.IsNullOrWhiteSpace(_cfg?.TrafficMode)) return;
        _trafficReminderDismissed = false;
        if (_trafficReminder != null && !_trafficReminder.IsDisposed && _trafficReminder.Unresolved)
        {
            if (_trafficReminder.IsMinimised) _trafficReminder.Restore(); else _trafficReminder.Activate();
            return;
        }
        PrintTrafficSheet("simulator running");
    }

    /// <summary>The Graphics > Traffic levels as the sim's file has them now, against what the mode needs.</summary>
    private object TrafficGraphicsForPage()
    {
        var mode = _cfg?.TrafficMode ?? "";
        var need = AppConfig.GraphicsRequiredFor(mode);
        var gfx = SimSettings.ReadTrafficGraphics(out var problem);
        return new
        {
            ok = gfx != null && need != null && gfx.Matches(need.Value.aircraft, need.Value.parked),
            problem = problem ?? "",
            aircraft = gfx == null ? "" : SimSettings.LevelWord(gfx.Aircraft),
            parked = gfx == null ? "" : SimSettings.LevelWord(gfx.Parked),
            needAircraft = need == null ? "" : SimSettings.LevelWord(need.Value.aircraft),
            needParked = need == null ? "" : SimSettings.LevelWord(need.Value.parked),
            writtenUtc = gfx == null ? "" : gfx.WrittenUtc.ToString("yyyy-MM-ddTHH:mm:ssZ")
        };
    }

    // ---- the traffic reminder ------------------------------------------------

    private TrafficReminderForm _trafficReminder;
    private PrintoutIconForm _trafficIcon;
    private bool _trafficReminderDismissed;

    /// <summary>
    /// Puts the tractor-feed sheet up when the chosen traffic mode needs a
    /// different MSFS Traffic Type from the one last recorded. Once per
    /// occasion: "not now" holds it until the next occasion (mode change,
    /// simulator start, program start), never for good.
    /// </summary>
    private void ShowTrafficReminderIfNeeded(string why)
    {
        var mode = _cfg?.TrafficMode ?? "";
        var required = AppConfig.TrafficTypeRequiredFor(mode);
        if (required == null) return;
        var recorded = _cfg?.TrafficTypeRecorded ?? "";
        var typeOk = string.Equals(recorded, required, StringComparison.OrdinalIgnoreCase);
        // The graphics levels are read from the sim's settings file; unreadable
        // counts as not right, and the sheet says why.
        var gfx = SimSettings.ReadTrafficGraphics(out _);
        var need = AppConfig.GraphicsRequiredFor(mode);
        var gfxOk = gfx != null && need != null && gfx.Matches(need.Value.aircraft, need.Value.parked);
        // The engine: for BATC/FSLTL it must be up; for MSFS none must be.
        var engine = TrafficEngines.For(mode, _cfg);
        var engineOk = engine == null
            ? !TrafficEngines.All(_cfg).Any(e => e != null && e.IsRunning())
            : engine.IsRunning();
        if (typeOk && gfxOk && engineOk) return;
        if (_trafficReminderDismissed) return;
        PrintTrafficSheet(why);
    }

    // ---- the sim's settings file, watched ----------------------------------
    // UserCfg.opt is rewritten by the sim within a second or two of any change
    // in Options (measured 2026-09-07, 2026-09-12). Its last-write time is
    // checked every two seconds; a change is read and goes to the sheet (which
    // confirms or complains in print) and to the checklist row.
    private readonly System.Windows.Forms.Timer _simCfgClock = new() { Interval = 2000 };
    private DateTime _simCfgSeen;
    private bool _simCfgWatching;

    private void WatchSimSettings()
    {
        if (_simCfgWatching) return;
        _simCfgWatching = true;
        try { var p = SimSettings.FindUserCfg(); if (p != null) _simCfgSeen = File.GetLastWriteTimeUtc(p); } catch { }
        _simCfgClock.Tick += async (_, __) =>
        {
            DateTime now;
            try { var p = SimSettings.FindUserCfg(); if (p == null) return; now = File.GetLastWriteTimeUtc(p); } catch { return; }
            if (now == _simCfgSeen) return;
            _simCfgSeen = now;
            var gfx = SimSettings.ReadTrafficGraphics(out var problem);
            Program.Log(gfx == null ? "sim settings changed: " + problem
                : $"sim settings changed: aircraft traffic {SimSettings.LevelWord(gfx.Aircraft)}, parked {SimSettings.LevelWord(gfx.Parked)}");
            if (_trafficReminder != null && !_trafficReminder.IsDisposed) _trafficReminder.GraphicsNow(gfx);
            else
            {
                // No sheet up: a change that makes the graphics wrong for the
                // mode is a new occasion, even after NOT NOW.
                var need = AppConfig.GraphicsRequiredFor(_cfg?.TrafficMode ?? "");
                if (need != null && gfx != null && !gfx.Matches(need.Value.aircraft, need.Value.parked)) { _trafficReminderDismissed = false; ShowTrafficReminderIfNeeded("sim settings changed"); }
            }
            try { await PushConfigAsync(); } catch (Exception ex) { Program.LogError("push after sim settings change", ex); }
        };
        _simCfgClock.Start();
    }

    /// <summary>
    /// Prints a fresh sheet for the current state. One printout window lives
    /// for the session: it opens pinned (on top) and stays open; minimised it
    /// becomes a small square that brings the same sheet back. A new occasion
    /// prints a new sheet in place of the old one.
    /// </summary>
    private void PrintTrafficSheet(string why)
    {
        var mode = _cfg?.TrafficMode ?? "";
        var required = AppConfig.TrafficTypeRequiredFor(mode);
        if (required == null) return;
        var recorded = _cfg?.TrafficTypeRecorded ?? "";
        if (_trafficReminder != null && !_trafficReminder.IsDisposed) { try { _trafficReminder.CloseWithoutAsking(); } catch { } }
        if (_trafficIcon != null && !_trafficIcon.IsDisposed) _trafficIcon.Hide();

        float pitch = _cfg?.PrintoutPitch ?? 2.6f;
        if (Array.IndexOf(TrafficReminderForm.Pitches, pitch) < 0) pitch = 2.6f;
        Program.Log($"traffic sheet printed ({why}): mode {mode} needs Traffic Type '{required}', recorded '{(recorded == "" ? "never" : recorded)}'");
        Rectangle? remembered = null;
        var pb = _cfg?.PrintoutBounds;
        if (pb != null && pb.Length == 4) remembered = new Rectangle(pb[0], pb[1], pb[2], pb[3]);
        var need = AppConfig.GraphicsRequiredFor(mode) ?? (-1, -1);
        var engine = TrafficEngines.For(mode, _cfg);
        var facts = new TrafficReminderForm.Facts
        {
            Mode = mode, RequiredType = required, RecordedType = recorded,
            RecordedBy = _cfg?.TrafficTypeRecordedBy ?? "", RecordedUtc = _cfg?.TrafficTypeRecordedUtc ?? "", Who = Environment.UserName,
            RequiredAircraft = need.aircraft, RequiredParked = need.parked,
            Sim = SimSettings.ReadTrafficGraphics(out var gfxProblem), SimProblem = gfxProblem ?? "",
            EngineName = engine?.Name, EngineFound = engine?.Path != null, EngineRunning = engine?.IsRunning() ?? false,
            ForeignEnginesRunning = engine != null ? Array.Empty<string>()
                : TrafficEngines.All(_cfg).Where(e => e != null && e.IsRunning()).Select(e => e.Name).ToArray()
        };
        if (engine != null) Program.Log($"traffic sheet: engine {engine.Name} {(engine.Path == null ? "not found" : "at " + engine.Path)}, {(facts.EngineRunning ? "running" : "not running")}");
        Program.Log(facts.Sim == null ? "traffic sheet: sim settings unreadable - " + gfxProblem
            : $"traffic sheet: sim graphics aircraft {SimSettings.LevelWord(facts.Sim.Aircraft)}, parked {SimSettings.LevelWord(facts.Sim.Parked)}; needs {SimSettings.LevelWord(need.aircraft)}, {SimSettings.LevelWord(need.parked)}");
        WatchSimSettings(); WatchProcesses();
        var opts = new TrafficReminderForm.Options
        {
            Ink = _cfg?.PrintoutInk ?? 1, Bidirectional = _cfg?.PrintoutBidirectional ?? false,
            MixedCase = _cfg?.PrintoutMixedCase ?? false, Speed = _cfg?.PrintoutSpeed ?? 0,
            Printer = _cfg?.PrintoutPrinter ?? 0, Face = string.IsNullOrWhiteSpace(_cfg?.PrintoutFace) ? "Helvetica" : _cfg.PrintoutFace,
            Ambience = _cfg?.PrintoutAmbience ?? true,
            PrinterVolume = _cfg?.PrintoutPrinterVolume ?? 2, AmbienceVolume = _cfg?.PrintoutAmbienceVolume ?? 2
        };
        var f = new TrafficReminderForm(facts, opts, true, pitch, remembered);
        f.OptionsChanged += o =>
        {
            _cfg ??= new AppConfig();
            _cfg.PrintoutInk = o.Ink; _cfg.PrintoutBidirectional = o.Bidirectional; _cfg.PrintoutMixedCase = o.MixedCase; _cfg.PrintoutSpeed = o.Speed;
            _cfg.PrintoutPrinter = o.Printer; _cfg.PrintoutFace = o.Face; _cfg.PrintoutAmbience = o.Ambience;
            _cfg.PrintoutPrinterVolume = o.PrinterVolume; _cfg.PrintoutAmbienceVolume = o.AmbienceVolume;
            try { _cfg.Save(); } catch (Exception ex) { Program.LogError("save printout options", ex); }
            Program.Log($"printout options: {(o.Printer == 1 ? "LaserWriter, " + o.Face : "dot matrix")}, ink {o.Ink}, both directions {o.Bidirectional}, mixed case {o.MixedCase}, speed {o.Speed}");
        };
        f.EngineStartRequested += () =>
        {
            var e = TrafficEngines.For(_cfg?.TrafficMode ?? "", _cfg);
            var why = TrafficEngines.Start(e);
            Program.Log(why == null ? $"started {e.Name} from {e.Path} (asked for on the printout)" : $"could not start {e?.Name}: {why}");
            if (why != null) f.EngineStartFailed(why);
        };
        f.BoundsSettled += r =>
        {
            _cfg ??= new AppConfig();
            _cfg.PrintoutBounds = new[] { r.X, r.Y, r.Width, r.Height };
            try { _cfg.Save(); } catch (Exception ex) { Program.LogError("save printout place", ex); }
        };
        f.PinChanged += p => Program.Log("traffic sheet: " + (p ? "anchored on top" : "let loose"));
        f.PitchChanged += p =>
        {
            _cfg ??= new AppConfig();
            _cfg.PrintoutPitch = p;
            try { _cfg.Save(); } catch (Exception ex) { Program.LogError("save printout pitch", ex); }
        };
        f.Finished += async outcome =>
        {
            if (outcome == TrafficReminderForm.Outcome.Done)
            {
                _cfg ??= new AppConfig();
                _cfg.TrafficTypeRecorded = required;
                _cfg.TrafficTypeRecordedBy = Environment.UserName;
                _cfg.TrafficTypeRecordedUtc = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ");
                _cfg.Save();
                Program.Log($"traffic type recorded as '{required}' by {Environment.UserName} (their word)");
                try { await PushConfigAsync(); } catch (Exception ex) { Program.LogError("push after traffic record", ex); }
            }
            else
            {
                _trafficReminderDismissed = true;
                Program.Log("traffic sheet: not now / closed");
            }
        };
        f.Minimised += () =>
        {
            if (_trafficIcon == null || _trafficIcon.IsDisposed)
            {
                _trafficIcon = new PrintoutIconForm(new Point(f.RestingLocation.X + f.Width, f.RestingLocation.Y));
                _trafficIcon.Restore += () => { if (_trafficReminder != null && !_trafficReminder.IsDisposed) _trafficReminder.Restore(); };
            }
            // The square sits at the sheet's top-RIGHT corner (Mark, 2026-09-11).
            _trafficIcon.Location = new Point(f.RestingLocation.X + f.Width - _trafficIcon.Width, f.RestingLocation.Y);
            _trafficIcon.Show(); _trafficIcon.BringToFront();
        };
        f.Restored += () => { if (_trafficIcon != null && !_trafficIcon.IsDisposed) _trafficIcon.Hide(); };
        f.FormClosed += (_, __) => { if (_trafficIcon != null && !_trafficIcon.IsDisposed) _trafficIcon.Hide(); };
        _trafficReminder = f;
        f.Show();
    }

    // ---- plumbing ----------------------------------------------------------

    // Set once the WebView has been seen dead, so the log gets one line about
    // it rather than one per push for the rest of the session.
    private bool _webGoneLogged;

    /// <summary>
    /// The page can go away underneath us - the WebView2 browser process can
    /// die, and CoreWebView2 is then null. Every push used to dereference it
    /// and throw NullReferenceException from inside RefreshAll and the slow
    /// poll, which said nothing about the cause. Now a dead page is logged
    /// once, in words, and pushes are dropped. The ProcessFailed handler in
    /// StartAsync records why it died.
    /// </summary>
    private bool PageIsAlive()
    {
        if (_web.CoreWebView2 != null) return true;
        if (!_webGoneLogged)
        {
            _webGoneLogged = true;
            Program.Log("page is gone: CoreWebView2 is null, so nothing more can be shown. See any 'WebView2 process failed' line above.");
        }
        return false;
    }

    private async Task Send(object payload)
    {
        if (!PageIsAlive()) return;
        var json = JsonSerializer.Serialize(payload);
        await _web.CoreWebView2.ExecuteScriptAsync($"window.APP && window.APP.receive({json});");
    }

    private async Task SendRaw(string kind, JsonElement body)
    {
        if (!PageIsAlive()) return;
        var json = $"{{\"kind\":\"{kind}\",\"data\":{body.GetRawText()}}}";
        await _web.CoreWebView2.ExecuteScriptAsync($"window.APP && window.APP.receive({json});");
    }
}
