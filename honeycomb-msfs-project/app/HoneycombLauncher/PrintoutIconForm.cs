using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace HoneycombLauncher;

/// <summary>
/// The printout, minimised: a small square of tractor-feed paper, always on
/// top, at the corner the sheet was in. One click brings the same sheet back
/// down - nothing is reprinted, nothing is lost.
/// </summary>
internal sealed class PrintoutIconForm : Form
{
    public event Action Restore;

    private static readonly Color Paper = Color.FromArgb(244, 241, 228);
    private static readonly Color Bar = Color.FromArgb(214, 232, 208);
    private static readonly Color Ink = Color.FromArgb(28, 34, 66);
    private static readonly Color Perf = Color.FromArgb(200, 196, 180);
    private bool _hover;

    public PrintoutIconForm(Point topLeft)
    {
        FormBorderStyle = FormBorderStyle.None;
        TopMost = true;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        Text = "Honeycomb Preflight - printout (minimised)";
        DoubleBuffered = true;
        BackColor = Color.FromArgb(24, 24, 24);
        ClientSize = new Size(56, 56);
        Location = topLeft;
        Cursor = Cursors.Hand;
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.Clear(Paper);
        using (var bar = new SolidBrush(Bar)) g.FillRectangle(bar, 14, 18, Width - 14, 20);
        using var perf = new Pen(Perf, 1) { DashStyle = DashStyle.Dot };
        g.DrawLine(perf, 14, 0, 14, Height);
        g.DrawLine(perf, 0, 4, Width, 4);
        g.DrawLine(perf, 0, Height - 5, Width, Height - 5);
        using var hole = new SolidBrush(BackColor);
        using var rim = new Pen(Color.FromArgb(120, 110, 100, 90), 1);
        foreach (var y in new[] { 14f, 28f, 42f }) { g.FillEllipse(hole, 3, y - 4, 8, 8); g.DrawEllipse(rim, 3, y - 4, 8, 8); }
        var ink = _hover ? Color.FromArgb(120, 20, 20) : Ink;
        var rnd = new Random(9);
        float p = 1.9f, x = 20;
        foreach (var c in "PRT") { DotMatrix.DrawChar(g, c, x, 22, p, ink, rnd); x += p * 6; }
        // A few faint printed lines above and below, as text on a folded sheet.
        using var faint = new Pen(Color.FromArgb(70, Ink), 1.2f);
        g.DrawLine(faint, 19, 11, 47, 11); g.DrawLine(faint, 19, 45, 41, 45); g.DrawLine(faint, 19, 49, 47, 49);
        using var edge = new Pen(Color.FromArgb(90, 0, 0, 0), 1f);
        g.DrawRectangle(edge, 0, 0, Width - 1, Height - 1);
    }

    protected override void OnMouseEnter(EventArgs e) { base.OnMouseEnter(e); _hover = true; Invalidate(); }
    protected override void OnMouseLeave(EventArgs e) { base.OnMouseLeave(e); _hover = false; Invalidate(); }
    protected override void OnMouseClick(MouseEventArgs e) { base.OnMouseClick(e); Restore?.Invoke(); }
}
