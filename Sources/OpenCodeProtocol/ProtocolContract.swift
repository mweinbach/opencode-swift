import OpenCodeSchema

/// Typed HTTP method enumeration for `OpenCodeProtocol` endpoint definitions.
public enum HTTPMethod: String, Equatable, Hashable, Sendable, Codable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
    case head = "HEAD"
    case options = "OPTIONS"
}

/// Declarative endpoint descriptor mirroring `packages/protocol/src/groups/*`.
public struct EndpointDescriptor: Equatable, Hashable, Sendable, Codable {
    public let group: String
    public let name: String
    public let method: HTTPMethod
    public let path: String
    public let experimental: Bool

    public init(
        group: String,
        name: String,
        method: HTTPMethod,
        path: String,
        experimental: Bool = false
    ) {
        self.group = group
        self.name = name
        self.method = method
        self.path = path
        self.experimental = experimental
    }

    public var openAPIIdentifier: String {
        experimental ? "experimental.\(group).\(name)" : "\(group).\(name)"
    }
}

/// Catalog of upstream `packages/protocol` API groups to be ported 1:1.
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
