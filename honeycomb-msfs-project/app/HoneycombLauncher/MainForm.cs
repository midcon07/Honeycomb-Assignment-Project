using System.Text.Json;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

namespace HoneycombLauncher;

internal sealed class MainForm : Form
{
    private readonly WebView2 _web = new() { Dock = DockStyle.Fill };
    private AppConfig _cfg;
    private string _cfgProblem;

    public MainForm()
    {
        Text = "Honeycomb Preflight";
        Width = 1400;
        Height = 980;
        StartPosition = FormStartPosition.CenterScreen;
        BackColor = Color.FromArgb(10, 12, 13);
        Controls.Add(_web);
        Shown += async (_, _) => await StartAsync();
    }

    private async Task StartAsync()
    {
        var userData = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "HoneycombAssignment", "webview");
        Directory.CreateDirectory(userData);

        var env = await CoreWebView2Environment.CreateAsync(null, userData);
        await _web.EnsureCoreWebView2Async(env);

        _web.CoreWebView2.Settings.AreDefaultContextMenusEnabled = false;
        _web.CoreWebView2.Settings.IsStatusBarEnabled = false;
        _web.CoreWebView2.WebMessageReceived += OnMessage;

        var ui = Path.Combine(AppContext.BaseDirectory, "ui", "index.html");
        _web.CoreWebView2.Navigate(new Uri(ui).AbsoluteUri);
        _web.CoreWebView2.NavigationCompleted += async (_, _) => await RefreshAllAsync();
    }

    // ---- messages from the page -------------------------------------------

    private async void OnMessage(object sender, CoreWebView2WebMessageReceivedEventArgs e)
    {
        JsonElement msg;
        try { msg = JsonDocument.Parse(e.WebMessageAsJson).RootElement; } catch { return; }
        var action = msg.TryGetProperty("action", out var a) ? a.GetString() : null;

        switch (action)
        {
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
                    if (_cfg != null && !string.IsNullOrEmpty(layout))
                    {
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
        await PushPreflightAsync();
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

    private async Task PushPreflightAsync()
    {
        await Send(new { kind = "preflightBusy" });
        var (json, raw) = await Runner.PreflightAsync();
        if (json is null)
        {
            await Send(new
            {
                kind = "preflight",
                verdict = "CANNOT RUN",
                error = string.IsNullOrWhiteSpace(raw.StdErr) ? raw.StdOut : raw.StdErr,
                results = Array.Empty<object>()
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
            await Send(new { kind = "plan", status = "NoPilotId" });
            return;
        }
        await Send(new { kind = "planBusy" });
        var (json, _) = await Runner.SimBriefAsync(pid);
        if (json is null) { await Send(new { kind = "plan", status = "Unavailable" }); return; }
        await SendRaw("plan", json.Value);
    }

    private async Task LaunchAsync()
    {
        // Start FSUIPC first so it is waiting when the simulator comes up, then
        // the simulator last, which is the whole point of the sequence.
        if (!string.IsNullOrWhiteSpace(_cfg?.FsuipcRoot))
            Runner.LaunchFsuipc(_cfg.FsuipcRoot);

        Runner.LaunchSimulator();
        await Send(new { kind = "launched" });
    }

    // ---- plumbing ----------------------------------------------------------

    private async Task Send(object payload)
    {
        var json = JsonSerializer.Serialize(payload);
        await _web.CoreWebView2.ExecuteScriptAsync(
            $"window.APP && window.APP.receive({json});");
    }

    private async Task SendRaw(string kind, JsonElement body)
    {
        var json = $"{{\"kind\":\"{kind}\",\"data\":{body.GetRawText()}}}";
        await _web.CoreWebView2.ExecuteScriptAsync(
            $"window.APP && window.APP.receive({json});");
    }
}
