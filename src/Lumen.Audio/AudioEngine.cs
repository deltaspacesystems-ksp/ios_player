using Lumen.Core;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace Lumen.Audio;

public enum RepeatMode { Off, All, One }

public sealed class EngineSettings
{
    public double CrossfadeSeconds { get; set; } = 6;
    public FadeCurve Curve { get; set; } = FadeCurve.EqualPower;
    public bool CrossfadeOnSkip { get; set; }
    public double SkipFadeSeconds { get; set; } = 2.5;
    public bool UseReplayGain { get; set; } = true;
    public float Volume { get; set; } = 0.8f;
}

/// <summary>Queue + transport on top of <see cref="Mixer"/> and a WASAPI output.</summary>
public sealed class AudioEngine : IDisposable
{
    private readonly object _q = new();
    private readonly System.Threading.Timer _tick;
    private WasapiPlayer? _out;
    private List<Track> _queue = new();
    private List<Track> _original = new();
    private int _index = -1;
    private Track? _preparing;

    public Mixer Mixer { get; } = new();
    public EngineSettings Settings { get; } = new();
    public RepeatMode Repeat { get; set; }
    public bool Shuffle { get; private set; }

    public IReadOnlyList<Track> Queue { get { lock (_q) return _queue.ToArray(); } }
    public int Index { get { lock (_q) return _index; } }
    public Track? Current { get { lock (_q) return _index >= 0 && _index < _queue.Count ? _queue[_index] : null; } }
    public bool IsPlaying => Mixer.Playing;
    public double Position => Mixer.Active?.Position ?? 0;
    public double Duration
    {
        get
        {
            var d = Mixer.Active;
            if (d != null && d.Duration > 0) return d.Duration;
            return Current?.Duration ?? 0;
        }
    }

    public event Action<Track?, int>? TrackChanged;
    public event Action? StateChanged;
    public event Action<string>? Error;

    public AudioEngine()
    {
        Mixer.Advanced += OnAdvanced;
        Mixer.Ended += OnEnded;
        _tick = new System.Threading.Timer(_ => Tick(), null, 100, 30);
    }

    // ------------------------------------------------------------ transport

    public void SetQueue(IReadOnlyList<Track> tracks, int start, bool play = true, bool shuffle = false)
    {
        if (tracks.Count == 0) return;
        lock (_q)
        {
            _original = tracks.ToList();
            Shuffle = shuffle;
            if (shuffle)
            {
                var first = tracks[Math.Clamp(start, 0, tracks.Count - 1)];
                var rest = tracks.Where(t => !ReferenceEquals(t, first)).OrderBy(_ => Random.Shared.Next()).ToList();
                _queue = new List<Track> { first }; _queue.AddRange(rest);
                start = 0;
            }
            else _queue = tracks.ToList();
        }
        PlayIndex(start, play);
    }

    public void ToggleShuffle()
    {
        lock (_q)
        {
            var cur = _index >= 0 && _index < _queue.Count ? _queue[_index] : null;
            Shuffle = !Shuffle;
            if (Shuffle && cur != null)
            {
                var rest = _queue.Where(t => !ReferenceEquals(t, cur)).OrderBy(_ => Random.Shared.Next()).ToList();
                _queue = new List<Track> { cur }; _queue.AddRange(rest);
                _index = 0;
            }
            else if (!Shuffle)
            {
                _queue = _original.ToList();
                _index = cur != null ? Math.Max(0, _queue.IndexOf(cur)) : 0;
            }
        }
        Mixer.SetNext(null);
        _preparing = null;
        StateChanged?.Invoke();
    }

    public void PlayIndex(int index, bool play = true, double startSeconds = 0, int depth = 0)
    {
        Track t;
        lock (_q)
        {
            if (index < 0 || index >= _queue.Count) return;
            _index = index;
            t = _queue[index];
        }
        var deck = MakeDeck(t, startSeconds);
        Mixer.SetActive(deck);
        _preparing = null;
        Log.I("engine", $"play {t}");
        if (play) Resume(); else StateChanged?.Invoke();
        TrackChanged?.Invoke(t, index);
        if (deck.Failed && depth < 5) { Error?.Invoke($"Can't play {t.Display}"); Next(); }
    }

    private Deck MakeDeck(Track t, double start = 0)
    {
        float gain = 1f;
        if (Settings.UseReplayGain && t.ReplayGainDb is double rg) gain = (float)Math.Clamp(Math.Pow(10, rg / 20), 0.1, 2.0);
        return new Deck(t.Path, start) { Gain = gain, Track = t };
    }

    public void EnsureDevice()
    {
        if (_out != null) return;
        try
        {
            _out = new WasapiPlayerBuilder().WithSharedMode().WithLatency(80).WithEventSync().Build();
            _out.Init(new SampleToWaveProvider(Mixer));
            Log.I("engine", $"output: {_out.DeviceFriendlyName}, latency {_out.LatencyMilliseconds} ms, mix {_out.DeviceMixFormat}");
            _out.Play();
        }
        catch (Exception e)
        {
            Log.E("engine", $"audio device failed: {e.Message}");
            Error?.Invoke("Audio device error: " + e.Message);
            _out?.Dispose(); _out = null;
        }
    }

