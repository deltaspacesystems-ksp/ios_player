namespace Lumen.Audio;

public enum SpatialMode { Off, Stage, Wide, Surround, Hall, Spatial3D }

/// <summary>
/// Stereo → "surround" processing for 48 kHz interleaved float audio:
/// Stage (speaker-friendly width: bass and centre untouched, highs widened, decorrelated air that stays mono-compatible),
/// Wide (mid/side width), Surround (Pro-Logic style decorrelated rear + early reflections),
/// Hall (Freeverb-style room), Spatial3D (binaural virtual speakers with head-shadow and inter-aural delay),
/// plus an optional headphone crossfeed.
/// </summary>
public sealed class SpatialFx
{
    private const int Rate = 48000;

    // ---- parameters (written from the UI thread, read from the audio thread) ----
    public volatile SpatialMode Mode = SpatialMode.Off;
    public float Amount = 0.6f;        // 0..1 how much effect
    public float Width = 1.3f;         // 0..2 stereo width (Wide / Surround / Hall)
    public float Room = 0.6f;          // 0..1 room size (Hall / Spatial3D tail)
    public volatile bool Crossfeed;

    // ---- small DSP building blocks ----
    private sealed class Delay
    {
        private readonly float[] _b; private int _w;
        public Delay(int max) { _b = new float[max + 2]; }
        public void Write(float x) { _b[_w] = x; _w = (_w + 1) % _b.Length; }
        public float Read(int d) { int i = _w - 1 - d; if (i < 0) i += _b.Length; return _b[i]; }
    }

    private sealed class LowPass
    {
        private float _y; private readonly float _a;
        public LowPass(float fc) { _a = 1 - MathF.Exp(-2 * MathF.PI * fc / Rate); }
        public float Run(float x) { _y += _a * (x - _y); return _y; }
        public void Reset() => _y = 0;
    }

    /// <summary>2nd-order Butterworth high-pass (RBJ biquad), steep enough to keep bass out of the "air" path.</summary>
    private sealed class HighPass2
    {
        private readonly float _b0, _b1, _b2, _a1, _a2;
        private float _x1, _x2, _y1, _y2;
        public HighPass2(float fc)
        {
            double w0 = 2 * Math.PI * fc / Rate, cos = Math.Cos(w0), alpha = Math.Sin(w0) / (2 * 0.70710678);
            double a0 = 1 + alpha;
            _b0 = (float)((1 + cos) / 2 / a0); _b1 = (float)(-(1 + cos) / a0); _b2 = _b0;
            _a1 = (float)(-2 * cos / a0); _a2 = (float)((1 - alpha) / a0);
        }
        public float Run(float x)
        {
            float y = _b0 * x + _b1 * _x1 + _b2 * _x2 - _a1 * _y1 - _a2 * _y2;
            _x2 = _x1; _x1 = x; _y2 = _y1; _y1 = y;
            return y;
        }
    }

    private sealed class AllPass
    {
        private readonly float[] _b; private int _i; private readonly float _g;
        public AllPass(int len, float g) { _b = new float[len]; _g = g; }
        public float Run(float x) { float o = _b[_i]; float y = -x + o; _b[_i] = x + o * _g; _i = (_i + 1) % _b.Length; return y; }
    }

    private sealed class Comb
    {
        private readonly float[] _b; private int _i; private float _store;
        public Comb(int len) { _b = new float[len]; }
        public float Run(float x, float feedback, float damp)
        {
            float o = _b[_i];
            _store = o * (1 - damp) + _store * damp;
            _b[_i] = x + _store * feedback;
            _i = (_i + 1) % _b.Length;
            return o;
        }
    }

    private sealed class Reverb
    {
        private static readonly int[] CombLen = { 1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617 };
        private static readonly int[] APLen = { 556, 441, 341, 225 };
        private readonly Comb[][] _combs = new Comb[2][];
        private readonly AllPass[][] _aps = new AllPass[2][];

        public Reverb()
        {
            for (int c = 0; c < 2; c++)
            {
                _combs[c] = CombLen.Select(l => new Comb(Scale(l) + c * Scale(23))).ToArray();
                _aps[c] = APLen.Select(l => new AllPass(Scale(l) + c * Scale(23), 0.5f)).ToArray();
            }
        }

        private static int Scale(int n) => (int)(n * (Rate / 44100.0));

