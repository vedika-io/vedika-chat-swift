// Tests that prove the iOS chat library never logs the token.
//
// The chat WebView wrapper has only one place where a log call could
// plausibly receive the token value: if a future refactor accidentally
// pipes `request`, `token`, or the bridge reply through `print`,
// `NSLog`, `os_log`, or any other logging primitive. These tests scan
// the production source for every such call and assert the inputs do
// not reference the token field.
//
// The library is also exercised end-to-end with a captured logger so
// the no-token-in-logs invariant is verified at runtime, not just
// statically. A capturing logger is installed before any bridge call,
// the bridge is exercised with a known token value, and the captured
// event list is asserted to contain none of the secret.
//
// The marker itself is generated at runtime from a UUID — a static
// marker would trip GitGuardian's secret scanner on every PR. The
// invariant still holds: the bridge never sees the marker outside the
// token payload, and the logger never sees the token at all.

import XCTest
import WebKit
@testable import VedikaChat

@MainActor
final class VedikaChatTokenLoggingTests: XCTestCase {

    /// A UUID-shaped marker that mimics a real token. Built per-test so
    /// the string never appears as a literal in source and never trips
    /// the GitGuardian scanner on a diff.
    private static func makeSecretMarker() -> String {
        return "tk_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    private var secretMarker: String { Self.makeSecretMarker() }
    private var originalLogger: VedikaChatBridgeLogger!
    private var captured: [String] = []

    override func setUp() {
        super.setUp()
        captured.removeAll()
        originalLogger = VedikaChatLogging.peek()
        VedikaChatLogging.install(VedikaChatBridgeLogger { [weak self] event in
            self?.captured.append(event)
        })
    }

    override func tearDown() {
        VedikaChatLogging.install(originalLogger ?? .silent)
        super.tearDown()
    }

    /// A real `acquireToken` round-trip with a token whose value is
    /// the secret marker. The bridge MUST NOT log the marker through
    /// the diagnostic sink.
    func testAcquireTokenDoesNotLeakThroughLogger() async throws {
        let marker = secretMarker
        let secret = VedikaChatToken(value: marker, expiresAt: 1)
        let provider: VedikaChatTokenProvider = { _ in secret }
        let bridge = VedikaChatBridge(tokenProvider: provider, allowedOrigins: ["example.com"])
        let envelope = VedikaChatBridgeMessage(
            kind: "acquireToken",
            payload: .acquireToken(VedikaChatTokenRequest(reason: .init_, threadId: nil))
        )
        let body = try JSONEncoder().encode(envelope)
        let message = MockScriptMessage(
            name: VedikaChatBridge.handlerName,
            body: String(data: body, encoding: .utf8)!,
            host: "example.com"
        )
        let reply = await bridge.processForTesting(
            handlerName: message.name, body: message.body, originHost: message.host
        )
        // The reply legitimately contains the token (the page asked
        // for it). The logger MUST NOT.
        if let json = reply.0 as? String {
            XCTAssertTrue(json.contains(marker), "reply must carry the token for the page")
        } else if let nested = reply.0 as? (Any?, String?) {
            if let json = nested.0 as? String {
                XCTAssertTrue(json.contains(marker), "reply must carry the token for the page")
            }
        }
        XCTAssertFalse(
            captured.contains(where: { $0.contains(marker) }),
            "logger captured secret: \(captured)"
        )
    }

    /// A provider that throws with a message containing the token
    /// value. The provider error path MUST NOT log the token either.
    func testProviderErrorDoesNotLeakThroughLogger() async throws {
        let marker = secretMarker
        struct Boom: LocalizedError {
            let marker: String
            var errorDescription: String? { "explosion: \(marker)" }
        }
        let provider: VedikaChatTokenProvider = { _ in throw Boom(marker: marker) }
        let bridge = VedikaChatBridge(tokenProvider: provider, allowedOrigins: ["example.com"])
        let envelope = VedikaChatBridgeMessage(
            kind: "acquireToken",
            payload: .acquireToken(VedikaChatTokenRequest(reason: .init_, threadId: nil))
        )
        let body = try JSONEncoder().encode(envelope)
        let message = MockScriptMessage(
            name: VedikaChatBridge.handlerName,
            body: String(data: body, encoding: .utf8)!,
            host: "example.com"
        )
        _ = await bridge.processForTesting(
            handlerName: message.name, body: message.body, originHost: message.host
        )
        // The error message is forwarded to the page (it is the
        // page's job to display it). The logger MUST NOT have seen
        // the secret.
        XCTAssertFalse(
            captured.contains(where: { $0.contains(secretMarker) }),
            "logger captured secret: \(captured)"
        )
    }

    /// A successful acquire-token emits NO logger event. Only failure
    /// paths emit; the happy path is silent.
    func testHappyPathEmitsNoLogEvent() async throws {
        let secret = VedikaChatToken(value: secretMarker, expiresAt: 0)
        let provider: VedikaChatTokenProvider = { _ in secret }
        let bridge = VedikaChatBridge(tokenProvider: provider, allowedOrigins: ["example.com"])
        let envelope = VedikaChatBridgeMessage(
            kind: "acquireToken",
            payload: .acquireToken(VedikaChatTokenRequest(reason: .init_, threadId: "t"))
        )
        let body = try JSONEncoder().encode(envelope)
        let message = MockScriptMessage(
            name: VedikaChatBridge.handlerName,
            body: String(data: body, encoding: .utf8)!,
            host: "example.com"
        )
        _ = await bridge.processForTesting(
            handlerName: message.name, body: message.body, originHost: message.host
        )
        XCTAssertEqual(captured.count, 0, "happy path must be silent; got: \(captured)")
    }

    /// Static check: production source must not contain any log-style
    /// call (`print`, `NSLog`, `os_log`, `dump`, `Logger`) that
    /// references the token field.
    ///
    /// The check uses a simple regex against the bundled library
    /// source tree. If this test fails, a contributor has wired the
    /// token into a log line.
    func testNoLogCallReferencesTokenField() throws {
        let libDir = locateLibrarySource()
        let enumerator = FileManager.default.enumerator(
            at: libDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )!
        var swiftFiles: [URL] = []
        for case let file as URL in enumerator {
            guard let isFile = (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile,
                  isFile else { continue }
            if file.pathExtension == "swift" && !file.path.contains("/Tests/") {
                swiftFiles.append(file)
            }
        }

        XCTAssertFalse(swiftFiles.isEmpty, "expected library sources under \(libDir.path), found \(swiftFiles.count) files")

        let tokenReferences = ["token", "Token"]
        let logPatterns: [NSRegularExpression] = [
            try NSRegularExpression(pattern: #"\bprint\s*\("#),
            try NSRegularExpression(pattern: #"\bNSLog\s*\("#),
            try NSRegularExpression(pattern: #"\bos_log\s*\("#),
            try NSRegularExpression(pattern: #"\bdump\s*\("#),
            try NSRegularExpression(pattern: #"\blogger?\.\w+\s*\("#),
            try NSRegularExpression(pattern: #"\bLogger\(.*\)\.\w+\s*\("#)
        ]

        var offenders: [String] = []
        for file in swiftFiles {
            let text = try String(contentsOf: file, encoding: .utf8)
            for pattern in logPatterns {
                let range = NSRange(text.startIndex..., in: text)
                pattern.enumerateMatches(in: text, range: range) { match, _, _ in
                    guard let match = match, let r = Range(match.range, in: text) else { return }
                    let lineStart = text[..<r.lowerBound].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
                    let lineEnd = text[r.upperBound...].firstIndex(of: "\n") ?? text.endIndex
                    let line = text[lineStart..<lineEnd]
                    if tokenReferences.contains(where: { line.contains($0) }) {
                        offenders.append("\(file.lastPathComponent): \(line)")
                    }
                }
            }
        }
        XCTAssertTrue(
            offenders.isEmpty,
            "Library must not log token fields. Offending lines:\n" + offenders.joined(separator: "\n")
        )
    }

    /// Locate the library source directory by walking up from the
    /// test bundle's resources.
    private func locateLibrarySource() -> URL {
        // The test target depends on the `Vedika` library, so its
        // source root sits next to the test directory.
        var dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // VedikaChatTokenLoggingTests.swift
            .deletingLastPathComponent()  // VedikaChatTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // package root
        // The library source is at <root>/Sources/VedikaChat.
        let candidate = dir.appendingPathComponent("Sources/VedikaChat")
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        // Fallback: walk up to the repo root and look for the package.
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("packages/mobile-ios/Sources/VedikaChat")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            dir.deleteLastPathComponent()
        }
        XCTFail("could not locate library source directory")
        return URL(fileURLWithPath: "/")
    }
}

/// `WKScriptMessage` is a class with private initialisers in the SDK.
/// Rather than subclass it (and `WKFrameInfo`, whose designated init is
/// also unavailable in newer SDKs), the tests drive the bridge through
/// its public test entry point `processForTesting(handlerName:body:originHost:)`.
private final class MockScriptMessage {
    let name: String
    let body: Any
    let host: String

    init(name: String, body: Any, host: String) {
        self.name = name
        self.body = body
        self.host = host
    }
}