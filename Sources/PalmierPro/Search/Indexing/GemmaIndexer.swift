import AVFoundation
import CoreGraphics
import Foundation

enum GemmaIndexer {
    static let modelName = "embeddinggemma-2"
    static let modelVersion = 1

    static func indexKey(sourceURL: URL?, fallbackURL: URL) -> String? {
        if let sourceURL, let key = EmbeddingStore.key(for: sourceURL) { return key }
        return EmbeddingStore.key(for: fallbackURL)
    }

    static func needsIndex(key: String) -> Bool {
        let framesCurrent = EmbeddingStore.isCurrent(
            key: key, model: modelName, modelVersion: modelVersion,
            samplerVersion: FrameSampler.samplerVersion)
        let clipCurrent = ClipEmbedStore.isCurrent(key: key, model: modelName, modelVersion: modelVersion)
        return !(framesCurrent && clipCurrent)
    }

    static func indexVideo(
        indexURL: URL,
        key: String,
        duration: Double,
        embedder: any GemmaEmbedding,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        guard needsIndex(key: key) else { return }

        var times: [Double] = []
        var shotStarts: [Double] = []
        var shotIndices: [Int] = []
        var vectors: [Float] = []

        for try await frame in FrameSampler.frames(url: indexURL, duration: duration) {
            try Task.checkCancellation()
            try await ExportQueue.shared.waitWhileExportActive()
            if frame.isNewShot { shotStarts.append(shotStarts.isEmpty ? 0 : frame.time) }
            vectors += try await embedder.embedImages([frame.image])[0]
            times.append(frame.time)
            shotIndices.append(shotStarts.count - 1)
            if duration > 0 { progress?(min(frame.time / duration, 0.9)) }
        }
        try Task.checkCancellation()

        let rows = zip(times, shotIndices).map { time, shot in
            EmbeddingStore.Row(
                time: time,
                shotStart: shotStarts[shot],
                shotEnd: shot + 1 < shotStarts.count ? shotStarts[shot + 1] : duration)
        }
        let header = EmbeddingStore.Header(
            model: modelName, modelVersion: modelVersion,
            samplerVersion: FrameSampler.samplerVersion,
            dim: embedder.dim, count: rows.count)
        try EmbeddingStore.save(header: header, rows: rows, vectors: vectors, key: key)

        let clips = try await clipFrames(url: indexURL, duration: duration)
        let clipVector = clips.isEmpty ? nil
            : try await embedder.embedVideo(clips.map(\.image))
        try ClipEmbedStore.save(
            .init(model: modelName, modelVersion: modelVersion, clipVector: clipVector, audio: []),
            key: key)
        progress?(1)
    }

    static func indexAudio(url: URL, key: String, embedder: any GemmaEmbedding) async throws {
        // Skip only when this record's audio pass already ran; a record from indexVideo (audio: []) still merges.
        let existing = ClipEmbedStore.load(key: key)
        if let existing,
           existing.model == modelName, existing.modelVersion == modelVersion,
           !existing.audio.isEmpty {
            return
        }
        let chunks = try await AudioPCMExtractor.mono16kChunks(url: url)
        var embedded: [ClipEmbedStore.AudioChunk] = []
        for chunk in chunks {
            try Task.checkCancellation()
            let vector = try await embedder.embedAudio(chunk.samples, sampleRate: 16_000)
            embedded.append(.init(start: chunk.start, end: chunk.start + Double(chunk.samples.count) / 16_000.0, vector: vector))
        }
        try ClipEmbedStore.save(
            .init(model: modelName, modelVersion: modelVersion, clipVector: existing?.clipVector, audio: embedded),
            key: key)
    }

    /// Uniform ≤ maxFrames samples at `fps` for the whole-clip embedding.
    static func clipFrames(url: URL, duration: Double, fps: Double = 1, maxFrames: Int = 32) async throws -> [(time: Double, image: CGImage)] {
        guard duration > 0 else { return [] }
        let count = min(maxFrames, max(1, Int(duration * fps)))
        let stride = duration / Double(count)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 512, height: 512)
        let tolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        let times = (0..<count).map { CMTime(seconds: Double($0) * stride + stride / 2, preferredTimescale: 600) }
        var out: [(Double, CGImage)] = []
        for await result in generator.images(for: times) {
            try Task.checkCancellation()
            if case .success(_, let image, let actual) = result {
                out.append((actual.seconds, image))
            }
        }
        return out.map { (time: $0.0, image: $0.1) }
    }
}
