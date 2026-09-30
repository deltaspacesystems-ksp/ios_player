import Accelerate
import AudioToolbox
import AVFoundation
import CoreHaptics
import QuartzCore

/// Drives the Taptic Engine from the music: a continuous rumble following bass energy + transient taps on beats.
final class HapticsEngine {
    private var engine: CHHapticEngine?
    private var cont: CHHapticPatternPlayer?
    private var contStart = Date.distantPast
    private let q = DispatchQueue(label: "lumen.haptics")
    private var background = false
    private var backgroundFallback = true
    let supported = CHHapticEngine.capabilitiesForHardware().supportsHaptics

    func prepare() {
        guard supported else { return }
        q.async {
            self.engine = try? CHHapticEngine()
            self.engine?.isAutoShutdownEnabled = false
            self.engine?.playsHapticsOnly = false
            self.engine?.resetHandler = { [weak self] in
                self?.q.async { self?.cont = nil; try? self?.engine?.start() }
            }
            self.engine?.stoppedHandler = { [weak self] _ in self?.q.async { self?.cont = nil } }
            try? self.engine?.start()
        }
    }

    /// Core Haptics is suspended by iOS in the background; on return we must restart the engine.
    func setBackgroundFallback(_ on: Bool) { q.async { self.backgroundFallback = on } }

    func setBackground(_ b: Bool) {
        q.async {
            self.background = b
            if !b {
                self.cont = nil
                try? self.engine?.start()
            }
        }
    }

    func update(intensity: Float) {
        q.async {
            guard let e = self.engine, !self.background else { return }
            if intensity < 0.02 {
                if let c = self.cont { try? c.sendParameters([self.param(0)], atTime: CHHapticTimeImmediate) }
                return
            }
            if self.cont == nil || Date().timeIntervalSince(self.contStart) > 25 {
                try? e.start()
                try? self.cont?.stop(atTime: CHHapticTimeImmediate)
                let ev = CHHapticEvent(eventType: .hapticContinuous,
                                       parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                                                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.25)],
                                       relativeTime: 0, duration: 30)
                guard let pattern = try? CHHapticPattern(events: [ev], parameters: []),
                      let player = try? e.makePlayer(with: pattern) else { return }
                try? player.start(atTime: CHHapticTimeImmediate)
                self.cont = player
                self.contStart = Date()
            }
            try? self.cont?.sendParameters([self.param(min(1, intensity))], atTime: CHHapticTimeImmediate)
        }
    }

    private func param(_ v: Float) -> CHHapticDynamicParameter {
        CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: v, relativeTime: 0)
    }

    func pulse(_ intensity: Float) {
        q.async {
            if self.background {
                // Best effort while backgrounded: system "peek" haptic (fixed strength). Optional.
                if self.backgroundFallback { AudioServicesPlaySystemSound(1519) }
                return
            }
            guard let e = self.engine else { return }
            try? e.start()
            let ev = CHHapticEvent(eventType: .hapticTransient,
                                   parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                                                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.7)],
                                   relativeTime: 0)
            if let p = try? CHHapticPattern(events: [ev], parameters: []),
               let pl = try? e.makePlayer(with: p) { try? pl.start(atTime: CHHapticTimeImmediate) }
        }
    }

    func stop() {
        q.async {
            try? self.cont?.stop(atTime: CHHapticTimeImmediate)
            self.cont = nil
        }
    }
}

/// Audio-thread analyzer: bass energy -> haptics + UI levels.
final class Analyzer {
    var enabled = true
    var strength: Float = 1
    var cutoff: Float = 140
    var threshold: Float = 1.45
    var rumble = true
    var beats = true
    var publish: (@Sendable (Float, Float) -> Void)?
    // Spectrum (cava-style bars)
    var barCount = 32
    var vizGain: Float = 1
    var wantBars = false
    var publishBars: (@Sendable ([Float]) -> Void)?
    private let fftN = 2048
    private let fftLog2: vDSP_Length = 11
    private var fftSetup: FFTSetup?
    private var window = [Float](repeating: 0, count: 2048)
    private var ring = [Float](repeating: 0, count: 2048)
    private var realp = [Float](repeating: 0, count: 1024)
    private var imagp = [Float](repeating: 0, count: 1024)
    private var mags = [Float](repeating: 0, count: 1024)
    private var windowed = [Float](repeating: 0, count: 2048)
    private var bars: [Float] = []
    private var edges: [Int] = []
    private var lastBars: CFTimeInterval = 0

