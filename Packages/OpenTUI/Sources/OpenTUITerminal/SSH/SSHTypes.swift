import OpenTUICore
import Synchronization

// MARK: - Identity & Addressing

/// A client public key as surfaced by an SSH transport during authentication.
// parity: ssh/src/types.ts#PublicKey [status=implemented hash=c5bf3afe2a2c]
public struct SSHPublicKey: Equatable, Hashable, Sendable {
    public let algorithm: String
    public let blob: [UInt8]

    public init(algorithm: String, blob: [UInt8]) {
        self.algorithm = algorithm
        self.blob = blob
    }
}

/// Discriminated union on authentication method; only `.publicKey` carries
/// `fingerprint` and `publicKey`.
///
/// Security note: `username` is client-supplied. For `publickey`, key ownership is
/// verified but the name is not; authorize by `fingerprint` and pair names to keys
/// in `auth.publicKey.allow` if you need that binding.
// parity: ssh/src/types.ts#Identity [status=implemented hash=7f1112a9eaee]
public enum SSHIdentity: Equatable, Hashable, Sendable {
    case none(username: String)
    case password(username: String)
    case keyboardInteractive(username: String)
    case publicKey(username: String, fingerprint: String, publicKey: SSHPublicKey)

    public var method: SSHAuthMethod {
        switch self {
        case .none: return .none
        case .password: return .password
        case .keyboardInteractive: return .keyboardInteractive
        case .publicKey: return .publicKey
        }
    }

    public var username: String {
        switch self {
        case .none(let u), .password(let u), .keyboardInteractive(let u), .publicKey(let u, _, _):
            return u
        }
    }

    public var fingerprint: String? {
        if case .publicKey(_, let fp, _) = self { return fp }
        return nil
    }

    public var publicKey: SSHPublicKey? {
        if case .publicKey(_, _, let pk) = self { return pk }
        return nil
    }
}

/// Helper validating whether an `SSHIdentity` conforms to a given `SSHAuthConfig`
/// (Swift counterpart to upstream's TypeScript `IdentityFor<A>` type narrowing).
// parity: ssh/src/types.ts#IdentityFor [status=adapted hash=aadcef72c10e]
public enum SSHIdentityFor {
    public static func allows(_ identity: SSHIdentity, under config: SSHAuthConfig) -> Bool {
        switch config {
        case .open:
            if case .none = identity { return true }
            return false
        case .methods(let methods):
            switch identity {
            case .none:
                return false
            case .password:
                return methods.password != nil
            case .keyboardInteractive:
                return methods.keyboardInteractive != nil
            case .publicKey:
                return methods.publicKey != nil
            }
        }
    }
}

/// Client socket address for logging, rate limiting, and policy.
// parity: ssh/src/types.ts#RemoteAddress [status=implemented hash=249ed62121df]
public struct SSHRemoteAddress: Equatable, Hashable, Sendable {
    public let address: String
    public let port: Int?

    public init(address: String, port: Int? = nil) {
        self.address = address
        self.port = port
    }
}

// MARK: - Type-Safe Context Bag & Middleware Handoff

/// Marker protocol for type-safe keys stored in `SSHContextBag`.
public protocol SSHContextKey {
    associatedtype Value: Sendable
}

/// Thread-safe per-session context bag populated by middleware via `next(...)`
/// and read by downstream middleware and the session handler.
public final class SSHContextBag: @unchecked Sendable {
    private struct Storage: Sendable {
        var typed: [ObjectIdentifier: any Sendable] = [:]
        var named: [String: any Sendable] = [:]
    }

    private let storage = Mutex(Storage())

    public init() {}

    public subscript<K: SSHContextKey>(_ key: K.Type) -> K.Value? {
        get {
            storage.withLock { $0.typed[ObjectIdentifier(key)] as? K.Value }
        }
        set {
            storage.withLock { state in
                if let newValue {
                    state.typed[ObjectIdentifier(key)] = newValue
                } else {
                    _ = state.typed.removeValue(forKey: ObjectIdentifier(key))
                }
            }
        }
    }

    public subscript(_ name: String) -> (any Sendable)? {
        get {
            storage.withLock { $0.named[name] }
        }
        set {
            storage.withLock { state in
                if let newValue {
                    state.named[name] = newValue
                } else {
                    _ = state.named.removeValue(forKey: name)
                }
            }
        }
    }

    public func merge(_ values: [String: any Sendable]) {
        storage.withLock { state in
            for (k, v) in values {
                state.named[k] = v
            }
        }
    }

