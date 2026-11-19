import OpenCodeSchema

// MARK: - Decoding Errors & Pure-Swift JSON Parser

/// Error thrown when decoding or validating a simulation JSON-RPC message.
public struct SimulationDecodeError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}

/// Pure-Swift RFC 8259 JSON parser into `JSONValue` (zero OS or Foundation imports).
private struct PureJSONParser {
    private let bytes: [UInt8]
    private var index: Int = 0

    init(_ string: String) {
        self.bytes = Array(string.utf8)
    }

    mutating func parseDocument() throws(SimulationDecodeError) -> JSONValue {
        skipWhitespace()
        let value = try parseValue()
        skipWhitespace()
        if index < bytes.count {
            throw SimulationDecodeError("Unexpected trailing content in JSON at offset \(index)")
        }
        return value
    }

    private mutating func skipWhitespace() {
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x09, 0x0A, 0x0D:
                index += 1
            default:
                return
            }
        }
    }

    private mutating func parseValue() throws(SimulationDecodeError) -> JSONValue {
        skipWhitespace()
        guard index < bytes.count else {
            throw SimulationDecodeError("Unexpected end of JSON input")
        }
        switch bytes[index] {
        case 0x7B: // '{'
            return try parseObject()
        case 0x5B: // '['
            return try parseArray()
        case 0x22: // '"'
            return .string(try parseString())
        case 0x74: // 't'
            try expectLiteral("true")
            return .bool(true)
        case 0x66: // 'f'
            try expectLiteral("false")
            return .bool(false)
        case 0x6E: // 'n'
            try expectLiteral("null")
            return .null
        case 0x2D, 0x30...0x39:
            return try parseNumber()
        default:
            throw SimulationDecodeError("Unexpected byte \(bytes[index]) at offset \(index)")
        }
    }

    private mutating func expectLiteral(_ literal: StaticString) throws(SimulationDecodeError) {
        let expected = Array(literal.description.utf8)
        guard index + expected.count <= bytes.count else {
            throw SimulationDecodeError("Unexpected end of JSON while expecting '\(literal)'")
        }
        for offset in 0..<expected.count {
            if bytes[index + offset] != expected[offset] {
                throw SimulationDecodeError("Expected '\(literal)' at offset \(index)")
            }
        }
        index += expected.count
    }

    private mutating func parseObject() throws(SimulationDecodeError) -> JSONValue {
        index += 1 // '{'
        skipWhitespace()
        var result: [String: JSONValue] = [:]
        if index < bytes.count && bytes[index] == 0x7D { // '}'
            index += 1
            return .object(result)
        }
        while true {
            skipWhitespace()
            guard index < bytes.count && bytes[index] == 0x22 else {
                throw SimulationDecodeError("Expected string key in JSON object at offset \(index)")
            }
            let key = try parseString()
            skipWhitespace()
            guard index < bytes.count && bytes[index] == 0x3A else { // ':'
                throw SimulationDecodeError("Expected ':' after object key at offset \(index)")
            }
            index += 1
            let value = try parseValue()
            result[key] = value
            skipWhitespace()
            guard index < bytes.count else {
                throw SimulationDecodeError("Unterminated JSON object")
            }
            if bytes[index] == 0x7D { // '}'
                index += 1
                return .object(result)
            }
            if bytes[index] == 0x2C { // ','
                index += 1
                continue
            }
            throw SimulationDecodeError("Expected ',' or '}' in JSON object at offset \(index)")
        }
    }

    private mutating func parseArray() throws(SimulationDecodeError) -> JSONValue {
        index += 1 // '['
        skipWhitespace()
        var items: [JSONValue] = []
        if index < bytes.count && bytes[index] == 0x5D { // ']'
            index += 1
            return .array(items)
        }
        while true {
            items.append(try parseValue())
            skipWhitespace()
            guard index < bytes.count else {
                throw SimulationDecodeError("Unterminated JSON array")
            }
            if bytes[index] == 0x5D { // ']'
                index += 1
                return .array(items)
            }
            if bytes[index] == 0x2C { // ','
                index += 1
                continue
            }
            throw SimulationDecodeError("Expected ',' or ']' in JSON array at offset \(index)")
        }
    }

    private mutating func parseString() throws(SimulationDecodeError) -> String {
        index += 1 // '"'
        var out: [UInt8] = []
        while index < bytes.count {
            let b = bytes[index]
            if b == 0x22 { // '"'
                index += 1
                return String(decoding: out, as: UTF8.self)
            }
            if b == 0x5C { // '\\'
                index += 1
                guard index < bytes.count else {
                    throw SimulationDecodeError("Unterminated escape sequence in JSON string")
                }
                let esc = bytes[index]
                index += 1
                switch esc {
                case 0x22: out.append(0x22)
                case 0x5C: out.append(0x5C)
                case 0x2F: out.append(0x2F)
                case 0x62: out.append(0x08)
                case 0x66: out.append(0x0C)
                case 0x6E: out.append(0x0A)
                case 0x72: out.append(0x0D)
                case 0x74: out.append(0x09)
                case 0x75:
                    let codeUnit = try parseHex4()
                    if codeUnit >= 0xD800 && codeUnit <= 0xDBFF {
                        guard index + 1 < bytes.count, bytes[index] == 0x5C, bytes[index + 1] == 0x75 else {
                            throw SimulationDecodeError("Unpaired high surrogate in JSON string")
                        }
                        index += 2
                        let low = try parseHex4()
                        guard low >= 0xDC00 && low <= 0xDFFF else {
                            throw SimulationDecodeError("Invalid low surrogate in JSON string")
                        }
                        let scalarValue = 0x10000 + ((UInt32(codeUnit - 0xD800) << 10) | UInt32(low - 0xDC00))
                        guard let scalar = UnicodeScalar(scalarValue) else {
                            throw SimulationDecodeError("Invalid Unicode scalar")
                        }
                        out.append(contentsOf: String(scalar).utf8)
                    } else if let scalar = UnicodeScalar(codeUnit) {
                        out.append(contentsOf: String(scalar).utf8)
                    } else {
                        throw SimulationDecodeError("Invalid Unicode escape in JSON string")
                    }
                default:
                    throw SimulationDecodeError("Invalid escape character in JSON string")
                }
            } else if b < 0x20 {
                throw SimulationDecodeError("Unescaped control character in JSON string")
            } else {
                out.append(b)
                index += 1
            }
        }
        throw SimulationDecodeError("Unterminated JSON string")
    }

    private mutating func parseHex4() throws(SimulationDecodeError) -> UInt16 {
        guard index + 4 <= bytes.count else {
            throw SimulationDecodeError("Truncated \\u escape in JSON string")
        }
        var value: UInt16 = 0
        for _ in 0..<4 {
            let b = bytes[index]
            index += 1
            let nibble: UInt16
            switch b {
            case 48...57: nibble = UInt16(b - 48)
            case 65...70: nibble = UInt16(b - 55)
            case 97...102: nibble = UInt16(b - 87)
            default: throw SimulationDecodeError("Invalid hex digit in \\u escape")
            }
            value = (value << 4) | nibble
        }
        return value
    }

    private mutating func parseNumber() throws(SimulationDecodeError) -> JSONValue {
        let start = index
        if bytes[index] == 0x2D { index += 1 }
        guard index < bytes.count else { throw SimulationDecodeError("Invalid JSON number") }
        if bytes[index] == 0x30 {
            index += 1
        } else if bytes[index] >= 0x31 && bytes[index] <= 0x39 {
            while index < bytes.count && bytes[index] >= 0x30 && bytes[index] <= 0x39 { index += 1 }
        } else {
            throw SimulationDecodeError("Invalid JSON number at offset \(start)")
        }
        var isFloat = false
        if index < bytes.count && bytes[index] == 0x2E { // '.'
            isFloat = true
            index += 1
            guard index < bytes.count && bytes[index] >= 0x30 && bytes[index] <= 0x39 else {
                throw SimulationDecodeError("Invalid fractional JSON number")
            }
            while index < bytes.count && bytes[index] >= 0x30 && bytes[index] <= 0x39 { index += 1 }
        }
        if index < bytes.count && (bytes[index] == 0x65 || bytes[index] == 0x45) { // 'e'/'E'
            isFloat = true
            index += 1
            if index < bytes.count && (bytes[index] == 0x2B || bytes[index] == 0x2D) { index += 1 }
            guard index < bytes.count && bytes[index] >= 0x30 && bytes[index] <= 0x39 else {
                throw SimulationDecodeError("Invalid exponent in JSON number")
            }
            while index < bytes.count && bytes[index] >= 0x30 && bytes[index] <= 0x39 { index += 1 }
        }
        let token = String(decoding: bytes[start..<index], as: UTF8.self)
        if !isFloat, let i = Int64(token) {
            return .int(i)
        }
        guard let d = Double(token), d.isFinite else {
            throw SimulationDecodeError("Out-of-range JSON number '\(token)'")
        }
        return .double(d)
    }
}

private func parseJSONString(_ input: String) throws(SimulationDecodeError) -> JSONValue {
    var parser = PureJSONParser(input)
    return try parser.parseDocument()
}

// MARK: - Validation Helpers

private func isProviderSafeName(_ name: String) -> Bool {
    let utf8 = name.utf8
    guard utf8.count >= 1 && utf8.count <= 64 else { return false }
    guard let first = utf8.first else { return false }
    let firstAlpha = (first >= 65 && first <= 90) || (first >= 97 && first <= 122)
    guard firstAlpha else { return false }
    for b in utf8.dropFirst() {
        let ok =
            (b >= 65 && b <= 90) ||
            (b >= 97 && b <= 122) ||
            (b >= 48 && b <= 57) ||
            b == 95 || // '_'
            b == 45    // '-'
        if !ok { return false }
    }
    return true
}

private func isValidToolNamespace(_ namespace: String) -> Bool {
    guard !namespace.isEmpty else { return false }
    let segments = namespace.split(separator: ".", omittingEmptySubsequences: false)
    return segments.allSatisfy { isProviderSafeName(String($0)) }
}

