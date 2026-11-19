/// SSH authentication decision core, context adaptation, and config resolution.

/// Internal normalized policy the `SSHAuthenticator` decides over.
/// `.open` is normalized to `none = true`; an `SSHAuthMethods` set passes through.
// parity: ssh/src/auth.ts#NormalizedAuthConfig [status=implemented hash=7f30c2be55c1]
public struct SSHNormalizedAuthConfig: Sendable {
    public var publicKey: SSHPublicKeyAuthMode?
    public var password: (@Sendable (SSHPasswordAuthContext) async throws -> Bool)?
    public var keyboardInteractive: (@Sendable (SSHKeyboardInteractiveAuthContext) async throws -> Bool)?
    /// Set by normalization when `auth` is `.open`.
    public var none: Bool

    public init(
        publicKey: SSHPublicKeyAuthMode? = nil,
        password: (@Sendable (SSHPasswordAuthContext) async throws -> Bool)? = nil,
        keyboardInteractive: (@Sendable (SSHKeyboardInteractiveAuthContext) async throws -> Bool)? = nil,
        none: Bool = false
    ) {
        self.publicKey = publicKey
        self.password = password
        self.keyboardInteractive = keyboardInteractive
        self.none = none
    }
}

/// The SSH auth methods this package understands.
// parity: ssh/src/auth.ts#AuthMethod [status=implemented hash=c9e8c06b72c4]
public enum SSHAuthMethod: String, Equatable, Hashable, Sendable, CaseIterable {
    case none = "none"
    case password = "password"
    case publicKey = "publickey"
    case keyboardInteractive = "keyboard-interactive"
}

/// A single auth attempt, narrowed to the fields a decision needs so the auth
/// core stays testable without a live SSH handshake.
// parity: ssh/src/auth.ts#AuthAttempt [status=implemented hash=185757981184]
public enum SSHAuthAttempt: Sendable {
    case none(username: String)
    case password(username: String, password: String)
    case keyboardInteractive(username: String, prompt: SSHKeyboardPrompt)
    case publicKey(
        username: String,
        key: SSHPublicKey,
        /// Present only on the signed (second) pass; absent on the probe.
        signature: [UInt8]? = nil,
        /// The signed data; present alongside `signature`.
        blob: [UInt8]? = nil,
        hashAlgo: String? = nil
    )

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
        case .none(let u), .password(let u, _), .keyboardInteractive(let u, _), .publicKey(let u, _, _, _, _):
            return u
        }
    }
}

/// The verdict for one attempt. `.acceptProbe` is the publickey query reply
/// (`PK_OK`): the key is acceptable, so the client should sign — no identity yet.
/// Only a verified attempt yields `.accept(identity:)`.
// parity: ssh/src/auth.ts#AuthOutcome [status=implemented hash=4eacb2bf4ad0]
public enum SSHAuthOutcome: Equatable, Sendable {
    case accept(identity: SSHIdentity)
    case acceptProbe
    case reject(methods: [SSHAuthMethod])
}

/// Raw transport authentication context surfaced by an `SSHClientConnection`.
/// Mirrors ssh2's `AuthContext` so `attemptFromAuthContext` remains a pure,
/// read-only mapping.
public struct SSHRawAuthContext: Sendable {
    public let method: String
    public let username: String
    public let password: String?
    public let prompt: (@Sendable ([SSHKeyboardQuestion], @escaping @Sendable ([String]?) -> Void) -> Void)?
    public let keyAlgorithm: String?
    public let keyData: [UInt8]?
    public let signature: [UInt8]?
    public let blob: [UInt8]?
    public let hashAlgo: String?
    private let acceptAction: @Sendable () -> Void
    private let rejectAction: @Sendable ([SSHAuthMethod]) -> Void

    public init(
        method: String,
        username: String,
        password: String? = nil,
        prompt: (@Sendable ([SSHKeyboardQuestion], @escaping @Sendable ([String]?) -> Void) -> Void)? = nil,
        keyAlgorithm: String? = nil,
        keyData: [UInt8]? = nil,
        signature: [UInt8]? = nil,
        blob: [UInt8]? = nil,
        hashAlgo: String? = nil,
        accept: @escaping @Sendable () -> Void = {},
        reject: @escaping @Sendable ([SSHAuthMethod]) -> Void = { _ in }
    ) {
        self.method = method
        self.username = username
        self.password = password
        self.prompt = prompt
        self.keyAlgorithm = keyAlgorithm
        self.keyData = keyData
        self.signature = signature
        self.blob = blob
        self.hashAlgo = hashAlgo
        self.acceptAction = accept
        self.rejectAction = reject
    }

