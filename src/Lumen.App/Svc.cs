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
    private static System.Threading.Timer? _sessionTimer;

    public static void Init(DispatcherQueue ui)
    {
        UI = ui;
        DataDir = Environment.GetEnvironmentVariable("LUMEN_DATA")
                  ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Lumen");
        Directory.CreateDirectory(DataDir);
        Log.Init(Path.Combine(DataDir, "logs"));
        Settings = AppSettings.Load(Path.Combine(DataDir, "settings.json"));
        Log.Min = Enum.TryParse<Lumen.Core.LogLevel>(Settings.LogLevel, out var lv) ? lv : Lumen.Core.LogLevel.Info;

        Scanner = new LibraryScanner(DataDir) { Fallback = Lumen.Audio.FfmpegProbe.Read };
        Lyrics = new LyricsService(Path.Combine(DataDir, "lyrics"), () => new LyricsOptions(Settings.LyricsOnline, Settings.LyricsNetEase));
        Library = Scanner.LoadCached();

        Engine = new AudioEngine();
        Engine.TrackChanged += (t, i) => UI.TryEnqueue(() => { TrackChanged?.Invoke(t, i); _ = LoadLyricsAsync(t); });
        Engine.StateChanged += () => UI.TryEnqueue(() => PlaybackStateChanged?.Invoke());
        Engine.Error += msg => Log.E("engine", msg);
        ApplySettings();
        Log.I("app", $"library: {Library.Count} cached tracks, {Settings.Folders.Count} folder(s)");
        RestoreSession();
        _ = RescanAsync();
        _sessionTimer = new System.Threading.Timer(_ => SaveSession(), null, 15000, 15000);
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
        var sp = Engine.Mixer.Spatial;
        sp.Amount = Settings.SpatialAmount; sp.Width = Settings.SpatialWidth; sp.Room = Settings.SpatialRoom; sp.Crossfeed = Settings.Crossfeed;
        sp.Mode = Enum.TryParse<SpatialMode>(Settings.SpatialMode, out var sm) ? sm : SpatialMode.Off;
        Log.Min = Enum.TryParse<Lumen.Core.LogLevel>(Settings.LogLevel, out var lv) ? lv : Lumen.Core.LogLevel.Info;
        SettingsChanged?.Invoke();
    }

    // ---------------------------------------------------------------- opening files / session

    public static List<Track> TracksFromPaths(IEnumerable<string> paths)
    {
        var files = new List<string>();
        foreach (var p in paths)
        {
            if (Directory.Exists(p)) files.AddRange(Directory.EnumerateFiles(p, "*.*", SearchOption.AllDirectories).Where(AudioExt.IsAudio).OrderBy(x => x, StringComparer.OrdinalIgnoreCase));
            else if (File.Exists(p) && AudioExt.IsAudio(p)) files.Add(p);
        }
        var byPath = Library.GroupBy(t => t.Path, StringComparer.OrdinalIgnoreCase).ToDictionary(g => g.Key, g => g.First(), StringComparer.OrdinalIgnoreCase);
        return files.Select(f => byPath.TryGetValue(f, out var t) ? t : Scanner.ReadTrack(f)).ToList();
    }

    public static void PlayFiles(IEnumerable<string> paths)
    {
        var list = TracksFromPaths(paths);
        if (list.Count == 0) return;
        Log.I("app", $"open {list.Count} file(s)");
        Engine.SetQueue(list, 0);
    }

    private sealed class SessionData
    {
        public List<string> Paths { get; set; } = new();
        public int Index { get; set; }
        public double Position { get; set; }
        public bool Shuffle { get; set; }
        public string Repeat { get; set; } = "Off";
    }

    private static string SessionFile => Path.Combine(DataDir, "session.json");

    public static void SaveSession()
    {
        try
        {
            var q = Engine.Queue;
            if (q.Count == 0) return;
            var d = new SessionData { Paths = q.Select(t => t.Path).ToList(), Index = Engine.Index, Position = Engine.Position, Shuffle = Engine.Shuffle, Repeat = Engine.Repeat.ToString() };
            File.WriteAllText(SessionFile, System.Text.Json.JsonSerializer.Serialize(d));
        }
        catch (Exception e) { Log.W("session", $"save failed: {e.Message}"); }
    }

    public static void RestoreSession()
    {
        try
        {
            if (!File.Exists(SessionFile) || Engine.Queue.Count > 0) return;
            var d = System.Text.Json.JsonSerializer.Deserialize<SessionData>(File.ReadAllText(SessionFile));
            if (d == null || d.Paths.Count == 0) return;
            var byPath = Library.GroupBy(t => t.Path, StringComparer.OrdinalIgnoreCase).ToDictionary(g => g.Key, g => g.First(), StringComparer.OrdinalIgnoreCase);
            var tracks = d.Paths.Where(File.Exists).Select(p => byPath.TryGetValue(p, out var t) ? t : Scanner.ReadTrack(p)).ToList();
            if (tracks.Count == 0) return;
            int idx = Math.Clamp(d.Index, 0, tracks.Count - 1);
            Engine.Repeat = Enum.TryParse<RepeatMode>(d.Repeat, out var r) ? r : RepeatMode.Off;
            Engine.SetQueue(tracks, idx, play: false);
            if (d.Position > 1) Engine.Seek(d.Position);
            Log.I("session", $"restored {tracks.Count} tracks, index {idx}, at {d.Position:0}s");
        }
        catch (Exception e) { Log.W("session", $"restore failed: {e.Message}"); }
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

    public static async Task LoadLyricsAsync(Track? t, bool force = false)
    {
        _lyricsCts?.Cancel();
        CurrentLyrics = null;
        if (t == null) { LyricsLoading = false; LyricsChanged?.Invoke(); return; }
        var cts = _lyricsCts = new CancellationTokenSource();
        LyricsLoading = true;
        LyricsChanged?.Invoke();
        try
        {
            // every better result replaces the previous one as soon as it is known (file → cache → web)
            await foreach (var l in Lyrics.StreamAsync(t, force, cts.Token))
            {
                if (cts.IsCancellationRequested) return;
                CurrentLyrics = l;
                LyricsChanged?.Invoke();
            }
        }
        catch (OperationCanceledException) { return; }
        catch (Exception e) { Log.W("lyrics", e.Message); }
        if (cts.IsCancellationRequested) return;
        LyricsLoading = false;
        LyricsChanged?.Invoke();
        _ = PrefetchNextAsync(cts.Token);
    }

    /// <summary>While the current track plays, quietly download lyrics for the next one so it starts with lyrics ready.</summary>
    private static async Task PrefetchNextAsync(CancellationToken ct)
    {
        if (!Settings.LyricsPrefetch || !Settings.LyricsOnline) return;
        try
        {
            var q = Engine.Queue; int i = Engine.Index + 1;
            if (i < 0 || i >= q.Count) return;
            await Task.Delay(1500, ct);
            if (await Lyrics.PrefetchAsync(q[i], ct)) Log.D("lyrics", $"prefetched {q[i]}");
        }
        catch (OperationCanceledException) { }
        catch (Exception e) { Log.W("lyrics", $"prefetch: {e.Message}"); }
    }

    private static CancellationTokenSource? _bulkCts;
    public static bool BulkRunning => _bulkCts != null;

    /// <summary>Downloads lyrics for the whole library in the background (about 2 requests per second), skipping what is cached.</summary>
    public static async Task BulkLyricsAsync(IProgress<(int done, int total, int found)> progress)
    {
        if (_bulkCts != null) return;
        var cts = _bulkCts = new CancellationTokenSource();
        var tracks = Library.ToList();
        int done = 0, found = 0;
        try
        {
            foreach (var t in tracks)
            {
                cts.Token.ThrowIfCancellationRequested();
                bool net = !Lyrics.IsCached(t);
                if (net && await Lyrics.PrefetchAsync(t, cts.Token)) found++;
                progress.Report((++done, tracks.Count, found));
                if (net) await Task.Delay(450, cts.Token);
            }
        }
        catch (OperationCanceledException) { }
        finally { _bulkCts = null; }
        Log.I("lyrics", $"bulk download finished: {done}/{tracks.Count}");
    }

    public static void CancelBulkLyrics() => _bulkCts?.Cancel();

    public static double LyricOffset(Track? t) => t != null && Settings.LyricsOffsets.TryGetValue(t.Path, out var v) ? v : 0;

    public static void SetLyricOffset(Track t, double seconds)
    {
        if (Math.Abs(seconds) < 0.001) Settings.LyricsOffsets.Remove(t.Path); else Settings.LyricsOffsets[t.Path] = seconds;
        Settings.Save();
    }
}
