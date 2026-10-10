using Lumen.Audio;
using Lumen.Core;
using Microsoft.UI.Dispatching;

namespace Lumen.App;

/// <summary>Application-wide services (engine, settings, library, lyrics). Everything UI-facing is raised on the UI thread.</summary>
public static class Svc
{
    public static DispatcherQueue UI { get; private set; } = null!;
    public static string DataDir { get; private set; } = "";
    public static AppSettings Settings { get; private set; } = new();
    public static AudioEngine Engine { get; private set; } = null!;
    public static LibraryScanner Scanner { get; private set; } = null!;
    public static LyricsService Lyrics { get; private set; } = null!;
    public static List<Track> Library { get; private set; } = new();

    public static Lumen.Core.Lyrics? CurrentLyrics { get; private set; }
    public static bool LyricsLoading { get; private set; }
    public static bool Scanning { get; private set; }

    public static event Action? LibraryChanged;
    public static event Action? LyricsChanged;
    public static event Action? SettingsChanged;
    public static event Action<(int done, int total)>? ScanProgress;
    public static event Action<Track?, int>? TrackChanged;
    public static event Action? PlaybackStateChanged;

    private static CancellationTokenSource? _lyricsCts;

    public static void Init(DispatcherQueue ui)
    {
        UI = ui;
        DataDir = Environment.GetEnvironmentVariable("LUMEN_DATA")
                  ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Lumen");
        Directory.CreateDirectory(DataDir);
        Log.Init(Path.Combine(DataDir, "logs"));
        Settings = AppSettings.Load(Path.Combine(DataDir, "settings.json"));
        Log.Min = Enum.TryParse<Lumen.Core.LogLevel>(Settings.LogLevel, out var lv) ? lv : Lumen.Core.LogLevel.Info;

        Scanner = new LibraryScanner(DataDir);
        Lyrics = new LyricsService(Path.Combine(DataDir, "lyrics"), () => Settings.LyricsOnline);
        Library = Scanner.LoadCached();

        Engine = new AudioEngine();
        Engine.TrackChanged += (t, i) => UI.TryEnqueue(() => { TrackChanged?.Invoke(t, i); _ = LoadLyricsAsync(t); });
        Engine.StateChanged += () => UI.TryEnqueue(() => PlaybackStateChanged?.Invoke());
        Engine.Error += msg => Log.E("engine", msg);
        ApplySettings();
        Log.I("app", $"library: {Library.Count} cached tracks, {Settings.Folders.Count} folder(s)");
        _ = RescanAsync();
    }

    public static void ApplySettings()
    {
        var e = Engine.Settings;
        e.CrossfadeSeconds = Settings.CrossfadeSeconds;
        e.Curve = Enum.TryParse<FadeCurve>(Settings.Curve, out var c) ? c : FadeCurve.EqualPower;
        e.CrossfadeOnSkip = Settings.CrossfadeOnSkip;
        e.SkipFadeSeconds = Settings.SkipFadeSeconds;
        e.UseReplayGain = Settings.UseReplayGain;
        Engine.SetVolume(Settings.Volume);
        Engine.Mixer.SetEq(Settings.EqGains, Settings.Preamp);
        Log.Min = Enum.TryParse<Lumen.Core.LogLevel>(Settings.LogLevel, out var lv) ? lv : Lumen.Core.LogLevel.Info;
        SettingsChanged?.Invoke();
    }

    public static void SaveSettings() { Settings.Save(); ApplySettings(); }

    private static bool _scanAgain;

    public static async Task RescanAsync()
    {
        if (Scanning) { _scanAgain = true; while (Scanning) await Task.Delay(50); return; }
        Scanning = true;
        try
        {
            do
            {
                _scanAgain = false;
                var progress = new Progress<(int, int)>(p => UI.TryEnqueue(() => ScanProgress?.Invoke(p)));
                var list = await Task.Run(() => Scanner.ScanAsync(Settings.Folders, Library, progress));
                Library = list;
            } while (_scanAgain);
        }
        catch (Exception e) { Log.E("library", $"scan failed: {e.Message}"); }
        finally { Scanning = false; }
        UI.TryEnqueue(() => LibraryChanged?.Invoke());
    }

    public static async Task LoadLyricsAsync(Track? t)
    {
        _lyricsCts?.Cancel();
        CurrentLyrics = null;
        if (t == null) { LyricsLoading = false; LyricsChanged?.Invoke(); return; }
        var cts = _lyricsCts = new CancellationTokenSource();
        LyricsLoading = true;
        LyricsChanged?.Invoke();
        try
        {
            var l = await Lyrics.GetAsync(t, cts.Token);
            if (cts.IsCancellationRequested) return;
            CurrentLyrics = l;
        }
        catch (OperationCanceledException) { return; }
        catch (Exception e) { Log.W("lyrics", e.Message); }
        LyricsLoading = false;
        LyricsChanged?.Invoke();
    }

    public static double LyricOffset(Track? t) => t != null && Settings.LyricsOffsets.TryGetValue(t.Path, out var v) ? v : 0;

    public static void SetLyricOffset(Track t, double seconds)
    {
        if (Math.Abs(seconds) < 0.001) Settings.LyricsOffsets.Remove(t.Path); else Settings.LyricsOffsets[t.Path] = seconds;
        Settings.Save();
    }
}
