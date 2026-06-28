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

    /// Build a homography that applies (tx,ty,rot,scale) about the pivot (cx,cy).
    /// Camera stabilization pivots about the frame center; object tracking pivots about the object's
    /// centroid, otherwise rotation/scale correction swings the off-center object in a big arc.
    private static func compose(_ s: State, cx: Double = 0.5, cy: Double = 0.5) -> StabFrameTransform {
        let cs = cos(s.rot) * s.scale, sn = sin(s.rot) * s.scale
        let tx = s.tx + cx - (cs * cx - sn * cy)
        let ty = s.ty + cy - (sn * cx + cs * cy)
        return StabFrameTransform(m: [cs, -sn, tx, sn, cs, ty, 0, 0, 1])
    }

    /// Hampel identifier — replaces transient outliers (sudden one-off bumps) with the local median.
    /// For each sample, `sigma = 1.4826·MAD` over a window; samples beyond `nSigma·sigma` from the
    /// local median are anomalies. Leaves normal motion (and degenerate flat windows) untouched.
    static func hampel(_ xs: [Double], halfWindow: Int = 4, nSigma: Double = 3) -> [Double] {
        let n = xs.count
        guard halfWindow > 0, n > 2 * halfWindow + 1 else { return xs }
        func median(_ a: [Double]) -> Double { a.sorted()[a.count / 2] }
        var out = xs
        for i in 0..<n {
            let lo = max(0, i - halfWindow), hi = min(n - 1, i + halfWindow)
            let window = Array(xs[lo...hi])
            let med = median(window)
            let mad = median(window.map { abs($0 - med) })
            let sigma = 1.4826 * mad
            if sigma > 0, abs(xs[i] - med) > nSigma * sigma { out[i] = med }
        }
        return out
    }

    /// Gaussian low-pass — organic smoothing that follows the camera more loosely than L1.
    static func gaussianSmooth(_ xs: [Double], sigma: Double) -> [Double] {
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

    static func corrections(
        raw: [StabFrameTransform],
        window: Range<Int>,
        method: StabMethod,
        engine: StabEngine,
        smoothness: Double,
        cropToFit: Bool,
        objectPivot: Bool = false,
        denoiseRaw: Double = 0,
        pinTarget: StabFrameTransform? = nil
    ) -> Result {
        // NaN-safe clamp: non-finite input yields the midpoint (or 1.0 for scale handled below).
        func safeClamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
            guard v.isFinite else { return (lo + hi) / 2 }
            return min(max(v, lo), hi)
        }
        let idx = Array(window).filter { $0 >= 0 && $0 < raw.count }
        guard !idx.isEmpty else { return Result(corrections: [], cropZoom: 1.0) }

        // 1. Decompose each raw frame into the camera path (already absolute/cumulative).
        let rawPath = idx.map { decompose(raw[$0]) }
        var path = rawPath          // smoothing input (target is computed from this)
        var baseline = rawPath      // what the correction differences against (output = raw + (target − baseline))

        // Object tracking: clean the measured path. `path` (cleaned+denoised) feeds the target so
        // tracking jitter and spikes don't shape it. `baseline` is denoised normally — so steady
        // tracking noise isn't reinjected as vibration — but uses the RAW value at Hampel-flagged spike
        // frames, so an occasional hand-bump IS corrected (pulled back) instead of riding through.
        // No-op for camera engines, whose homography path is already accurate.
        if denoiseRaw > 0, path.count > 2 {
            func clean(_ ch: [Double]) -> (target: [Double], base: [Double]) {
                let h = hampel(ch)                                   // spikes → local median
                let d = gaussianSmooth(h, sigma: denoiseRaw)         // low-pass the de-spiked channel
                let base = d.indices.map { h[$0] == ch[$0] ? d[$0] : ch[$0] }   // raw at spikes
                return (d, base)
            }
            let (txT, txB) = clean(rawPath.map(\.tx))
            let (tyT, tyB) = clean(rawPath.map(\.ty))
            let (rotT, rotB) = clean(rawPath.map(\.rot))
            let (scT, scB) = clean(rawPath.map(\.scale))
            path = rawPath.indices.map { State(tx: txT[$0], ty: tyT[$0], rot: rotT[$0], scale: scT[$0]) }
            baseline = rawPath.indices.map { State(tx: txB[$0], ty: tyB[$0], rot: rotB[$0], scale: scB[$0]) }
        }

        // Native engine selects the smoother. L1 = locked/cinematic (piecewise-linear);
        // Gaussian = organic (follows the camera). smoothness maps to each one's strength.
        let lambda = pow(10.0, 1.0 + smoothness * 3.5)        // L1 penalty
        let sigma  = 1 + smoothness * 59                       // Gaussian window (wider than before for low-freq bob)
        func smoothChannel(_ xs: [Double]) -> [Double] {
            engine == .smooth ? gaussianSmooth(xs, sigma: sigma) : l1Smooth(xs, lambda: lambda)
        }
        var txS = smoothChannel(path.map(\.tx))
        var tyS = smoothChannel(path.map(\.ty))
        var rotS = method == .position ? path.map { _ in 0.0 } : smoothChannel(path.map(\.rot))
        var scS  = method == .position ? path.map { _ in path.first!.scale } : smoothChannel(path.map(\.scale))

        // Hard lock: pin the POSITION to a fixed point (e.g. the seed-frame centroid) so the object is
        // held in place rather than following a smoothed version of its travel. Rotation/scale stay on
        // the gentle smoothed follow — hard-pinning them fights the noisy points-fit rotation/scale and
        // makes the frame spin. The denoised raw above keeps the position pin smooth.
        if let pin = pinTarget {
            let p = decompose(pin)
            txS = Array(repeating: p.tx, count: path.count)
            tyS = Array(repeating: p.ty, count: path.count)
        }

        // 3. Correction = smoothed target − baseline, expressed as a homography. Differencing against
        //    `baseline` (raw at spike frames, denoised elsewhere) corrects bumps without reinjecting noise.
        var corrections: [StabFrameTransform] = []
        var maxAbsTx = 0.0, maxAbsTy = 0.0, maxAbsRot = 0.0
        for k in path.indices {
            var cor = State(tx: txS[k] - baseline[k].tx,
                            ty: tyS[k] - baseline[k].ty,
                            rot: (method == .position) ? 0 : rotS[k] - baseline[k].rot,
                            scale: (method == .position) ? 1 : scS[k] / max(baseline[k].scale, 1e-9))
            // Defense-in-depth: NaN-safe clamp so no non-finite value can reach a correction matrix.
            cor.tx = safeClamp(cor.tx, -0.25, 0.25)
            cor.ty = safeClamp(cor.ty, -0.25, 0.25)
            cor.rot = safeClamp(cor.rot, -0.35, 0.35)
            cor.scale = cor.scale.isFinite ? min(max(cor.scale, 0.5), 2.0) : 1.0
            // Object tracking pivots rotation/scale about the object's own centroid (its raw position).
            let (px, py) = objectPivot ? (baseline[k].tx, baseline[k].ty) : (0.5, 0.5)
            corrections.append(compose(cor, cx: px, cy: py))
            maxAbsTx = max(maxAbsTx, abs(cor.tx))
            maxAbsTy = max(maxAbsTy, abs(cor.ty))
            maxAbsRot = max(maxAbsRot, abs(cor.rot))
        }

        // 4. Crop zoom: cover translation + rotation-induced corner displacement, but cap it —
        //    an aggressive zoom is more objectionable than a sliver of exposed edge on big shakes.
        let rotMargin = sin(min(maxAbsRot, 0.35))
        let cropZoom = cropToFit ? min(1.25, 1 + 2 * (max(maxAbsTx, maxAbsTy) + rotMargin)) : 1.0
        return Result(corrections: corrections, cropZoom: max(1.0, cropZoom))
    }

    /// L1 trend filter: returns a path p minimizing Σ|p−x| + λ·Σ|Δ²p| (data + second-difference,
    /// both L1). Produces piecewise-linear segments — the cinematic "constant-velocity" look —
    /// rather than the blur of a Gaussian. Solved by IRLS: repeated reweighted least-squares,
    /// each solved exactly via banded Cholesky on the pentadiagonal normal equations.
    static func l1Smooth(_ x: [Double], lambda: Double, irls: Int = 8) -> [Double] {
        let n = x.count
        guard n >= 3 else { return x }
        var p = x
        let eps = 1e-6

        for _ in 0..<irls {
            // IRLS weights: wD[i] = 1/|p[i]−x[i]|,  wS[k] = 1/|Δ²p[k]|  (k ∈ 1..<n-1).
            var wD = [Double](repeating: 0, count: n)
            for i in 0..<n { wD[i] = 1.0 / max(eps, abs(p[i] - x[i])) }
            var wS = [Double](repeating: 0, count: n)   // wS[0] = wS[n-1] = 0
            for k in 1..<(n - 1) {
                wS[k] = 1.0 / max(eps, abs(p[k-1] - 2*p[k] + p[k+1]))
            }

            // Build the pentadiagonal SPD system A p = b  (upper triangle stored).
            // A[i,i]   = wD[i] + λ(wS[i-1] + 4·wS[i] + wS[i+1])
            // A[i,i+1] = −2λ(wS[i] + wS[i+1])
            // A[i,i+2] =  λ·wS[i+1]
            var d  = [Double](repeating: 0, count: n)
            var s1 = [Double](repeating: 0, count: n)   // A[i,i+1]
            var s2 = [Double](repeating: 0, count: n)   // A[i,i+2]
            var b  = [Double](repeating: 0, count: n)
            for i in 0..<n {
                let wSm = i > 0   ? wS[i-1] : 0.0
                let wSp = i < n-1 ? wS[i+1] : 0.0
                d[i] = wD[i] + lambda * (wSm + 4*wS[i] + wSp)
                b[i] = wD[i] * x[i]
            }
            for i in 0..<(n-1) { s1[i] = -2*lambda*(wS[i] + wS[i+1]) }
            for i in 0..<(n-2) { s2[i] =    lambda * wS[i+1]          }

            // Banded Cholesky  A = L Lᵀ  (L lower, half-bandwidth 2).
            // ld[i]=L[i,i],  ls1[i]=L[i+1,i],  ls2[i]=L[i+2,i].
            var ld  = d
            var ls1 = [Double](repeating: 0, count: n)
            var ls2 = [Double](repeating: 0, count: n)
            var ok  = true
            for i in 0..<n {
                if i >= 1 { ld[i] -= ls1[i-1]*ls1[i-1] }
                if i >= 2 { ld[i] -= ls2[i-2]*ls2[i-2] }
                guard ld[i] > eps else { ok = false; break }
                ld[i] = ld[i].squareRoot()
                if i+1 < n {
                    var v = s1[i]
                    if i >= 1 { v -= ls2[i-1]*ls1[i-1] }
                    ls1[i] = v / ld[i]
                }
                if i+2 < n { ls2[i] = s2[i] / ld[i] }
            }
            guard ok else { continue }

            // Forward solve  L y = b,  then back-solve  Lᵀ p = y.
            var y = b
            for i in 0..<n {
                if i >= 1 { y[i] -= ls1[i-1]*y[i-1] }
                if i >= 2 { y[i] -= ls2[i-2]*y[i-2] }
                y[i] /= ld[i]
            }
            p = y
            for i in stride(from: n-1, through: 0, by: -1) {
                if i+1 < n { p[i] -= ls1[i]*p[i+1] }
                if i+2 < n { p[i] -= ls2[i]*p[i+2] }
                p[i] /= ld[i]
            }
        }
        return p
    }
}
