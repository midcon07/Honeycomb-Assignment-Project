using System.Speech.AudioFormat;
using System.Speech.Synthesis;
using System.Text;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace HoneycombLauncher;

/// <summary>
/// The airport under the printer (Mark, 2026-09-12: "random airport
/// ambience - 'now boarding', that kind of thing"; then "the wind sound in
/// the background isn't needed - drop it. Maybe *faint* jet (and the
/// occasional turboprop) sounds in the background, but that's it"). So:
/// nothing continuous. Every minute or so a jet at a distance, now and then
/// a turboprop, both faint and synthesised on the spot; and every half-minute
/// or so a gate announcement in one of Windows' own voices - several
/// announcers, women mostly, a man now and then - run through a PA: the
/// two-tone chime, the tinny band of a ceiling horn, the hall's echo.
///
/// The flights are real when a plan is loaded: the departures from the
/// plan's origin around its departure time (Departures.cs). Without a plan,
/// invented flights on the airlines of the era. Flight numbers are read as
/// digits - "one two four five", never "twelve forty-five" (Mark).
/// NAudio mixes it all under the printer's own sounds.
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
    private List<Departures.Flight> _flights = new();

    public Ambience(Control owner) { _owner = owner; }

    /// <summary>Overall level, 0..1. Aircraft stay faint; announcements carry.</summary>
    public float Volume { get => _volume; set => _volume = Math.Max(0, Math.Min(1, value)); }

    /// <summary>The real departures to announce, when there are any.</summary>
    public void SetFlights(List<Departures.Flight> flights) { _flights = flights ?? new List<Departures.Flight>(); }

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

    // Lines about a flight. {airline} {flight} {city} {gate} are filled in;
    // a real flight without a city or a gate gets a line that needs neither.
    private static readonly string[] FlightLines =
    {
        "Attention passengers. {airline} flight {flight} to {city} is now boarding at gate {gate}.",
        "This is the final boarding call for {airline} flight {flight} to {city}, departing from gate {gate}. All remaining passengers please board at this time.",
        "{airline} flight {flight} to {city} has been delayed. Please see the agent at gate {gate} for further information.",
        "Passengers on {airline} flight {flight} to {city}, we are now boarding rows twenty and higher. Please have your boarding pass ready.",
        "Ladies and gentlemen, {airline} flight {flight} with service to {city} will begin boarding in approximately ten minutes.",
        "{airline} flight {flight} to {city} is now departing from gate {gate}. This is a gate change.",
    };
    private static readonly string[] FlightLinesNoGate =
    {
        "Attention passengers. {airline} flight {flight} to {city} is now boarding.",
        "This is the final boarding call for {airline} flight {flight} to {city}. All remaining passengers please board at this time.",
        "Passengers on {airline} flight {flight} to {city}, we are now boarding rows twenty and higher. Please have your boarding pass ready.",
        "Ladies and gentlemen, {airline} flight {flight} with service to {city} will begin boarding in approximately ten minutes.",
    };
    private static readonly string[] FlightLinesNoCity =
    {
        "Attention passengers. {airline} flight {flight} is now boarding at gate {gate}.",
        "This is the final boarding call for {airline} flight {flight}, departing from gate {gate}.",
        "{airline} flight {flight} is now boarding all rows. Please have your boarding pass ready.",
    };
    private static readonly string[] Others =
    {
        "Paging passenger {name}. Passenger {name}, please come to the {airline} ticket counter.",
        "Attention in the terminal. Please do not leave your baggage unattended. Unattended baggage will be removed by airport security.",
        "The white zone is for the immediate loading and unloading of passengers only. There is no stopping in the red zone.",
        "Attention. Would passenger {name}, arriving from {city}, please pick up the white courtesy telephone.",
        "The moving walkway is now ending. Please look down.",
        "Smoking is permitted in designated areas only. Thank you for flying {airline}.",
    };

    /// <summary>The line, in SSML, so flight numbers are read digit by digit; and the plain words for the log.</summary>
    private string Compose(out string plain)
    {
        string airline, flight, city, gate, line;
        bool real = _flights.Count > 0 && _rnd.NextDouble() < 0.75;
        bool other = !real && _rnd.NextDouble() < 0.35;
        if (real)
        {
            var f = _flights[_rnd.Next(_flights.Count)];
            airline = f.Airline; flight = f.Number; city = f.City; gate = f.Gate;
            var pool = city == null ? FlightLinesNoCity : gate == null ? FlightLinesNoGate : FlightLines;
            if (city == null && gate == null) pool = new[] { "{airline} flight {flight} is now boarding all rows. Please have your boarding pass ready." };
            line = pool[_rnd.Next(pool.Length)];
        }
        else
        {
            airline = Airlines[_rnd.Next(Airlines.Length)];
            flight = _rnd.Next(101, 2999).ToString();
            city = Cities[_rnd.Next(Cities.Length)];
            gate = ((char)('A' + _rnd.Next(0, 4))).ToString() + _rnd.Next(1, 39);
            line = other ? Others[_rnd.Next(Others.Length)] : FlightLines[_rnd.Next(FlightLines.Length)];
        }
        var name = Names[_rnd.Next(Names.Length)];
        plain = line.Replace("{airline}", airline).Replace("{flight}", flight).Replace("{city}", city ?? "").Replace("{gate}", gate ?? "").Replace("{name}", name);
        // SSML: the flight number as characters ("one two four five"); the gate's letter apart from its number ("B twelve").
        string Esc(string s) => System.Security.SecurityElement.Escape(s ?? "");
        var flightSsml = "<say-as interpret-as=\"characters\">" + Esc(flight) + "</say-as>";
        var gateSsml = gate == null ? "" : Esc(gate.Length > 1 && char.IsLetter(gate[0]) ? gate[0] + " " + gate.Substring(1) : gate);
        return Esc(line).Replace("{airline}", Esc(airline)).Replace("{flight}", flightSsml).Replace("{city}", Esc(city ?? "")).Replace("{gate}", gateSsml).Replace("{name}", Esc(name));
    }

    private void Announce()
    {
        if (!_running || _busy) { if (_running) Schedule(); return; }
        _busy = true;
        var ssml = Compose(out var plain);
        // The voice is synthesised off the UI thread (it blocks for a second),
        // then played from it.
        Task.Run(() =>
        {
            byte[] pcm = null; string who = "";
            try { pcm = Pa(Speak(ssml, out who)); }
            catch (Exception ex) { Program.LogError("ambience announcement", ex); }
            try
            {
                _owner.BeginInvoke(() =>
                {
                    _busy = false;
                    if (!_running) return;
                    if (pcm != null) PlayPa(pcm);
                    Program.Log("ambience (" + who + "): " + plain);
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
        var vol = new VolumeSampleProvider(src.ToSampleProvider()) { Volume = _volume * 0.36f };
        _paOut = new WaveOutEvent { DesiredLatency = 200 };
        _paOut.Init(vol);
        _paOut.Play();
    }

    // ---- the announcers -----------------------------------------------------------
    // Several people share the microphone: every installed voice, women four
    // times in five (the concourse voice of the era), each in three settings
    // of pitch and pace, so one Windows voice makes more than one announcer.
    // Chosen at random per announcement.
    private sealed class Announcer { public string Voice; public string Gender; public int Pitch; public int Rate; }
    private static List<Announcer> _announcers;

    private static List<Announcer> Announcers()
    {
        if (_announcers != null) return _announcers;
        var list = new List<Announcer>();
        try
        {
            using var synth = new SpeechSynthesizer();
            foreach (var v in synth.GetInstalledVoices())
            {
                if (!v.Enabled) continue;
                var g = v.VoiceInfo.Gender == VoiceGender.Male ? "m" : "f";
                foreach (var (p, r) in new[] { (0, -1), (-6, -2), (5, 0) })
                    list.Add(new Announcer { Voice = v.VoiceInfo.Name, Gender = g, Pitch = p, Rate = r });
            }
        }
        catch { }
        _announcers = list;
        return list;
    }

    private Announcer Pick()
    {
        var all = Announcers();
        if (all.Count == 0) return null;
        var women = all.Where(a => a.Gender == "f").ToList();
        var men = all.Where(a => a.Gender == "m").ToList();
        var pool = (women.Count > 0 && (men.Count == 0 || _rnd.NextDouble() < 0.8)) ? women : (men.Count > 0 ? men : all);
        return pool[_rnd.Next(pool.Count)];
    }

    /// <summary>One of the announcers reading the line, as raw 16-bit mono PCM at our rate.</summary>
    private short[] Speak(string ssmlBody, out string who)
    {
        var a = Pick();
        who = a == null ? "default voice" : a.Voice + (a.Pitch == 0 ? "" : a.Pitch > 0 ? " (higher)" : " (lower)");
        using var synth = new SpeechSynthesizer();
        try { if (a != null) synth.SelectVoice(a.Voice); } catch { }
        synth.Rate = a?.Rate ?? -1;
        using var ms = new MemoryStream();
        synth.SetOutputToAudioStream(ms, new SpeechAudioFormatInfo(Rate, AudioBitsPerSample.Sixteen, AudioChannel.Mono));
        var sb = new StringBuilder();
        sb.Append("<speak version=\"1.0\" xmlns=\"http://www.w3.org/2001/10/synthesis\" xml:lang=\"en-US\">");
        sb.Append("<prosody pitch=\"").Append(a == null ? 0 : a.Pitch).Append("%\">").Append(ssmlBody).Append("</prosody>");
        sb.Append("</speak>");
        synth.SpeakSsml(sb.ToString());
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
