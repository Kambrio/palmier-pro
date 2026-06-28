import Foundation
import Testing
@testable import PalmierPro

@Suite("GenerationInput language")
struct GenerationInputCodableTests {

    @Test func languageRoundTrips() throws {
        var input = GenerationInput(prompt: "hi", model: "m", duration: 0, aspectRatio: "")
        input.language = "Spanish"
        let data = try JSONEncoder().encode(input)
        let decoded = try JSONDecoder().decode(GenerationInput.self, from: data)
        #expect(decoded.language == "Spanish")
    }

    @Test func languageDefaultsNil() {
        let input = GenerationInput(prompt: "hi", model: "m", duration: 0, aspectRatio: "")
        #expect(input.language == nil)
    }
}
