using Lumen.Audio;
using Xunit;

namespace Lumen.Tests;

public class SpatialTests
{
    private static float[] Noise(int frames, int seed = 1, bool mono = false)
    {
        var rnd = new Random(seed);
        var b = new float[frames * 2];
        for (int i = 0; i < frames; i++)
        {
            float l = (float)(rnd.NextDouble() * 2 - 1) * 0.3f;
            b[i * 2] = l;
            b[i * 2 + 1] = mono ? l : (float)(rnd.NextDouble() * 2 - 1) * 0.3f;
        }
        return b;
    }

    private static double Energy(float[] b, int ch, int from, int to)
    {
        double e = 0;
        for (int i = from; i < to; i++) e += b[i * 2 + ch] * b[i * 2 + ch];
        return e;
    }

    [Fact]
    public void Off_is_transparent()
    {
        var fx = new SpatialFx { Mode = SpatialMode.Off };
        var src = Noise(4800); var buf = (float[])src.Clone();
        fx.Process(buf, 4800);
        Assert.Equal(src, buf);
    }

    [Fact]
    public void Wide_at_unity_width_does_not_change_the_signal()
    {
        var fx = new SpatialFx { Mode = SpatialMode.Wide, Width = 1f, Amount = 1f };
        var src = Noise(4800); var buf = (float[])src.Clone();
        fx.Process(buf, 4800);
        for (int i = 0; i < buf.Length; i++) Assert.True(Math.Abs(buf[i] - src[i]) < 1e-5f);
    }

    [Fact]
    public void Wide_at_zero_width_collapses_to_mono()
    {
        var fx = new SpatialFx { Mode = SpatialMode.Wide, Width = 0f, Amount = 1f };
        var buf = Noise(4800);
        fx.Process(buf, 4800);
        for (int i = 0; i < 4800; i++) Assert.True(Math.Abs(buf[i * 2] - buf[i * 2 + 1]) < 1e-5f);
    }

    [Fact]
    public void Surround_keeps_mono_sources_centered()
    {
        var fx = new SpatialFx { Mode = SpatialMode.Surround, Amount = 1f, Width = 1.6f };
        var buf = Noise(9600, mono: true);
        fx.Process(buf, 9600);
        for (int i = 0; i < 9600; i++) Assert.True(Math.Abs(buf[i * 2] - buf[i * 2 + 1]) < 1e-4f, $"frame {i}");
    }

    [Fact]
    public void Surround_adds_side_energy_to_wide_material()
    {
        var fx = new SpatialFx { Mode = SpatialMode.Surround, Amount = 1f, Width = 1.6f };
        var src = Noise(48000, seed: 7);
        var buf = (float[])src.Clone();
        fx.Process(buf, 48000);
        double Side(float[] b) { double e = 0; for (int i = 0; i < 48000; i++) { var s = b[i * 2] - b[i * 2 + 1]; e += s * s; } return e; }
        Assert.True(Side(buf) > Side(src) * 1.2);
        Assert.All(buf, v => Assert.True(float.IsFinite(v)));
    }

    [Fact]
    public void Hall_has_a_decaying_tail_and_stays_stable()
    {
        var fx = new SpatialFx { Mode = SpatialMode.Hall, Amount = 1f, Room = 0.8f };
        int n = 48000 * 4;
        var buf = new float[n * 2];
        buf[0] = 1f; buf[1] = 1f;                         // impulse
        fx.Process(buf, n);
        double early = Energy(buf, 0, 4800, 48000);       // 0.1–1 s
        double late = Energy(buf, 0, 48000 * 3, 48000 * 4);
        Assert.True(early > 1e-6, $"early tail {early}");
        Assert.True(late < early, $"late {late} should be below early {early}");
        Assert.All(buf, v => Assert.True(float.IsFinite(v)));

        var loud = Noise(48000 * 10, seed: 3);
        var fx2 = new SpatialFx { Mode = SpatialMode.Hall, Amount = 1f, Room = 1f };
        fx2.Process(loud, 48000 * 10);
        Assert.True(loud.Max(Math.Abs) < 5f, "reverb must not run away");
    }

    [Fact]
    public void Spatial3D_feeds_the_opposite_ear_and_stays_finite()
    {
        var fx = new SpatialFx { Mode = SpatialMode.Spatial3D, Amount = 1f, Room = 0.5f };
        int n = 48000;
        var buf = new float[n * 2];
        for (int i = 0; i < n; i++) buf[i * 2] = 0.5f * MathF.Sin(2 * MathF.PI * 440 * i / 48000f);   // left only
        fx.Process(buf, n);
        double left = Energy(buf, 0, 4800, n), right = Energy(buf, 1, 4800, n);
        Assert.True(right > left * 0.05, $"right {right} vs left {left}");
        Assert.All(buf, v => Assert.True(float.IsFinite(v)));
    }

    [Fact]
    public void Crossfeed_bleeds_but_keeps_the_channel_dominant()
    {
        var fx = new SpatialFx { Mode = SpatialMode.Off, Crossfeed = true };
        int n = 48000;
        var buf = new float[n * 2];
        for (int i = 0; i < n; i++) buf[i * 2] = 0.5f * MathF.Sin(2 * MathF.PI * 300 * i / 48000f);
        fx.Process(buf, n);
        double left = Energy(buf, 0, 4800, n), right = Energy(buf, 1, 4800, n);
        Assert.True(right > 0 && right < left, $"right {right} left {left}");
    }

    [Fact]
    public void Heavy_modes_run_much_faster_than_real_time()
    {
        var fx = new SpatialFx { Mode = SpatialMode.Spatial3D, Amount = 1f, Crossfeed = true };
        var buf = Noise(48000 * 30);
        var sw = System.Diagnostics.Stopwatch.StartNew();
        fx.Process(buf, 48000 * 30);
        sw.Stop();
        Assert.True(sw.Elapsed.TotalSeconds < 6, $"30 s of audio took {sw.Elapsed.TotalSeconds:0.00} s");
    }
}
