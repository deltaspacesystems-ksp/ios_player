using System.Net;
using System.Net.Http.Json;
using System.Runtime.CompilerServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace Lumen.Core;

public sealed record LyricsOptions(bool Online = true, bool NetEase = false);

public sealed record LyricsCacheStats(int Files, long Bytes, int Negative);

/// <summary>
/// Finds lyrics progressively and caches everything: sidecar file (.lrc/.ttml/.yrc) → embedded tag → disk cache →
/// LRCLIB (free, no key) → optional NetEase. <see cref="StreamAsync"/> yields every *better* result as soon as it is known,
/// so the UI shows line-synced lyrics instantly and upgrades if a word-synced source turns up.
/// </summary>
public sealed class LyricsService
{
    private static readonly string[] SidecarExt = { ".ttml", ".yrc", ".elrc", ".lrc" };
    private readonly HttpClient _http;
    private readonly string _dir;
    private readonly Func<LyricsOptions> _options;
    private readonly SemaphoreSlim _netGate = new(2);

    public LyricsService(string cacheDir, Func<LyricsOptions>? options = null, HttpClient? http = null)
    {
        _dir = cacheDir;
        _options = options ?? (() => new LyricsOptions());
        _http = http ?? CreateClient();
        Directory.CreateDirectory(_dir);
    }

    private static HttpClient CreateClient()
    {
        var c = new HttpClient(new SocketsHttpHandler { AutomaticDecompression = DecompressionMethods.All }) { Timeout = TimeSpan.FromSeconds(10) };
        c.DefaultRequestHeaders.UserAgent.ParseAdd("Lumen/1.0 (https://github.com/deltaspacesystems-ksp/ios_player)");
        return c;
    }

    // ------------------------------------------------------------------ cache

    private sealed class CacheEntry
    {
        public string Provider { get; set; } = "";
        public string Text { get; set; } = "";
        public bool None { get; set; }
        public DateTime Fetched { get; set; }
    }

    private static string Norm(string s)
    {
        s = Regex.Replace(s.ToLowerInvariant(), @"\s*[\(\[][^\)\]]*[\)\]]", "");      // drop (feat. x) / [remix]
        s = Regex.Replace(s, @"[^\p{L}\p{N}]+", " ").Trim();
        return s;
    }

    private string KeyOf(Track t)
    {
        var raw = $"{Norm(t.Artist)}|{Norm(t.Display)}|{(int)Math.Round(t.Duration / 2) * 2}";
        return Convert.ToHexString(SHA1.HashData(Encoding.UTF8.GetBytes(raw)))[..20].ToLowerInvariant();
    }

    private string CacheFile(Track t) => Path.Combine(_dir, KeyOf(t) + ".json");

    private CacheEntry? ReadCache(Track t)
    {
        try
        {
            var f = CacheFile(t);
            if (!File.Exists(f)) return null;
            return JsonSerializer.Deserialize<CacheEntry>(File.ReadAllText(f));
        }
        catch { return null; }
    }

    private void WriteCache(Track t, CacheEntry e)
    {
        try { File.WriteAllText(CacheFile(t), JsonSerializer.Serialize(e)); }
        catch (Exception ex) { Log.W("lyrics", $"cache write failed: {ex.Message}"); }
    }

    public LyricsCacheStats GetStats()
    {
        try
        {
            var files = new DirectoryInfo(_dir).GetFiles("*.json");
            int neg = 0;
            foreach (var f in files) { try { if (File.ReadAllText(f.FullName).Contains("\"None\":true")) neg++; } catch { } }
            return new LyricsCacheStats(files.Length - neg, files.Sum(f => f.Length), neg);
        }
        catch { return new LyricsCacheStats(0, 0, 0); }
    }

    public void ClearCache()
    {
        foreach (var f in Directory.GetFiles(_dir, "*.json")) { try { File.Delete(f); } catch { } }
        foreach (var f in Directory.GetFiles(_dir, "*.lrc")) { try { File.Delete(f); } catch { } }
    }

    /// <summary>True when lyrics (or a recent "nothing found") are already cached, so no network is needed.</summary>
    public bool IsCached(Track t)
    {
        var e = ReadCache(t);
        return e != null && (!e.None || DateTime.UtcNow - e.Fetched < TimeSpan.FromDays(3));
    }

    // ------------------------------------------------------------------ local sources

    private Lyrics? LoadSidecar(Track t)
    {
        foreach (var ext in SidecarExt)
        {
            var f = Path.ChangeExtension(t.Path, ext);
            if (!File.Exists(f)) continue;
            try
            {
                var l = LyricsFormat.Parse(File.ReadAllText(f), "file", t.Duration);
                if (!l.IsEmpty) return l;
            }
            catch (Exception e) { Log.W("lyrics", $"{Path.GetFileName(f)}: {e.Message}"); }
        }
        return null;
    }

