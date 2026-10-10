using System.Runtime.InteropServices;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;

namespace Lumen.App;

/// <summary>Custom entry point (same as the generated one) so that a startup failure is shown instead of silently closing.</summary>
public static class Program
{
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int MessageBoxW(IntPtr hWnd, string text, string caption, uint type);

    [STAThread]
    public static void Main(string[] args)
    {
        try
        {
            WinRT.ComWrappersSupport.InitializeComWrappers();
            Application.Start(_ =>
            {
                var ctx = new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread());
                SynchronizationContext.SetSynchronizationContext(ctx);
                new App();
            });
        }
        catch (Exception e)
        {
            Fail(e);
        }
    }

    public static void Fail(Exception e)
    {
        try { Lumen.Core.Log.E("fatal", e.ToString()); } catch { }
        var log = Lumen.Core.Log.Directory;
        try
        {
            var dir = string.IsNullOrEmpty(log)
                ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Lumen", "logs") : log;
            Directory.CreateDirectory(dir);
            File.WriteAllText(Path.Combine(dir, "crash.txt"), DateTime.Now + Environment.NewLine + e);
            log = dir;
        }
        catch { }
        MessageBoxW(IntPtr.Zero,
            "Lumen could not start.\n\n" + e.GetType().Name + ": " + e.Message +
            (string.IsNullOrEmpty(log) ? "" : "\n\nLog folder:\n" + log),
            "Lumen", 0x10);
    }
}
