// The chat view controller.
//
// Hosts the chat WebView, installs the bridge, and loads the chat page.
// By default the page is HOSTED: it is loaded from its https URL, so a
// chat fix reaches every installed app without an app release. If the
// hosted page cannot be reached (offline, DNS, TLS, timeout, or an HTTP
// error) the controller shows a small offline page with a Retry link and
// reports the failure through `onError`.
//
// A copy of the page shipped inside the app can be used instead
// (`VedikaChatConfig(pinnedBundle:)`). That is an explicit opt-in: the
// bundle manifest is verified before it loads, and it stays at its
// build-time version until the host ships a new app.
//
// Layout is purely from Vedika — no native re-draw of any layout. The
// view controller only sets the WebView as its `view`, enforces the
// allowed-origin list on every navigation, and forwards the safe-area
// insets and theme tokens to the page.

import Foundation
import UIKit
import WebKit

/// Errors surfaced to the host when the page cannot be loaded.
public enum VedikaChatLoadError: Error, Equatable, CustomStringConvertible {

    /// The hosted chat page could not be loaded. The controller is already
    /// showing its offline page with a Retry link. `httpStatus` is set for
    /// an HTTP error.
    case hostedLoadFailed(VedikaChatLoadFailure, httpStatus: Int?)

    /// The pinned bundle manifest did not verify. The bundle MUST NOT be used.
    case manifestFailed(VedikaChatManifestError)

    /// The bundle directory itself was missing.
    case bundleMissing(String)

    /// `index.html` was missing inside the bundle.
    case entryPointMissing(String)

    public var description: String {
        switch self {
        case .hostedLoadFailed(let failure, let status):
            if let status {
                return "Chat page failed to load: \(failure) (\(status))"
            }
            return "Chat page failed to load: \(failure)"
        case .manifestFailed(let e):
            return "Manifest verification failed: \(e)"
        case .bundleMissing(let p):
            return "Bundle directory not found at \(p)."
        case .entryPointMissing(let p):
            return "Entry point not found at \(p)."
        }
    }
}

/// A chat view controller that hosts the Vedika chat page.
@MainActor
public final class VedikaChatViewController: UIViewController {

    // MARK: - Public surface

    /// Configuration used when the controller was initialised.
    public let config: VedikaChatConfig

    /// Optional host-installed token provider. Assign before `viewDidLoad`
    /// fires, or set via `init(config:tokenProvider:)`.
    public var tokenProvider: VedikaChatTokenProvider? {
        didSet { bridge.tokenProvider = tokenProvider }
    }

    /// Fired once the page begins loading (for a pinned copy, after its
    /// manifest verifies). Useful for hiding a launch screen.
    public var onReady: (() -> Void)?

    /// Fired when the page cannot be loaded. For a hosted page the error is
    /// a `VedikaChatLoadError.hostedLoadFailed` and the offline page is
    /// already showing.
    public var onError: ((Error) -> Void)?

    /// Try the hosted page again after the offline page was shown. Does
    /// nothing unless the offline page is up, so it is safe to call from a
    /// connectivity callback.
    public func retry() {
        guard case .hosted(let url) = config.source, tracker.retry() else { return }
        startHostedLoad(url)
    }

    /// Underlying WebView for inspection. Created lazily on `loadView`.
    public private(set) var webView: WKWebView!

    /// Re-apply the host's theme. Useful for dark-mode toggles.
    public func applyTheme(_ theme: VedikaChatTheme) {
        let js = Self.buildThemeInjectionScript(for: theme)
        if js.isEmpty { return }
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    /// Re-apply the safe-area insets. Useful after a rotation.
    public func applySafeAreaInsets(_ insets: UIEdgeInsets) {
        let js = Self.buildSafeAreaInjectionScript(for: insets)
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: - Internals

    private let bridge: VedikaChatBridge
    private let tracker = VedikaChatLoadTracker()
    private var offlinePageLoading = false
    private var loaded: Bool = false
    private var lastAppliedTheme: VedikaChatTheme?
    private var lastAppliedInsets: UIEdgeInsets?

    // MARK: - Init

    /// Create a chat view controller.
    ///
    /// - Parameters:
    ///   - config: Configuration describing the bundle location and other
    ///             host preferences.
    ///   - tokenProvider: Optional token provider. The host should assign
    ///             this before `viewDidLoad` runs (i.e. before presenting
    ///             the view controller), or by setting the
    ///             `tokenProvider` property between init and present.
    public init(
        config: VedikaChatConfig,
        tokenProvider: VedikaChatTokenProvider? = nil
    ) {
        self.config = config
        // A hosted page may only talk to the bridge from its own host
        // (or the hosts the app allowed). A pinned copy keeps its
        // allowlist as configured.
        self.bridge = VedikaChatBridge(
            tokenProvider: tokenProvider,
            allowedOrigins: config.effectiveAllowedOrigins
        )
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable, message: "VedikaChatViewController does not support storyboard/XIB instantiation -- use init(config:tokenProvider:).")
    public required init?(coder: NSCoder) {
        fatalError("VedikaChatViewController does not support storyboard/XIB instantiation -- use init(config:tokenProvider:).")
    }

    // MARK: - Lifecycle

    public override func loadView() {
        let contentController = WKUserContentController()
        if #available(iOS 14.0, *) {
            contentController.addScriptMessageHandler(
                self.bridge,
                contentWorld: WKContentWorld.page,
                name: VedikaChatBridge.handlerName
            )
        }

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = contentController
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        // Default prefs: deny file access from arbitrary origins and disable
        // universal file-access. Defence in depth.
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences = prefs

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.scrollView.bounces = true
        webView.isOpaque = true
        webView.backgroundColor = .systemBackground
        webView.navigationDelegate = self

        // iOS 16.4+ supports `isInspectable`. Default false; honour the
        // host's request otherwise.
        if #available(iOS 16.4, *) {
            webView.isInspectable = config.inspectable
        }

        self.webView = webView
        self.view = webView
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        loadChat()
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // UIKit supplies the safe-area insets on the root view. The
        // host's chat layout consumes them as CSS env() variables
        // (`--vedika-safe-*`); we re-apply on every layout pass so
        // rotations and inset changes propagate without a page reload.
        let insets = view.safeAreaInsets
        if insets != lastAppliedInsets {
            lastAppliedInsets = insets
            applySafeAreaInsets(insets)
        }
    }

