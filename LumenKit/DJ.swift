import AVFoundation
import Foundation

enum DJMood: String, Codable, CaseIterable, Identifiable {
    case flow = "Flow", build = "Build up", chill = "Chill", party = "Party"
    var id: String { rawValue }
}

/// Builds a harmonically + rhythmically smooth track order from offline analysis.
enum DJPlanner {
    static func bpmDistance(_ a: Double, _ b: Double) -> Double {
        [1.0, 2.0, 0.5].map { abs(a - b * $0) / a }.min() ?? 1
    }

    static func keyDistance(_ a: TrackAnalysis, _ b: TrackAnalysis) -> Double {
        let d = abs(a.camelot - b.camelot)
        let cd = Double(min(d, 12 - d))
        if a.minor == b.minor { return cd == 0 ? 0 : (cd == 1 ? 0.1 : cd * 0.35) }
        return cd == 0 ? 0.1 : 0.2 + cd * 0.35
    }

    private static func target(_ mood: DJMood, step: Int, cur: Double) -> Double {
        switch mood {
        case .flow: return cur
        case .build: return min(1, 0.3 + Double(step) * 0.04)
        case .chill: return 0.25
        case .party: return 0.85
        }
    }

    private static func cost(_ a: Track, _ b: Track, _ an: [String: TrackAnalysis], target: Double) -> Double {
        var c = 0.0
        if let x = an[a.id], let y = an[b.id] {
            c = bpmDistance(x.bpm, y.bpm) * 4 + keyDistance(x, y) * 1.5 + abs(y.energy - target)
        } else {
            c = 1.2 + Double.random(in: 0...0.3)
        }
        if !a.artist.isEmpty, a.artist == b.artist { c += 0.5 }
        return c
    }

    static func build(start: Track, pool: [Track], analysis: [String: TrackAnalysis],
                      mood: DJMood, length: Int, exclude: Set<String> = []) -> [Track] {
        var remaining = pool.filter { $0.id != start.id && !$0.isVideo && !exclude.contains($0.id) }
        var out = [start]
        var cur = start
        while out.count < length, !remaining.isEmpty {
            let t = target(mood, step: out.count, cur: analysis[cur.id]?.energy ?? 0.5)
            var best: [(Int, Double)] = []
            for (i, tr) in remaining.enumerated() {
                let c = cost(cur, tr, analysis, target: t)
                if best.count < 3 { best.append((i, c)); best.sort { $0.1 < $1.1 } }
                else if c < best[2].1 { best[2] = (i, c); best.sort { $0.1 < $1.1 } }
            }
            guard let pick = best.randomElement() else { break }
            cur = remaining.remove(at: pick.0)
            out.append(cur)
        }
        return out
    }
}

/// Template-based spoken lines (works fully offline).
enum DJScript {
    private static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "\\s*[\\(\\[][^\\)\\]]*[\\)\\]]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func fill(_ t: String, _ tr: Track) -> String {
        let title = clean(tr.title)
        let artist = clean(tr.artist)
        var s = t.replacingOccurrences(of: "{t}", with: title)
        s = artist.isEmpty
            ? s.replacingOccurrences(of: ", {a}", with: "").replacingOccurrences(of: " by {a}", with: "")
                .replacingOccurrences(of: " — {a}", with: "").replacingOccurrences(of: "{a}", with: title)
            : s.replacingOccurrences(of: "{a}", with: artist)
        return s
    }

    static func nextLine(_ tr: Track, _ a: TrackAnalysis?, lang: String) -> String {
        let pl = lang == "pl"
        let templates = pl
            ? ["Za chwilę: {t}, {a}.", "Zostajemy z muzyką — {t}, {a}.", "Teraz {a} i kawałek {t}.",
               "Lecimy dalej: {t}, {a}.", "A teraz coś dla Ciebie: {t}, {a}."]
            : ["Up next: {t} by {a}.", "Here comes {t}, from {a}.", "Keep it going — {t}, {a}.",
               "{a} with {t}.", "Coming up: {t} by {a}."]
        var line = fill(templates.randomElement() ?? templates[0], tr)
        if let a, Int.random(in: 0..<4) == 0 {
            let bpm = Int(a.bpm.rounded())
            line += pl ? " Tempo: \(bpm) uderzeń na minutę." : " That's \(bpm) beats per minute."
        }
        return line
    }

    static func introLine(_ tr: Track, lang: String) -> String {
        let t = lang == "pl"
            ? "Cześć, tu Twój DJ Lumen. Zaczynamy od: {t}, {a}."
            : "Hey, it's your Lumen DJ. Let's start with {t} by {a}."
        return fill(t, tr)
    }
}

@MainActor
final class DJVoice: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    var onSpeaking: ((Bool) -> Void)?

    override init() {
        super.init()
        synth.delegate = self
    }

    func speak(_ text: String, lang: String, voiceID: String, rate: Float, volume: Float) {
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(identifier: voiceID)
            ?? AVSpeechSynthesisVoice(language: lang == "pl" ? "pl-PL" : "en-US")
        u.rate = rate
        u.volume = volume
        u.preUtteranceDelay = 0.15
        synth.speak(u)
    }

    func stop() { synth.stopSpeaking(at: .immediate) }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didStart u: AVSpeechUtterance) {
        Task { @MainActor in self.onSpeaking?(true) }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Task { @MainActor in self.onSpeaking?(false) }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        Task { @MainActor in self.onSpeaking?(false) }
    }
}
