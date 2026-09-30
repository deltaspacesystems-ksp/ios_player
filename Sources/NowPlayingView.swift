import AVKit
import SwiftUI

struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = .white
        v.activeTintColor = .systemPink
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

struct Backdrop: View {
    var tint: Color
    var bass: Float
    var body: some View {
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
    @State private var showQueue = false

    var body: some View {
        ZStack {
            Backdrop(tint: p.current?.tint ?? .indigo, bass: p.bass)
            VStack(spacing: 20) {
                Capsule().fill(.white.opacity(0.4)).frame(width: 40, height: 5).padding(.top, 8)
                Spacer(minLength: 0)

                ArtworkView(image: p.current?.artwork, radius: 26)
                    .shadow(color: (p.current?.tint ?? .pink).opacity(0.6), radius: 30 + CGFloat(p.bass) * 30, y: 16)
                    .scaleEffect(p.isPlaying ? 1 + CGFloat(p.bass) * 0.035 : 0.84)
                    .animation(.linear(duration: 0.06), value: p.bass)
                    .animation(.spring(response: 0.5, dampingFraction: 0.7), value: p.isPlaying)
                    .padding(.horizontal, 28)

                Spacer(minLength: 0)

                VStack(alignment: .leading, spacing: 4) {
                    Text(p.current?.title ?? "Not Playing").font(.title2.bold()).lineLimit(1)
                    Text(p.current?.artist ?? "").font(.title3).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)

                VStack(spacing: 2) {
                    Scrubber(value: p.position, total: p.duration) { p.seek($0) }
                    HStack {
                        Text(formatTime(p.position))
                        Spacer()
                        Text("-" + formatTime(max(0, p.duration - p.position)))
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
                        toggle("waveform.path", on: p.hapticsOn) { p.hapticsOn.toggle() }
                        RoutePicker().frame(width: 44, height: 44).glassEffect(.regular.interactive(), in: .circle)
                        Button { showQueue = true } label: { Image(systemName: "list.bullet").frame(width: 44, height: 44) }
                            .buttonStyle(.plain).glassEffect(.regular.interactive(), in: .circle)
                    }
                    .font(.body.weight(.semibold))
                }
                .padding(.bottom, 12)
            }
            .foregroundStyle(.white)
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showQueue) { QueueView().presentationDetents([.medium, .large]) }
    }

    private func toggle(_ icon: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).frame(width: 44, height: 44)
                .foregroundStyle(on ? Color.pink : .white)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
    }
}

struct QueueView: View {
    @EnvironmentObject var p: Player
    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(p.queue.enumerated()), id: \.element.id) { i, t in
                    Button { p.play(i) } label: { TrackRow(track: t, playing: i == p.index) }.buttonStyle(.plain)
                }
                .onDelete { p.removeFromQueue(at: $0) }
            }
            .listStyle(.plain)
            .navigationTitle("Up Next")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
