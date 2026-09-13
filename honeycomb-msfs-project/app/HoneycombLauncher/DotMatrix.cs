using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Media;

namespace HoneycombLauncher;

/// <summary>
/// A 9-pin dot-matrix printer, in software: a 5x7 dot font drawn one
/// character at a time, and the printer's sounds synthesised in memory
/// (nothing is fetched, nothing ships as a media file). Used by the
/// tractor-feed reminder. The look is the airline dispatch printout of the
/// dot-matrix era: uppercase, a little ribbon fade on every dot.
/// </summary>
internal static class DotMatrix
{
    // ---- font: 5 columns x 7 rows, row-major, X = dot ----------------------
    private static readonly Dictionary<char, string[]> Glyphs = new()
    {
        ['A'] = new[] { ".XXX.", "X...X", "X...X", "XXXXX", "X...X", "X...X", "X...X" },
        ['B'] = new[] { "XXXX.", "X...X", "X...X", "XXXX.", "X...X", "X...X", "XXXX." },
        ['C'] = new[] { ".XXX.", "X...X", "X....", "X....", "X....", "X...X", ".XXX." },
        ['D'] = new[] { "XXX..", "X..X.", "X...X", "X...X", "X...X", "X..X.", "XXX.." },
        ['E'] = new[] { "XXXXX", "X....", "X....", "XXXX.", "X....", "X....", "XXXXX" },
        ['F'] = new[] { "XXXXX", "X....", "X....", "XXXX.", "X....", "X....", "X...." },
        ['G'] = new[] { ".XXX.", "X...X", "X....", "X.XXX", "X...X", "X...X", ".XXXX" },
        ['H'] = new[] { "X...X", "X...X", "X...X", "XXXXX", "X...X", "X...X", "X...X" },
        ['I'] = new[] { ".XXX.", "..X..", "..X..", "..X..", "..X..", "..X..", ".XXX." },
        ['J'] = new[] { "..XXX", "...X.", "...X.", "...X.", "...X.", "X..X.", ".XX.." },
        ['K'] = new[] { "X...X", "X..X.", "X.X..", "XX...", "X.X..", "X..X.", "X...X" },
        ['L'] = new[] { "X....", "X....", "X....", "X....", "X....", "X....", "XXXXX" },
        ['M'] = new[] { "X...X", "XX.XX", "X.X.X", "X.X.X", "X...X", "X...X", "X...X" },
        ['N'] = new[] { "X...X", "X...X", "XX..X", "X.X.X", "X..XX", "X...X", "X...X" },
        ['O'] = new[] { ".XXX.", "X...X", "X...X", "X...X", "X...X", "X...X", ".XXX." },
        ['P'] = new[] { "XXXX.", "X...X", "X...X", "XXXX.", "X....", "X....", "X...." },
        ['Q'] = new[] { ".XXX.", "X...X", "X...X", "X...X", "X.X.X", "X..X.", ".XX.X" },
        ['R'] = new[] { "XXXX.", "X...X", "X...X", "XXXX.", "X.X..", "X..X.", "X...X" },
        ['S'] = new[] { ".XXXX", "X....", "X....", ".XXX.", "....X", "....X", "XXXX." },
        ['T'] = new[] { "XXXXX", "..X..", "..X..", "..X..", "..X..", "..X..", "..X.." },
        ['U'] = new[] { "X...X", "X...X", "X...X", "X...X", "X...X", "X...X", ".XXX." },
        ['V'] = new[] { "X...X", "X...X", "X...X", "X...X", ".X.X.", ".X.X.", "..X.." },
        ['W'] = new[] { "X...X", "X...X", "X...X", "X.X.X", "X.X.X", "XX.XX", "X...X" },
        ['X'] = new[] { "X...X", "X...X", ".X.X.", "..X..", ".X.X.", "X...X", "X...X" },
        ['Y'] = new[] { "X...X", "X...X", ".X.X.", "..X..", "..X..", "..X..", "..X.." },
        ['Z'] = new[] { "XXXXX", "....X", "...X.", "..X..", ".X...", "X....", "XXXXX" },
        // Lowercase (Mark, 2026-09-12: mixed case as an option). Descenders are
        // squeezed into the seven rows, as a 5x7 head had to.
        ['a'] = new[] { ".....", ".....", ".XXX.", "....X", ".XXXX", "X...X", ".XXXX" },
        ['b'] = new[] { "X....", "X....", "X.XX.", "XX..X", "X...X", "X...X", "XXXX." },
        ['c'] = new[] { ".....", ".....", ".XXX.", "X....", "X....", "X...X", ".XXX." },
        ['d'] = new[] { "....X", "....X", ".XX.X", "X..XX", "X...X", "X...X", ".XXXX" },
        ['e'] = new[] { ".....", ".....", ".XXX.", "X...X", "XXXXX", "X....", ".XXX." },
        ['f'] = new[] { "..XX.", ".X..X", ".X...", "XXX..", ".X...", ".X...", ".X..." },
        ['g'] = new[] { ".....", ".XXXX", "X...X", "X...X", ".XXXX", "....X", ".XXX." },
        ['h'] = new[] { "X....", "X....", "X.XX.", "XX..X", "X...X", "X...X", "X...X" },
        ['i'] = new[] { "..X..", ".....", ".XX..", "..X..", "..X..", "..X..", ".XXX." },
        ['j'] = new[] { "...X.", ".....", "..XX.", "...X.", "...X.", "X..X.", ".XX.." },
        ['k'] = new[] { "X....", "X....", "X..X.", "X.X..", "XX...", "X.X..", "X..X." },
        ['l'] = new[] { ".XX..", "..X..", "..X..", "..X..", "..X..", "..X..", ".XXX." },
        ['m'] = new[] { ".....", ".....", "XX.X.", "X.X.X", "X.X.X", "X...X", "X...X" },
        ['n'] = new[] { ".....", ".....", "X.XX.", "XX..X", "X...X", "X...X", "X...X" },
        ['o'] = new[] { ".....", ".....", ".XXX.", "X...X", "X...X", "X...X", ".XXX." },
        ['p'] = new[] { ".....", ".....", "XXXX.", "X...X", "XXXX.", "X....", "X...." },
        ['q'] = new[] { ".....", ".....", ".XXXX", "X...X", ".XXXX", "....X", "....X" },
        ['r'] = new[] { ".....", ".....", "X.XX.", "XX..X", "X....", "X....", "X...." },
        ['s'] = new[] { ".....", ".....", ".XXXX", "X....", ".XXX.", "....X", "XXXX." },
        ['t'] = new[] { ".X...", ".X...", "XXX..", ".X...", ".X...", ".X..X", "..XX." },
        ['u'] = new[] { ".....", ".....", "X...X", "X...X", "X...X", "X..XX", ".XX.X" },
        ['v'] = new[] { ".....", ".....", "X...X", "X...X", "X...X", ".X.X.", "..X.." },
        ['w'] = new[] { ".....", ".....", "X...X", "X...X", "X.X.X", "X.X.X", ".X.X." },
        ['x'] = new[] { ".....", ".....", "X...X", ".X.X.", "..X..", ".X.X.", "X...X" },
        ['y'] = new[] { ".....", ".....", "X...X", "X...X", ".XXXX", "....X", ".XXX." },
        ['z'] = new[] { ".....", ".....", "XXXXX", "...X.", "..X..", ".X...", "XXXXX" },
        ['0'] = new[] { ".XXX.", "X...X", "X..XX", "X.X.X", "XX..X", "X...X", ".XXX." },
        ['1'] = new[] { "..X..", ".XX..", "..X..", "..X..", "..X..", "..X..", ".XXX." },
        ['2'] = new[] { ".XXX.", "X...X", "....X", "...X.", "..X..", ".X...", "XXXXX" },
        ['3'] = new[] { "XXXXX", "...X.", "..X..", "...X.", "....X", "X...X", ".XXX." },
        ['4'] = new[] { "...X.", "..XX.", ".X.X.", "X..X.", "XXXXX", "...X.", "...X." },
        ['5'] = new[] { "XXXXX", "X....", "XXXX.", "....X", "....X", "X...X", ".XXX." },
        ['6'] = new[] { "..XX.", ".X...", "X....", "XXXX.", "X...X", "X...X", ".XXX." },
        ['7'] = new[] { "XXXXX", "....X", "...X.", "..X..", ".X...", ".X...", ".X..." },
        ['8'] = new[] { ".XXX.", "X...X", "X...X", ".XXX.", "X...X", "X...X", ".XXX." },
        ['9'] = new[] { ".XXX.", "X...X", "X...X", ".XXXX", "....X", "...X.", ".XX.." },
        [' '] = new[] { ".....", ".....", ".....", ".....", ".....", ".....", "....." },
        ['.'] = new[] { ".....", ".....", ".....", ".....", ".....", ".XX..", ".XX.." },
        [','] = new[] { ".....", ".....", ".....", ".....", ".XX..", "..X..", ".X..." },
        [':'] = new[] { ".....", ".XX..", ".XX..", ".....", ".XX..", ".XX..", "....." },
        [';'] = new[] { ".....", ".XX..", ".XX..", ".....", ".XX..", "..X..", ".X..." },
        ['-'] = new[] { ".....", ".....", ".....", "XXXXX", ".....", ".....", "....." },
        ['/'] = new[] { "....X", "...X.", "...X.", "..X..", ".X...", ".X...", "X...." },
        ['('] = new[] { "..X..", ".X...", "X....", "X....", "X....", ".X...", "..X.." },
        [')'] = new[] { "..X..", "...X.", "....X", "....X", "....X", "...X.", "..X.." },
        ['['] = new[] { ".XXX.", ".X...", ".X...", ".X...", ".X...", ".X...", ".XXX." },
        [']'] = new[] { ".XXX.", "...X.", "...X.", "...X.", "...X.", "...X.", ".XXX." },
        ['\''] = new[] { ".XX..", "..X..", ".X...", ".....", ".....", ".....", "....." },
        ['"'] = new[] { ".X.X.", ".X.X.", ".X.X.", ".....", ".....", ".....", "....." },
        ['!'] = new[] { "..X..", "..X..", "..X..", "..X..", "..X..", ".....", "..X.." },
        ['?'] = new[] { ".XXX.", "X...X", "....X", "...X.", "..X..", ".....", "..X.." },
        ['='] = new[] { ".....", ".....", "XXXXX", ".....", "XXXXX", ".....", "....." },
        ['+'] = new[] { ".....", "..X..", "..X..", "XXXXX", "..X..", "..X..", "....." },
        ['*'] = new[] { ".....", "X.X.X", ".XXX.", "XXXXX", ".XXX.", "X.X.X", "....." },
        ['#'] = new[] { ".X.X.", ".X.X.", "XXXXX", ".X.X.", "XXXXX", ".X.X.", ".X.X." },
        ['_'] = new[] { ".....", ".....", ".....", ".....", ".....", ".....", "XXXXX" },
        ['>'] = new[] { "X....", ".X...", "..X..", "...X.", "..X..", ".X...", "X...." },
        ['<'] = new[] { "...X.", "..X..", ".X...", "X....", ".X...", "..X..", "...X." },
        ['&'] = new[] { ".XX..", "X..X.", "X.X..", ".X...", "X.X.X", "X..X.", ".XX.X" },
        ['%'] = new[] { "XX..X", "XX.X.", "..X..", "..X..", "..X..", ".X.XX", "X..XX" },
    };

