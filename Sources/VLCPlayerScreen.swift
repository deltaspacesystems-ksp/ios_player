import SwiftUI
import UIKit
import UniformTypeIdentifiers
import VLCKit

struct VLCSurface: UIViewRepresentable {
    let controller: VLCController
    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .black
        v.isUserInteractionEnabled = false
        DispatchQueue.main.async { controller.attach(v) }
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

private struct HUDInfo: Equatable {
    var icon: String
    var text: String
}

struct VLCPlayerScreen: View {
    @EnvironmentObject var app: Player
    @StateObject private var vlc: VLCController
    @Environment(\.dismiss) private var dismiss
    @State private var controls = true
    @State private var locked = false
    @State private var showMore = false
    @State private var hideTask: Task<Void, Never>?
    @State private var scrubbing = false
    @State private var scrubMs = 0
    @State private var dragAxis: Axis?
    @State private var dragStart = 0
    @State private var startBrightness: CGFloat = 0
    @State private var startVolume = 100
    @State private var hud: HUDInfo?
    @State private var landscape = false

    init(items: [VLCItem], start: Int, cfg: Settings) {
        _vlc = StateObject(wrappedValue: VLCController(items: items, start: start, cfg: cfg))
    }

    private var tint: Color { app.cfg.vlcOrangeTheme ? vlcOrange : app.cfg.accent }
    private var skipSec: Int { app.cfg.skipSeconds }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VLCSurface(controller: vlc).ignoresSafeArea()
            gestureLayer
            if vlc.buffering { ProgressView().controlSize(.large).tint(.white) }
            if let e = vlc.error { errorView(e) }
            if controls && !locked { overlay.transition(.opacity) }
            if locked { lockOverlay }
            if let h = hud { hudView(h) }
            if let t = vlc.toast { toast(t) }
        }
        .statusBarHidden(!controls)
        .persistentSystemOverlays(controls ? .automatic : .hidden)
        .preferredColorScheme(.dark)
        .tint(tint)
        .onAppear {
            app.pause()
            scheduleHide()
            Log.i("vlc-ui", "Player screen appeared")
        }
        .onDisappear {
            vlc.stop()
            setOrientation(portraitAllowed: true)
        }
        .sheet(isPresented: $showMore) {
            VLCMoreOptions(vlc: vlc, tint: tint)
                .environmentObject(app)
                .presentationDetents([.medium, .large])
                .presentationBackground(.regularMaterial)
        }
    }

    // MARK: Gestures

    private var gestureLayer: some View {
        GeometryReader { geo in
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    SpatialTapGesture(count: 2).onEnded { v in
                        guard !locked else { return }
                        let x = v.location.x / geo.size.width
                        if x < 0.35 { vlc.skip(-skipSec); flash("gobackward", "-\(skipSec) s") }
                        else if x > 0.65 { vlc.skip(skipSec); flash("goforward", "+\(skipSec) s") }
                        else { vlc.togglePlay() }
                    }
                    .exclusively(before: TapGesture().onEnded {
                        withAnimation(.easeInOut(duration: 0.25)) { controls.toggle() }
                        scheduleHide()
                    })
                )
                .gesture(
                    DragGesture(minimumDistance: 14)
                        .onChanged { v in
                            guard !locked, app.cfg.vlcGestures else { return }
                            if dragAxis == nil {
                                dragAxis = abs(v.translation.width) > abs(v.translation.height) ? .horizontal : .vertical
                                dragStart = vlc.timeMs
                                startBrightness = UIScreen.main.brightness
                                startVolume = vlc.volumeBoost
                            }
                            if dragAxis == .horizontal {
                                scrubMs = max(0, min(vlc.lengthMs, dragStart + Int(v.translation.width / geo.size.width * 120_000)))
                                hud = HUDInfo(icon: "arrow.left.and.right", text: formatTime(Double(scrubMs) / 1000))
                            } else {
                                let delta = -v.translation.height / geo.size.height
                                if v.startLocation.x < geo.size.width / 2 {
                                    let b = max(0, min(1, startBrightness + delta))
                                    UIScreen.main.brightness = b
                                    hud = HUDInfo(icon: "sun.max.fill", text: "\(Int(b * 100))%")
                                } else {
                                    let vol = max(0, min(200, startVolume + Int(delta * 200)))
                                    vlc.volumeBoost = vol
                                    hud = HUDInfo(icon: vol == 0 ? "speaker.slash.fill" : "speaker.wave.3.fill", text: "\(vol)%")
                                }
                            }
                        }
                        .onEnded { _ in
                            if dragAxis == .horizontal { vlc.seek(ms: scrubMs) }
                            dragAxis = nil
                            hideHUD()
                        }
                )
                .simultaneousGesture(
                    MagnifyGesture().onEnded { v in
                        guard !locked else { return }
                        vlc.aspect = v.magnification > 1.05 ? .fill : .standard
                        flash("arrow.up.left.and.arrow.down.right", vlc.aspect.rawValue)
                    }
                )
        }
    }

    private func flash(_ icon: String, _ text: String) {
        hud = HUDInfo(icon: icon, text: text)
        hideHUD()
    }

    private func hideHUD() {
        Task {
            try? await Task.sleep(for: .seconds(0.9))
            withAnimation { hud = nil }
        }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(app.cfg.controlsHide))
            if !Task.isCancelled, vlc.isPlaying, !showMore { withAnimation(.easeInOut(duration: 0.3)) { controls = false } }
        }
    }

    private func setOrientation(portraitAllowed: Bool) {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        let mask: UIInterfaceOrientationMask = portraitAllowed ? .allButUpsideDown : .landscape
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
    }

    // MARK: Overlays

    private var overlay: some View {
        VStack(spacing: 0) {
            topBar
            Spacer()
            centerControls
            Spacer()
            bottomBar
        }
        .foregroundStyle(.white)
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            circle("chevron.down") { dismiss() }
            VStack(alignment: .leading, spacing: 1) {
                Text(vlc.title).font(.headline).lineLimit(1)
                if vlc.items.count > 1 {
                    Text("\(vlc.index + 1) of \(vlc.items.count)").font(.caption).foregroundStyle(.white.opacity(0.7))
                }
            }
            Spacer()
            if vlc.recording { Image(systemName: "record.circle.fill").foregroundStyle(.red).symbolEffect(.pulse) }
            RoutePicker(accent: UIColor(tint)).frame(width: 40, height: 40).lGlass(Circle(), interactive: true)
            circle("lock.open") { locked = true; withAnimation { controls = false }; flash("lock.fill", "Locked") }
            circle("ellipsis") { showMore = true }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 24)
        .background(LinearGradient(colors: [.black.opacity(0.65), .clear], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
    }

    private var centerControls: some View {
        GlassEffectContainer(spacing: 24) {
            HStack(spacing: 22) {
                bigCircle("backward.end.fill", 22) { vlc.previous(); scheduleHide() }
                bigCircle("gobackward.\(skipSec)", 26) { vlc.skip(-skipSec); scheduleHide() }
                Button { vlc.togglePlay(); scheduleHide() } label: {
                    Image(systemName: vlc.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 36))
                        .frame(width: 78, height: 78)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.glass).buttonBorderShape(.circle)
                bigCircle("goforward.\(skipSec)", 26) { vlc.skip(skipSec); scheduleHide() }
                bigCircle("forward.end.fill", 22) { vlc.next(); scheduleHide() }
            }
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            VStack(spacing: 2) {
                Scrubber(value: Double(scrubbing ? scrubMs : vlc.timeMs), total: Double(max(1, vlc.lengthMs)), fill: tint) { v in
                    vlc.seek(ms: Int(v))
                    scheduleHide()
                }
                HStack {
                    Text(formatTime(Double(vlc.timeMs) / 1000))
                    Spacer()
                    Text(vlc.lengthMs > 0 ? "-" + formatTime(Double(max(0, vlc.lengthMs - vlc.timeMs)) / 1000) : "LIVE")
                }
                .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.8))
            }
            HStack(spacing: 10) {
                pill(vlc.rate == 1 ? "1×" : String(format: "%g×", vlc.rate), "speedometer") { cycleSpeed() }
                pill(vlc.aspect.rawValue, "aspectratio") { cycleAspect() }
                pill(vlc.abState == 0 ? "A–B" : vlc.abState == 1 ? "A…" : "A–B ●", "repeat") { vlc.abTap() }
                Spacer()
                circle(landscape ? "iphone" : "iphone.landscape", size: 38) {
                    landscape.toggle()
                    setOrientation(portraitAllowed: !landscape)
                }
                circle(vlc.repeatMode == .one ? "repeat.1" : "repeat", size: 38) { vlc.cycleRepeat(); flash("repeat", repeatName) }
                circle("captions.bubble", size: 38) { showMore = true }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .lGlass(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    private var repeatName: String {
        switch vlc.repeatMode {
        case .off: return "Repeat off"
        case .all: return "Repeat all"
        case .one: return "Repeat one"
        }
    }

    private func cycleSpeed() {
        let steps: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]
        let i = steps.firstIndex(where: { $0 > vlc.rate + 0.001 }) ?? 0
        vlc.rate = steps[i]
        flash("speedometer", String(format: "%g×", vlc.rate))
        scheduleHide()
    }

    private func cycleAspect() {
        let all = AspectChoice.allCases
        let i = (all.firstIndex(of: vlc.aspect) ?? 0) + 1
        vlc.aspect = all[i % all.count]
        flash("aspectratio", vlc.aspect.rawValue)
        scheduleHide()
    }

    private func circle(_ icon: String, size: CGFloat = 40, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: 17, weight: .semibold)).frame(width: size, height: size) }
            .buttonStyle(.plain)
            .lGlass(Circle(), interactive: true)
    }

    private func bigCircle(_ icon: String, _ pt: CGFloat, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: pt)).frame(width: 52, height: 52) }
            .buttonStyle(.glass).buttonBorderShape(.circle)
    }

    private func pill(_ text: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(text, systemImage: icon).font(.footnote.weight(.semibold)).padding(.horizontal, 12).frame(height: 38)
        }
        .buttonStyle(.plain)
        .lGlass(Capsule(), interactive: true)
    }

    private var lockOverlay: some View {
        VStack {
            HStack {
                Spacer()
                Button {
                    locked = false
                    withAnimation { controls = true }
                    scheduleHide()
                } label: { Image(systemName: "lock.fill").font(.title3).frame(width: 46, height: 46) }
                    .buttonStyle(.glass).buttonBorderShape(.circle)
                    .opacity(controls ? 1 : 0.0)
            }
            .padding()
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation { controls.toggle() } }
    }

    private func hudView(_ h: HUDInfo) -> some View {
        Label(h.text, systemImage: h.icon)
            .font(.title3.weight(.semibold).monospacedDigit())
            .padding(.horizontal, 20).padding(.vertical, 12)
            .lGlass(Capsule())
            .transition(.opacity)
    }

    private func toast(_ t: String) -> some View {
        VStack {
            Spacer()
            Text(t).font(.subheadline.weight(.medium)).padding(.horizontal, 16).padding(.vertical, 10)
                .lGlass(Capsule())
                .padding(.bottom, 120)
        }
        .transition(.opacity)
        .allowsHitTesting(false)
    }

    private func errorView(_ e: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 44)).foregroundStyle(tint)
            Text("Can't play this file").font(.headline)
            Text(e).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack {
                Button("Retry") { vlc.load(vlc.index) }.buttonStyle(.borderedProminent)
                Button("Close") { dismiss() }.buttonStyle(.bordered)
            }
        }
        .padding(24)
        .lGlass(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(32)
    }
}

