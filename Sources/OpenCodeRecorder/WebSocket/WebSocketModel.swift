import OpenCodeUtil

/// Direction of a recorded WebSocket frame.
public enum WebSocketDirection: String, Equatable, Hashable, Sendable, Codable {
    case client
    case server
}

/// Kind of a recorded WebSocket frame.
public enum WebSocketEventKind: String, Equatable, Hashable, Sendable, Codable {
    case text
    case binary
}

/// A single recorded WebSocket frame event matching `packages/http-recorder/src/websocket/model.ts#WebSocketEvent`.
// parity: http-recorder/src/websocket/model.ts#WebSocketEvent [status=implemented hash=944de635b321]
public enum WebSocketEvent: Equatable, Hashable, Sendable, Codable {
    case text(direction: WebSocketDirection, body: String)
    case binary(direction: WebSocketDirection, body: String)

    public var direction: WebSocketDirection {
        switch self {
        case .text(let direction, _), .binary(let direction, _):
            return direction
        }
    }

    public var kind: WebSocketEventKind {
        switch self {
        case .text: return .text
        case .binary: return .binary
        }
    }

    public var body: String {
        switch self {
        case .text(_, let body), .binary(_, let body):
            return body
        }
    }

    public var bodyEncoding: String? {
        switch self {
        case .text: return nil
        case .binary: return "base64"
        }
    }

    /// Creates a binary WebSocket event by base64-encoding raw bytes.
    public static func binary(direction: WebSocketDirection, bytes: [UInt8]) -> WebSocketEvent {
        .binary(direction: direction, body: bytesToBase64(bytes))
    }

    private enum CodingKeys: String, CodingKey {
        case direction
        case kind
        case body
        case bodyEncoding
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let direction = try container.decode(WebSocketDirection.self, forKey: .direction)
        let kind = try container.decode(WebSocketEventKind.self, forKey: .kind)
        let body = try container.decode(String.self, forKey: .body)
        switch kind {
        case .text:
            self = .text(direction: direction, body: body)
        case .binary:
            let encoding = try container.decode(String.self, forKey: .bodyEncoding)
            guard encoding == "base64" else {
                throw DecodingError.dataCorruptedError(
                    forKey: .bodyEncoding,
                    in: container,
                    debugDescription: "Expected bodyEncoding 'base64', got '\(encoding)'"
                )
            }
            self = .binary(direction: direction, body: body)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(direction, forKey: .direction)
        try container.encode(kind, forKey: .kind)
        try container.encode(body, forKey: .body)
        if let bodyEncoding {
            try container.encode(bodyEncoding, forKey: .bodyEncoding)
        }
    }
}

/// Runtime schema for `WebSocketEvent`.
// parity: http-recorder/src/websocket/model.ts#WebSocketEventSchema [status=implemented hash=642d2ce048de]
public let WebSocketEventSchema = RecorderSchema<WebSocketEvent>(
    name: "WebSocketEvent",
    decode: { value in
        let obj = try SchemaJSONHelper.objectMap(value, schema: "WebSocketEvent")
        let dirRaw = try SchemaJSONHelper.requiredString(obj, key: "direction", schema: "WebSocketEvent")
        guard let direction = WebSocketDirection(rawValue: dirRaw) else {
            throw RecorderSchemaError(
                schema: "WebSocketEvent",
                message: "Expected 'client' or 'server' at 'direction'"
            )
        }
        let kindRaw = try SchemaJSONHelper.requiredString(obj, key: "kind", schema: "WebSocketEvent")
        guard let kind = WebSocketEventKind(rawValue: kindRaw) else {
            throw RecorderSchemaError(
                schema: "WebSocketEvent",
                message: "Expected 'text' or 'binary' at 'kind'"
            )
        }
        let body = try SchemaJSONHelper.requiredString(obj, key: "body", schema: "WebSocketEvent")
        switch kind {
        case .text:
            return .text(direction: direction, body: body)
        case .binary:
            let encoding = try SchemaJSONHelper.requiredString(obj, key: "bodyEncoding", schema: "WebSocketEvent")
            guard encoding == "base64" else {
                throw RecorderSchemaError(
                    schema: "WebSocketEvent",
                    message: "Expected 'base64' at 'bodyEncoding'"
                )
            }
            return .binary(direction: direction, body: body)
        }
    },
    encode: { event in
        switch event {
        case let .text(direction, body):
            return .object([
                ("direction", .string(direction.rawValue)),
                ("kind", .string("text")),
                ("body", .string(body)),
            ])
        case let .binary(direction, body):
            return .object([
                ("direction", .string(direction.rawValue)),
                ("kind", .string("binary")),
                ("body", .string(body)),
                ("bodyEncoding", .string("base64")),
            ])
        }
    }
)

/// Recorded terminal WebSocket close metadata.
public struct WebSocketClose: Equatable, Hashable, Sendable, Codable {
    public let code: Int
    public let reason: String

