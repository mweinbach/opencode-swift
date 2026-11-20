#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Synchronization
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

/// Authentication primitives and header signers for AI routes.
/// Ports `packages/ai/src/route/auth.ts`.
public enum AIAuth {
    /// Redacted secret wrapper whose `description` never leaks the underlying credential.
    public struct RedactedSecret: Equatable, Hashable, Sendable, CustomStringConvertible {
        public let value: String

        public init(_ value: String) {
            self.value = value
        }

        public var description: String { "<redacted>" }
    }

    /// Secret input accepted by auth helpers: plain string, redacted secret, or environment variable lookup.
    public enum Secret: Sendable {
        case plain(String)
        case redacted(RedactedSecret)
        case config(name: String, environment: (any EnvironmentProviding)?)
    }

    // parity: ai/src/route/auth.ts#MissingCredentialError [status=implemented hash=8d427f2f0311]
    public struct MissingCredentialError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public static let tag = "MissingCredentialError"
        public let source: String
        public let message: String

        public init(source: String, message: String? = nil) {
            self.source = source
            self.message = message ?? "Missing auth credential: \(source)"
        }

        public var description: String { message }
    }

    // parity: ai/src/route/auth.ts#CredentialError [status=adapted hash=944cfff445c2]
    public enum CredentialError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        case missing(MissingCredentialError)
        case config(String)

        public var description: String {
            switch self {
            case .missing(let e): e.message
            case .config(let m): m
            }
        }
    }

    // parity: ai/src/route/auth.ts#AuthError [status=adapted hash=286dc05c9ea2]
    public enum AuthError: Swift.Error, Equatable, Sendable, CustomStringConvertible {
        case credential(CredentialError)
        case ai(AISchema.AIError)

        public var description: String {
            switch self {
            case .credential(let e): e.description
            case .ai(let e): e.message
            }
        }
    }

    // parity: ai/src/route/auth.ts#AuthInput [status=implemented hash=bad264e8aa51]
    public struct AuthInput: Sendable {
        public enum Method: String, Equatable, Hashable, Sendable, Codable {
            case POST
            case GET
            case PUT
            case DELETE
        }

        public let httpOptions: AISchema.HttpOptions?
        public let method: Method
        public let url: String
        public let body: String
        public let headers: [String: String]

        public init(
            httpOptions: AISchema.HttpOptions? = nil,
            method: Method,
            url: String,
            body: String,
            headers: [String: String]
        ) {
            self.httpOptions = httpOptions
            self.method = method
            self.url = url
            self.body = body
            self.headers = headers
        }

        public func withHeaders(_ next: [String: String]) -> AuthInput {
            AuthInput(httpOptions: httpOptions, method: method, url: url, body: body, headers: next)
        }
    }

    // parity: ai/src/route/auth.ts#Credential [status=implemented hash=10c7b94b24d9]
    public struct Credential: Sendable {
        public let load: @Sendable () async throws -> RedactedSecret

        public init(load: @escaping @Sendable () async throws -> RedactedSecret) {
            self.load = load
        }

        public func orElse(_ other: Credential) -> Credential {
            let primary = load
            let fallback = other.load
            return Credential {
                do {
                    return try await primary()
                } catch {
                    return try await fallback()
                }
            }
        }

        public func bearer() -> Definition {
            AIAuth.fromCredential(self) { secret in
                ["authorization": "Bearer \(secret)"]
            }
        }

        public func header(_ name: String) -> Definition {
            AIAuth.fromCredential(self) { secret in
                [name: secret]
            }
        }

        public func pipe<A>(_ f: (Credential) -> A) -> A {
            f(self)
        }
    }

    // parity: ai/src/route/auth.ts#Definition [status=implemented hash=efd1c972a201]
    public struct Definition: Sendable {
        public let apply: @Sendable (AuthInput) async throws -> [String: String]

        public init(apply: @escaping @Sendable (AuthInput) async throws -> [String: String]) {
            self.apply = apply
        }

        public func andThen(_ other: Definition) -> Definition {
            let first = apply
            let second = other.apply
            return Definition { input in
                let headers = try await first(input)
                return try await second(input.withHeaders(headers))
            }
        }

        public func orElse(_ other: Definition) -> Definition {
            let first = apply
            let second = other.apply
            return Definition { input in
                do {
                    return try await first(input)
                } catch {
                    return try await second(input)
                }
            }
        }

        public func pipe<A>(_ f: (Definition) -> A) -> A {
            f(self)
        }
    }

    private static func setAllHeaders(_ base: [String: String], _ added: [String: String]) -> [String: String] {
        var result = base
        for (key, value) in added {
            // Case-insensitive replacement matching HTTP Headers.setAll semantics
            let lower = key.lowercased()
            for existingKey in result.keys where existingKey.lowercased() == lower {
                result.removeValue(forKey: existingKey)
            }
            result[lower] = value
        }
        return result
    }

    private static func removeHeader(_ base: [String: String], named name: String) -> [String: String] {
        let lower = name.lowercased()
        return base.filter { $0.key.lowercased() != lower }
    }

    private static func fromCredential(
        _ source: Credential,
        render: @escaping @Sendable (String) -> [String: String]
    ) -> Definition {
        Definition { input in
            let secret: RedactedSecret
            do {
                secret = try await source.load()
            } catch let credErr as CredentialError {
                throw AuthError.credential(credErr)
            } catch let missing as MissingCredentialError {
                throw AuthError.credential(.missing(missing))
            } catch let authErr as AuthError {
                throw authErr
            } catch {
                throw AuthError.credential(.config(String(describing: error)))
            }
            return setAllHeaders(input.headers, render(secret.value))
        }
    }

    private static func credentialFromSecret(_ secret: Secret, source: String) -> Credential {
        switch secret {
        case .plain(let str):
            return Credential {
                guard !str.isEmpty else { throw CredentialError.missing(MissingCredentialError(source: source)) }
                return RedactedSecret(str)
            }
        case .redacted(let red):
            return Credential {
                guard !red.value.isEmpty else { throw CredentialError.missing(MissingCredentialError(source: source)) }
                return red
            }
        case .config(let name, let env):
            return config(name, environment: env)
        }
    }

    // parity: ai/src/route/auth.ts#value [status=implemented hash=6bf449b7fb37]
    public static func value(_ secret: String, source: String = "value") -> Credential {
        credentialFromSecret(.plain(secret), source: source)
    }

    // parity: ai/src/route/auth.ts#optional [status=implemented hash=2be157010489]
    public static func optional(_ secret: Secret?, source: String = "optional value") -> Credential {
        guard let secret else {
            return Credential {
                throw CredentialError.missing(MissingCredentialError(source: source))
            }
        }
        return credentialFromSecret(secret, source: source)
    }

    public static func optional(_ secret: String?, source: String = "optional value") -> Credential {
        optional(secret.map { .plain($0) }, source: source)
    }

    // parity: ai/src/route/auth.ts#config [status=implemented hash=b96f825d2123]
    public static func config(_ name: String, environment: (any EnvironmentProviding)? = nil) -> Credential {
        Credential {
            let env = environment ?? SystemEnvironment.shared
            if let value = env.variable(name), !value.isEmpty {
                return RedactedSecret(value)
            }
            throw CredentialError.missing(MissingCredentialError(source: name, message: "\(name) is not set"))
        }
    }

    // parity: ai/src/route/auth.ts#effect [status=implemented hash=84e5e8553d75]
    public static func effect(_ load: @escaping @Sendable () async throws -> RedactedSecret) -> Credential {
        Credential(load: load)
    }

    // parity: ai/src/route/auth.ts#none [status=implemented hash=90839b59764f]
    public static let none = Definition { input in
        input.headers
    }

    // parity: ai/src/route/auth.ts#headers [status=implemented hash=427013a43a20]
    public static func headers(_ extra: [String: String]) -> Definition {
        Definition { input in
            setAllHeaders(input.headers, extra)
        }
    }

    // parity: ai/src/route/auth.ts#remove [status=implemented hash=b9aeb6877388]
    public static func remove(_ name: String) -> Definition {
        Definition { input in
            removeHeader(input.headers, named: name)
        }
    }

    // parity: ai/src/route/auth.ts#custom [status=implemented hash=7a7245a31909]
    public static func custom(
        _ apply: @escaping @Sendable (AuthInput) async throws -> [String: String]
    ) -> Definition {
        Definition { input in
            do {
                return try await apply(input)
            } catch let aiError as AISchema.AIError {
                throw AuthError.ai(aiError)
            }
        }
    }

    // parity: ai/src/route/auth.ts#passthrough [status=implemented hash=7fb41851ecd4]
    public static let passthrough = none

    // parity: ai/src/route/auth.ts#bearer [status=implemented hash=96463c7d093d]
    public static func bearer(_ source: Credential) -> Definition {
        source.bearer()
    }

    public static func bearer(_ source: Secret) -> Definition {
        credentialFromSecret(source, source: "value").bearer()
    }

    public static func bearer(_ source: String) -> Definition {
        value(source).bearer()
    }

    // parity: ai/src/route/auth.ts#header [status=implemented hash=6f3a3077b7f5]
    public static func header(_ name: String) -> @Sendable (Credential) -> Definition {
        { credential in credential.header(name) }
    }

    public static func header(_ name: String, _ source: Credential) -> Definition {
        source.header(name)
    }

    public static func header(_ name: String, _ source: String) -> Definition {
        value(source).header(name)
    }

    // parity: ai/src/route/auth.ts#bearerHeader [status=implemented hash=39196c19d756]
    public static func bearerHeader(_ name: String) -> @Sendable (Credential) -> Definition {
        { credential in
            fromCredential(credential) { secret in [name: "Bearer \(secret)"] }
        }
    }

    public static func bearerHeader(_ name: String, _ source: Credential) -> Definition {
        fromCredential(source) { secret in [name: "Bearer \(secret)"] }
    }

    public static func bearerHeader(_ name: String, _ source: String) -> Definition {
        bearerHeader(name, value(source))
    }

    // parity: ai/src/route/auth.ts#scheme [status=implemented hash=4c6b53bfcff7]
    public static func scheme(_ name: String) -> @Sendable (Credential) -> Definition {
        { credential in
            fromCredential(credential) { secret in ["authorization": "\(name) \(secret)"] }
        }
    }

    public static func scheme(_ name: String, _ source: Credential) -> Definition {
        fromCredential(source) { secret in ["authorization": "\(name) \(secret)"] }
    }

    public static func scheme(_ name: String, _ source: String) -> Definition {
        scheme(name, value(source))
    }

    private static func toAIError(_ error: AuthError) -> AISchema.AIError {
        switch error {
        case .ai(let aiError):
            return aiError
        case .credential(let credErr):
            let message: String = switch credErr {
            case .missing(let m): m.message
            case .config(let m): "Failed to resolve auth config: \(m)"
            }
            return AISchema.AIError(reason: .authentication(AISchema.AuthenticationError(
                message: message,
                cause: credErr.description
            )))
        }
    }

    // parity: ai/src/route/auth.ts#toEffect [status=implemented hash=847ee669e29b]
    public static func toEffect(
        _ definition: Definition
    ) -> @Sendable (AuthInput) async throws -> [String: String] {
        { input in
            do {
                return try await definition.apply(input)
            } catch let authErr as AuthError {
                throw toAIError(authErr)
            } catch let credErr as CredentialError {
                throw toAIError(.credential(credErr))
            } catch let aiErr as AISchema.AIError {
                throw aiErr
            } catch {
                throw AISchema.AIError(reason: .authentication(AISchema.AuthenticationError(
                    message: "Failed to resolve auth config: \(error)",
                    cause: String(describing: error)
                )))
            }
        }
    }
}

/// Provider API-key option resolution helpers.
/// Ports `packages/ai/src/route/auth-options.ts`.
public enum AIAuthOptions {
    // parity: ai/src/route/auth-options.ts#ApiKeyMode [status=implemented hash=113a69353a78]
    public enum ApiKeyMode: String, Equatable, Hashable, Sendable, Codable {
        case optional
        case required
    }

    // parity: ai/src/route/auth-options.ts#AuthOverride [status=implemented hash=46b4783d58d7]
    public struct AuthOverride: Sendable {
        public let auth: AIAuth.Definition

        public init(auth: AIAuth.Definition) {
            self.auth = auth
        }
    }

    /// `disabled` (`false` in upstream) marks a provider that needs no key.
    // parity: ai/src/route/auth-options.ts#ApiKey [status=implemented hash=4523bde7850d]
    public enum ApiKey: Sendable {
        case secret(AIAuth.Secret)
        case disabled

        public static func string(_ value: String) -> ApiKey {
            .secret(.plain(value))
        }
    }

    // parity: ai/src/route/auth-options.ts#OptionalApiKeyAuth [status=implemented hash=6b22a8824415]
    public struct OptionalApiKeyAuth: Sendable {
        public let apiKey: ApiKey?

        public init(apiKey: ApiKey? = nil) {
            self.apiKey = apiKey
        }
    }

    // parity: ai/src/route/auth-options.ts#RequiredApiKeyAuth [status=implemented hash=8b62f0a377ec]
    public struct RequiredApiKeyAuth: Sendable {
        public let apiKey: ApiKey

        public init(apiKey: ApiKey) {
            self.apiKey = apiKey
        }
    }

    // parity: ai/src/route/auth-options.ts#ProviderAuthOption [status=implemented hash=7fa662f1deb2]
    public enum ProviderAuthOption: Sendable {
        case auth(AIAuth.Definition)
        case apiKey(ApiKey?)

        public static let none = ProviderAuthOption.apiKey(nil)
    }

    /// Type witness for option groups requiring at least one member.
    // parity: ai/src/route/auth-options.ts#AtLeastOne [status=adapted hash=846c62094d6a]
    public enum AtLeastOne<First: Sendable, Second: Sendable>: Sendable {
        case first(First)
        case second(Second)
        case both(First, Second)
    }

    // parity: ai/src/route/auth-options.ts#apiKey [status=implemented hash=4f4afc06b637]
    public static func apiKey(
        _ options: ProviderAuthOption,
        envVars: [String],
        environment: (any EnvironmentProviding)? = nil,
        apply: @Sendable (AIAuth.Credential) -> AIAuth.Definition
    ) -> AIAuth.Definition {
        switch options {
        case .auth(let definition):
            return definition
        case .apiKey(.disabled):
            return AIAuth.none
        case .apiKey(.secret(let secret)):
            let initial = AIAuth.optional(secret, source: "apiKey")
            let resolved = envVars.reduce(initial) { current, name in
                current.orElse(AIAuth.config(name, environment: environment))
            }
            return apply(resolved)
        case .apiKey(nil):
            let initial = AIAuth.optional(nil as AIAuth.Secret?, source: "apiKey")
            let resolved = envVars.reduce(initial) { current, name in
                current.orElse(AIAuth.config(name, environment: environment))
            }
            return apply(resolved)
        }
    }

    public static func apiKey(
        _ options: ProviderAuthOption,
        envVar: String,
        environment: (any EnvironmentProviding)? = nil,
        apply: @Sendable (AIAuth.Credential) -> AIAuth.Definition
    ) -> AIAuth.Definition {
        apiKey(options, envVars: [envVar], environment: environment, apply: apply)
    }

    // parity: ai/src/route/auth-options.ts#bearer [status=implemented hash=2ed25dc8efe2]
    public static func bearer(
        _ options: ProviderAuthOption,
        envVars: [String],
        environment: (any EnvironmentProviding)? = nil
    ) -> AIAuth.Definition {
        apiKey(options, envVars: envVars, environment: environment) { $0.bearer() }
    }

    public static func bearer(
        _ options: ProviderAuthOption,
        envVar: String,
        environment: (any EnvironmentProviding)? = nil
    ) -> AIAuth.Definition {
        bearer(options, envVars: [envVar], environment: environment)
    }
}

/// Declarative URL construction for routes.
/// Ports `packages/ai/src/route/endpoint.ts`.
public enum AIEndpoint {
    // parity: ai/src/route/endpoint.ts#EndpointInput [status=implemented hash=0c7bbe2d2a3a]
    public struct EndpointInput<Body: Sendable, Request: Sendable>: Sendable {
        public let request: Request
        public let body: Body

        public init(request: Request, body: Body) {
            self.request = request
            self.body = body
        }
    }

    // parity: ai/src/route/endpoint.ts#EndpointPart [status=implemented hash=d5dca2542c50]
    public enum EndpointPart<Body: Sendable, Request: Sendable>: Sendable {
        case literal(String)
        case dynamic(@Sendable (EndpointInput<Body, Request>) -> String)

        public func render(_ input: EndpointInput<Body, Request>) -> String {
            switch self {
            case .literal(let s): s
            case .dynamic(let fn): fn(input)
            }
        }
    }

    // parity: ai/src/route/endpoint.ts#Definition [status=implemented hash=2caaa957ca18]
    public struct Definition<Body: Sendable, Request: Sendable>: Sendable {
        public let baseURL: String?
        public let path: EndpointPart<Body, Request>
        public let query: [String: String]?

        public init(
            baseURL: String? = nil,
            path: EndpointPart<Body, Request>,
            query: [String: String]? = nil
        ) {
            self.baseURL = baseURL
            self.path = path
            self.query = query
        }
    }

    // parity: ai/src/route/endpoint.ts#EndpointPatch [status=implemented hash=060fc3566f93]
    public struct EndpointPatch<Body: Sendable, Request: Sendable>: Sendable {
        public let baseURL: String?
        public let path: EndpointPart<Body, Request>?
        public let query: [String: String]?

        public init(
            baseURL: String? = nil,
            path: EndpointPart<Body, Request>? = nil,
            query: [String: String]? = nil
        ) {
            self.baseURL = baseURL
            self.path = path
            self.query = query
        }
    }

    // parity: ai/src/route/endpoint.ts#path [status=implemented hash=2bd00a2b04b4]
    public static func path<Body: Sendable, Request: Sendable>(
        _ value: EndpointPart<Body, Request>,
        baseURL: String? = nil,
        query: [String: String]? = nil
    ) -> Definition<Body, Request> {
        Definition(baseURL: baseURL, path: value, query: query)
    }

    public static func path<Body: Sendable, Request: Sendable>(
        _ literal: String,
        baseURL: String? = nil,
        query: [String: String]? = nil
    ) -> Definition<Body, Request> {
        Definition(baseURL: baseURL, path: .literal(literal), query: query)
    }

    // parity: ai/src/route/endpoint.ts#merge [status=implemented hash=b30a42aebaf3]
    public static func merge<Body: Sendable, Request: Sendable>(
        _ base: Definition<Body, Request>,
        _ patch: EndpointPatch<Body, Request>
    ) -> Definition<Body, Request> {
        let mergedQuery: [String: String]?
        if let patchQuery = patch.query {
            var q = base.query ?? [:]
            for (k, v) in patchQuery { q[k] = v }
            mergedQuery = q
        } else {
            mergedQuery = base.query
        }
        return Definition(
            baseURL: patch.baseURL ?? base.baseURL,
            path: patch.path ?? base.path,
            query: mergedQuery
        )
    }

    // parity: ai/src/route/endpoint.ts#trimBaseUrl [status=implemented hash=eac87b75734d]
    public static func trimBaseUrl(_ value: String) -> String {
        var end = value.endIndex
        while end > value.startIndex {
            let prev = value.index(before: end)
            if value[prev] == "/" {
                end = prev
            } else {
                break
            }
        }
        return String(value[..<end])
    }

    // parity: ai/src/route/endpoint.ts#render [status=implemented hash=003b9e38098c]
    public static func render<Body: Sendable, Request: Sendable>(
        _ endpoint: Definition<Body, Request>,
        input: EndpointInput<Body, Request>
    ) throws(AISchema.AIError) -> URL {
        let raw = "\(trimBaseUrl(endpoint.baseURL ?? ""))\(endpoint.path.render(input))"
        guard var components = URLComponents(string: raw) else {
            throw AISchema.AIError(reason: .invalidRequest(AISchema.InvalidRequestError(
                message: "Invalid endpoint URL: \(raw)"
            )))
        }
        if let query = endpoint.query, !query.isEmpty {
            var items = components.queryItems ?? []
            for key in query.keys.sorted() {
                if let val = query[key] {
                    items.removeAll { $0.name == key }
                    items.append(URLQueryItem(name: key, value: val))
                }
            }
            components.queryItems = items
        }
        guard let url = components.url else {
            throw AISchema.AIError(reason: .invalidRequest(AISchema.InvalidRequestError(
                message: "Failed to build endpoint URL from: \(raw)"
            )))
        }
        return url
    }

    public static func setQueryParams(_ url: URL, query: [(String, [String])]) -> URL {
        guard !query.isEmpty, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        var items = components.queryItems ?? []
        for (key, values) in query {
            items.removeAll { $0.name == key }
            for v in values {
                items.append(URLQueryItem(name: key, value: v))
            }
        }
        components.queryItems = items
        return components.url ?? url
    }
}

/// Incremental UTF-8, Server-Sent Events (SSE), and NDJSON line stream framing.
/// Ports `packages/ai/src/route/framing.ts`.
public enum AIFraming {
    /// Incremental UTF-8 byte decoder that cleanly handles multi-byte code points split across chunk boundaries.
    public struct IncrementalUTF8Decoder: Sendable {
        private var pending: [UInt8] = []
        private var sawFirstChunk = false

        public init() {}

        public mutating func decode(_ bytes: [UInt8], stripLeadingBOM: Bool = false) -> String {
            guard !bytes.isEmpty else { return "" }
            var buffer: [UInt8]
            if pending.isEmpty {
                buffer = bytes
            } else {
                buffer = pending + bytes
                pending.removeAll(keepingCapacity: true)
            }

            if !sawFirstChunk {
                sawFirstChunk = true
                if stripLeadingBOM && buffer.count >= 3 && buffer[0] == 0xEF && buffer[1] == 0xBB && buffer[2] == 0xBF {
                    buffer.removeFirst(3)
                }
            }

            // Check if the tail holds an incomplete UTF-8 multi-byte sequence (up to 3 trailing bytes).
            let trailingIncomplete = Self.incompleteTrailingByteCount(buffer)
            if trailingIncomplete > 0 {
                let splitAt = buffer.count - trailingIncomplete
                pending = Array(buffer[splitAt...])
                buffer.removeLast(trailingIncomplete)
            }

            return buffer.isEmpty ? "" : String(decoding: buffer, as: UTF8.self)
        }

        public mutating func finish() -> String {
            guard !pending.isEmpty else { return "" }
            let result = String(decoding: pending, as: UTF8.self)
            pending.removeAll(keepingCapacity: false)
            return result
        }

        private static func incompleteTrailingByteCount(_ bytes: [UInt8]) -> Int {
            let count = bytes.count
            guard count > 0 else { return 0 }
            // Walk back up to 3 bytes to locate the start byte of the final sequence.
            let maxLookback = min(3, count)
            for back in 1...maxLookback {
                let b = bytes[count - back]
                if (b & 0x80) == 0 {
                    // Pure ASCII byte — complete.
                    return 0
                }
                if (b & 0xC0) != 0x80 {
                    // Leading byte of a multi-byte sequence.
                    let expectedLen: Int
                    if (b & 0xE0) == 0xC0 {
                        expectedLen = 2
                    } else if (b & 0xF0) == 0xE0 {
                        expectedLen = 3
                    } else if (b & 0xF8) == 0xF0 {
                        expectedLen = 4
                    } else {
                        // Invalid lead byte; let UTF-8 replacement decode it immediately.
                        return 0
                    }
                    return back < expectedLen ? back : 0
                }
            }
            return 0
        }
    }

    /// Parsed Server-Sent Event matching the WHATWG EventSource specification.
    public struct SSEEvent: Equatable, Hashable, Sendable {
        public let event: String
        public let data: String
        public let id: String?

        public init(event: String = "message", data: String, id: String? = nil) {
            self.event = event
            self.data = data
            self.id = id
        }
    }

    /// Stateful incremental WHATWG Server-Sent Events parser.
    /// Correctly handles arbitrary chunk splits, `\r\n`/`\n`/`\r` line endings, BOM, comments,
    /// multi-line `data:` joining, `event:`, `id:`, and `retry:` directives.
    public struct SSEParser: Sendable {
        private var utf8 = IncrementalUTF8Decoder()
        private var lineBuffer = ""
        private var skipLeadingLF = false
        private var eventType = ""
        private var dataLines: [String] = []
        private var lastEventId: String? = nil
        public private(set) var retryMs: Int? = nil

