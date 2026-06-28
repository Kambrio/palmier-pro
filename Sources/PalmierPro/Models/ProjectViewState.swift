import CoreGraphics
import Foundation

/// Last-session editor view state — where the user was on the timeline, the zoom, the horizontal/
/// vertical scroll, and what was selected. Persisted as `view-state.json` so reopening a project
/// resumes where you left off. Purely a convenience; tolerant decode so it can grow.
struct ProjectViewState: Codable, Sendable, Equatable {
    var version: Int = 1
    var playheadFrame: Int = 0
    var zoomScale: Double?
    var scrollX: Double = 0
    var scrollY: Double = 0
    var selectedClipIds: [String] = []
    var selectedMediaAssetIds: [String] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        playheadFrame = try c.decodeIfPresent(Int.self, forKey: .playheadFrame) ?? 0
        zoomScale = try c.decodeIfPresent(Double.self, forKey: .zoomScale)
        scrollX = try c.decodeIfPresent(Double.self, forKey: .scrollX) ?? 0
        scrollY = try c.decodeIfPresent(Double.self, forKey: .scrollY) ?? 0
        selectedClipIds = try c.decodeIfPresent([String].self, forKey: .selectedClipIds) ?? []
        selectedMediaAssetIds = try c.decodeIfPresent([String].self, forKey: .selectedMediaAssetIds) ?? []
    }

    /// Nothing worth persisting (fresh project, never navigated) — lets the writer skip the file.
    var isDefault: Bool {
        playheadFrame == 0 && zoomScale == nil && scrollX == 0 && scrollY == 0
            && selectedClipIds.isEmpty && selectedMediaAssetIds.isEmpty
    }
}
