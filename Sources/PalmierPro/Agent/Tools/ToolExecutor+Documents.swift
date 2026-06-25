import Foundation

extension ToolExecutor {
    private static let saveDocumentAllowedKeys: Set<String> = ["filename", "content", "format"]
    private static let exportTranscriptAllowedKeys: Set<String> = ["filename", "format"]

    /// Writes an agent-produced text artifact (script, hooks, notes, captions) into the
    /// project's configurable documents directory. Confined to that directory.
    func saveDocument(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.saveDocumentAllowedKeys, path: "save_document")
        let filename = try args.requireString("filename")
        let content = try args.requireString("content")
        let format = (args.string("format") ?? "md").lowercased()
        do {
            let url = try DocumentsStore.write(content, filename: filename, format: format, projectURL: editor.projectURL)
            return .ok("Saved to \(url.path)")
        } catch let e as DocumentsStore.DocError {
            throw ToolError(e.errorDescription ?? "Could not save document.")
        } catch {
            throw ToolError("Failed to save document: \(error.localizedDescription)")
        }
    }

    /// Builds the current timeline's spoken transcript as an .srt (timecoded cues) or .md
    /// (plain text) file and saves it to the documents directory.
    func exportTranscript(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.exportTranscriptAllowedKeys, path: "export_transcript")
        let format = (args.string("format") ?? "srt").lowercased()
        guard format == "srt" || format == "md" else {
            throw ToolError("export_transcript: format must be 'srt' or 'md'.")
        }

        let fps = editor.timeline.fps
        let assetsById = Dictionary(editor.mediaAssets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let engineTag = TranscriptCache.currentEngineTag()

        struct Cue { let start: Int; let end: Int; let text: String }
        var cues: [Cue] = []
        var transcripts: [URL: TranscriptionResult] = [:]

        for clip in editor.captionTargets(ids: []) {
            guard editor.findClip(id: clip.id) != nil, let asset = assetsById[clip.mediaRef] else { continue }
            let url = asset.url
            if transcripts[url] == nil {
                do { transcripts[url] = try await TranscriptCache.shared.transcript(for: url, isVideo: asset.type == .video, range: nil, engineTag: engineTag) }
                catch { continue }
            }
            guard let transcript = transcripts[url] else { continue }
            let visStart = Double(clip.trimStartFrame)
            let visEnd = visStart + Double(clip.durationFrames) * max(clip.speed, 0.0001)
            for seg in transcript.segments {
                let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let midFrame = (seg.start + seg.end) / 2 * Double(fps)
                guard midFrame >= visStart, midFrame < visEnd,
                      let f = ToolExecutor.spanFrames(start: seg.start, end: seg.end, clip: clip, fps: fps) else { continue }
                cues.append(Cue(start: f.start, end: f.end, text: text))
            }
        }
        guard !cues.isEmpty else {
            throw ToolError("No spoken transcript found on the timeline to export. Generate captions or check the audio first.")
        }
        cues.sort { ($0.start, $0.end) < ($1.start, $1.end) }

        let body: String
        if format == "srt" {
            body = cues.enumerated().map { i, c in
                "\(i + 1)\n\(Self.srtTimestamp(frame: c.start, fps: fps)) --> \(Self.srtTimestamp(frame: c.end, fps: fps))\n\(c.text)\n"
            }.joined(separator: "\n")
        } else {
            body = "# Transcript\n\n" + cues.map(\.text).joined(separator: "\n\n") + "\n"
        }

        let filename = args.string("filename") ?? "transcript"
        do {
            let url = try DocumentsStore.write(body, filename: filename, format: format, projectURL: editor.projectURL)
            return .ok("Exported \(cues.count) caption line\(cues.count == 1 ? "" : "s") to \(url.path)")
        } catch let e as DocumentsStore.DocError {
            throw ToolError(e.errorDescription ?? "Could not export transcript.")
        } catch {
            throw ToolError("Failed to export transcript: \(error.localizedDescription)")
        }
    }

    private static func srtTimestamp(frame: Int, fps: Int) -> String {
        let total = Double(max(frame, 0)) / Double(max(fps, 1))
        let whole = Int(total)
        let ms = Int((total - Double(whole)) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", whole / 3600, (whole % 3600) / 60, whole % 60, ms)
    }
}
