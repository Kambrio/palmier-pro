import Foundation

/// Intermediate, app-state-free model produced by FCPXMLParser and consumed by
/// FCPXMLImporter. All frame counts are in `fps` frames.
struct ParsedTimeline: Equatable {
    var fps: Int
    var width: Int
    var height: Int
    var assets: [String: ParsedAsset]   // id → asset
    var tracks: [ParsedTrack]
    var skipped: [String]               // unsupported elements, for the import summary
}

struct ParsedAsset: Equatable {
    var id: String
    var name: String
    var src: URL?
    var hasVideo: Bool
    var hasAudio: Bool
}

enum ParsedTrackKind: Equatable { case video, audio }

struct ParsedTrack: Equatable {
    var kind: ParsedTrackKind
    var clips: [ParsedClip]
}

/// A placed clip. `assetId` is empty for a gap.
struct ParsedClip: Equatable {
    var assetId: String
    var startFrame: Int
    var durationFrames: Int
    var sourceInFrames: Int
    var isGap: Bool
}