    /// <summary>The glyph for a character; lowercase prints as uppercase, unknown as a hollow box.</summary>
    public static string[] Glyph(char c)
    {
        if (Glyphs.TryGetValue(c, out var g)) return g;
        if (Glyphs.TryGetValue(char.ToUpperInvariant(c), out g)) return g;
        return new[] { "XXXXX", "X...X", "X...X", "X...X", "X...X", "X...X", "XXXXX" };
    }

    /// <summary>
    /// Prints one character at a cell origin: 5x7 dots at the given pitch. Each
    /// dot is a small filled circle, darker in the middle of the glyph and a
    /// touch lighter at the edges, the way a used ribbon prints.
    /// </summary>
    /// <summary>Ink weights for the darkness option: 0 light, 1 normal (the original), 2 dark, 3 black.</summary>
    public const int Weights = 4;

    public static void DrawChar(Graphics g, char c, float x, float y, float pitch, Color ink, Random ribbon, int weight = 1)
    {
        var rows = Glyph(c);
        // Weight (Mark, 2026-09-12: "make the font darker"): a fresher ribbon
        // and a harder strike - less fade dot to dot, and a fatter dot.
        float d = pitch * weight switch { 0 => 0.80f, 2 => 0.93f, 3 => 1.0f, _ => 0.86f };
        int baseA = weight switch { 0 => 150, 2 => 236, 3 => 255, _ => 205 };
        int varyA = weight switch { 0 => 60, 2 => 19, 3 => 0, _ => 50 };
        for (int r = 0; r < 7; r++)
            for (int col = 0; col < 5; col++)
            {
                if (rows[r][col] != 'X') continue;
                // Ribbon wear: alpha varies dot to dot, never enough to lose one.
                int a = baseA + (varyA > 0 ? ribbon.Next(0, varyA) : 0);
                using var b = new SolidBrush(Color.FromArgb(a, ink));
                float jx = (float)(ribbon.NextDouble() - 0.5) * pitch * 0.12f;
                g.FillEllipse(b, x + col * pitch + jx, y + r * pitch, d, d);
            }
    }

