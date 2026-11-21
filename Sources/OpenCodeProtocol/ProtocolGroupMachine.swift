import OpenCodeSchema

// MARK: - groups/machine.ts (`server.experimental` machine routes & WebSocket link)

// parity: protocol/src/groups/machine.ts#MACHINE_LINK_PATH [status=implemented hash=cdfabb1fb060]
public let MACHINE_LINK_PATH = "/api/experimental/machine/link"

private let machineExperimentalNote =
    "Behind the machines flag. Experimental: may change without compatibility guarantees."

/// Known remote machine status returned by `GET /api/experimental/machine` (`Machine.Info`).
// parity: protocol/src/groups/machine.ts#MachineInfo [status=implemented hash=3680a094f892]
public struct MachineInfo: Equatable, Hashable, Sendable, Codable {
    public struct Connection: Equatable, Hashable, Sendable, Codable {
        public enum Kind: String, Equatable, Hashable, Sendable, Codable {
            case websocket
            case iroh
        }

        public enum Path: String, Equatable, Hashable, Sendable, Codable {
            case direct
            case relayed
        }

        public let kind: Kind
        public let path: Path?
        /// Round-trip time in milliseconds.
        public let rtt: Double?

        public init(kind: Kind, path: Path? = nil, rtt: Double? = nil) {
            self.kind = kind
            self.path = path
            self.rtt = rtt
        }
    }

    public let id: String
    public let online: Bool
    public let paired: Bool
    public let os: String?
    public let arch: String?
    public let connection: Connection?

    public init(
        id: String,
        online: Bool,
        paired: Bool,
        os: String? = nil,
        arch: String? = nil,
        connection: Connection? = nil
    ) {
        self.id = id
        self.online = online
        self.paired = paired
        self.os = os
        self.arch = arch
        self.connection = connection
    }
}

/// WebSocket URL reach address carried in machine invite requests and responses (`Machine.Reach`).
// parity: protocol/src/groups/machine.ts#MachineReach [status=implemented hash=1b6ba6da5290]
public struct MachineReach: Equatable, Hashable, Sendable, Codable {
    public let type: String
    public let url: String

    public init(url: String) {
        self.type = "url"
        self.url = url
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        guard type == "url" else {
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Expected Machine.Reach type 'url', got '\(type)'"
            )
        }
        self.type = "url"
        self.url = try container.decode(String.self, forKey: .url)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("url", forKey: .type)
        try container.encode(url, forKey: .url)
    }

    enum CodingKeys: String, CodingKey {
        case type
        case url
    }
}

/// Request payload for `POST /api/experimental/machine` (`Machine.AddPayload`).
// parity: protocol/src/groups/machine.ts#MachineAddPayload [status=implemented hash=a92b042d399f]
public struct MachineAddPayload: Equatable, Hashable, Sendable, Codable {
    public let name: String
    public let reach: [MachineReach]
    public let replace: Bool?

    public init(name: String, reach: [MachineReach], replace: Bool? = nil) {
        self.name = name
        self.reach = reach
        self.replace = replace
    }
}

/// Single-use join invite returned by `POST /api/experimental/machine` (`Machine.Invite`).
// parity: protocol/src/groups/machine.ts#MachineInvite [status=implemented hash=bacbe26df46d]
public struct MachineInvite: Equatable, Hashable, Sendable, Codable {
    public enum ReachEntry: Equatable, Hashable, Sendable, Codable {
        case url(String)
        case iroh

        enum CodingKeys: String, CodingKey {
            case type
            case url
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "url":
                self = .url(try container.decode(String.self, forKey: .url))
            case "iroh":
                self = .iroh
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .type,
                    in: container,
                    debugDescription: "Unknown Machine.Invite reach type '\(type)'"
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .url(let url):
                try container.encode("url", forKey: .type)
                try container.encode(url, forKey: .url)
            case .iroh:
                try container.encode("iroh", forKey: .type)
            }
        }
    }

    public let name: String
    public let join: String
    public let expires: Int64
    public let reach: [ReachEntry]

    public init(name: String, join: String, expires: Int64, reach: [ReachEntry]) {
        self.name = name
        self.join = join
        self.expires = expires
        self.reach = reach
    }
}

/// Whether a request asks to become a WebSocket, the one request the machine link serves and the one the server lets in
/// without its password: a GET with `Upgrade: websocket` and `upgrade` among its `Connection` tokens.
// parity: protocol/src/groups/machine.ts#isWebSocketUpgrade [status=implemented hash=3e1d8759e3dd]
public func isWebSocketUpgrade(method: String, headers: [String: String]) -> Bool {
    guard method == "GET" else { return false }
    var upgradeHeader: String?
    var connectionHeader: String?
    for (key, value) in headers {
        let lower = key.lowercased()
        if lower == "upgrade" {
            upgradeHeader = value
        } else if lower == "connection" {
            connectionHeader = value
        }
    }
    guard upgradeHeader?.lowercased() == "websocket" else { return false }
    guard let connectionHeader else { return false }
    return connectionHeader.split(separator: ",").contains { token in
        trimASCIIWhitespace(token).lowercased() == "upgrade"
    }
}

