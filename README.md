# VedikaChat for iOS

Public mirror of the Vedika chat Swift package, version 0.1.0.

## Install

Swift Package Manager, from this repository (iOS 15 or later):

```swift
.package(url: "https://github.com/vedika-io/vedika-chat-swift.git", from: "0.1.0")
```

Then add `.product(name: "VedikaChat", package: "vedika-chat-swift")` to your
target's dependencies. In Xcode: File > Add Package Dependencies, paste the URL
and choose "Up to Next Major Version" from 0.1.0. The package is not
distributed through CocoaPods or Carthage.

Vedika chat for iPhone, iPad and Mac Catalyst hosts.

This package is a thin Swift wrapper around `WKWebView` that loads the
Vedika chat page and bridges a short-lived token from the host app down
to the page through `WKScriptMessageHandlerWithReply`. The chat layout
is rendered by the page itself; this package does not draw a single
chat pixel.

## Hosted by default

The chat page is loaded from its https URL (`chatURL`). Chat fixes and
new features reach every installed app the next time the chat opens,
with no app release and no App Store review.

If the page cannot be reached (offline, DNS, TLS, a slow server, or an
HTTP error from the server) the controller shows a small offline page
with a **Retry** link, and calls `onError` with
`VedikaChatLoadError.hostedLoadFailed(_:httpStatus:)`, which names the
failure. Retry loads the hosted URL again. A host can also call
`chat.retry()` itself, for example when connectivity returns. Only
failures of the main page show the offline page; a failed sub-request
does not replace a working chat. The offline text is
`VedikaChatConfig.offlineText`, so a host can localise it. A request
that gets no data for `loadTimeout` seconds (default 30) counts as a
failure.

A copy of the page can instead be shipped inside the app with
`VedikaChatConfig(pinnedBundle:)`. That is an explicit opt-in: a pinned
copy stays at the version it was built with until you release a new
app, so it does not get chat fixes on its own. Choose it only when the
chat must open with no network at all. The pinned copy keeps its
manifest check (SHA-256 over every file).

It is the Swift counterpart of the Vedika chat Android library
(`vedika-chat-android`, Kotlin / WebView).

## What is here

| File | Purpose |
|---|---|
| `Package.swift` | Swift Package manifest. iOS 15 floor, zero dependencies. |
| `Sources/VedikaChat/VedikaChatConfig.swift` | Configuration: hosted URL (default) or pinned bundle (opt-in), allowed origins, required headers, theme, offline text. |
| `Sources/VedikaChat/VedikaChatHosted.swift` | Hosted URL validation and the navigation policy. |
| `Sources/VedikaChat/VedikaChatOffline.swift` | Load tracking and the offline page with its Retry link. |
| `Sources/VedikaChat/VedikaChatManifest.swift` | Manifest verifier. SHA-256 over every file in the chat bundle. |
| `Sources/VedikaChat/VedikaChatTokenProvider.swift` | Host-side token type and provider closure. |
| `Sources/VedikaChat/VedikaChatBridge.swift` | The native <-> page bridge (acquireToken). |
| `Sources/VedikaChat/VedikaChatBridgeLogger.swift` | Indirection for diagnostics. Token never enters the log path. |
| `Sources/VedikaChat/VedikaChatViewController.swift` | The chat view controller. |
| `Sources/VedikaChat/Resources/README.md` | Notes on bundle layout. |
| `Tests/VedikaChatTests/` | Config, offline fallback (including one in a real `WKWebView`), manifest and bridge tests. |
| `Example/VedikaChatExample/` | A runnable example app. |

## What is NOT here

- The chat page itself. It is hosted. For the pinned opt-in, Vedika
  provides a bundle as `VedikaChat.bundle` for the app to include;
  the example ships a placeholder so the build is self-contained.
- A native SSE / stream core. Per plan, the page streams itself.
- Native UIKit / SwiftUI chat components. The page owns the layout.
- Any reference to a provider or model name. Wire contract only.

## Usage

