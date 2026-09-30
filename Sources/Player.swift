import AVFoundation
import MediaPlayer
import UIKit

enum RepeatMode: Int { case off, all, one }

enum EQPreset: String, CaseIterable, Identifiable {
    case flat = "Flat", bass = "Bass Boost", vocal = "Vocal", treble = "Treble", rock = "Rock", electronic = "Electronic"
    var id: String { rawValue }
    var gains: [Float] {
        switch self {
        case .flat:       return [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        case .bass:       return [7, 6, 4, 2, 0, 0, 0, 0, 0, 0]
        case .vocal:      return [-2, -2, -1, 1, 3, 4, 3, 1, 0, -1]
        case .treble:     return [0, 0, 0, 0, 0, 1, 3, 5, 6, 7]
        case .rock:       return [5, 4, 2, -1, -2, -1, 2, 4, 5, 5]
        case .electronic: return [6, 5, 1, 0, -2, 2, 1, 3, 5, 6]
        }
    }
}

/// One of two alternating players used for crossfading.
final class Deck {
    let node = AVAudioPlayerNode()
    var file: AVAudioFile?
    var gen = 0
    var startFrame: AVAudioFramePosition = 0
    var lastPos: Double = 0

    var duration: Double {
        guard let f = file else { return 0 }
        return Double(f.length) / f.processingFormat.sampleRate
    }

    var position: Double {
        guard let f = file else { return 0 }
        if node.isPlaying, let t = node.lastRenderTime, let p = node.playerTime(forNodeTime: t) {
            lastPos = min(duration, max(0, (Double(startFrame) + Double(p.sampleTime)) / f.processingFormat.sampleRate))
        }
        return lastPos
    }

    func schedule(_ file: AVAudioFile, from t: Double, onEnd: @escaping (Deck, Int) -> Void) {
        gen += 1
        node.stop()
        self.file = file
        let rate = file.processingFormat.sampleRate
        let start = AVAudioFramePosition(max(0, min(t, duration - 0.1)) * rate)
        startFrame = start
        lastPos = Double(start) / rate
        let count = AVAudioFrameCount(max(1, file.length - start))
        let g = gen
        node.scheduleSegment(file, startingFrame: start, frameCount: count, at: nil,
                             completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async { if let self { onEnd(self, g) } }
        }
    }
}

func makeArtwork(_ img: UIImage) -> MPMediaItemArtwork {
    MPMediaItemArtwork(boundsSize: img.size) { _ in img }
}

@MainActor
final class Player: ObservableObject {
    // Queue / transport
    @Published var queue: [Track] = []
    @Published var index = 0
    @Published var isPlaying = false
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var repeatMode: RepeatMode = .off
    @Published var shuffle = false
    // Live levels (for UI)
    @Published var level: Float = 0
    @Published var bass: Float = 0
    // Settings
    @Published var crossfade: Double = UserDefaults.standard.object(forKey: "xfade") as? Double ?? 6 {
        didSet { UserDefaults.standard.set(crossfade, forKey: "xfade") }
    }
    @Published var hapticsOn: Bool = UserDefaults.standard.object(forKey: "haptics") as? Bool ?? true {
        didSet { UserDefaults.standard.set(hapticsOn, forKey: "haptics"); analyzer.enabled = hapticsOn; if !hapticsOn { haptics.stop() } }
    }
    @Published var hapticStrength: Double = UserDefaults.standard.object(forKey: "hstrength") as? Double ?? 1 {
        didSet { UserDefaults.standard.set(hapticStrength, forKey: "hstrength"); analyzer.strength = Float(hapticStrength) }
    }
    @Published var preset: EQPreset = EQPreset(rawValue: UserDefaults.standard.string(forKey: "eq") ?? "") ?? .flat {
        didSet { UserDefaults.standard.set(preset.rawValue, forKey: "eq"); applyEQ() }
    }
    @Published var speed: Float = 1 {
        didSet { timePitch.rate = speed; updateNowPlaying() }
    }

    var current: Track? { queue.indices.contains(index) ? queue[index] : nil }