private func isValidBase64(_ input: String) -> Bool {
    let utf8 = Array(input.utf8)
    guard utf8.count % 4 == 0 else { return false }
    if utf8.isEmpty { return true }
    func isB64Char(_ b: UInt8) -> Bool {
        (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || (b >= 48 && b <= 57) || b == 43 || b == 47
    }
    let bodyCount = utf8.count - 4
    for i in 0..<bodyCount {
        if !isB64Char(utf8[i]) { return false }
    }
    let a = utf8[bodyCount]
    let b = utf8[bodyCount + 1]
    let c = utf8[bodyCount + 2]
    let d = utf8[bodyCount + 3]
    guard isB64Char(a) && isB64Char(b) else { return false }
    if c == 61 && d == 61 { return true } // ==
    if isB64Char(c) && d == 61 { return true } // =
    return isB64Char(c) && isB64Char(d)
}

private func jsonObject(_ value: JSONValue, context: String) throws(SimulationDecodeError) -> [String: JSONValue] {
    guard case .object(let obj) = value else {
        throw SimulationDecodeError("Expected JSON object for \(context)")
    }
    return obj
}

private func jsonString(_ obj: [String: JSONValue], key: String) throws(SimulationDecodeError) -> String {
    guard case .string(let s) = obj[key] else {
        throw SimulationDecodeError("Expected string field '\(key)'")
    }
    return s
}

private func jsonOptionalString(_ obj: [String: JSONValue], key: String) throws(SimulationDecodeError) -> String? {
    guard let raw = obj[key] else { return nil }
    guard case .string(let s) = raw else {
        throw SimulationDecodeError("Expected optional string field '\(key)'")
    }
    return s
}

private func jsonDouble(_ obj: [String: JSONValue], key: String) throws(SimulationDecodeError) -> Double {
    guard let raw = obj[key] else { throw SimulationDecodeError("Missing number field '\(key)'") }
    switch raw {
    case .int(let i): return Double(i)
    case .double(let d): return d
    default: throw SimulationDecodeError("Expected number field '\(key)'")
    }
}

private func jsonInt(_ obj: [String: JSONValue], key: String) throws(SimulationDecodeError) -> Int {
    guard let raw = obj[key] else { throw SimulationDecodeError("Missing integer field '\(key)'") }
    switch raw {
    case .int(let i): return Int(i)
    case .double(let d) where d.isFinite && d.rounded() == d: return Int(d)
    default: throw SimulationDecodeError("Expected integer field '\(key)'")
    }
}

private func jsonOptionalBool(_ obj: [String: JSONValue], key: String) throws(SimulationDecodeError) -> Bool? {
    guard let raw = obj[key] else { return nil }
    guard case .bool(let b) = raw else {
        throw SimulationDecodeError("Expected optional boolean field '\(key)'")
    }
    return b
}

private func jsonArray(_ obj: [String: JSONValue], key: String) throws(SimulationDecodeError) -> [JSONValue] {
    guard case .array(let arr) = obj[key] else {
        throw SimulationDecodeError("Expected array field '\(key)'")
    }
    return arr
}

private func encodeNumber(_ value: Double, into container: inout SingleValueEncodingContainer) throws {
    if value.isFinite, value.rounded() == value, value >= Double(Int64.min), value <= Double(Int64.max) {
        try container.encode(Int64(value))
    } else {
        try container.encode(value)
    }
}

// MARK: - JsonRpc Namespace

// parity: protocol/src/simulation.ts#JsonRpc [status=implemented hash=5ff3e45a16a3]
public enum JsonRpc {
    /// JSON-RPC 2.0 request/response identifier (`string | number | null`).
    public enum ID: Equatable, Hashable, Sendable, Codable {
        case string(String)
        case number(Double)
        case null

        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() {
                self = .null
            } else if let s = try? c.decode(String.self) {
                self = .string(s)
            } else if let i = try? c.decode(Int64.self) {
                self = .number(Double(i))
            } else if let d = try? c.decode(Double.self) {
                self = .number(d)
            } else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid JsonRpc.ID")
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .string(let s): try c.encode(s)
            case .number(let d): try encodeNumber(d, into: &c)
            case .null: try c.encodeNil()
            }
        }

        fileprivate static func decode(from value: JSONValue) throws(SimulationDecodeError) -> ID {
            switch value {
            case .string(let s): return .string(s)
            case .int(let i): return .number(Double(i))
            case .double(let d): return .number(d)
            case .null: return .null
            default: throw SimulationDecodeError("Expected string, number, or null for JsonRpc.ID")
            }
        }
    }

    // parity: protocol/src/simulation.ts#JsonRpc.RequestFields [status=implemented hash=5fb2ed398464]
    public struct RequestFields: Equatable, Hashable, Sendable, Codable {
        public let jsonrpc: String
        public let id: ID?

        public init(id: ID? = nil) {
            self.jsonrpc = "2.0"
            self.id = id
        }

        private enum CodingKeys: String, CodingKey {
            case jsonrpc, id
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let version = try c.decode(String.self, forKey: .jsonrpc)
            guard version == "2.0" else {
                throw DecodingError.dataCorruptedError(
                    forKey: .jsonrpc,
                    in: c,
                    debugDescription: "Expected jsonrpc '2.0', got '\(version)'"
                )
            }
            self.jsonrpc = version
            self.id = c.contains(.id) ? try c.decode(ID.self, forKey: .id) : nil
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("2.0", forKey: .jsonrpc)
            if let id {
                try c.encode(id, forKey: .id)
            }
        }

        fileprivate static func decode(from obj: [String: JSONValue]) throws(SimulationDecodeError) -> RequestFields {
            let version = try jsonString(obj, key: "jsonrpc")
            guard version == "2.0" else {
                throw SimulationDecodeError("Expected jsonrpc '2.0', got '\(version)'")
            }
            let id: ID? = if let rawId = obj["id"] { try ID.decode(from: rawId) } else { nil }
            return RequestFields(id: id)
        }
    }

    // parity: protocol/src/simulation.ts#JsonRpc.Request [status=implemented hash=96360874b62f]
    public struct Request: Equatable, Hashable, Sendable, Codable {
        public let jsonrpc: String
        public let id: ID?
        public let method: String
        public let params: JSONValue?

        public init(id: ID? = nil, method: String, params: JSONValue? = nil) {
            self.jsonrpc = "2.0"
            self.id = id
            self.method = method
            self.params = params
        }

        private enum CodingKeys: String, CodingKey {
            case jsonrpc, id, method, params
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let version = try c.decode(String.self, forKey: .jsonrpc)
            guard version == "2.0" else {
                throw DecodingError.dataCorruptedError(
                    forKey: .jsonrpc,
                    in: c,
                    debugDescription: "Expected jsonrpc '2.0', got '\(version)'"
                )
            }
            self.jsonrpc = version
            self.id = c.contains(.id) ? try c.decode(ID.self, forKey: .id) : nil
            self.method = try c.decode(String.self, forKey: .method)
            self.params = c.contains(.params) ? try c.decode(JSONValue.self, forKey: .params) : nil
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("2.0", forKey: .jsonrpc)
            if let id { try c.encode(id, forKey: .id) }
            try c.encode(method, forKey: .method)
            if let params { try c.encode(params, forKey: .params) }
        }
    }

    // parity: protocol/src/simulation.ts#JsonRpc.ErrorObject [status=implemented hash=8b2a9e4496a3]
    public struct ErrorObject: Equatable, Hashable, Sendable, Codable {
        public let code: Int
        public let message: String
        public let data: JSONValue?

        public init(code: Int, message: String, data: JSONValue? = nil) {
            self.code = code
            self.message = message
            self.data = data
        }
    }

    // parity: protocol/src/simulation.ts#JsonRpc.Response [status=implemented hash=7b5367e6a530]
    public enum Response: Equatable, Hashable, Sendable, Codable {
        case success(id: ID, result: JSONValue)
        case failure(id: ID, error: ErrorObject)

        public var jsonrpc: String { "2.0" }

        public var id: ID {
            switch self {
            case .success(let id, _): id
            case .failure(let id, _): id
            }
        }

        private enum CodingKeys: String, CodingKey {
            case jsonrpc, id, result, error
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let version = try c.decode(String.self, forKey: .jsonrpc)
            guard version == "2.0" else {
                throw DecodingError.dataCorruptedError(
                    forKey: .jsonrpc,
                    in: c,
                    debugDescription: "Expected jsonrpc '2.0', got '\(version)'"
                )
            }
            let id = try c.decode(ID.self, forKey: .id)
            let hasResult = c.contains(.result)
            let hasError = c.contains(.error)
            if hasResult && hasError {
                throw DecodingError.dataCorruptedError(
                    forKey: .result,
                    in: c,
                    debugDescription: "JsonRpc.Response cannot contain both 'result' and 'error'"
                )
            }
            if hasResult {
                self = .success(id: id, result: try c.decode(JSONValue.self, forKey: .result))
            } else if hasError {
                self = .failure(id: id, error: try c.decode(ErrorObject.self, forKey: .error))
            } else {
                throw DecodingError.dataCorruptedError(
                    forKey: .result,
                    in: c,
                    debugDescription: "JsonRpc.Response must contain either 'result' or 'error'"
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("2.0", forKey: .jsonrpc)
            switch self {
            case .success(let id, let result):
                try c.encode(id, forKey: .id)
                try c.encode(result, forKey: .result)
            case .failure(let id, let error):
                try c.encode(id, forKey: .id)
                try c.encode(error, forKey: .error)
            }
        }
    }

    // parity: protocol/src/simulation.ts#JsonRpc.decodeRequest [status=implemented hash=d24bf14efa58]
    public static func decodeRequest(_ value: JSONValue) throws(SimulationDecodeError) -> Request {
        let obj = try jsonObject(value, context: "JsonRpc.Request")
        let fields = try RequestFields.decode(from: obj)
        let method = try jsonString(obj, key: "method")
        return Request(id: fields.id, method: method, params: obj["params"])
    }

    /// Builds a JSON-RPC 2.0 success response, returning `nil` for notification requests (`id == nil`).
    // parity: protocol/src/simulation.ts#JsonRpc.success [status=implemented hash=f63de30ac814]
    public static func success(id: ID?, result: JSONValue) -> Response? {
        guard let id else { return nil }
        return .success(id: id, result: result)
    }

    /// Builds a JSON-RPC 2.0 failure response (`code: -32000`), normalizing `nil` id to `.null`.
    // parity: protocol/src/simulation.ts#JsonRpc.failure [status=implemented hash=dd8289ac5539]
    public static func failure(id: ID?, message: String) -> Response {
        .failure(
            id: id ?? .null,
            error: ErrorObject(code: -32000, message: message)
        )
    }

    /// Overload formatting any Swift `Error` into a JSON-RPC 2.0 failure response.
    public static func failure(id: ID?, error: any Error) -> Response {
        let message: String
        if let protocolError = error as? any ProtocolError {
            message = protocolError.message
        } else {
            message = String(describing: error)
        }
        return failure(id: id, message: message)
    }
}

// MARK: - SimulationRequestError

// parity: protocol/src/simulation.ts#SimulationRequestError [status=implemented hash=08825d09b016]
public struct SimulationRequestError: Error, Equatable, Hashable, Sendable, Codable {
    public static let tag = "SimulationRequestError"

    public let method: String
    public let code: Int
    public let message: String
    public let data: JSONValue?

    public init(method: String, code: Int, message: String, data: JSONValue? = nil) {
        self.method = method
        self.code = code
        self.message = message
        self.data = data
    }

    private enum CodingKeys: String, CodingKey {
        case _tag, method, code, message, data
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try validateErrorTag(Self.tag, in: c, key: ._tag)
        self.method = try c.decode(String.self, forKey: .method)
        self.code = try c.decode(Int.self, forKey: .code)
        self.message = try c.decode(String.self, forKey: .message)
        self.data = try c.decodeIfPresent(JSONValue.self, forKey: .data)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.tag, forKey: ._tag)
        try c.encode(method, forKey: .method)
        try c.encode(code, forKey: .code)
        try c.encode(message, forKey: .message)
        try c.encodeIfPresent(data, forKey: .data)
    }
}

// MARK: - Handshake Namespace

// parity: protocol/src/simulation.ts#Handshake [status=implemented hash=722fc7370197]
public enum Handshake {
    // parity: protocol/src/simulation.ts#Handshake.ProtocolVersion [status=implemented hash=ad2b260c8481]
    public enum ProtocolVersion: Int, Equatable, Hashable, Sendable, Codable {
        case v1 = 1
    }

    // parity: protocol/src/simulation.ts#Handshake.Capability [status=implemented hash=d63b794ff1b4]
    public typealias Capability = String