    public var namedKeys: [String] {
        storage.withLock { Array($0.named.keys).sorted() }
    }
}

/// Opaque token returned by `next()`. Middleware returns it to prove control
/// was handed onward.
// parity: ssh/src/types.ts#Handoff [status=implemented hash=44b6bfe3873b]
public struct SSHHandoff: Sendable, Equatable {
    internal init() {}
}

/// Hand off to the rest of the middleware chain. Call bare to continue, or pass
/// context entries to contribute state to downstream middleware and the handler.
/// Resolves when the session ends, making `defer` blocks natural teardown points.
// parity: ssh/src/types.ts#Next [status=implemented hash=86fb33f0cc96]
public struct SSHNext: Sendable {
    private let invoke: @Sendable ((SSHContextBag) -> Void) async throws -> SSHHandoff

    internal init(invoke: @escaping @Sendable ((SSHContextBag) -> Void) async throws -> SSHHandoff) {
        self.invoke = invoke
    }

    /// Continue downstream without modifying context.
    public func callAsFunction() async throws -> SSHHandoff {
        try await invoke { _ in }
    }

    /// Continue downstream after merging named context entries.
    public func callAsFunction(_ add: [String: any Sendable]) async throws -> SSHHandoff {
        try await invoke { bag in
            bag.merge(add)
        }
    }

    /// Continue downstream after setting a typed `SSHContextKey` value.
    public func callAsFunction<K: SSHContextKey>(_ key: K.Type, value: K.Value) async throws -> SSHHandoff {
        try await invoke { bag in
            bag[key] = value
        }
    }

    /// Continue downstream after applying arbitrary mutations to the context bag.
    public func callAsFunction(_ update: @escaping @Sendable (SSHContextBag) -> Void) async throws -> SSHHandoff {
        try await invoke(update)
    }
}

// MARK: - Attachable Renderer Seam (Wave 3B Conforms CliRenderer Here)

/// Configuration passed to an `SSHRendererFactory` when attaching a renderer
/// to an authorized SSH session.
public struct SSHRendererCreateOptions: Sendable {
    public let width: Int
    public let height: Int
    public let term: String
    public let hasPty: Bool
    public let environment: [String: String]
    public let backend: SSHTerminalBackend
    public let exitOnCtrlC: Bool
    public let targetFps: Int

    public init(
        width: Int,
        height: Int,
        term: String,
        hasPty: Bool,
        environment: [String: String],
        backend: SSHTerminalBackend,
        exitOnCtrlC: Bool = false,
        targetFps: Int = 30
    ) {
        self.width = width
        self.height = height
        self.term = term
        self.hasPty = hasPty
        self.environment = environment
        self.backend = backend
        self.exitOnCtrlC = exitOnCtrlC
        self.targetFps = targetFps
    }
}

/// Clean seam that `CliRenderer` (and test/headless renderers) conform to so
/// `OpenTUITerminal`'s SSH bridge can drive any renderer without depending on
/// higher-tier modules.
public protocol SSHAttachableRenderer: AnyObject, Sendable {
    var width: Int { get }
    var height: Int { get }
    /// Deliver raw UTF-8/escape input bytes received from the SSH client.
    func feedInput(_ bytes: [UInt8])
    /// Request a terminal dimension change from an SSH `window-change` event.
    func requestResize(cols: Int, rows: Int)
    /// Subscribe to accepted renderer resize events; returns an unsubscribe closure.
    @discardableResult
    func onResize(_ listener: @escaping @Sendable (Int, Int) -> Void) -> @Sendable () -> Void
    /// Subscribe to renderer destruction; returns an unsubscribe closure.
    @discardableResult
    func onDestroy(_ listener: @escaping @Sendable () -> Void) -> @Sendable () -> Void
    /// Destroy the renderer and release resources (idempotent).
    func destroy()
    /// Await completion (or failure) of renderer teardown & output restoration.
    func waitForClose() async throws
}

// MARK: - Session Protocols & Middleware / Handler Types