        public init() {}

        public mutating func feed(_ bytes: [UInt8]) -> [SSEEvent] {
            let chunk = utf8.decode(bytes, stripLeadingBOM: true)
            return feed(chunk)
        }

        public mutating func feed(_ chunk: String) -> [SSEEvent] {
            guard !chunk.isEmpty else { return [] }
            var emitted: [SSEEvent] = []
            var iterator = chunk.unicodeScalars.makeIterator()

            if skipLeadingLF {
                skipLeadingLF = false
                if let first = iterator.next() {
                    if first != "\n" {
                        processScalar(first, into: &emitted)
                    }
                } else {
                    return emitted
                }
            }

            while let scalar = iterator.next() {
                if scalar == "\r" {
                    let line = lineBuffer
                    lineBuffer.removeAll(keepingCapacity: true)
                    processLine(line, into: &emitted)
                    // Peek/skip immediate LF either in this chunk or at start of next chunk.
                    if let next = iterator.next() {
                        if next != "\n" {
                            processScalar(next, into: &emitted)
                        }
                    } else {
                        skipLeadingLF = true
                    }
                } else {
                    processScalar(scalar, into: &emitted)
                }
            }

            return emitted
        }

        public mutating func finish() -> [SSEEvent] {
            var emitted: [SSEEvent] = []
            let remainder = utf8.finish()
            if !remainder.isEmpty {
                emitted.append(contentsOf: feed(remainder))
            }
            if !lineBuffer.isEmpty {
                let line = lineBuffer
                lineBuffer.removeAll(keepingCapacity: false)
                processLine(line, into: &emitted)
            }
            // Per WHATWG EventSource, an unterminated event buffer without trailing blank line is discarded;
            // however, flush only if caller explicitly wants EOF-terminated data? No — spec discards incomplete
            // trailing event without blank line. Reset buffers cleanly.
            return emitted
        }

        private mutating func processScalar(_ scalar: Unicode.Scalar, into emitted: inout [SSEEvent]) {
            if scalar == "\n" {
                let line = lineBuffer
                lineBuffer.removeAll(keepingCapacity: true)
                processLine(line, into: &emitted)
            } else {
                lineBuffer.unicodeScalars.append(scalar)
            }
        }