    private static Lyrics? LoadEmbedded(Track t)
    {
        try
        {
            using var f = TagLib.File.Create(t.Path);
            var text = f.Tag.Lyrics;
            if (!string.IsNullOrWhiteSpace(text))
            {
                var l = LyricsFormat.Parse(text, "tag", t.Duration);
                if (!l.IsEmpty) return l;
            }
        }
        catch { /* TagLib can't read every format; other sources follow */ }
        return null;
    }

    // ------------------------------------------------------------------ progressive stream

    /// <summary>Yields results of increasing <see cref="Lyrics.Quality"/>; completes when nothing better can be found.</summary>
    public async IAsyncEnumerable<Lyrics> StreamAsync(Track t, bool force = false, [EnumeratorCancellation] CancellationToken ct = default)
    {
        int best = 0;

        if (!force)
        {
            var side = LoadSidecar(t) ?? LoadEmbedded(t);
            if (side != null) { best = side.Quality; yield return side; if (best >= 3) yield break; }

            var c = ReadCache(t);
            if (c != null && !c.None)
            {
                var l = LyricsFormat.Parse(c.Text, c.Provider + " (cached)", t.Duration);
                if (l.Quality > best) { best = l.Quality; yield return l; }
                if (best >= 2) yield break;            // nothing better is reachable online right now
            }
            else if (c is { None: true } && DateTime.UtcNow - c.Fetched < TimeSpan.FromDays(3) && best == 0) yield break;
        }

        var opt = _options();
        if (!opt.Online) yield break;

        Lyrics? fromWeb = null;
        string provider = "";
        string text = "";

        (string text, string provider)? hit = null;
        try { hit = await FromLrcLib(t, ct); } catch (OperationCanceledException) { throw; } catch (Exception e) { Log.W("lyrics", $"LRCLIB: {e.Message}"); }
        if (hit == null || !LooksSynced(hit.Value.text))
        {
            if (opt.NetEase)
            {
                try { var ne = await FromNetEase(t, ct); if (ne != null && (hit == null || LooksSynced(ne.Value.text))) hit = ne; }
                catch (OperationCanceledException) { throw; }
                catch (Exception e) { Log.W("lyrics", $"NetEase: {e.Message}"); }
            }
        }
        if (hit != null) { text = hit.Value.text; provider = hit.Value.provider; fromWeb = LyricsFormat.Parse(text, provider, t.Duration); }

        if (fromWeb != null && !fromWeb.IsEmpty)
        {
            WriteCache(t, new CacheEntry { Provider = provider, Text = text, Fetched = DateTime.UtcNow });
            Log.I("lyrics", $"{provider}: {fromWeb.QualityLabel} for {t}");
            if (fromWeb.Quality > best) yield return fromWeb;
        }
        else if (best == 0)
        {
            WriteCache(t, new CacheEntry { None = true, Fetched = DateTime.UtcNow });
            Log.I("lyrics", $"no lyrics found for {t}");
        }
    }

    private static bool LooksSynced(string text) => Regex.IsMatch(text, @"^\s*\[\d+:\d+", RegexOptions.Multiline);

    /// <summary>Best available lyrics (waits for the whole stream).</summary>
    public async Task<Lyrics> GetAsync(Track t, CancellationToken ct = default)
    {
        Lyrics? best = null;
        await foreach (var l in StreamAsync(t, false, ct)) if (best == null || l.Quality > best.Quality) best = l;
        return best ?? new Lyrics();
    }

    /// <summary>Downloads and caches lyrics for a track without returning them (used for the next track in the queue / the whole library).</summary>
    public async Task<bool> PrefetchAsync(Track t, CancellationToken ct = default)
    {
        if (IsCached(t) || LoadSidecar(t) != null) return false;
        await foreach (var _ in StreamAsync(t, false, ct)) { }
        return true;
    }

    public Task SaveSidecarAsync(Track t, string lrcText) =>
        File.WriteAllTextAsync(Path.ChangeExtension(t.Path, ".lrc"), lrcText);

    // ------------------------------------------------------------------ providers

    private async Task<T?> GetJson<T>(string url, CancellationToken ct)
    {
        await _netGate.WaitAsync(ct);
        try
        {
            for (int attempt = 0; attempt < 2; attempt++)
            {
                using var resp = await _http.GetAsync(url, ct);
                if (resp.StatusCode == HttpStatusCode.NotFound) return default;
                if ((int)resp.StatusCode >= 500 || resp.StatusCode == HttpStatusCode.TooManyRequests)
                {
                    await Task.Delay(attempt == 0 ? 800 : 0, ct);
                    continue;
                }
                if (!resp.IsSuccessStatusCode) return default;
                return await resp.Content.ReadFromJsonAsync<T>(cancellationToken: ct);
            }
            return default;
        }
        finally { _netGate.Release(); }
    }

