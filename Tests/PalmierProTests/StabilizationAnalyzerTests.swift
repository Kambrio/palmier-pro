import Testing
import AVFoundation
@testable import PalmierPro

struct StabilizationAnalyzerTests {
    // A whole-frame pan must yield a SANE camera path: bounded, smooth, and non-trivial.
    // This guards the normalization bug where a few-pixel shift read as several frame-widths,
    // producing tx ≈ 2966 and frame-to-frame jumps of ~185 (→ black / jumping preview).
    @Test func recoversBoundedSmoothPan() async throws {
        let url = try await TestClip.makeGlobalPanClip(frames: 24, pxPerFrame: 3, size: 400)
        defer { try? FileManager.default.removeItem(at: url) }
        let (_, frames) = try await StabilizationAnalyzer.analyze(url: url, progress: { _ in })
        #expect(frames.count >= 22)

        let txs = frames.map { $0.m[2] }
        let tys = frames.map { $0.m[5] }

        // 1. Finite.
        #expect(frames.allSatisfy { $0.m.allSatisfy { $0.isFinite } })
        // 2. Bounded — a real normalized path stays within a couple frame-widths, never thousands.
        #expect((txs + tys).allSatisfy { abs($0) < 1.0 })
        // 3. Smooth — no frame-to-frame jump anywhere near the old garbage (185); handheld ≤ clamp.
        let maxJump = zip(txs.dropFirst(), txs).map { abs($0 - $1) }.max() ?? 0
        #expect(maxJump <= 0.09)
        // 4. Non-trivial — a steady pan actually registers some motion.
        #expect(abs((txs.last ?? 0) - (txs.first ?? 0)) > 0.01)
    }
}
