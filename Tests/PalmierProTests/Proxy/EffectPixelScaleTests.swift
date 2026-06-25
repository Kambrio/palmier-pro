import CoreImage
import Testing
@testable import PalmierPro

@Suite("Effect pixel scaling")
struct EffectPixelScaleTests {
    @Test func pxParamRadiusShrinksWithPixelScale() {
        guard let descriptor = EffectRegistry.all.first(where: { d in d.params.contains { $0.unit == "px" } }),
              let spec = descriptor.params.first(where: { $0.unit == "px" })
        else { Issue.record("no px-unit effect found"); return }

        // Sharp edge: white left half, black right half (64×64).
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: 32, height: 64))
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0))
            .cropped(to: CGRect(x: 32, y: 0, width: 32, height: 64))
        let input = white.composited(over: black)

        var e = descriptor.makeEffect()
        e.params[spec.key] = EffectParam(value: spec.range.upperBound)  // max radius

        let full = descriptor.render(input, effect: e, atOffset: 0, pixelScale: 1)
        let tiny = descriptor.render(input, effect: e, atOffset: 0, pixelScale: 0.1)

        // Render both to Float32 pixel buffers and compare actual pixel values.
        let ctx = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        let bounds = CGRect(x: 0, y: 0, width: 64, height: 64)
        let stride = 64 * 4 * MemoryLayout<Float>.size
        var fullPx = [Float](repeating: 0, count: 64 * 64 * 4)
        var tinyPx = [Float](repeating: 0, count: 64 * 64 * 4)
        ctx.render(full, toBitmap: &fullPx, rowBytes: stride,
                   bounds: bounds, format: .RGBAf, colorSpace: nil)
        ctx.render(tiny, toBitmap: &tinyPx, rowBytes: stride,
                   bounds: bounds, format: .RGBAf, colorSpace: nil)

        // Sum absolute difference across all channels.
        // pixelScale:1 → max radius (strong blur, edge heavily smeared).
        // pixelScale:0.1 → 10% of max radius (weak blur, edge mostly sharp).
        // If scaling were removed, both renders would use the same radius → sad == 0 → test fails.
        var sad: Double = 0
        for i in 0..<(64 * 64 * 4) {
            sad += abs(Double(fullPx[i]) - Double(tinyPx[i]))
        }
        #expect(sad > 50, "renders at pixelScale:1 and pixelScale:0.1 must differ (sad=\(sad))")
    }
}
