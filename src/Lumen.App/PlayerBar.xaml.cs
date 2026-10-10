using Lumen.Audio;
using Lumen.Core;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;

namespace Lumen.App;

public sealed partial class PlayerBar : UserControl
{
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromMilliseconds(100) };
    private bool _dragging, _settingValue;
    private float _volBeforeMute = 0.8f;

    public PlayerBar()
    {
        InitializeComponent();
        SeekSlider.AddHandler(PointerPressedEvent, new PointerEventHandler((_, _) => _dragging = true), true);
        SeekSlider.AddHandler(PointerReleasedEvent, new PointerEventHandler((_, _) => CommitSeek()), true);
        SeekSlider.AddHandler(PointerCaptureLostEvent, new PointerEventHandler((_, _) => CommitSeek()), true);
        SeekSlider.AddHandler(KeyUpEvent, new KeyEventHandler((_, _) => CommitSeek()), true);

        Svc.TrackChanged += (t, _) => SetTrack(t);
        Svc.PlaybackStateChanged += UpdateState;
        Svc.SettingsChanged += UpdateSettings;
        _timer.Tick += (_, _) => Tick();
        Loaded += (_, _) => { _timer.Start(); UpdateSettings(); UpdateState(); SetTrack(Svc.Engine.Current); };
        Unloaded += (_, _) => _timer.Stop();
    }

    private async void SetTrack(Track? t)
    {
        TitleText.Text = t?.Display ?? "Nothing playing";
        ArtistText.Text = t == null ? "" : t.ArtistDisplay + (string.IsNullOrWhiteSpace(t.Album) ? "" : " — " + t.Album);
        DurText.Text = TrackVM.FormatTime(Svc.Engine.Duration > 0 ? Svc.Engine.Duration : t?.Duration ?? 0);
        ArtImage.Source = t == null ? null : await ArtLoader.LoadAsync(t.ArtPath, 128);
        UpdateState();
    }

    private void UpdateState()
    {
        var e = Svc.Engine;
        PlayIcon.Glyph = e.IsPlaying ? "" : "";
        ShuffleBtn.IsChecked = e.Shuffle;
        RepeatIcon.Glyph = e.Repeat == RepeatMode.One ? "" : "";
        RepeatBtn.Opacity = e.Repeat == RepeatMode.Off ? 0.55 : 1;
        SleepBtn.Opacity = e.SleepAt != null || e.SleepAtEndOfTrack ? 1 : 0.55;
        ToolTipService.SetToolTip(SleepBtn, e.SleepAt is DateTime at ? $"Sleep at {at.ToLocalTime():HH:mm}" : e.SleepAtEndOfTrack ? "Sleep after this track" : "Sleep timer");
    }

    private void UpdateSettings()
    {
        _settingValue = true;
        VolSlider.Value = Svc.Settings.Volume * 100;
        _settingValue = false;
        VolIcon.Glyph = Svc.Settings.Volume <= 0.001 ? "" : "";
        SpatialBtn.Opacity = Svc.Settings.SpatialMode == "Off" ? 0.55 : 1;
        if (SpatialBtn.Flyout is MenuFlyout mf)
            foreach (var it in mf.Items.OfType<RadioMenuFlyoutItem>()) it.IsChecked = (string)it.Tag == Svc.Settings.SpatialMode;
        var s = Svc.Settings.CrossfadeSeconds;
        XfadeText.Text = s < 0.1 ? "Gapless" : $"{s:0.#} s";
    }

    private void Tick()
    {
        var e = Svc.Engine;
        double dur = e.Duration, pos = e.Position;
        PosText.Text = TrackVM.FormatTime(pos);
        DurText.Text = TrackVM.FormatTime(dur);
        if (!_dragging && dur > 0)
        {
            _settingValue = true;
            SeekSlider.Value = Math.Clamp(pos / dur * 1000, 0, 1000);
            _settingValue = false;
        }
    }

    private void CommitSeek()
    {
        if (!_dragging) return;
        _dragging = false;
        var dur = Svc.Engine.Duration;
        if (dur > 0) Svc.Engine.Seek(SeekSlider.Value / 1000 * dur);
    }

    private void Seek_ValueChanged(object sender, Microsoft.UI.Xaml.Controls.Primitives.RangeBaseValueChangedEventArgs e)
    {
        if (_settingValue) return;
        var dur = Svc.Engine.Duration;
        if (dur <= 0) return;
        if (_dragging) PosText.Text = TrackVM.FormatTime(e.NewValue / 1000 * dur);
        else Svc.Engine.Seek(e.NewValue / 1000 * dur);      // keyboard / click without pointer capture
    }

    private void Vol_ValueChanged(object sender, Microsoft.UI.Xaml.Controls.Primitives.RangeBaseValueChangedEventArgs e)
    {
        if (_settingValue) return;
        Svc.Settings.Volume = (float)(e.NewValue / 100);
        Svc.Engine.SetVolume(Svc.Settings.Volume);
        VolIcon.Glyph = Svc.Settings.Volume <= 0.001 ? "" : "";
    }

    private void Mute_Click(object sender, RoutedEventArgs e)
    {
        if (Svc.Settings.Volume > 0.001) { _volBeforeMute = Svc.Settings.Volume; VolSlider.Value = 0; }
        else VolSlider.Value = _volBeforeMute * 100;
    }

    private void Play_Click(object sender, RoutedEventArgs e) => Svc.Engine.Toggle();
    private void Next_Click(object sender, RoutedEventArgs e) => Svc.Engine.Next();
    private void Prev_Click(object sender, RoutedEventArgs e) => Svc.Engine.Previous();
    private void Shuffle_Click(object sender, RoutedEventArgs e) { Svc.Engine.ToggleShuffle(); UpdateState(); }

    private void Repeat_Click(object sender, RoutedEventArgs e)
    {
        Svc.Engine.Repeat = Svc.Engine.Repeat switch { RepeatMode.Off => RepeatMode.All, RepeatMode.All => RepeatMode.One, _ => RepeatMode.Off };
        UpdateState();
    }

    private void Spatial_Click(object sender, RoutedEventArgs e)
    {
        Svc.Settings.SpatialMode = (string)((RadioMenuFlyoutItem)sender).Tag;
        Svc.SaveSettings();
    }

    private void Sleep_Click(object sender, RoutedEventArgs e)
    {
        switch ((string)((MenuFlyoutItem)sender).Tag)
        {
            case "off": Svc.Engine.SetSleep(null); break;
            case "end": Svc.Engine.SetSleep(null, atEndOfTrack: true); break;
            case var m: Svc.Engine.SetSleep(TimeSpan.FromMinutes(int.Parse(m))); break;
        }
        UpdateState();
    }

    private void Info_Click(object sender, RoutedEventArgs e) => App.Window?.Navigate("now");
    private void Xfade_Click(object sender, RoutedEventArgs e) => App.Window?.Navigate("settings");
}
