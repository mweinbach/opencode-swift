import Foundation

// MARK: - HTTP API Wire Models (`@opentunnel/protocol/api`)

public enum OpenTunnelAPIState: String, Equatable, Hashable, Sendable, Codable {
    case offline
    case online
}

public struct OpenTunnelInfo: Equatable, Hashable, Sendable, Codable {
    public let id: String
    public let hostname: String
    public let state: OpenTunnelAPIState
    public let certificateID: String?

    public init(
        id: String,
        hostname: String,
        state: OpenTunnelAPIState = .offline,
        certificateID: String? = nil
    ) {
        self.id = id
        self.hostname = hostname
        self.state = state
        self.certificateID = certificateID
    }
}

public struct OpenTunnelCreateResponse: Equatable, Hashable, Sendable, Codable {
    public let tunnel: OpenTunnelInfo
    public let token: String

    public init(tunnel: OpenTunnelInfo, token: String) {
        self.tunnel = tunnel
        self.token = token
    }
}

public enum OpenTunnelCertificateState: Equatable, Hashable, Sendable, Codable {
    case challenge(token: String, key: String)
    case issuing
    case ready(certificate: String, chain: String, expiry: String)
    case failed(reason: String)

    private enum CodingKeys: String, CodingKey {
        case type, token, key, certificate, chain, expiry, reason
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "challenge":
            let token = try container.decode(String.self, forKey: .token)
            let key = try container.decode(String.self, forKey: .key)
            self = .challenge(token: token, key: key)
        case "issuing":
            self = .issuing
        case "ready":
            let certificate = try container.decode(String.self, forKey: .certificate)
            let chain = try container.decodeIfPresent(String.self, forKey: .chain) ?? ""
            let expiry = try container.decode(String.self, forKey: .expiry)
            self = .ready(certificate: certificate, chain: chain, expiry: expiry)
        case "failed":
            let reason = try container.decode(String.self, forKey: .reason)
            self = .failed(reason: reason)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown certificate state type: \(type)"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .challenge(token, key):
            try container.encode("challenge", forKey: .type)
            try container.encode(token, forKey: .token)
            try container.encode(key, forKey: .key)
        case .issuing:
            try container.encode("issuing", forKey: .type)
        case let .ready(certificate, chain, expiry):
            try container.encode("ready", forKey: .type)
            try container.encode(certificate, forKey: .certificate)
            try container.encode(chain, forKey: .chain)
            try container.encode(expiry, forKey: .expiry)
        case let .failed(reason):
            try container.encode("failed", forKey: .type)
            try container.encode(reason, forKey: .reason)
        }
    }
}

public struct OpenTunnelCertificateInfo: Equatable, Hashable, Sendable, Codable {
    public let id: String
    public let state: OpenTunnelCertificateState

    public init(id: String, state: OpenTunnelCertificateState) {
        self.id = id
        self.state = state
    }
}

public struct OpenTunnelAPIErrorBody: Equatable, Hashable, Sendable, Codable {
    public let tag: String?
    public let message: String?

    private enum CodingKeys: String, CodingKey {
        case tag = "_tag"
        case message
    }

    public init(tag: String? = nil, message: String? = nil) {
        self.tag = tag
        self.message = message
    }
}

// MARK: - API Retry Rules (`@opentunnel/protocol/api-retry.ts`)

public enum OpenTunnelAPIRetry {
    public static let retryBaseMs = 250
    public static let retryMaxMs = 8_000
    public static let maxRetries = 6

    public enum RepeatPolicy: Equatable, Hashable, Sendable {
        case idempotent
        case once
    }

    private static let onceRetryableStatuses: Set<Int> = [429, 503, 521, 522, 523, 525]

    private static let cloudflareReasons: [Int: String] = [
        520: "the server returned an unknown error",
        521: "the server refused the connection",
        522: "the connection to the server timed out",
        523: "the server is unreachable",
        524: "the server did not answer in time",
        525: "the SSL handshake with the server failed",
        526: "the server's certificate is invalid",
        527: "the connection to the server failed",
    ]

    public static func retryableStatus(_ status: Int, repeatPolicy: RepeatPolicy) -> Bool {
        switch repeatPolicy {
        case .idempotent:
            return status == 429 || (status >= 500 && status <= 599)
        case .once:
            return onceRetryableStatuses.contains(status)
        }
    }

