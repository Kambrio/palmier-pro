import Testing
import CoreGraphics
import Foundation
@testable import PalmierPro

struct PointSetFitTests {
    /// Apply a known similarity (scale s, rotation θ, translation t) to reference points and confirm
    /// the closed-form fit recovers a = s·cosθ, b = s·sinθ, and the translated centroid.
    @Test func recoversKnownSimilarity() throws {
        let P = [CGPoint(x: 0.2, y: 0.3), CGPoint(x: 0.6, y: 0.25),
                 CGPoint(x: 0.5, y: 0.7), CGPoint(x: 0.3, y: 0.6)]
        let s = 1.4, theta = 0.4, tx = 0.1, ty = -0.05
        let a0 = s * cos(theta), b0 = s * sin(theta)
        let muP = CGPoint(x: P.reduce(0) { $0 + $1.x } / 4, y: P.reduce(0) { $0 + $1.y } / 4)
        let Q = P.map { p -> CGPoint in
            let dx = Double(p.x - muP.x), dy = Double(p.y - muP.y)
            return CGPoint(x: Double(muP.x) + a0 * dx - b0 * dy + tx,
                           y: Double(muP.y) + b0 * dx + a0 * dy + ty)
        }
        let fit = try #require(PointSetTracker.fitSimilarity(reference: P, current: Q))
        #expect(abs(fit.a - a0) < 1e-6)
        #expect(abs(fit.b - b0) < 1e-6)
        let muQ = CGPoint(x: Q.reduce(0) { $0 + $1.x } / 4, y: Q.reduce(0) { $0 + $1.y } / 4)
        #expect(abs(fit.centroid.x - muQ.x) < 1e-6)
        #expect(abs(fit.centroid.y - muQ.y) < 1e-6)
        // Decomposed scale/rotation match the input.
        #expect(abs(hypot(fit.a, fit.b) - s) < 1e-6)
        #expect(abs(atan2(fit.b, fit.a) - theta) < 1e-6)
    }

    @Test func identityWhenReferenceEqualsCurrent() throws {
        let P = [CGPoint(x: 0.2, y: 0.3), CGPoint(x: 0.6, y: 0.4), CGPoint(x: 0.4, y: 0.7)]
        let fit = try #require(PointSetTracker.fitSimilarity(reference: P, current: P))
        #expect(abs(fit.a - 1) < 1e-9)
        #expect(abs(fit.b) < 1e-9)
    }

    @Test func onePointIsTranslationOnly() throws {
        let P = [CGPoint(x: 0.2, y: 0.3)]
        let Q = [CGPoint(x: 0.7, y: 0.8)]
        let fit = try #require(PointSetTracker.fitSimilarity(reference: P, current: Q))
        #expect(fit.a == 1)
        #expect(fit.b == 0)
        #expect(abs(fit.centroid.x - 0.7) < 1e-9)
        #expect(abs(fit.centroid.y - 0.8) < 1e-9)
    }

    @Test func zeroPointsReturnsNil() {
        #expect(PointSetTracker.fitSimilarity(reference: [], current: []) == nil)
        // Mismatched counts → nil.
        #expect(PointSetTracker.fitSimilarity(
            reference: [CGPoint(x: 0, y: 0)], current: []) == nil)
    }

    /// One grossly displaced correspondence is rejected; the fit recovers the inliers' transform.
    @Test func rejectsOutlier() throws {
        let P = [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.5, y: 0.2), CGPoint(x: 0.8, y: 0.2),
                 CGPoint(x: 0.2, y: 0.5), CGPoint(x: 0.8, y: 0.5),
                 CGPoint(x: 0.2, y: 0.8), CGPoint(x: 0.5, y: 0.8), CGPoint(x: 0.8, y: 0.8),
                 CGPoint(x: 0.5, y: 0.5)]
        let tx = 0.1, ty = 0.05
        var Q = P.map { CGPoint(x: $0.x + tx, y: $0.y + ty) }
        Q[8] = CGPoint(x: 0.05, y: 0.95)   // last point is a gross outlier
        let clean = try #require(PointSetTracker.fitSimilarity(reference: P, current: Q))
        // Inliers are a pure translation → a≈1, b≈0.
        #expect(abs(clean.a - 1) < 0.05)
        #expect(abs(clean.b) < 0.05)
    }

    @Test func clampsExtremeScale() throws {
        let P = [CGPoint(x: 0.4, y: 0.4), CGPoint(x: 0.6, y: 0.4), CGPoint(x: 0.5, y: 0.6)]
        // Blow the points apart by 100× about their centroid → scale would be ~100, clamped to ≤5.
        let muP = CGPoint(x: 0.5, y: 0.4667)
        let Q = P.map { CGPoint(x: muP.x + ($0.x - muP.x) * 100, y: muP.y + ($0.y - muP.y) * 100) }
        let fit = try #require(PointSetTracker.fitSimilarity(reference: P, current: Q))
        #expect(hypot(fit.a, fit.b) <= 5.0 + 1e-9)
        #expect(fit.a.isFinite && fit.b.isFinite)
    }
}

struct PointsSeedCodingTests {
    @Test func pointsSeedRoundTrips() throws {
        let seed = PointsSeed(frame: 7, points: [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.3, y: 0.4)])
        let data = try JSONEncoder().encode(seed)
        let back = try JSONDecoder().decode(PointsSeed.self, from: data)
        #expect(back == seed)
        #expect(back.seedKey == seed.seedKey)
    }

    @Test func stabilizationDecodesWithoutPointsSeed() throws {
        // A stabilization JSON predating pointsSeed must decode with pointsSeed == nil.
        let json = """
        {"enabled":true,"engine":"points","method":"similarity","smoothness":0.5,"cropToFit":true}
        """
        let stab = try JSONDecoder().decode(Stabilization.self, from: Data(json.utf8))
        #expect(stab.pointsSeed == nil)
        #expect(stab.engine == .points)
    }

    @Test func stabilizationRoundTripsPointsSeed() throws {
        var stab = Stabilization(enabled: true, engine: .points, method: .similarity)
        stab.pointsSeed = PointsSeed(frame: 3, points: [CGPoint(x: 0.5, y: 0.5)])
        let data = try JSONEncoder().encode(stab)
        let back = try JSONDecoder().decode(Stabilization.self, from: data)
        #expect(back.pointsSeed == stab.pointsSeed)
    }

    @Test func pointSidecarRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let seedKey = "5|0.1000,0.2000;0.3000,0.4000"
        let sidecar = PointSidecar(sourceSig: "sig9", seedKey: seedKey, fps: 30, frames: [
            StabFrameTransform(m: [1, 0, 0.4, 0, 1, 0.6, 0, 0, 1]),
            StabFrameTransform(m: [0.99, -0.05, 0.5, 0.05, 0.99, 0.5, 0, 0, 1]),
        ])
        try PointSidecarStore.write(sidecar, assetId: "asset9", baseDir: dir)
        let loaded = PointSidecarStore.read(assetId: "asset9", baseDir: dir, sourceSig: "sig9", seedKey: seedKey)
        #expect(loaded?.frames.count == 2)
        #expect(loaded?.fps == 30)
        // Wrong sig / seed / asset are rejected cleanly.
        #expect(PointSidecarStore.read(assetId: "asset9", baseDir: dir, sourceSig: "x", seedKey: seedKey) == nil)
        #expect(PointSidecarStore.read(assetId: "asset9", baseDir: dir, sourceSig: "sig9", seedKey: "other") == nil)
        #expect(PointSidecarStore.read(assetId: "none", baseDir: dir, sourceSig: "sig9", seedKey: seedKey) == nil)
    }
}
