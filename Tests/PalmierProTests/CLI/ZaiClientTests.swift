import Foundation
import Testing
@testable import PalmierPro

@Suite("ZaiClient + request builder")
struct ZaiClientTests {

    @Test func buildAcceptsRawModelString() {
        let body = AnthropicRequestBody.build(
            model: "glm-4.6", maxTokens: 8, system: "s", tools: [], messages: [])
        #expect(body["model"] as? String == "glm-4.6")
        #expect(body["max_tokens"] as? Int == 8)
        #expect(body["stream"] as? Bool == true)
    }
}
