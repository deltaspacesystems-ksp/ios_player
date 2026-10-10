using System.Globalization;
using System.Net.Http.Json;
using System.Text;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace Lumen.Core;

public sealed record LyricWord(double Time, double End, string Text);

public sealed class LyricLine
{
    public double Time { get; init; }
    /// <summary>When the next line starts (or a sensible fallback for the last line).</summary>
    public double End { get; set; }
    public string Text { get; init; } = "";
    /// <summary>Word timings. <see cref="WordsExact"/> tells whether they came from the file or were estimated.</summary>
    public IReadOnlyList<LyricWord> Words { get; set; } = Array.Empty<LyricWord>();
    public bool WordsExact { get; set; }
}

public sealed class Lyrics
{
    public IReadOnlyList<LyricLine> Lines { get; init; } = Array.Empty<LyricLine>();
    public bool Synced { get; init; }
    public string Source { get; init; } = "";
    public string? Title { get; init; }
    public string? Artist { get; init; }
    /// <summary>Global [offset:ms] from the LRC header (seconds added to the playback time).</summary>
    public double OffsetSeconds { get; init; }
    public bool IsEmpty => Lines.Count == 0;

    /// <summary>Index of the line active at <paramref name="seconds"/> (-1 before the first line).</summary>
    public int IndexAt(double seconds, double userOffset = 0)
    {
        if (!Synced || Lines.Count == 0) return -1;
        double t = seconds + OffsetSeconds + userOffset;
        int lo = 0, hi = Lines.Count - 1, ans = -1;
        while (lo <= hi)
        {
            int mid = (lo + hi) / 2;
            if (Lines[mid].Time <= t) { ans = mid; lo = mid + 1; } else hi = mid - 1;
        }
        return ans;
    }

    /// <summary>Playback time converted to the lyrics' own clock.</summary>
    public double LyricTime(double seconds, double userOffset = 0) => seconds + OffsetSeconds + userOffset;
}

public static class LyricTiming
{
    /// <summary>Spreads <paramref name="text"/> over [start, end] by character weight, so un-timed words still get a karaoke sweep.</summary>
    public static IReadOnlyList<LyricWord> Estimate(string text, double start, double end)
    {
        var parts = Regex.Matches(text, @"\S+\s*").Select(m => m.Value).ToList();
        if (parts.Count == 0) return Array.Empty<LyricWord>();
        // leave a short pause before the next line so the last word doesn't sing into it
        double span = Math.Max(0.2, end - start);
        double sing = Math.Min(span * 0.92, Math.Max(0.3, parts.Sum(p => p.Trim().Length) * 0.075));
        double total = parts.Sum(p => Weight(p));
        var list = new List<LyricWord>(parts.Count);
        double t = start;
        foreach (var p in parts)
        {
            double d = sing * Weight(p) / total;
            list.Add(new LyricWord(t, t + d, p));
            t += d;
        }
        return list;
    }

    private static double Weight(string w) => Math.Max(1, w.Trim().Length) + (w.TrimEnd().EndsWith(',') || w.TrimEnd().EndsWith('.') ? 1.5 : 0);
}

public static class LrcParser
{
    private static readonly Regex TimeTag = new(@"\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]", RegexOptions.Compiled);
    private static readonly Regex WordTag = new(@"<(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?>", RegexOptions.Compiled);
    private static readonly Regex Meta = new(@"^\[(ti|ar|al|by|offset|length|re|ve):(.*)\]\s*$", RegexOptions.Compiled | RegexOptions.IgnoreCase);

