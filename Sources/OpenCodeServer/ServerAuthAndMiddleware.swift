#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Synchronization
import OpenCodeCore
import OpenCodePlatform
import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeUtil

// MARK: - 1. Server Authentication (server/src/auth.ts)

public enum ServerAuth {
    /// Decoded Basic/query credentials.
    // parity: server/src/auth.ts#DecodedCredentials [status=implemented hash=a27b0c86869a]
    public struct DecodedCredentials: Equatable, Hashable, Sendable {
        public let username: String
        public let password: String

        public init(username: String, password: String) {
            self.username = username
            self.password = password
        }
    }

    /// Server authentication configuration (`password: nil` disables auth).
    // parity: server/src/auth.ts#Info [status=implemented hash=d8ee19e712b9]
    public struct Info: Equatable, Hashable, Sendable {
        public let password: String?
        public let username: String

        public init(password: String? = nil, username: String = "opencode") {
            self.password = password
            self.username = username
        }
    }

    /// Pairing-issued session token lifetime (30 days in seconds).
    // parity: server/src/auth.ts#SESSION_TTL_SECONDS [status=implemented hash=021442006f2c]
    public static let SESSION_TTL_SECONDS: Int = 30 * 24 * 60 * 60

    /// Service tag and factory for `ServerAuth.Info`.
    // parity: server/src/auth.ts#Config [status=adapted hash=bb1a1eedbbfb]
    public final class Config: Sendable {
        public static let serviceKey = "@opencode/ServerAuthConfig"
        public let info: Info

        public init(_ info: Info) {
            self.info = info
        }

        // parity: server/src/auth.ts#Config.configLayer [status=implemented hash=fb793742f54f]
        public static func configLayer(password: String?) -> LayerNode.ExecutableLayer {
            LayerNode.ExecutableLayer.succeed(
                key: serviceKey,
                value: Config(Info(password: password, username: "opencode"))
            )
        }

        // parity: server/src/auth.ts#Config.layer [status=implemented hash=513783ff224f]
        public static var layer: LayerNode.ExecutableLayer {
            configLayer(password: nil)
        }
    }

    /// Returns `true` when authentication is enabled (non-empty password configured).
    // parity: server/src/auth.ts#required [status=implemented hash=54fb70de8021]
    public static func required(_ config: Info) -> Bool {
        guard let password = config.password else { return false }
        return !password.isEmpty
    }

    /// Verifies decoded credentials against the server password or an HMAC-signed pairing session token.
    // parity: server/src/auth.ts#authorized [status=implemented hash=a49a5170217f]
    public static func authorized(_ credentials: DecodedCredentials, config: Info, nowMs: Int64? = nil) -> Bool {
        guard let expectedPassword = config.password, credentials.username == config.username else {
            return false
        }
        if ServerCrypto.timingSafeEqual(Array(credentials.password.utf8), Array(expectedPassword.utf8)) {
            return true
        }
        return verifySession(credentials.password, config: config, nowMs: nowMs)
    }

    /// Issues an HMAC-SHA256-signed session token derived from the server password.
    // parity: server/src/auth.ts#issueSession [status=implemented hash=7bae98a528f2]
    public static func issueSession(_ config: Info, nowMs: Int64? = nil) -> String? {
        guard let password = config.password else { return nil }
        let now = nowMs ?? Flock.currentEpochMs()
        let expires = (now / 1000) + Int64(SESSION_TTL_SECONDS)
        let expiresStr = String(expires)
        return "\(expiresStr).\(sign(password: password, payload: expiresStr))"
    }

    /// Verifies an HMAC-SHA256-signed pairing session token using constant-time comparison.
    // parity: server/src/auth.ts#verifySession [status=implemented hash=8b9bc18a157a]
    public static func verifySession(_ token: String, config: Info, nowMs: Int64? = nil) -> Bool {
        guard let password = config.password else { return false }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let expiresPart = String(parts[0])
        let sigPart = String(parts[1])
        guard !expiresPart.isEmpty, let expires = Int64(expiresPart) else { return false }
        let now = nowMs ?? Flock.currentEpochMs()
        guard expires * 1000 > now else { return false }
        let expected = Array(sign(password: password, payload: expiresPart).utf8)
        let actual = Array(sigPart.utf8)
        return ServerCrypto.timingSafeEqual(actual, expected)
    }

    /// Port-scoped session cookie name isolating local servers sharing the same host.
    // parity: server/src/auth.ts#sessionCookieName [status=implemented hash=7161d3030b1e]
    public static func sessionCookieName(_ host: String?) -> String {
        let parsed = ServerParsedURL("http://\(host ?? "")")
        if let port = parsed.port, !port.isEmpty {
            return "opencode_session_\(port)"
        }
        return "opencode_session"
    }

    private static func sign(password: String, payload: String) -> String {
        let key = ServerCrypto.hmacSHA256(
            key: Array(password.utf8),
            message: Array("opencode-session-v1".utf8)
        )
        let mac = ServerCrypto.hmacSHA256(key: key, message: Array(payload.utf8))
        return ServerCrypto.base64URLEncode(mac)
    }
}

// MARK: - 2. Content Headers (server/src/content-headers.ts)

public enum ContentHeaders {
    /// Sandboxed CSP ensuring downloaded raw files cannot execute scripts in the server's origin.
    // parity: server/src/content-headers.ts#CONTENT_SECURITY_POLICY [status=implemented hash=8c5162f14978]
    public static let CONTENT_SECURITY_POLICY = "default-src 'none'; img-src 'self'; media-src 'self'; sandbox"

    private static let textType = "text/plain; charset=utf-8"

    /// Safe download headers for raw file bytes.
    // parity: server/src/content-headers.ts#download [status=implemented hash=49fc92dbea41]
    public static func download(path: String? = nil, mime: String) -> [String: String] {
        let safeType = isActiveBrowserMime(mime) ? textType : mime
        let baseName: String
        if let path {
            baseName = basename(path)
        } else {
            baseName = ""
        }
        return [
            "content-type": safeType,
            "content-disposition": disposition(baseName),
            "content-security-policy": CONTENT_SECURITY_POLICY,
            "x-content-type-options": "nosniff",
        ]
    }

    /// RFC 6266 `Content-Disposition` with ASCII fallback and UTF-8 `filename*`.
    // parity: server/src/content-headers.ts#disposition [status=implemented hash=fc9d120dbd60]
    public static func disposition(_ name: String) -> String {
        if name.isEmpty { return "attachment" }
        var fallback = ""
        fallback.reserveCapacity(name.utf16.count)
        for unit in name.utf16 {
            if unit < 0x20 || unit > 0x7E || unit == 0x22 || unit == 0x5C || unit == 0x25 {
                fallback.append("_")
            } else if let scalar = UnicodeScalar(unit) {
                fallback.unicodeScalars.append(scalar)
            }
        }
        let encoded = encodeRFC5987(name)
        return "attachment; filename=\"\(fallback)\"; filename*=UTF-8''\(encoded)"
    }

    private static func isWordByte(_ b: UInt8) -> Bool {
        (b >= 0x30 && b <= 0x39)
            || (b >= 0x41 && b <= 0x5A)
            || (b >= 0x61 && b <= 0x7A)
            || b == 0x5F
    }

    /// Matches upstream `/^(text\/html|text\/javascript|application\/(x-)?javascript)\b|[/+]xml\b/i`.
    private static func isActiveBrowserMime(_ mime: String) -> Bool {
        let lowerBytes = Array(mime.lowercased().utf8)
        let prefixes: [[UInt8]] = [
            Array("text/html".utf8),
            Array("text/javascript".utf8),
            Array("application/javascript".utf8),
            Array("application/x-javascript".utf8),
        ]
        for prefix in prefixes where lowerBytes.count >= prefix.count {
            if lowerBytes.prefix(prefix.count).elementsEqual(prefix) {
                if lowerBytes.count == prefix.count || !isWordByte(lowerBytes[prefix.count]) {
                    return true
                }
            }
        }
        // Match `[/+]xml\b` anywhere in lowerBytes
        if lowerBytes.count >= 4 {
            for i in 0...(lowerBytes.count - 4) {
                let sep = lowerBytes[i]
                if (sep == 0x2F || sep == 0x2B)
                    && lowerBytes[i + 1] == 0x78 // x
                    && lowerBytes[i + 2] == 0x6D // m
                    && lowerBytes[i + 3] == 0x6C // l
                {
                    let nextIdx = i + 4
                    if nextIdx == lowerBytes.count || !isWordByte(lowerBytes[nextIdx]) {
                        return true
                    }
                }
            }
        }
        return false
    }

    private static func basename(_ path: String) -> String {
        var trimmed = path
        while trimmed.count > 1 && (trimmed.hasSuffix("/") || trimmed.hasSuffix("\\")) {
            trimmed.removeLast()
        }
        if trimmed == "/" || trimmed == "\\" { return "" }
        if let idx = trimmed.lastIndex(where: { $0 == "/" || $0 == "\\" }) {
            return String(trimmed[trimmed.index(after: idx)...])
        }
        return trimmed
    }

