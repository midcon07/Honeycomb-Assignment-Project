using System.Diagnostics;
using Microsoft.Win32;

namespace HoneycombLauncher;

/// <summary>
/// The programs that feed AI traffic when the simulator's own engine is off:
/// BeyondATC and the FSLTL injector. Where they are, whether they run, and
/// starting them (Mark, 2026-09-12: "once the graphics settings are correct,
/// prompt the user to start the AI traffic program").
///
/// Nothing here is a constant path. BeyondATC is found through the uninstall
/// registry it writes (Inno Setup), a running copy, or a folder named
/// BeyondATC at the root of a drive, and the place is then recorded in
/// config.json. The FSLTL injector lives in the Community folder the
/// simulator names in UserCfg.opt.
/// </summary>
internal static class TrafficEngines
{
    /// <summary>One engine: how it is named on the sheet, its process name, and where its exe is (null if not found).</summary>
    public sealed class Engine
    {
        public string Mode;          // BATC or FSLTL
        public string Name;          // as printed
        public string ProcessName;   // for Process.GetProcessesByName
        public string Path;          // the exe, or null
        public bool IsRunning() { try { return Process.GetProcessesByName(ProcessName).Length > 0; } catch { return false; } }
    }

    /// <summary>The engine a mode needs; null for MSFS (its own engine) or no mode.</summary>
    public static Engine For(string mode, AppConfig cfg) => mode switch
    {
        "BATC"  => new Engine { Mode = "BATC",  Name = "BeyondATC",      ProcessName = "BeyondATC",            Path = FindBatc(cfg) },
        "FSLTL" => new Engine { Mode = "FSLTL", Name = "FSLTL injector", ProcessName = "fsltl-trafficinjector", Path = FindFsltlInjector() },
        _ => null
    };

    /// <summary>Every engine, for warning when one runs that the mode does not want.</summary>
    public static Engine[] All(AppConfig cfg) => new[] { For("BATC", cfg), For("FSLTL", cfg) };

    public static string FindBatc(AppConfig cfg)
    {
        // Recorded from an earlier find, if it is still there.
        var known = cfg?.BatcPath ?? "";
        if (known != "" && File.Exists(known)) return known;

        // A running copy says where it is.
        try
        {
            var p = Process.GetProcessesByName("BeyondATC").FirstOrDefault();
            if (p?.MainModule?.FileName is string running && File.Exists(running)) return Remember(cfg, running);
        }
        catch { /* a process we cannot inspect */ }

        // The uninstall entry its installer writes.
        foreach (var (hive, sub) in new[]
        {
            (Registry.LocalMachine, @"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"),
            (Registry.LocalMachine, @"SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"),
            (Registry.CurrentUser,  @"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"),
        })
        {
            try
            {
                using var key = hive.OpenSubKey(sub);
                if (key == null) continue;
                foreach (var name in key.GetSubKeyNames())
                {
                    using var k = key.OpenSubKey(name);
                    var display = k?.GetValue("DisplayName") as string ?? "";
                    if (!display.Contains("BeyondATC", StringComparison.OrdinalIgnoreCase)) continue;
                    var loc = k.GetValue("InstallLocation") as string ?? "";
                    var exe = loc == "" ? "" : System.IO.Path.Combine(loc, "BeyondATC.exe");
                    if (exe != "" && File.Exists(exe)) return Remember(cfg, exe);
                    var icon = (k.GetValue("DisplayIcon") as string ?? "").Split(',')[0].Trim('"');
                    if (icon.EndsWith("BeyondATC.exe", StringComparison.OrdinalIgnoreCase) && File.Exists(icon)) return Remember(cfg, icon);
                }
            }
            catch { }
        }

        // A folder named BeyondATC at the root of a drive, or under Program Files.
        var roots = new List<string>();
        try { foreach (var d in DriveInfo.GetDrives()) if (d.DriveType == DriveType.Fixed) roots.Add(d.RootDirectory.FullName); } catch { }
        roots.Add(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles));
        roots.Add(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86));
        roots.Add(System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs"));
        foreach (var r in roots)
        {
            try
            {
                var exe = System.IO.Path.Combine(r, "BeyondATC", "BeyondATC.exe");
                if (File.Exists(exe)) return Remember(cfg, exe);
            }
            catch { }
        }
        return null;
    }

    private static string Remember(AppConfig cfg, string path)
    {
        if (cfg != null && cfg.BatcPath != path)
        {
            cfg.BatcPath = path;
            try { cfg.Save(); } catch (Exception ex) { Program.LogError("remember BeyondATC path", ex); }
        }
        return path;
    }

    public static string FindFsltlInjector()
    {
        var userCfg = SimSettings.FindUserCfg();
        if (userCfg == null) return null;
        string packages = null;
        try
        {
            foreach (var line in File.ReadLines(userCfg))
            {
                var t = line.Trim();
                if (!t.StartsWith("InstalledPackagesPath", StringComparison.Ordinal)) continue;
                var q1 = t.IndexOf('"'); var q2 = t.LastIndexOf('"');
                if (q1 >= 0 && q2 > q1) packages = t.Substring(q1 + 1, q2 - q1 - 1);
                break;
            }
        }
        catch { return null; }
        if (packages == null) return null;
        var exe = System.IO.Path.Combine(packages, "Community", "fsltl-traffic-injector", "fsltl-trafficinjector.exe");
        return File.Exists(exe) ? exe : null;
    }

    /// <summary>Starts the engine from its own folder. Returns null on success, else why not.</summary>
    public static string Start(Engine e)
    {
        if (e?.Path == null) return e?.Name + " was not found on this computer";
        try
        {
            Process.Start(new ProcessStartInfo
            {
                FileName = e.Path,
                WorkingDirectory = System.IO.Path.GetDirectoryName(e.Path),
                UseShellExecute = true
            });
            return null;
        }
        catch (Exception ex) { return ex.Message; }
    }
}