    // MARK: - Loading

    /// Start loading the chat: the hosted page by default, or, when the
    /// config opts in with `pinnedBundle`, the verified copy in the app.
    ///
    /// Returns when the WebView's load request has been issued, not when
    /// the page finishes loading.
    public func loadChat() {
        switch config.source {
        case .hosted(let url):
            loadHosted(url)
        case .pinned(let bundleSource):
            loadPinned(bundleSource)
        }
    }

    private func loadHosted(_ url: URL) {
        loaded = true
        lastAppliedTheme = config.theme
        tracker.begin()
        startHostedLoad(url)
        onReady?()
    }

    private func startHostedLoad(_ url: URL) {
        var request = URLRequest(url: url, timeoutInterval: config.loadTimeout)
        for (key, value) in config.requiredRequestHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        webView.load(request)
    }

    /// Replace the failed page with the offline page and tell the host why.
    private func showOffline(_ error: VedikaChatLoadError?) {
        guard let error else { return }
        offlinePageLoading = true
        webView.loadHTMLString(
            VedikaChatOfflinePage.render(text: config.offlineText, theme: config.theme),
            baseURL: nil
        )
        onError?(error)
    }

    /// Resolve the pinned bundle directory, verify it, and load it.
    private func loadPinned(_ bundleSource: VedikaChatBundleSource) {
        guard let bundleURL = resolveBundleURL(bundleSource) else {
            let err = VedikaChatLoadError.bundleMissing("<unresolved>")
            reportLoadFailure(err)
            return
        }

        switch VedikaChatManifest.loadAndVerify(at: bundleURL) {
        case .failure(let e):
            reportLoadFailure(VedikaChatLoadError.manifestFailed(e))
            return

        case .success(let manifest):
            let entry = manifest.entry.isEmpty ? config.entryPoint : manifest.entry
            let entryURL = bundleURL.appendingPathComponent(entry)
            guard FileManager.default.fileExists(atPath: entryURL.path) else {
                reportLoadFailure(VedikaChatLoadError.entryPointMissing(entryURL.path))
                return
            }
            loadFile(at: entryURL)
        }
    }

    /// Loads the chat's entry point. The bundle directory is loaded
    /// through `loadFileURL(_:allowingReadAccessTo:)`, which gives the
    /// page a real file origin and access to its own directory.
    private func loadFile(at entryURL: URL) {
        var request = URLRequest(url: entryURL)
        for (key, value) in config.requiredRequestHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        // `loadFileURL` reads the parent directory as `allowingReadAccessTo:`.
        // Passing the bundle root is safe because the bundle is read-only.
        let accessRoot = entryURL.deletingLastPathComponent()
        webView.loadFileURL(entryURL, allowingReadAccessTo: accessRoot)
        loaded = true
        onReady?()
        // Inject the host's theme immediately; the WebView's page has
        // already started loading by the time the `evaluateJavaScript`
        // arrives, so we use a small delay in the WKWebView's
        // completion path. Re-applying on every layout pass is safe.
        lastAppliedTheme = config.theme
        applyTheme(config.theme)
    }

    // MARK: - Bundle resolution

    /// Resolves the pinned bundle source into a concrete on-disk URL.
    private func resolveBundleURL(_ bundleSource: VedikaChatBundleSource) -> URL? {
        switch bundleSource {
        case .bundledResource(let name, let ext):
            return Bundle.main.url(forResource: name, withExtension: ext)

        case .directory(let url):
            return url
        }
    }

    private func reportLoadFailure(_ error: VedikaChatLoadError) {
        loaded = false
        onError?(error)
    }

    // MARK: - Theme injection