    public static func retryDelayMs(
        attempt: Int,
        retryAfter: String? = nil,
        baseMs: Int = retryBaseMs,
        maxMs: Int = retryMaxMs
    ) -> (min: Int, max: Int) {
        if let raw = retryAfter?.trimmingASCIIWhitespace(),
           !raw.isEmpty,
           raw.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
           let seconds = Int(raw)
        {
            let clamped = min(seconds * 1_000, maxMs)
            return (clamped, clamped)
        }
        let clampedAttempt = min(max(attempt, 0), 16)
        let expDelay = baseMs * (1 << clampedAttempt)
        let capped = min(expDelay, maxMs)
        return (capped / 2, capped)
    }

    public static func cloudflareReason(for status: Int) -> String? {
        cloudflareReasons[status]
    }

    public static func statusMessage(status: Int, body: String) -> String {
        if let reason = cloudflareReasons[status] {
            return "Cloudflare \(status): \(reason) (HTTP \(status))"
        }
        let trimmed = body.trimmingASCIIWhitespace()
        if !trimmed.isEmpty {
            return String(trimmed.prefix(200))
        }
        return "HTTP \(status)"
    }
}

// MARK: - Bridge Wire Protocol (`@opentunnel/protocol/bridge-protocol.ts`)

public struct OpenTunnelBridgeClientInfo: Equatable, Hashable, Sendable, Codable {
    public let version: String
    public let maxConns: Int

    private enum CodingKeys: String, CodingKey {
        case version
        case maxConns = "max_conns"
    }

    public init(version: String, maxConns: Int) {
        self.version = version
        self.maxConns = maxConns
    }
}

/// Control messages sent from client to OpenTunnel relay over WebSocket text frames.
public enum OpenTunnelClientControlMessage: Equatable, Hashable, Sendable {
    case attach(token: String, transport: String, routes: [String], client: OpenTunnelBridgeClientInfo)
    case ping(timeSent: Int64)
    case pong(timeSent: Int64)
    case drain(reason: String)
    case end(conn: UInt32)
    case reset(conn: UInt32, code: String)
}

/// Control messages sent from OpenTunnel relay to client over WebSocket text frames.
public enum OpenTunnelServerControlMessage: Equatable, Hashable, Sendable {
    case attached(session: String, routes: [String], heartbeatMs: Int, idleTimeoutMs: Int)
    case attachError(code: String)
    case open(conn: UInt32, peer: String, sni: String, alpn: String)
    case ping(timeSent: Int64)
    case pong(timeSent: Int64)
    case drain(reason: String)
    case end(conn: UInt32)
    case reset(conn: UInt32, code: String)
    /// Forward-compatibility placeholder: unknown message types must be ignored per spec.
    case unknown(type: String)
}

/// Wire encoding & decoding for the OpenTunnel WebSocket bridge protocol.
public enum OpenTunnelBridgeProtocol {
    public static let webSocketSubprotocol = "opentunnel"
    public static let connIDSize = 4
    public static let maxDataPayloadSize = 32_768
    public static let defaultHeartbeatMs = 15_000
    public static let defaultIdleTimeoutMs = 45_000
    public static let connectTimeoutMs = 10_000

    /// Encodes a binary data frame: big-endian `u32` connection ID followed by payload bytes.
    public static func buildDataFrame(conn: UInt32, payload: [UInt8]) -> [UInt8] {
        var frame: [UInt8] = []
        frame.reserveCapacity(connIDSize + payload.count)
        frame.append(UInt8((conn >> 24) & 0xFF))
        frame.append(UInt8((conn >> 16) & 0xFF))
        frame.append(UInt8((conn >> 8) & 0xFF))
        frame.append(UInt8(conn & 0xFF))
        frame.append(contentsOf: payload)
        return frame
    }

    /// Parses a binary data frame into `(conn, payload)`. Returns `nil` if fewer than 4 bytes.
    public static func parseDataFrame(_ data: [UInt8]) -> (conn: UInt32, payload: [UInt8])? {
        guard data.count >= connIDSize else { return nil }
        let conn = (UInt32(data[0]) << 24)
            | (UInt32(data[1]) << 16)
            | (UInt32(data[2]) << 8)
            | UInt32(data[3])
        return (conn: conn, payload: Array(data[connIDSize...]))
    }