/// Fields every session exposes, whether held by a middleware or the handler.
// parity: ssh/src/types.ts#SessionCommon [status=implemented hash=68e6c1b81676]
public protocol SSHSessionCommon: AnyObject, Sendable {
    /// Who connected, and how.
    var identity: SSHIdentity { get }
    /// Terminal type reported by the client (e.g. `"xterm-256color"`).
    var term: String { get }
    /// Requested PTY width before attachment; accepted renderer width afterward.
    var cols: Int { get }
    /// Requested PTY height before attachment; accepted renderer height afterward.
    var rows: Int { get }
    /// Whether the client requested a PTY; false for bare shell channels.
    var hasPty: Bool { get }
    /// Client socket address for logging, rate limiting, and policy.
    var remoteAddress: SSHRemoteAddress { get }
    /// Subscribe to resize events; returns a disposer. No-op once closed.
    @discardableResult
    func onResize(_ callback: @escaping @Sendable (Int, Int) -> Void) -> @Sendable () -> Void
    /// Subscribe to logical session close; returns a disposer. Late subscribers
    /// registered after close are invoked once immediately.
    @discardableResult
    func onClose(_ callback: @escaping @Sendable () -> Void) -> @Sendable () -> Void
    /// Write raw bytes to the client terminal, bypassing frame diffing.
    /// No-op once closed. Throws `OutputPressureError` on temporary saturation
    /// or `SSHOutputCapacityError` if the write exceeds maximum capacity.
    /// Rejection accepts zero bytes and is never queued or replayed.
    func write(_ bytes: [UInt8]) throws
    /// UTF-8 string convenience overload for `write(_ bytes:)`.
    func write(_ string: String) throws
    /// Force-close this session (idempotent).
    func end()
}

/// The session shape middleware receives before renderer attachment.
// parity: ssh/src/types.ts#MiddlewareSession [status=implemented hash=59a85d3292bd]
public protocol SSHMiddlewareSession: SSHSessionCommon {
    /// Per-session context bag populated by upstream middleware.
    var context: SSHContextBag { get }
    /// Deny this session before the handler runs. Writes `reason` (with CRLF)
    /// when output admission succeeds, closes the session, and throws `DenyError`.
    func deny(_ reason: String?) throws -> Never
}

public extension SSHMiddlewareSession {
    func deny() throws -> Never {
        try deny(nil)
    }
}

/// A reusable middleware function.
// parity: ssh/src/types.ts#Middleware [status=implemented hash=833dcf87749e]
public typealias SSHMiddleware = @Sendable (any SSHMiddlewareSession, SSHNext) async throws -> SSHHandoff

/// The call signature `.use(...)` accepts.
// parity: ssh/src/types.ts#MiddlewareFunction [status=implemented hash=1065ea0ec582]
public typealias SSHMiddlewareFunction = @Sendable (any SSHMiddlewareSession, SSHNext) async throws -> SSHHandoff

/// The per-session app handler. Receives a `SSHSession` with the live renderer
/// and accumulated middleware context.
// parity: ssh/src/types.ts#SessionHandler [status=implemented hash=5fbc03b56747]
public typealias SSHSessionHandler = @Sendable (any SSHSession) async throws -> Void

/// The session shape the handler receives: common fields plus the attached
/// renderer, `TerminalBackend`, and accumulated context.
// parity: ssh/src/types.ts#Session [status=implemented hash=f291b8159fb2]
public protocol SSHSession: SSHSessionCommon {
    /// Per-session context bag populated by middleware.
    var context: SSHContextBag { get }
    /// Pre-wired renderer attached after middleware authorization.
    var renderer: any SSHAttachableRenderer { get }
    /// `TerminalBackend` adapter backed directly by this session's SSH channel.
    var terminalBackend: SSHTerminalBackend { get }
}

// MARK: - Auth Configuration Types

/// Question presented during `keyboard-interactive` authentication.
public struct SSHKeyboardQuestion: Equatable, Hashable, Sendable {
    public let prompt: String
    public let echo: Bool

    public init(prompt: String, echo: Bool) {
        self.prompt = prompt
        self.echo = echo
    }
}

/// Async keyboard-interactive prompt callback bridged onto the SSH transport.
// parity: ssh/src/types.ts#KeyboardPrompt [status=implemented hash=74e6363fad84]
public typealias SSHKeyboardPrompt = @Sendable ([SSHKeyboardQuestion]) async -> [String]

/// Static allowlist source for `SSHPublicKeyPolicy`.
public enum SSHAuthorizedKeysSource: Equatable, Sendable {
    /// Path to an OpenSSH `authorized_keys` file.
    case file(String)
    /// Inline array of OpenSSH public key lines.
    case keys([String])
}

/// Context passed to a dynamic `SSHPublicKeyPolicy.allow` predicate after
/// cryptographic signature verification succeeds.
public struct SSHPublicKeyAuthContext: Equatable, Sendable {
    public let username: String
    public let fingerprint: String
    public let publicKey: SSHPublicKey

