using Microsoft.UI.Xaml.Controls;

namespace Lumen.App;

public sealed partial class QueuePage : Page
{
    private List<TrackVM> _items = new();

    public QueuePage()
    {
        InitializeComponent();
        Loaded += (_, _) => { Svc.TrackChanged += OnChange; Refresh(); };
        Unloaded += (_, _) => Svc.TrackChanged -= OnChange;
        List.ContainerContentChanging += (_, a) => { if (a.Phase == 0 && a.Item is TrackVM vm) vm.EnsureArt(); };
    }

    private void OnChange(Lumen.Core.Track? t, int i) => Refresh();

    private void Refresh()
    {
        _items = Svc.Engine.Queue.Select(t => new TrackVM(t)).ToList();
        List.ItemsSource = _items;
        int idx = Svc.Engine.Index;
        if (idx >= 0 && idx < _items.Count) List.ScrollIntoView(_items[idx], ScrollIntoViewAlignment.Leading);
    }

    private void List_ItemClick(object sender, ItemClickEventArgs e)
    {
        int i = _items.IndexOf((TrackVM)e.ClickedItem);
        if (i >= 0) Svc.Engine.PlayIndex(i);
    }
}
