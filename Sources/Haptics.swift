import AVFoundation
import CoreHaptics
import QuartzCore

/// Drives the Taptic Engine from the music: a continuous rumble following bass energy + transient taps on beats.
final class HapticsEngine {
    private var engine: CHHapticEngine?
    private var cont: CHHapticPatternPlayer?
    private var contStart = Date.distantPast
    private let q = DispatchQueue(label: "lumen.haptics")
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

    func update(intensity: Float) {
        q.async {
            guard let e = self.engine else { return }
            if intensity < 0.02 {
                if let c = self.cont { try? c.sendParameters([self.param(0)], atTime: CHHapticTimeImmediate) }
                return
            }
            if self.cont == nil || Date().timeIntervalSince(self.contStart) > 25 {
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
            guard let e = self.engine else { return }
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
    private let haptics: HapticsEngine
    private var lp: Float = 0, peak: Float = 0.05, avg: Float = 0
    private var lastOnset: CFTimeInterval = 0, lastPublish: CFTimeInterval = 0

    init(haptics: HapticsEngine) { self.haptics = haptics }

    func process(_ buf: AVAudioPCMBuffer) {
        guard let ch = buf.floatChannelData, buf.frameLength > 0 else { return }
        let n = Int(buf.frameLength)
        let sr = Float(buf.format.sampleRate)
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
