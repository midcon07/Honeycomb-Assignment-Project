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
