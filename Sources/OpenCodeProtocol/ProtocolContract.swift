import OpenCodeSchema

/// Typed HTTP method enumeration for `OpenCodeProtocol` endpoint definitions.
public enum HTTPMethod: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
    case head = "HEAD"
    case options = "OPTIONS"
    case trace = "TRACE"
}

/// Wire placement of a typed endpoint parameter.
public enum ParameterLocation: String, Equatable, Hashable, Sendable, Codable {
    case path
    case query
    case header
}

/// OpenAPI serialization style for a parameter.
public enum ParameterStyle: String, Equatable, Hashable, Sendable, Codable {
    case simple
    case form
    case deepObject
}

/// Declarative descriptor for a path, query, or header parameter on an HTTP API endpoint.
public struct ParameterDescriptor: Equatable, Hashable, Sendable, Codable {
    public let name: String
    public let location: ParameterLocation
    public let required: Bool
    public let typeName: String
    public let description: String?
    public let pattern: String?
    public let style: ParameterStyle?
    public let explode: Bool?

    public init(
        name: String,
        location: ParameterLocation,
        required: Bool = false,
        typeName: String = "String",
        description: String? = nil,
        pattern: String? = nil,
        style: ParameterStyle? = nil,
        explode: Bool? = nil
    ) {
        self.name = name
        self.location = location
        self.required = required
        self.typeName = typeName
        self.description = description
        self.pattern = pattern
        self.style = style
        self.explode = explode
    }

    public func withOpenAPIStyle(_ style: ParameterStyle, explode: Bool) -> ParameterDescriptor {
        ParameterDescriptor(
            name: name,
            location: location,
            required: required,
            typeName: typeName,
            description: description,
            pattern: pattern,
            style: style,
            explode: explode
        )
    }
}

/// Wire encoding of an endpoint's request payload or success response.
public enum PayloadEncoding: String, Equatable, Hashable, Sendable, Codable {
    case json = "application/json"
    case binary = "application/octet-stream"
}

/// Wire encoding of an endpoint's success response.
public enum ResponseEncoding: String, Equatable, Hashable, Sendable, Codable {
    case json = "application/json"
    case noContent = "204"
    case binary = "application/octet-stream"
    case sse = "text/event-stream"
    case websocket = "websocket"
}

/// Declarative endpoint descriptor mirroring `packages/protocol/src/groups/*`.
public struct EndpointDescriptor: Equatable, Hashable, Sendable, Codable {
    public let group: String
    public let name: String
    public let method: HTTPMethod
    public let path: String
    public let experimental: Bool
    public let openAPIIdentifier: String
    public let summary: String?
    public let description: String?
    public let pathParameters: [ParameterDescriptor]
    public let queryParameters: [ParameterDescriptor]
    public let headerParameters: [ParameterDescriptor]
    public let payloadType: String?
    public let payloadEncoding: PayloadEncoding?
    public let successType: String
    public let successEncoding: ResponseEncoding
    public let errors: [ProtocolErrorRef]
    public let middlewares: [MiddlewareDescriptor]
    public let tags: [String]
    public let isWebSocket: Bool
    public let isDeprecated: Bool

    public init(
        group: String,
        name: String,
        method: HTTPMethod,
        path: String,
        experimental: Bool = false,
        openAPIIdentifier: String? = nil,
        summary: String? = nil,
        description: String? = nil,
        pathParameters: [ParameterDescriptor] = [],
        queryParameters: [ParameterDescriptor] = [],
        headerParameters: [ParameterDescriptor] = [],
        payloadType: String? = nil,
        payloadEncoding: PayloadEncoding? = nil,
        successType: String = "Success",
        successEncoding: ResponseEncoding = .json,
        errors: [ProtocolErrorRef] = [],
        middlewares: [MiddlewareDescriptor] = [],
        tags: [String] = [],
        isWebSocket: Bool = false,
        isDeprecated: Bool = false
    ) {
        self.group = group
        self.name = name
        self.method = method
        self.path = path
        self.experimental = experimental
        self.openAPIIdentifier = openAPIIdentifier ?? (experimental ? "experimental.\(group).\(name)" : "\(group).\(name)")
        self.summary = summary
        self.description = description
        self.pathParameters = pathParameters
        self.queryParameters = queryParameters
        self.headerParameters = headerParameters
        self.payloadType = payloadType
        self.payloadEncoding = payloadEncoding ?? (payloadType == nil ? nil : .json)
        self.successType = successType
        self.successEncoding = successEncoding
        self.errors = errors
        self.middlewares = middlewares
        self.tags = tags
        self.isWebSocket = isWebSocket
        self.isDeprecated = isDeprecated
    }

