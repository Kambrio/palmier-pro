import AVFoundation
import CoreGraphics
import Foundation

/// An in-progress Subject Lock pick: the detected objects on a chosen source frame of a clip.
struct SubjectPickerSession: Equatable {
    var clipId: String
    var sourceFrame: Int
    var objects: [DetectedObject]
}

extension EditorViewModel {
    /// The source-frame index under the playhead for `clip` (speed-aware, clamped to the clip).
    private func sourceFrame(for clip: Clip) -> Int {
        let rel = max(0, currentFrame - clip.startFrame)
        let consumed = Int((Double(rel) * clip.speed).rounded())
        return clip.trimStartFrame + min(consumed, max(0, clip.sourceFramesConsumed - 1))
    }

    /// Enter pick mode: grab the clip's current source frame, detect objects, show the overlay.
    func beginSubjectPick(clip: Clip) {
        guard let url = mediaResolver.resolveURL(for: clip.mediaRef) else {
            mediaPanelToast = "Subject Lock needs the clip's source file — it appears to be offline."
            return
        }
        if isPlaying { pause() }
        let frame = sourceFrame(for: clip)
        let fps = timeline.fps
        let clipId = clip.id
        Task { @MainActor in
            guard let image = await Self.sourceFrameImage(url: url, frame: frame, fps: fps) else {
                mediaPanelToast = "Couldn't read this frame for subject detection."
                return
            }
            do {
                let objects = try await ObjectDetector.shared.detect(in: image)
                guard !objects.isEmpty else {
                    mediaPanelToast = "No objects detected on this frame. Move the playhead and try again."
                    return
                }
                subjectPicker = SubjectPickerSession(clipId: clipId, sourceFrame: frame, objects: objects)
            } catch {
                mediaPanelToast = "Subject detection failed: \(error.localizedDescription)"
            }
        }
    }

    /// Commit a picked object as the clip's subject seed and start tracking.
    func commitSubjectPick(object: DetectedObject) {
        guard let session = subjectPicker,
              let clip = timeline.tracks.flatMap(\.clips).first(where: { $0.id == session.clipId }) else {
            subjectPicker = nil
            return
        }
        let seed = SubjectSeed(frame: session.sourceFrame, box: object.box, label: object.label)
        mutateClips(ids: [clip.id], actionName: "Choose Subject") { c in
            var s = c.stabilization ?? Stabilization()
            s.engine = .subject
            s.subjectSeed = seed
            c.stabilization = s
        }
        subjectPicker = nil
        stabilizationManager.invalidateCache()
        videoEngine?.refreshVisuals()
        if let url = mediaResolver.resolveURL(for: clip.mediaRef) {
            stabilizationManager.enqueueSubjectTrack(assetId: clip.mediaRef, url: url, seed: seed)
        }
    }

    func cancelSubjectPick() {
        subjectPicker = nil
    }

    /// Decode a single source frame as a CGImage (exact-time, oriented), off the calling actor.
    private static func sourceFrameImage(url: URL, frame: Int, fps: Int) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        let time = CMTime(value: CMTimeValue(max(0, frame)), timescale: CMTimeScale(max(1, fps)))
        return try? await generator.image(at: time).image
    }
}