    public init(username: String, fingerprint: String, publicKey: SSHPublicKey) {
        self.username = username
        self.fingerprint = fingerprint
        self.publicKey = publicKey
    }
}

/// Public-key admission policy. A key is admitted when it matches `authorizedKeys`,
/// when `allow` returns true, or both.
// parity: ssh/src/types.ts#PublicKeyPolicy [status=implemented hash=6107589102c6]
public struct SSHPublicKeyPolicy: Sendable {
    public var authorizedKeys: SSHAuthorizedKeysSource?
    public var allow: (@Sendable (SSHPublicKeyAuthContext) async throws -> Bool)?

    public init(
        authorizedKeys: SSHAuthorizedKeysSource? = nil,
        allow: (@Sendable (SSHPublicKeyAuthContext) async throws -> Bool)? = nil
    ) {
        self.authorizedKeys = authorizedKeys
        self.allow = allow
    }
}

/// Public-key authentication mode: accept/identify any key or enforce a policy.
public enum SSHPublicKeyAuthMode: Sendable {
    case any
    case policy(SSHPublicKeyPolicy)
}

/// Context passed to a password authentication predicate.
public struct SSHPasswordAuthContext: Equatable, Sendable {
    public let username: String
    public let password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }
}

/// Context passed to a keyboard-interactive authentication predicate.
public struct SSHKeyboardInteractiveAuthContext: Sendable {
    public let username: String
    public let prompt: SSHKeyboardPrompt

    public init(username: String, prompt: @escaping SSHKeyboardPrompt) {
        self.username = username
        self.prompt = prompt
    }
}

/// The credential methods a client can present.
// parity: ssh/src/types.ts#CredentialMethods [status=implemented hash=abad3ba943e8]
public struct SSHCredentialMethods: Sendable {
    public var publicKey: SSHPublicKeyAuthMode?
    public var password: (@Sendable (SSHPasswordAuthContext) async throws -> Bool)?
    public var keyboardInteractive: (@Sendable (SSHKeyboardInteractiveAuthContext) async throws -> Bool)?

    public init(
        publicKey: SSHPublicKeyAuthMode? = nil,
        password: (@Sendable (SSHPasswordAuthContext) async throws -> Bool)? = nil,
        keyboardInteractive: (@Sendable (SSHKeyboardInteractiveAuthContext) async throws -> Bool)? = nil
    ) {
        self.publicKey = publicKey
        self.password = password
        self.keyboardInteractive = keyboardInteractive
    }
}

/// Credentialed authentication configuration. An empty set is rejected at
/// startup with `ConfigError`; use `SSHAuthConfig.open` for deliberate no-auth.
// parity: ssh/src/types.ts#AuthMethods [status=implemented hash=e64eab9063b6]
public struct SSHAuthMethods: Sendable {
    public var publicKey: SSHPublicKeyAuthMode?
    public var password: (@Sendable (SSHPasswordAuthContext) async throws -> Bool)?
    public var keyboardInteractive: (@Sendable (SSHKeyboardInteractiveAuthContext) async throws -> Bool)?

    public init(
        publicKey: SSHPublicKeyAuthMode? = nil,
        password: (@Sendable (SSHPasswordAuthContext) async throws -> Bool)? = nil,
        keyboardInteractive: (@Sendable (SSHKeyboardInteractiveAuthContext) async throws -> Bool)? = nil
    ) {
        self.publicKey = publicKey
        self.password = password
        self.keyboardInteractive = keyboardInteractive
    }

    internal var asCredentialMethods: SSHCredentialMethods {
        SSHCredentialMethods(
            publicKey: publicKey,
            password: password,
            keyboardInteractive: keyboardInteractive
        )
    }
}

/// How clients authenticate: either `.open` (no auth) or `.methods(SSHAuthMethods)`.
// parity: ssh/src/types.ts#AuthConfig [status=implemented hash=4f3ec0675734]
public enum SSHAuthConfig: Sendable {
    case open
    case methods(SSHAuthMethods)
}

// MARK: - Server Configuration, Listen Info, Builder & Server Protocols

/// Host key source for `SSHServerConfig`.
public enum SSHHostKeyConfig: Equatable, Sendable {
    /// Persist/load a host key PEM at `path` (generates on first run).
    case path(String)
    /// Explicit PEM string(s).
    case pem([String])

