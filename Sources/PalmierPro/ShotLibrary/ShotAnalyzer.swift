import AVFoundation
import CoreGraphics
import Foundation

/// Builds a `ShotEntry` for one video asset: samples 3 frames (10% / 50% / 90%), runs on-device
/// Vision + the bundled YOLO detector on each, folds in the transcript, and composes a baseline
/// description and a meaningful name. The agent or the user can refine the text afterwards.
enum ShotAnalyzer {
    struct Input: Sendable {
        let assetId: String
        let url: URL              // decode source (proxy if available, else source)
        let durationSeconds: Double
        let sourceSig: String?
        let projectURL: URL
    }

    static func analyze(
        _ input: Input,
        transcript: TranscriptionResult?,
        progress: @escaping @Sendable (Double) -> Void
    ) async -> ShotEntry? {
        let asset = AVURLAsset(url: input.url)
        guard (try? await asset.loadTracks(withMediaType: .video).first) != nil else { return nil }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 768, height: 768)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)

        // SigLIP2 (the search model) gives zero-shot, semantically grounded shot/scene labels when
        // it's installed. Optional — analysis degrades to Vision-only without it.
        let embedder = await VisualModelLoader.shared.embedder

        let duration = max(0.001, input.durationSeconds)
        var entry = ShotEntry(assetId: input.assetId)
        entry.durationSeconds = input.durationSeconds
        entry.sourceSig = input.sourceSig

        var bestEmbedding: [Float]?
        var bestQuality = -1.0

        let positions = ShotPosition.allCases
        for (i, position) in positions.enumerated() {
            progress(Double(i) / Double(positions.count))
            let t = duration * position.fraction
            let time = CMTime(seconds: t, preferredTimescale: 600)
            guard let cg = try? await generator.image(at: time).image else {
                entry.frames.append(ShotFrame(position: position, timeSeconds: t))
                continue
            }

            // Vision and the YOLO detector use independent subsystems — overlap them.
            async let visionTask = FrameVisionAnalyzer.analyze(cg)
            async let objectsTask = ObjectDetector.shared.detect(in: cg)
            let vision = await visionTask
            let objects = (try? await objectsTask) ?? []
            var siglip: SigLIPShotSignal?
            if let embedder { siglip = await SigLIPShotClassifier.shared.classify(image: cg, embedder: embedder) }

            var frame = ShotFrame(position: position, timeSeconds: t)
            // Prefer SigLIP's semantic scene phrases; back-fill with Vision's classifier labels.
            frame.sceneLabels = mergedLabels(siglip?.sceneLabels ?? [], vision.sceneLabels, limit: 5)
            frame.objects = orderedUniqueLabels(objects)
            frame.people = max(vision.faceCount, objects.filter { $0.label == "person" }.count)
            frame.faceQuality = vision.faceQuality
            frame.action = siglip?.action
            frame.shotSize = shotSize(
                faceFraction: vision.largestFaceFraction, objects: objects,
                sceneLabels: frame.sceneLabels, siglip: siglip)
            frame.thumbnailRelPath = ShotThumbnailStore.write(cg, assetId: input.assetId, position: position, projectURL: input.projectURL)
            frame.description = frameDescription(frame)
            entry.frames.append(frame)

            if let emb = vision.faceEmbedding {
                let q = vision.faceQuality ?? 0.5
                if q > bestQuality { bestQuality = q; bestEmbedding = emb }
            }
        }
        progress(1)

        // Representative signals come from the middle frame, falling back to whatever exists.
        let mid = entry.frames.first { $0.position == .median } ?? entry.frames.first
        entry.shotSize = mid?.shotSize
        entry.people = entry.frames.map(\.people).max()
        if let emb = bestEmbedding { entry.faceEmbedding = EmbeddingCodec.encode(emb) }

        let text = transcript?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        entry.hasSpeech = !text.isEmpty
        if !text.isEmpty { entry.transcriptExcerpt = String(text.prefix(280)) }

        entry.summary = composeSummary(entry: entry, mid: mid)
        entry.displayName = composeName(entry: entry, mid: mid)
        entry.analyzedAt = Date()
        return entry
    }

    // MARK: - Heuristics

    private static func orderedUniqueLabels(_ objects: [DetectedObject]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for o in objects.sorted(by: { $0.confidence > $1.confidence }) where !seen.contains(o.label) {
            seen.insert(o.label); out.append(o.label)
            if out.count >= 6 { break }
        }
        return out
    }

    /// Blends direct geometric evidence (face / person coverage — authoritative when a subject is
    /// present) with SigLIP's zero-shot guess (used when no subject anchors the scale). Maps onto the
    /// canonical 8-size scale (`ShotSize.selectable`).
    private static func shotSize(faceFraction: Double, objects: [DetectedObject], sceneLabels: [String], siglip: SigLIPShotSignal?) -> ShotSize {
        if faceFraction > 0 {
            switch faceFraction {
            case 0.40...:       return .extremeCloseUp
            case 0.18..<0.40:   return .closeUp
            case 0.09..<0.18:   return .mediumCloseUp
            case 0.04..<0.09:   return .mediumFull
            default:            return .full
            }
        }
        let personHeights = objects.filter { $0.label == "person" }.map { $0.box.height }
        if let tallest = personHeights.max() {
            switch tallest {
            case 0.85...:       return .full
            case 0.5..<0.85:    return .mediumFull
            case 0.25..<0.5:    return .wide
            default:            return .establishing
            }
        }
        // No subject to measure → trust SigLIP's semantic guess when available (best remaining signal).
        if let guess = siglip?.shotSizeGuess { return guess }
        let landscape: Set<String> = ["outdoor", "nature", "landscape", "sky", "mountain", "beach", "field", "forest", "ocean", "sea", "sunset", "cityscape"]
        if sceneLabels.contains(where: { l in landscape.contains(where: { l.contains($0) }) }) { return .establishing }
        return objects.isEmpty && sceneLabels.isEmpty ? .unknown : .wide
    }

    /// Primary labels first, then back-fill with secondary, deduped, capped.
    private static func mergedLabels(_ primary: [String], _ secondary: [String], limit: Int) -> [String] {
        var out: [String] = []
        for label in primary + secondary where !out.contains(label) {
            out.append(label)
            if out.count >= limit { break }
        }
        return out
    }

    private static func frameDescription(_ frame: ShotFrame) -> String {
        var parts: [String] = []
        if frame.shotSize != .unknown { parts.append(frame.shotSize.displayName.lowercased() + " shot") }
        if frame.people > 0 { parts.append("\(frame.people) " + (frame.people == 1 ? "person" : "people")) }
        if let action = frame.action { parts.append(action) }
        let tags = (frame.objects.filter { $0 != "person" } + frame.sceneLabels)
        let subject = Array(NSOrderedSet(array: tags).array as? [String] ?? []).prefix(3)
        if !subject.isEmpty { parts.append(subject.joined(separator: ", ")) }
        return parts.isEmpty ? "Frame" : parts.joined(separator: ", ").capitalizedFirst
    }

    private static func composeSummary(entry: ShotEntry, mid: ShotFrame?) -> String {
        var parts: [String] = []
        if let size = entry.shotSize, size != .unknown { parts.append("\(size.displayName) shot") }
        if let people = entry.people, people > 0 { parts.append("\(people) " + (people == 1 ? "person" : "people")) }
        if let action = dominantAction(entry) { parts.append(action) }

        var subjects: [String] = []
        for frame in entry.frames {
            for s in frame.objects.filter({ $0 != "person" }) where !subjects.contains(s) { subjects.append(s) }
            for s in frame.sceneLabels where !subjects.contains(s) { subjects.append(s) }
        }
        if !subjects.isEmpty { parts.append(subjects.prefix(5).joined(separator: ", ")) }

        var summary = parts.isEmpty ? "Footage" : parts.joined(separator: ", ").capitalizedFirst + "."
        if let excerpt = entry.transcriptExcerpt, !excerpt.isEmpty {
            summary += " Says: “\(excerpt)”"
        }
        return summary
    }

    private static func composeName(entry: ShotEntry, mid: ShotFrame?) -> String {
        // Prefer a concrete action, then a salient object, then a scene; fall back to people/shot.
        let objectSubjects = entry.frames.flatMap { $0.objects }.filter { $0 != "person" }
        let sceneSubjects = entry.frames.flatMap { $0.sceneLabels }
        let size = entry.shotSize.flatMap { $0 == .unknown ? nil : $0.displayName }

        var lead: String
        if let action = dominantAction(entry) {
            lead = action.capitalizedFirst
        } else if let subject = objectSubjects.first ?? sceneSubjects.first {
            lead = subject.capitalizedFirst
        } else if (entry.people ?? 0) > 0 {
            lead = (entry.people == 1) ? "Person" : "Group"
        } else {
            lead = "Shot"
        }
        if let size { lead += " · \(size)" }
        return lead
    }

    /// The action that appears on the most frames (ties broken by first occurrence).
    private static func dominantAction(_ entry: ShotEntry) -> String? {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for a in entry.frames.compactMap(\.action) {
            if counts[a] == nil { order.append(a) }
            counts[a, default: 0] += 1
        }
        var best: String?
        var bestCount = 0
        for a in order where counts[a]! > bestCount { best = a; bestCount = counts[a]! }
        return best
    }
}

extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
