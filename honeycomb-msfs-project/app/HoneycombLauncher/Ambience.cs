using System.Speech.AudioFormat;
using System.Speech.Synthesis;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace HoneycombLauncher;

/// <summary>
/// The airport under the printer (Mark, 2026-09-12: "random airport
/// ambience - 'now boarding', that kind of thing" - in place of the printer's
/// fan, which sounded like a jet engine; then "the wind sound in the
/// background isn't needed - drop it. Maybe *faint* jet (and the occasional
/// turboprop) sounds in the background, but that's it"). So: nothing
/// continuous. Every minute or so a jet at a distance, now and then a
/// turboprop, both faint and synthesised on the spot; and every half-minute
/// or so a gate announcement - one of Windows' own voices, run through a PA:
/// the two-tone chime, the tinny band of a ceiling horn, the hall's echo.
/// Airlines and cities of the era. NAudio mixes it under the printer's own
/// sounds, which SoundPlayer alone could not do.
/// </summary>
internal sealed class Ambience : IDisposable
{
    private const int Rate = 22050;
    private readonly Control _owner;
    private readonly Random _rnd = new();
    private WaveOutEvent _paOut, _acOut;
    private readonly System.Windows.Forms.Timer _nextPa = new(), _nextAc = new();
    private bool _running, _busy;
    private float _volume = 0.55f;

    public Ambience(Control owner) { _owner = owner; }

    /// <summary>Overall level, 0..1. Aircraft stay faint; announcements carry.</summary>
    public float Volume { get => _volume; set => _volume = Math.Max(0, Math.Min(1, value)); }

    public void Start()
    {
        if (_running) return;
        _running = true;
        _nextPa.Tick += (_, __) => { _nextPa.Stop(); Announce(); };
        _nextPa.Interval = _rnd.Next(6000, 14000);
        _nextPa.Start();
        _nextAc.Tick += (_, __) => { _nextAc.Stop(); Aircraft(); };
        _nextAc.Interval = _rnd.Next(3000, 12000);
        _nextAc.Start();
    }

    public void Stop()
    {
        if (!_running) return;
        _running = false;
        _nextPa.Stop(); _nextAc.Stop();
        try { _paOut?.Stop(); _paOut?.Dispose(); } catch { }
        try { _acOut?.Stop(); _acOut?.Dispose(); } catch { }
        _paOut = null; _acOut = null;
    }

    public void Dispose() { Stop(); _nextPa.Dispose(); _nextAc.Dispose(); }

    // ---- the aircraft, at a distance ----------------------------------------------
    private void Aircraft()
    {
        if (!_running) return;
        try
        {
            bool prop = _rnd.NextDouble() < 0.3;
            var pcm = prop ? Turboprop(6 + _rnd.NextDouble() * 4) : Jet(8 + _rnd.NextDouble() * 6);
            try { _acOut?.Stop(); _acOut?.Dispose(); } catch { }
            var src = new RawSourceWaveStream(new MemoryStream(pcm), new WaveFormat(Rate, 16, 1));
            var vol = new VolumeSampleProvider(src.ToSampleProvider()) { Volume = _volume * (prop ? 0.11f : 0.09f) };
            _acOut = new WaveOutEvent { DesiredLatency = 200 };
            _acOut.Init(vol);
            _acOut.Play();
            Program.Log("ambience: " + (prop ? "a turboprop" : "a jet") + " at a distance");
        }
        catch (Exception ex) { Program.LogError("ambience aircraft", ex); }
        _nextAc.Interval = _rnd.Next(30000, 90000);
        _nextAc.Start();
    }

    /// <summary>
    /// A jet passing at a distance: a roar shaped like a swell, mostly below
    /// 600 Hz with a breath of the higher hiss, the pitch of the hiss easing
    /// down as it goes away. No whine - that reads as an engine in the room.
    /// </summary>
    private static byte[] Jet(double seconds)
    {
        var rnd = new Random();
        int n = (int)(Rate * seconds);
        var pcm = new byte[n * 2];
        double lp1 = 0, lp2 = 0, lp3 = 0, mid = 0;
        for (int i = 0; i < n; i++)
        {
            double p = i / (double)n, t = i / (double)Rate;
            double white = rnd.NextDouble() * 2 - 1;
            double a = 0.17 - 0.06 * p;                      // the roar: lower as it goes
            lp1 += (white - lp1) * a; lp2 += (lp1 - lp2) * a; lp3 += (lp2 - lp3) * a;
            mid += (white - mid) * 0.5;
            double swell = Math.Pow(Math.Sin(Math.PI * p), 1.6);
            double v = lp3 * 2.6 * swell + (mid - lp3) * 0.12 * swell * (1 - 0.5 * p);
            v *= 1 + 0.06 * Math.Sin(2 * Math.PI * 0.9 * t);   // the slight beat of two engines
            short s = (short)Math.Max(-32767, Math.Min(32767, v * 0.9 * 32767));
            pcm[2 * i] = (byte)(s & 0xFF); pcm[2 * i + 1] = (byte)((s >> 8) & 0xFF);
        }
        return pcm;
    }

