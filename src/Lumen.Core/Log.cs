namespace Lumen.Core;

public enum LogLevel { Debug, Info, Warning, Error }

/// <summary>Tiny rolling file logger + in-memory ring for the log viewer; exports a text file for sharing.</summary>
public static class Log
{
    private static readonly object Gate = new();
    private static readonly List<string> Ring = new();
    private static string? _file;
    public static LogLevel Min { get; set; } = LogLevel.Info;
    public static string Directory { get; private set; } = "";

    public static event Action<string>? Line;

    public static void Init(string dir)
    {
        Directory = dir;
        System.IO.Directory.CreateDirectory(dir);
        _file = System.IO.Path.Combine(dir, "lumen.log");
        try
        {
            if (File.Exists(_file) && new FileInfo(_file).Length > 1_500_000)
            {
                var old = System.IO.Path.Combine(dir, "lumen.1.log");
                File.Delete(old);
                File.Move(_file, old);
            }
        }
        catch { /* best effort */ }
        AppDomain.CurrentDomain.UnhandledException += (_, e) => Write(LogLevel.Error, "crash", e.ExceptionObject.ToString() ?? "unhandled");
        TaskScheduler.UnobservedTaskException += (_, e) => Write(LogLevel.Error, "task", e.Exception.ToString());
        I("session", $"Launch - {Environment.OSVersion} .NET {Environment.Version}");
    }

    public static void D(string c, string m) => Write(LogLevel.Debug, c, m);
    public static void I(string c, string m) => Write(LogLevel.Info, c, m);
    public static void W(string c, string m) => Write(LogLevel.Warning, c, m);
    public static void E(string c, string m) => Write(LogLevel.Error, c, m);

    public static void Write(LogLevel level, string category, string message)
    {
        if (level < Min) return;
        var line = $"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff} [{level.ToString().ToUpperInvariant()}] {category}: {message}";
        lock (Gate)
        {
            Ring.Add(line);
            if (Ring.Count > 3000) Ring.RemoveRange(0, 500);
            if (_file != null)
            {
                try { File.AppendAllText(_file, line + Environment.NewLine); } catch { /* ignore */ }
            }
        }
        Line?.Invoke(line);
    }

    public static string[] Snapshot() { lock (Gate) return Ring.ToArray(); }

    public static string Export()
    {
        var path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), $"Lumen-log-{DateTime.Now:yyyyMMdd-HHmmss}.txt");
        var header = $"Lumen log\nOS: {Environment.OSVersion}\n.NET: {Environment.Version}\nCPU cores: {Environment.ProcessorCount}\n----- log -----\n";
        string body;
        lock (Gate) body = string.Join(Environment.NewLine, Ring);
        File.WriteAllText(path, header + body);
        return path;
    }
}
