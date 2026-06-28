import CoreGraphics
import Foundation

// MARK: - Input shapes (Decodable)

fileprivate struct StabilizeInput: DecodableToolArgs {
    let clipIds: [String]
    let enabled: Bool?
    let engine: String?
    let method: String?
    let smoothness: Double?
    let cropToFit: Bool?
    let subjectSmoothing: String?
    let lockAxis: String?
    let subject: SubjectInput?
    let points: PointsInput?

    static let allowedKeys: Set<String> = [
        "clipIds", "enabled", "engine", "method", "smoothness", "cropToFit",
        "subjectSmoothing", "lockAxis", "subject", "points",
    ]

    struct SubjectInput: Decodable {
        let frame: Int
        let box: [Double]
        let label: String?
        static let allowedKeys: Set<String> = ["frame", "box", "label"]
    }

    struct PointsInput: Decodable {
        let frame: Int
        let points: [[Double]]
        let direction: String?
        static let allowedKeys: Set<String> = ["frame", "points", "direction"]
    }
}

extension ToolExecutor {

    // MARK: stabilize_clips

    func stabilizeClips(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let input: StabilizeInput = try decodeToolArgs(args, path: "stabilize_clips")
        guard !input.clipIds.isEmpty else { throw ToolError("Missing or empty 'clipIds' array") }
        if let raw = args["subject"] as? [String: Any] {
            try validateUnknownKeys(raw, allowed: StabilizeInput.SubjectInput.allowedKeys, path: "subject")
        }
        if let raw = args["points"] as? [String: Any] {
            try validateUnknownKeys(raw, allowed: StabilizeInput.PointsInput.allowedKeys, path: "points")
        }

        let engine = try Self.parseEnum(input.engine, StabEngine.self, field: "engine")
        let method = try Self.parseEnum(input.method, StabMethod.self, field: "method")
        let subjectSmoothing = try Self.parseEnum(input.subjectSmoothing, SubjectSmoothing.self, field: "subjectSmoothing")
        let lockAxis = try Self.parseEnum(input.lockAxis, SubjectLockAxis.self, field: "lockAxis")
        if let s = input.smoothness, !(0...1).contains(s) {
            throw ToolError("smoothness must be between 0 and 1 (got \(s))")
        }

        // A subject/points payload implies its engine; building the seed picks the right one.
        var subjectSeed: SubjectSeed?
        if let sub = input.subject {
            guard sub.box.count == 4 else {
                throw ToolError("subject.box must be [x, y, width, height] (got \(sub.box.count) value(s))")
            }
            for v in sub.box where !(0...1).contains(v) {
                throw ToolError("subject.box values must be normalized 0–1 (got \(v))")
            }
            guard sub.box[2] > 0.01, sub.box[3] > 0.01 else {
                throw ToolError("subject.box width and height must be > 0.01")
            }
            guard sub.box[0] + sub.box[2] <= 1.001, sub.box[1] + sub.box[3] <= 1.001 else {
                throw ToolError("subject.box must lie within the frame (x+width ≤ 1, y+height ≤ 1).")
            }
            guard sub.frame >= 0 else { throw ToolError("subject.frame must be >= 0 (got \(sub.frame))") }
            subjectSeed = SubjectSeed(
                frame: sub.frame,
                box: CGRect(x: sub.box[0], y: sub.box[1], width: sub.box[2], height: sub.box[3]),
                label: sub.label ?? "subject")
        }

        var pointsSeed: PointsSeed?
        if let pts = input.points {
            guard !pts.points.isEmpty else { throw ToolError("points.points must contain at least one [x, y] point") }
            guard pts.frame >= 0 else { throw ToolError("points.frame must be >= 0 (got \(pts.frame))") }
            var cgPoints: [CGPoint] = []
            for (i, p) in pts.points.enumerated() {
                guard p.count == 2 else { throw ToolError("points.points[\(i)] must be [x, y] (got \(p.count) value(s))") }
                for v in p where !(0...1).contains(v) {
                    throw ToolError("points.points[\(i)] values must be normalized 0–1 (got \(v))")
                }
                cgPoints.append(CGPoint(x: p[0], y: p[1]))
            }
            let direction = try Self.parseEnum(pts.direction, TrackDirection.self, field: "points.direction") ?? .both
            pointsSeed = PointsSeed(frame: pts.frame, points: cgPoints, direction: direction)
        }

        // A seed pins the engine; otherwise honor the explicit engine argument.
        let resolvedEngine: StabEngine? = subjectSeed != nil ? .subject : (pointsSeed != nil ? .points : engine)

        // Resolve and validate clips up front.
        var clips: [Clip] = []
        for id in input.clipIds {
            guard let clip = editor.clipFor(id: id) else { throw ToolError("Clip not found: \(id)") }
            guard clip.mediaType == .video else {
                throw ToolError("Clip \(id) is \(clip.mediaType); stabilization applies to video clips only.")
            }
            guard clip.speed == 1.0 else {
                throw ToolError("Clip \(id) is not at normal speed (1×); stabilization requires speed 1.0.")
            }
            clips.append(clip)
        }

        let enabling = input.enabled ?? true
        // Subject/Point engines need a seed. Without an interactive picker, the agent must supply one
        // (or the clip must already carry one) — otherwise tracking has nothing to follow.
        if enabling {
            for clip in clips {
                let finalEngine = resolvedEngine ?? clip.stabilization?.engine ?? .vidstab
                if finalEngine == .subject, subjectSeed == nil, clip.stabilization?.subjectSeed == nil {
                    throw ToolError("Clip \(clip.id): the subject engine needs a `subject` box. Inspect a frame with inspect_timeline/inspect_media, then pass subject:{frame, box:[x,y,w,h]}.")
                }
                if finalEngine == .points, pointsSeed == nil, clip.stabilization?.pointsSeed == nil {
                    throw ToolError("Clip \(clip.id): the points engine needs `points`. Pass points:{frame, points:[[x,y], …]} placed on the object to hold steady.")
                }
            }
        }

        let actionName = input.clipIds.count == 1 ? "Stabilize Clip (Agent)" : "Stabilize Clips (Agent)"
        withUndoGroup(editor, actionName: actionName) {
            editor.mutateClips(ids: Set(input.clipIds), actionName: actionName) { c in
                var s = c.stabilization ?? Stabilization()
                s.enabled = enabling
                if let resolvedEngine { s.engine = resolvedEngine }
                if let method { s.method = method }
                if let v = input.smoothness { s.smoothness = v }
                if let v = input.cropToFit { s.cropToFit = v }
                if let subjectSmoothing { s.subjectSmoothing = subjectSmoothing }
                if let lockAxis { s.subjectLockAxis = lockAxis }
                if let subjectSeed { s.subjectSeed = subjectSeed }
                if let pointsSeed { s.pointsSeed = pointsSeed }
                c.stabilization = s
            }
        }
        editor.stabilizationManager.invalidateCache()
        editor.videoEngine?.refreshVisuals()

        var summaries: [String] = []
        for id in input.clipIds {
            guard let clip = editor.clipFor(id: id), let stab = clip.stabilization else { continue }
            if stab.enabled { Self.triggerStabilizationWork(editor, clip: clip, stab: stab) }
            let detail = stab.enabled
                ? "\(stab.engine.rawValue), smoothness \(String(format: "%.2f", stab.smoothness))"
                : "off"
            summaries.append("\(id): \(detail)")
        }

        let note = enabling
            ? " Tracking/baking runs in the background; the preview updates when it finishes."
            : ""
        return .ok("Stabilization updated on \(input.clipIds.count) clip(s): \(summaries.joined(separator: "; ")).\(note)")
    }