    private static func encodeRFC5987(_ input: String) -> String {
        let base = ServerParsedURL.encodeURIComponent(input)
        var out = ""
        out.reserveCapacity(base.utf8.count)
        for ch in base {
            switch ch {
            case "'": out.append("%27")
            case "(": out.append("%28")
            case ")": out.append("%29")
            case "*": out.append("%2A")
            default: out.append(ch)
            }
        }
        return out
    }
}

// MARK: - 3. CORS Policy (server/src/cors.ts)

/// Allowed custom CORS origins configuration.
// parity: server/src/cors.ts#CorsOptions [status=implemented hash=0097cc700fef]
public struct CorsOptions: Equatable, Hashable, Sendable, Codable {
    public let cors: [String]?

    public init(cors: [String]? = nil) {
        self.cors = cors
    }
}

/// Service tag for `CorsOptions`.
// parity: server/src/cors.ts#CorsConfig [status=adapted hash=43659dd5924d]
public enum CorsConfig {
    public static let serviceKey = "@opencode/ServerCorsConfig"
    public static let defaultValue: CorsOptions? = nil
}

/// Returns `true` when `input` matches OpenCode's CORS allowlist (localhost, Tauri, oc://renderer, *.opencode.ai, or configured origins).
// parity: server/src/cors.ts#isAllowedCorsOrigin [status=implemented hash=70e12dc6c370]
public func isAllowedCorsOrigin(_ input: String?, opts: CorsOptions? = nil) -> Bool {
    guard let input, !input.isEmpty else { return true }
    if input.hasPrefix("http://localhost:") { return true }
    if input.hasPrefix("http://127.0.0.1:") { return true }
    if input.hasPrefix("oc://renderer") { return true }
    if input == "tauri://localhost" || input == "http://tauri.localhost" || input == "https://tauri.localhost" {
        return true
    }
    if isOpencodeHTTPSOrigin(input) { return true }
    return opts?.cors?.contains(input) ?? false
}

/// Returns `true` when `input` matches either the request `host` (same-host) or `isAllowedCorsOrigin`.
// parity: server/src/cors.ts#isAllowedRequestOrigin [status=implemented hash=66e2161a1f4a]
public func isAllowedRequestOrigin(_ input: String?, host: String?, opts: CorsOptions? = nil) -> Bool {
    guard let input, !input.isEmpty else { return true }
    if let host, !host.isEmpty, sameOriginHost(origin: input, host: host) {
        return true
    }
    return isAllowedCorsOrigin(input, opts: opts)
}

private func isOpencodeHTTPSOrigin(_ input: String) -> Bool {
    guard input.hasPrefix("https://") else { return false }
    let rest = String(input.dropFirst("https://".count))
    guard !rest.isEmpty, !rest.contains("/"), !rest.contains("?"), !rest.contains("#"), !rest.contains(":") else {
        return false
    }
    if rest == "opencode.ai" { return true }
    guard rest.hasSuffix(".opencode.ai") else { return false }
    let prefix = rest.dropLast(".opencode.ai".count)
    guard !prefix.isEmpty else { return false }
    for label in prefix.split(separator: ".", omittingEmptySubsequences: false) {
        guard !label.isEmpty else { return false }
        for b in label.utf8 {
            let valid = (b >= 0x61 && b <= 0x7A) || (b >= 0x30 && b <= 0x39) || b == 0x2D
            if !valid { return false }
        }
    }
    return true
}

internal func sameOriginHost(origin: String, host: String) -> Bool {
    let parsed = ServerParsedURL(origin)
    guard parsed.scheme != nil, let originHost = parsed.host else { return false }
    return originHost.lowercased() == host
}

/// Applies CORS headers and handles `OPTIONS` preflight requests.
public enum ServerCORSMiddleware {
    public static func wrap(
        options: CorsOptions?,
        next: @escaping ServerHTTPHandler
    ) -> ServerHTTPHandler {
        { request in
            let origin = request.header("origin")
            let allowed = isAllowedCorsOrigin(origin, opts: options)
            if request.method == "OPTIONS" && request.header("access-control-request-method") != nil {
                var headers: [String: String] = ["vary": "Origin"]
                if let origin, !origin.isEmpty, allowed {
                    headers["access-control-allow-origin"] = origin
                    headers["access-control-allow-credentials"] = "true"
                    headers["access-control-allow-methods"] = "GET, POST, PUT, PATCH, DELETE, HEAD, OPTIONS"
                    if let reqHeaders = request.header("access-control-request-headers"), !reqHeaders.isEmpty {
                        headers["access-control-allow-headers"] = reqHeaders
                    } else {
                        headers["access-control-allow-headers"] = "authorization, content-type, x-opencode-directory, x-opencode-ticket, x-opencode-capabilities"
                    }
                    headers["access-control-max-age"] = "86400"
                }
                return ServerHTTPResponse.empty(statusCode: 204, headers: headers)
            }

            var response = await next(request)
            if let origin, !origin.isEmpty, allowed {
                if ServerHeaders.value(in: response.headers, for: "access-control-allow-origin") == nil {
                    ServerHeaders.set("access-control-allow-origin", value: origin, in: &response.headers)
                    ServerHeaders.set("access-control-allow-credentials", value: "true", in: &response.headers)
                }
                if let existingVary = ServerHeaders.value(in: response.headers, for: "vary") {
                    if !existingVary.lowercased().contains("origin") {
                        ServerHeaders.set("vary", value: "\(existingVary), Origin", in: &response.headers)
                    }
                } else {
                    ServerHeaders.set("vary", value: "Origin", in: &response.headers)
                }
            }
            return response
        }
    }
}

// MARK: - 4. HTTP Byte Range Parser (server/src/range.ts)

public enum ByteRange {
    public struct Slice: Equatable, Hashable, Sendable {
        public let start: Int
        public let end: Int

        public init(start: Int, end: Int) {
            self.start = start
            self.end = end
        }
    }

    public enum ParseResult: Equatable, Hashable, Sendable {
        case range(Slice)
        case unsatisfiable
    }

    /// Parses a single `bytes=` Range header for a `size`-byte body (inclusive). Returns `nil` to serve the full body.
    // parity: server/src/range.ts#parse [status=implemented hash=623c09d13d39]
    public static func parse(_ header: String?, size: Int) -> ParseResult? {
        guard let header else { return nil }
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("bytes=") else { return nil }
        let spec = String(trimmed.dropFirst("bytes=".count)).trimmingCharacters(in: .whitespaces)
        // Multi-range requests (containing ',') fall back to full 200 body.
        guard !spec.contains(",") else { return nil }
        guard let dash = spec.firstIndex(of: "-") else { return nil }
        let rawStart = String(spec[..<dash]).trimmingCharacters(in: .whitespaces)
        let rawEnd = String(spec[spec.index(after: dash)...]).trimmingCharacters(in: .whitespaces)
        // Must have only ASCII digits in both parts and at least one non-empty part.
        guard !rawStart.isEmpty || !rawEnd.isEmpty else { return nil }
        guard rawStart.allSatisfy({ $0.isASCII && $0.isNumber }),
              rawEnd.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            return nil
        }
        if rawStart.isEmpty {
            guard let suffix = Int(rawEnd) else { return nil }
            if suffix == 0 || size == 0 { return .unsatisfiable }
            return .range(Slice(start: max(size - suffix, 0), end: size - 1))
        }
        guard let start = Int(rawStart) else { return nil }
        let end: Int
        if rawEnd.isEmpty {
            end = size - 1
        } else {
            guard let parsedEnd = Int(rawEnd) else { return nil }
            end = parsedEnd
        }
        if start > end || start >= size { return .unsatisfiable }
        return .range(Slice(start: start, end: min(end, size - 1)))
    }
}

// MARK: - 5. Media URI Capability Negotiation (server/src/media-uri.ts)

private let mediaCapabilitiesHeader = "x-opencode-capabilities"
private let mediaUriCapabilityToken = "experimental-media-uri"

/// Returns `true` when the client opted into `experimental-media-uri` via `X-OpenCode-Capabilities`.
// parity: server/src/media-uri.ts#wantsMediaRefs [status=implemented hash=a442eb72caf3]
public let wantsMediaRefs: @Sendable (ServerHTTPRequest) -> Bool = { request in
    guard let raw = request.header(mediaCapabilitiesHeader) else { return false }
    return raw
        .split(separator: ",")
        .contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == mediaUriCapabilityToken }
}

// MARK: - 6. Request-Site Protection (server/src/request-site.ts)

