import Foundation
import simd

enum PathSmoother {
    struct Result: Sendable, Equatable {
        var corrections: [StabFrameTransform]   // one per frame in `window`
        var cropZoom: Double                    // ≥ 1.0
    }

    /// Decomposed 2D camera state we smooth independently.
    private struct State { var tx: Double; var ty: Double; var rot: Double; var scale: Double }

    private static func decompose(_ t: StabFrameTransform) -> State {
        let a = t.m[0], b = t.m[1], c = t.m[3], d = t.m[4]
        let scale = (hypot(a, c) + hypot(b, d)) / 2
        let rot = atan2(c, a)
        return State(tx: t.m[2], ty: t.m[5], rot: rot, scale: scale == 0 ? 1 : scale)
    }

    /// Build a homography that applies (tx,ty,rot,scale) about the frame center (0.5,0.5).
    private static func compose(_ s: State) -> StabFrameTransform {
        let cs = cos(s.rot) * s.scale, sn = sin(s.rot) * s.scale
        let cx = 0.5, cy = 0.5
        let tx = s.tx + cx - (cs * cx - sn * cy)
        let ty = s.ty + cy - (sn * cx + cs * cy)
        return StabFrameTransform(m: [cs, -sn, tx, sn, cs, ty, 0, 0, 1])
    }

    static func corrections(
        raw: [StabFrameTransform],
        window: Range<Int>,
        method: StabMethod,
        smoothness: Double,
        cropToFit: Bool
    ) -> Result {
        let idx = Array(window).filter { $0 >= 0 && $0 < raw.count }
        guard !idx.isEmpty else { return Result(corrections: [], cropZoom: 1.0) }

        // 1. Decompose each raw frame into the camera path (already absolute/cumulative).
        let path = idx.map { decompose(raw[$0]) }

        // 2. Gaussian-smooth each channel. smoothness 0…1 → sigma 1…30 frames.
        let sigma = 1 + smoothness * 29
        let txS = gaussian(path.map(\.tx), sigma: sigma)
        let tyS = gaussian(path.map(\.ty), sigma: sigma)
        let rotS = method == .position ? path.map { _ in 0.0 } : gaussian(path.map(\.rot), sigma: sigma)
        let scS  = method == .position ? path.map { _ in path.first!.scale }
                                       : gaussian(path.map(\.scale), sigma: sigma)

        // 3. Correction = smoothed − raw, expressed as a homography.
        var corrections: [StabFrameTransform] = []
        var maxAbsTx = 0.0, maxAbsTy = 0.0
        for k in path.indices {
            let cor = State(tx: txS[k] - path[k].tx,
                            ty: tyS[k] - path[k].ty,
                            rot: (method == .position) ? 0 : rotS[k] - path[k].rot,
                            scale: (method == .position) ? 1 : scS[k] / max(path[k].scale, 1e-9))
            corrections.append(compose(cor))
            maxAbsTx = max(maxAbsTx, abs(cor.tx)); maxAbsTy = max(maxAbsTy, abs(cor.ty))
        }

        // 4. Crop zoom: enough scale-up so the largest translation never exposes an edge.
        let cropZoom = cropToFit ? 1 + 2 * max(maxAbsTx, maxAbsTy) : 1.0
        return Result(corrections: corrections, cropZoom: max(1.0, cropZoom))
    }

    private static func gaussian(_ xs: [Double], sigma: Double) -> [Double] {
        guard xs.count > 1, sigma > 0 else { return xs }
        let radius = max(1, Int((sigma * 3).rounded()))
        var kernel = (-radius...radius).map { exp(-Double($0 * $0) / (2 * sigma * sigma)) }
        let sum = kernel.reduce(0, +); kernel = kernel.map { $0 / sum }
        return xs.indices.map { i in
            var acc = 0.0
            for (k, w) in kernel.enumerated() {
                let j = min(max(i + k - radius, 0), xs.count - 1)
                acc += xs[j] * w
            }
            return acc
        }
    }
}
