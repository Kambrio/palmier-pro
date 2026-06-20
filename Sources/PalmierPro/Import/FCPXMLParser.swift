import Foundation

enum FCPXMLParseError: LocalizedError {
    case unreadable(String)
    case notFCPXML
    case noSequence

    var errorDescription: String? {
        switch self {
        case .unreadable(let m): return "Could not read FCPXML: \(m)"
        case .notFCPXML: return "Not an FCPXML document (missing <fcpxml> root)."
        case .noSequence: return "No <sequence>/<spine> found in the FCPXML."
        }
    }
}

/// Parses an FCPXML document into a `ParsedTimeline`. Pure — no app state.
enum FCPXMLParser {
    private static let clipElementNames: Set<String> = ["video", "asset-clip", "clip"]

    static func parse(url: URL) throws -> ParsedTimeline {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw FCPXMLParseError.unreadable(error.localizedDescription) }
        return try parse(data: data)
    }

    static func parse(data: Data) throws -> ParsedTimeline {
        let doc: XMLDocument
        do { doc = try XMLDocument(data: data) }
        catch { throw FCPXMLParseError.unreadable(error.localizedDescription) }

        guard let root = doc.rootElement(), root.name == "fcpxml" else {
            throw FCPXMLParseError.notFCPXML
        }

        let resources = root.elements(forName: "resources").first
        let (fps, width, height) = parseFormat(resources)
        let assets = parseAssets(resources)

        guard let spine = firstDescendant(named: "spine", in: root) else {
            throw FCPXMLParseError.noSequence
        }

        var skipped: [String] = []
        var clips: [ParsedClip] = []
        for child in (spine.children ?? []) {
            guard let el = child as? XMLElement, let name = el.name else { continue }
            if name == "gap" {
                clips.append(ParsedClip(
                    assetId: "",
                    startFrame: FCPTime.frames(attr(el, "offset") ?? "0s", fps: fps) ?? 0,
                    durationFrames: FCPTime.frames(attr(el, "duration") ?? "0s", fps: fps) ?? 0,
                    sourceInFrames: 0, isGap: true))
            } else if clipElementNames.contains(name) {
                clips.append(ParsedClip(
                    assetId: attr(el, "ref") ?? "",
                    startFrame: FCPTime.frames(attr(el, "offset") ?? "0s", fps: fps) ?? 0,
                    durationFrames: FCPTime.frames(attr(el, "duration") ?? "0s", fps: fps) ?? 0,
                    sourceInFrames: FCPTime.frames(attr(el, "start") ?? "0s", fps: fps) ?? 0,
                    isGap: false))
            } else {
                skipped.append(name)
            }
        }

        // Split into video and audio tracks by the referenced asset's type, so audio
        // elements (e.g. a music bed on a connected lane) get their own audio track
        // instead of being flattened onto the video track as silent video clips.
        var videoClips: [ParsedClip] = []
        var audioClips: [ParsedClip] = []
        for clip in clips {
            if !clip.isGap, isAudioOnly(assets[clip.assetId]) {
                audioClips.append(clip)
            } else {
                videoClips.append(clip)
            }
        }
        var tracks: [ParsedTrack] = []
        if !videoClips.isEmpty { tracks.append(ParsedTrack(kind: .video, clips: videoClips)) }
        if !audioClips.isEmpty { tracks.append(ParsedTrack(kind: .audio, clips: audioClips)) }

        return ParsedTimeline(fps: fps, width: width, height: height,
                              assets: assets, tracks: tracks, skipped: skipped)
    }

    private static func attr(_ el: XMLElement, _ name: String) -> String? {
        el.attribute(forName: name)?.stringValue
    }

    private static let audioExtensions: Set<String> = ["mp3", "wav", "aac", "m4a", "aiff", "caf"]

    private static func isAudioOnly(_ asset: ParsedAsset?) -> Bool {
        guard let asset else { return false }
        if asset.hasAudio && !asset.hasVideo { return true }
        if !asset.hasAudio && !asset.hasVideo, let ext = asset.src?.pathExtension.lowercased() {
            return audioExtensions.contains(ext)
        }
        return false
    }

    private static func parseFormat(_ resources: XMLElement?) -> (fps: Int, width: Int, height: Int) {
        guard let format = resources?.elements(forName: "format").first else { return (30, 1920, 1080) }
        let fps: Int
        if let fd = attr(format, "frameDuration"), let sec = FCPTime.seconds(fd), sec > 0 {
            fps = Int((1.0 / sec).rounded())
        } else { fps = 30 }
        let width = attr(format, "width").flatMap { Int($0) } ?? 1920
        let height = attr(format, "height").flatMap { Int($0) } ?? 1080
        return (fps, width, height)
    }

    private static func parseAssets(_ resources: XMLElement?) -> [String: ParsedAsset] {
        var out: [String: ParsedAsset] = [:]
        for el in resources?.elements(forName: "asset") ?? [] {
            guard let id = attr(el, "id") else { continue }
            let mediaRep = el.elements(forName: "media-rep").first
            let src = mediaRep.flatMap { attr($0, "src") }.flatMap { URL(string: $0) }
            out[id] = ParsedAsset(
                id: id,
                name: attr(el, "name") ?? id,
                src: src,
                hasVideo: attr(el, "hasVideo") == "1",
                hasAudio: attr(el, "hasAudio") == "1")
        }
        return out
    }

    private static func firstDescendant(named name: String, in element: XMLElement) -> XMLElement? {
        for child in (element.children ?? []) {
            guard let el = child as? XMLElement else { continue }
            if el.name == name { return el }
            if let found = firstDescendant(named: name, in: el) { return found }
        }
        return nil
    }
}
