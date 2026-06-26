import Testing
import Foundation
@testable import PalmierPro

struct StabilizationSidecarTests {
    @Test func roundTripsTransforms() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let payload = StabSidecar(
            sourceSig: "abc123",
            fps: 30,
            frames: [.identity, StabFrameTransform(m: [1,0,0.1, 0,1,0.2, 0,0,1])]
        )
        try StabilizationSidecar.write(payload, assetId: "asset1", baseDir: dir)
        let loaded = try #require(StabilizationSidecar.read(assetId: "asset1", baseDir: dir))
        #expect(loaded.frames.count == 2)
        #expect(loaded.frames[1].m[2] == 0.1)
        #expect(loaded.sourceSig == "abc123")
    }

    @Test func staleSidecarIsRejected() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try StabilizationSidecar.write(
            StabSidecar(sourceSig: "old", fps: 30, frames: [.identity]),
            assetId: "asset1", baseDir: dir)
        #expect(StabilizationSidecar.read(assetId: "asset1", baseDir: dir, requiringSig: "new") == nil)
        #expect(StabilizationSidecar.read(assetId: "asset1", baseDir: dir, requiringSig: "old") != nil)
    }

    // An old-format sidecar (no `version` key) and a wrong-version one must both be rejected as stale.
    @Test func unversionedAndOldVersionSidecarsRejected() throws {
        let dir = StabilizationSidecar.dir(baseDir: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = dir.deletingLastPathComponent().deletingLastPathComponent()

        // No version key at all (legacy file).
        let legacy = #"{"sourceSig":"s","fps":30,"frames":[{"m":[1,0,0,0,1,0,0,0,1]}]}"#
        try legacy.data(using: .utf8)!.write(to: dir.appendingPathComponent("legacy.json"))
        #expect(StabilizationSidecar.read(assetId: "legacy", baseDir: base) == nil)

        // Explicit older version.
        try StabilizationSidecar.write(
            StabSidecar(version: 1, sourceSig: "s", fps: 30, frames: [.identity]),
            assetId: "v1", baseDir: base)
        #expect(StabilizationSidecar.read(assetId: "v1", baseDir: base) == nil)

        // Current version round-trips.
        try StabilizationSidecar.write(
            StabSidecar(sourceSig: "s", fps: 30, frames: [.identity]),
            assetId: "cur", baseDir: base)
        #expect(StabilizationSidecar.read(assetId: "cur", baseDir: base) != nil)
    }
}
