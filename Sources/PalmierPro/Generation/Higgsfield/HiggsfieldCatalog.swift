import Foundation

struct HiggsfieldModel: Identifiable, Sendable, Equatable {
    let id: String          // e.g. "nano_banana_2"
    let displayName: String
    let kind: Kind
    enum Kind: Sendable { case image, video }
}

@Observable
@MainActor
final class HiggsfieldCatalog {
    static let shared = HiggsfieldCatalog()
    private init() {}

    private(set) var image: [HiggsfieldModel] = []
    private(set) var video: [HiggsfieldModel] = []
    private(set) var isLoaded = false
    private(set) var lastError: String?

    func refresh() async {
        guard let path = HiggsfieldCLI.path else {
            lastError = "Higgsfield CLI not found"; return
        }
        async let img = Self.fetch(path: path, kindFlag: "--image", kind: .image)
        async let vid = Self.fetch(path: path, kindFlag: "--video", kind: .video)
        let (i, v) = await (img, vid)
        self.image = i
        self.video = v
        self.isLoaded = true
        self.lastError = (i.isEmpty && v.isEmpty) ? "No models (are you logged in?)" : nil
    }

    private static func fetch(path: String, kindFlag: String, kind: HiggsfieldModel.Kind) async -> [HiggsfieldModel] {
        let proc = CLIProcess(executable: path,
                              arguments: ["model", "list", kindFlag, "--json"], timeout: 30)
        guard let out = try? await proc.runCapturing(),
              let data = out.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return arr.compactMap { entry in
            guard let id = entry["id"] as? String ?? entry["name"] as? String else { return nil }
            let name = entry["display_name"] as? String ?? entry["title"] as? String ?? id
            return HiggsfieldModel(id: id, displayName: name, kind: kind)
        }
    }
}
