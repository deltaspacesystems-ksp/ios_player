using Lumen.Core;
using Xunit;

namespace Lumen.Tests;

public class LyricsTests
{
    private const string Lrc = """
        [ti:Song]
        [ar:Artist]
        [offset:500]
        [00:01.00]First line here
        [00:05.50]Second <00:05.50>line <00:06.20>words
        [00:10.00][00:20.00]Repeated chorus
        """;

    [Fact]
    public void Parses_headers_lines_and_repeats()
    {
        var l = LrcParser.Parse(Lrc, "test", 30);
        Assert.True(l.Synced);
        Assert.Equal("Song", l.Title);
        Assert.Equal("Artist", l.Artist);
        Assert.Equal(0.5, l.OffsetSeconds, 3);
        Assert.Equal(4, l.Lines.Count);                 // 1 + 1 + 2 (repeated chorus)
        Assert.Equal(new[] { 1.0, 5.5, 10.0, 20.0 }, l.Lines.Select(x => x.Time).ToArray());
    }

    [Fact]
    public void Index_follows_playback_time_with_offset()
    {
        var l = LrcParser.Parse(Lrc, "test", 30);
        Assert.Equal(-1, l.IndexAt(0.0));
        Assert.Equal(0, l.IndexAt(0.6));                // 0.6 + 0.5 offset = 1.1 >= 1.0
        Assert.Equal(1, l.IndexAt(5.2));
        Assert.Equal(2, l.IndexAt(9.6));
        Assert.Equal(3, l.IndexAt(25));
        Assert.Equal(2, l.IndexAt(19.0, userOffset: -1.0));
    }

    [Fact]
    public void Exact_word_timings_are_kept_and_missing_ones_are_estimated()
    {
        var l = LrcParser.Parse(Lrc, "test", 30);
        var exact = l.Lines[1];
        Assert.True(exact.WordsExact);
        Assert.Equal(3, exact.Words.Count);
        Assert.Equal(6.2, exact.Words[2].Time, 2);

        var est = l.Lines[0];
        Assert.False(est.WordsExact);
        Assert.Equal(3, est.Words.Count);
        Assert.True(est.Words[0].Time >= est.Time);
        Assert.True(est.Words[^1].End <= est.End);
        for (int i = 1; i < est.Words.Count; i++) Assert.True(est.Words[i].Time >= est.Words[i - 1].End - 1e-6);
    }

    [Fact]
    public void Unsynced_text_is_not_marked_synced()
    {
        var l = LrcParser.Parse("just some words\nand more words", "tag");
        Assert.False(l.Synced);
        Assert.Equal(2, l.Lines.Count);
        Assert.Equal(-1, l.IndexAt(10));
    }
}