    public static func pem(_ single: String) -> SSHHostKeyConfig {
        .pem([single])
    }
}

/// Duration configuration supporting raw milliseconds or unit-suffixed strings
/// such as `"10m"`, `"30s"`, `"500ms"`, `"1h"`.
public enum SSHDuration: Equatable, Sendable, ExpressibleByIntegerLiteral, ExpressibleByStringLiteral {
    case milliseconds(Int)
    case string(String)

    public init(integerLiteral value: Int) {
        self = .milliseconds(value)
    }

    public init(stringLiteral value: String) {
        self = .string(value)
    }
}

/// Resource limits for renderer-backed SSH shell sessions.
public struct SSHSessionLimitsConfig: Equatable, Sendable {
    /// Maximum live shell sessions on one SSH connection. Default 1.
    public var perConnection: Int?
    /// Maximum live shell sessions across this server. Default 100.
    public var global: Int?

    public init(perConnection: Int? = nil, global: Int? = nil) {
        self.perConnection = perConnection
        self.global = global
    }
}

/// Container for server resource limits.
public struct SSHLimitsConfig: Equatable, Sendable {
    public var session: SSHSessionLimitsConfig?

    public init(session: SSHSessionLimitsConfig? = nil) {
        self.session = session
    }
}

/// Static server configuration, excluding the middleware chain and handler.
// parity: ssh/src/types.ts#ServerConfig [status=implemented hash=c2015b615b9e]
public struct SSHServerConfig: Sendable {
    public var auth: SSHAuthConfig?
    public var hostKey: SSHHostKeyConfig?
    public var idleTimeout: SSHDuration?
    public var maxTimeout: SSHDuration?
    public var limits: SSHLimitsConfig?
    public var startupBanner: Bool
    public var onError: (@Sendable (any Error) throws -> Void)?
    public var createRenderer: SSHRendererFactory?
    public var keyFileStore: any SSHKeyFileStore
    public var signatureVerifier: (any SSHSignatureVerifier)?
    public var bannerSink: (@Sendable ([String]) -> Void)?
    public var warningSink: (@Sendable (String) -> Void)?

    public init(
        auth: SSHAuthConfig? = nil,
        hostKey: SSHHostKeyConfig? = nil,
        idleTimeout: SSHDuration? = nil,
        maxTimeout: SSHDuration? = nil,
        limits: SSHLimitsConfig? = nil,
        startupBanner: Bool = true,
        onError: (@Sendable (any Error) throws -> Void)? = nil,
        createRenderer: SSHRendererFactory? = nil,
        keyFileStore: any SSHKeyFileStore = DefaultSSHKeyFileStore(),
        signatureVerifier: (any SSHSignatureVerifier)? = nil,
        bannerSink: (@Sendable ([String]) -> Void)? = nil,
        warningSink: (@Sendable (String) -> Void)? = nil
    ) {
        self.auth = auth
        self.hostKey = hostKey
        self.idleTimeout = idleTimeout
        self.maxTimeout = maxTimeout
        self.limits = limits
        self.startupBanner = startupBanner
        self.onError = onError
        self.createRenderer = createRenderer
        self.keyFileStore = keyFileStore
        self.signatureVerifier = signatureVerifier
        self.bannerSink = bannerSink
        self.warningSink = warningSink
    }
}

/// What `listen()` resolves to — useful for tests and programmatic callers.
// parity: ssh/src/types.ts#ListenInfo [status=implemented hash=d8c766b75625]
public struct SSHListenInfo: Equatable, Hashable, Sendable {
    public let host: String
    public let port: Int
    /// SHA256 fingerprints for every configured host key, in configuration order.
    public let fingerprints: [String]

    public init(host: String, port: Int, fingerprints: [String]) {
        self.host = host
        self.port = port
        self.fingerprints = fingerprints
    }
}

/// Builder interface returned by `createSSHServer`. Each `.use(...)` appends a
/// middleware link; `.serve(_:)` / `.handle(_:)` seals the chain into a startable `SSHServer`.
// parity: ssh/src/types.ts#ServerBuilder [status=implemented hash=4a5470c56fe9]
public protocol SSHServerBuilderProtocol: Sendable {
    func use(_ middleware: @escaping SSHMiddlewareFunction) -> Self
    func serve(_ handler: @escaping SSHSessionHandler) throws -> SSHServer
    func handle(_ handler: @escaping SSHSessionHandler) throws -> SSHServer
}

