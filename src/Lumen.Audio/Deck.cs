using FFmpeg.AutoGen;
using Lumen.Core;

namespace Lumen.Audio;

/// <summary>
/// One decoded stream: a background thread demuxes/decodes with FFmpeg, resamples to 48 kHz stereo float and fills a ring buffer;
/// the mixer pulls from it. Supports sample-accurate position and seeking.
/// </summary>
public sealed unsafe class Deck : IDisposable
{
    public const int Rate = 48000;
    public const int Channels = 2;
    private const int RingSeconds = 4;

    private readonly string _path;
    private readonly float[] _ring = new float[Rate * Channels * RingSeconds];
    private readonly object _lk = new();
    private int _rd, _wr, _count;               // in samples (interleaved), guarded by _lk
    private long _consumed;                     // frames consumed since the last seek
    private double _startSeconds;
    private int _gen;                           // seek generation
    private volatile bool _stop, _eof, _failed;
    private double _seekTarget = -1;
    private readonly Thread _thread;

    public double Duration { get; private set; }
    public string Path => _path;
    public bool Failed => _failed;
    /// <summary>Linear gain (ReplayGain etc.) applied by the mixer.</summary>
    public float Gain { get; set; } = 1f;
    public Track? Track { get; init; }

    public Deck(string path, double startSeconds = 0)
    {
        Ffmpeg.Init();
        _path = path;
        _startSeconds = startSeconds;
        if (startSeconds > 0) _seekTarget = startSeconds;
        _thread = new Thread(Run) { IsBackground = true, Name = "deck-decode", Priority = ThreadPriority.AboveNormal };
        _thread.Start();
    }

    public double Position { get { lock (_lk) return _startSeconds + _consumed / (double)Rate; } }
    public int BufferedFrames { get { lock (_lk) return _count / Channels; } }
    /// <summary>Enough audio buffered (or stream finished) so starting it will not underrun.</summary>
    public bool IsReady => _failed || _eof || BufferedFrames >= Rate / 2;
    /// <summary>Decoder finished and everything has been consumed.</summary>
    public bool Drained { get { lock (_lk) return (_eof || _failed) && _count == 0; } }

    public int Read(Span<float> dest, int frames)
    {
        lock (_lk)
        {
            int want = Math.Min(frames * Channels, _count);
            int n = want / Channels * Channels;
            int first = Math.Min(n, _ring.Length - _rd);
            _ring.AsSpan(_rd, first).CopyTo(dest);
            if (n > first) _ring.AsSpan(0, n - first).CopyTo(dest[first..]);
            _rd = (_rd + n) % _ring.Length;
            _count -= n;
            _consumed += n / Channels;
            return n / Channels;
        }
    }

    public void Seek(double seconds)
    {
        lock (_lk)
        {
            _gen++;
            _rd = _wr = _count = 0;
            _consumed = 0;
            _startSeconds = Math.Max(0, seconds);
            _seekTarget = _startSeconds;
            _eof = false;
        }
    }

    private bool Write(ReadOnlySpan<float> src, int gen)
    {
        int offset = 0;
        while (offset < src.Length)
        {
            if (_stop) return false;
            lock (_lk)
            {
                if (gen != _gen) return false;            // a seek happened — drop stale samples
                int room = _ring.Length - _count;
                int n = Math.Min(room, src.Length - offset) / Channels * Channels;
                if (n > 0)
                {
                    int first = Math.Min(n, _ring.Length - _wr);
                    src.Slice(offset, first).CopyTo(_ring.AsSpan(_wr));
                    if (n > first) src.Slice(offset + first, n - first).CopyTo(_ring);
                    _wr = (_wr + n) % _ring.Length;
                    _count += n;
                    offset += n;
                    continue;
                }
            }
            Thread.Sleep(4);
        }
        return true;
    }

