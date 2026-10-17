// Tests for how a `VedikaChatConfig` picks its source and which hosts it
// lets through.
//
// The point of these tests: the chat page is HOSTED unless the host asks
// for a pinned copy by name, so a chat fix reaches installed apps without
// an app release.

import XCTest
@testable import VedikaChat

final class VedikaChatConfigTests: XCTestCase {

    private let chatURL = URL(string: "https://chat.example.com/embed/chat.html")!

    // MARK: - Hosted is the default

    func testAChatURLAloneIsHosted() throws {
        let config = try VedikaChatConfig(chatURL: chatURL)
        XCTAssertEqual(config.source, .hosted(chatURL))
    }

    func testAPinnedCopyNeedsAnExplicitOptIn() {
        let config = VedikaChatConfig(pinnedBundle: .default)
        XCTAssertEqual(config.source, .pinned(.default))
        // The conventional location is a name, not a choice: nothing is
        // pinned unless a config is built with `pinnedBundle:`.
        XCTAssertEqual(
            VedikaChatBundleSource.default,
            .bundledResource(name: "VedikaChat", extension: "bundle")
        )
    }

    // MARK: - The hosted URL

    func testTheHostedURLMustBeHTTPSWithAHostAndNoCredentials() {
        let rejected = [
            "http://chat.example.com/",
            "ftp://chat.example.com/",
            "file:///var/mobile/chat.html",
            "https://user:secret@chat.example.com/",
            "https://user@chat.example.com/",
            "javascript:alert(1)",
        ]
        for string in rejected {
            guard let url = URL(string: string) else { continue }
            XCTAssertThrowsError(try VedikaChatConfig(chatURL: url), string) { error in
                XCTAssertEqual(error as? VedikaChatConfigError, .invalidChatURL, string)
            }
        }
    }

    func testAnHTTPSURLWithAPortIsAccepted() throws {
        let url = URL(string: "https://chat.example.com:8443/x")!
        XCTAssertEqual(try VedikaChatConfig(chatURL: url).source, .hosted(url))
    }

    // MARK: - Which hosts reach the bridge

    func testTheBridgeHostFollowsTheHostedURL() throws {
        let config = try VedikaChatConfig(chatURL: URL(string: "HTTPS://Chat.Example.com:443/a?b=c#d")!)
        XCTAssertEqual(config.effectiveAllowedOrigins, ["chat.example.com"])
    }

    func testExplicitAllowedOriginsReplaceTheDefaultButMustKeepTheChatHost() throws {
        let kept = try VedikaChatConfig(chatURL: chatURL, allowedOrigins: ["chat.example.com", "*.example.org"])
        XCTAssertEqual(kept.effectiveAllowedOrigins, ["chat.example.com", "*.example.org"])

        // A wildcard that covers the chat host is enough.
        XCTAssertNoThrow(try VedikaChatConfig(chatURL: chatURL, allowedOrigins: ["*.example.com"]))

        // A list that left the chat page's own host out would lock the page
        // out of the bridge, so it is refused up front.
        XCTAssertThrowsError(try VedikaChatConfig(chatURL: chatURL, allowedOrigins: ["other.example.com"])) { error in
            XCTAssertEqual(
                error as? VedikaChatConfigError,
                .allowedOriginsMissingChatHost("chat.example.com")
            )
        }
    }

    func testAPinnedCopyKeepsItsAllowlistAsConfigured() {
        XCTAssertEqual(VedikaChatConfig(pinnedBundle: .default).effectiveAllowedOrigins, [])
        XCTAssertEqual(
            VedikaChatConfig(pinnedBundle: .default, allowedOrigins: ["example.com"]).effectiveAllowedOrigins,
            ["example.com"]
        )
    }

    func testHostRulesMatchExactlyOrBySubdomain() {
        let match = VedikaChatHostedURL.hostMatches
        XCTAssertTrue(match("chat.example.com", ["chat.example.com"]))
        XCTAssertTrue(match("Chat.Example.com", ["chat.example.com"]))
        XCTAssertTrue(match("chat.example.com", ["*.example.com"]))
        XCTAssertTrue(match("deep.chat.example.com", ["*.example.com"]))
        XCTAssertFalse(match("example.com", ["*.example.com"]))
        XCTAssertFalse(match("badexample.com", ["*.example.com"]))
        XCTAssertFalse(match("chat.example.com.evil.net", ["chat.example.com"]))
    }

    // MARK: - The rest of the config

    func testTheLoadTimeoutIsAtLeastOneSecond() throws {
        XCTAssertEqual(try VedikaChatConfig(chatURL: chatURL).loadTimeout, 30)
        XCTAssertEqual(try VedikaChatConfig(chatURL: chatURL, loadTimeout: 0).loadTimeout, 1)
    }

