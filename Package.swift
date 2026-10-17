// swift-tools-version:5.9
import PackageDescription

// Vedika chat iOS SDK — shows the Vedika chat in a WKWebView and bridges a
// short-lived token provider from the host app down to the page. The chat
// page is hosted by default, so chat fixes reach installed apps without an
// app release; a copy shipped inside the app is an explicit opt-in.
//
// Platform floor: `.iOS(.v15)` only. No macOS support — `WKScriptMessageHandlerWithReply`
// and the chat page both rely on UIKit-aware behaviour, and the chat is
// delivered on phones and tablets.
//
// Zero external dependencies. This package compiles with a stock Swift
// toolchain and no network fetch. The runtime brings up a `WKWebView`,
// loads the hosted chat page (or, when pinned, injects the chat bundle after
// verifying its manifest), and lets the host install a
// `VedikaChatTokenProvider` closure that is invoked on demand from the
// page via `WKScriptMessageHandlerWithReply`.
//
// Distribution: Swift Package Manager from
// https://github.com/vedika-io/vedika-chat-swift (tagged releases).
let package = Package(
    name: "VedikaChat",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(name: "VedikaChat", targets: ["VedikaChat"])
    ],
    targets: [
        .target(
            name: "VedikaChat",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "VedikaChatTests",
            dependencies: ["VedikaChat"]
        )
    ]
)
