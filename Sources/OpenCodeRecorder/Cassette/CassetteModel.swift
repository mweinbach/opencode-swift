import OpenCodeUtil

/// Runtime schema for `CassetteMetadata`.
// parity: http-recorder/src/cassette/model.ts#CassetteMetadataSchema [status=implemented hash=57b14dd18ea8]
public let CassetteMetadataSchema = RecorderSchema<CassetteMetadata>(
    name: "CassetteMetadata",
    decode: { value in
        guard case .object(let entries) = value else {
            throw RecorderSchemaError(schema: "CassetteMetadata", message: "Expected JSON object")
        }
        var out: CassetteMetadata = [:]
        out.reserveCapacity(entries.count)
        for (key, child) in entries {
            out[key] = JsonValue.fromPureJSON(child)
        }
        return out
    },
    encode: { metadata in
        let entries = metadata.keys.sorted(by: jsStringLessThan).map { key in
            (key, metadata[key]!.toPureJSON())
        }
        return .object(entries)
    }
)

/// Tagged union of recorded HTTP and WebSocket interactions matching `packages/http-recorder/src/cassette/model.ts#Interaction`.
// parity: http-recorder/src/cassette/model.ts#Interaction [status=implemented hash=a54409820407]
public enum Interaction: Equatable, Hashable, Sendable, Codable {
    case http(HttpInteraction)
    case websocket(WebSocketInteraction)