    // parity: protocol/src/simulation.ts#Handshake.EndpointRole [status=implemented hash=fd48a69122ee]
    public enum EndpointRole: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
        case ui
        case backend
    }

    // parity: protocol/src/simulation.ts#Handshake.Identity [status=implemented hash=5dc5c13b8f31]
    public struct Identity: Equatable, Hashable, Sendable, Codable {
        public let name: String
        public let version: String

        public init(name: String, version: String) {
            self.name = name
            self.version = version
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let name = try c.decode(String.self, forKey: .name)
            let version = try c.decode(String.self, forKey: .version)
            guard !name.isEmpty, !version.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    forKey: name.isEmpty ? .name : .version,
                    in: c,
                    debugDescription: "Handshake.Identity fields must be non-empty"
                )
            }
            self.name = name
            self.version = version
        }

        private enum CodingKeys: String, CodingKey {
            case name, version
        }

        fileprivate static func decode(from value: JSONValue) throws(SimulationDecodeError) -> Identity {
            let obj = try jsonObject(value, context: "Handshake.Identity")
            let name = try jsonString(obj, key: "name")
            let version = try jsonString(obj, key: "version")
            guard !name.isEmpty, !version.isEmpty else {
                throw SimulationDecodeError("Handshake.Identity name and version must be non-empty")
            }
            return Identity(name: name, version: version)
        }
    }

    // parity: protocol/src/simulation.ts#Handshake.Params [status=implemented hash=72254e7f3164]
    public struct Params: Equatable, Hashable, Sendable, Codable {
        public let client: Identity
        public let expectedRole: EndpointRole
        public let offeredVersions: [Int]
        public let requiredCapabilities: [Capability]
        public let optionalCapabilities: [Capability]

        public init(
            client: Identity,
            expectedRole: EndpointRole,
            offeredVersions: [Int],
            requiredCapabilities: [Capability] = [],
            optionalCapabilities: [Capability] = []
        ) {
            self.client = client
            self.expectedRole = expectedRole
            self.offeredVersions = offeredVersions
            self.requiredCapabilities = requiredCapabilities
            self.optionalCapabilities = optionalCapabilities
        }

        public func validate() throws(SimulationDecodeError) {
            guard !client.name.isEmpty && !client.version.isEmpty else {
                throw SimulationDecodeError("Handshake.Params.client fields must be non-empty")
            }
            guard !offeredVersions.isEmpty else {
                throw SimulationDecodeError("Handshake.Params.offeredVersions must not be empty")
            }
            guard offeredVersions.allSatisfy({ $0 > 0 }) else {
                throw SimulationDecodeError("Handshake.Params.offeredVersions must contain positive integers")
            }
            guard Set(offeredVersions).count == offeredVersions.count else {
                throw SimulationDecodeError("Handshake.Params.offeredVersions must be unique")
            }
            guard requiredCapabilities.allSatisfy({ !$0.isEmpty }),
                  Set(requiredCapabilities).count == requiredCapabilities.count else {
                throw SimulationDecodeError("Handshake.Params.requiredCapabilities must be unique non-empty strings")
            }
            guard optionalCapabilities.allSatisfy({ !$0.isEmpty }),
                  Set(optionalCapabilities).count == optionalCapabilities.count else {
                throw SimulationDecodeError("Handshake.Params.optionalCapabilities must be unique non-empty strings")
            }
        }

        fileprivate static func decode(from value: JSONValue) throws(SimulationDecodeError) -> Params {
            let obj = try jsonObject(value, context: "Handshake.Params")
            guard let clientRaw = obj["client"] else {
                throw SimulationDecodeError("Missing 'client' in Handshake.Params")
            }
            let client = try Identity.decode(from: clientRaw)
            let roleRaw = try jsonString(obj, key: "expectedRole")
            guard let expectedRole = EndpointRole(rawValue: roleRaw) else {
                throw SimulationDecodeError("Invalid expectedRole '\(roleRaw)'")
            }
            let offeredRaw = try jsonArray(obj, key: "offeredVersions")
            var offered: [Int] = []
            for item in offeredRaw {
                switch item {
                case .int(let i): offered.append(Int(i))
                case .double(let d) where d.isFinite && d.rounded() == d: offered.append(Int(d))
                default: throw SimulationDecodeError("Expected integer in offeredVersions")
                }
            }
            let reqRaw = try jsonArray(obj, key: "requiredCapabilities")
            var req: [String] = []
            for item in reqRaw {
                guard case .string(let s) = item else { throw SimulationDecodeError("Expected string in requiredCapabilities") }
                req.append(s)
            }
            let optRaw = try jsonArray(obj, key: "optionalCapabilities")
            var opt: [String] = []
            for item in optRaw {
                guard case .string(let s) = item else { throw SimulationDecodeError("Expected string in optionalCapabilities") }
                opt.append(s)
            }
            let params = Params(
                client: client,
                expectedRole: expectedRole,
                offeredVersions: offered,
                requiredCapabilities: req,
                optionalCapabilities: opt
            )
            try params.validate()
            return params
        }
    }

    // parity: protocol/src/simulation.ts#Handshake.Response [status=implemented hash=064288e78477]
    public struct Response: Equatable, Hashable, Sendable, Codable {
        public let protocolVersion: ProtocolVersion
        public let role: EndpointRole
        public let server: Identity
        public let capabilities: [Capability]

        public init(
            protocolVersion: ProtocolVersion = .v1,
            role: EndpointRole,
            server: Identity,
            capabilities: [Capability]
        ) {
            self.protocolVersion = protocolVersion
            self.role = role
            self.server = server
            self.capabilities = capabilities
        }
    }

    // parity: protocol/src/simulation.ts#Handshake.Request [status=implemented hash=0d44b90829d0]
    public struct Request: Equatable, Hashable, Sendable, Codable {
        public let jsonrpc: String
        public let id: JsonRpc.ID?
        public let method: String
        public let params: Params

        public init(id: JsonRpc.ID? = nil, params: Params) {
            self.jsonrpc = "2.0"
            self.id = id
            self.method = "simulation.handshake"
            self.params = params
        }

        private enum CodingKeys: String, CodingKey {
            case jsonrpc, id, method, params
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let version = try c.decode(String.self, forKey: .jsonrpc)
            guard version == "2.0" else {
                throw DecodingError.dataCorruptedError(forKey: .jsonrpc, in: c, debugDescription: "Expected jsonrpc '2.0'")
            }
            let method = try c.decode(String.self, forKey: .method)
            guard method == "simulation.handshake" else {
                throw DecodingError.dataCorruptedError(forKey: .method, in: c, debugDescription: "Expected method 'simulation.handshake'")
            }
            self.jsonrpc = version
            self.id = c.contains(.id) ? try c.decode(JsonRpc.ID.self, forKey: .id) : nil
            self.method = method
            self.params = try c.decode(Params.self, forKey: .params)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("2.0", forKey: .jsonrpc)
            if let id { try c.encode(id, forKey: .id) }
            try c.encode("simulation.handshake", forKey: .method)
            try c.encode(params, forKey: .params)
        }

        fileprivate static func decode(from obj: [String: JSONValue]) throws(SimulationDecodeError) -> Request {
            let fields = try JsonRpc.RequestFields.decode(from: obj)
            let method = try jsonString(obj, key: "method")
            guard method == "simulation.handshake" else {
                throw SimulationDecodeError("Expected method 'simulation.handshake', got '\(method)'")
            }
            guard let paramsRaw = obj["params"] else {
                throw SimulationDecodeError("Missing 'params' in simulation.handshake request")
            }
            let params = try Params.decode(from: paramsRaw)
            return Request(id: fields.id, params: params)
        }
    }

    // parity: protocol/src/simulation.ts#Handshake.DispatchAction [status=implemented hash=b4328915e7aa]
    public struct DispatchAction: Equatable, Hashable, Sendable, Codable {
        public let role: EndpointRole
        public let server: Identity
        public let capabilities: [Capability]

        public init(role: EndpointRole, server: Identity, capabilities: [Capability]) {
            self.role = role
            self.server = server
            self.capabilities = capabilities
        }
    }

    // parity: protocol/src/simulation.ts#Handshake.RoleMismatchError [status=implemented hash=9fceb130a29a]
    public struct RoleMismatchError: Error, Equatable, Hashable, Sendable, Codable {
        public static let tag = "SimulationHandshake.RoleMismatchError"

        public let expected: EndpointRole
        public let actual: EndpointRole
        public let message: String

        public init(expected: EndpointRole, actual: EndpointRole, message: String) {
            self.expected = expected
            self.actual = actual
            self.message = message
        }

        private enum CodingKeys: String, CodingKey {
            case _tag, expected, actual, message
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            try validateErrorTag(Self.tag, in: c, key: ._tag)
            self.expected = try c.decode(EndpointRole.self, forKey: .expected)
            self.actual = try c.decode(EndpointRole.self, forKey: .actual)
            self.message = try c.decode(String.self, forKey: .message)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(Self.tag, forKey: ._tag)
            try c.encode(expected, forKey: .expected)
            try c.encode(actual, forKey: .actual)
            try c.encode(message, forKey: .message)
        }
    }

    // parity: protocol/src/simulation.ts#Handshake.UnsupportedProtocolError [status=implemented hash=42395246fad6]
    public struct UnsupportedProtocolError: Error, Equatable, Hashable, Sendable, Codable {
        public static let tag = "SimulationHandshake.UnsupportedProtocolError"

        public let offered: [Int]
        public let supported: [ProtocolVersion]
        public let message: String

        public init(offered: [Int], supported: [ProtocolVersion], message: String) {
            self.offered = offered
            self.supported = supported
            self.message = message
        }

        private enum CodingKeys: String, CodingKey {
            case _tag, offered, supported, message
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            try validateErrorTag(Self.tag, in: c, key: ._tag)
            self.offered = try c.decode([Int].self, forKey: .offered)
            self.supported = try c.decode([ProtocolVersion].self, forKey: .supported)
            self.message = try c.decode(String.self, forKey: .message)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(Self.tag, forKey: ._tag)
            try c.encode(offered, forKey: .offered)
            try c.encode(supported, forKey: .supported)
            try c.encode(message, forKey: .message)
        }
    }

    // parity: protocol/src/simulation.ts#Handshake.MissingCapabilityError [status=implemented hash=2c972eed5c4f]
    public struct MissingCapabilityError: Error, Equatable, Hashable, Sendable, Codable {
        public static let tag = "SimulationHandshake.MissingCapabilityError"

        public let missing: [Capability]
        public let message: String

        public init(missing: [Capability], message: String) {
            self.missing = missing
            self.message = message
        }

        private enum CodingKeys: String, CodingKey {
            case _tag, missing, message
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            try validateErrorTag(Self.tag, in: c, key: ._tag)
            self.missing = try c.decode([Capability].self, forKey: .missing)
            self.message = try c.decode(String.self, forKey: .message)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(Self.tag, forKey: ._tag)
            try c.encode(missing, forKey: .missing)
            try c.encode(message, forKey: .message)
        }
    }

    /// Typed union of handshake failures returned by `Handshake.dispatch`.
    public enum DispatchError: Error, Equatable, Hashable, Sendable {
        case roleMismatch(RoleMismatchError)
        case unsupportedProtocol(UnsupportedProtocolError)
        case missingCapability(MissingCapabilityError)
    }

    /// Evaluates a simulation handshake request against an endpoint's role, version, and capabilities.
    // parity: protocol/src/simulation.ts#Handshake.dispatch [status=implemented hash=d102343722a4]
    public static func dispatch(action: DispatchAction, params: Params) throws(DispatchError) -> Response {
        if params.expectedRole != action.role {
            throw .roleMismatch(
                RoleMismatchError(
                    expected: params.expectedRole,
                    actual: action.role,
                    message: "Expected simulation endpoint role \(params.expectedRole.rawValue), received \(action.role.rawValue)"
                )
            )
        }
        if !params.offeredVersions.contains(1) {
            throw .unsupportedProtocol(
                UnsupportedProtocolError(
                    offered: params.offeredVersions,
                    supported: [.v1],
                    message: "No mutually supported simulation protocol version"
                )
            )
        }
        var seen = Set<Capability>()
        var installedOrdered: [Capability] = []
        for cap in action.capabilities where seen.insert(cap).inserted {
            installedOrdered.append(cap)
        }
        let missing = params.requiredCapabilities.filter { !seen.contains($0) }
        if !missing.isEmpty {
            throw .missingCapability(
                MissingCapabilityError(
                    missing: missing,
                    message: "Simulation endpoint is missing required capabilities: \(missing.joined(separator: ", "))"
                )
            )
        }
        return Response(
            protocolVersion: .v1,
            role: action.role,
            server: action.server,
            capabilities: installedOrdered
        )
    }
}

// MARK: - Frontend Namespace

// parity: protocol/src/simulation.ts#Frontend [status=implemented hash=1780972c23e7]
public enum Frontend {
    // parity: protocol/src/simulation.ts#Frontend.Capabilities [status=implemented hash=da86c1bed891]
    public static let Capabilities: [Handshake.Capability] = [
        "ui.type",
        "ui.press",
        "ui.enter",
        "ui.arrow",
        "ui.focus",
        "ui.click",
        "ui.click.semantic",
        "ui.mouse",
        "ui.recording.pointer",
        "ui.resize",
        "ui.matches",
        "ui.state",
        "ui.snapshot",
        "ui.capture",
        "ui.recording.finish",
    ]

