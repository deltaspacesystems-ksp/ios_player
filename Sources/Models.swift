import AVFoundation
import SwiftUI
import UIKit

struct Track: Identifiable, Equatable {
    let id: String
    let url: URL
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var artwork: UIImage?
    var tint: Color
    var isVideo: Bool

    static func == (a: Track, b: Track) -> Bool { a.id == b.id }

    static func load(_ url: URL) async -> Track {
        let asset = AVURLAsset(url: url)
        var title = url.deletingPathExtension().lastPathComponent
        var artist = "", album = ""
        var art: UIImage?
        var dur = 0.0
        if let d = try? await asset.load(.duration), d.seconds.isFinite { dur = d.seconds }
        if let md = try? await asset.load(.commonMetadata) {
            for item in md {
                guard let key = item.commonKey else { continue }
                switch key {
                case .commonKeyTitle:
                    if let v = try? await item.load(.stringValue), !v.isEmpty { title = v }
                case .commonKeyArtist:
                    if let v = try? await item.load(.stringValue) { artist = v }
                case .commonKeyAlbumName:
                    if let v = try? await item.load(.stringValue) { album = v }
                case .commonKeyArtwork:
                    if let d = try? await item.load(.dataValue), let img = UIImage(data: d) {
                        art = await img.byPreparingThumbnail(ofSize: CGSize(width: 700, height: 700)) ?? img
                    }
                default: break
                }
            }
        }
        let vt = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        let tint = art?.averageColor.map { Color(uiColor: $0) } ?? Color(hue: Double(abs(title.hashValue) % 360) / 360, saturation: 0.6, brightness: 0.7)
        return Track(id: url.path, url: url, title: title, artist: artist, album: album,
                     duration: dur, artwork: art, tint: tint, isVideo: !vt.isEmpty)
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

struct LibraryFolder: Identifiable {
    let id = UUID()
    var name: String
    var url: URL?          // nil = bookmark could not be resolved (e.g. LiveContainer / moved folder)
    var bookmark: Data
    var available: Bool { url != nil }
}

@MainActor
final class Library: ObservableObject {
    @Published var tracks: [Track] = []
    @Published var folders: [LibraryFolder] = []
    @Published var scanning = false

    static let audioExt: Set<String> = ["mp3", "m4a", "aac", "wav", "aiff", "aif", "caf", "flac", "alac"]
    static let videoExt: Set<String> = ["mp4", "m4v", "mov"]
    private static let foldersKey = "lumen.folders.v2"

    var audio: [Track] { tracks.filter { !$0.isVideo } }
    var videos: [Track] { tracks.filter { $0.isVideo } }

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
                // Keep it: never silently forget a folder the user added.
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

    // MARK: Scanning

    nonisolated private static func scan(_ root: URL) -> [URL] {
        var out: [URL] = []
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                                      options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return out }
        while let u = en.nextObject() as? URL {
            let ext = u.pathExtension.lowercased()
            if audioExt.contains(ext) || videoExt.contains(ext) { out.append(u) }
        }
        return out
    }

    func reload() async {
        scanning = true
        defer { scanning = false }
        let roots = [docs] + folders.compactMap(\.url)
        var urls: [URL] = []
        var seen = Set<String>()
        for r in roots {
            let found = await Task.detached { Self.scan(r) }.value
            for u in found where seen.insert(u.path).inserted { urls.append(u) }
        }
        var out: [Track] = []
        var i = 0
        while i < urls.count {
            let chunk = Array(urls[i..<min(i + 16, urls.count)])
            i += 16
            let loaded = await withTaskGroup(of: Track.self) { g in
                for u in chunk { g.addTask { await Track.load(u) } }
                var r: [Track] = []
                for await t in g { r.append(t) }
                return r
            }
            out += loaded
        }
        tracks = out.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
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
