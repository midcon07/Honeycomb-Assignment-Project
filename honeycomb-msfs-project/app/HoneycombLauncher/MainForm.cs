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

    private readonly WebView2 _web = new() { Dock = DockStyle.Fill };
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
            var cfg = AppConfig.Load(out _);
            var outcome = Runner.LaunchFsuipc(cfg?.FsuipcRoot);
            Program.Log("FSUIPC7 at startup: " + outcome);
        }
        catch (Exception ex)
        {
            // Not fatal. The gate will report FSUIPC missing or not run, in
            // words, which is better than a crash here would be.
            Program.LogError("LaunchFsuipc at startup", ex);
        }

        var userData = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "HoneycombAssignment", "webview");
        Directory.CreateDirectory(userData);

        var env = await CoreWebView2Environment.CreateAsync(null, userData);
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
        _web.CoreWebView2.ProcessFailed += (_, ev) =>
            Program.Log($"WebView2 process failed: {ev.ProcessFailedKind}, reason {ev.Reason}, exit code {ev.ExitCode}" +
                        (string.IsNullOrEmpty(ev.ProcessDescription) ? "" : $", {ev.ProcessDescription}"));
        _web.CoreWebView2.NavigationCompleted += async (_, _) =>
        {
            try { await RefreshAllAsync(); }
            catch (Exception ex) { Program.LogError("RefreshAll", ex); }
            _slowPoll.Start();
        };

        var ui = Path.Combine(AppContext.BaseDirectory, "ui", "index.html");
        _web.CoreWebView2.Navigate(new Uri(ui).AbsoluteUri);
    }

    protected override void WndProc(ref Message m)
    {
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
                ReleaseCapture();
                SendMessage(Handle, WM_NCLBUTTONDOWN, (IntPtr)HTCAPTION, IntPtr.Zero);
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

    private Task PushConfigAsync() => Send(new
    {
        kind = "config",
        exists = _cfg != null,
        problem = _cfgProblem,
        pilotId = _cfg?.SimBriefPilotId ?? "",
        lastAircraftId = _cfg?.LastAircraftId ?? "",
        capsSetForLayout = _cfg?.CapsSetForLayout ?? "",
        aircraftUse = _cfg?.AircraftUse ?? new Dictionary<string, int>()
    });

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

    private async Task LaunchAsync()
    {
        // FSUIPC normally started with the program; this is the safety net if
        // it was closed since. Already running is the expected answer here.
        Program.Log("FSUIPC7 at launch step: " + Runner.LaunchFsuipc(_cfg?.FsuipcRoot));

        Runner.LaunchSimulator();
        await Send(new { kind = "launched" });
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
