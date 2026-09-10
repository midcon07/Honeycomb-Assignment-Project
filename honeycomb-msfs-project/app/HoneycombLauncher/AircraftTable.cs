using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace HoneycombLauncher;

/// <summary>
/// One aircraft the launcher knows: the same shape as an entry in
/// data/lever-layouts.json, whether it shipped with the program or was added
/// on this machine.
/// </summary>
internal sealed class AircraftEntry
{
    [JsonPropertyName("name")]       public string Name { get; set; } = "";
    [JsonPropertyName("icao")]       public string Icao { get; set; } = "";
    [JsonPropertyName("match")]      public string Match { get; set; } = "";
    [JsonPropertyName("titleMatch")] public string TitleMatch { get; set; } = "";
    [JsonPropertyName("facts")]      public Dictionary<string, JsonElement> Facts { get; set; } = new();
    [JsonPropertyName("layout")]     public string Layout { get; set; } = "";
    [JsonPropertyName("verified")]   public string Verified { get; set; } = "";
    [JsonExtensionData]              public Dictionary<string, JsonElement> Extra { get; set; } = new();

    /// <summary>True for an entry from this machine's own file.</summary>
    [JsonIgnore] public bool Local { get; set; }

    /// <summary>
    /// The key the app stores (lastAircraftId, aircraftUse): the ICAO type in
    /// lower case, or the profile name for an aircraft added without one.
    /// </summary>
    [JsonIgnore] public string Id => (string.IsNullOrWhiteSpace(Icao) ? Match : Icao).Trim().ToLowerInvariant();
}

internal sealed class LocalAircraftFile
{
    [JsonPropertyName("schemaVersion")] public int SchemaVersion { get; set; } = 1;
    [JsonPropertyName("$comment")] public string Comment { get; set; } =
        "Aircraft added in the launcher on this machine. Same shape as the aircraft entries in " +
        "data/lever-layouts.json; an entry here with the same ICAO (or profile name) replaces the " +
        "shipped one. Written by the app; safe to edit by hand while the app is closed.";
    [JsonPropertyName("aircraft")] public List<AircraftEntry> Aircraft { get; set; } = new();
}

/// <summary>
/// The aircraft table as one list: the shipped data/lever-layouts.json plus
/// this machine's additions in %LOCALAPPDATA%\HoneycombAssignment\aircraft.json.
///
/// The second file is the whole point. Until it existed, adding an aircraft
/// meant editing the shipped table, rebuilding the program and sending a new
/// zip - which the person flying cannot do. Now the app writes the entry
/// itself, from the one fact only the simulator can give (the aircraft's
/// title as FSUIPC logs it) and the few facts a person answers.
/// </summary>
internal static class AircraftTable
{
    public static string LocalPath { get; } =
        Path.Combine(Path.GetDirectoryName(AppConfig.Path)!, "aircraft.json");

    public static string ShippedPath { get; } =
        Path.Combine(Runner.ToolsDir, "..", "data", "lever-layouts.json");

    public static List<AircraftEntry> LoadMerged()
    {
        var list = new List<AircraftEntry>();
        try
        {
            if (File.Exists(ShippedPath))
            {
                using var doc = JsonDocument.Parse(File.ReadAllText(ShippedPath));
                if (doc.RootElement.TryGetProperty("aircraft", out var arr))
                    foreach (var a in arr.EnumerateArray())
                    {
                        var e = a.Deserialize<AircraftEntry>();
                        if (e != null && !string.IsNullOrWhiteSpace(e.Id)) list.Add(e);
                    }
            }
        }
        catch (Exception ex) { Program.LogError("read shipped aircraft table", ex); }

        foreach (var e in LoadLocal().Aircraft)
        {
            if (string.IsNullOrWhiteSpace(e.Id)) continue;
            e.Local = true;
            list.RemoveAll(x => string.Equals(x.Id, e.Id, StringComparison.OrdinalIgnoreCase));
            list.Add(e);
        }
        return list;
    }

