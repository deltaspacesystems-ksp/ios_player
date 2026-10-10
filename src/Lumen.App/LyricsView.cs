using Lumen.Core;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using System.Numerics;
using Windows.UI;

namespace Lumen.App;

/// <summary>
/// Apple-Music-style lyrics: active line centered and bright, neighbours dimmed, smooth scrolling,
/// word-by-word karaoke sweep (exact timings from enhanced LRC, otherwise estimated), tap a line to seek.
/// </summary>
public sealed class LyricsView : UserControl
{
    private sealed class Row
    {
        public required LyricLine Line;
        public required TextBlock Text;
        public List<(Run run, LinearGradientBrush brush, LyricWord word)> Words = new();
        public bool Karaoke;
    }

    private static readonly Color Lit = Colors.White;
    private static readonly Color Dim = Color.FromArgb(0x59, 0xFF, 0xFF, 0xFF);

    private readonly ScrollViewer _sv = new() { VerticalScrollBarVisibility = ScrollBarVisibility.Hidden, VerticalScrollMode = ScrollMode.Enabled, HorizontalScrollMode = ScrollMode.Disabled };
    private readonly StackPanel _panel = new() { Spacing = 10 };
    private readonly TextBlock _status = new() { Foreground = new SolidColorBrush(Color.FromArgb(0xB0, 255, 255, 255)), FontSize = 18, TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center };
    private readonly List<Row> _rows = new();
    private Lumen.Core.Lyrics? _lyrics;
    private int _cur = -2;
    private double _scale = 1;

    public LyricsView()
    {
        var host = new Grid();
        _sv.Content = _panel;
        host.Children.Add(_sv);
        host.Children.Add(_status);
        Content = host;
        SizeChanged += (_, e) =>
        {
            double pad = Math.Max(40, e.NewSize.Height / 2 - 30);
            _panel.Padding = new Thickness(8, pad, 8, pad);
        };
    }

    public void Show(Lumen.Core.Lyrics? lyrics, bool loading, double fontScale, string? emptyHint = null)
    {
        _lyrics = lyrics;
        _scale = fontScale;
        _rows.Clear();
        _panel.Children.Clear();
        _cur = -2;
        _sv.ChangeView(null, 0, null, true);

        if (loading) { _status.Text = "Looking for lyrics…"; _status.Visibility = Visibility.Visible; return; }
        if (lyrics == null || lyrics.IsEmpty) { _status.Text = emptyHint ?? "No lyrics found"; _status.Visibility = Visibility.Visible; return; }
        _status.Visibility = Visibility.Collapsed;

        foreach (var line in lyrics.Lines)
        {
            var tb = new TextBlock
            {
                Text = line.Text.Length == 0 ? "♪" : line.Text,
                FontSize = 30 * fontScale,
                FontWeight = Microsoft.UI.Text.FontWeights.Bold,
                TextWrapping = TextWrapping.Wrap,
                Foreground = new SolidColorBrush(lyrics.Synced ? Dim : Color.FromArgb(0xE6, 255, 255, 255)),
                Opacity = lyrics.Synced ? 0.55 : 1,
                Margin = new Thickness(6, 4, 6, 4),
            };
            tb.OpacityTransition = new ScalarTransition { Duration = TimeSpan.FromMilliseconds(350) };
            tb.ScaleTransition = new Vector3Transition { Duration = TimeSpan.FromMilliseconds(350) };
            tb.CenterPoint = new Vector3(0, 20, 0);
            var row = new Row { Line = line, Text = tb };
            if (lyrics.Synced)
            {
                tb.Tapped += (_, _) => Svc.Engine.Seek(Math.Max(0, line.Time - lyrics.OffsetSeconds - Svc.LyricOffset(Svc.Engine.Current)));
                tb.PointerEntered += (_, _) => { if (!ReferenceEquals(_rows.ElementAtOrDefault(_cur), row)) tb.Opacity = 0.8; };
                tb.PointerExited += (_, _) => { if (!ReferenceEquals(_rows.ElementAtOrDefault(_cur), row)) tb.Opacity = DistanceOpacity(_rows.IndexOf(row)); };
            }
            _rows.Add(row);
            _panel.Children.Add(tb);
        }
    }

