import Testing
import Foundation
@testable import PalmierPro

@Suite struct ClipEmbedStoreTests {
    @Test func roundTrip() throws {
        let key = "test-clip-\(UUID().uuidString.prefix(8))"
        defer { ClipEmbedStore.remove(key: key) }
        let record = ClipEmbedStore.Record(
            model: "embeddinggemma-2", modelVersion: 1,
            clipVector: [0.1, 0.2, 0.3],
            audio: [.init(start: 0, end: 30, vector: [0.4, 0.5])],
            transcriptText: "a person walks along the shore",
            transcriptVector: [0.6, 0.7, 0.8])
        try ClipEmbedStore.save(record, key: key)
        let loaded = ClipEmbedStore.load(key: key)
        #expect(loaded == record)
    }

    @Test func legacyJSONWithoutTranscriptFieldsDecodesNil() throws {
        let key = "test-legacy-\(UUID().uuidString.prefix(8))"
        defer { ClipEmbedStore.remove(key: key) }
        let legacy = #"{"model":"embeddinggemma-2","modelVersion":1,"clipVector":[0.1,0.2],"audio":[{"start":0,"end":30,"vector":[0.4]}]}"#
        try FileManager.default.createDirectory(at: EmbeddingStore.directory, withIntermediateDirectories: true)
        try Data(legacy.utf8).write(to: ClipEmbedStore.url(forKey: key))
        let loaded = ClipEmbedStore.load(key: key)
        #expect(loaded?.clipVector == [0.1, 0.2])
        #expect(loaded?.audio == [.init(start: 0, end: 30, vector: [0.4])])
        #expect(loaded?.transcriptText == nil)
        #expect(loaded?.transcriptVector == nil)
    }

    @Test func isCurrentChecksModelIdentity() throws {
        let key = "test-cur-\(UUID().uuidString.prefix(8))"
        defer { ClipEmbedStore.remove(key: key) }
        #expect(!ClipEmbedStore.isCurrent(key: key, model: "embeddinggemma-2", modelVersion: 1))
        try ClipEmbedStore.save(.init(model: "embeddinggemma-2", modelVersion: 1, clipVector: nil, audio: []), key: key)
        #expect(ClipEmbedStore.isCurrent(key: key, model: "embeddinggemma-2", modelVersion: 1))
        #expect(!ClipEmbedStore.isCurrent(key: key, model: "embeddinggemma-2", modelVersion: 2))
    }

    @Test func missingLoadReturnsNil() {
        #expect(ClipEmbedStore.load(key: "no-such-key") == nil)
    }
}
