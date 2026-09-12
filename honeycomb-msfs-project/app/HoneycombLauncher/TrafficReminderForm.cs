using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace HoneycombLauncher;

/// <summary>
/// A sheet of tractor-feed paper that stays on top of everything, including
/// the simulator, and prints - character by character, with the printer's
/// sounds - what has to be changed in the sim's own options. Exists because
/// MSFS keeps its Traffic Type setting where no program can read or write it
/// (measured 2026-09-11), so the only way to get it right is to tell the
/// person, in the sim, in a way they cannot miss.
///
/// Two printed lines are clickable. "DONE" strikes the line through and prints
/// who and when: that is the person's word, and it is recorded as such.
/// "NOT NOW" leaves it for the next occasion. The program never pretends it
/// verified anything here.
///
/// One printout window lives for the session. The pushpin in its corner keeps
/// it up on top of everything; with the pin out, a choice scrolls it up into
/// a small icon, and the icon scrolls the same sheet back down. It can be
/// dragged anywhere, to any monitor, by its paper.
/// </summary>
internal sealed class TrafficReminderForm : Form
{
    public enum Outcome { None, Done, NotNow }
    public Outcome Result { get; private set; } = Outcome.None;
    /// <summary>Raised when a choice is made (DONE or NOT NOW), whether or not the sheet then leaves the screen.</summary>
    public event Action<Outcome> Finished;
    /// <summary>Raised when the sheet has scrolled up out of sight; the icon takes its place.</summary>
    public event Action Collapsed;
    /// <summary>Raised when the sheet has scrolled back down.</summary>
    public event Action Expanded;
    public bool IsCollapsed { get; private set; }
    /// <summary>The pushpin through the top corner: pinned, the sheet stays up after a choice.</summary>
    public bool Pinned { get; private set; }

    // ---- paper geometry ------------------------------------------------------
    private const int Cols = 46;
    private const float Pitch = 2.6f;                 // dot pitch in px
    private const float CharW = Pitch * 6;            // 5 dots + 1 gap
    private const float LineH = Pitch * 10;           // 7 dots + 3 gap
    private const int StripW = 42;                    // sprocket strip each side
    private const int TopMargin = 30, BottomMargin = 26;
    private const double CharMs = 17;                 // print speed (19 was 10% too slow - Mark)

    private static readonly Color Paper = Color.FromArgb(244, 241, 228);
    private static readonly Color Bar = Color.FromArgb(214, 232, 208);
    private static readonly Color Ink = Color.FromArgb(28, 34, 66);
    private static readonly Color Perf = Color.FromArgb(200, 196, 180);

    private readonly List<string> _lines = new();
    private readonly Dictionary<int, Outcome> _clickable = new();
    private readonly HashSet<int> _struck = new();
    private readonly Bitmap _sheet;
    private readonly Random _ribbon = new(42);
    private readonly DotMatrix.Sounds _sounds;
    private readonly System.Windows.Forms.Timer _clock = new() { Interval = (int)CharMs };
    private int _line, _col;                          // print head position
    private bool _printing, _closing;
    private int _lineFeedPause;

    private readonly bool _resolved;

