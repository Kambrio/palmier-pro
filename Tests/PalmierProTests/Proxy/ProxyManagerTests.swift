import Foundation
import Testing
@testable import PalmierPro

@MainActor
@Suite("ProxyManager")
struct ProxyManagerTests {
    @Test func assetsNeedingProxiesExcludesNonVideo() {
        let editor = EditorViewModel()
        let v = MediaAsset(id: "v", url: URL(fileURLWithPath: "/tmp/v.mov"), type: .video, name: "v", duration: 1)
        let a = MediaAsset(id: "a", url: URL(fileURLWithPath: "/tmp/a.m4a"), type: .audio, name: "a", duration: 1)
        editor.importMediaAsset(v)
        editor.importMediaAsset(a)
        let mgr = ProxyManager(editor: editor)
        #expect(mgr.assetsNeedingProxies().map(\.id) == ["v"])
    }

    @Test func diskUsageAndDelete() throws {
        let editor = EditorViewModel()
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let proxies = base.appendingPathComponent("media/proxies")
        try FileManager.default.createDirectory(at: proxies, withIntermediateDirectories: true)
        let proxyFile = proxies.appendingPathComponent("v.mov")
        try Data(repeating: 7, count: 1234).write(to: proxyFile)
        editor.projectURL = base
        let v = MediaAsset(id: "v", url: URL(fileURLWithPath: "/tmp/v.mov"), type: .video, name: "v", duration: 1)
        v.proxyState = .ready
        editor.importMediaAsset(v)
        editor.mediaManifest.entries[0].proxyPath = "media/proxies/v.mov"
        let mgr = ProxyManager(editor: editor)

        #expect(mgr.proxyDiskUsage() == 1234)
        mgr.deleteProxies()
        #expect(mgr.proxyDiskUsage() == 0)
        #expect(FileManager.default.fileExists(atPath: proxyFile.path) == false)
        #expect(editor.mediaManifest.entries[0].proxyPath == nil)
        #expect(v.proxyState == .none)
    }
}
