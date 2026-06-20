import Foundation
import Testing
@testable import PalmierPro

@Suite("FCPTime")
struct FCPTimeTests {
    @Test func parsesWholeSeconds() {
        #expect(FCPTime.seconds("5s") == 5.0)
        #expect(FCPTime.seconds("0s") == 0.0)
    }

    @Test func parsesRationalSeconds() {
        #expect(FCPTime.seconds("116/24s") == 116.0 / 24.0)
        #expect(FCPTime.seconds("30000/1001s") == 30000.0 / 1001.0)
    }

    @Test func toleratesMissingSuffixAndWhitespace() {
        #expect(FCPTime.seconds(" 3 ") == 3.0)
    }

    @Test func returnsNilOnGarbage() {
        #expect(FCPTime.seconds("abc") == nil)
        #expect(FCPTime.seconds("1/0s") == nil)   // divide by zero
        #expect(FCPTime.seconds("") == nil)
    }

    @Test func convertsToFramesRounded() {
        #expect(FCPTime.frames("116/24s", fps: 24) == 116)
        #expect(FCPTime.frames("5s", fps: 24) == 120)
        #expect(FCPTime.frames("236/24s", fps: 24) == 236)
        #expect(FCPTime.frames("garbage", fps: 24) == nil)
    }
}
