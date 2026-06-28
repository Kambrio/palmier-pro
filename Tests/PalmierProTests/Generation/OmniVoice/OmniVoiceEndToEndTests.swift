import Foundation
import Testing
@testable import PalmierPro

@Suite("OmniVoice end-to-end (opt-in)")
struct OmniVoiceEndToEndTests {

    /// Runs only when PALMIER_OMNIVOICE_E2E=1 AND a usable runtime resolves.
    @Test func synthesizesAWav() async throws {
        guard ProcessInfo.processInfo.environment["PALMIER_OMNIVOICE_E2E"] == "1" else { return }
        guard let python = OmniVoiceLocator().resolve(override: nil) else { return }

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("ov-e2e-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: out) }

        let job = OmniVoiceJob(
            language: "English",
            segments: [OmniVoiceSegment(text: "Hello from Palmier.", output: out.path)]
        )
        let produced = try await OmniVoiceGenerationProvider.generate(job: job, python: python)
        #expect(produced == [out.path])
        let size = try FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int ?? 0
        #expect(size > 1000)
    }
}
