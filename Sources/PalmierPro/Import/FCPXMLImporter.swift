import Foundation

struct ImportSummary: Sendable {
    var tracksAdded = 0
    var clipsAdded = 0
    var mediaImported = 0
    var clipsSkipped = 0
    var skipped: [String] = []

    var text: String {
        var s = "Imported \(clipsAdded) clip(s) across \(tracksAdded) track(s); \(mediaImported) media file(s)."
        if clipsSkipped > 0 { s += " Skipped \(clipsSkipped) clip(s) with unresolved media." }
        if !skipped.isEmpty { s += " Unsupported (ignored): \(Set(skipped).sorted().joined(separator: ", "))." }
        return s
    }
}

enum FCPXMLImporter {
    /// Pure build: turns a ParsedTimeline into a new Timeline. `resolveMedia` returns the
    /// imported asset id (mediaRef) for a ParsedAsset, or nil if it couldn't be resolved.
    /// Replaces `current` if it has no clips, otherwise appends the imported tracks.
    static func build(
        parsed: ParsedTimeline,
        into current: Timeline,
        resolveMedia: (ParsedAsset) -> String?
    ) -> (Timeline, ImportSummary) {
        let hasExisting = current.tracks.contains { !$0.clips.isEmpty }
        let targetFps = hasExisting ? current.fps : parsed.fps

        func conv(_ frames: Int) -> Int {
            guard parsed.fps != targetFps, parsed.fps > 0 else { return frames }
            return Int((Double(frames) / Double(parsed.fps) * Double(targetFps)).rounded())
        }

        var summary = ImportSummary(skipped: parsed.skipped)
        var newTracks: [Track] = []

        for pTrack in parsed.tracks {
            var clips: [Clip] = []
            for pClip in pTrack.clips where !pClip.isGap {
                guard let asset = parsed.assets[pClip.assetId],
                      let mediaRef = resolveMedia(asset) else {
                    summary.clipsSkipped += 1
                    continue
                }
                let type = clipType(for: asset, kind: pTrack.kind)
                clips.append(Clip(
                    mediaRef: mediaRef,
                    mediaType: type,
                    sourceClipType: type,
                    startFrame: conv(pClip.startFrame),
                    durationFrames: max(1, conv(pClip.durationFrames)),
                    trimStartFrame: conv(pClip.sourceInFrames)))
            }
            guard !clips.isEmpty else { continue }
            newTracks.append(Track(type: pTrack.kind == .audio ? .audio : .video, clips: clips))
            summary.clipsAdded += clips.count
        }
        summary.tracksAdded = newTracks.count

        var result = current
        if hasExisting {
            result.tracks.append(contentsOf: newTracks)
        } else {
            result = Timeline(fps: parsed.fps, width: parsed.width, height: parsed.height,
                              settingsConfigured: true, tracks: newTracks)
        }
        return (result, summary)
    }

    private static func clipType(for asset: ParsedAsset, kind: ParsedTrackKind) -> ClipType {
        if kind == .audio { return .audio }
        if let ext = asset.src?.pathExtension.lowercased(),
           ClipType(fileExtension: ext) == .image { return .image }
        return .video
    }
}

extension FCPXMLImporter {
    /// Parses `url`, imports referenced media into `editor`, builds + applies the timeline.
    @MainActor
    static func importFile(at url: URL, into editor: EditorViewModel) throws -> ImportSummary {
        let parsed = try FCPXMLParser.parse(url: url)

        // Resolve each asset id -> imported MediaAsset id (referenced in place).
        var resolved: [String: String] = [:]
        var imported = 0
        for (id, asset) in parsed.assets {
            guard let src = asset.src, src.isFileURL else { continue }
            materializeIfNeeded(src)
            guard FileManager.default.fileExists(atPath: src.path),
                  let mediaAsset = editor.addMediaAsset(from: src) else { continue }
            resolved[id] = mediaAsset.id
            imported += 1
        }

        let built = build(parsed: parsed, into: editor.timeline) { asset in
            resolved[asset.id]
        }
        var summary = built.1
        summary.mediaImported = imported
        editor.timeline = built.0
        // Assigning `timeline` only bumps the render revision; the preview composition is
        // rebuilt by an explicit notify (like every other edit path), else Play has nothing.
        editor.notifyTimelineChanged()
        return summary
    }

    /// Triggers iCloud download for a not-yet-downloaded file and waits briefly.
    @MainActor
    private static func materializeIfNeeded(_ url: URL) {
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        guard values?.isUbiquitousItem == true,
              values?.ubiquitousItemDownloadingStatus != .current else { return }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path),
               (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?
                   .ubiquitousItemDownloadingStatus == .current { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
    }
}
