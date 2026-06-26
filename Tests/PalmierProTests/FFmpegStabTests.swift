import Testing
import AVFoundation
import Foundation
@testable import PalmierPro

struct FFmpegStabTests {
    @Test func deshakeProducesOpenableStabilizedFile() async throws {
        guard let ffmpeg = await MainActor.run(body: { VidStab.ffmpegPath() }) else { return }  // skip if no ffmpeg
        let _ = await MainActor.run { () -> VidStab.Capability in VidStab.detectIfNeeded(); return .deshake }
        let src = try await TestClip.makeGlobalPanClip(frames: 16, pxPerFrame: 3, size: 320)
        defer { try? FileManager.default.removeItem(at: src) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("stab.mov")
        try await FFmpegStabService.stabilize(source: src, to: out, smoothness: 0.5, capability: .deshake, ffmpeg: ffmpeg, progress: { _ in })
        #expect(await ProxyService.isOpenableVideo(out))
        // No temp leftovers.
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.filter { $0.hasPrefix(".tmp-") || $0.hasPrefix(".trf-") } ?? []
        #expect(leftovers.isEmpty)
    }
}
