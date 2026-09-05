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
    /// Works out where FSUIPC7 is installed, the same way the preflight check
    /// does: the running process first, then the uninstall registry, then a
    /// folder named FSUIPC7 at the root of each drive. Returns "" if not found.
    ///
    /// Needed because fsuipcRoot was read from the configuration but never
    /// written to it. On this machine it happened to be set; on a fresh one it
    /// is empty, so the app would neither start FSUIPC nor be able to tell the
    /// aircraft check where the ini lives - and nothing would say why.
    /// </summary>
    public static string FindFsuipcRoot()
    {
        try
        {
            var p = Process.GetProcessesByName("FSUIPC7").FirstOrDefault();
            if (p?.MainModule?.FileName is string running) return Path.GetDirectoryName(running) ?? "";
        }
        catch { /* a running process we cannot inspect is not an error here */ }

        foreach (var key in new[]
        {
            @"HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
            @"HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
            @"HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        })
        {
            try
            {
                using var root = Microsoft.Win32.RegistryKey.OpenBaseKey(
                        key.StartsWith("HKEY_CURRENT_USER") ? Microsoft.Win32.RegistryHive.CurrentUser
                                                            : Microsoft.Win32.RegistryHive.LocalMachine,
                        Microsoft.Win32.RegistryView.Default)
                    .OpenSubKey(key.Substring(key.IndexOf('\\') + 1));
                if (root is null) continue;
                foreach (var name in root.GetSubKeyNames())
                {
                    using var sub = root.OpenSubKey(name);
                    if (sub?.GetValue("DisplayName") is string dn && dn.Contains("FSUIPC7", StringComparison.OrdinalIgnoreCase)
                        && sub.GetValue("InstallLocation") is string loc && !string.IsNullOrWhiteSpace(loc)
                        && File.Exists(Path.Combine(loc, "FSUIPC7.exe")))
                        return loc.TrimEnd('\\');
                }
            }
            catch { /* try the next hive */ }
        }

        foreach (var d in DriveInfo.GetDrives())
        {
            try
            {
                var c = Path.Combine(d.RootDirectory.FullName, "FSUIPC7");
                if (File.Exists(Path.Combine(c, "FSUIPC7.exe"))) return c;
            }
            catch { /* an unready drive is not an error */ }
        }
        return "";
    }

    /// <summary>
    /// Closes FSUIPC7 so its ini can be written, and reports whether it went.
    /// FSUIPC rewrites the whole file when it exits, so anything written while
    /// it runs is silently undone - which is why the assignment tool refuses.
    ///
    /// Asks politely first. FSUIPC7 normally sits in the tray with no window to
    /// close, so the fallback is expected rather than exceptional; at setup
    /// time there are no in-session settings to lose.
    /// </summary>
    public static bool StopFsuipc(TimeSpan timeout)
    {
        var procs = Process.GetProcessesByName("FSUIPC7");
        if (procs.Length == 0) return true;

        foreach (var p in procs)
        {
            try { if (p.MainWindowHandle != IntPtr.Zero) p.CloseMainWindow(); } catch { }
        }
        var deadline = DateTime.UtcNow + timeout;
        while (DateTime.UtcNow < deadline)
        {
            if (Process.GetProcessesByName("FSUIPC7").Length == 0) { Thread.Sleep(750); return true; }
            Thread.Sleep(250);
        }
        foreach (var p in Process.GetProcessesByName("FSUIPC7"))
        {
            try { p.Kill(); } catch { }
        }
        Thread.Sleep(750);
        return Process.GetProcessesByName("FSUIPC7").Length == 0;
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
