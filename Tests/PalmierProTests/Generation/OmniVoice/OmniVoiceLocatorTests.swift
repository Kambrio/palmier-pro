import Foundation
import Testing
@testable import PalmierPro

@Suite("OmniVoiceLocator")
struct OmniVoiceLocatorTests {
    private let provisioned = URL(fileURLWithPath: "/as/.venv/bin/python3")
    private let dev = URL(fileURLWithPath: "/home/dev/.venv/bin/python3")
    private let override = URL(fileURLWithPath: "/custom/python3")

    private func locator(usable: Set<String>) -> OmniVoiceLocator {
        OmniVoiceLocator(
            provisionedPython: provisioned,
            devPython: dev,
            isUsable: { usable.contains($0.path) }
        )
    }

    @Test func prefersOverrideWhenUsable() {
        let l = locator(usable: [override.path, provisioned.path, dev.path])
        #expect(l.resolve(override: override) == override)
    }

    @Test func fallsThroughUnusableOverrideToProvisioned() {
        let l = locator(usable: [provisioned.path])
        #expect(l.resolve(override: override) == provisioned)
    }

    @Test func usesDevWhenNothingElse() {
        let l = locator(usable: [dev.path])
        #expect(l.resolve(override: nil) == dev)
    }

    @Test func returnsNilWhenNoneUsable() {
        let l = locator(usable: [])
        #expect(l.resolve(override: override) == nil)
    }
}
