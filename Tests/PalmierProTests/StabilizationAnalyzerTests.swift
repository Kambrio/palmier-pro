import Testing
import AVFoundation
@testable import PalmierPro

struct StabilizationAnalyzerTests {
    // A clip that pans steadily should yield a monotonic, non-zero horizontal camera path.
    @Test func recoversHorizontalPan() async throws {
        let url = try await TestClip.makePanningClip(frames: 20, pxPerFrame: 6)
        defer { try? FileManager.default.removeItem(at: url) }
        let (_, frames) = try await StabilizationAnalyzer.analyze(url: url, progress: { _ in })
        #expect(frames.count >= 18)
        // Absolute path: later frames should have drifted horizontally from frame 0.
        let firstTx = frames.first?.m[2] ?? 0
        let lastTx = frames.last?.m[2] ?? 0
        #expect(abs(lastTx - firstTx) > 0.01)
    }
}
