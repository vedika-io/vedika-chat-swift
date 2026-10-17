// Tests for `VedikaChatBridge`.
//
// The bridge is the only native <-> page handshake. It must:
//   * Decode the page's envelope.
//   * Forward `acquireToken` to the host's `VedikaChatTokenProvider`.
//   * Reply with a typed `VedikaChatBridgeReply`.
//   * Refuse unknown kinds with a typed error.
//   * Refuse messages from origins outside the configured allowlist.
//   * NEVER log the token value.
//
// These tests run on the main actor (the bridge is `@MainActor`) and
// drive the handler with a manually constructed `WKScriptMessage`.

import XCTest
import WebKit
@testable import VedikaChat

@MainActor
final class VedikaChatBridgeTests: XCTestCase {

    /// Decode the JSON-string first tuple element of the bridge reply.
    private func decodeReply(_ tuple: (Any?, String?)) throws -> VedikaChatBridgeReply {
        // `tuple.0` is `Any?`. Sometimes Swift's bridging through
        // `WK_SWIFT_ASYNC(3)` wraps the result so the actual `String` is
        // doubly-optional. Handle both.
        let anyString: String?
        if let s = tuple.0 as? String {
            anyString = s
        } else if let inner = tuple.0 as? String? {
            anyString = inner
        } else if let inner = tuple.0 as? (Any?, String?) {
            // Whole tuple was returned as the first element somehow.
            guard let s = inner.0 as? String else {
                XCTFail("Expected JSON string reply, got nested tuple \(String(describing: inner))")
                throw NSError(domain: "test", code: 0)
            }
            anyString = s
        } else {
            XCTFail("Expected JSON string reply, got \(String(describing: tuple.0)) (type: \(type(of: tuple.0)))")
            throw NSError(domain: "test", code: 0)
        }
        guard let json = anyString else {
            XCTFail("JSON string was nil")
            throw NSError(domain: "test", code: 0)
        }
        return try JSONDecoder().decode(VedikaChatBridgeReply.self, from: json.data(using: .utf8)!)
    }

