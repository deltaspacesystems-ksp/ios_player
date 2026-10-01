import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var player: Player
    @EnvironmentObject var library: Library
    @EnvironmentObject var analysis: AnalysisStore
    @State private var addFolder = false
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
                folders
                vlcEngine
                visualizer
                dj
                appearance
                crossfade
                haptics
                equalizer
                playback
                video
                Section {
                    NavigationLink { LogViewer() } label: { Label("Logs & diagnostics", systemImage: "doc.text.magnifyingglass") }
                }
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

    private var vlcEngine: some View {
        Section {
            Picker("Video engine", selection: $player.cfg.videoEngine) {
                ForEach(VideoEngine.allCases) { Text($0.rawValue).tag($0) }
            }
            Toggle("VLC orange theme in the VLC player", isOn: $player.cfg.vlcOrangeTheme)
            Toggle("Remember playback position", isOn: $player.cfg.vlcRememberPosition)
            Toggle("Play next automatically", isOn: $player.cfg.vlcAutoNext)
            Toggle("Gestures (brightness, volume, seek)", isOn: $player.cfg.vlcGestures)
            Toggle("Hardware decoding", isOn: $player.cfg.vlcHardware)
            Stepper("Network caching: \(player.cfg.vlcNetCache) ms", value: $player.cfg.vlcNetCache, in: 0...10000, step: 250)
            Stepper("File caching: \(player.cfg.vlcFileCache) ms", value: $player.cfg.vlcFileCache, in: 0...5000, step: 100)
            ColorPicker("Subtitle color", selection: Binding(get: { Color(hex: player.cfg.vlcSubColorHex) }, set: { player.cfg.vlcSubColorHex = $0.hexString }), supportsOpacity: false)
            Picker("Subtitle size", selection: $player.cfg.vlcSubFontSize) {
                Text("Smaller").tag(20)
                Text("Small").tag(18)
                Text("Normal").tag(16)
                Text("Large").tag(12)
                Text("Larger").tag(6)
            }
            Toggle("Bold subtitles", isOn: $player.cfg.vlcSubBold)
            TextField("Subtitle encoding (e.g. CP1250, empty = auto)", text: $player.cfg.vlcSubEncoding)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: { Text("VLC engine (libvlc 4)") } footer: {
            Text("Plays MKV, AVI, WebM, FLV, WMV, TS, OGG, Opus, WMA, APE and more. Changes apply to the next video you open.")
        }
    }

    private var visualizer: some View {
        Section("Visualizer") {
            Toggle("Spectrum on Now Playing", isOn: $player.cfg.vizOn)
            if player.cfg.vizOn {
                Picker("Style", selection: $player.cfg.vizStyle) {
                    ForEach(VizStyle.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Color", selection: $player.cfg.vizColor) {
                    ForEach(VizColor.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                row("Refresh rate", "\(Int(player.cfg.vizFPS)) fps", Slider(value: $player.cfg.vizFPS, in: 1...60, step: 1))
                Stepper("Bars: \(player.cfg.vizBars)", value: $player.cfg.vizBars, in: 12...64, step: 4)
                row("Height", "\(Int(player.cfg.vizHeight)) pt", Slider(value: $player.cfg.vizHeight, in: 30...160, step: 5))
                row("Sensitivity", String(format: "%.1f×", player.cfg.vizGain), Slider(value: $player.cfg.vizGain, in: 0.5...2.5))
            }
        }
    }

    private var voices: [AVSpeechSynthesisVoice] {
        let prefix = player.cfg.djLang == "pl" ? "pl" : "en"
        return AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(prefix) }
    }

    private var dj: some View {
        Group {
            Section {
                Toggle("Voice announcements", isOn: $player.cfg.djVoice)
                if player.cfg.djVoice {
                    Picker("Language", selection: $player.cfg.djLang) {
                        Text("Polski").tag("pl")
                        Text("English").tag("en")
                    }
                    Picker("Voice", selection: $player.cfg.djVoiceID) {
                        Text("Automatic").tag("")
                        ForEach(voices, id: \.identifier) { v in
                            Text(v.name + (v.quality == .premium ? " (premium)" : v.quality == .enhanced ? " (enhanced)" : "")).tag(v.identifier)
                        }
                    }
                    row("Speech rate", String(format: "%.2f", player.cfg.djRate), Slider(value: $player.cfg.djRate, in: 0.35...0.6))
                    row("Voice volume", "\(Int(player.cfg.djVolume * 100))%", Slider(value: $player.cfg.djVolume, in: 0.3...1))
                    row("Music level while talking", "\(Int(player.cfg.djDuck * 100))%", Slider(value: $player.cfg.djDuck, in: 0.05...1))
                    Stepper("Announce every \(player.cfg.djEvery) track(s)", value: $player.cfg.djEvery, in: 1...10)
                    Button("Test voice", systemImage: "speaker.wave.2") { player.testVoice() }
                }
                Picker("Mood", selection: $player.cfg.djMood) {
                    ForEach(DJMood.allCases) { Text($0.rawValue).tag($0) }
                }
                Stepper("Mix length: \(player.cfg.djLength) tracks", value: $player.cfg.djLength, in: 10...200, step: 10)
                row("DJ crossfade", "\(Int(player.cfg.djFade)) s", Slider(value: $player.cfg.djFade, in: 1...20, step: 1))
                Toggle("Match tempo in transitions", isOn: $player.cfg.djTempoMatch)
            } header: { Text("DJ (offline)") } footer: {
                Text("Builds mixes by tempo, key (Camelot) and energy, all on-device. Start it with the DJ button on Songs or the sparkles button in Now Playing.")
            }
            Section("Library analysis") {
                if analysis.running {
                    ProgressView(value: Double(analysis.done), total: Double(max(1, analysis.total)))
                    Text("Analyzing \(analysis.done) / \(analysis.total)").foregroundStyle(.secondary)
                } else {
                    Text("\(analysis.count) of \(library.audio.count) tracks analyzed").foregroundStyle(.secondary)
                    Button("Analyze library", systemImage: "waveform.badge.magnifyingglass") {
                        Task { await analysis.analyze(library.audio) }
                    }
                }
            }
        }
    }

    private var folders: some View {
        Section {
            ForEach(library.folders) { f in
                HStack {
                    Label(f.name, systemImage: f.available ? "folder.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(f.available ? Color.primary : Color.orange)
                    if !f.available { Spacer(); Text("Tap Add to re-grant").font(.caption).foregroundStyle(.secondary) }
                }
                .swipeActions { Button("Remove", role: .destructive) { Task { await library.removeFolder(f) } } }
            }
            Button("Add folder…", systemImage: "folder.badge.plus") { addFolder = true }
            Button("Rescan library", systemImage: "arrow.clockwise") { Task { await library.reload() } }
            if library.scanning { HStack { ProgressView(); Text("Scanning…").foregroundStyle(.secondary) } }
        } header: { Text("Library folders") } footer: {
            Text("Folders are remembered and scanned recursively on every launch; files are read in place. If a folder shows a warning (can happen inside LiveContainer), pick it again with Add folder. Swipe to remove.")
        }
        .fileImporter(isPresented: $addFolder, allowedContentTypes: [.folder]) { r in
            if case .success(let u) = r { Task { await library.addFolder(u) } }
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
            row("Artwork size", "\(Int(player.cfg.artworkSize * 100))%",
                Slider(value: $player.cfg.artworkSize, in: 0.3...1, step: 0.01))
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
                Toggle("Background taps (system workaround)", isOn: $player.cfg.hapticBackground)
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
