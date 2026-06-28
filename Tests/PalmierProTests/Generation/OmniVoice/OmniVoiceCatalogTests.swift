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
}
