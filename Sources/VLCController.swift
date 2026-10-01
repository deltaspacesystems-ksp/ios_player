import Combine
import SwiftUI
import UIKit
import VLCKit

let vlcOrange = Color(red: 1.0, green: 0.533, blue: 0.0)

struct VLCItem: Identifiable, Equatable {
    let id = UUID()
    var url: URL
    var title: String
    var isLocal: Bool { url.isFileURL }
}

struct VLCBookmark: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var ms: Int
}

enum AspectChoice: String, CaseIterable, Identifiable {
    case standard = "Default", fill = "Fill", r16_9 = "16:9", r4_3 = "4:3", r16_10 = "16:10"
    case r21_9 = "21:9", r1_1 = "1:1", r5_4 = "5:4", r235 = "2.35:1"
    var id: String { rawValue }
    var ratio: String? {
        switch self {
        case .standard, .fill: return nil
        case .r16_9: return "16:9"
        case .r4_3: return "4:3"
        case .r16_10: return "16:10"
        case .r21_9: return "21:9"
        case .r1_1: return "1:1"
        case .r5_4: return "5:4"
        case .r235: return "235:100"
        }
    }
}

// MARK: - Resume positions & bookmarks

@MainActor
final class PlaybackMemory {
    static let shared = PlaybackMemory()

    private struct Store: Codable {
        var resume: [String: Int] = [:]
        var bookmarks: [String: [VLCBookmark]] = [:]
    }

    private var store = Store()
    private let fileURL: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("lumen-playback.json")
        if let d = try? Data(contentsOf: fileURL), let s = try? JSONDecoder().decode(Store.self, from: d) { store = s }
    }

    private func key(_ u: URL) -> String { u.isFileURL ? u.path : u.absoluteString }
    private func save() { if let d = try? JSONEncoder().encode(store) { try? d.write(to: fileURL) } }

    func resume(for u: URL) -> Int? { store.resume[key(u)] }
    func setResume(_ ms: Int?, for u: URL) { store.resume[key(u)] = ms; save() }
    func bookmarks(for u: URL) -> [VLCBookmark] { store.bookmarks[key(u)] ?? [] }
    func setBookmarks(_ b: [VLCBookmark], for u: URL) { store.bookmarks[key(u)] = b; save() }
}

// MARK: - VLC engine log bridge

final class VLCLogBridge: NSObject, VLCLogging {
    static let shared = VLCLogBridge()
    var level: VLCLogLevel = VLCLogLevel(rawValue: 1) ?? VLCLogLevel(rawValue: 0)!

    func handleMessage(_ message: String, logLevel: VLCLogLevel, context: VLCLogContext?) {
        let l: LogLevel
        switch logLevel.rawValue {
        case 0: l = .error
        case 1: l = .warning
        case 2: l = .info
        default: l = .debug
        }
        Log.shared.log(l, "vlc", context.map { "[\($0.module)] " + message } ?? message)
    }
}

enum VLCSupport {
    @MainActor static func configureLogging(level: Int) {
        let bridge = VLCLogBridge.shared
        bridge.level = VLCLogLevel(rawValue: Int32(min(3, max(0, level)))) ?? bridge.level
        VLCLibrary.shared().loggers = [bridge]
    }
}

// MARK: - Metadata via libvlc (for formats Apple frameworks can't read)

final class VLCMetaParser: NSObject, VLCMediaParserDelegate, @unchecked Sendable {
    static let shared = VLCMetaParser()
    private var conts: [ObjectIdentifier: CheckedContinuation<VLCMedia?, Never>] = [:]
    private let lock = NSLock()
    private let parser = VLCMediaParser.shared()

    private override init() {
        super.init()
        parser.delegate = self
    }

    func parse(_ url: URL) async -> VLCMedia? {
        guard let media = VLCMedia(url: url) else { return nil }
        return await withCheckedContinuation { cont in
            lock.lock(); conts[ObjectIdentifier(media)] = cont; lock.unlock()
            let r = parser.queueMedia(media, options: VLCMediaParsingOptions(rawValue: 0x01 | 0x02))
            if r != 0 {
                lock.lock(); let c = conts.removeValue(forKey: ObjectIdentifier(media)); lock.unlock()
                c?.resume(returning: nil)
            }
        }
    }