public enum RequestSite {
    /// Returns `true` when a browser cross-site/same-site API navigation or disallowed-origin request must be blocked.
    // parity: server/src/request-site.ts#rejected [status=implemented hash=bd96d1a5497d]
    public static func rejected(_ request: ServerHTTPRequest, options: CorsOptions? = nil) -> Bool {
        let site = request.header("sec-fetch-site")
        guard site == "cross-site" || site == "same-site" else { return false }
        let pathname = request.pathname
        guard pathname == "/api" || pathname.hasPrefix("/api/") else { return false }
        if isArtifactViewPath(pathname) { return false }
        if request.header("sec-fetch-mode") == "navigate" { return true }
        if let origin = request.header("origin") {
            return !isAllowedRequestOrigin(origin, host: request.header("host"), opts: options)
        }
        return false
    }

    /// Middleware rejecting disallowed cross-site API requests with `403 ForbiddenError`.
    // parity: server/src/request-site.ts#middleware [status=implemented hash=7745b20b638b]
    public static let middleware: @Sendable (CorsOptions?) -> @Sendable (@escaping ServerHTTPHandler) -> ServerHTTPHandler = { options in
        { next in
            { request in
                if rejected(request, options: options) {
                    return ServerErrorResponse.encodeProtocolError(
                        ForbiddenError(message: "Cross-site requests to the API are not allowed")
                    )
                }
                return await next(request)
            }
        }
    }

    private static func isArtifactViewPath(_ pathname: String) -> Bool {
        let prefix = "/api/experimental/artifacts/"
        guard pathname.hasPrefix(prefix) else { return false }
        let rest = pathname.dropFirst(prefix.count)
        guard let slash = rest.firstIndex(of: "/"), slash > rest.startIndex else { return false }
        let afterID = rest[rest.index(after: slash)...]
        return afterID == "view" || afterID.hasPrefix("view/")
    }
}

// MARK: - 7. Request Tracing Isolation (server/src/request-tracing.ts)

/// Detaches the ambient startup trace span so handlers and requests start fresh root traces.
// parity: server/src/request-tracing.ts#withoutParentSpan [status=adapted hash=cbdd50e29ecf]
public let withoutParentSpan: @Sendable (@escaping @Sendable () async throws -> Void) async throws -> Void = { body in
    try await body()
}

// MARK: - 8. Server Options (server/src/options.ts)

/// Configuration surface for `OpenCodeServer` matching `packages/server/src/options.ts`.
// parity: server/src/options.ts#ServerOptions [status=implemented hash=892c16914cf1]
public struct ServerOptions: Sendable {
    public struct AppOptions: Equatable, Hashable, Sendable, Codable {
        public let name: String?
        public let version: String?
        public let channel: String?

        public init(name: String? = nil, version: String? = nil, channel: String? = nil) {
            self.name = name
            self.version = version
            self.channel = channel
        }
    }

    public struct EventsOptions: Equatable, Hashable, Sendable, Codable {
        public let persist: Bool?

        public init(persist: Bool? = nil) {
            self.persist = persist
        }
    }

    public struct ConfigOptions: Equatable, Hashable, Sendable, Codable {
        public let directory: String?
        public let project: Bool?
        public let claude: Bool?
        public let file: String?
        public let content: String?

        public init(
            directory: String? = nil,
            project: Bool? = nil,
            claude: Bool? = nil,
            file: String? = nil,
            content: String? = nil
        ) {
            self.directory = directory
            self.project = project
            self.claude = claude
            self.file = file
            self.content = content
        }
    }

    public struct InstructionsOptions: Equatable, Hashable, Sendable, Codable {
        public let claude: Bool?

        public init(claude: Bool? = nil) {
            self.claude = claude
        }
    }

    public struct WindowsOptions: Equatable, Hashable, Sendable, Codable {
        public let gitbash: String?

        public init(gitbash: String? = nil) {
            self.gitbash = gitbash
        }
    }

    public struct FSOptions: Equatable, Hashable, Sendable, Codable {
        public let filewatcher: Bool?
        public let fff: Bool?

        public init(filewatcher: Bool? = nil, fff: Bool? = nil) {
            self.filewatcher = filewatcher
            self.fff = fff
        }
    }

    public let app: AppOptions?
    public let hostname: String?
    public let port: Int?
    public let password: String?
    public let cors: [String]?
    public let simulation: Bool?
    public let database: CoreDatabaseStore.Options?
    public let pty: CorePty.Persistent.Options?
    public let events: EventsOptions?
    public let models: CoreModel.ModelsDev.Options?
    public let fetch: LayerNodePlatform.Fetch?
    public let config: ConfigOptions?
    public let instructions: InstructionsOptions?
    public let windows: WindowsOptions?
    public let fs: FSOptions?

    public init(
        app: AppOptions? = nil,
        hostname: String? = nil,
        port: Int? = nil,
        password: String? = nil,
        cors: [String]? = nil,
        simulation: Bool? = nil,
        database: CoreDatabaseStore.Options? = nil,
        pty: CorePty.Persistent.Options? = nil,
        events: EventsOptions? = nil,
        models: CoreModel.ModelsDev.Options? = nil,
        fetch: LayerNodePlatform.Fetch? = nil,
        config: ConfigOptions? = nil,
        instructions: InstructionsOptions? = nil,
        windows: WindowsOptions? = nil,
        fs: FSOptions? = nil
    ) {
        self.app = app
        self.hostname = hostname
        self.port = port
        self.password = password
        self.cors = cors
        self.simulation = simulation
        self.database = database
        self.pty = pty
        self.events = events
        self.models = models
        self.fetch = fetch
        self.config = config
        self.instructions = instructions
        self.windows = windows
        self.fs = fs
    }
}

// MARK: - 9. Server Pairing (server/src/pairing.ts)

public enum ServerPairing {
    public static let ttlSeconds: Int = 5 * 60
    public static let capacity: Int = 1_000

    // parity: server/src/pairing.ts#Interface [status=implemented hash=2802c8403ebe]
    public protocol Interface: Sendable {
        func issue() -> PairingCode
        func consume(_ code: String) -> Bool
    }

    /// Short-lived, single-use pairing code store (5 min TTL, 1,000 max entries).
    // parity: server/src/pairing.ts#Service [status=implemented hash=8ebbe0a08309]
    public final class Service: Interface, Sendable {
        public static let serviceKey = "@opencode/ServerPairing"

        private let ttlMs: Int64
        private let nowMs: @Sendable () -> Int64
        private let codes = Mutex<[String: Int64]>([:])

        public init(
            ttlSeconds: Int = ServerPairing.ttlSeconds,
            nowMs: @escaping @Sendable () -> Int64 = { Flock.currentEpochMs() }
        ) {
            self.ttlMs = Int64(ttlSeconds) * 1_000
            self.nowMs = nowMs
        }

        public func issue() -> PairingCode {
            let code = ServerCrypto.base64URLEncode(ServerCrypto.randomBytes(16))
            let now = nowMs()
            let expiresAt = now + ttlMs
            codes.withLock { map in
                if map.count >= ServerPairing.capacity {
                    map = map.filter { $0.value > now }
                    if map.count >= ServerPairing.capacity, let oldest = map.min(by: { $0.value < $1.value })?.key {
                        map.removeValue(forKey: oldest)
                    }
                }
                map[code] = expiresAt
            }
            return PairingCode(code: code, expiresIn: Int(ttlMs / 1_000))
        }

        public func consume(_ code: String) -> Bool {
            let now = nowMs()
            return codes.withLock { map in
                guard let expiresAt = map.removeValue(forKey: code) else { return false }
                return expiresAt > now
            }
        }
    }

    // parity: server/src/pairing.ts#node [status=adapted hash=f295b9fcbf23]
    public static let node: LayerNode.Provider = AppNode.makeGlobalNode(
        Service.serviceKey,
        LayerNode.ExecutableLayer.succeed(key: Service.serviceKey, value: Service()),
        []
    )
}

// MARK: - 10. Server Info (server/src/server-info.ts)

public enum ServerInfo {
    public struct Paths: Equatable, Hashable, Sendable, Codable {
        public let tmp: String

        public init(tmp: String) {
            self.tmp = tmp
        }
    }

    // parity: server/src/server-info.ts#Service [status=implemented hash=c833304b62f9]
    public final class Service: Sendable {
        public static let serviceKey = "@opencode/server/ServerInfo"
        public let urls: @Sendable () -> [String]
        public let app: ServerOptions.AppOptions
        public let paths: Paths

        public init(
            urls: @escaping @Sendable () -> [String] = { [] },
            app: ServerOptions.AppOptions = ServerOptions.AppOptions(),
            paths: Paths
        ) {
            self.urls = urls
            self.app = app
            self.paths = paths
        }
    }

    // parity: server/src/server-info.ts#layer [status=adapted hash=385c519d9100]
    public static func layer(
        urls: @escaping @Sendable () -> [String],
        tmp: String,
        app: ServerOptions.AppOptions = ServerOptions.AppOptions()
    ) -> LayerNode.ExecutableLayer {
        LayerNode.ExecutableLayer.succeed(
            key: Service.serviceKey,
            value: Service(urls: urls, app: app, paths: Paths(tmp: tmp))
        )
    }

