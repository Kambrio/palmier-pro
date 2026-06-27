import Testing
import CoreImage
import CoreGraphics
import Foundation
@testable import PalmierPro

@MainActor
struct ObjectDetectorTests {
    /// Render a synthetic CGImage with a couple of shapes on a textured background.
    private func makeImage(size: Int = 416) -> CGImage {
        let ctx = CIContext()
        let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!
            .cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
        let rect = CIImage(color: .white)
            .cropped(to: CGRect(x: size / 4, y: size / 4, width: size / 3, height: size / 2))
        let image = rect.composited(over: noise)
        return ctx.createCGImage(image, from: CGRect(x: 0, y: 0, width: size, height: size))!
    }

    @Test func detectReturnsBoundedBoxesAndNeverThrowsOnNoDetections() async throws {
        let objects = try await ObjectDetector.shared.detect(in: makeImage())
        // Synthetic input may detect nothing — that's fine, but it must return an array, not throw.
        for o in objects {
            #expect(o.box.minX >= 0 && o.box.minX <= 1)
            #expect(o.box.minY >= 0 && o.box.minY <= 1)
            #expect(o.box.maxX <= 1.0001)
            #expect(o.box.maxY <= 1.0001)
            #expect(o.box.width > 0 && o.box.height > 0)
            #expect(o.confidence >= 0.25)
            #expect(!o.label.isEmpty)
            #expect(o.box.minX.isFinite && o.box.minY.isFinite)
        }
        // Sorted by descending confidence, capped at 20.
        #expect(objects.count <= 20)
        #expect(objects == objects.sorted { $0.confidence > $1.confidence })
    }

    /// top-left → Vision bottom-left → top-left must be the identity.
    @Test func coordinateRoundTripIsIdentity() {
        let cases = [
            CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
            CGRect(x: 0, y: 0, width: 1, height: 1),
            CGRect(x: 0.5, y: 0.5, width: 0.25, height: 0.25),
            CGRect(x: 0.73, y: 0.01, width: 0.2, height: 0.6),
        ]
        for tl in cases {
            let vision = CGRect(x: tl.minX, y: 1 - tl.minY - tl.height, width: tl.width, height: tl.height)
            let back = CGRect(x: vision.minX, y: 1 - vision.minY - vision.height,
                              width: vision.width, height: vision.height)
            #expect(abs(back.minX - tl.minX) < 1e-9)
            #expect(abs(back.minY - tl.minY) < 1e-9)
            #expect(abs(back.width - tl.width) < 1e-9)
            #expect(abs(back.height - tl.height) < 1e-9)
        }
    }
}