    /// Converts `:param` route template segments to OpenAPI `{param}` syntax.
    public var openAPIPath: String {
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        let converted = segments.map { segment -> String in
            if segment.hasPrefix(":") && segment.count > 1 {
                return "{\(segment.dropFirst())}"
            }
            return String(segment)
        }
        return converted.joined(separator: "/")
    }

    /// All parameters declared on this endpoint (path, header, then query).
    public var allParameters: [ParameterDescriptor] {
        pathParameters + headerParameters + queryParameters
    }

    /// Expected HTTP success status code (`204` for no-content endpoints, `200` otherwise).
    public var successStatusCode: Int {
        successEncoding == .noContent ? 204 : 200
    }

    /// Returns a copy with `group` and default tags updated when attached to an `EndpointGroupDescriptor`.
    public func assigned(toGroup groupID: String, defaultTag: String) -> EndpointDescriptor {
        EndpointDescriptor(
            group: groupID,
            name: name,
            method: method,
            path: path,
            experimental: experimental,
            openAPIIdentifier: openAPIIdentifier,
            summary: summary,
            description: description,
            pathParameters: pathParameters,
            queryParameters: queryParameters,
            headerParameters: headerParameters,
            payloadType: payloadType,
            payloadEncoding: payloadEncoding,
            successType: successType,
            successEncoding: successEncoding,
            errors: errors,
            middlewares: middlewares,
            tags: tags.isEmpty ? [defaultTag] : tags,
            isWebSocket: isWebSocket,
            isDeprecated: isDeprecated
        )
    }

    /// Returns a copy with `middleware` attached and its errors merged (deduplicated, preserving order).
    public func withMiddleware(_ middleware: MiddlewareDescriptor) -> EndpointDescriptor {
        var nextMiddlewares = middlewares
        if !nextMiddlewares.contains(middleware) {
            nextMiddlewares.append(middleware)
        }
        var nextErrors = errors
        for err in middleware.errors where !nextErrors.contains(err) {
            nextErrors.append(err)
        }
        return EndpointDescriptor(
            group: group,
            name: name,
            method: method,
            path: path,
            experimental: experimental,
            openAPIIdentifier: openAPIIdentifier,
            summary: summary,
            description: description,
            pathParameters: pathParameters,
            queryParameters: queryParameters,
            headerParameters: headerParameters,
            payloadType: payloadType,
            payloadEncoding: payloadEncoding,
            successType: successType,
            successEncoding: successEncoding,
            errors: nextErrors,
            middlewares: nextMiddlewares,
            tags: tags,
            isWebSocket: isWebSocket,
            isDeprecated: isDeprecated
        )
    }

    /// Returns a copy with a transformed query parameter list.
    public func mappingQueryParameters(_ transform: (ParameterDescriptor) -> ParameterDescriptor) -> EndpointDescriptor {
        EndpointDescriptor(
            group: group,
            name: name,
            method: method,
            path: path,
            experimental: experimental,
            openAPIIdentifier: openAPIIdentifier,
            summary: summary,
            description: description,
            pathParameters: pathParameters,
            queryParameters: queryParameters.map(transform),
            headerParameters: headerParameters,
            payloadType: payloadType,
            payloadEncoding: payloadEncoding,
            successType: successType,
            successEncoding: successEncoding,
            errors: errors,
            middlewares: middlewares,
            tags: tags,
            isWebSocket: isWebSocket,
            isDeprecated: isDeprecated
        )
    }
}

/// Declarative group of HTTP API endpoints mirroring Effect's `HttpApiGroup`.
public struct EndpointGroupDescriptor: Equatable, Hashable, Sendable, Codable {
    public let identifier: String
    public let title: String
    public let description: String?
    public let endpoints: [EndpointDescriptor]
    public let middlewares: [MiddlewareDescriptor]

