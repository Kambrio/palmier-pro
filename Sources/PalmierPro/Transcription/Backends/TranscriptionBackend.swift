import Foundation

/// How transcription chooses between the Apple and Whisper backends.
enum TranscriptionEngineMode: String, CaseIterable, Sendable {
    case automatic      // Apple for supported languages, Whisper otherwise
    case alwaysApple
    case alwaysWhisper

    var displayName: String {
        switch self {
        case .automatic: "Automatic"
        case .alwaysApple: "Always Apple"
        case .alwaysWhisper: "Always Whisper"
        }
    }
}

/// Which concrete backend the router resolved to.
enum TranscriptionBackendChoice: Sendable { case apple, whisper }

/// A pluggable speech-to-text engine. Both backends produce the same value type
/// so every consumer (TranscriptCache, captions, get_transcript, search) is unchanged.
protocol TranscriptionBackend: Sendable {
    /// Transcribe a decoded audio file (16 kHz mono PCM .caf produced by the router).
    /// `language` is a BCP-47 *language* (region optional); nil means auto.
    func transcribe(fileURL: URL, language: Locale?, censorProfanity: Bool) async throws -> TranscriptionResult

    /// BCP-47 language codes (e.g. "en", "ru") this backend can handle.
    func supportedLanguages() async -> Set<String>
}
