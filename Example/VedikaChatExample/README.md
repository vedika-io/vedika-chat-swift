# VedikaChatExample

A minimal iOS example app showing how a host application embeds the
Vedika chat.

The chat page is hosted. The example loads it from `chatURL` (see
`Sources/RootViewController.swift`; replace the placeholder with the URL
your Vedika contact gave you), so a chat fix reaches the app without an app
release. If the page cannot be reached the controller shows an offline page
with a Retry link and reports the failure through `onError`.

To use the example:

1. Set `chatURL` in `RootViewController.swift`.
2. In your real app, replace the in-memory token provider with one that
   calls your backend's `vt_` mint endpoint.
3. Open the example in Xcode, select an iOS 15+ simulator, and run.

To try the explicit opt-in, a copy of the page shipped in the app, set
`usePinnedCopy` to `true` and drop the exported `VedikaChat.bundle` into the
app's `Resources/` directory (the build system copies it into the app bundle
as `VedikaChat.bundle`). A pinned copy renders with no network, but it stays
at the version it was built with until you release a new app.