    /// <summary>
    /// A turboprop taxiing past: the prop's buzz - a rich tone near 95 Hz
    /// with its harmonics, beating slowly as the two engines drift - dropping
    /// a few percent in pitch as it passes, over a little of the exhaust.
    /// </summary>
    private static byte[] Turboprop(double seconds)
    {
        var rnd = new Random();
        int n = (int)(Rate * seconds);
        var pcm = new byte[n * 2];
        double phase1 = 0, phase2 = 0, lp = 0;
        double f0 = 88 + rnd.NextDouble() * 14;
        for (int i = 0; i < n; i++)
        {
            double p = i / (double)n, t = i / (double)Rate;
            double f = f0 * (1.03 - 0.06 * p);                 // through the pass, the pitch drops
            phase1 += 2 * Math.PI * f / Rate; phase2 += 2 * Math.PI * (f * 1.012) / Rate;
            double buzz = 0;
            for (int h = 1; h <= 9; h++) buzz += (Math.Sin(h * phase1) + 0.8 * Math.Sin(h * phase2)) / (h * 1.15);
            double white = rnd.NextDouble() * 2 - 1;
            lp += (white - lp) * 0.12;
            double swell = Math.Pow(Math.Sin(Math.PI * p), 1.4);
            double v = (buzz * 0.11 + lp * 0.5) * swell;
            short s = (short)Math.Max(-32767, Math.Min(32767, v * 32767));
            pcm[2 * i] = (byte)(s & 0xFF); pcm[2 * i + 1] = (byte)((s >> 8) & 0xFF);
        }
        return pcm;
    }

    // ---- the announcements -------------------------------------------------------
    private static readonly string[] Airlines = { "United", "American", "Delta", "Northwest", "Continental", "TWA", "Pan Am", "Eastern", "Braniff", "Piedmont", "US Air", "Republic" };
    private static readonly string[] Cities = { "Denver", "Chicago O'Hare", "Dallas Fort Worth", "Atlanta", "Los Angeles", "Minneapolis Saint Paul", "Salt Lake City", "Phoenix", "Seattle", "Boston", "Omaha", "Kansas City", "Saint Louis", "Lincoln", "Cleveland", "Pittsburgh", "Memphis", "Houston", "Newark", "San Francisco" };
    private static readonly string[] Names = { "Johnson", "Williams", "Anderson", "Miller", "Thompson", "Peterson", "Nelson", "Carlson", "Martinez", "Schmidt", "Larsen", "O'Brien", "Kowalski", "Nguyen", "Hoffman", "Bergstrom" };
    private static readonly string[] Templates =
    {
        "Attention passengers. {airline} flight {flight} to {city} is now boarding at gate {gate}.",
        "This is the final boarding call for {airline} flight {flight} to {city}, departing from gate {gate}. All remaining passengers please board at this time.",
        "Paging passenger {name}. Passenger {name}, please come to the {airline} ticket counter.",
        "Attention in the terminal. Please do not leave your baggage unattended. Unattended baggage will be removed by airport security.",
        "{airline} flight {flight} to {city} has been delayed. Please see the agent at gate {gate} for further information.",
        "The white zone is for the immediate loading and unloading of passengers only. There is no stopping in the red zone.",
        "Passengers on {airline} flight {flight} to {city}, we are now boarding rows twenty and higher. Please have your boarding pass ready.",
        "Attention. Would passenger {name}, arriving from {city}, please pick up the white courtesy telephone.",
        "Ladies and gentlemen, {airline} flight {flight} with service to {city} will begin boarding in approximately ten minutes.",
        "{airline} flight {flight} to {city} is now departing from gate {gate}. This is a gate change.",
        "The moving walkway is now ending. Please look down.",
        "Smoking is permitted in designated areas only. Thank you for flying {airline}.",
    };

    private string Compose()
    {
        var t = Templates[_rnd.Next(Templates.Length)];
        return t.Replace("{airline}", Airlines[_rnd.Next(Airlines.Length)])
                .Replace("{flight}", _rnd.Next(101, 2999).ToString())
                .Replace("{city}", Cities[_rnd.Next(Cities.Length)])
                .Replace("{gate}", ((char)('A' + _rnd.Next(0, 4))).ToString() + _rnd.Next(1, 39))
                .Replace("{name}", Names[_rnd.Next(Names.Length)]);
    }

