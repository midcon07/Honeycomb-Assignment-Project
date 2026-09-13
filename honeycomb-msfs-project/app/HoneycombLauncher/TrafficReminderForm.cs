using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace HoneycombLauncher;

/// <summary>
/// The printout: a sheet of green-bar tractor-feed paper, always on top, that
/// prints - one character at a time, with the printer's sounds - what a person
/// has to do in the simulator for the chosen traffic mode, and what the program
/// has found out for itself. Mark, 2026-09-11: "I want to push more information
/// through this during the flight" - so this is a feed: lines are appended to
/// the foot of the sheet as things happen, never rewritten.
///
/// Three parts print for a mode. 1. The two Graphics > Traffic levels, read
/// from the sim's settings file: the sheet strikes its own "must be" lines and
/// prints a confirmation the moment the file agrees (measured, not anyone's
/// word). 2. The Traffic Type on the Online page, which lives where no program
/// can read it: a person clicks DONE and the sheet prints who and when, and
/// says in print that it is their word. 3. The traffic engine (BeyondATC, the
/// FSLTL injector): once the graphics are right, a line offers to start it,
/// and the sheet confirms from the process list when it is up.
///
/// One printout window lives for the session. It opens pinned (on top), and
/// stays open. An anchor lamp top-left: green = on top of everything, red = an
/// ordinary window; dropping it after a drag anchors it. Printed chrome
/// top-right: A- A+ (text size), minimise (winds up into a small square that
/// brings it back), maximise, close (which asks first, in print). Resizable by
/// its edges - the text reflows to the width, wrapped at spaces. Right-click
/// the paper for the printer options (Mark, 2026-09-12): ink weight, printing
/// in both directions, upper and lower case, speed.
/// </summary>
internal sealed class TrafficReminderForm : Form
{
    public enum Outcome { None, Done, NotNow, CloseYes, CloseNo, StartEngine }
    public Outcome Result { get; private set; } = Outcome.None;
    /// <summary>A choice was made (DONE or NOT NOW). The sheet stays up.</summary>
    public event Action<Outcome> Finished;
    /// <summary>Minimised to the square / brought back.</summary>
    public event Action Minimised, Restored;
    public event Action<bool> PinChanged;
    public event Action<float> PitchChanged;
    /// <summary>The person asked, on the sheet, for the traffic engine to be started.</summary>
    public event Action EngineStartRequested;
    /// <summary>A printer option was changed from the right-click menu.</summary>
    public event Action<Options> OptionsChanged;
    /// <summary>Raised when the person has moved or resized the sheet, so the place can be remembered.</summary>
    public event Action<Rectangle> BoundsSettled;
    public bool IsMinimised { get; private set; }
    /// <summary>Anchored: kept on top of everything, the simulator included.</summary>
    public bool Pinned { get; private set; }
    /// <summary>True until every part of the sheet is right: something is still wanted of the person.</summary>
    public bool Unresolved => !_resolved;

    /// <summary>Everything the sheet prints from: the mode, what it needs, what is recorded, what the sim's file says, the engine.</summary>
    public sealed class Facts
    {
        public string Mode = "", RequiredType = "", RecordedType = "", RecordedBy = "", RecordedUtc = "", Who = "";
        public int RequiredAircraft, RequiredParked;          // Graphics > Traffic levels the mode needs
        public SimSettings.TrafficGraphics Sim;               // what the sim's settings file holds now; null if unreadable
        public string SimProblem = "";                        // why, when Sim is null
        public string EngineName;                             // BeyondATC / FSLTL injector; null when the mode is MSFS
        public bool EngineFound;                              // its exe was found, so the sheet can offer to start it
        public bool EngineRunning;                            // its process is up now
        public string[] ForeignEnginesRunning = Array.Empty<string>();   // engines running that the mode does not want
    }

    /// <summary>The printer options, from the right-click menu; saved by the launcher.</summary>
    public sealed class Options
    {
        public int Ink = 1;               // 0 light, 1 normal, 2 dark, 3 black
        public bool Bidirectional;        // the head prints alternate lines right to left, as a real one did
        public bool MixedCase;            // upper and lower case; off = the all-capitals original
        public int Speed;                 // 0 normal, 1 fast, 2 fastest
        public int Printer;               // 0 the dot matrix, 1 the LaserWriter (Mark, 2026-09-12)
        public string Face = "Helvetica"; // the LaserWriter's face, by its PostScript name
        public Options Clone() => (Options)MemberwiseClone();
    }
    private bool IsLaser => Opts.Printer == 1;

    /// <summary>
    /// The LaserWriter's resident faces (the LaserWriter Plus set, less Symbol
    /// and Zapf), each with the Windows face that stands in for it. A face
    /// whose stand-in is not installed is left out of the menu.
    /// </summary>
    public static readonly (string Name, string Windows)[] Faces =
    {
        ("Helvetica", "Arial"), ("Times", "Times New Roman"), ("Courier", "Courier New"), ("Palatino", "Palatino Linotype"),
        ("Bookman", "Bookman Old Style"), ("New Century Schoolbook", "Century Schoolbook"), ("Avant Garde", "Century Gothic"), ("Helvetica Narrow", "Arial Narrow")
    };
    public static bool FaceInstalled(string windows)
    {
        try { using var ff = new FontFamily(windows); return ff.IsStyleAvailable(FontStyle.Regular); } catch { return false; }
    }
    private Font _laserFont; private float _laserFontPitch = -1; private string _laserFontFace = "";
    private Font LaserFont
    {
        get
        {
            if (_laserFont != null && _laserFontPitch == _pitch && _laserFontFace == Opts.Face) return _laserFont;
            _laserFont?.Dispose();
            string win = "Arial";
            foreach (var (name, w) in Faces) if (name == Opts.Face && FaceInstalled(w)) { win = w; break; }
            _laserFont = new Font(win, _pitch * 10f, FontStyle.Regular, GraphicsUnit.Pixel);
            _laserFontPitch = _pitch; _laserFontFace = Opts.Face;
            return _laserFont;
        }
    }
    private static readonly StringFormat Typo = MakeTypo();
    private static StringFormat MakeTypo() { var sf = (StringFormat)StringFormat.GenericTypographic.Clone(); sf.FormatFlags |= StringFormatFlags.MeasureTrailingSpaces; return sf; }
    private float MeasureW(Graphics g, string text) => text.Length == 0 ? 0 : g.MeasureString(text, LaserFont, PointF.Empty, Typo).Width;
    // The page coming out: rows revealed so far during a LaserWriter print.
    private float _reveal = float.MaxValue;
    private System.Windows.Forms.Timer _laserTimer;
    private static readonly double[][] LaserPhases = { new[] { 0.9, 1.1, 2.2, 0.7 }, new[] { 0.4, 0.6, 1.2, 0.4 }, new[] { 0.1, 0.3, 0.6, 0.2 } };
    private double[] LaserPhase => LaserPhases[Math.Max(0, Math.Min(2, Opts.Speed))];
    public Options Opts { get; private set; }
    private static readonly double[] SpeedMs = { 17, 9, 4 };
    private static readonly Color[] InkByWeight =
    {
        Color.FromArgb(28, 34, 66), Color.FromArgb(28, 34, 66), Color.FromArgb(18, 22, 48), Color.FromArgb(6, 8, 22)
    };
    private static readonly int[] TonerAlpha = { 165, 215, 240, 255 };
    private Color Ink => IsLaser ? Color.FromArgb(TonerAlpha[Math.Max(0, Math.Min(3, Opts.Ink))], 18, 18, 18) : InkByWeight[Math.Max(0, Math.Min(3, Opts.Ink))];
    private double CharMs => SpeedMs[Math.Max(0, Math.Min(2, Opts.Speed))];

