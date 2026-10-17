// Configuration for `VedikaChatViewController`.
//
// The chat page is HOSTED by default: give `VedikaChatConfig(chatURL:)` the
// https URL of the page and the WebView loads it from there, so a chat fix
// reaches every installed app without an app release. Shipping a copy of
// the page inside the app is an explicit opt-in
// (`VedikaChatConfig(pinnedBundle:)`); a pinned copy only changes when the
// host app is released.
//
// All defaults are safe: the chat page is the only content shown, the token
// provider is optional (a host that does not supply one gets the chat's
// built-in demo transport, which renders with fixture data), and file-access
// from arbitrary URLs is refused.

import Foundation

/// Where a pinned copy of the chat bundle lives. Either a file URL inside
/// the host app's own bundle, or a custom `URL` already pointing at the
/// verified chat directory.
public enum VedikaChatBundleSource: Equatable, Sendable {
    /// A directory bundled into the host app by name `name` (no extension).
    case bundledResource(name: String, extension: String?)

    /// A pre-resolved directory URL on disk.
    case directory(URL)

    /// The conventional location of a pinned copy, `VedikaChat.bundle`
    /// inside the host app. Nothing is pinned unless the config asks for it.
    public static let `default`: VedikaChatBundleSource =
        .bundledResource(name: "VedikaChat", extension: "bundle")
}

/// Optional theme overrides for the chat page.
///
/// Any field set to `nil` is left at the page's own default. Hosts
/// that need a full restyle should ship a `customCss` block; the bridge
/// injects it on first load and on every theme change.
public struct VedikaChatTheme: Equatable, Sendable {

    /// Background colour behind the chat surface. ARGB hex
    /// (`"#RRGGBB"` or `"#AARRGGBB"`).
    public var backgroundColor: String?

    /// Primary text colour.
    public var textColor: String?

    /// Accent colour for interactive controls.
    public var accentColor: String?

    /// Font family stack forwarded to the page.
    public var fontFamily: String?

    /// Free-form CSS appended after the bridge's own theming layer.
    /// Useful for hosts that ship their own design system.
    public var customCss: String?

    public init(
        backgroundColor: String? = nil,
        textColor: String? = nil,
        accentColor: String? = nil,
        fontFamily: String? = nil,
        customCss: String? = nil
    ) {
        self.backgroundColor = backgroundColor
        self.textColor = textColor
        self.accentColor = accentColor
        self.fontFamily = fontFamily
        self.customCss = customCss
    }
}

/// Where the chat page comes from.
public enum VedikaChatSource: Equatable, Sendable {

    /// The chat page loaded from its https URL. This is the default and
    /// the recommended choice: the page is always current.
    case hosted(URL)

    /// A copy of the chat page shipped inside the app, verified against
    /// its manifest before it loads. Opt-in only. It stays at the version
    /// it was built with until the host ships a new app.
    case pinned(VedikaChatBundleSource)
}

/// Configuration passed to `VedikaChatViewController.init(config:)`.
///
/// There is no default source. Build the config with
/// `init(chatURL:...)` (hosted, recommended) or `init(pinnedBundle:...)`
/// (a copy shipped in the app, explicit opt-in), so an app can never end
/// up pinned by accident.
public struct VedikaChatConfig: Equatable, Sendable {

    /// Where the chat page comes from.
    public private(set) var source: VedikaChatSource

    /// Entry point inside a pinned bundle. Defaults to `index.html`.
    /// Ignored for a hosted page.
    public var entryPoint: String

    /// Required headers sent with the request for the chat page.
    public var requiredRequestHeaders: [String: String]

    /// Hosts the page may talk to the bridge from (`chat.example.com`, or
    /// `*.example.com` for subdomains). For a hosted page, empty means the
    /// page's own host; a non-empty list replaces that and must still
    /// include it. For a pinned copy, empty means no check, as before.
    public var allowedOrigins: [String]

    /// Whether `isInspectable` should be enabled. Defaults to `false`.
    /// Apple policy: never enable in production. Enable only in debug
    /// builds for Safari Web Inspector.
    public var inspectable: Bool

    /// Optional theme overrides (background, text, accent, font, free-form CSS).
    public var theme: VedikaChatTheme

    /// Text of the page shown when the hosted chat cannot be reached.
    /// Hosts localise it here.
    public var offlineText: VedikaChatOfflineText

    /// How long the hosted page may go without data before the offline
    /// page is shown instead, in seconds. Ignored for a pinned copy.
    public var loadTimeout: TimeInterval

    /// Hosted: load the chat page from `chatURL`. This is the default way
    /// to show the chat.
    ///
    /// - Throws: `VedikaChatConfigError.invalidChatURL` unless `chatURL`
    ///   is https with a host and no embedded credentials, and
    ///   `.allowedOriginsMissingChatHost` when `allowedOrigins` is set
    ///   but leaves out the page's own host.
    public init(
        chatURL: URL,
        requiredRequestHeaders: [String: String] = [:],
        allowedOrigins: [String] = [],
        inspectable: Bool = false,
        theme: VedikaChatTheme = VedikaChatTheme(),
        offlineText: VedikaChatOfflineText = VedikaChatOfflineText(),
        loadTimeout: TimeInterval = 30
    ) throws {
        guard VedikaChatHostedURL.isValid(chatURL),
              let host = VedikaChatHostedURL.normalisedHost(chatURL) else {
            throw VedikaChatConfigError.invalidChatURL
        }
        if !allowedOrigins.isEmpty,
           !VedikaChatHostedURL.hostMatches(host, rules: allowedOrigins) {
            throw VedikaChatConfigError.allowedOriginsMissingChatHost(host)
        }
        self.source = .hosted(chatURL)
        self.entryPoint = "index.html"
        self.requiredRequestHeaders = requiredRequestHeaders
        self.allowedOrigins = allowedOrigins
        self.inspectable = inspectable
        self.theme = theme
        self.offlineText = offlineText
        self.loadTimeout = max(loadTimeout, 1)
    }

    /// Pinned: load a copy of the chat page shipped inside the app. This
    /// is an explicit opt-in; the copy only changes when the app is
    /// released. Prefer `init(chatURL:)` unless the chat must open with no
    /// network at all.
    public init(
        pinnedBundle: VedikaChatBundleSource,
        entryPoint: String = "index.html",
        requiredRequestHeaders: [String: String] = [:],
        allowedOrigins: [String] = [],
        inspectable: Bool = false,
        theme: VedikaChatTheme = VedikaChatTheme()
    ) {
        self.source = .pinned(pinnedBundle)
        self.entryPoint = entryPoint
        self.requiredRequestHeaders = requiredRequestHeaders
        self.allowedOrigins = allowedOrigins
        self.inspectable = inspectable
        self.theme = theme
        self.offlineText = VedikaChatOfflineText()
        self.loadTimeout = 30
    }

    /// The hosts allowed to reach the bridge.
    public var effectiveAllowedOrigins: [String] {
        guard allowedOrigins.isEmpty else { return allowedOrigins }
        if case .hosted(let url) = source, let host = VedikaChatHostedURL.normalisedHost(url) {
            return [host]
        }
        return []
    }
}
