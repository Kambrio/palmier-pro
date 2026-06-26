import Foundation

/// On-disk per-asset analysis payload.
struct StabSidecar: Codable, Sendable, Equatable {
    /// Analyzer algorithm version; bump when the math changes so stale sidecars are re-analyzed.
    var version: Int = StabilizationSidecar.currentVersion
    var sourceSig: String      // ProxySignature.of(sourceURL) when analyzed
    var fps: Double            // source fps the frames were sampled at
    var frames: [StabFrameTransform]   // index = source frame
}

enum StabilizationSidecar {
    /// Bump when the analyzer's output math changes (forces re-analysis of older sidecars).
    static let currentVersion = 3

    static func dir(baseDir: URL) -> URL {
        baseDir.appendingPathComponent(
            "\(Project.mediaDirectoryName)/\(Project.stabilizationDirname)", isDirectory: true)
    }

    /// `baseDir` is the project package URL when used in-app; tests pass a temp dir directly.
    private static func fileURL(assetId: String, baseDir: URL) -> URL {
        dir(baseDir: baseDir).appendingPathComponent("\(assetId).json")
    }

    static func write(_ payload: StabSidecar, assetId: String, baseDir: URL) throws {
        let url = fileURL(assetId: assetId, baseDir: baseDir)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(payload).write(to: url, options: .atomic)
    }

    static func read(assetId: String, baseDir: URL, requiringSig: String? = nil) -> StabSidecar? {
        let url = fileURL(assetId: assetId, baseDir: baseDir)
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(StabSidecar.self, from: data) else { return nil }
        // Older-format sidecars (different/missing version) are stale → force re-analysis.
        guard payload.version == currentVersion else { return nil }
        if let sig = requiringSig, payload.sourceSig != sig { return nil }
        return payload
    }
}
