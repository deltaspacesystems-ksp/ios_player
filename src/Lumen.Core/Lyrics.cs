using System.Globalization;
using System.Text.RegularExpressions;
using System.Xml.Linq;

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

    /// <summary>0 = none, 1 = plain text, 2 = line-synced, 3 = word-synced (timings from the source).</summary>
    public int Quality => IsEmpty ? 0 : !Synced ? 1 : Lines.Any(l => l.WordsExact) ? 3 : 2;
    public string QualityLabel => Quality switch { 3 => "Word-synced", 2 => "Line-synced (words estimated)", 1 => "Plain text", _ => "" };

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
    private static readonly string Vowels = "aeiouyàáâãäåæèéêëìíîïòóôõöøùúûüýÿąęśźżAEIOUYÀÁÂÃÄÅÆÈÉÊËÌÍÎÏÒÓÔÕÖØÙÚÛÜÝĄĘ";

    /// <summary>Rough syllable count (vowel groups; every CJK character counts as one).</summary>
    public static double Syllables(string word)
    {
        int count = 0; bool inV = false, anyLetter = false;
        foreach (var ch in word)
        {
            if (ch >= 0x2E80) { count++; anyLetter = true; inV = false; continue; }      // CJK / kana / hangul
            if (char.IsLetter(ch))
            {
                anyLetter = true;
                bool v = Vowels.Contains(ch);
                if (v && !inV) count++;
                inV = v;
            }
            else inV = false;
        }
        if (!anyLetter) return 0.4;
        return Math.Max(1, count);
    }

    /// <summary>Spreads <paramref name="text"/> over [start, end] by syllable weight, so un-timed words still get a natural karaoke sweep.</summary>
    public static IReadOnlyList<LyricWord> Estimate(string text, double start, double end)
    {
        var parts = Regex.Matches(text, @"\S+\s*").Select(m => m.Value).ToList();
        if (parts.Count == 0) return Array.Empty<LyricWord>();
        double span = Math.Max(0.2, end - start);
        double syll = parts.Sum(p => Syllables(p));
        // a natural singing pace is ~0.24 s per syllable; never run into the next line
        double sing = Math.Min(span * 0.92, Math.Max(0.35, syll * 0.24));
        double total = parts.Sum(Weight);
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

    private static double Weight(string w)
    {
        var tw = w.TrimEnd();
        double pause = tw.EndsWith(',') ? 0.5 : tw.EndsWith('.') || tw.EndsWith('!') || tw.EndsWith('?') ? 0.9 : 0;
        return Syllables(w) + pause;
    }

    /// <summary>Fills in line ends and estimated words wherever the source gave no word timings.</summary>
    public static void Finish(List<LyricLine> lines, double trackDuration)
    {
        for (int i = 0; i < lines.Count; i++)
        {
            var l = lines[i];
            double end = i + 1 < lines.Count ? lines[i + 1].Time : (trackDuration > l.Time ? trackDuration : l.Time + 5);
            l.End = end;
            if (!l.WordsExact) l.Words = Estimate(l.Text, l.Time, end);
        }
    }
}

public static class LyricsFormat
{
    /// <summary>Picks a parser from the content: TTML (xml), YRC (<c>[ms,ms](ms,ms,0)word</c>) or LRC / enhanced LRC.</summary>
    public static Lyrics Parse(string text, string source, double trackDuration = 0)
    {
        var t = text.TrimStart('﻿', ' ', '\r', '\n', '\t');
        if (t.StartsWith('<') && t.Contains("<tt", StringComparison.OrdinalIgnoreCase)) return TtmlParser.Parse(t, source, trackDuration);
        if (Regex.IsMatch(t, @"^\[\d+,\d+\]\(\d+,\d+,\d+\)", RegexOptions.Multiline)) return YrcParser.Parse(t, source, trackDuration);
        return LrcParser.Parse(t, source, trackDuration);
    }
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
        LyricTiming.Finish(lines, trackDuration);
        return new Lyrics { Lines = lines, Synced = true, Source = source, Title = title, Artist = artist, OffsetSeconds = offset };
    }
}

/// <summary>NetEase / "YRC" word-level lyrics: <c>[lineStartMs,lineDurMs](wordStartMs,wordDurMs,0)word...</c></summary>
public static class YrcParser
{
    private static readonly Regex LineRx = new(@"^\[(\d+),(\d+)\](.*)$", RegexOptions.Compiled);
    private static readonly Regex WordRx = new(@"\((\d+),(\d+),-?\d+\)([^(]*)", RegexOptions.Compiled);

