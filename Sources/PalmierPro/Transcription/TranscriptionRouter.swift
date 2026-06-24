import Foundation

/// Pure routing decision. Language resolution / auto-detect happens in the
/// Transcription router *before* calling this; here we only branch on facts.
enum TranscriptionRouter {
    static func decide(
        mode: TranscriptionEngineMode,
        appleSupportsLanguage: Bool,
        whisperModelAvailable: Bool
    ) throws -> TranscriptionBackendChoice {
        switch mode {
        case .alwaysApple:
            return .apple
        case .alwaysWhisper:
            guard whisperModelAvailable else { throw TranscriptionError.whisperModelNotInstalled }
            return .whisper
        case .automatic:
            if appleSupportsLanguage { return .apple }
            guard whisperModelAvailable else { throw TranscriptionError.whisperModelNotInstalled }
            return .whisper
        }
    }
}
