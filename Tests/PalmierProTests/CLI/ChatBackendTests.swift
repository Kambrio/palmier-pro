import Foundation
import Testing
@testable import PalmierPro

@Suite("ChatBackend")
struct ChatBackendTests {

    @Test func effectiveUsesSelectedWhenAvailable() {
        let avail: Set<ChatBackend> = [.apiKey, .palmier, .claudeCLI]
        #expect(ChatBackend.effective(selected: .claudeCLI, available: avail) == .claudeCLI)
    }

    @Test func effectiveFallsBackWhenSelectedUnavailable() {
        let avail: Set<ChatBackend> = [.palmier]
        #expect(ChatBackend.effective(selected: .claudeCLI, available: avail) == .palmier)
    }

    @Test func effectiveIsNilWhenNothingAvailable() {
        #expect(ChatBackend.effective(selected: .apiKey, available: []) == nil)
    }

    @Test func fallbackOrderPrefersApiKeyThenPalmierThenCLI() {
        #expect(ChatBackend.effective(selected: .palmier,
                                      available: [.apiKey, .claudeCLI]) == .apiKey)
        #expect(ChatBackend.effective(selected: .palmier,
                                      available: [.claudeCLI]) == .claudeCLI)
    }

    @Test func claudeCLIDefaultsToHaiku() {
        UserDefaults.standard.removeObject(forKey: "io.palmier.pro.chat.cli.model")
        #expect(ClaudeCLIModelPreference.value == .haiku45)
    }
}