    func mediaFinishedParsing(_ media: VLCMedia, withStatus status: VLCMediaParsedStatus) {
        lock.lock(); let c = conts.removeValue(forKey: ObjectIdentifier(media)); lock.unlock()
        c?.resume(returning: status == .done ? media : nil)
    }
}

// MARK: - Controller

@MainActor
final class VLCController: NSObject, ObservableObject, VLCMediaPlayerDelegate, VLCRendererDiscovererDelegate {
    let player: VLCMediaPlayer
    var items: [VLCItem]
    let cfg: Settings

    @Published var index = 0
    @Published var state: VLCMediaPlayerState = .nothingSpecial
    @Published var isPlaying = false
    @Published var timeMs = 0
    @Published var lengthMs = 0
    @Published var buffering = false
    @Published var audioTracks: [VLCMediaPlayer.Track] = []
    @Published var textTracks: [VLCMediaPlayer.Track] = []
    @Published var titles: [VLCMediaPlayer.TitleDescription] = []
    @Published var chapters: [VLCMediaPlayer.ChapterDescription] = []
    @Published var chapterIndex = 0
    @Published var error: String?
    @Published var toast: String?
    @Published var repeatMode: RepeatMode = .off
    @Published var shuffle = false
    @Published var abState = 0          // 0 none, 1 A marked, 2 loop active
    @Published var abA = 0
    @Published var abB = 0
    @Published var recording = false
    @Published var sleepEnd: Date?
    @Published var sleepAtEnd = false
    @Published var bookmarks: [VLCBookmark] = []
    @Published var renderers: [VLCRendererItem] = []
    @Published var selectedRenderer: VLCRendererItem?
    @Published var hasVideo = false

    @Published var rate: Float = 1 { didSet { player.rate = rate } }
    @Published var audioDelayMs = 0 { didSet { player.currentAudioPlaybackDelay = audioDelayMs * 1000 } }
    @Published var subDelayMs = 0 { didSet { player.currentVideoSubTitleDelay = subDelayMs * 1000 } }
    @Published var subScale: Float = 1 { didSet { player.currentSubTitleFontScale = subScale } }
    @Published var aspect: AspectChoice = .standard { didSet { applyAspect() } }
    @Published var deinterlace = 0 { didSet { applyDeinterlace() } }   // -1 auto, 0 off, 1 on
    @Published var volumeBoost = 100 { didSet { player.audio?.volume = Int32(volumeBoost) } }
    @Published var adjustOn = false { didSet { player.adjustFilter.isEnabled = adjustOn } }
    @Published var brightness: Float = 1 { didSet { setAdjust(player.adjustFilter.brightness, brightness) } }
    @Published var contrast: Float = 1 { didSet { setAdjust(player.adjustFilter.contrast, contrast) } }
    @Published var hue: Float = 0 { didSet { setAdjust(player.adjustFilter.hue, hue) } }
    @Published var saturation: Float = 1 { didSet { setAdjust(player.adjustFilter.saturation, saturation) } }
    @Published var gamma: Float = 1 { didSet { setAdjust(player.adjustFilter.gamma, gamma) } }
    @Published var eqPreset = -1
    @Published var eqBands: [Float] = Array(repeating: 0, count: 10)
    @Published var eqPre: Float = 0
    @Published var stereoMode = 0 { didSet { if let m = VLCMediaPlayer.AudioStereoMode(rawValue: UInt(stereoMode)) { player.audioStereoMode = m } } }
    @Published var mixMode = 0 { didSet { if let m = VLCMediaPlayer.AudioMixMode(rawValue: UInt32(mixMode)) { player.audioMixMode = m } } }

    private var equalizer: VLCAudioEqualizer?
    private var pendingResume: Int?
    private var stoppedByUser = false
    private var sleepTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var discoverers: [VLCRendererDiscoverer] = []
    private var attached = false
    private var wantsPlay = false
    private var baseOrder: [VLCItem]