// MARK: - More options (VLC-style action sheet)

enum VLCPage: String, Hashable, CaseIterable, Identifiable {
    case playback = "Playback", tracks = "Tracks", sleep = "Sleep Timer", filters = "Video Filters"
    case equalizer = "Equalizer", chapters = "Chapters", bookmarks = "Bookmarks", cast = "Cast", info = "Media Info"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .playback: return "gauge.with.dots.needle.50percent"
        case .tracks: return "captions.bubble"
        case .sleep: return "moon.zzz"
        case .filters: return "slider.horizontal.3"
        case .equalizer: return "waveform"
        case .chapters: return "list.number"
        case .bookmarks: return "bookmark"
        case .cast: return "tv.badge.wifi"
        case .info: return "info.circle"
        }
    }
}

struct VLCMoreOptions: View {
    @ObservedObject var vlc: VLCController
    let tint: Color

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                        ForEach(VLCPage.allCases) { p in
                            NavigationLink(value: p) {
                                VStack(spacing: 8) {
                                    Image(systemName: p.icon).font(.title2).foregroundStyle(tint)
                                    Text(p.rawValue).font(.footnote.weight(.medium)).multilineTextAlignment(.center)
                                }
                                .frame(maxWidth: .infinity, minHeight: 82)
                                .lGlass(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    HStack(spacing: 12) {
                        action("Snapshot", "camera") { vlc.snapshot() }
                        action(vlc.recording ? "Stop rec" : "Record", vlc.recording ? "stop.circle" : "record.circle") { vlc.toggleRecording() }
                        action("Frame ◂", "backward.frame") { vlc.previousFrame() }
                        action("Frame ▸", "forward.frame") { vlc.nextFrame() }
                    }
                    HStack(spacing: 12) {
                        action("Shuffle", "shuffle", on: vlc.shuffle) { vlc.toggleShuffle() }
                        action(vlc.repeatMode == .one ? "Repeat 1" : "Repeat", "repeat", on: vlc.repeatMode != .off) { vlc.cycleRepeat() }
                        action("A–B", "repeat.circle", on: vlc.abState != 0) { vlc.abTap() }
                    }
                }
                .padding(16)
            }
            .navigationTitle("More options")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: VLCPage.self) { page in
                Group {
                    switch page {
                    case .playback: PlaybackPage(vlc: vlc)
                    case .tracks: TracksPage(vlc: vlc)
                    case .sleep: SleepPage(vlc: vlc)
                    case .filters: FiltersPage(vlc: vlc)
                    case .equalizer: EqualizerPage(vlc: vlc)
                    case .chapters: ChaptersPage(vlc: vlc)
                    case .bookmarks: BookmarksPage(vlc: vlc)
                    case .cast: CastPage(vlc: vlc)
                    case .info: InfoPage(vlc: vlc)
                    }
                }
                .navigationTitle(page.rawValue)
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .tint(tint)
    }