    public init(
        identifier: String,
        title: String,
        description: String? = nil,
        endpoints: [EndpointDescriptor] = [],
        middlewares: [MiddlewareDescriptor] = []
    ) {
        self.identifier = identifier
        self.title = title
        self.description = description
        self.endpoints = endpoints.map { $0.assigned(toGroup: identifier, defaultTag: title) }
        self.middlewares = middlewares
    }

    /// Appends one endpoint to this group without retroactively applying earlier group middlewares.
    public func adding(_ endpoint: EndpointDescriptor) -> EndpointGroupDescriptor {
        EndpointGroupDescriptor(
            identifier: identifier,
            title: title,
            description: description,
            endpoints: endpoints + [endpoint.assigned(toGroup: identifier, defaultTag: title)],
            middlewares: middlewares
        )
    }

    /// Appends multiple endpoints to this group.
    public func adding(_ newEndpoints: [EndpointDescriptor]) -> EndpointGroupDescriptor {
        EndpointGroupDescriptor(
            identifier: identifier,
            title: title,
            description: description,
            endpoints: endpoints + newEndpoints.map { $0.assigned(toGroup: identifier, defaultTag: title) },
            middlewares: middlewares
        )
    }

    /// Applies middleware to all endpoints currently registered in this group (mirroring Effect's `HttpApiGroup.middleware`).
    public func middleware(_ mw: MiddlewareDescriptor) -> EndpointGroupDescriptor {
        var nextMiddlewares = middlewares
        if !nextMiddlewares.contains(mw) {
            nextMiddlewares.append(mw)
        }
        return EndpointGroupDescriptor(
            identifier: identifier,
            title: title,
            description: description,
            endpoints: endpoints.map { $0.withMiddleware(mw) },
            middlewares: nextMiddlewares
        )
    }
}

/// Pure-Swift URL pathname & query parser matching WHATWG `URL.pathname` and `URL.searchParams.get(...)`
/// without any OS or Foundation imports.
public struct ProtocolURLComponents: Equatable, Hashable, Sendable {
    public let pathname: String
    public let queryItems: [(name: String, value: String)]

    public init(urlString: String) {
        // Strip fragment (#...)
        let withoutFragment: Substring
        if let hashIndex = urlString.firstIndex(of: "#") {
            withoutFragment = urlString[..<hashIndex]
        } else {
            withoutFragment = urlString[...]
        }

        // Split path part and query string at first '?'
        let pathPart: Substring
        let queryPart: Substring?
        if let queryIndex = withoutFragment.firstIndex(of: "?") {
            pathPart = withoutFragment[..<queryIndex]
            queryPart = withoutFragment[withoutFragment.index(after: queryIndex)...]
        } else {
            pathPart = withoutFragment
            queryPart = nil
        }

        // Extract pathname from either full URL (scheme://authority/path) or raw path
        let rawPathname: String
        if let schemeRange = ProtocolURLComponents.findSchemeDelimiter(in: pathPart) {
            let afterScheme = pathPart[schemeRange.upperBound...]
            if let slashIndex = afterScheme.firstIndex(of: "/") {
                rawPathname = String(afterScheme[slashIndex...])
            } else {
                rawPathname = "/"
            }
        } else if pathPart.isEmpty {
            rawPathname = "/"
        } else {
            rawPathname = String(pathPart)
        }

        self.pathname = ProtocolURLComponents.normalizeDotSegments(rawPathname)

        if let queryPart, !queryPart.isEmpty {
            var parsed: [(name: String, value: String)] = []
            for pair in queryPart.split(separator: "&", omittingEmptySubsequences: true) {
                if let eqIndex = pair.firstIndex(of: "=") {
                    let rawName = pair[..<eqIndex]
                    let rawValue = pair[pair.index(after: eqIndex)...]
                    parsed.append((
                        name: ProtocolURLComponents.decodeFormComponent(rawName),
                        value: ProtocolURLComponents.decodeFormComponent(rawValue)
                    ))
                } else {
                    parsed.append((
                        name: ProtocolURLComponents.decodeFormComponent(pair),
                        value: ""
                    ))
                }
            }
            self.queryItems = parsed
        } else {
            self.queryItems = []
        }
    }

