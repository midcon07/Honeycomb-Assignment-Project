using System.Drawing;
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
    private static void Main(string[] args)
    {
        // "--traffic-sheet [mode]" prints the reminder sheet on its own, with
        // sample values, and records nothing: for seeing and hearing it
        // without a simulator, and for testing it.
        if (args.Length > 0 && args[0] == "--traffic-sheet")
        {
            ApplicationConfiguration.Initialize();
            var mode = args.Length > 1 ? args[1] : "BATC";
            var required = AppConfig.TrafficTypeRequiredFor(mode) ?? "Off";
            // The whole window, as in the launcher: print, anchor, minimise to
            // the square, restore, resize, text size. Close ends the demo.
            var ctx = new ApplicationContext();
            // Sample facts, except the graphics levels, which are read from the
            // real settings file so the sheet can be watched confirming them.
            var need = AppConfig.GraphicsRequiredFor(mode) ?? (-1, -1);
            var facts = new TrafficReminderForm.Facts
            {
                Mode = mode, RequiredType = required, RecordedType = "Real-Time Online", RecordedBy = "midcon07", RecordedUtc = "2026-09-07T04:43:00Z", Who = Environment.UserName,
                RequiredAircraft = need.aircraft, RequiredParked = need.parked,
                Sim = SimSettings.ReadTrafficGraphics(out var gfxProblem), SimProblem = gfxProblem ?? ""
            };
            var sheet = new TrafficReminderForm(facts);
            // The demo watches the file too, so a change made in the sim prints.
            var seen = facts.Sim?.WrittenUtc ?? DateTime.MinValue;
            var clock = new System.Windows.Forms.Timer { Interval = 2000 };
            clock.Tick += (s_, e_) =>
            {
                var g = SimSettings.ReadTrafficGraphics(out string _);
                if (g == null || g.WrittenUtc == seen) return;
                seen = g.WrittenUtc; Log("traffic sheet demo: sim settings changed"); sheet.GraphicsNow(g);
            };
            clock.Start();
            sheet.Text = "Honeycomb Preflight - printout (demo)";   // never the same title as a real sheet
            PrintoutIconForm icon = null;
            sheet.PinChanged += p => Log("traffic sheet demo: " + (p ? "anchored" : "loose"));
            sheet.PitchChanged += p => Log("traffic sheet demo: pitch " + p);
            sheet.Finished += o => Log("traffic sheet demo: " + o);
            sheet.Minimised += () =>
            {
                Log("traffic sheet demo: minimised");
                if (icon == null || icon.IsDisposed) { icon = new PrintoutIconForm(sheet.RestingLocation); icon.Restore += () => sheet.Restore(); }
                icon.Location = new Point(sheet.RestingLocation.X + sheet.Width - icon.Width, sheet.RestingLocation.Y);
                icon.Show();
            };
            sheet.Restored += () => { Log("traffic sheet demo: restored"); icon?.Hide(); };
            ctx.MainForm = sheet;
            sheet.Show();
            Application.Run(ctx);
            return;


        }

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