    /// Expands wildcard bind addresses (`0.0.0.0`, `::`) into loopback + external interface connection URLs.
    // parity: server/src/server-info.ts#connectionURLs [status=implemented hash=b139c915dab8]
    public static func connectionURLs(
        _ value: String,
        requestedHostname: String? = nil,
        interfaceAddresses: ((Bool) -> [String])? = nil
    ) -> [String] {
        let parsed = ServerParsedURL(value)
        let hostname = requestedHostname ?? parsed.hostname ?? ""
        let isIPv4Wildcard = hostname == "0.0.0.0"
        let isIPv6Wildcard = hostname == "::" || hostname == "[::]"
        guard isIPv4Wildcard || isIPv6Wildcard else {
            return [value]
        }

        let scheme = parsed.scheme ?? "http"
        let portSuffix = parsed.port.map { ":\($0)" } ?? ""
        let loopbackHost = isIPv6Wildcard ? "[::1]" : "127.0.0.1"
        var urls: [String] = ["\(scheme)://\(loopbackHost)\(portSuffix)"]
        var seen: Set<String> = [urls[0]]

        let external = interfaceAddresses?(isIPv6Wildcard)
            ?? ServerHostInfo.externalInterfaceAddresses(ipv6: isIPv6Wildcard)
        for address in external {
            let formattedHost = isIPv6Wildcard ? "[\(address)]" : address
            let candidate = "\(scheme)://\(formattedHost)\(portSuffix)"
            if seen.insert(candidate).inserted {
                urls.append(candidate)
            }
        }
        return urls
    }
}

// MARK: - 11. Service Status State Machine (server/src/service-status.ts)

public enum ServiceStatus {
    // parity: server/src/service-status.ts#State [status=implemented hash=8100e16840c1]
    public enum State: String, Equatable, Hashable, Sendable, Codable {
        case starting
        case ready
        case stopping
        case failed
    }

    // parity: server/src/service-status.ts#Interface [status=implemented hash=fa690527b6c6]
    public protocol Interface: Sendable {
        var current: State { get }
        func ready()
        func fail()
        func beginStopping()
    }

    public final class Store: Interface, Sendable {
        private let state: Mutex<State>

        public init(initial: State = .starting) {
            self.state = Mutex(initial)
        }

        public var current: State {
            state.withLock { $0 }
        }

        public func ready() {
            state.withLock { s in
                if s == .starting { s = .ready }
            }
        }

        public func fail() {
            state.withLock { s in
                if s == .starting { s = .failed }
            }
        }

        public func beginStopping() {
            state.withLock { s in
                if s != .stopping { s = .stopping }
            }
        }
    }

    // parity: server/src/service-status.ts#make [status=implemented hash=157d3f3b154e]
    public static func make(initial: State = .starting) -> Store {
        Store(initial: initial)
    }
}

// MARK: - 12. Location Resolution & Middleware (server/src/location.ts)

/// Location-scoped services provided to handlers by `LocationMiddleware`.
// parity: server/src/location.ts#LocationServices [status=implemented hash=c825ac5c5f43]
public typealias LocationServices = ServerLocationBundle

/// Location middleware descriptor (`@opencode/HttpApiLocation`).
// parity: server/src/location.ts#LocationMiddleware [status=implemented hash=cf941f763fcd]
public final class LocationMiddleware: Sendable {
    public static let id = "@opencode/HttpApiLocation"
    public static let descriptor = MiddlewareDescriptor(
        id: id,
        errors: [ProtocolErrorRef(LocationNotFoundError.self)]
    )
}

/// Converts `CoreFilesystem.DirectoryNotFoundError` into `LocationNotFoundError` (404).
// parity: server/src/location.ts#locationErrors [status=implemented hash=9fbebbeadc63]
public func locationErrors<A>(_ operation: () async throws -> A) async throws -> A {
    do {
        return try await operation()
    } catch let error as CoreFilesystem.DirectoryNotFoundError {
        throw LocationNotFoundError(
            location: OpenCodeLocation(directory: error.directory.rawValue),
            message: "Location not found: \(error.directory.rawValue)"
        )
    } catch let error as CoreLocation.Instance.Error {
        if case .directoryNotFound(let dir) = error {
            throw LocationNotFoundError(
                location: OpenCodeLocation(directory: dir),
                message: "Location not found: \(dir)"
            )
        }
        throw error
    }
}

/// Wraps a Location-scoped payload into `{ location, data }` (`LocationSchema.ResponseEnvelope`).
// parity: server/src/location.ts#response [status=implemented hash=201df3c17068]
public func response<A: Equatable & Hashable & Sendable & Codable>(
    location: LocationServices,
    data: A
) -> LocationSchema.ResponseEnvelope<A> {
    LocationSchema.ResponseEnvelope(location: location.publicRef, data: data)
}

/// Validates a raw session ID parameter and loads the session info (throwing `InvalidRequestError` or `SessionNotFoundError`).
// parity: server/src/location.ts#sessionInfo [status=implemented hash=3261f7456ba4]
public let sessionInfo: @Sendable (any CoreSession.Interface, String) throws -> SessionSchema.Info = { sessions, rawID in
    let id: SessionID
    do {
        id = try SessionID(validating: rawID)
    } catch {
        throw InvalidRequestError(message: "Invalid session ID", field: "sessionID")
    }
    do {
        return try sessions.get(id)
    } catch let error as CoreSessionErrors.NotFoundError {
        throw missingSession(error)
    }
}

/// Extracts `LocationSchema.Ref` from `location[directory]` query, `x-opencode-directory` header, or default directory.
// parity: server/src/location.ts#requestRef [status=implemented hash=1f7e22d1c6bd]
public func requestRef(
    _ request: ServerHTTPRequest,
    defaultDirectory: String? = nil
) -> LocationSchema.Ref {
    let directory: String
    if let qDir = request.query("location[directory]"), !qDir.isEmpty {
        directory = qDir
    } else if let hDir = request.header("x-opencode-directory"), !hDir.isEmpty {
        directory = ServerParsedURL.decodeURIComponentStrict(hDir) ?? hDir
    } else {
        directory = defaultDirectory ?? ServerHostInfo.currentWorkingDirectory()
    }
    return LocationSchema.Ref(directory: SchemaPrimitive.AbsolutePath(rawValue: directory))
}

/// Middleware layer resolving `LocationServices` for an inbound request.
// parity: server/src/location.ts#layer [status=adapted hash=70eb607eaf63]
public let layer: @Sendable (ServerAppRuntime, ServerHTTPRequest) async throws -> LocationServices = { runtime, request in
    let ref = requestRef(request, defaultDirectory: runtime.defaultDirectory)
    return try await locationErrors {
        try await runtime.resolveLocation(ref)
    }
}

// MARK: - 13. Authorization Middleware (server/src/middleware/authorization.ts)

private let authTokenQueryName = "auth_token"
private let wwwAuthenticateHeader = "Basic realm=\"Secure Area\""
private let unauthorizedMessage = "Authentication required"

private func decodeBasicCredential(_ encoded: String) -> ServerAuth.DecodedCredentials {
    let decoded: String
    if let standardBytes = try? base64ToBytes(encoded) {
        decoded = String(decoding: standardBytes, as: UTF8.self)
    } else if let urlSafe = try? base64Decode(encoded) {
        decoded = urlSafe
    } else {
        return ServerAuth.DecodedCredentials(username: "", password: "")
    }
    guard let colon = decoded.firstIndex(of: ":") else {
        return ServerAuth.DecodedCredentials(username: "", password: "")
    }
    return ServerAuth.DecodedCredentials(
        username: String(decoded[..<colon]),
        password: String(decoded[decoded.index(after: colon)...])
    )
}

private func shouldChallengeRequest(_ request: ServerHTTPRequest) -> Bool {
    let mode = request.header("sec-fetch-mode")
    return mode == nil || mode == "navigate"
}

/// Builds a `401 UnauthorizedError` response, adding `WWW-Authenticate` only for non-browser or navigation requests.
// parity: server/src/middleware/authorization.ts#unauthorizedResponse [status=implemented hash=7be7fd32997d]
public func unauthorizedResponse(_ request: ServerHTTPRequest) -> ServerHTTPResponse {
    var headers: [String: String] = [:]
    if shouldChallengeRequest(request) {
        headers["www-authenticate"] = wwwAuthenticateHeader
    }
    return ServerHTTPResponse.json(
        UnauthorizedError(message: unauthorizedMessage),
        statusCode: 401,
        headers: headers
    )
}

