import AVFoundation

/// Stabilization correction baked for the renderer (resolved on the main actor at build time).
struct StabResolved: Sendable, Equatable {
    var affines: [CGAffineTransform]
    var perspective: [StabFrameTransform]?   // populated only for the perspective method
    var zoom: CGFloat = 1
}

/// Immutable per-clip snapshot read on the render queue — never the live timeline.
struct LayerPlan: Sendable {
    let trackID: CMPersistentTrackID
    let clip: Clip
    /// Decoded frame display size (proxy size when proxied).
    let natSize: CGSize
    /// Original source display size; equals natSize when not proxied.
    let sourceNatSize: CGSize
    let preferredTransform: CGAffineTransform
    var stabAffines: [CGAffineTransform]? = nil
    var stabPerspective: [StabFrameTransform]? = nil
    var stabZoom: CGFloat = 1
}

/// One timeline segment between clip boundaries. Layers are ordered bottom → top.
final class CompositorInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    // Post-processing must stay on: the export animationTool (text) keys off it.
    let enablePostProcessing = true
    // Values are sampled per frame; never let AVFoundation cache one frame per instruction.
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let layers: [LayerPlan]
    let renderSize: CGSize
    let fps: Int

    init(timeRange: CMTimeRange, layers: [LayerPlan], renderSize: CGSize, fps: Int) {
        self.timeRange = timeRange
        self.layers = layers
        self.renderSize = renderSize
        self.fps = fps
        var seen = Set<CMPersistentTrackID>()
        self.requiredSourceTrackIDs = layers.compactMap {
            seen.insert($0.trackID).inserted ? NSNumber(value: $0.trackID) : nil
        }
        super.init()
    }
}