    // ---- paper geometry ------------------------------------------------------
    public static readonly float[] Pitches = { 2.0f, 2.3f, 2.6f, 3.0f, 3.4f, 3.9f, 4.4f };
    private float _pitch;                             // dot pitch in px: the text size
    private float CharW => _pitch * 6;                // 5 dots + 1 gap
    private float LineH => IsLaser ? _pitch * 12.5f : _pitch * 10;   // 7 dots + 3 gap; the LaserWriter's leading
    private const int StripW = 42;                    // sprocket strip each side
    private const int TopMargin = 38, BottomMargin = 26, Edge = 7;
    private const int DefaultCols = 46;
    private int _cols = DefaultCols;

    private static readonly Color DmPaper = Color.FromArgb(244, 241, 228);
    private static readonly Color LaserPaper = Color.FromArgb(252, 252, 250);
    private Color Paper => IsLaser ? LaserPaper : DmPaper;
    private static readonly Color Bar = Color.FromArgb(214, 232, 208);
    private static readonly Color Perf = Color.FromArgb(200, 196, 180);

    // ---- what is printed -------------------------------------------------------
    // Source lines are kept in sentence case; Disp() gives what is printed.
    private sealed class Src { public string Text = ""; public Outcome Click = Outcome.None; public bool Struck; public string Right; }   // Right: printed at the right edge (the header's date)
    private sealed class Row { public int Src; public string Text = ""; public int Start; }   // Start = index of this row's first char within the source text
    private readonly List<Src> _src = new();
    private readonly List<Row> _rows = new();
    private Bitmap _sheet;
    private readonly Random _ribbon = new(42);
    private DotMatrix.Sounds _sounds;
    private readonly System.Windows.Forms.Timer _clock = new();
    // Print head: how many source lines are fully printed, and how many characters of the current one.
    private int _headSrc, _headChar;
    private bool _printing, _busy;
    private int _lineFeedPause;
    private readonly string _who;
    private bool _resolved;

    // The graphics lines that are struck through once the sim's file agrees.
    private readonly List<int> _gfxLines = new();
    private readonly int _reqAircraft, _reqParked;
    private bool _gfxOk;
    // The engine: its START line, and whether it is up.
    private readonly string _engineName;
    private readonly bool _engineFound;
    private bool _engineRunning, _engineStartAsked, _engineLineDue;

    public TrafficReminderForm(Facts f, Options opts = null, bool pinned = true, float pitch = 2.6f, Rectangle? remembered = null)
    {
        Opts = (opts ?? new Options()).Clone();
        string mode = f.Mode ?? "", required = f.RequiredType ?? "", recorded = f.RecordedType ?? "", recordedBy = f.RecordedBy ?? "", recordedUtc = f.RecordedUtc ?? "";
        Pinned = pinned;
        _pitch = pitch;
        _reqAircraft = f.RequiredAircraft; _reqParked = f.RequiredParked;
        _gfxOk = f.Sim != null && f.Sim.Matches(_reqAircraft, _reqParked);
        _engineName = f.EngineName; _engineFound = f.EngineFound; _engineRunning = f.EngineRunning;
        var typeResolved = !string.IsNullOrWhiteSpace(recorded) && string.Equals(recorded, required, StringComparison.OrdinalIgnoreCase);
        var engineOk = _engineName == null ? f.ForeignEnginesRunning.Length == 0 : _engineRunning;
        _resolved = typeResolved && _gfxOk && engineOk;
        _who = string.IsNullOrWhiteSpace(f.Who) ? Environment.UserName : f.Who;

        FormBorderStyle = FormBorderStyle.None;
        TopMost = Pinned;
        ShowInTaskbar = true;
        StartPosition = FormStartPosition.Manual;
        Text = "Honeycomb Preflight - printout";
        DoubleBuffered = true;
        BackColor = Color.FromArgb(24, 24, 24);
        MinimumSize = new Size(StripW * 2 + 24 + (int)(2.0f * 6 * 24), 160);

        var mono = mode switch
        {
            "BATC"  => "BATC - BeyondATC drives the traffic",
            "FSLTL" => "FSLTL - the injector drives the traffic",
            "MSFS"  => "MSFS - Asobo's own traffic engine",
            _       => mode
        };
        string when = "";
        if (!string.IsNullOrWhiteSpace(recordedUtc) && DateTime.TryParse(recordedUtc, null, System.Globalization.DateTimeStyles.AdjustToUniversal | System.Globalization.DateTimeStyles.AssumeUniversal, out var dt))
            when = dt.ToLocalTime().ToString("dd MMM");

        Add("Honeycomb Preflight", right: DateTime.Now.ToString("dd MMM yy HH:mm"));
        Add(_resolved ? "*** Traffic - all as it should be ***" : "*** Action required in the simulator ***");
        Add("");
        Add("Traffic mode: " + mono);
        Add("");

        // 1. The graphics levels: read from the sim's settings file, which the
        //    sim rewrites the moment a setting changes, so this part confirms
        //    itself (measured 2026-09-12).
        string wa = Word(_reqAircraft), wp = Word(_reqParked);
        Add("1. Options > General > Graphics");
        if (f.Sim == null)
        {
            Add("   Could not read the sim's settings file:");
            Add("   " + (f.SimProblem ?? ""));
            Add("   Aircraft Traffic must be: " + wa);
            Add("   Parked Aircraft must be:  " + wp);
        }
        else if (_gfxOk)
        {
            Add("   Aircraft Traffic: " + wa + "   Parked: " + wp);
            Add("   Right - read from the sim's settings file.");
        }
        else
        {
            _gfxLines.Add(_src.Count); Add("   Aircraft Traffic must be: " + wa + " (now " + Word(f.Sim.Aircraft) + ")");
            _gfxLines.Add(_src.Count); Add("   Parked Aircraft must be:  " + wp + " (now " + Word(f.Sim.Parked) + ")");
            Add("   Save, then back. This sheet reads the sim's");
            Add("   settings file and confirms it by itself.");
        }
        if (_reqAircraft == -1)
        {
            // Turning the two levels off takes the page's overall preset off
            // its word (measured 2026-09-12: Ultra -> Custom). Said here so
            // nobody "fixes" it back (Mark's item 0, 2026-09-12).
            Add("   Global Rendering Quality will say Custom -");
            Add("   that is right; leave it.");
        }
        Add("");

        // 2. The Traffic Type: in the cloud profile, so a person's word.
        Add("2. Options > General > Online");
        Add("   Traffic Type must be: " + required);
        if (string.IsNullOrWhiteSpace(recorded)) Add("   Last recorded as: never recorded");
        else
        {
            Add("   Last recorded as: " + recorded);
            if (when != "") Add("                     (" + when + (string.IsNullOrWhiteSpace(recordedBy) ? "" : " by " + recordedBy) + ")");
        }
        Add(typeResolved ? "   As recorded - nothing to change." : "   Save, then back.");
        Add("   (The sim keeps this one where no program");
        Add("    can check it, so your word is the record.)");
        Add("");

        // 3. The engine that feeds the traffic (Mark's item 6, 2026-09-12).
        if (_engineName != null)
        {
            Add("3. Traffic engine: " + _engineName);
            if (_engineRunning) Add("   Running - its process was seen " + DateTime.Now.ToString("HH:mm") + ".");
            else
            {
                Add("   Not running.");
                if (!_engineFound)
                {
                    Add("   Not found on this computer - start it");
                    Add("   yourself. This sheet confirms it by itself.");
                }
                else if (_gfxOk) Add("[ ] Start " + _engineName + " now", Outcome.StartEngine);
                else { _engineLineDue = true; Add("   (Offered here once the graphics are right.)"); }
            }
        }
        else
        {
            Add("3. Traffic engine: the simulator's own");
            Add("   Nothing to start.");
            foreach (var e in f.ForeignEnginesRunning)
            {
                Add("   !! " + e + " is running - close it, or");
                Add("   the traffic doubles.");
            }
        }
        Add("");

        if (typeResolved)
        {
            Add("[ ] Noted", Outcome.NotNow);
        }
        else
        {
            Add("[ ] Done - Traffic Type is now " + required, Outcome.Done);
            Add("[ ] Not now - remind me next time", Outcome.NotNow);
        }
        Add("");

        int w = StripW * 2 + (int)Math.Ceiling(CharW * DefaultCols) + 25;
        int h = TopMargin + (int)(LineH * (_src.Count + 2)) + BottomMargin;
        ClientSize = new Size(w, h);
        var scr = Screen.PrimaryScreen.WorkingArea;
        Location = new Point(scr.Right - w - 36, scr.Top + 36);
        // Where it was last left, moved or resized by hand, wins - unless
        // that place is off every screen now (a monitor unplugged).
        if (remembered is Rectangle rb && rb.Width >= MinimumSize.Width && rb.Height >= MinimumSize.Height)
        {
            var onScreen = false;
            foreach (var sc in Screen.AllScreens) if (sc.WorkingArea.IntersectsWith(rb)) { onScreen = true; break; }
            if (onScreen) { Location = rb.Location; ClientSize = rb.Size; }
        }

        _sounds = new DotMatrix.Sounds(CharMs, LaserPhase);
        _clock.Interval = (int)CharMs;
        _clock.Tick += (_, __) => Step();
        BuildMenu();
        Relayout();
    }

