import CoreGraphics
import Foundation

extension ToolExecutor {
    private static let addCaptionsAllowedKeys: Set<String> = Set([
        "style", "transform", "censorProfanity", "language", "animation", "highlightColor", "maxWords",
        "maxCharacters", "trackIndex", "maximumGapSeconds", "subtitleMediaRef",
    ])

    func addCaptions(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.addCaptionsAllowedKeys, path: "add_captions")

        if args.keys.contains("subtitleMediaRef") {
            guard let subtitleMediaRef = args.string("subtitleMediaRef"), !subtitleMediaRef.isEmpty else {
                throw ToolError("add_captions: subtitleMediaRef must be a non-empty media asset id string.")
            }
            let combined = Set(args.keys).subtracting(["subtitleMediaRef"])
            guard combined.isEmpty else {
                throw ToolError(
                    "add_captions: subtitleMediaRef uses the file's text, timing, and default styling as-is; "
                    + "remove \(combined.sorted().joined(separator: ", "))."
                )
            }
            return try await addCaptions(fromSubtitle: subtitleMediaRef, editor: editor)
        }

        let stylePatch = try parseTextStylePatch(args, path: "add_captions")
        var style = TextStyle.caption
        if let stylePatch { Self.applyTextStylePatch(stylePatch, to: &style) }

        let transform = try parseTextTransform(args["transform"], path: "add_captions.transform")
        var center = AppTheme.Caption.defaultCenter
        if let x = transform?.x { center.x = CGFloat(x) }
        if let y = transform?.y { center.y = CGFloat(y) }

        let animation = try parseTextAnimation(preset: args.string("animation"), highlightColor: args.string("highlightColor"), path: "add_captions") ?? TextAnimation()

        let maxWords = try captionLimit("maxWords", from: args)
        let maxCharacters = try captionLimit("maxCharacters", from: args)

        let gapSettings: CaptionGapSettings
        if let rawMaximumGap = args["maximumGapSeconds"] {
            guard !isJSONBoolean(rawMaximumGap),
                  rawMaximumGap is NSNumber || rawMaximumGap is Double || rawMaximumGap is Int,
                  let maximumGapSeconds = args.double("maximumGapSeconds"),
                  let parsed = CaptionGapSettings(maximumGapSeconds: maximumGapSeconds) else {
                throw ToolError(
                    "add_captions: maximumGapSeconds must be a finite number from "
                    + "\(CaptionGapSettings.maximumGapRange.lowerBound) through "
                    + "\(CaptionGapSettings.maximumGapRange.upperBound)."
                )
            }
            gapSettings = parsed
        } else {
            gapSettings = .default
        }

        let scope = try resolveTranscriptionScope(editor, args, path: "add_captions")
        let cloudRequest = scope.captionRequest(in: editor, provider: .cloud)
        let context = try await transcriptionContext(args, path: "add_captions") {
            await editor.captionCloudCreditCost(for: cloudRequest)
        }
        let provider = context.provider
        if provider == .cloud {
            if args.bool("censorProfanity") == true {
                throw ToolError("add_captions: censorProfanity is only available with local transcription.")
            }
        }

        var request = scope.captionRequest(in: editor, provider: provider)
        request.style = style
        request.center = center
        request.censorProfanity = args.bool("censorProfanity") ?? false
        request.locale = context.preferredLocale
        request.maxWords = maxWords
        request.maxCharacters = maxCharacters
        request.gapSettings = gapSettings
        request.animation = animation

        try await Self.validateCloudTranscriptionAccess(for: request, in: editor)

        // Transcription can take minutes on long media, so run it as a tracked background
        // job and return immediately — progress shows in the app's caption HUD. Blocking here
        // would stall the agent turn (and trip its idle timeout) for no benefit.
        editor.startCaptionGeneration(for: request)
        return .ok("Started generating captions in the background. Poll get_caption_status until status is 'completed' (or 'failed') before relying on the caption track or making further edits.")
    }

    /// Read-only progress of the background caption job started by add_captions.
    func getCaptionStatus(_ editor: EditorViewModel) -> ToolResult {
        let obj: [String: Any]
        if let job = editor.captionJob {
            if let err = job.errorMessage {
                obj = ["status": "failed", "message": err]
            } else {
                obj = ["status": "in_progress", "completed": job.completed, "total": job.total, "label": job.label]
            }
        } else if let added = editor.lastCaptionResult {
            obj = ["status": "completed", "captionsAdded": added]
        } else {
            obj = ["status": "idle"]
        }
        return .ok(Self.jsonString(obj) ?? #"{"status":"idle"}"#)
    }

    private func addCaptions(fromSubtitle mediaRef: String, editor: EditorViewModel) async throws -> ToolResult {
        guard let asset = editor.mediaAssets.first(where: { $0.id == mediaRef }) else {
            throw ToolError("add_captions: media asset not found: \(mediaRef)")
        }
        guard asset.type == .subtitle else {
            throw ToolError("add_captions: '\(mediaRef)' is \(asset.type.rawValue), not a subtitle file. Omit subtitleMediaRef to caption spoken audio.")
        }
        guard let url = editor.mediaResolver.resolveURL(for: asset.id) else {
            throw ToolError("add_captions: the subtitle file for '\(mediaRef)' is offline.")
        }
        let snapshot = timelineSnapshot(editor)
        do {
            let ids = try await editor.importCaptions(from: url)
            guard !ids.isEmpty else { throw ToolError("The subtitle file contains no captions.") }
            return mutationResult(editor, since: snapshot)
        } catch let error as SubtitleFileParser.ParseError {
            throw ToolError("add_captions: \(error.localizedDescription)")
        }
    }

    private func captionLimit(_ key: String, from args: [String: Any]) throws -> Int? {
        guard args.keys.contains(key) else { return nil }
        guard let value = exactJSONInt(args[key]), value >= 1 else {
            throw ToolError("add_captions: \(key) must be an integer >= 1.")
        }
        return value
    }
}
