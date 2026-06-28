import Testing
import Foundation
@testable import PalmierPro

struct PathSmootherTests {
    // Applying the correction to the raw path must REDUCE frame-to-frame jitter — proves the
    // correction has the right sign (a flipped sign would double the shake → "more shaky").
    @Test func applyingCorrectionReducesJitter() {
        // Raw path = slow ramp + high-frequency jitter (a shaky pan).
        var raw: [StabFrameTransform] = []
        for i in 0..<120 {
            let ramp = Double(i) * 0.003
            let jitter = (i % 2 == 0 ? 0.02 : -0.02) + (i % 3 == 0 ? 0.01 : -0.005)
            raw.append(StabFrameTransform(m: [1,0, ramp + jitter, 0,1, jitter, 0,0,1]))
        }
        let out = PathSmoother.corrections(
            raw: raw, window: 0..<120, method: .similarity, engine: .l1, smoothness: 0.6, cropToFit: false)
        // Stabilized position = raw + correction; its frame-to-frame motion must be smaller.
        func jitterEnergy(_ txs: [Double]) -> Double {
            zip(txs.dropFirst(), txs).map { ($0 - $1) * ($0 - $1) }.reduce(0, +)
        }
        let rawTx = raw.map { $0.m[2] }
        let stabTx = zip(raw, out.corrections).map { $0.m[2] + $1.m[2] }
        #expect(jitterEnergy(stabTx) < jitterEnergy(rawTx) * 0.5)   // at least halved
    }

