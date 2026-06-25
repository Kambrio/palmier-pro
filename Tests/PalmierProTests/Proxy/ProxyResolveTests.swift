import Foundation
import Testing
@testable import PalmierPro

@Suite("MediaResolver — proxy lookup")
struct ProxyResolveTests {
    @Test func proxyURLReturnsFileWhenPresentElseNil() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("media/proxies"), withIntermediateDirectories: true)
        let proxy = base.appendingPathComponent("media/proxies/asset1.mov")
        try Data([0]).write(to: proxy)

        var manifest = MediaManifest()
        manifest.entries = [MediaManifestEntry(id: "asset1", name: "a", type: .video,
            source: .project(relativePath: "media/asset1.mov"), duration: 1,
            proxyPath: "media/proxies/asset1.mov")]
        let resolver = MediaResolver(manifest: { manifest }, projectURL: { base })

        #expect(resolver.proxyURL(for: "asset1") == proxy)
        #expect(resolver.proxyURL(for: "missing") == nil)
    }
}