    public func accept() {
        acceptAction()
    }

    public func reject(_ methods: [SSHAuthMethod]) {
        rejectAction(methods)
    }
}

/// Adapt a transport's live `SSHRawAuthContext` into a plain `SSHAuthAttempt`.
/// Read-only (never calls `accept()` / `reject()`). Returns `nil` for unmodeled
/// methods (e.g. `"hostbased"`) so `handle()` rejects them fail-closed.
// parity: ssh/src/auth.ts#attemptFromAuthContext [status=implemented hash=c6887f964538]
public func attemptFromAuthContext(_ ctx: SSHRawAuthContext) -> SSHAuthAttempt? {
    switch ctx.method {
    case "none":
        return .none(username: ctx.username)
    case "password":
        guard let password = ctx.password else { return nil }
        return .password(username: ctx.username, password: password)
    case "keyboard-interactive":
        guard let callbackPrompt = ctx.prompt else { return nil }
        let asyncPrompt: SSHKeyboardPrompt = { questions in
            await withCheckedContinuation { continuation in
                callbackPrompt(questions) { answers in
                    continuation.resume(returning: answers ?? [])
                }
            }
        }
        return .keyboardInteractive(username: ctx.username, prompt: asyncPrompt)
    case "publickey":
        guard let algo = ctx.keyAlgorithm, let data = ctx.keyData else { return nil }
        return .publicKey(
            username: ctx.username,
            key: SSHPublicKey(algorithm: algo, blob: data),
            signature: ctx.signature,
            blob: ctx.blob,
            hashAlgo: ctx.hashAlgo
        )
    default:
        return nil
    }
}

/// Injectable signature verifier seam so transports or custom algorithms can
/// participate in public-key proof verification while defaulting to `SSHParsedKey.verify`.
public protocol SSHSignatureVerifier: Sendable {
    func verify(key: SSHPublicKey, blob: [UInt8], signature: [UInt8], hashAlgo: String?) throws -> Bool
}

/// Default verifier reconstructing `SSHParsedKey` from the attempt's `SSHPublicKey`
/// and calling `verify(blob:signature:hashAlgo:)`.
public struct DefaultSSHSignatureVerifier: SSHSignatureVerifier, Sendable {
    public init() {}

    public func verify(key: SSHPublicKey, blob: [UInt8], signature: [UInt8], hashAlgo: String?) throws -> Bool {
        let reconstructed = "\(key.algorithm) \(SSHBase64.encode(key.blob, padding: true))"
        guard let parsed = parseOneKey(reconstructed) else {
            return false
        }
        return parsed.verify(blob: blob, signature: signature, hashAlgo: hashAlgo)
    }
}

/// Closure-backed `SSHSignatureVerifier` convenience wrapper.
public struct ClosureSSHSignatureVerifier: SSHSignatureVerifier, Sendable {
    private let fn: @Sendable (SSHPublicKey, [UInt8], [UInt8], String?) throws -> Bool

    public init(_ fn: @escaping @Sendable (SSHPublicKey, [UInt8], [UInt8], String?) throws -> Bool) {
        self.fn = fn
    }

    public func verify(key: SSHPublicKey, blob: [UInt8], signature: [UInt8], hashAlgo: String?) throws -> Bool {
        try fn(key, blob, signature, hashAlgo)
    }
}

/// Pure SSH authentication decision engine.
// parity: ssh/src/auth.ts#Authenticator [status=implemented hash=d084e8e417b4]
public protocol SSHAuthenticator: Sendable {
    /// Decide a live transport auth context end to end: adapt, decide, and fail closed.
    func handle(_ ctx: SSHRawAuthContext) async -> SSHAuthOutcome
    /// Decide a single already-adapted attempt.
    func authenticate(_ attempt: SSHAuthAttempt) async -> SSHAuthOutcome
    /// The configured methods advertised to clients on reject and in the banner.
    func advertisedMethods() -> [SSHAuthMethod]
}

private struct DefaultSSHAuthenticator: SSHAuthenticator {
    let auth: SSHNormalizedAuthConfig
    let authorizedKeyBlobs: [[UInt8]]
    let authorizedKeyFingerprints: [String]
    let hasAuthorizedKeys: Bool
    let signatureVerifier: any SSHSignatureVerifier
    let onError: @Sendable (any Error) -> Void

    private func guarded(_ fn: () async throws -> Bool) async -> Bool {
        do {
            return try await fn()
        } catch {
            onError(error)
            return false
        }
    }

