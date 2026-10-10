using System.Text.Json;

namespace Lumen.Core;

/// <summary>User settings, persisted as JSON in %LOCALAPPDATA%\Lumen\settings.json. Unknown/missing fields fall back to defaults.</summary>
public sealed class AppSettings
{
    // library
    public List<string> Folders { get; set; } = new();
    // playback
    public double CrossfadeSeconds { get; set; } = 6;
    public string Curve { get; set; } = "EqualPower";      // EqualPower | Linear | SCurve
    public bool CrossfadeOnSkip { get; set; }
    public double SkipFadeSeconds { get; set; } = 2.5;
    public bool UseReplayGain { get; set; } = true;
    public float Volume { get; set; } = 0.8f;
    // equalizer
    public float[] EqGains { get; set; } = new float[10];
    public float Preamp { get; set; }
    // spatial audio
    public string SpatialMode { get; set; } = "Off";      // Off | Wide | Surround | Hall | Spatial3D
    public float SpatialAmount { get; set; } = 0.6f;
    public float SpatialWidth { get; set; } = 1.4f;
    public float SpatialRoom { get; set; } = 0.6f;
    public bool Crossfeed { get; set; }
    // lyrics
    public bool LyricsOnline { get; set; } = true;
    public double LyricsFontScale { get; set; } = 1.0;
    public bool LyricsKaraoke { get; set; } = true;
    public Dictionary<string, double> LyricsOffsets { get; set; } = new();   // per track path, seconds
    // visualizer
    public bool VizOn { get; set; } = true;
    public int VizBars { get; set; } = 48;
    public int VizFps { get; set; } = 60;
    public double VizGain { get; set; } = 1.0;
    // appearance
    public string Theme { get; set; } = "System";         // System | Light | Dark
    public string Backdrop { get; set; } = "Mica";        // Mica | Acrylic | None
    public string AccentHex { get; set; } = "";           // empty = Windows accent
    // logging
    public string LogLevel { get; set; } = "Info";

    [System.Text.Json.Serialization.JsonIgnore] public string? Path { get; private set; }

    private static readonly JsonSerializerOptions Opts = new() { WriteIndented = true };

    public static AppSettings Load(string path)
    {
        AppSettings s;
        try { s = File.Exists(path) ? JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(path)) ?? new() : new(); }
        catch (Exception e) { Log.W("settings", $"load failed, using defaults: {e.Message}"); s = new(); }
        if (s.EqGains.Length != 10) s.EqGains = new float[10];
        s.Path = path;
        return s;
    }

    public void Save()
    {
        if (Path == null) return;
        try
        {
            Directory.CreateDirectory(System.IO.Path.GetDirectoryName(Path)!);
            File.WriteAllText(Path, JsonSerializer.Serialize(this, Opts));
        }
        catch (Exception e) { Log.W("settings", $"save failed: {e.Message}"); }
    }
}
