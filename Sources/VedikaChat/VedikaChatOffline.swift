// What the user sees when the hosted chat page cannot be reached.
//
// The fallback is a small static page drawn inside the WebView itself
// (no script, no network, no bridge). Its Retry link points at a private
// URL scheme that the view controller intercepts and turns into a reload
// of the hosted chat URL.

import Foundation

/// Text of the offline fallback. Hosts localise it by passing their own
/// strings; the defaults are English.
public struct VedikaChatOfflineText: Equatable, Sendable {

    public var title: String
    public var message: String
    public var retryLabel: String

    public init(
        title: String = "You're offline",
        message: String = "Chat can't be reached right now. Check your connection, then try again.",
        retryLabel: String = "Retry"
    ) {
        self.title = title
        self.message = message
        self.retryLabel = retryLabel
    }
}

/// Tracks one chat page load and decides when the fallback is shown.
///
/// Only failures of the main page count. A missing image or a failed
/// sub-request must never replace a working chat with the fallback, so
/// callers pass main-frame callbacks only.
///
/// WebKit reports a finished load for the fallback page we draw. That is
/// ignored while the state is `.offline`; only `retry()` leaves it.
final class VedikaChatLoadTracker {

    enum State: Equatable {
        case idle
        case loading
        case ready
        case offline
    }

    private(set) var state: State = .idle

    /// The hosted page is being requested.
    func begin() {
        state = .loading
    }

    /// The main page finished loading. Returns true when it became ready.
    func pageFinished() -> Bool {
        guard state == .loading else { return false }
        state = .ready
        return true
    }

    /// The main page failed with `error`. Returns the error to report, or
    /// `nil` for a cancelled navigation or a failure already reported for
    /// this load.
    func mainFrameError(_ error: Error) -> VedikaChatLoadError? {
        let ns = error as NSError
        guard let failure = Self.classify(domain: ns.domain, code: ns.code) else { return nil }
        return failWith(.hostedLoadFailed(failure, httpStatus: nil))
    }

    /// The main page answered with `status`. Returns the error to report
    /// for 400 and above, or `nil` for a success or a repeat failure.
    func mainFrameHTTPError(status: Int) -> VedikaChatLoadError? {
        guard status >= 400 else { return nil }
        return failWith(.hostedLoadFailed(.httpError, httpStatus: status))
    }

    /// The user asked to try again. Returns true when a reload should start.
    func retry() -> Bool {
        guard state == .offline else { return false }
        state = .loading
        return true
    }

    private func failWith(_ error: VedikaChatLoadError) -> VedikaChatLoadError? {
        guard state != .offline else { return nil }
        state = .offline
        return error
    }

    /// Name a WebKit / URL loading error, or `nil` when it is not a failure
    /// to show (a navigation we or the page cancelled on purpose).
    static func classify(domain: String, code: Int) -> VedikaChatLoadFailure? {
        if domain == NSURLErrorDomain {
            switch code {
            case NSURLErrorCancelled:
                return nil
            case NSURLErrorTimedOut:
                return .timeout
            case NSURLErrorCannotFindHost,
                 NSURLErrorCannotConnectToHost,
                 NSURLErrorNetworkConnectionLost,
                 NSURLErrorDNSLookupFailed,
                 NSURLErrorNotConnectedToInternet,
                 NSURLErrorInternationalRoamingOff,
                 NSURLErrorCallIsActive,
                 NSURLErrorDataNotAllowed:
                return .network
            case NSURLErrorSecureConnectionFailed,
                 NSURLErrorServerCertificateHasBadDate,
                 NSURLErrorServerCertificateUntrusted,
                 NSURLErrorServerCertificateHasUnknownRoot,
                 NSURLErrorServerCertificateNotYetValid,
                 NSURLErrorClientCertificateRejected,
                 NSURLErrorClientCertificateRequired:
                return .secureConnection
            default:
                return .other
            }
        }
        // WebKit "frame load interrupted" (102): the load was cancelled by a
        // policy decision, which is not a failure.
        if domain == "WebKitErrorDomain" && code == 102 {
            return nil
        }
        return .other
    }
}

/// The static fallback page and its Retry link.
enum VedikaChatOfflinePage {

    /// Private scheme the Retry link points at. The view controller
    /// intercepts it.
    static let retryScheme = "vedika-chat-retry"
    static let retryURLString = "\(retryScheme)://now"

    static func isRetryURL(_ url: URL?) -> Bool {
        url?.scheme?.lowercased() == retryScheme
    }

    static func render(text: VedikaChatOfflineText, theme: VedikaChatTheme) -> String {
        let background = cssColor(theme.backgroundColor, fallback: "#FFFFFF")
        let foreground = cssColor(theme.textColor, fallback: "#1B1F23")
        let accent = cssColor(theme.accentColor, fallback: "#1F6FEB")
        return """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
        <title>\(escapeHTML(text.title))</title>
        <style>
        html,body{height:100%;margin:0}
        body{display:flex;align-items:center;justify-content:center;background:\(background);color:\(foreground);font:16px/1.5 -apple-system,system-ui,sans-serif;text-align:center}
        main{max-width:22rem;padding:1.5rem}
        h1{font-size:1.25rem;margin:0 0 .5rem}
        p{margin:0 0 1.5rem;opacity:.8}
        a.retry{display:inline-block;min-width:8rem;padding:.75rem 1.5rem;border-radius:.5rem;background:\(accent);color:#fff;text-decoration:none;font-weight:600}
        </style></head>
        <body><main>
        <h1>\(escapeHTML(text.title))</h1>
        <p>\(escapeHTML(text.message))</p>
        <a class="retry" href="\(retryURLString)">\(escapeHTML(text.retryLabel))</a>
        </main></body></html>
        """
    }

    static func escapeHTML(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count)
        for c in value {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(c)
            }
        }
        return out
    }

    /// A colour from the host's theme, or `fallback` when it is not a plain
    /// hex colour. The value goes into CSS, so nothing else is let through.
    static func cssColor(_ value: String?, fallback: String) -> String {
        guard let value,
              value.range(of: "^#([0-9A-Fa-f]{3,4}|[0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})$", options: .regularExpression) != nil else {
            return fallback
        }
        return value
    }
}
