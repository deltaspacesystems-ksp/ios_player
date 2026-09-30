import Accelerate
import AVFoundation
import Foundation

struct TrackAnalysis: Codable, Equatable {
    var bpm: Double
    var camelot: Int       // 1...12
    var minor: Bool        // true = "A" (minor), false = "B" (major)
    var energy: Double     // 0...1
    var mtime: Double
    var keyName: String { "\(camelot)\(minor ? "A" : "B")" }
}

/// Offline tempo / key / energy estimation (no network, no ML model).
enum TrackAnalyzer {
    private static let majorProfile: [Float] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    private static let minorProfile: [Float] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]
    // Camelot number of the MAJOR key with tonic pitch class 0...11 (C, C#, D ...)
    private static let camelotMajor = [8, 3, 10, 5, 12, 7, 2, 9, 4, 11, 6, 1]

    static func fileMtime(_ url: URL) -> Double {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0
    }

    static func analyze(_ url: URL) -> TrackAnalysis? {
        guard let (mono, sr) = decode(url), mono.count > Int(sr * 10) else { return nil }
        let (bpm, rms) = tempo(mono, sr)
        let (cam, minor) = key(mono, sr)
        let db = 20 * log10(max(rms, 1e-5))
        let loud = min(1, max(0, (Double(db) + 35) / 25))
        let tempoE = min(1, max(0, (bpm - 70) / 110))
        return TrackAnalysis(bpm: bpm, camelot: cam, minor: minor, energy: 0.7 * loud + 0.3 * tempoE, mtime: fileMtime(url))
    }

    /// Mono, decimated to ~11 kHz, up to 100 s taken from the middle of the track.
    private static func decode(_ url: URL) -> ([Float], Double)? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let fmt = file.processingFormat
        let sr = fmt.sampleRate
        let dec = max(1, Int((sr / 11025).rounded()))
        let effSR = sr / Double(dec)
        let maxFrames = AVAudioFramePosition(100 * sr)
        file.framePosition = file.length > maxFrames ? (file.length - maxFrames) / 2 : 0
        let chunk: AVAudioFrameCount = 16384
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunk) else { return nil }
        var mono: [Float] = []
        mono.reserveCapacity(Int(effSR * 100) + 1)
        var read: AVAudioFramePosition = 0
        let chs = Int(fmt.channelCount)
        while read < maxFrames {
            buf.frameLength = 0
            do { try file.read(into: buf, frameCount: chunk) } catch { break }
            let n = Int(buf.frameLength)
            if n == 0 { break }
            guard let ch = buf.floatChannelData else { break }
            var i = 0
            while i + dec <= n {
                var acc: Float = 0
                for c in 0..<chs { for k in 0..<dec { acc += ch[c][i + k] } }
                mono.append(acc / Float(dec * chs))
                i += dec
            }
            read += AVAudioFramePosition(n)
        }
        return (mono, effSR)
    }

    /// Returns (bpm, overall rms).
    private static func tempo(_ x: [Float], _ sr: Double) -> (Double, Float) {
        let hop = 64, win = 256
        let frames = (x.count - win) / hop
        guard frames > 400 else { return (120, 0.05) }
        var env = [Float](repeating: 0, count: frames)
        var total: Float = 0
        for f in 0..<frames {
            var s: Float = 0
            let o = f * hop
            for k in 0..<win { let v = x[o + k]; s += v * v }
            let e = sqrt(s / Float(win))
            env[f] = e
            total += e
        }
        let rms = total / Float(frames)
        // onset strength: positive difference of log-compressed energy
        var flux = [Float](repeating: 0, count: frames)
        var prev = log(1 + 100 * env[0])
        for f in 1..<frames {
            let c = log(1 + 100 * env[f])
            flux[f] = max(0, c - prev)
            prev = c
        }
        var mean: Float = 0
        vDSP_meanv(flux, 1, &mean, vDSP_Length(frames))
        for i in 0..<frames { flux[i] -= mean }

        let fps = sr / Double(hop)
        let minLag = Int(60 * fps / 185), maxLag = Int(60 * fps / 68)
        guard maxLag * 2 < frames else { return (120, rms) }
        var ac = [Float](repeating: 0, count: maxLag * 2 + 2)
        for lag in minLag...(maxLag * 2) {
            var d: Float = 0
            vDSP_dotpr(flux, 1, Array(flux[lag...]), 1, &d, vDSP_Length(frames - lag))
            ac[lag] = d / Float(frames - lag)
        }
        var bestLag = minLag
        var best = -Float.greatestFiniteMagnitude
        for lag in minLag...maxLag {
            let bpm = 60 * fps / Double(lag)
            let prior = Float(exp(-pow(log2(bpm / 122), 2) / (2 * 0.55 * 0.55)))
            let score = (ac[lag] + 0.5 * ac[lag * 2]) * prior
            if score > best { best = score; bestLag = lag }
        }
        // parabolic interpolation for sub-lag precision
        var lagF = Double(bestLag)
        if bestLag > minLag, bestLag < maxLag {
            let a = ac[bestLag - 1], b = ac[bestLag], c = ac[bestLag + 1]
            let den = a - 2 * b + c
            if den != 0 { lagF += Double(0.5 * (a - c) / den) }
        }
        return (60 * fps / lagF, rms)
    }

    private static func key(_ x: [Float], _ sr: Double) -> (Int, Bool) {
        let n = 4096, log2n = vDSP_Length(12)
        guard x.count > n * 4, let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return (8, true) }
        defer { vDSP_destroy_fftsetup(setup) }
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        var chroma = [Float](repeating: 0, count: 12)
        var realp = [Float](repeating: 0, count: n / 2)
        var imagp = [Float](repeating: 0, count: n / 2)
        var mags = [Float](repeating: 0, count: n / 2)
        var windowed = [Float](repeating: 0, count: n)
        let hop = n * 2
        var pos = 0
        let binHz = Float(sr) / Float(n)
        while pos + n <= x.count {
            vDSP_vmul(Array(x[pos..<pos + n]), 1, window, 1, &windowed, 1, vDSP_Length(n))
            windowed.withUnsafeBufferPointer { wp in
                realp.withUnsafeMutableBufferPointer { rp in
                    imagp.withUnsafeMutableBufferPointer { ip in
                        var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                        wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { cp in
                            vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(n / 2))
                        }
                        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                        vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(n / 2))
                    }
                }
            }
            for k in 1..<(n / 2) {
                let f = Float(k) * binHz
                if f < 65 || f > 2000 { continue }
                let midi = 69 + 12 * log2(f / 440)
                let pc = ((Int(midi.rounded()) % 12) + 12) % 12
                chroma[pc] += sqrt(mags[k])
            }
            pos += hop
        }
        var bestScore = -Float.greatestFiniteMagnitude
        var bestTonic = 0
        var bestMinor = false
        for minor in [false, true] {
            let prof = minor ? minorProfile : majorProfile
            for t in 0..<12 {
                var rotated = [Float](repeating: 0, count: 12)
                for i in 0..<12 { rotated[i] = chroma[(i + t) % 12] }
                let s = pearson(rotated, prof)
                if s > bestScore { bestScore = s; bestTonic = t; bestMinor = minor }
            }
        }
        let majorTonic = bestMinor ? (bestTonic + 3) % 12 : bestTonic
        return (camelotMajor[majorTonic], bestMinor)
    }

    private static func pearson(_ a: [Float], _ b: [Float]) -> Float {
        let n = Float(a.count)
        let ma = a.reduce(0, +) / n, mb = b.reduce(0, +) / n
        var num: Float = 0, da: Float = 0, db: Float = 0
        for i in 0..<a.count {
            let x = a[i] - ma, y = b[i] - mb
            num += x * y; da += x * x; db += y * y
        }
        let den = sqrt(da * db)
        return den > 0 ? num / den : 0
    }
}

