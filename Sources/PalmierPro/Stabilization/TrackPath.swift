import Foundation

/// Confidence-gated cleanup for tracked trajectories. Transient frames where tracking is unreliable
/// (occlusion, low Vision confidence) produce a bad per-frame fit that downstream smoothing can't fully
/// remove — a path spike. We reject those frames at the source and interpolate them from the nearest
/// reliable neighbours, so the smoother only ever sees a continuous path.
enum TrackPath {
    private struct State { var tx: Double; var ty: Double; var rot: Double; var scale: Double }

    private static func decompose(_ t: StabFrameTransform) -> State {
        let a = t.m[0], b = t.m[3]
        let scale = hypot(a, b)
        return State(tx: t.m[2], ty: t.m[5], rot: atan2(b, a), scale: scale == 0 ? 1 : scale)
    }

    private static func recompose(_ s: State) -> StabFrameTransform {
        let cs = s.scale * cos(s.rot), sn = s.scale * sin(s.rot)
        return StabFrameTransform(m: [cs, -sn, s.tx, sn, cs, s.ty, 0, 0, 1])
    }

    /// Shortest signed angular distance from `a` to `b`, wrapped into (−π, π].
    private static func shortestArc(_ a: Double, _ b: Double) -> Double {
        var d = (b - a).truncatingRemainder(dividingBy: 2 * .pi)
        if d > .pi { d -= 2 * .pi }
        if d <= -.pi { d += 2 * .pi }
        return d
    }

    /// Replace each run of frames with `conf < minConf` by per-channel (tx, ty, rot, scale) linear
    /// interpolation between the nearest reliable frame before and after the run. Rotation interpolates
    /// along the shortest arc so a fit near ±π doesn't swing the long way. If a reliable frame exists on
    /// only one side, hold it; if there are NO reliable frames, return the input unchanged. Length and
    /// finiteness preserved.
    static func interpolateLowConfidence(
        _ frames: [StabFrameTransform], conf: [Double], minConf: Double
    ) -> [StabFrameTransform] {
        guard frames.count == conf.count, !frames.isEmpty else { return frames }
        guard conf.contains(where: { $0 >= minConf }) else { return frames }  // no anchors → unchanged

        var out = frames
        let n = frames.count
        var i = 0
        while i < n {
            if conf[i] >= minConf { i += 1; continue }
            var j = i
            while j < n, conf[j] < minConf { j += 1 }      // low-confidence run is [i, j)
            let before: Int? = i > 0 ? i - 1 : nil          // i-1 is reliable by construction
            let after: Int? = j < n ? j : nil
            for k in i..<j {
                switch (before, after) {
                case let (lo?, hi?):
                    let s0 = decompose(frames[lo]), s1 = decompose(frames[hi])
                    let f = Double(k - lo) / Double(hi - lo)
                    let st = State(
                        tx: s0.tx + (s1.tx - s0.tx) * f,
                        ty: s0.ty + (s1.ty - s0.ty) * f,
                        rot: s0.rot + shortestArc(s0.rot, s1.rot) * f,
                        scale: s0.scale + (s1.scale - s0.scale) * f)
                    out[k] = recompose(st)
                case let (lo?, nil):
                    out[k] = recompose(decompose(frames[lo]))
                case let (nil, hi?):
                    out[k] = recompose(decompose(frames[hi]))
                case (nil, nil):
                    break                                    // unreachable: anchors exist
                }
            }
            i = j
        }
        return out
    }
}
