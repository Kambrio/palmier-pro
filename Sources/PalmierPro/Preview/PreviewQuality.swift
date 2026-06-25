import Foundation

/// Resolution the timeline preview composites at. Lower = faster playback, softer
/// preview. Export always renders at full canvas (see `TimelineRenderer`).
enum PreviewQuality: String, CaseIterable, Sendable {
    case adaptive, full, high, medium, low, veryLow

    /// Fixed long-side cap for the manual modes; nil for adaptive/full (computed).
    var fixedLongSideCap: Int? {
        switch self {
        case .adaptive, .full: nil
        case .high: 2560
        case .medium: 1440
        case .low: 960
        case .veryLow: 640
        }
    }

    /// Long side used for adaptive when the preview pixel size isn't known yet
    /// (before first layout) — a light default so a 6K canvas never briefly
    /// composites full-res.
    private static let adaptiveFallbackLongSide = 1440.0

    /// Preview composition size for a given canvas and current preview pixel size.
    /// Aspect-preserving, even dimensions, never larger than the canvas.
    func renderSize(canvas: CGSize, adaptivePixelSize: CGSize) -> CGSize {
        let w = Double(canvas.width), h = Double(canvas.height)
        guard w > 0, h > 0 else { return canvas }
        func even(_ v: Double) -> Int { let i = Int(v.rounded()); return max(2, i - (i % 2)) }

        let scale: Double
        switch self {
        case .full:
            scale = 1
        case .adaptive:
            let longPx = max(adaptivePixelSize.width, adaptivePixelSize.height)
            let target = longPx > 0 ? Double(longPx) : Self.adaptiveFallbackLongSide
            scale = min(1, target / max(w, h))
        case .high, .medium, .low, .veryLow:
            scale = min(1, Double(fixedLongSideCap!) / max(w, h))
        }
        return CGSize(width: even(w * scale), height: even(h * scale))
    }

    var menuLabel: String {
        switch self {
        case .adaptive: "Adaptive"   // resolution appended live by the menu
        case .full: "Full"
        case .high: "High (2560)"
        case .medium: "Medium (1440)"
        case .low: "Low (960)"
        case .veryLow: "Very Low (640)"
        }
    }

    /// Short form for the badge next to the canvas-zoom control.
    var badgeLabel: String {
        switch self {
        case .adaptive: "Auto"
        case .full: "Full"
        case .high: "High"
        case .medium: "Med"
        case .low: "Low"
        case .veryLow: "V.Low"
        }
    }
}
