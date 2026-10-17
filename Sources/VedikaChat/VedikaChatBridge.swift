// The native <-> page bridge.
//
// The chat page exposes a `VedikaNative` object on `window` that calls
// `window.webkit.messageHandlers.<name>.postMessage(...)`. We expose one
// handler, `vedika`, which speaks a small JSON envelope. The page side
// wraps the postMessage call in a Promise that resolves with the reply
// posted from `WKScriptMessageHandlerWithReply.userContentController(_:didReceive:replyHandler:)`.
//
// At this stage the only message the page sends is `acquireToken`. Future
// revisions can add cancel, report, or share messages through the same
// envelope without changing the bridge surface.
//
// The bridge NEVER logs the token. Diagnostic events (origin rejection,
// decode failure) flow through `VedikaChatLogging.emit`, which routes
// to the host-installed `VedikaChatBridgeLogger` or a no-op by default.
// Event codes are fixed strings; they do not contain the request
// payload or the reply body.

import Foundation
import WebKit

/// Envelope used between the page and the bridge. The page sends a JSON
/// object with `kind: "acquireToken"` (or another known kind), and the
/// bridge replies with a JSON object of the same shape.
public struct VedikaChatBridgeMessage: Codable {

    /// The kind of request. Today only `acquireToken` is defined.
    public let kind: String

    /// Per-kind payload. Decoded by the matching handler.
    public let payload: BridgePayload?

    /// Wrapper for the per-kind payload so we can keep `Codable` simple.
    public enum BridgePayload: Codable {
        case acquireToken(VedikaChatTokenRequest)

        // Custom Codable so we can switch on `kind`.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self = .acquireToken(try container.decode(VedikaChatTokenRequest.self, forKey: .acquireToken))
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .acquireToken(let req):
                try container.encode(req, forKey: .acquireToken)
            }
        }

        private enum CodingKeys: String, CodingKey {
            case acquireToken
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind, payload
    }

    public init(kind: String, payload: BridgePayload? = nil) {
        self.kind = kind
        self.payload = payload
    }
}

/// Reply envelope. `ok` is true on success; `data` carries the response;
/// `error` carries a typed error message on failure.
public struct VedikaChatBridgeReply: Codable {

    public let ok: Bool
    public let data: ReplyData?
    public let error: ReplyError?

    public enum ReplyData: Codable {
        case token(VedikaChatToken)
        case echo(String)

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let token = try container.decodeIfPresent(VedikaChatToken.self, forKey: .token) {
                self = .token(token)
            } else if let echo = try container.decodeIfPresent(String.self, forKey: .echo) {
                self = .echo(echo)
            } else {
                throw DecodingError.dataCorruptedError(
                    forKey: .token,
                    in: container,
                    debugDescription: "Reply payload must contain 'token' or 'echo'."
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .token(let token):
                try container.encode(token, forKey: .token)
            case .echo(let s):
                try container.encode(s, forKey: .echo)
            }
        }

        private enum CodingKeys: String, CodingKey {
            case token, echo
        }
    }

    public struct ReplyError: Codable, Equatable {
        public let code: String
        public let message: String
        public init(code: String, message: String) {
            self.code = code
            self.message = message
        }
    }

    private enum CodingKeys: String, CodingKey {
        case ok, data, error
    }

    public static func token(_ t: VedikaChatToken) -> VedikaChatBridgeReply {
        VedikaChatBridgeReply(ok: true, data: .token(t), error: nil)
    }

    public static func echo(_ s: String) -> VedikaChatBridgeReply {
        VedikaChatBridgeReply(ok: true, data: .echo(s), error: nil)
    }

    public static func failure(code: String, message: String) -> VedikaChatBridgeReply {
        VedikaChatBridgeReply(ok: false, data: nil, error: ReplyError(code: code, message: message))
    }
}

/// WKScriptMessageHandlerWithReply that forwards `acquireToken` to the
/// host-supplied `VedikaChatTokenProvider` and replies with the freshly
/// minted token.
///
/// The handler NEVER logs the token. Origin / decode failures emit a
/// fixed event code through `VedikaChatLogging`; the request body and
/// the reply body never enter the logging path.
@MainActor
public final class VedikaChatBridge: NSObject, WKScriptMessageHandlerWithReply {

    /// The handler name the page posts to.
    public static let handlerName: String = "vedika"

    private var _tokenProvider: VedikaChatTokenProvider?

    /// Allowed origins for this bridge. Compared against
    /// `message.frameInfo` (origin) and `message.body` (URL of the
    /// message). Defaults to an empty list, which means only origins
    /// matching the bundled file URL are accepted.
    public var allowedOrigins: [String]

