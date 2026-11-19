/// The package's error vocabulary: `SshError` for failures and `DenyError`
/// for intentional session denial.

/// Common protocol implemented by structured errors in `@opentui/ssh`.
public protocol SSHErrorProtocol: Error, Sendable, CustomStringConvertible {
    /// Stable, machine-branchable error category — e.g. `"CONFIG"`, `"OUTPUT_PRESSURE"`.
    var code: String { get }
    /// Error type name matching upstream class names (e.g. `"ConfigError"`).
    var name: String { get }
    /// Formatted developer-facing message.
    var message: String { get }
}

/// Base for every failure this package throws. Carries a stable `code` so a
/// caller can branch without string-matching the message; `name` identifies
/// the concrete category (e.g. `"ConfigError"`).
// parity: ssh/src/errors.ts#SshError [status=implemented hash=99cdbeb57ab1]
public struct SshError: SSHErrorProtocol, Equatable, Hashable, Sendable {
    public let code: String
    public let name: String
    public let message: String

    public init(code: String, message: String, name: String = "SshError") {
        // Prefix with the package name: these are dev-facing (startup/`onError`),
        // never shown to a client, so the prefix leaks nothing. `DenyError` is the
        // exception — its message is the client-facing deny reason, so it stays plain.
        self.code = code
        self.name = name
        self.message = "@opentui/ssh: \(message)"
    }

    public var description: String {
        message
    }
}

/// A misconfiguration the developer must fix before the server can run (empty
/// credentials, an unparseable host key, a malformed `idleTimeout`). Thrown at
/// startup, never per-connection.
// parity: ssh/src/errors.ts#ConfigError [status=implemented hash=1128d56e9f2c]
public struct ConfigError: SSHErrorProtocol, Equatable, Hashable, Sendable {
    public let code: String = "CONFIG"
    public let name: String = "ConfigError"
    public let message: String

    public init(_ message: String) {
        self.message = "@opentui/ssh: \(message)"
    }

    public var asSshError: SshError {
        SshError(code: code, message: String(message.dropFirst("@opentui/ssh: ".count)), name: name)
    }

    public var description: String {
        message
    }
}

/// The native output budget is temporarily full; this write accepted no bytes.
// parity: ssh/src/errors.ts#OutputPressureError [status=implemented hash=e04f2fc398f2]
public struct OutputPressureError: SSHErrorProtocol, Equatable, Hashable, Sendable {
    public let code: String = "OUTPUT_PRESSURE"
    public let name: String = "OutputPressureError"
    public let message: String = "@opentui/ssh: native session output is full; no bytes were accepted"

    public init() {}

    public var asSshError: SshError {
        SshError(code: code, message: "native session output is full; no bytes were accepted", name: name)
    }

    public var description: String {
        message
    }
}

/// Thrown when a single atomic write or deny reason exceeds the maximum
/// output buffer capacity (`RangeError` in upstream TypeScript).
public struct SSHOutputCapacityError: SSHErrorProtocol, Equatable, Hashable, Sendable {
    public let code: String = "RANGE"
    public let name: String = "RangeError"
    public let message: String

    public init(_ message: String = "raw write exceeds the native session output limit") {
        self.message = "@opentui/ssh: \(message)"
    }

    public var description: String {
        message
    }
}

/// The control-flow signal a middleware's `session.deny()` throws to unwind the
/// chain — not a failure. `runSession` swallows it; anything that is not a
/// `DenyError` routes to `onError`.
// parity: ssh/src/errors.ts#DenyError [status=implemented hash=6c62a0f5beb4]
public struct DenyError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
    public let name: String = "DenyError"
    /// The reason passed to `deny()`, if any; output failure can prevent delivery.
    public let reason: String?
    public let message: String

    public init(_ reason: String? = nil) {
        self.reason = reason
        self.message = reason ?? "session denied"
    }

    public var description: String {
        message
    }
}

/// True for the deny control-flow signal — the one throw `runSession` swallows.
// parity: ssh/src/errors.ts#isDeny [status=implemented hash=7c106bc982d5]
public func isDeny(_ error: any Error) -> Bool {
    error is DenyError
}

/// Overload checking an existential `Any` value for `DenyError`.
public func isDeny(_ value: Any) -> Bool {
    value is DenyError
}
