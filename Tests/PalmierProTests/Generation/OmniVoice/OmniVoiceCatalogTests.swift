import Foundation
import Testing
@testable import PalmierPro

@Suite("OmniVoiceCatalog")
struct OmniVoiceCatalogTests {

    @Test func modelHasExpectedShape() {
        let m = OmniVoiceCatalog.model
        #expect(m.id == OmniVoiceCatalog.modelId)
        #expect(m.category == .tts)
        #expect(m.supportsStyleInstructions)
        #expect(m.inputs == [.text])
        #expect(m.minPromptLength >= 1)
    }

    @Test func modelIdIsStable() {
        #expect(OmniVoiceCatalog.modelId == "omnivoice-local")
    }

    @MainActor
    @Test func catalogIncludesOmniVoiceOffline() {
        // No Convex configured in tests → audio comes only from local registration.
        let audio = ModelCatalog.shared.audio
        #expect(audio.contains { $0.id == OmniVoiceCatalog.modelId })
        if case .audio(let m)? = ModelCatalog.shared.byId[OmniVoiceCatalog.modelId] {
            #expect(m.id == OmniVoiceCatalog.modelId)
        } else {
            Issue.record("OmniVoice model not in byId")
        }
    }
}