    func advertisedMethods() -> [SSHAuthMethod] {
        var methods: [SSHAuthMethod] = []
        if auth.publicKey != nil || hasAuthorizedKeys { methods.append(.publicKey) }
        if auth.password != nil { methods.append(.password) }
        if auth.keyboardInteractive != nil { methods.append(.keyboardInteractive) }
        if auth.none { methods.append(.none) }
        return methods
    }

    private func reject() -> SSHAuthOutcome {
        .reject(methods: advertisedMethods())
    }

    private var allowFn: (@Sendable (SSHPublicKeyAuthContext) async throws -> Bool)? {
        if case .policy(let policy) = auth.publicKey {
            return policy.allow
        }
        return nil
    }

    private func staticAdmits(key: SSHPublicKey) -> Bool {
        if case .any = auth.publicKey {
            return true
        }
        guard hasAuthorizedKeys else { return false }
        var matched = false
        for allowedBlob in authorizedKeyBlobs {
            if timingSafeEqual(key.blob, allowedBlob) {
                matched = true
            }
        }
        if !matched && !authorizedKeyFingerprints.isEmpty {
            let fp = sha256Fingerprint(key.blob)
            for allowedFp in authorizedKeyFingerprints {
                if timingSafeEqual(fp, allowedFp) {
                    matched = true
                }
            }
        }
        return matched
    }

    func authenticate(_ attempt: SSHAuthAttempt) async -> SSHAuthOutcome {
        switch attempt {
        case .none(let username):
            return auth.none ? .accept(identity: .none(username: username)) : reject()

        case .password(let username, let password):
            guard let fn = auth.password else { return reject() }
            let ok = await guarded {
                try await fn(SSHPasswordAuthContext(username: username, password: password))
            }
            return ok ? .accept(identity: .password(username: username)) : reject()

        case .keyboardInteractive(let username, let prompt):
            guard let fn = auth.keyboardInteractive else { return reject() }
            let ok = await guarded {
                try await fn(SSHKeyboardInteractiveAuthContext(username: username, prompt: prompt))
            }
            return ok ? .accept(identity: .keyboardInteractive(username: username)) : reject()

        case .publicKey(let username, let key, let signature, let blob, let hashAlgo):
            guard auth.publicKey != nil || hasAuthorizedKeys else { return reject() }

            // Phase 1 (probe): tell the client whether this key is worth signing.
            // Never run the dynamic `allow` predicate before proof of possession.
            guard let signature else {
                if staticAdmits(key: key) || allowFn != nil {
                    return .acceptProbe
                }
                return reject()
            }

            // Phase 2 (signed): verify cryptographic proof over `blob` before minting identity.
            let fingerprint = sha256Fingerprint(key.blob)
            guard let blob else { return reject() }

            let verified = await guarded {
                try signatureVerifier.verify(key: key, blob: blob, signature: signature, hashAlgo: hashAlgo)
            }
            guard verified else { return reject() }

            // Key proven; apply admission policy (static allowlist OR dynamic `allow`).
            if !staticAdmits(key: key) {
                guard let allow = allowFn else { return reject() }
                let allowed = await guarded {
                    try await allow(SSHPublicKeyAuthContext(
                        username: username,
                        fingerprint: fingerprint,
                        publicKey: key
                    ))
                }
                guard allowed else { return reject() }
            }

            return .accept(identity: .publicKey(
                username: username,
                fingerprint: fingerprint,
                publicKey: key
            ))
        }
    }

    func handle(_ ctx: SSHRawAuthContext) async -> SSHAuthOutcome {
        guard let attempt = attemptFromAuthContext(ctx) else {
            return reject()
        }
        return await authenticate(attempt)
    }
}

/// Build the auth decision core from normalized config and an optional pre-parsed
/// allowlist of Base64 public-SSH blobs (or `SHA256:...` fingerprints).
// parity: ssh/src/auth.ts#createAuthenticator [status=implemented hash=1d5341653d9d]
public func createAuthenticator(
    auth: SSHNormalizedAuthConfig,
    authorizedKeys: [String]? = nil,
    signatureVerifier: any SSHSignatureVerifier = DefaultSSHSignatureVerifier(),
    onError: @escaping @Sendable (any Error) -> Void = { _ in }
) -> any SSHAuthenticator {
    var blobs: [[UInt8]] = []
    var fingerprints: [String] = []
    if let authorizedKeys {
        for entry in authorizedKeys {
            if let normFp = normalizeFingerprint(entry) {
                fingerprints.append(normFp)
            } else if let decoded = SSHBase64.decode(entry) {
                blobs.append(decoded)
            }
        }
    }
    return DefaultSSHAuthenticator(
        auth: auth,
        authorizedKeyBlobs: blobs,
        authorizedKeyFingerprints: fingerprints,
        hasAuthorizedKeys: authorizedKeys != nil,
        signatureVerifier: signatureVerifier,
        onError: onError
    )
}

