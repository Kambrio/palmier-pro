import Foundation

/// Resolution the timeline preview composites at. Lower = faster playback, softer
/// preview. Export always renders at full canvas (see `TimelineRenderer`).
enum PreviewQuality: String, CaseIterable, Sendable {
    case full, high, medium, low

    /// Long-side cap for the preview composition; nil = full canvas (no cap).
    var longSideCap: Int? {
        switch self {
        case .full: nil
        case .high: 2560
        case .medium: 1440
        case .low: 960
        }
    }

    var menuLabel: String {
        switch self {
        case .full: "Full"
        case .high: "High (2560)"
        case .medium: "Medium (1440)"
        case .low: "Low (960)"
        }
    }

    /// Short form for the badge next to the canvas-zoom control.
    var badgeLabel: String {
        switch self {
        case .full: "Full"
        case .high: "High"
        case .medium: "Med"
        case .low: "Low"
        }
    }
}