    // parity: protocol/src/simulation.ts#Frontend.Capability [status=implemented hash=d271487d7715]
    public enum Capability: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
        case uiType = "ui.type"
        case uiPress = "ui.press"
        case uiEnter = "ui.enter"
        case uiArrow = "ui.arrow"
        case uiFocus = "ui.focus"
        case uiClick = "ui.click"
        case uiClickSemantic = "ui.click.semantic"
        case uiMouse = "ui.mouse"
        case uiRecordingPointer = "ui.recording.pointer"
        case uiResize = "ui.resize"
        case uiMatches = "ui.matches"
        case uiState = "ui.state"
        case uiSnapshot = "ui.snapshot"
        case uiCapture = "ui.capture"
        case uiRecordingFinish = "ui.recording.finish"
    }

    public enum Direction: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
        case up, down, left, right
    }

    public enum MouseButton: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
        case left, middle, right
    }

    public struct MouseModifiers: Equatable, Hashable, Sendable, Codable {
        public let shift: Bool?
        public let alt: Bool?
        public let ctrl: Bool?

        public init(shift: Bool? = nil, alt: Bool? = nil, ctrl: Bool? = nil) {
            self.shift = shift
            self.alt = alt
            self.ctrl = ctrl
        }

        fileprivate static func decode(from value: JSONValue) throws(SimulationDecodeError) -> MouseModifiers {
            let obj = try jsonObject(value, context: "Frontend.MouseModifiers")
            return MouseModifiers(
                shift: try jsonOptionalBool(obj, key: "shift"),
                alt: try jsonOptionalBool(obj, key: "alt"),
                ctrl: try jsonOptionalBool(obj, key: "ctrl")
            )
        }
    }

    // parity: protocol/src/simulation.ts#Frontend.KeyModifiers [status=implemented hash=33a29c535974]
    public struct KeyModifiers: Equatable, Hashable, Sendable, Codable {
        public let ctrl: Bool?
        public let shift: Bool?
        public let meta: Bool?
        public let superKey: Bool?
        public let hyper: Bool?

        public init(
            ctrl: Bool? = nil,
            shift: Bool? = nil,
            meta: Bool? = nil,
            superKey: Bool? = nil,
            hyper: Bool? = nil
        ) {
            self.ctrl = ctrl
            self.shift = shift
            self.meta = meta
            self.superKey = superKey
            self.hyper = hyper
        }

        private enum CodingKeys: String, CodingKey {
            case ctrl, shift, meta
            case superKey = "super"
            case hyper
        }

        fileprivate static func decode(from value: JSONValue) throws(SimulationDecodeError) -> KeyModifiers {
            let obj = try jsonObject(value, context: "Frontend.KeyModifiers")
            return KeyModifiers(
                ctrl: try jsonOptionalBool(obj, key: "ctrl"),
                shift: try jsonOptionalBool(obj, key: "shift"),
                meta: try jsonOptionalBool(obj, key: "meta"),
                superKey: try jsonOptionalBool(obj, key: "super"),
                hyper: try jsonOptionalBool(obj, key: "hyper")
            )
        }
    }

    // parity: protocol/src/simulation.ts#Frontend.SemanticClickTarget [status=implemented hash=687417e8b923]
    public struct SemanticClickTarget: Equatable, Hashable, Sendable, Codable {
        public let id: String
        public let instance: String?
        public let element: Int

        public init(id: String, instance: String? = nil, element: Int) {
            self.id = id
            self.instance = instance
            self.element = element
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let id = try c.decode(String.self, forKey: .id)
            let instance = try c.decodeIfPresent(String.self, forKey: .instance)
            let element = try c.decode(Int.self, forKey: .element)
            guard !id.isEmpty else {
                throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "SemanticClickTarget.id must be non-empty")
            }
            if let instance, instance.isEmpty {
                throw DecodingError.dataCorruptedError(forKey: .instance, in: c, debugDescription: "SemanticClickTarget.instance must be non-empty")
            }
            guard element > 0 else {
                throw DecodingError.dataCorruptedError(forKey: .element, in: c, debugDescription: "SemanticClickTarget.element must be > 0")
            }
            self.id = id
            self.instance = instance
            self.element = element
        }

        private enum CodingKeys: String, CodingKey {
            case id, instance, element
        }

        fileprivate static func decode(from value: JSONValue) throws(SimulationDecodeError) -> SemanticClickTarget {
            let obj = try jsonObject(value, context: "Frontend.SemanticClickTarget")
            let id = try jsonString(obj, key: "id")
            let instance = try jsonOptionalString(obj, key: "instance")
            let element = try jsonInt(obj, key: "element")
            guard !id.isEmpty, element > 0 else {
                throw SimulationDecodeError("Invalid SemanticClickTarget")
            }
            if let instance, instance.isEmpty {
                throw SimulationDecodeError("SemanticClickTarget.instance must be non-empty")
            }
            return SemanticClickTarget(id: id, instance: instance, element: element)
        }
    }

    // parity: protocol/src/simulation.ts#Frontend.MouseParams [status=implemented hash=ce840afd4bec]
    public enum MouseParams: Equatable, Hashable, Sendable, Codable {
        case move(x: Int, y: Int, modifiers: MouseModifiers? = nil)
        case down(x: Int, y: Int, button: MouseButton? = nil, modifiers: MouseModifiers? = nil)
        case up(x: Int, y: Int, button: MouseButton? = nil, modifiers: MouseModifiers? = nil)
        case scroll(x: Int, y: Int, direction: Direction, modifiers: MouseModifiers? = nil)

        private enum CodingKeys: String, CodingKey {
            case x, y, modifiers, action, button, direction
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let x = try c.decode(Int.self, forKey: .x)
            let y = try c.decode(Int.self, forKey: .y)
            guard x >= 0, y >= 0 else {
                throw DecodingError.dataCorruptedError(forKey: .x, in: c, debugDescription: "Mouse coordinates must be >= 0")
            }
            let modifiers = try c.decodeIfPresent(MouseModifiers.self, forKey: .modifiers)
            let action = try c.decode(String.self, forKey: .action)
            switch action {
            case "move":
                self = .move(x: x, y: y, modifiers: modifiers)
            case "down":
                self = .down(x: x, y: y, button: try c.decodeIfPresent(MouseButton.self, forKey: .button), modifiers: modifiers)
            case "up":
                self = .up(x: x, y: y, button: try c.decodeIfPresent(MouseButton.self, forKey: .button), modifiers: modifiers)
            case "scroll":
                self = .scroll(x: x, y: y, direction: try c.decode(Direction.self, forKey: .direction), modifiers: modifiers)
            default:
                throw DecodingError.dataCorruptedError(forKey: .action, in: c, debugDescription: "Unknown MouseParams action '\(action)'")
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .move(let x, let y, let modifiers):
                try c.encode(x, forKey: .x)
                try c.encode(y, forKey: .y)
                try c.encodeIfPresent(modifiers, forKey: .modifiers)
                try c.encode("move", forKey: .action)
            case .down(let x, let y, let button, let modifiers):
                try c.encode(x, forKey: .x)
                try c.encode(y, forKey: .y)
                try c.encodeIfPresent(modifiers, forKey: .modifiers)
                try c.encode("down", forKey: .action)
                try c.encodeIfPresent(button, forKey: .button)
            case .up(let x, let y, let button, let modifiers):
                try c.encode(x, forKey: .x)
                try c.encode(y, forKey: .y)
                try c.encodeIfPresent(modifiers, forKey: .modifiers)
                try c.encode("up", forKey: .action)
                try c.encodeIfPresent(button, forKey: .button)
            case .scroll(let x, let y, let direction, let modifiers):
                try c.encode(x, forKey: .x)
                try c.encode(y, forKey: .y)
                try c.encodeIfPresent(modifiers, forKey: .modifiers)
                try c.encode("scroll", forKey: .action)
                try c.encode(direction, forKey: .direction)
            }
        }

        fileprivate static func decode(from value: JSONValue) throws(SimulationDecodeError) -> MouseParams {
            let obj = try jsonObject(value, context: "Frontend.MouseParams")
            let x = try jsonInt(obj, key: "x")
            let y = try jsonInt(obj, key: "y")
            guard x >= 0, y >= 0 else { throw SimulationDecodeError("Mouse coordinates must be >= 0") }
            let modifiers: MouseModifiers? = if let raw = obj["modifiers"] { try MouseModifiers.decode(from: raw) } else { nil }
            let action = try jsonString(obj, key: "action")
            switch action {
            case "move":
                return .move(x: x, y: y, modifiers: modifiers)
            case "down", "up":
                let button: MouseButton?
                if let btnStr = try jsonOptionalString(obj, key: "button") {
                    guard let b = MouseButton(rawValue: btnStr) else {
                        throw SimulationDecodeError("Invalid mouse button '\(btnStr)'")
                    }
                    button = b
                } else {
                    button = nil
                }
                return action == "down"
                    ? .down(x: x, y: y, button: button, modifiers: modifiers)
                    : .up(x: x, y: y, button: button, modifiers: modifiers)
            case "scroll":
                let dirStr = try jsonString(obj, key: "direction")
                guard let dir = Direction(rawValue: dirStr) else {
                    throw SimulationDecodeError("Invalid scroll direction '\(dirStr)'")
                }
                return .scroll(x: x, y: y, direction: dir, modifiers: modifiers)
            default:
                throw SimulationDecodeError("Unknown MouseParams action '\(action)'")
            }
        }
    }

    // parity: protocol/src/simulation.ts#Frontend.Action [status=implemented hash=7b86293e0224]
    public enum Action: Equatable, Hashable, Sendable, Codable {
        case type(text: String)
        case press(key: String, modifiers: KeyModifiers? = nil)
        case enter
        case arrow(direction: Direction)
        case focus(target: Double)
        case mouse(params: MouseParams)
        case click(target: Double, x: Double, y: Double, semantic: SemanticClickTarget? = nil)
        case resize(cols: Double, rows: Double)

        private enum CodingKeys: String, CodingKey {
            case type, text, key, modifiers, direction, target, params, x, y, semantic, cols, rows
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let kind = try c.decode(String.self, forKey: .type)
            switch kind {
            case "ui.type":
                self = .type(text: try c.decode(String.self, forKey: .text))
            case "ui.press":
                self = .press(
                    key: try c.decode(String.self, forKey: .key),
                    modifiers: try c.decodeIfPresent(KeyModifiers.self, forKey: .modifiers)
                )
            case "ui.enter":
                self = .enter
            case "ui.arrow":
                self = .arrow(direction: try c.decode(Direction.self, forKey: .direction))
            case "ui.focus":
                self = .focus(target: try c.decode(Double.self, forKey: .target))
            case "ui.mouse":
                self = .mouse(params: try c.decode(MouseParams.self, forKey: .params))
            case "ui.click":
                self = .click(
                    target: try c.decode(Double.self, forKey: .target),
                    x: try c.decode(Double.self, forKey: .x),
                    y: try c.decode(Double.self, forKey: .y),
                    semantic: try c.decodeIfPresent(SemanticClickTarget.self, forKey: .semantic)
                )
            case "ui.resize":
                self = .resize(
                    cols: try c.decode(Double.self, forKey: .cols),
                    rows: try c.decode(Double.self, forKey: .rows)
                )
            default:
                throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown Frontend.Action '\(kind)'")
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .type(let text):
                try c.encode("ui.type", forKey: .type)
                try c.encode(text, forKey: .text)
            case .press(let key, let modifiers):
                try c.encode("ui.press", forKey: .type)
                try c.encode(key, forKey: .key)
                try c.encodeIfPresent(modifiers, forKey: .modifiers)
            case .enter:
                try c.encode("ui.enter", forKey: .type)
            case .arrow(let direction):
                try c.encode("ui.arrow", forKey: .type)
                try c.encode(direction, forKey: .direction)
            case .focus(let target):
                try c.encode("ui.focus", forKey: .type)
                try c.encode(target, forKey: .target)
            case .mouse(let params):
                try c.encode("ui.mouse", forKey: .type)
                try c.encode(params, forKey: .params)
            case .click(let target, let x, let y, let semantic):
                try c.encode("ui.click", forKey: .type)
                try c.encode(target, forKey: .target)
                try c.encode(x, forKey: .x)
                try c.encode(y, forKey: .y)
                try c.encodeIfPresent(semantic, forKey: .semantic)
            case .resize(let cols, let rows):
                try c.encode("ui.resize", forKey: .type)
                try c.encode(cols, forKey: .cols)
                try c.encode(rows, forKey: .rows)
            }
        }
    }

    // parity: protocol/src/simulation.ts#Frontend.Element [status=implemented hash=bee24a4cb5e1]
    public struct Element: Equatable, Hashable, Sendable, Codable {
        public let id: String
        public let num: Double
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double
        public let focusable: Bool
        public let focused: Bool
        public let clickable: Bool
        public let editor: Bool

        public init(
            id: String,
            num: Double,
            x: Double,
            y: Double,
            width: Double,
            height: Double,
            focusable: Bool,
            focused: Bool,
            clickable: Bool,
            editor: Bool
        ) {
            self.id = id
            self.num = num
            self.x = x
            self.y = y
            self.width = width
            self.height = height
            self.focusable = focusable
            self.focused = focused
            self.clickable = clickable
            self.editor = editor
        }
    }

    // parity: protocol/src/simulation.ts#Frontend.State [status=implemented hash=2be8dcc2e69f]
    public struct State: Equatable, Hashable, Sendable, Codable {
        public struct Focused: Equatable, Hashable, Sendable, Codable {
            public let renderable: Double?
            public let editor: Bool

            public init(renderable: Double? = nil, editor: Bool) {
                self.renderable = renderable
                self.editor = editor
            }
        }

        public let focused: Focused
        public let elements: [Element]

        public init(focused: Focused, elements: [Element]) {
            self.focused = focused
            self.elements = elements
        }
    }

    // parity: protocol/src/simulation.ts#Frontend.SemanticNode [status=implemented hash=9834c443cfef]
    public struct SemanticNode: Equatable, Hashable, Sendable, Codable {
        public let id: String
        public let instance: String?
        public let parent: String?
        public let role: String
        public let label: String?
        public let element: Int
        public let focused: Bool?
        public let selected: Bool?
        public let expanded: Bool?
        public let disabled: Bool?

        public init(
            id: String,
            instance: String? = nil,
            parent: String? = nil,
            role: String,
            label: String? = nil,
            element: Int,
            focused: Bool? = nil,
            selected: Bool? = nil,
            expanded: Bool? = nil,
            disabled: Bool? = nil
        ) {
            self.id = id
            self.instance = instance
            self.parent = parent
            self.role = role
            self.label = label
            self.element = element
            self.focused = focused
            self.selected = selected
            self.expanded = expanded
            self.disabled = disabled
        }

        private enum CodingKeys: String, CodingKey {
            case id, instance, parent, role, label, element, focused, selected, expanded, disabled
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let id = try c.decode(String.self, forKey: .id)
            let instance = try c.decodeIfPresent(String.self, forKey: .instance)
            let parent = try c.decodeIfPresent(String.self, forKey: .parent)
            let role = try c.decode(String.self, forKey: .role)
            let label = try c.decodeIfPresent(String.self, forKey: .label)
            let element = try c.decode(Int.self, forKey: .element)
            guard !id.isEmpty, !role.isEmpty, element > 0 else {
                throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "Invalid SemanticNode")
            }
            if let instance, instance.isEmpty {
                throw DecodingError.dataCorruptedError(forKey: .instance, in: c, debugDescription: "SemanticNode.instance must be non-empty")
            }
            if let parent, parent.isEmpty {
                throw DecodingError.dataCorruptedError(forKey: .parent, in: c, debugDescription: "SemanticNode.parent must be non-empty")
            }
            if let label, label.isEmpty {
                throw DecodingError.dataCorruptedError(forKey: .label, in: c, debugDescription: "SemanticNode.label must be non-empty")
            }
            self.id = id
            self.instance = instance
            self.parent = parent
            self.role = role
            self.label = label
            self.element = element
            self.focused = try c.decodeIfPresent(Bool.self, forKey: .focused)
            self.selected = try c.decodeIfPresent(Bool.self, forKey: .selected)
            self.expanded = try c.decodeIfPresent(Bool.self, forKey: .expanded)
            self.disabled = try c.decodeIfPresent(Bool.self, forKey: .disabled)
        }
    }

    // parity: protocol/src/simulation.ts#Frontend.SemanticSnapshot [status=implemented hash=6b3531ac1e25]
    public struct SemanticSnapshot: Equatable, Hashable, Sendable, Codable {
        public static let expectedFormat = "opencode-ui-snapshot-v1"

        public let format: String
        public let nodes: [SemanticNode]

        public init(nodes: [SemanticNode]) throws(SimulationDecodeError) {
            self.format = Self.expectedFormat
            self.nodes = nodes
            try Self.validateNodes(nodes)
        }

        public static func validateNodes(_ nodes: [SemanticNode]) throws(SimulationDecodeError) {
            let ids = Set(nodes.map(\.id))
            if ids.count != nodes.count {
                throw SimulationDecodeError("semantic node ids must be unique")
            }
            if Set(nodes.map(\.element)).count != nodes.count {
                throw SimulationDecodeError("semantic node elements must be unique")
            }
            if nodes.contains(where: { $0.parent != nil && !ids.contains($0.parent!) }) {
                throw SimulationDecodeError("semantic node parents must reference another node")
            }
            let parents = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.parent) })
            for node in nodes {
                var visited = Set<String>()
                var current: String? = node.id
                while let id = current {
                    if !visited.insert(id).inserted {
                        throw SimulationDecodeError("semantic node hierarchy must be acyclic")
                    }
                    current = parents[id] ?? nil
                }
            }
        }

        private enum CodingKeys: String, CodingKey {
            case format, nodes
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let format = try c.decode(String.self, forKey: .format)
            guard format == Self.expectedFormat else {
                throw DecodingError.dataCorruptedError(
                    forKey: .format,
                    in: c,
                    debugDescription: "Expected format '\(Self.expectedFormat)', got '\(format)'"
                )
            }
            let nodes = try c.decode([SemanticNode].self, forKey: .nodes)
            do {
                try Self.validateNodes(nodes)
            } catch {
                throw DecodingError.dataCorruptedError(forKey: .nodes, in: c, debugDescription: error.message)
            }
            self.format = format
            self.nodes = nodes
        }
    }

    // parity: protocol/src/simulation.ts#Frontend.Color [status=implemented hash=f225d5ba7a0b]
    public struct Color: Equatable, Hashable, Sendable, Codable {
        public let r: Double
        public let g: Double
        public let b: Double
        public let a: Double

        public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double) {
            self.r = r
            self.g = g
            self.b = b
            self.a = a
        }

        public init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            let r = try c.decode(Double.self)
            let g = try c.decode(Double.self)
            let b = try c.decode(Double.self)
            let a = try c.decode(Double.self)
            guard c.isAtEnd else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Frontend.Color expects exactly 4 numbers")
            }
            self.init(r, g, b, a)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.unkeyedContainer()
            try c.encode(r)
            try c.encode(g)
            try c.encode(b)
            try c.encode(a)
        }
    }

    // parity: protocol/src/simulation.ts#Frontend.CapturedImage [status=implemented hash=ffa70edb115f]
    public struct CapturedImage: Equatable, Hashable, Sendable, Codable {
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double
        public let pixelWidth: Double
        public let pixelHeight: Double
        public let rgba: String

        public init(
            x: Double,
            y: Double,
            width: Double,
            height: Double,
            pixelWidth: Double,
            pixelHeight: Double,
            rgba: String
        ) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
            self.pixelWidth = pixelWidth
            self.pixelHeight = pixelHeight
            self.rgba = rgba
        }

        private enum CodingKeys: String, CodingKey {
            case x, y, width, height, pixelWidth, pixelHeight, rgba
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.x = try c.decode(Double.self, forKey: .x)
            self.y = try c.decode(Double.self, forKey: .y)
            self.width = try c.decode(Double.self, forKey: .width)
            self.height = try c.decode(Double.self, forKey: .height)
            self.pixelWidth = try c.decode(Double.self, forKey: .pixelWidth)
            self.pixelHeight = try c.decode(Double.self, forKey: .pixelHeight)
            let rgba = try c.decode(String.self, forKey: .rgba)
            guard isValidBase64(rgba) else {
                throw DecodingError.dataCorruptedError(forKey: .rgba, in: c, debugDescription: "CapturedImage.rgba must be valid base64")
            }
            self.rgba = rgba
        }
    }

    // parity: protocol/src/simulation.ts#Frontend.CapturedFrame [status=implemented hash=e21ec8d56a0c]
    public struct CapturedFrame: Equatable, Hashable, Sendable, Codable {
        public struct Cursor: Equatable, Hashable, Sendable, Codable {
            public let col: Double
            public let row: Double

            public init(_ col: Double, _ row: Double) {
                self.col = col
                self.row = row
            }

            public init(from decoder: Decoder) throws {
                var c = try decoder.unkeyedContainer()
                let col = try c.decode(Double.self)
                let row = try c.decode(Double.self)
                guard c.isAtEnd else {
                    throw DecodingError.dataCorruptedError(in: c, debugDescription: "Cursor expects exactly 2 numbers")
                }
                self.init(col, row)
            }

            public func encode(to encoder: Encoder) throws {
                var c = encoder.unkeyedContainer()
                try c.encode(col)
                try c.encode(row)
            }
        }

        public struct Span: Equatable, Hashable, Sendable, Codable {
            public let text: String
            public let fg: Color
            public let bg: Color
            public let attributes: Double
            public let width: Double

            public init(text: String, fg: Color, bg: Color, attributes: Double, width: Double) {
                self.text = text
                self.fg = fg
                self.bg = bg
                self.attributes = attributes
                self.width = width
            }
        }

        public struct Line: Equatable, Hashable, Sendable, Codable {
            public let spans: [Span]

            public init(spans: [Span]) {
                self.spans = spans
            }
        }

        public let cols: Double
        public let rows: Double
        public let cursor: Cursor
        public let lines: [Line]
        public let images: [CapturedImage]?

        public init(cols: Double, rows: Double, cursor: Cursor, lines: [Line], images: [CapturedImage]? = nil) {
            self.cols = cols
            self.rows = rows
            self.cursor = cursor
            self.lines = lines
            self.images = images
        }
    }

    // parity: protocol/src/simulation.ts#Frontend.RecordingFinish [status=implemented hash=f244ce30535a]
    public typealias RecordingFinish = String

    // parity: protocol/src/simulation.ts#Frontend.Matches [status=implemented hash=23b045bab13f]
    public typealias Matches = Bool

    // parity: protocol/src/simulation.ts#Frontend.TypeParams [status=implemented hash=5ba3ad94f197]
    public struct TypeParams: Equatable, Hashable, Sendable, Codable {
        public let text: String

        public init(text: String) {
            self.text = text
        }
    }

    // parity: protocol/src/simulation.ts#Frontend.MatchesParams [status=implemented hash=2ed515ba8278]
    public struct MatchesParams: Equatable, Hashable, Sendable, Codable {
        public let text: String

        public init(text: String) {
            self.text = text
        }
    }

    // parity: protocol/src/simulation.ts#Frontend.PressParams [status=implemented hash=30eaa35148fa]
    public struct PressParams: Equatable, Hashable, Sendable, Codable {
        public let key: String
        public let modifiers: KeyModifiers?

        public init(key: String, modifiers: KeyModifiers? = nil) {
            self.key = key
            self.modifiers = modifiers
        }
    }

    // parity: protocol/src/simulation.ts#Frontend.pressParams [status=implemented hash=ba6909bd6162]
    public static func pressParams(_ key: String, modifiers: KeyModifiers? = nil) -> PressParams {
        PressParams(key: key, modifiers: modifiers)
    }

    // parity: protocol/src/simulation.ts#Frontend.ArrowParams [status=implemented hash=1b77c1249232]
    public struct ArrowParams: Equatable, Hashable, Sendable, Codable {
        public let direction: Direction

        public init(direction: Direction) {
            self.direction = direction
        }
    }

    // parity: protocol/src/simulation.ts#Frontend.FocusParams [status=implemented hash=f0d071a62afe]
    public struct FocusParams: Equatable, Hashable, Sendable, Codable {
        public let target: Double

        public init(target: Double) {
            self.target = target
        }
    }

    // parity: protocol/src/simulation.ts#Frontend.ClickParams [status=implemented hash=65c42ec86eec]
    public struct ClickParams: Equatable, Hashable, Sendable, Codable {
        public let target: Double
        public let x: Double
        public let y: Double
        public let semantic: SemanticClickTarget?

        public init(target: Double, x: Double, y: Double, semantic: SemanticClickTarget? = nil) {
            self.target = target
            self.x = x
            self.y = y
            self.semantic = semantic
        }
    }

    // parity: protocol/src/simulation.ts#Frontend.ResizeParams [status=implemented hash=81c9587958ee]
    public struct ResizeParams: Equatable, Hashable, Sendable, Codable {
        public let cols: Double
        public let rows: Double

        public init(cols: Double, rows: Double) {
            self.cols = cols
            self.rows = rows
        }
    }

    // parity: protocol/src/simulation.ts#Frontend.Request [status=implemented hash=b4f8ccbb64d0]
    public enum Request: Equatable, Hashable, Sendable, Codable {
        case handshake(Handshake.Request)
        case uiType(id: JsonRpc.ID?, params: TypeParams)
        case uiPress(id: JsonRpc.ID?, params: PressParams)
        case uiArrow(id: JsonRpc.ID?, params: ArrowParams)
        case uiFocus(id: JsonRpc.ID?, params: FocusParams)
        case uiClick(id: JsonRpc.ID?, params: ClickParams)
        case uiMouse(id: JsonRpc.ID?, params: MouseParams)
        case uiResize(id: JsonRpc.ID?, params: ResizeParams)
        case uiMatches(id: JsonRpc.ID?, params: MatchesParams)
        case uiEnter(id: JsonRpc.ID?)
        case uiState(id: JsonRpc.ID?)
        case uiSnapshot(id: JsonRpc.ID?)
        case uiRecordingFinish(id: JsonRpc.ID?)
        case uiCapture(id: JsonRpc.ID?)

        private enum CodingKeys: String, CodingKey {
            case jsonrpc, id, method, params
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let version = try c.decode(String.self, forKey: .jsonrpc)
            guard version == "2.0" else {
                throw DecodingError.dataCorruptedError(forKey: .jsonrpc, in: c, debugDescription: "Expected jsonrpc '2.0'")
            }
            let id = c.contains(.id) ? try c.decode(JsonRpc.ID.self, forKey: .id) : nil
            let method = try c.decode(String.self, forKey: .method)
            switch method {
            case "simulation.handshake":
                self = .handshake(try Handshake.Request(from: decoder))
            case "ui.type":
                self = .uiType(id: id, params: try c.decode(TypeParams.self, forKey: .params))
            case "ui.press":
                self = .uiPress(id: id, params: try c.decode(PressParams.self, forKey: .params))
            case "ui.arrow":
                self = .uiArrow(id: id, params: try c.decode(ArrowParams.self, forKey: .params))
            case "ui.focus":
                self = .uiFocus(id: id, params: try c.decode(FocusParams.self, forKey: .params))
            case "ui.click":
                self = .uiClick(id: id, params: try c.decode(ClickParams.self, forKey: .params))
            case "ui.mouse":
                self = .uiMouse(id: id, params: try c.decode(MouseParams.self, forKey: .params))
            case "ui.resize":
                self = .uiResize(id: id, params: try c.decode(ResizeParams.self, forKey: .params))
            case "ui.matches":
                self = .uiMatches(id: id, params: try c.decode(MatchesParams.self, forKey: .params))
            case "ui.enter":
                self = .uiEnter(id: id)
            case "ui.state":
                self = .uiState(id: id)
            case "ui.snapshot":
                self = .uiSnapshot(id: id)
            case "ui.recording.finish":
                self = .uiRecordingFinish(id: id)
            case "ui.capture":
                self = .uiCapture(id: id)
            default:
                throw DecodingError.dataCorruptedError(forKey: .method, in: c, debugDescription: "Unknown Frontend.Request method '\(method)'")
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .handshake(let req):
                try req.encode(to: encoder)
            case .uiType(let id, let params):
                try c.encode("2.0", forKey: .jsonrpc)
                if let id { try c.encode(id, forKey: .id) }
                try c.encode("ui.type", forKey: .method)
                try c.encode(params, forKey: .params)
            case .uiPress(let id, let params):
                try c.encode("2.0", forKey: .jsonrpc)
                if let id { try c.encode(id, forKey: .id) }
                try c.encode("ui.press", forKey: .method)
                try c.encode(params, forKey: .params)
            case .uiArrow(let id, let params):
                try c.encode("2.0", forKey: .jsonrpc)
                if let id { try c.encode(id, forKey: .id) }
                try c.encode("ui.arrow", forKey: .method)
                try c.encode(params, forKey: .params)
            case .uiFocus(let id, let params):
                try c.encode("2.0", forKey: .jsonrpc)
                if let id { try c.encode(id, forKey: .id) }
                try c.encode("ui.focus", forKey: .method)
                try c.encode(params, forKey: .params)
            case .uiClick(let id, let params):
                try c.encode("2.0", forKey: .jsonrpc)
                if let id { try c.encode(id, forKey: .id) }
                try c.encode("ui.click", forKey: .method)
                try c.encode(params, forKey: .params)
            case .uiMouse(let id, let params):
                try c.encode("2.0", forKey: .jsonrpc)
                if let id { try c.encode(id, forKey: .id) }
                try c.encode("ui.mouse", forKey: .method)
                try c.encode(params, forKey: .params)
            case .uiResize(let id, let params):
                try c.encode("2.0", forKey: .jsonrpc)
                if let id { try c.encode(id, forKey: .id) }
                try c.encode("ui.resize", forKey: .method)
                try c.encode(params, forKey: .params)
            case .uiMatches(let id, let params):
                try c.encode("2.0", forKey: .jsonrpc)
                if let id { try c.encode(id, forKey: .id) }
                try c.encode("ui.matches", forKey: .method)
                try c.encode(params, forKey: .params)
            case .uiEnter(let id):
                try c.encode("2.0", forKey: .jsonrpc)
                if let id { try c.encode(id, forKey: .id) }
                try c.encode("ui.enter", forKey: .method)
            case .uiState(let id):
                try c.encode("2.0", forKey: .jsonrpc)
                if let id { try c.encode(id, forKey: .id) }
                try c.encode("ui.state", forKey: .method)
            case .uiSnapshot(let id):
                try c.encode("2.0", forKey: .jsonrpc)
                if let id { try c.encode(id, forKey: .id) }
                try c.encode("ui.snapshot", forKey: .method)
            case .uiRecordingFinish(let id):
                try c.encode("2.0", forKey: .jsonrpc)
                if let id { try c.encode(id, forKey: .id) }
                try c.encode("ui.recording.finish", forKey: .method)
            case .uiCapture(let id):
                try c.encode("2.0", forKey: .jsonrpc)
                if let id { try c.encode(id, forKey: .id) }
                try c.encode("ui.capture", forKey: .method)
            }
        }
    }

    // parity: protocol/src/simulation.ts#Frontend.decodeRequest [status=implemented hash=d24bf14efa58]
    public static func decodeRequest(_ value: JSONValue) throws(SimulationDecodeError) -> Request {
        let obj = try jsonObject(value, context: "Frontend.Request")
        let fields = try JsonRpc.RequestFields.decode(from: obj)
        let method = try jsonString(obj, key: "method")
        switch method {
        case "simulation.handshake":
            return .handshake(try Handshake.Request.decode(from: obj))
        case "ui.type":
            guard let raw = obj["params"] else { throw SimulationDecodeError("Missing params for ui.type") }
            let p = try jsonObject(raw, context: "Frontend.TypeParams")
            return .uiType(id: fields.id, params: TypeParams(text: try jsonString(p, key: "text")))
        case "ui.press":
            guard let raw = obj["params"] else { throw SimulationDecodeError("Missing params for ui.press") }
            let p = try jsonObject(raw, context: "Frontend.PressParams")
            let mods: KeyModifiers? = if let m = p["modifiers"] { try KeyModifiers.decode(from: m) } else { nil }
            return .uiPress(id: fields.id, params: PressParams(key: try jsonString(p, key: "key"), modifiers: mods))
        case "ui.arrow":
            guard let raw = obj["params"] else { throw SimulationDecodeError("Missing params for ui.arrow") }
            let p = try jsonObject(raw, context: "Frontend.ArrowParams")
            let dirStr = try jsonString(p, key: "direction")
            guard let dir = Direction(rawValue: dirStr) else {
                throw SimulationDecodeError("Invalid arrow direction '\(dirStr)'")
            }
            return .uiArrow(id: fields.id, params: ArrowParams(direction: dir))
        case "ui.focus":
            guard let raw = obj["params"] else { throw SimulationDecodeError("Missing params for ui.focus") }
            let p = try jsonObject(raw, context: "Frontend.FocusParams")
            return .uiFocus(id: fields.id, params: FocusParams(target: try jsonDouble(p, key: "target")))
        case "ui.click":
            guard let raw = obj["params"] else { throw SimulationDecodeError("Missing params for ui.click") }
            let p = try jsonObject(raw, context: "Frontend.ClickParams")
            let semantic: SemanticClickTarget? = if let s = p["semantic"] {
                try SemanticClickTarget.decode(from: s)
            } else { nil }
            return .uiClick(
                id: fields.id,
                params: ClickParams(
                    target: try jsonDouble(p, key: "target"),
                    x: try jsonDouble(p, key: "x"),
                    y: try jsonDouble(p, key: "y"),
                    semantic: semantic
                )
            )
        case "ui.mouse":
            guard let raw = obj["params"] else { throw SimulationDecodeError("Missing params for ui.mouse") }
            return .uiMouse(id: fields.id, params: try MouseParams.decode(from: raw))
        case "ui.resize":
            guard let raw = obj["params"] else { throw SimulationDecodeError("Missing params for ui.resize") }
            let p = try jsonObject(raw, context: "Frontend.ResizeParams")
            return .uiResize(
                id: fields.id,
                params: ResizeParams(cols: try jsonDouble(p, key: "cols"), rows: try jsonDouble(p, key: "rows"))
            )
        case "ui.matches":
            guard let raw = obj["params"] else { throw SimulationDecodeError("Missing params for ui.matches") }
            let p = try jsonObject(raw, context: "Frontend.MatchesParams")
            return .uiMatches(id: fields.id, params: MatchesParams(text: try jsonString(p, key: "text")))
        case "ui.enter":
            return .uiEnter(id: fields.id)
        case "ui.state":
            return .uiState(id: fields.id)
        case "ui.snapshot":
            return .uiSnapshot(id: fields.id)
        case "ui.recording.finish":
            return .uiRecordingFinish(id: fields.id)
        case "ui.capture":
            return .uiCapture(id: fields.id)
        default:
            throw SimulationDecodeError("Unknown Frontend.Request method '\(method)'")
        }
    }

    // parity: protocol/src/simulation.ts#Frontend.decodeRequestEffect [status=implemented hash=5dca76898ab8]
    public static func decodeRequestEffect(_ jsonString: String) throws(SimulationDecodeError) -> Request {
        let value = try parseJSONString(jsonString)
        return try decodeRequest(value)
    }
}