/// Running or startable SSH server contract.
// parity: ssh/src/types.ts#Server [status=implemented hash=be5cc3685e32]
public protocol SSHServerProtocol: Sendable {
    func listen(port: Int, host: String) async throws -> SSHListenInfo
    func close() async
}

// MARK: - Pluggable SSH Transport Abstractions

/// A bidirectional SSH shell channel (abstracting ssh2's `ServerChannel`, NIO SSH,
/// libssh2, or `InMemorySSHChannel`).
public protocol SSHChannel: AnyObject, Sendable {
    /// Attempt to write bytes to the peer. Returns `true` if the channel is ready
    /// for more writes immediately, or `false` if backpressured until `onDrain`.
    @discardableResult
    func write(_ bytes: [UInt8]) -> Bool
    /// Pause incoming client data reads (stdin backpressure).
    func pause()
    /// Resume incoming client data reads.
    func resume()
    /// Send the shell exit status code to the peer.
    func exit(code: Int)
    /// Close the channel.
    func close()
    /// Register client data listener.
    func setDataHandler(_ handler: (@Sendable ([UInt8]) -> Void)?)
    /// Register output drain listener.
    func setDrainHandler(_ handler: (@Sendable () -> Void)?)
    /// Register channel close listener.
    func setCloseHandler(_ handler: (@Sendable () -> Void)?)
    /// Register channel error listener.
    func setErrorHandler(_ handler: (@Sendable (any Error) -> Void)?)
}

/// Client `pty-req` payload.
public struct SSHPtyRequest: Equatable, Sendable {
    public let term: String
    public let cols: Double
    public let rows: Double

    public init(term: String, cols: Double, rows: Double) {
        self.term = term
        self.cols = cols
        self.rows = rows
    }

    public init(term: String, cols: Int, rows: Int) {
        self.term = term
        self.cols = Double(cols)
        self.rows = Double(rows)
    }
}

/// Client `window-change` payload.
public struct SSHWindowChangeRequest: Equatable, Sendable {
    public let cols: Double
    public let rows: Double

    public init(cols: Double, rows: Double) {
        self.cols = cols
        self.rows = rows
    }

    public init(cols: Int, rows: Int) {
        self.cols = Double(cols)
        self.rows = Double(rows)
    }
}

/// Client `env` request payload.
public struct SSHEnvRequest: Equatable, Sendable {
    public let key: String
    public let value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

/// A single multiplexed SSH session channel before and after `shell` acceptance.
public protocol SSHSessionChannel: AnyObject, Sendable {
    func setEnvHandler(_ handler: (@Sendable (SSHEnvRequest) -> Bool)?)
    func setPtyHandler(_ handler: (@Sendable (SSHPtyRequest) -> Bool)?)
    func setWindowChangeHandler(_ handler: (@Sendable (SSHWindowChangeRequest) -> Void)?)
    func setSignalHandler(_ handler: (@Sendable (String) -> Void)?)
    func setShellHandler(_ handler: (@Sendable () -> (any SSHChannel)?)?)
    func setCloseHandler(_ handler: (@Sendable () -> Void)?)
}

/// A single connected SSH client transport before and after authentication.
public protocol SSHClientConnection: AnyObject, Sendable {
    var remoteAddress: SSHRemoteAddress { get }
    func setNoDelay(_ enabled: Bool) throws
    func setAuthenticationHandler(
        _ handler: (@Sendable (SSHRawAuthContext) async -> Void)?
    )
    func setReadyHandler(_ handler: (@Sendable () -> Void)?)
    func setSessionHandler(_ handler: (@Sendable (any SSHSessionChannel) -> Void)?)
    func setCloseHandler(_ handler: (@Sendable () -> Void)?)
    func setErrorHandler(_ handler: (@Sendable (any Error) -> Void)?)
    func end()
    func forceClose()
}

/// Pluggable transport driver powering `SSHServer` (e.g. `InMemorySSHTransportDriver`,
/// SwiftNIO SSH, or libssh2).
public protocol SSHTransportDriver: AnyObject, Sendable {
    /// Start listening on `host:port` with the resolved `hostKeys`, invoking
    /// `onConnection` for each incoming client and `onError` for server-level errors.
    func listen(
        port: Int,
        host: String,
        hostKeys: [String],
        onConnection: @escaping @Sendable (any SSHClientConnection) -> Void,
        onError: @escaping @Sendable (any Error) -> Void
    ) async throws -> (host: String, port: Int)

    /// Stop listening and release transport resources.
    func close() async
}
