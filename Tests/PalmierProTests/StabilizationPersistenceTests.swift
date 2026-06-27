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

    // subjectSeed is absent on older stabilization JSON → decodeIfPresent falls back to nil.
    @Test func subjectSeedDecodeFallsBackToNil() throws {
        let json = #"{"enabled":true,"engine":"subject","method":"position","smoothness":0.5,"cropToFit":true}"#
        let decoded = try JSONDecoder().decode(Stabilization.self, from: Data(json.utf8))
        #expect(decoded.subjectSeed == nil)
        #expect(decoded.engine == .subject)
    }

    @Test func subjectSeedRoundTrips() throws {
        var stab = Stabilization(enabled: true, engine: .subject)
        stab.subjectSeed = SubjectSeed(
            frame: 12, box: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4), label: "person")
        let data = try JSONEncoder().encode(stab)
        let decoded = try JSONDecoder().decode(Stabilization.self, from: data)
        #expect(decoded.subjectSeed == stab.subjectSeed)
        #expect(decoded.subjectSeed?.frame == 12)
        #expect(decoded.subjectSeed?.label == "person")
    }

    @Test func subjectSeedKeyIsStable() {
        let a = SubjectSeed(frame: 5, box: CGRect(x: 0.1234, y: 0.2, width: 0.3, height: 0.4), label: "dog")
        let b = SubjectSeed(frame: 5, box: CGRect(x: 0.5678, y: 0.2, width: 0.3, height: 0.4), label: "dog")
        // Same inputs → same key; a different box (at 4dp) → a different key.
        #expect(a.seedKey == SubjectSeed(frame: 5, box: a.box, label: "dog").seedKey)
        #expect(a.seedKey != b.seedKey)
        // Sub-4dp jitter rounds away, so the key is stable.
        let jittered = SubjectSeed(frame: 5, box: CGRect(x: 0.12341, y: 0.2, width: 0.3, height: 0.4), label: "dog")
        #expect(a.seedKey == jittered.seedKey)
        #expect(a.seedKey.contains("dog"))
    }
}
