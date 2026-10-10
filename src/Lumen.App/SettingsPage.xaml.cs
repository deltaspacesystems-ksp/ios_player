using Lumen.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.ApplicationModel.DataTransfer;

namespace Lumen.App;

/// <summary>Settings: a XAML page (so navigation can create it) whose rows are built in code.</summary>
public sealed partial class SettingsPage : Page
{
    private readonly StackPanel _root = new() { Spacing = 8, Padding = new Thickness(28, 12, 28, 40), MaxWidth = 900, HorizontalAlignment = HorizontalAlignment.Left };
    private StackPanel _folders = null!;

    private static readonly (string name, float[] gains)[] Presets =
    {
        ("Flat", new float[] { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }),
        ("Bass boost", new float[] { 7, 6, 4, 2, 0, 0, 0, 0, 0, 0 }),
        ("Vocal", new float[] { -2, -2, -1, 1, 3, 4, 3, 1, 0, -1 }),
        ("Treble", new float[] { 0, 0, 0, 0, 0, 1, 3, 5, 6, 7 }),
        ("Rock", new float[] { 5, 4, 2, -1, -2, -1, 2, 4, 5, 5 }),
        ("Electronic", new float[] { 6, 5, 1, 0, -2, 2, 1, 3, 5, 6 }),
    };

    public SettingsPage()
    {
        InitializeComponent();
        Host.Content = _root;
        Build();
    }

    private static TextBlock Header(string t) => new() { Text = t, FontSize = 20, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, Margin = new Thickness(0, 22, 0, 4) };
    private static TextBlock Note(string t) => new() { Text = t, Opacity = 0.65, FontSize = 12, TextWrapping = TextWrapping.Wrap };

    private FrameworkElement SliderRow(string title, double min, double max, double step, double value, Func<double, string> fmt, Action<double> set)
    {
        var label = new TextBlock { Text = fmt(value), Width = 90, TextAlignment = Microsoft.UI.Xaml.TextAlignment.Right, VerticalAlignment = VerticalAlignment.Center };
        var slider = new Slider { Minimum = min, Maximum = max, StepFrequency = step, Value = value, Width = 320, IsThumbToolTipEnabled = false };
        slider.ValueChanged += (_, e) => { label.Text = fmt(e.NewValue); set(e.NewValue); Svc.SaveSettings(); };
        var g = new Grid { ColumnSpacing = 12 };
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(230) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.Children.Add(new TextBlock { Text = title, VerticalAlignment = VerticalAlignment.Center });
        Grid.SetColumn(slider, 1); g.Children.Add(slider);
        Grid.SetColumn(label, 2); g.Children.Add(label);
        return g;
    }

    private FrameworkElement ToggleRow(string title, bool value, Action<bool> set, string? note = null)
    {
        var t = new ToggleSwitch { Header = title, IsOn = value, OnContent = "On", OffContent = "Off" };
        t.Toggled += (_, _) => { set(t.IsOn); Svc.SaveSettings(); };
        if (note == null) return t;
        var p = new StackPanel(); p.Children.Add(t); p.Children.Add(Note(note)); return p;
    }

    private FrameworkElement ComboRow(string title, string[] items, string current, Action<string> set)
    {
        var c = new ComboBox { Header = title, MinWidth = 220 };
        foreach (var i in items) c.Items.Add(i);
        c.SelectedItem = items.Contains(current) ? current : items[0];
        c.SelectionChanged += (_, _) => { if (c.SelectedItem is string s) { set(s); Svc.SaveSettings(); } };
        return c;
    }