    var current: VLCItem? { items.indices.contains(index) ? items[index] : nil }
    var title: String { current?.title ?? "" }

    init(items: [VLCItem], start: Int, cfg: Settings) {
        self.items = items
        self.baseOrder = items
        self.cfg = cfg
        var opts: [String] = [
            "--network-caching=\(cfg.vlcNetCache)",
            "--file-caching=\(cfg.vlcFileCache)",
            "--freetype-color=\(Int(cfg.vlcSubColorRGB))",
            "--freetype-rel-fontsize=\(cfg.vlcSubFontSize)",
        ]
        if !cfg.vlcHardware { opts.append("--avcodec-hw=none") }
        if cfg.vlcSubBold { opts.append("--freetype-bold") }
        if !cfg.vlcSubEncoding.isEmpty { opts.append("--subsdec-encoding=\(cfg.vlcSubEncoding)") }
        player = VLCMediaPlayer(options: opts)
        super.init()
        index = max(0, min(start, items.count - 1))
        player.delegate = self
        rate = cfg.videoSpeed
        Log.i("vlc", "Controller created: \(items.count) item(s), options \(opts.joined(separator: " "))")
    }

    // MARK: Attach / lifecycle

    func attach(_ view: UIView) {
        player.drawable = view
        guard !attached else { return }
        attached = true
        load(index)
    }

    func stop() {
        stoppedByUser = true
        saveResume()
        sleepTask?.cancel()
        for d in discoverers { d.stop() }
        discoverers.removeAll()
        player.stop()
        player.drawable = nil
        Log.i("vlc", "Stopped by user")
    }

    func load(_ i: Int, startMs: Int? = nil) {
        guard items.indices.contains(i) else { return }
        saveResume()
        index = i
        abState = 0
        let it = items[i]
        guard let media = VLCMedia(url: it.url) else {
            error = "Can't open \(it.url.lastPathComponent)"
            Log.e("vlc", "VLCMedia init failed for \(it.url.absoluteString)")
            return
        }
        if !it.isLocal { media.addOption(":network-caching=\(cfg.vlcNetCache)") }
        pendingResume = startMs ?? (cfg.vlcRememberPosition ? PlaybackMemory.shared.resume(for: it.url) : nil)
        stoppedByUser = false
        error = nil
        timeMs = 0
        lengthMs = 0
        audioTracks = []
        textTracks = []
        bookmarks = PlaybackMemory.shared.bookmarks(for: it.url)
        player.media = media
        player.play()
        Log.i("vlc", "Opening \(it.url.isFileURL ? it.url.lastPathComponent : it.url.absoluteString)")
    }

    private func saveResume() {
        guard cfg.vlcRememberPosition, let it = current, lengthMs > 0 else { return }
        let done = timeMs > lengthMs - 5000 || timeMs < 5000
        PlaybackMemory.shared.setResume(done ? nil : timeMs, for: it.url)
    }

    // MARK: Transport

    func togglePlay() {
        if player.isPlaying { player.pause() } else { player.play() }
    }