    private static double ToSeconds(Match m)
    {
        double min = int.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture);
        double sec = int.Parse(m.Groups[2].Value, CultureInfo.InvariantCulture);
        double frac = 0;
        if (m.Groups[3].Success) frac = double.Parse("0." + m.Groups[3].Value, CultureInfo.InvariantCulture);
        return min * 60 + sec + frac;
    }

    public static Lyrics Parse(string text, string source = "", double trackDuration = 0)
    {
        var lines = new List<LyricLine>();
        string? title = null, artist = null;
        double offset = 0;
        bool anyTimed = false;

        foreach (var raw in text.Replace("\r\n", "\n").Replace('\r', '\n').Split('\n'))
        {
            var line = raw.Trim();
            if (line.Length == 0) continue;
            var meta = Meta.Match(line);
            if (meta.Success)
            {
                var key = meta.Groups[1].Value.ToLowerInvariant();
                var val = meta.Groups[2].Value.Trim();
                if (key == "ti") title = val;
                else if (key == "ar") artist = val;
                else if (key == "offset" && double.TryParse(val, NumberStyles.Float, CultureInfo.InvariantCulture, out var ms)) offset = ms / 1000.0;
                continue;
            }
            var tags = TimeTag.Matches(line);
            if (tags.Count == 0)
            {
                lines.Add(new LyricLine { Time = 0, Text = line });
                continue;
            }
            anyTimed = true;
            string body = TimeTag.Replace(line, "").Trim();
            var exact = new List<(double t, string text)>();
            string prefix = "";
            var firstTag = WordTag.Match(body);
            if (firstTag.Success && firstTag.Index > 0) prefix = body[..firstTag.Index];
            foreach (Match w in WordTag.Matches(body))
            {
                int start = w.Index + w.Length;
                var next = WordTag.Match(body, start);
                int end = next.Success ? next.Index : body.Length;
                exact.Add((ToSeconds(w), body.Substring(start, end - start)));
            }
            string clean = WordTag.Replace(body, "").Trim();
            foreach (Match t in tags)
            {
                var l = new LyricLine { Time = ToSeconds(t), Text = clean };
                if (exact.Count > 0)
                {
                    var ws = new List<LyricWord>();
                    if (prefix.Trim().Length > 0) ws.Add(new LyricWord(l.Time, exact[0].t, prefix));
                    for (int i = 0; i < exact.Count; i++)
                    {
                        double e = i + 1 < exact.Count ? exact[i + 1].t : exact[i].t + 0.5;
                        ws.Add(new LyricWord(exact[i].t, e, exact[i].text));
                    }
                    l.Words = ws;
                    l.WordsExact = true;
                }
                lines.Add(l);
            }
        }

        if (!anyTimed)
            return new Lyrics { Lines = lines, Synced = false, Source = source, Title = title, Artist = artist };

        lines = lines.OrderBy(l => l.Time).ToList();
        for (int i = 0; i < lines.Count; i++)
        {
            var l = lines[i];
            double end = i + 1 < lines.Count ? lines[i + 1].Time : (trackDuration > l.Time ? trackDuration : l.Time + 5);
            l.End = end;
            if (!l.WordsExact) l.Words = LyricTiming.Estimate(l.Text, l.Time, end);
        }
        return new Lyrics { Lines = lines, Synced = true, Source = source, Title = title, Artist = artist, OffsetSeconds = offset };
    }
}

/// <summary>Finds lyrics: sidecar .lrc → embedded tag → cache → LRCLIB (free, no key).</summary>
public sealed class LyricsService
{
    private static readonly HttpClient Http = CreateClient();
    private readonly string _cacheDir;
    private readonly Func<bool> _onlineEnabled;

    public LyricsService(string cacheDir, Func<bool>? onlineEnabled = null)
    {
        _cacheDir = cacheDir;
        _onlineEnabled = onlineEnabled ?? (() => true);
        Directory.CreateDirectory(cacheDir);
    }

    private static HttpClient CreateClient()
    {
        var c = new HttpClient { Timeout = TimeSpan.FromSeconds(10) };
        c.DefaultRequestHeaders.UserAgent.ParseAdd("Lumen/1.0 (https://github.com/deltaspacesystems-ksp/ios_player)");
        return c;
    }

