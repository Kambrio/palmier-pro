import Testing
@testable import PalmierPro

struct WhisperTranscriptMapperTests {
    private func sample() -> RawTranscript {
        RawTranscript(
            detectedLanguage: "ru",
            segments: [
                RawSegment(text: "  Привет мир  ", start: 0.0, end: 1.5, words: [
                    RawWord(text: "Привет", start: 0.0, end: 0.7),
                    RawWord(text: "  мир ", start: 0.7, end: 1.5),
                ]),
                RawSegment(text: "  ", start: 1.5, end: 1.6, words: []),  // blank → dropped
            ]
        )
    }

    @Test func mapsSegmentsTrimmedAndDropsBlanks() {
        let r = WhisperTranscriptMapper.map(sample(), requestedLanguage: nil)
        #expect(r.segments.count == 1)
        #expect(r.segments[0].text == "Привет мир")
        #expect(r.segments[0].start == 0.0)
        #expect(r.segments[0].end == 1.5)
    }

    @Test func mapsWordsTrimmedAndMonotonic() {
        let r = WhisperTranscriptMapper.map(sample(), requestedLanguage: nil)
        #expect(r.words.map(\.text) == ["Привет", "мир"])
        for i in 1..<r.words.count {
            #expect((r.words[i].start ?? 0) >= (r.words[i-1].start ?? 0))
        }
    }

    @Test func prefersRequestedLanguageOverDetected() {
        let r = WhisperTranscriptMapper.map(sample(), requestedLanguage: "uk")
        #expect(r.language == "uk")
    }

    @Test func fallsBackToDetectedLanguage() {
        let r = WhisperTranscriptMapper.map(sample(), requestedLanguage: nil)
        #expect(r.language == "ru")
    }
}
