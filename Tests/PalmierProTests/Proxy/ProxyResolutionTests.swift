import Foundation
import Testing
@testable import PalmierPro

@Suite("ProxyResolution")
struct ProxyResolutionTests {
    @Test func shortSidesAreStandard() {
        #expect(ProxyResolution.p240.shortSide == 240)
        #expect(ProxyResolution.p720.shortSide == 720)
        #expect(ProxyResolution.p1080.shortSide == 1080)
    }

    // Landscape 6144x3456 at 720p -> short side 720, long side 1280, even.
    @Test func targetSizePreservesAspectAndIsEven() {
        let s = ProxyResolution.p720.targetSize(forSource: CGSize(width: 6144, height: 3456))
        #expect(s.height == 720)
        #expect(s.width == 1280)
        #expect(Int(s.width) % 2 == 0 && Int(s.height) % 2 == 0)
    }

    // Never upscale: a 480-tall source stays 480 at 720p.
    @Test func neverUpscales() {
        let s = ProxyResolution.p720.targetSize(forSource: CGSize(width: 854, height: 480))
        #expect(s.height == 480)
    }
}
