import Foundation
import CryptoKit

enum ProxySignature {
    /// `mtime|size` hashed to a short hex string; nil if the file is unreadable.
    static func of(_ url: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int,
              let mtime = attrs[.modificationDate] as? Date
        else { return nil }
        let identity = "\(mtime.timeIntervalSince1970)|\(size)"
        return SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }.joined().prefix(16).description
    }
}
