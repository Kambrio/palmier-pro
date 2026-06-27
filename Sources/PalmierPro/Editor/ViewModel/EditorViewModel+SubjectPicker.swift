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

    /// The pick session valid for the preview: timeline tab, its clip still the sole selection, and
    /// still on the subject engine. A stale session renders to nothing and is ignored on commit.
    var activeSubjectPicker: SubjectPickerSession? {
        guard let s = subjectPicker, activePreviewTab == .timeline, selectedClipIds.contains(s.clipId),
              let clip = timeline.tracks.flatMap(\.clips).first(where: { $0.id == s.clipId }),
              clip.stabilization?.engine == .subject else { return nil }
        return s
    }

    /// Enter pick mode: grab the clip's current source frame, detect objects, show the overlay.
    func beginSubjectPick(clip: Clip) {
        guard let source = mediaResolver.resolveURL(for: clip.mediaRef) else {
            mediaPanelToast = "Subject Lock needs the clip's source file — it appears to be offline."
            return
        }
        if isPlaying { pause() }
        // Grab from the SAME input the tracker will use (proxy when on) so picker and tracker see
        // identical frames; the proxy preserves frame count and is already upright.
        let proxy = mediaManifest.useProxies ? mediaResolver.proxyURL(for: clip.mediaRef) : nil
        let input = proxy ?? source
        let frame = sourceFrame(for: clip)
        let clipId = clip.id
        subjectPickToken &+= 1
        let token = subjectPickToken
        Task { @MainActor in
            guard let image = await Self.sourceFrameImage(url: input, sourceFrame: frame) else {
                mediaPanelToast = "Couldn't read this frame for subject detection."
                return
            }
            do {
                let objects = try await ObjectDetector.shared.detect(in: image)
                Log.preview.notice("subjectPick: \(objects.count) objects on frame \(frame)")
                // A newer pick, a cancel, or a selection change supersedes this stale result.
                // `contains` (not ==): a video clip is usually selected together with its linked audio.
                guard token == subjectPickToken, selectedClipIds.contains(clipId) else { return }
                guard !objects.isEmpty else {
                    mediaPanelToast = "No objects detected on this frame. Move the playhead and try again."
                    return
                }
                subjectPicker = SubjectPickerSession(clipId: clipId, sourceFrame: frame, objects: objects)
            } catch {
                Log.preview.error("subjectPick: detection failed: \(Log.detail(error))")
                mediaPanelToast = "Subject detection failed: \(error.localizedDescription)"
            }
        }
    }

    /// Commit a picked object as the clip's subject seed and start tracking.
    func commitSubjectPick(object: DetectedObject) {
        guard let session = subjectPicker,
              selectedClipIds.contains(session.clipId),
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
        subjectPickToken &+= 1
        subjectPicker = nil
    }

    /// Decode a single source frame as a CGImage (exact-time, upright), off the calling actor.
    /// Seeks at the input track's own frame rate so the grabbed image is the exact frame the
    /// tracker seeds (`frame` is a source-frame index, not a timeline frame).
    private static func sourceFrameImage(url: URL, sourceFrame: Int) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let fps = try? await track.load(.nominalFrameRate), fps > 0 else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        let time = CMTime(value: CMTimeValue(max(0, sourceFrame)), timescale: CMTimeScale(fps.rounded()))
        return try? await generator.image(at: time).image
    }
}
