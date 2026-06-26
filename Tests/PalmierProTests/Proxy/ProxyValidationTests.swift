import Testing
import AVFoundation
import Foundation
@testable import PalmierPro

struct ProxyValidationTests {
    @Test func detectsUnfinalizedMovieAsNotOpenable() async throws {
        // A movie header with ftyp + mdat but NO moov atom = unfinalized, unopenable.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mov")
        // ftyp 'qt  ' box + a tiny mdat box, no moov.
        let bytes: [UInt8] = [
            0,0,0,0x14, 0x66,0x74,0x79,0x70, 0x71,0x74,0x20,0x20, 0,0,0,0, 0x71,0x74,0x20,0x20, // ftyp
            0,0,0,0x10, 0x6d,0x64,0x61,0x74, 0,0,0,0, 0,0,0,0                                    // mdat (8 bytes payload)
        ]
        try Data(bytes).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let openable = await ProxyService.isOpenableVideo(url)
        #expect(openable == false)
    }

    @Test func detectsValidMovieAsOpenable() async throws {
        // Reuse the test-clip generator (exists from stabilization tests).
        let url = try await TestClip.makePanningClip(frames: 6, pxPerFrame: 4, size: 128)
        defer { try? FileManager.default.removeItem(at: url) }
        let openable = await ProxyService.isOpenableVideo(url)
        #expect(openable == true)
    }
}
