import CryptoKit
import Foundation

/// On-disk per-asset analysis payload.
struct StabSidecar: Codable, Sendable, Equatable {
    /// Analyzer algorithm version; bump when the math changes so stale sidecars are re-analyzed.
    var version: Int = StabilizationSidecar.currentVersion
    var sourceSig: String      // ProxySignature.of(sourceURL) when analyzed
    var fps: Double            // source fps the frames were sampled at
    var frames: [StabFrameTransform]   // index = source frame

    init(version: Int = StabilizationSidecar.currentVersion, sourceSig: String, fps: Double, frames: [StabFrameTransform]) {
        self.version = version; self.sourceSig = sourceSig; self.fps = fps; self.frames = frames
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A pre-versioning sidecar (no version key) decodes to 0 → rejected as stale, not silently kept.
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 0
        sourceSig = try c.decode(String.self, forKey: .sourceSig)
        fps = try c.decode(Double.self, forKey: .fps)
        frames = try c.decode([StabFrameTransform].self, forKey: .frames)
    }
}

// MARK: - Subject sidecar

struct SubjectSidecar: Codable, Sendable, Equatable {
    var version: Int = SubjectSidecarStore.currentVersion
    var sourceSig: String
    var seedKey: String                // SubjectSeed.seedKey this track was produced for
    var fps: Double
    var frames: [StabFrameTransform]   // per frame: tx=subjectCenterX, ty=subjectCenterY
}

enum SubjectSidecarStore {
    /// Bumped from 1: the sidecar is now keyed by the user-picked seed.
    static let currentVersion = 2

    /// Short, filesystem-safe, deterministic hash of a seed key.
    static func seedHash(_ seedKey: String) -> String {
        let digest = SHA256.hash(data: Data(seedKey.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(8).description
    }

    static func fileURL(assetId: String, baseDir: URL, seedKey: String) -> URL {
        StabilizationSidecar.dir(baseDir: baseDir)
            .appendingPathComponent("\(assetId).\(seedHash(seedKey)).subject.json")
    }

    static func read(assetId: String, baseDir: URL, sourceSig: String, seedKey: String) -> SubjectSidecar? {
        guard let data = try? Data(contentsOf: fileURL(assetId: assetId, baseDir: baseDir, seedKey: seedKey)),
              let s = try? JSONDecoder().decode(SubjectSidecar.self, from: data),
              s.version == currentVersion, s.sourceSig == sourceSig, s.seedKey == seedKey else { return nil }
        return s
    }

    static func write(_ s: SubjectSidecar, assetId: String, baseDir: URL) throws {
        let url = fileURL(assetId: assetId, baseDir: baseDir, seedKey: s.seedKey)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(s).write(to: url, options: .atomic)
    }
}

// MARK: -

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
