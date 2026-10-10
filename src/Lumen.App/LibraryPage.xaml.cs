using CommunityToolkit.Mvvm.ComponentModel;
using Lumen.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Storage.Pickers;
using WinRT.Interop;

namespace Lumen.App;

public sealed partial class GroupVM : ObservableObject
{
    public string Title { get; init; } = "";
    public string Subtitle { get; init; } = "";
    public List<Track> Tracks { get; init; } = new();
    public string Kind { get; init; } = "";
    private Microsoft.UI.Xaml.Media.ImageSource? _art;
    public Microsoft.UI.Xaml.Media.ImageSource? Art { get => _art; private set => SetProperty(ref _art, value); }
    private bool _req;

    public async void EnsureArt()
    {
        if (_req) return;
        _req = true;
        var path = Tracks.Select(t => t.ArtPath).FirstOrDefault(p => !string.IsNullOrEmpty(p)) ?? "";
        Art = await ArtLoader.LoadAsync(path, 200);
    }
}

public sealed partial class LibraryPage : Page
{
    private string _mode = "Tracks";
    private Func<Track, bool>? _filter;
    private string _filterLabel = "";
    private List<TrackVM> _shown = new();

    public LibraryPage()
    {
        InitializeComponent();
        Loaded += (_, _) =>
        {
            Svc.LibraryChanged += Refresh;
            Svc.ScanProgress += OnScan;
            Refresh();
        };
        Unloaded += (_, _) => { Svc.LibraryChanged -= Refresh; Svc.ScanProgress -= OnScan; };
    }

    private void OnScan((int done, int total) p)
    {
        ScanRing.IsActive = Svc.Scanning && p.done < p.total;
        ScanText.Text = p.done < p.total ? $"Scanning {p.done}/{p.total}" : "";
    }

    private void Refresh()
    {
        ScanRing.IsActive = false;
        ScanText.Text = "";
        var q = Search.Text?.Trim() ?? "";
        IEnumerable<Track> tracks = Svc.Library;
        if (_filter != null) tracks = tracks.Where(_filter);
        if (q.Length > 0)
            tracks = tracks.Where(t => t.Display.Contains(q, StringComparison.CurrentCultureIgnoreCase)
                                    || t.Artist.Contains(q, StringComparison.CurrentCultureIgnoreCase)
                                    || t.Album.Contains(q, StringComparison.CurrentCultureIgnoreCase));
        var list = tracks.ToList();
        EmptyPanel.Visibility = Svc.Library.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        FilterChip.Visibility = _filter != null ? Visibility.Visible : Visibility.Collapsed;
        FilterText.Text = _filterLabel;

        if (_mode == "Tracks" || _filter != null)
        {
            TrackList.Visibility = Svc.Library.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
            GroupGrid.Visibility = Visibility.Collapsed;
            _shown = list.OrderBy(t => t.Artist, StringComparer.CurrentCultureIgnoreCase)
                         .ThenBy(t => t.Album, StringComparer.CurrentCultureIgnoreCase)
                         .ThenBy(t => t.TrackNumber).ThenBy(t => t.Title, StringComparer.CurrentCultureIgnoreCase)
                         .Select(t => new TrackVM(t)).ToList();
            if (_filter != null && _mode == "Albums") _shown = _shown.OrderBy(v => v.Track.TrackNumber).ToList();
            TrackList.ItemsSource = _shown;
        }
        else
        {
            TrackList.Visibility = Visibility.Collapsed;
            GroupGrid.Visibility = Svc.Library.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
            IEnumerable<IGrouping<string, Track>> groups = _mode switch
            {
                "Albums" => list.GroupBy(t => t.AlbumDisplay + "\u0001" + (string.IsNullOrWhiteSpace(t.AlbumArtist) ? t.Artist : t.AlbumArtist)),
                "Artists" => list.GroupBy(t => t.ArtistDisplay),
                _ => list.GroupBy(t => t.GenreDisplay),
            };
            GroupGrid.ItemsSource = groups.OrderBy(g => g.Key, StringComparer.CurrentCultureIgnoreCase).Select(g =>
            {
                var first = g.First();
                string title = _mode switch { "Albums" => first.AlbumDisplay, "Artists" => first.ArtistDisplay, _ => first.GenreDisplay };
                string sub = _mode == "Albums" ? first.ArtistDisplay : $"{g.Count()} tracks";
                return new GroupVM { Title = title, Subtitle = sub, Tracks = g.ToList(), Kind = _mode };
            }).ToList();
        }
    }

