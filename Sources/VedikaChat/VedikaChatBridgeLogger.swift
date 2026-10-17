// Indirection between the chat WebView wrapper and the host's logging.
//
// The chat bridge never logs the token. To prove that in a test we route
// every diagnostic message through a `VedikaChatBridgeLogger` and capture
// them in the test; the production default is a no-op so the SDK ships
// with zero logging side effects.
//
// A host that wants logs wires its own logger with
// `VedikaChatBridgeLogger.install(_:)`.
//
// The logger MUST NOT receive the token, the request envelope, or any
// field derived from it. The bridge trims messages to fixed strings
// (event codes, origin host only) so even a misconfigured logger cannot
// leak the secret.

import Foundation

/// Diagnostic sink for the chat bridge. Default implementation is a
/// no-op so the SDK has zero logging side effects.
///
/// Hosts that want diagnostics implement this and install it with
/// ``VedikaChatBridgeLogger/install(_:)``.
public struct VedikaChatBridgeLogger: @unchecked Sendable {
    public typealias Emit = (String) -> Void

    private let emit: Emit

    public init(emit: @escaping Emit) {
        self.emit = emit
    }

    /// The default no-op logger.
    public static let silent = VedikaChatBridgeLogger(emit: { _ in })

    /// Emit a fixed event code. The event code MUST NOT include the
    /// token value, the request payload, or the reply body.
    internal func emit(_ event: String) {
        emit(event)
    }
}

/// Shared logger. Hosts install their own logger once per process; the
/// SDK ships with a silent default so there is no logging side effect
/// unless the host explicitly opts in.
public enum VedikaChatLogging {

    private static let lock = NSLock()
    private static var stored: VedikaChatBridgeLogger = .silent

    /// Install a custom logger. Pass ``VedikaChatBridgeLogger/silent``
    /// to silence the bridge.
    public static func install(_ logger: VedikaChatBridgeLogger) {
        lock.lock()
        stored = logger
        lock.unlock()
    }

    /// Internal: emit a fixed event code.
    internal static func emit(_ event: String) {
        // Snapshot under lock so a concurrent `install` cannot swap
        // the logger out mid-emit.
        let snapshot: VedikaChatBridgeLogger
        lock.lock()
        snapshot = stored
        lock.unlock()
        snapshot.emit(event)
    }

    /// Test-only accessor.
    internal static func peek() -> VedikaChatBridgeLogger {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}