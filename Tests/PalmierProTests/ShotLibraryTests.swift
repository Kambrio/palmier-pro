import Testing
import Foundation
@testable import PalmierPro

struct ShotLibraryModelTests {
    @Test func roundTripsThroughJSON() throws {
        var entry = ShotEntry(assetId: "asset-1")
        entry.displayName = "Founder interview"
        entry.summary = "Medium shot, 1 person, office."
        entry.labels = ["key", "interview"]
        entry.shotSize = .mediumFull
        entry.people = 1
        entry.hasSpeech = true
        entry.transcriptExcerpt = "We started this in 2024"
        entry.durationSeconds = 12.5
        entry.personGroup = 0
        var frame = ShotFrame(position: .median, timeSeconds: 6.25)
        frame.sceneLabels = ["office", "indoor"]
        frame.objects = ["person", "laptop"]
        frame.shotSize = .mediumFull
        frame.people = 1
        frame.description = "A person at a desk."
        frame.thumbnailRelPath = "media/shots/asset-1.median.jpg"
        entry.frames = [frame]

        var library = ShotLibrary()
        library.upsert(entry)

        let data = try JSONEncoder().encode(library)
        let decoded = try JSONDecoder().decode(ShotLibrary.self, from: data)
        let back = try #require(decoded.entry(assetId: "asset-1"))
        #expect(back.displayName == "Founder interview")
        #expect(back.labels == ["key", "interview"])
        #expect(back.shotSize == .mediumFull)
        #expect(back.frames.first?.objects == ["person", "laptop"])
        #expect(back.isKey)
        #expect(!back.isSkipped)
    }

    @Test func decodesToleratesMissingFields() throws {
        // An older / minimal payload must still decode (default-tolerant).
        let json = #"{"version":1,"entries":[{"assetId":"x","summary":"s"}]}"#
        let decoded = try JSONDecoder().decode(ShotLibrary.self, from: Data(json.utf8))
        let entry = try #require(decoded.entry(assetId: "x"))
        #expect(entry.summary == "s")
        #expect(entry.labels.isEmpty)
        #expect(entry.frames.isEmpty)
        #expect(entry.shotSize == nil)
    }

    @Test func decodesLegacyShotSizeStrings() throws {
        // Older projects stored the legacy `medium` size and the still-current raw values.
        let json = #"""
        {"version":1,"entries":[
            {"assetId":"legacy","shotSize":"medium","frames":[{"position":"median","timeSeconds":1,"shotSize":"medium"}]},
            {"assetId":"current","shotSize":"wide","frames":[{"position":"median","timeSeconds":1,"shotSize":"closeUp"}]}
        ]}
        """#
        let decoded = try JSONDecoder().decode(ShotLibrary.self, from: Data(json.utf8))
        let legacy = try #require(decoded.entry(assetId: "legacy"))
        #expect(legacy.shotSize == .mediumFull)
        #expect(legacy.frames.first?.shotSize == .mediumFull)
        let current = try #require(decoded.entry(assetId: "current"))
        #expect(current.shotSize == .wide)
        #expect(current.frames.first?.shotSize == .closeUp)
        #expect(ShotSize.parse("medium") == .mediumFull)
        #expect(ShotSize.parse("bogus") == nil)
    }

    @Test func upsertReplacesAndRemoveDrops() {
        var library = ShotLibrary()
        var a = ShotEntry(assetId: "a"); a.summary = "first"
        library.upsert(a)
        a.summary = "second"
        library.upsert(a)
        #expect(library.entries.count == 1)
        #expect(library.entry(assetId: "a")?.summary == "second")
        library.remove(assetId: "a")
        #expect(library.entries.isEmpty)
    }

    @Test func stalenessTracksSourceSignature() {
        var entry = ShotEntry(assetId: "a")
        entry.sourceSig = "sig-1"
        #expect(!entry.isStale(against: "sig-1"))
        #expect(entry.isStale(against: "sig-2"))
        #expect(!entry.isStale(against: nil))   // unknown current sig → don't force re-analysis
    }

    @Test func labelNormalizationIsCanonical() {
        #expect(ShotLabels.normalize("  KEY ") == "key")
        #expect(ShotLabels.normalize("B  Roll") == "b roll")
        #expect(ShotLabels.def("key")?.title == "Key")
    }
}

@MainActor
struct ShotDisplayNameIndexTests {
    @Test func indexReflectsLibraryAndExcludesBlanks() {
        let editor = EditorViewModel()
        var lib = ShotLibrary()
        var a = ShotEntry(assetId: "asset-a"); a.displayName = "Founder interview"
        var b = ShotEntry(assetId: "asset-b"); b.displayName = "   "   // blank → excluded
        var c = ShotEntry(assetId: "asset-c")                          // nil name → excluded
        lib.entries = [a, b, c]
        editor.shotLibrary = lib   // didSet rebuilds the O(1) index

        #expect(editor.shotDisplayNameByAsset["asset-a"] == "Founder interview")
        #expect(editor.shotDisplayNameByAsset["asset-b"] == nil)
        #expect(editor.shotDisplayNameByAsset["asset-c"] == nil)

        // Mutating an entry's name through the library keeps the index in sync.
        editor.shotLibrary.entries[2].displayName = "Sunset b-roll"
        #expect(editor.shotDisplayNameByAsset["asset-c"] == "Sunset b-roll")
    }
}

struct EmbeddingCodecTests {
    @Test func encodeDecodeRoundTripsApproximately() throws {
        let vector: [Float] = [0.1, -0.5, 0.9, 0.0, 0.42]
        let encoded = EmbeddingCodec.encode(vector)
        let decoded = try #require(EmbeddingCodec.decode(encoded))
        #expect(decoded.count == vector.count)
        for (a, b) in zip(vector, decoded) {
            #expect(abs(a - b) < 0.01)   // Float16 precision
        }
    }

    @Test func cosineMatchesIdenticalAndDiffersOrthogonal() throws {
        let a: [Float] = [1, 0, 0]
        let b: [Float] = [1, 0, 0]
        let c: [Float] = [0, 1, 0]
        #expect(try #require(EmbeddingCodec.cosine(a, b)) > 0.99)
        #expect(abs(try #require(EmbeddingCodec.cosine(a, c))) < 0.01)
        #expect(EmbeddingCodec.cosine(a, [1, 0]) == nil)   // mismatched length
    }
}

struct ShotIdentityClusteringTests {
    @Test func groupsSimilarEmbeddingsAndLeavesSingletonsNil() {
        // Two near-identical vectors (same person) + one distinct singleton.
        let p1: [Float] = [1, 0, 0, 0]
        let p1b: [Float] = [0.98, 0.02, 0, 0]
        let other: [Float] = [0, 0, 1, 0]
        let groups = ShotIdentityClustering.groups(for: [p1, p1b, other, nil], threshold: 0.82)
        #expect(groups[0] != nil)
        #expect(groups[0] == groups[1])   // same person → same group
        #expect(groups[2] == nil)         // singleton identity → no shared group
        #expect(groups[3] == nil)         // no embedding → nil
    }

    @Test func allDistinctYieldsNoGroups() {
        let groups = ShotIdentityClustering.groups(
            for: [[1, 0, 0], [0, 1, 0], [0, 0, 1]], threshold: 0.82)
        #expect(groups.allSatisfy { $0 == nil })
    }
}
