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
        // NaN-safe clamp: non-finite input yields the midpoint (or 1.0 for scale handled below).
        func safeClamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
            guard v.isFinite else { return (lo + hi) / 2 }
            return min(max(v, lo), hi)
        }
        let idx = Array(window).filter { $0 >= 0 && $0 < raw.count }
        guard !idx.isEmpty else { return Result(corrections: [], cropZoom: 1.0) }

        // 1. Decompose each raw frame into the camera path (already absolute/cumulative).
        let path = idx.map { decompose(raw[$0]) }

        // 2. L1 trend-filter each channel → piecewise-linear (constant-velocity) path.
        //    smoothness 0…1 → lambda ~10…~5600; higher = flatter, removes more low-freq bob.
        let lambda = pow(10.0, 1.0 + smoothness * 3.5)
        let txS = l1Smooth(path.map(\.tx), lambda: lambda)
        let tyS = l1Smooth(path.map(\.ty), lambda: lambda)
        let rotS = method == .position ? path.map { _ in 0.0 } : l1Smooth(path.map(\.rot), lambda: lambda)
        let scS  = method == .position ? path.map { _ in path.first!.scale }
                                       : l1Smooth(path.map(\.scale), lambda: lambda)

        // 3. Correction = smoothed − raw, expressed as a homography.
        var corrections: [StabFrameTransform] = []
        var maxAbsTx = 0.0, maxAbsTy = 0.0, maxAbsRot = 0.0
        for k in path.indices {
            var cor = State(tx: txS[k] - path[k].tx,
                            ty: tyS[k] - path[k].ty,
                            rot: (method == .position) ? 0 : rotS[k] - path[k].rot,
                            scale: (method == .position) ? 1 : scS[k] / max(path[k].scale, 1e-9))
            // Defense-in-depth: NaN-safe clamp so no non-finite value can reach a correction matrix.
            cor.tx = safeClamp(cor.tx, -0.25, 0.25)
            cor.ty = safeClamp(cor.ty, -0.25, 0.25)
            cor.rot = safeClamp(cor.rot, -0.35, 0.35)
            cor.scale = cor.scale.isFinite ? min(max(cor.scale, 0.5), 2.0) : 1.0
            corrections.append(compose(cor))
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