// MARK: - Backend Namespace

// parity: protocol/src/simulation.ts#Backend [status=implemented hash=145cdbc9a471]
public enum Backend {
    // parity: protocol/src/simulation.ts#Backend.Capabilities [status=implemented hash=da86c1bed891]
    public static let Capabilities: [Handshake.Capability] = [
        "llm.attach",
        "llm.chunk",
        "llm.finish",
        "llm.disconnect",
        "llm.pending",
        "llm.request",
        "llm.tool-input-delta",
        "tool.attach",
        "tool.update",
        "tool.finish",
        "tool.fail",
        "tool.invocation",
        "tool.cancel",
    ]

    // parity: protocol/src/simulation.ts#Backend.Item [status=implemented hash=fec3c982170d]
    public enum Item: Equatable, Hashable, Sendable, Codable {
        case textDelta(text: String)
        case reasoningDelta(text: String)
        case toolInputStart(index: Double, id: String, name: String)
        case toolInputDelta(index: Double, text: String)
        case toolCall(index: Double, id: String, name: String, input: JSONValue)
        case raw(chunk: JSONValue)

        private enum CodingKeys: String, CodingKey {
            case type, text, index, id, name, input, chunk
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let kind = try c.decode(String.self, forKey: .type)
            switch kind {
            case "textDelta":
                self = .textDelta(text: try c.decode(String.self, forKey: .text))
            case "reasoningDelta":
                self = .reasoningDelta(text: try c.decode(String.self, forKey: .text))
            case "toolInputStart":
                self = .toolInputStart(
                    index: try c.decode(Double.self, forKey: .index),
                    id: try c.decode(String.self, forKey: .id),
                    name: try c.decode(String.self, forKey: .name)
                )
            case "toolInputDelta":
                self = .toolInputDelta(
                    index: try c.decode(Double.self, forKey: .index),
                    text: try c.decode(String.self, forKey: .text)
                )
            case "toolCall":
                self = .toolCall(
                    index: try c.decode(Double.self, forKey: .index),
                    id: try c.decode(String.self, forKey: .id),
                    name: try c.decode(String.self, forKey: .name),
                    input: try c.decode(JSONValue.self, forKey: .input)
                )
            case "raw":
                self = .raw(chunk: try c.decode(JSONValue.self, forKey: .chunk))
            default:
                throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown Backend.Item '\(kind)'")
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .textDelta(let text):
                try c.encode("textDelta", forKey: .type)
                try c.encode(text, forKey: .text)
            case .reasoningDelta(let text):
                try c.encode("reasoningDelta", forKey: .type)
                try c.encode(text, forKey: .text)
            case .toolInputStart(let index, let id, let name):
                try c.encode("toolInputStart", forKey: .type)
                try c.encode(index, forKey: .index)
                try c.encode(id, forKey: .id)
                try c.encode(name, forKey: .name)
            case .toolInputDelta(let index, let text):
                try c.encode("toolInputDelta", forKey: .type)
                try c.encode(index, forKey: .index)
                try c.encode(text, forKey: .text)
            case .toolCall(let index, let id, let name, let input):
                try c.encode("toolCall", forKey: .type)
                try c.encode(index, forKey: .index)
                try c.encode(id, forKey: .id)
                try c.encode(name, forKey: .name)
                try c.encode(input, forKey: .input)
            case .raw(let chunk):
                try c.encode("raw", forKey: .type)
                try c.encode(chunk, forKey: .chunk)
            }
        }