    // A purely smooth pan should be left ~untouched (correction ≈ identity translation).
    @Test func smoothMotionNeedsLittleCorrection() {
        let frames = (0..<60).map { i -> StabFrameTransform in
            StabFrameTransform(m: [1,0, Double(i) * 0.001, 0,1,0, 0,0,1])  // steady drift
        }
        let out = PathSmoother.corrections(
            raw: frames, window: 0..<60, method: .similarity, engine: .l1, smoothness: 0.5, cropToFit: false)
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
            raw: frames, window: 0..<60, method: .position, engine: .l1, smoothness: 0.8, cropToFit: false)
        // Residual jitter after applying corrections is smaller than the input jitter.
        let residual = zip(frames, out.corrections).map { abs($0.m[2] + $1.m[2]) }.max() ?? 1
        #expect(residual < 0.05)
    }

    @Test func cropFactorAtLeastOne() {
        let frames = (0..<30).map { i in
            StabFrameTransform(m: [1,0, Double(i % 3) * 0.04, 0,1,0, 0,0,1])
        }
        let out = PathSmoother.corrections(
            raw: frames, window: 0..<30, method: .similarity, engine: .l1, smoothness: 0.5, cropToFit: true)
        #expect(out.cropZoom >= 1.0)
    }

    @Test func emptyWindowIsSafe() {
        let out = PathSmoother.corrections(
            raw: [], window: 0..<0, method: .similarity, engine: .l1, smoothness: 0.5, cropToFit: true)
        #expect(out.corrections.isEmpty)
        #expect(out.cropZoom == 1.0)
    }

    @Test func identityCorrectionMapsToIdentityAffine() {
        let a = CompositionBuilder.normalizedHomographyToAffine(
            .identity, natSize: CGSize(width: 1920, height: 1080), zoom: 1)
        #expect(abs(a.a - 1) < 1e-9 && abs(a.d - 1) < 1e-9)
        #expect(abs(a.tx) < 1e-9 && abs(a.ty) < 1e-9)
        #expect(abs(a.b) < 1e-9 && abs(a.c) < 1e-9)
    }

    // A long, noisy path must never produce a correction that pushes content off-frame.
    @Test func correctionsStayBoundedOnNoisyPath() {
        var frames: [StabFrameTransform] = []
        var tx = 0.0, ty = 0.0
        for i in 0..<600 {
            tx += (i % 2 == 0 ? 0.02 : -0.018)   // jitter + slight drift
            ty += (i % 3 == 0 ? 0.015 : -0.01)
            frames.append(StabFrameTransform(m: [1,0,tx, 0,1,ty, 0,0,1]))
        }
        let out = PathSmoother.corrections(
            raw: frames, window: 0..<600, method: .similarity, engine: .l1, smoothness: 0.6, cropToFit: true)
        #expect(out.cropZoom <= 1.5)
        for c in out.corrections {
            #expect(abs(c.m[2]) <= 0.25 + 1e-9)   // tx clamped
            #expect(abs(c.m[5]) <= 0.25 + 1e-9)   // ty clamped
            #expect(c.m.allSatisfy { $0.isFinite })
        }
    }

    @Test func zoomScalesAboutCenter() {
        let a = CompositionBuilder.normalizedHomographyToAffine(
            .identity, natSize: CGSize(width: 100, height: 100), zoom: 2)
        let center = CGPoint(x: 50, y: 50).applying(a)
        #expect(abs(center.x - 50) < 1e-6 && abs(center.y - 50) < 1e-6)
    }

    @Test func translationScalesByGivenAxis() {
        let t = StabFrameTransform(m: [1,0,0.1, 0,1,0, 0,0,1])
        let wide = CompositionBuilder.normalizedHomographyToAffine(t, natSize: CGSize(width: 1920, height: 1080), zoom: 1)
        let tall = CompositionBuilder.normalizedHomographyToAffine(t, natSize: CGSize(width: 1080, height: 1920), zoom: 1)
        // 0.1 of width: 192 vs 108 px — proves the axis length matters (the rotated-source fix).
        #expect(abs(wide.tx - 192) < 1e-6)
        #expect(abs(tall.tx - 108) < 1e-6)
    }

    @Test func nonFinitePathYieldsFiniteCorrections() {
        // A path with an infinite/NaN entry must never yield a non-finite correction.
        var frames: [StabFrameTransform] = []
        for i in 0..<30 { frames.append(StabFrameTransform(m: [1,0, Double(i)*0.01, 0,1,0, 0,0,1])) }
        frames[15] = StabFrameTransform(m: [1,0, .infinity, 0,1, .nan, 0,0,1])
        let out = PathSmoother.corrections(raw: frames, window: 0..<30, method: .similarity, engine: .l1, smoothness: 0.5, cropToFit: true)
        #expect(out.cropZoom.isFinite)
        for c in out.corrections { #expect(c.m.allSatisfy { $0.isFinite }) }
    }

    @Test func l1PreservesLinearTrendRemovesBob() {
        // Intended tracking move (linear ramp) + walking bob (low-freq oscillation).
        let n = 200
        var x = [Double](); x.reserveCapacity(n)
        for i in 0..<n {
            let ramp = Double(i) * 0.004                     // steady intended pan
            let bob = 0.03 * sin(Double(i) * 2 * .pi / 15)   // ~15-frame walking bob
            x.append(ramp + bob)
        }
        let s = PathSmoother.l1Smooth(x, lambda: pow(10, 1 + 0.6 * 3.5))
        // 1. Bob removed: second-difference energy of the smoothed path ≪ raw.
        func d2energy(_ a: [Double]) -> Double {
            (1..<(a.count-1)).map { let v = a[$0-1]-2*a[$0]+a[$0+1]; return v*v }.reduce(0,+)
        }
        #expect(d2energy(s) < d2energy(x) * 0.1)
        // 2. Intended ramp preserved: net displacement end−start kept (not flattened to zero).
        #expect((s.last! - s.first!) > (x.last! - x.first!) * 0.7)
        // 3. Finite + same length.
        #expect(s.count == n && s.allSatisfy { $0.isFinite })
    }

    // A rotating, shaky path must have its rotation jitter REDUCED after applying corrections —
    // a flipped rotation sign would amplify shake instead. Guards the similarity correction direction.
    @Test func rotationCorrectionReducesRotationJitter() {
        func rot(_ t: StabFrameTransform) -> Double { atan2(t.m[3], t.m[0]) }
        // Raw path: a slow rotation ramp + high-frequency rotation jitter.
        var raw: [StabFrameTransform] = []
        for i in 0..<120 {
            let ramp = Double(i) * 0.004
            let jitter = (i % 2 == 0 ? 0.03 : -0.03) + (i % 3 == 0 ? 0.015 : -0.008)
            let theta = ramp + jitter
            raw.append(StabFrameTransform(m: [cos(theta), -sin(theta), 0, sin(theta), cos(theta), 0, 0, 0, 1]))
        }
        let out = PathSmoother.corrections(
            raw: raw, window: 0..<120, method: .similarity, engine: .l1, smoothness: 0.6, cropToFit: false)
        // Stabilized rotation = raw.rot + correction.rot; its frame-to-frame variation must shrink.
        func jitterEnergy(_ xs: [Double]) -> Double {
            zip(xs.dropFirst(), xs).map { ($0 - $1) * ($0 - $1) }.reduce(0, +)
        }
        let rawRot = raw.map(rot)
        let stabRot = zip(raw, out.corrections).map { rot($0) + rot($1) }
        #expect(jitterEnergy(stabRot) < jitterEnergy(rawRot) * 0.5)   // at least halved, not amplified
    }

    // An off-center object with rotation jitter must stay put after stabilization. With the correction
    // pivoted at the frame center the off-center object swings in a big arc ("crazy wobble"); pivoting
    // at the object centroid keeps it locked. Proves objectPivot fixes Point Track rotation.
    @Test func objectPivotKeepsOffCenterObjectSteadyUnderRotation() {
        let cx = 0.85, cy = 0.5   // object far from the frame center
        var raw: [StabFrameTransform] = []
        for i in 0..<120 {
            let r = 0.12 * sin(Double(i) * 2 * .pi / 7)   // rotation jitter, no real motion
            raw.append(StabFrameTransform(m: [cos(r), -sin(r), cx, sin(r), cos(r), cy, 0, 0, 1]))
        }
        func mappedCentroidJitter(objectPivot: Bool) -> Double {
            let out = PathSmoother.corrections(
                raw: raw, window: 0..<120, method: .similarity, engine: .l1,
                smoothness: 0.8, cropToFit: false, objectPivot: objectPivot)
            // Apply each correction to the (constant) object centroid; a locked object barely moves.
            let pts = out.corrections.map { c -> (Double, Double) in
                (c.m[0]*cx + c.m[1]*cy + c.m[2], c.m[3]*cx + c.m[4]*cy + c.m[5])
            }
            return zip(pts.dropFirst(), pts).map { hypot($0.0 - $1.0, $0.1 - $1.1) }.max() ?? 0
        }
        let pivoted = mappedCentroidJitter(objectPivot: true)
        let centered = mappedCentroidJitter(objectPivot: false)
        #expect(pivoted < centered * 0.25)   // object pivot dramatically reduces the swing
        #expect(pivoted < 0.01)              // and the object is held nearly still
    }

    // A hard pin must hold the object at the pin pose even as it drifts (Cinematic "lock to start").
    @Test func pinTargetHoldsObjectAtSeedPose() {
        // Object centroid drifts 0.50 → 0.58 over the clip (within the ±0.25 correction clamp).
        var raw: [StabFrameTransform] = []
        for i in 0..<100 {
            let tx = 0.5 + Double(i) * 0.0008
            raw.append(StabFrameTransform(m: [1, 0, tx, 0, 1, 0.5, 0, 0, 1]))
        }
        let pin = raw[0]   // pose where tracking started
        let out = PathSmoother.corrections(
            raw: raw, window: 0..<100, method: .position, engine: .l1,
            smoothness: 0.5, cropToFit: false, objectPivot: true, denoiseRaw: 4, pinTarget: pin)
        // Stabilized centroid = raw + correction should stay pinned near 0.5, not drift to 0.58.
        let stabTx = zip(raw, out.corrections).map { $0.m[2] + $1.m[2] }
        for tx in stabTx { #expect(abs(tx - 0.5) < 0.02) }
    }

    // Hampel removes a transient spike but leaves real motion alone.
    @Test func hampelRejectsSpikesKeepsMotion() {
        // A gentle ramp + small noise with one big bump at frame 60.
        var xs = [Double]()
        for i in 0..<120 {
            let noise: Double = i % 2 == 0 ? 0.0008 : -0.0008
            xs.append(Double(i) * 0.002 + noise)
        }
        xs[60] += 0.25                                   // sudden hand-bump
        let out = PathSmoother.hampel(xs)
        #expect(abs(out[60] - 0.25 - (60 * 0.002)) > 0.2)   // the spike was removed…
        #expect(abs(out[60] - xs[59]) < 0.02)               // …replaced near its neighbours
        #expect(out.count == xs.count)

        // A clean linear ramp (a genuine fast pan) must be preserved — no false positives.
        let ramp = (0..<120).map { Double($0) * 0.01 }
        let rampOut = PathSmoother.hampel(ramp)
        for i in ramp.indices { #expect(abs(rampOut[i] - ramp[i]) < 1e-9) }
    }

    // A path with an injected spike yields a smoother stabilized result with spike rejection than the
    // raw spike would (the bump doesn't propagate into the correction). denoiseRaw>0 enables Hampel.
    @Test func spikeDoesNotPropagateIntoCorrection() {
        var frames: [StabFrameTransform] = []
        for i in 0..<120 { frames.append(StabFrameTransform(m: [1,0, Double(i)*0.001, 0,1,0, 0,0,1])) }
        frames[60] = StabFrameTransform(m: [1,0, 0.001*60 + 0.2, 0,1,0, 0,0,1])   // one-frame bump
        let out = PathSmoother.corrections(
            raw: frames, window: 0..<120, method: .position, engine: .smooth,
            smoothness: 0.5, cropToFit: false, denoiseRaw: 4)
        // Stabilized position around the bump stays continuous (no spike in the output path).
        let stab = zip(frames, out.corrections).map { $0.m[2] + $1.m[2] }
        #expect(abs(stab[60] - stab[59]) < 0.02 && abs(stab[61] - stab[60]) < 0.02)
        for c in out.corrections { #expect(c.m.allSatisfy { $0.isFinite }) }
    }

    @Test func smoothEngineDiffersFromL1AndReducesJitter() {
        var raw: [StabFrameTransform] = []
        for i in 0..<120 {
            let ramp = Double(i) * 0.003
            let bob = 0.025 * sin(Double(i) * 2 * .pi / 14)
            raw.append(StabFrameTransform(m: [1,0, ramp + bob, 0,1, bob, 0,0,1]))
        }
        let l1 = PathSmoother.corrections(raw: raw, window: 0..<120, method: .similarity, engine: .l1, smoothness: 0.6, cropToFit: false)
        let sm = PathSmoother.corrections(raw: raw, window: 0..<120, method: .similarity, engine: .smooth, smoothness: 0.6, cropToFit: false)
        // The two engines produce different corrections.
        let differ = zip(l1.corrections, sm.corrections).contains { abs($0.m[2] - $1.m[2]) > 1e-4 }
        #expect(differ)
        // Both reduce frame-to-frame jitter vs the raw path.
        func jit(_ txs: [Double]) -> Double { zip(txs.dropFirst(), txs).map { ($0-$1)*($0-$1) }.reduce(0,+) }
        let rawTx = raw.map { $0.m[2] }
        for out in [l1, sm] {
            let stab = zip(raw, out.corrections).map { $0.m[2] + $1.m[2] }
            #expect(jit(stab) < jit(rawTx))
        }
    }
}
