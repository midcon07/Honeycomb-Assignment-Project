using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace HoneycombLauncher;

/// <summary>
/// The printout: a sheet of tractor-feed paper that prints - character by
/// character, with the printer's sounds - what a person has to do in the
/// sim's own options. Exists because MSFS keeps its Traffic Type setting
/// where no program can read or write it (measured 2026-09-11).
///
/// A window in its own right (Mark, 2026-09-11): opens pinned on top and
/// stays open; an anchor lamp top-left (green = on top, red = an ordinary
/// window); minimise, maximise and close, and text smaller/larger, drawn in
/// the printer's style top-right; resizable by its edges, the text reflowing
/// to the width; draggable by its paper to any monitor. Minimise puts it
/// away as a small square that brings it back. Nothing collapses on its own.
///
/// Two printed lines are clickable. "DONE" strikes the line through and prints
/// who and when: that is the person's word, recorded as such. "NOT NOW" leaves
/// it for the next occasion. The sheet never claims to have verified anything.
/// </summary>
internal sealed class TrafficReminderForm : Form
{
    public enum Outcome { None, Done, NotNow }
    public Outcome Result { get; private set; } = Outcome.None;
    /// <summary>A choice was made (DONE or NOT NOW). The sheet stays up.</summary>
    public event Action<Outcome> Finished;
    /// <summary>Minimised to the square / brought back.</summary>
    public event Action Minimised, Restored;
    public event Action<bool> PinChanged;
    public event Action<float> PitchChanged;
    public bool IsMinimised { get; private set; }
    /// <summary>Anchored: kept on top of everything, the simulator included.</summary>
    public bool Pinned { get; private set; }

    // ---- paper geometry ------------------------------------------------------
    public static readonly float[] Pitches = { 2.0f, 2.3f, 2.6f, 3.0f, 3.4f, 3.9f, 4.4f };
    private float _pitch;                             // dot pitch in px: the text size
    private float CharW => _pitch * 6;                // 5 dots + 1 gap
    private float LineH => _pitch * 10;               // 7 dots + 3 gap
    private const int StripW = 42;                    // sprocket strip each side
    private const int TopMargin = 38, BottomMargin = 26, Edge = 7;
    private const double CharMs = 17;                 // print speed
    private const int DefaultCols = 46;
    private int _cols = DefaultCols;

    private static readonly Color Paper = Color.FromArgb(244, 241, 228);
    private static readonly Color Bar = Color.FromArgb(214, 232, 208);
    private static readonly Color Ink = Color.FromArgb(28, 34, 66);
    private static readonly Color Perf = Color.FromArgb(200, 196, 180);

    // ---- what is printed -------------------------------------------------------
    private sealed class Src { public string Text = ""; public Outcome Click = Outcome.None; public bool Struck; }
    private sealed class Row { public int Src; public string Text = ""; public int Start; }   // Start = index of this row's first char within the source text
    private readonly List<Src> _src = new();
    private readonly List<Row> _rows = new();
    private Bitmap _sheet;
    private readonly Random _ribbon = new(42);
    private readonly DotMatrix.Sounds _sounds;
    private readonly System.Windows.Forms.Timer _clock = new() { Interval = (int)CharMs };
    // Print head: how many source lines are fully printed, and how far into the current one.
    private int _headSrc, _headChar;
    private bool _printing, _busy;
    private int _lineFeedPause;
    private readonly string _who;
    private readonly bool _resolved;

    public TrafficReminderForm(string mode, string required, string recorded, string recordedBy, string recordedUtc, string who, bool pinned = true, float pitch = 2.6f)
    {
        Pinned = pinned;
        _pitch = pitch;
        _resolved = !string.IsNullOrWhiteSpace(recorded) && string.Equals(recorded, required, StringComparison.OrdinalIgnoreCase);
        _who = string.IsNullOrWhiteSpace(who) ? Environment.UserName : who;

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
            "BATC"  => "BATC - BEYONDATC DRIVES THE TRAFFIC",
            "FSLTL" => "FSLTL - THE INJECTOR DRIVES THE TRAFFIC",
            "MSFS"  => "MSFS - ASOBO'S OWN TRAFFIC ENGINE",
            _       => mode
        };
        string when = "";
        if (!string.IsNullOrWhiteSpace(recordedUtc) && DateTime.TryParse(recordedUtc, null, System.Globalization.DateTimeStyles.AdjustToUniversal | System.Globalization.DateTimeStyles.AssumeUniversal, out var dt))
            when = dt.ToLocalTime().ToString("dd MMM").ToUpperInvariant();