/// Evaluates Basic auth, `auth_token` query, Bearer token, or same-origin session cookie against `ServerAuth.Info`.
// parity: server/src/middleware/authorization.ts#authorizedRequest [status=implemented hash=8028f81e4798]
public func authorizedRequest(
    _ request: ServerHTTPRequest,
    config: ServerAuth.Info,
    nowMs: Int64? = nil
) -> Bool {
    if let token = request.query(authTokenQueryName), !token.isEmpty {
        let cred = decodeBasicCredential(token)
        if ServerAuth.authorized(cred, config: config, nowMs: nowMs) {
            return true
        }
    } else if let authHeader = request.header("authorization") {
        let trimmed = authHeader.trimmingCharacters(in: .whitespaces)
        if let schemeEnd = trimmed.firstIndex(where: \.isWhitespace) {
            let scheme = trimmed[..<schemeEnd].lowercased()
            let value = String(trimmed[schemeEnd...]).trimmingCharacters(in: .whitespaces)
            if scheme == "basic" && !value.isEmpty {
                let cred = decodeBasicCredential(value)
                if ServerAuth.authorized(cred, config: config, nowMs: nowMs) {
                    return true
                }
            } else if scheme == "bearer" && !value.isEmpty {
                if let expected = config.password,
                   (ServerCrypto.timingSafeEqual(Array(value.utf8), Array(expected.utf8))
                    || ServerAuth.verifySession(value, config: config, nowMs: nowMs)) {
                    return true
                }
            }
        }
    }
    return authorizedSessionCookie(request, config: config, nowMs: nowMs)
}

private func authorizedSessionCookie(
    _ request: ServerHTTPRequest,
    config: ServerAuth.Info,
    nowMs: Int64? = nil
) -> Bool {
    let cookieName = ServerAuth.sessionCookieName(request.header("host"))
    guard let token = request.cookies[cookieName], !token.isEmpty else { return false }
    if let origin = request.header("origin") {
        guard let host = request.header("host"), sameOriginHost(origin: origin, host: host) else {
            return false
        }
    }
    return ServerAuth.verifySession(token, config: config, nowMs: nowMs)
}

/// WebSocket endpoint path where remote machine workers dial in to authenticate via Noise XX (`MachineLink.accept`).
public let MACHINE_LINK_PATH = "/api/machine/link"

public func isMachineLinkURL(_ urlString: String) -> Bool {
    ServerParsedURL(urlString).pathname == MACHINE_LINK_PATH
}

/// Authorization middleware checking route exemptions (pairing connect, machine Noise link, ticketed PTY/MCP WebSockets) and auth credentials.
// parity: server/src/middleware/authorization.ts#authorizationLayer [status=implemented hash=c1b59186de32]
public let authorizationLayer: @Sendable (
    ServerAuth.Info,
    String,
    ServerHTTPRequest
) -> ServerHTTPResponse? = { config, routePath, request in
    guard ServerAuth.required(config) else { return nil }
    let hasTicket = !(request.query(PTY_CONNECT_TICKET_QUERY) ?? "").isEmpty
    if ((routePath == PTY_CONNECT_PATH
        || routePath == PERSISTENT_PTY_CONNECT_PATH
        || routePath == MCP_CLIENT_PATH) && hasTicket)
        || routePath == PAIRING_CONNECT_PATH
        || routePath == MACHINE_LINK_PATH {
        return nil
    }
    if authorizedRequest(request, config: config) {
        return nil
    }
    return unauthorizedResponse(request)
}

// MARK: - 14. Defect, Schema Error, Form Location & Session Location Middlewares

/// Replaces unexpected unhandled server failures with a structured `500 UnknownError` carrying a log reference
/// (and a human-readable message for SQLite storage failures).
// parity: server/src/middleware/defect-response.ts#defectResponseLayer [status=implemented hash=24412dbc524c]
public let defectResponseLayer: @Sendable (any Error, ServerHTTPRequest) -> ServerHTTPResponse = { error, _ in
    if let encoded = ServerErrorResponse.encode(error) {
        return encoded
    }
    let ref = "err_\(uuid().prefix(8))"
    let message = CoreDatabaseStorageFailure.message(error)
        ?? "Server failed to handle the request. Check server logs for details."
    return ServerHTTPResponse.json(UnknownError(message: message, ref: ref), statusCode: 500)
}

/// Transforms request schema decoding failures into `400 InvalidRequestError` and response encoding failures into `500 UnknownError`.
// parity: server/src/middleware/schema-error.ts#schemaErrorLayer [status=implemented hash=45c2bf205752]
public let schemaErrorLayer: @Sendable (String, String) -> ServerHTTPResponse = { kind, rawReason in
    let limit = 1024
    let reason: String
    if rawReason.count <= limit {
        reason = rawReason
    } else {
        reason = String(rawReason.prefix(limit)) + "... (\(rawReason.count - limit) more chars)"
    }
    if kind == "Body" || kind == "ResponseHeaders" {
        let ref = "err_\(uuid().prefix(8))"
        return ServerHTTPResponse.json(
            UnknownError(
                message: "Server failed to encode its response. Check server logs for details.",
                ref: ref
            ),
            statusCode: 500
        )
    }
    return ServerErrorResponse.encodeProtocolError(InvalidRequestError(message: reason, kind: kind))
}

/// Form location middleware descriptor (`@opencode/HttpApiFormLocation`), supporting the temporary `sessionID == "global"` MCP elicitation sentinel.
// parity: server/src/middleware/form-location.ts#FormLocationMiddleware [status=implemented hash=cbe65525a16b]
public final class FormLocationMiddleware: Sendable {
    public static let id = "@opencode/HttpApiFormLocation"
    public static let descriptor = MiddlewareDescriptor(
        id: id,
        errors: [
            ProtocolErrorRef(InvalidRequestError.self),
            ProtocolErrorRef(SessionNotFoundError.self),
            ProtocolErrorRef(LocationNotFoundError.self),
        ]
    )
}

public enum FormLocationResolution: Sendable {
    case location(LocationServices)
    case emptyListShortcut
}

/// Resolves location services for form routes without booting a cold Location on `session.form.list`.
// parity: server/src/middleware/form-location.ts#formLocationLayer [status=implemented hash=ea326e11ed0a]
public let formLocationLayer: @Sendable (
    ServerAppRuntime,
    ServerHTTPRequest,
    String,
    String
) async throws -> FormLocationResolution = { runtime, request, sessionIDParam, endpointIdentifier in
    if sessionIDParam == "global" {
        let ref = requestRef(request, defaultDirectory: runtime.defaultDirectory)
        return .location(try await runtime.resolveLocation(ref))
    }
    let session = try sessionInfo(runtime.session, sessionIDParam)
    let locRef = LocationSchema.Ref(
        directory: SchemaPrimitive.AbsolutePath(rawValue: session.location.directory),
        workspaceID: session.location.workspaceID
    )
    if endpointIdentifier == "session.form.list" {
        let isLive = await runtime.instance.live(location: locRef)
        if !isLive {
            return .emptyListShortcut
        }
    }
    return .location(try await runtime.resolveLocation(locRef))
}

/// Session location middleware descriptor (`@opencode/HttpApiSessionLocation`).
// parity: server/src/middleware/session-location.ts#SessionLocationMiddleware [status=implemented hash=b729d9b95662]
public final class SessionLocationMiddleware: Sendable {
    public static let id = "@opencode/HttpApiSessionLocation"
    public static let descriptor = MiddlewareDescriptor(
        id: id,
        errors: [
            ProtocolErrorRef(InvalidRequestError.self),
            ProtocolErrorRef(SessionNotFoundError.self),
            ProtocolErrorRef(LocationNotFoundError.self),
        ]
    )
}

/// Resolves the Location owning `sessionIDParam` for session-scoped location endpoints.
// parity: server/src/middleware/session-location.ts#sessionLocationLayer [status=implemented hash=99ef41a50bf9]
public let sessionLocationLayer: @Sendable (
    ServerAppRuntime,
    String
) async throws -> LocationServices = { runtime, sessionIDParam in
    let session = try sessionInfo(runtime.session, sessionIDParam)
    let locRef = LocationSchema.Ref(
        directory: SchemaPrimitive.AbsolutePath(rawValue: session.location.directory),
        workspaceID: session.location.workspaceID
    )
    return try await runtime.resolveLocation(locRef)
}

// MARK: - 15. Route Composition (server/src/routes.ts)