/// The same, for code that runs before the router has matched a route: the path is the request's own, up to its query,
/// compared as it was sent. A URL parser would resolve `..` and a leading `//host` to this path, and the router would not.
// parity: protocol/src/groups/machine.ts#isMachineLinkUpgrade [status=implemented hash=2af6269122b9]
public func isMachineLinkUpgrade(method: String, url: String, headers: [String: String]) -> Bool {
    let rawPath: Substring
    if let q = url.firstIndex(of: "?") {
        rawPath = url[..<q]
    } else {
        rawPath = url[...]
    }
    return rawPath == MACHINE_LINK_PATH && isWebSocketUpgrade(method: method, headers: headers)
}

private func trimASCIIWhitespace(_ substring: Substring) -> String {
    let bytes = Array(substring.utf8)
    var start = 0
    var end = bytes.count
    while start < end && (bytes[start] == 0x20 || bytes[start] == 0x09 || bytes[start] == 0x0A || bytes[start] == 0x0D) {
        start += 1
    }
    while end > start && (bytes[end - 1] == 0x20 || bytes[end - 1] == 0x09 || bytes[end - 1] == 0x0A || bytes[end - 1] == 0x0D) {
        end -= 1
    }
    return String(decoding: bytes[start..<end], as: UTF8.self)
}

/// Lives in the `server.experimental` group (see `ExperimentalGroup`).
// parity: protocol/src/groups/machine.ts#MachineLinkEndpoint [status=implemented hash=ae11e66c28de]
public let MachineLinkEndpoint = EndpointDescriptor(
    group: "server.experimental",
    name: "machine.link",
    method: .get,
    path: MACHINE_LINK_PATH,
    experimental: true,
    openAPIIdentifier: "experimental.machine.link",
    summary: "Connect a machine",
    description: "Upgrade to a WebSocket that carries a machine's link to this server: binary messages only, each at most 65,535 bytes. It takes no server password. The link's own handshake, which starts with the machine's first message, is the only way in: it admits a key this server has paired or a valid join string, and closes the socket on anything else without saying why. Behind the machines flag; without it the route does not exist. Experimental: may change without compatibility guarantees.",
    successType: "Boolean",
    successEncoding: .websocket,
    tags: ["experimental"],
    isWebSocket: true
)

/// Lives in the `server.experimental` group (see `ExperimentalGroup`).
// parity: protocol/src/groups/machine.ts#MachineEndpoints [status=implemented hash=e9bac86cf50a]
public let MachineEndpoints: [EndpointDescriptor] = [
    MachineLinkEndpoint,
    EndpointDescriptor(
        group: "server.experimental",
        name: "machine.list",
        method: .get,
        path: "/api/experimental/machine",
        experimental: true,
        openAPIIdentifier: "experimental.machine.list",
        summary: "List machines",
        description: "List known machines and whether each is paired and online. \(machineExperimentalNote)",
        successType: "{ data: Machine.Info[] }",
        errors: [
            ProtocolErrorRef(ForbiddenError.self),
        ],
        tags: ["experimental"]
    ),
    EndpointDescriptor(
        group: "server.experimental",
        name: "machine.add",
        method: .post,
        path: "/api/experimental/machine",
        experimental: true,
        openAPIIdentifier: "experimental.machine.add",
        summary: "Add or invite a machine",
        description: "Add a machine by name if it does not exist, then create a single-use join string carrying the given reach addresses. \(machineExperimentalNote)",
        payloadType: "Machine.AddPayload",
        successType: "{ data: Machine.Invite }",
        errors: [
            ProtocolErrorRef(InvalidRequestError.self),
            ProtocolErrorRef(ForbiddenError.self),
            ProtocolErrorRef(MachineNotFoundError.self),
            ProtocolErrorRef(ConflictError.self),
        ],
        tags: ["experimental"]
    ),
    EndpointDescriptor(
        group: "server.experimental",
        name: "machine.remove",
        method: .delete,
        path: "/api/experimental/machine/:name",
        experimental: true,
        openAPIIdentifier: "experimental.machine.remove",
        summary: "Remove a machine",
        description: "Forget a machine by name, closing any live link and revoking its key. \(machineExperimentalNote)",
        pathParameters: [
            ParameterDescriptor(
                name: "name",
                location: .path,
                required: true,
                typeName: "String"
            ),
        ],
        successType: "NoContent",
        successEncoding: .noContent,
        errors: [
            ProtocolErrorRef(ForbiddenError.self),
            ProtocolErrorRef(MachineNotFoundError.self),
        ],
        tags: ["experimental"]
    ),
]