    private static double Distance(int i, int cur) => Math.Abs(i - cur);
    private double DistanceOpacity(int i) => _cur < 0 ? 0.55 : Math.Max(0.18, 0.62 - 0.12 * (Distance(i, _cur) - 1));

    /// <summary>Called every frame with the playback position (already compensated for output latency).</summary>
    public void Tick(double position, double userOffset, bool karaoke)
    {
        if (_lyrics == null || !_lyrics.Synced || _rows.Count == 0) return;
        double t = _lyrics.LyricTime(position, userOffset);
        int idx = _lyrics.IndexAt(position, userOffset);

        if (idx != _cur)
        {
            int prev = _cur;
            _cur = idx;
            if (prev >= 0 && prev < _rows.Count) Deactivate(_rows[prev]);
            for (int i = 0; i < _rows.Count; i++)
            {
                var r = _rows[i];
                if (i == idx) continue;
                r.Text.Opacity = DistanceOpacity(i);
                r.Text.Scale = new Vector3(1, 1, 1);
            }
            if (idx >= 0)
            {
                var r = _rows[idx];
                Activate(r, karaoke);
                ScrollTo(r);
            }
        }
        if (idx >= 0 && idx < _rows.Count) UpdateKaraoke(_rows[idx], t);
    }

    private void Activate(Row r, bool karaoke)
    {
        r.Text.Opacity = 1;
        r.Text.Scale = new Vector3(1.04f, 1.04f, 1);
        if (!karaoke || r.Line.Words.Count == 0)
        {
            r.Text.Foreground = new SolidColorBrush(Lit);
            return;
        }
        r.Karaoke = true;
        r.Words.Clear();
        r.Text.Inlines.Clear();
        foreach (var w in r.Line.Words)
        {
            var brush = new LinearGradientBrush { StartPoint = new Windows.Foundation.Point(0, 0.5), EndPoint = new Windows.Foundation.Point(1, 0.5) };
            brush.GradientStops.Add(new GradientStop { Color = Lit, Offset = 0 });
            brush.GradientStops.Add(new GradientStop { Color = Lit, Offset = 0 });
            brush.GradientStops.Add(new GradientStop { Color = Dim, Offset = 0.0001 });
            brush.GradientStops.Add(new GradientStop { Color = Dim, Offset = 1 });
            var run = new Run { Text = w.Text, Foreground = brush };
            r.Text.Inlines.Add(run);
            r.Words.Add((run, brush, w));
        }
    }

    private void Deactivate(Row r)
    {
        if (r.Karaoke)
        {
            r.Karaoke = false;
            r.Words.Clear();
            r.Text.Inlines.Clear();
            r.Text.Text = r.Line.Text.Length == 0 ? "♪" : r.Line.Text;
        }
        r.Text.Foreground = new SolidColorBrush(Dim);
    }

    private static void UpdateKaraoke(Row r, double t)
    {
        if (!r.Karaoke) return;
        foreach (var (_, brush, w) in r.Words)
        {
            double p = w.End <= w.Time ? (t >= w.Time ? 1 : 0) : Math.Clamp((t - w.Time) / (w.End - w.Time), 0, 1);
            // soft-edged sweep: lit part up to p, short fade, dim remainder
            double edge = Math.Min(1, p + 0.12 * (p > 0 && p < 1 ? 1 : 0));
            brush.GradientStops[0].Offset = 0;
            brush.GradientStops[1].Offset = p;
            brush.GradientStops[2].Offset = Math.Max(p + 0.0001, edge);
            brush.GradientStops[3].Offset = 1;
            // fully sung words stay lit, unsung stay dim
            if (p >= 1) { brush.GradientStops[1].Offset = 1; brush.GradientStops[2].Offset = 1; }
            if (p <= 0) { brush.GradientStops[1].Offset = 0; brush.GradientStops[2].Offset = 0.0001; }
        }
    }

    private void ScrollTo(Row r)
    {
        try
        {
            var y = r.Text.TransformToVisual(_panel).TransformPoint(new Windows.Foundation.Point(0, 0)).Y;
            double target = y + r.Text.ActualHeight / 2 - _sv.ViewportHeight / 2;
            _sv.ChangeView(null, Math.Max(0, target), null, false);
        }
        catch { /* layout not ready yet */ }
    }
}
