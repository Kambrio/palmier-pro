import Testing
import Foundation
@testable import PalmierPro

struct StabilizationPersistenceTests {
    // Guards the custom Clip decoder: stabilization must survive a JSON round-trip.
    @Test func clipStabilizationSurvivesRoundTrip() throws {
        var clip = Clip(mediaRef: "asset-1", startFrame: 0, durationFrames: 30)
        clip.stabilization = Stabilization(
            enabled: true, method: .perspective, smoothness: 0.8, cropToFit: false)

        let data = try JSONEncoder().encode(clip)
        let decoded = try JSONDecoder().decode(Clip.self, from: data)

        #expect(decoded.stabilization == clip.stabilization)
        #expect(decoded.stabilization?.method == .perspective)
        #expect(decoded.stabilization?.smoothness == 0.8)
        #expect(decoded.stabilization?.cropToFit == false)
    }

    @Test func clipWithoutStabilizationDecodesNil() throws {
        let clip = Clip(mediaRef: "asset-2", startFrame: 0, durationFrames: 10)
        let data = try JSONEncoder().encode(clip)
        let decoded = try JSONDecoder().decode(Clip.self, from: data)
        #expect(decoded.stabilization == nil)
    }
}
