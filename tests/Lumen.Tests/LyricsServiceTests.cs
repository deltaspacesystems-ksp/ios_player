using System.Net;
using System.Text;
using Lumen.Core;
using Xunit;

namespace Lumen.Tests;

public class LyricsServiceTests
{
    private sealed class FakeHandler : HttpMessageHandler
    {
        public int Requests;
        public Func<Uri, (HttpStatusCode, string)> Respond = _ => (HttpStatusCode.NotFound, "");
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            Interlocked.Increment(ref Requests);
            var (code, body) = Respond(request.RequestUri!);
            return Task.FromResult(new HttpResponseMessage(code) { Content = new StringContent(body, Encoding.UTF8, "application/json") });
        }
    }

    private static (LyricsService svc, FakeHandler h, string dir) Make(bool online = true)
    {
        var dir = Path.Combine(Path.GetTempPath(), "lumen-lyrics-" + Guid.NewGuid().ToString("N"));
        var h = new FakeHandler();
        return (new LyricsService(dir, () => new LyricsOptions(online), new HttpClient(h)), h, dir);
    }

    private static Track Song(string name = "Faded") => new() { Path = Path.Combine(Path.GetTempPath(), "nonexistent-" + name + ".mp3"), Title = name, Artist = "Alan Walker", Album = "Different World", Duration = 212 };

    private const string LrclibJson = """{"id":1,"trackName":"Faded","artistName":"Alan Walker","duration":212.0,"syncedLyrics":"[00:10.00] You were the shadow\n[00:17.00] Another star","plainLyrics":"You were the shadow\nAnother star"}""";

    [Fact]
    public void Ttml_with_word_spans_gives_exact_word_timings()
    {
        const string ttml = """
            <tt xmlns="http://www.w3.org/ns/ttml"><body><div>
              <p begin="00:00:10.000" end="00:00:13.000"><span begin="00:00:10.000" end="00:00:10.500">Hello</span> <span begin="00:00:10.600" end="00:00:11.200">world</span></p>
              <p begin="00:00:14.000" end="00:00:16.000">Only a line</p>
            </div></body></tt>
            """;
        var l = LyricsFormat.Parse(ttml, "test", 30);
        Assert.True(l.Synced);
        Assert.Equal(2, l.Lines.Count);
        Assert.True(l.Lines[0].WordsExact);
        Assert.Equal(2, l.Lines[0].Words.Count);
        Assert.Equal(10.6, l.Lines[0].Words[1].Time, 2);
        Assert.Equal("Hello world", l.Lines[0].Text);
        Assert.False(l.Lines[1].WordsExact);
        Assert.Equal(3, l.Quality);
    }

    [Fact]
    public void Yrc_word_level_format_is_detected_and_parsed()
    {
        const string yrc = "[10000,3000](10000,500,0)Hel(10500,400,0)lo (10900,600,0)world\n[14000,2000](14000,1000,0)Next(15000,900,0) line";
        var l = LyricsFormat.Parse(yrc, "test", 30);
        Assert.True(l.Synced);
        Assert.Equal(2, l.Lines.Count);
        Assert.Equal(3, l.Lines[0].Words.Count);
        Assert.Equal(10.9, l.Lines[0].Words[2].Time, 2);
        Assert.Equal("Hello world", l.Lines[0].Text);
        Assert.Equal(3, l.Quality);
    }

    [Fact]
    public void Plain_lrc_is_still_detected_as_lrc()
    {
        var l = LyricsFormat.Parse("[00:01.00]One\n[00:03.00]Two", "x", 10);
        Assert.Equal(2, l.Quality);
    }

    [Fact]
    public void Estimated_words_follow_syllables()
    {
        var w = LyricTiming.Estimate("a incredible day", 0, 4);
        // "incredible" (4 syllables) must get clearly more time than "a" (1)
        Assert.True((w[1].End - w[1].Time) > (w[0].End - w[0].Time) * 2.5);
        Assert.True(w[^1].End <= 4 + 1e-9);
    }

    [Fact]
    public async Task Downloads_once_then_serves_from_cache_without_network()
    {
        var (svc, h, dir) = Make();
        h.Respond = _ => (HttpStatusCode.OK, LrclibJson);
        var t = Song();
        var first = await svc.GetAsync(t);
        Assert.Equal(2, first.Quality);
        Assert.Equal(2, first.Lines.Count);
        int afterFirst = h.Requests;
        Assert.True(afterFirst >= 1);

        // a brand-new service instance (fresh app start) must not touch the network
        var h2 = new FakeHandler { Respond = _ => throw new InvalidOperationException("network must not be used") };
        var svc2 = new LyricsService(dir, () => new LyricsOptions(true), new HttpClient(h2));
        var second = await svc2.GetAsync(t);
        Assert.Equal(2, second.Quality);
        Assert.Equal(0, h2.Requests);
        Assert.Contains("cached", second.Source);
        Assert.Equal(1, svc2.GetStats().Files);
    }

    [Fact]
    public async Task Not_found_is_remembered()
    {
        var (svc, h, dir) = Make();
        var t = Song("Unknown Song");
        var r1 = await svc.GetAsync(t);
        Assert.True(r1.IsEmpty);
        int n = h.Requests;
        Assert.True(n >= 1);
        var r2 = await svc.GetAsync(t);
        Assert.True(r2.IsEmpty);
        Assert.Equal(n, h.Requests);                       // no new requests: negative cache
        Assert.Equal(1, svc.GetStats().Negative);
    }

    [Fact]
    public async Task Word_synced_file_wins_and_skips_the_network()
    {
        var (svc, h, _) = Make();
        h.Respond = _ => (HttpStatusCode.OK, LrclibJson);
        var dir = Path.Combine(Path.GetTempPath(), "lumen-side-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        var t = new Track { Path = Path.Combine(dir, "song.mp3"), Title = "Song", Artist = "A", Duration = 100 };
        await File.WriteAllTextAsync(Path.Combine(dir, "song.lrc"), "[00:01.00]<00:01.00>Word <00:01.50>level\n");
        var best = await svc.GetAsync(t);
        Assert.Equal(3, best.Quality);
        Assert.Equal(0, h.Requests);
    }

    [Fact]
    public async Task Stream_yields_improvements_only_and_force_redownloads()
    {
        var (svc, h, _) = Make();
        h.Respond = _ => (HttpStatusCode.OK, LrclibJson);
        var t = Song();
        var seen = new List<int>();
        await foreach (var l in svc.StreamAsync(t)) seen.Add(l.Quality);
        Assert.Equal(new[] { 2 }, seen.ToArray());
        int n = h.Requests;
        seen.Clear();
        await foreach (var l in svc.StreamAsync(t, force: true)) seen.Add(l.Quality);
        Assert.Equal(new[] { 2 }, seen.ToArray());
        Assert.True(h.Requests > n, "force must go back to the network");
    }

    [Fact]
    public async Task Prefetch_downloads_when_missing_and_skips_when_cached()
    {
        var (svc, h, _) = Make();
        h.Respond = _ => (HttpStatusCode.OK, LrclibJson);
        var t = Song();
        Assert.True(await svc.PrefetchAsync(t));
        int n = h.Requests;
        Assert.False(await svc.PrefetchAsync(t));
        Assert.Equal(n, h.Requests);
        Assert.True(svc.IsCached(t));
    }

    [Fact]
    public async Task Offline_mode_never_touches_the_network()
    {
        var (svc, h, _) = Make(online: false);
        h.Respond = _ => (HttpStatusCode.OK, LrclibJson);
        var r = await svc.GetAsync(Song());
        Assert.True(r.IsEmpty);
        Assert.Equal(0, h.Requests);
    }
}
