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

    @Test func requestTargetsZaiAnthropicEndpointWithBearerAuth() throws {
        let msg = AnthropicMessage(role: .user, content: [["type": "text", "text": "hi"]])
        let req = try ZaiClient.makeRequest(
            apiKey: "k", model: "glm-4.6", maxTokens: 8,
            system: "s", tools: [], messages: [msg])
        #expect(req.url == ZaiClient.endpoint)
        #expect(req.httpMethod == "POST")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer k")
        #expect(req.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        // z.ai uses Bearer auth, never the Anthropic x-api-key header.
        #expect(req.value(forHTTPHeaderField: "x-api-key") == nil)
        #expect(req.value(forHTTPHeaderField: "accept") == "text/event-stream")
    }

    @Test func requestBodyCarriesGlmModel() throws {
        let req = try ZaiClient.makeRequest(
            apiKey: "k", model: ZaiModel.glm46.rawValue, maxTokens: 8,
            system: "s", tools: [], messages: [])
        let body = try #require(req.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "glm-4.6")
        #expect(json["stream"] as? Bool == true)
    }
}
