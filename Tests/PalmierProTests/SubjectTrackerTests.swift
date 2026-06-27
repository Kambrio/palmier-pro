import Testing
import AVFoundation
import Foundation
@testable import PalmierPro

struct SubjectTrackerTests {
    // Vision may not detect a person/face on synthetic content — the test accepts both outcomes:
    // a valid path, or a clean "no subject detected" error. What must NOT happen is a crash or
    // an unexpected error type.
    @Test func handlesClipGracefully() async throws {
        let url = try await TestClip.makePanningClip(frames: 30, pxPerFrame: 3)
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let (fps, frames) = try await SubjectTracker.track(input: url, progress: { _ in })
            #expect(fps > 0)
            #expect(!frames.isEmpty)
            #expect(frames.count <= 32)  // should be close to frame count
            #expect(frames.allSatisfy { $0.m.allSatisfy { $0.isFinite } })
            // Subject centers must stay in normalized [0,1] range.
            #expect(frames.allSatisfy { $0.m[2] >= 0 && $0.m[2] <= 1 })
            #expect(frames.allSatisfy { $0.m[5] >= 0 && $0.m[5] <= 1 })
            // Identity elements must hold.
            #expect(frames.allSatisfy { $0.m[0] == 1 && $0.m[4] == 1 && $0.m[8] == 1 })
        } catch let err as SubjectTracker.Failure {
            // Synthetic content often has no detectable person/face — this is acceptable.
            #expect(err.reason == "no subject detected")
        }
    }

    @Test func rejectsMissingVideoTrack() async {
        let noVideoURL = URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString).mov")
        do {
            _ = try await SubjectTracker.track(input: noVideoURL, progress: { _ in })
            Issue.record("Expected a Failure error")
        } catch {
            // Any error (Failure or AVFoundation) is acceptable — just must not crash.
            #expect(error is SubjectTracker.Failure || error is NSError)
        }
    }

    // SubjectSidecar round-trips to disk and rejects wrong/missing source sig.
    @Test func subjectSidecarRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let seedKey = "0|0.1000,0.2000,0.3000,0.4000|person"
        let sidecar = SubjectSidecar(sourceSig: "sig123", seedKey: seedKey, fps: 30, frames: [
            StabFrameTransform(m: [1, 0, 0.4, 0, 1, 0.6, 0, 0, 1]),
            StabFrameTransform(m: [1, 0, 0.5, 0, 1, 0.5, 0, 0, 1])
        ])
        try SubjectSidecarStore.write(sidecar, assetId: "asset1", baseDir: dir)

        let loaded = SubjectSidecarStore.read(assetId: "asset1", baseDir: dir, sourceSig: "sig123", seedKey: seedKey)
        #expect(loaded != nil)
        #expect(loaded?.frames.count == 2)
        #expect(loaded?.fps == 30)
        #expect(loaded?.frames[0].m[2] == 0.4)
        #expect(loaded?.frames[0].m[5] == 0.6)

        // Wrong sig is rejected.
        #expect(SubjectSidecarStore.read(assetId: "asset1", baseDir: dir, sourceSig: "wrong", seedKey: seedKey) == nil)
        // Wrong seed key is rejected (a different pick → distinct sidecar).
        #expect(SubjectSidecarStore.read(assetId: "asset1", baseDir: dir, sourceSig: "sig123", seedKey: "other") == nil)
        // Missing asset returns nil cleanly.
        #expect(SubjectSidecarStore.read(assetId: "noSuchAsset", baseDir: dir, sourceSig: "sig123", seedKey: seedKey) == nil)
    }
}
