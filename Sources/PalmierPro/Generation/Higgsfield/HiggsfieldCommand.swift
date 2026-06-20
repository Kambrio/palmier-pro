import Foundation

/// Builds `higgsfield generate create …` argv from a generation request.
/// Reference paths are local files; the CLI auto-uploads them.
enum HiggsfieldCommand {
    static func argv(
        genInput: GenerationInput,
        assetType: ClipType,
        referencePaths: [String],
        numImages: Int
    ) -> [String] {
        var argv = ["generate", "create", genInput.model,
                    "--prompt", genInput.prompt,
                    "--aspect_ratio", genInput.aspectRatio]
        if let resolution = genInput.resolution {
            argv.append(contentsOf: ["--resolution", resolution])
        }

        switch assetType {
        case .image:
            for path in referencePaths { argv.append(contentsOf: ["--image", path]) }
        case .video:
            // First ref is the start frame; a second (optional) is the end frame.
            if let first = referencePaths.first {
                argv.append(contentsOf: ["--start-image", first])
            }
            if referencePaths.count > 1 {
                argv.append(contentsOf: ["--end-image", referencePaths[1]])
            }
        case .audio:
            for path in referencePaths { argv.append(contentsOf: ["--audio", path]) }
        case .text, .lottie:
            break
        }

        argv.append(contentsOf: ["--wait", "--json"])
        return argv
    }
}
