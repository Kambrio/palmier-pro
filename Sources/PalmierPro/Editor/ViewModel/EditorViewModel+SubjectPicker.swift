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
    /// The clip the renderer should show RAW (no stabilization transform/zoom): the one being picked
    /// (so points land on real source pixels) or the tracking-preview clip. Nil → normal stabilized.
    var stabBypassClipId: String? {
        if let p = pointPick { return p.clipId }
        if let s = subjectPicker { return s.clipId }
        return trackingPreviewClipId
    }

    /// While tracking-preview is on, the single selected object-tracking clip (with a seed) to render
    /// RAW so its tracked points/box ride the object. Nil otherwise (normal stabilized render).
    var trackingPreviewClipId: String? {
        guard subjectTrackingPreview, subjectPicker == nil, pointPick == nil,
              activePreviewTab == .timeline else { return nil }
        let sel = timeline.tracks.flatMap(\.clips)
            .filter { selectedClipIds.contains($0.id) && $0.mediaType == .video }
        guard sel.count == 1, let clip = sel.first, let stab = clip.stabilization, stab.enabled,
              (stab.engine == .points && stab.pointsSeed != nil)
              || (stab.engine == .subject && stab.subjectSeed != nil) else { return nil }
        return clip.id
    }

    /// The source-frame index under the playhead for `clip` (speed-aware, clamped to the clip).
    func sourceFrame(for clip: Clip) -> Int {
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

    /// The input the tracker/picker decode from: the proxy when proxies are on (a frame-exact,
    /// upright re-encode of the source), else the source. nil only when neither is on disk — so
    /// subject/point tracking keeps working from local proxies with the source volume offline.
    func trackingInputURL(for assetId: String) -> URL? {
        let proxy = mediaManifest.useProxies ? mediaResolver.proxyURL(for: assetId) : nil
        return proxy ?? mediaResolver.resolveURL(for: assetId)
    }

    /// Like `trackingInputURL` but prefers the SOURCE — for analyzers (L1/Smooth global motion
    /// estimation) that are too noisy on a low-res proxy. Falls back to the proxy only when the
    /// source is offline, so analysis still works (a bit noisier) from local proxies.
    func sourcePreferredInputURL(for assetId: String) -> URL? {
        mediaResolver.resolveURL(for: assetId)
            ?? (mediaManifest.useProxies ? mediaResolver.proxyURL(for: assetId) : nil)
    }

    /// Enter pick mode: grab the clip's current frame, detect objects, show the overlay.
    func beginSubjectPick(clip: Clip) {
        // Grab from the SAME input the tracker will use (proxy when on) so picker and tracker see
        // identical frames; the proxy preserves frame count and is already upright.
        guard let input = trackingInputURL(for: clip.mediaRef) else {
            mediaPanelToast = "Subject Lock needs the clip's media — the source is offline and there's no proxy."
            return
        }
        if isPlaying { pause() }
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
                // Always open the picker — with zero detections the overlay falls back to draw-a-box.
                subjectPicker = SubjectPickerSession(clipId: clipId, sourceFrame: frame, objects: objects)
                videoEngine?.refreshVisuals()   // show the clip RAW so the box lands on real source pixels
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
        if let url = trackingInputURL(for: clip.mediaRef) {
            stabilizationManager.enqueueSubjectTrack(assetId: clip.mediaRef, url: url, seed: seed)
        }
    }

    /// Commit a hand-drawn region (source-normalized TOP-LEFT box) as the subject seed.
    func commitSubjectDraw(box: CGRect) {
        let clamped = CGRect(
            x: min(max(box.minX, 0), 1), y: min(max(box.minY, 0), 1),
            width: min(box.width, 1), height: min(box.height, 1))
        guard clamped.width > 0.01, clamped.height > 0.01 else { return }
        commitSubjectPick(object: DetectedObject(id: -1, label: "selection", confidence: 1, box: clamped))
    }

    func cancelSubjectPick() {
        subjectPickToken &+= 1
        subjectPicker = nil
        videoEngine?.refreshVisuals()   // restore the stabilized preview
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