/// Creates an authenticated HTTP router backed by `ServerAppRuntime` (`options.password` enables Basic/Bearer/cookie auth).
// parity: server/src/routes.ts#createRoutes [status=adapted hash=5621bb83e78d]
public func createRoutes(
    options: ServerOptions = ServerOptions(),
    serviceURLs: @escaping @Sendable () -> [String] = { [] },
    overrides: [LayerNode.Replacement] = [],
    fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
    httpTransport: any HTTPTransport = URLSessionHTTPTransport.shared,
    environment: any EnvironmentProviding = SystemEnvironment.shared,
    globalOverrides: Global.Overrides? = nil,
    defaultDirectory: String? = nil,
    databaseClient: (any SQLiteDatabase)? = nil,
    customPersistentPty: (any CorePty.Persistent.Interface)? = nil,
    customBlobStore: (any CoreBlobStore.Interface)? = nil,
    customVideoGeneration: (any CoreIntegration.VideoGeneration.Interface)? = nil,
    customPluginUpdate: (any CorePlugin.Update.Interface)? = nil,
    customWellKnown: (any CoreIntegration.WellKnown.Interface)? = nil,
    customWatcher: (any CoreFilesystem.Watcher.Interface)? = nil,
    logSink: (any LogSink)? = nil,
    configDebounce: Duration = CoreConfig.Service.defaultDebounce,
    instructionDebounce: Duration = CoreConfigPlugin.Instruction.Loader.defaultDebounce,
    instructionURLTimeout: Duration = CoreConfigPlugin.Instruction.Loader.defaultURLFetchTimeout,
    workerdProfile: Bool = false,
    videoGenerationPollIntervalMs: UInt64? = nil,
    onLocationBoot: ServerAppRuntime.LocationCustomizer? = nil
) async throws -> ServerRouter {
    _ = overrides
    let runtime = try await ServerAppRuntime.make(
        options: options,
        serviceURLs: serviceURLs,
        fileSystem: fileSystem,
        httpTransport: httpTransport,
        environment: environment,
        globalOverrides: globalOverrides,
        defaultDirectory: defaultDirectory,
        databaseClient: databaseClient,
        customPersistentPty: customPersistentPty,
        customBlobStore: customBlobStore,
        customVideoGeneration: customVideoGeneration,
        customPluginUpdate: customPluginUpdate,
        customWellKnown: customWellKnown,
        customWatcher: customWatcher,
        logSink: logSink,
        configDebounce: configDebounce,
        instructionDebounce: instructionDebounce,
        instructionURLTimeout: instructionURLTimeout,
        workerdProfile: workerdProfile,
        videoGenerationPollIntervalMs: videoGenerationPollIntervalMs,
        onLocationBoot: onLocationBoot
    )
    return ServerRouter(runtime: runtime)
}

/// Creates an unauthenticated embedded HTTP router (for in-process SDK / CLI / tests).
// parity: server/src/routes.ts#createEmbeddedRoutes [status=adapted hash=60d80f49d2ed]
public func createEmbeddedRoutes(
    options: ServerOptions = ServerOptions(),
    overrides: [LayerNode.Replacement] = [],
    fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
    httpTransport: any HTTPTransport = URLSessionHTTPTransport.shared,
    environment: any EnvironmentProviding = SystemEnvironment.shared,
    globalOverrides: Global.Overrides? = nil,
    defaultDirectory: String? = nil,
    databaseClient: (any SQLiteDatabase)? = nil,
    customWatcher: (any CoreFilesystem.Watcher.Interface)? = nil,
    logSink: (any LogSink)? = nil,
    configDebounce: Duration = CoreConfig.Service.defaultDebounce,
    instructionDebounce: Duration = CoreConfigPlugin.Instruction.Loader.defaultDebounce,
    instructionURLTimeout: Duration = CoreConfigPlugin.Instruction.Loader.defaultURLFetchTimeout,
    onLocationBoot: ServerAppRuntime.LocationCustomizer? = nil
) async throws -> ServerRouter {
    let unauthenticated = ServerOptions(
        app: options.app,
        hostname: options.hostname,
        port: options.port,
        password: nil,
        cors: options.cors,
        simulation: options.simulation,
        database: options.database,
        pty: options.pty,
        events: options.events,
        models: options.models,
        fetch: options.fetch,
        config: options.config,
        instructions: options.instructions,
        windows: options.windows,
        fs: options.fs
    )
    return try await createRoutes(
        options: unauthenticated,
        serviceURLs: { [] },
        overrides: overrides,
        fileSystem: fileSystem,
        httpTransport: httpTransport,
        environment: environment,
        globalOverrides: globalOverrides,
        defaultDirectory: defaultDirectory,
        databaseClient: databaseClient,
        customWatcher: customWatcher,
        logSink: logSink,
        configDebounce: configDebounce,
        instructionDebounce: instructionDebounce,
        instructionURLTimeout: instructionURLTimeout,
        onLocationBoot: onLocationBoot
    )
}

// MARK: - 16. Embeddable Fetch Handler (server/src/fetch.ts)

public enum ServerFetch {
    // parity: server/src/fetch.ts#BootOptions [status=implemented hash=33a23c641871]
    public struct BootOptions: Sendable {
        public let overrides: [LayerNode.Replacement]
        public let fileSystem: any OpenCodeFileSystem
        public let httpTransport: any HTTPTransport
        public let environment: any EnvironmentProviding
        public let globalOverrides: Global.Overrides?
        public let defaultDirectory: String?
        public let databaseClient: (any SQLiteDatabase)?
        public let customWatcher: (any CoreFilesystem.Watcher.Interface)?
        public let logSink: (any LogSink)?
        public let configDebounce: Duration
        public let instructionDebounce: Duration
        public let instructionURLTimeout: Duration
        public let workerdProfile: Bool
        public let videoGenerationPollIntervalMs: UInt64?
        public let onLocationBoot: ServerAppRuntime.LocationCustomizer?

        public init(
            overrides: [LayerNode.Replacement] = [],
            fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
            httpTransport: any HTTPTransport = URLSessionHTTPTransport.shared,
            environment: any EnvironmentProviding = SystemEnvironment.shared,
            globalOverrides: Global.Overrides? = nil,
            defaultDirectory: String? = nil,
            databaseClient: (any SQLiteDatabase)? = nil,
            customWatcher: (any CoreFilesystem.Watcher.Interface)? = nil,
            logSink: (any LogSink)? = nil,
            configDebounce: Duration = CoreConfig.Service.defaultDebounce,
            instructionDebounce: Duration = CoreConfigPlugin.Instruction.Loader.defaultDebounce,
            instructionURLTimeout: Duration = CoreConfigPlugin.Instruction.Loader.defaultURLFetchTimeout,
            workerdProfile: Bool = false,
            videoGenerationPollIntervalMs: UInt64? = nil,
            onLocationBoot: ServerAppRuntime.LocationCustomizer? = nil
        ) {
            self.overrides = overrides
            self.fileSystem = fileSystem
            self.httpTransport = httpTransport
            self.environment = environment
            self.globalOverrides = globalOverrides
            self.defaultDirectory = defaultDirectory
            self.databaseClient = databaseClient
            self.customWatcher = customWatcher
            self.logSink = logSink
            self.configDebounce = configDebounce
            self.instructionDebounce = instructionDebounce
            self.instructionURLTimeout = instructionURLTimeout
            self.workerdProfile = workerdProfile
            self.videoGenerationPollIntervalMs = videoGenerationPollIntervalMs
            self.onLocationBoot = onLocationBoot
        }
    }

    public struct Handle: Sendable {
        public let router: ServerRouter
        public let fetch: ServerHTTPHandler
        public let transport: ServerInProcessTransport

        public init(router: ServerRouter, fetch: @escaping ServerHTTPHandler) {
            self.router = router
            self.fetch = fetch
            self.transport = ServerInProcessTransport(handler: fetch)
        }

        public var runtime: ServerAppRuntime { router.runtime }

        public func close() async {
            await router.runtime.close()
        }
    }

    /// Eagerly builds the OpenCode server router without binding a TCP listener, forks suspended session recovery,
    /// and returns a web-standard fetch handler wrapped with RequestSite and CORS middlewares.
    // parity: server/src/fetch.ts#make [status=adapted hash=e37dc8de285a]
    public static func make(
        options: ServerOptions = ServerOptions(),
        boot: BootOptions = BootOptions()
    ) async throws -> Handle {
        let router = try await createRoutes(
            options: options,
            serviceURLs: { [] },
            overrides: boot.overrides,
            fileSystem: boot.fileSystem,
            httpTransport: boot.httpTransport,
            environment: boot.environment,
            globalOverrides: boot.globalOverrides,
            defaultDirectory: boot.defaultDirectory,
            databaseClient: boot.databaseClient,
            customWatcher: boot.customWatcher,
            logSink: boot.logSink,
            configDebounce: boot.configDebounce,
            instructionDebounce: boot.instructionDebounce,
            instructionURLTimeout: boot.instructionURLTimeout,
            workerdProfile: boot.workerdProfile,
            videoGenerationPollIntervalMs: boot.videoGenerationPollIntervalMs,
            onLocationBoot: boot.onLocationBoot
        )
        let restart = router.runtime.sessionRestart
        Task.detached {
            try? await restart.resumeSuspendedSessions()
        }
        let corsOpts = CorsOptions(cors: options.cors)
        let baseHandler: ServerHTTPHandler = { request in
            await router.handle(request)
        }
        let siteGuarded = RequestSite.middleware(corsOpts)(baseHandler)
        let wrapped = ServerCORSMiddleware.wrap(options: corsOpts, next: siteGuarded)
        return Handle(router: router, fetch: wrapped)
    }
}

