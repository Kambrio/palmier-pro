import AVFoundation
import Testing
@testable import PalmierPro

@Suite("ProxyService")
struct ProxyServiceTests {
    // Build a 1280x720 source, transcode to 360p proxy, assert codec + size.
    @Test func transcodesToProResProxyAtTargetShortSide() async throws {
        let src = try await CompositorFixtures.makeSolidVideo(width: 1280, height: 720, seconds: 1)
        defer { try? FileManager.default.removeItem(at: src) }
        let out = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: out) }

        try await ProxyService.transcode(source: src, to: out, resolution: .p360) { _ in }

        let asset = AVURLAsset(url: out)
        let track = try await asset.loadTracks(withMediaType: .video).first
        let size = try await track?.load(.naturalSize)
        #expect(size?.height == 360)
        #expect(size?.width == 640)
        let formats = try await track?.load(.formatDescriptions) ?? []
        let codec = formats.first.map { CMFormatDescriptionGetMediaSubType($0) }
        #expect(codec == kCMVideoCodecType_AppleProRes422Proxy)
    }

    // A source WITH audio must transcode without deadlocking. (Video-only fixtures hid
    // a multi-output AVAssetReader stall.) The time limit turns a hang into a failure.
    @Test(.timeLimit(.minutes(1)))
    func transcodesSourceWithAudioWithoutDeadlock() async throws {
        let src = try await CompositorFixtures.makeSolidVideoWithAudio(width: 1280, height: 720, seconds: 1)
        defer { try? FileManager.default.removeItem(at: src) }
        let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: out) }

        try await ProxyService.transcode(source: src, to: out, resolution: .p360) { _ in }

        let asset = AVURLAsset(url: out)
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        #expect(video.count == 1)
        #expect(audio.count == 1)   // audio carried through
        let codec = try await (video.first?.load(.formatDescriptions) ?? []).first.map { CMFormatDescriptionGetMediaSubType($0) }
        #expect(codec == kCMVideoCodecType_AppleProRes422Proxy)
    }
}