        public (float l, float r) Run(float l, float r, float room, float damp)
        {
            float fb = 0.70f + 0.28f * Math.Clamp(room, 0, 1);
            float input = (l + r) * 0.015f;
            float oL = 0, oR = 0;
            for (int i = 0; i < 8; i++) { oL += _combs[0][i].Run(input, fb, damp); oR += _combs[1][i].Run(input, fb, damp); }
            for (int i = 0; i < 4; i++) { oL = _aps[0][i].Run(oL); oR = _aps[1][i].Run(oR); }
            return (oL, oR);
        }
    }

    // ---- state ----
    private readonly Delay _sideDelay = new(Rate / 20);       // up to 50 ms
    private readonly Delay _monoDelay = new(Rate / 10);       // early reflections
    private readonly LowPass _rearLp = new(7000), _rearLp2 = new(5200);
    private readonly Reverb _hall = new();
    private readonly AllPass[] _decor = { new(113, 0.6f), new(211, 0.6f), new(331, 0.6f) };

    // stage
    private readonly LowPass _stSideLp = new(380), _stAirLp = new(9000);
    private readonly HighPass2 _stMidHp = new(750);
    private readonly AllPass[] _stDecor = { new(137, 0.55f), new(229, 0.55f), new(353, 0.5f), new(487, 0.5f) };
    private readonly AllPass[] _stDecorSide = { new(173, 0.5f), new(283, 0.5f) };
    private readonly Delay _stEr = new(Rate / 20);

    // spatial 3D
    private readonly Delay _dlL = new(64), _dlR = new(64), _dsL = new(64), _dsR = new(64);
    private readonly LowPass _shadowFrontL = new(3200), _shadowFrontR = new(3200), _shadowRearL = new(2400), _shadowRearR = new(2400);
    private readonly AllPass _rearDecorL = new(167, 0.55f), _rearDecorR = new(223, 0.55f);
    private readonly Reverb _room = new();

    // crossfeed
    private readonly Delay _cfL = new(64), _cfR = new(64);
    private readonly LowPass _cfLpL = new(700), _cfLpR = new(700);

    private SpatialMode _lastMode = SpatialMode.Off;