    private void Announce()
    {
        if (!_running || _busy) { if (_running) Schedule(); return; }
        _busy = true;
        var text = Compose();
        // The voice is synthesised off the UI thread (it blocks for a second),
        // then played from it.
        Task.Run(() =>
        {
            byte[] pcm = null;
            try { pcm = Pa(Speak(text)); }
            catch (Exception ex) { Program.LogError("ambience announcement", ex); }
            try
            {
                _owner.BeginInvoke(() =>
                {
                    _busy = false;
                    if (!_running) return;
                    if (pcm != null) PlayPa(pcm);
                    Program.Log("ambience: " + text);
                    Schedule();
                });
            }
            catch { _busy = false; }
        });
    }

    private void Schedule()
    {
        if (!_running) return;
        _nextPa.Interval = _rnd.Next(25000, 60000);
        _nextPa.Start();
    }

    private void PlayPa(byte[] pcm)
    {
        try { _paOut?.Stop(); _paOut?.Dispose(); } catch { }
        var src = new RawSourceWaveStream(new MemoryStream(pcm), new WaveFormat(Rate, 16, 1));
        var vol = new VolumeSampleProvider(src.ToSampleProvider()) { Volume = _volume * 0.9f };
        _paOut = new WaveOutEvent { DesiredLatency = 200 };
        _paOut.Init(vol);
        _paOut.Play();
    }

    /// <summary>One of Windows' voices reading the line, as raw 16-bit mono PCM at our rate.</summary>
    private static short[] Speak(string text)
    {
        using var synth = new SpeechSynthesizer();
        try
        {
            // A woman's voice if there is one - the concourse voice of the era.
            foreach (var v in synth.GetInstalledVoices())
                if (v.Enabled && v.VoiceInfo.Gender == VoiceGender.Female) { synth.SelectVoice(v.VoiceInfo.Name); break; }
        }
        catch { }
        synth.Rate = -1;
        using var ms = new MemoryStream();
        synth.SetOutputToAudioStream(ms, new SpeechAudioFormatInfo(Rate, AudioBitsPerSample.Sixteen, AudioChannel.Mono));
        synth.Speak(text);
        synth.SetOutputToNull();
        var bytes = ms.ToArray();
        var pcm = new short[bytes.Length / 2];
        Buffer.BlockCopy(bytes, 0, pcm, 0, pcm.Length * 2);
        return pcm;
    }

    /// <summary>
    /// The PA: a two-tone chime, then the voice through a ceiling horn - the
    /// band below 300 Hz and above 3 kHz gone, a little overdrive, and the
    /// concourse's echo behind it.
    /// </summary>
    private static byte[] Pa(short[] voice)
    {
        int chimeN = (int)(Rate * 1.1), gapN = (int)(Rate * 0.25), tailN = (int)(Rate * 1.4);
        int n = chimeN + gapN + voice.Length + tailN;
        var x = new double[n];
        // the chime: two notes, the second lower, each ringing down
        for (int i = 0; i < chimeN; i++)
        {
            double t = i / (double)Rate;
            double a = t < 0.5 ? Math.Exp(-t / 0.35) * Math.Sin(2 * Math.PI * 659 * t) : 0;
            double b = t >= 0.45 ? Math.Exp(-(t - 0.45) / 0.4) * Math.Sin(2 * Math.PI * 523 * t) : 0;
            x[i] = 0.35 * (a + b);
        }
        // the voice through the horn
        double lpLow = 0, lp1 = 0, lp2 = 0;
        for (int i = 0; i < voice.Length; i++)
        {
            double s = voice[i] / 32768.0;
            lpLow += (s - lpLow) * 0.08;                  // ~280 Hz: what the horn cannot make
            double hp = s - lpLow;
            lp1 += (hp - lp1) * 0.62; lp2 += (lp1 - lp2) * 0.62;   // ~2.5 kHz: where it stops
            double v = Math.Tanh(lp2 * 3.2) * 0.9;        // the overdrive
            x[chimeN + gapN + i] += v;
        }
        // the hall: two echoes fed back
        int d1 = (int)(Rate * 0.19), d2 = (int)(Rate * 0.41);
        for (int i = 0; i < n; i++)
        {
            double e = 0;
            if (i >= d1) e += 0.30 * x[i - d1];
            if (i >= d2) e += 0.16 * x[i - d2];
            x[i] += e;
        }
        var pcm = new byte[n * 2];
        for (int i = 0; i < n; i++)
        {
            short s = (short)Math.Max(-32767, Math.Min(32767, x[i] * 0.8 * 32767));
            pcm[2 * i] = (byte)(s & 0xFF); pcm[2 * i + 1] = (byte)((s >> 8) & 0xFF);
        }
        return pcm;
    }
}
