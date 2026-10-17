// Tests for `VedikaChatManifest.loadAndVerify(at:)`.
//
// The manifest verification is the security boundary: a bundle whose
// manifest does not verify MUST NOT load. These tests cover the happy
// path and the failure paths (missing file, hash mismatch, missing
// manifest, size mismatch) the loader must reject.
//
// All fixtures are constructed in a temporary directory at test setup,
// so the test target ships no bundle resources.

import XCTest
import CryptoKit
@testable import VedikaChat

final class VedikaChatManifestTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("VedikaChatManifestTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDir = nil
        try super.tearDownWithError()
    }

    /// SHA-256 hex of `data`, lower-case, ready for `VedikaChatManifestEntry`.
    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Build a happy-path bundle in the temp directory and return its
    /// URL. Caller can then call `loadAndVerify(at:)`.
    private func writeHappyBundle(
        files: [String: String] = [
            "index.html": "<!doctype html><html><body>hi</body></html>",
            "runtime.js": "(function(){ window.__VEDIKA_CHAT_FIXTURE__=true; })();"
        ]
    ) throws -> URL {
        let dir = tempDir.appendingPathComponent("bundle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var entries: [VedikaChatManifestEntry] = []
        for (path, contents) in files {
            let data = Data(contents.utf8)
            try data.write(to: dir.appendingPathComponent(path))
            entries.append(VedikaChatManifestEntry(path: path, sha256: sha256(data), size: data.count))
        }

        let manifest = VedikaChatManifest(schema: 1, entry: "index.html", entries: entries)
        let manifestData = try JSONEncoder().encode(manifest)
        try manifestData.write(to: dir.appendingPathComponent("manifest.json"))
        return dir
    }

    func testHappyPath() throws {
        let url = try writeHappyBundle()
        let result = VedikaChatManifest.loadAndVerify(at: url)
        switch result {
        case .success(let manifest):
            XCTAssertEqual(manifest.schema, 1)
            XCTAssertEqual(manifest.entry, "index.html")
            XCTAssertEqual(manifest.entries.count, 2)
        case .failure(let e):
            XCTFail("Expected success, got \(e)")
        }
    }

    func testHashMismatch() throws {
        let dir = try writeHappyBundle()
        // Rewrite the file with corrupted content but leave the manifest
        // hashes alone.
        try Data("garbage".utf8).write(to: dir.appendingPathComponent("index.html"))
        let result = VedikaChatManifest.loadAndVerify(at: dir)
        switch result {
        case .success:
            XCTFail("Expected failure, got success")
        case .failure(let e):
            switch e {
            case .hashMismatch: break
            default: XCTFail("Expected hashMismatch, got \(e)")
            }
        }
    }

    func testMissingManifest() throws {
        let dir = tempDir.appendingPathComponent("no-manifest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Write one file so the directory is non-empty.
        try Data("hi".utf8).write(to: dir.appendingPathComponent("index.html"))
        let result = VedikaChatManifest.loadAndVerify(at: dir)
        switch result {
        case .success:
            XCTFail("Expected failure, got success")
        case .failure(let e):
            switch e {
            case .missingManifest: break
            default: XCTFail("Expected missingManifest, got \(e)")
            }
        }
    }

    func testMissingFile() throws {
        let dir = tempDir.appendingPathComponent("missing-file-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Manifest references a file that is not on disk.
        let manifest = VedikaChatManifest(
            schema: 1,
            entry: "absent.html",
            entries: [
                VedikaChatManifestEntry(path: "absent.html", sha256: sha256(Data("x".utf8)))
            ]
        )
        try JSONEncoder().encode(manifest).write(to: dir.appendingPathComponent("manifest.json"))
        let result = VedikaChatManifest.loadAndVerify(at: dir)
        switch result {
        case .success:
            XCTFail("Expected failure, got success")
        case .failure(let e):
            switch e {
            case .missingFile: break
            default: XCTFail("Expected missingFile, got \(e)")
            }
        }
    }

    func testSizeMismatch() throws {
        let dir = try writeHappyBundle()
        // Rewrite the manifest for `index.html` to claim the wrong size.
        let data = try Data(contentsOf: dir.appendingPathComponent("index.html"))
        let manifest = VedikaChatManifest(
            schema: 1,
            entry: "index.html",
            entries: [
                VedikaChatManifestEntry(path: "index.html", sha256: sha256(data), size: data.count + 1),
                VedikaChatManifestEntry(path: "runtime.js", sha256: sha256(Data("ok".utf8)), size: 2)
            ]
        )
        // Write `runtime.js` so the directory has both files referenced.
        try Data("ok".utf8).write(to: dir.appendingPathComponent("runtime.js"))
        try JSONEncoder().encode(manifest).write(to: dir.appendingPathComponent("manifest.json"))
        let result = VedikaChatManifest.loadAndVerify(at: dir)
        switch result {
        case .success:
            XCTFail("Expected failure, got success")
        case .failure(let e):
            switch e {
            case .sizeMismatch: break
            default: XCTFail("Expected sizeMismatch, got \(e)")
            }
        }
    }
}
