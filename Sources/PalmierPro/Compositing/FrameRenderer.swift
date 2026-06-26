import AVFoundation
import CoreImage

/// Composites a frame from a CompositorInstruction's layers with Core Image:
/// per-layer crop → effects → transform → opacity, stacked bottom→top.
enum FrameRenderer {

    static func render(
        instruction: CompositorInstruction,
        sourceFrame: (CMPersistentTrackID) -> CVPixelBuffer?,
        compositionTime: CMTime,
        into output: CVPixelBuffer,
        context: CIContext
    ) {
        let renderRect = CGRect(origin: .zero, size: instruction.renderSize)
        let frame = Int((compositionTime.seconds * Double(instruction.fps)).rounded())

        var accum = CIImage(color: .black).cropped(to: renderRect)
        for layer in instruction.layers {
            guard let buffer = sourceFrame(layer.trackID) else { continue }
            if let image = composedLayer(layer, buffer: buffer, frame: frame,
                                         renderSize: instruction.renderSize) {
                accum = image.composited(over: accum)
            }
        }
        context.render(accum, to: output, bounds: renderRect, colorSpace: nil)
        tag709(output)
    }

    /// Tag output Rec. 709 at the buffer level so downstream reads our bytes correctly.
    private static func tag709(_ buffer: CVPixelBuffer) {
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    }

    private static func composedLayer(
        _ layer: LayerPlan,
        buffer: CVPixelBuffer,
        frame: Int,
        renderSize: CGSize
    ) -> CIImage? {
        let clip = layer.clip
        let alpha = min(1.0, max(0.0, clip.opacityAt(frame: frame)))
        guard alpha > 0 else { return nil }

        // CI (color management off) treats pixels as unpremultiplied; sources are
        // premultiplied, so undo it or the composite double-darkens edges.
        var image = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()])
            .unpremultiplyingAlpha()
        let srcHeight = CGFloat(CVPixelBufferGetHeight(buffer))

        let crop = clip.cropAt(frame: frame)
        if !crop.isIdentity {
            // Display-space insets → source pixels → CI's bottom-left origin.
            let avRect = CGRect(
                x: crop.left * layer.natSize.width,
                y: crop.top * layer.natSize.height,
                width: max(1, crop.visibleWidthFraction * layer.natSize.width),
                height: max(1, crop.visibleHeightFraction * layer.natSize.height)
            ).applying(layer.preferredTransform.inverted())
            image = image.cropped(to: CGRect(
                x: avRect.origin.x,
                y: srcHeight - avRect.origin.y - avRect.height,
                width: avRect.width,
                height: avRect.height
            ))
        }

        // Effects apply in source-pixel space: after crop, before placement.
        if let effects = clip.effects, !effects.isEmpty {
            let offset = frame - clip.startFrame
            let srcLong = max(layer.sourceNatSize.width, layer.sourceNatSize.height)
            let decLong = max(layer.natSize.width, layer.natSize.height)
            let pixelScale = srcLong > 0 ? min(1, decLong / srcLong) : 1
            for effect in effects where effect.enabled {
                guard let descriptor = EffectRegistry.descriptor(id: effect.type) else { continue }
                image = descriptor.render(image, effect: effect, atOffset: offset, pixelScale: pixelScale)
            }
        }

        if let homos = layer.stabPerspective, !homos.isEmpty {
            let rel = max(0, min(homos.count - 1, frame - clip.startFrame))
            image = applyPerspective(image, homos[rel], natSize: layer.natSize, zoom: layer.stabZoom)
        }

        // transformAt drops the flip flags, so use the static transform unless animated.
        let t = clip.hasTransformAnimation ? clip.transformAt(frame: frame) : clip.transform
        let placement = CompositionBuilder.affineTransform(for: t, natSize: layer.natSize, renderSize: renderSize)
        var srcSpace = layer.preferredTransform
        if let affines = layer.stabAffines, !affines.isEmpty {
            let rel = max(0, min(affines.count - 1, frame - clip.startFrame))
            // Prepend the stabilization correction in source/natSize space, before placement.
            srcSpace = affines[rel].concatenating(srcSpace)
        }
        let av = srcSpace.concatenating(placement)
        // Conjugate the AV top-left-origin mapping into CI's bottom-left space.
        let ci = flipY(srcHeight).concatenating(av).concatenating(flipY(renderSize.height))
        image = image.transformed(by: ci)

        if alpha < 1 {
            // Alpha only — CIColorMatrix re-premultiplies by the result's alpha, so
            // scaling RGB too would double the fade.
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha),
            ])
        }
        return image
    }

    /// Warp the image by a normalized correction homography via Core Image, with crop-zoom about center.
    private static func applyPerspective(_ image: CIImage, _ t: StabFrameTransform, natSize: CGSize, zoom: CGFloat) -> CIImage {
        let ext = image.extent
        guard ext.width > 0, ext.height > 0 else { return image }
        let cx = ext.midX, cy = ext.midY
        func warp(_ p: CGPoint) -> CGPoint {
            let nx = (p.x - ext.minX) / ext.width, ny = (p.y - ext.minY) / ext.height
            let m = t.m
            let w = m[6]*nx + m[7]*ny + m[8]
            let d = (w == 0 ? 1 : w)
            let ox = (m[0]*nx + m[1]*ny + m[2]) / d
            let oy = (m[3]*nx + m[4]*ny + m[5]) / d
            let px = ext.minX + ox * ext.width, py = ext.minY + oy * ext.height
            return CGPoint(x: cx + (px - cx) * zoom, y: cy + (py - cy) * zoom)
        }
        return image.applyingFilter("CIPerspectiveTransform", parameters: [
            "inputTopLeft":     CIVector(cgPoint: warp(CGPoint(x: ext.minX, y: ext.maxY))),
            "inputTopRight":    CIVector(cgPoint: warp(CGPoint(x: ext.maxX, y: ext.maxY))),
            "inputBottomRight": CIVector(cgPoint: warp(CGPoint(x: ext.maxX, y: ext.minY))),
            "inputBottomLeft":  CIVector(cgPoint: warp(CGPoint(x: ext.minX, y: ext.minY))),
        ])
    }

    private static func flipY(_ height: CGFloat) -> CGAffineTransform {
        CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: height)
    }
}
