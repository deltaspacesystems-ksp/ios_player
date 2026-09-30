import AVFoundation
import MediaPlayer
import UIKit

enum RepeatMode: Int { case off, all, one }

final class Clock: ObservableObject {
    @Published var position: Double = 0
    @Published var level: Float = 0
    @Published var bass: Float = 0
}

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
    let tp = AVAudioUnitTimePitch()
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
    // High-frequency values are mirrored into `clock` so only Now Playing redraws at 30 Hz, not the whole app.
    let clock = Clock()
    @Published var artwork: UIImage?
    private var artID: String?
    var position: Double = 0 { didSet { clock.position = position } }
    @Published var duration: Double = 0
    @Published var repeatMode: RepeatMode = .off
    @Published var shuffle = false
    // Live levels (for UI)
    var level: Float = 0 { didSet { clock.level = level } }
    var bass: Float = 0 { didSet { clock.bass = bass } }
    // Settings (everything user-customizable lives in Settings.swift)
    @Published var cfg: Settings = Settings.load() {
        didSet {
            cfg.save()
            applyCfg()
            if oldValue.speed != cfg.speed { updateNowPlaying() }
        }
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

    // AI DJ
    @Published var djActive = false
    let analysis = AnalysisStore()
    let voice = DJVoice()
    private var djPool: [Track] = []
    private var announcedID: String?
    private var announceCount = 0
    private var tempoRatio: Double = 1
    private var rampTask: Task<Void, Never>?

    private let haptics = HapticsEngine()
    private let analyzer: Analyzer

    init() {
        analyzer = Analyzer(haptics: haptics)
        analyzer.publish = { [weak self] l, b in
            Task { @MainActor in self?.level = l; self?.bass = b }
        }

        for n in [deckA.node, deckB.node, deckA.tp, deckB.tp, timePitch, eq] as [AVAudioNode] { engine.attach(n) }
        deckA.tp.bypass = true
        deckB.tp.bypass = true
        voice.onSpeaking = { [weak self] on in self?.rampMixer(to: on ? Float(self?.cfg.djDuck ?? 0.35) : 1) }
        engine.connect(engine.mainMixerNode, to: timePitch, format: nil)
        engine.connect(timePitch, to: eq, format: nil)
        engine.connect(eq, to: engine.outputNode, format: nil)
        installTap(on: engine.mainMixerNode, analyzer: analyzer)
        applyCfg()
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
        stopDJ()
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
        refreshArtwork()
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
        skip(to: index + 1 < queue.count ? index + 1 : 0)
    }

    func previous() {
        if position > 3 { seek(0) } else { skip(to: max(0, index - 1)) }
    }

    private func skip(to i: Int) {
        if cfg.fadeOnSkip, isPlaying, outgoing == nil, queue.indices.contains(i),
           let _ = try? AVAudioFile(forReading: queue[i].url) {
            startFade(to: i, len: max(0.3, cfg.skipFade))
        } else {
            play(i)
        }
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
        engine.connect(d.node, to: d.tp, format: file.processingFormat)
        engine.connect(d.tp, to: engine.mainMixerNode, format: file.processingFormat)
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
        if djActive, index + 1 >= queue.count - 1 { extendDJ() }
        if index + 1 < queue.count { return index + 1 }
        return repeatMode == .all ? 0 : nil
    }

    private func tick() {
        guard isPlaying else { return }
        let a = active
        position = a.position
        if let out = outgoing {
            let p = fadeLen > 0 ? min(1, a.position / fadeLen) : 1
            let g = fadeGains(p)
            out.node.volume = g.out
            a.node.volume = g.inn
            if tempoRatio != 1 { a.tp.rate = Float(tempoRatio + (1 - tempoRatio) * p) }
            if p >= 1 { endFade() }
        } else if duration > 0, let n = autoNext() {
            let remaining = duration - position
            let base = djActive ? cfg.djFade : cfg.crossfade
            let len = max(0.05, min(base, duration * 0.4))
            announceIfNeeded(n, remaining: remaining, len: len)
            if remaining <= len && position > 1 { startFade(to: n, len: max(0.05, remaining)) }
        }
    }

    private func startFade(to n: Int, len: Double) {
        guard let file = try? AVAudioFile(forReading: queue[n].url) else { return }
        let out = active
        let inc = other
        inc.node.volume = 0
        tempoRatio = 1
        inc.tp.rate = 1
        inc.tp.bypass = true
        if djActive, cfg.djTempoMatch, queue.indices.contains(index),
           let ao = analysis.results[queue[index].id], let ai = analysis.results[queue[n].id], ao.bpm > 0, ai.bpm > 0 {
            var r = ao.bpm / ai.bpm
            for c in [r * 2, r / 2] where abs(c - 1) < abs(r - 1) { r = c }
            if abs(r - 1) <= 0.08, abs(r - 1) > 0.002 {
                tempoRatio = r
                inc.tp.bypass = false
                inc.tp.rate = Float(r)
            }
        }
        load(inc, file, from: 0)
        inc.node.play()
        outgoing = out
        active = inc
        fadeLen = len
        index = n
        refreshArtwork()
        duration = inc.duration
        position = 0
        updateNowPlaying()
    }

    private func endFade() {
        outgoing?.node.stop()
        outgoing?.node.volume = 1
        outgoing = nil
        active.node.volume = 1
        tempoRatio = 1
        for d in [deckA, deckB] { d.tp.rate = 1; d.tp.bypass = true }
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

    private func applyCfg() {
        analyzer.enabled = cfg.hapticsOn
        analyzer.strength = Float(cfg.hapticStrength)
        analyzer.cutoff = Float(cfg.hapticCutoff)
        analyzer.threshold = Float(cfg.hapticThreshold)
        analyzer.rumble = cfg.hapticRumble
        analyzer.beats = cfg.hapticBeats
        haptics.setBackgroundFallback(cfg.hapticBackground)
        if !cfg.hapticsOn { haptics.stop() }
        timePitch.rate = cfg.speed
        timePitch.pitch = cfg.pitchCents
        applyEQ()
    }

    func applyPreset(_ p: EQPreset) { cfg.eqGains = p.gains }

    private func fadeGains(_ p: Double) -> (out: Float, inn: Float) {
        switch cfg.fadeCurve {
        case .equalPower: return (Float(cos(p * .pi / 2)), Float(sin(p * .pi / 2)))
        case .linear: return (Float(1 - p), Float(p))
        case .sCurve:
            let s = p * p * (3 - 2 * p)
            return (Float(1 - s), Float(s))
        }
    }

    private func applyEQ() {
        let freqs: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
        let g = cfg.eqGains
        eq.globalGain = cfg.preamp
        for (i, b) in eq.bands.enumerated() {
            b.filterType = .parametric
            b.frequency = freqs[i]
            b.bandwidth = 1
            b.gain = g[i]
            b.bypass = false
        }
    }

    // MARK: AI DJ (offline)

    func startDJ(pool: [Track], from: Track? = nil) {
        let audio = pool.filter { !$0.isVideo }
        guard let start = from ?? current ?? audio.randomElement() else { return }
        djPool = audio
        announcedID = nil
        announceCount = 0
        let plan = DJPlanner.build(start: start, pool: audio, analysis: analysis.results, mood: cfg.djMood, length: cfg.djLength)
        djActive = true
        shuffle = false
        originalQueue = plan
        queue = plan
        play(0)
        if cfg.djVoice { speak(DJScript.introLine(start, lang: cfg.djLang)) }
        if analysis.count < max(1, audio.count / 5) {
            Task {
                await analysis.analyze(audio)
                replanDJ()
            }
        }
    }

    func stopDJ() {
        guard djActive else { return }
        djActive = false
        voice.stop()
    }

    private func replanDJ() {
        guard djActive, let cur = current else { return }
        let plan = DJPlanner.build(start: cur, pool: djPool, analysis: analysis.results, mood: cfg.djMood, length: cfg.djLength)
        queue = plan
        originalQueue = plan
        index = 0
    }

    private func extendDJ() {
        guard djPool.count > 1, let last = queue.last else { return }
        let recent = Set(queue.suffix(max(1, djPool.count / 2)).map(\.id))
        var plan = Array(DJPlanner.build(start: last, pool: djPool, analysis: analysis.results,
                                         mood: cfg.djMood, length: cfg.djLength, exclude: recent).dropFirst())
        if plan.isEmpty { plan = Array(djPool.filter { $0.id != last.id }.shuffled().prefix(10)) }
        queue += plan
        originalQueue += plan
    }

    private func announceIfNeeded(_ n: Int, remaining: Double, len: Double) {
        guard djActive, cfg.djVoice, queue.indices.contains(n), announcedID != queue[n].id,
              remaining <= len + 5, position > 2 else { return }
        announcedID = queue[n].id
        announceCount += 1
        guard announceCount % max(1, cfg.djEvery) == 0 else { return }
        speak(DJScript.nextLine(queue[n], analysis.results[queue[n].id], lang: cfg.djLang))
    }

    private func speak(_ text: String) {
        voice.speak(text, lang: cfg.djLang, voiceID: cfg.djVoiceID, rate: Float(cfg.djRate), volume: Float(cfg.djVolume))
    }

    func testVoice() {
        speak(cfg.djLang == "pl" ? "Cześć, tu Twój DJ Lumen. Tak brzmi mój głos." : "Hey, it's your Lumen DJ. This is how I sound.")
    }

    /// Smoothly duck (or restore) the music under the DJ's voice.
    private func rampMixer(to target: Float) {
        rampTask?.cancel()
        rampTask = Task {
            let m = engine.mainMixerNode
            let from = m.outputVolume
            for i in 1...10 {
                if Task.isCancelled { return }
                m.outputVolume = from + (target - from) * Float(i) / 10
                try? await Task.sleep(for: .milliseconds(30))
            }
        }
    }

    private func refreshArtwork() {
        guard let t = current else { artwork = nil; artID = nil; return }
        if t.id == artID { return }
        artID = t.id
        artwork = nil
        let url = t.url, id = t.id
        Task {
            let data = await MetaReader.read(url, wantArt: true).art
            let img = data.flatMap { UIImage(data: $0) }.flatMap { $0.preparingThumbnail(of: CGSize(width: 800, height: 800)) ?? $0 }
            if artID == id { artwork = img; updateNowPlaying() }
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
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.haptics.setBackground(true) }
        }
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.haptics.setBackground(false) }
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
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(cfg.speed) : 0.0,
        ]
        if artID == t.id, let img = artwork { info[MPMediaItemPropertyArtwork] = makeArtwork(img) }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