    private sealed class LrclibItem
    {
        [JsonPropertyName("syncedLyrics")] public string? SyncedLyrics { get; set; }
        [JsonPropertyName("plainLyrics")] public string? PlainLyrics { get; set; }
        [JsonPropertyName("duration")] public double? Duration { get; set; }
        [JsonPropertyName("trackName")] public string? TrackName { get; set; }
        [JsonPropertyName("artistName")] public string? ArtistName { get; set; }
    }

    private async Task<(string text, string provider)?> FromLrcLib(Track t, CancellationToken ct)
    {
        var q = $"https://lrclib.net/api/get?track_name={Uri.EscapeDataString(t.Display)}&artist_name={Uri.EscapeDataString(t.Artist)}"
              + $"&album_name={Uri.EscapeDataString(t.Album)}&duration={(int)Math.Round(t.Duration)}";
        var item = await GetJson<LrclibItem>(q, ct);
        if (item == null)
        {
            var s = $"https://lrclib.net/api/search?track_name={Uri.EscapeDataString(t.Display)}&artist_name={Uri.EscapeDataString(t.Artist)}";
            var list = await GetJson<List<LrclibItem>>(s, ct);
            item = list?.Where(i => Math.Abs((i.Duration ?? 0) - t.Duration) < 5)
                        .OrderBy(i => string.IsNullOrWhiteSpace(i.SyncedLyrics) ? 1 : 0)
                        .ThenBy(i => Math.Abs((i.Duration ?? 0) - t.Duration)).FirstOrDefault();
        }
        var text = !string.IsNullOrWhiteSpace(item?.SyncedLyrics) ? item!.SyncedLyrics : item?.PlainLyrics;
        return string.IsNullOrWhiteSpace(text) ? null : (text!, "lrclib");
    }

    private sealed class NeSearch { [JsonPropertyName("result")] public NeResult? Result { get; set; } }
    private sealed class NeResult { [JsonPropertyName("songs")] public List<NeSong>? Songs { get; set; } }
    private sealed class NeSong
    {
        [JsonPropertyName("id")] public long Id { get; set; }
        [JsonPropertyName("name")] public string Name { get; set; } = "";
        [JsonPropertyName("duration")] public double Duration { get; set; }
        [JsonPropertyName("artists")] public List<NeArtist>? Artists { get; set; }
    }
    private sealed class NeArtist { [JsonPropertyName("name")] public string Name { get; set; } = ""; }
    private sealed class NeLyric { [JsonPropertyName("lrc")] public NeLrc? Lrc { get; set; } }
    private sealed class NeLrc { [JsonPropertyName("lyric")] public string? Lyric { get; set; } }

    /// <summary>Optional secondary source (unofficial public endpoint, line-synced only). Strict matching on title, artist and length.</summary>
    private async Task<(string text, string provider)?> FromNetEase(Track t, CancellationToken ct)
    {
        var s = $"https://music.163.com/api/search/get?s={Uri.EscapeDataString(t.Artist + " " + t.Display)}&type=1&limit=6";
        var res = await GetJson<NeSearch>(s, ct);
        var want = Norm(t.Display); var artist = Norm(t.Artist);
        var song = res?.Result?.Songs?.FirstOrDefault(x =>
            Norm(x.Name) == want && Math.Abs(x.Duration / 1000 - t.Duration) <= 4 &&
            (artist.Length == 0 || (x.Artists?.Any(a => { var n = Norm(a.Name); return n.Length > 0 && (artist.Contains(n) || n.Contains(artist)); }) ?? false)));
        if (song == null) return null;
        var ly = await GetJson<NeLyric>($"https://music.163.com/api/song/lyric?id={song.Id}&lv=-1&kv=-1&tv=-1", ct);
        var text = ly?.Lrc?.Lyric;
        if (string.IsNullOrWhiteSpace(text)) return null;
        // drop credit lines such as "作词 : ..." / "Written by :"
        text = string.Join("\n", text.Split('\n').Where(l => !Regex.IsMatch(l, @"^\[\d+:\d+(\.\d+)?\]\s*(作[词曲]|编曲|制作|Lyrics?|Composer|Written|Produced|Arranged)\b.*[:：]", RegexOptions.IgnoreCase)));
        return (text, "netease");
    }
}
