using FFmpeg.AutoGen;
using Lumen.Core;

namespace Lumen.Audio;

/// <summary>Locates and loads the FFmpeg shared libraries (LGPL build shipped next to the app).</summary>
public static class Ffmpeg
{
    private static bool _ready;
    private static readonly object Gate = new();

    public static void Init(string? dir = null)
    {
        lock (Gate)
        {
            if (_ready) return;
            dir ??= FindDir();
            ffmpeg.RootPath = dir;
            DynamicallyLoadedBindings.Initialize();
            _ready = true;
            Log.I("ffmpeg", $"loaded from {dir} (avcodec {ffmpeg.avcodec_version() >> 16}.{(ffmpeg.avcodec_version() >> 8) & 0xFF})");
        }
    }

    private static string FindDir()
    {
        var env = Environment.GetEnvironmentVariable("LUMEN_FFMPEG");
        if (!string.IsNullOrEmpty(env) && Directory.Exists(env)) return env;
        var baseDir = AppContext.BaseDirectory;
        foreach (var c in new[] { baseDir, Path.Combine(baseDir, "ffmpeg") })
            if (Directory.Exists(c) && Directory.GetFiles(c, "avcodec-*.dll").Length > 0) return c;
        // development: walk up to <repo>/native/ffmpeg
        var d = new DirectoryInfo(baseDir);
        while (d != null)
        {
            var cand = Path.Combine(d.FullName, "native", "ffmpeg");
            if (Directory.Exists(cand) && Directory.GetFiles(cand, "avcodec-*.dll").Length > 0) return cand;
            d = d.Parent;
        }
        throw new DirectoryNotFoundException("FFmpeg libraries (avcodec-*.dll) not found. Set LUMEN_FFMPEG or copy them next to the app.");
    }
}
