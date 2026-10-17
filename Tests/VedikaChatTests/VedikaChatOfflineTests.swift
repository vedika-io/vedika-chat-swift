// Tests for the offline fallback: when it appears, what it says, and
// that its Retry link reloads the hosted chat URL.

import XCTest
@testable import VedikaChat

final class VedikaChatOfflineTests: XCTestCase {

    private func tracker() -> VedikaChatLoadTracker {
        let t = VedikaChatLoadTracker()
        t.begin()
        return t
    }

    private func nsError(_ domain: String, _ code: Int) -> NSError {
        NSError(domain: domain, code: code)
    }

    // MARK: - The fallback appears on a main-page failure

    func testAPageThatFinishesIsReadyAndNeverOffline() {
        let t = tracker()
        XCTAssertEqual(t.state, .loading)
        XCTAssertTrue(t.pageFinished())
        XCTAssertEqual(t.state, .ready)
    }

    func testANetworkFailureShowsTheFallback() {
        let t = tracker()
        let error = t.mainFrameError(nsError(NSURLErrorDomain, NSURLErrorNotConnectedToInternet))
        XCTAssertEqual(error, .hostedLoadFailed(.network, httpStatus: nil))
        XCTAssertEqual(t.state, .offline)
    }

    func testEveryKindOfFailureIsNamed() {
        let url = NSURLErrorDomain
        let cases: [(Int, VedikaChatLoadFailure)] = [
            (NSURLErrorNotConnectedToInternet, .network),
            (NSURLErrorCannotFindHost, .network),
            (NSURLErrorCannotConnectToHost, .network),
            (NSURLErrorNetworkConnectionLost, .network),
            (NSURLErrorDNSLookupFailed, .network),
            (NSURLErrorTimedOut, .timeout),
            (NSURLErrorSecureConnectionFailed, .secureConnection),
            (NSURLErrorServerCertificateUntrusted, .secureConnection),
            (NSURLErrorServerCertificateHasBadDate, .secureConnection),
            (NSURLErrorBadServerResponse, .other),
        ]
        for (code, expected) in cases {
            XCTAssertEqual(VedikaChatLoadTracker.classify(domain: url, code: code), expected, "\(code)")
        }
        XCTAssertEqual(VedikaChatLoadTracker.classify(domain: "SomeOtherDomain", code: 1), .other)
    }

