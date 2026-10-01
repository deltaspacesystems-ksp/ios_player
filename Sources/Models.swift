import AVFoundation
import CryptoKit
import SwiftUI
import UIKit

enum MediaExt {
    static let nativeAudio: Set<String> = ["mp3", "m4a", "aac", "wav", "aiff", "aif", "caf", "flac", "alac"]
    static let nativeVideo: Set<String> = ["mp4", "m4v", "mov"]
    /// Played by the VLC engine only (Apple frameworks can't decode these).
    static let vlcAudio: Set<String> = ["opus", "ogg", "oga", "wma", "ape", "wv", "mka", "mpc", "tta", "ac3", "dts", "amr", "spx"]
    static let vlcVideo: Set<String> = ["mkv", "avi", "webm", "flv", "wmv", "ts", "m2ts", "mts", "mpg", "mpeg", "vob", "3gp", "ogv", "rmvb", "asf", "divx", "m2v"]
    static var audio: Set<String> { nativeAudio.union(vlcAudio) }
    static var video: Set<String> { nativeVideo.union(vlcVideo) }
}

struct Track: Identifiable, Equatable {
    let id: String
    let url: URL
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var isVideo: Bool
    var tintHex: String?
    var genre = ""
    var modified = 0.0

    var tint: Color {
        if let h = tintHex { return Color(hex: h) }
        let h = id.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) % 360 }
        return Color(hue: Double(h) / 360, saturation: 0.6, brightness: 0.7)
    }

    static func == (a: Track, b: Track) -> Bool { a.id == b.id }

    /// Audio that only the VLC engine can play (opus, ogg, wma, ape ...).
    var vlcOnly: Bool { MediaExt.vlcAudio.contains(url.pathExtension.lowercased()) }
}

struct CachedMeta: Codable {
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var isVideo: Bool
    var tintHex: String?
    var mtime: Double
    var genre: String?
}

extension Track {
    init(url: URL, meta m: CachedMeta) {
        self.init(id: url.path, url: url, title: m.title, artist: m.artist, album: m.album,
                  duration: m.duration, isVideo: m.isVideo, tintHex: m.tintHex, genre: m.genre ?? "", modified: m.mtime)
    }

    static func build(_ url: URL, mtime: Double) async -> CachedMeta {
        let r = await MetaReader.read(url, wantArt: true)
        var title = r.title ?? ""
        var artist = r.artist ?? ""
        if title.isEmpty {
            let base = url.deletingPathExtension().lastPathComponent
            if artist.isEmpty, let range = base.range(of: " - ") {
                artist = String(base[..<range.lowerBound])
                title = String(base[range.upperBound...])
            } else {
                title = base
            }
        }
        var tint: String?
        if let d = r.art, let img = UIImage(data: d),
           let th = img.preparingThumbnail(of: CGSize(width: 160, height: 160)) {
            ThumbStore.write(th, id: url.path)
            tint = th.averageColor.map { Color(uiColor: $0).hexString }
        } else if r.isVideo {
            // no embedded cover: grab a frame (Apple frames for MP4/MOV, libvlc for everything else)
            let ext = url.pathExtension.lowercased()
            let frame = MediaExt.nativeVideo.contains(ext)
                ? await VideoThumbs.native(url, duration: r.duration)
                : await VideoThumbs.vlc(url)
            if let frame, let th = frame.preparingThumbnail(of: CGSize(width: 480, height: 480)) {
                ThumbStore.write(th, id: url.path)
                tint = th.averageColor.map { Color(uiColor: $0).hexString }
            } else {
                Log.w("scan", "No thumbnail for \(url.lastPathComponent)")
            }
        }
        return CachedMeta(title: title, artist: artist, album: r.album ?? "", duration: r.duration,
                          isVideo: r.isVideo, tintHex: tint, mtime: mtime, genre: r.genre)
    }
}

// MARK: - Thumbnails (disk + memory cache, loaded lazily per row)

