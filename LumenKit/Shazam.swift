import AVFoundation
import ShazamKit
import SwiftUI

// MARK: - Per-file tag overrides (from Shazam)

struct MetaOverride: Codable {
    var title: String
    var artist: String
    var tintHex: String?
}

@MainActor
final class OverrideStore {
    static let shared = OverrideStore()
    private(set) var items: [String: MetaOverride] = [:]
    private let dir: URL

    private var jsonURL: URL { dir.appendingPathComponent("overrides.json") }

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("lumen-art", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let d = try? Data(contentsOf: jsonURL),
           let m = try? JSONDecoder().decode([String: MetaOverride].self, from: d) { items = m }
    }

    private func artURL(_ id: String) -> URL {
        dir.appendingPathComponent(ThumbStore.fileURL(id).lastPathComponent)
    }

    func artData(_ id: String) -> Data? { try? Data(contentsOf: artURL(id)) }

    func set(_ id: String, title: String, artist: String, art: Data?) {
        var o = MetaOverride(title: title, artist: artist, tintHex: items[id]?.tintHex)
        if let art, let img = UIImage(data: art) {
            try? art.write(to: artURL(id))
            if let th = img.preparingThumbnail(of: CGSize(width: 160, height: 160)) {
                ThumbStore.write(th, id: id)
                ThumbStore.mem.removeObject(forKey: id as NSString)
                o.tintHex = th.averageColor.map { Color(uiColor: $0).hexString }
            }
        }
        items[id] = o
        if let d = try? JSONEncoder().encode(items) { try? d.write(to: jsonURL) }
    }

    func apply(_ t: Track) -> Track {
        guard let o = items[t.id] else { return t }
        var x = t
        x.title = o.title
        x.artist = o.artist
        if let h = o.tintHex { x.tintHex = h }
        return x
    }
}

// MARK: - ShazamKit

enum ShazamPresenter { case list, nowPlaying }

struct ShazamMatch {
    let title: String
    let artist: String
    let artworkURL: URL?
    let webURL: URL?
    let appleMusicURL: URL?
}

enum ShazamState {
    case idle
    case working(String)
    case match(ShazamMatch)
    case noMatch
    case failed(String)
}

enum ShazamAudioError: Error { case audio }

@MainActor
final class ShazamService: ObservableObject {
    @Published var state: ShazamState = .idle
    @Published var showSheet = false
    @Published var saved = false
    private(set) var presenter: ShazamPresenter = .list
    private(set) var target: Track?

    /// Identify a file (no microphone): fingerprints ~12 s of the audio and asks Shazam.
    func identify(_ track: Track, from seconds: Double?, presenter: ShazamPresenter) async {
        self.presenter = presenter
        target = track
        saved = false
        state = .working("Reading audio…")
        showSheet = true
        var start = seconds ?? track.duration * Double.random(in: 0.2...0.5)
        start = max(0, min(start, track.duration - 13))
        let url = track.url
        let sig: SHSignature?
        do {
            sig = try await Task.detached(priority: .userInitiated) {
                try ShazamService.signature(url, from: start, length: 12)
            }.value
        } catch {
            state = .failed("Couldn't read this file: \(error.localizedDescription)")
            return
        }
        guard let sig else { state = .failed("Couldn't create a fingerprint."); return }
        state = .working("Asking Shazam…")
        handle(await SHSession().result(from: sig))
    }

    /// Listen through the microphone (music playing around you).
    func listen(target: Track?, presenter: ShazamPresenter) async {
        self.presenter = presenter
        self.target = target
        saved = false
        state = .working("Listening…")
        showSheet = true
        handle(await SHManagedSession().result())
    }

    private func handle(_ r: SHSession.Result) {
        switch r {
        case .match(let m):
            if let i = m.mediaItems.first {
                state = .match(ShazamMatch(title: i.title ?? "Unknown", artist: i.artist ?? i.subtitle ?? "",
                                           artworkURL: i.artworkURL, webURL: i.webURL, appleMusicURL: i.appleMusicURL))
            } else {
                state = .noMatch
            }
        case .noMatch:
            state = .noMatch
        case .error(let e, _):
            state = .failed(e.localizedDescription)
        }
    }

