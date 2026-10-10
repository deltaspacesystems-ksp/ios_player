using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using WinRT.Interop;

namespace Lumen.App;

public sealed partial class MainWindow : Window
{
    public IntPtr Hwnd => WindowNative.GetWindowHandle(this);

    public MainWindow()
    {
        InitializeComponent();
        Title = "Lumen";
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);
        AppWindow.Resize(new Windows.Graphics.SizeInt32(1280, 820));
        try { AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "lumen.ico")); } catch { }
        ApplyAppearance();
        Svc.SettingsChanged += ApplyAppearance;
        Nav.SelectedItem = Nav.MenuItems[0];
        Closed += (_, _) => { Svc.Engine.Dispose(); Svc.Settings.Save(); };
    }

    public void Navigate(string tag)
    {
        if (tag == "settings") { Nav.SelectedItem = Nav.SettingsItem; return; }
        foreach (var o in Nav.MenuItems)
            if (o is NavigationViewItem i && (string?)i.Tag == tag) { Nav.SelectedItem = i; return; }
    }

    private void ApplyAppearance()
    {
        Root.RequestedTheme = Svc.Settings.Theme switch { "Light" => ElementTheme.Light, "Dark" => ElementTheme.Dark, _ => ElementTheme.Default };
        SystemBackdrop = Svc.Settings.Backdrop switch
        {
            "Acrylic" => new DesktopAcrylicBackdrop(),
            "None" => null,
            _ => new MicaBackdrop { Kind = MicaKind.BaseAlt },
        };
    }

    private void Nav_SelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (args.IsSettingsSelected) { ContentFrame.Navigate(typeof(SettingsPage)); return; }
        var tag = (args.SelectedItem as NavigationViewItem)?.Tag as string;
        var page = tag switch
        {
            "now" => typeof(NowPlayingPage),
            "queue" => typeof(QueuePage),
            _ => typeof(LibraryPage),
        };
        if (ContentFrame.CurrentSourcePageType != page) ContentFrame.Navigate(page);
    }
}
