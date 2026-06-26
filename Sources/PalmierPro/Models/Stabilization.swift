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

/// Per-clip stabilization parameters. Cheap to store; the expensive raw camera
/// path lives in a per-asset sidecar (see StabilizationSidecar).
struct Stabilization: Codable, Sendable, Equatable {
    var enabled: Bool = true
    var method: StabMethod = .similarity
    /// 0…1 — drives the smoothing window. Higher = smoother / more locked-down.
    var smoothness: Double = 0.5
    /// Auto-zoom so counter-motion never exposes the frame edges.
    var cropToFit: Bool = true
}
