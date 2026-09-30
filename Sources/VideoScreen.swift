import AVFoundation
import SwiftUI

final class LayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    var fill: Bool
    func makeUIView(context: Context) -> LayerView {
        let v = LayerView()
        v.playerLayer.player = player
        return v
    }
    func updateUIView(_ v: LayerView, context: Context) {
        v.playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
    }
}

@MainActor
final class VideoModel: ObservableObject {
    let player: AVPlayer
    @Published var position = 0.0
    @Published var duration = 0.0
    @Published var isPlaying = false
    @Published var rate: Float = 1 { didSet { player.defaultRate = rate; if isPlaying { player.rate = rate } } }
    private var observer: Any?

    init(url: URL) {
        player = AVPlayer(url: url)
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback)
        try? s.setActive(true)
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.position = t.seconds
                if let d = self.player.currentItem?.duration.seconds, d.isFinite { self.duration = d }
                self.isPlaying = self.player.timeControlStatus != .paused
            }
        }
    }

    func toggle() {
        if player.timeControlStatus == .paused {
            if duration > 0, position >= duration - 0.5 { player.seek(to: .zero) }
            player.play()
            isPlaying = true
        } else {
            player.pause()
            isPlaying = false
        }
    }

    func seek(_ t: Double) {
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        position = t
    }

    func skip(_ d: Double) { seek(min(max(0, position + d), max(duration, 0))) }

    deinit { if let o = observer { player.removeTimeObserver(o) } }
}

struct VideoScreen: View {
    let track: Track
    @EnvironmentObject var music: Player
    @StateObject private var vm: VideoModel
    @Environment(\.dismiss) private var dismiss
    @State private var controls = true
    @State private var fill = false
    @State private var hideTask: Task<Void, Never>?

    init(track: Track) {
        self.track = track
        _vm = StateObject(wrappedValue: VideoModel(url: track.url))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PlayerLayerView(player: vm.player, fill: fill).ignoresSafeArea()

            HStack(spacing: 0) {
                Color.clear.contentShape(Rectangle()).onTapGesture(count: 2) { vm.skip(-10) }
                Color.clear.contentShape(Rectangle()).onTapGesture(count: 2) { vm.skip(10) }
            }

            if controls { overlay.transition(.opacity) }
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeInOut(duration: 0.25)) { controls.toggle() }; scheduleHide() }
        .statusBarHidden(!controls)
        .preferredColorScheme(.dark)
        .onAppear { music.pause(); vm.toggle(); scheduleHide() }
        .onDisappear { vm.player.pause() }
    }

    private var overlay: some View {
        VStack {
            HStack(spacing: 12) {
                Button { dismiss() } label: { Image(systemName: "xmark").font(.headline).frame(width: 40, height: 40) }
                    .buttonStyle(.glass).buttonBorderShape(.circle)
                Text(track.title).font(.headline).lineLimit(1).shadow(radius: 4)
                Spacer()
                Menu {
                    Picker("Speed", selection: $vm.rate) {
                        ForEach([Float(0.5), 0.75, 1, 1.25, 1.5, 2], id: \.self) { Text("\($0, specifier: "%g")×").tag($0) }
                    }
                } label: { Text("\(vm.rate, specifier: "%g")×").font(.subheadline.bold()).frame(width: 44, height: 40) }
                    .buttonStyle(.glass)
                Button { withAnimation { fill.toggle() } } label: {
                    Image(systemName: fill ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.glass).buttonBorderShape(.circle)
            }
            .padding(.horizontal)

            Spacer()

            GlassEffectContainer(spacing: 30) {
                HStack(spacing: 28) {
                    Button { vm.skip(-10); scheduleHide() } label: { Image(systemName: "gobackward.10").font(.title).frame(width: 52, height: 52) }
                        .buttonStyle(.glass).buttonBorderShape(.circle)
                    Button { vm.toggle(); scheduleHide() } label: {
                        Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 36)).frame(width: 70, height: 70)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.glassProminent).buttonBorderShape(.circle)
                    Button { vm.skip(10); scheduleHide() } label: { Image(systemName: "goforward.10").font(.title).frame(width: 52, height: 52) }
                        .buttonStyle(.glass).buttonBorderShape(.circle)
                }
            }

            Spacer()

            VStack(spacing: 2) {
                Scrubber(value: vm.position, total: vm.duration) { vm.seek($0); scheduleHide() }
                HStack {
                    Text(formatTime(vm.position))
                    Spacer()
                    Text("-" + formatTime(max(0, vm.duration - vm.position)))
                }
                .font(.caption).monospacedDigit().foregroundStyle(.white.opacity(0.8))
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            .glassEffect(.regular, in: .rect(cornerRadius: 28))
            .padding(.horizontal)
        }
        .foregroundStyle(.white)
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled, vm.isPlaying { withAnimation(.easeInOut(duration: 0.3)) { controls = false } }
        }
    }
}
