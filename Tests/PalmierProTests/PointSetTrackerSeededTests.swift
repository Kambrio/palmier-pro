import Testing
import AVFoundation
import CoreGraphics
import Foundation
@testable import PalmierPro

private func decompose(_ t: StabFrameTransform) -> (tx: Double, ty: Double, rot: Double, scale: Double) {
    (tx: t.m[2], ty: t.m[5], rot: atan2(t.m[3], t.m[0]), scale: hypot(t.m[0], t.m[3]))
}

struct PointSetTrackerSeededTests {
    /// A rigid triangle of bright dots translates in +x and rotates about its centroid each frame.
    /// Seed at K; assert the recovered per-frame centroid/rotation/scale follow the known motion both
    /// before and after the seed.
    @Test func seededTrackFollowsRigidMotion() async throws {
        let frames = 24, K = 12, pxPerFrame = 2
        let dots = [CGPoint(x: 0.35, y: 0.40), CGPoint(x: 0.62, y: 0.42), CGPoint(x: 0.48, y: 0.66)]
        let (url, seedPoints) = try await TestClip.makeRigidDotsClip(
            frames: frames, dots: dots, pxPerFrame: pxPerFrame, degPerFrame: 1.0, seedFrame: K)
        defer { try? FileManager.default.removeItem(at: url) }

        let (fps, out) = try await PointSetTracker.track(
            input: url, seedFrame: K, seedPointsTopLeft: seedPoints, progress: { _ in })

        #expect(fps > 0)
        #expect(out.count >= frames - 1)
        #expect(out.allSatisfy { $0.m.allSatisfy(\.isFinite) })
        // Scale stays sane (rigid; bounded 0.2…5 by the fit clamp).
        #expect(out.allSatisfy { let s = hypot($0.m[0], $0.m[3]); return s >= 0.2 && s <= 5 })

        let d = out.map(decompose)
        // Seed frame: identity rotation & unit scale, centroid = mean(seedPoints).
        let muX = seedPoints.reduce(0.0) { $0 + Double($1.x) } / 3
        let muY = seedPoints.reduce(0.0) { $0 + Double($1.y) } / 3
        #expect(abs(d[K].rot) < 1e-6)
        #expect(abs(d[K].scale - 1) < 1e-6)
        #expect(abs(d[K].tx - muX) < 1e-6)
        #expect(abs(d[K].ty - muY) < 1e-6)

        // Forward centroid moves +x; backward moves −x.
        #expect(d[frames - 1].tx > d[K].tx + 0.02)
        #expect(d[0].tx < d[K].tx - 0.02)
        // Scale stays near unity near the seed (no scaling in the synthetic motion).
        #expect(abs(d[K + 4].scale - 1) < 0.35)
        #expect(abs(d[K - 4].scale - 1) < 0.35)
        // Rotation accumulates with distance from the seed (magnitude grows away from K).
        #expect(abs(d[frames - 1].rot) > abs(d[K + 1].rot))
        #expect(abs(d[0].rot) > abs(d[K - 1].rot))
    }

    @Test func rejectsEmptySeed() async {
        let bad = URL(fileURLWithPath: "/tmp/nope-\(UUID().uuidString).mov")
        await #expect(throws: (any Error).self) {
            _ = try await PointSetTracker.track(
                input: bad, seedFrame: 0, seedPointsTopLeft: [], progress: { _ in })
        }
    }
}

@MainActor
struct PointCorrectionsTests {
    @Test func pointsBranchReturnsCorrectionsWithSeedAndNilWithout() async throws {
        let assetURL = try await TestClip.makePanningClip(frames: 30, pxPerFrame: 2)
        defer { try? FileManager.default.removeItem(at: assetURL) }
        let projectDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: projectDir) }

        let editor = EditorViewModel()
        editor.projectURL = projectDir
        let manager = editor.stabilizationManager

        let mediaRef = "asset-pts"
        let seed = PointsSeed(frame: 5, points: [
            CGPoint(x: 0.4, y: 0.4), CGPoint(x: 0.6, y: 0.4), CGPoint(x: 0.5, y: 0.6)])
        let sourceSig = ProxySignature.of(assetURL) ?? ""
        // Synthetic similarity path: slight drift + small rotation per frame.
        let centers = (0..<30).map { i -> StabFrameTransform in
            let theta = Double(i) * 0.01
            let a = cos(theta), b = sin(theta)
            return StabFrameTransform(m: [a, -b, 0.5 + Double(i) * 0.005, b, a, 0.5, 0, 0, 1])
        }
        let sidecar = PointSidecar(sourceSig: sourceSig, seedKey: seed.seedKey, fps: 30, frames: centers)
        try PointSidecarStore.write(sidecar, assetId: mediaRef, baseDir: projectDir)

        var clip = Clip(mediaRef: mediaRef, startFrame: 0, durationFrames: 20)
        clip.stabilization = Stabilization(
            enabled: true, engine: .points, method: .similarity, smoothness: 0.5, cropToFit: true,
            pointsSeed: seed)

        let result = manager.corrections(for: clip, assetURL: assetURL)
        #expect(result != nil)
        #expect(result?.corrections.isEmpty == false)
        #expect(result?.corrections.allSatisfy { $0.m.allSatisfy(\.isFinite) } == true)
        let zoom = try #require(result?.cropZoom)
        #expect(zoom.isFinite)
        #expect(zoom >= 1.0)

        // No seed → no correction.
        var unseeded = clip
        unseeded.stabilization?.pointsSeed = nil
        manager.invalidateCache()
        #expect(manager.corrections(for: unseeded, assetURL: assetURL) == nil)
    }
}
