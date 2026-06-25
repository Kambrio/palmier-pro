import CoreGraphics
import Foundation

extension ToolExecutor {
    private static let addCaptionsAllowedKeys: Set<String> = [
        "clipIds", "fontName", "fontSize", "color", "centerX", "centerY", "textCase", "censorProfanity", "language",
    ]

    func addCaptions(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.addCaptionsAllowedKeys, path: "add_captions")

        let clipIds = (args["clipIds"] as? [Any])?.compactMap { $0 as? String } ?? []

        var style = TextStyle(fontSize: AppTheme.Caption.defaultFontSize)
        if let f = args.string("fontName") { style.fontName = f }
        if let s = args.double("fontSize") { style.fontSize = s }
        if let c = try parseColorHex(args.string("color"), path: "add_captions") { style.color = c }

        var locale: Locale?
        if let lang = args.string("language") {
            let candidate = Locale(identifier: lang)
            let langCode = candidate.language.languageCode?.identifier
            let appleLangs = await Transcription.supportedLocales()
            let appleMatch = Transcription.matchLocale(candidates: [candidate], supported: appleLangs)
            let whisperOK = langCode.map { WhisperModelCatalog.languages.contains($0) } ?? false
            guard appleMatch != nil || whisperOK else {
                throw ToolError("add_captions: language '\(lang)' is not supported by Apple on-device or Whisper.")
            }
            locale = appleMatch ?? candidate
        }

        var center = AppTheme.Caption.defaultCenter
        if let x = args.double("centerX") { center.x = CGFloat(x) }
        if let y = args.double("centerY") { center.y = CGFloat(y) }

        var textCase: EditorViewModel.CaptionCase = .auto
        if let raw = args.string("textCase") {
            guard let parsed = EditorViewModel.CaptionCase(rawValue: raw) else {
                throw ToolError("add_captions: textCase must be auto, upper, or lower (got \(raw))")
            }
            textCase = parsed
        }

        let request = EditorViewModel.CaptionRequest(
            sourceClipIds: clipIds,
            autoDetect: clipIds.isEmpty,
            style: style,
            center: center,
            textCase: textCase,
            censorProfanity: args.bool("censorProfanity") ?? false,
            locale: locale
        )

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
