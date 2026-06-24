import Foundation

struct WhisperBackend: TranscriptionBackend {
    func transcribe(fileURL: URL, language: Locale?, censorProfanity: Bool) async throws -> TranscriptionResult {
        // censorProfanity has no Whisper equivalent — ignored by design (see spec).
        let langCode = language?.language.languageCode?.identifier
        let modelId = await MainActor.run { WhisperModelManager.shared.activeModelId }
        Log.transcription.notice(
            "whisper transcribe start lang=\(langCode ?? "auto") model=\(modelId)",
            telemetry: "Whisper transcription started",
            data: ["language": langCode ?? "auto", "modelId": modelId]
        )
        let raw: RawTranscript
        do {
            raw = try await WhisperModelManager.shared.transcribe(audioPath: fileURL.path, language: langCode)
        } catch {
            Log.transcription.warning(
                "whisper transcribe failed model=\(modelId) error=\(error.localizedDescription)",
                telemetry: "Whisper transcription failed",
                data: ["modelId": modelId, "error": error.localizedDescription]
            )
            throw error
        }
        let result = WhisperTranscriptMapper.map(raw, requestedLanguage: langCode)
        Log.transcription.notice(
            "whisper transcribe ok textChars=\(result.text.count) words=\(result.words.count) segments=\(result.segments.count) lang=\(result.language ?? "?") model=\(modelId)",
            telemetry: "Whisper transcription finished",
            data: [
                "textChars": result.text.count,
                "words": result.words.count,
                "segments": result.segments.count,
                "language": result.language ?? "unknown",
                "modelId": modelId
            ]
        )
        return result
    }

    func supportedLanguages() async -> Set<String> { WhisperModelCatalog.languages }

    /// Best-effort language detection for the router's auto path.
    func detectLanguage(fileURL: URL) async throws -> String? {
        try await WhisperModelManager.shared.detectLanguage(audioPath: fileURL.path)
    }
}