    func seek(ms: Int) {
        player.time = VLCTime(int: Int32(max(0, min(ms, max(lengthMs, 0))))
        timeMs = max(0, ms)
    }

    func seek(fraction: Double) { seek(ms: Int(Double(lengthMs) * fraction)) }
    func skip(_ seconds: Int) { seek(ms: timeMs + seconds * 1000) }
    func nextFrame() { player.gotoNextFrame() }
    func previousFrame() { player.gotoPreviousFrame() }

    func next() {
        guard !items.isEmpty else { return }
        if index + 1 < items.count { load(index + 1) } else if repeatMode == .all { load(0) }
    }

    func previous() {
        if timeMs > 3000 { seek(ms: 0) } else if index > 0 { load(index - 1) } else { seek(ms: 0) }
    }

    func cycleRepeat() { repeatMode = RepeatMode(rawValue: (repeatMode.rawValue + 1) % 3) ?? .off }

    func toggleShuffle() {
        shuffle.toggle()
        let cur = current
        if shuffle {
            var rest = items
            if let i = rest.firstIndex(where: { $0.id == cur?.id }) { rest.remove(at: i) }
            rest.shuffle()
            items = (cur.map { [$0] } ?? []) + rest
            index = 0
        } else {
            items = baseOrder
            index = items.firstIndex(where: { $0.id == cur?.id }) ?? 0
        }
    }

    private func handleEnded() {
        if let it = current { PlaybackMemory.shared.setResume(nil, for: it.url) }
        Log.i("vlc", "Reached end of \(title)")
        if sleepAtEnd { sleepAtEnd = false; show("Sleep timer: stopped"); return }
        if repeatMode == .one { load(index); return }
        if cfg.vlcAutoNext, index + 1 < items.count { load(index + 1) }
        else if repeatMode == .all, !items.isEmpty { load(0) }
    }

    // MARK: Tracks & subtitles

    func refreshTracks() {
        audioTracks = player.audioTracks
        textTracks = player.textTracks
        hasVideo = !player.videoTracks.isEmpty
        titles = player.titleDescriptions
        chapters = player.currentTitleDescription?.chapterDescriptions ?? []
        chapterIndex = Int(player.currentChapterIndex)
    }

    func selectAudio(_ t: VLCMediaPlayer.Track?) {
        if let t { t.isSelectedExclusively = true } else { player.deselectAllAudioTracks() }
        refreshTracks()
    }

    func selectText(_ t: VLCMediaPlayer.Track?) {
        if let t { t.isSelectedExclusively = true } else { player.deselectAllTextTracks() }
        refreshTracks()
    }

    func addSubtitle(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        // copy to a stable place so VLC can read it after the picker closes
        let dir = FileManager.default.temporaryDirectory
        let dest = dir.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: url, to: dest)
        let r = player.addPlaybackSlave(dest, type: .subtitle, enforce: true)
        Log.i("vlc", "Added subtitle \(url.lastPathComponent) result=\(r)")
        show(r == 0 ? "Subtitle added" : "Couldn't add subtitle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.refreshTracks() }
    }

    // MARK: Video

    private func applyAspect() {
        switch aspect {
        case .standard:
            player.videoAspectRatio = nil
            if let m = VLCMediaPlayer.VideoFitMode(rawValue: 0) { player.videoFitMode = m }
        case .fill:
            player.videoAspectRatio = nil
            if let m = VLCMediaPlayer.VideoFitMode(rawValue: 2) { player.videoFitMode = m }
        default:
            if let m = VLCMediaPlayer.VideoFitMode(rawValue: 0) { player.videoFitMode = m }
            player.videoAspectRatio = aspect.ratio
        }
    }

    private func applyDeinterlace() {
        if deinterlace == 0 { player.setDeinterlaceFilter(nil) }
        else if let m = VLCDeinterlace(rawValue: deinterlace) { player.setDeinterlace(m, withFilter: "yadif") }
    }

    private func setAdjust(_ p: any VLCFilterParameterProtocol, _ v: Float) { p.value = NSNumber(value: v) }

    func resetAdjust() {
        brightness = 1; contrast = 1; hue = 0; saturation = 1; gamma = 1
    }

    func zoom(_ factor: Float) { player.scaleFactor = factor }

    // MARK: Audio

    func setEqualizer(preset i: Int) {
        eqPreset = i
        if i >= 0, VLCAudioEqualizer.presets.indices.contains(i) {
            let e = VLCAudioEqualizer(preset: VLCAudioEqualizer.presets[i])
            equalizer = e
            eqPre = e.preAmplification
            eqBands = e.bands.map { $0.amplification }
            player.equalizer = e
        } else {
            equalizer = nil
            player.equalizer = nil
            eqBands = Array(repeating: 0, count: 10)
            eqPre = 0
        }
    }

    func setBand(_ i: Int, _ v: Float) {
        if equalizer == nil { let e = VLCAudioEqualizer(); equalizer = e; player.equalizer = e }
        guard let e = equalizer, e.bands.indices.contains(i) else { return }
        e.bands[i].amplification = v
        if eqBands.indices.contains(i) { eqBands[i] = v }
        eqPreset = -1
    }

    func setPre(_ v: Float) {
        if equalizer == nil { let e = VLCAudioEqualizer(); equalizer = e; player.equalizer = e }
        equalizer?.preAmplification = v
        eqPre = v
    }

    // MARK: Chapters / titles

    func selectChapter(_ i: Int) { player.currentChapterIndex = Int32(i); chapterIndex = i }
    func selectTitle(_ t: VLCMediaPlayer.TitleDescription) { t.setCurrent(); refreshTracks() }

    // MARK: A-B repeat

    func abTap() {
        switch abState {
        case 0:
            abA = timeMs
            abState = 1
            show("A point set")
        case 1:
            abB = timeMs
            if abB > abA + 500, player.setABLoop(from: VLCTime(int: Int32(abA)), to: VLCTime(int: Int32(abB))) {
                abState = 2
                show("A–B repeat on")
            } else {
                abState = 0
                show("B must be after A")
            }
        default:
            _ = player.resetABLoop()
            abState = 0
            show("A–B repeat off")
        }
    }

    // MARK: Bookmarks

    func addBookmark() {
        guard let it = current else { return }
        bookmarks.append(VLCBookmark(name: "Bookmark \(bookmarks.count + 1)", ms: timeMs))
        PlaybackMemory.shared.setBookmarks(bookmarks, for: it.url)
        show("Bookmark added")
    }

    func renameBookmark(_ b: VLCBookmark, to name: String) {
        guard let it = current, let i = bookmarks.firstIndex(of: b) else { return }
        bookmarks[i].name = name
        PlaybackMemory.shared.setBookmarks(bookmarks, for: it.url)
    }

    func deleteBookmarks(at o: IndexSet) {
        guard let it = current else { return }
        bookmarks.remove(atOffsets: o)
        PlaybackMemory.shared.setBookmarks(bookmarks, for: it.url)
    }

    // MARK: Sleep timer

    func setSleep(minutes: Int?, atEnd: Bool = false) {
        sleepTask?.cancel()
        sleepAtEnd = atEnd
        guard let m = minutes else { sleepEnd = nil; return }
        sleepEnd = Date().addingTimeInterval(Double(m) * 60)
        sleepTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(m * 60))
            guard !Task.isCancelled, let self else { return }
            self.player.pause()
            self.sleepEnd = nil
            self.show("Sleep timer: paused")
            Log.i("vlc", "Sleep timer fired")
        }
    }

    // MARK: Snapshot / recording

    private func docsSubdir(_ name: String) -> URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func snapshot() {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let name = (current?.title ?? "snapshot") + "-" + f.string(from: Date()) + ".png"
        let path = docsSubdir("Snapshots").appendingPathComponent(name).path
        player.saveVideoSnapshot(at: path, withWidth: 0, andHeight: 0)
        Log.i("vlc", "Snapshot → \(path)")
        show("Snapshot saved to Files › Lumen › Snapshots")
    }

    func toggleRecording() {
        if recording {
            player.stopRecording()
            recording = false
            show("Recording saved to Files › Lumen › Recordings")
        } else {
            player.startRecording(atPath: docsSubdir("Recordings").path)
            recording = true
            show("Recording…")
        }
        Log.i("vlc", "Recording \(recording ? "started" : "stopped")")
    }

    // MARK: Renderers (Chromecast etc.)

    func startRendererDiscovery() {
        guard discoverers.isEmpty, let list = VLCRendererDiscoverer.list() else { return }
        for d in list {
            if let disc = VLCRendererDiscoverer(name: d.name) {
                disc.delegate = self
                _ = disc.start()
                discoverers.append(disc)
                Log.d("vlc", "Renderer discoverer started: \(d.name)")
            }
        }
    }

    func selectRenderer(_ item: VLCRendererItem?) {
        selectedRenderer = item
        _ = player.setRendererItem(item)
        Log.i("vlc", "Renderer: \(item?.name ?? "local")")
    }

    nonisolated func rendererDiscovererItemAdded(_ rendererDiscoverer: VLCRendererDiscoverer, item: VLCRendererItem) {
        Task { @MainActor in self.renderers.append(item) }
    }

    nonisolated func rendererDiscovererItemDeleted(_ rendererDiscoverer: VLCRendererDiscoverer, item: VLCRendererItem) {
        Task { @MainActor in self.renderers.removeAll { $0 === item } }
    }

    // MARK: Info

    var mediaInfo: [(String, String)] {
        var rows: [(String, String)] = []
        guard let media = player.media else { return rows }
        let m = media.metaData
        if let t = m.title { rows.append(("Title", t)) }
        if let a = m.artist { rows.append(("Artist", a)) }
        if let a = m.album { rows.append(("Album", a)) }
        rows.append(("Duration", formatTime(Double(lengthMs) / 1000)))
        for t in media.tracksInformation {
            let kind: String
            switch t.type.rawValue {
            case 0: kind = "Audio"
            case 1: kind = "Video"
            case 2: kind = "Subtitle"
            default: kind = "Track"
            }
            var parts = [t.codecName()]
            if let v = t.video { parts.append("\(v.width)×\(v.height)"); if v.frameRateDenominator > 0 { parts.append(String(format: "%.2f fps", Double(v.frameRate) / Double(v.frameRateDenominator))) } }
            if let a = t.audio { parts.append("\(a.channelsNumber) ch"); parts.append("\(a.rate) Hz") }
            if t.bitrate > 0 { parts.append("\(t.bitrate / 1000) kbps") }
            if let l = t.language, !l.isEmpty { parts.append(l) }
            rows.append((kind, parts.filter { !$0.isEmpty }.joined(separator: " · ")))
        }
        let s = media.statistics
        rows.append(("Displayed / lost frames", "\(s.displayedPictures) / \(s.lostPictures)"))
        rows.append(("Input bitrate", String(format: "%.0f kbps", s.inputBitrate * 8000)))
        return rows
    }

    // MARK: Toast

    func show(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.2))
            if !Task.isCancelled { self?.toast = nil }
        }
    }

    // MARK: VLCMediaPlayerDelegate (may arrive off the main thread)

    nonisolated func mediaPlayerStateChanged(_ newState: VLCMediaPlayerState) {
        Task { @MainActor in
            self.state = newState
            self.isPlaying = newState == .playing
            self.buffering = newState == .opening
            Log.d("vlc", "State → \(VLCMediaPlayerStateToString(newState) ?? "?")")
            switch newState {
            case .playing:
                self.refreshTracks()
                if let ms = self.pendingResume {
                    self.pendingResume = nil
                    if ms > 5000 { self.seek(ms: ms); Log.i("vlc", "Resumed at \(ms) ms") }
                }
            case .stopped:
                if !self.stoppedByUser { self.handleEnded() }
            case .error:
                let msg = VLCLibrary.currentErrorMessage ?? "Playback error"
                self.error = msg
                Log.e("vlc", "Playback error: \(msg) — \(self.current?.url.absoluteString ?? "")")
            default: break
            }
        }
    }

    nonisolated func mediaPlayerTimeChanged(_ aNotification: Notification) {
        Task { @MainActor in self.timeMs = Int(self.player.time.intValue) }
    }

    nonisolated func mediaPlayerLengthChanged(_ length: Int64) {
        Task { @MainActor in self.lengthMs = Int(length) }
    }

    nonisolated func mediaPlayerBufferingChanged(_ progress: Float) {
        Task { @MainActor in self.buffering = progress < 100 && self.state != .paused }
    }

    nonisolated func mediaPlayerTrackAdded(_ trackId: String, with trackType: VLCMedia.TrackType) {
        Task { @MainActor in self.refreshTracks() }
    }

    nonisolated func mediaPlayerTrackRemoved(_ trackId: String, with trackType: VLCMedia.TrackType) {
        Task { @MainActor in self.refreshTracks() }
    }

    nonisolated func mediaPlayerTrackSelected(_ trackType: VLCMedia.TrackType, selectedId: String, unselectedId: String) {
        Task { @MainActor in self.refreshTracks() }
    }

    nonisolated func mediaPlayerChapterChanged(_ aNotification: Notification) {
        Task { @MainActor in self.chapterIndex = Int(self.player.currentChapterIndex) }
    }
}