    public TrafficReminderForm(string mode, string required, string recorded, string recordedBy, string recordedUtc, string who, bool pinned = false)
    {
        Pinned = pinned;
        _resolved = !string.IsNullOrWhiteSpace(recorded) && string.Equals(recorded, required, StringComparison.OrdinalIgnoreCase);
        FormBorderStyle = FormBorderStyle.None;
        TopMost = true;
        ShowInTaskbar = true;
        StartPosition = FormStartPosition.Manual;
        Text = "Honeycomb Preflight - action required in the simulator";
        DoubleBuffered = true;
        BackColor = Color.FromArgb(24, 24, 24);

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

        // The date ends six columns short of the edge: the pushpin lives in that corner.
        _lines.Add(("HONEYCOMB PREFLIGHT".PadRight(Cols - 21) + DateTime.Now.ToString("dd MMM yy HH:mm").ToUpperInvariant()));
        _lines.Add(_resolved ? "*** TRAFFIC - AS RECORDED ***" : "*** ACTION REQUIRED IN THE SIMULATOR ***");
        _lines.Add("");
        _lines.Add("TRAFFIC MODE: " + mono);
        _lines.Add("MSFS TRAFFIC TYPE MUST BE: " + required.ToUpperInvariant());
        if (string.IsNullOrWhiteSpace(recorded)) _lines.Add("LAST RECORDED AS: NEVER RECORDED");
        else
        {
            _lines.Add("LAST RECORDED AS: " + recorded.ToUpperInvariant());
            if (when != "") _lines.Add("                  (" + when + (string.IsNullOrWhiteSpace(recordedBy) ? "" : " BY " + recordedBy.ToUpperInvariant()) + ")");
        }
        _lines.Add("");
        if (_resolved)
        {
            _lines.Add("NOTHING TO CHANGE. IF THE SIM SAYS OTHERWISE,");
            _lines.Add("OPTIONS > GENERAL > ONLINE > TRAFFIC TYPE.");
            _lines.Add("");
            _lines.Add("(THE SIM KEEPS THIS SETTING WHERE NO PROGRAM");
            _lines.Add(" CAN CHECK IT, SO THE RECORD IS SOMEONE'S WORD.)");
            _lines.Add("");
            _clickable[_lines.Count] = Outcome.NotNow; _lines.Add("[ ] CLOSE");
        }
        else
        {
            _lines.Add("IN THE SIM:");
            _lines.Add("  1. OPTIONS > GENERAL > ONLINE");
            _lines.Add("  2. TRAFFIC TYPE: " + required.ToUpperInvariant());
            _lines.Add("  3. SAVE, THEN BACK");
            _lines.Add("");
            _lines.Add("(THE SIM KEEPS THIS SETTING WHERE NO PROGRAM");
            _lines.Add(" CAN CHECK IT, SO YOUR WORD IS THE RECORD.)");
            _lines.Add("");
            _clickable[_lines.Count] = Outcome.Done;  _lines.Add("[ ] DONE - TRAFFIC TYPE IS NOW " + required.ToUpperInvariant());
            _clickable[_lines.Count] = Outcome.NotNow; _lines.Add("[ ] NOT NOW - REMIND ME NEXT TIME");
        }
        _lines.Add("");
        _lines.Add("");                                   // room for the RECORDED line

        // Nothing prints past the sprocket strip: a line longer than the
        // paper is wrapped at a space, and the clickable lines keep their
        // numbers straight when a wrap lands above them.
        for (int i = 0; i < _lines.Count; i++)
        {
            if (_lines[i].Length <= Cols) continue;
            var s = _lines[i];
            int cut = s.LastIndexOf(' ', Cols - 1);
            if (cut <= 0) cut = Cols;
            _lines[i] = s.Substring(0, cut).TrimEnd();
            _lines.Insert(i + 1, "  " + s.Substring(cut).TrimStart());
            var shifted = new Dictionary<int, Outcome>();
            foreach (var kv in _clickable) shifted[kv.Key > i ? kv.Key + 1 : kv.Key] = kv.Value;
            _clickable.Clear(); foreach (var kv in shifted) _clickable[kv.Key] = kv.Value;
        }

        int w = StripW * 2 + (int)(CharW * Cols) + 24;
        int h = TopMargin + (int)(LineH * _lines.Count) + BottomMargin;
        ClientSize = new Size(w, h);
        var scr = Screen.PrimaryScreen.WorkingArea;
        Location = new Point(scr.Right - w - 36, scr.Top + 36);

        _sheet = new Bitmap(w, h);
        DrawBlankSheet();
        _sounds = new DotMatrix.Sounds(CharMs);
        _clock.Tick += (_, __) => Step();
        _who = string.IsNullOrWhiteSpace(who) ? Environment.UserName : who;
    }
    private readonly string _who;

    protected override void OnShown(EventArgs e)
    {
        base.OnShown(e);
        _printing = true;
        _sounds.StartPrinting();
        _clock.Start();
    }

    // ---- the sheet ------------------------------------------------------------
    private float TextLeft => StripW + 12;
    private float LineTop(int line) => TopMargin + line * LineH;