enum ThumbStore {
    static let mem: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 600
        return c
    }()

    static let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("thumbs")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    static func fileURL(_ id: String) -> URL {
        let h = SHA256.hash(data: Data(id.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent(h + ".jpg")
    }

    static func cached(_ id: String) -> UIImage? { mem.object(forKey: id as NSString) }

    static func image(for id: String) -> UIImage? {
        if let c = cached(id) { return c }
        guard let img = UIImage(contentsOfFile: fileURL(id).path) else { return nil }
        mem.setObject(img, forKey: id as NSString)
        return img
    }

    static func write(_ img: UIImage, id: String) {
        if let d = img.jpegData(compressionQuality: 0.8) { try? d.write(to: fileURL(id)) }
    }
}

struct ThumbView: View {
    let id: String?
    var radius: CGFloat = 8
    @State private var img: UIImage?

    var body: some View {
        ArtworkView(image: img ?? id.flatMap { ThumbStore.cached($0) }, radius: radius)
            .task(id: id) {
                guard let id else { img = nil; return }
                if let c = ThumbStore.cached(id) { img = c; return }
                img = await Task.detached(priority: .utility) { ThumbStore.image(for: id) }.value
            }
    }
}

// MARK: - Metadata (AVFoundation + own FLAC/Vorbis parser)

enum MetaReader {
    struct Result {
        var title: String?
        var artist: String?
        var album: String?
        var art: Data?
        var genre: String?
        var duration = 0.0
        var isVideo = false
    }

    static func read(_ url: URL, wantArt: Bool) async -> Result {
        var r = Result()
        let ext = url.pathExtension.lowercased()
        if MediaExt.vlcAudio.contains(ext) || MediaExt.vlcVideo.contains(ext) {
            // Apple frameworks can't read these — let libvlc parse tags, length and cover art.
            r.isVideo = MediaExt.vlcVideo.contains(ext)
            if let m = await VLCMetaParser.shared.parse(url) {
                let md = m.metaData
                r.title = md.title
                r.artist = md.artist
                r.album = md.album
                r.genre = md.genre
                r.duration = Double(m.length.intValue) / 1000
                if wantArt { r.art = md.artwork?.pngData() }
            } else {
                Log.w("scan", "libvlc could not parse \(url.lastPathComponent)")
            }
            return r
        }
        let asset = AVURLAsset(url: url)
        if let d = try? await asset.load(.duration), d.seconds.isFinite { r.duration = d.seconds }
        if ext == "flac" {
            let f = flac(url, wantArt: wantArt)
            r.title = f.title
            r.artist = f.artist
            r.album = f.album
            r.genre = f.genre
            r.art = f.art
            if r.duration <= 0, let d = f.duration { r.duration = d }
        }
        if r.title == nil || (wantArt && r.art == nil) { await av(asset, &r, wantArt) }
        if MediaExt.nativeVideo.contains(ext) {
            let vt = (try? await asset.loadTracks(withMediaType: .video)) ?? []
            r.isVideo = !vt.isEmpty
        }
        return r
    }

    private static func av(_ asset: AVURLAsset, _ r: inout Result, _ wantArt: Bool) async {
        let common = (try? await asset.load(.commonMetadata)) ?? []
        let all = (try? await asset.load(.metadata)) ?? []
        for item in common + all {
            var kind = ""
            if let k = item.commonKey {
                switch k {
                case .commonKeyTitle: kind = "t"
                case .commonKeyArtist: kind = "a"
                case .commonKeyAlbumName: kind = "l"
                case .commonKeyArtwork: kind = "p"
                case .commonKeyType: kind = "g"
                default: break
                }
            }
            if kind.isEmpty, let id = item.identifier {
                switch id {
                case .id3MetadataTitleDescription, .iTunesMetadataSongName: kind = "t"
                case .id3MetadataLeadPerformer, .iTunesMetadataArtist, .id3MetadataBand: kind = "a"
                case .id3MetadataAlbumTitle, .iTunesMetadataAlbum: kind = "l"
                case .id3MetadataAttachedPicture, .iTunesMetadataCoverArt: kind = "p"
                case .id3MetadataContentType, .iTunesMetadataUserGenre: kind = "g"
                default: break
                }
            }
            switch kind {
            case "t": if r.title == nil, let v = try? await item.load(.stringValue), !v.isEmpty { r.title = v }
            case "a": if r.artist == nil, let v = try? await item.load(.stringValue), !v.isEmpty { r.artist = v }
            case "l": if r.album == nil, let v = try? await item.load(.stringValue), !v.isEmpty { r.album = v }
            case "g": if r.genre == nil, let v = try? await item.load(.stringValue), !v.isEmpty { r.genre = v }
            case "p": if wantArt, r.art == nil, let d = try? await item.load(.dataValue) { r.art = d }
            default: break
            }
        }
    }

    struct Flac {
        var title: String?
        var artist: String?
        var album: String?
        var art: Data?
        var genre: String?
        var duration: Double?
    }

    private static func le32(_ b: [UInt8], _ o: Int) -> Int {
        Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24
    }

    private static func be32(_ b: [UInt8], _ o: Int) -> Int {
        Int(b[o]) << 24 | Int(b[o + 1]) << 16 | Int(b[o + 2]) << 8 | Int(b[o + 3])
    }

    static func flac(_ url: URL, wantArt: Bool) -> Flac {
        var m = Flac()
        guard let fh = try? FileHandle(forReadingFrom: url) else { return m }
        defer { try? fh.close() }
        guard let magic = try? fh.read(upToCount: 4), magic == Data("fLaC".utf8) else { return m }
        var last = false
        while !last {
            guard let hd = try? fh.read(upToCount: 4), hd.count == 4 else { break }
            let h = [UInt8](hd)
            last = h[0] & 0x80 != 0
            let type = h[0] & 0x7F
            let len = Int(h[1]) << 16 | Int(h[2]) << 8 | Int(h[3])
            guard type == 0 || type == 4 || (type == 6 && wantArt) else {
                if let off = try? fh.offset() { try? fh.seek(toOffset: off + UInt64(len)) }
                continue
            }
            guard let dd = try? fh.read(upToCount: len), dd.count == len else { break }
            let b = [UInt8](dd)
            switch type {
            case 0:
                if b.count >= 18 {
                    let sr = UInt64(b[10]) << 12 | UInt64(b[11]) << 4 | UInt64(b[12]) >> 4
                    let total = UInt64(b[13] & 0x0F) << 32 | UInt64(b[14]) << 24 | UInt64(b[15]) << 16 | UInt64(b[16]) << 8 | UInt64(b[17])
                    if sr > 0 { m.duration = Double(total) / Double(sr) }
                }
            case 4:
                guard b.count >= 8 else { break }
                var o = 4 + le32(b, 0)
                guard o >= 0, o + 4 <= b.count else { break }
                let n = le32(b, o)
                o += 4
                for _ in 0..<max(0, min(n, 500)) {
                    guard o + 4 <= b.count else { break }
                    let l = le32(b, o)
                    o += 4
                    guard l >= 0, o + l <= b.count else { break }
                    let s = String(decoding: b[o..<o + l], as: UTF8.self)
                    o += l
                    guard let eq = s.firstIndex(of: "=") else { continue }
                    let key = s[..<eq].uppercased()
                    let val = String(s[s.index(after: eq)...])
                    guard !val.isEmpty else { continue }
                    switch key {
                    case "TITLE": if m.title == nil { m.title = val }
                    case "ARTIST": m.artist = val
                    case "ALBUMARTIST": if m.artist == nil { m.artist = val }
                    case "ALBUM": if m.album == nil { m.album = val }
                    case "GENRE": if m.genre == nil { m.genre = val }
                    default: break
                    }
                }
            case 6:
                var o = 4
                guard b.count >= 32 else { break }
                let ml = be32(b, o); o += 4 + ml
                guard o >= 0, o + 4 <= b.count else { break }
                let dl = be32(b, o); o += 4 + dl + 16
                guard o >= 0, o + 4 <= b.count else { break }
                let pl = be32(b, o); o += 4
                if m.art == nil, pl > 0, o + pl <= b.count { m.art = Data(b[o..<o + pl]) }
            default: break
            }
        }
        return m
    }
}

extension UIImage {
    var averageColor: UIColor? {
        guard let cg = cgImage else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return UIColor(red: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255, alpha: 1)
    }
}

// MARK: - Library

struct LibraryFolder: Identifiable {
    let id = UUID()
    var name: String
    var url: URL?          // nil = bookmark could not be resolved (e.g. LiveContainer / moved folder)
    var bookmark: Data
    var available: Bool { url != nil }
}

@MainActor
final class Library: ObservableObject {
    @Published var tracks: [Track] = [] {
        didSet {
            audio = tracks.filter { !$0.isVideo && !$0.vlcOnly }
            vlcAudio = tracks.filter { !$0.isVideo && $0.vlcOnly }
            videos = tracks.filter { $0.isVideo }
        }
    }
    @Published private(set) var audio: [Track] = []
    @Published private(set) var vlcAudio: [Track] = []
    @Published private(set) var videos: [Track] = []
    @Published var folders: [LibraryFolder] = []
    @Published var scanning = false

    private static let foldersKey = "lumen.folders.v2"

    private var docs: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    init() { resolveFolders() }

    // MARK: Folders outside Lumen's sandbox (persisted as security-scoped bookmarks)

    private func resolveFolders() {
        let saved = UserDefaults.standard.array(forKey: Self.foldersKey) as? [[String: Data]] ?? []
        var out: [LibraryFolder] = []
        for entry in saved {
            guard let b = entry["b"] else { continue }
            let name = entry["n"].flatMap { String(data: $0, encoding: .utf8) } ?? "Folder"
            var stale = false
            if let u = try? URL(resolvingBookmarkData: b, options: [], relativeTo: nil, bookmarkDataIsStale: &stale),
               u.startAccessingSecurityScopedResource() {
                out.append(LibraryFolder(name: u.lastPathComponent, url: u, bookmark: stale ? ((try? u.bookmarkData()) ?? b) : b))
            } else {
                out.append(LibraryFolder(name: name, url: nil, bookmark: b))
            }
        }
        folders = out
        saveFolders()
    }

    private func saveFolders() {
        let arr: [[String: Data]] = folders.map { ["b": $0.bookmark, "n": Data($0.name.utf8)] }
        UserDefaults.standard.set(arr, forKey: Self.foldersKey)
    }

    func addFolder(_ url: URL) async {
        guard url.startAccessingSecurityScopedResource(),
              let data = try? url.bookmarkData() else { return }
        if folders.contains(where: { $0.url?.path == url.path }) { url.stopAccessingSecurityScopedResource(); return }
        let f = LibraryFolder(name: url.lastPathComponent, url: url, bookmark: data)
        if let i = folders.firstIndex(where: { !$0.available && $0.name == f.name }) { folders[i] = f } else { folders.append(f) }
        saveFolders()
        await reload()
    }

    func removeFolder(_ f: LibraryFolder) async {
        f.url?.stopAccessingSecurityScopedResource()
        folders.removeAll { $0.id == f.id }
        saveFolders()
        await reload()
    }

    // MARK: Scanning (cached by path + modification time)

    nonisolated private static var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("lumen-meta-v2.json")
    }

    nonisolated private static func loadCache() -> [String: CachedMeta] {
        guard let d = try? Data(contentsOf: cacheURL) else { return [:] }
        return (try? JSONDecoder().decode([String: CachedMeta].self, from: d)) ?? [:]
    }

    nonisolated private static func saveCache(_ c: [String: CachedMeta]) {
        if let d = try? JSONEncoder().encode(c) { try? d.write(to: cacheURL) }
    }

    nonisolated private static func scan(_ root: URL) -> [(URL, Double)] {
        var out: [(URL, Double)] = []
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey],
                                                      options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return out }
        while let u = en.nextObject() as? URL {
            let ext = u.pathExtension.lowercased()
            guard MediaExt.audio.contains(ext) || MediaExt.video.contains(ext) else { continue }
            let m = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0
            out.append((u, m))
        }
        return out
    }

    private static func sorted(_ t: [Track]) -> [Track] {
        t.map { OverrideStore.shared.apply($0) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    func reload() async {
        scanning = true
        defer { scanning = false }
        let roots = [docs] + folders.compactMap(\.url)
        let (files, cache) = await Task.detached { () -> ([(URL, Double)], [String: CachedMeta]) in
            var all: [(URL, Double)] = []
            var seen = Set<String>()
            for r in roots { for f in Library.scan(r) where seen.insert(f.0.path).inserted { all.append(f) } }
            return (all, Library.loadCache())
        }.value

        var newCache: [String: CachedMeta] = [:]
        var out: [Track] = []
        var pending: [(URL, Double)] = []
        for (u, m) in files {
            if let c = cache[u.path], c.mtime == m {
                out.append(Track(url: u, meta: c))
                newCache[u.path] = c
            } else {
                pending.append((u, m))
            }
        }
        tracks = Self.sorted(out)

        var i = 0, n = 0
        while i < pending.count {
            let chunk = Array(pending[i..<min(i + 12, pending.count)])
            i += 12
            let done = await withTaskGroup(of: (URL, CachedMeta).self) { g in
                for (u, m) in chunk { g.addTask { (u, await Track.build(u, mtime: m)) } }
                var r: [(URL, CachedMeta)] = []
                for await x in g { r.append(x) }
                return r
            }
            for (u, c) in done {
                out.append(Track(url: u, meta: c))
                newCache[u.path] = c
            }
            n += 1
            if n % 4 == 0 { tracks = Self.sorted(out) }
        }
        tracks = Self.sorted(out)
        let snapshot = newCache
        Task.detached(priority: .utility) { Library.saveCache(snapshot) }
    }

    /// Re-applies a saved Shazam override to one track without rescanning.
    func applyOverride(_ id: String) {
        if let i = tracks.firstIndex(where: { $0.id == id }) { tracks[i] = OverrideStore.shared.apply(tracks[i]) }
    }

    func importFiles(_ urls: [URL]) async {
        for u in urls {
            let scoped = u.startAccessingSecurityScopedResource()
            defer { if scoped { u.stopAccessingSecurityScopedResource() } }
            let dest = docs.appendingPathComponent(u.lastPathComponent)
            if dest.standardizedFileURL == u.standardizedFileURL { continue }
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: u, to: dest)
        }
        await reload()
    }

    /// Only files inside Lumen's own folder can be deleted; external folders are read-only here.
    func canDelete(_ t: Track) -> Bool { t.url.path.hasPrefix(docs.path) }

    func delete(_ t: Track) {
        guard canDelete(t) else { return }
        try? FileManager.default.removeItem(at: t.url)
        tracks.removeAll { $0 == t }
    }
}

func formatTime(_ s: Double) -> String {
    guard s.isFinite, s >= 0 else { return "0:00" }
    let t = Int(s)
    let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
}
