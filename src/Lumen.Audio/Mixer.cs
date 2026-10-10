using Lumen.Core;
using NAudio.Dsp;
using NAudio.Wave;

namespace Lumen.Audio;

public enum FadeCurve { EqualPower, Linear, SCurve }

public static class Curves
{
    public static (float outG, float inG) Gains(FadeCurve c, double p)
    {
        p = Math.Clamp(p, 0, 1);
        switch (c)
        {
            case FadeCurve.Linear: return ((float)(1 - p), (float)p);
            case FadeCurve.SCurve:
                double s = p * p * (3 - 2 * p);
                return ((float)(1 - s), (float)s);
            default: return ((float)Math.Cos(p * Math.PI / 2), (float)Math.Sin(p * Math.PI / 2));
        }
    }
}

/// <summary>
/// Sample provider that renders the active deck, performs equal-power crossfades into the next deck,
/// gapless hand-over at end of stream, then applies EQ, volume and feeds the spectrum tap.
/// </summary>
public sealed class Mixer : ISampleProvider
{
    private sealed class Fade
    {
        public required Deck Out, In;
        public int Total, Pos;
        public FadeCurve Curve;
    }

    private readonly object _gate = new();
    private Deck? _active, _next;
    private Fade? _fade;
    private float[] _tmpA = new float[8192], _tmpB = new float[8192];

    public WaveFormat WaveFormat { get; } = WaveFormat.CreateIeeeFloatWaveFormat(Deck.Rate, Deck.Channels);
    public volatile bool Playing;
    public float Volume { get; set; } = 1f;

    /// <summary>Raised when a different deck becomes the active one (gapless hand-over or finished crossfade).</summary>
    public event Action<Deck>? Advanced;
    /// <summary>Raised when the active deck ran dry and nothing follows.</summary>
    public event Action? Ended;

    // ---- EQ ----
    private static readonly float[] EqFreqs = { 32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000 };
    private readonly BiQuadFilter[,] _eq = new BiQuadFilter[2, 10];
    private volatile bool _eqOn;
    private float _preamp = 1f;

    public Mixer() { SetEq(new float[10], 0); }

    public void SetEq(float[] gainsDb, float preampDb)
    {
        bool any = false;
        for (int c = 0; c < 2; c++)
            for (int b = 0; b < 10; b++)
            {
                float g = b < gainsDb.Length ? gainsDb[b] : 0;
                if (Math.Abs(g) > 0.01f) any = true;
                _eq[c, b] = BiQuadFilter.PeakingEQ(Deck.Rate, EqFreqs[b], 1.0f, g);
            }
        _preamp = MathF.Pow(10, preampDb / 20f);
        _eqOn = any || Math.Abs(preampDb) > 0.01f;
    }

    // ---- spectrum tap (mono, last N samples) ----
    private readonly float[] _tap = new float[4096];
    private int _tapPos;
    private readonly object _tapLock = new();

    public void CopyTap(Span<float> dst)
    {
        lock (_tapLock)
        {
            int n = dst.Length;
            int start = ((_tapPos - n) % _tap.Length + _tap.Length) % _tap.Length;
            int first = Math.Min(n, _tap.Length - start);
            _tap.AsSpan(start, first).CopyTo(dst);
            if (n > first) _tap.AsSpan(0, n - first).CopyTo(dst[first..]);
        }
    }

    // ---- state accessors ----
    public Deck? Active { get { lock (_gate) return _active; } }
    public Deck? Next { get { lock (_gate) return _next; } }
    public bool Fading { get { lock (_gate) return _fade != null; } }

    /// <summary>Replaces everything with a new active deck (hard cut).</summary>
    public void SetActive(Deck? deck)
    {
        List<Deck> retire = new();
        lock (_gate)
        {
            if (_active != null) retire.Add(_active);
            if (_next != null) retire.Add(_next);
            if (_fade != null) { retire.Add(_fade.Out); retire.Add(_fade.In); _fade = null; }
            _active = deck;
            _next = null;
        }
        Retire(retire.Where(d => d != deck));
    }

    public void SetNext(Deck? deck)
    {
        Deck? old;
        lock (_gate) { old = _next; _next = deck; }
        if (old != null && old != deck) Retire(new[] { old });
    }

    /// <summary>Starts crossfading from the active deck into the prepared next deck.</summary>
    public bool StartFade(double seconds, FadeCurve curve)
    {
        lock (_gate)
        {
            if (_fade != null || _active == null || _next == null) return false;
            int total = Math.Max(64, (int)(seconds * Deck.Rate));
            _fade = new Fade { Out = _active, In = _next, Total = total, Curve = curve };
            _next = null;
            return true;
        }
    }