    /// Host-installed token factory. Set via `init` or mutated at any
    /// time before the bridge receives a message. The bridge is the
    /// only owner of this value; the view controller passes the host's
    /// provider through this property.
    public var tokenProvider: VedikaChatTokenProvider? {
        get { _tokenProvider }
        set { _tokenProvider = newValue }
    }

    public init(
        tokenProvider: VedikaChatTokenProvider?,
        allowedOrigins: [String] = []
    ) {
        self._tokenProvider = tokenProvider
        self.allowedOrigins = allowedOrigins
        super.init()
    }

    public func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) async -> (Any?, String?) {

        guard message.name == VedikaChatBridge.handlerName else {
            VedikaChatLogging.emit("UNKNOWN_HANDLER")
            return (nil, "unknown handler \(message.name)")
        }

        // Defence in depth: the WebView only delivers messages from
        // the configured page world, but a misconfigured web view or
        // a future API change should not be the only line of defence.
        // We compare the message's origin against the allowlist.
        let origin = message.frameInfo.request.url?.host ?? ""
        let scheme = message.frameInfo.request.url?.scheme ?? ""
        if !allowedOrigins.isEmpty {
            let originAllowed = Self.originIsAllowed(
                rules: allowedOrigins, scheme: scheme, host: origin
            )
            if !originAllowed {
                VedikaChatLogging.emit("ORIGIN_REJECTED")
                return (
                    reply(for: VedikaChatBridgeReply.failure(
                        code: "BAD_ORIGIN",
                        message: "unknown origin"
                    )),
                    nil
                )
            }
        }

        // The page sends a JSON string as its body.
        let body: Data
        if let str = message.body as? String {
            guard let data = str.data(using: .utf8) else {
                VedikaChatLogging.emit("BAD_BODY_ENCODING")
                return (nil, "body is not UTF-8")
            }
            body = data
        } else if let dict = message.body as? [String: Any] {
            // Some page senders ship an object instead of a JSON string;
            // bridge it through the same codepath.
            do {
                body = try JSONSerialization.data(withJSONObject: dict, options: [])
            } catch {
                VedikaChatLogging.emit("BAD_BODY_SERIALIZE")
                return (nil, "body is not serialisable: \(error.localizedDescription)")
            }
        } else {
            VedikaChatLogging.emit("BAD_BODY_TYPE")
            return (nil, "body is neither string nor object")
        }

        // Decode the envelope.
        let decoded: VedikaChatBridgeMessage
        do {
            decoded = try JSONDecoder().decode(VedikaChatBridgeMessage.self, from: body)
        } catch {
            VedikaChatLogging.emit("BAD_ENVELOPE")
            return (nil, "decode failed: \(error.localizedDescription)")
        }

        switch decoded.kind {
        case "acquireToken":
            let payload = decoded.payload
            guard case .acquireToken(let request) = payload else {
                VedikaChatLogging.emit("BAD_PAYLOAD")
                return (reply(for: VedikaChatBridgeReply.failure(
                    code: "BAD_PAYLOAD",
                    message: "acquireToken requires payload { reason, threadId? }"
                )))
            }
            guard let provider = _tokenProvider else {
                VedikaChatLogging.emit("NO_PROVIDER")
                return (reply(for: VedikaChatBridgeReply.failure(
                    code: "NO_PROVIDER",
                    message: "Host app has not installed a VedikaChatTokenProvider."
                )))
            }
            do {
                let token = try await provider(request)
                // NOTE: the token is serialised into the reply; the
                // page asked for it. The logger is NEVER given the
                // token — only fixed event codes.
                return (reply(for: VedikaChatBridgeReply.token(token)), nil)
            } catch {
                VedikaChatLogging.emit("PROVIDER_ERROR")
                return (reply(for: VedikaChatBridgeReply.failure(
                    code: "PROVIDER_ERROR",
                    message: error.localizedDescription
                )))
            }
        case "ping":
            return (reply(for: VedikaChatBridgeReply.echo("pong")), nil)
        default:
            VedikaChatLogging.emit("UNKNOWN_KIND")
            return (reply(for: VedikaChatBridgeReply.failure(
                code: "UNKNOWN_KIND",
                message: "Unknown message kind: \(decoded.kind)"
            )))
        }
    }

    // MARK: - Test surface

    /// Process a request body and origin host directly, without
    /// requiring a `WKScriptMessage`. Used by the unit tests so they
    /// can drive the bridge without subclassing WebKit classes whose
    /// initialisers are not public in newer SDKs.
    @MainActor
    public func processForTesting(
        handlerName: String,
        body inputBody: Any,
        originHost: String,
        originScheme: String = "https"
    ) async -> (Any?, String?) {
        // Mirror the handler-name check from `userContentController(_:didReceive:)`.
        guard handlerName == VedikaChatBridge.handlerName else {
            VedikaChatLogging.emit("UNKNOWN_HANDLER")
            return (nil, "unknown handler \(handlerName)")
        }

        // Mirror the origin check from `userContentController(_:didReceive:)`.
        if !allowedOrigins.isEmpty {
            let originAllowed = Self.originIsAllowed(
                rules: allowedOrigins, scheme: originScheme, host: originHost
            )
            if !originAllowed {
                VedikaChatLogging.emit("ORIGIN_REJECTED")
                return (
                    reply(for: VedikaChatBridgeReply.failure(
                        code: "BAD_ORIGIN",
                        message: "unknown origin"
                    )),
                    nil
                )
            }
        }

        let body: Data
        if let str = inputBody as? String {
            guard let data = str.data(using: .utf8) else {
                VedikaChatLogging.emit("BAD_BODY_ENCODING")
                return (nil, "body is not UTF-8")
            }
            body = data
        } else if let dict = inputBody as? [String: Any] {
            do {
                body = try JSONSerialization.data(withJSONObject: dict, options: [])
            } catch {
                VedikaChatLogging.emit("BAD_BODY_SERIALIZE")
                return (nil, "body is not serialisable: \(error.localizedDescription)")
            }
        } else {
            VedikaChatLogging.emit("BAD_BODY_TYPE")
            return (nil, "body is neither string nor object")
        }

        let decoded: VedikaChatBridgeMessage
        do {
            decoded = try JSONDecoder().decode(VedikaChatBridgeMessage.self, from: body)
        } catch {
            VedikaChatLogging.emit("BAD_ENVELOPE")
            return (nil, "decode failed: \(error.localizedDescription)")
        }

        switch decoded.kind {
        case "acquireToken":
            let payload = decoded.payload
            guard case .acquireToken(let request) = payload else {
                VedikaChatLogging.emit("BAD_PAYLOAD")
                return (reply(for: VedikaChatBridgeReply.failure(
                    code: "BAD_PAYLOAD",
                    message: "acquireToken requires payload { reason, threadId? }"
                )))
            }
            guard let provider = _tokenProvider else {
                VedikaChatLogging.emit("NO_PROVIDER")
                return (reply(for: VedikaChatBridgeReply.failure(
                    code: "NO_PROVIDER",
                    message: "Host app has not installed a VedikaChatTokenProvider."
                )))
            }
            do {
                let token = try await provider(request)
                return (reply(for: VedikaChatBridgeReply.token(token)), nil)
            } catch {
                VedikaChatLogging.emit("PROVIDER_ERROR")
                return (reply(for: VedikaChatBridgeReply.failure(
                    code: "PROVIDER_ERROR",
                    message: error.localizedDescription
                )))
            }
        case "ping":
            return (reply(for: VedikaChatBridgeReply.echo("pong")), nil)
        default:
            VedikaChatLogging.emit("UNKNOWN_KIND")
            return (reply(for: VedikaChatBridgeReply.failure(
                code: "UNKNOWN_KIND",
                message: "Unknown message kind: \(decoded.kind)"
            )))
        }
    }

    // MARK: - Origin matching

    /// Match an allowlist rule against an origin host. Supports exact
    /// host matches (`appassets.example.com`) and host-only wildcard
    /// rules prefixed by `*.` (`*.example.com`). A wildcard rule does
    /// NOT match its parent domain: `*.example.com` matches
    /// `chat.example.com` and `deep.chat.example.com`, but NOT
    /// `example.com` itself (matching RFC 6125 wildcard certificate
    /// semantics).
    /// True when a page at `scheme://host` may use the bridge under the
    /// allowlist `rules`. The rules name hosts only, so the scheme is
    /// checked first: only `https` passes, and a plain `http` page on an
    /// allowed host (or on any host a wildcard covers) never does.
    internal static func originIsAllowed(rules: [String], scheme: String, host: String) -> Bool {
        guard scheme.lowercased() == "https" else { return false }
        return rules.contains { ruleMatchesOrigin(rule: $0, host: host) }
    }

    internal static func ruleMatchesOrigin(rule: String, host: String) -> Bool {
        if rule == host { return true }
        if rule.hasPrefix("*.") {
            let suffix = String(rule.dropFirst(2))
            return host.hasSuffix("." + suffix)
        }
        return false
    }

    // MARK: - Reply encoding

    /// Encodes a `VedikaChatBridgeReply` into the JSON the page expects.
    /// We always reply with a JSON string (never a bare object) so the
    /// page's `JSON.parse` path stays consistent across iOS versions.
    private func reply(for value: VedikaChatBridgeReply) -> (Any?, String?) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value),
              let json = String(data: data, encoding: .utf8) else {
            VedikaChatLogging.emit("ENCODE_FAILED")
            return (nil, "ENCODE_FAILED")
        }
        return (json, nil)
    }
}