    private static string Word(int level) => SimSettings.LevelWord(level) switch
    {
        "OFF" => "Off",
        "ULTRA" => "Ultra",
        var s => s.ToLowerInvariant()
    };

    private void Add(string text, Outcome click = Outcome.None, string right = null) => _src.Add(new Src { Text = text, Click = click, Right = right });

    /// <summary>What a source line looks like on the paper: the original is all capitals; mixed case is the option.</summary>
    private string Disp(string text) => Opts.MixedCase ? text : text.ToUpperInvariant();

    // ---- a real, resizable window with no frame ----------------------------------
    private const int WS_THICKFRAME = 0x00040000, WM_NCCALCSIZE = 0x0083, WM_NCHITTEST = 0x0084, WM_EXITSIZEMOVE = 0x0232, WM_NCLBUTTONDOWN = 0x00A1;
    private const int HTCLIENT = 1, HTCAPTION = 2, HTLEFT = 10, HTRIGHT = 11, HTTOP = 12, HTTOPLEFT = 13, HTTOPRIGHT = 14, HTBOTTOM = 15, HTBOTTOMLEFT = 16, HTBOTTOMRIGHT = 17;
    [DllImport("user32.dll")] private static extern bool ReleaseCapture();
    [DllImport("user32.dll")] private static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);

    protected override CreateParams CreateParams
    {
        get { var cp = base.CreateParams; cp.Style |= WS_THICKFRAME; return cp; }
    }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == WM_NCCALCSIZE && m.WParam != IntPtr.Zero) { m.Result = IntPtr.Zero; return; }   // no frame drawn
        if (m.Msg == WM_NCHITTEST)
        {
            var p = PointToClient(new Point(m.LParam.ToInt32() & 0xFFFF, (m.LParam.ToInt32() >> 16) & 0xFFFF));
            bool l = p.X < Edge, r = p.X >= Width - Edge, t = p.Y < Edge, b = p.Y >= Height - Edge;
            int ht = HTCLIENT;
            if (!_maximised)
            {
                if (t && l) ht = HTTOPLEFT; else if (t && r) ht = HTTOPRIGHT; else if (b && l) ht = HTBOTTOMLEFT; else if (b && r) ht = HTBOTTOMRIGHT;
                else if (l) ht = HTLEFT; else if (r) ht = HTRIGHT; else if (t) ht = HTTOP; else if (b) ht = HTBOTTOM;
            }
            m.Result = (IntPtr)ht;
            return;
        }
        base.WndProc(ref m);
        if (m.Msg == WM_EXITSIZEMOVE && !_busy && !IsMinimised)
        {
            // Dropped or resized by hand: it stays there, on top, and the
            // place is remembered for every sheet after this (Mark, 2026-09-11).
            if (!Pinned) SetPinned(true);
            if (!_maximised) BoundsSettled?.Invoke(new Rectangle(Location, ClientSize));
        }
    }

    protected override void OnResize(EventArgs e)
    {
        base.OnResize(e);
        if (_src.Count > 0 && ClientSize.Width > 0 && ClientSize.Height > 0) Relayout();
    }

    // ---- layout: wrap the source lines to the paper's width ------------------------
    private void Relayout()
    {
        _cols = Math.Max(20, (int)Math.Floor((ClientSize.Width - 2 * StripW - 24) / CharW + 0.01f));
        _rows.Clear();
        if (IsLaser) { RelayoutLaser(); return; }
        for (int s = 0; s < _src.Count; s++)
        {
            var src = _src[s];
            var text = Disp(src.Right == null ? src.Text : src.Text.PadRight(Math.Max(0, DefaultCols - src.Right.Length)) + src.Right);
            int start = 0;
            while (true)
            {
                if (text.Length - start <= _cols) { _rows.Add(new Row { Src = s, Text = text.Substring(start), Start = start }); break; }
                int cut = text.LastIndexOf(' ', start + _cols - 1, _cols);
                if (cut <= start) cut = start + _cols;
                _rows.Add(new Row { Src = s, Text = text.Substring(start, cut - start), Start = start });
                start = cut; while (start < text.Length && text[start] == ' ') start++;
            }
        }
        _sheet?.Dispose();
        _sheet = new Bitmap(Math.Max(1, ClientSize.Width), Math.Max(1, ClientSize.Height));
        RedrawAll();
        Invalidate();
    }

    /// <summary>The LaserWriter's page: proportional text, wrapped at spaces to the page's width.</summary>
    private void RelayoutLaser()
    {
        using var g = Graphics.FromHwnd(IntPtr.Zero);
        float avail = ClientSize.Width - 2 * StripW - 24;
        for (int s = 0; s < _src.Count; s++)
        {
            var text = Disp(_src[s].Text);
            int start = 0;
            while (true)
            {
                if (MeasureW(g, text.Substring(start)) <= avail) { _rows.Add(new Row { Src = s, Text = text.Substring(start), Start = start }); break; }
                // The last space at which the row still fits; failing that, the most characters that fit.
                int cut = -1;
                for (int i = start + 1; i < text.Length; i++)
                    if (text[i] == ' ') { if (MeasureW(g, text.Substring(start, i - start)) <= avail) cut = i; else break; }
                if (cut <= start)
                {
                    cut = start + 1;
                    while (cut < text.Length && MeasureW(g, text.Substring(start, cut - start + 1)) <= avail) cut++;
                }
                _rows.Add(new Row { Src = s, Text = text.Substring(start, cut - start), Start = start });
                start = cut; while (start < text.Length && text[start] == ' ') start++;
            }
        }
        _sheet?.Dispose();
        _sheet = new Bitmap(Math.Max(1, ClientSize.Width), Math.Max(1, ClientSize.Height));
        RedrawAll();
        Invalidate();
    }

    private float TextLeft => StripW + 12;
    private float RowTop(int row) => TopMargin + row * LineH;
    private int RowAt(float y) => (int)Math.Floor((y - TopMargin) / LineH);

    /// <summary>Whether a row prints left to right. With the bidirectional option, every other row runs back.</summary>
    private bool Forward(int row) => !Opts.Bidirectional || row % 2 == 0;

    /// <summary>The column printed k-th on a row, in the row's direction.</summary>
    private int ColForStep(int row, int k) => Forward(row) ? k : _rows[row].Text.Length - 1 - k;

    /// <summary>The whole sheet from scratch: paper, chrome, everything printed so far, strikes.</summary>
    private void RedrawAll()
    {
        using var g = Graphics.FromImage(_sheet);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
        g.Clear(Paper);
        if (IsLaser)
        {
            // A cut sheet: a hairline at the edge and nothing else.
            using (var edge = new Pen(Color.FromArgb(215, 212, 205), 1)) g.DrawRectangle(edge, 0, 0, _sheet.Width - 1, _sheet.Height - 1);
            using var toner = new SolidBrush(Ink);
            var rndL = new Random(42);
            for (int r = 0; r < _rows.Count; r++)
            {
                var row = _rows[r];
                if (row.Src >= _headSrc) continue;
                g.DrawString(row.Text, LaserFont, toner, TextLeft, RowTop(r), Typo);
                var right = _src[row.Src].Right;
                if (right != null && row.Start == 0) { var rt = Disp(right); g.DrawString(rt, LaserFont, toner, _sheet.Width - StripW - 12 - MeasureW(g, rt), RowTop(r), Typo); }
                if (_src[row.Src].Struck) DrawStrike(g, r, rndL);
            }
            DrawLamp(g);
            DrawChrome(g);
            return;
        }
        using (var bar = new SolidBrush(Bar))
            for (int l = 0; RowTop(l) < _sheet.Height; l += 6)
                g.FillRectangle(bar, StripW, RowTop(l) - _pitch * 1.5f, _sheet.Width - 2 * StripW, LineH * 3);
        using (var perf = new Pen(Perf, 1) { DashStyle = DashStyle.Dot })
        {
            g.DrawLine(perf, StripW, 0, StripW, _sheet.Height);
            g.DrawLine(perf, _sheet.Width - StripW, 0, _sheet.Width - StripW, _sheet.Height);
            g.DrawLine(perf, 0, 6, _sheet.Width, 6);
            g.DrawLine(perf, 0, _sheet.Height - 7, _sheet.Width, _sheet.Height - 7);
        }
        using (var hole = new SolidBrush(BackColor))
        using (var rim = new Pen(Color.FromArgb(120, 110, 100, 90), 1))
            for (float y = 14; y < _sheet.Height - 8; y += LineH)
                foreach (var cx in new[] { StripW / 2f, _sheet.Width - StripW / 2f })
                {
                    if (cx < StripW && y < 34) continue;      // the lamp sits there
                    g.FillEllipse(hole, cx - 5, y - 5, 10, 10);
                    g.DrawEllipse(rim, cx - 5, y - 5, 10, 10);
                }
        // Everything the head has printed so far.
        var rnd = new Random(42);
        for (int r = 0; r < _rows.Count; r++)
        {
            var row = _rows[r];
            int len = row.Text.Length;
            // How many characters of this row are on the paper.
            int k = row.Src < _headSrc ? len : (row.Src == _headSrc ? Math.Max(0, Math.Min(len, _headChar - row.Start)) : 0);
            if (k == 0) continue;
            for (int c = 0; c < len; c++)
            {
                bool printed = Forward(r) ? c < k : c >= len - k;
                if (printed && row.Text[c] != ' ') DotMatrix.DrawChar(g, row.Text[c], TextLeft + c * CharW, RowTop(r), _pitch, Ink, rnd, Opts.Ink);
            }
            if (_src[row.Src].Struck && row.Src < _headSrc) DrawStrike(g, r, rnd);
        }
        DrawLamp(g);
        DrawChrome(g);
    }

    private void PrintCharAt(int row, int col, char c)
    {
        using var g = Graphics.FromImage(_sheet);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        DotMatrix.DrawChar(g, c, TextLeft + col * CharW, RowTop(row), _pitch, Ink, _ribbon, Opts.Ink);
        Invalidate(new Rectangle((int)(TextLeft + col * CharW) - 2, (int)RowTop(row) - 2, (int)CharW + 6, (int)LineH + 4));
    }

    private void DrawStrike(Graphics g, int row, Random rnd)
    {
        float y = IsLaser ? RowTop(row) + _pitch * 4.2f : RowTop(row) + _pitch * 3.5f;
        using var pen = new Pen(Color.FromArgb(230, Ink), _pitch * 0.9f);
        var pts = new List<PointF>();
        float x0 = TextLeft - 2, x1 = TextLeft + (IsLaser ? MeasureW(g, _rows[row].Text) : _rows[row].Text.Length * CharW) + 2;
        for (float x = x0; x <= x1; x += 8) pts.Add(new PointF(x, y + (float)(rnd.NextDouble() - 0.5) * 1.6f));
        if (pts.Count > 1) g.DrawLines(pen, pts.ToArray());
    }

    private void StrikeSource(int s)
    {
        _src[s].Struck = true;
        using var g = Graphics.FromImage(_sheet);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        var rnd = new Random(42);
        for (int r = 0; r < _rows.Count; r++) if (_rows[r].Src == s) DrawStrike(g, r, rnd);
        Invalidate();
    }

    // ---- the anchor lamp -----------------------------------------------------------
    private Rectangle LampRect => new(0, 0, StripW, 40);
    private bool _lampHover;

    private void DrawLamp(Graphics g)
    {
        var r = LampRect;
        using (var paper = new SolidBrush(Paper)) g.FillRectangle(paper, r);
        using (var perf = new Pen(Perf, 1) { DashStyle = DashStyle.Dot }) { g.DrawLine(perf, StripW, r.Top, StripW, r.Bottom); g.DrawLine(perf, r.Left, 6, r.Right, 6); }
        float cx = StripW / 2f, cy = 22;
        Color on = Pinned ? Color.FromArgb(70, 220, 90) : Color.FromArgb(240, 60, 50);
        if (_lampHover) on = Pinned ? Color.FromArgb(120, 255, 130) : Color.FromArgb(255, 110, 95);
        for (int i = 8; i >= 1; i--)
        {
            float rad = 5 + i * 2.2f;
            using var bloom = new SolidBrush(Color.FromArgb(6 + (8 - i) * 6, on));
            g.FillEllipse(bloom, cx - rad, cy - rad, rad * 2, rad * 2);
        }
        using (var bezel = new SolidBrush(Color.FromArgb(60, 58, 55))) g.FillEllipse(bezel, cx - 7, cy - 7, 14, 14);
        using (var lens = new SolidBrush(on)) g.FillEllipse(lens, cx - 5, cy - 5, 10, 10);
        using (var core = new SolidBrush(Color.FromArgb(200, 255, 255, 255))) g.FillEllipse(core, cx - 2.2f, cy - 2.8f, 3.6f, 3.2f);
    }

    private void RedrawLamp() { using (var g = Graphics.FromImage(_sheet)) DrawLamp(g); Invalidate(LampRect); }

    private void SetPinned(bool on)
    {
        if (Pinned == on) return;
        Pinned = on;
        TopMost = on;
        RedrawLamp();
        _sounds.StrikeNow();
        PinChanged?.Invoke(on);
    }

    // ---- the chrome: A- A+  _ [] X  top-right, printed on the paper -------------------
    private enum Btn { Smaller, Larger, Minimise, Maximise, Close }
    private const int BtnW = 24, BtnH = 18, BtnGap = 4, BtnTop = 10;
    private Btn? _btnHover;

    private Rectangle BtnRect(Btn b)
    {
        int right = _sheet.Width - StripW - 6;
        int i = b switch { Btn.Close => 0, Btn.Maximise => 1, Btn.Minimise => 2, Btn.Larger => 3, Btn.Smaller => 4, _ => 0 };
        int extra = i >= 3 ? 10 : 0;                          // a gap between the text buttons and the window buttons
        return new Rectangle(right - (i + 1) * (BtnW + BtnGap) - extra, BtnTop, BtnW, BtnH);
    }

    private Rectangle ChromeRect => new(_sheet.Width - StripW - 6 - 5 * (BtnW + BtnGap) - 12, 7, 5 * (BtnW + BtnGap) + 14, BtnH + 6);

    private void DrawChrome(Graphics g)
    {
        using (var paper = new SolidBrush(Paper)) g.FillRectangle(paper, ChromeRect);
        using (var perf = new Pen(Perf, 1) { DashStyle = DashStyle.Dot }) g.DrawLine(perf, ChromeRect.Left, 6, ChromeRect.Right, 6);
        foreach (Btn b in Enum.GetValues(typeof(Btn)))
        {
            var r = BtnRect(b);
            if (_btnHover == b) { using var tint = new SolidBrush(Color.FromArgb(b == Btn.Close ? 40 : 22, b == Btn.Close ? Color.FromArgb(200, 40, 30) : Ink)); g.FillRectangle(tint, r); }
            using var pen = new Pen(Color.FromArgb(170, Ink), 1f);
            g.DrawRectangle(pen, r.X, r.Y, r.Width - 1, r.Height - 1);
            var rnd = new Random(7);
            float p = 1.7f;                                   // small dot font for the labels
            switch (b)
            {
                case Btn.Smaller: DotMatrix.DrawChar(g, 'A', r.X + 3, r.Y + 3, p, Ink, rnd); DotMatrix.DrawChar(g, '-', r.X + 3 + p * 6, r.Y + 3, p, Ink, rnd); break;
                case Btn.Larger:  DotMatrix.DrawChar(g, 'A', r.X + 3, r.Y + 3, p, Ink, rnd); DotMatrix.DrawChar(g, '+', r.X + 3 + p * 6, r.Y + 3, p, Ink, rnd); break;
                case Btn.Minimise: { using var ink = new Pen(Ink, 2f); g.DrawLine(ink, r.X + 7, r.Bottom - 6, r.Right - 7, r.Bottom - 6); break; }
                case Btn.Maximise: { using var ink = new Pen(Ink, 1.5f); if (_maximised) { g.DrawRectangle(ink, r.X + 6, r.Y + 7, 9, 7); g.DrawRectangle(ink, r.X + 9, r.Y + 4, 9, 7); } else g.DrawRectangle(ink, r.X + 6, r.Y + 4, r.Width - 13, r.Height - 9); break; }
                case Btn.Close: { using var ink = new Pen(Ink, 2f); g.DrawLine(ink, r.X + 7, r.Y + 4, r.Right - 8, r.Bottom - 5); g.DrawLine(ink, r.Right - 8, r.Y + 4, r.X + 7, r.Bottom - 5); break; }
            }
        }
    }

    private void RedrawChrome() { using (var g = Graphics.FromImage(_sheet)) DrawChrome(g); Invalidate(ChromeRect); }

    private Btn? BtnAt(Point p) { foreach (Btn b in Enum.GetValues(typeof(Btn))) if (BtnRect(b).Contains(p)) return b; return null; }

    private void Press(Btn b)
    {
        switch (b)
        {
            case Btn.Smaller: StepPitch(-1); break;
            case Btn.Larger:  StepPitch(+1); break;
            case Btn.Minimise: Minimise(); break;
            case Btn.Maximise: ToggleMaximise(); break;
            case Btn.Close: AskClose(); break;
        }
    }

    // ---- text size ---------------------------------------------------------------------
    private void StepPitch(int dir)
    {
        int i = Array.IndexOf(Pitches, _pitch); if (i < 0) i = 2;
        int j = Math.Max(0, Math.Min(Pitches.Length - 1, i + dir));
        if (j == i) return;
        _pitch = Pitches[j];
        _sounds.StrikeNow();
        if (!_maximised)
        {
            // The window grows or shrinks with the text, keeping its top-right corner.
            int right = Right;
            int w = StripW * 2 + (int)Math.Ceiling(CharW * DefaultCols) + 25;
            int h = TopMargin + (int)(LineH * (_src.Count + 2)) + BottomMargin;
            var scr = Screen.FromControl(this).WorkingArea;
            w = Math.Min(w, scr.Width); h = Math.Min(h, scr.Height);
            SetBounds(Math.Max(scr.Left, right - w), Top, w, h);
            BoundsSettled?.Invoke(new Rectangle(Location, ClientSize));
        }
        Relayout();
        PitchChanged?.Invoke(_pitch);
    }

    // ---- the printer options: right-click the paper (Mark, 2026-09-12) -------------------
    private ContextMenuStrip _menu;

    private void BuildMenu()
    {
        _menu = new ContextMenuStrip();
        var ink = new ToolStripMenuItem("Ink");
        foreach (var (label, w) in new[] { ("Light", 0), ("Normal", 1), ("Dark", 2), ("Black", 3) })
        {
            var it = new ToolStripMenuItem(label) { Checked = Opts.Ink == w, Tag = w };
            it.Click += (_, __) => { Opts.Ink = w; ApplyOptions(); };
            ink.DropDownItems.Add(it);
        }
        var speed = new ToolStripMenuItem("Speed");
        foreach (var (label, v) in new[] { ("Normal", 0), ("Fast", 1), ("Fastest", 2) })
        {
            var it = new ToolStripMenuItem(label) { Checked = Opts.Speed == v, Tag = v };
            it.Click += (_, __) => { Opts.Speed = v; ApplyOptions(); };
            speed.DropDownItems.Add(it);
        }
        var printer = new ToolStripMenuItem("Printer");
        foreach (var (label, v) in new[] { ("Dot matrix", 0), ("LaserWriter", 1) })
        {
            var it = new ToolStripMenuItem(label) { Checked = Opts.Printer == v, Tag = v };
            it.Click += (_, __) => { Opts.Printer = v; ApplyOptions(); };
            printer.DropDownItems.Add(it);
        }
        var face = new ToolStripMenuItem("Face");
        foreach (var (name, win) in Faces)
        {
            if (!FaceInstalled(win)) continue;
            var it = new ToolStripMenuItem(name) { Checked = Opts.Face == name, Tag = name, Font = new Font(win, 10f) };
            it.Click += (_, __) => { Opts.Face = name; ApplyOptions(); };
            face.DropDownItems.Add(it);
        }
        var bidi = new ToolStripMenuItem("Print in both directions") { Checked = Opts.Bidirectional, CheckOnClick = true };
        bidi.Click += (_, __) => { Opts.Bidirectional = bidi.Checked; ApplyOptions(); };
        var mixed = new ToolStripMenuItem("Upper and lower case") { Checked = Opts.MixedCase, CheckOnClick = true };
        mixed.Click += (_, __) => { Opts.MixedCase = mixed.Checked; ApplyOptions(); };
        _menu.Items.Add(printer);
        _menu.Items.Add(face);
        _menu.Items.Add(new ToolStripSeparator());
        _menu.Items.Add(ink);
        _menu.Items.Add(speed);
        _menu.Items.Add(new ToolStripSeparator());
        _menu.Items.Add(bidi);
        _menu.Items.Add(mixed);
        _menu.Opening += (_, __) =>
        {
            foreach (ToolStripMenuItem it in printer.DropDownItems) it.Checked = (int)it.Tag == Opts.Printer;
            foreach (ToolStripMenuItem it in face.DropDownItems) it.Checked = (string)it.Tag == Opts.Face;
            face.Enabled = IsLaser; bidi.Enabled = !IsLaser;
            foreach (ToolStripMenuItem it in ink.DropDownItems) it.Checked = (int)it.Tag == Opts.Ink;
            foreach (ToolStripMenuItem it in speed.DropDownItems) it.Checked = (int)it.Tag == Opts.Speed;
            bidi.Checked = Opts.Bidirectional; mixed.Checked = Opts.MixedCase;
        };
    }

    /// <summary>A changed option takes effect on the paper at once, and is told to the launcher to keep.</summary>
    private void ApplyOptions()
    {
        _clock.Interval = (int)CharMs;
        bool wasPrinting = _printing && _clock.Enabled && !IsLaser;
        try { _sounds.StopPrinting(); _sounds.LaserStop(); _sounds.Dispose(); } catch { }
        _sounds = new DotMatrix.Sounds(CharMs, LaserPhase);
        if (wasPrinting && _lineFeedPause == 0) _sounds.StartPrinting();
        // A change of printer while the dot matrix was mid-line: the rest
        // appears on the new page at once, and the head is at the foot.
        if (IsLaser && _printing) { _clock.Stop(); _lineFeedPause = 0; _headSrc = _src.Count; _headChar = 0; _printing = false; }
        if (!IsLaser && _laserTimer != null) { _laserTimer.Stop(); _laserTimer.Dispose(); _laserTimer = null; _reveal = float.MaxValue; _printing = false; }
        Relayout();
        if (!_printing) Flush();
        OptionsChanged?.Invoke(Opts.Clone());
    }

    // ---- maximise / minimise -----------------------------------------------------------
    private bool _maximised;
    private Rectangle _normalBounds;

    private void ToggleMaximise()
    {
        _sounds.StrikeNow();
        if (_maximised) { _maximised = false; Bounds = _normalBounds; }
        else { _normalBounds = Bounds; _maximised = true; Bounds = Screen.FromControl(this).WorkingArea; }
        RedrawChrome();
    }

    /// <summary>Where the sheet sits when it is out: where it was printed, or wherever it was last dragged to.</summary>
    public Point RestingLocation { get; private set; }
    protected override void OnLoad(EventArgs e) { base.OnLoad(e); RestingLocation = Location; }
    protected override void OnMove(EventArgs e) { base.OnMove(e); if (!_busy && !IsMinimised && Visible) RestingLocation = Location; }

    /// <summary>Winds the sheet up out of sight; the square takes its place. Nothing is lost.</summary>
    public void Minimise()
    {
        if (_busy || IsMinimised) return;
        _busy = true;
        int startTop = Top, steps = 0, feeds = 0;
        int screenTop = Screen.FromControl(this).Bounds.Top;
        var slide = new System.Windows.Forms.Timer { Interval = 12 };
        slide.Tick += (_, __) =>
        {
            steps++;
            if (steps % 5 == 1 && feeds++ < 6) _sounds.LineFeedNow();
            Top = startTop - (int)(Math.Pow(steps, 1.6) * 3);
            if (Top + Height < screenTop - 10 || steps > 70)
            {
                slide.Stop(); slide.Dispose();
                Hide(); Top = startTop; IsMinimised = true; _busy = false;
                Minimised?.Invoke();
                Flush();
            }
        };
        slide.Start();
    }

    /// <summary>Brings a minimised sheet back down, as it was.</summary>
    public void Restore()
    {
        if (!IsMinimised || _busy) return;
        _busy = true;
        int endTop = RestingLocation.Y;
        Top = Screen.FromPoint(RestingLocation).Bounds.Top - Height; Show(); Activate();
        int steps = 0, feeds = 0, from = Top;
        var slide = new System.Windows.Forms.Timer { Interval = 12 };
        slide.Tick += (_, __) =>
        {
            steps++;
            if (steps % 5 == 1 && feeds++ < 6) _sounds.LineFeedNow();
            Top = Math.Min(endTop, from + (int)(Math.Pow(steps, 1.6) * 3));
            if (Top >= endTop || steps > 70)
            {
                slide.Stop(); slide.Dispose();
                Top = endTop; IsMinimised = false; _busy = false;
                Restored?.Invoke();
                Flush();
            }
        };
        slide.Start();
    }

    // ---- the print head ----------------------------------------------------------------
    protected override void OnShown(EventArgs e)
    {
        base.OnShown(e);
        if (IsLaser) { _headSrc = _src.Count; _headChar = 0; LaserPrint(null); return; }
        _printing = true;
        _sounds.StartPrinting();
        _clock.Start();
    }

    /// <summary>
    /// The LaserWriter printing the page as it now is: the pause, the motor,
    /// the page coming out top first over the transport phase, the drop.
    /// The head is already at the foot; the rows are revealed as it emerges.
    /// </summary>
    private void LaserPrint(Action then)
    {
        _printing = true;
        Relayout();
        _reveal = 0; Invalidate();
        var ph = LaserPhase;
        double think = ph[0], spin = ph[1], feed = ph[2], down = ph[3];
        _sounds.LaserPageNow();
        var sw = System.Diagnostics.Stopwatch.StartNew();
        _laserTimer?.Stop(); _laserTimer?.Dispose();
        var t = new System.Windows.Forms.Timer { Interval = 16 };
        _laserTimer = t;
        t.Tick += (_, __) =>
        {
            double s = sw.Elapsed.TotalSeconds;
            double f = (s - think - spin) / feed;
            _reveal = f <= 0 ? 0 : f >= 1 ? float.MaxValue : (float)(f * (_rows.Count + 1));
            Invalidate();
            if (s >= think + spin + feed + down)
            {
                t.Stop(); t.Dispose(); if (_laserTimer == t) _laserTimer = null;
                _reveal = float.MaxValue; _printing = false;
                then?.Invoke();
                Flush();
            }
        };
        t.Start();
    }

    /// <summary>The row and the k-th step within it for the head's position in the current source line.</summary>
    private (int row, int k) HeadPos()
    {
        for (int r = 0; r < _rows.Count; r++)
        {
            var row = _rows[r];
            if (row.Src != _headSrc) continue;
            if (_headChar >= row.Start && _headChar < row.Start + row.Text.Length) return (r, _headChar - row.Start);
            if (_headChar >= row.Start + row.Text.Length && (r + 1 >= _rows.Count || _rows[r + 1].Src != _headSrc)) return (r, row.Text.Length);
        }
        return (-1, 0);
    }

    private void Step()
    {
        if (_busy || IsLaser) return;
        if (_lineFeedPause > 0) { _lineFeedPause--; if (_lineFeedPause == 0) _sounds.StartPrinting(); return; }
        // The last source line (blank, for the RECORDED line) is not printed on its own.
        if (_headSrc >= _src.Count - 1) { FinishPrinting(); return; }
        var text = Disp(_src[_headSrc].Text);
        if (_headChar < text.Length)
        {
            var (row, k) = HeadPos();
            if (row >= 0 && k < _rows[row].Text.Length)
            {
                int col = ColForStep(row, k);
                char c = _rows[row].Text[col];
                if (c != ' ') PrintCharAt(row, col, c);
            }
            _headChar++;
            // A wrap inside the source line is a line feed too.
            var (row2, _) = HeadPos();
            if (row2 != row && _headChar < text.Length) { _sounds.StopPrinting(); _sounds.LineFeedNow(); _lineFeedPause = 6; }
            return;
        }
        _sounds.StopPrinting();
        _sounds.LineFeedNow();
        _headSrc++; _headChar = 0;
        _lineFeedPause = text.Length == 0 ? 4 : 8;
    }

    private void FinishPrinting()
    {
        _printing = false;
        _sounds.StopPrinting();
        _clock.Stop();
        Flush();
    }

    /// <summary>Prints one more source line at printer speed, then calls back.</summary>
    private void PrintSourceThen(int s, string text, Action then)
    {
        _src[s].Text = text;
        if (IsLaser) { _headSrc = Math.Max(_headSrc, s + 1); _headChar = 0; LaserPrint(then); return; }
        Relayout();
        var disp = Disp(text);
        int n = 0;
        var t = new System.Windows.Forms.Timer { Interval = (int)CharMs };
        _sounds.StartPrinting();
        t.Tick += (_, __) =>
        {
            if (n < disp.Length)
            {
                int r = _rows.FindIndex(x => x.Src == s && n >= x.Start && n < x.Start + x.Text.Length);
                if (r >= 0)
                {
                    int col = ColForStep(r, n - _rows[r].Start);
                    char c = _rows[r].Text[col];
                    if (c != ' ') PrintCharAt(r, col, c);
                }
                n++; return;
            }
            t.Stop(); t.Dispose();
            _sounds.StopPrinting(); _sounds.LineFeedNow();
            // The head has passed this line now, so a later layout keeps it
            // (the YES line was being wiped by the layout for NO - Mark, 2026-09-11).
            _headSrc = Math.Max(_headSrc, s + 1); _headChar = 0;
            then();
        };
        t.Start();
    }

    // ---- interaction ---------------------------------------------------------------------
    private int SrcAt(Point p)
    {
        int row = RowAt(p.Y);
        return row >= 0 && row < _rows.Count ? _rows[row].Src : -1;
    }

    private bool IsChoice(int s) => s >= 0 && s < _src.Count && _src[s].Click != Outcome.None && !_src[s].Struck
                                    && !(_src[s].Click == Outcome.StartEngine && _engineStartAsked);

    protected override void OnMouseClick(MouseEventArgs e)
    {
        base.OnMouseClick(e);
        if (_busy) return;
        if (e.Button == MouseButtons.Right) { _menu.Show(this, e.Location); return; }
        if (e.Button != MouseButtons.Left) return;
        if (LampRect.Contains(e.Location)) { SetPinned(!Pinned); return; }
        var b = BtnAt(e.Location);
        if (b != null) { Press(b.Value); return; }
        if (_printing) return;
        Choose(SrcAt(e.Location));
    }

    /// <summary>Marks one of the printed choices: the X, the strike, the record.</summary>
    private void Choose(int s)
    {
        if (_printing || _busy || !IsChoice(s)) return;
        _sounds.StrikeNow();
        var outcome = _src[s].Click;
        int firstRow = _rows.FindIndex(x => x.Src == s);
        if (firstRow >= 0 && !IsLaser) PrintCharAt(firstRow, 1, 'X');
        _src[s].Text = "[X]" + _src[s].Text.Substring(3);
        if (IsLaser) Relayout();
        if (outcome == Outcome.CloseYes || outcome == Outcome.CloseNo) { AnswerClose(outcome == Outcome.CloseYes); return; }
        if (outcome == Outcome.StartEngine)
        {
            _engineStartAsked = true;
            PrintLines(new[] { L("Starting " + _engineName + " - watch for its window.") });
            EngineStartRequested?.Invoke();
            return;
        }
        Result = outcome;
        // No second choice after this one.
        foreach (var x in _src) if (x.Click == Outcome.Done || x.Click == Outcome.NotNow) x.Struck = true;
        if (outcome == Outcome.Done)
        {
            var t = new System.Windows.Forms.Timer { Interval = 260 };
            t.Tick += (_, __) =>
            {
                t.Stop(); t.Dispose();
                using (var g = Graphics.FromImage(_sheet)) { var rnd = new Random(42); for (int r = 0; r < _rows.Count; r++) if (_rows[r].Src == s) DrawStrike(g, r, rnd); }
                Invalidate();
                _printing = true;
                PrintSourceThen(_src.Count - 1, "Recorded " + DateTime.Now.ToString("HH:mm") + " by " + _who, () =>
                {
                    _src.Add(new Src { Text = "" });                 // a fresh blank for the feed
                    _headSrc = _src.Count; _headChar = 0; _printing = false;
                    Relayout();
                    Finished?.Invoke(Result);
                    Flush();
                });
            };
            t.Start();
        }
        else Finished?.Invoke(Result);
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        MaybeStartDrag(e);
        bool onLamp = !_busy && LampRect.Contains(e.Location);
        var b = _busy ? null : BtnAt(e.Location);
        bool onChoice = !_printing && !_busy && IsChoice(SrcAt(e.Location));
        Cursor = (onLamp || b != null || onChoice) ? Cursors.Hand : Cursors.Default;
        if (onLamp != _lampHover) { _lampHover = onLamp; RedrawLamp(); }
        if (b != _btnHover) { _btnHover = b; RedrawChrome(); }
    }

    protected override void OnMouseLeave(EventArgs e)
    {
        base.OnMouseLeave(e);
        if (_lampHover) { _lampHover = false; RedrawLamp(); }
        if (_btnHover != null) { _btnHover = null; RedrawChrome(); }
    }

    // Dragging by the paper: Windows does the drag, so it moves and snaps like
    // any window and crosses monitors. Not from the lamp, the buttons, a choice
    // line, or the resize edges.
    // A press on the paper is not yet a drag: a click with a pixel of hand
    // movement in it used to nudge the sheet (Mark, 2026-09-11). The native
    // drag begins only once the mouse has moved past the system drag size
    // with the button held; a plain click leaves the sheet where it is.
    private Point? _pressAt;

    protected override void OnMouseDown(MouseEventArgs e)
    {
        base.OnMouseDown(e);
        _pressAt = null;
        if (e.Button != MouseButtons.Left || _busy || _maximised) return;
        if (LampRect.Contains(e.Location) || BtnAt(e.Location) != null) return;
        if (!_printing && IsChoice(SrcAt(e.Location))) return;
        if (e.X < Edge || e.Y < Edge || e.X >= Width - Edge || e.Y >= Height - Edge) return;
        _pressAt = e.Location;
    }

    protected override void OnMouseUp(MouseEventArgs e) { base.OnMouseUp(e); _pressAt = null; }

    private void MaybeStartDrag(MouseEventArgs e)
    {
        if (_pressAt is not Point p || e.Button != MouseButtons.Left) return;
        var drag = SystemInformation.DragSize;
        if (Math.Abs(e.X - p.X) < drag.Width && Math.Abs(e.Y - p.Y) < drag.Height) return;
        _pressAt = null;
        ReleaseCapture();
        SendMessage(Handle, WM_NCLBUTTONDOWN, (IntPtr)HTCAPTION, IntPtr.Zero);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        if (_sheet == null) return;
        e.Graphics.DrawImageUnscaled(_sheet, 0, 0);
        if (IsLaser && _reveal < _rows.Count + 1)
        {
            float y = TopMargin + _reveal * LineH;
            using var blank = new SolidBrush(Paper);
            e.Graphics.FillRectangle(blank, 1, y, _sheet.Width - 2, Math.Max(0, _sheet.Height - 1 - y));
            using var slot = new Pen(Color.FromArgb(120, 90, 90, 85), 1);
            e.Graphics.DrawLine(slot, 1, y, _sheet.Width - 2, y);
        }
    }

    // ---- the feed: lines that arrive after the sheet is printed --------------------------
    // Anything that wants to print waits its turn: nothing prints over the
    // sheet's own printing, an animation, or the close question.
    private readonly Queue<Action> _later = new();

    private void Later(Action a) { _later.Enqueue(a); Flush(); }

    private void Flush()
    {
        if (IsDisposed || _later.Count == 0) return;
        if (_printing || _busy || _askingClose) return;
        var a = _later.Dequeue();
        a();
    }

    private static Src L(string text, Outcome click = Outcome.None) => new() { Text = text, Click = click };

    /// <summary>Grows the window for more rows, unless maximised or already tall enough.</summary>
    private void EnsureRoom(int extraRows)
    {
        int need = TopMargin + (int)(LineH * (_rows.Count + extraRows)) + BottomMargin;
        if (!_maximised && ClientSize.Height < need) { var sc = Screen.FromControl(this).WorkingArea; Height = Math.Min(need, sc.Height); if (Bottom > sc.Bottom) Top = Math.Max(sc.Top, sc.Bottom - Height); }
    }

    /// <summary>
    /// Appends lines to the foot of the sheet and prints them at printer speed:
    /// a blank line above (reusing one already there), the lines, then a fresh
    /// blank for whatever comes next. Runs the next waiting item when done.
    /// </summary>
    private void PrintLines(Src[] lines, Action then = null)
    {
        int blank = _src.Count - 1;
        if (blank < 0 || _src[blank].Text != "") { blank = _src.Count; _src.Add(new Src { Text = "" }); }
        int first = _src.Count;
        foreach (var l in lines) _src.Add(new Src { Text = "", Click = l.Click });
        _src.Add(new Src { Text = "" });
        EnsureRoom(lines.Length + 2);
        _headSrc = Math.Max(_headSrc, blank + 1); _headChar = 0;
        if (IsLaser)
        {
            for (int j = 0; j < lines.Length; j++) _src[first + j].Text = lines[j].Text;
            _headSrc = _src.Count; _headChar = 0;
            LaserPrint(then);
            return;
        }
        Relayout();
        _printing = true;
        int i = 0;
        Action next = null;
        next = () =>
        {
            if (i < lines.Length) { int s = first + i; string t = lines[i].Text; i++; PrintSourceThen(s, t, next); return; }
            _headSrc = _src.Count; _headChar = 0; _printing = false;
            then?.Invoke();
            Flush();
        };
        next();
    }

    /// <summary>
    /// The sim's graphics levels as read from its settings file just now. When
    /// they come to agree with what the mode needs, the "must be" lines are
    /// struck through and a confirmation prints - read from the sim, not
    /// anyone's word. When they stop agreeing, that prints too. Then, the
    /// first time they are right, the engine's START line is offered.
    /// </summary>
    public void GraphicsNow(SimSettings.TrafficGraphics g)
    {
        if (g == null || IsDisposed) return;
        if (g.Matches(_reqAircraft, _reqParked) == _gfxOk) return;      // nothing changed
        Later(() =>
        {
            bool ok = g.Matches(_reqAircraft, _reqParked);
            if (ok == _gfxOk) return;
            _gfxOk = ok;
            var stamp = DateTime.Now.ToString("HH:mm");
            if (ok)
            {
                _sounds.StrikeNow();
                foreach (var s in _gfxLines) StrikeSource(s);
                var lines = new List<Src>
                {
                    L("Graphics confirmed " + stamp + " - read from the sim:"),
                    L("   Aircraft Traffic " + Word(g.Aircraft) + "   Parked " + Word(g.Parked))
                };
                if (_engineLineDue && !_engineRunning && _engineFound)
                {
                    _engineLineDue = false;
                    lines.Add(L(""));
                    lines.Add(L("[ ] Start " + _engineName + " now", Outcome.StartEngine));
                }
                PrintLines(lines.ToArray());
            }
            else
            {
                PrintLines(new[]
                {
                    L("!! Graphics changed " + stamp + " - the sim now says:"),
                    L("   Aircraft Traffic " + Word(g.Aircraft) + "   Parked " + Word(g.Parked)),
                    L("   Must be " + Word(_reqAircraft) + " and " + Word(_reqParked) + " - set them again.")
                });
            }
        });
    }

    /// <summary>The engine's process seen up or gone, from the process list.</summary>
    public void EngineNow(bool running)
    {
        if (IsDisposed || _engineName == null || running == _engineRunning) return;
        _engineRunning = running;
        Later(() =>
        {
            var stamp = DateTime.Now.ToString("HH:mm");
            if (running)
            {
                _sounds.StrikeNow();
                for (int s = 0; s < _src.Count; s++) if (_src[s].Click == Outcome.StartEngine && !_src[s].Struck) StrikeSource(s);
                _engineLineDue = false;
                PrintLines(new[] { L(_engineName + " running - confirmed " + stamp + ","), L("   its process is up.") });
            }
            else
            {
                _engineStartAsked = false;
                var lines = new List<Src> { L("!! " + _engineName + " has stopped " + stamp + ".") };
                if (_engineFound) lines.Add(L("[ ] Start " + _engineName + " again", Outcome.StartEngine));
                else lines.Add(L("   Start it yourself; this sheet confirms it."));
                PrintLines(lines.ToArray());
            }
        });
    }

    /// <summary>The launcher could not start the engine: said in print, and the offer stands.</summary>
    public void EngineStartFailed(string why)
    {
        if (IsDisposed) return;
        Later(() =>
        {
            _engineStartAsked = false;
            PrintLines(new[]
            {
                L("!! Could not start " + _engineName + ": " + why),
                L("[ ] Start " + _engineName + " again", Outcome.StartEngine)
            });
        });
    }

    // ---- closing asks first (Mark, 2026-09-11) ---------------------------------------
    // The X, Alt+F4, the taskbar: all print the question at the foot of the
    // sheet, and only YES closes. More is going to come through this window
    // during a flight, so a stray click must not throw it away.
    private bool _askingClose, _closeConfirmed;

    /// <summary>Everything still to print appears at once: for when a person wants the sheet now, not in ten seconds.</summary>
    private void CompletePrintNow()
    {
        if (!_printing) return;
        if (_laserTimer != null) { _laserTimer.Stop(); _laserTimer.Dispose(); _laserTimer = null; _sounds.LaserStop(); }
        _reveal = float.MaxValue;
        _clock.Stop(); _lineFeedPause = 0;
        _headSrc = _src.Count; _headChar = 0;
        _printing = false;
        _sounds.StopPrinting();
        RedrawAll(); Invalidate();
    }

    private void AskClose()
    {
        if (_askingClose || _busy) return;
        if (_printing) CompletePrintNow();
        _askingClose = true;
        _sounds.StrikeNow();
        _src.Add(new Src { Text = "" });
        _src.Add(new Src { Text = "Close the printout?" });
        int yes = _src.Count; _src.Add(new Src { Text = "[ ] Yes - close it", Click = Outcome.CloseYes });
        int no = _src.Count;  _src.Add(new Src { Text = "[ ] No - keep it", Click = Outcome.CloseNo });
        EnsureRoom(3);
        _headSrc = Math.Max(_headSrc, yes - 2); _headChar = 0;   // the blank line above the question counts as printed
        if (IsLaser) { _headSrc = _src.Count; _headChar = 0; LaserPrint(null); return; }
        Relayout();
        _printing = true;
        PrintSourceThen(yes - 1, "Close the printout?", () =>
            PrintSourceThen(yes, "[ ] Yes - close it", () =>
                PrintSourceThen(no, "[ ] No - keep it", () => { _headSrc = _src.Count; _headChar = 0; _printing = false; })));
    }

    /// <summary>The program replacing this sheet with a new one: no question asked.</summary>
    public void CloseWithoutAsking() { _closeConfirmed = true; Close(); }

    private void AnswerClose(bool yes)
    {
        if (yes)
        {
            _closeConfirmed = true;
            if (Result == Outcome.None) { Result = Outcome.NotNow; Finished?.Invoke(Result); }
            Close();
            return;
        }
        // NO: the question is torn off the foot of the sheet, and it stays.
        _askingClose = false;
        _src.RemoveRange(_src.Count - 4, 4);
        _src.Add(new Src { Text = "" });
        _headSrc = _src.Count; _headChar = 0;
        Relayout();
        Flush();
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        base.OnFormClosing(e);
        if (e.CloseReason == CloseReason.UserClosing && !_closeConfirmed)
        {
            e.Cancel = true;
            if (IsMinimised) Restore();
            AskClose();
        }
    }

    protected override void OnFormClosed(FormClosedEventArgs e)
    {
        base.OnFormClosed(e);
        _clock.Stop(); _clock.Dispose();
        _sounds.Dispose();
        _sheet?.Dispose();
        _menu?.Dispose();
        _laserFont?.Dispose();
        _laserTimer?.Dispose();
    }

    // Keyboard: Enter = DONE, Escape = NOT NOW, same as the printed lines.
    protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
    {
        if (!_printing && !_busy)
        {
            if (keyData == Keys.Escape) { Choose(_src.FindIndex(x => x.Click == (_askingClose ? Outcome.CloseNo : Outcome.NotNow))); return true; }
            if (keyData == Keys.Enter)  { Choose(_src.FindIndex(x => x.Click == Outcome.Done)); return true; }
        }
        return base.ProcessCmdKey(ref msg, keyData);
    }
}