    private string CachePath(Track t)
    {
        var key = $"{t.Artist}|{t.Title}|{t.Album}|{(int)t.Duration}";
        var hash = Convert.ToHexString(System.Security.Cryptography.SHA1.HashData(Encoding.UTF8.GetBytes(key)))[..16];
        return Path.Combine(_cacheDir, hash + ".lrc");
    }

    public async Task<Lyrics> GetAsync(Track t, CancellationToken ct = default)
    {
        var sidecar = System.IO.Path.ChangeExtension(t.Path, ".lrc");
        if (File.Exists(sidecar))
        {
            var l = LrcParser.Parse(await File.ReadAllTextAsync(sidecar, ct), "file", t.Duration);
            if (!l.IsEmpty) return l;
        }
        try
        {
            using var f = TagLib.File.Create(t.Path);
            var embedded = f.Tag.Lyrics;
            if (!string.IsNullOrWhiteSpace(embedded))
            {
                var l = LrcParser.Parse(embedded, "tag", t.Duration);
                if (!l.IsEmpty) return l;
            }
        }
        catch (Exception e) { Log.W("lyrics", $"tag read failed: {e.Message}"); }

        var cache = CachePath(t);
        if (File.Exists(cache))
        {
            var l = LrcParser.Parse(await File.ReadAllTextAsync(cache, ct), "cache", t.Duration);
            if (!l.IsEmpty) return l;
        }
        if (!_onlineEnabled()) return new Lyrics();
        try
        {
            var q = $"https://lrclib.net/api/get?track_name={Uri.EscapeDataString(t.Display)}&artist_name={Uri.EscapeDataString(t.Artist)}"
                  + $"&album_name={Uri.EscapeDataString(t.Album)}&duration={(int)Math.Round(t.Duration)}";
            LrclibItem? item = null;
            using (var resp = await Http.GetAsync(q, ct))
            {
                if (resp.IsSuccessStatusCode) item = await resp.Content.ReadFromJsonAsync<LrclibItem>(cancellationToken: ct);
            }
            if (item == null)
            {
                var s = $"https://lrclib.net/api/search?track_name={Uri.EscapeDataString(t.Display)}&artist_name={Uri.EscapeDataString(t.Artist)}";
                var list = await Http.GetFromJsonAsync<List<LrclibItem>>(s, ct);
                item = list?.Where(i => Math.Abs((i.Duration ?? 0) - t.Duration) < 5)
                            .OrderBy(i => string.IsNullOrWhiteSpace(i.SyncedLyrics) ? 1 : 0)
                            .ThenBy(i => Math.Abs((i.Duration ?? 0) - t.Duration)).FirstOrDefault();
            }
            var text = !string.IsNullOrWhiteSpace(item?.SyncedLyrics) ? item!.SyncedLyrics : item?.PlainLyrics;
            if (!string.IsNullOrWhiteSpace(text))
            {
                await File.WriteAllTextAsync(cache, text, ct);
                Log.I("lyrics", $"LRCLIB hit for {t}");
                return LrcParser.Parse(text, "lrclib", t.Duration);
            }
            Log.I("lyrics", $"no lyrics found for {t}");
        }
        catch (OperationCanceledException) { throw; }
        catch (Exception e) { Log.W("lyrics", $"LRCLIB failed: {e.Message}"); }
        return new Lyrics();
    }

    public Task SaveSidecarAsync(Track t, string lrcText) =>
        File.WriteAllTextAsync(System.IO.Path.ChangeExtension(t.Path, ".lrc"), lrcText);

    private sealed class LrclibItem
    {
        [JsonPropertyName("syncedLyrics")] public string? SyncedLyrics { get; set; }
        [JsonPropertyName("plainLyrics")] public string? PlainLyrics { get; set; }
        [JsonPropertyName("duration")] public double? Duration { get; set; }
    }
}