    func save(_ m: ShazamMatch, library: Library, player: Player) async {
        guard let t = target else { return }
        var art: Data?
        if let u = m.artworkURL { art = try? await URLSession.shared.data(from: u).0 }
        OverrideStore.shared.set(t.id, title: m.title, artist: m.artist, art: art)
        library.applyOverride(t.id)
        player.refreshMeta(id: t.id)
        saved = true
    }

    nonisolated static func signature(_ url: URL, from: Double, length: Double) throws -> SHSignature {
        let src = try AVAudioFile(forReading: url)
        let inFmt = src.processingFormat
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: inFmt, to: fmt),
              let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: 8192),
              let outBuf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 16384) else { throw ShazamAudioError.audio }
        src.framePosition = AVAudioFramePosition(from * inFmt.sampleRate)
        let total = Int(length * inFmt.sampleRate)
        var consumed = 0
        let gen = SHSignatureGenerator()
        while true {
            outBuf.frameLength = 0
            var err: NSError?
            let status = conv.convert(to: outBuf, error: &err) { _, st in
                let want = min(8192, total - consumed)
                if want <= 0 { st.pointee = .endOfStream; return nil }
                inBuf.frameLength = 0
                try? src.read(into: inBuf, frameCount: AVAudioFrameCount(want))
                if inBuf.frameLength == 0 { st.pointee = .endOfStream; return nil }
                consumed += Int(inBuf.frameLength)
                st.pointee = .haveData
                return inBuf
            }
            if outBuf.frameLength > 0 { try gen.append(outBuf, at: nil) }
            if status != .haveData || err != nil { break }
        }
        return gen.signature()
    }
}

// MARK: - Result sheet

struct ShazamSheet: View {
    @EnvironmentObject var shazam: ShazamService
    @EnvironmentObject var library: Library
    @EnvironmentObject var player: Player
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                switch shazam.state {
                case .idle:
                    EmptyView()
                case .working(let msg):
                    ProgressView().controlSize(.large)
                    Text(msg).foregroundStyle(.secondary)
                case .match(let m):
                    result(m)
                case .noMatch:
                    Image(systemName: "questionmark.circle").font(.system(size: 54)).foregroundStyle(.secondary)
                    Text("No match found").font(.headline)
                    Text("Shazam didn't recognise this part. Try another section of the song.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    if let t = shazam.target {
                        Button("Try another part", systemImage: "arrow.clockwise") {
                            Task { await shazam.identify(t, from: nil, presenter: shazam.presenter) }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                case .failed(let e):
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 48)).foregroundStyle(.orange)
                    Text(e).multilineTextAlignment(.center)
                    Text("ShazamKit may be unavailable for sideloaded apps, depending on how the app is signed.")
                        .font(.footnote).multilineTextAlignment(.center).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(24)
            .navigationTitle("Shazam")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder private func result(_ m: ShazamMatch) -> some View {
        AsyncImage(url: m.artworkURL) { img in
            img.resizable().scaledToFill()
        } placeholder: {
            RoundedRectangle(cornerRadius: 16).fill(.quaternary).overlay { Image(systemName: "music.note") }
        }
        .frame(width: 160, height: 160)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        VStack(spacing: 4) {
            Text(m.title).font(.title3.bold()).multilineTextAlignment(.center)
            Text(m.artist).foregroundStyle(.secondary)
        }
        if shazam.target != nil {
            if shazam.saved {
                Label("Saved to this track", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button { Task { await shazam.save(m, library: library, player: player) } } label: {
                    Label("Use as this track's tags & artwork", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        HStack {
            if let u = m.appleMusicURL { Link("Apple Music", destination: u) }
            if let u = m.webURL { Link("Shazam", destination: u) }
        }
        .buttonStyle(.bordered)
    }
}
