import AVFoundation
import Foundation

struct MixItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var trackID: String
    var inPoint = 0.0              // start offset inside the track (s)
    var outPoint: Double?          // end offset (nil = end of track)
    var overlap = 6.0              // crossfade length INTO this item from the previous one (s)
    var curve: FadeCurve = .equalPower
    var tempoMatch = false
    var gainDB = 0.0
}

struct Mix: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var items: [MixItem] = []
}

@MainActor
final class MixStore: ObservableObject {
    @Published var mixes: [Mix] = [] { didSet { save() } }

    private static var fileURL: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("lumen-mixes.json")
    }

    init() {
        if let d = try? Data(contentsOf: Self.fileURL),
           let m = try? JSONDecoder().decode([Mix].self, from: d) { mixes = m }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(mixes) { try? d.write(to: Self.fileURL) }
    }

    func add(from tracks: [Track], name: String, overlap: Double) -> Mix {
        var m = Mix(name: name)
        m.items = tracks.filter { !$0.isVideo }.map { MixItem(trackID: $0.id, overlap: overlap) }
        mixes.append(m)
        return m
    }
}

extension FadeCurve {
    func gains(_ p: Double) -> (out: Float, inn: Float) {
        let p = min(1, max(0, p))
        switch self {
        case .equalPower: return (Float(cos(p * .pi / 2)), Float(sin(p * .pi / 2)))
        case .linear: return (Float(1 - p), Float(p))
        case .sCurve:
            let s = p * p * (3 - 2 * p)
            return (Float(1 - s), Float(s))
        }
    }
}

typealias MixSlot = (start: Double, len: Double, overlap: Double)

/// Position of every item on the mix timeline (seconds).
func mixLayout(_ mix: Mix, _ tracks: [String: Track]) -> [MixSlot] {
    var out: [MixSlot] = []
    for (i, it) in mix.items.enumerated() {
        let dur = tracks[it.trackID]?.duration ?? 0
        let len = max(1, (it.outPoint ?? dur) - it.inPoint)
        let ov = i > 0 ? min(it.overlap, out[i - 1].len * 0.9, len * 0.9) : 0
        let start = i == 0 ? 0 : out[i - 1].start + out[i - 1].len - ov
        out.append((start: start, len: len, overlap: ov))
    }
    return out
}

// MARK: - Offline rendering to a file

enum ExportFormat: String, CaseIterable, Identifiable {
    case aac = "AAC 256 kbps (.m4a)", alac = "Lossless ALAC (.m4a)", wav = "WAV 16-bit (.wav)"
    var id: String { rawValue }
    var ext: String { self == .wav ? "wav" : "m4a" }
    var settings: [String: Any] {
        switch self {
        case .aac:
            return [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 256000]
        case .alac:
            return [AVFormatIDKey: kAudioFormatAppleLossless, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 2, AVEncoderBitDepthHintKey: 16]
        case .wav:
            return [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 2,
                    AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
        }
    }
}

struct RenderSeg {
    let url: URL
    let inP: Double
    let outP: Double
    let gain: Float
    let overlap: Double
    let curve: FadeCurve
}

enum MixError: Error { case convert, empty }

enum MixRenderer {
    static let sr = 44100.0

    /// Converts [from, to] of a file into a temporary 44.1 kHz stereo float CAF.
    private static func convert(_ url: URL, from: Double, to: Double, fmt: AVAudioFormat) throws -> URL {
        let src = try AVAudioFile(forReading: url)
        let inFmt = src.processingFormat
        guard let conv = AVAudioConverter(from: inFmt, to: fmt),
              let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: 8192),
              let outBuf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 16384) else { throw MixError.convert }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        let out = try AVAudioFile(forWriting: tmp, settings: fmt.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let rate = inFmt.sampleRate
        src.framePosition = AVAudioFramePosition(from * rate)
        let total = Int((to - from) * rate)
        var consumed = 0
        while true {
            outBuf.frameLength = 0
            var err: NSError?
            let status = conv.convert(to: outBuf, error: &err) { _, st in
                let want = min(8192, total - consumed)
                if want <= 0 { st.pointee = .endOfStream; return nil }
                inBuf.frameLength = 0
                try? src.read(into: inBuf, frameCount: AVAudioFrameCount(want))
                if inBuf.frameLength == 0 { st.pointee = .endOfStream; return nil }
                consumed += Int(inBuf.frameLength)
                st.pointee = .haveData
                return inBuf
            }
            if outBuf.frameLength > 0 { try out.write(from: outBuf) }
            if status != .haveData || err != nil { break }
        }
        return tmp
    }

