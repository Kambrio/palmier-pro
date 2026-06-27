import Foundation

/// A user-picked subject to track: the box (normalized, TOP-LEFT) on a chosen source frame.
struct SubjectSeed: Codable, Equatable, Sendable {
    var frame: Int          // source-frame index the box was picked on
    var box: CGRect         // normalized, TOP-LEFT origin
    var label: String

    /// Stable identity string used to key the per-pick sidecar.
    var seedKey: String {
        func r(_ v: CGFloat) -> String { String(format: "%.4f", v) }
        return "\(frame)|\(r(box.origin.x)),\(r(box.origin.y)),\(r(box.width)),\(r(box.height))|\(label)"
    }
}

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

/// How the tracked subject's path is smoothed for Subject Lock.
enum SubjectSmoothing: String, Codable, Sendable, CaseIterable {
    case cinematic   // L1: locked, piecewise-linear — holds the subject very steady
    case organic     // Gaussian: follows the subject more loosely

    var displayName: String {
        switch self {
        case .cinematic: "Cinematic (locked)"
        case .organic:   "Organic (loose)"
        }
    }
}

/// Which axes Subject Lock corrects. Lock one axis to hold the subject steady there while letting
/// it move freely on the other (e.g. lock horizontal during a vertical reveal).
enum SubjectLockAxis: String, Codable, Sendable, CaseIterable {
    case both, horizontal, vertical

    var displayName: String {
        switch self {
        case .both:       "Both axes"
        case .horizontal: "Horizontal"
        case .vertical:   "Vertical"
        }
    }
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
    /// Subject Lock pick (engine == .subject). Nil until the user chooses a subject.
    var subjectSeed: SubjectSeed? = nil
    /// Subject Lock: how the subject path is smoothed.
    var subjectSmoothing: SubjectSmoothing = .cinematic
    /// Subject Lock: which axes to hold steady.
    var subjectLockAxis: SubjectLockAxis = .both

    init(enabled: Bool = true, engine: StabEngine = .vidstab, method: StabMethod = .similarity,
         smoothness: Double = 0.5, cropToFit: Bool = true, subjectSeed: SubjectSeed? = nil,
         subjectSmoothing: SubjectSmoothing = .cinematic, subjectLockAxis: SubjectLockAxis = .both) {
        self.enabled = enabled; self.engine = engine; self.method = method
        self.smoothness = smoothness; self.cropToFit = cropToFit; self.subjectSeed = subjectSeed
        self.subjectSmoothing = subjectSmoothing; self.subjectLockAxis = subjectLockAxis
    }

    // Tolerate older clips saved before `engine` existed (decode would otherwise drop stabilization).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        engine = try c.decodeIfPresent(StabEngine.self, forKey: .engine) ?? .vidstab
        method = try c.decodeIfPresent(StabMethod.self, forKey: .method) ?? .similarity
        smoothness = try c.decodeIfPresent(Double.self, forKey: .smoothness) ?? 0.5
        cropToFit = try c.decodeIfPresent(Bool.self, forKey: .cropToFit) ?? true
        subjectSeed = try c.decodeIfPresent(SubjectSeed.self, forKey: .subjectSeed) ?? nil
        subjectSmoothing = try c.decodeIfPresent(SubjectSmoothing.self, forKey: .subjectSmoothing) ?? .cinematic
        subjectLockAxis = try c.decodeIfPresent(SubjectLockAxis.self, forKey: .subjectLockAxis) ?? .both
    }
}
