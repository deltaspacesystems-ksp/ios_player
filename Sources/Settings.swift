import SwiftUI
import UIKit

enum FadeCurve: String, Codable, CaseIterable, Identifiable {
    case equalPower = "Equal power", linear = "Linear", sCurve = "S-curve"
    var id: String { rawValue }
}

enum VizStyle: String, Codable, CaseIterable, Identifiable {
    case bars = "Bars", mirror = "Mirrored", dots = "Dots"
    var id: String { rawValue }
}

enum VizColor: String, Codable, CaseIterable, Identifiable {
    case accent = "Accent", art = "Artwork", white = "White"
    var id: String { rawValue }
}

enum VideoEngine: String, Codable, CaseIterable, Identifiable {
    case auto = "Auto (Apple for MP4/MOV, VLC for the rest)", vlc = "Always VLC", native = "Always Apple"
    var id: String { rawValue }
}

enum BackdropStyle: String, Codable, CaseIterable, Identifiable {
    case mesh = "Animated mesh", gradient = "Gradient", blur = "Blurred art", black = "Black"
    var id: String { rawValue }
}

struct Settings: Codable, Equatable {
    // Crossfade
    var crossfade = 6.0
    var fadeCurve: FadeCurve = .equalPower
    var fadeOnSkip = false
    var skipFade = 3.0
    // Haptics
    var hapticsOn = true
    var hapticStrength = 1.0
    var hapticCutoff = 140.0
    var hapticThreshold = 1.45
    var hapticRumble = true
    var hapticBeats = true
    var hapticBackground = true
    // Visualizer
    var vizOn = true
    var vizStyle: VizStyle = .bars
    var vizColor: VizColor = .accent
    var vizBars = 32
    var vizHeight = 70.0
    var vizGain = 1.0
    var vizFPS = 30.0
    // VLC engine
    var videoEngine: VideoEngine = .auto
    var vlcOrangeTheme = true
    var vlcNetCache = 1500
    var vlcFileCache = 1000
    var vlcHardware = true
    var vlcSubColorHex = "FFFFFF"
    var vlcSubFontSize = 16
    var vlcSubBold = false
    var vlcSubEncoding = ""
    var vlcRememberPosition = true
    var vlcAutoNext = true
    var vlcGestures = true
    // Logging
    var logLevel: LogLevel = .info
    var vlcLogLevel = 1
    var logToFile = true
    // AI DJ (offline)
    var djVoice = true
    var djLang = Locale.current.language.languageCode?.identifier == "pl" ? "pl" : "en"
    var djVoiceID = ""
    var djRate = 0.5
    var djVolume = 1.0
    var djDuck = 0.35
    var djEvery = 1
    var djTempoMatch = true
    var djMood: DJMood = .flow
    var djLength = 40
    var djFade = 8.0
    // Audio
    var eqGains: [Float] = Array(repeating: 0, count: 10)
    var preamp: Float = 0
    var speed: Float = 1
    var pitchCents: Float = 0
    // Appearance
    var accentHex = "FF2D78"
    var useCustomAccent = false
    var backdrop: BackdropStyle = .mesh
    var pulseArtwork = true
    var pulseAmount = 1.0
    var artworkRadius = 26.0
    var artworkSize = 0.72
    var clearGlass = false
    var showRemaining = true
    // Video
    var skipSeconds = 10
    var videoFill = false
    var controlsHide = 4.0
    var videoSpeed: Float = 1

    var accent: Color { useCustomAccent ? Color(hex: accentHex) : vlcOrange }
    var vlcSubColorRGB: UInt32 { UInt32(vlcSubColorHex, radix: 16) ?? 0xFFFFFF }

    private static let key = "lumen.settings.v1"

    static func load() -> Settings {
        // Merge saved values over defaults so newly added options never reset existing settings.
        guard let d = UserDefaults.standard.data(forKey: key),
              let saved = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let defData = try? JSONEncoder().encode(Settings()),
              let base = (try? JSONSerialization.jsonObject(with: defData)) as? [String: Any],
              let md = try? JSONSerialization.data(withJSONObject: base.merging(saved) { $1 }),
              let s = try? JSONDecoder().decode(Settings.self, from: md) else { return Settings() }
        return s
    }

    func save() {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: Self.key) }
    }
}

extension Color {
    init(hex: String) {
        var v: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&v)
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}

struct LGlass<S: Shape>: ViewModifier {
    @EnvironmentObject var p: Player
    let shape: S
    let interactive: Bool
    func body(content: Content) -> some View {
        var g: Glass = p.cfg.clearGlass ? .clear : .regular
        if interactive { g = g.interactive() }
        return content.glassEffect(g, in: shape)
    }
}

extension View {
    func lGlass<S: Shape>(_ shape: S, interactive: Bool = false) -> some View {
        modifier(LGlass(shape: shape, interactive: interactive))
    }
}

extension Color {
    /// Caps brightness so white controls stay readable on bright artwork.
    var capped: Color {
        var h: CGFloat = 0, sat: CGFloat = 0, br: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getHue(&h, saturation: &sat, brightness: &br, alpha: &a)
        return Color(hue: Double(h), saturation: Double(min(1, sat * 1.1)), brightness: Double(min(br, 0.45)))
    }
}
