using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.ApplicationModel.DataTransfer;
using Windows.System;
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
        Closed += (_, _) => { Svc.SaveSession(); Svc.Engine.Dispose(); Svc.Settings.Save(); };
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

    private void Root_DragOver(object sender, DragEventArgs e)
    {
        if (e.DataView.Contains(StandardDataFormats.StorageItems))
        {
            e.AcceptedOperation = DataPackageOperation.Copy;
            e.DragUIOverride.Caption = "Play in Lumen";
        }
    }

    private async void Root_Drop(object sender, DragEventArgs e)
    {
        if (!e.DataView.Contains(StandardDataFormats.StorageItems)) return;
        var items = await e.DataView.GetStorageItemsAsync();
        var paths = items.Select(i => i.Path).Where(p => !string.IsNullOrEmpty(p)).ToList();
        Svc.PlayFiles(paths);
    }

    private void Root_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        var src = e.OriginalSource as DependencyObject;
        for (var d = src; d != null; d = VisualTreeHelper.GetParent(d))
            if (d is TextBox or AutoSuggestBox or ComboBox or Slider) return;   // let inputs keep their keys
        var ctrl = InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Control).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
        var eng = Svc.Engine;
        switch (e.Key)
        {
            case VirtualKey.Space: eng.Toggle(); break;
            case VirtualKey.Right when ctrl: eng.Next(); break;
            case VirtualKey.Left when ctrl: eng.Previous(); break;
            case VirtualKey.Right: eng.Seek(eng.Position + 5); break;
            case VirtualKey.Left: eng.Seek(eng.Position - 5); break;
            case VirtualKey.Up: Svc.Settings.Volume = Math.Min(1, Svc.Settings.Volume + 0.05f); Svc.ApplySettings(); break;
            case VirtualKey.Down: Svc.Settings.Volume = Math.Max(0, Svc.Settings.Volume - 0.05f); Svc.ApplySettings(); break;
            case VirtualKey.M: Svc.Settings.Volume = Svc.Settings.Volume > 0 ? 0 : 0.6f; Svc.ApplySettings(); break;
            case VirtualKey.L: Navigate("now"); break;
            case VirtualKey.Q: Navigate("queue"); break;
            default: return;
        }
        e.Handled = true;
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