        private mutating func processLine(_ line: String, into emitted: inout [SSEEvent]) {
            if line.isEmpty {
                dispatchEvent(into: &emitted)
                return
            }
            if line.first == ":" {
                // SSE comment line — ignore.
                return
            }
            let field: String
            let value: String
            if let colonIndex = line.firstIndex(of: ":") {
                field = String(line[..<colonIndex])
                var valueStart = line.index(after: colonIndex)
                if valueStart < line.endIndex && line[valueStart] == " " {
                    valueStart = line.index(after: valueStart)
                }
                value = String(line[valueStart...])
            } else {
                field = line
                value = ""
            }

            switch field {
            case "event":
                eventType = value
            case "data":
                dataLines.append(value)
            case "id":
                if !value.unicodeScalars.contains("\u{0000}") {
                    lastEventId = value
                }
            case "retry":
                if !value.isEmpty && value.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }), let ms = Int(value) {
                    retryMs = ms
                }
            default:
                break
            }
        }

        private mutating func dispatchEvent(into emitted: inout [SSEEvent]) {
            defer {
                eventType = ""
                dataLines.removeAll(keepingCapacity: true)
            }
            guard !dataLines.isEmpty else { return }
            let data = dataLines.joined(separator: "\n")
            let name = eventType.isEmpty ? "message" : eventType
            emitted.append(SSEEvent(event: name, data: data, id: lastEventId))
        }
    }

    /// Stateful incremental NDJSON / newline-delimited text line decoder.
    public struct NDJSONLineDecoder: Sendable {
        private var utf8 = IncrementalUTF8Decoder()
        private var buffer = ""
        private var skipLeadingLF = false

        public init() {}

        public mutating func feed(_ bytes: [UInt8]) -> [String] {
            let chunk = utf8.decode(bytes)
            return feed(chunk)
        }

        public mutating func feed(_ chunk: String) -> [String] {
            guard !chunk.isEmpty else { return [] }
            var lines: [String] = []
            var iterator = chunk.unicodeScalars.makeIterator()

            if skipLeadingLF {
                skipLeadingLF = false
                if let first = iterator.next(), first != "\n" {
                    appendOrFlush(first, into: &lines)
                }
            }

            while let scalar = iterator.next() {
                if scalar == "\r" {
                    lines.append(buffer)
                    buffer.removeAll(keepingCapacity: true)
                    if let next = iterator.next() {
                        if next != "\n" {
                            appendOrFlush(next, into: &lines)
                        }
                    } else {
                        skipLeadingLF = true
                    }
                } else {
                    appendOrFlush(scalar, into: &lines)
                }
            }
            return lines
        }

        public mutating func finish() -> [String] {
            var lines: [String] = []
            let tail = utf8.finish()
            if !tail.isEmpty {
                lines.append(contentsOf: feed(tail))
            }
            if !buffer.isEmpty {
                lines.append(buffer)
                buffer.removeAll(keepingCapacity: false)
            }
            return lines
        }

        private mutating func appendOrFlush(_ scalar: Unicode.Scalar, into lines: inout [String]) {
            if scalar == "\n" {
                lines.append(buffer)
                buffer.removeAll(keepingCapacity: true)
            } else {
                buffer.unicodeScalars.append(scalar)
            }
        }
    }

    // parity: ai/src/route/framing.ts#Definition [status=implemented hash=55ad19a652df]
    public struct Definition<Frame: Sendable>: Sendable {
        public let id: String
        public let frame: @Sendable (AsyncThrowingStream<[UInt8], Error>) -> AsyncThrowingStream<Frame, Error>
        public let body: (@Sendable (Frame) -> String?)?
        public let raw: (@Sendable (Frame) -> JSONValue?)?

        public init(
            id: String,
            frame: @escaping @Sendable (AsyncThrowingStream<[UInt8], Error>) -> AsyncThrowingStream<Frame, Error>,
            body: (@Sendable (Frame) -> String?)? = nil,
            raw: (@Sendable (Frame) -> JSONValue?)? = nil
        ) {
            self.id = id
            self.frame = frame
            self.body = body
            self.raw = raw
        }
    }

    /// Filter predicate matching upstream `sseFraming` exactly.
    public static func shouldEmitSSEEvent(
        _ event: SSEEvent,
        events: Set<String>? = nil,
        includeDone: Bool = false
    ) -> Bool {
        if let events, !events.contains(event.event) { return false }
        guard !event.data.isEmpty else { return false }
        if event.data == "null" { return false }
        if event.data == ": keepalive" { return false }
        if event.data == "[DONE]" && !includeDone && !(events != nil && event.event != "message") {
            return false
        }
        return true
    }

    // parity: ai/src/route/framing.ts#sseFraming [status=implemented hash=45da39c2e07a]
    public static func sseFraming(
        _ bytes: AsyncThrowingStream<[UInt8], Error>,
        events: Set<String>? = nil,
        includeDone: Bool = false
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var parser = SSEParser()
                do {
                    for try await chunk in bytes {
                        let parsed = parser.feed(chunk)
                        for ev in parsed where shouldEmitSSEEvent(ev, events: events, includeDone: includeDone) {
                            continuation.yield(ev.data)
                        }
                    }
                    let tail = parser.finish()
                    for ev in tail where shouldEmitSSEEvent(ev, events: events, includeDone: includeDone) {
                        continuation.yield(ev.data)
                    }
                    continuation.finish()
                } catch let aiError as AISchema.AIError {
                    continuation.finish(throwing: aiError)
                } catch {
                    continuation.finish(throwing: AISchema.AIError(reason: .invalidProviderOutput(
                        AISchema.InvalidProviderOutputError(
                            message: String(describing: error),
                            cause: String(describing: error),
                            route: "sse"
                        )
                    )))
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // parity: ai/src/route/framing.ts#sse [status=implemented hash=84cebc89097a]
    public static let sse = Definition<String>(id: "sse") { bytes in
        sseFraming(bytes, events: nil, includeDone: false)
    }

    // parity: ai/src/route/framing.ts#sseWithDone [status=implemented hash=29c5177f266d]
    public static let sseWithDone = Definition<String>(id: "sse") { bytes in
        sseFraming(bytes, events: nil, includeDone: true)
    }

    // parity: ai/src/route/framing.ts#sseEvents [status=implemented hash=716b5a7900f8]
    public static func sseEvents(_ events: Set<String>) -> Definition<String> {
        Definition<String>(id: "sse") { bytes in
            sseFraming(bytes, events: events, includeDone: false)
        }
    }

    // parity: ai/src/route/framing.ts#lines [status=implemented hash=2e1d4050152e]
    public static let lines = Definition<String>(id: "lines") { bytes in
        AsyncThrowingStream { continuation in
            let task = Task {
                var decoder = NDJSONLineDecoder()
                do {
                    for try await chunk in bytes {
                        for line in decoder.feed(chunk) {
                            if line.contains(where: { !$0.isWhitespace }) {
                                continuation.yield(line)
                            }
                        }
                    }
                    for line in decoder.finish() {
                        if line.contains(where: { !$0.isWhitespace }) {
                            continuation.yield(line)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // parity: ai/src/route/framing.ts#document [status=implemented hash=1bf881526cff]
    public static let document = Definition<String>(id: "document") { bytes in
        AsyncThrowingStream { continuation in
            let task = Task {
                var decoder = IncrementalUTF8Decoder()
                var full = ""
                do {
                    for try await chunk in bytes {
                        full += decoder.decode(chunk)
                    }
                    full += decoder.finish()
                    continuation.yield(full)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Request executor service, HTTP middleware composition, status/rate-limit diagnostics, and
/// streaming HTTP responses built strictly over `OpenCodePlatform.HTTPTransport`.
///
/// Ports `packages/ai/src/route/executor-service.ts` and `packages/ai/src/route/executor.ts`.
public enum AIRequestExecutor {
    /// Unified portable HTTP response carrying either buffered bytes or a live byte stream.
    public struct ExecutorResponse: Sendable {
        public enum Body: Sendable {
            case buffered([UInt8])
            case streaming(AsyncThrowingStream<[UInt8], Error>)
        }

        public let request: HTTPRequest
        public let head: HTTPResponseHead
        public let body: Body

        public var status: Int { head.statusCode }
        public var headers: [String: String] { head.headers }

        public init(request: HTTPRequest, response: HTTPResponse) {
            self.request = request
            self.head = response.head
            self.body = .buffered(response.body)
        }

        public init(request: HTTPRequest, streaming: HTTPStreamingResponse) {
            self.request = request
            self.head = streaming.head
            self.body = .streaming(streaming.chunks)
        }

        public init(request: HTTPRequest, head: HTTPResponseHead, body: Body) {
            self.request = request
            self.head = head
            self.body = body
        }

        public func bytes() async throws -> [UInt8] {
            switch body {
            case .buffered(let data):
                return data
            case .streaming(let stream):
                var chunks: [[UInt8]] = []
                for try await chunk in stream {
                    chunks.append(chunk)
                }
                return AIUtils.concatBytes(chunks)
            }
        }

        public func text() async throws -> String {
            let data = try await bytes()
            return String(decoding: data, as: UTF8.self)
        }

        public func byteStream() -> AsyncThrowingStream<[UInt8], Error> {
            switch body {
            case .buffered(let data):
                return AsyncThrowingStream { continuation in
                    if !data.isEmpty {
                        continuation.yield(data)
                    }
                    continuation.finish()
                }
            case .streaming(let stream):
                return stream
            }
        }
    }

    /// Wrapper for low-level transport/client failures carrying an optional system error code and cause.
    public struct ClientTransportError: Swift.Error, Sendable, CustomStringConvertible {
        public let request: HTTPRequest
        public let message: String
        public let code: String?
        public let isDecodeError: Bool
        public let isTimeout: Bool
        public let underlying: (any Error & Sendable)?

        public init(
            request: HTTPRequest,
            message: String,
            code: String? = nil,
            isDecodeError: Bool = false,
            isTimeout: Bool = false,
            underlying: (any Error & Sendable)? = nil
        ) {
            self.request = request
            self.message = message
            self.code = code
            self.isDecodeError = isDecodeError
            self.isTimeout = isTimeout
            self.underlying = underlying
        }

        public var description: String { message }
    }

    // parity: ai/src/route/executor-service.ts#HttpHandler [status=implemented hash=9e5d9b5c4fca]
    public typealias HttpHandler = @Sendable (HTTPRequest) async throws -> ExecutorResponse

    // parity: ai/src/route/executor-service.ts#HttpMiddleware [status=implemented hash=95a6a6a328c9]
    public typealias HttpMiddleware = @Sendable (HTTPRequest, @escaping HttpHandler) async throws -> ExecutorResponse

    // parity: ai/src/route/executor-service.ts#Interface [status=implemented hash=4c941054c83f]
    public protocol Interface: Sendable {
        func execute(_ request: HTTPRequest, middleware: HttpMiddleware?) async throws -> ExecutorResponse
    }

    // parity: ai/src/route/executor-service.ts#RequestExecutorService [status=implemented hash=7b7d6fecff64]
    public struct RequestExecutorService: Interface, Sendable {
        public static let serviceID = "@opencode/AI/RequestExecutor"
        private let runExecute: @Sendable (HTTPRequest, HttpMiddleware?) async throws -> ExecutorResponse

        public init(
            execute: @escaping @Sendable (HTTPRequest, HttpMiddleware?) async throws -> ExecutorResponse
        ) {
            self.runExecute = execute
        }

        public func execute(
            _ request: HTTPRequest,
            middleware: HttpMiddleware? = nil
        ) async throws -> ExecutorResponse {
            try await runExecute(request, middleware)
        }
    }

    // parity: ai/src/route/executor-service.ts#Service [status=implemented hash=ae70e600ec12]
    public typealias Service = RequestExecutorService

    // parity: ai/src/route/executor-service.ts#CurrentTls [status=adapted hash=2ca72f0baabf]
    @TaskLocal public static var CurrentTls: AISchema.ClientTls? = nil

    // parity: ai/src/route/executor-service.ts#CurrentTimeout [status=adapted hash=a0b006650511]
    @TaskLocal public static var CurrentTimeout: AISchema.RequestTimeout? = nil

    // parity: ai/src/route/executor-service.ts#CurrentMiddleware [status=adapted hash=0e1ebe5da380]
    @TaskLocal public static var CurrentMiddleware: HttpMiddleware? = nil

    /// `outer` wraps `inner`: it sees the request first and the response last.
    // parity: ai/src/route/executor-service.ts#composeMiddleware [status=implemented hash=b249512a5955]
    public static func composeMiddleware(
        _ outer: HttpMiddleware?,
        _ inner: HttpMiddleware?
    ) -> HttpMiddleware? {
        guard let outer else { return inner }
        guard let inner else { return outer }
        return { request, handler in
            try await outer(request) { forwarded in
                try await inner(forwarded, handler)
            }
        }
    }

    /// Runs `fn` on every provider request made inside `operation`.
    // parity: ai/src/route/executor-service.ts#withMiddleware [status=adapted hash=6cd1204d0e8d]
    public static func withMiddleware<T: Sendable>(
        _ fn: @escaping HttpMiddleware,
        operation: () async throws -> T
    ) async rethrows -> T {
        let merged = composeMiddleware(CurrentMiddleware, fn)
        return try await $CurrentMiddleware.withValue(merged, operation: operation)
    }

    // parity: ai/src/route/executor-service.ts#headerDetails [status=implemented hash=5a463006cabb]
    public static func headerDetails(_ headers: [String: String]) -> [String: String] {
        var normalized: [String: String] = [:]
        normalized.reserveCapacity(headers.count)
        for (name, value) in headers {
            normalized[name.lowercased()] = value
        }
        return normalized
    }

    // parity: ai/src/route/executor-service.ts#responseHttp [status=implemented hash=9163256bfc06]
    public static func responseHttp(_ response: ExecutorResponse) -> AISchema.HttpContext {
        AISchema.HttpContext(
            url: response.request.url,
            status: response.status,
            headers: headerDetails(response.headers)
        )
    }

    // parity: ai/src/route/executor-service.ts#HttpOperation [status=implemented hash=a44c5dbe3877]
    public enum HttpOperation: String, Equatable, Hashable, Sendable, Codable {
        case request
        case read

        public var asTransportOperation: AISchema.TransportOperation {
            switch self {
            case .request: .request
            case .read: .read
            }
        }
    }

    // parity: ai/src/route/executor-service.ts#rootCause [status=implemented hash=1ef1b595e805]
    public static func rootCause(_ error: any Error) -> any Error {
        if let clientErr = error as? ClientTransportError, let inner = clientErr.underlying {
            return rootCause(inner)
        }
        return error
    }

    private static let connectionLost = "Connection lost while reading the response"

    // parity: ai/src/route/executor-service.ts#httpError [status=implemented hash=d1c3bd86ebbe]
    public static func httpError(
        error: any Error,
        request: HTTPRequest,
        operation: HttpOperation,
        http: AISchema.HttpContext? = nil
    ) -> AISchema.AIError {
        if let aiError = error as? AISchema.AIError {
            return aiError
        }
        let clientErr = error as? ClientTransportError
        let effectiveRequest = clientErr?.request ?? request
        let source = rootCause(error)
        let sourceClientErr = source as? ClientTransportError
        let code = sourceClientErr?.code ?? clientErr?.code
        let baseMessage = sourceClientErr?.message ?? clientErr?.message ?? String(describing: error)
        let detail: String
        if let code, !baseMessage.contains(code) {
            detail = "\(code): \(baseMessage)"
        } else {
            detail = baseMessage
        }

        func makeTransportError(message: String, code: String?) -> AISchema.AIError {
            AISchema.AIError(reason: .transport(AISchema.TransportError(
                message: message,
                http: http,
                cause: String(describing: source),
                transport: .http,
                operation: operation.asTransportOperation,
                code: code,
                url: effectiveRequest.url
            )))
        }

        if clientErr?.isTimeout == true || sourceClientErr?.isTimeout == true {
            return makeTransportError(
                message: baseMessage.isEmpty ? "HTTP transport timed out" : detail,
                code: code ?? "Timeout"
            )
        }
        if operation == .read && clientErr?.isDecodeError == true {
            let msg = detail.isEmpty ? connectionLost : "\(connectionLost): \(detail)"
            return makeTransportError(message: msg, code: code)
        }
        return makeTransportError(
            message: detail.isEmpty ? "HTTP transport failed" : detail,
            code: code
        )
    }

    // parity: ai/src/route/executor-service.ts#responseStream [status=implemented hash=6838678c59e5]
    public static func responseStream(_ response: ExecutorResponse) -> AsyncThrowingStream<[UInt8], Error> {
        let http = responseHttp(response)
        let req = response.request
        let source = response.byteStream()
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await chunk in source {
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: httpError(error: error, request: req, operation: .read, http: http))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // parity: ai/src/route/executor-service.ts#responseBytes [status=implemented hash=ee4ddb8859e1]
    public static func responseBytes(_ response: ExecutorResponse) async throws -> [UInt8] {
        do {
            return try await response.bytes()
        } catch {
            throw httpError(error: error, request: response.request, operation: .read, http: responseHttp(response))
        }
    }

    // parity: ai/src/route/executor-service.ts#responseText [status=implemented hash=ff75dfa6b080]
    public static func responseText(_ response: ExecutorResponse) async throws -> String {
        do {
            return try await response.text()
        } catch {
            throw httpError(error: error, request: response.request, operation: .read, http: responseHttp(response))
        }
    }

    // MARK: - src/route/executor.ts

    private static let maxBodyChars = 2000

    private static func clampRetryAfterMs(_ millis: Double) -> Int {
        guard millis.isFinite else { return 0 }
        let clamped = max(0, ceil(millis))
        if clamped >= Double(Int.max) { return Int.max }
        return Int(clamped)
    }

    /// Parses `retry-after-ms` and `retry-after` (seconds or IMF-fixdate HTTP date) into milliseconds.
    public static func parseRetryAfterMs(headers: [String: String], nowEpochMs: Double? = nil) -> Int? {
        if let rawMs = headers["retry-after-ms"], let ms = Double(rawMs.trimmingCharacters(in: .whitespaces)), ms.isFinite {
            return clampRetryAfterMs(ms)
        }
        guard let raw = headers["retry-after"]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return nil
        }
        if let seconds = Double(raw), seconds.isFinite {
            return clampRetryAfterMs(seconds * 1000.0)
        }
        if let epochMs = parseHTTPDateEpochMs(raw) {
            let now = nowEpochMs ?? (Date().timeIntervalSince1970 * 1000.0)
            return clampRetryAfterMs(epochMs - now)
        }
        return nil
    }

    /// Pure portable RFC 7231 IMF-fixdate parser (e.g. `"Wed, 21 Oct 2015 07:28:00 GMT"`).
    internal static func parseHTTPDateEpochMs(_ raw: String) -> Double? {
        let months: [String: Int] = [
            "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
            "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12,
        ]
        // Tokenize on spaces and commas: e.g. ["Wed", "21", "Oct", "2015", "07:28:00", "GMT"]
        let tokens = raw.split { $0 == " " || $0 == "," || $0 == "\t" }.map(String.init)
        guard tokens.count >= 5 else { return nil }
        let day: Int
        let month: Int
        let year: Int
        let timeToken: String
        if let d = Int(tokens[1]), let m = months[tokens[2].lowercased()], let y = Int(tokens[3]) {
            day = d
            month = m
            year = y
            timeToken = tokens[4]
        } else {
            return nil
        }
        let hms = timeToken.split(separator: ":").compactMap { Int($0) }
        guard hms.count == 3 else { return nil }
        let (hour, minute, second) = (hms[0], hms[1], hms[2])
        guard (1...31).contains(day), (0...23).contains(hour), (0...59).contains(minute), (0...60).contains(second) else {
            return nil
        }
        // Civil-from-days inverse (Howard Hinnant algorithm) — pure arithmetic, zero Calendar/Locale dependencies.
        let adjY = month <= 2 ? year - 1 : year
        let era = (adjY >= 0 ? adjY : adjY - 399) / 400
        let yoe = adjY - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let daysSinceEpoch = era * 146_097 + doe - 719_468
        let totalSeconds = Int64(daysSinceEpoch) * 86_400 + Int64(hour * 3600 + minute * 60 + second)
        return Double(totalSeconds) * 1000.0
    }

    public static func parseRateLimitDetails(headers: [String: String], retryAfter: Int?) -> AISchema.HttpRateLimitDetails? {
        var limit: [String: String] = [:]
        var remaining: [String: String] = [:]
        var reset: [String: String] = [:]

        for (name, value) in headers {
            if name.hasPrefix("x-ratelimit-limit-") {
                let key = String(name.dropFirst("x-ratelimit-limit-".count))
                if !key.isEmpty { limit[key] = value }
            } else if name.hasPrefix("x-ratelimit-remaining-") {
                let key = String(name.dropFirst("x-ratelimit-remaining-".count))
                if !key.isEmpty { remaining[key] = value }
            } else if name.hasPrefix("x-ratelimit-reset-") {
                let key = String(name.dropFirst("x-ratelimit-reset-".count))
                if !key.isEmpty { reset[key] = value }
            } else if name.hasPrefix("anthropic-ratelimit-") {
                let rest = String(name.dropFirst("anthropic-ratelimit-".count))
                if rest.hasSuffix("-limit") {
                    let key = String(rest.dropLast("-limit".count))
                    if !key.isEmpty { limit[key] = value }
                } else if rest.hasSuffix("-remaining") {
                    let key = String(rest.dropLast("-remaining".count))
                    if !key.isEmpty { remaining[key] = value }
                } else if rest.hasSuffix("-reset") {
                    let key = String(rest.dropLast("-reset".count))
                    if !key.isEmpty { reset[key] = value }
                }
            }
        }

        if retryAfter == nil && limit.isEmpty && remaining.isEmpty && reset.isEmpty {
            return nil
        }

        return AISchema.HttpRateLimitDetails(
            retryAfterMs: retryAfter,
            limit: limit.isEmpty ? nil : limit,
            remaining: remaining.isEmpty ? nil : remaining,
            reset: reset.isEmpty ? nil : reset
        )
    }

    private static func providerMessage(status: Int, body: String?) -> String {
        let fallback = "Provider request failed with HTTP \(status)"
        let text = body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let extracted = AIErrorClassifier.providerErrorMessage(text) {
            return extracted
        }
        let lowerPrefix = text.prefix(16).lowercased()
        if text.isEmpty || lowerPrefix.hasPrefix("<!doctype") || lowerPrefix.hasPrefix("<html") {
            return fallback
        }
        if text.count > maxBodyChars {
            return "\(fallback): \(text.prefix(maxBodyChars))…"
        }
        return "\(fallback): \(text)"
    }

    /// Preserve HTTP diagnostics for executor and externally captured failures alike.
    // parity: ai/src/route/executor.ts#httpFailure [status=implemented hash=8f72ff57fa65]
    public static func httpFailure(
        message: String,
        url: String? = nil,
        status: Int? = nil,
        data: JSONValue? = nil,
        responseHeaders: [String: String]? = nil,
        responseBody: String? = nil,
        cause: String? = nil,
        nowEpochMs: Double? = nil
    ) -> AISchema.AIError {
        let headers = headerDetails(responseHeaders ?? [:])
        let retryAfter = parseRetryAfterMs(headers: headers, nowEpochMs: nowEpochMs)
        let rateLimit = parseRateLimitDetails(headers: headers, retryAfter: retryAfter)
        let httpContext: AISchema.HttpContext? = if let status, let url {
            AISchema.HttpContext(url: url, status: status, headers: headers)
        } else {
            nil
        }
        return AISchema.AIError(reason: AIErrorClassifier.classifyProviderFailure(
            AIErrorClassifier.ProviderFailure(
                message: message,
                status: status,
                rawBody: responseBody,
                data: data,
                http: httpContext,
                cause: cause,
                retryAfterMs: retryAfter,
                rateLimit: rateLimit
            )
        ))
    }

    // parity: ai/src/route/executor.ts#stream [status=implemented hash=5d4e4b85f16d]
    public static func stream(
        executor: any Interface,
        request: HTTPRequest,
        middleware: HttpMiddleware? = nil
    ) -> AsyncThrowingStream<[UInt8], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await executor.execute(request, middleware: middleware)
                    for try await chunk in responseStream(response) {
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Build a `RequestExecutorService` over any portable `OpenCodePlatform.HTTPTransport`.
    // parity: ai/src/route/executor.ts#layer [status=adapted hash=bda12dc466e7]
    public static func layer(transport: any HTTPTransport) -> RequestExecutorService {
        RequestExecutorService { request, nextMiddleware in
            let composed = composeMiddleware(CurrentMiddleware, nextMiddleware)
            let timeout = CurrentTimeout
            return try await $CurrentMiddleware.withValue(nil) {
                try await $CurrentTimeout.withValue(nil) {
                    try await executeOnce(
                        transport: transport,
                        request: request,
                        middleware: composed,
                        timeout: timeout
                    )
                }
            }
        }
    }

    private static let noBodyStatuses: Set<Int> = [101, 204, 205, 304]

    private static func timeoutMillis(
        _ value: AISchema.HttpTimeout?,
        fallback: Double? = nil
    ) -> Double? {
        switch value {
        case .disabled:
            return nil
        case .milliseconds(let ms) where ms.isFinite && ms > 0:
            return ms
        case .milliseconds:
            return nil
        case .none:
            return fallback
        }
    }

    private static func timeoutError(
        url: String,
        operation: HttpOperation,
        message: String,
        http: AISchema.HttpContext? = nil
    ) -> AISchema.AIError {
        AISchema.AIError(reason: .transport(AISchema.TransportError(
            message: message,
            http: http,
            transport: .http,
            operation: operation.asTransportOperation,
            code: "Timeout",
            url: url
        )))
    }

    private static func raceWithTimeout<T: Sendable>(
        ms: Double?,
        onTimeout: @escaping @Sendable () -> AISchema.AIError,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard let ms else {
            return try await operation()
        }
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: .milliseconds(ms))
                throw onTimeout()
            }
            guard let result = try await group.next() else {
                throw onTimeout()
            }
            group.cancelAll()
            return result
        }
    }

    private final class StreamTimeoutCoordinator: Sendable {
        private struct State: Sendable {
            var completed = false
            var readerTask: Task<Void, Never>?
            var chunkTimerTask: Task<Void, Never>?
            var totalTimerTask: Task<Void, Never>?
        }

        private let state = Mutex(State())
        private let continuation: AsyncThrowingStream<[UInt8], Error>.Continuation

        init(continuation: AsyncThrowingStream<[UInt8], Error>.Continuation) {
            self.continuation = continuation
        }

        func setReaderTask(_ task: Task<Void, Never>) {
            let shouldCancel = state.withLock { s -> Bool in
                if s.completed { return true }
                s.readerTask = task
                return false
            }
            if shouldCancel { task.cancel() }
        }

        func setTotalTimerTask(_ task: Task<Void, Never>) {
            let shouldCancel = state.withLock { s -> Bool in
                if s.completed { return true }
                s.totalTimerTask = task
                return false
            }
            if shouldCancel { task.cancel() }
        }

        func resetChunkTimer(ms: Double, error: AISchema.AIError) {
            let previous = state.withLock { s -> Task<Void, Never>? in
                guard !s.completed else { return nil }
                let old = s.chunkTimerTask
                s.chunkTimerTask = Task { [weak self] in
                    do {
                        try await Task.sleep(for: .milliseconds(ms))
                    } catch {
                        return
                    }
                    self?.finishFailure(error, cancelReader: true)
                }
                return old
            }
            previous?.cancel()
        }

        func yield(_ chunk: [UInt8]) {
            let active = state.withLock { !$0.completed }
            if active {
                continuation.yield(chunk)
            }
        }

        func finishSuccess() {
            let tasks = state.withLock { s -> [Task<Void, Never>]? in
                guard !s.completed else { return nil }
                s.completed = true
                let toCancel = [s.chunkTimerTask, s.totalTimerTask].compactMap { $0 }
                s.chunkTimerTask = nil
                s.totalTimerTask = nil
                s.readerTask = nil
                return toCancel
            }
            guard let tasks else { return }
            for task in tasks { task.cancel() }
            continuation.finish()
        }

        func finishFailure(_ error: any Error, cancelReader: Bool) {
            let tasks = state.withLock { s -> [Task<Void, Never>]? in
                guard !s.completed else { return nil }
                s.completed = true
                var toCancel = [s.chunkTimerTask, s.totalTimerTask].compactMap { $0 }
                if cancelReader, let reader = s.readerTask {
                    toCancel.append(reader)
                }
                s.chunkTimerTask = nil
                s.totalTimerTask = nil
                s.readerTask = nil
                return toCancel
            }
            guard let tasks else { return }
            for task in tasks { task.cancel() }
            continuation.finish(throwing: error)
        }

        func cancelAll() {
            let tasks = state.withLock { s -> [Task<Void, Never>] in
                s.completed = true
                let toCancel = [s.chunkTimerTask, s.totalTimerTask, s.readerTask].compactMap { $0 }
                s.chunkTimerTask = nil
                s.totalTimerTask = nil
                s.readerTask = nil
                return toCancel
            }
            for task in tasks { task.cancel() }
        }
    }

    private static func withBodyTimeouts(
        _ raw: ExecutorResponse,
        chunkTimeoutMs: Double?,
        deadline: ContinuousClock.Instant?
    ) -> ExecutorResponse {
        guard !noBodyStatuses.contains(raw.status),
              chunkTimeoutMs != nil || deadline != nil,
              case .streaming(let source) = raw.body
        else {
            return raw
        }

        let http = responseHttp(raw)
        let url = raw.request.url
        let wrapped = AsyncThrowingStream<[UInt8], Error> { continuation in
            let coordinator = StreamTimeoutCoordinator(continuation: continuation)
            let chunkError = timeoutError(
                url: url,
                operation: .read,
                message: "Timed out waiting for response data",
                http: http
            )
            let totalError = timeoutError(
                url: url,
                operation: .read,
                message: "Timed out waiting for the response to complete",
                http: http
            )

            if let deadline {
                let remaining = ContinuousClock.now.duration(to: deadline)
                if remaining <= .zero {
                    coordinator.finishFailure(totalError, cancelReader: true)
                    return
                }
                let totalTask = Task {
                    do {
                        try await Task.sleep(for: remaining)
                    } catch {
                        return
                    }
                    coordinator.finishFailure(totalError, cancelReader: true)
                }
                coordinator.setTotalTimerTask(totalTask)
            }

            if let chunkTimeoutMs {
                coordinator.resetChunkTimer(ms: chunkTimeoutMs, error: chunkError)
            }

            let readerTask = Task {
                do {
                    for try await chunk in source {
                        if Task.isCancelled { return }
                        if let chunkTimeoutMs {
                            coordinator.resetChunkTimer(ms: chunkTimeoutMs, error: chunkError)
                        }
                        coordinator.yield(chunk)
                    }
                    if !Task.isCancelled {
                        coordinator.finishSuccess()
                    }
                } catch is CancellationError {
                    return
                } catch {
                    coordinator.finishFailure(error, cancelReader: false)
                }
            }
            coordinator.setReaderTask(readerTask)

            continuation.onTermination = { _ in
                coordinator.cancelAll()
            }
        }
        return ExecutorResponse(request: raw.request, head: raw.head, body: .streaming(wrapped))
    }

    private static func executeOnce(
        transport: any HTTPTransport,
        request: HTTPRequest,
        middleware: HttpMiddleware?,
        timeout: AISchema.RequestTimeout?
    ) async throws -> ExecutorResponse {
        let started = ContinuousClock.now
        let limits = AISchema.timeoutConfig(timeout)
        // Unlike header and chunk limits, the whole-request budget has no default.
        let totalMs = timeoutMillis(limits.total, fallback: nil)
        let headersMs = timeoutMillis(limits.headers, fallback: AISchema.DEFAULT_HTTP_TIMEOUT_MS)
        let chunkMs = timeoutMillis(limits.chunk, fallback: AISchema.DEFAULT_CHUNK_TIMEOUT_MS)
        let headersLimitMs: Double? = switch (headersMs, totalMs) {
        case let (h?, t?): min(h, t)
        case let (h?, nil): h
        case let (nil, t?): t
        case (nil, nil): nil
        }

        let baseHandler: HttpHandler = { req in
            let streaming = try await transport.stream(req)
            return ExecutorResponse(request: req, streaming: streaming)
        }
        let raw: ExecutorResponse
        do {
            raw = try await raceWithTimeout(
                ms: headersLimitMs,
                onTimeout: {
                    timeoutError(
                        url: request.url,
                        operation: .request,
                        message: "Timed out waiting for response headers"
                    )
                },
                operation: {
                    if let middleware {
                        return try await middleware(request, baseHandler)
                    } else {
                        return try await baseHandler(request)
                    }
                }
            )
        } catch let aiError as AISchema.AIError {
            throw aiError
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw httpError(error: error, request: request, operation: .request)
        }

        let deadline: ContinuousClock.Instant? = totalMs.map { started.advanced(by: .milliseconds($0)) }
        let timedResponse = withBodyTimeouts(raw, chunkTimeoutMs: chunkMs, deadline: deadline)

        if timedResponse.status < 400 {
            return timedResponse
        }

        var bodyText: String? = nil
        var readCause: String? = nil
        do {
            bodyText = try await timedResponse.text()
        } catch {
            readCause = String(describing: rootCause(error))
        }
        throw httpFailure(
            message: providerMessage(status: timedResponse.status, body: bodyText),
            url: timedResponse.request.url,
            status: timedResponse.status,
            responseHeaders: timedResponse.headers,
            responseBody: bodyText,
            cause: readCause
        )
    }

    /// Default unavailable transport layer unless an explicit `OpenCodePlatform.HTTPTransport` is injected.
    // parity: ai/src/route/executor.ts#fetchLayer [status=adapted hash=083eb2d26496]
    public static func fetchLayer(transport: any HTTPTransport) -> RequestExecutorService {
        layer(transport: transport)
    }

    // parity: ai/src/route/executor.ts#withTls [status=implemented hash=f5d983ff6896]
    public static func withTls(
        _ execute: @escaping @Sendable (HTTPRequest, HttpMiddleware?) async throws -> ExecutorResponse,
        tls: AISchema.ClientTls?
    ) -> @Sendable (HTTPRequest, HttpMiddleware?) async throws -> ExecutorResponse {
        guard let tls else { return execute }
        return { request, middleware in
            try await $CurrentTls.withValue(tls) {
                try await execute(request, middleware)
            }
        }
    }

    // parity: ai/src/route/executor.ts#withTimeout [status=implemented hash=653a373ca095]
    public static func withTimeout(
        _ execute: @escaping @Sendable (HTTPRequest, HttpMiddleware?) async throws -> ExecutorResponse,
        timeout: AISchema.RequestTimeout?
    ) -> @Sendable (HTTPRequest, HttpMiddleware?) async throws -> ExecutorResponse {
        guard let timeout else { return execute }
        return { request, middleware in
            try await $CurrentTimeout.withValue(timeout) {
                try await execute(request, middleware)
            }
        }
    }

    // parity: ai/src/route/executor.ts#withFetch [status=adapted hash=f17899621a4f]
    public static func withFetch(
        _ fetch: (any HTTPTransport)?,
        middleware: HttpMiddleware? = nil
    ) -> HttpMiddleware? {
        guard let fetch else { return middleware }
        let send: HttpHandler = { request in
            let streaming = try await fetch.stream(request)
            return ExecutorResponse(request: request, streaming: streaming)
        }
        guard let middleware else {
            return { request, _ in try await send(request) }
        }
        return { request, _ in
            try await middleware(request, send)
        }
    }

    /// Wraps an executor so `fn` runs around every request before status classification.
    // parity: ai/src/route/executor.ts#middleware [status=implemented hash=274e23b7ef33]
    public static func middleware(
        _ fn: @escaping HttpMiddleware,
        executor: RequestExecutorService
    ) -> RequestExecutorService {
        RequestExecutorService { request, next in
            let scoped = composeMiddleware(CurrentMiddleware, next)
            let merged = composeMiddleware(fn, scoped)
            return try await $CurrentMiddleware.withValue(nil) {
                try await executor.execute(request, middleware: merged)
            }
        }
    }
}

/// Transport abstractions for HTTP-JSON and WebSocket route execution.
/// Ports `packages/ai/src/route/transport/{index,http,websocket-channel,websocket}.ts`.
public enum AITransport {

    // MARK: - src/route/transport/index.ts

    // parity: ai/src/route/transport/index.ts#TransportRuntime [status=implemented hash=a79fd760046c]
    public struct TransportRuntime: Sendable {
        public let http: AIRequestExecutor.RequestExecutorService

        public init(http: AIRequestExecutor.RequestExecutorService) {
            self.http = http
        }
    }

    // parity: ai/src/route/transport/index.ts#TransportExecution [status=implemented hash=85a73a583eeb]
    public struct TransportExecution<Frame: Sendable>: Sendable {
        public let frames: AsyncThrowingStream<Frame, Error>
        public let http: AISchema.HttpContext?
        public let body: (@Sendable (Frame) -> String?)?
        public let raw: (@Sendable (Frame) -> JSONValue?)?
        public let complete: (@Sendable () async -> Void)?

        public init(
            frames: AsyncThrowingStream<Frame, Error>,
            http: AISchema.HttpContext? = nil,
            body: (@Sendable (Frame) -> String?)? = nil,
            raw: (@Sendable (Frame) -> JSONValue?)? = nil,
            complete: (@Sendable () async -> Void)? = nil
        ) {
            self.frames = frames
            self.http = http
            self.body = body
            self.raw = raw
            self.complete = complete
        }
    }

    // parity: ai/src/route/transport/index.ts#TransportExecuteOptions [status=implemented hash=a3f22600ac4c]
    public struct TransportExecuteOptions: Sendable {
        public let webSocket: WebSocketChannelExecutor?

        public init(webSocket: WebSocketChannelExecutor? = nil) {
            self.webSocket = webSocket
        }
    }

    // parity: ai/src/route/transport/index.ts#TransportPrepareInput [status=implemented hash=131aff31760e]
    public struct TransportPrepareInput<Body: Sendable>: Sendable {
        public let body: Body
        public let request: AISchema.LLMRequest
        public let endpoint: AIEndpoint.Definition<Body, AISchema.LLMRequest>
        public let auth: AIAuth.Definition
        public let encodeBody: @Sendable (Body) throws -> String
        public let headers: (@Sendable (AISchema.LLMRequest) -> [String: String])?
        public let middleware: AIRequestExecutor.HttpMiddleware?
        public let webSocket: WebSocketChannelExecutor?

        public init(
            body: Body,
            request: AISchema.LLMRequest,
            endpoint: AIEndpoint.Definition<Body, AISchema.LLMRequest>,
            auth: AIAuth.Definition,
            encodeBody: @escaping @Sendable (Body) throws -> String,
            headers: (@Sendable (AISchema.LLMRequest) -> [String: String])? = nil,
            middleware: AIRequestExecutor.HttpMiddleware? = nil,
            webSocket: WebSocketChannelExecutor? = nil
        ) {
            self.body = body
            self.request = request
            self.endpoint = endpoint
            self.auth = auth
            self.encodeBody = encodeBody
            self.headers = headers
            self.middleware = middleware
            self.webSocket = webSocket
        }
    }

    // parity: ai/src/route/transport/index.ts#Transport [status=implemented hash=2d85a1593348]
    public struct Transport<Body: Sendable, Prepared: Sendable, Frame: Sendable>: Sendable {
        public let id: String
        public let prepare: @Sendable (TransportPrepareInput<Body>) async throws -> Prepared
        public let execute: @Sendable (
            Prepared,
            AISchema.LLMRequest,
            TransportRuntime,
            TransportExecuteOptions?
        ) async throws -> TransportExecution<Frame>

        public init(
            id: String,
            prepare: @escaping @Sendable (TransportPrepareInput<Body>) async throws -> Prepared,
            execute: @escaping @Sendable (
                Prepared,
                AISchema.LLMRequest,
                TransportRuntime,
                TransportExecuteOptions?
            ) async throws -> TransportExecution<Frame>
        ) {
            self.id = id
            self.prepare = prepare
            self.execute = execute
        }
    }

    // MARK: - src/route/transport/http.ts

    // parity: ai/src/route/transport/http.ts#JsonRequestInput [status=implemented hash=423bc7ab407e]
    public typealias JsonRequestInput<Body: Sendable> = TransportPrepareInput<Body>

    // parity: ai/src/route/transport/http.ts#JsonRequestParts [status=implemented hash=558c0090f3fd]
    public struct JsonRequestParts: Sendable {
        public let url: String
        public let jsonBody: JSONValue
        public let bodyText: String
        public let headers: [String: String]

        public init(url: String, jsonBody: JSONValue, bodyText: String, headers: [String: String]) {
            self.url = url
            self.jsonBody = jsonBody
            self.bodyText = bodyText
            self.headers = headers
        }
    }

    // parity: ai/src/route/transport/http.ts#HttpPrepared [status=implemented hash=f0e01600f1fb]
    public struct HttpPrepared<Frame: Sendable>: Sendable {
        public let request: HTTPRequest
        public let framing: AIFraming.Definition<Frame>
        public let middleware: AIRequestExecutor.HttpMiddleware?

        public init(
            request: HTTPRequest,
            framing: AIFraming.Definition<Frame>,
            middleware: AIRequestExecutor.HttpMiddleware? = nil
        ) {
            self.request = request
            self.framing = framing
            self.middleware = middleware
        }
    }

    // parity: ai/src/route/transport/http.ts#jsonRequestParts [status=implemented hash=8d5c45abca73]
    public static func jsonRequestParts<Body: Sendable>(
        _ input: JsonRequestInput<Body>
    ) async throws -> JsonRequestParts {
        var url = try AIEndpoint.render(
            input.endpoint,
            input: AIEndpoint.EndpointInput(request: input.request, body: input.body)
        )
        if let extraQuery = input.request.http?.query, !extraQuery.isEmpty {
            let pairs = extraQuery.keys.sorted().compactMap { key -> (String, [String])? in
                extraQuery[key].map { (key, [$0]) }
            }
            url = AIEndpoint.setQueryParams(url, query: pairs)
        }
        let encodedBody: String
        do {
            encodedBody = try input.encodeBody(input.body)
        } catch {
            throw AISchema.AIError(reason: .invalidRequest(AISchema.InvalidRequestError(
                message: "Failed to encode request body: \(error)"
            )))
        }
        let decodedJson: JSONValue
        do {
            decodedJson = try AIUtils.decodeJson(encodedBody)
        } catch {
            decodedJson = .string(encodedBody)
        }

        let finalJson: JSONValue
        let finalText: String
        if let overlay = input.request.http?.body {
            guard case .object(let baseObj) = decodedJson else {
                throw AISchema.AIError(reason: .invalidRequest(AISchema.InvalidRequestError(
                    message: "http.body can only overlay JSON object request bodies"
                )))
            }
            let merged = AISchema.mergeJsonRecords(baseObj, overlay) ?? [:]
            finalJson = .object(merged)
            do {
                finalText = try AIUtils.encodeJson(finalJson)
            } catch {
                throw AISchema.AIError(reason: .invalidRequest(AISchema.InvalidRequestError(
                    message: "Failed to encode overlaid JSON body: \(error)"
                )))
            }
        } else {
            finalJson = decodedJson
            finalText = encodedBody
        }

        var mergedHeaders: [String: String] = [:]
        if let routeHeaders = input.headers?(input.request) {
            for (k, v) in routeHeaders { mergedHeaders[k.lowercased()] = v }
        }
        if let reqHeaders = input.request.headers {
            for (k, v) in reqHeaders { mergedHeaders[k.lowercased()] = v }
        }

        let signedHeaders = try await AIAuth.toEffect(input.auth)(AIAuth.AuthInput(
            httpOptions: input.request.http,
            method: .POST,
            url: url.absoluteString,
            body: finalText,
            headers: mergedHeaders
        ))

        return JsonRequestParts(
            url: url.absoluteString,
            jsonBody: finalJson,
            bodyText: finalText,
            headers: signedHeaders
        )
    }

    // parity: ai/src/route/transport/http.ts#HttpJsonInput [status=implemented hash=9b09b07acb2a]
    public struct HttpJsonInput<Frame: Sendable>: Sendable {
        public let framing: AIFraming.Definition<Frame>

        public init(framing: AIFraming.Definition<Frame>) {
            self.framing = framing
        }
    }

    // parity: ai/src/route/transport/http.ts#HttpJsonPatch [status=implemented hash=55d52f7f50ed]
    public struct HttpJsonPatch<Frame: Sendable>: Sendable {
        public let framing: AIFraming.Definition<Frame>?

        public init(framing: AIFraming.Definition<Frame>? = nil) {
            self.framing = framing
        }
    }

    // parity: ai/src/route/transport/http.ts#HttpJsonTransport [status=implemented hash=50c6501b429a]
    public struct HttpJsonTransport<Body: Sendable, Frame: Sendable>: Sendable {
        public let transport: Transport<Body, HttpPrepared<Frame>, Frame>
        public let framing: AIFraming.Definition<Frame>

        public init(framing: AIFraming.Definition<Frame>) {
            self.framing = framing
            self.transport = Transport(
                id: "http-json",
                prepare: { prepareInput in
                    let parts = try await jsonRequestParts(prepareInput)
                    var headers = parts.headers
                    if !headers.keys.contains(where: { $0.lowercased() == "content-type" }) {
                        headers["content-type"] = "application/json"
                    }
                    let req = HTTPRequest(
                        method: "POST",
                        url: parts.url,
                        headers: headers,
                        body: Array(parts.bodyText.utf8)
                    )
                    return HttpPrepared(
                        request: req,
                        framing: framing,
                        middleware: prepareInput.middleware
                    )
                },
                execute: { prepared, request, runtime, _ in
                    let execFn = AIRequestExecutor.withTimeout(
                        AIRequestExecutor.withTls(
                            { req, mw in try await runtime.http.execute(req, middleware: mw) },
                            tls: request.http?.tls
                        ),
                        timeout: request.timeout
                    )
                    let response = try await execFn(prepared.request, prepared.middleware)
                    return TransportExecution(
                        frames: prepared.framing.frame(AIRequestExecutor.responseStream(response)),
                        http: AIRequestExecutor.responseHttp(response),
                        body: prepared.framing.body,
                        raw: prepared.framing.raw
                    )
                }
            )
        }

        public func with(_ patch: HttpJsonPatch<Frame>) -> HttpJsonTransport<Body, Frame> {
            HttpJsonTransport(framing: patch.framing ?? framing)
        }
    }

    // parity: ai/src/route/transport/http.ts#httpJson [status=implemented hash=4f484d20d313]
    public static func httpJson<Body: Sendable, Frame: Sendable>(
        _ input: HttpJsonInput<Frame>
    ) -> HttpJsonTransport<Body, Frame> {
        HttpJsonTransport(framing: input.framing)
    }

    // parity: ai/src/route/transport/http.ts#sseJson [status=implemented hash=a69b447884c2]
    public enum sseJson {
        public static let id = "http-json/sse"

        public static func with<Body: Sendable>() -> HttpJsonTransport<Body, String> {
            httpJson(HttpJsonInput(framing: AIFraming.sse))
        }
    }

    // MARK: - src/route/transport/websocket-channel.ts

    // parity: ai/src/route/transport/websocket-channel.ts#ChannelCheckpoint [status=implemented hash=5dd4781e19af]
    public struct ChannelCheckpoint: Equatable, Hashable, Sendable, Codable {
        public let protocolID: String
        public let value: JSONValue

        public init(protocolID: String, value: JSONValue) {
            self.protocolID = protocolID
            self.value = value
        }

        enum CodingKeys: String, CodingKey {
            case protocolID = "protocol"
            case value
        }
    }

    // parity: ai/src/route/transport/websocket-channel.ts#ChannelCreate [status=implemented hash=aa4b0a98cbb9]
    public struct ChannelCreate: Equatable, Hashable, Sendable, Codable {
        public enum Mode: String, Equatable, Hashable, Sendable, Codable {
            case full
            case incremental
        }

        public let message: String
        public let mode: Mode

        public init(message: String, mode: Mode) {
            self.message = message
            self.mode = mode
        }
    }

    // parity: ai/src/route/transport/websocket-channel.ts#ChannelObservation [status=implemented hash=b71f594d94f1]
    public enum ChannelObservation: Equatable, Sendable {
        public enum RejectionRecovery: String, Equatable, Hashable, Sendable {
            case retryFull = "retry-full"
            case rotateAndRetryFull = "rotate-and-retry-full"
        }

        case frame(String)
        case completed(frame: String, checkpoint: ChannelCheckpoint?)
        case incomplete(frame: String)
        case providerFailure(AISchema.AIError)
        case rejected(error: AISchema.AIError, recovery: RejectionRecovery)

        public var isTerminal: Bool {
            if case .frame = self { return false }
            return true
        }
    }

    // parity: ai/src/route/transport/websocket-channel.ts#WebSocketChannelDriver [status=implemented hash=76d9111f8fc7]
    public struct WebSocketChannelDriver: Sendable {
        public let create: @Sendable (ChannelCheckpoint?) async throws -> ChannelCreate
        public let observe: @Sendable (ChannelCreate, String) async throws -> ChannelObservation

        public init(
            create: @escaping @Sendable (ChannelCheckpoint?) async throws -> ChannelCreate,
            observe: @escaping @Sendable (ChannelCreate, String) async throws -> ChannelObservation
        ) {
            self.create = create
            self.observe = observe
        }
    }

    // parity: ai/src/route/transport/websocket-channel.ts#WebSocketChannelExchange [status=implemented hash=0ad74c285bba]
    public struct WebSocketChannelExchange: Sendable {
        public struct Connect: Equatable, Hashable, Sendable {
            public let url: String
            public let headers: [String: String]
            public let rotateAfterMs: Int?

            public init(url: String, headers: [String: String] = [:], rotateAfterMs: Int? = nil) {
                self.url = url
                self.headers = headers
                self.rotateAfterMs = rotateAfterMs
            }
        }

        public let id: String
        public let connect: Connect
        public let fallback: @Sendable () -> AsyncThrowingStream<String, Error>
        public let driver: WebSocketChannelDriver

        public init(
            id: String,
            connect: Connect,
            fallback: @escaping @Sendable () -> AsyncThrowingStream<String, Error>,
            driver: WebSocketChannelDriver
        ) {
            self.id = id
            self.connect = connect
            self.fallback = fallback
            self.driver = driver
        }
    }

    // parity: ai/src/route/transport/websocket-channel.ts#WebSocketChannelExecution [status=implemented hash=38cac437bc8c]
    public struct WebSocketChannelExecution: Sendable {
        public let frames: AsyncThrowingStream<String, Error>
        public let http: AISchema.HttpContext?
        public let complete: @Sendable () async -> Void

        public init(
            frames: AsyncThrowingStream<String, Error>,
            http: AISchema.HttpContext? = nil,
            complete: @escaping @Sendable () async -> Void = {}
        ) {
            self.frames = frames
            self.http = http
            self.complete = complete
        }
    }

    // parity: ai/src/route/transport/websocket-channel.ts#WebSocketChannelExecutor [status=implemented hash=98873b2059d3]
    public struct WebSocketChannelExecutor: Sendable {
        public let execute: @Sendable (WebSocketChannelExchange) async throws -> WebSocketChannelExecution

        public init(
            execute: @escaping @Sendable (WebSocketChannelExchange) async throws -> WebSocketChannelExecution
        ) {
            self.execute = execute
        }
    }

    // MARK: - src/route/transport/websocket.ts

    // parity: ai/src/route/transport/websocket.ts#WebSocketRequest [status=implemented hash=b89f85d3a798]
    public struct WebSocketRequest: Equatable, Hashable, Sendable {
        public let url: String
        public let headers: [String: String]

        public init(url: String, headers: [String: String] = [:]) {
            self.url = url
            self.headers = headers
        }
    }

    public enum WebSocketMessage: Equatable, Sendable {
        case text(String)
        case binary([UInt8])
    }

    // parity: ai/src/route/transport/websocket.ts#WebSocketConnection [status=implemented hash=330750fd6adf]
    public struct WebSocketConnection: Sendable {
        public let http: AISchema.HttpContext?
        public let sendText: @Sendable (String) async throws -> Void
        public let messages: AsyncThrowingStream<WebSocketMessage, Error>
        public let close: @Sendable () async -> Void

        public init(
            http: AISchema.HttpContext? = nil,
            sendText: @escaping @Sendable (String) async throws -> Void,
            messages: AsyncThrowingStream<WebSocketMessage, Error>,
            close: @escaping @Sendable () async -> Void
        ) {
            self.http = http
            self.sendText = sendText
            self.messages = messages
            self.close = close
        }
    }

    // parity: ai/src/route/transport/websocket.ts#WebSocketConnector [status=implemented hash=f20eb3a2b6af]
    public struct WebSocketConnector: Sendable {
        public let open: @Sendable (WebSocketRequest) async throws -> WebSocketConnection

        public init(open: @escaping @Sendable (WebSocketRequest) async throws -> WebSocketConnection) {
            self.open = open
        }
    }

    public static let maxWebSocketFrameBytes = 16 * 1024 * 1024

    // parity: ai/src/route/transport/websocket.ts#toWebSocketUrl [status=implemented hash=a161b460c4b6]
    public static func toWebSocketUrl(_ value: String) throws(AISchema.AIError) -> String {
        guard var components = URLComponents(string: value), let scheme = components.scheme?.lowercased() else {
            throw AISchema.AIError(reason: .transport(AISchema.TransportError(
                message: "Invalid WebSocket URL",
                transport: .websocket,
                operation: .request,
                code: "invalid-url",
                url: value,
                phase: .prepare,
                delivery: .notSent
            )))
        }
        switch scheme {
        case "https":
            components.scheme = "wss"
        case "http":
            components.scheme = "ws"
        default:
            throw AISchema.AIError(reason: .transport(AISchema.TransportError(
                message: "Unsupported WebSocket URL protocol \(scheme):",
                transport: .websocket,
                operation: .request,
                code: "invalid-url",
                url: value,
                phase: .prepare,
                delivery: .notSent
            )))
        }
        guard let result = components.string else {
            throw AISchema.AIError(reason: .transport(AISchema.TransportError(
                message: "Invalid WebSocket URL",
                transport: .websocket,
                operation: .request,
                code: "invalid-url",
                url: value,
                phase: .prepare,
                delivery: .notSent
            )))
        }
        return result
    }

    // parity: ai/src/route/transport/websocket.ts#open [status=adapted hash=463bebddc594]
    public static func open(
        _ input: WebSocketRequest,
        connector: WebSocketConnector
    ) async throws -> WebSocketConnection {
        try await connector.open(input)
    }

    // parity: ai/src/route/transport/websocket.ts#fromWebSocket [status=adapted hash=5804709d9408]
    public static func fromWebSocket(
        _ connection: WebSocketConnection,
        input: WebSocketRequest
    ) -> WebSocketConnection {
        let guardedStream = AsyncThrowingStream<WebSocketMessage, Error> { continuation in
            let task = Task {
                do {
                    for try await msg in connection.messages {
                        let byteCount: Int = switch msg {
                        case .text(let s): s.utf8.count
                        case .binary(let b): b.count
                        }
                        if byteCount > maxWebSocketFrameBytes {
                            let body = messageText(msg)
                            await connection.close()
                            continuation.finish(throwing: AISchema.AIError(reason: .transport(AISchema.TransportError(
                                message: "WebSocket message exceeds the 16 MiB limit",
                                body: body,
                                transport: .websocket,
                                operation: .read,
                                code: "message-too-large",
                                url: input.url,
                                phase: .receive
                            ))))
                            return
                        }
                        continuation.yield(msg)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return WebSocketConnection(
            http: connection.http,
            sendText: connection.sendText,
            messages: guardedStream,
            close: connection.close
        )
    }

    // parity: ai/src/route/transport/websocket.ts#messageText [status=implemented hash=9d14f030b423]
    public static func messageText(_ message: WebSocketMessage) -> String {
        switch message {
        case .text(let s): s
        case .binary(let bytes): String(decoding: bytes, as: UTF8.self)
        }
    }

    private static func annotateWebSocketError(
        _ error: AISchema.AIError,
        phase: AISchema.TransportError.Phase,
        delivery: AISchema.TransportError.Delivery
    ) -> AISchema.AIError {
        guard case .transport(let t) = error.reason else { return error }
        return AISchema.AIError(reason: .transport(AISchema.TransportError(
            message: t.message,
            body: t.body,
            http: t.http,
            cause: t.cause,
            transport: t.transport,
            operation: t.operation,
            code: t.code,
            url: t.url,
            phase: phase,
            delivery: delivery,
            recovery: t.recovery
        )))
    }

    // parity: ai/src/route/transport/websocket.ts#makeDirect [status=implemented hash=c5b63cbf73b4]
    public static func makeDirect(_ connector: WebSocketConnector) -> WebSocketChannelExecutor {
        WebSocketChannelExecutor { exchange in
            let req = WebSocketRequest(url: exchange.connect.url, headers: exchange.connect.headers)
            let connection: WebSocketConnection
            do {
                connection = try await connector.open(req)
            } catch let aiError as AISchema.AIError {
                throw annotateWebSocketError(aiError, phase: .connect, delivery: .notSent)
            } catch {
                throw AISchema.AIError(reason: .transport(AISchema.TransportError(
                    message: String(describing: error),
                    cause: String(describing: error),
                    transport: .websocket,
                    operation: .request,
                    url: exchange.connect.url,
                    phase: .connect,
                    delivery: .notSent
                )))
            }
            let create: ChannelCreate
            do {
                create = try await exchange.driver.create(nil)
            } catch {
                await connection.close()
                throw error
            }
            do {
                try await connection.sendText(create.message)
            } catch let aiError as AISchema.AIError {
                await connection.close()
                throw AISchema.AIError(reason: aiError.reason.with(http: connection.http))
            } catch {
                await connection.close()
                throw error
            }

            let frames = AsyncThrowingStream<String, Error> { continuation in
                let task = Task {
                    var observed = false
                    defer {
                        Task { await connection.close() }
                    }
                    do {
                        for try await message in connection.messages {
                            observed = true
                            let frame = messageText(message)
                            let observation: ChannelObservation
                            do {
                                observation = try await exchange.driver.observe(create, frame)
                            } catch let aiError as AISchema.AIError {
                                continuation.finish(throwing: AISchema.AIError(
                                    reason: aiError.reason.with(body: frame, http: connection.http)
                                ))
                                return
                            } catch {
                                continuation.finish(throwing: error)
                                return
                            }
                            switch observation {
                            case .frame(let f):
                                continuation.yield(f)
                            case .completed(let f, _), .incomplete(let f):
                                continuation.yield(f)
                                continuation.finish()
                                return
                            case .providerFailure(let err), .rejected(let err, _):
                                continuation.finish(throwing: AISchema.AIError(
                                    reason: err.reason.with(body: frame, http: connection.http)
                                ))
                                return
                            }
                        }
                        continuation.finish()
                    } catch let aiError as AISchema.AIError {
                        let phase: AISchema.TransportError.Phase = if case .transport(let t) = aiError.reason, t.phase == .close {
                            .close
                        } else {
                            .receive
                        }
                        let annotated = annotateWebSocketError(
                            aiError,
                            phase: phase,
                            delivery: observed ? .accepted : .ambiguous
                        )
                        continuation.finish(throwing: AISchema.AIError(
                            reason: annotated.reason.with(http: connection.http)
                        ))
                    } catch {
                        continuation.finish(throwing: AISchema.AIError(reason: .transport(AISchema.TransportError(
                            message: String(describing: error),
                            http: connection.http,
                            cause: String(describing: error),
                            transport: .websocket,
                            operation: .read,
                            url: exchange.connect.url,
                            phase: .receive,
                            delivery: observed ? .accepted : .ambiguous
                        ))))
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }

            return WebSocketChannelExecution(frames: frames, http: connection.http, complete: {})
        }
    }

    // parity: ai/src/route/transport/websocket.ts#direct [status=adapted hash=9939ee06394c]
    public static func direct(connector: WebSocketConnector) -> WebSocketChannelExecutor {
        makeDirect(connector)
    }

    // parity: ai/src/route/transport/websocket.ts#WebSocketTransport [status=implemented hash=5a4ad287e1fd]
    public enum WebSocketTransport {
        public static func toWebSocketUrl(_ value: String) throws(AISchema.AIError) -> String {
            try AITransport.toWebSocketUrl(value)
        }

        public static func messageText(_ message: WebSocketMessage) -> String {
            AITransport.messageText(message)
        }

        public static func makeDirect(_ connector: WebSocketConnector) -> WebSocketChannelExecutor {
            AITransport.makeDirect(connector)
        }

        public static func direct(connector: WebSocketConnector) -> WebSocketChannelExecutor {
            AITransport.direct(connector: connector)
        }

        public static func open(
            _ input: WebSocketRequest,
            connector: WebSocketConnector
        ) async throws -> WebSocketConnection {
            try await AITransport.open(input, connector: connector)
        }

        public static func fromWebSocket(
            _ connection: WebSocketConnection,
            input: WebSocketRequest
        ) -> WebSocketConnection {
            AITransport.fromWebSocket(connection, input: input)
        }
    }
}

/// Core routing, wire protocol contracts, LLM client execution, media protocols/routes,
/// decision routes, and embedding routes.
///
/// Ports `packages/ai/src/route/{protocol,client,media-protocol,media,decision,embedding}.ts`.
public enum AIRoute {

    // MARK: - src/route/protocol.ts

    // parity: ai/src/route/protocol.ts#ProtocolBody [status=implemented hash=fecef0405495]
    public struct ProtocolBody<Body: Sendable>: Sendable {
        public let encode: @Sendable (Body) throws -> String
        public let from: @Sendable (AISchema.LLMRequest) async throws -> Body

        public init(
            encode: @escaping @Sendable (Body) throws -> String,
            from: @escaping @Sendable (AISchema.LLMRequest) async throws -> Body
        ) {
            self.encode = encode
            self.from = from
        }
    }

    // parity: ai/src/route/protocol.ts#ProtocolStream [status=implemented hash=0adb4cb9a768]
    public struct ProtocolStream<Frame: Sendable, Event: Sendable, State: Sendable>: Sendable {
        public let decodeEvent: @Sendable (Frame) throws -> Event
        public let initial: @Sendable (AISchema.LLMRequest) -> State
        public let step: @Sendable (State, Event) async throws -> (State, [AISchema.LLMEvent])
        public let terminal: (@Sendable (Event) -> Bool)?
        public let onHalt: (@Sendable (State) async throws -> [AISchema.LLMEvent])?

        public init(
            decodeEvent: @escaping @Sendable (Frame) throws -> Event,
            initial: @escaping @Sendable (AISchema.LLMRequest) -> State,
            step: @escaping @Sendable (State, Event) async throws -> (State, [AISchema.LLMEvent]),
            terminal: (@Sendable (Event) -> Bool)? = nil,
            onHalt: (@Sendable (State) async throws -> [AISchema.LLMEvent])? = nil
        ) {
            self.decodeEvent = decodeEvent
            self.initial = initial
            self.step = step
            self.terminal = terminal
            self.onHalt = onHalt
        }
    }

    // parity: ai/src/route/protocol.ts#Protocol [status=implemented hash=94e74aeb0da5]
    public struct WireProtocol<Body: Sendable, Frame: Sendable, Event: Sendable, State: Sendable>: Sendable {
        public let id: AISchema.ProtocolID
        public let body: ProtocolBody<Body>
        public let stream: ProtocolStream<Frame, Event, State>
        public let supportsEffortUpdates: (@Sendable (AISchema.LLMRequest) -> Bool)?
        public let toolUpdates: AIToolUpdates.ToolUpdateEncoding?
        public let sanitizer: AISchema.LanguageModelSanitizerCompatibility?

        public init(
            id: AISchema.ProtocolID,
            body: ProtocolBody<Body>,
            stream: ProtocolStream<Frame, Event, State>,
            supportsEffortUpdates: (@Sendable (AISchema.LLMRequest) -> Bool)? = nil,
            toolUpdates: AIToolUpdates.ToolUpdateEncoding? = nil,
            sanitizer: AISchema.LanguageModelSanitizerCompatibility? = nil
        ) {
            self.id = id
            self.body = body
            self.stream = stream
            self.supportsEffortUpdates = supportsEffortUpdates
            self.toolUpdates = toolUpdates
            self.sanitizer = sanitizer
        }
    }

    // parity: ai/src/route/protocol.ts#make [status=implemented hash=22c70b0c7b7a]
    public static func makeProtocol<Body: Sendable, Frame: Sendable, Event: Sendable, State: Sendable>(
        _ input: WireProtocol<Body, Frame, Event, State>
    ) -> WireProtocol<Body, Frame, Event, State> {
        input
    }

    // parity: ai/src/route/protocol.ts#jsonEvent [status=implemented hash=e4f927b75661]
    public static func jsonEvent<Event: Decodable & Sendable>(
        _ type: Event.Type
    ) -> @Sendable (String) throws -> Event {
        { frame in
            let data = Data(frame.utf8)
            return try JSONDecoder().decode(Event.self, from: data)
        }
    }

    // MARK: - src/route/client.ts

    // parity: ai/src/route/client.ts#RouteBody [status=implemented hash=efa8697d092d]
    public struct RouteBody<Body: Sendable>: Sendable {
        public let encode: @Sendable (Body) throws -> String
        public let from: @Sendable (AISchema.LLMRequest) async throws -> Body

        public init(
            encode: @escaping @Sendable (Body) throws -> String,
            from: @escaping @Sendable (AISchema.LLMRequest) async throws -> Body
        ) {
            self.encode = encode
            self.from = from
        }
    }

    // parity: ai/src/route/client.ts#StreamOptions [status=implemented hash=29f3ae490112]
    public struct StreamOptions: Sendable {
        public let http: AIRequestExecutor.HttpMiddleware?
        public let webSocket: AITransport.WebSocketChannelExecutor?

        public init(
            http: AIRequestExecutor.HttpMiddleware? = nil,
            webSocket: AITransport.WebSocketChannelExecutor? = nil
        ) {
            self.http = http
            self.webSocket = webSocket
        }
    }

    // parity: ai/src/route/client.ts#StreamMethod [status=implemented hash=9527355a61b1]
    public typealias StreamMethod = @Sendable (AISchema.LLMRequest, StreamOptions?) -> AsyncThrowingStream<AISchema.LLMEvent, Error>

    // parity: ai/src/route/client.ts#GenerateMethod [status=implemented hash=65ddbaacb981]
    public typealias GenerateMethod = @Sendable (AISchema.LLMRequest, StreamOptions?) async throws -> AISchema.LLMResponse

    // parity: ai/src/route/client.ts#EndpointCompactOptions [status=implemented hash=13fcb94a5d3f]
    public struct EndpointCompactOptions: Sendable {
        public let mechanism: String
        public let http: AIRequestExecutor.HttpMiddleware?

        public init(http: AIRequestExecutor.HttpMiddleware? = nil) {
            self.mechanism = "endpoint"
            self.http = http
        }
    }

    // parity: ai/src/route/client.ts#TriggerCompactOptions [status=implemented hash=adf66aa33092]
    public struct TriggerCompactOptions: Sendable {
        public let mechanism: String
        public let http: AIRequestExecutor.HttpMiddleware?
        public let webSocket: AITransport.WebSocketChannelExecutor?

        public init(
            http: AIRequestExecutor.HttpMiddleware? = nil,
            webSocket: AITransport.WebSocketChannelExecutor? = nil
        ) {
            self.mechanism = "trigger"
            self.http = http
            self.webSocket = webSocket
        }
    }

    // parity: ai/src/route/client.ts#CompactOperation [status=implemented hash=7f3c08d13d33]
    public typealias CompactOperation = @Sendable (
        AISchema.LLMRequest,
        AIRequestExecutor.RequestExecutorService,
        EndpointCompactOptions?
    ) async throws -> AISchema.CompactionResponse

    // parity: ai/src/route/client.ts#TriggerCompactOperation [status=implemented hash=9b35b3b03ce6]
    public typealias TriggerCompactOperation = @Sendable (
        AISchema.LLMRequest,
        AIRequestExecutor.RequestExecutorService,
        TriggerCompactOptions
    ) async throws -> AISchema.CompactionCheckpointResponse

    // parity: ai/src/route/client.ts#CompactionOperations [status=implemented hash=f7001b99328c]
    public struct CompactionOperations: Sendable {
        public let endpoint: CompactOperation?
        public let trigger: TriggerCompactOperation?

        public init(endpoint: CompactOperation? = nil, trigger: TriggerCompactOperation? = nil) {
            self.endpoint = endpoint
            self.trigger = trigger
        }
    }

    // parity: ai/src/route/client.ts#CompactionRequest [status=implemented hash=02289681eb05]
    public typealias CompactionRequest = AILLM.LLMRequestInput

    // parity: ai/src/route/client.ts#CheckpointRequest [status=implemented hash=e603b3a89a54]
    public typealias CheckpointRequest = AILLM.LLMRequestInput

    public enum CompactionResult: Equatable, Sendable {
        case endpoint(AISchema.CompactionResponse)
        case trigger(AISchema.CompactionCheckpointResponse)
    }

    public enum CompactOptions: Sendable {
        case endpoint(EndpointCompactOptions?)
        case trigger(TriggerCompactOptions)
        case custom(String)
    }

    // parity: ai/src/route/client.ts#CompactMethod [status=implemented hash=56e9da08f70a]
    public typealias CompactMethod = @Sendable (AISchema.LLMRequest, CompactOptions) async throws -> CompactionResult

    // parity: ai/src/route/client.ts#RouteLanguageModelInput [status=implemented hash=e997cf459042]
    public struct RouteLanguageModelInput: Sendable {
        public let id: String
        public let options: AISchema.RequestOptions?
        public let capabilities: AISchema.Capabilities?
        public let compatibility: AISchema.LanguageModelCompatibility.Input?

        public init(
            id: String,
            options: AISchema.RequestOptions? = nil,
            capabilities: AISchema.Capabilities? = nil,
            compatibility: AISchema.LanguageModelCompatibility.Input? = nil
        ) {
            self.id = id
            self.options = options
            self.capabilities = capabilities
            self.compatibility = compatibility
        }
    }

    // parity: ai/src/route/client.ts#RouteRoutedLanguageModelInput [status=implemented hash=39cfcf627c27]
    public struct RouteRoutedLanguageModelInput: Sendable {
        public let id: String
        public let provider: String
        public let options: AISchema.RequestOptions?
        public let capabilities: AISchema.Capabilities?
        public let compatibility: AISchema.LanguageModelCompatibility.Input?

        public init(
            id: String,
            provider: String,
            options: AISchema.RequestOptions? = nil,
            capabilities: AISchema.Capabilities? = nil,
            compatibility: AISchema.LanguageModelCompatibility.Input? = nil
        ) {
            self.id = id
            self.provider = provider
            self.options = options
            self.capabilities = capabilities
            self.compatibility = compatibility
        }
    }

    // parity: ai/src/route/client.ts#RoutePatch [status=implemented hash=8478d9a96f94]
    public struct RoutePatch<Body: Sendable, Prepared: Sendable>: Sendable {
        public let compact: CompactionOperations??
        public let id: String?
        public let provider: String?
        public let providerMetadataKey: String?
        public let auth: AIAuth.Definition?
        public let transport: AITransport.Transport<Body, Prepared, JSONValue>?
        public let endpoint: AIEndpoint.EndpointPatch<Body, AISchema.LLMRequest>?
        public let options: AISchema.RequestOptions?

        public init(
            compact: CompactionOperations?? = nil,
            id: String? = nil,
            provider: String? = nil,
            providerMetadataKey: String? = nil,
            auth: AIAuth.Definition? = nil,
            transport: AITransport.Transport<Body, Prepared, JSONValue>? = nil,
            endpoint: AIEndpoint.EndpointPatch<Body, AISchema.LLMRequest>? = nil,
            options: AISchema.RequestOptions? = nil
        ) {
            self.compact = compact
            self.id = id
            self.provider = provider
            self.providerMetadataKey = providerMetadataKey
            self.auth = auth
            self.transport = transport
            self.endpoint = endpoint
            self.options = options
        }
    }

    /// Compiled route request inspection output (`compileRequest`).
    public struct CompiledRequest: Sendable {
        public let id: String
        public let route: String
        public let protocolID: AISchema.ProtocolID
        public let model: AISchema.LanguageModel
        public let body: JSONValue
        public let transportID: String

        public init(
            id: String,
            route: String,
            protocolID: AISchema.ProtocolID,
            model: AISchema.LanguageModel,
            body: JSONValue,
            transportID: String
        ) {
            self.id = id
            self.route = route
            self.protocolID = protocolID
            self.model = model
            self.body = body
            self.transportID = transportID
        }
    }

    /// Type-erased runnable route stored on `AISchema.LanguageModel`.
    // parity: ai/src/route/client.ts#AnyRoute [status=implemented hash=a4e1ec6007d9]
    public struct AnyRoute: Sendable {
        public let compact: CompactionOperations?
        public let id: String
        public let provider: AISchema.ProviderID?
        public let providerMetadataKey: String?
        public let protocolID: AISchema.ProtocolID
        public let baseURL: String?
        public let transportID: String
        public let headers: (@Sendable (AISchema.LLMRequest) -> [String: String])?
        public let options: AISchema.RequestOptions?
        public let supportsEffortUpdates: (@Sendable (AISchema.LLMRequest) -> Bool)?
        public let toolUpdates: AIToolUpdates.ToolUpdateEncoding?
        public let sanitizer: AISchema.LanguageModelSanitizerCompatibility?
        internal let buildBody: @Sendable (AISchema.LLMRequest) async throws -> JSONValue
        internal let executeStream: @Sendable (
            AISchema.LLMRequest,
            AITransport.TransportRuntime,
            StreamOptions?
        ) -> AsyncThrowingStream<AISchema.LLMEvent, Error>

        public init(
            compact: CompactionOperations? = nil,
            id: String,
            provider: AISchema.ProviderID? = nil,
            providerMetadataKey: String? = nil,
            protocolID: AISchema.ProtocolID,
            baseURL: String? = nil,
            transportID: String = "http-json",
            headers: (@Sendable (AISchema.LLMRequest) -> [String: String])? = nil,
            options: AISchema.RequestOptions? = nil,
            supportsEffortUpdates: (@Sendable (AISchema.LLMRequest) -> Bool)? = nil,
            toolUpdates: AIToolUpdates.ToolUpdateEncoding? = nil,
            sanitizer: AISchema.LanguageModelSanitizerCompatibility? = nil,
            buildBody: @escaping @Sendable (AISchema.LLMRequest) async throws -> JSONValue,
            executeStream: @escaping @Sendable (
                AISchema.LLMRequest,
                AITransport.TransportRuntime,
                StreamOptions?
            ) -> AsyncThrowingStream<AISchema.LLMEvent, Error>
        ) {
            self.compact = compact
            self.id = id
            self.provider = provider
            self.providerMetadataKey = providerMetadataKey
            self.protocolID = protocolID
            self.baseURL = baseURL
            self.transportID = transportID
            self.headers = headers
            self.options = options
            self.supportsEffortUpdates = supportsEffortUpdates
            self.toolUpdates = toolUpdates
            self.sanitizer = sanitizer
            self.buildBody = buildBody
            self.executeStream = executeStream
        }

        public func model(_ input: RouteLanguageModelInput) throws(AISchema.ProviderConfigurationError) -> AISchema.LanguageModel {
            guard let provider else {
                throw AISchema.ProviderConfigurationError(
                    provider: AISchema.ProviderID.make("unknown"),
                    message: "Route.model(\(id)) requires a provider"
                )
            }
            return try model(RouteRoutedLanguageModelInput(
                id: input.id,
                provider: provider.rawValue,
                options: input.options,
                capabilities: input.capabilities,
                compatibility: input.compatibility
            ))
        }

        public func model(_ input: RouteRoutedLanguageModelInput) throws(AISchema.ProviderConfigurationError) -> AISchema.LanguageModel {
            let resolvedProvider = provider ?? AISchema.ProviderID.make(input.provider)
            guard let baseURL, !baseURL.isEmpty else {
                throw AISchema.ProviderConfigurationError(
                    provider: resolvedProvider,
                    message: "Route.model(\(id)) requires an endpoint baseURL — configure it on the route first"
                )
            }
            return AISchema.LanguageModel.make(AISchema.LanguageModel.Input(
                id: input.id,
                provider: resolvedProvider.rawValue,
                route: self,
                options: input.options,
                capabilities: input.capabilities,
                compatibility: input.compatibility
            ))
        }
    }

    // parity: ai/src/route/client.ts#Route [status=implemented hash=7a295a9f5af6]
    public struct Route<Body: Sendable, Prepared: Sendable, Frame: Sendable, Event: Sendable, State: Sendable>: Sendable {
        public let compact: CompactionOperations?
        public let id: String
        public let provider: AISchema.ProviderID?
        public let providerMetadataKey: String?
        public let wireProtocol: WireProtocol<Body, Frame, Event, State>
        public let endpoint: AIEndpoint.Definition<Body, AISchema.LLMRequest>
        public let auth: AIAuth.Definition
        public let headers: (@Sendable (AISchema.LLMRequest) -> [String: String])?
        public let transport: AITransport.Transport<Body, Prepared, Frame>
        public let options: AISchema.RequestOptions?

        public var protocolID: AISchema.ProtocolID { wireProtocol.id }
        public var body: RouteBody<Body> {
            RouteBody(encode: wireProtocol.body.encode, from: wireProtocol.body.from)
        }

        public init(
            compact: CompactionOperations? = nil,
            id: String,
            provider: AISchema.ProviderID? = nil,
            providerMetadataKey: String? = nil,
            wireProtocol: WireProtocol<Body, Frame, Event, State>,
            endpoint: AIEndpoint.Definition<Body, AISchema.LLMRequest>,
            auth: AIAuth.Definition = AIAuth.none,
            headers: (@Sendable (AISchema.LLMRequest) -> [String: String])? = nil,
            transport: AITransport.Transport<Body, Prepared, Frame>,
            options: AISchema.RequestOptions? = nil
        ) {
            self.compact = compact
            self.id = id
            self.provider = provider
            self.providerMetadataKey = providerMetadataKey
            self.wireProtocol = wireProtocol
            self.endpoint = endpoint
            self.auth = auth
            self.headers = headers
            self.transport = transport
            self.options = AISchema.mergeRequestOptions(options)
        }

        public func with(
            compact: CompactionOperations?? = nil,
            id: String? = nil,
            provider: String? = nil,
            providerMetadataKey: String? = nil,
            auth: AIAuth.Definition? = nil,
            endpoint: AIEndpoint.EndpointPatch<Body, AISchema.LLMRequest>? = nil,
            transport: AITransport.Transport<Body, Prepared, Frame>? = nil,
            options: AISchema.RequestOptions? = nil
        ) -> Route<Body, Prepared, Frame, Event, State> {
            let nextProvider = provider.map(AISchema.ProviderID.make) ?? self.provider
            let nextMetaKey: String? = if let providerMetadataKey {
                providerMetadataKey
            } else if let provider, provider != self.provider?.rawValue {
                provider
            } else {
                self.providerMetadataKey
            }
            return Route(
                compact: compact ?? self.compact,
                id: id ?? self.id,
                provider: nextProvider,
                providerMetadataKey: nextMetaKey,
                wireProtocol: wireProtocol,
                endpoint: endpoint.map { AIEndpoint.merge(self.endpoint, $0) } ?? self.endpoint,
                auth: auth ?? self.auth,
                headers: headers,
                transport: transport ?? self.transport,
                options: AISchema.mergeRequestOptions(self.options, options)
            )
        }

        public func prepareTransport(
            body: Body,
            request: AISchema.LLMRequest,
            options: StreamOptions? = nil
        ) async throws -> Prepared {
            try await transport.prepare(AITransport.TransportPrepareInput(
                body: body,
                request: request,
                endpoint: endpoint,
                auth: auth,
                encodeBody: wireProtocol.body.encode,
                headers: headers,
                middleware: AIRequestExecutor.withFetch(request.fetch, middleware: options?.http),
                webSocket: options?.webSocket
            ))
        }

        public func streamPrepared(
            prepared: Prepared,
            request: AISchema.LLMRequest,
            runtime: AITransport.TransportRuntime,
            options: StreamOptions? = nil
        ) -> AsyncThrowingStream<AISchema.LLMEvent, Error> {
            let routeLabel = "\(request.model.provider.rawValue)/\(request.model.route.id)"
            let routeID = id
            let proto = wireProtocol
            let tr = transport
            return AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        let execution = try await tr.execute(
                            prepared,
                            request,
                            runtime,
                            AITransport.TransportExecuteOptions(webSocket: options?.webSocket)
                        )
                        var state = proto.stream.initial(request)
                        var sawTerminal = false

                        func emit(_ event: AISchema.LLMEvent) throws(AISchema.AIError) {
                            if sawTerminal && !event.isRaw {
                                throw AISchema.AIError(reason: .invalidProviderOutput(AISchema.InvalidProviderOutputError(
                                    message: "Provider emitted \(event.typeName) after the terminal event",
                                    http: execution.http,
                                    route: routeLabel
                                )))
                            }
                            if event.isFinish { sawTerminal = true }
                            continuation.yield(event)
                        }

                        for try await frame in execution.frames {
                            let wireBody = execution.body?(frame) ?? (frame as? String)
                            let decoded: Event
                            do {
                                decoded = try proto.stream.decodeEvent(frame)
                            } catch let aiError as AISchema.AIError {
                                throw AISchema.AIError(reason: aiError.reason.with(body: wireBody, http: execution.http))
                            } catch {
                                throw AISchema.AIError(reason: .invalidProviderOutput(AISchema.InvalidProviderOutputError(
                                    message: "Invalid \(routeLabel) stream event",
                                    body: wireBody,
                                    http: execution.http,
                                    cause: String(describing: error),
                                    route: routeID
                                )))
                            }

                            let (nextState, produced): (State, [AISchema.LLMEvent])
                            do {
                                (nextState, produced) = try await proto.stream.step(state, decoded)
                            } catch let aiError as AISchema.AIError {
                                throw AISchema.AIError(reason: aiError.reason.with(body: wireBody, http: execution.http))
                            } catch {
                                throw AISchema.AIError(reason: .invalidProviderOutput(AISchema.InvalidProviderOutputError(
                                    message: "Failed to parse \(routeLabel) event",
                                    body: wireBody,
                                    http: execution.http,
                                    cause: String(describing: error),
                                    route: routeID
                                )))
                            }
                            state = nextState

                            if request.includeRaw == true {
                                let rawValue: JSONValue
                                if let customRaw = execution.raw?(frame) {
                                    rawValue = customRaw
                                } else if let textFrame = frame as? String {
                                    rawValue = (try? AIUtils.decodeJson(textFrame)) ?? .string(textFrame)
                                } else {
                                    rawValue = .string(String(describing: frame))
                                }
                                try emit(.raw(AISchema.RawEvent(data: rawValue)))
                            }
                            for ev in produced {
                                try emit(ev)
                            }
                            if proto.stream.terminal?(decoded) == true {
                                break
                            }
                        }

                        if let onHalt = proto.stream.onHalt {
                            let flushed = try await onHalt(state)
                            for ev in flushed {
                                try emit(ev)
                            }
                        }

                        if !sawTerminal {
                            throw AISchema.AIError(reason: .invalidProviderOutput(AISchema.InvalidProviderOutputError(
                                message: "The provider response ended unexpectedly.",
                                http: execution.http,
                                classification: .incompleteStream,
                                route: routeLabel
                            )))
                        }

                        await execution.complete?()
                        continuation.finish()
                    } catch let aiError as AISchema.AIError {
                        continuation.finish(throwing: aiError)
                    } catch {
                        continuation.finish(throwing: AISchema.AIError(reason: .invalidProviderOutput(
                            AISchema.InvalidProviderOutputError(
                                message: "Failed to read \(routeLabel) stream",
                                cause: String(describing: error),
                                route: routeID
                            )
                        )))
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }

        public var erased: AnyRoute {
            let routeCopy = self
            return AnyRoute(
                compact: compact,
                id: id,
                provider: provider,
                providerMetadataKey: providerMetadataKey,
                protocolID: protocolID,
                baseURL: endpoint.baseURL,
                transportID: transport.id,
                headers: headers,
                options: options,
                supportsEffortUpdates: wireProtocol.supportsEffortUpdates,
                toolUpdates: wireProtocol.toolUpdates,
                sanitizer: wireProtocol.sanitizer,
                buildBody: { request in
                    let body = try await routeCopy.wireProtocol.body.from(request)
                    let encoded = (try? routeCopy.wireProtocol.body.encode(body)) ?? "{}"
                    return (try? AIUtils.decodeJson(encoded)) ?? .string(encoded)
                },
                executeStream: { request, runtime, options in
                    AsyncThrowingStream { continuation in
                        let task = Task {
                            do {
                                let body = try await routeCopy.wireProtocol.body.from(request)
                                let prepared = try await routeCopy.prepareTransport(body: body, request: request, options: options)
                                for try await event in routeCopy.streamPrepared(prepared: prepared, request: request, runtime: runtime, options: options) {
                                    continuation.yield(event)
                                }
                                continuation.finish()
                            } catch {
                                continuation.finish(throwing: error)
                            }
                        }
                        continuation.onTermination = { _ in task.cancel() }
                    }
                }
            )
        }

        public func model(_ input: RouteLanguageModelInput) throws(AISchema.ProviderConfigurationError) -> AISchema.LanguageModel {
            try erased.model(input)
        }

        public func model(_ input: RouteRoutedLanguageModelInput) throws(AISchema.ProviderConfigurationError) -> AISchema.LanguageModel {
            try erased.model(input)
        }
    }

    // parity: ai/src/route/client.ts#MakeInput [status=implemented hash=ab4b634e68a2]
    public struct MakeInput<Body: Sendable, Frame: Sendable, Event: Sendable, State: Sendable>: Sendable {
        public let compact: CompactionOperations?
        public let id: String
        public let provider: String?
        public let providerMetadataKey: String?
        public let wireProtocol: WireProtocol<Body, Frame, Event, State>
        public let endpoint: AIEndpoint.Definition<Body, AISchema.LLMRequest>
        public let auth: AIAuth.Definition?
        public let framing: AIFraming.Definition<Frame>
        public let headers: (@Sendable (AISchema.LLMRequest) -> [String: String])?
        public let options: AISchema.RequestOptions?

        public init(
            compact: CompactionOperations? = nil,
            id: String,
            provider: String? = nil,
            providerMetadataKey: String? = nil,
            wireProtocol: WireProtocol<Body, Frame, Event, State>,
            endpoint: AIEndpoint.Definition<Body, AISchema.LLMRequest>,
            auth: AIAuth.Definition? = nil,
            framing: AIFraming.Definition<Frame>,
            headers: (@Sendable (AISchema.LLMRequest) -> [String: String])? = nil,
            options: AISchema.RequestOptions? = nil
        ) {
            self.compact = compact
            self.id = id
            self.provider = provider
            self.providerMetadataKey = providerMetadataKey
            self.wireProtocol = wireProtocol
            self.endpoint = endpoint
            self.auth = auth
            self.framing = framing
            self.headers = headers
            self.options = options
        }
    }

    // parity: ai/src/route/client.ts#MakeTransportInput [status=implemented hash=d5df456a8b6c]
    public struct MakeTransportInput<Body: Sendable, Prepared: Sendable, Frame: Sendable, Event: Sendable, State: Sendable>: Sendable {
        public let compact: CompactionOperations?
        public let id: String
        public let provider: String?
        public let providerMetadataKey: String?
        public let wireProtocol: WireProtocol<Body, Frame, Event, State>
        public let endpoint: AIEndpoint.Definition<Body, AISchema.LLMRequest>
        public let auth: AIAuth.Definition?
        public let headers: (@Sendable (AISchema.LLMRequest) -> [String: String])?
        public let transport: AITransport.Transport<Body, Prepared, Frame>
        public let options: AISchema.RequestOptions?

        public init(
            compact: CompactionOperations? = nil,
            id: String,
            provider: String? = nil,
            providerMetadataKey: String? = nil,
            wireProtocol: WireProtocol<Body, Frame, Event, State>,
            endpoint: AIEndpoint.Definition<Body, AISchema.LLMRequest>,
            auth: AIAuth.Definition? = nil,
            headers: (@Sendable (AISchema.LLMRequest) -> [String: String])? = nil,
            transport: AITransport.Transport<Body, Prepared, Frame>,
            options: AISchema.RequestOptions? = nil
        ) {
            self.compact = compact
            self.id = id
            self.provider = provider
            self.providerMetadataKey = providerMetadataKey
            self.wireProtocol = wireProtocol
            self.endpoint = endpoint
            self.auth = auth
            self.headers = headers
            self.transport = transport
            self.options = options
        }
    }

    // parity: ai/src/route/client.ts#make [status=implemented hash=c463dfbefe49]
    public static func make<Body: Sendable, Frame: Sendable, Event: Sendable, State: Sendable>(
        _ input: MakeInput<Body, Frame, Event, State>
    ) -> Route<Body, AITransport.HttpPrepared<Frame>, Frame, Event, State> {
        let httpTransport = AITransport.httpJson(AITransport.HttpJsonInput(framing: input.framing)).transport as AITransport.Transport<Body, AITransport.HttpPrepared<Frame>, Frame>
        return make(MakeTransportInput(
            compact: input.compact,
            id: input.id,
            provider: input.provider,
            providerMetadataKey: input.providerMetadataKey,
            wireProtocol: input.wireProtocol,
            endpoint: input.endpoint,
            auth: input.auth,
            headers: input.headers,
            transport: httpTransport,
            options: input.options
        ))
    }

    public static func make<Body: Sendable, Prepared: Sendable, Frame: Sendable, Event: Sendable, State: Sendable>(
        _ input: MakeTransportInput<Body, Prepared, Frame, Event, State>
    ) -> Route<Body, Prepared, Frame, Event, State> {
        Route(
            compact: input.compact,
            id: input.id,
            provider: input.provider.map(AISchema.ProviderID.make),
            providerMetadataKey: input.providerMetadataKey,
            wireProtocol: input.wireProtocol,
            endpoint: input.endpoint,
            auth: input.auth ?? AIAuth.none,
            headers: input.headers,
            transport: input.transport,
            options: input.options
        )
    }

    // parity: ai/src/route/client.ts#canCompact [status=implemented hash=dc7a3a42bf72]
    public static func canCompact(_ model: AISchema.LanguageModel, mechanism: String? = nil) -> Bool {
        if mechanism == "trigger" {
            return model.route.compact?.trigger != nil
        }
        if let mechanism, mechanism != "endpoint" {
            return false
        }
        return model.route.compact?.endpoint != nil
    }

    public static func canCompact(_ request: AISchema.LLMRequest, mechanism: String? = nil) -> Bool {
        canCompact(request.model, mechanism: mechanism)
    }

    private static func unsupportedCompaction(model: AISchema.LanguageModel, mechanism: String?) -> AISchema.AIError {
        if let mechanism, mechanism != "endpoint" && mechanism != "trigger" {
            return AISchema.AIError(reason: .invalidRequest(AISchema.InvalidRequestError(
                message: "Unknown compaction mechanism: \(mechanism)"
            )))
        }
        let isTrigger = mechanism == "trigger"
        return AISchema.AIError(reason: .unsupportedOperation(AISchema.UnsupportedOperationError(
            message: "\(model.provider.rawValue)/\(model.route.id) does not support \(isTrigger ? "trigger" : "explicit") compaction",
            operation: isTrigger ? "compact.trigger" : "compact",
            provider: model.provider,
            route: model.route.id
        )))
    }

    private static func dedupeTools(_ tools: [AISchema.ToolEntry]) -> [AISchema.ToolEntry] {
        var order: [String] = []
        var map: [String: AISchema.ToolEntry] = [:]
        for entry in tools {
            let key = "\(entry.typeTag):\(entry.name)"
            if map[key] == nil { order.append(key) }
            map[key] = entry
        }
        return order.compactMap { key in
            guard let entry = map[key] else { return nil }
            switch entry {
            case .tool:
                return entry
            case .namespace(let ns):
                return .namespace(AISchema.ToolNamespace(
                    name: ns.name,
                    description: ns.description,
                    tools: dedupeTools(ns.tools)
                ))
            }
        }
    }

    public static func prepareRequest(_ request: AISchema.LLMRequest) -> AISchema.LLMRequest {
        let normalizedMessages = AIToolHistory.normalizeToolHistory(request.messages)
        let modelOpts = request.model.options
        let mergedGen = AISchema.mergeGeneration(modelOpts?.generation, request.generationOptions)
        let mergedTransport = AISchema.mergeTransport(modelOpts?.transport, request.transportOptions)
        let mergedProvider = AISchema.mergeProviderOptions(modelOpts?.providerOptions, request.providerOptions)
        var resolved = request.replacing(
            messages: normalizedMessages,
            generation: mergedGen,
            transport: mergedTransport,
            providerOptions: .some(mergedProvider)
        )
        let updated = AIToolUpdates.planToolUpdates(resolved)
        resolved = AICachePolicy.applyCachePolicy(
            AIEffortUpdates.applyEffortUpdates(
                AIToolUpdates.mapToolUpdates(updated.replacing(tools: dedupeTools(updated.tools)), dedupeTools)
            )
        )
        if let routeHeaders = resolved.model.route.headers?(resolved) {
            var combined = routeHeaders
            if let existing = resolved.headers {
                for (k, v) in existing { combined[k] = v }
            }
            resolved = resolved.replacing(headers: .some(combined))
        }
        return resolved
    }

    private static func validateNoFileReferences(_ request: AISchema.LLMRequest) throws(AISchema.AIError) {
        for message in request.messages {
            for part in message.contentParts {
                switch part {
                case .media(let mediaPart):
                    let candidate: String? = switch mediaPart.media.source {
                    case .url(let u, _, _): u
                    case .ref(_, let id, _): id
                    case .bytes, .base64: nil
                    }
                    if let candidate, candidate.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("file:") {
                        throw AISchema.AIError(reason: .invalidRequest(AISchema.InvalidRequestError(
                            message: "Local file references must be read with Media.file(path) before sending"
                        )))
                    }
                case .toolResult(let tr):
                    if case .content(let items) = tr.result {
                        for item in items {
                            if case .file(let f) = item,
                               f.uri.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("file:") {
                                throw AISchema.AIError(reason: .invalidRequest(AISchema.InvalidRequestError(
                                    message: "Local file references must be read with Media.file(path) before sending"
                                )))
                            }
                        }
                    }
                default:
                    break
                }
            }
        }
    }

    // parity: ai/src/route/client.ts#compileRequest [status=implemented hash=f80025804a4b]
    public static func compileRequest(_ request: AISchema.LLMRequest) async throws -> CompiledRequest {
        try validateNoFileReferences(request)
        let resolved = prepareRequest(request)
        let body = try await resolved.model.route.buildBody(resolved)
        return CompiledRequest(
            id: resolved.id ?? "request",
            route: resolved.model.route.id,
            protocolID: resolved.model.route.protocolID,
            model: resolved.model,
            body: body,
            transportID: resolved.model.route.transportID
        )
    }

    // parity: ai/src/route/client.ts#Interface [status=implemented hash=6274ff7c4e54]
    public protocol Interface: Sendable {
        func stream(_ request: AISchema.LLMRequest, options: StreamOptions?) -> AsyncThrowingStream<AISchema.LLMEvent, Error>
        func generate(_ request: AISchema.LLMRequest, options: StreamOptions?) async throws -> AISchema.LLMResponse
        func compact(_ request: AISchema.LLMRequest, options: CompactOptions) async throws -> CompactionResult
    }

    // parity: ai/src/route/client.ts#LLMClientService [status=implemented hash=0c311ba48e3b]
    public struct LLMClientService: Interface, Sendable {
        public static let serviceID = "@opencode/LLMClient"
        private let runStream: StreamMethod
        private let runGenerate: GenerateMethod
        private let runCompact: CompactMethod

        public init(
            stream: @escaping StreamMethod,
            generate: GenerateMethod? = nil,
            compact: @escaping CompactMethod
        ) {
            self.runStream = stream
            self.runGenerate = generate ?? AIRoute.generateWith(stream)
            self.runCompact = compact
        }

        public func stream(
            _ request: AISchema.LLMRequest,
            options: StreamOptions? = nil
        ) -> AsyncThrowingStream<AISchema.LLMEvent, Error> {
            runStream(request, options)
        }

        public func generate(
            _ request: AISchema.LLMRequest,
            options: StreamOptions? = nil
        ) async throws -> AISchema.LLMResponse {
            try await runGenerate(request, options)
        }

        public func compact(
            _ request: AISchema.LLMRequest,
            options: CompactOptions = .endpoint(nil)
        ) async throws -> CompactionResult {
            try await runCompact(request, options)
        }
    }

    // parity: ai/src/route/client.ts#Service [status=implemented hash=89ccdb1f586d]
    public typealias Service = LLMClientService

    // parity: ai/src/route/client.ts#generateWith [status=implemented hash=71f1a0bf933c]
    public static func generateWith(_ streamFn: @escaping StreamMethod) -> GenerateMethod {
        { request, options in
            var state = AISchema.ResponseFold.empty()
            do {
                for try await event in streamFn(request, options) {
                    state = AISchema.ResponseFold.reduce(state, event)
                }
            } catch let aiError as AISchema.AIError {
                throw AISchema.withPartial(aiError, partial: AISchema.ResponseFold.partial(state))
            } catch {
                let wrapped = AISchema.AIError(reason: .unknownProvider(AISchema.UnknownProviderError(
                    message: String(describing: error),
                    cause: String(describing: error)
                )))
                throw AISchema.withPartial(wrapped, partial: AISchema.ResponseFold.partial(state))
            }
            if let response = AISchema.ResponseFold.complete(state) {
                return response
            }
            let incomplete = AISchema.AIError(reason: .invalidProviderOutput(AISchema.InvalidProviderOutputError(
                message: "The provider response ended unexpectedly.",
                classification: .incompleteStream,
                route: "\(request.model.provider.rawValue)/\(request.model.route.id)"
            )))
            throw AISchema.withPartial(incomplete, partial: AISchema.ResponseFold.partial(state))
        }
    }

    // parity: ai/src/route/client.ts#stream [status=implemented hash=502b90a5e567]
    public static func stream(
        _ request: AISchema.LLMRequest,
        options: StreamOptions? = nil,
        client: any Interface
    ) -> AsyncThrowingStream<AISchema.LLMEvent, Error> {
        client.stream(request, options: options)
    }

    // parity: ai/src/route/client.ts#generate [status=implemented hash=507c842e7d7a]
    public static func generate(
        _ request: AISchema.LLMRequest,
        options: StreamOptions? = nil,
        client: any Interface
    ) async throws -> AISchema.LLMResponse {
        try await client.generate(request, options: options)
    }

    // parity: ai/src/route/client.ts#compactRequest [status=implemented hash=9a038db63f57]
    public static func compactRequest(
        _ request: AISchema.LLMRequest,
        options: CompactOptions = .endpoint(nil),
        client: any Interface
    ) async throws -> CompactionResult {
        switch options {
        case .trigger:
            if canCompact(request, mechanism: "trigger") {
                return try await client.compact(request, options: options)
            }
            throw unsupportedCompaction(model: request.model, mechanism: "trigger")
        case .endpoint:
            if canCompact(request, mechanism: "endpoint") {
                return try await client.compact(request, options: options)
            }
            throw unsupportedCompaction(model: request.model, mechanism: "endpoint")
        case .custom(let mechanism):
            throw unsupportedCompaction(model: request.model, mechanism: mechanism)
        }
    }

    // parity: ai/src/route/client.ts#layer [status=implemented hash=fb762f246055]
    public static func layer(executor: AIRequestExecutor.RequestExecutorService) -> LLMClientService {
        let runtime = AITransport.TransportRuntime(http: executor)
        let streamFn: StreamMethod = { request, options in
            AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        try validateNoFileReferences(request)
                        let resolved = prepareRequest(request)
                        for try await event in resolved.model.route.executeStream(resolved, runtime, options) {
                            continuation.yield(event)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
        let compactFn: CompactMethod = { request, options in
            switch options {
            case .trigger(let opts):
                guard let trigger = request.model.route.compact?.trigger else {
                    throw unsupportedCompaction(model: request.model, mechanism: "trigger")
                }
                let res = try await trigger(prepareRequest(request), executor, opts)
                return .trigger(res)
            case .endpoint(let opts):
                guard let endpoint = request.model.route.compact?.endpoint else {
                    throw unsupportedCompaction(model: request.model, mechanism: "endpoint")
                }
                let res = try await endpoint(prepareRequest(request), executor, opts)
                return .endpoint(res)
            case .custom(let mechanism):
                throw unsupportedCompaction(model: request.model, mechanism: mechanism)
            }
        }
        return LLMClientService(stream: streamFn, compact: compactFn)
    }

    // parity: ai/src/route/client.ts#LLMClient [status=implemented hash=71352683f7a3]
    public enum LLMClient {
        public typealias Service = AIRoute.LLMClientService

        public static func layer(executor: AIRequestExecutor.RequestExecutorService) -> Service {
            AIRoute.layer(executor: executor)
        }

        public static func stream(
            _ request: AISchema.LLMRequest,
            options: StreamOptions? = nil,
            client: any Interface
        ) -> AsyncThrowingStream<AISchema.LLMEvent, Error> {
            AIRoute.stream(request, options: options, client: client)
        }

        public static func generate(
            _ request: AISchema.LLMRequest,
            options: StreamOptions? = nil,
            client: any Interface
        ) async throws -> AISchema.LLMResponse {
            try await AIRoute.generate(request, options: options, client: client)
        }
    }

    // MARK: - src/route/media-protocol.ts

    /// Pure portable multipart/form-data builder (no `FoundationNetworking`).
    public struct MultipartFormData: Equatable, Sendable {
        public struct Part: Equatable, Sendable {
            public let name: String
            public let filename: String?
            public let contentType: String?
            public let data: [UInt8]

            public init(name: String, filename: String? = nil, contentType: String? = nil, data: [UInt8]) {
                self.name = name
                self.filename = filename
                self.contentType = contentType
                self.data = data
            }
        }

        public var parts: [Part]
        public let boundary: String

        public init(parts: [Part] = [], boundary: String = "----OpenCodeBoundary\(UUID().uuidString.replacing("-", with: ""))") {
            self.parts = parts
            self.boundary = boundary
        }

        public mutating func append(_ name: String, value: String) {
            parts.append(Part(name: name, data: Array(value.utf8)))
        }

        public mutating func append(_ name: String, data: [UInt8], filename: String? = nil, contentType: String? = nil) {
            parts.append(Part(name: name, filename: filename, contentType: contentType, data: data))
        }

        public func encode() -> (contentType: String, body: [UInt8]) {
            var out: [UInt8] = []
            for part in parts {
                out.append(contentsOf: "--\(boundary)\r\n".utf8)
                if let filename = part.filename {
                    out.append(contentsOf: "Content-Disposition: form-data; name=\"\(part.name)\"; filename=\"\(filename)\"\r\n".utf8)
                } else {
                    out.append(contentsOf: "Content-Disposition: form-data; name=\"\(part.name)\"\r\n".utf8)
                }
                if let ct = part.contentType {
                    out.append(contentsOf: "Content-Type: \(ct)\r\n".utf8)
                }
                out.append(contentsOf: "\r\n".utf8)
                out.append(contentsOf: part.data)
                out.append(contentsOf: "\r\n".utf8)
            }
            out.append(contentsOf: "--\(boundary)--\r\n".utf8)
            return ("multipart/form-data; boundary=\(boundary)", out)
        }
    }

    public enum MediaProtocol {
        // parity: ai/src/route/media-protocol.ts#Query [status=implemented hash=eddba18f968b]
        public typealias Query = [String: [String]]

        // parity: ai/src/route/media-protocol.ts#Body [status=implemented hash=06206188aa12]
        public enum Body: Sendable {
            case json([String: JSONValue], query: Query? = nil)
            case multipart(MultipartFormData)
            case binary([UInt8], contentType: String, query: Query? = nil)

            public var query: Query? {
                switch self {
                case .json(_, let q), .binary(_, _, let q): q
                case .multipart: nil
                }
            }
        }

        // parity: ai/src/route/media-protocol.ts#json [status=implemented hash=90264e5994e1]
        public static func json(_ value: [String: JSONValue], query: Query? = nil) -> Body {
            .json(value, query: query)
        }

        // parity: ai/src/route/media-protocol.ts#multipart [status=implemented hash=ebee0744ddce]
        public static func multipart(_ value: MultipartFormData) -> Body {
            .multipart(value)
        }

        // parity: ai/src/route/media-protocol.ts#binary [status=implemented hash=d14dc48ddaa0]
        public static func binary(_ value: [UInt8], contentType: String, query: Query? = nil) -> Body {
            .binary(value, contentType: contentType, query: query)
        }

        // parity: ai/src/route/media-protocol.ts#Send [status=implemented hash=e9060eb24778]
        public typealias Send = @Sendable (String, Body) async throws -> AIRequestExecutor.ExecutorResponse

        // parity: ai/src/route/media-protocol.ts#Prepare [status=implemented hash=ccebd8143430]
        public typealias Prepare<Request: Sendable> = @Sendable (Request, @escaping Send) async throws -> Request

        // parity: ai/src/route/media-protocol.ts#DecodeContext [status=implemented hash=567c729e8992]
        public struct DecodeContext<Request: Sendable>: Sendable {
            public let request: Request
            public let body: Body

            public init(request: Request, body: Body) {
                self.request = request
                self.body = body
            }
        }

        // parity: ai/src/route/media-protocol.ts#Inline [status=implemented hash=a8465cf9c9aa]
        public struct Inline<Request: Sendable, Response: Sendable>: Sendable {
            public let id: String
            public let provider: AISchema.ProviderID
            public let unsupportedCheck: (@Sendable (Request) -> [String])?
            public let bodyFrom: @Sendable (Request) async throws -> Body
            public let decodeResponse: @Sendable (AIRequestExecutor.ExecutorResponse, DecodeContext<Request>) async throws -> Response

            public init(
                id: String,
                provider: AISchema.ProviderID,
                unsupportedCheck: (@Sendable (Request) -> [String])? = nil,
                bodyFrom: @escaping @Sendable (Request) async throws -> Body,
                decodeResponse: @escaping @Sendable (AIRequestExecutor.ExecutorResponse, DecodeContext<Request>) async throws -> Response
            ) {
                self.id = id
                self.provider = provider
                self.unsupportedCheck = unsupportedCheck
                self.bodyFrom = bodyFrom
                self.decodeResponse = decodeResponse
            }
        }

        // parity: ai/src/route/media-protocol.ts#inline [status=implemented hash=19a9ba958338]
        public static func inline<Request: Sendable, Response: Sendable>(
            _ route: Identity,
            unsupportedCheck: (@Sendable (Request) -> [String])? = nil,
            bodyFrom: @escaping @Sendable (Request) async throws -> Body,
            decodeResponse: @escaping @Sendable (AIRequestExecutor.ExecutorResponse, DecodeContext<Request>) async throws -> Response
        ) -> Inline<Request, Response> {
            Inline(
                id: route.id,
                provider: route.provider,
                unsupportedCheck: unsupportedCheck,
                bodyFrom: bodyFrom,
                decodeResponse: decodeResponse
            )
        }

        // parity: ai/src/route/media-protocol.ts#Started [status=implemented hash=76787f4051d2]
        public struct Started<Token: Sendable>: Sendable {
            public let token: Token
            public let snapshot: AIGeneration.Snapshot

            public init(token: Token, snapshot: AIGeneration.Snapshot) {
                self.token = token
                self.snapshot = snapshot
            }
        }

        public struct DownloadCredentials: Sendable {
            public let headers: [String: String]?
            public let middleware: AIRequestExecutor.HttpMiddleware?

            public init(headers: [String: String]? = nil, middleware: AIRequestExecutor.HttpMiddleware? = nil) {
                self.headers = headers
                self.middleware = middleware
            }
        }

        // parity: ai/src/route/media-protocol.ts#PollContext [status=implemented hash=86fdd132554c]
        public struct PollContext<Token: Sendable>: Sendable {
            public let token: Token
            public let credentials: @Sendable (String) async throws -> DownloadCredentials
            public let get: @Sendable (String) async throws -> AIRequestExecutor.ExecutorResponse

            public init(
                token: Token,
                credentials: @escaping @Sendable (String) async throws -> DownloadCredentials,
                get: @escaping @Sendable (String) async throws -> AIRequestExecutor.ExecutorResponse
            ) {
                self.token = token
                self.credentials = credentials
                self.get = get
            }
        }

        // parity: ai/src/route/media-protocol.ts#Queued [status=implemented hash=744ea9469ae3]
        public struct Queued<Request: Sendable, Response: Sendable, Token: Codable & Sendable>: Sendable {
            public struct CancelSpec: Sendable {
                public let method: AIAuth.AuthInput.Method
                public let path: @Sendable (Token) -> String

                public init(method: AIAuth.AuthInput.Method, path: @escaping @Sendable (Token) -> String) {
                    self.method = method
                    self.path = path
                }
            }

            public let id: String
            public let provider: AISchema.ProviderID
            public let unsupportedCheck: (@Sendable (Request) -> [String])?
            public let prepare: Prepare<Request>?
            public let startBodyFrom: @Sendable (Request) async throws -> Body
            public let startDecode: @Sendable (AIRequestExecutor.ExecutorResponse, DecodeContext<Request>) async throws -> Started<Token>
            public let statusPath: @Sendable (Token) -> String
            public let statusDecode: @Sendable (AIRequestExecutor.ExecutorResponse, PollContext<Token>) async throws -> AIGeneration.Snapshot
            public let resultPath: @Sendable (Token) -> String
            public let resultDecode: @Sendable (AIRequestExecutor.ExecutorResponse, PollContext<Token>) async throws -> Response
            public let cancel: CancelSpec?

            public init(
                id: String,
                provider: AISchema.ProviderID,
                unsupportedCheck: (@Sendable (Request) -> [String])? = nil,
                prepare: Prepare<Request>? = nil,
                startBodyFrom: @escaping @Sendable (Request) async throws -> Body,
                startDecode: @escaping @Sendable (AIRequestExecutor.ExecutorResponse, DecodeContext<Request>) async throws -> Started<Token>,
                statusPath: @escaping @Sendable (Token) -> String,
                statusDecode: @escaping @Sendable (AIRequestExecutor.ExecutorResponse, PollContext<Token>) async throws -> AIGeneration.Snapshot,
                resultPath: @escaping @Sendable (Token) -> String,
                resultDecode: @escaping @Sendable (AIRequestExecutor.ExecutorResponse, PollContext<Token>) async throws -> Response,
                cancel: CancelSpec? = nil
            ) {
                self.id = id
                self.provider = provider
                self.unsupportedCheck = unsupportedCheck
                self.prepare = prepare
                self.startBodyFrom = startBodyFrom
                self.startDecode = startDecode
                self.statusPath = statusPath
                self.statusDecode = statusDecode
                self.resultPath = resultPath
                self.resultDecode = resultDecode
                self.cancel = cancel
            }
        }

        // parity: ai/src/route/media-protocol.ts#queued [status=implemented hash=776c629081bc]
        public static func queued<Request: Sendable, Response: Sendable, Token: Codable & Sendable>(
            _ route: Identity,
            unsupportedCheck: (@Sendable (Request) -> [String])? = nil,
            prepare: Prepare<Request>? = nil,
            startBodyFrom: @escaping @Sendable (Request) async throws -> Body,
            startDecode: @escaping @Sendable (AIRequestExecutor.ExecutorResponse, DecodeContext<Request>) async throws -> Started<Token>,
            statusPath: @escaping @Sendable (Token) -> String,
            statusDecode: @escaping @Sendable (AIRequestExecutor.ExecutorResponse, PollContext<Token>) async throws -> AIGeneration.Snapshot,
            resultPath: @escaping @Sendable (Token) -> String,
            resultDecode: @escaping @Sendable (AIRequestExecutor.ExecutorResponse, PollContext<Token>) async throws -> Response,
            cancel: Queued<Request, Response, Token>.CancelSpec? = nil
        ) -> Queued<Request, Response, Token> {
            Queued(
                id: route.id,
                provider: route.provider,
                unsupportedCheck: unsupportedCheck,
                prepare: prepare,
                startBodyFrom: startBodyFrom,
                startDecode: startDecode,
                statusPath: statusPath,
                statusDecode: statusDecode,
                resultPath: resultPath,
                resultDecode: resultDecode,
                cancel: cancel
            )
        }

        // parity: ai/src/route/media-protocol.ts#Mode [status=implemented hash=4fb8eae5dd36]
        public enum Mode: String, Equatable, Hashable, Sendable, Codable {
            case generate
            case stream
        }

        // parity: ai/src/route/media-protocol.ts#Addressed [status=implemented hash=42dff29c9e06]
        public struct Addressed<Request: Sendable>: Sendable {
            public let request: Request
            public let mode: Mode

            public init(request: Request, mode: Mode) {
                self.request = request
                self.mode = mode
            }
        }

        // parity: ai/src/route/media-protocol.ts#ResponseContext [status=implemented hash=0a6c193aef90]
        public struct ResponseContext<Request: Sendable>: Sendable {
            public let request: Addressed<Request>
            public let body: Body
            public let http: AISchema.HttpContext

            public init(request: Addressed<Request>, body: Body, http: AISchema.HttpContext) {
                self.request = request
                self.body = body
                self.http = http
            }
        }

        // parity: ai/src/route/media-protocol.ts#Streamed [status=implemented hash=cbc70f88b1f0]
        public struct Streamed<Request: Sendable, Event: Sendable, Frame: Sendable, State: Sendable>: Sendable {
            public let id: String
            public let provider: AISchema.ProviderID
            public let unsupportedCheck: (@Sendable (Addressed<Request>) -> [String])?
            public let bodyFrom: @Sendable (Addressed<Request>) async throws -> Body
            public let frames: @Sendable (AsyncThrowingStream<[UInt8], Error>, DecodeContext<Addressed<Request>>) -> AsyncThrowingStream<Frame, Error>
            public let initial: @Sendable () -> State
            public let step: @Sendable (State, Frame) async throws -> (State, [Event])
            public let finish: @Sendable (State, ResponseContext<Request>) async throws -> [Event]

            public init(
                id: String,
                provider: AISchema.ProviderID,
                unsupportedCheck: (@Sendable (Addressed<Request>) -> [String])? = nil,
                bodyFrom: @escaping @Sendable (Addressed<Request>) async throws -> Body,
                frames: @escaping @Sendable (AsyncThrowingStream<[UInt8], Error>, DecodeContext<Addressed<Request>>) -> AsyncThrowingStream<Frame, Error>,
                initial: @escaping @Sendable () -> State,
                step: @escaping @Sendable (State, Frame) async throws -> (State, [Event]),
                finish: @escaping @Sendable (State, ResponseContext<Request>) async throws -> [Event]
            ) {
                self.id = id
                self.provider = provider
                self.unsupportedCheck = unsupportedCheck
                self.bodyFrom = bodyFrom
                self.frames = frames
                self.initial = initial
                self.step = step
                self.finish = finish
            }
        }

        // parity: ai/src/route/media-protocol.ts#stream [status=implemented hash=8f2c4f658329]
        public static func stream<Request: Sendable, Event: Sendable, Frame: Sendable, State: Sendable>(
            _ route: Identity,
            unsupportedCheck: (@Sendable (Addressed<Request>) -> [String])? = nil,
            bodyFrom: @escaping @Sendable (Addressed<Request>) async throws -> Body,
            frames: @escaping @Sendable (AsyncThrowingStream<[UInt8], Error>, DecodeContext<Addressed<Request>>) -> AsyncThrowingStream<Frame, Error>,
            initial: @escaping @Sendable () -> State,
            step: @escaping @Sendable (State, Frame) async throws -> (State, [Event]),
            finish: @escaping @Sendable (State, ResponseContext<Request>) async throws -> [Event]
        ) -> Streamed<Request, Event, Frame, State> {
            Streamed(
                id: route.id,
                provider: route.provider,
                unsupportedCheck: unsupportedCheck,
                bodyFrom: bodyFrom,
                frames: frames,
                initial: initial,
                step: step,
                finish: finish
            )
        }

        // parity: ai/src/route/media-protocol.ts#Failure [status=implemented hash=e1fd02b92571]
        public enum Failure: String, Equatable, Hashable, Sendable, Codable {
            case invalidRequest = "InvalidRequest"
            case authentication = "Authentication"
            case rateLimit = "RateLimit"
            case providerInternal = "ProviderInternal"
        }

        public struct TextOutput: Sendable {
            public let routeID: String
            public let routeName: String
            public let body: String
            public let http: AISchema.HttpContext

            public func invalid(_ message: String, cause: String? = nil) -> AISchema.AIError {
                AISchema.AIError(reason: .invalidProviderOutput(AISchema.InvalidProviderOutputError(
                    message: message,
                    body: body,
                    http: http,
                    cause: cause,
                    route: routeID
                )))
            }

            public func ended(
                reason: AIGeneration.Reason,
                message: String,
                failure: Failure = .providerInternal
            ) -> AISchema.AIError {
                guard reason == .failed else {
                    return AISchema.AIError(reason: .invalidRequest(AISchema.InvalidRequestError(
                        message: message,
                        body: body,
                        http: http
                    )))
                }
                switch failure {
                case .invalidRequest:
                    return AISchema.AIError(reason: .invalidRequest(AISchema.InvalidRequestError(message: message, body: body, http: http)))
                case .authentication:
                    return AISchema.AIError(reason: .authentication(AISchema.AuthenticationError(message: message, body: body, http: http)))
                case .rateLimit:
                    return AISchema.AIError(reason: .rateLimit(AISchema.RateLimitError(message: message, body: body, http: http)))
                case .providerInternal:
                    return AISchema.AIError(reason: .providerInternal(AISchema.ProviderInternalError(message: message, body: body, http: http)))
                }
            }

            public func pending(id: String) -> AISchema.AIError {
                AISchema.AIError(reason: .invalidRequest(AISchema.InvalidRequestError(
                    message: "\(routeName) generation \(id) has not finished; await it before reading the result",
                    body: body,
                    http: http
                )))
            }

            public func contentPolicy(_ message: String) -> AISchema.AIError {
                AISchema.AIError(reason: .contentPolicy(AISchema.ContentPolicyError(
                    message: message,
                    body: body,
                    http: http
                )))
            }
        }

        // parity: ai/src/route/media-protocol.ts#Identity [status=implemented hash=f7037fba45b5]
        public struct Identity: Sendable {
            public let id: String
            public let name: String
            public let provider: AISchema.ProviderID

            public init(id: String, name: String, provider: String) {
                self.id = id
                self.name = name
                self.provider = AISchema.ProviderID.make(provider)
            }

            public func frameError(_ message: String, body: String? = nil, cause: String? = nil) -> AISchema.AIError {
                AISchema.AIError(reason: .invalidProviderOutput(AISchema.InvalidProviderOutputError(
                    message: message,
                    body: body,
                    cause: cause,
                    route: id
                )))
            }

            public func text(_ response: AIRequestExecutor.ExecutorResponse) async throws -> TextOutput {
                let http = AIRequestExecutor.responseHttp(response)
                let body = try await AIRequestExecutor.responseText(response)
                return TextOutput(routeID: id, routeName: name, body: body, http: http)
            }

            public func bytes(_ response: AIRequestExecutor.ExecutorResponse) async throws -> [UInt8] {
                try await AIRequestExecutor.responseBytes(response)
            }

            public func decodeJson<A: Decodable & Sendable>(
                _ type: A.Type,
                from response: AIRequestExecutor.ExecutorResponse
            ) async throws -> (output: TextOutput, value: A) {
                let output = try await text(response)
                do {
                    let value = try JSONDecoder().decode(A.self, from: Data(output.body.utf8))
                    return (output, value)
                } catch {
                    throw output.invalid("\(name) returned an invalid response", cause: String(describing: error))
                }
            }

            public func decodeStarted<A: Decodable & Sendable, Token: Sendable>(
                _ type: A.Type,
                from response: AIRequestExecutor.ExecutorResponse,
                started: (A) -> Started<Token>
            ) async throws -> Started<Token> {
                let decoded = try await decodeJson(type, from: response)
                return started(decoded.value)
            }

            public func decodeFrame<A: Decodable & Sendable>(
                _ type: A.Type,
                frame: String
            ) throws(AISchema.AIError) -> A {
                do {
                    return try JSONDecoder().decode(A.self, from: Data(frame.utf8))
                } catch {
                    throw frameError("\(name) sent an invalid stream event", body: frame, cause: String(describing: error))
                }
            }

            public func incomplete() -> AISchema.AIError {
                AISchema.AIError(reason: .invalidProviderOutput(AISchema.InvalidProviderOutputError(
                    message: "The provider response ended unexpectedly.",
                    classification: .incompleteStream,
                    route: id
                )))
            }

            public func unsupported(operation: String, message: String) -> AISchema.AIError {
                AISchema.AIError(reason: .unsupportedOperation(AISchema.UnsupportedOperationError(
                    message: message,
                    operation: operation,
                    provider: provider,
                    route: id
                )))
            }
        }

        // parity: ai/src/route/media-protocol.ts#identity [status=implemented hash=3ff60396c148]
        public static func identity(id: String, name: String, provider: String) -> Identity {
            Identity(id: id, name: name, provider: provider)
        }

        // parity: ai/src/route/media-protocol.ts#State [status=implemented hash=1c7f84bdc8fe]
        public enum State: Equatable, Hashable, Sendable {
            case running
            case completed
            case error(AIGeneration.Reason)
        }

        // parity: ai/src/route/media-protocol.ts#state [status=implemented hash=82c7840ccab0]
        public static func state(_ table: [String: State], raw: String) -> State {
            table[raw] ?? .running
        }

        // parity: ai/src/route/media-protocol.ts#status [status=implemented hash=d54b488fd21d]
        public static func status(_ table: [String: State], raw: String) -> (status: AIGeneration.Status, reason: AIGeneration.Reason?) {
            switch state(table, raw: raw) {
            case .running: (.running, nil)
            case .completed: (.completed, nil)
            case .error(let r): (.error, r)
            }
        }

        // parity: ai/src/route/media-protocol.ts#failure [status=implemented hash=547078b26bbe]
        public static func failure(_ table: [String: Failure], code: String?) -> Failure {
            guard let code else { return .providerInternal }
            return table[code] ?? .providerInternal
        }

        // parity: ai/src/route/media-protocol.ts#expiringUrl [status=implemented hash=dd96aa959765]
        public static func expiringUrl(
            _ url: String,
            retentionMs: Double,
            nowEpochMs: Double? = nil,
            mediaType: String? = nil,
            options: AIMedia.AssetOptions? = nil
        ) -> AIMedia.Asset {
            let now = nowEpochMs ?? (Date().timeIntervalSince1970 * 1000.0)
            return AIMedia.url(url, mediaType: mediaType, expiresAt: now + retentionMs, options: options)
        }
    }

    // MARK: - src/route/media.ts

    public enum MediaRoute {
        // parity: ai/src/route/media.ts#Execute [status=implemented hash=54549ec5894c]
        public typealias Execute = @Sendable (HTTPRequest, AIRequestExecutor.HttpMiddleware?) async throws -> AIRequestExecutor.ExecutorResponse

        public struct ModelDescriptor: Sendable {
            public let id: String
            public let provider: AISchema.ProviderID
            public let transport: AISchema.TransportOptions?
            public let providerOptions: AISchema.ProviderOptions?

            public init(
                id: String,
                provider: AISchema.ProviderID,
                transport: AISchema.TransportOptions? = nil,
                providerOptions: AISchema.ProviderOptions? = nil
            ) {
                self.id = id
                self.provider = provider
                self.transport = transport
                self.providerOptions = providerOptions
            }
        }

        // parity: ai/src/route/media.ts#MediaRequest [status=adapted hash=38c9629087af]
        public protocol MediaRequest: Sendable {
            var modelDescriptor: ModelDescriptor { get }
            var headers: [String: String]? { get }
            var timeout: AISchema.RequestTimeout? { get }
            var http: AISchema.HttpOptions? { get }
            var providerOptions: AISchema.ProviderOptions? { get }
            var fetch: (any HTTPTransport)? { get }
        }

        // parity: ai/src/route/media.ts#ModelInput [status=implemented hash=c4ea6ac5e550]
        public struct ModelInput: Sendable {
            public let id: String
            public let auth: AIAuth.Definition
            public let baseURL: String?
            public let transport: AISchema.TransportOptions?
            public let providerOptions: AISchema.ProviderOptions?

            public init(
                id: String,
                auth: AIAuth.Definition,
                baseURL: String? = nil,
                transport: AISchema.TransportOptions? = nil,
                providerOptions: AISchema.ProviderOptions? = nil
            ) {
                self.id = id
                self.auth = auth
                self.baseURL = baseURL
                self.transport = transport
                self.providerOptions = providerOptions
            }
        }

        public struct DeploymentConfig: Sendable {
            public let auth: AIAuth.Definition
            public let baseURL: String?
            public let transport: AISchema.TransportOptions?

            public init(auth: AIAuth.Definition, baseURL: String? = nil, transport: AISchema.TransportOptions? = nil) {
                self.auth = auth
                self.baseURL = baseURL
                self.transport = transport
            }
        }

        // parity: ai/src/route/media.ts#deployment [status=implemented hash=a296662b0b83]
        public static func deployment(
            baseURL: String? = nil,
            transport: AISchema.TransportOptions? = nil,
            auth: AIAuth.Definition
        ) -> DeploymentConfig {
            DeploymentConfig(auth: auth, baseURL: baseURL, transport: AISchema.mergeTransport(transport))
        }

        // parity: ai/src/route/media.ts#InlineRoute [status=implemented hash=839b6e322076]
        public struct InlineRoute<Request: MediaRequest, Response: Sendable>: Sendable {
            public let id: String
            public let provider: AISchema.ProviderID
            public let protocolID: String
            public let generate: @Sendable (Request, @escaping Execute) async throws -> Response

            public init(
                id: String,
                provider: AISchema.ProviderID,
                protocolID: String,
                generate: @escaping @Sendable (Request, @escaping Execute) async throws -> Response
            ) {
                self.id = id
                self.provider = provider
                self.protocolID = protocolID
                self.generate = generate
            }
        }

        // parity: ai/src/route/media.ts#QueuedRoute [status=implemented hash=0d3cfe6754f2]
        public struct QueuedRoute<Request: MediaRequest, Response: Sendable>: Sendable {
            public let id: String
            public let provider: AISchema.ProviderID
            public let protocolID: String
            public let start: @Sendable (Request, @escaping Execute) async throws -> AIGeneration.Generation<Response>
            public let resume: @Sendable (ModelDescriptor, JSONValue, @escaping Execute) async throws -> AIGeneration.Generation<Response>
            public let attach: @Sendable (ModelDescriptor, JSONValue, @escaping Execute) async throws -> AIGeneration.Route<Response>

            public init(
                id: String,
                provider: AISchema.ProviderID,
                protocolID: String,
                start: @escaping @Sendable (Request, @escaping Execute) async throws -> AIGeneration.Generation<Response>,
                resume: @escaping @Sendable (ModelDescriptor, JSONValue, @escaping Execute) async throws -> AIGeneration.Generation<Response>,
                attach: @escaping @Sendable (ModelDescriptor, JSONValue, @escaping Execute) async throws -> AIGeneration.Route<Response>
            ) {
                self.id = id
                self.provider = provider
                self.protocolID = protocolID
                self.start = start
                self.resume = resume
                self.attach = attach
            }
        }

        // parity: ai/src/route/media.ts#StreamRoute [status=implemented hash=ee8d9c415e3a]
        public struct StreamRoute<Request: MediaRequest, Event: Sendable, Response: Sendable>: Sendable {
            public let id: String
            public let provider: AISchema.ProviderID
            public let protocolID: String
            public let stream: @Sendable (Request, @escaping Execute) -> AsyncThrowingStream<Event, Error>
            public let generate: @Sendable (Request, @escaping Execute) async throws -> Response

            public init(
                id: String,
                provider: AISchema.ProviderID,
                protocolID: String,
                stream: @escaping @Sendable (Request, @escaping Execute) -> AsyncThrowingStream<Event, Error>,
                generate: @escaping @Sendable (Request, @escaping Execute) async throws -> Response
            ) {
                self.id = id
                self.provider = provider
                self.protocolID = protocolID
                self.stream = stream
                self.generate = generate
            }
        }

        // parity: ai/src/route/media.ts#AnyRoute [status=implemented hash=13a3799f33ac]
        public enum AnyRoute<Request: MediaRequest, Event: Sendable, Response: Sendable>: Sendable {
            case inline(InlineRoute<Request, Response>)
            case stream(StreamRoute<Request, Event, Response>)
            case queued(QueuedRoute<Request, Response>)

            public var id: String {
                switch self {
                case .inline(let r): r.id
                case .stream(let r): r.id
                case .queued(let r): r.id
                }
            }

            public var provider: AISchema.ProviderID {
                switch self {
                case .inline(let r): r.provider
                case .stream(let r): r.provider
                case .queued(let r): r.provider
                }
            }

            public var kind: String {
                switch self {
                case .inline: "inline"
                case .stream: "stream"
                case .queued: "queued"
                }
            }
        }

        // parity: ai/src/route/media.ts#Composition [status=implemented hash=d7854acd323e]
        public struct Composition<Request: Sendable>: Sendable {
            public let endpoint: AIEndpoint.Definition<MediaProtocol.Body, Request>
            public let auth: AIAuth.Definition
            public let headers: [String: String]?

            public init(
                endpoint: AIEndpoint.Definition<MediaProtocol.Body, Request>,
                auth: AIAuth.Definition,
                headers: [String: String]? = nil
            ) {
                self.endpoint = endpoint
                self.auth = auth
                self.headers = headers
            }
        }

        // parity: ai/src/route/media.ts#InlineInput [status=implemented hash=6affffbe472c]
        public struct InlineInput<Request: MediaRequest, Response: Sendable>: Sendable {
            public let composition: Composition<Request>
            public let wireProtocol: MediaProtocol.Inline<Request, Response>

            public init(
                protocol wireProtocol: MediaProtocol.Inline<Request, Response>,
                endpoint: AIEndpoint.Definition<MediaProtocol.Body, Request>,
                auth: AIAuth.Definition,
                headers: [String: String]? = nil
            ) {
                self.composition = Composition(endpoint: endpoint, auth: auth, headers: headers)
                self.wireProtocol = wireProtocol
            }
        }

        // parity: ai/src/route/media.ts#QueuedInput [status=implemented hash=02026f936c11]
        public struct QueuedInput<Request: MediaRequest, Response: Sendable, Token: Codable & Sendable>: Sendable {
            public let composition: Composition<Request>
            public let wireProtocol: MediaProtocol.Queued<Request, Response, Token>

            public init(
                protocol wireProtocol: MediaProtocol.Queued<Request, Response, Token>,
                endpoint: AIEndpoint.Definition<MediaProtocol.Body, Request>,
                auth: AIAuth.Definition,
                headers: [String: String]? = nil
            ) {
                self.composition = Composition(endpoint: endpoint, auth: auth, headers: headers)
                self.wireProtocol = wireProtocol
            }
        }

        // parity: ai/src/route/media.ts#StreamInput [status=implemented hash=b7ff49ba05cc]
        public struct StreamInput<Request: MediaRequest, Event: Sendable, Response: Sendable, Frame: Sendable, State: Sendable>: Sendable {
            public let composition: Composition<MediaProtocol.Addressed<Request>>
            public let wireProtocol: MediaProtocol.Streamed<Request, Event, Frame, State>
            public let collect: @Sendable ([Event]) async throws -> Response

            public init(
                protocol wireProtocol: MediaProtocol.Streamed<Request, Event, Frame, State>,
                endpoint: AIEndpoint.Definition<MediaProtocol.Body, MediaProtocol.Addressed<Request>>,
                auth: AIAuth.Definition,
                headers: [String: String]? = nil,
                collect: @escaping @Sendable ([Event]) async throws -> Response
            ) {
                self.composition = Composition(endpoint: endpoint, auth: auth, headers: headers)
                self.wireProtocol = wireProtocol
                self.collect = collect
            }
        }

        private struct Exchange: Sendable {
            let headers: [String: String]?
            let timeout: AISchema.RequestTimeout?
            let http: AISchema.HttpOptions?
            let fetch: (any HTTPTransport)?
        }

        private static func encodeBody(
            _ body: MediaProtocol.Body?,
            headers: [String: String]
        ) throws(AISchema.AIError) -> (text: String, headers: [String: String], bytes: [UInt8]?) {
            guard let body else { return ("", headers, nil) }
            switch body {
            case .json(let obj, _):
                let text: String
                do {
                    text = try AIUtils.encodeJson(.object(obj))
                } catch {
                    throw AISchema.AIError(reason: .invalidRequest(AISchema.InvalidRequestError(
                        message: "Failed to encode JSON body: \(error)"
                    )))
                }
                var h = headers
                h["content-type"] = "application/json"
                return (text, h, Array(text.utf8))
            case .binary(let data, let contentType, _):
                var h = headers
                h["content-type"] = contentType
                return ("[\(contentType)]", h, data)
            case .multipart(let form):
                let encoded = form.encode()
                var h = headers.filter { $0.key.lowercased() != "content-type" }
                h["content-type"] = encoded.contentType
                return ("[multipart/form-data]", h, encoded.body)
            }
        }

        private static func sendRequest(
            auth: AIAuth.Definition,
            method: AIAuth.AuthInput.Method,
            url: URL,
            headers: [String: String],
            httpOptions: AISchema.HttpOptions?,
            body: MediaProtocol.Body?,
            timeout: AISchema.RequestTimeout?,
            fetch: (any HTTPTransport)?,
            execute: @escaping Execute
        ) async throws -> AIRequestExecutor.ExecutorResponse {
            let encoded = try encodeBody(body, headers: headers)
            let signed = try await AIAuth.toEffect(auth)(AIAuth.AuthInput(
                httpOptions: httpOptions,
                method: method,
                url: url.absoluteString,
                body: encoded.text,
                headers: encoded.headers
            ))
            let req = HTTPRequest(method: method.rawValue, url: url.absoluteString, headers: signed, body: encoded.bytes)
            let exec = AIRequestExecutor.withTimeout(
                AIRequestExecutor.withTls(execute, tls: httpOptions?.tls),
                timeout: timeout
            )
            return try await exec(req, AIRequestExecutor.withFetch(fetch))
        }

        private static func rejectUnsupported(
            route: String,
            provider: AISchema.ProviderID,
            fields: [String]
        ) throws(AISchema.AIError) {
            guard let first = fields.first else { return }
            throw AISchema.AIError(reason: .unsupportedOperation(AISchema.UnsupportedOperationError(
                message: "\(provider.rawValue)/\(route) does not support \(fields.joined(separator: ", "))",
                operation: "media.\(first)",
                provider: provider,
                route: route
            )))
        }

        private static func applyQuery(_ url: URL, query: MediaProtocol.Query?) -> URL {
            guard let query, !query.isEmpty else { return url }
            let pairs = query.keys.sorted().compactMap { k -> (String, [String])? in
                query[k].map { (k, $0) }
            }
            return AIEndpoint.setQueryParams(url, query: pairs)
        }

        private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
            lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
                && lhs.host?.lowercased() == rhs.host?.lowercased()
                && lhs.port == rhs.port
        }

        // parity: ai/src/route/media.ts#inline [status=implemented hash=fb3ae58105e1]
        public static func inline<Request: MediaRequest, Response: Sendable>(
            _ input: InlineInput<Request, Response>
        ) -> InlineRoute<Request, Response> {
            let proto = input.wireProtocol
            let comp = input.composition
            return InlineRoute(id: proto.id, provider: proto.provider, protocolID: proto.id) { request, execute in
                if let check = proto.unsupportedCheck {
                    try rejectUnsupported(route: proto.id, provider: proto.provider, fields: check(request))
                }
                let merged = AISchema.mergeTransport(
                    AISchema.TransportOptions(headers: comp.headers),
                    request.modelDescriptor.transport,
                    AISchema.TransportOptions(headers: request.headers, timeout: request.timeout, http: request.http)
                )
                let body = try await proto.bodyFrom(request)
                var url = try AIEndpoint.render(comp.endpoint, input: AIEndpoint.EndpointInput(request: request, body: body))
                url = applyQuery(url, query: body.query)
                if let extraQ = merged.http?.query {
                    url = applyQuery(url, query: extraQ.mapValues { [$0] })
                }
                let response = try await sendRequest(
                    auth: comp.auth,
                    method: .POST,
                    url: url,
                    headers: merged.headers ?? [:],
                    httpOptions: merged.http,
                    body: body,
                    timeout: merged.timeout,
                    fetch: request.fetch,
                    execute: execute
                )
                return try await proto.decodeResponse(response, MediaProtocol.DecodeContext(request: request, body: body))
            }
        }

        // parity: ai/src/route/media.ts#queued [status=implemented hash=c87f17c0c9e8]
        public static func queued<Request: MediaRequest, Response: Sendable, Token: Codable & Sendable>(
            _ input: QueuedInput<Request, Response, Token>
        ) -> QueuedRoute<Request, Response> {
            let proto = input.wireProtocol
            let comp = input.composition

            @Sendable func makeURL(for path: String, exchange: Exchange) throws(AISchema.AIError) -> URL {
                let raw = (path.hasPrefix("http://") || path.hasPrefix("https://"))
                    ? path
                    : "\(AIEndpoint.trimBaseUrl(comp.endpoint.baseURL ?? ""))\(path)"
                guard var url = URL(string: raw) else {
                    throw AISchema.AIError(reason: .invalidRequest(AISchema.InvalidRequestError(
                        message: "Invalid media route URL: \(raw)"
                    )))
                }
                if let extraQ = exchange.http?.query {
                    url = applyQuery(url, query: extraQ.mapValues { [$0] })
                }
                if let endpointQ = comp.endpoint.query {
                    url = applyQuery(url, query: endpointQ.mapValues { [$0] })
                }
                return url
            }

            @Sendable func makeGenerationRoute(
                token: Token,
                exchange: Exchange,
                execute: @escaping Execute
            ) -> AIGeneration.Route<Response> {
                let getOp: @Sendable (String) async throws -> AIRequestExecutor.ExecutorResponse = { path in
                    let url = try makeURL(for: path, exchange: exchange)
                    return try await sendRequest(
                        auth: comp.auth,
                        method: .GET,
                        url: url,
                        headers: exchange.headers ?? [:],
                        httpOptions: exchange.http,
                        body: nil,
                        timeout: exchange.timeout,
                        fetch: exchange.fetch,
                        execute: execute
                    )
                }

                let credentialsOp: @Sendable (String) async throws -> MediaProtocol.DownloadCredentials = { rawUrl in
                    guard let target = URL(string: rawUrl),
                          let base = URL(string: AIEndpoint.trimBaseUrl(comp.endpoint.baseURL ?? "")),
                          sameOrigin(target, base)
                    else {
                        return MediaProtocol.DownloadCredentials()
                    }
                    let signed = try await AIAuth.toEffect(comp.auth)(AIAuth.AuthInput(
                        httpOptions: exchange.http,
                        method: .GET,
                        url: rawUrl,
                        body: "",
                        headers: exchange.headers ?? [:]
                    ))
                    return MediaProtocol.DownloadCredentials(headers: signed, middleware: AIRequestExecutor.CurrentMiddleware)
                }

                let pollContext = MediaProtocol.PollContext(token: token, credentials: credentialsOp, get: getOp)

                let cancelOp: (@Sendable () async throws -> Void)?
                if let spec = proto.cancel {
                    cancelOp = {
                        let url = try makeURL(for: spec.path(token), exchange: exchange)
                        _ = try await sendRequest(
                            auth: comp.auth,
                            method: spec.method,
                            url: url,
                            headers: exchange.headers ?? [:],
                            httpOptions: exchange.http,
                            body: nil,
                            timeout: exchange.timeout,
                            fetch: exchange.fetch,
                            execute: execute
                        )
                    }
                } else {
                    cancelOp = nil
                }

                return AIGeneration.Route(
                    status: {
                        let resp = try await getOp(proto.statusPath(token))
                        return try await proto.statusDecode(resp, pollContext)
                    },
                    result: {
                        let resp = try await getOp(proto.resultPath(token))
                        return try await proto.resultDecode(resp, pollContext)
                    },
                    cancel: cancelOp
                )
            }

            @Sendable func encodeToken(_ token: Token) -> JSONValue {
                guard let data = try? JSONEncoder().encode(token),
                      let value = try? JSONDecoder().decode(JSONValue.self, from: data)
                else {
                    return .null
                }
                return value
            }

            @Sendable func decodeToken(_ raw: JSONValue) throws(AISchema.AIError) -> Token {
                do {
                    let data = try JSONEncoder().encode(raw)
                    return try JSONDecoder().decode(Token.self, from: data)
                } catch {
                    throw AISchema.AIError(reason: .invalidRequest(AISchema.InvalidRequestError(
                        message: "\(proto.id) cannot resume a generation from this token",
                        cause: String(describing: error)
                    )))
                }
            }

            return QueuedRoute(
                id: proto.id,
                provider: proto.provider,
                protocolID: proto.id,
                start: { request, execute in
                    if let check = proto.unsupportedCheck {
                        try rejectUnsupported(route: proto.id, provider: proto.provider, fields: check(request))
                    }
                    let merged = AISchema.mergeTransport(
                        AISchema.TransportOptions(headers: comp.headers),
                        request.modelDescriptor.transport,
                        AISchema.TransportOptions(headers: request.headers, timeout: request.timeout, http: request.http)
                    )
                    let exchange = Exchange(headers: merged.headers, timeout: merged.timeout, http: merged.http, fetch: request.fetch)
                    let prepared: Request
                    if let prepare = proto.prepare {
                        prepared = try await prepare(request) { path, body in
                            let url = try makeURL(for: path, exchange: exchange)
                            return try await sendRequest(
                                auth: comp.auth,
                                method: .POST,
                                url: url,
                                headers: exchange.headers ?? [:],
                                httpOptions: exchange.http,
                                body: body,
                                timeout: exchange.timeout,
                                fetch: exchange.fetch,
                                execute: execute
                            )
                        }
                    } else {
                        prepared = request
                    }
                    let body = try await proto.startBodyFrom(prepared)
                    var url = try AIEndpoint.render(comp.endpoint, input: AIEndpoint.EndpointInput(request: prepared, body: body))
                    url = applyQuery(url, query: body.query)
                    if let extraQ = merged.http?.query {
                        url = applyQuery(url, query: extraQ.mapValues { [$0] })
                    }
                    let resp = try await sendRequest(
                        auth: comp.auth,
                        method: .POST,
                        url: url,
                        headers: merged.headers ?? [:],
                        httpOptions: merged.http,
                        body: body,
                        timeout: merged.timeout,
                        fetch: request.fetch,
                        execute: execute
                    )
                    let started = try await proto.startDecode(resp, MediaProtocol.DecodeContext(request: prepared, body: body))
                    let genRoute = makeGenerationRoute(token: started.token, exchange: exchange, execute: execute)
                    return AIGeneration.Generation(route: genRoute, token: encodeToken(started.token), snapshot: started.snapshot)
                },
                resume: { model, rawToken, execute in
                    let token = try decodeToken(rawToken)
                    let merged = AISchema.mergeTransport(AISchema.TransportOptions(headers: comp.headers), model.transport)
                    let exchange = Exchange(headers: merged.headers, timeout: merged.timeout, http: merged.http, fetch: nil)
                    let genRoute = makeGenerationRoute(token: token, exchange: exchange, execute: execute)
                    let snapshot = try await genRoute.status()
                    return AIGeneration.Generation(route: genRoute, token: encodeToken(token), snapshot: snapshot)
                },
                attach: { model, rawToken, execute in
                    let token = try decodeToken(rawToken)
                    let merged = AISchema.mergeTransport(AISchema.TransportOptions(headers: comp.headers), model.transport)
                    let exchange = Exchange(headers: merged.headers, timeout: merged.timeout, http: merged.http, fetch: nil)
                    return makeGenerationRoute(token: token, exchange: exchange, execute: execute)
                }
            )
        }

        // parity: ai/src/route/media.ts#stream [status=implemented hash=427f618d74bd]
        public static func stream<Request: MediaRequest, Event: Sendable, Response: Sendable, Frame: Sendable, State: Sendable>(
            _ input: StreamInput<Request, Event, Response, Frame, State>
        ) -> StreamRoute<Request, Event, Response> {
            let proto = input.wireProtocol
            let comp = input.composition
            let collectFn = input.collect

            @Sendable func runEvents(
                request: Request,
                execute: @escaping Execute,
                mode: MediaProtocol.Mode
            ) -> AsyncThrowingStream<Event, Error> {
                AsyncThrowingStream { continuation in
                    let task = Task {
                        do {
                            let addressed = MediaProtocol.Addressed(request: request, mode: mode)
                            if let check = proto.unsupportedCheck {
                                try rejectUnsupported(route: proto.id, provider: proto.provider, fields: check(addressed))
                            }
                            let merged = AISchema.mergeTransport(
                                AISchema.TransportOptions(headers: comp.headers),
                                request.modelDescriptor.transport,
                                AISchema.TransportOptions(headers: request.headers, timeout: request.timeout, http: request.http)
                            )
                            let body = try await proto.bodyFrom(addressed)
                            var url = try AIEndpoint.render(comp.endpoint, input: AIEndpoint.EndpointInput(request: addressed, body: body))
                            url = applyQuery(url, query: body.query)
                            if let extraQ = merged.http?.query {
                                url = applyQuery(url, query: extraQ.mapValues { [$0] })
                            }
                            let response = try await sendRequest(
                                auth: comp.auth,
                                method: .POST,
                                url: url,
                                headers: merged.headers ?? [:],
                                httpOptions: merged.http,
                                body: body,
                                timeout: merged.timeout,
                                fetch: request.fetch,
                                execute: execute
                            )
                            let http = AIRequestExecutor.responseHttp(response)
                            let decodeCtx = MediaProtocol.DecodeContext(request: addressed, body: body)
                            var state = proto.initial()
                            do {
                                for try await frame in proto.frames(AIRequestExecutor.responseStream(response), decodeCtx) {
                                    let (nextState, events) = try await proto.step(state, frame)
                                    state = nextState
                                    for ev in events { continuation.yield(ev) }
                                }
                                let finalEvents = try await proto.finish(
                                    state,
                                    MediaProtocol.ResponseContext(request: addressed, body: body, http: http)
                                )
                                for ev in finalEvents { continuation.yield(ev) }
                                continuation.finish()
                            } catch let aiError as AISchema.AIError {
                                continuation.finish(throwing: AISchema.AIError(
                                    reason: aiError.reason.http != nil ? aiError.reason : aiError.reason.with(http: http)
                                ))
                            }
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
            }

            return StreamRoute(
                id: proto.id,
                provider: proto.provider,
                protocolID: proto.id,
                stream: { request, execute in runEvents(request: request, execute: execute, mode: .stream) },
                generate: { request, execute in
                    var collected: [Event] = []
                    do {
                        for try await ev in runEvents(request: request, execute: execute, mode: .generate) {
                            collected.append(ev)
                        }
                    } catch let aiError as AISchema.AIError {
                        throw aiError
                    } catch {
                        throw AISchema.AIError(reason: .unknownProvider(AISchema.UnknownProviderError(
                            message: String(describing: error)
                        )))
                    }
                    return try await collectFn(collected)
                }
            )
        }
    }

    // MARK: - src/route/decision.ts

    public enum DecisionRoute {
        // parity: ai/src/route/decision.ts#Protocol [status=implemented hash=57a233ef31ee]
        public struct ProtocolSpec: Sendable {
            public struct DecodeContext: Sendable {
                public let request: AIDecision.DecisionRequest
                public let providerMetadataKey: String

                public init(request: AIDecision.DecisionRequest, providerMetadataKey: String) {
                    self.request = request
                    self.providerMetadataKey = providerMetadataKey
                }
            }

            public let id: String
            public let name: String
            public let inlineMedia: Bool
            public let bodyFrom: @Sendable (AIDecision.DecisionRequest) async throws -> [String: JSONValue]
            public let decodeResponse: @Sendable (AIRequestExecutor.ExecutorResponse, DecodeContext) async throws -> AIDecision.DecisionResponse

            public init(
                id: String,
                name: String,
                inlineMedia: Bool = false,
                bodyFrom: @escaping @Sendable (AIDecision.DecisionRequest) async throws -> [String: JSONValue],
                decodeResponse: @escaping @Sendable (AIRequestExecutor.ExecutorResponse, DecodeContext) async throws -> AIDecision.DecisionResponse
            ) {
                self.id = id
                self.name = name
                self.inlineMedia = inlineMedia
                self.bodyFrom = bodyFrom
                self.decodeResponse = decodeResponse
            }
        }

        // parity: ai/src/route/decision.ts#protocol [status=implemented hash=4ed7b9f1a90c]
        public static func `protocol`(_ input: ProtocolSpec) -> ProtocolSpec {
            input
        }

        // parity: ai/src/route/decision.ts#Patch [status=implemented hash=78d527a7d962]
        public struct Patch: Sendable {
            public let id: String?
            public let provider: String?
            public let providerMetadataKey: String?
            public let endpoint: AIEndpoint.EndpointPatch<MediaProtocol.Body, AIDecision.DecisionRequest>?
            public let auth: AIAuth.Definition?
            public let transport: AISchema.TransportOptions?

            public init(
                id: String? = nil,
                provider: String? = nil,
                providerMetadataKey: String? = nil,
                endpoint: AIEndpoint.EndpointPatch<MediaProtocol.Body, AIDecision.DecisionRequest>? = nil,
                auth: AIAuth.Definition? = nil,
                transport: AISchema.TransportOptions? = nil
            ) {
                self.id = id
                self.provider = provider
                self.providerMetadataKey = providerMetadataKey
                self.endpoint = endpoint
                self.auth = auth
                self.transport = transport
            }
        }

        // parity: ai/src/route/decision.ts#MakeInput [status=implemented hash=97808e5f7cf3]
        public struct MakeInput: Sendable {
            public let id: String
            public let provider: String
            public let providerMetadataKey: String?
            public let wireProtocol: ProtocolSpec
            public let endpoint: AIEndpoint.Definition<MediaProtocol.Body, AIDecision.DecisionRequest>
            public let auth: AIAuth.Definition?
            public let transport: AISchema.TransportOptions?

            public init(
                id: String,
                provider: String,
                providerMetadataKey: String? = nil,
                protocol wireProtocol: ProtocolSpec,
                endpoint: AIEndpoint.Definition<MediaProtocol.Body, AIDecision.DecisionRequest>,
                auth: AIAuth.Definition? = nil,
                transport: AISchema.TransportOptions? = nil
            ) {
                self.id = id
                self.provider = provider
                self.providerMetadataKey = providerMetadataKey
                self.wireProtocol = wireProtocol
                self.endpoint = endpoint
                self.auth = auth
                self.transport = transport
            }
        }

        // parity: ai/src/route/decision.ts#Route [status=implemented hash=7f8e2db5a7a3]
        public struct Route: Sendable {
            public let id: String
            public let provider: AISchema.ProviderID
            public let providerMetadataKey: String
            public let wireProtocol: ProtocolSpec
            public let endpoint: AIEndpoint.Definition<MediaProtocol.Body, AIDecision.DecisionRequest>
            public let auth: AIAuth.Definition
            public let transport: AISchema.TransportOptions

            public func with(_ patch: Patch) -> Route {
                DecisionRoute.make(MakeInput(
                    id: patch.id ?? id,
                    provider: patch.provider ?? provider.rawValue,
                    providerMetadataKey: patch.providerMetadataKey ?? (patch.provider == nil ? providerMetadataKey : nil),
                    protocol: wireProtocol,
                    endpoint: patch.endpoint.map { AIEndpoint.merge(endpoint, $0) } ?? endpoint,
                    auth: patch.auth ?? auth,
                    transport: AISchema.mergeTransport(transport, patch.transport)
                ))
            }

            public func model(
                id modelID: String,
                compatibility: AIDecision.DecisionModelCompatibility? = nil,
                providerOptions: AISchema.ProviderOptions? = nil
            ) -> AIDecision.DecisionModel {
                let routeCopy = self
                let identity = MediaProtocol.identity(id: routeCopy.id, name: routeCopy.wireProtocol.name, provider: routeCopy.provider.rawValue)
                let composed = MediaRoute.inline(MediaRoute.InlineInput<AIDecision.DecisionRequest, AIDecision.DecisionResponse>(
                    protocol: MediaProtocol.inline(
                        identity,
                        bodyFrom: { req in
                            MediaProtocol.json(try await routeCopy.wireProtocol.bodyFrom(req))
                        },
                        decodeResponse: { resp, ctx in
                            try await routeCopy.wireProtocol.decodeResponse(
                                resp,
                                ProtocolSpec.DecodeContext(request: ctx.request, providerMetadataKey: routeCopy.providerMetadataKey)
                            )
                        }
                    ),
                    endpoint: routeCopy.endpoint,
                    auth: routeCopy.auth
                ))

                return AIDecision.DecisionModel.make(AIDecision.DecisionModel.MakeInput(
                    id: modelID,
                    provider: provider.rawValue,
                    route: AIDecision.DecisionModelRoute(id: id) { req, execute in
                        guard routeCopy.wireProtocol.inlineMedia else {
                            return try await composed.generate(req, execute)
                        }
                        let timed = AIRequestExecutor.withTimeout(
                            execute,
                            timeout: AISchema.mergeTransport(req.model.transport, AISchema.TransportOptions(headers: req.headers, timeout: req.timeout, http: req.http)).timeout
                        )
                        let execService = AIRequestExecutor.RequestExecutorService(execute: timed)
                        var materialized: [AIDecision.DecisionPart] = []
                        materialized.reserveCapacity(req.input.count)
                        for part in req.input {
                            if case .media(let m) = part, case .url = m.media.source {
                                let owned = try await m.media.materialize(executor: execService)
                                materialized.append(.media(AIDecision.DecisionMediaPart(media: owned, filename: m.filename)))
                            } else {
                                materialized.append(part)
                            }
                        }
                        let updatedReq = AIDecision.DecisionRequest(
                            model: req.model,
                            input: materialized,
                            questions: req.questions,
                            providerOptions: req.providerOptions,
                            headers: req.headers,
                            timeout: req.timeout,
                            http: req.http,
                            fetch: req.fetch
                        )
                        return try await composed.generate(updatedReq, execute)
                    },
                    transport: transport,
                    compatibility: compatibility,
                    providerOptions: providerOptions
                ))
            }
        }

        // parity: ai/src/route/decision.ts#make [status=implemented hash=ace7ae560d8b]
        public static func make(_ input: MakeInput) -> Route {
            let providerID = AISchema.ProviderID.make(input.provider)
            return Route(
                id: input.id,
                provider: providerID,
                providerMetadataKey: input.providerMetadataKey ?? providerID.rawValue,
                wireProtocol: input.wireProtocol,
                endpoint: input.endpoint,
                auth: input.auth ?? AIAuth.none,
                transport: AISchema.mergeTransport(input.transport)
            )
        }
    }

    // MARK: - src/route/embedding.ts

    public enum EmbeddingRoute {
        // parity: ai/src/route/embedding.ts#Protocol [status=implemented hash=8c47610a6fb8]
        public struct ProtocolSpec: Sendable {
            public struct DecodeContext: Sendable {
                public let request: AIEmbedding.EmbeddingRequest
                public let providerMetadataKey: String

                public init(request: AIEmbedding.EmbeddingRequest, providerMetadataKey: String) {
                    self.request = request
                    self.providerMetadataKey = providerMetadataKey
                }
            }

            public let id: String
            public let name: String
            public let bodyFrom: @Sendable (AIEmbedding.EmbeddingRequest) async throws -> [String: JSONValue]
            public let decodeResponse: @Sendable (AIRequestExecutor.ExecutorResponse, DecodeContext) async throws -> AIEmbedding.EmbeddingResponse

            public init(
                id: String,
                name: String,
                bodyFrom: @escaping @Sendable (AIEmbedding.EmbeddingRequest) async throws -> [String: JSONValue],
                decodeResponse: @escaping @Sendable (AIRequestExecutor.ExecutorResponse, DecodeContext) async throws -> AIEmbedding.EmbeddingResponse
            ) {
                self.id = id
                self.name = name
                self.bodyFrom = bodyFrom
                self.decodeResponse = decodeResponse
            }
        }

        // parity: ai/src/route/embedding.ts#protocol [status=implemented hash=4ed7b9f1a90c]
        public static func `protocol`(_ input: ProtocolSpec) -> ProtocolSpec {
            input
        }

        // parity: ai/src/route/embedding.ts#Patch [status=implemented hash=907fab5ab104]
        public struct Patch: Sendable {
            public let id: String?
            public let provider: String?
            public let providerMetadataKey: String?
            public let endpoint: AIEndpoint.EndpointPatch<MediaProtocol.Body, AIEmbedding.EmbeddingRequest>?
            public let auth: AIAuth.Definition?
            public let transport: AISchema.TransportOptions?
            public let maxValues: Int?

            public init(
                id: String? = nil,
                provider: String? = nil,
                providerMetadataKey: String? = nil,
                endpoint: AIEndpoint.EndpointPatch<MediaProtocol.Body, AIEmbedding.EmbeddingRequest>? = nil,
                auth: AIAuth.Definition? = nil,
                transport: AISchema.TransportOptions? = nil,
                maxValues: Int? = nil
            ) {
                self.id = id
                self.provider = provider
                self.providerMetadataKey = providerMetadataKey
                self.endpoint = endpoint
                self.auth = auth
                self.transport = transport
                self.maxValues = maxValues
            }
        }

        // parity: ai/src/route/embedding.ts#MakeInput [status=implemented hash=149b566d9a3e]
        public struct MakeInput: Sendable {
            public let id: String
            public let provider: String
            public let providerMetadataKey: String?
            public let wireProtocol: ProtocolSpec
            public let endpoint: AIEndpoint.Definition<MediaProtocol.Body, AIEmbedding.EmbeddingRequest>
            public let auth: AIAuth.Definition?
            public let transport: AISchema.TransportOptions?
            public let maxValues: Int?

            public init(
                id: String,
                provider: String,
                providerMetadataKey: String? = nil,
                protocol wireProtocol: ProtocolSpec,
                endpoint: AIEndpoint.Definition<MediaProtocol.Body, AIEmbedding.EmbeddingRequest>,
                auth: AIAuth.Definition? = nil,
                transport: AISchema.TransportOptions? = nil,
                maxValues: Int? = nil
            ) {
                self.id = id
                self.provider = provider
                self.providerMetadataKey = providerMetadataKey
                self.wireProtocol = wireProtocol
                self.endpoint = endpoint
                self.auth = auth
                self.transport = transport
                self.maxValues = maxValues
            }
        }

        // parity: ai/src/route/embedding.ts#Route [status=implemented hash=9c2485777f79]
        public struct Route: Sendable {
            public let id: String
            public let provider: AISchema.ProviderID
            public let providerMetadataKey: String
            public let wireProtocol: ProtocolSpec
            public let endpoint: AIEndpoint.Definition<MediaProtocol.Body, AIEmbedding.EmbeddingRequest>
            public let auth: AIAuth.Definition
            public let transport: AISchema.TransportOptions
            public let maxValues: Int?

            public func with(_ patch: Patch) -> Route {
                EmbeddingRoute.make(MakeInput(
                    id: patch.id ?? id,
                    provider: patch.provider ?? provider.rawValue,
                    providerMetadataKey: patch.providerMetadataKey ?? (patch.provider == nil ? providerMetadataKey : nil),
                    protocol: wireProtocol,
                    endpoint: patch.endpoint.map { AIEndpoint.merge(endpoint, $0) } ?? endpoint,
                    auth: patch.auth ?? auth,
                    transport: AISchema.mergeTransport(transport, patch.transport),
                    maxValues: patch.maxValues ?? maxValues
                ))
            }

            public func model(
                id modelID: String,
                providerOptions: AISchema.ProviderOptions? = nil
            ) -> AIEmbedding.EmbeddingModel {
                let routeCopy = self
                let identity = MediaProtocol.identity(id: routeCopy.id, name: routeCopy.wireProtocol.name, provider: routeCopy.provider.rawValue)
                let composed = MediaRoute.inline(MediaRoute.InlineInput<AIEmbedding.EmbeddingRequest, AIEmbedding.EmbeddingResponse>(
                    protocol: MediaProtocol.inline(
                        identity,
                        bodyFrom: { req in
                            MediaProtocol.json(try await routeCopy.wireProtocol.bodyFrom(req))
                        },
                        decodeResponse: { resp, ctx in
                            try await routeCopy.wireProtocol.decodeResponse(
                                resp,
                                ProtocolSpec.DecodeContext(request: ctx.request, providerMetadataKey: routeCopy.providerMetadataKey)
                            )
                        }
                    ),
                    endpoint: routeCopy.endpoint,
                    auth: routeCopy.auth
                ))

                let maxVals = routeCopy.maxValues
                return AIEmbedding.EmbeddingModel.make(AIEmbedding.EmbeddingModel.MakeInput(
                    id: modelID,
                    provider: provider.rawValue,
                    route: AIEmbedding.EmbeddingModelRoute(id: id) { req, execute in
                        guard let maxVals, maxVals > 0, req.values.count > maxVals else {
                            return try await composed.generate(req, execute)
                        }
                        var chunks: [[AIEmbedding.EmbeddingValue]] = []
                        var offset = 0
                        while offset < req.values.count {
                            let end = min(offset + maxVals, req.values.count)
                            chunks.append(Array(req.values[offset..<end]))
                            offset = end
                        }

                        var responses = [AIEmbedding.EmbeddingResponse?](repeating: nil, count: chunks.count)
                        do {
                            try await withThrowingTaskGroup(of: (Int, AIEmbedding.EmbeddingResponse).self) { group in
                                var nextIndex = 0
                                let concurrency = min(4, chunks.count)
                                for _ in 0..<concurrency {
                                    let idx = nextIndex
                                    nextIndex += 1
                                    let slice = chunks[idx]
                                    group.addTask {
                                        let sub = AIEmbedding.EmbeddingRequest(
                                            model: req.model,
                                            values: slice,
                                            dimensions: req.dimensions,
                                            inputType: req.inputType,
                                            providerOptions: req.providerOptions,
                                            headers: req.headers,
                                            timeout: req.timeout,
                                            http: req.http,
                                            fetch: req.fetch
                                        )
                                        let res = try await composed.generate(sub, execute)
                                        return (idx, res)
                                    }
                                }
                                while let (idx, res) = try await group.next() {
                                    responses[idx] = res
                                    if nextIndex < chunks.count {
                                        let launchIdx = nextIndex
                                        nextIndex += 1
                                        let slice = chunks[launchIdx]
                                        group.addTask {
                                            let sub = AIEmbedding.EmbeddingRequest(
                                                model: req.model,
                                                values: slice,
                                                dimensions: req.dimensions,
                                                inputType: req.inputType,
                                                providerOptions: req.providerOptions,
                                                headers: req.headers,
                                                timeout: req.timeout,
                                                http: req.http,
                                                fetch: req.fetch
                                            )
                                            let res = try await composed.generate(sub, execute)
                                            return (launchIdx, res)
                                        }
                                    }
                                }
                            }
                        } catch let aiError as AISchema.AIError {
                            throw aiError
                        } catch {
                            throw AISchema.AIError(reason: .unknownProvider(AISchema.UnknownProviderError(
                                message: String(describing: error)
                            )))
                        }

                        let ordered = responses.compactMap { $0 }
                        let embeddings = ordered.flatMap(\.embeddings)
                        let allHaveTokens = ordered.allSatisfy { $0.usage?.inputTokens != nil }
                        let usage: AIEmbedding.EmbeddingUsage? = allHaveTokens
                            ? AIEmbedding.EmbeddingUsage(inputTokens: ordered.reduce(0.0) { $0 + ($1.usage?.inputTokens ?? 0) })
                            : nil
                        var allKeys: [String] = []
                        var seenKeys: Set<String> = []
                        for resp in ordered {
                            if let meta = resp.providerMetadata {
                                for k in meta.keys {
                                    if seenKeys.insert(k).inserted { allKeys.append(k) }
                                }
                            }
                        }
                        let providerMetadata: AISchema.ProviderMetadata? = if allKeys.isEmpty {
                            nil
                        } else {
                            Dictionary(uniqueKeysWithValues: allKeys.map { key in
                                let perChunk = ordered.map { JSONValue.object($0.providerMetadata?[key] ?? [:]) }
                                return (key, ["responses": .array(perChunk)])
                            })
                        }
                        return AIEmbedding.EmbeddingResponse(
                            embeddings: embeddings,
                            usage: usage,
                            providerMetadata: providerMetadata
                        )
                    },
                    transport: transport,
                    providerOptions: providerOptions
                ))
            }
        }

        // parity: ai/src/route/embedding.ts#make [status=implemented hash=52daf1a0fca9]
        public static func make(_ input: MakeInput) -> Route {
            let providerID = AISchema.ProviderID.make(input.provider)
            return Route(
                id: input.id,
                provider: providerID,
                providerMetadataKey: input.providerMetadataKey ?? providerID.rawValue,
                wireProtocol: input.wireProtocol,
                endpoint: input.endpoint,
                auth: input.auth ?? AIAuth.none,
                transport: AISchema.mergeTransport(input.transport),
                maxValues: input.maxValues
            )
        }
    }
}
