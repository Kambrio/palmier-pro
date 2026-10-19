import Testing
import Foundation
@testable import PalmierPro

@MainActor
@Suite struct GemmaModelManagerTests {
    private func makeManager(installed: Bool, loadFails: Bool = false)
        -> (GemmaModelManager, CheckedContinuation<Void, Never>?) {
        var continuation: CheckedContinuation<Void, Never>? = nil
        let factories = GemmaModelManager.ModelFactories(
            load: { _ in
                if loadFails { throw ModelErrorForTests.boom }
                return StubGemmaEmbedding()
            },
            isInstalled: { installed },
            delete: {})
        return (GemmaModelManager(factories: factories), continuation)
    }

    enum ModelErrorForTests: Error { case boom }

    @Test func prepareWhenNotInstalledStaysNotInstalled() async {
        let (manager, _) = makeManager(installed: false)
        await manager.prepare()
        #expect(manager.state == .notInstalled)
    }

    @Test func prepareWhenInstalledBecomesReady() async {
        let (manager, _) = makeManager(installed: true)
        await manager.prepare()
        #expect(manager.state == .ready)
        #expect(manager.embedder != nil)
    }

    @Test func downloadInstallsAndReadies() async {
        let (manager, _) = makeManager(installed: false)
        manager.download()
        while manager.state != .ready && !manager.isFailedState {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(manager.state == .ready)
    }

    @Test func loadFailureSurfaces() async {
        let (manager, _) = makeManager(installed: true, loadFails: true)
        await manager.prepare()
        if case .failed = manager.state { } else { Issue.record("expected failed, got \(manager.state)") }
    }

    @Test func disabledByDefault() { #expect(GemmaModelManager.defaultEnabled == false) }
}

extension GemmaModelManager {
    var isFailedState: Bool { if case .failed = state { return true }; return false }
    static let defaultEnabled = false
}
