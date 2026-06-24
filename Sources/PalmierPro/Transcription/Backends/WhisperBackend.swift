import Foundation

struct WhisperBackend: TranscriptionBackend {
    func transcribe(fileURL: URL, language: Locale?, censorProfanity: Bool) async throws -> TranscriptionResult {
        // censorProfanity has no Whisper equivalent — ignored by design (see spec).
        let langCode = language?.language.languageCode?.identifier
        let raw = try await WhisperModelManager.shared.transcribe(audioPath: fileURL.path, language: langCode)
        return WhisperTranscriptMapper.map(raw, requestedLanguage: langCode)
    }

    func supportedLanguages() async -> Set<String> { WhisperModelCatalog.languages }

    /// Best-effort language detection for the router's auto path.
    func detectLanguage(fileURL: URL) async throws -> String? {
        try await WhisperModelManager.shared.detectLanguage(audioPath: fileURL.path)
    }
}