    private func action(_ title: String, _ icon: String, on: Bool = false, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.title3)
                Text(title).font(.caption2.weight(.medium)).lineLimit(1)
            }
            .foregroundStyle(on ? tint : .primary)
            .frame(maxWidth: .infinity, minHeight: 64)
            .lGlass(RoundedRectangle(cornerRadius: 16, style: .continuous), interactive: true)
        }
        .buttonStyle(.plain)
    }
}

private func sliderRow(_ title: String, _ value: String, _ slider: some View) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        HStack { Text(title); Spacer(); Text(value).foregroundStyle(.secondary).monospacedDigit() }
        slider
    }
}

struct PlaybackPage: View {
    @ObservedObject var vlc: VLCController
    var body: some View {
        Form {
            Section("Speed") {
                sliderRow("Playback speed", String(format: "%.2f×", vlc.rate), Slider(value: $vlc.rate, in: 0.25...4, step: 0.05))
                HStack {
                    ForEach([Float(0.5), 1, 1.5, 2], id: \.self) { s in
                        Button(String(format: "%g×", s)) { vlc.rate = s }.buttonStyle(.bordered)
                    }
                }
            }
            Section("Sync") {
                sliderRow("Audio delay", "\(vlc.audioDelayMs) ms",
                          Slider(value: Binding(get: { Double(vlc.audioDelayMs) }, set: { vlc.audioDelayMs = Int($0) }), in: -2000...2000, step: 10))
                sliderRow("Subtitle delay", "\(vlc.subDelayMs) ms",
                          Slider(value: Binding(get: { Double(vlc.subDelayMs) }, set: { vlc.subDelayMs = Int($0) }), in: -5000...5000, step: 50))
                sliderRow("Subtitle size", String(format: "%.0f%%", vlc.subScale * 100), Slider(value: $vlc.subScale, in: 0.4...3, step: 0.05))
            }
            Section("Video") {
                Picker("Aspect ratio", selection: $vlc.aspect) {
                    ForEach(AspectChoice.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Deinterlace", selection: $vlc.deinterlace) {
                    Text("Off").tag(0)
                    Text("Auto").tag(-1)
                    Text("On").tag(1)
                }
            }
            Section("Audio") {
                sliderRow("Volume", "\(vlc.volumeBoost)%", Slider(value: Binding(get: { Double(vlc.volumeBoost) }, set: { vlc.volumeBoost = Int($0) }), in: 0...200, step: 1))
                Picker("Stereo mode", selection: $vlc.stereoMode) {
                    Text("Default").tag(0)
                    Text("Stereo").tag(1)
                    Text("Reverse stereo").tag(2)
                    Text("Left only").tag(3)
                    Text("Right only").tag(4)
                    Text("Dolby surround").tag(5)
                    Text("Mono").tag(7)
                }
                Picker("Mix mode", selection: $vlc.mixMode) {
                    Text("Default").tag(0)
                    Text("Stereo").tag(1)
                    Text("Binaural").tag(2)
                    Text("4.0").tag(3)
                    Text("5.1").tag(4)
                    Text("7.1").tag(5)
                }
            }
        }
    }
}

struct TracksPage: View {
    @ObservedObject var vlc: VLCController
    @State private var importing = false