    private void Build()
    {
        var s = Svc.Settings;
        _root.Children.Add(new TextBlock { Text = "Settings", FontSize = 30, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });

        // ---------------- library
        _root.Children.Add(Header("Library"));
        _folders = new StackPanel { Spacing = 4 };
        _root.Children.Add(_folders);
        RebuildFolders();
        var addBtn = new Button { Content = "Add folder…" };
        addBtn.Click += async (_, _) =>
        {
            var picker = new Windows.Storage.Pickers.FolderPicker();
            picker.FileTypeFilter.Add("*");
            WinRT.Interop.InitializeWithWindow.Initialize(picker, App.Window!.Hwnd);
            var f = await picker.PickSingleFolderAsync();
            if (f == null) return;
            if (!s.Folders.Contains(f.Path, StringComparer.OrdinalIgnoreCase)) s.Folders.Add(f.Path);
            Svc.SaveSettings(); RebuildFolders(); _ = Svc.RescanAsync();
        };
        _root.Children.Add(addBtn);

        // ---------------- playback
        _root.Children.Add(Header("Playback"));
        _root.Children.Add(SliderRow("Crossfade", 0, 20, 0.5, s.CrossfadeSeconds, v => v < 0.1 ? "Off (gapless)" : $"{v:0.#} s", v => s.CrossfadeSeconds = v));
        _root.Children.Add(ComboRow("Crossfade curve", new[] { "EqualPower", "Linear", "SCurve" }, s.Curve, v => s.Curve = v));
        _root.Children.Add(ToggleRow("Also crossfade when skipping tracks", s.CrossfadeOnSkip, v => s.CrossfadeOnSkip = v));
        _root.Children.Add(SliderRow("Skip fade", 0.3, 10, 0.1, s.SkipFadeSeconds, v => $"{v:0.0} s", v => s.SkipFadeSeconds = v));
        _root.Children.Add(ToggleRow("ReplayGain", s.UseReplayGain, v => s.UseReplayGain = v, "Normalises loudness using ReplayGain tags when present."));

        // ---------------- equalizer
        _root.Children.Add(Header("Equalizer"));
        var presetBar = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        var eqPanel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, Margin = new Thickness(0, 8, 0, 0) };
        string[] freqs = { "32", "64", "125", "250", "500", "1k", "2k", "4k", "8k", "16k" };
        var sliders = new Slider[10];
        for (int i = 0; i < 10; i++)
        {
            int idx = i;
            var sl = new Slider { Orientation = Orientation.Vertical, Minimum = -12, Maximum = 12, StepFrequency = 0.5, Height = 150, Value = s.EqGains[i], IsThumbToolTipEnabled = true };
            sl.ValueChanged += (_, e) => { s.EqGains[idx] = (float)e.NewValue; Svc.SaveSettings(); };
            sliders[i] = sl;
            var col = new StackPanel { Spacing = 4, HorizontalAlignment = HorizontalAlignment.Center };
            col.Children.Add(sl);
            col.Children.Add(new TextBlock { Text = freqs[i], FontSize = 11, Opacity = 0.7, HorizontalAlignment = HorizontalAlignment.Center });
            eqPanel.Children.Add(col);
        }
        foreach (var (name, gains) in Presets)
        {
            var b = new Button { Content = name, Padding = new Thickness(10, 3, 10, 3) };
            b.Click += (_, _) => { for (int i = 0; i < 10; i++) sliders[i].Value = gains[i]; };
            presetBar.Children.Add(b);
        }
        _root.Children.Add(presetBar);
        _root.Children.Add(eqPanel);
        _root.Children.Add(SliderRow("Preamp", -12, 12, 0.5, s.Preamp, v => $"{v:+0.0;-0.0;0.0} dB", v => s.Preamp = (float)v));

        // ---------------- spatial audio
        _root.Children.Add(Header("Spatial audio"));
        _root.Children.Add(ComboRow("Mode", new[] { "Off", "Stage", "Wide", "Surround", "Hall", "Spatial3D" }, s.SpatialMode, v => s.SpatialMode = v));
        _root.Children.Add(Note("Stage = best for speakers and headphones: solid bass, wider highs, extra air (mono-safe) · Wide = stereo width · Surround = cinema-style rear field · Hall = concert-hall reverb · Spatial3D = virtual speakers around you (best on headphones)."));
        _root.Children.Add(SliderRow("Amount", 0, 1, 0.05, s.SpatialAmount, v => $"{v * 100:0}%", v => s.SpatialAmount = (float)v));
        _root.Children.Add(SliderRow("Width", 0, 2, 0.05, s.SpatialWidth, v => $"{v:0.00}×", v => s.SpatialWidth = (float)v));
        _root.Children.Add(SliderRow("Room size", 0, 1, 0.05, s.SpatialRoom, v => $"{v * 100:0}%", v => s.SpatialRoom = (float)v));
        _root.Children.Add(ToggleRow("Headphone crossfeed", s.Crossfeed, v => s.Crossfeed = v, "Mixes a softened copy of each channel into the other ear, like listening to speakers."));

        // ---------------- lyrics
        _root.Children.Add(Header("Lyrics"));
        _root.Children.Add(ToggleRow("Fetch lyrics online (LRCLIB)", s.LyricsOnline, v => s.LyricsOnline = v, "Free, no account. Synced lyrics are cached next to the app data."));
        _root.Children.Add(ToggleRow("Prefetch lyrics for the next track", s.LyricsPrefetch, v => s.LyricsPrefetch = v, "Downloads and caches lyrics while the current song plays, so the next one starts with lyrics ready."));
        _root.Children.Add(ToggleRow("Extra source: NetEase (line-synced, unofficial)", s.LyricsNetEase, v => s.LyricsNetEase = v, "Used only when LRCLIB has no synced lyrics. Strict matching on title, artist and length."));
        BuildLyricsCache();
        _root.Children.Add(ToggleRow("Word-by-word karaoke highlight", s.LyricsKaraoke, v => s.LyricsKaraoke = v, "Exact when the lyrics file has word timings (enhanced LRC); otherwise estimated per line."));
        _root.Children.Add(SliderRow("Lyrics size", 0.6, 1.8, 0.05, s.LyricsFontScale, v => $"{v * 100:0}%", v => s.LyricsFontScale = v));

