import Foundation
import Testing
@testable import PalmierPro

@Suite("OmniVoiceGenerationProvider failure message")
struct OmniVoiceGenerationProviderTests {

    /// When the worker finishes with zero output, the thrown error must include the worker's
    /// segment errors verbatim — otherwise a rejected `instruct` (e.g. "Unsupported instruct
    /// items…") is hidden behind a generic "Worker produced no audio" and the user sees empty audio.
    @Test func noAudioMessageIncludesSegmentErrors() {
        let msg = OmniVoiceGenerationProvider.noAudioFailureMessage(errors: [
            "Unsupported instruct items found in female, Russian native speaker, warm"
        ])
        #expect(msg.contains("Worker produced no audio"))
        #expect(msg.contains("Unsupported instruct items"), "segment error must surface: \(msg)")
    }

    @Test func noAudioMessageWithoutErrorsIsGeneric() {
        let msg = OmniVoiceGenerationProvider.noAudioFailureMessage(errors: [])
        #expect(msg == "Worker produced no audio.")
    }
}
