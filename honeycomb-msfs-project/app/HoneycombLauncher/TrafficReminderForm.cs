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
/// Two printed lines are clickable. "DONE" strikes the line through, prints
/// who and when, and tears the sheet off: that is the person's word, and it
/// is recorded as such. "NOT NOW" tears the sheet off and the reminder comes
/// back next time. The program never pretends it verified anything here.
/// </summary>
internal sealed class TrafficReminderForm : Form
{
    public enum Outcome { None, Done, NotNow }
    public Outcome Result { get; private set; } = Outcome.None;
    public event Action<Outcome> Finished;

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

    public TrafficReminderForm(string mode, string required, string recorded, string recordedBy, string recordedUtc, string who)
    {
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

        _lines.Add(("HONEYCOMB PREFLIGHT".PadRight(Cols - 15) + DateTime.Now.ToString("dd MMM yy HH:mm").ToUpperInvariant()));
        _lines.Add("*** ACTION REQUIRED IN THE SIMULATOR ***");
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
        if (_printing || _closing) return;
        int line = (int)Math.Floor((e.Y - TopMargin) / LineH);
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
                PrintLineThen(_lines.Count - 1, ("RECORDED " + DateTime.Now.ToString("HH:mm") + " BY " + _who).ToUpperInvariant(), () => TearOffAndClose(900));
            };
            t.Start();
        }
        else TearOffAndClose(500);
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        int line = (int)Math.Floor((e.Y - TopMargin) / LineH);
        Cursor = (!_printing && !_closing && _clickable.ContainsKey(line) && !_struck.Contains(line)) ? Cursors.Hand : Cursors.Default;
    }

    private void TearOffAndClose(int delayMs)
    {
        if (_closing) return;
        _closing = true;
        var wait = new System.Windows.Forms.Timer { Interval = delayMs };
        wait.Tick += (_, __) =>
        {
            wait.Stop(); wait.Dispose();
            _sounds.TearNow();
            // The sheet slides up off the platen.
            int startTop = Top, steps = 0;
            var slide = new System.Windows.Forms.Timer { Interval = 12 };
            slide.Tick += (_2, __2) =>
            {
                steps++;
                Top = startTop - (int)(Math.Pow(steps, 1.7) * 3);
                if (Top + Height < 0 || steps > 60) { slide.Stop(); slide.Dispose(); Finished?.Invoke(Result); Close(); }
            };
            slide.Start();
        };
        wait.Start();
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
            if (keyData == Keys.Escape) { OnMouseClick(new MouseEventArgs(MouseButtons.Left, 1, 0, (int)(LineTop(NotNowLine()) + 2), 0)); return true; }
            if (keyData == Keys.Enter)  { OnMouseClick(new MouseEventArgs(MouseButtons.Left, 1, 0, (int)(LineTop(DoneLine()) + 2), 0)); return true; }
        }
        return base.ProcessCmdKey(ref msg, keyData);
    }
    private int DoneLine()   { foreach (var kv in _clickable) if (kv.Value == Outcome.Done) return kv.Key; return -1; }
    private int NotNowLine() { foreach (var kv in _clickable) if (kv.Value == Outcome.NotNow) return kv.Key; return -1; }
}