    // Audio graph
    private let engine = AVAudioEngine()
    private let timePitch = AVAudioUnitTimePitch()
    private let eq = AVAudioUnitEQ(numberOfBands: 10)
    private let deckA = Deck(), deckB = Deck()
    private lazy var active: Deck = deckA
    private var other: Deck { active === deckA ? deckB : deckA }
    private var outgoing: Deck?
    private var fadeLen: Double = 0
    private var originalQueue: [Track] = []
    private var timer: Timer?

    private let haptics = HapticsEngine()
    private let analyzer: Analyzer

    init() {
        analyzer = Analyzer(haptics: haptics)
        analyzer.enabled = hapticsOn
        analyzer.strength = Float(hapticStrength)
        analyzer.publish = { [weak self] l, b in
            Task { @MainActor in self?.level = l; self?.bass = b }
        }

        for n in [deckA.node, deckB.node, timePitch, eq] as [AVAudioNode] { engine.attach(n) }
        engine.connect(engine.mainMixerNode, to: timePitch, format: nil)
        engine.connect(timePitch, to: eq, format: nil)
        engine.connect(eq, to: engine.outputNode, format: nil)
        installTap(on: engine.mainMixerNode, analyzer: analyzer)
        applyEQ()
        engine.prepare()
        haptics.prepare()
        setupRemote()
        observeSession()

        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    // MARK: Queue

    func setQueue(_ tracks: [Track], start: Int, shuffled: Bool? = nil) {
        guard tracks.indices.contains(start) else { return }
        if let s = shuffled { shuffle = s }
        originalQueue = tracks
        if shuffle {
            var rest = tracks
            let first = rest.remove(at: start)
            rest.shuffle()
            queue = [first] + rest
            play(0)
        } else {
            queue = tracks
            play(start)
        }
    }

    func toggleShuffle() {
        shuffle.toggle()
        guard let cur = current else { return }
        if shuffle {
            var rest = queue
            rest.remove(at: index)
            rest.shuffle()
            queue = [cur] + rest
            index = 0
        } else {
            queue = originalQueue
            index = queue.firstIndex(of: cur) ?? 0
        }
    }

    func cycleRepeat() {
        repeatMode = RepeatMode(rawValue: (repeatMode.rawValue + 1) % 3) ?? .off
    }

    func playNext(_ t: Track) {
        if queue.isEmpty { setQueue([t], start: 0); return }
        queue.insert(t, at: index + 1)
        originalQueue.append(t)
    }

    func enqueue(_ t: Track) {
        if queue.isEmpty { setQueue([t], start: 0); return }
        queue.append(t)
        originalQueue.append(t)
    }

    func removeFromQueue(at offsets: IndexSet) {
        let cur = current
        queue.remove(atOffsets: offsets)
        if let cur, let i = queue.firstIndex(of: cur) { index = i }
    }

    // MARK: Transport

    func play(_ i: Int, from t: Double = 0, autoplay: Bool = true, depth: Int = 0) {
        guard queue.indices.contains(i) else { return }
        cancelFade()
        guard let file = try? AVAudioFile(forReading: queue[i].url) else {
            if depth < queue.count { play((i + 1) % queue.count, depth: depth + 1) }
            return
        }
        index = i
        other.node.stop()
        let d = active
        d.node.volume = 1
        load(d, file, from: t)
        activateSession()
        ensureEngine()
        if autoplay { d.node.play() }
        isPlaying = autoplay
        duration = d.duration
        position = t
        if !autoplay { haptics.stop() }
        updateNowPlaying()
    }

    func togglePlay() { isPlaying ? pause() : resume() }

    func pause() {
        guard isPlaying else { return }
        isPlaying = false
        active.node.pause()
        outgoing?.node.pause()
        haptics.stop()
        updateNowPlaying()
    }

    func resume() {
        guard current != nil else { return }
        activateSession()
        ensureEngine()
        active.node.play()
        outgoing?.node.play()
        isPlaying = true
        updateNowPlaying()
    }

    func next() {
        guard !queue.isEmpty else { return }
        play(index + 1 < queue.count ? index + 1 : 0)
    }

    func previous() {
        if position > 3 { seek(0) } else { play(max(0, index - 1)) }
    }

    func seek(_ t: Double) {
        guard let file = active.file else { return }
        cancelFade()
        let was = isPlaying
        active.node.volume = 1
        load(active, file, from: t)
        if was { active.node.play() }
        position = min(max(0, t), duration)
        updateNowPlaying()
    }

    // MARK: Engine internals

    private func load(_ d: Deck, _ file: AVAudioFile, from t: Double) {
        d.node.stop()
        engine.connect(d.node, to: engine.mainMixerNode, format: file.processingFormat)
        d.schedule(file, from: t) { [weak self] deck, gen in
            MainActor.assumeIsolated { self?.deckEnded(deck, gen) }
        }
    }

    private func deckEnded(_ d: Deck, _ gen: Int) {
        guard d === active, gen == d.gen, outgoing == nil, isPlaying else { return }
        if let n = autoNext() { play(n) } else { play(0, autoplay: false) }
    }

    private func autoNext() -> Int? {
        if repeatMode == .one { return index }
        if index + 1 < queue.count { return index + 1 }
        return repeatMode == .all ? 0 : nil
    }

    private func tick() {
        guard isPlaying else { return }
        let a = active
        position = a.position
        if let out = outgoing {
            let p = fadeLen > 0 ? min(1, a.position / fadeLen) : 1
            out.node.volume = Float(cos(p * .pi / 2))   // equal-power crossfade
            a.node.volume = Float(sin(p * .pi / 2))
            if p >= 1 { endFade() }
        } else if duration > 0, let n = autoNext() {
            let remaining = duration - position
            let len = max(0.05, min(crossfade, duration * 0.4))
            if remaining <= len && position > 1 { startFade(to: n, len: max(0.05, remaining)) }
        }
    }

    private func startFade(to n: Int, len: Double) {
        guard let file = try? AVAudioFile(forReading: queue[n].url) else { return }
        let out = active
        let inc = other
        inc.node.volume = 0
        load(inc, file, from: 0)
        inc.node.play()
        outgoing = out
        active = inc
        fadeLen = len
        index = n
        duration = inc.duration
        position = 0
        updateNowPlaying()
    }

    private func endFade() {
        outgoing?.node.stop()
        outgoing?.node.volume = 1
        outgoing = nil
        active.node.volume = 1
    }

    private func cancelFade() {
        guard outgoing != nil else { return }
        endFade()
    }

    private func ensureEngine() {
        if !engine.isRunning { try? engine.start() }
    }

    private func activateSession() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .default)
        try? s.setActive(true)
    }

