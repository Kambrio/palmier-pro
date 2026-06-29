import AppKit
import Foundation

/// Loads the bundled shot-size preview images (one per canonical `ShotSize`) from
/// `Resources/Images/ShotSizes/`. Cached after first decode.
enum ShotSizeArtwork {
    private nonisolated(unsafe) static let cache = NSCache<NSString, NSImage>()

    static func image(for size: ShotSize) -> NSImage? {
        guard !size.imageName.isEmpty else { return nil }
        let key = size.imageName as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let root = Bundle.main.resourceURL else { return nil }
        let rel = "Images/ShotSizes/\(size.imageName).png"
        let candidates = [
            root.appendingPathComponent(rel),
            root.appendingPathComponent("PalmierPro_PalmierPro.bundle/\(rel)"),
        ]
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            if let img = NSImage(contentsOf: url) {
                normalizeSize(img, maxEdge: 48)
                let rounded = roundedCorners(img)
                cache.setObject(rounded, forKey: key)
                return rounded
            }
        }
        return nil
    }

    /// Pin the logical (layout) size to a small edge so the image's intrinsic size is small wherever
    /// it's rendered — including `Menu`/borderless-button labels that draw an `Image` at its natural
    /// `NSImage.size` and bypass SwiftUI `.frame()` modifiers. Pixel data is unchanged (CA downsamples).
    private static func normalizeSize(_ img: NSImage, maxEdge: CGFloat) {
        let s = img.size
        guard s.width > 0, s.height > 0 else { return }
        let scale = maxEdge / max(s.width, s.height)
        if scale < 1 { img.size = NSSize(width: s.width * scale, height: s.height * scale) }
    }

    /// Bake rounded corners into the image's drawing itself. `Menu` labels render an `Image` at its
    /// natural size and ignore SwiftUI `.clipShape`, so rounding must live in the NSImage, not the view.
    private static func roundedCorners(_ img: NSImage, fraction: CGFloat = 0.22) -> NSImage {
        let size = img.size
        guard size.width > 0, size.height > 0 else { return img }
        let radius = min(size.width, size.height) * fraction
        return NSImage(size: size, flipped: false) { dst in
            NSBezierPath(roundedRect: dst, xRadius: radius, yRadius: radius).addClip()
            img.draw(in: dst)
            return true
        }
    }
}
