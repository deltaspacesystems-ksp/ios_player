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
        return Track(id: url.lastPathComponent, url: url, title: title, artist: artist, album: album,
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

@MainActor
final class Library: ObservableObject {
    @Published var tracks: [Track] = []

    static let audioExt: Set<String> = ["mp3", "m4a", "aac", "wav", "aiff", "aif", "caf", "flac", "alac"]
    static let videoExt: Set<String> = ["mp4", "m4v", "mov"]

    var audio: [Track] { tracks.filter { !$0.isVideo } }
    var videos: [Track] { tracks.filter { $0.isVideo } }

    private var docs: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    func reload() async {
        let files = (try? FileManager.default.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil)) ?? []
        var out: [Track] = []
        for u in files.sorted(by: { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }) {
            let ext = u.pathExtension.lowercased()
            guard Self.audioExt.contains(ext) || Self.videoExt.contains(ext) else { continue }
            out.append(await Track.load(u))
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

    func delete(_ t: Track) {
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