    private func applyEQ() {
        let freqs: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
        let g = preset.gains
        for (i, b) in eq.bands.enumerated() {
            b.filterType = .parametric
            b.frequency = freqs[i]
            b.bandwidth = 1
            b.gain = g[i]
            b.bypass = false
        }
    }

    // MARK: System integration

    private func observeSession() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            let type = (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            let opts = n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            MainActor.assumeIsolated {
                guard let self else { return }
                if type == .began { self.isPlaying = false; self.haptics.stop() }
                else if type == .ended, AVAudioSession.InterruptionOptions(rawValue: opts).contains(.shouldResume) {
                    self.play(self.index, from: self.position)
                }
            }
        }
        nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] n in
            let reason = (n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init)
            MainActor.assumeIsolated { if reason == .oldDeviceUnavailable { self?.pause() } }
        }
        nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.current != nil else { return }
                self.play(self.index, from: self.position, autoplay: self.isPlaying)
            }
        }
    }

    private func setupRemote() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.resume() }; return .success }
        c.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.togglePlay() }; return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.next() }; return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.previous() }; return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] e in
            if let e = e as? MPChangePlaybackPositionCommandEvent {
                let t = e.positionTime
                Task { @MainActor in self?.seek(t) }
            }
            return .success
        }
    }

    private func updateNowPlaying() {
        guard let t = current else { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: t.title,
            MPMediaItemPropertyArtist: t.artist,
            MPMediaItemPropertyAlbumTitle: t.album,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(speed) : 0.0,
        ]
        if let img = t.artwork { info[MPMediaItemPropertyArtwork] = makeArtwork(img) }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
