import Foundation

/// How aggressively the correction is allowed to transform each frame.
enum StabMethod: String, Codable, Sendable, CaseIterable {
    case position       // translation only
    case similarity     // translation + scale + rotation (default)
    case perspective    // full homography

    var displayName: String {
        switch self {
        case .position:    "Position"
        case .similarity:  "Position, Scale & Rotation"
        case .perspective: "Perspective (approx.)"
        }
    }
}

/// The stabilization approach (the user-facing "Engine" choice).
enum StabEngine: String, Codable, Sendable, CaseIterable {
    case l1        // native L1-optimal path: locked / cinematic segments
    case smooth    // native Gaussian path: organic, follows the camera more loosely
    case vidstab   // FFmpeg + vid.stab (requires a vidstab-enabled ffmpeg on PATH)
    case subject   // Vision subject-tracking: keeps a detected person/face steady

    var displayName: String {
        switch self {
        case .l1:      "L1 — locked / cinematic"
        case .smooth:  "Smooth — organic"
        case .vidstab: "vid.stab (FFmpeg)"
        case .subject: "Subject Lock"
        }
    }

    /// Native engines apply per-frame corrections through the compositor; vid.stab bakes a file.
    var isNative: Bool { self != .vidstab }
}

/// Per-clip stabilization parameters. Cheap to store; the expensive raw camera
/// path lives in a per-asset sidecar (see StabilizationSidecar).
struct Stabilization: Codable, Sendable, Equatable {
    var enabled: Bool = true
    var engine: StabEngine = .vidstab
    var method: StabMethod = .similarity
    /// 0…1 — drives the smoothing strength. Higher = smoother / more locked-down.
    var smoothness: Double = 0.5
    /// Auto-zoom so counter-motion never exposes the frame edges.
    var cropToFit: Bool = true

    init(enabled: Bool = true, engine: StabEngine = .vidstab, method: StabMethod = .similarity,
         smoothness: Double = 0.5, cropToFit: Bool = true) {
        self.enabled = enabled; self.engine = engine; self.method = method
        self.smoothness = smoothness; self.cropToFit = cropToFit
    }

    // Tolerate older clips saved before `engine` existed (decode would otherwise drop stabilization).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        engine = try c.decodeIfPresent(StabEngine.self, forKey: .engine) ?? .vidstab
        method = try c.decodeIfPresent(StabMethod.self, forKey: .method) ?? .similarity
        smoothness = try c.decodeIfPresent(Double.self, forKey: .smoothness) ?? 0.5
        cropToFit = try c.decodeIfPresent(Bool.self, forKey: .cropToFit) ?? true
    }
}
