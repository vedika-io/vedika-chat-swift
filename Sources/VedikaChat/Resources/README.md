# Chat bundle (pinned copy only)

The chat page is hosted by default and needs nothing from this directory.

This directory is where a host app that opts into a pinned copy of the chat
(`VedikaChatConfig(pinnedBundle:)`) drops the chat bundle provided by
Vedika. A pinned copy stays at the version it was built with until the host
ships a new app, so it does not get chat fixes on its own.

The SDK does not ship a chat bundle. The host application copies the
exported `VedikaChat.bundle` (containing `index.html`, `manifest.json`
and the rest of the chat assets) into its own application bundle at build
time, then constructs the config with
`VedikaChatConfig(pinnedBundle: .bundledResource(name: "VedikaChat", extension: "bundle"))`
(also available as `.default`).

If the host app installs its bundle under a different name or extension,
pass that `VedikaChatBundleSource` instead.
