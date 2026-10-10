using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;

namespace Lumen.App;

public partial class App : Application
{
    public static MainWindow? Window { get; private set; }
    private static SystemMedia? _media;

    public App()
    {
        InitializeComponent();
        UnhandledException += (_, e) =>
        {
            Lumen.Core.Log.E("crash", e.Exception.ToString());
            e.Handled = true;
        };
    }

    /// <summary>Developer/QA switches: --add-folder P, --volume V, --page library|now|queue|settings, --play, --seek S.</summary>
    private static async void ApplyCommandLine(string[] a)
    {
        string? Arg(string n) { int i = Array.IndexOf(a, n); return i >= 0 && i + 1 < a.Length ? a[i + 1] : null; }
        var files = a.Skip(1).Where(x => !x.StartsWith("--") && (File.Exists(x) || Directory.Exists(x))).ToList();
        if (files.Count > 0 && Arg("--add-folder") == null) Svc.PlayFiles(files);
        if (Arg("--volume") is { } v && float.TryParse(v, System.Globalization.CultureInfo.InvariantCulture, out var vol)) { Svc.Settings.Volume = vol; Svc.ApplySettings(); }
        if (Arg("--add-folder") is { } f) { if (!Svc.Settings.Folders.Contains(f)) Svc.Settings.Folders.Add(f); Svc.SaveSettings(); await Svc.RescanAsync(); }
        if (Arg("--page") is { } p) Window?.Navigate(p);
        if (a.Contains("--play") && Svc.Library.Count > 0)
        {
            var list = Svc.Library.OrderBy(t => t.Path).ToList();
            int start = 0;
            if (Arg("--find") is { } q) { int fi = list.FindIndex(t => t.Display.Contains(q, StringComparison.OrdinalIgnoreCase)); if (fi >= 0) start = fi; }
            Svc.Engine.SetQueue(list, start);
            if (Arg("--seek") is { } sk && double.TryParse(sk, System.Globalization.CultureInfo.InvariantCulture, out var sec)) Svc.Engine.Seek(sec);
            if (a.Contains("--pause")) Svc.Engine.Pause();
        }
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        try
        {
            Svc.Init(DispatcherQueue.GetForCurrentThread());
            Window = new MainWindow();
            Window.Activate();
            _media = new SystemMedia();
            ApplyCommandLine(Environment.GetCommandLineArgs());
        }
        catch (Exception e)
        {
            Program.Fail(e);
            Environment.Exit(1);
        }
    }
}
