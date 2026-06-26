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
}