        fileprivate static func decode(from value: JSONValue) throws(SimulationDecodeError) -> Item {
            let obj = try jsonObject(value, context: "Backend.Item")
            let kind = try jsonString(obj, key: "type")
            switch kind {
            case "textDelta":
                return .textDelta(text: try jsonString(obj, key: "text"))
            case "reasoningDelta":
                return .reasoningDelta(text: try jsonString(obj, key: "text"))
            case "toolInputStart":
                return .toolInputStart(
                    index: try jsonDouble(obj, key: "index"),
                    id: try jsonString(obj, key: "id"),
                    name: try jsonString(obj, key: "name")
                )
            case "toolInputDelta":
                return .toolInputDelta(
                    index: try jsonDouble(obj, key: "index"),
                    text: try jsonString(obj, key: "text")
                )
            case "toolCall":
                guard let input = obj["input"] else { throw SimulationDecodeError("Missing input in toolCall") }
                return .toolCall(
                    index: try jsonDouble(obj, key: "index"),
                    id: try jsonString(obj, key: "id"),
                    name: try jsonString(obj, key: "name"),
                    input: input
                )
            case "raw":
                guard let chunk = obj["chunk"] else { throw SimulationDecodeError("Missing chunk in raw item") }
                return .raw(chunk: chunk)
            default:
                throw SimulationDecodeError("Unknown Backend.Item type '\(kind)'")
            }
        }
    }

