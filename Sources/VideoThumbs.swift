import AVFoundation
import UIKit
import VLCKit

/// Tiny async mutex so only one libvlc thumbnailer runs at a time during a library scan.
actor AsyncGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}

enum VideoThumbs {
    private static let gate = AsyncGate()

    static func native(_ url: URL, duration: Double) async -> UIImage? {
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        g.appliesPreferredTrackTransform = true
        g.maximumSize = CGSize(width: 640, height: 640)
        let t = CMTime(seconds: max(1, min(duration * 0.1, 60)), preferredTimescale: 600)
        if let (cg, _) = try? await g.image(at: t) { return UIImage(cgImage: cg) }
        return nil
    }

    static func vlc(_ url: URL) async -> UIImage? {
        await gate.acquire()
        let img = await VLCThumbnailer.shared.thumbnail(url)
        await gate.release()
        return img
    }
}

final class VLCThumbnailer: NSObject, VLCMediaThumbnailerDelegate, @unchecked Sendable {
    static let shared = VLCThumbnailer()
    private var conts: [ObjectIdentifier: CheckedContinuation<UIImage?, Never>] = [:]
    private var live: [ObjectIdentifier: VLCMediaThumbnailer] = [:]
    private let lock = NSLock()

    func thumbnail(_ url: URL) async -> UIImage? {
        guard let media = VLCMedia(url: url) else { return nil }
        return await withCheckedContinuation { (cont: CheckedContinuation<UIImage?, Never>) in
            DispatchQueue.main.async {
                let t = VLCMediaThumbnailer(media: media, delegate: self, andVLCLibrary: nil)
                t.thumbnailWidth = 640
                t.thumbnailHeight = 360
                t.snapshotPosition = 0.15
                let key = ObjectIdentifier(t)
                self.lock.lock()
                self.conts[key] = cont
                self.live[key] = t
                self.lock.unlock()
                t.fetchThumbnail()
                DispatchQueue.global().asyncAfter(deadline: .now() + 10) { self.finish(key, nil) }
            }
        }
    }

    private func finish(_ key: ObjectIdentifier, _ img: UIImage?) {
        lock.lock()
        let c = conts.removeValue(forKey: key)
        live.removeValue(forKey: key)
        lock.unlock()
        c?.resume(returning: img)
    }

    func mediaThumbnailerDidTimeOut(_ mediaThumbnailer: VLCMediaThumbnailer) {
        finish(ObjectIdentifier(mediaThumbnailer), nil)
    }

    func mediaThumbnailer(_ mediaThumbnailer: VLCMediaThumbnailer, didFinishThumbnail thumbnail: CGImage) {
        finish(ObjectIdentifier(mediaThumbnailer), UIImage(cgImage: thumbnail))
    }
}
