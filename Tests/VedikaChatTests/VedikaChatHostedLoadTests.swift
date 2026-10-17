// The offline fallback in a real WKWebView.
//
// The host name below ends in `.invalid`, which can never resolve, so the
// hosted page cannot load whether or not this machine is online. The test
// checks the whole path: the failure is reported, the offline page is
// drawn in the WebView, and its Retry link loads the hosted URL again.

import XCTest
import WebKit
@testable import VedikaChat

@MainActor
final class VedikaChatHostedLoadTests: XCTestCase {

    private func pageText(_ webView: WKWebView) async -> String {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript("document.body ? document.body.innerText : ''") { value, _ in
                continuation.resume(returning: (value as? String) ?? "")
            }
        }
    }

    private func waitForPageText(_ webView: WKWebView, containing needle: String, seconds: TimeInterval = 60) async -> String {
        let deadline = Date().addingTimeInterval(seconds)
        var text = ""
        while Date() < deadline {
            text = await pageText(webView)
            if text.contains(needle) { return text }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return text
    }

    func testAnUnreachableHostedPageShowsTheOfflinePageAndRetryLoadsItAgain() async throws {
        let config = try VedikaChatConfig(
            chatURL: URL(string: "https://chat.invalid/chat.html")!,
            offlineText: VedikaChatOfflineText(title: "No connection", message: "Try again soon.", retryLabel: "Try again"),
            loadTimeout: 15
        )
        let controller = VedikaChatViewController(config: config)

        var errors: [VedikaChatLoadError] = []
        let first = expectation(description: "the failure is reported")
        let second = expectation(description: "the failure is reported again after Retry")
        controller.onError = { error in
            guard let error = error as? VedikaChatLoadError else { return }
            errors.append(error)
            if errors.count == 1 { first.fulfill() }
            if errors.count == 2 { second.fulfill() }
        }
        var ready = 0
        controller.onReady = { ready += 1 }

        // A WKWebView that is not in a window never starts a load on recent
        // iOS versions, so give the controller a window, as an app would.
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        // viewDidLoad starts the hosted load.
        controller.loadViewIfNeeded()
        XCTAssertEqual(ready, 1)
        await fulfillment(of: [first], timeout: 150)

        guard case .hostedLoadFailed(let failure, let status)? = errors.first else {
            return XCTFail("expected a hosted load failure, got \(errors)")
        }
        XCTAssertTrue([.network, .timeout].contains(failure), "\(failure)")
        XCTAssertNil(status)

        // The offline page is what the user sees, in the host's words.
        let text = await waitForPageText(controller.webView, containing: "Try again soon.")
        XCTAssertTrue(text.contains("No connection"), text)
        XCTAssertTrue(text.contains("Try again soon."), text)

        // Tapping Retry loads the hosted URL again, which fails the same way.
        controller.webView.evaluateJavaScript("document.querySelector('a.retry').click()") { _, _ in }
        await fulfillment(of: [second], timeout: 150)
        XCTAssertEqual(errors.count, 2)
        let again = await waitForPageText(controller.webView, containing: "No connection")
        XCTAssertTrue(again.contains("No connection"), again)
    }
}
