namespace Lumen.Core;

/// <summary>Radix-2 FFT + log-spaced band mapping, used by the spectrum visualizer.</summary>
public sealed class SpectrumAnalyzer
{
    private readonly int _n;
    private readonly float[] _window;
    private readonly float[] _re, _im;
    private int[] _edges = Array.Empty<int>();
    private float[] _bars = Array.Empty<float>();
    private int _bands;
    private double _rate;

    public SpectrumAnalyzer(int fftSize = 2048)
    {
        _n = fftSize;
        _window = new float[_n];
        for (int i = 0; i < _n; i++) _window[i] = 0.5f * (1 - MathF.Cos(2 * MathF.PI * i / (_n - 1)));
        _re = new float[_n];
        _im = new float[_n];
    }

    public int Size => _n;

    private void BuildEdges(int bands, double rate)
    {
        _bands = bands; _rate = rate;
        _edges = new int[bands + 1];
        double binHz = rate / _n;
        double lo = 50, hi = Math.Min(16000, rate / 2 * 0.95);
        int prev = 0;
        for (int i = 0; i <= bands; i++)
        {
            double f = lo * Math.Pow(hi / lo, (double)i / bands);
            int b = (int)(f / binHz);
            if (i > 0 && b <= prev) b = prev + 1;
            _edges[i] = Math.Min(b, _n / 2);
            prev = _edges[i];
        }
        _bars = new float[bands];
    }

    /// <summary>Computes smoothed bar heights (0..1) from the latest <c>Size</c> mono samples.</summary>
    public float[] Compute(ReadOnlySpan<float> mono, int bands, double rate, float gain, double dt)
    {
        if (bands != _bands || Math.Abs(rate - _rate) > 1) BuildEdges(bands, rate);
        for (int i = 0; i < _n; i++) { _re[i] = mono[i] * _window[i]; _im[i] = 0; }
        Transform(_re, _im);
        float ka = MathF.Pow(0.35f, (float)(dt * 32)), kd = MathF.Pow(0.88f, (float)(dt * 32));
        for (int b = 0; b < bands; b++)
        {
            float m = 0;
            int a = _edges[b], z = Math.Max(_edges[b + 1], a + 1);
            for (int k = a; k < Math.Min(z, _n / 2); k++) m = Math.Max(m, _re[k] * _re[k] + _im[k] * _im[k]);
            float amp = MathF.Sqrt(m) / _n * 2;
            float db = 20 * MathF.Log10(amp + 1e-7f);
            float tilt = (float)b / bands * 12;
            float v = Math.Clamp(Math.Max(0, (db + 68 + tilt) / 58) * gain, 0, 1);
            _bars[b] = v > _bars[b] ? _bars[b] * ka + v * (1 - ka) : _bars[b] * kd + v * (1 - kd);
        }
        return _bars;
    }

    private static void Transform(float[] re, float[] im)
    {
        int n = re.Length;
        for (int i = 1, j = 0; i < n; i++)
        {
            int bit = n >> 1;
            for (; (j & bit) != 0; bit >>= 1) j ^= bit;
            j ^= bit;
            if (i < j) { (re[i], re[j]) = (re[j], re[i]); (im[i], im[j]) = (im[j], im[i]); }
        }
        for (int len = 2; len <= n; len <<= 1)
        {
            double ang = -2 * Math.PI / len;
            float wlr = (float)Math.Cos(ang), wli = (float)Math.Sin(ang);
            for (int i = 0; i < n; i += len)
            {
                float wr = 1, wi = 0;
                for (int k = 0; k < len / 2; k++)
                {
                    int u = i + k, v = i + k + len / 2;
                    float xr = re[v] * wr - im[v] * wi, xi = re[v] * wi + im[v] * wr;
                    re[v] = re[u] - xr; im[v] = im[u] - xi;
                    re[u] += xr; im[u] += xi;
                    float nwr = wr * wlr - wi * wli;
                    wi = wr * wli + wi * wlr;
                    wr = nwr;
                }
            }
        }
    }
}