    public static Lyrics Parse(string text, string source = "", double trackDuration = 0)
    {
        var lines = new List<LyricLine>();
        foreach (var raw in text.Replace("\r\n", "\n").Split('\n'))
        {
            var m = LineRx.Match(raw.Trim());
            if (!m.Success) continue;
            double start = long.Parse(m.Groups[1].Value) / 1000.0;
            var words = new List<LyricWord>();
            foreach (Match w in WordRx.Matches(m.Groups[3].Value))
            {
                double ws = long.Parse(w.Groups[1].Value) / 1000.0;
                double wd = long.Parse(w.Groups[2].Value) / 1000.0;
                words.Add(new LyricWord(ws, ws + wd, w.Groups[3].Value));
            }
            if (words.Count == 0) continue;
            var l = new LyricLine { Time = start, Text = string.Concat(words.Select(x => x.Text)).Trim(), Words = words, WordsExact = true };
            lines.Add(l);
        }
        lines = lines.OrderBy(l => l.Time).ToList();
        LyricTiming.Finish(lines, trackDuration);
        return new Lyrics { Lines = lines, Synced = lines.Count > 0, Source = source };
    }
}

/// <summary>Apple-style TTML with per-word &lt;span begin end&gt; timings (also works for line-only TTML).</summary>
public static class TtmlParser
{
    public static double? Time(string? s)
    {
        if (string.IsNullOrWhiteSpace(s)) return null;
        s = s.Trim();
        var inv = CultureInfo.InvariantCulture;
        if (s.EndsWith("ms")) return double.TryParse(s[..^2], NumberStyles.Float, inv, out var ms) ? ms / 1000 : null;
        if (s.EndsWith('s')) return double.TryParse(s[..^1], NumberStyles.Float, inv, out var sec) ? sec : null;
        var parts = s.Split(':');
        double total = 0;
        foreach (var p in parts)
        {
            if (!double.TryParse(p, NumberStyles.Float, inv, out var v)) return null;
            total = total * 60 + v;
        }
        return total;
    }

    public static Lyrics Parse(string xml, string source = "", double trackDuration = 0)
    {
        XDocument doc;
        try { doc = XDocument.Parse(xml, LoadOptions.PreserveWhitespace); }
        catch { return new Lyrics(); }
        var lines = new List<LyricLine>();
        foreach (var p in doc.Descendants().Where(e => e.Name.LocalName == "p"))
        {
            var begin = Time((string?)p.Attribute("begin"));
            if (begin == null) continue;
            var words = new List<LyricWord>();
            bool sawTimedSpan = false;
            foreach (var node in p.Nodes())
            {
                if (node is XElement span && span.Name.LocalName == "span")
                {
                    var role = span.Attributes().FirstOrDefault(a => a.Name.LocalName == "role")?.Value;
                    var wb = Time((string?)span.Attribute("begin"));
                    var we = Time((string?)span.Attribute("end"));
                    var txt = span.Value;
                    if (wb != null && we != null && txt.Length > 0)
                    {
                        sawTimedSpan = true;
                        words.Add(new LyricWord(wb.Value, we.Value, role == "x-bg" ? "(" + txt.Trim() + ") " : txt));
                    }
                }
                else if (node is XText t && words.Count > 0 && t.Value.Length > 0)
                {
                    // whitespace between spans = the space after the previous word
                    var last = words[^1];
                    if (!last.Text.EndsWith(' ')) words[^1] = last with { Text = last.Text + " " };
                }
            }
            string text = sawTimedSpan ? string.Concat(words.Select(w => w.Text)).Trim() : p.Value.Trim();
            if (text.Length == 0) continue;
            var l = new LyricLine { Time = begin.Value, End = Time((string?)p.Attribute("end")) ?? 0, Text = text };
            if (sawTimedSpan) { l.Words = words; l.WordsExact = true; }
            lines.Add(l);
        }
        lines = lines.OrderBy(l => l.Time).ToList();
        LyricTiming.Finish(lines, trackDuration);
        return new Lyrics { Lines = lines, Synced = lines.Count > 0, Source = source };
    }
}