    func testACancelledNavigationIsNotAFailure() {
        // We cancel navigations on purpose (a tapped link, a refused host,
        // an HTTP error page). WebKit reports them as failures.
        XCTAssertNil(VedikaChatLoadTracker.classify(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
        XCTAssertNil(VedikaChatLoadTracker.classify(domain: "WebKitErrorDomain", code: 102))

        let t = tracker()
        XCTAssertNil(t.mainFrameError(nsError(NSURLErrorDomain, NSURLErrorCancelled)))
        XCTAssertEqual(t.state, .loading)
    }

    func testAnHTTPErrorOnTheMainPageShowsTheFallback() {
        for status in [400, 401, 403, 404, 429, 500, 502, 503, 504] {
            let t = tracker()
            XCTAssertEqual(
                t.mainFrameHTTPError(status: status),
                .hostedLoadFailed(.httpError, httpStatus: status),
                "\(status)"
            )
            XCTAssertEqual(t.state, .offline, "\(status)")
        }
    }

    func testASuccessOrRedirectStatusIsNotAFailure() {
        for status in [200, 204, 301, 304, 399] {
            let t = tracker()
            XCTAssertNil(t.mainFrameHTTPError(status: status), "\(status)")
            XCTAssertEqual(t.state, .loading, "\(status)")
        }
    }

    func testAFailureIsReportedOnceEvenIfWebKitReportsItTwice() {
        let t = tracker()
        XCTAssertNotNil(t.mainFrameError(nsError(NSURLErrorDomain, NSURLErrorCannotFindHost)))
        XCTAssertNil(t.mainFrameHTTPError(status: 503))
        XCTAssertNil(t.mainFrameError(nsError(NSURLErrorDomain, NSURLErrorCannotFindHost)))
    }

    func testTheFallbackFinishingDoesNotTurnItIntoReady() {
        let t = tracker()
        _ = t.mainFrameError(nsError(NSURLErrorDomain, NSURLErrorCannotFindHost))
        // WebKit reports a finished load for the fallback page we draw.
        XCTAssertFalse(t.pageFinished())
        XCTAssertFalse(t.pageFinished())
        XCTAssertEqual(t.state, .offline)
    }

    func testAPageThatWasNeverRequestedIsNotReady() {
        let t = VedikaChatLoadTracker()
        XCTAssertEqual(t.state, .idle)
        XCTAssertFalse(t.pageFinished())
    }

    // MARK: - Retry reloads the hosted URL

    func testRetryFromTheFallbackStartsAnotherLoad() {
        let t = tracker()
        _ = t.mainFrameError(nsError(NSURLErrorDomain, NSURLErrorNotConnectedToInternet))
        XCTAssertTrue(t.retry())
        XCTAssertEqual(t.state, .loading)
        XCTAssertTrue(t.pageFinished())
        XCTAssertEqual(t.state, .ready)
    }

    func testRetryDoesNothingWhileTheChatIsLoadingOrWorking() {
        let loading = tracker()
        XCTAssertFalse(loading.retry())
        let ready = tracker()
        _ = ready.pageFinished()
        XCTAssertFalse(ready.retry())
        XCTAssertEqual(ready.state, .ready)
    }

    func testASecondFailureAfterRetryShowsTheFallbackAgain() {
        let t = tracker()
        _ = t.mainFrameError(nsError(NSURLErrorDomain, NSURLErrorCannotFindHost))
        XCTAssertTrue(t.retry())
        XCTAssertNotNil(t.mainFrameError(nsError(NSURLErrorDomain, NSURLErrorCannotFindHost)))
        XCTAssertEqual(t.state, .offline)
        XCTAssertTrue(t.retry())
    }

    func testTheLoadErrorNamesTheFailureWithoutAnyURL() {
        XCTAssertEqual(
            VedikaChatLoadError.hostedLoadFailed(.httpError, httpStatus: 503).description,
            "Chat page failed to load: httpError (503)"
        )
        XCTAssertEqual(
            VedikaChatLoadError.hostedLoadFailed(.network, httpStatus: nil).description,
            "Chat page failed to load: network"
        )
    }

    // MARK: - The page itself

    func testTheFallbackShowsTheTextAndALinkToRetry() {
        let html = VedikaChatOfflinePage.render(text: VedikaChatOfflineText(), theme: VedikaChatTheme())
        XCTAssertTrue(html.contains("You&#39;re offline"))
        XCTAssertTrue(html.contains("Check your connection"))
        XCTAssertTrue(html.contains(">Retry</a>"))
        XCTAssertTrue(html.contains("href=\"\(VedikaChatOfflinePage.retryURLString)\""))
    }

    func testTheFallbackRunsNoScriptAndLoadsNothing() {
        let html = VedikaChatOfflinePage.render(text: VedikaChatOfflineText(), theme: VedikaChatTheme())
        XCTAssertFalse(html.lowercased().contains("<script"))
        XCTAssertFalse(html.contains("http://"))
        XCTAssertFalse(html.contains("https://"))
        XCTAssertTrue(html.contains("default-src 'none'"))
    }

    func testHostsCanLocaliseTheTextAndItIsEscaped() {
        let html = VedikaChatOfflinePage.render(
            text: VedikaChatOfflineText(
                title: "Sin conexion <b>",
                message: "Revisa tu conexion & vuelve a intentarlo \"ahora\"",
                retryLabel: "Reintentar"
            ),
            theme: VedikaChatTheme()
        )
        XCTAssertTrue(html.contains("Sin conexion &lt;b&gt;"))
        XCTAssertTrue(html.contains("&amp; vuelve a intentarlo &quot;ahora&quot;"))
        XCTAssertTrue(html.contains(">Reintentar</a>"))
        XCTAssertFalse(html.contains("<b>"))
    }

    func testTheFallbackUsesTheHostThemeAndNothingThatIsNotAColour() {
        let themed = VedikaChatOfflinePage.render(
            text: VedikaChatOfflineText(),
            theme: VedikaChatTheme(backgroundColor: "#101418", textColor: "#F6F7F8", accentColor: "#FF6A00")
        )
        XCTAssertTrue(themed.contains("background:#101418"))
        XCTAssertTrue(themed.contains("color:#F6F7F8"))
        XCTAssertTrue(themed.contains("background:#FF6A00"))

        // The value goes into CSS, so anything but a hex colour is dropped.
        let hostile = VedikaChatOfflinePage.render(
            text: VedikaChatOfflineText(),
            theme: VedikaChatTheme(backgroundColor: "red;} body{display:none", textColor: "url(x)", accentColor: "#12")
        )
        XCTAssertFalse(hostile.contains("display:none"))
        XCTAssertFalse(hostile.contains("url(x)"))
        XCTAssertTrue(hostile.contains("background:#FFFFFF"))
        XCTAssertTrue(hostile.contains("color:#1B1F23"))
    }

    func testTheRetryURLIsRecognisedAndNothingElseIs() {
        XCTAssertTrue(VedikaChatOfflinePage.isRetryURL(URL(string: VedikaChatOfflinePage.retryURLString)))
        XCTAssertFalse(VedikaChatOfflinePage.isRetryURL(URL(string: "https://chat.example.com/vedika-chat-retry:")))
        XCTAssertFalse(VedikaChatOfflinePage.isRetryURL(nil))
    }
}
