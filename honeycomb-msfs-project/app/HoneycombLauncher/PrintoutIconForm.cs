using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace HoneycombLauncher;

/// <summary>
/// The printout, collapsed: a short strip of tractor-feed paper still in
/// the printer, always on top, where the sheet's top edge was. One click
/// brings the same sheet back down - nothing is reprinted, nothing is lost.
/// </summary>
internal sealed class PrintoutIconForm : Form
{
    public event Action Expand;

    private const int StripW = 42;
    private static readonly Color Paper = Color.FromArgb(244, 241, 228);
    private static readonly Color Bar = Color.FromArgb(214, 232, 208);
    private static readonly Color Ink = Color.FromArgb(28, 34, 66);
    private static readonly Color Perf = Color.FromArgb(200, 196, 180);
    private bool _hover;

    public PrintoutIconForm(Point topRightAnchor)
    {
        FormBorderStyle = FormBorderStyle.None;
        TopMost = true;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        Text = "Honeycomb Preflight - printout";
        DoubleBuffered = true;
        BackColor = Color.FromArgb(24, 24, 24);
        ClientSize = new Size(StripW * 2 + 190, 40);
        Location = new Point(topRightAnchor.X - Width, topRightAnchor.Y);
        Cursor = Cursors.Hand;
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.Clear(Paper);
        using (var bar = new SolidBrush(Bar)) g.FillRectangle(bar, StripW, 0, Width - 2 * StripW, Height);
        using var perf = new Pen(Perf, 1) { DashStyle = DashStyle.Dot };
        g.DrawLine(perf, StripW, 0, StripW, Height);
        g.DrawLine(perf, Width - StripW, 0, Width - StripW, Height);
        g.DrawLine(perf, 0, Height - 2, Width, Height - 2);
        using var hole = new SolidBrush(BackColor);
        using var rim = new Pen(Color.FromArgb(120, 110, 100, 90), 1);
        foreach (var cx in new[] { StripW / 2f, Width - StripW / 2f })
        {
            g.FillEllipse(hole, cx - 5, 7, 10, 10); g.DrawEllipse(rim, cx - 5, 7, 10, 10);
            g.FillEllipse(hole, cx - 5, 26, 10, 10); g.DrawEllipse(rim, cx - 5, 26, 10, 10);
        }
        var ink = _hover ? Color.FromArgb(120, 20, 20) : Ink;
        float pitch = 2.6f, x = StripW + 12, y = 10;
        var rnd = new Random(9);
        foreach (var c in "v PRINTOUT")
        {
            DotMatrix.DrawChar(g, c, x, y, pitch, ink, rnd);
            x += pitch * 6;
        }
    }

    protected override void OnMouseEnter(EventArgs e) { base.OnMouseEnter(e); _hover = true; Invalidate(); }
    protected override void OnMouseLeave(EventArgs e) { base.OnMouseLeave(e); _hover = false; Invalidate(); }
    protected override void OnMouseClick(MouseEventArgs e) { base.OnMouseClick(e); Expand?.Invoke(); }
}