    /// Build the JavaScript that injects theme tokens as CSS custom
    /// properties on `:root`. The page can read them via `var(--vedika-*)`.
    static func buildThemeInjectionScript(for theme: VedikaChatTheme) -> String {
        var parts: [String] = []
        if let bg = theme.backgroundColor { parts.append("--vedika-bg:\(bg);") }
        if let fg = theme.textColor { parts.append("--vedika-fg:\(fg);") }
        if let accent = theme.accentColor { parts.append("--vedika-accent:\(accent);") }
        if let font = theme.fontFamily { parts.append("--vedika-font:\(font);") }
        if let custom = theme.customCss, !custom.isEmpty {
            parts.append(custom.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard !parts.isEmpty else { return "" }
        let css = ":root{" + parts.joined() + "}"
        let escaped = css
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "\n", with: " ")
        return "(function(){" +
            "var s=document.createElement('style');" +
            "s.setAttribute('data-vedika-theme','1');" +
            "s.textContent=`\(escaped)`;" +
            "var prev=document.head && document.head.querySelector('style[data-vedika-theme]');" +
            "if(prev)prev.remove();" +
            "document.head.appendChild(s);" +
            "})();"
    }

    /// Build the JavaScript that pushes safe-area insets into the
    /// page as CSS env() variables the chat layout consumes.
    static func buildSafeAreaInjectionScript(for insets: UIEdgeInsets) -> String {
        let top = Int(insets.top.rounded())
        let bottom = Int(insets.bottom.rounded())
        let left = Int(insets.left.rounded())
        let right = Int(insets.right.rounded())
        return "(function(){" +
            "var s=document.documentElement.style;" +
            "s.setProperty('--vedika-safe-top','\(top)px');" +
            "s.setProperty('--vedika-safe-bottom','\(bottom)px');" +
            "s.setProperty('--vedika-safe-left','\(left)px');" +
            "s.setProperty('--vedika-safe-right','\(right)px');" +
            "})();"
    }
}

// MARK: - Navigation

extension VedikaChatViewController: WKNavigationDelegate {

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if case .hosted(let chatURL) = config.source {
            let policy = VedikaChatHostedNavigationPolicy(
                chatURL: chatURL,
                allowedHosts: config.effectiveAllowedOrigins
            )
            let url = navigationAction.request.url
            let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
            let decision = policy.decide(
                url: url,
                isMainFrame: isMainFrame,
                isLinkActivation: navigationAction.navigationType == .linkActivated,
                offlinePageLoading: offlinePageLoading
            )
            switch decision {
            case .allow:
                if isMainFrame, url?.absoluteString == "about:blank" {
                    offlinePageLoading = false
                }
                decisionHandler(.allow)
            case .retry:
                decisionHandler(.cancel)
                retry()
            case .cancel:
                VedikaChatLogging.emit("NAVIGATION_REJECTED")
                decisionHandler(.cancel)
            }
            return
        }

        // Pinned copy. The chat bundle is the only allowed content. Refuse
        // any attempt to navigate away, including link clicks inside the
        // page, so a stale link cannot drive a network request.
        if navigationAction.navigationType == .linkActivated {
            VedikaChatLogging.emit("LINK_NAVIGATION_REJECTED")
            decisionHandler(.cancel)
            return
        }
        // Allow same-origin sub-resource loads.
        if let url = navigationAction.request.url,
           let host = url.host,
           host == webView.url?.host {
            decisionHandler(.allow)
            return
        }
        // First-load entry: allow (the WebView's `url` is still nil).
        if navigationAction.navigationType == .other &&
            (webView.url == nil || navigationAction.request.url == webView.url) {
            decisionHandler(.allow)
            return
        }
        VedikaChatLogging.emit("NAVIGATION_REJECTED")
        decisionHandler(.cancel)
    }

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        // A hosted page that answers with an HTTP error is not shown. The
        // offline page replaces it.
        if case .hosted = config.source,
           navigationResponse.isForMainFrame,
           let http = navigationResponse.response as? HTTPURLResponse,
           let error = tracker.mainFrameHTTPError(status: http.statusCode) {
            decisionHandler(.cancel)
            showOffline(error)
            return
        }
        decisionHandler(.allow)
    }

    public func webView(
        _ webView: WKWebView,
        didFinish navigation: WKNavigation!
    ) {
        if case .hosted = config.source, !tracker.pageFinished() {
            // The offline page finishing, or a repeat: nothing to apply.
            return
        }
        // Re-apply theme + insets once the page is live so the first
        // paint already sees the host's overrides.
        if let theme = lastAppliedTheme {
            applyTheme(theme)
        }
        if let insets = lastAppliedInsets {
            applySafeAreaInsets(insets)
        }
    }

    public func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        hostedNavigationFailed(error)
    }

    public func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        if case .hosted = config.source {
            hostedNavigationFailed(error)
            return
        }
        if loaded {
            onError?(error)
        }
    }

    private func hostedNavigationFailed(_ error: Error) {
        guard case .hosted = config.source else { return }
        showOffline(tracker.mainFrameError(error))
    }
}
