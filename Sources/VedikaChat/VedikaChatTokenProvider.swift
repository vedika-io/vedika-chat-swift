// Token provider for the chat WebView.
//
// The bundled chat page asks for a short-lived token every time it sends
// a turn. The host app mints or fetches that token from its own backend
// and hands it back through this closure. Tokens never live in the page:
// the bridge passes them through `WKScriptMessageHandlerWithReply` per
// request, and the page holds them only in memory long enough to send the
// next turn.

import Foundation

/// A short-lived bearer token the page uses to call the Vedika chat API.
public struct VedikaChatToken: Codable, Equatable {

    /// The raw token string. Must not be logged.
    public let value: String

    /// Unix epoch seconds at which the token expires. The page refreshes
    /// before this moment. The host may also force-refresh by setting
    /// `expiresAt` to 0.
    public let expiresAt: Int

    public init(value: String, expiresAt: Int) {
        self.value = value
        self.expiresAt = expiresAt
    }
}

/// A request from the page for a fresh token.
public struct VedikaChatTokenRequest: Codable, Equatable {

    /// Why the page is asking. `refresh` means a previous token is about
    /// to expire; `init` means the page just started a new thread.
    public enum Reason: String, Codable {
        case init_ = "init"
        case refresh
    }

    public let reason: Reason
    public let threadId: String?

    public init(reason: Reason, threadId: String?) {
        self.reason = reason
        self.threadId = threadId
    }
}

/// Host-side token factory. Invoked on the main queue. Should call out to
/// the host's own backend and return the freshly minted token. Errors
/// propagate to the page, which then surfaces them to the user.
public typealias VedikaChatTokenProvider =
    @MainActor (VedikaChatTokenRequest) async throws -> VedikaChatToken
