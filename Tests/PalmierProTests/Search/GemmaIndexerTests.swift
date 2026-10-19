import Testing
import Foundation
import AVFoundation
@testable import PalmierPro

@Suite struct GemmaIndexerTests {
    @Test func indexKeyPrefersSourceWhenReadable() throws {
        let source = URL(fileURLWithPath: #filePath) // exists, has attrs
        let proxy = URL(fileURLWithPath: "/nonexistent/proxy.mov")
        let a = GemmaIndexer.indexKey(sourceURL: source, fallbackURL: proxy)
        let b = GemmaIndexer.indexKey(sourceURL: nil, fallbackURL: source)
        #expect(a == b) // same file identity
        let c = GemmaIndexer.indexKey(sourceURL: URL(fileURLWithPath: "/gone/a.mov"),
                                      fallbackURL: source)
        #expect(c == b) // unreadable source falls back to index URL
    }

    @Test func indexVideoWritesFrameRowsAndClipVector() async throws {
        let fixture = try TestMedia.makeVideo(seconds: 3, name: "gemma-index-video")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let key = GemmaIndexer.indexKey(sourceURL: nil, fallbackURL: fixture)!
        defer { ClipEmbedStore.remove(key: key); try? FileManager.default.removeItem(at: EmbeddingStore.diskURL(key)) }

        try await GemmaIndexer.indexVideo(
            indexURL: fixture, key: key, duration: 3, embedder: StubGemmaEmbedding(), progress: nil)

        let frames = try EmbeddingStore.load(key: key)
        #expect(frames.header.model == GemmaIndexer.modelName)
        #expect(frames.header.modelVersion == GemmaIndexer.modelVersion)
        #expect(frames.header.dim == 768)
        #expect(frames.header.count > 0)
        let record = ClipEmbedStore.load(key: key)
        #expect(record?.clipVector?.count == 768)
        #expect(GemmaIndexer.needsIndex(key: key) == false)
    }

    @Test func indexAudioWritesChunks() async throws {
        let fixture = try TestMedia.makeWAV(seconds: 2, sampleRate: 16_000, name: "gemma-index-audio")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let key = GemmaIndexer.indexKey(sourceURL: nil, fallbackURL: fixture)!
        defer { ClipEmbedStore.remove(key: key) }
        try await GemmaIndexer.indexAudio(url: fixture, key: key, embedder: StubGemmaEmbedding())
        let record = ClipEmbedStore.load(key: key)
        #expect(record?.audio.isEmpty == false)
        #expect(record?.audio.allSatisfy { $0.vector.count == 768 } == true)
    }

    @Test func indexAudioAfterIndexVideoMergesChunks() async throws {
        let video = try TestMedia.makeVideo(seconds: 4, name: "gemma-merge-video")
        let audio = try TestMedia.makeWAV(seconds: 2, sampleRate: 16_000, name: "gemma-merge-audio")
        defer { try? FileManager.default.removeItem(at: video); try? FileManager.default.removeItem(at: audio) }
        let vKey = GemmaIndexer.indexKey(sourceURL: nil, fallbackURL: video)!
        defer { ClipEmbedStore.remove(key: vKey); try? FileManager.default.removeItem(at: EmbeddingStore.diskURL(vKey)) }

        try await GemmaIndexer.indexVideo(indexURL: video, key: vKey, duration: 4, embedder: StubGemmaEmbedding())
        try await GemmaIndexer.indexAudio(url: audio, key: vKey, embedder: StubGemmaEmbedding())

        let record = ClipEmbedStore.load(key: vKey)
        #expect(record?.audio.isEmpty == false)
        #expect(record?.clipVector != nil)
    }

    @Test func needsAudioPassFlagsCancelledAudioWindow() async throws {
        let video = try TestMedia.makeVideo(seconds: 3, name: "gemma-audio-pass")
        let audio = try TestMedia.makeWAV(seconds: 2, sampleRate: 16_000, name: "gemma-audio-pass-src")
        defer { try? FileManager.default.removeItem(at: video); try? FileManager.default.removeItem(at: audio) }
        let key = GemmaIndexer.indexKey(sourceURL: nil, fallbackURL: video)!
        defer { ClipEmbedStore.remove(key: key); try? FileManager.default.removeItem(at: EmbeddingStore.diskURL(key)) }

        #expect(GemmaIndexer.needsAudioPass(key: key, hasAudio: true)) // no record yet
        #expect(!GemmaIndexer.needsAudioPass(key: key, hasAudio: false))

        try await GemmaIndexer.indexVideo(indexURL: video, key: key, duration: 3, embedder: StubGemmaEmbedding())
        #expect(!GemmaIndexer.needsIndex(key: key)) // both stores current after indexVideo
        #expect(GemmaIndexer.needsAudioPass(key: key, hasAudio: true)) // but audio pass cancelled

        try await GemmaIndexer.indexAudio(url: audio, key: key, embedder: StubGemmaEmbedding())
        #expect(!GemmaIndexer.needsAudioPass(key: key, hasAudio: true))
    }
}

@Suite struct AudioPCMExtractorTests {
    @Test func chunksAreMono16kAndBounded() async throws {
        let fixture = try TestMedia.makeWAV(seconds: 2, sampleRate: 48_000, name: "gemma-pcm")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let chunks = try await AudioPCMExtractor.mono16kChunks(url: fixture, chunkSeconds: 1)
        #expect(chunks.count == 2)
        for (i, chunk) in chunks.enumerated() {
            #expect(abs(chunk.start - Double(i)) < 0.01)
            #expect(chunk.samples.count <= 16_000)
        }
    }
}