    private void Modes_SelectionChanged(SelectorBar sender, SelectorBarSelectionChangedEventArgs args)
    {
        _mode = sender.SelectedItem?.Text ?? "Tracks";
        _filter = null;
        if (IsLoaded) Refresh();
    }

    private void Search_TextChanged(AutoSuggestBox sender, AutoSuggestBoxTextChangedEventArgs args)
    {
        if (args.Reason == AutoSuggestionBoxTextChangeReason.UserInput) Refresh();
    }

    private void ClearFilter_Click(object sender, RoutedEventArgs e) { _filter = null; Refresh(); }

    private void GroupGrid_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is not GroupVM g) return;
        var set = g.Tracks.Select(t => t.Path).ToHashSet(StringComparer.OrdinalIgnoreCase);
        _filter = t => set.Contains(t.Path);
        _filterLabel = g.Title;
        Refresh();
    }

    private void TrackList_ContainerContentChanging(ListViewBase sender, ContainerContentChangingEventArgs args)
    {
        if (args.Phase == 0 && args.Item is TrackVM vm) vm.EnsureArt();
    }

    private void GroupGrid_ContainerContentChanging(ListViewBase sender, ContainerContentChangingEventArgs args)
    {
        if (args.Item is GroupVM vm) vm.EnsureArt();
    }

    private void PlaySelected()
    {
        if (TrackList.SelectedItem is not TrackVM vm) return;
        int idx = _shown.IndexOf(vm);
        Svc.Engine.SetQueue(_shown.Select(v => v.Track).ToList(), Math.Max(0, idx));
    }

    private void TrackList_DoubleTapped(object sender, Microsoft.UI.Xaml.Input.DoubleTappedRoutedEventArgs e) => PlaySelected();
    private void Ctx_Play(object sender, RoutedEventArgs e) => PlaySelected();
    private void Ctx_PlayNext(object sender, RoutedEventArgs e) { if (TrackList.SelectedItem is TrackVM vm) Svc.Engine.PlayNext(vm.Track); }
    private void Ctx_Enqueue(object sender, RoutedEventArgs e) { if (TrackList.SelectedItem is TrackVM vm) Svc.Engine.Enqueue(vm.Track); }
    private void Ctx_Explorer(object sender, RoutedEventArgs e)
    {
        if (TrackList.SelectedItem is TrackVM vm)
            System.Diagnostics.Process.Start("explorer.exe", $"/select,\"{vm.Track.Path}\"");
    }

    private async void AddFolder_Click(object sender, RoutedEventArgs e)
    {
        var picker = new FolderPicker();
        picker.FileTypeFilter.Add("*");
        InitializeWithWindow.Initialize(picker, App.Window!.Hwnd);
        var folder = await picker.PickSingleFolderAsync();
        if (folder == null) return;
        if (!Svc.Settings.Folders.Contains(folder.Path, StringComparer.OrdinalIgnoreCase)) Svc.Settings.Folders.Add(folder.Path);
        Svc.SaveSettings();
        Log.I("library", $"added folder {folder.Path}");
        ScanRing.IsActive = true;
        await Svc.RescanAsync();
    }

    private async void Rescan_Click(object sender, RoutedEventArgs e)
    {
        ScanRing.IsActive = true;
        await Svc.RescanAsync();
    }
}