    /// Encodes a client control message as a JSON text frame.
    public static func encodeClientMessage(_ message: OpenTunnelClientControlMessage) throws -> String {
        let data: Data
        switch message {
        case let .attach(token, transport, routes, client):
            struct AttachPayload: Encodable {
                let type = "attach"
                let token: String
                let transport: String
                let routes: [String]
                let client: OpenTunnelBridgeClientInfo
            }
            data = try JSONEncoder().encode(AttachPayload(token: token, transport: transport, routes: routes, client: client))
        case let .ping(timeSent):
            struct PingPayload: Encodable {
                let type = "ping"
                let time_sent: Int64
            }
            data = try JSONEncoder().encode(PingPayload(time_sent: timeSent))
        case let .pong(timeSent):
            struct PongPayload: Encodable {
                let type = "pong"
                let time_sent: Int64
            }
            data = try JSONEncoder().encode(PongPayload(time_sent: timeSent))
        case let .drain(reason):
            struct DrainPayload: Encodable {
                let type = "drain"
                let reason: String
            }
            data = try JSONEncoder().encode(DrainPayload(reason: reason))
        case let .end(conn):
            struct EndPayload: Encodable {
                let type = "end"
                let conn: UInt32
            }
            data = try JSONEncoder().encode(EndPayload(conn: conn))
        case let .reset(conn, code):
            struct ResetPayload: Encodable {
                let type = "reset"
                let conn: UInt32
                let code: String
            }
            data = try JSONEncoder().encode(ResetPayload(conn: conn, code: code))
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Decodes a server control message from a JSON text frame.
    /// Returns `nil` for malformed frames; returns `.unknown(type:)` for unrecognized control types.
    public static func decodeServerMessage(_ text: String) -> OpenTunnelServerControlMessage? {
        guard let data = text.data(using: .utf8) else { return nil }
        struct TypeProbe: Decodable {
            let type: String
        }
        guard let probe = try? JSONDecoder().decode(TypeProbe.self, from: data) else {
            return nil
        }
        let decoder = JSONDecoder()
        switch probe.type {
        case "attached":
            struct Wire: Decodable {
                let session: String
                let routes: [String]
                let heartbeat_ms: Int
                let idle_timeout_ms: Int
            }
            guard let w = try? decoder.decode(Wire.self, from: data) else { return nil }
            return .attached(session: w.session, routes: w.routes, heartbeatMs: w.heartbeat_ms, idleTimeoutMs: w.idle_timeout_ms)
        case "attach_error":
            struct Wire: Decodable {
                let code: String
            }
            guard let w = try? decoder.decode(Wire.self, from: data) else { return nil }
            return .attachError(code: w.code)
        case "open":
            struct Wire: Decodable {
                let conn: UInt32
                let peer: String
                let sni: String
                let alpn: String?
            }
            guard let w = try? decoder.decode(Wire.self, from: data) else { return nil }
            return .open(conn: w.conn, peer: w.peer, sni: w.sni, alpn: w.alpn ?? "")
        case "ping":
            struct Wire: Decodable {
                let time_sent: Int64
            }
            guard let w = try? decoder.decode(Wire.self, from: data) else { return nil }
            return .ping(timeSent: w.time_sent)
        case "pong":
            struct Wire: Decodable {
                let time_sent: Int64
            }
            guard let w = try? decoder.decode(Wire.self, from: data) else { return nil }
            return .pong(timeSent: w.time_sent)
        case "drain":
            struct Wire: Decodable {
                let reason: String
            }
            guard let w = try? decoder.decode(Wire.self, from: data) else { return nil }
            return .drain(reason: w.reason)
        case "end":
            struct Wire: Decodable {
                let conn: UInt32
            }
            guard let w = try? decoder.decode(Wire.self, from: data) else { return nil }
            return .end(conn: w.conn)
        case "reset":
            struct Wire: Decodable {
                let conn: UInt32
                let code: String
            }
            guard let w = try? decoder.decode(Wire.self, from: data) else { return nil }
            return .reset(conn: w.conn, code: w.code)
        default:
            return .unknown(type: probe.type)
        }
    }
}
