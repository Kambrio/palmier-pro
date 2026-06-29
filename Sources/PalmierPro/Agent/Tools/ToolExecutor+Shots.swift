import Foundation

// MARK: - Input shapes

fileprivate struct AnalyzeFootageInput: DecodableToolArgs {
    let mediaRefs: [String]?
    let force: Bool?
    let includeFrames: Bool?
    static let allowedKeys: Set<String> = ["mediaRefs", "force", "includeFrames"]
}

fileprivate struct GetShotLibraryInput: DecodableToolArgs {
    let mediaRefs: [String]?
    static let allowedKeys: Set<String> = ["mediaRefs"]
}

fileprivate struct SetShotInput: DecodableToolArgs {
    let mediaRef: String
    let name: String?
    let description: String?
    let labels: [String]?
    let addLabels: [String]?
    let removeLabels: [String]?
    let shotSize: String?
    let frameDescriptions: [FrameDesc]?
    static let allowedKeys: Set<String> = ["mediaRef", "name", "description", "labels", "addLabels", "removeLabels", "shotSize", "frameDescriptions"]

    struct FrameDesc: Decodable {
        let position: String
        let description: String
    }
}

extension ToolExecutor {

    // MARK: analyze_footage

    func analyzeFootage(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let input: AnalyzeFootageInput = try decodeToolArgs(args, path: "analyze_footage")
        guard editor.projectURL != nil else {
            throw ToolError("Save the project first — shot analysis stores thumbnails inside the project package.")
        }
        let manager = editor.shotLibraryManager

        let targets: [String]
        if let refs = input.mediaRefs, !refs.isEmpty {
            for ref in refs {
                guard let asset = editor.mediaAssetsById[ref] else { throw ToolError("Media not found: \(ref)") }
                guard asset.type == .video else { throw ToolError("\(ref) is \(asset.type.rawValue); only video footage can be analyzed.") }
            }
            targets = refs
        } else {
            targets = manager.analyzableAssets.map(\.id)
        }
        guard !targets.isEmpty else { throw ToolError("No analyzable video footage in this project.") }

        let force = input.force ?? false
        for id in targets { manager.analyze(assetId: id, force: force) }

        // Single-asset includeFrames: the agent wants to SEE the frames now. Wait briefly (bounded well
        // under typical MCP request timeouts) for that one clip, then return its frames as images.
        if input.includeFrames == true, targets.count == 1 {
            let single = targets[0]
            let deadline = ContinuousClock.now.advanced(by: .seconds(20))
            while manager.isAnalyzing, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(250))
            }
            if let entry = editor.shotLibrary.entry(assetId: single), manager.progressByAsset[single] == nil {
                return shotResultWithFrames(editor, entry: entry)
            }
            return .ok("Analyzing \(single) — still processing. Call analyze_footage again with includeFrames, or get_shot_library, shortly for the result.")
        }

        // Otherwise return immediately — analysis runs in the background; don't block the MCP request.
        let alreadyDone = targets.filter { editor.shotLibrary.entry(assetId: $0) != nil }.count
        let payload: [String: Any] = [
            "queued": targets.count,
            "alreadyAnalyzed": alreadyDone,
            "note": "Analysis runs on-device in the background. Poll get_shot_library (unanalyzedCount drops to 0 when done), then read the shots.",
        ]
        guard let json = Self.jsonString(payload) else { throw ToolError("Failed to encode result") }
        return .ok(json)
    }

    // MARK: get_shot_library

    func getShotLibrary(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let input: GetShotLibraryInput = try decodeToolArgs(args, path: "get_shot_library")
        // Specific mediaRefs → full per-frame detail. Whole-library read → compact rows (no per-frame
        // arrays), so a 200+ clip project stays a small payload the agent can read in one call.
        let detailed = (input.mediaRefs?.isEmpty == false)
        let entries: [ShotEntry]
        if let refs = input.mediaRefs, !refs.isEmpty {
            entries = refs.compactMap { editor.shotLibrary.entry(assetId: $0) }
        } else {
            entries = editor.shotLibrary.entries
        }
        let pending = editor.shotLibraryManager.pendingAssetIds
        var payload: [String: Any] = [
            "shots": entries.map { detailed ? Self.shotJSON($0) : Self.shotSummaryJSON($0) },
            "analyzedCount": editor.shotLibrary.entries.count,
            "unanalyzedCount": pending.count,
            "labelCatalog": ShotLabels.all.map { ["id": $0.id, "hint": $0.hint] },
        ]
        if !detailed && !entries.isEmpty {
            payload["detail"] = "Compact view (per-frame scene/object tags omitted). Pass mediaRefs to get full detail for specific shots."
        }
        guard let json = Self.jsonString(payload) else { throw ToolError("Failed to encode shot library") }
        return .ok(json)
    }

    // MARK: set_shot

    func setShot(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let input: SetShotInput = try decodeToolArgs(args, path: "set_shot")
        guard editor.mediaAssetsById[input.mediaRef] != nil else {
            throw ToolError("Media not found: \(input.mediaRef)")
        }
        guard editor.shotLibrary.entry(assetId: input.mediaRef) != nil else {
            throw ToolError("No shot analysis for \(input.mediaRef) yet. Call analyze_footage first.")
        }
        let manager = editor.shotLibraryManager
        var changed: [String] = []

        if let name = input.name { manager.setDisplayName(assetId: input.mediaRef, name); changed.append("name") }
        if let desc = input.description { manager.setSummary(assetId: input.mediaRef, desc); changed.append("description") }
        if let labels = input.labels { manager.setLabels(assetId: input.mediaRef, labels); changed.append("labels") }
        for label in input.addLabels ?? [] {
            if editor.shotLibrary.entry(assetId: input.mediaRef)?.labels.contains(ShotLabels.normalize(label)) != true {
                manager.toggleLabel(assetId: input.mediaRef, label)
            }
        }
        if input.addLabels?.isEmpty == false { changed.append("addLabels") }
        for label in input.removeLabels ?? [] {
            if editor.shotLibrary.entry(assetId: input.mediaRef)?.labels.contains(ShotLabels.normalize(label)) == true {
                manager.toggleLabel(assetId: input.mediaRef, label)
            }
        }
        if input.removeLabels?.isEmpty == false { changed.append("removeLabels") }
        if let sizeRaw = input.shotSize {
            guard let size = ShotSize.parse(sizeRaw) else {
                throw ToolError("shotSize: '\(sizeRaw)' is not a known size. Valid: \(ShotSize.selectable.map(\.rawValue).joined(separator: ", ")).")
            }
            manager.setShotSize(assetId: input.mediaRef, size)
            changed.append("shotSize")
        }
        for fd in input.frameDescriptions ?? [] {
            guard let pos = ShotPosition(rawValue: fd.position) else {
                throw ToolError("frameDescriptions: invalid position '\(fd.position)'. Expected q10, median, or q90.")
            }
            manager.setFrameDescription(assetId: input.mediaRef, position: pos, fd.description)
        }
        if input.frameDescriptions?.isEmpty == false { changed.append("frameDescriptions") }

        guard !changed.isEmpty else { throw ToolError("set_shot needs at least one field to change.") }
        guard let updated = editor.shotLibrary.entry(assetId: input.mediaRef) else {
            return .ok("Updated \(changed.joined(separator: ", ")).")
        }
        guard let json = Self.jsonString(["updated": changed, "shot": Self.shotJSON(updated)]) else {
            throw ToolError("Failed to encode result")
        }
        return .ok(json)
    }

    // MARK: - Serialization

    /// Compact one-line-per-shot summary (no per-frame arrays) for the whole-library read.
    private static func shotSummaryJSON(_ entry: ShotEntry) -> [String: Any] {
        var out: [String: Any] = ["mediaRef": entry.assetId]
        if let name = entry.displayName { out["name"] = name }
        if !entry.summary.isEmpty { out["summary"] = entry.summary }
        if !entry.labels.isEmpty { out["labels"] = entry.labels }
        if let size = entry.shotSize, size != .unknown { out["shotSize"] = size.rawValue }
        if let people = entry.people { out["people"] = people }
        if let group = entry.personGroup { out["personGroup"] = group }
        if let speech = entry.hasSpeech, speech { out["hasSpeech"] = true }
        if let dur = entry.durationSeconds { out["durationSeconds"] = (dur * 100).rounded() / 100 }
        return out
    }

    private static func shotJSON(_ entry: ShotEntry) -> [String: Any] {
        var out: [String: Any] = ["mediaRef": entry.assetId, "summary": entry.summary]
        if let name = entry.displayName { out["name"] = name }
        if !entry.labels.isEmpty { out["labels"] = entry.labels }
        if let size = entry.shotSize, size != .unknown { out["shotSize"] = size.rawValue }
        if let people = entry.people { out["people"] = people }
        if let group = entry.personGroup { out["personGroup"] = group }
        if let speech = entry.hasSpeech { out["hasSpeech"] = speech }
        if let excerpt = entry.transcriptExcerpt { out["transcript"] = excerpt }
        if let dur = entry.durationSeconds { out["durationSeconds"] = (dur * 100).rounded() / 100 }
        out["frames"] = entry.frames.map { frame -> [String: Any] in
            var f: [String: Any] = ["position": frame.position.rawValue, "timeSeconds": (frame.timeSeconds * 100).rounded() / 100]
            if let d = frame.description { f["description"] = d }
            if let a = frame.action { f["action"] = a }
            if !frame.sceneLabels.isEmpty { f["scene"] = Array(frame.sceneLabels.prefix(5)) }
            if !frame.objects.isEmpty { f["objects"] = frame.objects }
            if frame.shotSize != .unknown { f["shotSize"] = frame.shotSize.rawValue }
            if frame.people > 0 { f["people"] = frame.people }
            return f
        }
        return out
    }

    /// Single-asset result that also attaches the 3 frame thumbnails as images so the agent can
    /// look at the footage and write richer descriptions back with set_shot.
    private func shotResultWithFrames(_ editor: EditorViewModel, entry: ShotEntry) -> ToolResult {
        var blocks: [ToolResult.Block] = []
        for frame in entry.frames {
            guard let url = ShotThumbnailStore.url(relativePath: frame.thumbnailRelPath, projectURL: editor.projectURL),
                  let data = try? Data(contentsOf: url) else { continue }
            blocks.append(.image(base64: data.base64EncodedString(), mediaType: "image/jpeg"))
        }
        let json = Self.jsonString(Self.shotJSON(entry)) ?? "{}"
        blocks.append(.text(json))
        return ToolResult(content: blocks, isError: false)
    }
}