    /// <summary>
    /// The lever layouts and the cap vocabulary from the shipped table, for
    /// the page. The page used to carry a hand copy of both and it drifted
    /// (King Air 350 on the wrong layout, C90 absent, a cap labelled
    /// differently), so every table change had to be made twice. One source
    /// now: a layout is {name, group, lv[6] cap ids with "none" for an empty
    /// lever, fns[6] function names}; capLabels maps cap id to its label.
    /// </summary>
    public static (Dictionary<string, object> layouts, Dictionary<string, string> capLabels) LoadLayouts()
    {
        var layouts = new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase);
        var caps = new Dictionary<string, string> { ["none"] = "No cap" };
        try
        {
            if (File.Exists(ShippedPath))
            {
                using var doc = JsonDocument.Parse(File.ReadAllText(ShippedPath));
                if (doc.RootElement.TryGetProperty("handles", out var handles) && handles.ValueKind == JsonValueKind.Object)
                    foreach (var h in handles.EnumerateObject())
                        if (h.Value.TryGetProperty("label", out var lbl) && lbl.ValueKind == JsonValueKind.String)
                            caps[h.Name] = lbl.GetString() ?? h.Name;
                if (doc.RootElement.TryGetProperty("layouts", out var arr) && arr.ValueKind == JsonValueKind.Array)
                    foreach (var l in arr.EnumerateArray())
                    {
                        var id = l.TryGetProperty("id", out var idEl) && idEl.ValueKind == JsonValueKind.String ? idEl.GetString() : null;
                        if (string.IsNullOrWhiteSpace(id)) continue;
                        string?[] Strings(string prop) =>
                            l.TryGetProperty(prop, out var a) && a.ValueKind == JsonValueKind.Array
                                ? a.EnumerateArray().Select(x => x.ValueKind == JsonValueKind.String ? x.GetString() : null).ToArray()
                                : Array.Empty<string?>();
                        layouts[id] = new
                        {
                            name  = l.TryGetProperty("name", out var n) && n.ValueKind == JsonValueKind.String ? n.GetString() ?? id : id,
                            group = l.TryGetProperty("group", out var g) && g.ValueKind == JsonValueKind.String ? g.GetString() ?? "" : "",
                            lv    = Strings("caps").Select(c => string.IsNullOrEmpty(c) ? "none" : c).ToArray(),
                            fns   = Strings("functions")
                        };
                    }
            }
        }
        catch (Exception ex) { Program.LogError("read lever layouts", ex); }
        return (layouts, caps);
    }

    public static LocalAircraftFile LoadLocal()
    {
        try
        {
            if (File.Exists(LocalPath))
                return JsonSerializer.Deserialize<LocalAircraftFile>(File.ReadAllText(LocalPath)) ?? new LocalAircraftFile();
        }
        catch (Exception ex) { Program.LogError("read local aircraft table", ex); }
        return new LocalAircraftFile();
    }

    public static void AddLocal(AircraftEntry e)
    {
        var f = LoadLocal();
        f.Aircraft.RemoveAll(x => string.Equals(x.Id, e.Id, StringComparison.OrdinalIgnoreCase));
        f.Aircraft.Add(e);
        Directory.CreateDirectory(Path.GetDirectoryName(LocalPath)!);
        if (File.Exists(LocalPath)) { try { File.Copy(LocalPath, LocalPath + ".bak", true); } catch { } }
        File.WriteAllText(LocalPath, JsonSerializer.Serialize(f, new JsonSerializerOptions { WriteIndented = true }));
    }

    /// <summary>
    /// Every aircraft title FSUIPC has logged (Aircraft="..."), newest first,
    /// each once. The current log first, then the previous one.
    /// </summary>
    public static List<string> LoggedTitles(string fsuipcRoot)
    {
        var seen = new List<string>();
        foreach (var name in new[] { "FSUIPC7.log", "FSUIPC7_prev.log" })
        {
            var p = Path.Combine(fsuipcRoot, name);
            if (!File.Exists(p)) continue;
            string text;
            try
            {
                // FSUIPC keeps the log open; share everything so a read never fails.
                using var fs = new FileStream(p, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
                using var sr = new StreamReader(fs);
                text = sr.ReadToEnd();
            }
            catch (Exception ex) { Program.LogError("read " + name, ex); continue; }

            var inThisFile = new List<string>();
            foreach (Match m in Regex.Matches(text, "Aircraft=\"([^\"]+)\""))
                inThisFile.Add(m.Groups[1].Value.Trim());
            inThisFile.Reverse();
            foreach (var t in inThisFile)
                if (!seen.Any(s => string.Equals(s, t, StringComparison.OrdinalIgnoreCase))) seen.Add(t);
        }
        return seen;
    }

    /// <summary>
    /// The substring the FSUIPC profile matches on: the logged title minus
    /// trailing variant and livery words. Measured examples this rule was
    /// built from: "737-600 PAX SC" -> "737-600"; "Douglas DC-3 METAL LEFT"
    /// -> "Douglas DC-3"; "DA62 Passengers" -> "DA62"; "Beechcraft King Air"
    /// stays whole. Trailing words are dropped while they are all capitals
    /// (a livery code) or a known variant word; a word with a digit in it
    /// ("G1000", "DC-3", "777F") is part of the aircraft's name and stops the
    /// trimming. The first word always stays.
    /// </summary>
    public static string TitleMatchFor(string title)
    {
        var toks = title.Trim().Split(' ', StringSplitOptions.RemoveEmptyEntries).ToList();
        while (toks.Count > 1)
        {
            var t = toks[^1];
            // Punctuation-only tokens (the " - " before a livery) go with it.
            var livery = Regex.IsMatch(t, @"^[\W_]+$") || Regex.IsMatch(t, "^[A-Z]{2,}$") ||
                         Regex.IsMatch(t, "^(Passengers?|Cargo|Freighter|Pax)$", RegexOptions.IgnoreCase);
            if (!livery) break;
            toks.RemoveAt(toks.Count - 1);
        }
        return string.Join(' ', toks);
    }

    /// <summary>Profile section name: the title substring with anything an ini section cannot carry removed.</summary>
    public static string ProfileNameFor(string titleMatch) =>
        Regex.Replace(titleMatch, @"[^A-Za-z0-9 ._\-]", "").Trim();

    public static bool ValidIcao(string s) => Regex.IsMatch(s, "^[A-Z0-9]{2,5}$");

    /// <summary>
    /// The layout the answers resolve to. The rule is the one the shipped
    /// table follows: prop control and mixture -> constant-speed; mixture
    /// alone -> fixed-pitch; neither -> FADEC. Turboprops and jets have
    /// their own families; a glider has one layout.
    /// </summary>
    public static string LayoutFor(string category, int engines, bool propLever, bool mixtureLever)
    {
        var n = Math.Clamp(engines, 1, 4);
        switch ((category ?? "").ToLowerInvariant())
        {
            case "jet":       return "jet_" + n;
            case "turboprop": return "turboprop_" + Math.Min(n, 2);
            case "glider":    return "glider";
            default:
                n = Math.Min(n, 2);
                if (propLever && mixtureLever) return $"prop_{n}_cs";
                if (mixtureLever) return $"prop_{n}_fixed";
                return $"fadec_{n}";
        }
    }
}