    /// Kicks off the right background work for a clip's engine, mirroring the Inspector.
    private static func triggerStabilizationWork(_ editor: EditorViewModel, clip: Clip, stab: Stabilization) {
        guard let url = editor.mediaResolver.resolveURL(for: clip.mediaRef) else { return }
        let manager = editor.stabilizationManager
        switch stab.engine {
        case .vidstab:
            manager.enqueueBake(assetId: clip.mediaRef, url: url, smoothness: stab.smoothness)
        case .subject:
            if let seed = stab.subjectSeed {
                manager.enqueueSubjectTrack(assetId: clip.mediaRef, url: url, seed: seed)
            }
        case .points:
            if let seed = stab.pointsSeed {
                manager.enqueuePointsTrack(assetId: clip.mediaRef, url: url, seed: seed)
            }
        case .l1, .smooth:
            manager.analyze(assetId: clip.mediaRef, url: url)
        }
    }

    private static func parseEnum<T: RawRepresentable & CaseIterable>(
        _ raw: String?, _ type: T.Type, field: String
    ) throws -> T? where T.RawValue == String {
        guard let raw else { return nil }
        guard let v = T(rawValue: raw) else {
            let allowed = T.allCases.map { $0.rawValue }.joined(separator: ", ")
            throw ToolError("\(field): invalid value '\(raw)'. Expected one of: \(allowed).")
        }
        return v
    }
}
