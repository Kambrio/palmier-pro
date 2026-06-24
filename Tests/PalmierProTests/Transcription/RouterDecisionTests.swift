import Testing
@testable import PalmierPro

struct RouterDecisionTests {
    @Test func alwaysAppleAlwaysPicksApple() throws {
        #expect(try TranscriptionRouter.decide(mode: .alwaysApple, appleSupportsLanguage: false, whisperModelAvailable: true) == .apple)
        #expect(try TranscriptionRouter.decide(mode: .alwaysApple, appleSupportsLanguage: true, whisperModelAvailable: false) == .apple)
    }

    @Test func alwaysWhisperPicksWhisperWhenModelPresent() throws {
        #expect(try TranscriptionRouter.decide(mode: .alwaysWhisper, appleSupportsLanguage: true, whisperModelAvailable: true) == .whisper)
    }

    @Test func alwaysWhisperThrowsWithoutModel() {
        #expect(throws: TranscriptionError.self) {
            try TranscriptionRouter.decide(mode: .alwaysWhisper, appleSupportsLanguage: true, whisperModelAvailable: false)
        }
    }

    @Test func automaticPrefersAppleWhenSupported() throws {
        #expect(try TranscriptionRouter.decide(mode: .automatic, appleSupportsLanguage: true, whisperModelAvailable: true) == .apple)
    }

    @Test func automaticFallsBackToWhisperWhenUnsupported() throws {
        #expect(try TranscriptionRouter.decide(mode: .automatic, appleSupportsLanguage: false, whisperModelAvailable: true) == .whisper)
    }

    @Test func automaticThrowsWhenUnsupportedAndNoModel() {
        #expect(throws: TranscriptionError.self) {
            try TranscriptionRouter.decide(mode: .automatic, appleSupportsLanguage: false, whisperModelAvailable: false)
        }
    }
}