        Add("HONEYCOMB PREFLIGHT".PadRight(DefaultCols - 15) + DateTime.Now.ToString("dd MMM yy HH:mm").ToUpperInvariant());
        Add(_resolved ? "*** TRAFFIC - AS RECORDED ***" : "*** ACTION REQUIRED IN THE SIMULATOR ***");
        Add("");
        Add("TRAFFIC MODE: " + mono);
        Add("MSFS TRAFFIC TYPE MUST BE: " + required.ToUpperInvariant());
        if (string.IsNullOrWhiteSpace(recorded)) Add("LAST RECORDED AS: NEVER RECORDED");
        else
        {
            Add("LAST RECORDED AS: " + recorded.ToUpperInvariant());
            if (when != "") Add("                  (" + when + (string.IsNullOrWhiteSpace(recordedBy) ? "" : " BY " + recordedBy.ToUpperInvariant()) + ")");
        }
        Add("");
        if (_resolved)
        {
            Add("NOTHING TO CHANGE. IF THE SIM SAYS OTHERWISE,");
            Add("OPTIONS > GENERAL > ONLINE > TRAFFIC TYPE.");
            Add("");
            Add("(THE SIM KEEPS THIS SETTING WHERE NO PROGRAM");
            Add(" CAN CHECK IT, SO THE RECORD IS SOMEONE'S WORD.)");
            Add("");
            Add("[ ] NOTED", Outcome.NotNow);
        }
        else
        {
            Add("IN THE SIM:");
            Add("  1. OPTIONS > GENERAL > ONLINE");
            Add("  2. TRAFFIC TYPE: " + required.ToUpperInvariant());
            Add("  3. SAVE, THEN BACK");
            Add("");
            Add("(THE SIM KEEPS THIS SETTING WHERE NO PROGRAM");
            Add(" CAN CHECK IT, SO YOUR WORD IS THE RECORD.)");
            Add("");
            Add("[ ] DONE - TRAFFIC TYPE IS NOW " + required.ToUpperInvariant(), Outcome.Done);
            Add("[ ] NOT NOW - REMIND ME NEXT TIME", Outcome.NotNow);
        }
        Add("");

        int w = StripW * 2 + (int)Math.Ceiling(CharW * DefaultCols) + 25;
        int h = TopMargin + (int)(LineH * (_src.Count + 2)) + BottomMargin;
        ClientSize = new Size(w, h);
        var scr = Screen.PrimaryScreen.WorkingArea;
        Location = new Point(scr.Right - w - 36, scr.Top + 36);