    /// <summary>Processes <paramref name="frames"/> interleaved stereo frames in place.</summary>
    public void Process(Span<float> buf, int frames)
    {
        var mode = Mode;
        bool cf = Crossfeed;
        if (mode == SpatialMode.Off && !cf) { _lastMode = mode; return; }
        float a = Math.Clamp(Amount, 0, 1);
        float width = Math.Clamp(Width, 0, 2);
        float room = Math.Clamp(Room, 0, 1);
        _lastMode = mode;

        for (int i = 0; i < frames; i++)
        {
            float l = buf[i * 2], r = buf[i * 2 + 1];

            switch (mode)
            {
                case SpatialMode.Stage:
                {
                    // 1) mid/side; the low part of the side signal is kept narrow so bass stays solid and centred
                    float m = (l + r) * 0.5f, s = (l - r) * 0.5f;
                    float sLo = _stSideLp.Run(s), sHi = s - sLo;
                    float w = 1 + (width - 1) * a;                                  // width target blended by Amount
                    float side = sLo * (1 - 0.6f * a) + sHi * w;
                    // 2) "air": a decorrelated copy of the side highs gives extra depth without changing the mono sum
                    float dec = sHi;
                    for (int k = 0; k < _stDecorSide.Length; k++) dec = _stDecorSide[k].Run(dec);
                    side += dec * 0.30f * a;
                    // 3) pseudo-stereo for near-mono material: decorrelated mid highs injected as side (cancels in mono)
                    float mHi = _stMidHp.Run(m);
                    float pm = mHi;
                    for (int k = 0; k < _stDecor.Length; k++) pm = _stDecor[k].Run(pm);
                    side += _stAirLp.Run(pm) * 0.26f * a;
                    // 4) a few quiet, symmetric early reflections of the mid for a sense of room
                    _stEr.Write(m);
                    float er = (_stEr.Read((int)(0.011 * Rate)) * 0.15f + _stEr.Read((int)(0.019 * Rate)) * 0.10f + _stEr.Read((int)(0.031 * Rate)) * 0.07f) * a * (0.4f + 0.6f * room);
                    // 5) keep loudness constant: the wider we go the more energy the side adds
                    float comp = 1f / MathF.Sqrt(1 + 0.10f * a * (w * w - 1) + 0.05f * a);
                    l = (m + er + side) * comp;
                    r = (m + er - side) * comp;
                    break;
                }
                case SpatialMode.Wide:
                {
                    float m = (l + r) * 0.5f;
                    // the width slider is the target, amount blends between the original (1.0) and that width
                    float w = 1 + (width - 1) * a;
                    float s = (l - r) * 0.5f * w;
                    l = m + s; r = m - s;
                    break;
                }
                case SpatialMode.Surround:
                {
                    float m = (l + r) * 0.5f, s = (l - r) * 0.5f;
                    _sideDelay.Write(s);
                    // decorrelated "rear" derived from the side signal (delayed ~14 ms, band-limited, phase-inverted per side)
                    float rear = _rearLp.Run(_rearLp2.Run(_sideDelay.Read((int)(0.014 * Rate))));
                    _monoDelay.Write(m);
                    float early = _monoDelay.Read((int)(0.017 * Rate)) * 0.32f + _monoDelay.Read((int)(0.029 * Rate)) * 0.22f + _monoDelay.Read((int)(0.043 * Rate)) * 0.14f;
                    float w = 1 + (width - 1) * a;
                    float sw = s * w;
                    float rl = rear * 1.6f * a, rr = -rear * 1.6f * a;
                    l = m + sw + rl + early * a * 0.6f;
                    r = m - sw + rr + early * a * 0.6f;
                    break;
                }
                case SpatialMode.Hall:
                {
                    var (wl, wr) = _hall.Run(l, r, room, 0.35f);
                    float m = (l + r) * 0.5f, s = (l - r) * 0.5f * (1 + (width - 1) * a);
                    float wet = 3.0f * a;
                    l = m + s + wl * wet; r = m - s + wr * wet;
                    break;
                }
                case SpatialMode.Spatial3D:
                {
                    float m = (l + r) * 0.5f, s = (l - r) * 0.5f;
                    // front virtual speakers at ±30°: each reaches the far ear later (0.27 ms), duller and quieter
                    _dlL.Write(l); _dlR.Write(r);
                    float farFromL = _shadowFrontR.Run(_dlL.Read(13)) * 0.45f;     // left speaker → right ear
                    float farFromR = _shadowFrontL.Run(_dlR.Read(13)) * 0.45f;     // right speaker → left ear
                    float frontL = l * 0.85f + farFromR;
                    float frontR = r * 0.85f + farFromL;
                    // rear virtual speakers at ±110° fed by the decorrelated side signal + a little mono (ambience)
                    float dec = s;
                    for (int k = 0; k < _decor.Length; k++) dec = _decor[k].Run(dec);
                    float rearLsrc = _rearDecorL.Run(dec + m * 0.18f);
                    float rearRsrc = _rearDecorR.Run(-dec + m * 0.18f);
                    _dsL.Write(rearLsrc); _dsR.Write(rearRsrc);
                    float rearLnear = rearLsrc * 0.75f;                               // near ear (left)
                    float rearLfar = _shadowRearR.Run(_dsL.Read(24)) * 0.40f;         // → right ear, ~0.5 ms later, head-shadowed
                    float rearRnear = rearRsrc * 0.75f;
                    float rearRfar = _shadowRearL.Run(_dsR.Read(24)) * 0.40f;
                    float pl = frontL + rearLnear + rearRfar;
                    float pr = frontR + rearRnear + rearLfar;
                    var (wl, wr) = _room.Run(l, r, 0.4f + 0.5f * room, 0.45f);
                    pl += wl * 1.6f * a; pr += wr * 1.6f * a;
                    l = l * (1 - a) + pl * a;
                    r = r * (1 - a) + pr * a;
                    break;
                }
            }

            if (cf)
            {
                // headphone crossfeed: a low-passed, slightly delayed, quieter copy of each channel in the other ear
                _cfL.Write(l); _cfR.Write(r);
                float xl = _cfLpL.Run(_cfL.Read(13)) * 0.30f;
                float xr = _cfLpR.Run(_cfR.Read(13)) * 0.30f;
                float k = 1 / 1.25f;
                l = (l + xr) * k; r = (r + xl) * k;
            }

            buf[i * 2] = l;
            buf[i * 2 + 1] = r;
        }
    }
}
