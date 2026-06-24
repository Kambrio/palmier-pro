import Foundation

/// Backend-neutral transcription shape produced by WhisperKitRunner. Deliberately
/// uses Palmier-owned names so no file mapping into TranscriptionResult needs to
/// import WhisperKit (whose TranscriptionResult/TranscriptionSegment names collide).
struct RawWord: Sendable { let text: String; let start: Double?; let end: Double? }
struct RawSegment: Sendable { let text: String; let start: Double; let end: Double; let words: [RawWord] }
struct RawTranscript: Sendable { let detectedLanguage: String?; let segments: [RawSegment] }

enum WhisperTranscriptMapper {
    /// Whisper special/timestamp tokens (`<|startoftranscript|>`, `<|ru|>`, `<|0.00|>`, …)
    /// can survive into segment/word text; strip any `<|…|>` and collapse the gap.
    static func cleaned(_ s: String) -> String {
        let stripped = s.replacing(/<\|[^|]*\|>/, with: " ")
        return stripped.replacing(/[ \t]+/, with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func map(_ raw: RawTranscript, requestedLanguage: String?) -> TranscriptionResult {
        var words: [TranscriptionWord] = []
        var segments: [TranscriptionSegment] = []
        var fullText = ""

        for seg in raw.segments {
            let segText = cleaned(seg.text)
            if !segText.isEmpty {
                segments.append(TranscriptionSegment(text: segText, start: seg.start, end: seg.end))
                fullText += (fullText.isEmpty ? "" : " ") + segText
            }
            for w in seg.words {
                let t = cleaned(w.text)
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