    public init(code: Int = 1000, reason: String = "") {
        self.code = code
        self.reason = reason
    }
}

/// Recorded WebSocket constructor connection metadata.
public struct WebSocketConnection: Equatable, Hashable, Sendable, Codable {
    public let sequence: Int
    public let url: String
    public let protocols: [String]
    public let close: WebSocketClose

    public init(
        sequence: Int,
        url: String,
        protocols: [String] = [],
        close: WebSocketClose = WebSocketClose()
    ) {
        self.sequence = sequence
        self.url = url
        self.protocols = protocols
        self.close = close
    }
}

/// Recorded WebSocket session interaction matching `packages/http-recorder/src/websocket/model.ts#WebSocketInteraction`.
// parity: http-recorder/src/websocket/model.ts#WebSocketInteraction [status=implemented hash=eb63fa6d830f]
public struct WebSocketInteraction: Equatable, Hashable, Sendable, Codable {
    public let transport: String
    public let connection: WebSocketConnection?
    public let events: [WebSocketEvent]

    public init(connection: WebSocketConnection? = nil, events: [WebSocketEvent]) {
        self.transport = "websocket"
        self.connection = connection
        self.events = events
    }

    private enum CodingKeys: String, CodingKey {
        case transport
        case connection
        case events
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let transport = try container.decode(String.self, forKey: .transport)
        guard transport == "websocket" else {
            throw DecodingError.dataCorruptedError(
                forKey: .transport,
                in: container,
                debugDescription: "Expected transport 'websocket', got '\(transport)'"
            )
        }
        self.transport = transport
        self.connection = try container.decodeIfPresent(WebSocketConnection.self, forKey: .connection)
        self.events = try container.decode([WebSocketEvent].self, forKey: .events)
    }
}

/// Runtime schema for `WebSocketInteraction`.
// parity: http-recorder/src/websocket/model.ts#WebSocketInteractionSchema [status=implemented hash=389d9b94613f]
public let WebSocketInteractionSchema = RecorderSchema<WebSocketInteraction>(
    name: "WebSocketInteraction",
    decode: { value in
        let obj = try SchemaJSONHelper.objectMap(value, schema: "WebSocketInteraction")
        let transport = try SchemaJSONHelper.requiredString(obj, key: "transport", schema: "WebSocketInteraction")
        guard transport == "websocket" else {
            throw RecorderSchemaError(
                schema: "WebSocketInteraction",
                message: "Expected transport 'websocket', got '\(transport)'"
            )
        }
        let connection: WebSocketConnection?
        if let connVal = obj["connection"] {
            let connObj = try SchemaJSONHelper.objectMap(connVal, schema: "WebSocketConnection")
            let sequence = try SchemaJSONHelper.requiredInt(connObj, key: "sequence", schema: "WebSocketConnection")
            let url = try SchemaJSONHelper.requiredString(connObj, key: "url", schema: "WebSocketConnection")
            let protocols = try SchemaJSONHelper.requiredStringArray(connObj, key: "protocols", schema: "WebSocketConnection")
            guard let closeVal = connObj["close"] else {
                throw RecorderSchemaError(schema: "WebSocketConnection", message: "Missing 'close'")
            }
            let closeObj = try SchemaJSONHelper.objectMap(closeVal, schema: "WebSocketClose")
            let code = try SchemaJSONHelper.requiredInt(closeObj, key: "code", schema: "WebSocketClose")
            let reason = try SchemaJSONHelper.requiredString(closeObj, key: "reason", schema: "WebSocketClose")
            connection = WebSocketConnection(
                sequence: sequence,
                url: url,
                protocols: protocols,
                close: WebSocketClose(code: code, reason: reason)
            )
        } else {
            connection = nil
        }

        guard let eventsVal = obj["events"], case .array(let rawEvents) = eventsVal else {
            throw RecorderSchemaError(schema: "WebSocketInteraction", message: "Expected array at 'events'")
        }
        let events = try rawEvents.map { try WebSocketEventSchema.decode($0) }
        return WebSocketInteraction(connection: connection, events: events)
    },
    encode: { interaction in
        var entries: [(String, PureJSONValue)] = [
            ("transport", .string("websocket")),
        ]
        if let conn = interaction.connection {
            entries.append((
                "connection",
                .object([
                    ("sequence", .number(Double(conn.sequence))),
                    ("url", .string(conn.url)),
                    ("protocols", .array(conn.protocols.map(PureJSONValue.string))),
                    ("close", .object([
                        ("code", .number(Double(conn.close.code))),
                        ("reason", .string(conn.close.reason)),
                    ])),
                ])
            ))
        }
        entries.append(("events", .array(interaction.events.map(WebSocketEventSchema.encode))))
        return .object(entries)
    }
)
