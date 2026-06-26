import Foundation
import os

/// Bakes a stabilized copy of a source video with ffmpeg. Two-pass vid.stab when available,
/// else single-pass deshake. Atomic publish (temp → verify openable → rename), like proxies.
/// Output is H.264 (small/fast) — baking 6K ProRes was multi-GB and minutes per clip; the input
/// is normally the low-res proxy (see StabilizationManager), so bakes are seconds and a few MB.
enum FFmpegStabService {
    struct Failure: LocalizedError { let reason: String; var errorDescription: String? { reason } }

    /// `smoothness` 0…1. `maxLongEdge` > 0 caps the output's long edge (0 = keep input size).
    /// Writes a stabilized `.mov` to `output`. Throws CancellationError on cancel.
    static func stabilize(
        source: URL, to output: URL, smoothness: Double, maxLongEdge: Int,
        capability: VidStab.Capability, ffmpeg: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let dir = output.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".tmp-\(UUID().uuidString)-\(output.lastPathComponent)")
        let trf = dir.appendingPathComponent(".trf-\(UUID().uuidString).trf")
        defer { try? FileManager.default.removeItem(at: trf); try? FileManager.default.removeItem(at: tmp) }

        // Scale prefix applied to BOTH vidstab passes so detected/applied transforms share coords.
        let scale = maxLongEdge > 0
            ? "scale=\(maxLongEdge):\(maxLongEdge):force_original_aspect_ratio=decrease:force_divisible_by=2,"
            : ""
        // H.264 + small file; copy audio through (ffmpeg omits it gracefully if absent).
        let encode = ["-c:v", "libx264", "-preset", "veryfast", "-crf", "19",
                      "-pix_fmt", "yuv420p", "-c:a", "copy"]

        switch capability {
        case .vidstab:
            try await run(ffmpeg, ["-y", "-i", source.path,
                "-vf", "\(scale)vidstabdetect=shakiness=6:accuracy=15:result=\(trf.path)",
                "-f", "null", "-"], progress: { progress($0 * 0.5) })
            try Task.checkCancellation()
            let smoothing = Int((6 + smoothness * 54).rounded())   // frames of look-ahead/behind
            try await run(ffmpeg, ["-y", "-i", source.path,
                "-vf", "\(scale)vidstabtransform=input=\(trf.path):smoothing=\(smoothing):crop=black:optzoom=1,unsharp=5:5:0.8:3:3:0.4"]
                + encode + [tmp.path], progress: { progress(0.5 + $0 * 0.5) })
        case .deshake:
            try await run(ffmpeg, ["-y", "-i", source.path,
                "-vf", "\(scale)deshake=rx=16:ry=16:edge=clamp"] + encode + [tmp.path],
                progress: progress)
        case .none:
            throw Failure(reason: "no ffmpeg stabilization filter available")
        }
        try Task.checkCancellation()
        guard await ProxyService.isOpenableVideo(tmp) else {
            throw Failure(reason: "ffmpeg produced an unopenable file")
        }
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.moveItem(at: tmp, to: output)
        progress(1)
    }

    /// Run ffmpeg, draining stderr (kept for diagnostics). Throws on nonzero exit or cancel.
    private static func run(_ ffmpeg: String, _ args: [String],
                            progress: @escaping @Sendable (Double) -> Void) async throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpeg)
        proc.arguments = args
        let err = Pipe(); proc.standardError = err
        proc.standardOutput = FileHandle.nullDevice   // never fills (we don't read stdout)
        try proc.run()
        let handle = err.fileHandleForReading
        let tail = OSAllocatedUnfairLock(initialState: "")
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .utility).async {
                    while true {
                        let d = handle.availableData
                        if d.isEmpty { break }
                        if let s = String(data: d, encoding: .utf8) {
                            tail.withLock { $0 = String(($0 + s).suffix(2000)) }   // keep last ~2KB
                        }
                    }
                    proc.waitUntilExit()
                    cont.resume()
                }
            }
        } onCancel: { proc.terminate() }
        if proc.terminationStatus != 0 {
            let detail = tail.withLock { $0 }.split(separator: "\n").suffix(4).joined(separator: " | ")
            Log.proxy.error("ffmpeg stab exit=\(proc.terminationStatus): \(detail)")
            throw Failure(reason: "ffmpeg exited \(proc.terminationStatus): \(detail)")
        }
        progress(1)
    }
}
