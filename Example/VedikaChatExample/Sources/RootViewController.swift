// Root view controller for the example.
//
// The chat page is hosted: the config names its https URL and the web view
// loads it, so a chat fix reaches this app without an app release. If the
// page cannot be reached the controller shows an offline page with a Retry
// link. `usePinnedCopy` flips the example to the explicit opt-in: a copy of
// the page shipped in `VedikaChat.bundle`, which only changes when this app
// is released.
//
// Shows a single button. Tapping the button presents the chat view
// controller with an in-memory token provider that logs only the
// request reason and thread id (never the token), and a custom theme
// that the chat picks up via the SDK's theme injection. The SDK
// forwards safe-area insets automatically on every layout pass.

import UIKit
import VedikaChat

final class RootViewController: UIViewController {

    /// The hosted chat page. Replace with the URL your Vedika contact gave you.
    private let chatURL = URL(string: "https://chat.example.com/chat.html")!

    /// Opt in to the copy of the page shipped in this app's bundle.
    private let usePinnedCopy = false

    private lazy var openChatButton: UIButton = {
        var config = UIButton.Configuration.borderedProminent()
        config.title = "Open chat"
        config.cornerStyle = .large
        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(openChat), for: .touchUpInside)
        return button
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.addSubview(openChatButton)
        NSLayoutConstraint.activate([
            openChatButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            openChatButton.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            openChatButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 200)
        ])
        title = "Vedika Chat — Example"
    }

    @objc private func openChat() {
        let provider: VedikaChatTokenProvider = { request in
            // The provider intentionally logs the request reason
            // and thread id, NOT the returned token. The bridge
            // never logs the token either.
            print("[example] acquireToken reason=\(request.reason) thread=\(request.threadId ?? "<nil>")")
            // Real host: call POST https://harness.vedika.io/api/v1/embed/tokens ...
            return VedikaChatToken(value: "tk_example_\(Int(Date().timeIntervalSince1970))", expiresAt: 0)
        }

        let theme = VedikaChatTheme(
            backgroundColor: "#101418",
            textColor: "#f6f7f8",
            accentColor: "#ff6a00",
            fontFamily: "Helvetica, sans-serif",
            customCss: ":root{--vedika-radius:14px;}"
        )

        let config: VedikaChatConfig
        do {
            if usePinnedCopy {
                config = VedikaChatConfig(
                    pinnedBundle: .bundledResource(name: "VedikaChat", extension: "bundle"),
                    theme: theme
                )
            } else {
                config = try VedikaChatConfig(chatURL: chatURL, theme: theme)
            }
        } catch {
            print("[example] bad chat config: \(error)")
            return
        }
        let chat = VedikaChatViewController(config: config, tokenProvider: provider)
        chat.onError = { error in
            print("[example] chat load failed: \(error)")
        }
        chat.modalPresentationStyle = .fullScreen
        present(UINavigationController(rootViewController: chat), animated: true)
    }
}