    // parity: protocol/src/simulation.ts#Backend.FinishReason [status=implemented hash=0d68abe8675b]
    public enum FinishReason: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
        case stop
        case toolCalls = "tool-calls"
        case length
        case contentFilter = "content-filter"
    }

    // parity: protocol/src/simulation.ts#Backend.ToolContent [status=implemented hash=dbd1ff45dcc2]
    public enum ToolContent: Equatable, Hashable, Sendable, Codable {
        case text(text: String)
        case file(data: String, mime: String, name: String? = nil)

        private enum CodingKeys: String, CodingKey {
            case type, text, data, mime, name
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let kind = try c.decode(String.self, forKey: .type)
            switch kind {
            case "text":
                self = .text(text: try c.decode(String.self, forKey: .text))
            case "file":
                let data = try c.decode(String.self, forKey: .data)
                let mime = try c.decode(String.self, forKey: .mime)
                guard !mime.isEmpty else {
                    throw DecodingError.dataCorruptedError(forKey: .mime, in: c, debugDescription: "ToolContent.file.mime must be non-empty")
                }
                self = .file(data: data, mime: mime, name: try c.decodeIfPresent(String.self, forKey: .name))
            default:
                throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown ToolContent type '\(kind)'")
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let text):
                try c.encode("text", forKey: .type)
                try c.encode(text, forKey: .text)
            case .file(let data, let mime, let name):
                try c.encode("file", forKey: .type)
                try c.encode(data, forKey: .data)
                try c.encode(mime, forKey: .mime)
                try c.encodeIfPresent(name, forKey: .name)
            }
        }

        fileprivate static func decode(from value: JSONValue) throws(SimulationDecodeError) -> ToolContent {
            let obj = try jsonObject(value, context: "Backend.ToolContent")
            let kind = try jsonString(obj, key: "type")
            switch kind {
            case "text":
                return .text(text: try jsonString(obj, key: "text"))
            case "file":
                let mime = try jsonString(obj, key: "mime")
                guard !mime.isEmpty else { throw SimulationDecodeError("ToolContent.file.mime must be non-empty") }
                return .file(
                    data: try jsonString(obj, key: "data"),
                    mime: mime,
                    name: try jsonOptionalString(obj, key: "name")
                )
            default:
                throw SimulationDecodeError("Unknown ToolContent type '\(kind)'")
            }
        }
    }

    // parity: protocol/src/simulation.ts#Backend.ToolRegistration [status=implemented hash=eec73fe714d6]
    public struct ToolRegistration: Equatable, Hashable, Sendable, Codable {
        public struct Options: Equatable, Hashable, Sendable, Codable {
            public let namespace: String?
            public let codemode: Bool?

            public init(namespace: String? = nil, codemode: Bool? = nil) {
                self.namespace = namespace
                self.codemode = codemode
            }

            public func validate() throws(SimulationDecodeError) {
                if let namespace, !isValidToolNamespace(namespace) {
                    throw SimulationDecodeError("simulated tool namespaces must contain provider-safe segments")
                }
            }
        }

        public let name: String
        public let description: String
        public let inputSchema: [String: JSONValue]
        public let outputSchema: [String: JSONValue]?
        public let permission: String?
        public let options: Options?

        public init(
            name: String,
            description: String,
            inputSchema: [String: JSONValue],
            outputSchema: [String: JSONValue]? = nil,
            permission: String? = nil,
            options: Options? = nil
        ) {
            self.name = name
            self.description = description
            self.inputSchema = inputSchema
            self.outputSchema = outputSchema
            self.permission = permission
            self.options = options
        }

        public func validate() throws(SimulationDecodeError) {
            guard isProviderSafeName(name) else {
                throw SimulationDecodeError("simulated tool names must be provider-safe")
            }
            if let permission, permission.isEmpty {
                throw SimulationDecodeError("simulated tool permission must be non-empty")
            }
            try options?.validate()
        }

        private enum CodingKeys: String, CodingKey {
            case name, description, inputSchema, outputSchema, permission, options
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.name = try c.decode(String.self, forKey: .name)
            self.description = try c.decode(String.self, forKey: .description)
            self.inputSchema = try c.decode([String: JSONValue].self, forKey: .inputSchema)
            self.outputSchema = try c.decodeIfPresent([String: JSONValue].self, forKey: .outputSchema)
            self.permission = try c.decodeIfPresent(String.self, forKey: .permission)
            self.options = try c.decodeIfPresent(Options.self, forKey: .options)
            do {
                try validate()
            } catch {
                throw DecodingError.dataCorruptedError(forKey: .name, in: c, debugDescription: error.message)
            }
        }

        fileprivate static func decode(from value: JSONValue) throws(SimulationDecodeError) -> ToolRegistration {
            let obj = try jsonObject(value, context: "Backend.ToolRegistration")
            guard let rawIn = obj["inputSchema"] else { throw SimulationDecodeError("Missing inputSchema") }
            let inputSchema = try jsonObject(rawIn, context: "ToolRegistration.inputSchema")
            let outputSchema: [String: JSONValue]? = if let rawOut = obj["outputSchema"] {
                try jsonObject(rawOut, context: "ToolRegistration.outputSchema")
            } else { nil }
            let options: Options?
            if let rawOpts = obj["options"] {
                let o = try jsonObject(rawOpts, context: "ToolRegistration.options")
                options = Options(
                    namespace: try jsonOptionalString(o, key: "namespace"),
                    codemode: try jsonOptionalBool(o, key: "codemode")
                )
            } else {
                options = nil
            }
            let reg = ToolRegistration(
                name: try jsonString(obj, key: "name"),
                description: try jsonString(obj, key: "description"),
                inputSchema: inputSchema,
                outputSchema: outputSchema,
                permission: try jsonOptionalString(obj, key: "permission"),
                options: options
            )
            try reg.validate()
            return reg
        }
    }

    // parity: protocol/src/simulation.ts#Backend.ToolAttachParams [status=implemented hash=8626b1818760]
    public struct ToolAttachParams: Equatable, Hashable, Sendable, Codable {
        public let tools: [ToolRegistration]

        public init(tools: [ToolRegistration]) throws(SimulationDecodeError) {
            self.tools = tools
            try Self.validateTools(tools)
        }

        public static func validateTools(_ tools: [ToolRegistration]) throws(SimulationDecodeError) {
            for tool in tools {
                try tool.validate()
            }
            let names = tools.map(Backend.exposedToolName)
            if names.contains(where: { !isProviderSafeName($0) }) {
                throw SimulationDecodeError("simulated tool names including namespaces must be provider-safe")
            }
            if Set(names).count != names.count {
                throw SimulationDecodeError("simulated tool registrations must have unique exposed names")
            }
            if tools.contains(where: { $0.name == "execute" && $0.options?.namespace == nil && $0.options?.codemode == false }) {
                throw SimulationDecodeError("direct simulated tool name \"execute\" is reserved")
            }
        }

        private enum CodingKeys: String, CodingKey {
            case tools
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let tools = try c.decode([ToolRegistration].self, forKey: .tools)
            do {
                try Self.validateTools(tools)
            } catch {
                throw DecodingError.dataCorruptedError(forKey: .tools, in: c, debugDescription: error.message)
            }
            self.tools = tools
        }

        fileprivate static func decode(from value: JSONValue) throws(SimulationDecodeError) -> ToolAttachParams {
            let obj = try jsonObject(value, context: "Backend.ToolAttachParams")
            let rawTools = try jsonArray(obj, key: "tools")
            var tools: [ToolRegistration] = []
            for item in rawTools {
                tools.append(try ToolRegistration.decode(from: item))
            }
            return try ToolAttachParams(tools: tools)
        }
    }

    /// Computes the provider-exposed tool name from a `ToolRegistration`, flattening namespace dots to underscores.
    // parity: protocol/src/simulation.ts#Backend.exposedToolName [status=implemented hash=1330320abbac]
    public static func exposedToolName(_ registration: ToolRegistration) -> String {
        guard let namespace = registration.options?.namespace else {
            return registration.name
        }
        let flattened = String(namespace.map { $0 == "." ? "_" : $0 })
        return "\(flattened)_\(registration.name)"
    }

    // parity: protocol/src/simulation.ts#Backend.ToolProgress [status=implemented hash=1d2b4a3508ac]
    public typealias ToolProgress = [String: JSONValue]

    // parity: protocol/src/simulation.ts#Backend.ToolOutput [status=implemented hash=d25df442d95f]
    public struct ToolOutput: Equatable, Hashable, Sendable, Codable {
        public let structured: JSONValue
        public let content: [ToolContent]

        public init(structured: JSONValue, content: [ToolContent]) {
            self.structured = structured
            self.content = content
        }

        fileprivate static func decode(from value: JSONValue) throws(SimulationDecodeError) -> ToolOutput {
            let obj = try jsonObject(value, context: "Backend.ToolOutput")
            guard let structured = obj["structured"] else { throw SimulationDecodeError("Missing structured in ToolOutput") }
            let rawContent = try jsonArray(obj, key: "content")
            var content: [ToolContent] = []
            for item in rawContent {
                content.append(try ToolContent.decode(from: item))
            }
            return ToolOutput(structured: structured, content: content)
        }
    }

    // parity: protocol/src/simulation.ts#Backend.ToolUpdateParams [status=implemented hash=96b10cee61e5]
    public struct ToolUpdateParams: Equatable, Hashable, Sendable, Codable {
        public let id: String
        public let sequence: Int
        public let update: ToolProgress

        public init(id: String, sequence: Int, update: ToolProgress) {
            self.id = id
            self.sequence = sequence
            self.update = update
        }

        private enum CodingKeys: String, CodingKey {
            case id, sequence, update
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try c.decode(String.self, forKey: .id)
            let seq = try c.decode(Int.self, forKey: .sequence)
            guard seq >= 0 else {
                throw DecodingError.dataCorruptedError(forKey: .sequence, in: c, debugDescription: "sequence must be >= 0")
            }
            self.sequence = seq
            self.update = try c.decode(ToolProgress.self, forKey: .update)
        }

        fileprivate static func decode(from value: JSONValue) throws(SimulationDecodeError) -> ToolUpdateParams {
            let obj = try jsonObject(value, context: "Backend.ToolUpdateParams")
            let seq = try jsonInt(obj, key: "sequence")
            guard seq >= 0 else { throw SimulationDecodeError("ToolUpdateParams.sequence must be >= 0") }
            guard let rawUpdate = obj["update"] else { throw SimulationDecodeError("Missing update in ToolUpdateParams") }
            let update = try jsonObject(rawUpdate, context: "Backend.ToolProgress")
            return ToolUpdateParams(id: try jsonString(obj, key: "id"), sequence: seq, update: update)
        }
    }

    // parity: protocol/src/simulation.ts#Backend.ToolFinishParams [status=implemented hash=295b2e2a0e12]
    public struct ToolFinishParams: Equatable, Hashable, Sendable, Codable {
        public let id: String
        public let output: ToolOutput

        public init(id: String, output: ToolOutput) {
            self.id = id
            self.output = output
        }

        fileprivate static func decode(from value: JSONValue) throws(SimulationDecodeError) -> ToolFinishParams {
            let obj = try jsonObject(value, context: "Backend.ToolFinishParams")
            guard let rawOut = obj["output"] else { throw SimulationDecodeError("Missing output in ToolFinishParams") }
            return ToolFinishParams(id: try jsonString(obj, key: "id"), output: try ToolOutput.decode(from: rawOut))
        }
    }

    // parity: protocol/src/simulation.ts#Backend.ToolFailParams [status=implemented hash=b0656c76c43f]
    public struct ToolFailParams: Equatable, Hashable, Sendable, Codable {
        public let id: String
        public let message: String

        public init(id: String, message: String) {
            self.id = id
            self.message = message
        }

        fileprivate static func decode(from value: JSONValue) throws(SimulationDecodeError) -> ToolFailParams {
            let obj = try jsonObject(value, context: "Backend.ToolFailParams")
            return ToolFailParams(id: try jsonString(obj, key: "id"), message: try jsonString(obj, key: "message"))
        }
    }

    // parity: protocol/src/simulation.ts#Backend.ToolInvocation [status=implemented hash=77ed2af6e973]
    public struct ToolInvocation: Equatable, Hashable, Sendable, Codable {
        public struct Context: Equatable, Hashable, Sendable, Codable {
            public let sessionID: String
            public let agent: String
            public let messageID: String
            public let id: String

            public init(sessionID: String, agent: String, messageID: String, id: String) {
                self.sessionID = sessionID
                self.agent = agent
                self.messageID = messageID
                self.id = id
            }
        }

        public let id: String
        public let name: String
        public let input: JSONValue
        public let context: Context

        public init(id: String, name: String, input: JSONValue, context: Context) {
            self.id = id
            self.name = name
            self.input = input
            self.context = context
        }

        fileprivate static func decode(from value: JSONValue) throws(SimulationDecodeError) -> ToolInvocation {
            let obj = try jsonObject(value, context: "Backend.ToolInvocation")
            guard let input = obj["input"] else { throw SimulationDecodeError("Missing input in ToolInvocation") }
            guard let rawCtx = obj["context"] else { throw SimulationDecodeError("Missing context in ToolInvocation") }
            let ctxObj = try jsonObject(rawCtx, context: "ToolInvocation.Context")
            return ToolInvocation(
                id: try jsonString(obj, key: "id"),
                name: try jsonString(obj, key: "name"),
                input: input,
                context: Context(
                    sessionID: try jsonString(ctxObj, key: "sessionID"),
                    agent: try jsonString(ctxObj, key: "agent"),
                    messageID: try jsonString(ctxObj, key: "messageID"),
                    id: try jsonString(ctxObj, key: "id")
                )
            )
        }
    }

    // parity: protocol/src/simulation.ts#Backend.ToolCancellation [status=implemented hash=bd962a6b5158]
    public struct ToolCancellation: Equatable, Hashable, Sendable, Codable {
        public let id: String
        public let reason: String

        public init(id: String) {
            self.id = id
            self.reason = "interrupted"
        }

        private enum CodingKeys: String, CodingKey {
            case id, reason
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try c.decode(String.self, forKey: .id)
            let reason = try c.decode(String.self, forKey: .reason)
            guard reason == "interrupted" else {
                throw DecodingError.dataCorruptedError(forKey: .reason, in: c, debugDescription: "Expected reason 'interrupted'")
            }
            self.reason = reason
        }

        fileprivate static func decode(from value: JSONValue) throws(SimulationDecodeError) -> ToolCancellation {
            let obj = try jsonObject(value, context: "Backend.ToolCancellation")
            let reason = try jsonString(obj, key: "reason")
            guard reason == "interrupted" else {
                throw SimulationDecodeError("Expected ToolCancellation.reason 'interrupted', got '\(reason)'")
            }
            return ToolCancellation(id: try jsonString(obj, key: "id"))
        }
    }

    // parity: protocol/src/simulation.ts#Backend.Attached [status=implemented hash=cc2722d08d20]
    public struct Attached: Equatable, Hashable, Sendable, Codable {
        public let attached: Bool

        public init() {
            self.attached = true
        }

        private enum CodingKeys: String, CodingKey {
            case attached
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let value = try c.decode(Bool.self, forKey: .attached)
            guard value else {
                throw DecodingError.dataCorruptedError(forKey: .attached, in: c, debugDescription: "Expected attached == true")
            }
            self.attached = true
        }
    }

    // parity: protocol/src/simulation.ts#Backend.Ok [status=implemented hash=18cabae893de]
    public struct Ok: Equatable, Hashable, Sendable, Codable {
        public let ok: Bool

        public init() {
            self.ok = true
        }

        private enum CodingKeys: String, CodingKey {
            case ok
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let value = try c.decode(Bool.self, forKey: .ok)
            guard value else {
                throw DecodingError.dataCorruptedError(forKey: .ok, in: c, debugDescription: "Expected ok == true")
            }
            self.ok = true
        }
    }

    // parity: protocol/src/simulation.ts#Backend.ChunkParams [status=implemented hash=37443968e9a7]
    public struct ChunkParams: Equatable, Hashable, Sendable, Codable {
        public let id: String
        public let items: [Item]

        public init(id: String, items: [Item]) {
            self.id = id
            self.items = items
        }

        fileprivate static func decode(from value: JSONValue) throws(SimulationDecodeError) -> ChunkParams {
            let obj = try jsonObject(value, context: "Backend.ChunkParams")
            let rawItems = try jsonArray(obj, key: "items")
            var items: [Item] = []
            for item in rawItems {
                items.append(try Item.decode(from: item))
            }
            return ChunkParams(id: try jsonString(obj, key: "id"), items: items)
        }
    }

    // parity: protocol/src/simulation.ts#Backend.FinishParams [status=implemented hash=f07731eca95f]
    public struct FinishParams: Equatable, Hashable, Sendable, Codable {
        public let id: String
        public let reason: FinishReason

        public init(id: String, reason: FinishReason = .stop) {
            self.id = id
            self.reason = reason
        }

        private enum CodingKeys: String, CodingKey {
            case id, reason
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try c.decode(String.self, forKey: .id)
            self.reason = try c.decodeIfPresent(FinishReason.self, forKey: .reason) ?? .stop
        }

        fileprivate static func decode(from value: JSONValue) throws(SimulationDecodeError) -> FinishParams {
            let obj = try jsonObject(value, context: "Backend.FinishParams")
            let reason: FinishReason
            if let r = try jsonOptionalString(obj, key: "reason") {
                guard let parsed = FinishReason(rawValue: r) else {
                    throw SimulationDecodeError("Invalid FinishReason '\(r)'")
                }
                reason = parsed
            } else {
                reason = .stop
            }
            return FinishParams(id: try jsonString(obj, key: "id"), reason: reason)
        }
    }

    // parity: protocol/src/simulation.ts#Backend.FinishPayload [status=implemented hash=e8421f873de1]
    public struct FinishPayload: Equatable, Hashable, Sendable, Codable {
        public let id: String
        public let reason: FinishReason?

        public init(id: String, reason: FinishReason? = nil) {
            self.id = id
            self.reason = reason
        }
    }

    // parity: protocol/src/simulation.ts#Backend.DisconnectParams [status=implemented hash=be3b46682ded]
    public struct DisconnectParams: Equatable, Hashable, Sendable, Codable {
        public let id: String

        public init(id: String) {
            self.id = id
        }

        fileprivate static func decode(from value: JSONValue) throws(SimulationDecodeError) -> DisconnectParams {
            let obj = try jsonObject(value, context: "Backend.DisconnectParams")
            return DisconnectParams(id: try jsonString(obj, key: "id"))
        }
    }

    // parity: protocol/src/simulation.ts#Backend.Request [status=implemented hash=29828459dbe5]
    public enum Request: Equatable, Hashable, Sendable, Codable {
        case handshake(Handshake.Request)
        case llmChunk(id: JsonRpc.ID?, params: ChunkParams)
        case llmFinish(id: JsonRpc.ID?, params: FinishParams)
        case llmDisconnect(id: JsonRpc.ID?, params: DisconnectParams)
        case toolAttach(id: JsonRpc.ID?, params: ToolAttachParams)
        case toolUpdate(id: JsonRpc.ID?, params: ToolUpdateParams)
        case toolFinish(id: JsonRpc.ID?, params: ToolFinishParams)
        case toolFail(id: JsonRpc.ID?, params: ToolFailParams)
        case llmAttach(id: JsonRpc.ID?)
        case llmPending(id: JsonRpc.ID?)

        private enum CodingKeys: String, CodingKey {
            case jsonrpc, id, method, params
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let version = try c.decode(String.self, forKey: .jsonrpc)
            guard version == "2.0" else {
                throw DecodingError.dataCorruptedError(forKey: .jsonrpc, in: c, debugDescription: "Expected jsonrpc '2.0'")
            }
            let id = c.contains(.id) ? try c.decode(JsonRpc.ID.self, forKey: .id) : nil
            let method = try c.decode(String.self, forKey: .method)
            switch method {
            case "simulation.handshake":
                self = .handshake(try Handshake.Request(from: decoder))
            case "llm.chunk":
                self = .llmChunk(id: id, params: try c.decode(ChunkParams.self, forKey: .params))
            case "llm.finish":
                self = .llmFinish(id: id, params: try c.decode(FinishParams.self, forKey: .params))
            case "llm.disconnect":
                self = .llmDisconnect(id: id, params: try c.decode(DisconnectParams.self, forKey: .params))
            case "tool.attach":
                self = .toolAttach(id: id, params: try c.decode(ToolAttachParams.self, forKey: .params))
            case "tool.update":
                self = .toolUpdate(id: id, params: try c.decode(ToolUpdateParams.self, forKey: .params))
            case "tool.finish":
                self = .toolFinish(id: id, params: try c.decode(ToolFinishParams.self, forKey: .params))
            case "tool.fail":
                self = .toolFail(id: id, params: try c.decode(ToolFailParams.self, forKey: .params))
            case "llm.attach":
                self = .llmAttach(id: id)
            case "llm.pending":
                self = .llmPending(id: id)
            default:
                throw DecodingError.dataCorruptedError(forKey: .method, in: c, debugDescription: "Unknown Backend.Request method '\(method)'")
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .handshake(let req):
                try req.encode(to: encoder)
            case .llmChunk(let id, let params):
                try c.encode("2.0", forKey: .jsonrpc)
                if let id { try c.encode(id, forKey: .id) }
                try c.encode("llm.chunk", forKey: .method)
                try c.encode(params, forKey: .params)
            case .llmFinish(let id, let params):
                try c.encode("2.0", forKey: .jsonrpc)
                if let id { try c.encode(id, forKey: .id) }
                try c.encode("llm.finish", forKey: .method)
                try c.encode(params, forKey: .params)
            case .llmDisconnect(let id, let params):
                try c.encode("2.0", forKey: .jsonrpc)
                if let id { try c.encode(id, forKey: .id) }
                try c.encode("llm.disconnect", forKey: .method)
                try c.encode(params, forKey: .params)
            case .toolAttach(let id, let params):
                try c.encode("2.0", forKey: .jsonrpc)
                if let id { try c.encode(id, forKey: .id) }
                try c.encode("tool.attach", forKey: .method)
                try c.encode(params, forKey: .params)
            case .toolUpdate(let id, let params):
                try c.encode("2.0", forKey: .jsonrpc)
                if let id { try c.encode(id, forKey: .id) }
                try c.encode("tool.update", forKey: .method)
                try c.encode(params, forKey: .params)
            case .toolFinish(let id, let params):
                try c.encode("2.0", forKey: .jsonrpc)
                if let id { try c.encode(id, forKey: .id) }
                try c.encode("tool.finish", forKey: .method)
                try c.encode(params, forKey: .params)
            case .toolFail(let id, let params):
                try c.encode("2.0", forKey: .jsonrpc)
                if let id { try c.encode(id, forKey: .id) }
                try c.encode("tool.fail", forKey: .method)
                try c.encode(params, forKey: .params)
            case .llmAttach(let id):
                try c.encode("2.0", forKey: .jsonrpc)
                if let id { try c.encode(id, forKey: .id) }
                try c.encode("llm.attach", forKey: .method)
            case .llmPending(let id):
                try c.encode("2.0", forKey: .jsonrpc)
                if let id { try c.encode(id, forKey: .id) }
                try c.encode("llm.pending", forKey: .method)
            }
        }
    }

    // parity: protocol/src/simulation.ts#Backend.decodeRequest [status=implemented hash=d24bf14efa58]
    public static func decodeRequest(_ value: JSONValue) throws(SimulationDecodeError) -> Request {
        let obj = try jsonObject(value, context: "Backend.Request")
        let fields = try JsonRpc.RequestFields.decode(from: obj)
        let method = try jsonString(obj, key: "method")
        switch method {
        case "simulation.handshake":
            return .handshake(try Handshake.Request.decode(from: obj))
        case "llm.chunk":
            guard let raw = obj["params"] else { throw SimulationDecodeError("Missing params for llm.chunk") }
            return .llmChunk(id: fields.id, params: try ChunkParams.decode(from: raw))
        case "llm.finish":
            guard let raw = obj["params"] else { throw SimulationDecodeError("Missing params for llm.finish") }
            return .llmFinish(id: fields.id, params: try FinishParams.decode(from: raw))
        case "llm.disconnect":
            guard let raw = obj["params"] else { throw SimulationDecodeError("Missing params for llm.disconnect") }
            return .llmDisconnect(id: fields.id, params: try DisconnectParams.decode(from: raw))
        case "tool.attach":
            guard let raw = obj["params"] else { throw SimulationDecodeError("Missing params for tool.attach") }
            return .toolAttach(id: fields.id, params: try ToolAttachParams.decode(from: raw))
        case "tool.update":
            guard let raw = obj["params"] else { throw SimulationDecodeError("Missing params for tool.update") }
            return .toolUpdate(id: fields.id, params: try ToolUpdateParams.decode(from: raw))
        case "tool.finish":
            guard let raw = obj["params"] else { throw SimulationDecodeError("Missing params for tool.finish") }
            return .toolFinish(id: fields.id, params: try ToolFinishParams.decode(from: raw))
        case "tool.fail":
            guard let raw = obj["params"] else { throw SimulationDecodeError("Missing params for tool.fail") }
            return .toolFail(id: fields.id, params: try ToolFailParams.decode(from: raw))
        case "llm.attach":
            return .llmAttach(id: fields.id)
        case "llm.pending":
            return .llmPending(id: fields.id)
        default:
            throw SimulationDecodeError("Unknown Backend.Request method '\(method)'")
        }
    }

    // parity: protocol/src/simulation.ts#Backend.decodeRequestEffect [status=implemented hash=5dca76898ab8]
    public static func decodeRequestEffect(_ jsonString: String) throws(SimulationDecodeError) -> Request {
        let value = try parseJSONString(jsonString)
        return try decodeRequest(value)
    }

    // parity: protocol/src/simulation.ts#Backend.ProviderInvocation [status=implemented hash=b26912dbccfc]
    public struct ProviderInvocation: Equatable, Hashable, Sendable, Codable {
        public let id: String
        public let url: String
        public let body: JSONValue

        public init(id: String, url: String, body: JSONValue) {
            self.id = id
            self.url = url
            self.body = body
        }

        fileprivate static func decode(from value: JSONValue) throws(SimulationDecodeError) -> ProviderInvocation {
            let obj = try jsonObject(value, context: "Backend.ProviderInvocation")
            guard let body = obj["body"] else { throw SimulationDecodeError("Missing body in ProviderInvocation") }
            return ProviderInvocation(
                id: try jsonString(obj, key: "id"),
                url: try jsonString(obj, key: "url"),
                body: body
            )
        }
    }

    // parity: protocol/src/simulation.ts#Backend.Pending [status=implemented hash=d4ea26fa8bda]
    public struct Pending: Equatable, Hashable, Sendable, Codable {
        public let invocations: [ProviderInvocation]

        public init(invocations: [ProviderInvocation]) {
            self.invocations = invocations
        }
    }

    // parity: protocol/src/simulation.ts#Backend.NetworkLogEntry [status=implemented hash=bf9ebfeecf2e]
    public struct NetworkLogEntry: Equatable, Hashable, Sendable, Codable {
        public let time: Double
        public let method: String
        public let url: String
        public let matched: Bool

        public init(time: Double, method: String, url: String, matched: Bool) {
            self.time = time
            self.method = method
            self.url = url
            self.matched = matched
        }
    }

    // parity: protocol/src/simulation.ts#Backend.Notification [status=implemented hash=f5649aa78899]
    public enum Notification: Equatable, Hashable, Sendable, Codable {
        case llmRequest(ProviderInvocation)
        case toolInvocation(ToolInvocation)
        case toolCancel(ToolCancellation)

        private enum CodingKeys: String, CodingKey {
            case jsonrpc, method, params
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let version = try c.decode(String.self, forKey: .jsonrpc)
            guard version == "2.0" else {
                throw DecodingError.dataCorruptedError(forKey: .jsonrpc, in: c, debugDescription: "Expected jsonrpc '2.0'")
            }
            let method = try c.decode(String.self, forKey: .method)
            switch method {
            case "llm.request":
                self = .llmRequest(try c.decode(ProviderInvocation.self, forKey: .params))
            case "tool.invocation":
                self = .toolInvocation(try c.decode(ToolInvocation.self, forKey: .params))
            case "tool.cancel":
                self = .toolCancel(try c.decode(ToolCancellation.self, forKey: .params))
            default:
                throw DecodingError.dataCorruptedError(forKey: .method, in: c, debugDescription: "Unknown Backend.Notification method '\(method)'")
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("2.0", forKey: .jsonrpc)
            switch self {
            case .llmRequest(let params):
                try c.encode("llm.request", forKey: .method)
                try c.encode(params, forKey: .params)
            case .toolInvocation(let params):
                try c.encode("tool.invocation", forKey: .method)
                try c.encode(params, forKey: .params)
            case .toolCancel(let params):
                try c.encode("tool.cancel", forKey: .method)
                try c.encode(params, forKey: .params)
            }
        }
    }

    // parity: protocol/src/simulation.ts#Backend.decodeNotification [status=implemented hash=4255133df26e]
    public static func decodeNotification(_ value: JSONValue) throws(SimulationDecodeError) -> Notification {
        let obj = try jsonObject(value, context: "Backend.Notification")
        let version = try jsonString(obj, key: "jsonrpc")
        guard version == "2.0" else {
            throw SimulationDecodeError("Expected jsonrpc '2.0', got '\(version)'")
        }
        let method = try jsonString(obj, key: "method")
        guard let rawParams = obj["params"] else {
            throw SimulationDecodeError("Missing params for notification '\(method)'")
        }
        switch method {
        case "llm.request":
            return .llmRequest(try ProviderInvocation.decode(from: rawParams))
        case "tool.invocation":
            return .toolInvocation(try ToolInvocation.decode(from: rawParams))
        case "tool.cancel":
            return .toolCancel(try ToolCancellation.decode(from: rawParams))
        default:
            throw SimulationDecodeError("Unknown Backend.Notification method '\(method)'")
        }
    }

    // parity: protocol/src/simulation.ts#Backend.decodeNotificationEffect [status=implemented hash=5de2a2b193c8]
    public static func decodeNotificationEffect(_ jsonString: String) throws(SimulationDecodeError) -> Notification {
        let value = try parseJSONString(jsonString)
        return try decodeNotification(value)
    }
}

