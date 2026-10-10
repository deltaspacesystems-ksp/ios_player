using Lumen.Audio;
using Lumen.Core;
using Windows.Media;
using Windows.Media.Playback;
using Windows.Storage;
using Windows.Storage.Streams;

namespace Lumen.App;

/// <summary>Windows media overlay / lock screen / hardware media keys via SystemMediaTransportControls.</summary>
public sealed class SystemMedia
{
    private readonly MediaPlayer _player = new();
    private readonly SystemMediaTransportControls _smtc;
    private DateTime _lastTimeline = DateTime.MinValue;

    public SystemMedia()
    {
        _player.CommandManager.IsEnabled = false;       // we drive the controls ourselves
        _smtc = _player.SystemMediaTransportControls;
        _smtc.IsEnabled = true;
        _smtc.IsPlayEnabled = _smtc.IsPauseEnabled = _smtc.IsNextEnabled = _smtc.IsPreviousEnabled = _smtc.IsStopEnabled = true;
        _smtc.ButtonPressed += (_, e) => Svc.UI.TryEnqueue(() =>
        {
            switch (e.Button)
            {
                case SystemMediaTransportControlsButton.Play: Svc.Engine.Resume(); break;
                case SystemMediaTransportControlsButton.Pause: Svc.Engine.Pause(); break;
                case SystemMediaTransportControlsButton.Stop: Svc.Engine.Pause(); break;
                case SystemMediaTransportControlsButton.Next: Svc.Engine.Next(); break;
                case SystemMediaTransportControlsButton.Previous: Svc.Engine.Previous(); break;
            }
        });
        _smtc.PlaybackPositionChangeRequested += (_, e) => Svc.UI.TryEnqueue(() => Svc.Engine.Seek(e.RequestedPlaybackPosition.TotalSeconds));
        Svc.TrackChanged += (t, _) => UpdateTrack(t);
        Svc.PlaybackStateChanged += UpdateState;
        var timer = new Microsoft.UI.Xaml.DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        timer.Tick += (_, _) => UpdateTimeline();
        timer.Start();
        UpdateTrack(Svc.Engine.Current);
        UpdateState();
        Log.I("smtc", "system media controls ready");
    }

    private void UpdateState()
    {
        _smtc.PlaybackStatus = Svc.Engine.Current == null ? MediaPlaybackStatus.Closed
            : Svc.Engine.IsPlaying ? MediaPlaybackStatus.Playing : MediaPlaybackStatus.Paused;
        UpdateTimeline();
    }

    private async void UpdateTrack(Track? t)
    {
        try
        {
            var u = _smtc.DisplayUpdater;
            if (t == null) { u.ClearAll(); u.Update(); return; }
            u.Type = MediaPlaybackType.Music;
            u.MusicProperties.Title = t.Display;
            u.MusicProperties.Artist = t.Artist;
            u.MusicProperties.AlbumTitle = t.Album;
            if (!string.IsNullOrEmpty(t.ArtPath) && File.Exists(t.ArtPath))
            {
                var f = await StorageFile.GetFileFromPathAsync(t.ArtPath);
                u.Thumbnail = RandomAccessStreamReference.CreateFromFile(f);
            }
            else u.Thumbnail = null;
            u.Update();
            UpdateTimeline();
        }
        catch (Exception e) { Log.W("smtc", e.Message); }
    }

    private void UpdateTimeline()
    {
        try
        {
            var e = Svc.Engine;
            if (e.Duration <= 0) return;
            _smtc.UpdateTimelineProperties(new SystemMediaTransportControlsTimelineProperties
            {
                StartTime = TimeSpan.Zero,
                MinSeekTime = TimeSpan.Zero,
                MaxSeekTime = TimeSpan.FromSeconds(e.Duration),
                EndTime = TimeSpan.FromSeconds(e.Duration),
                Position = TimeSpan.FromSeconds(Math.Min(e.Position, e.Duration)),
            });
        }
        catch { /* best effort */ }
    }
}
