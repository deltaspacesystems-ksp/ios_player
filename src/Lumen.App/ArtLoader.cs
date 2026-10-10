using Microsoft.UI.Xaml.Media.Imaging;
using CommunityToolkit.Mvvm.ComponentModel;
using Lumen.Core;

namespace Lumen.App;

public static class ArtLoader
{
    private static readonly Dictionary<string, BitmapImage> Cache = new();

    /// <summary>Loads a cover image from disk (must run on the UI thread). Small decode width keeps lists light.</summary>
    public static async Task<BitmapImage?> LoadAsync(string path, int decodeWidth = 96)
    {
        if (string.IsNullOrEmpty(path) || !File.Exists(path)) return null;
        var key = path + "|" + decodeWidth;
        if (Cache.TryGetValue(key, out var hit)) return hit;
        try
        {
            using var fs = File.OpenRead(path);
            using var ras = fs.AsRandomAccessStream();
            var bi = new BitmapImage();
            if (decodeWidth > 0) bi.DecodePixelWidth = decodeWidth;
            await bi.SetSourceAsync(ras);
            if (Cache.Count > 600) Cache.Clear();
            Cache[key] = bi;
            return bi;
        }
        catch (Exception e)
        {
            Log.W("art", $"{Path.GetFileName(path)}: {e.Message}");
            return null;
        }
    }
}

public sealed partial class TrackVM : ObservableObject
{
    public Track Track { get; }
    public TrackVM(Track t) { Track = t; }

    public string Title => Track.Display;
    public string Artist => Track.ArtistDisplay;
    public string Album => Track.AlbumDisplay;
    public string DurationText => FormatTime(Track.Duration);

    private Microsoft.UI.Xaml.Media.ImageSource? _art;
    public Microsoft.UI.Xaml.Media.ImageSource? Art { get => _art; private set => SetProperty(ref _art, value); }
    private bool _artRequested;

    public async void EnsureArt()
    {
        if (_artRequested) return;
        _artRequested = true;
        Art = await ArtLoader.LoadAsync(Track.ArtPath, 96);
    }

    public static string FormatTime(double s)
    {
        if (double.IsNaN(s) || s < 0) s = 0;
        var t = TimeSpan.FromSeconds(s);
        return t.TotalHours >= 1 ? $"{(int)t.TotalHours}:{t.Minutes:00}:{t.Seconds:00}" : $"{t.Minutes}:{t.Seconds:00}";
    }
}