    // MARK: - What the WebView may navigate to

    private func policy() throws -> VedikaChatHostedNavigationPolicy {
        let config = try VedikaChatConfig(chatURL: chatURL)
        return VedikaChatHostedNavigationPolicy(chatURL: chatURL, allowedHosts: config.effectiveAllowedOrigins)
    }

    private func decide(
        _ policy: VedikaChatHostedNavigationPolicy,
        _ string: String?,
        mainFrame: Bool = true,
        link: Bool = false,
        offlineLoading: Bool = false
    ) -> VedikaChatNavigationDecision {
        policy.decide(
            url: string.flatMap { URL(string: $0) },
            isMainFrame: mainFrame,
            isLinkActivation: link,
            offlinePageLoading: offlineLoading
        )
    }

    func testAHostedPageMayNavigateOnlyWithinItsOwnOrigin() throws {
        let p = try policy()
        XCTAssertEqual(decide(p, "https://chat.example.com/embed/chat.html"), .allow)
        XCTAssertEqual(decide(p, "https://chat.example.com/embed/frame?x=1", mainFrame: false), .allow)
        XCTAssertEqual(decide(p, "https://evil.example.net/"), .cancel)
        XCTAssertEqual(decide(p, "https://chat.example.com.evil.net/"), .cancel)
        XCTAssertEqual(decide(p, "http://chat.example.com/embed/chat.html"), .cancel)
        XCTAssertEqual(decide(p, "https://chat.example.com:8443/"), .cancel)
        XCTAssertEqual(decide(p, "data:text/html,hi"), .cancel)
        XCTAssertEqual(decide(p, "file:///etc/hosts"), .cancel)
        XCTAssertEqual(decide(p, "javascript:alert(1)"), .cancel)
        XCTAssertEqual(decide(p, nil), .cancel)
    }

    func testAnExplicitPortIsPartOfTheOrigin() throws {
        let url = URL(string: "https://chat.example.com:8443/x")!
        let p = VedikaChatHostedNavigationPolicy(chatURL: url, allowedHosts: ["chat.example.com"])
        XCTAssertEqual(decide(p, "https://chat.example.com:8443/y"), .allow)
        XCTAssertEqual(decide(p, "https://chat.example.com/y"), .cancel)
        XCTAssertEqual(decide(p, "https://chat.example.com:9443/y"), .cancel)
        XCTAssertEqual(decide(p, "https://evil.example.net:8443/y"), .cancel)
    }

    func testHostsTheAppAllowedBesidesTheChatHostAreReachable() throws {
        let p = VedikaChatHostedNavigationPolicy(chatURL: chatURL, allowedHosts: ["chat.example.com", "*.example.org"])
        XCTAssertEqual(decide(p, "https://assets.example.org/x.js", mainFrame: false), .allow)
        XCTAssertEqual(decide(p, "http://assets.example.org/x.js", mainFrame: false), .cancel)
        XCTAssertEqual(decide(p, "https://example.org/x.js", mainFrame: false), .cancel)
    }

    func testALinkTheUserTapsNeverLeavesTheChat() throws {
        let p = try policy()
        XCTAssertEqual(decide(p, "https://evil.example.net/", link: true), .cancel)
        XCTAssertEqual(decide(p, "https://chat.example.com/other", link: true), .cancel)
    }

    func testTheOfflinePageLoadsAsABlankPageOnlyWhenWeAskedForIt() throws {
        let p = try policy()
        XCTAssertEqual(decide(p, "about:blank", offlineLoading: true), .allow)
        // A page that tries to navigate the main frame to a blank page on
        // its own is refused.
        XCTAssertEqual(decide(p, "about:blank", offlineLoading: false), .cancel)
        // Frames the chat page creates for itself are fine.
        XCTAssertEqual(decide(p, "about:blank", mainFrame: false), .allow)
        XCTAssertEqual(decide(p, "about:srcdoc", mainFrame: false), .allow)
        XCTAssertEqual(decide(p, "about:srcdoc", mainFrame: true), .cancel)
        XCTAssertEqual(decide(p, "about:config"), .cancel)
    }

    func testTheRetryLinkReloadsTheChatInsteadOfNavigating() throws {
        let p = try policy()
        XCTAssertEqual(decide(p, VedikaChatOfflinePage.retryURLString, link: true), .retry)
        XCTAssertEqual(decide(p, "vedika-chat-retry://now"), .retry)
        XCTAssertEqual(decide(p, "vedika-chat-retry-evil://now"), .cancel)
    }
}