// MARK: - Simulation RPC Group Descriptors

/// Declarative descriptor for one RPC method in a simulation `RpcGroup`.
public struct SimulationRpcDescriptor: Equatable, Hashable, Sendable, Codable {
    public let tag: String
    public let payloadType: String?
    public let successType: String
    public let errorType: String

    public init(
        tag: String,
        payloadType: String? = nil,
        successType: String,
        errorType: String = SimulationRequestError.tag
    ) {
        self.tag = tag
        self.payloadType = payloadType
        self.successType = successType
        self.errorType = errorType
    }
}

/// Declarative group of simulation RPC methods mirroring Effect's `RpcGroup.make(...)`.
public struct SimulationRpcGroupDescriptor: Equatable, Hashable, Sendable, Codable {
    public let name: String
    public let methods: [SimulationRpcDescriptor]

    public init(name: String, methods: [SimulationRpcDescriptor]) {
        self.name = name
        self.methods = methods
    }

    public func method(tag: String) -> SimulationRpcDescriptor? {
        methods.first { $0.tag == tag }
    }
}

// parity: protocol/src/simulation.ts#UiRpcs [status=implemented hash=bee9b3f8d910]
public let UiRpcs = SimulationRpcGroupDescriptor(
    name: "UiRpcs",
    methods: [
        SimulationRpcDescriptor(tag: "simulation.handshake", payloadType: "Handshake.Params", successType: "Handshake.Response"),
        SimulationRpcDescriptor(tag: "ui.state", successType: "Frontend.State"),
        SimulationRpcDescriptor(tag: "ui.snapshot", successType: "Frontend.SemanticSnapshot"),
        SimulationRpcDescriptor(tag: "ui.capture", successType: "Frontend.CapturedFrame"),
        SimulationRpcDescriptor(tag: "ui.matches", payloadType: "Frontend.MatchesParams", successType: "Frontend.Matches"),
        SimulationRpcDescriptor(tag: "ui.recording.finish", successType: "Frontend.RecordingFinish"),
        SimulationRpcDescriptor(tag: "ui.type", payloadType: "Frontend.TypeParams", successType: "Frontend.State"),
        SimulationRpcDescriptor(tag: "ui.press", payloadType: "Frontend.PressParams", successType: "Frontend.State"),
        SimulationRpcDescriptor(tag: "ui.enter", successType: "Frontend.State"),
        SimulationRpcDescriptor(tag: "ui.arrow", payloadType: "Frontend.ArrowParams", successType: "Frontend.State"),
        SimulationRpcDescriptor(tag: "ui.focus", payloadType: "Frontend.FocusParams", successType: "Frontend.State"),
        SimulationRpcDescriptor(tag: "ui.click", payloadType: "Frontend.ClickParams", successType: "Frontend.State"),
        SimulationRpcDescriptor(tag: "ui.mouse", payloadType: "Frontend.MouseParams", successType: "Frontend.State"),
        SimulationRpcDescriptor(tag: "ui.resize", payloadType: "Frontend.ResizeParams", successType: "Frontend.State"),
    ]
)

// parity: protocol/src/simulation.ts#BackendRpcs [status=implemented hash=2417ea6d21aa]
public let BackendRpcs = SimulationRpcGroupDescriptor(
    name: "BackendRpcs",
    methods: [
        SimulationRpcDescriptor(tag: "simulation.handshake", payloadType: "Handshake.Params", successType: "Handshake.Response"),
        SimulationRpcDescriptor(tag: "llm.attach", successType: "Backend.Attached"),
        SimulationRpcDescriptor(tag: "llm.pending", successType: "Backend.Pending"),
        SimulationRpcDescriptor(tag: "llm.chunk", payloadType: "Backend.ChunkParams", successType: "Backend.Ok"),
        SimulationRpcDescriptor(tag: "llm.finish", payloadType: "Backend.FinishPayload", successType: "Backend.Ok"),
        SimulationRpcDescriptor(tag: "llm.disconnect", payloadType: "Backend.DisconnectParams", successType: "Backend.Ok"),
        SimulationRpcDescriptor(tag: "tool.attach", payloadType: "Backend.ToolAttachParams", successType: "Backend.Attached"),
        SimulationRpcDescriptor(tag: "tool.update", payloadType: "Backend.ToolUpdateParams", successType: "Backend.Ok"),
        SimulationRpcDescriptor(tag: "tool.finish", payloadType: "Backend.ToolFinishParams", successType: "Backend.Ok"),
        SimulationRpcDescriptor(tag: "tool.fail", payloadType: "Backend.ToolFailParams", successType: "Backend.Ok"),
    ]
)
