using System.Diagnostics;
using System.Text;
using System.Text.Json;

namespace HoneycombLauncher;

/// <summary>
/// Runs the PowerShell tools and reads their JSON back. The tools are the
/// tested part of this project; the app is glue, not a reimplementation.
/// </summary>
internal static class Runner
{
    /// <summary>Where the tools live, walking up from the executable.</summary>
    public static string ToolsDir { get; } = FindToolsDir();

    private static string FindToolsDir()
    {
        // bin\Release\net8.0-windows\ -> app\HoneycombLauncher -> app -> project
        var d = new DirectoryInfo(AppContext.BaseDirectory);
        for (int i = 0; i < 8 && d != null; i++)
        {
            var candidate = Path.Combine(d.FullName, "tools");
            if (Directory.Exists(Path.Combine(candidate, "Preflight"))) return candidate;
            d = d.Parent;
        }
        return Path.Combine(AppContext.BaseDirectory, "tools");
    }

    public sealed record Result(int ExitCode, string StdOut, string StdErr);

    public static async Task<Result> PowerShellAsync(string scriptPath, params string[] args)
    {
        var psi = new ProcessStartInfo
        {
            FileName = "powershell.exe",
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8
        };
        // Execution policy is Undefined on a stock machine, so a .ps1 will not
        // run when invoked normally. Bypass here rather than asking the user to
        // change a machine-wide security setting.
        psi.ArgumentList.Add("-NoProfile");
        psi.ArgumentList.Add("-ExecutionPolicy");
        psi.ArgumentList.Add("Bypass");
        psi.ArgumentList.Add("-File");
        psi.ArgumentList.Add(scriptPath);
        foreach (var a in args) psi.ArgumentList.Add(a);

        using var p = new Process { StartInfo = psi };
        p.Start();
        var so = p.StandardOutput.ReadToEndAsync();
        var se = p.StandardError.ReadToEndAsync();
        await p.WaitForExitAsync();
        return new Result(p.ExitCode, await so, await se);
    }

    /// <summary>Runs a tool that writes JSON to a temp file, and parses it.</summary>
    public static async Task<(JsonElement? Json, Result Raw)> JsonToolAsync(
        string scriptPath, params string[] args)
    {
        var tmp = Path.Combine(Path.GetTempPath(),
            $"hcl-{Guid.NewGuid():N}.json");
        var all = new List<string>(args) { "-Json", tmp, "-Quiet" };
        var res = await PowerShellAsync(scriptPath, all.ToArray());
        try
        {
            if (File.Exists(tmp))
            {
                using var doc = JsonDocument.Parse(File.ReadAllText(tmp));
                return (doc.RootElement.Clone(), res);
            }
        }
        catch { /* fall through - caller decides what a missing result means */ }
        finally
        {
            try { if (File.Exists(tmp)) File.Delete(tmp); } catch { }
        }
        return (null, res);
    }

    public static Task<(JsonElement? Json, Result Raw)> PreflightAsync() =>
        JsonToolAsync(Path.Combine(ToolsDir, "Preflight", "Invoke-Preflight.ps1"));

    public static Task<(JsonElement? Json, Result Raw)> SimBriefAsync(string pilotId) =>
        JsonToolAsync(Path.Combine(ToolsDir, "Get-SimBriefPlan.ps1"), "-PilotId", pilotId);

    /// <summary>
    /// Starts MSFS 2024. The incantation is taken from FSUIPC's own MSFS24.bat.
    /// </summary>
    public static void LaunchSimulator()
    {
        Process.Start(new ProcessStartInfo
        {
            FileName = "explorer.exe",
            Arguments = @"shell:AppsFolder\Microsoft.Limitless_8wekyb3d8bbwe!App",
            UseShellExecute = true
        });
    }

    /// <summary>
    /// Starts FSUIPC7 from its own folder, unless it is already running or is
    /// not where the configuration says. Returns a short word for the log:
    /// "started", "already running", "not configured" or "not found".
    /// FSUIPC7 is single-instance, but starting it again still rewrites its
    /// log and re-scans devices, so the check is worth having.
    /// </summary>
    public static string LaunchFsuipc(string? root)
    {
        if (string.IsNullOrWhiteSpace(root)) return "not configured";
        if (Process.GetProcessesByName("FSUIPC7").Length > 0) return "already running";

        var exe = Path.Combine(root, "FSUIPC7.exe");
        if (!File.Exists(exe)) return "not found at " + exe;

        Process.Start(new ProcessStartInfo
        {
            FileName = exe,
            WorkingDirectory = root,
            UseShellExecute = true
        });
        return "started";
    }

    public static void OpenUrl(string url)
    {
        Process.Start(new ProcessStartInfo { FileName = url, UseShellExecute = true });
    }
}