/// The auth facts `resolveAuth` decides from public `SSHAuthConfig`.
// parity: ssh/src/auth.ts#ResolvedAuth [status=implemented hash=e8f342e5557c]
public struct SSHResolvedAuth: Sendable {
    public let authenticator: any SSHAuthenticator
    /// True when `none` is the only advertised method (wide-open server).
    public let noneOnly: Bool
    /// Parsed static allowlist (Base64 public-SSH blobs), surfaced for the startup banner.
    public let authorizedKeys: [String]?

    public init(
        authenticator: any SSHAuthenticator,
        noneOnly: Bool,
        authorizedKeys: [String]?
    ) {
        self.authenticator = authenticator
        self.noneOnly = noneOnly
        self.authorizedKeys = authorizedKeys
    }
}

private func loadAuthorizedKeys(
    _ source: SSHAuthorizedKeysSource,
    fileStore: any SSHKeyFileStore
) throws -> [String] {
    let lines: [String]
    switch source {
    case .file(let path):
        do {
            let bytes = try fileStore.readFile(at: path)
            guard let text = String(bytes: bytes, encoding: .utf8) else {
                throw ConfigError("could not read authorizedKeys file: \(path)")
            }
            lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        } catch let error as ConfigError {
            throw error
        } catch {
            throw ConfigError("could not read authorizedKeys file: \(path)")
        }
    case .keys(let entries):
        lines = entries
    }

    var seen: Set<String> = []
    var ordered: [String] = []
    for raw in lines {
        let line = raw.trimmingWhitespace()
        if line.isEmpty || line.hasPrefix("#") { continue }
        guard let key = parseOneKey(line) else {
            throw ConfigError("invalid authorizedKeys entry: \(String(line.prefix(40)))")
        }
        let b64 = key.publicSSHBase64
        if seen.insert(b64).inserted {
            ordered.append(b64)
        }
    }
    if ordered.isEmpty {
        throw ConfigError("authorizedKeys did not contain any public keys")
    }
    return ordered
}

/// Resolve public `SSHAuthConfig` into the running authenticator, validating
/// non-empty credentials and pre-parsing any static `authorizedKeys` allowlist.
// parity: ssh/src/auth.ts#resolveAuth [status=implemented hash=20db9ee9f93b]
public func resolveAuth(
    _ auth: SSHAuthConfig?,
    fileStore: any SSHKeyFileStore = DefaultSSHKeyFileStore(),
    signatureVerifier: any SSHSignatureVerifier = DefaultSSHSignatureVerifier(),
    onError: @escaping @Sendable (any Error) -> Void
) throws -> SSHResolvedAuth {
    let isOpen: Bool
    let normalized: SSHNormalizedAuthConfig
    switch auth {
    case .none, .some(.open):
        isOpen = true
        normalized = SSHNormalizedAuthConfig(none: true)
    case .some(.methods(let methods)):
        isOpen = false
        normalized = SSHNormalizedAuthConfig(
            publicKey: methods.publicKey,
            password: methods.password,
            keyboardInteractive: methods.keyboardInteractive,
            none: false
        )
    }

    var authorizedKeys: [String]? = nil
    if case .policy(let policy) = normalized.publicKey {
        if policy.authorizedKeys == nil && policy.allow == nil {
            throw ConfigError("auth.publicKey must set \"any\", authorizedKeys, or allow")
        }
        if let source = policy.authorizedKeys {
            authorizedKeys = try loadAuthorizedKeys(source, fileStore: fileStore)
        }
    }

    let authenticator = createAuthenticator(
        auth: normalized,
        authorizedKeys: authorizedKeys,
        signatureVerifier: signatureVerifier,
        onError: onError
    )

    let methods = authenticator.advertisedMethods()
    if !isOpen && methods.isEmpty {
        throw ConfigError(
            "auth: {} configures no authentication methods — no client could connect. "
                + "Set publicKey / password / keyboardInteractive, or use auth: \"open\" for no authentication."
        )
    }

    return SSHResolvedAuth(
        authenticator: authenticator,
        noneOnly: isOpen,
        authorizedKeys: authorizedKeys
    )
}