// MARK: - 17. Managed Server Process (server/src/process.ts)

public enum ServerProcess {
    // parity: server/src/process.ts#Lifecycle [status=adapted hash=009e2f2dbcb9]
    public protocol Lifecycle: Sendable {
        func onListen(
            address: ServerSocketAddress,
            shutdown: @escaping @Sendable () -> Void
        ) async throws -> @Sendable () async -> Void
    }

    // parity: server/src/process.ts#Transform [status=implemented hash=b7ea6540f1bc]
    public typealias Transform = @Sendable (@escaping ServerHTTPHandler) -> ServerHTTPHandler

    public final class RunningServer: Sendable {
        public let address: ServerSocketAddress
        public let server: POSIXHTTPServer
        public let router: ServerRouter
        public let status: ServiceStatus.Store
        public let transport: ServerInProcessTransport
        private let shutdownFlag: Mutex<Bool>
        private let stopRunsHook: (@Sendable () async -> Void)?
        private let cleanupHook: (@Sendable () async -> Void)?

        internal init(
            address: ServerSocketAddress,
            server: POSIXHTTPServer,
            router: ServerRouter,
            status: ServiceStatus.Store,
            handler: @escaping ServerHTTPHandler,
            stopRunsHook: (@Sendable () async -> Void)? = nil,
            cleanupHook: (@Sendable () async -> Void)?
        ) {
            self.address = address
            self.server = server
            self.router = router
            self.status = status
            self.transport = ServerInProcessTransport(handler: handler)
            self.shutdownFlag = Mutex(false)
            self.stopRunsHook = stopRunsHook
            self.cleanupHook = cleanupHook
        }

        public func updateAvailable(version: String) async {
            _ = try? await router.runtime.bus.publish(
                InstallationEventSchema.UpdateAvailable,
                data: InstallationEventSchema.VersionData(version: version)
            )
        }

        public func updated(version: String) async {
            _ = try? await router.runtime.bus.publish(
                InstallationEventSchema.Updated,
                data: InstallationEventSchema.VersionData(version: version)
            )
        }

        public func stop() async {
            let already = shutdownFlag.withLock { flag -> Bool in
                if flag { return true }
                flag = true
                return false
            }
            guard !already else { return }
            status.beginStopping()
            server.stop()
            if let stopRunsHook {
                await stopRunsHook()
            }
            await router.runtime.close()
            if let cleanupHook {
                await cleanupHook()
            }
        }
    }

    /// A long-running application service loop the server process starts once its router exists and stops with the
    /// server (upstream `Automation.Service.run` and the one-time `SessionSearchBuild.Service.run`, forked into the
    /// application scope from any server process).
    public typealias ApplicationRun = @Sendable (ServerAppRuntime) async -> Void

    /// Default application-scoped service loops forked by `ServerProcess.start`, matching upstream
    /// `server/src/process.ts#start` (`Automation.Service.run` and `SessionSearchBuild.Service.run`).
    public static let defaultApplicationRuns: [ApplicationRun] = [
        { runtime in await runtime.automation.run() },
        { runtime in await runtime.sessionSearchBuild.run() },
    ]

    /// Starts the real HTTP/1.1 + SSE + WebSocket TCP server process with startup/ready/stopping lifecycle dispatch.
    // parity: server/src/process.ts#start [status=adapted hash=d786fa4dc2d5]
    public static func start(
        options: ServerOptions,
        lifecycle: (any Lifecycle)? = nil,
        transform: Transform? = nil,
        remoteURLs: (@Sendable () -> [String])? = nil,
        fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
        httpTransport: any HTTPTransport = URLSessionHTTPTransport.shared,
        environment: any EnvironmentProviding = SystemEnvironment.shared,
        globalOverrides: Global.Overrides? = nil,
        defaultDirectory: String? = nil,
        onLocationBoot: ServerAppRuntime.LocationCustomizer? = nil,
        applicationRuns: [ApplicationRun] = ServerProcess.defaultApplicationRuns
    ) async throws -> RunningServer {
        guard let password = options.password, !password.isEmpty else {
            throw InvalidRequestError(message: "Missing server password")
        }
        let hostname = options.hostname ?? "127.0.0.1"
        let status = ServiceStatus.make(initial: .starting)
        let routerBox = Mutex<ServerRouter?>(nil)
        let corsOpts = CorsOptions(cors: options.cors)
        let authInfo = ServerAuth.Info(password: password, username: "opencode")
        let version = options.app?.version ?? "unknown"
        let tmpPath = Global.make(globalOverrides ?? Global.Overrides(), environment: environment).tmp

        let boundURLsBox = Mutex<@Sendable () -> [String]>({ [] })
        let baseDispatch: ServerHTTPHandler = { request in
            let currentState = status.current
            let readyRouter = routerBox.withLock { $0 }
            let isReady = currentState == .ready && readyRouter != nil
            let fullURL = request.url

            if request.method == "GET" && request.pathname == "/api/info" && !isReady {
                if !authorizedRequest(request, config: authInfo) {
                    return unauthorizedResponse(request)
                }
                return processInfoResponse(
                    status: currentState,
                    version: version,
                    urls: boundURLsBox.withLock { $0 }(),
                    tmp: tmpPath
                )
            }

            let ticketExempt = isReady
                && (hasPtyConnectTicketURL(fullURL)
                    || hasPersistentPtyConnectTicketURL(fullURL)
                    || hasMcpClientTicketURL(fullURL))
            if !isPairingConnectURL(fullURL) && !isMachineLinkURL(fullURL) && !ticketExempt && !authorizedRequest(request, config: authInfo) {
                return unauthorizedResponse(request)
            }

            if isReady, let readyRouter {
                return await readyRouter.handle(request)
            }
            return processUnavailableResponse(status: currentState)
        }

        let transformed = transform?(baseDispatch) ?? baseDispatch
        let finalHandler = ServerCORSMiddleware.wrap(
            options: corsOpts,
            next: RequestSite.middleware(corsOpts)(transformed)
        )

        let tcpServer = try POSIXHTTPServer.start(hostname: hostname, port: options.port, handler: finalHandler)
        let boundAddress = tcpServer.address
        let urlsClosure: @Sendable () -> [String] = {
            let local = ServerInfo.connectionURLs(boundAddress.urlString, requestedHostname: hostname)
            let remote = remoteURLs?() ?? []
            return local + remote
        }
        boundURLsBox.withLock { $0 = urlsClosure }

        var cleanupHook: (@Sendable () async -> Void)? = nil
        if let lifecycle {
            cleanupHook = try await lifecycle.onListen(address: boundAddress) {
                status.beginStopping()
                tcpServer.stop()
            }
        }

        do {
            let router = try await createRoutes(
                options: options,
                serviceURLs: urlsClosure,
                fileSystem: fileSystem,
                httpTransport: httpTransport,
                environment: environment,
                globalOverrides: globalOverrides,
                defaultDirectory: defaultDirectory,
                onLocationBoot: onLocationBoot
            )
            if lifecycle != nil {
                let restart = router.runtime.sessionRestart
                Task.detached {
                    try? await restart.resumeSuspendedSessions()
                }
            }
            // Application-scoped service loops run from any server process; they stop with the server.
            let runtime = router.runtime
            let runs = applicationRuns.map { run in Task.detached { await run(runtime) } }
            let stopRuns: (@Sendable () async -> Void)? = runs.isEmpty ? nil : { @Sendable in
                for run in runs { run.cancel() }
                for run in runs { await run.value }
            }
            routerBox.withLock { $0 = router }
            status.ready()
            return RunningServer(
                address: boundAddress,
                server: tcpServer,
                router: router,
                status: status,
                handler: finalHandler,
                stopRunsHook: stopRuns,
                cleanupHook: cleanupHook
            )
        } catch {
            status.fail()
            tcpServer.stop()
            if let cleanupHook {
                await cleanupHook()
            }
            throw error
        }
    }

    private static func processInfoResponse(
        status: ServiceStatus.State,
        version: String,
        urls: [String],
        tmp: String
    ) -> ServerHTTPResponse {
        struct PreReadyInfo: Encodable {
            let version: String
            let pid: Int
            let urls: [String]
            let paths: ServerInfo.Paths
        }
        let code = status == .ready ? 200 : (status == .failed ? 500 : 503)
        let headers: [String: String] = (status == .starting || status == .stopping) ? ["retry-after": "1"] : [:]
        return ServerHTTPResponse.json(
            PreReadyInfo(version: version, pid: ServerHostInfo.processID(), urls: urls, paths: ServerInfo.Paths(tmp: tmp)),
            statusCode: code,
            headers: headers
        )
    }

