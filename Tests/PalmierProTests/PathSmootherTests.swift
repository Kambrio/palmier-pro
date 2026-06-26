import Testing
import Foundation
@testable import PalmierPro

struct PathSmootherTests {
    // A purely smooth pan should be left ~untouched (correction ≈ identity translation).
    @Test func smoothMotionNeedsLittleCorrection() {
        let frames = (0..<60).map { i -> StabFrameTransform in
            StabFrameTransform(m: [1,0, Double(i) * 0.001, 0,1,0, 0,0,1])  // steady drift
        }
        let out = PathSmoother.corrections(
            raw: frames, window: 0..<60, method: .similarity, smoothness: 0.5, cropToFit: false)
        let maxTx = out.corrections.map { abs($0.m[2]) }.max() ?? 1
        #expect(maxTx < 0.01)
    }

    // High-frequency jitter must be reduced: correction translation should oppose it.
    @Test func jitterIsReduced() {
        let frames = (0..<60).map { i -> StabFrameTransform in
            let jitter = (i % 2 == 0 ? 0.05 : -0.05)
            return StabFrameTransform(m: [1,0, jitter, 0,1,0, 0,0,1])
        }
        let out = PathSmoother.corrections(
            raw: frames, window: 0..<60, method: .position, smoothness: 0.8, cropToFit: false)
        // Residual jitter after applying corrections is smaller than the input jitter.
        let residual = zip(frames, out.corrections).map { abs($0.m[2] + $1.m[2]) }.max() ?? 1
        #expect(residual < 0.05)
    }

    @Test func cropFactorAtLeastOne() {
        let frames = (0..<30).map { i in
            StabFrameTransform(m: [1,0, Double(i % 3) * 0.04, 0,1,0, 0,0,1])
        }
        let out = PathSmoother.corrections(
            raw: frames, window: 0..<30, method: .similarity, smoothness: 0.5, cropToFit: true)
        #expect(out.cropZoom >= 1.0)
    }

    @Test func emptyWindowIsSafe() {
        let out = PathSmoother.corrections(
            raw: [], window: 0..<0, method: .similarity, smoothness: 0.5, cropToFit: true)
        #expect(out.corrections.isEmpty)
        #expect(out.cropZoom == 1.0)
    }

    @Test func identityCorrectionMapsToIdentityAffine() {
        let a = CompositionBuilder.normalizedHomographyToAffine(
            .identity, natSize: CGSize(width: 1920, height: 1080), zoom: 1)
        #expect(abs(a.a - 1) < 1e-9 && abs(a.d - 1) < 1e-9)
        #expect(abs(a.tx) < 1e-9 && abs(a.ty) < 1e-9)
    }

    @Test func zoomScalesAboutCenter() {
        let a = CompositionBuilder.normalizedHomographyToAffine(
            .identity, natSize: CGSize(width: 100, height: 100), zoom: 2)
        let center = CGPoint(x: 50, y: 50).applying(a)
        #expect(abs(center.x - 50) < 1e-6 && abs(center.y - 50) < 1e-6)
    }
}
