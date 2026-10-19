import CoreGraphics
import Foundation

enum GemmaTask: String, Sendable {
    case searchQuery = "search result"
    case document
    case clustering
}

protocol GemmaEmbedding: AnyObject, Sendable {
    var dim: Int { get }
    func embedText(_ text: String, task: GemmaTask) async throws -> [Float]
    func embedImages(_ images: [CGImage]) async throws -> [[Float]]
    /// Ordered frames of one clip; returns a single interleaved video embedding.
    func embedVideo(_ frames: [CGImage]) async throws -> [Float]
    /// Mono PCM; `sampleRate` is the caller's rate (16 kHz nominal).
    func embedAudio(_ samples: [Float], sampleRate: Int) async throws -> [Float]
}

enum GemmaVector {
    /// Matryoshka truncation with renormalization; empty when the request is out of range.
    static func truncate(_ vector: [Float], to dim: Int) -> [Float] {
        guard dim > 0, dim < vector.count else { return [] }
        var slice = Array(vector.prefix(dim))
        let norm = sqrt(slice.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return slice }
        for i in slice.indices { slice[i] /= norm }
        return slice
    }
}

/// Deterministic stand-in: unit vector derived from a seed, stable per input.
final class StubGemmaEmbedding: GemmaEmbedding {
    let dim: Int
    init(dim: Int = 768) { self.dim = dim }

    func embedText(_ text: String, task: GemmaTask) async throws -> [Float] {
        unit(seed: UInt64(abs("\(task.rawValue)|\(text)".hashValue)))
    }
    func embedImages(_ images: [CGImage]) async throws -> [[Float]] {
        images.indices.map { unit(seed: UInt64($0) &+ 3) }
    }
    func embedVideo(_ frames: [CGImage]) async throws -> [Float] {
        unit(seed: UInt64(abs(frames.count)) &+ 11)
    }
    func embedAudio(_ samples: [Float], sampleRate: Int) async throws -> [Float] {
        unit(seed: UInt64(abs(samples.count)) &+ UInt64(bitPattern: Int64(sampleRate)))
    }

    func unit(seed: UInt64) -> [Float] {
        var state = seed == 0 ? 1 : seed
        var out = [Float](repeating: 0, count: dim)
        for i in out.indices {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            out[i] = Float(Int8(bitPattern: UInt8(truncatingIfNeeded: state >> 33))) / 127
        }
        let norm = sqrt(out.reduce(0) { $0 + $1 * $1 })
        return out.map { $0 / max(norm, 1e-9) }
    }
}
