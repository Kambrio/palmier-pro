import Testing
import Foundation
@testable import PalmierPro

@MainActor
@Suite struct GemmaModelManagerTests {
    private func makeManager(installed: Bool, loadFails: Bool = false, enabled: Bool = false)
        -> GemmaModelManager {
        let factories = GemmaModelManager.ModelFactories(
            load: { _ in
                if loadFails { throw ModelErrorForTests.boom }
                return StubGemmaEmbedding()
            },
            isInstalled: { installed },
            delete: {})
        let manager = GemmaModelManager(factories: factories)
        if enabled { manager.setEnabledInternal(true) }
        return manager
    }

    enum ModelErrorForTests: Error { case boom }

    @Test func prepareWhenNotInstalledStaysNotInstalled() async {
        let manager = makeManager(installed: false, enabled: true)
        await manager.prepare()
        #expect(manager.state == .notInstalled)
    }

    @Test func prepareWhenInstalledBecomesReady() async {
        let manager = makeManager(installed: true, enabled: true)
        await manager.prepare()
        #expect(manager.state == .ready)
        #expect(manager.embedder != nil)
    }

    @Test func disabledPrepareStaysUnknown() async {
        let manager = makeManager(installed: true, enabled: false)
        await manager.prepare()
        #expect(manager.state == .unknown)
    }

    @Test func downloadInstallsAndReadies() async {
        let manager = makeManager(installed: false, enabled: true)
        manager.download()
        while manager.state != .ready && !manager.isFailedState {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(manager.state == .ready)
    }

    @Test func loadFailureSurfaces() async {
        let manager = makeManager(installed: true, loadFails: true, enabled: true)
        await manager.prepare()
        if case .failed = manager.state { } else { Issue.record("expected failed, got \(manager.state)") }
    }

    @Test func overlappingPrepareLoadsModelOnce() async {
        let counter = LoadCounter()
        let factories = GemmaModelManager.ModelFactories(
            load: { _ in
                counter.increment()
                return StubGemmaEmbedding()
            },
            isInstalled: {
                Thread.sleep(forTimeInterval: 0.1) // hold the window both callers race through
                return true
            },
            delete: {})
        let manager = GemmaModelManager(factories: factories)
        manager.setEnabledInternal(true)
        async let first: Void = manager.prepare()
        async let second: Void = manager.prepare()
        _ = await (first, second)
        #expect(manager.state == .ready)
        #expect(counter.value == 1)
        #expect(manager.embedder != nil)
    }

    @Test func setEnabledFalseDuringPreparingEndsUnknown() async {
        let gate = AsyncSemaphore()
        let factories = GemmaModelManager.ModelFactories(
            load: { _ in
                await gate.wait()
                return StubGemmaEmbedding()
            },
            isInstalled: { true },
            delete: {})
        let manager = GemmaModelManager(factories: factories)
        manager.setEnabledInternal(true)
        let preparing = Task { await manager.prepare() }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(manager.state == .preparing)
        manager.setEnabled(false)
        gate.open()
        await preparing.value
        try? await Task.sleep(for: .milliseconds(50)) // let the disable task finish its reset
        #expect(manager.state == .unknown)
        #expect(manager.embedder == nil)
    }

    @Test func disabledByDefault() {
        UserDefaults.standard.removeObject(forKey: GemmaModelManager.defaultsKey)
        #expect(GemmaModelManager(factories: .live).enabled == false)
    }
}

extension GemmaModelManager {
    var isFailedState: Bool { if case .failed = state { return true }; return false }
}

/// Counts factory loads across concurrent tasks; NSLock keeps it Sendable-safe.
private final class LoadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); defer { lock.unlock() }; count += 1 }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

/// One-shot async gate for pausing a stub factory load.
private final class AsyncSemaphore: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    func open() { lock.lock(); defer { lock.unlock() }; opened = true }
    func wait() async {
        while !isOpen() { try? await Task.sleep(for: .milliseconds(5)) }
    }
    private func isOpen() -> Bool { lock.lock(); defer { lock.unlock() }; return opened }
}