    private void Run()
    {
        AVFormatContext* fmt = null;
        AVCodecContext* cc = null;
        SwrContext* swr = null;
        AVPacket* pkt = null;
        AVFrame* frame = null;
        try
        {
            if (ffmpeg.avformat_open_input(&fmt, _path, null, null) < 0) throw new IOException("cannot open file");
            if (ffmpeg.avformat_find_stream_info(fmt, null) < 0) throw new IOException("no stream info");
            AVCodec* codec = null;
            int idx = ffmpeg.av_find_best_stream(fmt, AVMediaType.AVMEDIA_TYPE_AUDIO, -1, -1, &codec, 0);
            if (idx < 0 || codec == null) throw new IOException("no audio stream");
            AVStream* st = fmt->streams[idx];
            cc = ffmpeg.avcodec_alloc_context3(codec);
            ffmpeg.avcodec_parameters_to_context(cc, st->codecpar);
            if (ffmpeg.avcodec_open2(cc, codec, null) < 0) throw new IOException("cannot open decoder");

            double dur = fmt->duration > 0 ? fmt->duration / (double)ffmpeg.AV_TIME_BASE : 0;
            if (dur <= 0 && st->duration > 0) dur = st->duration * ffmpeg.av_q2d(st->time_base);
            Duration = dur;
            double tb = ffmpeg.av_q2d(st->time_base);

            swr = CreateSwr(cc);
            pkt = ffmpeg.av_packet_alloc();
            frame = ffmpeg.av_frame_alloc();
            float[] tmp = new float[Rate * Channels];     // 1 s scratch
            int gen;
            long skipFrames = 0;
            bool trim = false;
            double trimTarget = 0;
            bool draining = false;

            lock (_lk) gen = _gen;

            while (!_stop)
            {
                // ---- seek request ----
                double target;
                lock (_lk) { target = _seekTarget; _seekTarget = -1; if (target >= 0) gen = _gen; }
                if (target >= 0)
                {
                    long ts = (long)(target * ffmpeg.AV_TIME_BASE);
                    ffmpeg.av_seek_frame(fmt, -1, ts, ffmpeg.AVSEEK_FLAG_BACKWARD);
                    ffmpeg.avcodec_flush_buffers(cc);
                    ffmpeg.swr_free(&swr);
                    swr = CreateSwr(cc);
                    trim = target > 0.05;
                    trimTarget = target;
                    skipFrames = 0;
                    draining = false;
                    _eof = false;
                }

                if (draining)
                {
                    // finished: wait for a seek or stop
                    _eof = true;
                    Thread.Sleep(20);
                    continue;
                }

                int r = ffmpeg.av_read_frame(fmt, pkt);
                if (r < 0)
                {
                    ffmpeg.avcodec_send_packet(cc, null);   // flush decoder
                    DrainFrames(cc, frame, swr, tmp, tb, ref trim, trimTarget, ref skipFrames, gen);
                    draining = true;
                    continue;
                }
                if (pkt->stream_index == idx)
                {
                    if (ffmpeg.avcodec_send_packet(cc, pkt) >= 0)
                        DrainFrames(cc, frame, swr, tmp, tb, ref trim, trimTarget, ref skipFrames, gen);
                }
                ffmpeg.av_packet_unref(pkt);
            }
        }
        catch (Exception e)
        {
            _failed = true;
            Log.E("deck", $"{System.IO.Path.GetFileName(_path)}: {e.Message}");
        }
        finally
        {
            if (frame != null) { var f = frame; ffmpeg.av_frame_free(&f); }
            if (pkt != null) { var p = pkt; ffmpeg.av_packet_free(&p); }
            if (swr != null) ffmpeg.swr_free(&swr);
            if (cc != null) { var c = cc; ffmpeg.avcodec_free_context(&c); }
            if (fmt != null) ffmpeg.avformat_close_input(&fmt);
        }
    }

    private static SwrContext* CreateSwr(AVCodecContext* cc)
    {
        SwrContext* swr = null;
        AVChannelLayout outL;
        ffmpeg.av_channel_layout_default(&outL, Channels);
        int r = ffmpeg.swr_alloc_set_opts2(&swr, &outL, AVSampleFormat.AV_SAMPLE_FMT_FLT, Rate,
            &cc->ch_layout, cc->sample_fmt, cc->sample_rate, 0, null);
        if (r < 0) throw new IOException("cannot create resampler");
        if (cc->ch_layout.nb_channels == 1)
        {
            // mono: plain duplication to both channels (FFmpeg's default would attenuate by 3 dB)
            double* m = stackalloc double[2] { 1.0, 1.0 };
            ffmpeg.swr_set_matrix(swr, m, 1);
        }
        if (ffmpeg.swr_init(swr) < 0) throw new IOException("cannot init resampler");
        return swr;
    }

    private void DrainFrames(AVCodecContext* cc, AVFrame* frame, SwrContext* swr, float[] tmp, double tb,
                             ref bool trim, double trimTarget, ref long skipFrames, int gen)
    {
        while (!_stop)
        {
            int r = ffmpeg.avcodec_receive_frame(cc, frame);
            if (r < 0) return;                                   // EAGAIN / EOF
            long pts = frame->best_effort_timestamp;
            if (trim && pts != ffmpeg.AV_NOPTS_VALUE)
            {
                double fs = pts * tb;
                skipFrames = Math.Max(0, (long)((trimTarget - fs) * Rate));
                trim = false;
            }
            int maxOut = ffmpeg.swr_get_out_samples(swr, frame->nb_samples);
            if (maxOut * Channels > tmp.Length) tmp = new float[maxOut * Channels];
            int n;
            fixed (float* p = tmp)
            {
                byte* o = (byte*)p;
                n = ffmpeg.swr_convert(swr, &o, maxOut, frame->extended_data, frame->nb_samples);
            }
            ffmpeg.av_frame_unref(frame);
            if (n <= 0) continue;
            int start = 0;
            if (skipFrames > 0)
            {
                int s = (int)Math.Min(skipFrames, n);
                start = s; skipFrames -= s;
            }
            if (n - start > 0 && !Write(tmp.AsSpan(start * Channels, (n - start) * Channels), gen)) return;
        }
    }

    public void Dispose()
    {
        _stop = true;
        if (Thread.CurrentThread != _thread) _thread.Join(2000);
    }
}