    static func render(_ segs: [RenderSeg], to outURL: URL, format: ExportFormat, progress: (Double) -> Void) throws {
        guard !segs.isEmpty,
              let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: 2, interleaved: false)
        else { throw MixError.empty }
        var starts: [Double] = [], lens: [Double] = [], ovs: [Double] = []
        for (i, s) in segs.enumerated() {
            let len = max(1, s.outP - s.inP)
            let ov = i > 0 ? min(s.overlap, lens[i - 1] * 0.9, len * 0.9) : 0
            starts.append(i == 0 ? 0 : starts[i - 1] + lens[i - 1] - ov)
            lens.append(len)
            ovs.append(ov)
        }
        let totalFrames = Int(((starts.last ?? 0) + (lens.last ?? 0)) * sr)
        try? FileManager.default.removeItem(at: outURL)
        let outFile = try AVAudioFile(forWriting: outURL, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk = 4096
        guard let mixBuf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(chunk)),
              let rd = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(chunk)),
              let mixCh = mixBuf.floatChannelData, let rdCh = rd.floatChannelData else { throw MixError.convert }

        var readers: [Int: AVAudioFile] = [:]
        var temps: [Int: URL] = [:]
        defer { for (_, u) in temps { try? FileManager.default.removeItem(at: u) } }

        var frame = 0
        var chunks = 0
        while frame < totalFrames {
            let n = min(chunk, totalFrames - frame)
            mixBuf.frameLength = AVAudioFrameCount(n)
            for c in 0..<2 { for k in 0..<n { mixCh[c][k] = 0 } }
            let t0 = Double(frame) / sr, t1 = Double(frame + n) / sr

            for i in segs.indices {
                let st = starts[i], en = st + lens[i]
                if en <= t0 {
                    if let u = temps[i] { readers[i] = nil; try? FileManager.default.removeItem(at: u); temps[i] = nil }
                    continue
                }
                if st >= t1 { continue }
                if readers[i] == nil {
                    let tmp = try convert(segs[i].url, from: segs[i].inP, to: segs[i].outP, fmt: fmt)
                    temps[i] = tmp
                    readers[i] = try AVAudioFile(forReading: tmp, commonFormat: .pcmFormatFloat32, interleaved: false)
                }
                guard let f = readers[i] else { continue }
                let segStart = Int((st * sr).rounded())
                let from = max(frame, segStart)
                let to = min(frame + n, segStart + Int(lens[i] * sr))
                let count = to - from
                guard count > 0 else { continue }
                f.framePosition = AVAudioFramePosition(from - segStart)
                rd.frameLength = 0
                try f.read(into: rd, frameCount: AVAudioFrameCount(count))
                let got = Int(rd.frameLength)
                let inEnd = st + ovs[i]
                let outStart = i + 1 < segs.count ? starts[i + 1] : Double.infinity
                let outLen = i + 1 < segs.count ? ovs[i + 1] : 0
                for k in 0..<got {
                    let t = Double(from + k) / sr
                    var g = segs[i].gain
                    if i > 0, ovs[i] > 0, t < inEnd { g *= segs[i].curve.gains((t - st) / ovs[i]).inn }
                    if outLen > 0, t > outStart { g *= segs[i + 1].curve.gains((t - outStart) / outLen).out }
                    let o = from - frame + k
                    for c in 0..<2 { mixCh[c][o] += rdCh[c][k] * g }
                }
            }
            for c in 0..<2 { for k in 0..<n { mixCh[c][k] = max(-1, min(1, mixCh[c][k])) } }
            try outFile.write(from: mixBuf)
            frame += n
            chunks += 1
            if chunks % 20 == 0 { progress(Double(frame) / Double(totalFrames)) }
        }
        progress(1)
    }
}
