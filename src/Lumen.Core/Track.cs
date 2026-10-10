namespace Lumen.Core;

public sealed class Track
{
    public string Path { get; set; } = "";
    public string Title { get; set; } = "";
    public string Artist { get; set; } = "";
    public string Album { get; set; } = "";
    public string AlbumArtist { get; set; } = "";
    public string Genre { get; set; } = "";
    public uint Year { get; set; }
    public uint TrackNumber { get; set; }
    public double Duration { get; set; }
    public int Bitrate { get; set; }
    public int SampleRate { get; set; }
    public long Modified { get; set; }
    /// <summary>Path of the cached cover image, or empty.</summary>
    public string ArtPath { get; set; } = "";
    /// <summary>ReplayGain track gain in dB, if tagged.</summary>
    public double? ReplayGainDb { get; set; }

    public string Display => string.IsNullOrWhiteSpace(Title) ? System.IO.Path.GetFileNameWithoutExtension(Path) : Title;
    public string ArtistDisplay => string.IsNullOrWhiteSpace(Artist) ? "Unknown artist" : Artist;
    public string AlbumDisplay => string.IsNullOrWhiteSpace(Album) ? "Unknown album" : Album;
    public string GenreDisplay => string.IsNullOrWhiteSpace(Genre) ? "Unknown genre" : Genre;
    public override string ToString() => $"{ArtistDisplay} - {Display}";
}
