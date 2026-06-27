import Testing
import AVFoundation
import CoreGraphics
import Foundation
@testable import PalmierPro

struct SubjectTrackerSeededTests {
    /// A bright square slides right `pxPerFrame` each frame; seed at K and check the recovered
    /// center path follows it both before and after K.
    @Test func seededTrackFollowsMovingRectangle() async throws {
        let size = 256, frames = 24, pxPerFrame = 6, K = 12
        let url = try await TestClip.makePanningClip(frames: frames, pxPerFrame: pxPerFrame, size: size)
        defer { try? FileManager.default.removeItem(at: url) }

        // Square at frame i (top-left normalized): x=(20+i*ppf)/size, y=(size/2-20)/size, w=h=40/size.
        let sz = CGFloat(size)
        let seedBox = CGRect(
            x: CGFloat(20 + K * pxPerFrame) / sz, y: CGFloat(size / 2 - 20) / sz,
            width: 40 / sz, height: 40 / sz)
        let expectedCenterX = { (i: Int) in CGFloat(40 + i * pxPerFrame) / sz }

        let (fps, out) = try await SubjectTracker.track(
            input: url, seedFrame: K, seedBoxTopLeft: seedBox, progress: { _ in })

        #expect(fps > 0)
        #expect(out.count >= frames - 1)
        #expect(out.allSatisfy { $0.m.allSatisfy(\.isFinite) })
        #expect(out.allSatisfy { $0.m[2] >= 0 && $0.m[2] <= 1 && $0.m[5] >= 0 && $0.m[5] <= 1 })
        // Identity scale/shear elements hold.
        #expect(out.allSatisfy { $0.m[0] == 1 && $0.m[4] == 1 && $0.m[8] == 1 })

        let cx = out.map { CGFloat($0.m[2]) }
        // Seed frame center matches the picked box exactly.
        #expect(abs(cx[K] - expectedCenterX(K)) < 1e-6)
        // Forward: a later frame is meaningfully further right than the seed.
        #expect(cx[frames - 1] > cx[K] + 0.05)
        // Backward: an earlier frame is meaningfully further left than the seed.
        #expect(cx[0] < cx[K] - 0.05)
        // Tracking roughly matches the analytic path near the seed.
        #expect(abs(cx[K + 4] - expectedCenterX(K + 4)) < 0.15)
        #expect(abs(cx[K - 4] - expectedCenterX(K - 4)) < 0.15)
    }

    @Test func seededTrackRejectsMissingVideoTrack() async {
        let bad = URL(fileURLWithPath: "/tmp/nope-\(UUID().uuidString).mov")
        await #expect(throws: (any Error).self) {
            _ = try await SubjectTracker.track(
                input: bad, seedFrame: 0, seedBoxTopLeft: .init(x: 0.4, y: 0.4, width: 0.2, height: 0.2),
                progress: { _ in })
        }
    }
}

@MainActor
struct SubjectCorrectionsTests {
    @Test func subjectBranchReturnsCorrectionsWithSeedAndNilWithout() async throws {
        let assetURL = try await TestClip.makePanningClip(frames: 30, pxPerFrame: 2)
        defer { try? FileManager.default.removeItem(at: assetURL) }
        let projectDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: projectDir) }

        let editor = EditorViewModel()
        editor.projectURL = projectDir
        let manager = editor.stabilizationManager

        let mediaRef = "asset-x"
        let seed = SubjectSeed(
            frame: 5, box: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2), label: "person")
        let sourceSig = ProxySignature.of(assetURL) ?? ""
        let centers = (0..<30).map { i in
            StabFrameTransform(m: [1, 0, 0.3 + Double(i) * 0.01, 0, 1, 0.5, 0, 0, 1])
        }
        let sidecar = SubjectSidecar(
            sourceSig: sourceSig, seedKey: seed.seedKey, fps: 30, frames: centers)
        try SubjectSidecarStore.write(sidecar, assetId: mediaRef, baseDir: projectDir)

        var clip = Clip(mediaRef: mediaRef, startFrame: 0, durationFrames: 20)
        clip.stabilization = Stabilization(
            enabled: true, engine: .subject, method: .position, smoothness: 0.5, cropToFit: true,
            subjectSeed: seed)

        let result = manager.corrections(for: clip, assetURL: assetURL)
        #expect(result != nil)
        #expect(result?.corrections.isEmpty == false)
        #expect(result?.corrections.allSatisfy { $0.m.allSatisfy(\.isFinite) } == true)
        #expect((result?.cropZoom ?? 0).isFinite)

        // No seed → no correction.
        var unseeded = clip
        unseeded.stabilization?.subjectSeed = nil
        manager.invalidateCache()
        #expect(manager.corrections(for: unseeded, assetURL: assetURL) == nil)
    }
}
