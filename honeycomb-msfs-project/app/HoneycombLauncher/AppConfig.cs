using System.Text.Json;
using System.Text.Json.Serialization;

namespace HoneycombLauncher;

/// <summary>
/// The program's record of this machine. Read on every start, written only by
/// deliberate action. Schema version is checked, never assumed.
/// </summary>
internal sealed class AppConfig
{
    public const int CurrentSchema = 1;

    [JsonPropertyName("schemaVersion")] public int SchemaVersion { get; set; } = CurrentSchema;
    [JsonPropertyName("generatedUtc")] public string GeneratedUtc { get; set; } = "";
    [JsonPropertyName("machine")] public string Machine { get; set; } = "";
    [JsonPropertyName("simBriefPilotId")] public string SimBriefPilotId { get; set; } = "";
    [JsonPropertyName("lastAircraftId")] public string LastAircraftId { get; set; } = "";
    [JsonPropertyName("capsSetForLayout")] public string CapsSetForLayout { get; set; } = "";
    [JsonPropertyName("aircraftUse")] public Dictionary<string, int> AircraftUse { get; set; } = new();
    [JsonPropertyName("fsuipcRoot")] public string FsuipcRoot { get; set; } = "";

    // Set when a person has confirmed, in MSFS's controls options, that the
    // Bravo is on an EMPTY profile so it does not fight FSUIPC for the levers.
    // The sim keeps that setting in a cloud-synced binary container we cannot
    // read, so this is a record of someone having looked, not a verification.
    // Written by tools/Confirm-SimBravoProfile.ps1 (or a future setup step);
    // declared here so Save() round-trips it instead of dropping it.
    [JsonPropertyName("msfsBravoProfileConfirmedUtc")] public string MsfsBravoProfileConfirmedUtc { get; set; } = "";
    [JsonPropertyName("msfsBravoProfileConfirmedBy")]  public string MsfsBravoProfileConfirmedBy  { get; set; } = "";
    // The MSFS controller profile the Bravo must be on - "Claude Empty", the
    // one created for this program. Named so the gate can say which to pick.
    [JsonPropertyName("msfsBravoProfileName")]         public string MsfsBravoProfileName         { get; set; } = "";

    // AI traffic. The MODE is which engine feeds traffic: BATC, FSLTL or MSFS
    // (Mark, 2026-09-11). BATC and FSLTL need MSFS's Traffic Type set to
    // "Off" in Options > General > Online; MSFS needs "Real-Time Online".
    // That setting lives only in Microsoft's cloud profile (measured
    // 2026-09-11: three saves byte-compared, no trace on disk), so what is
    // recorded here is a person's word - who said it was set, to what, when.
    [JsonPropertyName("trafficMode")]            public string TrafficMode            { get; set; } = "";
    [JsonPropertyName("trafficTypeRecorded")]    public string TrafficTypeRecorded    { get; set; } = "";
    [JsonPropertyName("trafficTypeRecordedBy")]  public string TrafficTypeRecordedBy  { get; set; } = "";
    [JsonPropertyName("trafficTypeRecordedUtc")] public string TrafficTypeRecordedUtc { get; set; } = "";
    // The printout window's text size (dot pitch in px), from its A- / A+ buttons.
    [JsonPropertyName("printoutPitch")]          public float  PrintoutPitch          { get; set; } = 2.6f;
    // Where the printout window was last left by hand (moved or resized):
    // screen x, y and client width, height. Every sheet starts there.
    [JsonPropertyName("printoutBounds")]         public int[]  PrintoutBounds         { get; set; } = null;
    // Where the launcher window itself was last left (x, y, width, height).
    // It used to open centred on the primary monitor every time - which is
    // the monitor the simulator fills, so a restored launcher came up behind
    // the sim and could not be found (Mark, 2026-09-11).
    [JsonPropertyName("launcherBounds")]         public int[]  LauncherBounds         { get; set; } = null;
    // The printout's printer options (Mark, 2026-09-12), from its right-click menu.
    [JsonPropertyName("printoutInk")]            public int    PrintoutInk            { get; set; } = 1;      // 0 light .. 3 black
    [JsonPropertyName("printoutBidirectional")]  public bool   PrintoutBidirectional  { get; set; } = false;
    [JsonPropertyName("printoutMixedCase")]      public bool   PrintoutMixedCase      { get; set; } = false;
    [JsonPropertyName("printoutSpeed")]          public int    PrintoutSpeed          { get; set; } = 0;      // 0 normal, 1 fast, 2 fastest
    [JsonPropertyName("printoutPrinter")]        public int    PrintoutPrinter        { get; set; } = 0;      // 0 dot matrix, 1 LaserWriter
    [JsonPropertyName("printoutFace")]           public string PrintoutFace           { get; set; } = "Helvetica";   // the LaserWriter's face
    [JsonPropertyName("printoutAmbience")]       public bool   PrintoutAmbience       { get; set; } = true;   // the airport under the printer
    // Where BeyondATC was found (its exe), once found; empty until then. The
    // FSLTL injector needs no record - it lives in the Community folder.
    [JsonPropertyName("batcPath")]               public string BatcPath               { get; set; } = "";

    /// <summary>
    /// The two Graphics > Traffic levels the chosen mode needs (measured
    /// 2026-09-12 with Mark at the page: Off writes -1, Ultra writes 3).
    /// BATC and FSLTL: both Off, so the sim injects nothing of its own.
    /// MSFS: both Ultra, Mark's choice for Asobo's engine. Null when no mode.
    /// </summary>
    public static (int aircraft, int parked)? GraphicsRequiredFor(string mode) => mode switch
    {
        "BATC" or "FSLTL" => (-1, -1),
        "MSFS" => (3, 3),
        _ => null
    };

    /// <summary>What MSFS's Traffic Type must be for the chosen mode; null when no mode is chosen.</summary>
    public static string TrafficTypeRequiredFor(string mode) => mode switch
    {
        "BATC" or "FSLTL" => "Off",
        "MSFS" => "Real-Time Online",
        _ => null
    };

    public static string Path { get; } = System.IO.Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "HoneycombAssignment", "config.json");

    public static AppConfig Load(out string problem)
    {
        problem = null;
        if (!File.Exists(Path)) return null;                 // missing is not a fault
        try
        {
            var cfg = JsonSerializer.Deserialize<AppConfig>(File.ReadAllText(Path));
            if (cfg == null) { problem = "the settings file is empty"; return null; }
            if (cfg.SchemaVersion != CurrentSchema)
            {
                problem = $"the settings file was written by a different version " +
                          $"(found {cfg.SchemaVersion}, expected {CurrentSchema})";
                return null;
            }
            return cfg;
        }
        catch (Exception ex)
        {
            // Never overwrite an unreadable file. It may still hold a working
            // setup, and replacing it destroys the only copy.
            problem = "the settings file cannot be read: " + ex.Message;
            return null;
        }
    }

    public void Save()
    {
        GeneratedUtc = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ");
        Machine = Environment.MachineName;
        var dir = System.IO.Path.GetDirectoryName(Path);
        Directory.CreateDirectory(dir);

        // Keep one backup. Cheap, and the difference between an annoyance and
        // a lost setup.
        if (File.Exists(Path))
        {
            try { File.Copy(Path, Path + ".bak", true); } catch { }
        }
        File.WriteAllText(Path, JsonSerializer.Serialize(this,
            new JsonSerializerOptions { WriteIndented = true }));
    }
}