    // ---- sound -------------------------------------------------------------
    private const int Rate = 22050;

    private static byte[] Wav(short[] pcm)
    {
        using var ms = new MemoryStream();
        using var w = new BinaryWriter(ms);
        w.Write(new[] { 'R', 'I', 'F', 'F' }); w.Write(36 + pcm.Length * 2); w.Write(new[] { 'W', 'A', 'V', 'E' });
        w.Write(new[] { 'f', 'm', 't', ' ' }); w.Write(16); w.Write((short)1); w.Write((short)1); w.Write(Rate); w.Write(Rate * 2); w.Write((short)2); w.Write((short)16);
        w.Write(new[] { 'd', 'a', 't', 'a' }); w.Write(pcm.Length * 2);
        foreach (var s in pcm) w.Write(s);
        w.Flush();
        return ms.ToArray();
    }

    private static short Clip(double v) => (short)Math.Max(-32767, Math.Min(32767, v * 32767));

    /// <summary>
    /// The print head crossing the paper: one character every charMs, five
    /// column strikes per character (pins hitting ribbon and platen: a sharp
    /// noise burst with a ring near 2.3 kHz), over a faint carriage hum. Built
    /// long enough to loop while a line prints.
    /// </summary>
    public static byte[] PrintLoop(double charMs, double seconds = 2.4)
    {
        var rnd = new Random(7);
        int n = (int)(Rate * seconds);
        var pcm = new double[n];
        double colMs = charMs / 5.0;
        int colSamples = Math.Max(1, (int)(Rate * colMs / 1000.0));
        for (int start = 0; start < n; start += colSamples)
        {
            double amp = 0.22 + rnd.NextDouble() * 0.08;
            for (int i = 0; i < colSamples && start + i < n; i++)
            {
                double t = i / (double)Rate;
                double env = Math.Exp(-t / 0.0011);
                double ring = Math.Sin(2 * Math.PI * 2300 * t) * 0.55 + Math.Sin(2 * Math.PI * 4100 * t) * 0.25;
                double noise = (rnd.NextDouble() * 2 - 1) * 0.8;
                pcm[start + i] += amp * env * (ring + noise);
            }
        }
        for (int i = 0; i < n; i++)
        {
            double t = i / (double)Rate;
            pcm[i] += 0.025 * Math.Sin(2 * Math.PI * 118 * t) + 0.012 * Math.Sin(2 * Math.PI * 236 * t);
        }
        var outp = new short[n];
        for (int i = 0; i < n; i++) outp[i] = Clip(pcm[i]);
        return Wav(outp);
    }