    private static func processUnavailableResponse(status: ServiceStatus.State) -> ServerHTTPResponse {
        if status == .failed {
            struct FailedBody: Encodable {
                let code: String
                let message: String
                let action: String
            }
            return ServerHTTPResponse.json(
                FailedBody(
                    code: "service_failed",
                    message: "The background service could not start.",
                    action: "Run `opencode service restart` after checking the service logs."
                ),
                statusCode: 503
            )
        }
        struct StartingBody: Encodable {
            let code: String
        }
        return ServerHTTPResponse.json(
            StartingBody(code: status == .stopping ? "service_stopping" : "service_starting"),
            statusCode: 503,
            headers: ["retry-after": "1"]
        )
    }
}

// MARK: - 18. Workerd Runtime Profile (server/src/workerd.ts)

public enum ServerWorkerd {
    public struct ConfigOption: Equatable, Hashable, Sendable, Codable {
        public let content: String?

        public init(content: String? = nil) {
            self.content = content
        }
    }

    // parity: server/src/workerd.ts#Options [status=implemented hash=a05f7cdcbdb9]
    public struct Options: Sendable {
        public let storage: any CoreDatabaseWorkerdSQLite.DurableObjectStorage
        public let app: ServerOptions.AppOptions?
        public let password: String?
        public let config: ConfigOption?
        public let models: CoreModel.ModelsDev.Options?
        public let fetch: LayerNodePlatform.Fetch?

        public init(
            storage: any CoreDatabaseWorkerdSQLite.DurableObjectStorage,
            app: ServerOptions.AppOptions? = nil,
            password: String? = nil,
            config: ConfigOption? = nil,
            models: CoreModel.ModelsDev.Options? = nil,
            fetch: LayerNodePlatform.Fetch? = nil
        ) {
            self.storage = storage
            self.app = app
            self.password = password
            self.config = config
            self.models = models
            self.fetch = fetch
        }
    }

    /// Builds a web-standard fetch handler configured for the workerd / Durable Object runtime profile.
    // parity: server/src/workerd.ts#create [status=adapted hash=9395bff1fb3b]
    public static func create(_ options: Options) async throws -> ServerFetch.Handle {
        let adapter = CoreDatabaseWorkerdSQLite.StorageClientAdapter(storage: options.storage)
        let transport: any HTTPTransport = options.fetch.map { LayerNodePlatform.FetchTransport($0) }
            ?? URLSessionHTTPTransport.shared
        return try await ServerFetch.make(
            options: serverOptions(options),
            boot: ServerFetch.BootOptions(
                overrides: replacements(options),
                httpTransport: transport,
                databaseClient: adapter,
                workerdProfile: true
            )
        )
    }

    /// Maps `ServerWorkerd.Options` into `ServerOptions` with local filesystem watchers disabled and durable events forced on.
    // parity: server/src/workerd.ts#serverOptions [status=implemented hash=300912f722a5]
    public static func serverOptions(_ options: Options) -> ServerOptions {
        ServerOptions(
            app: options.app,
            password: options.password,
            events: ServerOptions.EventsOptions(persist: true),
            models: options.models,
            fetch: options.fetch,
            config: ServerOptions.ConfigOptions(content: options.config?.content),
            fs: ServerOptions.FSOptions(filewatcher: false, fff: false)
        )
    }

    /// Returns the workerd replacement graph swapping local-only services with workerd-safe stubs.
    // parity: server/src/workerd.ts#replacements [status=adapted hash=bb3e569f9423]
    public static func replacements(_ options: Options) -> [LayerNode.Replacement] {
        var result: [LayerNode.Replacement] = []
        if let dbRep = try? CoreDatabaseStore.node.replace(
            with: AppNode.makeGlobalNode(
                CoreDatabaseStore.Service.serviceKey,
                CoreDatabaseWorkerdSQLite.sqliteLayer(storage: options.storage),
                []
            )
        ) {
            result.append(dbRep)
        }
        result.append(CoreSnapshot.node.replace(with: CoreSnapshot.noopLayer))
        result.append(CoreVcs.Vcs.node.replace(
            with: LayerNode.ExecutableLayer.succeed(key: CoreVcs.Vcs.Service.serviceKey, value: ServerWorkerdNoopVcs() as any CoreVcs.Vcs.Interface)
        ))
        result.append(CoreFilesystem.node.replace(
            with: LayerNode.ExecutableLayer.succeed(key: CoreFilesystem.Service.serviceKey, value: ServerWorkerdUnavailableFileSystem() as any CoreFilesystem.Interface)
        ))
        result.append(CoreFilesystem.Search.node.replace(
            with: LayerNode.ExecutableLayer.succeed(key: CoreFilesystem.Search.Service.serviceKey, value: ServerWorkerdUnavailableFileSystemSearch() as any CoreFilesystem.Search.Interface)
        ))
        result.append(CorePty.node.replace(
            with: LayerNode.ExecutableLayer.succeed(key: CorePty.Service.serviceKey, value: ServerWorkerdUnavailablePty() as any CorePty.Interface)
        ))
        result.append(CoreBlobStore.node.replace(with: CoreBlobStore.unsupportedLayer))
        result.append(CoreIntegration.VideoGeneration.node.replace(with: CoreIntegration.VideoGeneration.unsupportedLayer))
        if let pluginRep = try? CoreConfigPlugin.Source.node.replace(with: CoreConfigPlugin.Source.empty) {
            result.append(pluginRep)
        }
        return result
    }
}

// MARK: - Workerd Profile Stub Services

public struct WorkerdUnavailableError: Error, Equatable, Sendable, CustomStringConvertible {
    public let operation: String
    public var description: String { "\(operation) is unavailable in the workerd profile" }

    public init(_ operation: String) {
        self.operation = operation
    }
}

public final class ServerWorkerdUnavailableFileSystem: CoreFilesystem.Interface, Sendable {
    public init() {}

    public func read(_ input: CoreFilesystem.ReadInput) async throws -> CoreFilesystem.File {
        _ = input
        throw WorkerdUnavailableError("FileSystem.read")
    }

    public func list(_ input: CoreFilesystem.ListInput?) async throws -> [FileSystemSchema.Entry] {
        _ = input
        throw WorkerdUnavailableError("FileSystem.list")
    }

    public func find(_ input: FileSystemSchema.FindInput) async -> [FileSystemSchema.Entry] {
        _ = input
        return []
    }

    public func write(_ input: CoreFilesystem.WriteInput) async throws -> FileSystemSchema.Write {
        _ = input
        throw WorkerdUnavailableError("FileSystem.write")
    }
}

public final class ServerWorkerdUnavailableFileSystemSearch: CoreFilesystem.Search.Interface, Sendable {
    public init() {}

    public func find(_ input: FileSystemSchema.FindInput) async -> [FileSystemSchema.Entry] {
        _ = input
        return []
    }
}

public final class ServerWorkerdUnavailablePty: CorePty.Interface, Sendable {
    public init() {}

    public func list() async -> [CorePty.Info] { [] }

    public func get(_ id: CorePty.ID) async throws -> CorePty.Info {
        throw CorePty.NotFoundError(ptyID: id)
    }

    public func create(_ input: CorePty.CreateInput) async throws -> CorePty.Info {
        _ = input
        throw WorkerdUnavailableError("Pty.create")
    }

    public func update(_ id: CorePty.ID, input: CorePty.UpdateInput) async throws -> CorePty.Info {
        _ = input
        throw CorePty.NotFoundError(ptyID: id)
    }

    public func remove(_ id: CorePty.ID) async throws {
        throw CorePty.NotFoundError(ptyID: id)
    }

    public func write(_ id: CorePty.ID, data: String) async throws {
        _ = data
        throw CorePty.NotFoundError(ptyID: id)
    }

    public func attach(_ id: CorePty.ID, input: CorePty.AttachInput) async throws -> CorePty.Attachment {
        _ = input
        throw CorePty.NotFoundError(ptyID: id)
    }
}

public final class ServerWorkerdNoopVcs: CoreVcs.Vcs.Interface, Sendable {
    public init() {}

    public func transform(_ update: @escaping @Sendable (CoreVcs.Vcs.Editor) throws -> Void) async throws -> CoreState.Registration {
        _ = update
        return CoreState.Registration {}
    }

    public func reload() async {}

    public func initialize(providerID: String) async throws {
        _ = providerID
        throw CoreVcs.Vcs.InitializeError(kind: .unsupported)
    }

    public func info() async -> VcsSchema.Info {
        VcsSchema.Info(provider: nil, branch: VcsSchema.Branch())
    }

    public func base() async throws -> VcsSchema.Base? { nil }

    public func branches(_ options: CoreVcs.Vcs.BranchOptions?) async -> VcsSchema.BranchList {
        _ = options
        return []
    }

    public func status() async -> [VcsSchema.FileStatus] { [] }

    public func diff(_ mode: VcsSchema.Mode, options: CoreVcs.Vcs.DiffOptions?) async throws -> [FileDiffSchema.Info] {
        _ = (mode, options)
        return []
    }
}
