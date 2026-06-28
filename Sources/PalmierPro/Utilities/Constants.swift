import Foundation

enum LayoutPreset: String, CaseIterable {
    case `default`
    case media
    case vertical

    var label: String {
        switch self {
        case .default: "Default"
        case .media: "Media"
        case .vertical: "Vertical"
        }
    }

    var icon: String {
        switch self {
        case .default: "rectangle.split.3x1"
        case .media: "sidebar.left"
        case .vertical: "sidebar.right"
        }
    }
}

enum Layout {
    // Media panel
    static let mediaPanelDefault: CGFloat = 500
    static let mediaPanelMin: CGFloat = 280

    // Inspector
    static let inspectorDefault: CGFloat = 260
    static let inspectorMin: CGFloat = 150

    // Agent panel
    static let agentPanelMin: CGFloat = 240
    static let agentPanelMax: CGFloat = 640
    static let chatColumnMax: CGFloat = 640

    // Headers & toolbars
    static let panelHeaderHeight: CGFloat = 28
    static let toolbarHeight: CGFloat = 38

    static let panelGap: CGFloat = 5

    // Timeline
    static let timelineMinHeight: CGFloat = 100
    static let timelineMaxHeight: CGFloat = 700
    static let trackHeight: CGFloat = 50
    static let rulerHeight: CGFloat = 24
    static let trackHeaderWidth: CGFloat = 100
    static let dropZoneHeight: CGFloat = 60
    static let insertThreshold: CGFloat = 10
    static let dragThreshold: CGFloat = 3

    // Preview
    static let previewMinWidth: CGFloat = 400
    static let previewMinHeight: CGFloat = 320
}

enum Defaults {
    static let pixelsPerFrame: Double = 4.0
    static let imageDurationSeconds: Double = 5.0
    static let audioTTSDurationSeconds: Double = 10.0
    static let audioMusicDurationSeconds: Double = 60.0
    static let textDurationSeconds: Double = 3.0
    static let aspectTolerance: Double = 0.02
}

enum Snap {
    static let thresholdPixels: Double = 8.0
    static let stickyMultiplier: Double = 1.5
    static let playheadMultiplier: Double = 1.5
}

enum TrackSize {
    static let minHeight: CGFloat = 32
    static let maxHeight: CGFloat = 200
    static let resizeHandleZone: CGFloat = 6
}

enum Zoom {
    static let min: Double = 0.05
    static let floor: Double = 0.0001
    static let max: Double = 40.0
    static let toolbarStepFactor: Double = 1.25
    static let scrollSensitivity: Double = 0.04
    static let magnifySensitivity: Double = 1.5 
    static let panSpeed: Double = 5.0
    static let fitAllBuffer: Double = 3.0
}

enum TimelineAutoScroll {
    static let edgeZoneWidth: CGFloat = 56
    static let maxZoneFraction: CGFloat = 0.5
    static let minStep: CGFloat = 4
    static let maxStep: CGFloat = 28
    static let interval: TimeInterval = 1.0 / 60.0
}

enum Trim {
    static let handleWidth: CGFloat = 4.0
    static let clipCornerRadius: CGFloat = 3.0
}

enum Project {
    static let fileExtension = "palmier"
    static let registryFilename = "project-registry.json"
    static let typeIdentifier = "io.palmier.project"
    static let defaultProjectName = "Untitled Project"
    static let timelineFilename = "project.json"
    static let manifestFilename = "media.json"
    static let generationLogFilename = "generation-log.json"
    /// Per-footage shot analysis library (descriptions, labels, meaningful names).
    static let shotLibraryFilename = "shot-library.json"
    /// Story-development graph (directions, structures, acts, beats wired to footage).
    static let storyGraphFilename = "story-graph.json"
    /// Last-session editor view state (playhead, zoom, scroll, selection).
    static let viewStateFilename = "view-state.json"
    static let thumbnailFilename = "thumbnail.jpg"
    static let mediaDirectoryName = "media"
    /// Subdirectory of `media/` holding generated proxy movies.
    static let proxiesDirname = "proxies"
    /// Subdirectory of `media/` holding per-shot sampled JPEG thumbnails for the Shot Library.
    static let shotsDirname = "shots"
    /// Subdirectory of `media/` holding per-asset stabilization analysis sidecars.
    static let stabilizationDirname = "stabilization"
    /// Subdirectory of `media/` holding ffmpeg-baked stabilized movies.
    static let stabilizedDirname = "stabilized"
    /// Subfolder inside a .palmier package for agent-saved documents (scripts, hooks,
    /// transcript/caption exports, notes). Extra subdirs are tolerated by the package format.
    static let documentsDirectoryName = "documents"

    static var storageDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Palmier Pro", isDirectory: true)
    }

    nonisolated static func ensureStorageDirectory() {
        let url = storageDirectory
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

func gcd(_ a: Int, _ b: Int) -> Int {
    b == 0 ? a : gcd(b, a % b)
}

/// Filesystem locations for the local OmniVoice runtime.
enum OmniVoicePaths {
    /// ~/Library/Application Support/PalmierPro/OmniVoice
    static var installRoot: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(Log.subsystem)/OmniVoice", isDirectory: true)
    }

    /// The provisioned venv's python interpreter.
    static var provisionedPython: URL {
        installRoot.appendingPathComponent(".venv/bin/python3", isDirectory: false)
    }

    /// Known developer install (reused so we don't re-download on dev machines).
    static var devPython: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Documents/OmniVoice/.venv/bin/python3", isDirectory: false)
    }

    /// HuggingFace cache kept inside the install root so weights are local + removable.
    static var hfCache: URL { installRoot.appendingPathComponent("hf-cache", isDirectory: true) }

    static let pythonPin = "3.13"
    static let omniVoiceVersion = "0.1.5"
}