    public static func == (lhs: ProtocolURLComponents, rhs: ProtocolURLComponents) -> Bool {
        guard lhs.pathname == rhs.pathname, lhs.queryItems.count == rhs.queryItems.count else {
            return false
        }
        for i in 0..<lhs.queryItems.count {
            if lhs.queryItems[i].name != rhs.queryItems[i].name || lhs.queryItems[i].value != rhs.queryItems[i].value {
                return false
            }
        }
        return true
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(pathname)
        hasher.combine(queryItems.count)
        for item in queryItems {
            hasher.combine(item.name)
            hasher.combine(item.value)
        }
    }

    /// Mirrors `URL.searchParams.get(name)` (returns first matching parameter value, or `nil`).
    public func queryValue(for name: String) -> String? {
        queryItems.first(where: { $0.name == name })?.value
    }

    /// Returns `true` iff `queryValue(for: name)` exists and is non-empty (matching JS `!!url.searchParams.get(name)`).
    public func hasNonEmptyQueryValue(for name: String) -> Bool {
        guard let value = queryValue(for: name) else { return false }
        return !value.isEmpty
    }

    private static func findSchemeDelimiter(in input: Substring) -> Range<Substring.Index>? {
        guard let range = input.range(of: "://") else { return nil }
        let scheme = input[..<range.lowerBound]
        guard let first = scheme.utf8.first, isASCIIAlpha(first) else { return nil }
        for byte in scheme.utf8.dropFirst() {
            let ok = isASCIIAlpha(byte) || isASCIIDigit(byte) || byte == 43 || byte == 45 || byte == 46 // + - .
            if !ok { return nil }
        }
        return range
    }

    private static func normalizeDotSegments(_ path: String) -> String {
        guard path.contains("/.") else { return path }
        let hadLeadingSlash = path.hasPrefix("/")
        let hadTrailingSlash = path.hasSuffix("/")
        var stack: [Substring] = []
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        for (idx, part) in parts.enumerated() {
            if idx == 0 && hadLeadingSlash && part.isEmpty {
                continue
            }
            if part == "." {
                continue
            } else if part == ".." {
                if !stack.isEmpty {
                    stack.removeLast()
                }
            } else if !(idx == parts.count - 1 && part.isEmpty) {
                stack.append(part)
            }
        }
        let body = stack.joined(separator: "/")
        let prefix = hadLeadingSlash ? "/" : ""
        let suffix = (hadTrailingSlash && !body.isEmpty) ? "/" : ""
        return prefix + body + suffix
    }

    private static func decodeFormComponent(_ input: Substring) -> String {
        let bytes = Array(input.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == 43 { // '+'
                out.append(32) // ' '
                i += 1
            } else if b == 37, i + 2 < bytes.count,
                      let hi = hexValue(bytes[i + 1]),
                      let lo = hexValue(bytes[i + 2]) {
                out.append((hi << 4) | lo)
                i += 3
            } else {
                out.append(b)
                i += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func isASCIIAlpha(_ b: UInt8) -> Bool {
        (b >= 65 && b <= 90) || (b >= 97 && b <= 122)
    }

    private static func isASCIIDigit(_ b: UInt8) -> Bool {
        b >= 48 && b <= 57
    }

    private static func hexValue(_ b: UInt8) -> UInt8? {
        switch b {
        case 48...57: return b - 48
        case 65...70: return b - 55
        case 97...102: return b - 87
        default: return nil
        }
    }
}

/// Catalog of upstream `packages/protocol` API groups ported 1:1.
public enum ProtocolCatalog {
    public static let apiVersion = "1"

    /// Canonical list of all 38 upstream protocol groups in `packages/protocol/src/groups/`.
    public static let upstreamGroups: [String] = [
        "agent", "artifact", "automation", "blob", "command", "config",
        "credential", "debug", "event", "experimental", "form", "fs",
        "generate", "integration", "job", "location", "mcp", "media",
        "message", "migration", "model", "permission", "persistent-pty",
        "plugin", "project", "provider", "pty", "reference", "rpc",
        "server", "session", "shell", "skill", "usage", "vcs",
        "voice", "websearch", "worktree",
    ]
}
