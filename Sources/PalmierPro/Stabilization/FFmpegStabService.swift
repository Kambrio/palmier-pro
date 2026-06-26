import Foundation
import os

/// Bakes a stabilized copy of a source video with ffmpeg. Two-pass vid.stab when available,
/// else single-pass deshake. Atomic publish (temp → verify openable → rename), like proxies.
enum FFmpegStabService {
    struct Failure: LocalizedError { let reason: String; var errorDescription: String? { reason } }

    /// `smoothness` 0…1. Writes a stabilized `.mov` to `output`. Throws CancellationError on cancel.
    static func stabilize(
        source: URL, to output: URL, smoothness: Double,
        capability: VidStab.Capability, ffmpeg: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let dir = output.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".tmp-\(UUID().uuidString)-\(output.lastPathComponent)")
        let trf = dir.appendingPathComponent(".trf-\(UUID().uuidString).trf")
        defer { try? FileManager.default.removeItem(at: trf); try? FileManager.default.removeItem(at: tmp) }

        do {
            switch capability {
            case .vidstab:
                // Pass 1: detect motion. shakiness scales mildly with smoothness.
                try await run(ffmpeg, ["-y", "-i", source.path,
                    "-vf", "vidstabdetect=shakiness=6:accuracy=15:result=\(trf.path)",
                    "-f", "null", "-"], progress: { progress($0 * 0.5) })
                try Task.checkCancellation()
                // Pass 2: apply. smoothing = frames of look-ahead/behind; map 0…1 → 6…60.
                let smoothing = Int((6 + smoothness * 54).rounded())
                try await run(ffmpeg, ["-y", "-i", source.path,
                    "-vf", "vidstabtransform=input=\(trf.path):smoothing=\(smoothing):crop=black:zoom=0:optzoom=1,unsharp=5:5:0.8:3:3:0.4",
                    "-c:v", "prores_ks", "-profile:v", "0", "-c:a", "copy", tmp.path],
                    progress: { progress(0.5 + $0 * 0.5) })
            case .deshake:
                // Single-pass built-in. edge=clamp avoids black borders; rx/ry search range.
                try await run(ffmpeg, ["-y", "-i", source.path,
                    "-vf", "deshake=rx=16:ry=16:edge=clamp",
                    "-c:v", "prores_ks", "-profile:v", "0", "-c:a", "copy", tmp.path],
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
        } catch {
            throw error   // defer cleans up tmp/trf
        }
    }

    /// Run ffmpeg, draining stderr. Throws on nonzero exit or cancel.
    private static func run(_ ffmpeg: String, _ args: [String],
                            progress: @escaping @Sendable (Double) -> Void) async throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpeg)
        proc.arguments = args
        let err = Pipe(); proc.standardError = err; proc.standardOutput = Pipe()
        try proc.run()
        let handle = err.fileHandleForReading
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .utility).async {
                    // Drain stderr so the pipe doesn't fill and block ffmpeg.
                    while true {
                        let d = handle.availableData
                        if d.isEmpty { break }
                    }
                    proc.waitUntilExit()
                    cont.resume()
                }
            }
        } onCancel: { proc.terminate() }
        if proc.terminationStatus != 0 {
            throw Failure(reason: "ffmpeg exited \(proc.terminationStatus)")
        }
        progress(1)
    }
}