    public void CancelFade()
    {
        Deck? drop = null;
        lock (_gate)
        {
            if (_fade == null) return;
            // keep the incoming track (it is the one the user sees), drop the outgoing one
            drop = _fade.Out;
            _active = _fade.In;
            _fade = null;
        }
        if (drop != null) Retire(new[] { drop });
    }

    private static void Retire(IEnumerable<Deck> decks)
    {
        foreach (var d in decks) ThreadPool.QueueUserWorkItem(_ => d.Dispose());
    }

    private void Ensure(int frames)
    {
        int need = frames * Deck.Channels;
        if (_tmpA.Length < need) { _tmpA = new float[need]; _tmpB = new float[need]; }
    }

    public int Read(Span<float> buffer)
    {
        int count = buffer.Length;
        int frames = count / Deck.Channels;
        buffer.Clear();
        if (!Playing) return count;

        Deck? advanced = null;
        bool ended = false;
        List<Deck>? retire = null;

        lock (_gate)
        {
            int done = 0;
            int guard = 0;
            while (done < frames && guard++ < 8)
            {
                int chunk = frames - done;
                if (_fade is { } f)
                {
                    chunk = Math.Min(chunk, f.Total - f.Pos);
                    Ensure(chunk);
                    Array.Clear(_tmpA, 0, chunk * 2);
                    Array.Clear(_tmpB, 0, chunk * 2);
                    f.Out.Read(_tmpA, chunk);
                    f.In.Read(_tmpB, chunk);
                    float ga = f.Out.Gain, gb = f.In.Gain;
                    int baseIdx = done * 2;
                    for (int i = 0; i < chunk; i++)
                    {
                        var (go, gi) = Curves.Gains(f.Curve, (f.Pos + i) / (double)f.Total);
                        buffer[baseIdx + i * 2] = _tmpA[i * 2] * go * ga + _tmpB[i * 2] * gi * gb;
                        buffer[baseIdx + i * 2 + 1] = _tmpA[i * 2 + 1] * go * ga + _tmpB[i * 2 + 1] * gi * gb;
                    }
                    f.Pos += chunk;
                    done += chunk;
                    if (f.Pos >= f.Total)
                    {
                        (retire ??= new()).Add(f.Out);
                        _active = f.In;
                        _fade = null;
                        advanced = _active;
                    }
                }
                else if (_active != null)
                {
                    var span = buffer.Slice(done * 2, chunk * 2);
                    int got = _active.Read(span, chunk);
                    float g = _active.Gain;
                    if (Math.Abs(g - 1f) > 0.0001f) for (int i = 0; i < got * 2; i++) span[i] *= g;
                    done += got;
                    if (got < chunk)
                    {
                        if (_active.Drained)
                        {
                            if (_next != null)
                            {
                                (retire ??= new()).Add(_active);
                                _active = _next;
                                _next = null;
                                advanced = _active;
                                continue;                          // keep filling this buffer from the new deck (gapless)
                            }
                            ended = true;
                        }
                        break;
                    }
                }
                else break;
            }
        }

        if (retire != null) Retire(retire);
        Dsp(buffer, frames);
        if (advanced != null) Advanced?.Invoke(advanced);
        if (ended) Ended?.Invoke();
        return count;
    }

    private void Dsp(Span<float> buffer, int frames)
    {
        bool eq = _eqOn;
        float vol = Volume, pre = _preamp;
        for (int i = 0; i < frames; i++)
        {
            for (int c = 0; c < 2; c++)
            {
                int idx = i * 2 + c;
                float s = buffer[idx];
                if (eq)
                {
                    s *= pre;
                    for (int b = 0; b < 10; b++) s = _eq[c, b].Transform(s);
                }
                buffer[idx] = s;
            }
        }
        // spectrum tap sits BEFORE the master volume so the visualizer does not shrink with the volume slider
        lock (_tapLock)
        {
            for (int i = 0; i < frames; i++)
            {
                _tap[_tapPos] = (buffer[i * 2] + buffer[i * 2 + 1]) * 0.5f;
                _tapPos = (_tapPos + 1) % _tap.Length;
            }
        }
        for (int i = 0; i < frames * 2; i++)
        {
            float s = buffer[i] * vol;
            // gentle limiter so EQ boosts never hard-clip
            if (s > 0.98f || s < -0.98f) s = MathF.Tanh(s);
            buffer[i] = s;
        }
    }
}
