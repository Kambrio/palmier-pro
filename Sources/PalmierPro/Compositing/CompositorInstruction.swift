import AVFoundation

/// Stabilization correction baked for the renderer (resolved on the main actor at build time).
struct StabResolved: Sendable, Equatable {
    var affines: [CGAffineTransform]
    var perspective: [StabFrameTransform]?   // populated only for the perspective method
    var zoom: CGFloat = 1
}

/// Immutable per-clip snapshot read on the render queue — never the live timeline.
struct LayerPlan: Sendable {
    enum Source: Sendable {
        case track(CMPersistentTrackID)
        case text
        /// Nested timeline: children composite into a `canvas`-sized unit, then the nest clip's pipeline applies.
        case group(children: [LayerPlan], canvas: CGSize)
    }
    let source: Source
    let clip: Clip
    /// Decoded frame display size (proxy size when proxied).
    let natSize: CGSize
    /// Original source display size; equals natSize when not proxied.
    var sourceNatSize: CGSize = .zero
    let preferredTransform: CGAffineTransform
    var stabAffines: [CGAffineTransform]? = nil
    var stabPerspective: [StabFrameTransform]? = nil
    var stabZoom: CGFloat = 1

    var trackID: CMPersistentTrackID? {
        if case .track(let id) = source { return id }
        return nil
    }

    func collectTrackIDs(into ids: inout [CMPersistentTrackID]) {
        switch source {
        case .track(let id): ids.append(id)
        case .text: break
        case .group(let children, _):
            for child in children { child.collectTrackIDs(into: &ids) }
        }
    }
}

/// One timeline segment between clip boundaries. Layers are ordered bottom → top.
final class CompositorInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
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
        var all: [CMPersistentTrackID] = []
        for layer in layers { layer.collectTrackIDs(into: &all) }
        var seen = Set<CMPersistentTrackID>()
        self.requiredSourceTrackIDs = all.compactMap {
            seen.insert($0).inserted ? NSNumber(value: $0) : nil
        }
        super.init()
    }
}