    public void Resume()
    {
        if (Mixer.Active == null && Current != null) PlayIndex(Index, false);
        EnsureDevice();
        Mixer.Volume = Settings.Volume;
        Mixer.Playing = true;
        StateChanged?.Invoke();
    }

    public void Pause() { Mixer.Playing = false; StateChanged?.Invoke(); }
    public void Toggle() { if (IsPlaying) Pause(); else Resume(); }

    public void SetVolume(float v) { Settings.Volume = Math.Clamp(v, 0, 1); Mixer.Volume = Settings.Volume; }

    public void Seek(double seconds)
    {
        Mixer.CancelFade();
        var d = Mixer.Active;
        if (d == null) return;
        d.Seek(Math.Clamp(seconds, 0, Math.Max(0, Duration - 0.1)));
        StateChanged?.Invoke();
    }

    public void Next()
    {
        int n = NextIndex(userSkip: true);
        if (n < 0) { Pause(); return; }
        if (Settings.CrossfadeOnSkip && IsPlaying && TryFadeTo(n, Settings.SkipFadeSeconds)) return;
        PlayIndex(n, true);
    }

    public void Previous()
    {
        if (Position > 3) { Seek(0); return; }
        int i = Index;
        PlayIndex(i > 0 ? i - 1 : 0, IsPlaying || true);
    }

    private bool TryFadeTo(int index, double seconds)
    {
        Track t;
        lock (_q) { if (index < 0 || index >= _queue.Count) return false; t = _queue[index]; }
        Mixer.CancelFade();
        var deck = MakeDeck(t);
        Mixer.SetNext(deck);
        // wait briefly for the decoder to prefill so the fade is smooth
        for (int i = 0; i < 40 && !deck.IsReady; i++) Thread.Sleep(5);
        if (!Mixer.StartFade(seconds, Settings.Curve)) { Mixer.SetNext(null); return false; }
        lock (_q) _index = index;
        _preparing = null;
        TrackChanged?.Invoke(t, index);
        return true;
    }

    // ------------------------------------------------------------ queue editing

    public void PlayNext(Track t) { lock (_q) { _queue.Insert(Math.Min(_queue.Count, _index + 1), t); _original.Add(t); } Mixer.SetNext(null); _preparing = null; StateChanged?.Invoke(); }
    public void Enqueue(Track t) { lock (_q) { _queue.Add(t); _original.Add(t); } StateChanged?.Invoke(); }

    private int NextIndex(bool userSkip)
    {
        lock (_q)
        {
            if (_queue.Count == 0) return -1;
            if (Repeat == RepeatMode.One && !userSkip) return _index;
            if (_index + 1 < _queue.Count) return _index + 1;
            return Repeat == RepeatMode.All || userSkip && Repeat != RepeatMode.Off ? 0 : -1;
        }
    }

    // ------------------------------------------------------------ timer: prepare next, start fades

    private void Tick()
    {
        try
        {
            var active = Mixer.Active;
            if (active == null || !Mixer.Playing) return;
            double dur = Duration;
            if (dur <= 0) return;
            double remaining = dur - active.Position;

            int n = NextIndex(userSkip: false);
            if (n < 0) return;

            if (Mixer.Next == null && !Mixer.Fading && remaining < 14)
            {
                Track t;
                lock (_q) t = _queue[n];
                if (!ReferenceEquals(_preparing, t))
                {
                    _preparing = t;
                    Mixer.SetNext(MakeDeck(t));
                    Log.D("engine", $"prepared next: {t}");
                }
            }

            double fade = Settings.CrossfadeSeconds;
            if (fade > 0.05 && !Mixer.Fading && Mixer.Next is { } next && remaining <= Math.Min(fade, dur * 0.45) && next.IsReady)
            {
                if (Mixer.StartFade(Math.Max(0.1, remaining), Settings.Curve))
                {
                    Track t;
                    lock (_q) { _index = n; t = _queue[n]; }
                    _preparing = null;
                    Log.I("engine", $"crossfade → {t} ({remaining:0.0}s)");
                    TrackChanged?.Invoke(t, n);
                }
            }
        }
        catch (Exception e) { Log.E("engine", $"tick: {e.Message}"); }
    }

    private void OnAdvanced(Deck deck)
    {
        // gapless hand-over or finished crossfade; for fades the index was already updated
        Track? t = deck.Track;
        int idx = -1;
        lock (_q)
        {
            if (t != null)
            {
                int i = _queue.IndexOf(t);
                if (i >= 0) { if (_index != i) { _index = i; idx = i; } }
            }
        }
        if (idx >= 0) { Log.I("engine", $"gapless → {t}"); TrackChanged?.Invoke(t, idx); }
        _preparing = null;
    }

    private void OnEnded()
    {
        Mixer.Playing = false;
        Log.I("engine", "queue ended");
        lock (_q) { _index = 0; }
        ThreadPool.QueueUserWorkItem(_ => { PlayIndex(0, false); });
    }

    public void Dispose()
    {
        _tick.Dispose();
        Mixer.Playing = false;
        _out?.Stop();
        _out?.Dispose();
        Mixer.SetActive(null);
    }
}
