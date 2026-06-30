import Foundation

/// Resolves a timeline clip to a local audio file usable as an OmniVoice voice-clone
/// reference (`ref_audio`). Footage often lives on an external drive, so resolution is
/// proxy-aware (source first, then proxy). OmniVoice expects an audio file, so video
/// sources are demuxed to a mono 24 kHz WAV via ffmpeg — matching OmniVoice's output rate.
enum OmniVoiceCloneResolver {

    /// Source file when on disk, else the proxy when present, else nil. Lets cloning work
    /// while the original footage drive is disconnected (proxies are local + carry audio).
    static func resolveFile(for mediaRef: String, resolver: MediaResolver) -> URL? {
        resolver.resolveURL(for: mediaRef) ?? resolver.proxyURL(for: mediaRef)
    }

    /// ffmpeg argv that extracts `[start, start+duration]` of `input` to a mono 24 kHz PCM
    /// WAV at `output`. `-ss` before `-i` (fast input seek), `-t` after (output duration).
    static func extractArgs(
        input: URL, startSeconds: Double, durationSeconds: Double, output: URL
    ) -> [String] {
        var args = ["-y", "-hide_banner", "-loglevel", "error"]
        if startSeconds > 0 { args += ["-ss", String(format: "%.3f", startSeconds)] }
        args += ["-i", input.path]
        if durationSeconds > 0 { args += ["-t", String(format: "%.3f", durationSeconds)] }
        args += ["-vn", "-acodec", "pcm_s16le", "-ar", "24000", "-ac", "1", output.path]
        return args
    }

    /// Resolves `mediaRef` to a local file and, if it's video, extracts a clip-span WAV.
    /// `isVideo` is the asset's type (video needs demux; audio is used directly). Returns
    /// the ref-audio file path. Throws if the media is offline or ffmpeg fails.
    static func makeRefAudio(
        mediaRef: String,
        isVideo: Bool,
        startSeconds: Double,
        durationSeconds: Double,
        resolver: MediaResolver,
        ffmpegPath: String?
    ) async throws -> URL {
        guard let file = resolveFile(for: mediaRef, resolver: resolver) else {
            throw OmniVoiceCloneError.offline
        }
        guard isVideo else { return file }
        guard let ffmpegPath else { throw OmniVoiceCloneError.ffmpegMissing }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("omnivoice-ref-\(UUID().uuidString).wav")
        let proc = CLIProcess(
            executable: ffmpegPath,
            arguments: extractArgs(input: file, startSeconds: startSeconds, durationSeconds: durationSeconds, output: out),
            timeout: 120
        )
        _ = try await proc.runCapturing()
        guard FileManager.default.fileExists(atPath: out.path) else {
            throw OmniVoiceCloneError.extractionFailed
        }
        return out
    }
}

enum OmniVoiceCloneError: LocalizedError {
    case offline
    case ffmpegMissing
    case extractionFailed

    var errorDescription: String? {
        switch self {
        case .offline: "Voice reference is offline. Reconnect its drive, or pick a clip with a local proxy."
        case .ffmpegMissing: "ffmpeg isn't installed, which is required to clone from a video clip."
        case .extractionFailed: "Couldn't extract audio from the selected clip."
        }
    }
}
