import CoreGraphics
import Foundation

extension ToolExecutor {
    private static let addCaptionsAllowedKeys: Set<String> = Set([
        "style", "transform", "censorProfanity", "language", "animation", "highlightColor", "maxWords",
    ])

    func addCaptions(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.addCaptionsAllowedKeys, path: "add_captions")

        let stylePatch = try parseTextStylePatch(args, path: "add_captions")
        var style = TextStyle(fontSize: AppTheme.Caption.defaultFontSize)
        if let stylePatch { Self.applyTextStylePatch(stylePatch, to: &style) }

        var center = AppTheme.Caption.defaultCenter
        if let t = args["transform"] as? [String: Any] {
            try validateUnknownKeys(t, allowed: ["centerX", "centerY"], path: "add_captions.transform")
            if let x = t.double("centerX") { center.x = CGFloat(x) }
            if let y = t.double("centerY") { center.y = CGFloat(y) }
        }

        let animation = try parseTextAnimation(preset: args.string("animation"), highlightColor: args.string("highlightColor"), path: "add_captions") ?? TextAnimation()

        var maxWords: Int?
        if let n = args.int("maxWords") {
            guard n >= 1 else { throw ToolError("add_captions: maxWords must be >= 1 (got \(n))") }
            maxWords = n
        }

        let context = try await transcriptionContext(args, path: "add_captions") {
            await editor.captionCloudCreditCost(for: .init(autoDetect: true, provider: .cloud))
        }
        let provider = context.provider
        if provider == .cloud {
            if args.bool("censorProfanity") == true {
                throw ToolError("add_captions: censorProfanity is only available with local transcription.")
            }
        }

        let request = EditorViewModel.CaptionRequest(
            sourceClipIds: [],
            autoDetect: true,
            style: style,
            center: center,
            textCase: .auto,
            censorProfanity: args.bool("censorProfanity") ?? false,
            locale: context.preferredLocale,
            maxWords: maxWords,
            provider: provider,
            animation: animation
        )

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
}