    /// <summary>
    /// The platen stepping one line: a stepper motor's zip - a clean tone
    /// around 1.4 kHz chopped at the step rate, quick in and out, a whisper of
    /// noise. No low thud (the first version had one; it sounded like a
    /// snort - Mark, 2026-09-11).
    /// </summary>
    public static byte[] LineFeed()
    {
        // No carrier tone at all - a tone chopped at a steady rate is a duck
        // (Mark, 2026-09-11, second attempt). A platen stepper is a ratchet:
        // a run of sharp mechanical clicks, each a few milliseconds of
        // broadband noise with a faint high ring, ~7 ms apart, the run
        // fading out as the platen settles.
        var rnd = new Random(11);
        int n = (int)(Rate * 0.09);
        var pcm = new double[n];
        int clicks = 9; double spacing = 0.0072;
        for (int c = 0; c < clicks; c++)
        {
            int start = (int)(Rate * (0.004 + c * spacing));
            double amp = 0.38 * (1.0 - 0.06 * c) * (0.85 + 0.3 * rnd.NextDouble());
            int len = (int)(Rate * 0.0035);
            for (int i = 0; i < len && start + i < n; i++)
            {
                double t = i / (double)Rate;
                double env = Math.Exp(-t / 0.0007);
                double noise = rnd.NextDouble() * 2 - 1;
                double ring = 0.35 * Math.Sin(2 * Math.PI * 3600 * t) * Math.Exp(-t / 0.0015);
                pcm[start + i] += amp * env * (noise + ring);
            }
        }
        var outp = new short[n];
        for (int i = 0; i < n; i++) outp[i] = Clip(pcm[i]);
        return Wav(outp);
    }