    // ---- the pushpin -----------------------------------------------------------
    // Through the top-right corner of the paper, inside the sprocket strip.
    // The top-right corner of the paper itself, over the first three lines
    // and the sprocket strip: big enough to be seen from across the room.
    private Rectangle PinRect => new(_sheet.Width - StripW - 74, 6, StripW + 70, 78);
    private bool _pinHover;
    public event Action<bool> PinChanged;

    private void DrawPin(Graphics g)
    {
        var r = PinRect;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        // The paper under the pin is redrawn first - cream, the green bar
        // that the first three lines sit on, the perforation and the sprocket
        // holes - so toggling leaves no trace.
        using (var paper = new SolidBrush(Paper)) g.FillRectangle(paper, r);
        using (var bar = new SolidBrush(Bar))
        {
            float barTop = LineTop(0) - Pitch * 1.5f, barBottom = barTop + LineH * 3;
            g.FillRectangle(bar, r.X, Math.Max(r.Y, barTop), Math.Min(r.Right, _sheet.Width - StripW) - r.X, Math.Min(r.Bottom, barBottom) - Math.Max(r.Y, barTop));
        }
        using (var perf = new Pen(Perf, 1) { DashStyle = DashStyle.Dot }) g.DrawLine(perf, _sheet.Width - StripW, r.Top, _sheet.Width - StripW, r.Bottom);
        using (var hole = new SolidBrush(BackColor))
        using (var rim = new Pen(Color.FromArgb(120, 110, 100, 90), 1))
            for (float y = 14; y < r.Bottom + 6; y += LineH)
                if (y >= r.Top - 6) { float hx = _sheet.Width - StripW / 2f; g.FillEllipse(hole, hx - 5, y - 5, 10, 10); g.DrawEllipse(rim, hx - 5, y - 5, 10, 10); }

        // The pin itself, over the paper's corner, with its word printed under it.
        float cx = r.X + 36, cy = r.Y + 30;
        var red = _pinHover ? Color.FromArgb(240, 70, 58) : Color.FromArgb(205, 36, 30);
        var rnd = new Random(3);
        if (Pinned)
        {
            // Pushed in: the head flat on the paper, a tight shadow, the needle gone.
            using var shadow = new SolidBrush(Color.FromArgb(85, 0, 0, 0));
            g.FillEllipse(shadow, cx - 15, cy - 11, 32, 30);
            using var head = new SolidBrush(red);
            g.FillEllipse(head, cx - 16, cy - 16, 32, 32);
            using var rimDark = new Pen(Color.FromArgb(150, 70, 12, 10), 1.4f);
            g.DrawEllipse(rimDark, cx - 16, cy - 16, 32, 32);
            using var hi = new SolidBrush(Color.FromArgb(170, 255, 255, 255));
            g.FillEllipse(hi, cx - 9, cy - 11, 11, 8);
            float tx = r.X + 4;
            foreach (var c in "PINNED") { DotMatrix.DrawChar(g, c, tx, r.Y + 54, 1.9f, Ink, rnd); tx += 1.9f * 6; }
        }
        else
        {
            // Out: the pin leans over the paper, needle down to a dotted ring
            // where it goes; the head lifted, catching the light.
            if (_pinHover) { using var glow = new SolidBrush(Color.FromArgb(80, 255, 200, 60)); g.FillEllipse(glow, cx - 26, cy - 30, 52, 52); }
            using var ring = new Pen(Color.FromArgb(210, 140, 130, 110), 1.6f) { DashStyle = DashStyle.Dot };
            g.DrawEllipse(ring, cx - 6, cy + 10, 12, 12);
            using var needleShadow = new Pen(Color.FromArgb(70, 0, 0, 0), 4f);
            g.DrawLine(needleShadow, cx + 6, cy - 4, cx + 2, cy + 16);
            using var needle = new Pen(Color.FromArgb(175, 175, 180), 3f);
            g.DrawLine(needle, cx + 5, cy - 6, cx + 1, cy + 15);
            using var glint = new Pen(Color.FromArgb(235, 255, 255, 255), 1f);
            g.DrawLine(glint, cx + 4, cy - 5, cx + 0.5f, cy + 12);
            using var shadow = new SolidBrush(Color.FromArgb(50, 0, 0, 0));
            g.FillEllipse(shadow, cx - 8, cy - 14, 32, 30);
            using var head = new SolidBrush(red);
            g.FillEllipse(head, cx - 10, cy - 30, 30, 30);
            using var rimDark = new Pen(Color.FromArgb(150, 70, 12, 10), 1.4f);
            g.DrawEllipse(rimDark, cx - 10, cy - 30, 30, 30);
            using var hi = new SolidBrush(Color.FromArgb(180, 255, 255, 255));
            g.FillEllipse(hi, cx - 4, cy - 26, 11, 8);
            float tx = r.X + 4;
            foreach (var c in "^ PIN") { DotMatrix.DrawChar(g, c, tx, r.Y + 54, 1.9f, Ink, rnd); tx += 1.9f * 6; }
        }
    }