    public var transport: String {
        switch self {
        case .http: return "http"
        case .websocket: return "websocket"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case transport
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let transport = try container.decode(String.self, forKey: .transport)
        switch transport {
        case "http":
            self = .http(try HttpInteraction(from: decoder))
        case "websocket":
            self = .websocket(try WebSocketInteraction(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .transport,
                in: container,
                debugDescription: "Unknown interaction transport '\(transport)'"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .http(let interaction):
            try interaction.encode(to: encoder)
        case .websocket(let interaction):
            try interaction.encode(to: encoder)
        }
    }
}

/// Runtime schema for `Interaction` tagged union (`transport: "http" | "websocket"`).
// parity: http-recorder/src/cassette/model.ts#InteractionSchema [status=implemented hash=87962b0ac3b6]
public let InteractionSchema = RecorderSchema<Interaction>(
    name: "Interaction",
    decode: { value in
        let obj = try SchemaJSONHelper.objectMap(value, schema: "Interaction")
        let transport = try SchemaJSONHelper.requiredString(obj, key: "transport", schema: "Interaction")
        switch transport {
        case "http":
            return .http(try HttpInteractionSchema.decode(value))
        case "websocket":
            return .websocket(try WebSocketInteractionSchema.decode(value))
        default:
            throw RecorderSchemaError(
                schema: "Interaction",
                message: "Unknown interaction transport '\(transport)'"
            )
        }
    },
    encode: { interaction in
        switch interaction {
        case .http(let http):
            return HttpInteractionSchema.encode(http)
        case .websocket(let ws):
            return WebSocketInteractionSchema.encode(ws)
        }
    }
)

/// Guard checking whether an `Interaction` is an HTTP interaction.
// parity: http-recorder/src/cassette/model.ts#isHttpInteraction [status=implemented hash=1a5f2f1a1a3c]
public func isHttpInteraction(_ interaction: Interaction) -> Bool {
    if case .http = interaction { return true }
    return false
}

/// Guard checking whether an `Interaction` is a WebSocket interaction.
// parity: http-recorder/src/cassette/model.ts#isWebSocketInteraction [status=implemented hash=aae0f326bd07]
public func isWebSocketInteraction(_ interaction: Interaction) -> Bool {
    if case .websocket = interaction { return true }
    return false
}

/// Filters an interaction list down to only `HttpInteraction` values.
// parity: http-recorder/src/cassette/model.ts#httpInteractions [status=implemented hash=dec705d687a8]
public func httpInteractions(_ interactions: [Interaction]) -> [HttpInteraction] {
    interactions.compactMap { interaction in
        if case .http(let http) = interaction { return http }
        return nil
    }
}

/// Filters an interaction list down to only `WebSocketInteraction` values.
// parity: http-recorder/src/cassette/model.ts#webSocketInteractions [status=implemented hash=379f1c1de42e]
public func webSocketInteractions(_ interactions: [Interaction]) -> [WebSocketInteraction] {
    interactions.compactMap { interaction in
        if case .websocket(let ws) = interaction { return ws }
        return nil
    }
}

/// Version 1 cassette envelope matching `packages/http-recorder/src/cassette/model.ts#Cassette`.
// parity: http-recorder/src/cassette/model.ts#Cassette [status=implemented hash=a28548d487a0]
public struct Cassette: Equatable, Sendable, Codable {
    public let version: Int
    public let metadata: CassetteMetadata?
    public let interactions: [Interaction]

    public init(
        version: Int = 1,
        metadata: CassetteMetadata? = nil,
        interactions: [Interaction]
    ) {
        self.version = version
        self.metadata = metadata
        self.interactions = interactions
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case metadata
        case interactions
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == 1 else {
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: container,
                debugDescription: "Expected cassette version 1, got \(version)"
            )
        }
        self.version = version
        self.metadata = try container.decodeIfPresent(CassetteMetadata.self, forKey: .metadata)
        self.interactions = try container.decode([Interaction].self, forKey: .interactions)
    }
}

/// Runtime schema for `Cassette`.
// parity: http-recorder/src/cassette/model.ts#CassetteSchema [status=implemented hash=f4b7a8bf150e]
public let CassetteSchema = RecorderSchema<Cassette>(
    name: "Cassette",
    decode: { value in
        let obj = try SchemaJSONHelper.objectMap(value, schema: "Cassette")
        let version = try SchemaJSONHelper.requiredInt(obj, key: "version", schema: "Cassette")
        guard version == 1 else {
            throw RecorderSchemaError(schema: "Cassette", message: "Expected cassette version 1, got \(version)")
        }
        let metadata: CassetteMetadata?
        if let metaVal = obj["metadata"] {
            metadata = try CassetteMetadataSchema.decode(metaVal)
        } else {
            metadata = nil
        }
        guard let interactionsVal = obj["interactions"], case .array(let rawInteractions) = interactionsVal else {
            throw RecorderSchemaError(schema: "Cassette", message: "Expected array at 'interactions'")
        }
        let interactions = try rawInteractions.map { try InteractionSchema.decode($0) }
        return Cassette(version: version, metadata: metadata, interactions: interactions)
    },
    encode: { cassette in
        var entries: [(String, PureJSONValue)] = [
            ("version", .number(Double(cassette.version))),
        ]
        if let metadata = cassette.metadata {
            entries.append(("metadata", CassetteMetadataSchema.encode(metadata)))
        }
        entries.append(("interactions", .array(cassette.interactions.map(InteractionSchema.encode))))
        return .object(entries)
    }
)

/// Decodes a `PureJSONValue` into a validated `Cassette`.
// parity: http-recorder/src/cassette/model.ts#decodeCassette [status=implemented hash=a9b028acbff7]
public func decodeCassette(_ value: PureJSONValue) throws -> Cassette {
    try CassetteSchema.decode(value)
}

/// Decodes a UTF-8 JSON string into a validated `Cassette`.
public func decodeCassette(fromJSON text: String) throws -> Cassette {
    try CassetteSchema.decode(fromJSON: text)
}

/// Decodes raw UTF-8 JSON bytes into a validated `Cassette`.
public func decodeCassette(fromBytes bytes: [UInt8]) throws -> Cassette {
    try decodeCassette(fromJSON: String(decoding: bytes, as: UTF8.self))
}

/// Encodes a `Cassette` into a deterministic `PureJSONValue`.
// parity: http-recorder/src/cassette/model.ts#encodeCassette [status=implemented hash=b4e7396ac645]
public func encodeCassette(_ cassette: Cassette) -> PureJSONValue {
    CassetteSchema.encode(cassette)
}

/// Formats a `Cassette` as pretty-printed 2-space JSON with a trailing newline matching upstream.
public func formatCassetteJSON(_ cassette: Cassette) -> String {
    PureJSON.stringifyPretty(encodeCassette(cassette), indent: 2) + "\n"
}