        // ---------------- visualizer
        _root.Children.Add(Header("Visualizer"));
        _root.Children.Add(ToggleRow("Spectrum on Now Playing", s.VizOn, v => s.VizOn = v));
        _root.Children.Add(SliderRow("Refresh rate", 1, 60, 1, s.VizFps, v => $"{v:0} fps", v => s.VizFps = (int)v));
        _root.Children.Add(SliderRow("Bars", 12, 96, 4, s.VizBars, v => $"{v:0}", v => s.VizBars = (int)v));
        _root.Children.Add(SliderRow("Sensitivity", 0.5, 2.5, 0.1, s.VizGain, v => $"{v:0.0}×", v => s.VizGain = v));

        // ---------------- appearance
        _root.Children.Add(Header("Appearance"));
        _root.Children.Add(ComboRow("Theme", new[] { "System", "Light", "Dark" }, s.Theme, v => s.Theme = v));
        _root.Children.Add(ComboRow("Window material", new[] { "Mica", "Acrylic", "None" }, s.Backdrop, v => s.Backdrop = v));

        // ---------------- diagnostics
        _root.Children.Add(Header("Diagnostics"));
        _root.Children.Add(ComboRow("Log level", new[] { "Debug", "Info", "Warning", "Error" }, s.LogLevel, v => s.LogLevel = v));
        var logBtns = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var export = new Button { Content = "Export log…" };
        export.Click += async (_, _) =>
        {
            var path = Log.Export();
            var f = await Windows.Storage.StorageFile.GetFileFromPathAsync(path);
            var dp = new DataPackage();
            dp.SetStorageItems(new[] { f });
            Clipboard.SetContent(dp);
            System.Diagnostics.Process.Start("explorer.exe", $"/select,\"{path}\"");
        };
        var open = new Button { Content = "Open log folder" };
        open.Click += (_, _) => System.Diagnostics.Process.Start("explorer.exe", Log.Directory);
        logBtns.Children.Add(export); logBtns.Children.Add(open);
        _root.Children.Add(logBtns);
        _root.Children.Add(Note("“Export log” copies a text file to the clipboard and shows it in Explorer, ready to send."));

        var tail = new TextBox { IsReadOnly = true, AcceptsReturn = true, TextWrapping = TextWrapping.NoWrap, Height = 220, FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Cascadia Mono"), FontSize = 11 };
        void Fill() => tail.Text = string.Join("\n", Log.Snapshot().TakeLast(120));
        Fill();
        ScrollViewer.SetHorizontalScrollBarVisibility(tail, ScrollBarVisibility.Auto);
        var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
        timer.Tick += (_, _) => Fill();
        Loaded += (_, _) => timer.Start();
        Unloaded += (_, _) => timer.Stop();
        _root.Children.Add(tail);
    }

    private void BuildLyricsCache()
    {
        var info = new TextBlock { Opacity = 0.75, FontSize = 12 };
        void Refresh() { var st = Svc.Lyrics.GetStats(); info.Text = $"Lyrics cache: {st.Files} songs ({st.Bytes / 1024.0:0} KB), {st.Negative} remembered as not found"; }
        Refresh();
        var status = new TextBlock { Opacity = 0.75, FontSize = 12 };
        var bulk = new Button { Content = "Download lyrics for the whole library" };
        var cancel = new Button { Content = "Cancel", Visibility = Visibility.Collapsed };
        var clear = new Button { Content = "Clear lyrics cache" };
        bulk.Click += async (_, _) =>
        {
            bulk.IsEnabled = false; cancel.Visibility = Visibility.Visible;
            var prog = new Progress<(int done, int total, int found)>(p => status.Text = $"{p.done}/{p.total} checked · {p.found} downloaded");
            await Svc.BulkLyricsAsync(prog);
            bulk.IsEnabled = true; cancel.Visibility = Visibility.Collapsed; Refresh();
        };
        cancel.Click += (_, _) => Svc.CancelBulkLyrics();
        clear.Click += (_, _) => { Svc.Lyrics.ClearCache(); Refresh(); status.Text = "Cache cleared"; };
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        row.Children.Add(bulk); row.Children.Add(cancel); row.Children.Add(clear);
        _root.Children.Add(info); _root.Children.Add(row); _root.Children.Add(status);
    }

    private void RebuildFolders()
    {
        _folders.Children.Clear();
        if (Svc.Settings.Folders.Count == 0) _folders.Children.Add(Note("No folders yet. Add the folders that contain your music."));
        foreach (var f in Svc.Settings.Folders.ToList())
        {
            var row = new Grid { ColumnSpacing = 8 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.Children.Add(new TextBlock { Text = f, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis });
            var rm = new Button { Content = "Remove" };
            rm.Click += (_, _) => { Svc.Settings.Folders.Remove(f); Svc.SaveSettings(); RebuildFolders(); _ = Svc.RescanAsync(); };
            Grid.SetColumn(rm, 1); row.Children.Add(rm);
            _folders.Children.Add(row);
        }
    }
}