    /// <summary>
    /// A LaserWriter printing one page (Mark, 2026-09-12: the Apple LaserWriter,
    /// Canon CX/SX engine, 8 pages a minute). The fan runs throughout. Then: the
    /// PostScript pause (fan only), a relay click, the main motor coming up to
    /// speed as a low rumble, the sheet drawn off the stack in the tray (a
    /// sliding hiss and a soft thump), the rollers carrying it through - a
    /// rolling rumble turning about nine times a second with the paper hissing
    /// against the guides - the page flapping out into the tray, and the motor
    /// winding down. No whine: Mark, 2026-09-12, "make it sound like a piece of
    /// paper being drawn out of the tray, then pushed through with rollers".
    /// Phase lengths in seconds.
    /// </summary>
    public static byte[] LaserPage(double think, double spin, double feed, double down)
    {
        var rnd = new Random(11);
        double total = think + spin + feed + down + 0.15;
        int n = (int)(Rate * total);
        var pcm = new short[n];
        double lp = 0, lp2 = 0, lp3 = 0;
        double tRelay = think, tPick = think + spin, tDrop = think + spin + feed;
        for (int i = 0; i < n; i++)
        {
            double t = i / (double)Rate;
            double white = rnd.NextDouble() * 2 - 1;
            lp3 += (white - lp3) * 0.25;                     // a broader rumble for the rollers
            double hiss = white - lp3;                       // paper against the guides: the high part only
            // No fan and no motor: they read as a jet engine (Mark, 2026-09-12).
            // The airport ambience plays under the printer instead. What is
            // left is the paper: the sheet drawn off the stack, the rollers
            // carrying it through, and the drop into the tray.
            double v = 0;
            // the rollers turning the sheet through: about nine turns a second
            if (t >= tPick && t < tDrop + down)
            {
                double fade = t < tDrop ? 1 : Math.Max(0, 1 - (t - tDrop) / down);
                double turn = 0.5 + 0.5 * Math.Sin(2 * Math.PI * 9 * t);
                v += 0.035 * fade * lp3 * turn;
                v += 0.014 * fade * hiss * (0.6 + 0.4 * Math.Sin(2 * Math.PI * 9 * t + 1.1));
            }
            // the relay
            double r = t - tRelay; if (r >= 0 && r < 0.012) v += 0.4 * white * Math.Exp(-r / 0.003);
            // the sheet drawn off the stack: a sliding hiss, rising then falling, over a soft thump
            double k = t - tPick;
            if (k >= 0 && k < 0.30)
            {
                double env = k < 0.06 ? k / 0.06 : Math.Exp(-(k - 0.06) / 0.09);
                v += 0.18 * env * hiss;
                v += 0.16 * Math.Sin(2 * Math.PI * 80 * k) * Math.Exp(-k / 0.035);
            }
            // the page flapping out into the tray
            double d = t - tDrop;
            if (d >= 0 && d < 0.12) v += 0.16 * lp3 * Math.Exp(-d / 0.03) + 0.07 * hiss * Math.Exp(-d / 0.02);
            // in and out gently
            double env2 = Math.Min(1, t / 0.15) * Math.Min(1, (total - t) / 0.15);
            pcm[i] = Clip(v * env2);
        }
        return Wav(pcm);
    }

