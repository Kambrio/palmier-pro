import Foundation

/// Per-asset sidecar for whole-clip and audio-chunk embeddings, JSON beside EmbeddingStore files.
struct ClipEmbedStore {
    struct AudioChunk: Codable, Equatable, Sendable {
        let start: Double
        let end: Double
        let vector: [Float]
    }

    struct Record: Codable, Equatable, Sendable {
        let model: String
        let modelVersion: Int
        var clipVector: [Float]?
        var audio: [AudioChunk]
        var transcriptText: String?
        var transcriptVector: [Float]?
    }

    static func url(forKey key: String) -> URL {
        EmbeddingStore.directory.appendingPathComponent("\(key).clipembed.json")
    }

    static func load(key: String) -> Record? {
        guard let data = try? Data(contentsOf: url(forKey: key)) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    static func save(_ record: Record, key: String) throws {
        let data = try JSONEncoder().encode(record)
        try FileManager.default.createDirectory(at: EmbeddingStore.directory, withIntermediateDirectories: true)
        try data.write(to: url(forKey: key), options: .atomic)
    }

    static func remove(key: String) {
        try? FileManager.default.removeItem(at: url(forKey: key))
    }

    static func isCurrent(key: String, model: String, modelVersion: Int) -> Bool {
        guard let record = load(key: key) else { return false }
        return record.model == model && record.modelVersion == modelVersion
    }
}
