using System.Security.Cryptography;
using System.Text.Json;

namespace Lumen.Core;

public static class AudioExt
{
    public static readonly HashSet<string> All = new(StringComparer.OrdinalIgnoreCase)
    {
        ".mp3", ".flac", ".m4a", ".aac", ".ogg", ".oga", ".opus", ".wav", ".aiff", ".aif", ".wma", ".ape", ".wv",
        ".mka", ".alac", ".mpc", ".tta", ".dsf", ".dff", ".ac3", ".dts", ".mp2", ".m4b", ".caf"
    };
    public static bool IsAudio(string path) => All.Contains(System.IO.Path.GetExtension(path));
}

/// <summary>Scans folders into <see cref="Track"/>s (tags via TagLib, cover art cached on disk) and persists the library as JSON.</summary>
public sealed class LibraryScanner
{
    private static readonly object ArtLock = new();
    private readonly string _artDir;
    private readonly string _dbFile;

    public LibraryScanner(string dataDir)
    {
        _artDir = System.IO.Path.Combine(dataDir, "art");
        _dbFile = System.IO.Path.Combine(dataDir, "library.json");
        Directory.CreateDirectory(_artDir);
    }

    public List<Track> LoadCached()
    {
        try
        {
            if (File.Exists(_dbFile))
                return JsonSerializer.Deserialize<List<Track>>(File.ReadAllText(_dbFile)) ?? new();
        }
        catch (Exception e) { Log.W("library", $"cache read failed: {e.Message}"); }
        return new();
    }

    public void Save(IEnumerable<Track> tracks)
    {
        try { File.WriteAllText(_dbFile, JsonSerializer.Serialize(tracks)); }
        catch (Exception e) { Log.W("library", $"cache write failed: {e.Message}"); }
    }

    public async Task<List<Track>> ScanAsync(IEnumerable<string> folders, List<Track> existing, IProgress<(int done, int total)>? progress = null, CancellationToken ct = default)
    {
        var known = existing.GroupBy(t => t.Path, StringComparer.OrdinalIgnoreCase)
                            .ToDictionary(g => g.Key, g => g.First(), StringComparer.OrdinalIgnoreCase);
        var files = new List<string>();
        foreach (var f in folders)
        {
            if (!Directory.Exists(f)) continue;
            try
            {
                files.AddRange(Directory.EnumerateFiles(f, "*.*", new EnumerationOptions { RecurseSubdirectories = true, IgnoreInaccessible = true })
                    .Where(AudioExt.IsAudio));
            }
            catch (Exception e) { Log.W("library", $"enumerate {f}: {e.Message}"); }
        }
        files = files.Distinct(StringComparer.OrdinalIgnoreCase).ToList();

        var result = new Track?[files.Count];
        int done = 0;
        await Parallel.ForEachAsync(Enumerable.Range(0, files.Count), new ParallelOptions { MaxDegreeOfParallelism = 4, CancellationToken = ct }, (i, _) =>
        {
            var path = files[i];
            long mtime = 0;
            try { mtime = File.GetLastWriteTimeUtc(path).Ticks; } catch { }
            if (known.TryGetValue(path, out var cached) && cached.Modified == mtime) result[i] = cached;
            else result[i] = Read(path, mtime);
            progress?.Report((Interlocked.Increment(ref done), files.Count));
            return ValueTask.CompletedTask;
        });
        var list = result.Where(t => t != null).Select(t => t!).ToList();
        Save(list);
        Log.I("library", $"scan done: {list.Count} tracks");
        return list;
    }

    public Track ReadTrack(string path)
    {
        long m = 0; try { m = File.GetLastWriteTimeUtc(path).Ticks; } catch { }
        return Read(path, m);
    }

    private Track Read(string path, long mtime)
    {
        var t = new Track { Path = path, Modified = mtime };
        try
        {
            using var f = TagLib.File.Create(path);
            var tag = f.Tag;
            t.Title = tag.Title ?? "";
            t.Artist = tag.FirstPerformer ?? tag.FirstAlbumArtist ?? "";
            t.AlbumArtist = tag.FirstAlbumArtist ?? "";
            t.Album = tag.Album ?? "";
            t.Genre = tag.FirstGenre ?? "";
            t.Year = tag.Year;
            t.TrackNumber = tag.Track;
            t.Duration = f.Properties.Duration.TotalSeconds;
            t.Bitrate = f.Properties.AudioBitrate;
            t.SampleRate = f.Properties.AudioSampleRate;
            if (!double.IsNaN(tag.ReplayGainTrackGain)) t.ReplayGainDb = tag.ReplayGainTrackGain;
            if (tag.Pictures.Length > 0)
            {
                var data = tag.Pictures[0].Data.Data;
                var hash = Convert.ToHexString(SHA1.HashData(data))[..16];
                var artPath = System.IO.Path.Combine(_artDir, hash + ".img");
                lock (ArtLock) { if (!File.Exists(artPath)) File.WriteAllBytes(artPath, data); }
                t.ArtPath = artPath;
            }
        }
        catch (Exception e)
        {
            Log.W("library", $"tags failed for {System.IO.Path.GetFileName(path)}: {e.Message}");
        }
        if (string.IsNullOrWhiteSpace(t.Title))
        {
            var name = System.IO.Path.GetFileNameWithoutExtension(path);
            var i = name.IndexOf(" - ", StringComparison.Ordinal);
            if (i > 0 && string.IsNullOrWhiteSpace(t.Artist)) { t.Artist = name[..i]; t.Title = name[(i + 3)..]; }
            else t.Title = name;
        }
        return t;
    }
}