    /// <summary>A single hard strike, for the X in a box.</summary>
    public static byte[] Strike()
    {
        var rnd = new Random(3);
        int n = (int)(Rate * 0.05);
        var pcm = new short[n];
        for (int i = 0; i < n; i++)
        {
            double t = i / (double)Rate;
            double env = Math.Exp(-t / 0.004);
            pcm[i] = Clip(0.5 * env * (Math.Sin(2 * Math.PI * 2100 * t) + 0.9 * (rnd.NextDouble() * 2 - 1)));
        }
        return Wav(pcm);
    }

    /// <summary>The sheet torn off along the perforation: a crackle sweeping across.</summary>
    public static byte[] Tear()
    {
        var rnd = new Random(5);
        int n = (int)(Rate * 0.28);
        var pcm = new short[n];
        for (int i = 0; i < n; i++)
        {
            double p = i / (double)n;
            double env = Math.Sin(Math.PI * p);
            double burst = (rnd.NextDouble() < 0.35 + 0.4 * p) ? (rnd.NextDouble() * 2 - 1) : 0;
            pcm[i] = Clip(0.3 * env * burst);
        }
        return Wav(pcm);
    }

    /// <summary>
    /// Plays the synthesised sounds. Files are written once to the app's
    /// local folder because SoundPlayer is happiest with a path.
    /// </summary>
    public sealed class Sounds : IDisposable
    {
        private readonly SoundPlayer _loop, _feed, _strike, _tear, _laser;
        public bool Muted { get; set; }

        /// <param name="laser">LaserWriter phase lengths (think, spin, feed, down) in seconds; null for the defaults.</param>
        public Sounds(double charMs, double[] laser = null)
        {
            laser ??= new[] { 0.9, 1.1, 2.2, 0.7 };
            var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "HoneycombAssignment", "sounds");
            Directory.CreateDirectory(dir);
            SoundPlayer Make(string name, byte[] wav)
            {
                var p = Path.Combine(dir, name);
                try { File.WriteAllBytes(p, wav); } catch { }
                var sp = new SoundPlayer(p);
                try { sp.Load(); } catch { }
                return sp;
            }
            _loop = Make("dotmatrix-print.wav", PrintLoop(charMs));
            _feed = Make("dotmatrix-linefeed.wav", LineFeed());
            _strike = Make("dotmatrix-strike.wav", Strike());
            _tear = Make("dotmatrix-tear.wav", Tear());
            _laser = Make("laserwriter-page.wav", LaserPage(laser[0], laser[1], laser[2], laser[3]));
        }

        public void LaserPageNow() => Try(() => _laser.Play());
        public void LaserStop() => Try(() => _laser.Stop());

        private void Try(Action a) { if (Muted) return; try { a(); } catch { } }
        public void StartPrinting() => Try(() => _loop.PlayLooping());
        public void StopPrinting() => Try(() => _loop.Stop());
        public void LineFeedNow() => Try(() => _feed.Play());
        public void StrikeNow() => Try(() => _strike.Play());
        public void TearNow() => Try(() => _tear.Play());
        public void Dispose() { foreach (var p in new[] { _loop, _feed, _strike, _tear, _laser }) { try { p.Stop(); p.Dispose(); } catch { } } }
    }
}
