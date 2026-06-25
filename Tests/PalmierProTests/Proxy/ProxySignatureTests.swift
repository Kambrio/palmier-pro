import Foundation
import Testing
@testable import PalmierPro

@Suite("ProxySignature")
struct ProxySignatureTests {
    @Test func stableForSameFileAndChangesWithContent() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("a.bin")
        try Data([1, 2, 3]).write(to: url)
        let s1 = ProxySignature.of(url)
        #expect(s1 != nil)
        #expect(ProxySignature.of(url) == s1)            // stable
        try Data([1, 2, 3, 4, 5]).write(to: url)         // size change
        #expect(ProxySignature.of(url) != s1)
    }

    @Test func nilForMissingFile() {
        #expect(ProxySignature.of(URL(fileURLWithPath: "/no/such/file.mov")) == nil)
    }
}
