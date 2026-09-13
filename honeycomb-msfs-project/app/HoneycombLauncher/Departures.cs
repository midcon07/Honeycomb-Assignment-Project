using System.Net.Http;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace HoneycombLauncher;

/// <summary>
/// The real departures from the plan's origin around the plan's departure
/// time, for the airport under the printer (Mark, 2026-09-12: "if I have a
/// simbrief plan loaded, look up departures for approximately the same time
/// as my scheduled departure from that airport to generate the ambience").
///
/// Source: Flightradar24's airport schedule endpoint, the one its own web
/// page reads - no key, no account, but unofficial, so every failure is
/// logged and the ambience falls back to its era-flavoured invented flights.
/// Never a guess: a flight is used only with an airline name and a number.
/// </summary>
internal static class Departures
{
    public sealed class Flight
    {
        public string Airline;     // "United Airlines"
        public string Number;      // "1245" - the digits after the airline code
        public string City;        // destination, spoken; may be null
        public string Gate;        // at the origin; may be null
        public DateTime SchedUtc;
    }

    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(25) };

    /// <summary>
    /// Departures scheduled within an hour and a half either side of the
    /// given time, as many as two pages of the schedule hold. Empty on any
    /// failure, with the reason logged.
    /// </summary>
    public static async Task<List<Flight>> FetchAsync(string originIcao, DateTime schedOutUtc)
    {
        var list = new List<Flight>();
        if (string.IsNullOrWhiteSpace(originIcao)) return list;
        // The schedule covers the days around now, not a week-old plan
        // (measured 2026-09-12: a date five days back answered 400). A
        // plan's departure outside that window is taken as its time of day,
        // today - the same airport at the same hour is the point.
        var now = DateTime.UtcNow;
        var when = schedOutUtc;
        if (when < now.AddHours(-12) || when > now.AddDays(2))
        {
            when = now.Date + schedOutUtc.TimeOfDay;
            if (when < now.AddHours(-12)) when = when.AddDays(1);
            Program.Log($"departures: the plan's departure {schedOutUtc:yyyy-MM-dd HH:mm}Z is outside the schedule's window; using {when:yyyy-MM-dd HH:mm}Z");
        }
        long ts = new DateTimeOffset(when, TimeSpan.Zero).ToUnixTimeSeconds();
        schedOutUtc = when;
        for (int page = 1; page <= 2; page++)
        {
            var url = "https://api.flightradar24.com/common/v1/airport.json?code=" + Uri.EscapeDataString(originIcao)
                    + "&plugin[]=schedule&plugin-setting[schedule][mode]=departures&plugin-setting[schedule][timestamp]=" + ts
                    + "&page=" + page + "&limit=100";
            string body = await GetAsync(url, originIcao, page);
            if (body == null) break;
            int before = list.Count;
            try { Parse(body, schedOutUtc, list); }
            catch (Exception ex) { Program.Log($"departures: {originIcao}: could not read the reply: {ex.Message}"); break; }
            if (list.Count == before) break;
        }
        Program.Log($"departures: {list.Count} flight(s) from {originIcao} within 90 minutes of {schedOutUtc:HH:mm}Z");
        return list;
    }

    private const string Ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/128 Safari/537.36";

    /// <summary>
    /// The page's JSON, or null (logged). Measured 2026-09-12: the same
    /// request answered 200 to curl and 403 to .NET's HttpClient with the same
    /// headers - the site fingerprints the client below the headers. Windows
    /// ships curl.exe (System32), so that is asked first; HttpClient is the
    /// fallback for a machine without it.
    /// </summary>
    private static async Task<string> GetAsync(string url, string originIcao, int page)
    {
        var curl = System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "curl.exe");
        if (File.Exists(curl))
        {
            try
            {
                var psi = new System.Diagnostics.ProcessStartInfo
                {
                    FileName = curl,
                    UseShellExecute = false, CreateNoWindow = true,
                    RedirectStandardOutput = true, RedirectStandardError = true,
                    StandardOutputEncoding = System.Text.Encoding.UTF8
                };
                psi.ArgumentList.Add("-sg"); psi.ArgumentList.Add("-m"); psi.ArgumentList.Add("25");
                psi.ArgumentList.Add("-A"); psi.ArgumentList.Add(Ua);
                psi.ArgumentList.Add("-w"); psi.ArgumentList.Add("\n%{http_code}");
                psi.ArgumentList.Add(url);
                using var p = System.Diagnostics.Process.Start(psi);
                var outText = await p.StandardOutput.ReadToEndAsync();
                await p.WaitForExitAsync();
                int nl = outText.LastIndexOf('\n');
                var code = nl >= 0 ? outText.Substring(nl + 1).Trim() : "";
                var body = nl >= 0 ? outText.Substring(0, nl) : outText;
                if (code == "200" && body.Length > 0) return body;
                Program.Log($"departures: {originIcao} page {page}: curl HTTP {(code == "" ? "?" : code)}");
                return null;
            }
            catch (Exception ex) { Program.Log($"departures: {originIcao}: curl failed: {ex.Message}"); }
        }
        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Get, url);
            req.Headers.UserAgent.ParseAdd(Ua);
            using var res = await Http.SendAsync(req);
            if (!res.IsSuccessStatusCode) { Program.Log($"departures: {originIcao} page {page}: HTTP {(int)res.StatusCode}"); return null; }
            return await res.Content.ReadAsStringAsync();
        }
        catch (Exception ex) { Program.Log($"departures: {originIcao}: {ex.Message}"); return null; }
    }

    private static void Parse(string json, DateTime around, List<Flight> into)
    {
        using var doc = JsonDocument.Parse(json);
        if (!Walk(doc.RootElement, out var data, "result", "response", "airport", "pluginData", "schedule", "departures", "data")) return;
        foreach (var item in data.EnumerateArray())
        {
            if (!item.TryGetProperty("flight", out var f)) continue;
            string number = Walk(f, out var num, "identification", "number", "default") ? num.GetString() : null;
            string airline = Walk(f, out var al, "airline", "name") ? al.GetString() : null;
            if (string.IsNullOrWhiteSpace(number) || string.IsNullOrWhiteSpace(airline)) continue;
            var m = Regex.Match(number, @"^[A-Z0-9]{2,3}?(\d{1,4})$");
            if (!m.Success) continue;
            long dep = Walk(f, out var t, "time", "scheduled", "departure") && t.ValueKind == JsonValueKind.Number ? t.GetInt64() : 0;
            if (dep == 0) continue;
            var when = DateTimeOffset.FromUnixTimeSeconds(dep).UtcDateTime;
            if (Math.Abs((when - around).TotalMinutes) > 90) continue;
            string city = null;
            if (Walk(f, out var c, "airport", "destination", "position", "region", "city") && c.ValueKind == JsonValueKind.String) city = c.GetString();
            if (string.IsNullOrWhiteSpace(city) && Walk(f, out var nm, "airport", "destination", "name") && nm.ValueKind == JsonValueKind.String) city = CityFromName(nm.GetString());
            string gate = Walk(f, out var g, "airport", "origin", "info", "gate") && g.ValueKind == JsonValueKind.String ? g.GetString() : null;
            // livery notes ride along in the airline name: "Frontier (Brazos the Hawk)"
            airline = Regex.Replace(airline, @"\s*\(.*?\)", "").Trim();
            into.Add(new Flight { Airline = airline, Number = m.Groups[1].Value, City = string.IsNullOrWhiteSpace(city) ? null : city, Gate = string.IsNullOrWhiteSpace(gate) ? null : gate, SchedUtc = when });
        }
    }

    /// <summary>"Atlanta Hartsfield-Jackson International Airport" becomes "Atlanta"; a name without a known suffix is used whole.</summary>
    private static string CityFromName(string name)
    {
        if (string.IsNullOrWhiteSpace(name)) return null;
        var s = name;
        foreach (var cut in new[] { " International", " Intl", " Regional", " Municipal", " National", " Metropolitan", " Airport", " Field" })
        {
            int at = s.IndexOf(cut, StringComparison.OrdinalIgnoreCase);
            if (at > 0) s = s.Substring(0, at);
        }
        // "Atlanta Hartsfield-Jackson" -> "Atlanta": the city is the first word
        // when a person's name follows; keep two words for "Salt Lake", "Kansas City", "Los Angeles".
        var words = s.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (words.Length >= 2 && (words[0] == "Salt" || words[0] == "Kansas" || words[0] == "Los" || words[0] == "Las" || words[0] == "San" || words[0] == "New" || words[0] == "Fort" || words[0] == "St." || words[0] == "Saint" || words[0] == "Oklahoma" || words[0] == "Colorado" || words[0] == "Grand" || words[0] == "Sioux" || words[0] == "Des" || words[0] == "Cedar" || words[0] == "Long" || words[0] == "Palm" || words[0] == "Little" || words[0] == "Rapid"))
            return words[0] + " " + words[1].TrimEnd(',', '-');
        return words.Length > 0 ? words[0].TrimEnd(',', '-') : s;
    }

    private static bool Walk(JsonElement from, out JsonElement found, params string[] path)
    {
        found = from;
        foreach (var p in path)
        {
            if (found.ValueKind != JsonValueKind.Object || !found.TryGetProperty(p, out var next)) return false;
            found = next;
        }
        return true;
    }
}
