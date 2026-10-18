import Testing
import Foundation
@testable import PalmierPro

@Suite struct GemmaEmbeddingTests {
    @Test func truncateSlicesAndRenormalizes() {
        let v = (0..<768).map { Float($0) / 1000 }
        let norm = { (x: [Float]) in sqrt(x.reduce(0) { $0 + $1 * $1 }) }
        let t = GemmaVector.truncate(v, to: 256)
        #expect(t.count == 256)
        #expect(abs(norm(t) - 1) < 1e-5)
        #expect(abs(t[0] - v[0] / norm(v)) < 1e-6) // same direction, unit length
    }

    @Test func truncateRejectsBadDim() {
        #expect(GemmaVector.truncate([0.5, 0.5], to: 0).isEmpty)
        #expect(GemmaVector.truncate([0.5, 0.5], to: 4).isEmpty)
    }

    @Test func stubIsDeterministicAndNormalized() async throws {
        let stub = StubGemmaEmbedding()
        let a = try await stub.embedText("night market", task: .searchQuery)
        let b = try await stub.embedText("night market", task: .searchQuery)
        #expect(a.count == stub.dim)
        #expect(a == b)
        #expect(abs(sqrt(a.reduce(0) { $0 + $1 * $1 }) - 1) < 1e-5)
    }

    @Test func stubDistinctInputsDiffer() async throws {
        let stub = StubGemmaEmbedding()
        let a = try await stub.embedText("rain", task: .document)
        let b = try await stub.embedText("sunshine", task: .document)
        #expect(a != b)
    }
}
