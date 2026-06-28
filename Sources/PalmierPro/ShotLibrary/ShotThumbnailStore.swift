import CoreGraphics
import Foundation
import ImageIO

/// Reads and writes the per-shot sampled JPEG thumbnails under `media/shots/` in a project package.
enum ShotThumbnailStore {
    static func dir(projectURL: URL) -> URL {
        projectURL
            .appendingPathComponent(Project.mediaDirectoryName, isDirectory: true)
            .appendingPathComponent(Project.shotsDirname, isDirectory: true)
    }

    static func relativePath(assetId: String, position: ShotPosition) -> String {
        "\(Project.mediaDirectoryName)/\(Project.shotsDirname)/\(assetId).\(position.rawValue).jpg"
    }

    /// Writes a JPEG for one sampled frame and returns its package-relative path, or nil on failure.
    @discardableResult
    static func write(_ image: CGImage, assetId: String, position: ShotPosition, projectURL: URL) -> String? {
        guard let jpeg = ImageEncoder.encodeJPEG(image, quality: 0.72) else { return nil }
        let folder = dir(projectURL: projectURL)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("\(assetId).\(position.rawValue).jpg")
            try jpeg.write(to: url, options: .atomic)
            return relativePath(assetId: assetId, position: position)
        } catch {
            Log.project.error("shot thumbnail write failed id=\(assetId.prefix(8)): \(Log.detail(error))")
            return nil
        }
    }

    static func url(relativePath: String?, projectURL: URL?) -> URL? {
        guard let relativePath, let projectURL else { return nil }
        let url = projectURL.appendingPathComponent(relativePath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Loads a thumbnail downsampled to `maxPixel` on the long edge. Safe to call off the main thread;
    /// use from a background task so the UI never decodes full-res JPEGs synchronously in a view body.
    static func loadDownsampled(relativePath: String?, projectURL: URL?, maxPixel: Int = 320) -> CGImage? {
        guard let url = url(relativePath: relativePath, projectURL: projectURL),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Remove all stored thumbnails for an asset (e.g. when its analysis is cleared).
    static func remove(assetId: String, projectURL: URL) {
        let folder = dir(projectURL: projectURL)
        for position in ShotPosition.allCases {
            let url = folder.appendingPathComponent("\(assetId).\(position.rawValue).jpg")
            try? FileManager.default.removeItem(at: url)
        }
    }
}