```swift
import VedikaChat

// 1. Configure the hosted chat page and the theme to apply. `chatURL`
//    must be https, with a host and no embedded credentials; the
//    initialiser throws otherwise. The page loads from the network on
//    every open, so it is always current.
let config = try VedikaChatConfig(
    chatURL: URL(string: "https://chat.your-site.com/chat.html")!,
    theme: VedikaChatTheme(
        backgroundColor: "#101418",
        textColor: "#f6f7f8",
        accentColor: "#ff6a00",
        fontFamily: "Helvetica, sans-serif",
        customCss: ":root{--vedika-radius:14px;}"
    )
)

// 2. Provide a token factory. A real host calls its backend's
//    `vt_` mint endpoint here and returns the short-lived token.
let provider: VedikaChatTokenProvider = { request in
    // POST https://harness.vedika.io/api/v1/embed/tokens ...
    return VedikaChatToken(value: "...", expiresAt: ...)
}

// 3. Create and present the view controller.
let chat = VedikaChatViewController(config: config, tokenProvider: provider)
// Called when the hosted page could not be reached; the controller is
// already showing its offline page with a Retry link.
chat.onError = { error in /* log it */ }
present(chat, animated: true)
```

To ship a pinned copy instead (explicit opt-in, see above), name it:

```swift
let config = VedikaChatConfig(
    pinnedBundle: .bundledResource(name: "VedikaChat", extension: "bundle")
)
```

There is no default source and no `VedikaChatConfig()`: a config is built
with `chatURL:` or `pinnedBundle:`, so an app can never end up pinned by
accident.

Upgrading from 0.1.0: `VedikaChatConfig(bundleSource: ...)` becomes
`VedikaChatConfig(pinnedBundle: ...)`, and the recommended config is now
`try VedikaChatConfig(chatURL: ...)`. `VedikaChatViewController.init(config:)`
no longer has a default config.

## Security

For a hosted page the bridge is locked to the host of `chatURL`.
`config.allowedOrigins` replaces that when set, and must still include
the chat host (the initialiser throws otherwise). The WebView navigates
only within the chat page's own origin (https, same host and port) plus
any other hosts the app allowed; a link, a redirect or a script
navigation to anywhere else is refused, and a link the user taps never
takes the WebView away from the chat. WebKit does not route sub-resource
loads (scripts, images, fetches) through the navigation delegate, so
the chat page's own content-security policy is what limits those. The
handler compares the message's origin host against the
allowlist using exact-host and wildcard (`*.example.com`) rules, only
for https pages (an http page on an allowed host is refused too), and
rejects messages from other origins with a typed `BAD_ORIGIN` reply.
The bridge never invokes the provider when the origin is rejected.
The bridge also never logs the token. The default logger is a no-op;
hosts that want diagnostics install a `VedikaChatBridgeLogger`.

## Safe areas and theming

The view controller reads `view.safeAreaInsets` on every layout pass
and forwards the values to the page as CSS variables
(`--vedika-safe-top`, `--vedika-safe-bottom`, `--vedika-safe-left`,
`--vedika-safe-right`). It also injects the host's theme tokens
(`--vedika-bg`, `--vedika-fg`, `--vedika-accent`, `--vedika-font`)
via `evaluateJavaScript` on first load and on every theme change.
Call `applyTheme(_:)` after a dark-mode toggle.

## Required Info.plist keys of the host app

- `NSAppTransportSecurity` exceptions are NOT needed. The hosted chat
  is https, and `chatURL` must be https.

## Build

```sh
xcodebuild build -project VedikaChat.xcodeproj -scheme VedikaChat \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
```

## Test

The package is iOS-only (UIKit and WebKit), so run the tests on an iOS
simulator:

```sh
xcodebuild test -project VedikaChat.xcodeproj -scheme VedikaChat \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO
```

`VedikaChat.xcodeproj` is generated from `project.yml`; run
`xcodegen generate` after adding a source or test file.

## Run the example

```sh
open Example/VedikaChatExample
```

Open the project in Xcode, select an iOS 15+ simulator, run, tap
"Open chat". Set `chatURL` in `RootViewController.swift` first.

## Wire contract

The bridge speaks a single JSON envelope:

```json
{ "kind": "acquireToken", "payload": { "acquireToken": { "reason": "init", "threadId": null } } }
```

The page posts this string to
`window.webkit.messageHandlers.vedika.postMessage(...)` and resolves a
Promise with the reply:

```json
{ "ok": true, "data": { "token": { "value": "tk_...", "expiresAt": 1900000000 } } }
```

Additional kinds may be added without breaking changes by appending a
new `case` to `VedikaChatBridgeMessage.BridgePayload` and dispatching on
the `kind` string.
