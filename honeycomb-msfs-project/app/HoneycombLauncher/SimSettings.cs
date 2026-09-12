using System.Text.RegularExpressions;

namespace HoneycombLauncher;

/// <summary>
/// What can be read of the simulator's own settings from disk. Only UserCfg.opt
/// so far: plain text, rewritten by the sim within a second or two of every
/// change made in Options (measured 2026-09-07 and again 2026-09-12), so a
/// read is always current. The Traffic Type on the Online page is NOT in it -
/// that one lives in Microsoft's cloud profile (measured 2026-09-11).
/// </summary>
internal static class SimSettings
{
    /// <summary>The two graphics traffic levels that change between traffic modes.</summary>
    public sealed class TrafficGraphics
    {
        public int Aircraft;          // Graphics > Traffic > AircraftTrafficQuantity
        public int Parked;            // Graphics > Traffic > ParkedAircraftQuantity
        public string Path;
        public DateTime WrittenUtc;   // the file's last write, i.e. when the sim last saved
        public bool Matches(int aircraft, int parked) => Aircraft == aircraft && Parked == parked;
    }

    /// <summary>
    /// The word the sim shows for a level. Measured 2026-09-12 with Mark at
    /// the Graphics page: Off writes -1, Ultra writes 3. The levels between
    /// have not been read back against their words, so they are named as
    /// levels rather than guessed at.
    /// </summary>
    public static string LevelWord(int level) => level switch
    {
        -1 => "OFF",
        3  => "ULTRA",
        _  => "LEVEL " + level
    };

    /// <summary>
    /// The settings file of the installed simulator: MS Store first, Steam
    /// second; null when neither exists.
    /// </summary>
    public static string FindUserCfg()
    {
        // For tests: point at a copy, so nothing rehearses against the real file.
        var over = Environment.GetEnvironmentVariable("HONEYCOMB_USERCFG");
        if (!string.IsNullOrWhiteSpace(over) && File.Exists(over)) return over;
        var store = System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            @"Packages\Microsoft.Limitless_8wekyb3d8bbwe\LocalCache\UserCfg.opt");
        if (File.Exists(store)) return store;
        var steam = System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            @"Microsoft Flight Simulator 2024\UserCfg.opt");
        if (File.Exists(steam)) return steam;
        return null;
    }

    /// <summary>
    /// Reads the two levels from the first {Traffic block, which is the one
    /// under {Graphics; the {GraphicsVR block has its own and is ignored.
    /// Returns null and says why when the file cannot be read or does not
    /// hold both values - never a guess.
    /// </summary>
    public static TrafficGraphics ReadTrafficGraphics(out string problem)
    {
        problem = null;
        var path = FindUserCfg();
        if (path == null) { problem = "the simulator's settings file (UserCfg.opt) was not found in the MS Store or Steam place"; return null; }
        string text;
        try { text = File.ReadAllText(path); }
        catch (Exception ex) { problem = "the simulator's settings file could not be read: " + ex.Message; return null; }
        return Parse(text, path, File.GetLastWriteTimeUtc(path), out problem);
    }

    public static TrafficGraphics Parse(string text, string path, DateTime writtenUtc, out string problem)
    {
        problem = null;
        int at = text.IndexOf("{Traffic", StringComparison.Ordinal);
        if (at < 0) { problem = "no {Traffic block in " + path; return null; }
        int end = text.IndexOf('}', at);
        if (end < 0) end = text.Length;
        var block = text.Substring(at, end - at);
        var a = Regex.Match(block, @"AircraftTrafficQuantity\s+(-?\d+)");
        var p = Regex.Match(block, @"ParkedAircraftQuantity\s+(-?\d+)");
        if (!a.Success || !p.Success) { problem = "the {Traffic block in " + path + " does not hold both AircraftTrafficQuantity and ParkedAircraftQuantity"; return null; }
        return new TrafficGraphics
        {
            Aircraft = int.Parse(a.Groups[1].Value),
            Parked = int.Parse(p.Groups[1].Value),
            Path = path,
            WrittenUtc = writtenUtc
        };
    }
}
