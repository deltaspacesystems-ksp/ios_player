using System.Runtime.InteropServices;
using System.Text;
using FFmpeg.AutoGen;
using Lumen.Core;

namespace Lumen.Audio;

/// <summary>Reads tags, duration and cover art with FFmpeg — used when TagLib can't parse a file (e.g. many .opus files).</summary>
public static unsafe class FfmpegProbe
{
    public static ProbeResult? Read(string path)
    {
        Ffmpeg.Init();
        AVFormatContext* fmt = null;
        try
        {
            if (ffmpeg.avformat_open_input(&fmt, path, null, null) < 0) return null;
            ffmpeg.avformat_find_stream_info(fmt, null);
            var t = new Track { Path = path };
            if (fmt->duration > 0) t.Duration = fmt->duration / (double)ffmpeg.AV_TIME_BASE;
            if (fmt->bit_rate > 0) t.Bitrate = (int)(fmt->bit_rate / 1000);

            var tags = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            Collect(fmt->metadata, tags);
            byte[]? art = null;
            for (int i = 0; i < fmt->nb_streams; i++)
            {
                var st = fmt->streams[i];
                if (st->codecpar->codec_type == AVMediaType.AVMEDIA_TYPE_AUDIO)
                {
                    Collect(st->metadata, tags);
                    if (t.SampleRate == 0) t.SampleRate = st->codecpar->sample_rate;
                    if (t.Duration <= 0 && st->duration > 0) t.Duration = st->duration * ffmpeg.av_q2d(st->time_base);
                }
                else if ((st->disposition & ffmpeg.AV_DISPOSITION_ATTACHED_PIC) != 0 && st->attached_pic.size > 0 && art == null)
                {
                    art = new byte[st->attached_pic.size];
                    Marshal.Copy((IntPtr)st->attached_pic.data, art, 0, art.Length);
                }
            }

            string Get(params string[] keys) { foreach (var k in keys) if (tags.TryGetValue(k, out var v) && !string.IsNullOrWhiteSpace(v)) return v.Trim(); return ""; }
            t.Title = Get("title");
            t.Artist = Get("artist", "album_artist", "albumartist");
            t.AlbumArtist = Get("album_artist", "albumartist");
            t.Album = Get("album");
            t.Genre = Get("genre");
            var year = Get("date", "year", "originaldate");
            if (year.Length >= 4 && uint.TryParse(year[..4], out var y)) t.Year = y;
            var trk = Get("track", "tracknumber");
            if (trk.Length > 0 && uint.TryParse(trk.Split('/')[0], out var n)) t.TrackNumber = n;
            var rg = Get("replaygain_track_gain");
            if (rg.Length > 0 && double.TryParse(rg.Replace("dB", "", StringComparison.OrdinalIgnoreCase).Trim(),
                    System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var g)) t.ReplayGainDb = g;

            // Ogg/Opus store covers as a base64 FLAC PICTURE block in METADATA_BLOCK_PICTURE
            if (art == null && tags.TryGetValue("metadata_block_picture", out var b64)) art = DecodePictureBlock(b64);

            return new ProbeResult(t, art);
        }
        catch (Exception e)
        {
            Log.W("probe", $"{Path.GetFileName(path)}: {e.Message}");
            return null;
        }
        finally
        {
            if (fmt != null) ffmpeg.avformat_close_input(&fmt);
        }
    }

    private static void Collect(AVDictionary* dict, Dictionary<string, string> into)
    {
        if (dict == null) return;
        AVDictionaryEntry* e = null;
        while ((e = ffmpeg.av_dict_get(dict, "", e, ffmpeg.AV_DICT_IGNORE_SUFFIX)) != null)
        {
            var k = Marshal.PtrToStringUTF8((IntPtr)e->key);
            var v = Marshal.PtrToStringUTF8((IntPtr)e->value);
            if (k != null && v != null && !into.ContainsKey(k)) into[k] = v;
        }
    }

    private static byte[]? DecodePictureBlock(string b64)
    {
        try
        {
            var b = Convert.FromBase64String(b64);
            int o = 4;                                   // picture type
            int Be(int at) => (b[at] << 24) | (b[at + 1] << 16) | (b[at + 2] << 8) | b[at + 3];
            int ml = Be(o); o += 4 + ml;                 // mime
            int dl = Be(o); o += 4 + dl;                 // description
            o += 16;                                     // width, height, depth, colours
            int len = Be(o); o += 4;
            if (len <= 0 || o + len > b.Length) return null;
            return b.AsSpan(o, len).ToArray();
        }
        catch { return null; }
    }
}