    private let haptics: HapticsEngine
    private var lp: Float = 0, peak: Float = 0.05, avg: Float = 0
    private var lastOnset: CFTimeInterval = 0, lastPublish: CFTimeInterval = 0

    init(haptics: HapticsEngine) {
        self.haptics = haptics
        vDSP_hann_window(&window, vDSP_Length(2048), Int32(vDSP_HANN_NORM))
        fftSetup = vDSP_create_fftsetup(11, FFTRadix(kFFTRadix2))
    }

    deinit { if let s = fftSetup { vDSP_destroy_fftsetup(s) } }

    private func spectrum(_ buf: AVAudioPCMBuffer, sr: Float, now: CFTimeInterval) {
        guard wantBars, let setup = fftSetup, let ch = buf.floatChannelData else { return }
        let n = Int(buf.frameLength)
        let chs = Int(buf.format.channelCount)
        let take = min(n, fftN)
        ring.withUnsafeMutableBufferPointer { r in
            if take < fftN { memmove(r.baseAddress!, r.baseAddress! + take, (fftN - take) * MemoryLayout<Float>.size) }
            for k in 0..<take {
                var v = ch[0][n - take + k]
                if chs > 1 { v = (v + ch[1][n - take + k]) * 0.5 }
                r[fftN - take + k] = v
            }
        }
        guard now - lastBars > 1.0 / 32 else { return }
        lastBars = now

        if edges.count != barCount + 1 {
            let binHz = sr / Float(fftN)
            let lo: Float = 50, hi = min(16000, sr / 2 * 0.95)
            var e: [Int] = []
            for i in 0...barCount {
                let f = lo * powf(hi / lo, Float(i) / Float(barCount))
                var b = Int(f / binHz)
                if let last = e.last, b <= last { b = last + 1 }
                e.append(min(b, fftN / 2 - 1 + (i == barCount ? 1 : 0)))
            }
            edges = e
            bars = [Float](repeating: 0, count: barCount)
        }

        vDSP_vmul(ring, 1, window, 1, &windowed, 1, vDSP_Length(fftN))
        windowed.withUnsafeBufferPointer { wp in
            realp.withUnsafeMutableBufferPointer { rp in
                imagp.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftN / 2) { cp in
                        vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(fftN / 2))
                    }
                    vDSP_fft_zrip(setup, &split, 1, fftLog2, FFTDirection(FFT_FORWARD))
                    vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(fftN / 2))
                }
            }
        }
        for b in 0..<barCount {
            var m: Float = 0
            let a = edges[b], z = max(edges[b + 1], a + 1)
            for k in a..<min(z, fftN / 2) { m = max(m, mags[k]) }
            let amp = sqrt(m) / Float(fftN)
            let db = 20 * log10(amp + 1e-7)
            let tilt = Float(b) / Float(barCount) * 12
            let v = min(1, max(0, (db + 68 + tilt) / 58) * vizGain)
            bars[b] = v > bars[b] ? bars[b] * 0.35 + v * 0.65 : bars[b] * 0.88 + v * 0.12
        }
        publishBars?(bars)
    }

    func process(_ buf: AVAudioPCMBuffer) {
        guard let ch = buf.floatChannelData, buf.frameLength > 0 else { return }
        let n = Int(buf.frameLength)
        let sr = Float(buf.format.sampleRate)
        spectrum(buf, sr: sr, now: CACurrentMediaTime())
        let a = 1 - exp(-2 * Float.pi * cutoff / sr)
        let x0 = ch[0]
        var full: Float = 0, low: Float = 0
        for i in 0..<n {
            let x = x0[i]
            lp += a * (x - lp)
            full += x * x
            low += lp * lp
        }
        full = sqrt(full / Float(n))
        low = sqrt(low / Float(n))
        peak = max(peak * 0.9993, low, 0.03)
        let norm = min(1, low / peak)
        let now = CACurrentMediaTime()
        if enabled {
            haptics.update(intensity: rumble ? powf(norm, 1.6) * 0.55 * strength : 0)
            if beats && low > avg * threshold && norm > 0.4 && now - lastOnset > 0.12 {
                lastOnset = now
                haptics.pulse(min(1, (0.5 + norm * 0.5) * strength))
            }
        }
        avg = avg * 0.88 + low * 0.12
        if now - lastPublish > 0.05 {
            lastPublish = now
            publish?(min(1, full * 2.5), norm)
        }
    }
}

func installTap(on node: AVAudioMixerNode, analyzer: Analyzer) {
    node.installTap(onBus: 0, bufferSize: 1024, format: nil) { buf, _ in analyzer.process(buf) }
}
