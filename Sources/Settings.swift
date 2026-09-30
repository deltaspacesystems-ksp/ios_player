import SwiftUI
import UIKit

enum FadeCurve: String, Codable, CaseIterable, Identifiable {
    case equalPower = "Equal power", linear = "Linear", sCurve = "S-curve"
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
    // Audio
    var eqGains: [Float] = Array(repeating: 0, count: 10)
    var preamp: Float = 0
    var speed: Float = 1
    var pitchCents: Float = 0
    // Appearance
    var accentHex = "FF2D78"
    var backdrop: BackdropStyle = .mesh
    var pulseArtwork = true
    var pulseAmount = 1.0
    var artworkRadius = 26.0
    var clearGlass = false
    var showRemaining = true
    // Video
    var skipSeconds = 10
    var videoFill = false
    var controlsHide = 4.0
    var videoSpeed: Float = 1

    var accent: Color { Color(hex: accentHex) }

    private static let key = "lumen.settings.v1"

    static func load() -> Settings {
        guard let d = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(Settings.self, from: d) else { return Settings() }
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
