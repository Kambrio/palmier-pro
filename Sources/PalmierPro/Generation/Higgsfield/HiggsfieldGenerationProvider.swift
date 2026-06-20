import Foundation

/// Runs one generation via the higgsfield CLI and returns result URL(s).
struct HiggsfieldGenerationProvider {

    enum ProviderError: LocalizedError {
        case notInstalled
        var errorDescription: String? {
            switch self {
            case .notInstalled: return "Higgsfield CLI not found. Install it or sign in with `higgsfield auth login`."
            }
        }
    }

    /// Generate and return result URL strings. Retries once on the result-is-input bug.
    static func generate(
        genInput: GenerationInput,
        assetType: ClipType,
        referencePaths: [String],
        numImages: Int
    ) async throws -> [String] {
        guard let path = HiggsfieldCLI.path else { throw ProviderError.notInstalled }
        let argv = HiggsfieldCommand.argv(
            genInput: genInput, assetType: assetType,
            referencePaths: referencePaths, numImages: numImages)

        for attempt in 0..<2 {
            let out = try await CLIProcess(executable: path, arguments: argv).runCapturing()
            let lastJSON = out.split(separator: "\n").last.map(String.init) ?? out
            let urls = try HiggsfieldResult.resultURLs(fromJSON: lastJSON)
            let inputUUIDs = referencePaths.map { ($0 as NSString).lastPathComponent }
            if attempt == 0, let first = urls.first,
               HiggsfieldResult.isInputReference(first, inputUUIDs: inputUUIDs) {
                Log.generation.notice("higgsfield returned input ref; retrying")
                continue
            }
            return urls
        }
        return []
    }
}
