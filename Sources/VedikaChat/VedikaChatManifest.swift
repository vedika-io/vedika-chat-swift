// Manifest verification for the bundled chat page.
//
// Each chat bundle ships a `manifest.json` next to `index.html` describing
// the expected files and their SHA-256 digests. The chat WebView refuses
// to load any bundle whose manifest does not verify.
//
// The manifest format matches what the upstream Vedika bundle installer
// writes, so a drop-in replacement of the bundle directory needs no
// changes here. The host app does not need to know this format — it
// only calls `VedikaChatManifest.verify(bundleURL:)` and gets a typed
// result.

import Foundation
import CryptoKit

/// One entry in a chat bundle manifest.
public struct VedikaChatManifestEntry: Codable, Equatable {
    /// Path relative to the bundle root.
    public let path: String
    /// Lower-case hex SHA-256 of the file's bytes.
    public let sha256: String
    /// Optional byte size, used as a sanity check.
    public let size: Int?

    public init(path: String, sha256: String, size: Int? = nil) {
        self.path = path
        self.sha256 = sha256
        self.size = size
    }
}

/// A chat bundle manifest.
public struct VedikaChatManifest: Codable, Equatable {
    /// Manifest schema version. Bump on any breaking format change.
    public let schema: Int
    /// The entry point the WebView should load.
    public let entry: String
    /// All expected files in the bundle.
    public let entries: [VedikaChatManifestEntry]

    public init(schema: Int, entry: String, entries: [VedikaChatManifestEntry]) {
        self.schema = schema
        self.entry = entry
        self.entries = entries
    }
}

extension VedikaChatManifest {

    /// Loads and verifies a manifest at the given directory URL.
    ///
    /// Returns the parsed manifest on success, or a typed error describing
    /// which file failed to verify and why.
    public static func loadAndVerify(at directoryURL: URL) -> Result<VedikaChatManifest, VedikaChatManifestError> {
        let manifestURL = directoryURL.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL) else {
            return .failure(.missingManifest(manifestURL.path))
        }
        let decoder = JSONDecoder()
        guard let manifest = try? decoder.decode(VedikaChatManifest.self, from: data) else {
            return .failure(.invalidManifestJSON(manifestURL.path))
        }
        for entry in manifest.entries {
            let fileURL = directoryURL.appendingPathComponent(entry.path)
            guard let fileData = try? Data(contentsOf: fileURL) else {
                return .failure(.missingFile(fileURL.path))
            }
            let actual = SHA256.hash(data: fileData)
            let actualHex = actual.map { String(format: "%02x", $0) }.joined()
            if actualHex.caseInsensitiveCompare(entry.sha256) != .orderedSame {
                return .failure(.hashMismatch(
                    path: fileURL.path,
                    expected: entry.sha256,
                    actual: actualHex
                ))
            }
            if let expectedSize = entry.size, fileData.count != expectedSize {
                return .failure(.sizeMismatch(
                    path: fileURL.path,
                    expected: expectedSize,
                    actual: fileData.count
                ))
            }
        }
        return .success(manifest)
    }
}

/// Typed errors from `VedikaChatManifest.loadAndVerify(at:)`.
public enum VedikaChatManifestError: Error, Equatable, CustomStringConvertible {
    case missingManifest(String)
    case invalidManifestJSON(String)
    case missingFile(String)
    case hashMismatch(path: String, expected: String, actual: String)
    case sizeMismatch(path: String, expected: Int, actual: Int)

    public var description: String {
        switch self {
        case .missingManifest(let p):
            return "Manifest not found at \(p)."
        case .invalidManifestJSON(let p):
            return "Manifest at \(p) is not valid JSON."
        case .missingFile(let p):
            return "Manifest references \(p), which is missing from the bundle."
        case .hashMismatch(let p, let e, let a):
            return "Hash mismatch for \(p): expected \(e), got \(a)."
        case .sizeMismatch(let p, let e, let a):
            return "Size mismatch for \(p): expected \(e) bytes, got \(a)."
        }
    }
}
