import Testing
import AVFoundation
import Foundation
@testable import PalmierPro

struct ProxyTranscodeTests {
    // A successful transcode must publish an OPENABLE file and leave no .tmp behind.
    @Test func transcodePublishesOpenableProxyAtomically() async throws {
        let src = try await TestClip.makePanningClip(frames: 12, pxPerFrame: 3, size: 320)
        defer { try? FileManager.default.removeItem(at: src) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("proxy.mov")

        try await ProxyService.transcode(source: src, to: out, resolution: .p360) { _ in }

        #expect(await ProxyService.isOpenableVideo(out))
        // No leftover temp files in the directory.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(".tmp-") }
        #expect(leftovers.isEmpty)
    }

    // Several concurrent transcodes must ALL publish openable files (the bug repro: concurrency).
    @Test func concurrentTranscodesAllOpenable() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var outs: [URL] = []
        try await withThrowingTaskGroup(of: URL.self) { group in
            for i in 0..<5 {
                group.addTask {
                    let src = try await TestClip.makePanningClip(frames: 10, pxPerFrame: 2, size: 256)
                    defer { try? FileManager.default.removeItem(at: src) }
                    let out = dir.appendingPathComponent("p\(i).mov")
                    try await ProxyService.transcode(source: src, to: out, resolution: .p360) { _ in }
                    return out
                }
            }
            for try await u in group { outs.append(u) }
        }
        #expect(outs.count == 5)
        for u in outs { #expect(await ProxyService.isOpenableVideo(u)) }
    }
}
