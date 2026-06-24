import Foundation

/// Backend-neutral transcription shape produced by WhisperKitRunner. Deliberately
/// uses Palmier-owned names so no file mapping into TranscriptionResult needs to
/// import WhisperKit (whose TranscriptionResult/TranscriptionSegment names collide).
struct RawWord: Sendable { let text: String; let start: Double?; let end: Double? }
struct RawSegment: Sendable { let text: String; let start: Double; let end: Double; let words: [RawWord] }
struct RawTranscript: Sendable { let detectedLanguage: String?; let segments: [RawSegment] }

enum WhisperTranscriptMapper {
    static func map(_ raw: RawTranscript, requestedLanguage: String?) -> TranscriptionResult {
        var words: [TranscriptionWord] = []
        var segments: [TranscriptionSegment] = []
        var fullText = ""

        for seg in raw.segments {
            let segText = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !segText.isEmpty {
                segments.append(TranscriptionSegment(text: segText, start: seg.start, end: seg.end))
                fullText += (fullText.isEmpty ? "" : " ") + segText
            }
            for w in seg.words {
                let t = w.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.isEmpty { continue }
                words.append(TranscriptionWord(text: t, start: w.start, end: w.end))
            }
        }

        return TranscriptionResult(
            text: fullText,
            language: requestedLanguage ?? raw.detectedLanguage,
            words: words,
            segments: segments
        )
    }
}
