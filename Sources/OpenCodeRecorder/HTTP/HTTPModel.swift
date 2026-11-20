import OpenCodeUtil

/// Response body encoding stored in a cassette snapshot.
public enum ResponseBodyEncoding: String, Equatable, Hashable, Sendable, Codable {
    case text
    case base64
}

/// Runtime schema for `RequestSnapshot`.
// parity: http-recorder/src/http/model.ts#RequestSnapshotSchema [status=implemented hash=953f74d4fd34]
public let RequestSnapshotSchema = RecorderSchema<RequestSnapshot>(
    name: "RequestSnapshot",
    decode: { value in
        let obj = try SchemaJSONHelper.objectMap(value, schema: "RequestSnapshot")
        return RequestSnapshot(
            method: try SchemaJSONHelper.requiredString(obj, key: "method", schema: "RequestSnapshot"),
            url: try SchemaJSONHelper.requiredString(obj, key: "url", schema: "RequestSnapshot"),
            headers: try SchemaJSONHelper.requiredStringMap(obj, key: "headers", schema: "RequestSnapshot"),
            body: try SchemaJSONHelper.requiredString(obj, key: "body", schema: "RequestSnapshot")
        )
    },
    encode: { snapshot in
        .object([
            ("method", .string(snapshot.method)),
            ("url", .string(snapshot.url)),
            ("headers", SchemaJSONHelper.encodeStringMap(snapshot.headers)),
            ("body", .string(snapshot.body)),
        ])
    }
)

/// Recorded HTTP response snapshot matching `packages/http-recorder/src/http/model.ts#ResponseSnapshot`.
// parity: http-recorder/src/http/model.ts#ResponseSnapshot [status=implemented hash=5fffb3c0069e]
public struct ResponseSnapshot: Equatable, Hashable, Sendable, Codable {
    public let status: Int
    public let headers: [String: String]
    public let body: String
    public let bodyEncoding: ResponseBodyEncoding?

    public init(
        status: Int,
        headers: [String: String] = [:],
        body: String = "",
        bodyEncoding: ResponseBodyEncoding? = nil
    ) {
        self.status = status
        self.headers = headers
        self.body = body
        self.bodyEncoding = bodyEncoding
    }
}

/// Runtime schema for `ResponseSnapshot`.
// parity: http-recorder/src/http/model.ts#ResponseSnapshotSchema [status=implemented hash=e3d096dfe11d]
public let ResponseSnapshotSchema = RecorderSchema<ResponseSnapshot>(
    name: "ResponseSnapshot",
    decode: { value in
        let obj = try SchemaJSONHelper.objectMap(value, schema: "ResponseSnapshot")
        let status = try SchemaJSONHelper.requiredInt(obj, key: "status", schema: "ResponseSnapshot")
        let headers = try SchemaJSONHelper.requiredStringMap(obj, key: "headers", schema: "ResponseSnapshot")
        let body = try SchemaJSONHelper.requiredString(obj, key: "body", schema: "ResponseSnapshot")
        let bodyEncoding: ResponseBodyEncoding?
        if let rawEnc = obj["bodyEncoding"] {
            guard case .string(let encStr) = rawEnc,
                  let parsed = ResponseBodyEncoding(rawValue: encStr) else {
                throw RecorderSchemaError(
                    schema: "ResponseSnapshot",
                    message: "Expected 'text' or 'base64' at 'bodyEncoding'"
                )
            }
            bodyEncoding = parsed
        } else {
            bodyEncoding = nil
        }
        return ResponseSnapshot(status: status, headers: headers, body: body, bodyEncoding: bodyEncoding)
    },
    encode: { snapshot in
        var entries: [(String, PureJSONValue)] = [
            ("status", .number(Double(snapshot.status))),
            ("headers", SchemaJSONHelper.encodeStringMap(snapshot.headers)),
            ("body", .string(snapshot.body)),
        ]
        if let bodyEncoding = snapshot.bodyEncoding {
            entries.append(("bodyEncoding", .string(bodyEncoding.rawValue)))
        }
        return .object(entries)
    }
)

/// Recorded HTTP request/response pair matching `packages/http-recorder/src/http/model.ts#HttpInteraction`.
// parity: http-recorder/src/http/model.ts#HttpInteraction [status=implemented hash=0ad3b0f65a1b]
public struct HttpInteraction: Equatable, Hashable, Sendable, Codable {
    public let transport: String
    public let request: RequestSnapshot
    public let response: ResponseSnapshot

    public init(request: RequestSnapshot, response: ResponseSnapshot) {
        self.transport = "http"
        self.request = request
        self.response = response
    }

    private enum CodingKeys: String, CodingKey {
        case transport
        case request
        case response
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let transport = try container.decode(String.self, forKey: .transport)
        guard transport == "http" else {
            throw DecodingError.dataCorruptedError(
                forKey: .transport,
                in: container,
                debugDescription: "Expected transport 'http', got '\(transport)'"
            )
        }
        self.transport = transport
        self.request = try container.decode(RequestSnapshot.self, forKey: .request)
        self.response = try container.decode(ResponseSnapshot.self, forKey: .response)
    }
}

/// Runtime schema for `HttpInteraction`.
// parity: http-recorder/src/http/model.ts#HttpInteractionSchema [status=implemented hash=84c736c65708]
public let HttpInteractionSchema = RecorderSchema<HttpInteraction>(
    name: "HttpInteraction",
    decode: { value in
        let obj = try SchemaJSONHelper.objectMap(value, schema: "HttpInteraction")
        let transport = try SchemaJSONHelper.requiredString(obj, key: "transport", schema: "HttpInteraction")
        guard transport == "http" else {
            throw RecorderSchemaError(
                schema: "HttpInteraction",
                message: "Expected transport 'http', got '\(transport)'"
            )
        }
        guard let reqVal = obj["request"] else {
            throw RecorderSchemaError(schema: "HttpInteraction", message: "Missing 'request'")
        }
        guard let resVal = obj["response"] else {
            throw RecorderSchemaError(schema: "HttpInteraction", message: "Missing 'response'")
        }
        return HttpInteraction(
            request: try RequestSnapshotSchema.decode(reqVal),
            response: try ResponseSnapshotSchema.decode(resVal)
        )
    },
    encode: { interaction in
        .object([
            ("transport", .string("http")),
            ("request", RequestSnapshotSchema.encode(interaction.request)),
            ("response", ResponseSnapshotSchema.encode(interaction.response)),
        ])
    }
)
