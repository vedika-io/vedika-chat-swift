// The hosted chat page: URL validation and the navigation policy.
//
// The default way to show the chat is to load its https page. A fix to
// the chat then reaches every installed app the next time the chat
// opens, with no app release. This file holds the pure decisions about
// that page (is the URL acceptable, may the WebView go there), so they
// can be unit-tested without a WebView.

import Foundation

/// Why the hosted chat page did not load.
public enum VedikaChatLoadFailure: Equatable, Sendable {

    /// Offline, DNS failure, connection refused or dropped.
    case network

    /// The server did not answer in time.
    case timeout

    /// The secure connection could not be established.
    case secureConnection

    /// The server answered with an HTTP status of 400 or higher.
    case httpError

    /// Anything else WebKit reported for the main page.
    case other
}

/// Errors from building a `VedikaChatConfig`.
public enum VedikaChatConfigError: Error, Equatable, CustomStringConvertible {

    /// `chatURL` must be an https URL with a host and no embedded credentials.
    case invalidChatURL

    /// A non-empty `allowedOrigins` replaces the default, so it must still
    /// include the chat page's own host or the page would be locked out of
    /// the bridge.
    case allowedOriginsMissingChatHost(String)

    public var description: String {
        switch self {
        case .invalidChatURL:
            return "chatURL must be an https URL with a host and no embedded credentials."
        case .allowedOriginsMissingChatHost(let host):
            return "allowedOrigins must include the chat page's host (\(host))."
        }
    }
}

enum VedikaChatHostedURL {

    /// True when `url` is an https URL with a plain host and no credentials.
    static func isValid(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else {
            return false
        }
        // Letters, digits, dots, dashes, and the colons of an IPv6 literal.
        return host.range(of: "^[A-Za-z0-9.:\\-]+$", options: .regularExpression) != nil
    }

    static func normalisedHost(_ url: URL) -> String? {
        url.host?.lowercased()
    }

    /// True for exactly the hosts a rule list names. Rules are exact hosts
    /// (`chat.example.com`) or `*.example.com`, which matches subdomains but
    /// not `example.com` itself.
    static func hostMatches(_ host: String, rules: [String]) -> Bool {
        let host = host.lowercased()
        return rules.contains { rule in
            let rule = rule.lowercased()
            if rule == host { return true }
            if rule.hasPrefix("*.") {
                return host.hasSuffix("." + rule.dropFirst(2))
            }
            return false
        }
    }
}

enum VedikaChatNavigationDecision: Equatable {
    case allow
    case cancel

    /// The offline page's Retry link: do not navigate, reload the chat.
    case retry
}

/// Decides which navigations the hosted chat WebView may make. Anything
/// outside the chat page's own origin (plus any hosts the app allowed) is
/// refused before a request is issued.
struct VedikaChatHostedNavigationPolicy {

    let chatURL: URL
    let allowedHosts: [String]

    func decide(
        url: URL?,
        isMainFrame: Bool,
        isLinkActivation: Bool,
        offlinePageLoading: Bool
    ) -> VedikaChatNavigationDecision {
        guard let url else { return .cancel }

        if VedikaChatOfflinePage.isRetryURL(url) { return .retry }

        // The chat page is the only content. A link the user taps never
        // takes the WebView away from it.
        if isLinkActivation { return .cancel }

        if url.scheme?.lowercased() == "about" {
            switch url.absoluteString {
            case "about:blank":
                // Our own offline page loads as `about:blank`. A frame the
                // chat page itself creates inherits the page's origin.
                return (isMainFrame ? offlinePageLoading : true) ? .allow : .cancel
            case "about:srcdoc":
                return isMainFrame ? .cancel : .allow
            default:
                return .cancel
            }
        }

        return isChatOrigin(url) || isAllowedOtherHost(url) ? .allow : .cancel
    }

    private func isChatOrigin(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              VedikaChatHostedURL.normalisedHost(url) == VedikaChatHostedURL.normalisedHost(chatURL) else {
            return false
        }
        return (url.port ?? 443) == (chatURL.port ?? 443)
    }

    /// A host the app allowed besides the chat page's own. The chat host
    /// itself is only ever accepted with its own scheme and port.
    private func isAllowedOtherHost(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = VedikaChatHostedURL.normalisedHost(url),
              host != VedikaChatHostedURL.normalisedHost(chatURL) else {
            return false
        }
        return VedikaChatHostedURL.hostMatches(host, rules: allowedHosts)
    }
}
