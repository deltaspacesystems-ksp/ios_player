using Lumen.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Storage.Pickers;
using WinRT.Interop;

namespace Lumen.App;

public sealed partial class NowPlayingPage : Page
{
    private readonly SpectrumAnalyzer _fft = new(2048);
    private readonly float[] _tap = new float[2048];
    private DateTime _lastViz = DateTime.UtcNow;
    private Track? _shown;

    public NowPlayingPage()
    {
        InitializeComponent();
        Loaded += (_, _) =>
        {
            Svc.TrackChanged += OnTrack;
            Svc.LyricsChanged += OnLyrics;
            Svc.SettingsChanged += OnSettings;
            Microsoft.UI.Xaml.Media.CompositionTarget.Rendering += OnFrame;
            OnTrack(Svc.Engine.Current, Svc.Engine.Index);
            OnLyrics();
            OnSettings();
        };
        Unloaded += (_, _) =>
        {
            Svc.TrackChanged -= OnTrack;
            Svc.LyricsChanged -= OnLyrics;
            Svc.SettingsChanged -= OnSettings;
            Microsoft.UI.Xaml.Media.CompositionTarget.Rendering -= OnFrame;
        };
    }

    private void OnSettings()
    {
        Viz.Visibility = Svc.Settings.VizOn ? Visibility.Visible : Visibility.Collapsed;
        OnLyrics();
    }

    private async void OnTrack(Track? t, int _)
    {
        _shown = t;
        TitleText.Text = t?.Display ?? "Nothing playing";
        ArtistText.Text = t?.ArtistDisplay ?? "";
        AlbumText.Text = t?.AlbumDisplay ?? "";
        BigArt.Source = t == null ? null : await ArtLoader.LoadAsync(t.ArtPath, 720);
        BgImage.Source = t == null ? null : await ArtLoader.LoadAsync(t.ArtPath, 24);
        UpdateOffsetText();
    }

    private void OnLyrics()
    {
        string hint = Svc.Settings.LyricsOnline
            ? "No lyrics found for this track.\nYou can import an .lrc file below."
            : "No lyrics in tags or next to the file.\nOnline lyrics are off (Settings → Lyrics).";
        Lyr.Show(Svc.CurrentLyrics, Svc.LyricsLoading, Svc.Settings.LyricsFontScale, hint);
        SourceText.Text = Svc.CurrentLyrics is { IsEmpty: false } l ? $"{(l.Synced ? "Synced" : "Plain")} · {l.Source}" : "";
    }

    private void OnFrame(object? sender, object e)
    {
        var eng = Svc.Engine;
        double pos = Math.Max(0, eng.Position - eng.OutputLatencySeconds);
        Lyr.Tick(pos, Svc.LyricOffset(_shown), Svc.Settings.LyricsKaraoke);

        if (!Svc.Settings.VizOn) return;
        var now = DateTime.UtcNow;
        double dt = (now - _lastViz).TotalSeconds;
        if (dt < 1.0 / Math.Clamp(Svc.Settings.VizFps, 1, 60) * 0.9) return;
        _lastViz = now;
        eng.Mixer.CopyTap(_tap);
        var bars = _fft.Compute(_tap, Math.Clamp(Svc.Settings.VizBars, 8, 128), 48000, (float)Svc.Settings.VizGain, dt);
        Viz.Update(bars);
    }

    private void UpdateOffsetText() => OffText.Text = $"{Svc.LyricOffset(_shown):+0.0;-0.0;0.0} s";

    private void Off_Click(object sender, RoutedEventArgs e)
    {
        if (_shown == null) return;
        var tag = (string)((Button)sender).Tag;
        double cur = Svc.LyricOffset(_shown);
        double next = tag == "reset" ? 0 : Math.Round(cur + double.Parse(tag, System.Globalization.CultureInfo.InvariantCulture), 2);
        Svc.SetLyricOffset(_shown, next);
        UpdateOffsetText();
    }

    private async void Import_Click(object sender, RoutedEventArgs e)
    {
        if (_shown == null) return;
        var picker = new FileOpenPicker();
        picker.FileTypeFilter.Add(".lrc");
        picker.FileTypeFilter.Add(".txt");
        InitializeWithWindow.Initialize(picker, App.Window!.Hwnd);
        var file = await picker.PickSingleFileAsync();
        if (file == null) return;
        var text = await File.ReadAllTextAsync(file.Path);
        await Svc.Lyrics.SaveSidecarAsync(_shown, text);
        Log.I("lyrics", $"imported {file.Name} for {_shown}");
        await Svc.LoadLyricsAsync(_shown);
    }
}