    /// A provider that returns a canned token. Verifies the bridge
    /// forwards the request faithfully.
    func testAcquireTokenForwardsRequest() async throws {
        let expected = VedikaChatToken(value: "tk_test_abc", expiresAt: 1_900_000_000)
        let provider: VedikaChatTokenProvider = { request in
            XCTAssertEqual(request.reason, .init_)
            XCTAssertEqual(request.threadId, "thread-1")
            return expected
        }
        let bridge = VedikaChatBridge(tokenProvider: provider, allowedOrigins: ["example.com"])
        let envelope = VedikaChatBridgeMessage(
            kind: "acquireToken",
            payload: .acquireToken(
                VedikaChatTokenRequest(reason: .init_, threadId: "thread-1")
            )
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
        XCTAssertNil(reply.1)
        let decoded = try decodeReply(reply)
        XCTAssertTrue(decoded.ok)
        guard case .token(let token) = decoded.data else {
            XCTFail("Expected token, got \(String(describing: decoded.data))")
            return
        }
        XCTAssertEqual(token, expected)
    }

    /// A bridge with no provider must reject `acquireToken` with a typed
    /// `NO_PROVIDER` error reply, not throw.
    func testAcquireTokenWithoutProvider() async throws {
        let bridge = VedikaChatBridge(tokenProvider: nil, allowedOrigins: ["example.com"])
        let envelope = VedikaChatBridgeMessage(
            kind: "acquireToken",
            payload: .acquireToken(
                VedikaChatTokenRequest(reason: .refresh, threadId: nil)
            )
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
        XCTAssertNil(reply.1)
        let decoded = try decodeReply(reply)
        XCTAssertFalse(decoded.ok)
        XCTAssertEqual(decoded.error?.code, "NO_PROVIDER")
    }

    /// A provider that throws must surface its error to the page as a
    /// typed `PROVIDER_ERROR` reply.
    func testProviderErrorPropagates() async throws {
        struct Boom: LocalizedError { var errorDescription: String? { "network gone" } }
        let provider: VedikaChatTokenProvider = { _ in throw Boom() }
        let bridge = VedikaChatBridge(tokenProvider: provider, allowedOrigins: ["example.com"])
        let envelope = VedikaChatBridgeMessage(
            kind: "acquireToken",
            payload: .acquireToken(
                VedikaChatTokenRequest(reason: .init_, threadId: nil)
            )
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
        let decoded = try decodeReply(reply)
        XCTAssertFalse(decoded.ok)
        XCTAssertEqual(decoded.error?.code, "PROVIDER_ERROR")
    }

    /// Unknown kinds are rejected with a typed `UNKNOWN_KIND` reply.
    func testUnknownKind() async throws {
        let bridge = VedikaChatBridge(tokenProvider: nil, allowedOrigins: ["example.com"])
        let envelope = VedikaChatBridgeMessage(kind: "wat", payload: nil)
        let body = try JSONEncoder().encode(envelope)
        let message = MockScriptMessage(
            name: VedikaChatBridge.handlerName,
            body: String(data: body, encoding: .utf8)!,
            host: "example.com"
        )
        let reply = await bridge.processForTesting(
            handlerName: message.name, body: message.body, originHost: message.host
        )
        let decoded = try decodeReply(reply)
        XCTAssertFalse(decoded.ok)
        XCTAssertEqual(decoded.error?.code, "UNKNOWN_KIND")
    }

    /// Ping returns a literal "pong" for round-trip testing.
    func testPing() async throws {
        let bridge = VedikaChatBridge(tokenProvider: nil, allowedOrigins: ["example.com"])
        let envelope = VedikaChatBridgeMessage(kind: "ping", payload: nil)
        let body = try JSONEncoder().encode(envelope)
        let message = MockScriptMessage(
            name: VedikaChatBridge.handlerName,
            body: String(data: body, encoding: .utf8)!,
            host: "example.com"
        )
        let reply = await bridge.processForTesting(
            handlerName: message.name, body: message.body, originHost: message.host
        )
        let decoded = try decodeReply(reply)
        XCTAssertTrue(decoded.ok)
        guard case .echo(let s) = decoded.data else {
            XCTFail("Expected echo, got \(String(describing: decoded.data))")
            return
        }
        XCTAssertEqual(s, "pong")
    }

    /// Messages from a handler that is not `vedika` are rejected with
    /// a string error in the second tuple element.
    func testUnknownHandler() async {
        let bridge = VedikaChatBridge(tokenProvider: nil, allowedOrigins: ["example.com"])
        let message = MockScriptMessage(name: "wrong", body: "{}", host: "example.com")
        let reply = await bridge.processForTesting(
            handlerName: message.name, body: message.body, originHost: message.host
        )
        XCTAssertNil(reply.0)
        XCTAssertTrue(reply.1?.contains("unknown handler") == true)
    }

    /// The provider property can be swapped at any time before a message
    /// arrives. This verifies the bridge really uses the latest value.
    func testProviderSwappable() async throws {
        let provider1: VedikaChatTokenProvider = { _ in VedikaChatToken(value: "tk_a", expiresAt: 1) }
        let provider2: VedikaChatTokenProvider = { _ in VedikaChatToken(value: "tk_b", expiresAt: 2) }
        let bridge = VedikaChatBridge(tokenProvider: provider1, allowedOrigins: ["example.com"])
        bridge.tokenProvider = provider2

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
        let decoded = try decodeReply(reply)
        guard case .token(let t) = decoded.data else { XCTFail("Expected token"); return }
        XCTAssertEqual(t.value, "tk_b")
    }

    /// Messages from origins outside the allowlist are rejected with
    /// `BAD_ORIGIN`. The bridge never invokes the provider.
    func testOriginRejected() async throws {
        let providerCalls = Counter()
        let provider: VedikaChatTokenProvider = { _ in
            providerCalls.bump()
            return VedikaChatToken(value: "tk_x", expiresAt: 0)
        }
        let bridge = VedikaChatBridge(tokenProvider: provider, allowedOrigins: ["example.com"])
        let envelope = VedikaChatBridgeMessage(
            kind: "acquireToken",
            payload: .acquireToken(VedikaChatTokenRequest(reason: .init_, threadId: nil))
        )
        let body = try JSONEncoder().encode(envelope)
        let message = MockScriptMessage(
            name: VedikaChatBridge.handlerName,
            body: String(data: body, encoding: .utf8)!,
            host: "evil.example.org"
        )
        let reply = await bridge.processForTesting(
            handlerName: message.name, body: message.body, originHost: message.host
        )
        let decoded = try decodeReply(reply)
        XCTAssertFalse(decoded.ok)
        XCTAssertEqual(decoded.error?.code, "BAD_ORIGIN")
        XCTAssertEqual(providerCalls.value, 0)
    }

    /// An empty allowlist (the default) lets every message through;
    /// the bridge defers to the WebView's own origin enforcement.
    /// This test pins that contract so a future change that closes
    /// the default must update the docs.
    func testEmptyAllowlistAcceptsAnyOrigin() async throws {
        let provider: VedikaChatTokenProvider = { _ in
            VedikaChatToken(value: "tk_y", expiresAt: 0)
        }
        let bridge = VedikaChatBridge(tokenProvider: provider, allowedOrigins: [])
        let envelope = VedikaChatBridgeMessage(
            kind: "ping",
            payload: nil
        )
        let body = try JSONEncoder().encode(envelope)
        let message = MockScriptMessage(
            name: VedikaChatBridge.handlerName,
            body: String(data: body, encoding: .utf8)!,
            host: "anything.example"
        )
        let reply = await bridge.processForTesting(
            handlerName: message.name, body: message.body, originHost: message.host
        )
        let decoded = try decodeReply(reply)
        XCTAssertTrue(decoded.ok)
    }

    /// Wildcard allowlist rules (e.g. `*.example.com`) match any host
    /// in the subdomain.
    func testWildcardAllowlist() {
        XCTAssertTrue(
            VedikaChatBridge.ruleMatchesOrigin(rule: "*.example.com", host: "chat.example.com")
        )
        XCTAssertTrue(
            VedikaChatBridge.ruleMatchesOrigin(rule: "*.example.com", host: "deep.chat.example.com")
        )
        XCTAssertFalse(
            VedikaChatBridge.ruleMatchesOrigin(rule: "*.example.com", host: "example.org")
        )
        XCTAssertFalse(
            VedikaChatBridge.ruleMatchesOrigin(rule: "*.example.com", host: "example.com")
        )
    }

    /// The allowlist names hosts, so the bridge checks the scheme first:
    /// an http page on an allowed host, or under a wildcard, is refused.
    func testTheBridgeAnswersOnlyHttpsPages() async throws {
        let bridge = VedikaChatBridge(
            tokenProvider: nil,
            allowedOrigins: ["example.com", "*.example.org"]
        )
        let envelope = VedikaChatBridgeMessage(kind: "ping", payload: nil)
        let body = String(data: try JSONEncoder().encode(envelope), encoding: .utf8)!
        let cases: [(scheme: String, host: String, ok: Bool)] = [
            ("https", "example.com", true),
            ("HTTPS", "example.com", true),
            ("http", "example.com", false),
            ("https", "chat.example.org", true),
            ("http", "chat.example.org", false),
            ("ws", "chat.example.org", false),
            ("file", "example.com", false),
            ("", "example.com", false),
        ]
        for c in cases {
            let reply = await bridge.processForTesting(
                handlerName: VedikaChatBridge.handlerName,
                body: body,
                originHost: c.host,
                originScheme: c.scheme
            )
            let decoded = try decodeReply(reply)
            XCTAssertEqual(decoded.ok, c.ok, "\(c.scheme)://\(c.host)")
            if !c.ok { XCTAssertEqual(decoded.error?.code, "BAD_ORIGIN", "\(c.scheme)://\(c.host)") }
        }
    }

    /// Theme injection script is empty when nothing is set, so the
    /// page keeps its bundled defaults.
    func testEmptyThemeScriptIsEmpty() {
        let js = VedikaChatViewController.buildThemeInjectionScript(for: VedikaChatTheme())
        XCTAssertEqual(js, "")
    }

    /// Theme injection script carries the host overrides.
    func testThemeInjectionCarriesOverrides() {
        let theme = VedikaChatTheme(
            backgroundColor: "#101418",
            textColor: "#ffffff",
            accentColor: "#ff6a00",
            fontFamily: "Helvetica"
        )
        let js = VedikaChatViewController.buildThemeInjectionScript(for: theme)
        XCTAssertTrue(js.contains("--vedika-bg:#101418"))
        XCTAssertTrue(js.contains("--vedika-fg:#ffffff"))
        XCTAssertTrue(js.contains("--vedika-accent:#ff6a00"))
        XCTAssertTrue(js.contains("--vedika-font:Helvetica"))
    }

    /// Safe-area injection script sets the four CSS env() variables.
    func testSafeAreaInjectionScript() {
        let insets = UIEdgeInsets(top: 44, left: 0, bottom: 34, right: 0)
        let js = VedikaChatViewController.buildSafeAreaInjectionScript(for: insets)
        XCTAssertTrue(js.contains("'--vedika-safe-top','44px'"))
        XCTAssertTrue(js.contains("'--vedika-safe-bottom','34px'"))
        XCTAssertTrue(js.contains("'--vedika-safe-left','0px'"))
        XCTAssertTrue(js.contains("'--vedika-safe-right','0px'"))
    }
}

/// Lightweight counter used by tests to assert the provider is or is not
/// invoked.
private final class Counter {
    private(set) var value: Int = 0
    func bump() { value += 1 }
}

/// `WKScriptMessage` is a class with private initialisers in the SDK.
/// Rather than subclass it (and `WKFrameInfo`, whose designated init is
/// also unavailable in newer SDKs), the tests drive the bridge through
/// its public test entry point `processForTesting(body:originHost:)`.
/// The test entry point exercises the same origin check, body decoding
/// and reply path the WebView handler uses.
private final class MockScriptMessage {
    let name: String
    let body: Any
    let host: String

    init(name: String, body: Any, host: String) {
        self.name = name
        self.body = body
        self.host = host
    }

    convenience init(name: String, body: Any) {
        self.init(name: name, body: body, host: "example.com")
    }
}