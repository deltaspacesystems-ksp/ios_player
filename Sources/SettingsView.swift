import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var player: Player
    @State private var confirmReset = false

    private var accentBinding: Binding<Color> {
        Binding(get: { player.cfg.accent }, set: { player.cfg.accentHex = $0.hexString })
    }

    private func row(_ title: String, _ value: String, _ slider: some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(title); Spacer(); Text(value).foregroundStyle(.secondary).monospacedDigit() }
            slider
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                appearance
                crossfade
                haptics
                equalizer
                playback
                video
                Section {
                    Button("Reset all settings", role: .destructive) { confirmReset = true }
                } footer: { Text("Formats: MP3, AAC/M4A, ALAC, FLAC, WAV, AIFF, CAF (audio) and MP4/MOV/M4V (video).") }
            }
            .navigationTitle("Settings")
            .confirmationDialog("Reset everything to defaults?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Reset", role: .destructive) { player.cfg = Settings() }
            }
        }
    }

    private var appearance: some View {
        Section("Appearance") {
            ColorPicker("Accent color", selection: accentBinding, supportsOpacity: false)
            Picker("Now Playing background", selection: $player.cfg.backdrop) {
                ForEach(BackdropStyle.allCases) { Text($0.rawValue).tag($0) }
            }
            Toggle("Clear glass (more transparent)", isOn: $player.cfg.clearGlass)
            Toggle("Artwork pulses with bass", isOn: $player.cfg.pulseArtwork)
            if player.cfg.pulseArtwork {
                row("Pulse amount", String(format: "%.1f×", player.cfg.pulseAmount),
                    Slider(value: $player.cfg.pulseAmount, in: 0.2...3))
            }
            row("Artwork corner radius", "\(Int(player.cfg.artworkRadius))",
                Slider(value: $player.cfg.artworkRadius, in: 0...60, step: 1))
            Toggle("Show remaining time", isOn: $player.cfg.showRemaining)
        }
    }

    private var crossfade: some View {
        Section {
            row("Duration", player.cfg.crossfade < 0.5 ? "Off (gapless)" : "\(Int(player.cfg.crossfade)) s",
                Slider(value: $player.cfg.crossfade, in: 0...20, step: 1))
            Picker("Curve", selection: $player.cfg.fadeCurve) {
                ForEach(FadeCurve.allCases) { Text($0.rawValue).tag($0) }
            }
            Toggle("Also crossfade when skipping", isOn: $player.cfg.fadeOnSkip)
            if player.cfg.fadeOnSkip {
                row("Skip fade", String(format: "%.1f s", player.cfg.skipFade),
                    Slider(value: $player.cfg.skipFade, in: 0.3...10))
            }
        } header: { Text("Crossfade") }
    }

    private var haptics: some View {
        Section {
            Toggle("Music haptics", isOn: $player.cfg.hapticsOn)
            if player.cfg.hapticsOn {
                row("Strength", String(format: "%.0f%%", player.cfg.hapticStrength * 100),
                    Slider(value: $player.cfg.hapticStrength, in: 0.1...1.5))
                Toggle("Continuous rumble (follows bass)", isOn: $player.cfg.hapticRumble)
                Toggle("Beat taps", isOn: $player.cfg.hapticBeats)
                row("Bass cutoff", "\(Int(player.cfg.hapticCutoff)) Hz",
                    Slider(value: $player.cfg.hapticCutoff, in: 40...400, step: 10))
                row("Beat threshold", String(format: "%.2f", player.cfg.hapticThreshold),
                    Slider(value: $player.cfg.hapticThreshold, in: 1.1...2.2))
            }
        } header: { Text("Haptics") } footer: { Text("Lower beat threshold = more taps. iPhone only.") }
    }

    private var equalizer: some View {
        Section("Equalizer") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(EQPreset.allCases) { p in
                        Button(p.rawValue) { player.applyPreset(p) }.buttonStyle(.glass)
                    }
                }
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(0..<10, id: \.self) { i in
                    VStack(spacing: 6) {
                        Slider(value: $player.cfg.eqGains[i], in: -12...12)
                            .frame(width: 120)
                            .rotationEffect(.degrees(-90))
                            .frame(width: 28, height: 120)
                        Text(["32", "64", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"][i])
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 8)
            row("Preamp", String(format: "%+.0f dB", player.cfg.preamp),
                Slider(value: $player.cfg.preamp, in: -12...12, step: 1))
        }
    }

    private var playback: some View {
        Section("Playback") {
            row("Speed", String(format: "%.2f×", player.cfg.speed),
                Slider(value: $player.cfg.speed, in: 0.5...2, step: 0.05))
            row("Pitch", String(format: "%+.0f cents", player.cfg.pitchCents),
                Slider(value: $player.cfg.pitchCents, in: -1200...1200, step: 25))
        }
    }

    private var video: some View {
        Section("Video") {
            Picker("Skip interval", selection: $player.cfg.skipSeconds) {
                ForEach([5, 10, 15, 30, 45, 60], id: \.self) { Text("\($0) s").tag($0) }
            }
            Toggle("Fill screen by default", isOn: $player.cfg.videoFill)
            row("Default speed", String(format: "%.2f×", player.cfg.videoSpeed),
                Slider(value: $player.cfg.videoSpeed, in: 0.5...2, step: 0.25))
            row("Hide controls after", String(format: "%.0f s", player.cfg.controlsHide),
                Slider(value: $player.cfg.controlsHide, in: 1...10, step: 1))
        }
    }
}