    var body: some View {
        Form {
            Section("Audio") {
                Button { vlc.selectAudio(nil) } label: { row("Disable", selected: vlc.audioTracks.allSatisfy { !$0.isSelected }) }
                ForEach(Array(vlc.audioTracks.enumerated()), id: \.offset) { _, t in
                    Button { vlc.selectAudio(t) } label: { row(t.trackName, selected: t.isSelected) }
                }
            }
            Section("Subtitles") {
                Button { vlc.selectText(nil) } label: { row("Disable", selected: vlc.textTracks.allSatisfy { !$0.isSelected }) }
                ForEach(Array(vlc.textTracks.enumerated()), id: \.offset) { _, t in
                    Button { vlc.selectText(t) } label: { row(t.trackName, selected: t.isSelected) }
                }
                Button("Add subtitle file…", systemImage: "doc.badge.plus") { importing = true }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { r in
            if case .success(let u) = r { vlc.addSubtitle(u) }
        }
        .onAppear { vlc.refreshTracks() }
    }

    private func row(_ title: String, selected: Bool) -> some View {
        HStack {
            Text(title).foregroundStyle(.primary)
            Spacer()
            if selected { Image(systemName: "checkmark") }
        }
    }
}

struct SleepPage: View {
    @ObservedObject var vlc: VLCController
    var body: some View {
        Form {
            if let end = vlc.sleepEnd {
                Section { Text("Stops \(end.formatted(date: .omitted, time: .shortened))") }
            }
            Section("Pause playback in") {
                ForEach([5, 15, 30, 45, 60, 90, 120], id: \.self) { m in
                    Button("\(m) minutes") { vlc.setSleep(minutes: m) }
                }
                Button("At the end of this media") { vlc.setSleep(minutes: nil, atEnd: true); vlc.show("Will pause at the end") }
            }
            Section { Button("Turn off", role: .destructive) { vlc.setSleep(minutes: nil) } }
        }
    }
}

struct FiltersPage: View {
    @ObservedObject var vlc: VLCController
    var body: some View {
        Form {
            Section { Toggle("Enable video filters", isOn: $vlc.adjustOn) }
            if vlc.adjustOn {
                Section {
                    sliderRow("Brightness", String(format: "%.2f", vlc.brightness), Slider(value: $vlc.brightness, in: 0...2))
                    sliderRow("Contrast", String(format: "%.2f", vlc.contrast), Slider(value: $vlc.contrast, in: 0...2))
                    sliderRow("Hue", String(format: "%.0f°", vlc.hue), Slider(value: $vlc.hue, in: 0...360))
                    sliderRow("Saturation", String(format: "%.2f", vlc.saturation), Slider(value: $vlc.saturation, in: 0...3))
                    sliderRow("Gamma", String(format: "%.2f", vlc.gamma), Slider(value: $vlc.gamma, in: 0.1...3))
                }
                Section { Button("Reset", role: .destructive) { vlc.resetAdjust() } }
            }
        }
    }
}

struct EqualizerPage: View {
    @ObservedObject var vlc: VLCController
    private let freqs = ["60", "170", "310", "600", "1k", "3k", "6k", "12k", "14k", "16k"]

    var body: some View {
        Form {
            Section("Preset") {
                Picker("Preset", selection: Binding(get: { vlc.eqPreset }, set: { vlc.setEqualizer(preset: $0) })) {
                    Text("Off / custom").tag(-1)
                    ForEach(Array(VLCAudioEqualizer.presets.enumerated()), id: \.offset) { i, p in Text(p.name).tag(i) }
                }
            }
            Section("Bands") {
                sliderRow("Preamp", String(format: "%+.1f dB", vlc.eqPre), Slider(value: Binding(get: { Double(vlc.eqPre) }, set: { vlc.setPre(Float($0)) }), in: -20...20))
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(0..<min(10, vlc.eqBands.count), id: \.self) { i in
                        VStack(spacing: 6) {
                            Slider(value: Binding(get: { Double(vlc.eqBands[i]) }, set: { vlc.setBand(i, Float($0)) }), in: -20...20)
                                .frame(width: 120)
                                .rotationEffect(.degrees(-90))
                                .frame(width: 28, height: 120)
                            Text(freqs[i]).font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }
}

struct ChaptersPage: View {
    @ObservedObject var vlc: VLCController
    var body: some View {
        Form {
            if vlc.titles.count > 1 {
                Section("Titles") {
                    ForEach(Array(vlc.titles.enumerated()), id: \.offset) { _, t in
                        Button { vlc.selectTitle(t) } label: {
                            HStack { Text(t.name ?? "Title \(t.titleIndex + 1)"); Spacer(); if t.isCurrent { Image(systemName: "checkmark") } }
                        }
                    }
                }
            }
            Section("Chapters") {
                if vlc.chapters.isEmpty { Text("This media has no chapters").foregroundStyle(.secondary) }
                ForEach(Array(vlc.chapters.enumerated()), id: \.offset) { i, c in
                    Button { vlc.selectChapter(i) } label: {
                        HStack {
                            Text(c.name ?? "Chapter \(i + 1)")
                            Spacer()
                            Text(formatTime(Double(c.timeOffset.intValue) / 1000)).foregroundStyle(.secondary).monospacedDigit()
                            if i == vlc.chapterIndex { Image(systemName: "checkmark") }
                        }
                    }
                }
            }
        }
        .onAppear { vlc.refreshTracks() }
    }
}

struct BookmarksPage: View {
    @ObservedObject var vlc: VLCController
    @State private var renaming: VLCBookmark?
    @State private var newName = ""

    var body: some View {
        Form {
            Section { Button("Add bookmark at \(formatTime(Double(vlc.timeMs) / 1000))", systemImage: "bookmark.fill") { vlc.addBookmark() } }
            Section {
                ForEach(vlc.bookmarks) { b in
                    Button { vlc.seek(ms: b.ms) } label: {
                        HStack { Text(b.name); Spacer(); Text(formatTime(Double(b.ms) / 1000)).foregroundStyle(.secondary).monospacedDigit() }
                    }
                    .swipeActions {
                        Button("Rename") { renaming = b; newName = b.name }.tint(.blue)
                    }
                }
                .onDelete { vlc.deleteBookmarks(at: $0) }
            }
        }
        .alert("Rename bookmark", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Save") { if let b = renaming { vlc.renameBookmark(b, to: newName) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }
}

struct CastPage: View {
    @ObservedObject var vlc: VLCController
    var body: some View {
        Form {
            Section {
                Button { vlc.selectRenderer(nil) } label: {
                    HStack { Text("This device"); Spacer(); if vlc.selectedRenderer == nil { Image(systemName: "checkmark") } }
                }
                ForEach(Array(vlc.renderers.enumerated()), id: \.offset) { _, r in
                    Button { vlc.selectRenderer(r) } label: {
                        HStack { Text(r.name); Spacer(); Text(r.type).foregroundStyle(.secondary); if vlc.selectedRenderer === r { Image(systemName: "checkmark") } }
                    }
                }
            } footer: { Text("Searches your network for Chromecast and other renderers. Needs Local Network access.") }
        }
        .onAppear { vlc.startRendererDiscovery() }
    }
}

struct InfoPage: View {
    @ObservedObject var vlc: VLCController
    var body: some View {
        List {
            ForEach(Array(vlc.mediaInfo.enumerated()), id: \.offset) { _, r in
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.0).font(.caption).foregroundStyle(.secondary)
                    Text(r.1)
                }
            }
        }
    }
}
