import Foundation
import Testing
@testable import PalmierPro

@Suite("OmniVoiceProvisioner")
struct OmniVoiceProvisionerTests {

    /// A failing setup step must annotate WHICH step failed and include the runner's
    /// stderr, so a provisioning failure is actionable instead of an opaque error.
    @Test func provisionAnnotatesWhichStepFailed() async {
        let provisioner = OmniVoiceProvisioner(
            uvPath: URL(fileURLWithPath: "/tmp/uv"),
            installRoot: URL(fileURLWithPath: "/tmp/ov-install"),
            hfCache: URL(fileURLWithPath: "/tmp/ov-hf"),
            pythonPin: "3.13",
            omniVoiceVersion: "0.1.5",
            run: { step in
                if step.argv.contains("venv") {
                    throw CLIProcessError.nonZeroExit(code: 1, stderr: "boom from uv")
                }
            })
        do {
            _ = try await provisioner.provision { _, _ in }
            Issue.record("provision should have thrown")
        } catch {
            let msg = error.localizedDescription
            #expect(msg.contains("Creating environment"), "error should name the failing step: \(msg)")
            #expect(msg.contains("boom from uv"), "error should include the runner stderr: \(msg)")
        }
    }
}