    private void RedrawPin()
    {
        using (var g = Graphics.FromImage(_sheet)) DrawPin(g);
        Invalidate(PinRect);
    }

    private void TogglePin()
    {
        Pinned = !Pinned;
        RedrawPin();
        _sounds.StrikeNow();
        PinChanged?.Invoke(Pinned);
        // Pulling the pin out lets the sheet go: it scrolls up to the icon.
        if (!Pinned) Collapse(250);
    }

    private void DrawBlankSheet()
    {
        using var g = Graphics.FromImage(_sheet);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.Clear(Paper);
        // Green bar: three lines pale, three lines paper, the whole way down.
        using (var bar = new SolidBrush(Bar))
            for (int l = 0; l < _lines.Count + 2; l += 6)
                g.FillRectangle(bar, StripW, LineTop(l) - Pitch * 1.5f, _sheet.Width - 2 * StripW, LineH * 3);
        // Sprocket strips: perforation line, then a hole per line.
        using var perf = new Pen(Perf, 1) { DashStyle = DashStyle.Dot };
        g.DrawLine(perf, StripW, 0, StripW, _sheet.Height);
        g.DrawLine(perf, _sheet.Width - StripW, 0, _sheet.Width - StripW, _sheet.Height);
        g.DrawLine(perf, 0, 6, _sheet.Width, 6);
        g.DrawLine(perf, 0, _sheet.Height - 7, _sheet.Width, _sheet.Height - 7);
        using var hole = new SolidBrush(BackColor);
        using var rim = new Pen(Color.FromArgb(120, 110, 100, 90), 1);
        for (float y = 14; y < _sheet.Height - 8; y += LineH)
        {
            foreach (var cx in new[] { StripW / 2f, _sheet.Width - StripW / 2f })
            {
                g.FillEllipse(hole, cx - 5, y - 5, 10, 10);
                g.DrawEllipse(rim, cx - 5, y - 5, 10, 10);
            }
        }
        DrawPin(g);
    }

    private void PrintCharAt(int line, int col, char c)
    {
        using var g = Graphics.FromImage(_sheet);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        DotMatrix.DrawChar(g, c, TextLeft + col * CharW, LineTop(line), Pitch, Ink, _ribbon);
        Invalidate(new Rectangle((int)(TextLeft + col * CharW) - 2, (int)LineTop(line) - 2, (int)CharW + 6, (int)LineH + 4));
    }

    private void StrikeThrough(int line)
    {
        using var g = Graphics.FromImage(_sheet);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        float y = LineTop(line) + Pitch * 3.5f;
        using var pen = new Pen(Color.FromArgb(230, Ink), Pitch * 0.9f);
        // A hand-drawn strike: a slight wobble, as a felt pen over paper.
        var pts = new List<PointF>();
        float x0 = TextLeft - 2, x1 = TextLeft + _lines[line].Length * CharW + 2;
        for (float x = x0; x <= x1; x += 8) pts.Add(new PointF(x, y + (float)(_ribbon.NextDouble() - 0.5) * 1.6f));
        if (pts.Count > 1) g.DrawLines(pen, pts.ToArray());
        _struck.Add(line);
        Invalidate();
    }

