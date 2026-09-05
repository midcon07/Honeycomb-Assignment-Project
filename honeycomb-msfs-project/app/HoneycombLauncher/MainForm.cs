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

            case "setupLevers":
                {
                    var id = msg.TryGetProperty("id", out var v) ? v.GetString() : null;
                    if (string.IsNullOrWhiteSpace(id))
                    {
                        await Send(new { kind = "setupResult", ok = false, message = "No aircraft chosen." });
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
                    await Send(new
                    {
                        kind = "setupResult",
                        ok = res.ExitCode == 0,
                        message = said
                    });
                    await PushPreflightAsync(true);
                    break;
                }

            case "setupButtons":
                await SetupButtonsAsync();
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
                    await SetupButtonsAsync();
                    if (!string.IsNullOrWhiteSpace(id)) await SetupLeversAsync(id);
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
        await Send(new { kind = "setupResult", ok = true, message = "Closing FSUIPC so its settings file can be written…" });

        var wasRunning = System.Diagnostics.Process.GetProcessesByName("FSUIPC7").Length > 0;
        if (!Runner.StopFsuipc(TimeSpan.FromSeconds(10)))
        {
            await Send(new
            {
                kind = "setupResult",
                ok = false,
                message = "FSUIPC7 would not close, so nothing was written.\n" +
                          "Close it from its icon near the clock, then try again."
            });
            return;
        }

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
        if (wasRunning && !string.IsNullOrWhiteSpace(root))
            Program.Log("FSUIPC7 restarted after setup: " + Runner.LaunchFsuipc(root));

        Program.Log($"setupLevers finished, exit {res.ExitCode}");
        await Send(new
        {
            kind = "setupResult",
            ok,
            message = (ok ? "Done.\n\n" : "Nothing was written.\n\n") + said
        });

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
        await Send(new { kind = "setupResult", ok = true, message = "Closing FSUIPC so its settings file can be written…" });

        var wasRunning = System.Diagnostics.Process.GetProcessesByName("FSUIPC7").Length > 0;
        if (!Runner.StopFsuipc(TimeSpan.FromSeconds(10)))
        {
            await Send(new { kind = "setupResult", ok = false,
                message = "FSUIPC7 would not close, so nothing was written.\nClose it from its icon near the clock, then try again." });
            return;
        }

        var res = await Runner.PowerShellAsync(
            Path.Combine(Runner.ToolsDir, "Set-BravoButtons.ps1"));
        var said = (res.StdOut + "\n" + res.StdErr).Trim();
        var ok = res.ExitCode == 0;

        var root = _cfg?.FsuipcRoot;
        if (string.IsNullOrWhiteSpace(root)) root = Runner.FindFsuipcRoot();
        if (wasRunning && !string.IsNullOrWhiteSpace(root))
            Program.Log("FSUIPC7 restarted after button setup: " + Runner.LaunchFsuipc(root));

        Program.Log($"setupButtons finished, exit {res.ExitCode}");
        await Send(new { kind = "setupResult", ok, message = (ok ? "Done.\n\n" : "Nothing was written.\n\n") + said });
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
