import AVKit
import SwiftUI

struct RoutePicker: UIViewRepresentable {
    var accent: UIColor
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = .white
        v.activeTintColor = accent
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) { uiView.activeTintColor = accent }
}

struct Backdrop: View {
    var tint: Color
    var bass: Float
    var style: BackdropStyle
    var art: UIImage?
    var body: some View {
        switch style {
        case .mesh: mesh
        case .gradient:
            LinearGradient(colors: [tint, tint.mix(with: .black, by: 0.6), .black], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
        case .blur:
            ZStack {
                Color.black
                if let art { Image(uiImage: art).resizable().scaledToFill().blur(radius: 60).opacity(0.8).overlay(Color.black.opacity(0.45)) }
                else { tint.opacity(0.6) }
            }
            .ignoresSafeArea()
        case .black: Color.black.ignoresSafeArea()
        }
    }

    private var mesh: some View {
        TimelineView(.animation) { tl in
            let t = Float(tl.date.timeIntervalSinceReferenceDate)
            let w = Float(0.06) + bass * 0.05
            MeshGradient(width: 3, height: 3, points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.5 + w * sin(t * 0.7)], [0.5 + w * sin(t * 0.9), 0.5 + w * cos(t * 0.8)], [1, 0.5 + w * cos(t * 0.6)],
                [0, 1], [0.5, 1], [1, 1],
            ], colors: [
                tint.opacity(0.9), tint.mix(with: .purple, by: 0.4), tint.mix(with: .black, by: 0.3),
                tint.mix(with: .pink, by: 0.3), tint, tint.mix(with: .black, by: 0.5),
                .black, tint.mix(with: .black, by: 0.7), .black,
            ])
        }
        .ignoresSafeArea()
        .overlay(Color.black.opacity(0.25).ignoresSafeArea())
    }
}

struct NowPlayingView: View {
    @EnvironmentObject var p: Player
    @EnvironmentObject var clock: Clock
    @EnvironmentObject var library: Library
    @EnvironmentObject var analysis: AnalysisStore
    @State private var showQueue = false

    var body: some View {
        ZStack {
            Backdrop(tint: (p.current?.tint ?? .indigo).capped, bass: clock.bass, style: p.cfg.backdrop, art: p.artwork)
            VStack(spacing: 20) {
                Capsule().fill(.white.opacity(0.4)).frame(width: 40, height: 5).padding(.top, 8)
                Spacer(minLength: 0)

                ArtworkView(image: p.artwork, radius: p.cfg.artworkRadius)
                    .shadow(color: (p.current?.tint ?? Color.accentColor).opacity(0.6), radius: 30 + CGFloat(clock.bass) * 30, y: 16)
                    .scaleEffect(p.isPlaying ? 1 + (p.cfg.pulseArtwork ? CGFloat(clock.bass) * 0.035 * p.cfg.pulseAmount : 0) : 0.84)
                    .animation(.linear(duration: 0.06), value: clock.bass)
                    .animation(.spring(response: 0.5, dampingFraction: 0.7), value: p.isPlaying)
                    .containerRelativeFrame(.horizontal) { w, _ in w * CGFloat(p.cfg.artworkSize) }

                Spacer(minLength: 0)

                VStack(alignment: .leading, spacing: 4) {
                    Text(p.current?.title ?? "Not Playing").font(.title2.bold()).lineLimit(1)
                    Text(p.current?.artist ?? "").font(.title3).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    if p.djActive || p.mixActive || (p.current.flatMap { analysis.results[$0.id] } != nil) {
                        HStack(spacing: 8) {
                            if let a = p.current.flatMap({ analysis.results[$0.id] }) {
                                Text("\(Int(a.bpm.rounded())) BPM")
                                Text(a.keyName)
                            }
                            if p.djActive { Label("DJ", systemImage: "sparkles") }
                            if p.mixActive { Label("Mix", systemImage: "rectangle.3.group") }
                        }
                        .font(.caption.bold())
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(.white.opacity(0.15), in: Capsule())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)

                VStack(spacing: 2) {
                    Scrubber(value: clock.position, total: p.duration) { p.seek($0) }
                    HStack {
                        Text(formatTime(clock.position))
                        Spacer()
                        Text(p.cfg.showRemaining ? "-" + formatTime(max(0, p.duration - clock.position)) : formatTime(p.duration))
                    }
                    .font(.caption).monospacedDigit().foregroundStyle(.white.opacity(0.7))
                }
                .padding(.horizontal, 28)

                GlassEffectContainer(spacing: 24) {
                    HStack(spacing: 22) {
                        Button { p.previous() } label: { Image(systemName: "backward.fill").font(.title2).frame(width: 38, height: 38) }
                            .buttonStyle(.glass).buttonBorderShape(.circle)
                        Button { p.togglePlay() } label: {
                            Image(systemName: p.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 34))
                                .frame(width: 56, height: 56).contentTransition(.symbolEffect(.replace))
                        }
                        .buttonStyle(.glassProminent).buttonBorderShape(.circle)
                        Button { p.next() } label: { Image(systemName: "forward.fill").font(.title2).frame(width: 38, height: 38) }
                            .buttonStyle(.glass).buttonBorderShape(.circle)
                    }
                }
                .sensoryFeedback(.impact(flexibility: .soft), trigger: p.isPlaying)

                GlassEffectContainer(spacing: 16) {
                    HStack(spacing: 14) {
                        toggle("shuffle", on: p.shuffle) { p.toggleShuffle() }
                        toggle(p.repeatMode == .one ? "repeat.1" : "repeat", on: p.repeatMode != .off) { p.cycleRepeat() }
                        toggle("waveform.path", on: p.cfg.hapticsOn) { p.cfg.hapticsOn.toggle() }
                        toggle("sparkles", on: p.djActive) { if p.djActive { p.stopDJ() } else { p.startDJ(pool: library.audio) } }
                        RoutePicker(accent: UIColor(p.cfg.accent)).frame(width: 44, height: 44).lGlass(Circle(), interactive: true)
                        Button { showQueue = true } label: { Image(systemName: "list.bullet").frame(width: 44, height: 44) }
                            .buttonStyle(.plain).lGlass(Circle(), interactive: true)
                    }
                    .font(.body.weight(.semibold))
                }
                .padding(.bottom, 12)
            }
            .foregroundStyle(.white)
        }
        .preferredColorScheme(.dark)
        .tint(p.cfg.accent)
        .sheet(isPresented: $showQueue) { QueueView().presentationDetents([.medium, .large]) }
    }

    private func toggle(_ icon: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).frame(width: 44, height: 44)
                .foregroundStyle(on ? Color.accentColor : .white)
        }
        .buttonStyle(.plain)
        .lGlass(Circle(), interactive: true)
    }
}

struct QueueView: View {
    @EnvironmentObject var p: Player
    @EnvironmentObject var mixStore: MixStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(p.queue.enumerated()), id: \.element.id) { i, t in
                    Button { p.play(i) } label: { TrackRow(track: t, playing: i == p.index) }.buttonStyle(.plain)
                }
                .onDelete { p.removeFromQueue(at: $0) }
            }
            .listStyle(.plain)
            .tint(p.cfg.accent)
            .navigationTitle("Up Next")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save as Mix", systemImage: "rectangle.3.group") {
                        _ = mixStore.add(from: p.queue, name: "Queue " + Date.now.formatted(date: .abbreviated, time: .shortened),
                                         overlap: p.cfg.crossfade)
                        dismiss()
                    }
                    .disabled(p.queue.isEmpty)
                }
            }
        }
    }
}
