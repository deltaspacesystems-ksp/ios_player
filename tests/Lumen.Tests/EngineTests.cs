using Lumen.Audio;
using Lumen.Core;
using Xunit;

namespace Lumen.Tests;

internal static class Wav
{
    /// <summary>Writes a mono 16-bit 44.1 kHz sine WAV and returns its path.</summary>
    public static string Sine(double freq, double seconds, double amp = 0.5)
    {
        var path = Path.Combine(Path.GetTempPath(), $"lumen-test-{Guid.NewGuid():N}.wav");
        int rate = 44100, n = (int)(seconds * rate);
        using var fs = File.Create(path);
        using var w = new BinaryWriter(fs);
        w.Write("RIFF"u8.ToArray()); w.Write(36 + n * 2); w.Write("WAVE"u8.ToArray());
        w.Write("fmt "u8.ToArray()); w.Write(16); w.Write((short)1); w.Write((short)1); w.Write(rate); w.Write(rate * 2); w.Write((short)2); w.Write((short)16);
        w.Write("data"u8.ToArray()); w.Write(n * 2);
        for (int i = 0; i < n; i++) w.Write((short)(Math.Sin(2 * Math.PI * freq * i / rate) * amp * short.MaxValue));
        return path;
    }

    public static void Cleanup(string path) { try { File.Delete(path); } catch (IOException) { /* decoder still holds it; temp file */ } }

    public static void WaitReady(Deck d, int ms = 3000)
    {
        var t = Environment.TickCount64;
        while (!d.IsReady && Environment.TickCount64 - t < ms) Thread.Sleep(5);
    }

    /// <summary>Waits until at least <paramref name="seconds"/> of audio is buffered (so tests never see decoder underruns).</summary>
    public static void WaitBuffered(Deck d, double seconds, int ms = 5000)
    {
        var t = Environment.TickCount64;
        while (d.BufferedFrames < seconds * 48000 && !d.Failed && Environment.TickCount64 - t < ms) Thread.Sleep(5);
    }
}

public class EngineTests
{
    private static double Rms(float[] b, int fromFrame, int frames)
    {
        double s = 0;
        for (int i = 0; i < frames * 2; i++) { var v = b[fromFrame * 2 + i]; s += v * v; }
        return Math.Sqrt(s / (frames * 2));
    }

    [Fact]
    public void Deck_decodes_whole_file()
    {
        var f = Wav.Sine(440, 3);
        using var d = new Deck(f);
        Wav.WaitReady(d);
        var buf = new float[4800 * 2];
        long frames = 0; float peak = 0;
        var sw = System.Diagnostics.Stopwatch.StartNew();
        while (!d.Drained && sw.ElapsedMilliseconds < 8000)
        {
            int got = d.Read(buf, 4800);
            frames += got;
            for (int i = 0; i < got * 2; i++) peak = Math.Max(peak, Math.Abs(buf[i]));
            if (got == 0) Thread.Sleep(2);
        }
        Assert.InRange(frames, 3 * 48000 - 600, 3 * 48000 + 600);
        Assert.InRange(peak, 0.45f, 0.55f);
        Assert.InRange(d.Duration, 2.9, 3.1);
        Wav.Cleanup(f);
    }

    [Fact]
    public void Deck_seek_moves_position_and_keeps_audio()
    {
        var f = Wav.Sine(440, 4);
        using var d = new Deck(f);
        Wav.WaitReady(d);
        d.Seek(2.5);
        Assert.InRange(d.Position, 2.49, 2.51);
        Wav.WaitReady(d);
        var buf = new float[4800 * 2];
        int got = 0, tries = 0;
        while (got < 2400 && tries++ < 500) { got += d.Read(buf.AsSpan(got * 2), 2400 - got); if (got < 2400) Thread.Sleep(5); }
        Assert.True(got >= 2400);
        Assert.True(Rms(buf, 0, 2400) > 0.2);
        Assert.InRange(d.Position, 2.5, 2.7);
        Wav.Cleanup(f);
    }

    [Fact]
    public void Mixer_is_gapless_between_decks()
    {
        var fa = Wav.Sine(440, 1.5); var fb = Wav.Sine(660, 1.5);
        var m = new Mixer { Volume = 1f };
        var a = new Deck(fa); var b = new Deck(fb);
        Wav.WaitBuffered(a, 1.45); Wav.WaitBuffered(b, 1.45);
        m.SetActive(a); m.SetNext(b);
        int advanced = 0; m.Advanced += _ => advanced++;
        bool ended = false; m.Ended += () => ended = true;
        m.Playing = true;

        var all = new List<float>();
        var buf = new float[2048 * 2];
        var sw = System.Diagnostics.Stopwatch.StartNew();
        while (!ended && sw.ElapsedMilliseconds < 8000) { m.Read(buf); all.AddRange(buf); Thread.Sleep(1); }
        Assert.True(ended);
        Assert.Equal(1, advanced);
        // find a long run of near-silence right around 1.5 s: there must be none
        var arr = all.ToArray();
        int boundary = (int)(1.5 * 48000);
        double around = Rms(arr, boundary - 240, 480);
        Assert.True(around > 0.2, $"rms around boundary was {around}");
        Wav.Cleanup(fa); Wav.Cleanup(fb);
    }

    [Theory]
    [InlineData(FadeCurve.EqualPower)]
    [InlineData(FadeCurve.Linear)]
    [InlineData(FadeCurve.SCurve)]
    public void Crossfade_keeps_loudness_reasonable(FadeCurve curve)
    {
        var fa = Wav.Sine(300, 6); var fb = Wav.Sine(900, 6);
        var m = new Mixer { Volume = 1f };
        var a = new Deck(fa); var b = new Deck(fb);
        Wav.WaitBuffered(a, 3.9); Wav.WaitBuffered(b, 3.9);
        m.SetActive(a); m.SetNext(b); m.Playing = true;
        var buf = new float[4096 * 2];
        // play 2 s, then fade for 2 s
        int frames = 0;
        while (frames < 2 * 48000) { m.Read(buf); frames += 4096; }
        Assert.True(m.StartFade(2, curve));
        var fade = new List<double>();
        int fadeFrames = 0;
        while (fadeFrames < 2 * 48000) { m.Read(buf); fade.Add(Rms(buf, 0, 4096)); fadeFrames += 4096; }
        // equal power on uncorrelated tones keeps rms close to the single-track value (0.354); linear dips in the middle
        double mid = fade[fade.Count / 2];
        if (curve == FadeCurve.EqualPower) Assert.InRange(mid, 0.28, 0.42);
        else Assert.InRange(mid, 0.18, 0.42);
        Assert.False(m.Fading);
        Assert.Same(b, m.Active);
        Wav.Cleanup(fa); Wav.Cleanup(fb);
    }

    [Fact]
    public void Eq_boost_raises_level()
    {
        var f = Wav.Sine(1000, 3);
        var m = new Mixer { Volume = 1f };
        var d = new Deck(f); Wav.WaitBuffered(d, 2.9); m.SetActive(d); m.Playing = true;
        var buf = new float[4096 * 2];
        for (int i = 0; i < 4; i++) m.Read(buf);
        double flat = Rms(buf, 0, 4096);
        var g = new float[10]; g[5] = 9;           // +9 dB at 1 kHz
        m.SetEq(g, 0);
        for (int i = 0; i < 4; i++) m.Read(buf);
        double boosted = Rms(buf, 0, 4096);
        Assert.True(boosted > flat * 1.8, $"flat {flat} boosted {boosted}");
        Wav.Cleanup(f);
    }
}