    // ---- the print head --------------------------------------------------------
    private void Step()
    {
        if (_closing) return;
        if (_lineFeedPause > 0) { _lineFeedPause--; if (_lineFeedPause == 0) _sounds.StartPrinting(); return; }
        if (_line >= _lines.Count - 2) { FinishPrinting(); return; }   // the last two lines are printed on demand
        var text = _lines[_line];
        if (_col < text.Length)
        {
            if (text[_col] != ' ') PrintCharAt(_line, _col, text[_col]);
            _col++;
            return;
        }
        // End of line: stop the head, feed the platen, pause a few ticks.
        _sounds.StopPrinting();
        _sounds.LineFeedNow();
        _line++; _col = 0;
        _lineFeedPause = text.Length == 0 ? 4 : 8;
    }

    private void FinishPrinting()
    {
        _printing = false;
        _sounds.StopPrinting();
        _clock.Stop();
    }

    /// <summary>Prints one more line immediately below the choices, at printer speed, then calls back.</summary>
    private void PrintLineThen(int line, string text, Action then)
    {
        _lines[line] = text;
        int col = 0;
        var t = new System.Windows.Forms.Timer { Interval = (int)CharMs };
        _sounds.StartPrinting();
        t.Tick += (_, __) =>
        {
            if (col < text.Length) { if (text[col] != ' ') PrintCharAt(line, col, text[col]); col++; return; }
            t.Stop(); t.Dispose();
            _sounds.StopPrinting(); _sounds.LineFeedNow();
            then();
        };
        t.Start();
    }

    // ---- interaction -----------------------------------------------------------
    protected override void OnMouseClick(MouseEventArgs e)
    {
        base.OnMouseClick(e);
        if (_closing) return;
        if (PinRect.Contains(e.Location)) { TogglePin(); return; }
        if (_printing) return;
        Choose((int)Math.Floor((e.Y - TopMargin) / LineH));
    }

    /// <summary>Marks one of the printed choices: the X, the strike, the record, the tear-off (unless pinned).</summary>
    private void Choose(int line)
    {
        if (_printing || _closing) return;
        if (!_clickable.TryGetValue(line, out var outcome) || _struck.Contains(line)) return;
        _sounds.StrikeNow();
        PrintCharAt(line, 1, 'X');
        Result = outcome;
        foreach (var l in _clickable.Keys) _struck.Add(l);          // no second choice
        if (outcome == Outcome.Done)
        {
            var t = new System.Windows.Forms.Timer { Interval = 260 };
            t.Tick += (_, __) =>
            {
                t.Stop(); t.Dispose();
                StrikeThrough(line);
                PrintLineThen(_lines.Count - 1, ("RECORDED " + DateTime.Now.ToString("HH:mm") + " BY " + _who).ToUpperInvariant(), () => { Finished?.Invoke(Result); Collapse(1200); });
            };
            t.Start();
        }
        else { Finished?.Invoke(Result); Collapse(600); }
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        int line = (int)Math.Floor((e.Y - TopMargin) / LineH);
        bool onLine = !_printing && !_closing && _clickable.ContainsKey(line) && !_struck.Contains(line);
        bool onPin = !_closing && PinRect.Contains(e.Location);
        Cursor = (onLine || onPin) ? Cursors.Hand : Cursors.Default;
        if (onPin != _pinHover) { _pinHover = onPin; RedrawPin(); }
    }

    protected override void OnMouseLeave(EventArgs e)
    {
        base.OnMouseLeave(e);
        if (_pinHover) { _pinHover = false; RedrawPin(); }
    }

    /// <summary>Where the sheet sits when it is down on the platen: where it was printed, or wherever it was last dragged to.</summary>
    public Point RestingLocation { get; private set; }
    protected override void OnLoad(EventArgs e) { base.OnLoad(e); RestingLocation = Location; }
    protected override void OnMove(EventArgs e)
    {
        base.OnMove(e);
        if (!_closing && !IsCollapsed && Visible) RestingLocation = Location;
    }

