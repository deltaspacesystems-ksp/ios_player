using Lumen.Audio;
using Xunit;

namespace Lumen.Tests;

public class StageTests
{
    private static float[] Pink(int frames, int seed, bool mono)
    {
        var rnd = new Random(seed);
        var b = new float[frames * 2];
        float b0 = 0, b1 = 0, b2 = 0, c0 = 0, c1 = 0, c2 = 0;
        for (int i = 0; i < frames; i++)
        {
            float wl = (float)(rnd.NextDouble() * 2 - 1), wr = mono ? wl : (float)(rnd.NextDouble() * 2 - 1);
            b0 = 0.99765f * b0 + wl * 0.0990460f; b1 = 0.96300f * b1 + wl * 0.2965164f; b2 = 0.57000f * b2 + wl * 1.0526913f;
            c0 = 0.99765f * c0 + wr * 0.0990460f; c1 = 0.96300f * c1 + wr * 0.2965164f; c2 = 0.57000f * c2 + wr * 1.0526913f;
            b[i * 2] = (b0 + b1 + b2 + wl * 0.1848f) * 0.05f;
            b[i * 2 + 1] = (c0 + c1 + c2 + wr * 0.1848f) * 0.05f;
        }
        return b;
    }

    private static (double mid, double side) MidSide(float[] b, int from, int to)
    {
        double m = 0, s = 0;
        for (int i = from; i < to; i++) { float l = b[i * 2], r = b[i * 2 + 1]; m += (l + r) * (l + r) / 4; s += (l - r) * (l - r) / 4; }
        return (m, s);
    }

    private static double Rms(float[] b, int from, int to)
    {
        double e = 0;
        for (int i = from * 2; i < to * 2; i++) e += b[i] * b[i];
        return Math.Sqrt(e / ((to - from) * 2));
    }

    [Fact]
    public void Stage_keeps_loudness_within_1_5_dB()
    {
        int n = 48000 * 8;
        foreach (var mono in new[] { false, true })
        {
            var src = Pink(n, 11, mono); var buf = (float[])src.Clone();
            new SpatialFx { Mode = SpatialMode.Stage, Amount = 0.8f, Width = 1.8f, Room = 0.6f }.Process(buf, n);
            double db = 20 * Math.Log10(Rms(buf, 48000, n) / Rms(src, 48000, n));
            Assert.InRange(db, -1.5, 1.5);
        }
    }

    [Fact]
    public void Stage_widens_stereo_material_but_leaves_the_centre_alone()
    {
        int n = 48000 * 8;
        var src = Pink(n, 5, false); var buf = (float[])src.Clone();
        new SpatialFx { Mode = SpatialMode.Stage, Amount = 0.8f, Width = 1.8f }.Process(buf, n);
        var (m0, s0) = MidSide(src, 48000, n); var (m1, s1) = MidSide(buf, 48000, n);
        Assert.True(s1 / m1 > (s0 / m0) * 1.25, $"side/mid {s0 / m0:0.000} -> {s1 / m1:0.000}");
        double db = 10 * Math.Log10(m1 / m0);
        Assert.InRange(db, -1.5, 1.5);
    }

    [Fact]
    public void Stage_makes_mono_sources_wider_yet_keeps_the_mono_sum()
    {
        int n = 48000 * 8;
        var src = Pink(n, 9, true); var buf = (float[])src.Clone();
        new SpatialFx { Mode = SpatialMode.Stage, Amount = 0.8f, Width = 1.6f, Room = 0.5f }.Process(buf, n);
        var (m0, _) = MidSide(src, 48000, n); var (m1, s1) = MidSide(buf, 48000, n);
        Assert.True(s1 > 1e-6, "a mono source should gain some stereo air");
        Assert.InRange(10 * Math.Log10(m1 / m0), -1.5, 1.5);
        Assert.True(s1 < m1 * 0.5, $"side {s1} mid {m1}");
    }

    [Fact]
    public void Stage_leaves_bass_centred()
    {
        int n = 48000 * 2;
        var buf = new float[n * 2];
        for (int i = 0; i < n; i++) { float x = 0.4f * MathF.Sin(2 * MathF.PI * 60 * i / 48000f); buf[i * 2] = x; buf[i * 2 + 1] = x * 0.9f; }
        var src = (float[])buf.Clone();
        new SpatialFx { Mode = SpatialMode.Stage, Amount = 1f, Width = 2f }.Process(buf, n);
        var (m0, s0) = MidSide(src, 4800, n); var (m1, s1) = MidSide(buf, 4800, n);
        Assert.True(s1 / m1 <= (s0 / m0) * 1.05, "low frequencies must not get wider");
    }

    [Fact]
    public void Stage_is_finite_on_loud_material()
    {
        int n = 48000 * 5;
        var buf = Pink(n, 2, false);
        for (int i = 0; i < buf.Length; i++) buf[i] = Math.Clamp(buf[i] * 6, -0.95f, 0.95f);
        new SpatialFx { Mode = SpatialMode.Stage, Amount = 1f, Width = 2f, Room = 1f, Crossfeed = true }.Process(buf, n);
        Assert.All(buf, v => Assert.True(float.IsFinite(v) && Math.Abs(v) < 4f));
    }
}