        _sounds = new DotMatrix.Sounds(CharMs);
        _clock.Tick += (_, __) => Step();
        Relayout();
    }

    private void Add(string text, Outcome click = Outcome.None) => _src.Add(new Src { Text = text, Click = click });

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
        if (m.Msg == WM_EXITSIZEMOVE && !Pinned && !_busy && !IsMinimised)
        {
            // Dropped somewhere on purpose: it stays there, on top (Mark, 2026-09-11).
            SetPinned(true);
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
        for (int s = 0; s < _src.Count; s++)
        {
            var text = _src[s].Text;
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

    private float TextLeft => StripW + 12;
    private float RowTop(int row) => TopMargin + row * LineH;
    private int RowAt(float y) => (int)Math.Floor((y - TopMargin) / LineH);

    /// <summary>The whole sheet from scratch: paper, chrome, everything printed so far, strikes.</summary>
    private void RedrawAll()
    {
        using var g = Graphics.FromImage(_sheet);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.Clear(Paper);
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
            int printedInSrc = row.Src < _headSrc ? int.MaxValue : (row.Src == _headSrc ? _headChar : -1);
            if (printedInSrc < 0) continue;
            for (int c = 0; c < row.Text.Length; c++)
            {
                if (row.Start + c >= printedInSrc) break;
                if (row.Text[c] != ' ') DotMatrix.DrawChar(g, row.Text[c], TextLeft + c * CharW, RowTop(r), _pitch, Ink, rnd);
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
        DotMatrix.DrawChar(g, c, TextLeft + col * CharW, RowTop(row), _pitch, Ink, _ribbon);
        Invalidate(new Rectangle((int)(TextLeft + col * CharW) - 2, (int)RowTop(row) - 2, (int)CharW + 6, (int)LineH + 4));
    }

    private void DrawStrike(Graphics g, int row, Random rnd)
    {
        float y = RowTop(row) + _pitch * 3.5f;
        using var pen = new Pen(Color.FromArgb(230, Ink), _pitch * 0.9f);
        var pts = new List<PointF>();
        float x0 = TextLeft - 2, x1 = TextLeft + _rows[row].Text.Length * CharW + 2;
        for (float x = x0; x <= x1; x += 8) pts.Add(new PointF(x, y + (float)(rnd.NextDouble() - 0.5) * 1.6f));
        if (pts.Count > 1) g.DrawLines(pen, pts.ToArray());
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
            case Btn.Close:
                if (Result == Outcome.None) { Result = Outcome.NotNow; Finished?.Invoke(Result); }
                Close();
                break;
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
        }
        Relayout();
        PitchChanged?.Invoke(_pitch);
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
            }
        };
        slide.Start();
    }

    // ---- the print head ----------------------------------------------------------------
    protected override void OnShown(EventArgs e)
    {
        base.OnShown(e);
        _printing = true;
        _sounds.StartPrinting();
        _clock.Start();
    }

    private (int row, int col) HeadPos()
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
        if (_busy) return;
        if (_lineFeedPause > 0) { _lineFeedPause--; if (_lineFeedPause == 0) _sounds.StartPrinting(); return; }
        // The last source line (blank, for the RECORDED line) is not printed on its own.
        if (_headSrc >= _src.Count - 1) { FinishPrinting(); return; }
        var text = _src[_headSrc].Text;
        if (_headChar < text.Length)
        {
            var (row, col) = HeadPos();
            if (row >= 0 && text[_headChar] != ' ') PrintCharAt(row, col, text[_headChar]);
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
    }

    /// <summary>Prints one more source line at printer speed, then calls back.</summary>
    private void PrintSourceThen(int s, string text, Action then)
    {
        _src[s].Text = text;
        Relayout();
        int col = 0;
        var t = new System.Windows.Forms.Timer { Interval = (int)CharMs };
        _sounds.StartPrinting();
        t.Tick += (_, __) =>
        {
            if (col < text.Length)
            {
                int r = _rows.FindIndex(x => x.Src == s && col >= x.Start && col < x.Start + x.Text.Length);
                if (r >= 0 && text[col] != ' ') PrintCharAt(r, col - _rows[r].Start, text[col]);
                col++; return;
            }
            t.Stop(); t.Dispose();
            _sounds.StopPrinting(); _sounds.LineFeedNow();
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

    private bool IsChoice(int s) => s >= 0 && s < _src.Count && _src[s].Click != Outcome.None && !_src[s].Struck;

    protected override void OnMouseClick(MouseEventArgs e)
    {
        base.OnMouseClick(e);
        if (_busy) return;
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
        Result = outcome;
        // The X goes into the box; no second choice after this one.
        int firstRow = _rows.FindIndex(x => x.Src == s);
        if (firstRow >= 0) PrintCharAt(firstRow, 1, 'X');
        _src[s].Text = "[X]" + _src[s].Text.Substring(3);
        foreach (var x in _src) if (x.Click != Outcome.None) x.Struck = true;
        if (outcome == Outcome.Done)
        {
            var t = new System.Windows.Forms.Timer { Interval = 260 };
            t.Tick += (_, __) =>
            {
                t.Stop(); t.Dispose();
                using (var g = Graphics.FromImage(_sheet)) { var rnd = new Random(42); for (int r = 0; r < _rows.Count; r++) if (_rows[r].Src == s) DrawStrike(g, r, rnd); }
                Invalidate();
                PrintSourceThen(_src.Count - 1, ("RECORDED " + DateTime.Now.ToString("HH:mm") + " BY " + _who).ToUpperInvariant(), () =>
                {
                    _headSrc = _src.Count; _headChar = 0;          // everything is printed now
                    Finished?.Invoke(Result);
                });
            };
            t.Start();
        }
        else Finished?.Invoke(Result);
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
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
    protected override void OnMouseDown(MouseEventArgs e)
    {
        base.OnMouseDown(e);
        if (e.Button != MouseButtons.Left || _busy || _maximised) return;
        if (LampRect.Contains(e.Location) || BtnAt(e.Location) != null) return;
        if (!_printing && IsChoice(SrcAt(e.Location))) return;
        if (e.X < Edge || e.Y < Edge || e.X >= Width - Edge || e.Y >= Height - Edge) return;
        ReleaseCapture();
        SendMessage(Handle, WM_NCLBUTTONDOWN, (IntPtr)HTCAPTION, IntPtr.Zero);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        if (_sheet != null) e.Graphics.DrawImageUnscaled(_sheet, 0, 0);
    }

    protected override void OnFormClosed(FormClosedEventArgs e)
    {
        base.OnFormClosed(e);
        _clock.Stop(); _clock.Dispose();
        _sounds.Dispose();
        _sheet?.Dispose();
    }

    // Keyboard: Enter = DONE, Escape = NOT NOW, same as the printed lines.
    protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
    {
        if (!_printing && !_busy)
        {
            if (keyData == Keys.Escape) { Choose(_src.FindIndex(x => x.Click == Outcome.NotNow)); return true; }
            if (keyData == Keys.Enter)  { Choose(_src.FindIndex(x => x.Click == Outcome.Done)); return true; }
        }
        return base.ProcessCmdKey(ref msg, keyData);
    }
}
