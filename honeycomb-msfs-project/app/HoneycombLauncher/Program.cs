using System.Text;

namespace HoneycombLauncher;

internal static class Program
{
    /// <summary>
    /// Beside the config, so a failure that happens before any window appears
    /// still leaves something to read.
    /// </summary>
    public static string LogPath { get; } = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "HoneycombAssignment", "launcher.log");

    public static void Log(string message)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(LogPath));
            File.AppendAllText(LogPath,
                $"{DateTime.Now:yyyy-MM-dd HH:mm:ss}  {message}{Environment.NewLine}",
                Encoding.UTF8);
        }
        catch { /* logging must never be the thing that breaks it */ }
    }

    public static void LogError(string where, Exception ex)
    {
        Log($"ERROR in {where}: {ex.GetType().FullName}: {ex.Message}");
        Log(ex.ToString());
    }

    [STAThread]
    private static void Main()
    {
        // An exception on a background task or a UI callback was killing the
        // process with nothing shown and nothing written down. Catch everything
        // at the edges, write it, and say so rather than vanishing.
        AppDomain.CurrentDomain.UnhandledException += (_, e) =>
        {
            if (e.ExceptionObject is Exception ex) LogError("AppDomain", ex);
            Show("Something went wrong and the program has to close.", ex: e.ExceptionObject as Exception);
        };
        Application.ThreadException += (_, e) =>
        {
            LogError("UI thread", e.Exception);
            Show("Something went wrong.", ex: e.Exception);
        };
        TaskScheduler.UnobservedTaskException += (_, e) =>
        {
            LogError("background task", e.Exception);
            e.SetObserved();
        };

        Log("---- starting ----");
        try
        {
            ApplicationConfiguration.Initialize();
            Application.Run(new MainForm());
            Log("---- closed normally ----");
        }
        catch (Exception ex)
        {
            LogError("Main", ex);
            Show("The program could not start.", ex: ex);
        }
    }

    private static void Show(string headline, Exception ex)
    {
        var detail = ex is null ? "" : $"\n\n{ex.GetType().Name}: {ex.Message}";
        try
        {
            MessageBox.Show(
                $"{headline}{detail}\n\nDetails were written to:\n{LogPath}",
                "Honeycomb Preflight", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
        catch { }
    }
}
