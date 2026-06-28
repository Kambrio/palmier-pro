import Testing
import Foundation
@testable import PalmierPro

private func decompose(_ t: StabFrameTransform) -> (tx: Double, ty: Double, rot: Double, scale: Double) {
    (tx: t.m[2], ty: t.m[5], rot: atan2(t.m[3], t.m[0]), scale: hypot(t.m[0], t.m[3]))
}

private func rotFrame(_ rot: Double, tx: Double = 0, ty: Double = 0, scale: Double = 1) -> StabFrameTransform {
    let cs = scale * cos(rot), sn = scale * sin(rot)
    return StabFrameTransform(m: [cs, -sn, tx, sn, cs, ty, 0, 0, 1])
}

struct TrackPathTests {
    // A clean tx ramp where frames 50–52 are marked low-confidence and corrupted with a wild spike →
    // after interpolation those frames land back on the ramp and the spike is gone, neighbours untouched.
    @Test func interpolatesLowConfidenceRunOntoRamp() {
        let n = 100
        var frames = (0..<n).map { StabFrameTransform(m: [1, 0, Double($0) * 0.01, 0, 1, 0, 0, 0, 1]) }
        var conf = [Double](repeating: 1.0, count: n)
        for k in 50...52 {
            frames[k] = StabFrameTransform(m: [1, 0, 5.0, 0, 1, 5.0, 0, 0, 1])  // wild spike
            conf[k] = 0.0
        }
        let out = TrackPath.interpolateLowConfidence(frames, conf: conf, minConf: 0.6)
        #expect(out.count == n)
        // Spike gone: corrupted frames lie on the original ramp.
        for k in 50...52 {
            #expect(abs(out[k].m[2] - Double(k) * 0.01) < 1e-9)
            #expect(abs(out[k].m[5]) < 1e-9)
        }
        // Reliable neighbours unchanged.
        #expect(abs(out[49].m[2] - 0.49) < 1e-12)
        #expect(abs(out[53].m[2] - 0.53) < 1e-12)
        #expect(out.allSatisfy { $0.m.allSatisfy(\.isFinite) })
    }

    // No reliable frames anywhere → input returned unchanged.
    @Test func allLowConfidenceReturnsInputUnchanged() {
        let frames = (0..<10).map { StabFrameTransform(m: [1, 0, Double($0), 0, 1, 0, 0, 0, 1]) }
        let conf = [Double](repeating: 0.0, count: 10)
        let out = TrackPath.interpolateLowConfidence(frames, conf: conf, minConf: 0.6)
        #expect(out == frames)
    }

    // A reliable frame on only one side → hold it across the run.
    @Test func oneSidedRunHoldsAnchor() {
        var frames = (0..<5).map { StabFrameTransform(m: [1, 0, Double($0) * 0.1, 0, 1, 0, 0, 0, 1]) }
        var conf = [Double](repeating: 1.0, count: 5)
        // Last two frames low-confidence with no reliable frame after them.
        frames[3] = StabFrameTransform(m: [1, 0, 9, 0, 1, 0, 0, 0, 1]); conf[3] = 0.0
        frames[4] = StabFrameTransform(m: [1, 0, 9, 0, 1, 0, 0, 0, 1]); conf[4] = 0.0
        let out = TrackPath.interpolateLowConfidence(frames, conf: conf, minConf: 0.6)
        #expect(abs(out[3].m[2] - 0.2) < 1e-9)   // held at frame 2's tx
        #expect(abs(out[4].m[2] - 0.2) < 1e-9)
    }

    // Rotation interpolates the SHORT way across the ±π wrap, not the long way through 0.
    @Test func rotationInterpolatesShortArcAcrossWrap() {
        let frames = [rotFrame(3.0), rotFrame(0), rotFrame(-3.0)]  // 3.0 → −3.0 short arc ≈ +0.28 rad
        let conf = [1.0, 0.0, 1.0]
        let out = TrackPath.interpolateLowConfidence(frames, conf: conf, minConf: 0.5)
        let r = decompose(out[1]).rot
        // Short way puts the midpoint near ±π (≈3.14), NOT near 0 (the long way).
        #expect(abs(r) > 3.0)
        #expect(out.allSatisfy { $0.m.allSatisfy(\.isFinite) })
    }

    // Length and finiteness preserved on a mixed path; reliable frames are never touched.
    @Test func preservesLengthAndReliableFrames() {
        let n = 30
        var frames = (0..<n).map { rotFrame(Double($0) * 0.01, tx: Double($0) * 0.02) }
        var conf = [Double](repeating: 1.0, count: n)
        frames[10] = rotFrame(2.0, tx: 8); conf[10] = 0.1
        frames[20] = rotFrame(-2.0, tx: -8); conf[20] = 0.2
        let out = TrackPath.interpolateLowConfidence(frames, conf: conf, minConf: 0.6)
        #expect(out.count == n)
        #expect(out[5] == frames[5] && out[15] == frames[15])
        #expect(out.allSatisfy { $0.m.allSatisfy(\.isFinite) })
    }
}
