import Foundation
import Testing
@testable import PalmierPro

@Suite("OmniVoiceProvisioner")
struct OmniVoiceProvisionerTests {

    private func makeProvisioner(record: @escaping @Sendable (OmniVoiceProvisioner.Step) -> Void) -> OmniVoiceProvisioner {
        OmniVoiceProvisioner(
            uvPath: URL(fileURLWithPath: "/bundle/uv"),
            installRoot: URL(fileURLWithPath: "/as/OmniVoice"),
            hfCache: URL(fileURLWithPath: "/as/OmniVoice/hf-cache"),
            pythonPin: "3.13",
            omniVoiceVersion: "0.1.5",
            run: { step in record(step) }
        )
    }

    @Test func runsStepsInOrderWithExpectedArgv() async throws {
        let box = StepBox()
        let progress = ProgressBox()
        let p = makeProvisioner(record: { box.append($0) })
        let python = try await p.provision { value, _ in progress.append(value) }

        let steps = box.steps
        #expect(steps.count == 4)
        #expect(steps[0].argv == ["python", "install", "3.13"])
        #expect(steps[1].argv == ["venv", "--python", "3.13", "/as/OmniVoice/.venv"])
        #expect(steps[2].argv == ["pip", "install", "--python", "/as/OmniVoice/.venv/bin/python3", "omnivoice==0.1.5"])
        #expect(steps[3].argv.prefix(3) == ["run", "--python", "/as/OmniVoice/.venv/bin/python3"])
        #expect(steps[3].env["HF_HOME"] == "/as/OmniVoice/hf-cache")

        #expect(python == URL(fileURLWithPath: "/as/OmniVoice/.venv/bin/python3"))
        #expect(progress.values.last == 1.0)
        #expect(progress.values == progress.values.sorted())
    }

    @Test func failingStepThrowsAndStops() async {
        let box = StepBox()
        let p = OmniVoiceProvisioner(
            uvPath: URL(fileURLWithPath: "/bundle/uv"),
            installRoot: URL(fileURLWithPath: "/as/OmniVoice"),
            hfCache: URL(fileURLWithPath: "/as/OmniVoice/hf-cache"),
            pythonPin: "3.13",
            omniVoiceVersion: "0.1.5",
            run: { step in
                box.append(step)
                if step.argv.first == "venv" { throw CLIProcessError.nonZeroExit(code: 1, stderr: "no python") }
            }
        )
        await #expect(throws: (any Error).self) {
            _ = try await p.provision { _, _ in }
        }
        #expect(box.steps.count == 2)
    }
}

private final class StepBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _steps: [OmniVoiceProvisioner.Step] = []
    func append(_ s: OmniVoiceProvisioner.Step) { lock.lock(); _steps.append(s); lock.unlock() }
    var steps: [OmniVoiceProvisioner.Step] { lock.lock(); defer { lock.unlock() }; return _steps }
}

private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Double] = []
    func append(_ v: Double) { lock.lock(); _values.append(v); lock.unlock() }
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return _values }
}