@MainActor
final class AnalysisStore: ObservableObject {
    @Published private(set) var done = 0
    @Published private(set) var total = 0
    @Published private(set) var running = false
    @Published private(set) var count = 0
    private(set) var results: [String: TrackAnalysis] = [:]

    private static var fileURL: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("lumen-analysis.json")
    }

    init() {
        if let d = try? Data(contentsOf: Self.fileURL),
           let r = try? JSONDecoder().decode([String: TrackAnalysis].self, from: d) {
            results = r
            count = r.count
        }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(results) { try? d.write(to: Self.fileURL) }
    }

    func analyze(_ tracks: [Track]) async {
        guard !running else { return }
        running = true
        defer { running = false }
        let todo = tracks.filter { t in
            guard !t.isVideo else { return false }
            guard let r = results[t.id] else { return true }
            return r.mtime != TrackAnalyzer.fileMtime(t.url)
        }
        total = todo.count
        done = 0
        var it = todo.makeIterator()
        await withTaskGroup(of: (String, TrackAnalysis?).self) { g in
            for _ in 0..<2 {
                if let t = it.next() {
                    let url = t.url, id = t.id
                    g.addTask(priority: .utility) { (id, TrackAnalyzer.analyze(url)) }
                }
            }
            for await (id, a) in g {
                done += 1
                if let a { results[id] = a; count = results.count }
                if done % 15 == 0 { save() }
                if let t = it.next() {
                    let url = t.url, id = t.id
                    g.addTask(priority: .utility) { (id, TrackAnalyzer.analyze(url)) }
                }
            }
        }
        save()
    }
}