    // ---- dragging: the sheet can be carried anywhere, to any monitor -----------
    // Windows does the drag (a caption-drag on a window with no caption), so it
    // moves like any window, snaps like any window, and crosses monitors. A
    // press on the pin or on a clickable line is not a drag.
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern bool ReleaseCapture();
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);
    private const int WM_NCLBUTTONDOWN = 0x00A1, HTCAPTION = 0x2;

    protected override void OnMouseDown(MouseEventArgs e)
    {
        base.OnMouseDown(e);
        if (e.Button != MouseButtons.Left || _closing) return;
        if (PinRect.Contains(e.Location)) return;
        int line = (int)Math.Floor((e.Y - TopMargin) / LineH);
        if (!_printing && _clickable.ContainsKey(line) && !_struck.Contains(line)) return;
        ReleaseCapture();
        SendMessage(Handle, WM_NCLBUTTONDOWN, (IntPtr)HTCAPTION, IntPtr.Zero);
    }

    /// <summary>
    /// Scrolls the sheet up out of sight - unless it is pinned, in which
    /// case it stays exactly where it is. Nothing is lost: Expand brings the
    /// same sheet back down. The platen sounds as it winds.
    /// </summary>
    public void Collapse(int delayMs = 0)
    {
        if (_closing || Pinned || IsCollapsed) return;
        _closing = true;
        var wait = new System.Windows.Forms.Timer { Interval = Math.Max(1, delayMs) };
        wait.Tick += (_, __) =>
        {
            wait.Stop(); wait.Dispose();
            int startTop = RestingLocation.Y, steps = 0, feeds = 0;
            var slide = new System.Windows.Forms.Timer { Interval = 12 };
            slide.Tick += (_2, __2) =>
            {
                steps++;
                if (steps % 5 == 1 && feeds++ < 6) _sounds.LineFeedNow();
                Top = startTop - (int)(Math.Pow(steps, 1.6) * 3);
                if (Top + Height < 0 || steps > 70)
                {
                    slide.Stop(); slide.Dispose();
                    Hide(); Top = startTop; IsCollapsed = true; _closing = false;
                    Collapsed?.Invoke();
                }
            };
            slide.Start();
        };
        wait.Start();
    }

    /// <summary>Brings a collapsed sheet back down onto the platen, as it was.</summary>
    public void Expand()
    {
        if (!IsCollapsed || _closing) return;
        _closing = true;
        int endTop = RestingLocation.Y;
        Top = -Height; Show(); Activate();
        int steps = 0, feeds = 0;
        var slide = new System.Windows.Forms.Timer { Interval = 12 };
        slide.Tick += (_, __) =>
        {
            steps++;
            if (steps % 5 == 1 && feeds++ < 6) _sounds.LineFeedNow();
            Top = Math.Min(endTop, -Height + (int)(Math.Pow(steps, 1.6) * 3));
            if (Top >= endTop || steps > 70)
            {
                slide.Stop(); slide.Dispose();
                Top = endTop; IsCollapsed = false; _closing = false;
                Expanded?.Invoke();
            }
        };
        slide.Start();
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        e.Graphics.DrawImageUnscaled(_sheet, 0, 0);
    }

    protected override void OnFormClosed(FormClosedEventArgs e)
    {
        base.OnFormClosed(e);
        _clock.Stop(); _clock.Dispose();
        _sounds.Dispose();
        _sheet.Dispose();
    }

    // Keyboard: Escape = not now, Enter = done (the printed lines say the same).
    protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
    {
        if (!_printing && !_closing)
        {
            // Straight to the choice, not through the mouse path (a synthetic
            // click at a computed y marked the wrong line once: the y was
            // taken from a line index that had not been shifted by the wrap).
            if (keyData == Keys.Escape) { Choose(NotNowLine()); return true; }
            if (keyData == Keys.Enter)  { Choose(DoneLine()); return true; }
        }
        return base.ProcessCmdKey(ref msg, keyData);
    }
    private int DoneLine()   { foreach (var kv in _clickable) if (kv.Value == Outcome.Done) return kv.Key; return -1; }
    private int NotNowLine() { foreach (var kv in _clickable) if (kv.Value == Outcome.NotNow) return kv.Key; return -1; }
}
