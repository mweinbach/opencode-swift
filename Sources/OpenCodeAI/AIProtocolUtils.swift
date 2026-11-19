/// Portable protocol utilities, shared wire types, SSE & AWS binary EventStream framing,
/// AWS SigV4 signing, partial JSON parsing, JSON schema normalization, image sizing,
/// lifecycle & tool-stream state machines for `OpenCodeAI`.
///
/// Ports `packages/ai/src/protocols/shared.ts`, `bedrock-event-stream.ts`,
/// and all 22 modules under `packages/ai/src/protocols/utils/*`.
///
/// Strictly PORTABLE tier: zero OS imports, all HTTP via `OpenCodePlatform.HTTPTransport`.

import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

// MARK: - AIProtocolUtils Namespace & Foundational Wire Types

public enum AIProtocolUtils {

    // MARK: Errors

    public enum ProtocolErrorKind: String, Equatable, Hashable, Sendable, Codable {
        case invalidRequest
        case invalidProviderOutput
        case unsupportedOperation
        case authentication
        case contentPolicy
        case providerInternal
        case rateLimit
        case unknownProvider
        case transport
    }

    public struct ProtocolError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public let kind: ProtocolErrorKind
        public let message: String
        public let route: String?
        public let provider: String?
        public let operation: String?
        public let statusCode: Int?
        public let body: String?
        public let classification: String?

        public init(
            kind: ProtocolErrorKind,
            message: String,
            route: String? = nil,
            provider: String? = nil,
            operation: String? = nil,
            statusCode: Int? = nil,
            body: String? = nil,
            classification: String? = nil
        ) {
            self.kind = kind
            self.message = message
            self.route = route
            self.provider = provider
            self.operation = operation
            self.statusCode = statusCode
            self.body = body
            self.classification = classification
        }

        public var description: String {
            if let route {
                return "[\(kind.rawValue):\(route)] \(message)"
            }
            return "[\(kind.rawValue)] \(message)"
        }
    }

    // MARK: Pure JSON & Crypto Helpers

    public enum JSONCodec {
        public static func toPureJSON(_ value: JSONValue) -> PureJSONValue {
            switch value {
            case .null:
                return .null
            case .bool(let b):
                return .bool(b)
            case .int(let i):
                return .number(Double(i))
            case .double(let d):
                return .number(d)
            case .string(let s):
                return .string(s)
            case .array(let items):
                return .array(items.map(toPureJSON))
            case .object(let dict):
                let sortedKeys = dict.keys.sorted()
                return .object(sortedKeys.map { ($0, toPureJSON(dict[$0]!)) })
            }
        }

        public static func fromPureJSON(_ value: PureJSONValue) -> JSONValue {
            switch value {
            case .null:
                return .null
            case .bool(let b):
                return .bool(b)
            case .number(let n):
                if n.isFinite && n.rounded(.towardZero) == n && n >= Double(Int64.min) && n <= Double(Int64.max) {
                    return .int(Int64(n))
                }
                return .double(n)
            case .string(let s):
                return .string(s)
            case .array(let items):
                return .array(items.map(fromPureJSON))
            case .object(let entries):
                var dict: [String: JSONValue] = [:]
                dict.reserveCapacity(entries.count)
                for (k, v) in entries {
                    dict[k] = fromPureJSON(v)
                }
                return .object(dict)
            }
        }

        public static func encode(_ value: JSONValue) -> String {
            PureJSON.stringifyCompact(toPureJSON(value))
        }

        public static func encodeObject(_ object: [String: JSONValue]) -> String {
            encode(.object(object))
        }

        public static func decode(_ text: String) throws(ProtocolError) -> JSONValue {
            guard let parsed = PureJSON.parse(text) else {
                throw ProtocolError(
                    kind: .invalidProviderOutput,
                    message: "Invalid JSON payload",
                    body: text
                )
            }
            return fromPureJSON(parsed)
        }

        public static func mergeObjects(_ objects: [String: JSONValue]?...) -> [String: JSONValue] {
            var merged: [String: JSONValue] = [:]
            for object in objects {
                guard let object else { continue }
                for (key, value) in object {
                    if case .object(let rhs) = value, case .object(let lhs) = merged[key] {
                        merged[key] = .object(mergeObjects(lhs, rhs))
                    } else {
                        merged[key] = value
                    }
                }
            }
            return merged
        }

        public static func stringValue(_ value: JSONValue?) -> String? {
            guard case .string(let s) = value else { return nil }
            return s
        }

        public static func intValue(_ value: JSONValue?) -> Int? {
            switch value {
            case .int(let i): return Int(i)
            case .double(let d) where d.isFinite: return Int(d)
            default: return nil
            }
        }

        public static func doubleValue(_ value: JSONValue?) -> Double? {
            switch value {
            case .double(let d) where d.isFinite: return d
            case .int(let i): return Double(i)
            default: return nil
            }
        }

        public static func boolValue(_ value: JSONValue?) -> Bool? {
            guard case .bool(let b) = value else { return nil }
            return b
        }

        public static func arrayValue(_ value: JSONValue?) -> [JSONValue]? {
            guard case .array(let a) = value else { return nil }
            return a
        }

        public static func objectValue(_ value: JSONValue?) -> [String: JSONValue]? {
            guard case .object(let o) = value else { return nil }
            return o
        }

        public static func percentEncodePathComponent(_ input: String) -> String {
            let hex: [UInt8] = Array("0123456789ABCDEF".utf8)
            var out: [UInt8] = []
            for byte in input.utf8 {
                let isUnreserved =
                    (byte >= 0x41 && byte <= 0x5A)
                    || (byte >= 0x61 && byte <= 0x7A)
                    || (byte >= 0x30 && byte <= 0x39)
                    || byte == 0x2D || byte == 0x2E || byte == 0x5F || byte == 0x7E
                if isUnreserved {
                    out.append(byte)
                } else {
                    out.append(0x25) // %
                    out.append(hex[Int(byte >> 4)])
                    out.append(hex[Int(byte & 0x0F)])
                }
            }
            return String(decoding: out, as: UTF8.self)
        }

        public static func hexToBytes(_ hex: String) -> [UInt8] {
            let utf8 = Array(hex.utf8)
            var out: [UInt8] = []
            out.reserveCapacity(utf8.count / 2)
            var i = 0
            while i + 1 < utf8.count {
                let hi = hexNibble(utf8[i])
                let lo = hexNibble(utf8[i + 1])
                out.append((hi << 4) | lo)
                i += 2
            }
            return out
        }

        public static func bytesToHex(_ bytes: [UInt8]) -> String {
            let digits: [UInt8] = Array("0123456789abcdef".utf8)
            var out: [UInt8] = []
            out.reserveCapacity(bytes.count * 2)
            for byte in bytes {
                out.append(digits[Int(byte >> 4)])
                out.append(digits[Int(byte & 0x0F)])
            }
            return String(decoding: out, as: UTF8.self)
        }

        private static func hexNibble(_ c: UInt8) -> UInt8 {
            if c >= 0x30 && c <= 0x39 { return c - 0x30 }
            if c >= 0x61 && c <= 0x66 { return c - 0x61 + 10 }
            if c >= 0x41 && c <= 0x46 { return c - 0x41 + 10 }
            return 0
        }

        /// Pure-Swift SHA-256 raw digest (32 bytes) using `OpenCodeUtil.Hash.sha256`.
        public static func sha256Bytes(_ input: [UInt8]) -> [UInt8] {
            hexToBytes(Hash.sha256(input))
        }

        /// Pure-Swift RFC 2104 HMAC-SHA256 returning 32 raw bytes.
        public static func hmacSHA256(key: [UInt8], message: [UInt8]) -> [UInt8] {
            let blockSize = 64
            var k = key.count > blockSize ? sha256Bytes(key) : key
            if k.count < blockSize {
                k.append(contentsOf: repeatElement(UInt8(0), count: blockSize - k.count))
            }
            var inner = [UInt8](repeating: 0, count: blockSize + message.count)
            var outer = [UInt8](repeating: 0, count: blockSize + 32)
            for i in 0..<blockSize {
                inner[i] = k[i] ^ 0x36
                outer[i] = k[i] ^ 0x5C
            }
            for i in 0..<message.count {
                inner[blockSize + i] = message[i]
            }
            let innerHash = sha256Bytes(inner)
            for i in 0..<32 {
                outer[blockSize + i] = innerHash[i]
            }
            return sha256Bytes(outer)
        }
    }

    // MARK: Pure-Swift IEEE 754 Natural Log (Zero C-Lib Imports)

    static func naturalLog(_ x: Double) -> Double {
        guard x > 0 else { return x == 0 ? -.infinity : .nan }
        let exp = x.exponent
        let m = x.significand
        // Scale m into [sqrt(0.5), sqrt(2)] for rapid convergence of artanh series.
        var mantissa = m
        var exponent = exp
        if mantissa > 1.4142135623730951 {
            mantissa *= 0.5
            exponent += 1
        }
        let u = (mantissa - 1.0) / (mantissa + 1.0)
        let u2 = u * u
        var term = u
        var sum = u
        var k = 3.0
        for _ in 0..<14 {
            term *= u2
            sum += term / k
            k += 2.0
        }
        return 2.0 * sum + Double(exponent) * 0.6931471805599453
    }

    static func logBase2(_ x: Double) -> Double {
        naturalLog(x) / 0.6931471805599453
    }

    // MARK: Media Types & Assets

    public enum MediaKind: String, Equatable, Hashable, Sendable, Codable {
        case image
        case audio
        case video
        case document
        case other
    }

    public enum MediaSource: Equatable, Hashable, Sendable {
        case bytes([UInt8])
        case base64(String)
        case url(String)
        case ref(provider: String, id: String)

        public var typeName: String {
            switch self {
            case .bytes: return "bytes"
            case .base64: return "base64"
            case .url: return "url"
            case .ref: return "ref"
            }
        }
    }

    public struct InlineMedia: Equatable, Hashable, Sendable {
        public let mime: String
        public let base64: String

        public init(mime: String, base64: String) {
            self.mime = mime
            self.base64 = base64
        }

        public var dataUrl: String {
            "data:\(mime);base64,\(base64)"
        }
    }

    public struct MediaAsset: Equatable, Hashable, Sendable {
        public let source: MediaSource
        public let mediaType: String
        public let info: [String: JSONValue]?
        public let providerMetadata: [String: [String: JSONValue]]?

        public init(
            source: MediaSource,
            mediaType: String,
            info: [String: JSONValue]? = nil,
            providerMetadata: [String: [String: JSONValue]]? = nil
        ) {
            self.source = source
            self.mediaType = mediaType
            self.info = info
            self.providerMetadata = providerMetadata
        }

        public var kind: MediaKind {
            let lower = mediaType.lowercased()
            if lower.hasPrefix("image/") { return .image }
            if lower.hasPrefix("audio/") { return .audio }
            if lower.hasPrefix("video/") { return .video }
            if lower == "application/pdf" || lower.hasPrefix("text/") { return .document }
            return .other
        }

        public func inline() -> InlineMedia? {
            switch source {
            case .bytes(let data):
                return InlineMedia(mime: mediaType, base64: bytesToBase64(data))
            case .base64(let encoded):
                return InlineMedia(mime: mediaType, base64: encoded)
            case .url, .ref:
                return nil
            }
        }

        public static func bytes(
            _ data: [UInt8],
            mediaType: String? = nil,
            info: [String: JSONValue]? = nil,
            providerMetadata: [String: [String: JSONValue]]? = nil
        ) -> MediaAsset {
            MediaAsset(
                source: .bytes(data),
                mediaType: mediaType ?? detectMediaType(data) ?? "application/octet-stream",
                info: info,
                providerMetadata: providerMetadata
            )
        }

        public static func base64(
            _ encoded: String,
            mediaType: String,
            info: [String: JSONValue]? = nil,
            providerMetadata: [String: [String: JSONValue]]? = nil
        ) -> MediaAsset {
            MediaAsset(source: .base64(encoded), mediaType: mediaType, info: info, providerMetadata: providerMetadata)
        }

        public static func url(
            _ url: String,
            mediaType: String = "application/octet-stream",
            info: [String: JSONValue]? = nil,
            providerMetadata: [String: [String: JSONValue]]? = nil
        ) -> MediaAsset {
            MediaAsset(source: .url(url), mediaType: mediaType, info: info, providerMetadata: providerMetadata)
        }

        public static func ref(provider: String, id: String, mediaType: String) -> MediaAsset {
            MediaAsset(source: .ref(provider: provider, id: id), mediaType: mediaType)
        }

        public static func parseDataUrl(_ value: String, providerMetadata: [String: [String: JSONValue]]? = nil) -> MediaAsset? {
            guard value.lowercased().hasPrefix("data:") else { return nil }
            let rest = value.dropFirst(5)
            guard let commaIndex = rest.firstIndex(of: ",") else { return nil }
            let meta = String(rest[..<commaIndex])
            let payload = String(rest[rest.index(after: commaIndex)...])
            let parts = meta.split(separator: ";").map(String.init)
            let isBase64 = parts.contains { $0.lowercased() == "base64" }
            let mime = parts.first.flatMap { $0.isEmpty || $0.lowercased() == "base64" ? nil : $0 } ?? "application/octet-stream"
            if isBase64 {
                return MediaAsset(source: .base64(payload), mediaType: mime, providerMetadata: providerMetadata)
            }
            return MediaAsset(source: .bytes(Array(payload.utf8)), mediaType: mime, providerMetadata: providerMetadata)
        }
    }

    public static func detectMediaType(_ bytes: [UInt8]) -> String? {
        if bytes.count >= 8, bytes[0] == 0x89, bytes[1] == 0x50, bytes[2] == 0x4E, bytes[3] == 0x47 {
            return "image/png"
        }
        if bytes.count >= 3, bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF {
            return "image/jpeg"
        }
        if bytes.count >= 6, bytes[0] == 0x47, bytes[1] == 0x49, bytes[2] == 0x46 {
            return "image/gif"
        }
        if bytes.count >= 12,
           bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46,
           bytes[8] == 0x57, bytes[9] == 0x45, bytes[10] == 0x42, bytes[11] == 0x50 {
            return "image/webp"
        }
        if bytes.count >= 4, bytes[0] == 0x25, bytes[1] == 0x50, bytes[2] == 0x44, bytes[3] == 0x46 {
            return "application/pdf"
        }
        if bytes.count >= 4, bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33 {
            return "audio/mpeg"
        }
        if bytes.count >= 2, bytes[0] == 0xFF, (bytes[1] & 0xE0) == 0xE0 {
            return "audio/mpeg"
        }
        if bytes.count >= 12,
           bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46,
           bytes[8] == 0x57, bytes[9] == 0x41, bytes[10] == 0x56, bytes[11] == 0x45 {
            return "audio/wav"
        }
        if bytes.count >= 4, bytes[0] == 0x4F, bytes[1] == 0x67, bytes[2] == 0x67, bytes[3] == 0x53 {
            return "audio/ogg"
        }
        if bytes.count >= 4, bytes[0] == 0x66, bytes[1] == 0x4C, bytes[2] == 0x61, bytes[3] == 0x43 {
            return "audio/flac"
        }
        return nil
    }

    public static func mediaTypeExtension(_ mediaType: String) -> String? {
        switch mediaType.lowercased().split(separator: ";").first.map(String.init) ?? "" {
        case "audio/mpeg", "audio/mp3": return "mp3"
        case "audio/mp4", "audio/m4a", "audio/x-m4a": return "m4a"
        case "video/mp4": return "mp4"
        case "audio/wav", "audio/x-wav", "audio/wave": return "wav"
        case "audio/webm", "video/webm": return "webm"
        case "audio/ogg": return "ogg"
        case "audio/flac", "audio/x-flac": return "flac"
        case "image/png": return "png"
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/webp": return "webp"
        case "image/gif": return "gif"
        case "application/pdf": return "pdf"
        default: return nil
        }
    }

    // MARK: Core LLM Request, Message, Tool & Event Data Structures

    public typealias ProviderMetadata = [String: [String: JSONValue]]
    public typealias CacheTTL = String

    public struct CacheHint: Equatable, Hashable, Sendable, Codable {
        public let type: String // "ephemeral" | "persistent"
        public let ttl: CacheTTL?

        public init(type: String = "ephemeral", ttl: CacheTTL? = nil) {
            self.type = type
            self.ttl = ttl
        }
    }

    public struct ToolFileContent: Equatable, Hashable, Sendable {
        public let uri: String
        public let mime: String
        public let name: String?

        public init(uri: String, mime: String, name: String? = nil) {
            self.uri = uri
            self.mime = mime
            self.name = name
        }
    }

    public enum ToolContentItem: Equatable, Hashable, Sendable {
        case text(String)
        case file(ToolFileContent)
    }

    public enum ToolResultValue: Equatable, Hashable, Sendable {
        case text(String)
        case json(JSONValue)
        case error(JSONValue)
        case content([ToolContentItem])
    }

    public struct TextPart: Equatable, Hashable, Sendable {
        public let text: String
        public let cache: CacheHint?
        public let providerMetadata: ProviderMetadata?

        public init(text: String, cache: CacheHint? = nil, providerMetadata: ProviderMetadata? = nil) {
            self.text = text
            self.cache = cache
            self.providerMetadata = providerMetadata
        }
    }

    public struct ReasoningPart: Equatable, Hashable, Sendable {
        public let text: String
        public let encrypted: String?
        public let providerMetadata: ProviderMetadata?

        public init(text: String, encrypted: String? = nil, providerMetadata: ProviderMetadata? = nil) {
            self.text = text
            self.encrypted = encrypted
            self.providerMetadata = providerMetadata
        }
    }

    public struct MediaPart: Equatable, Hashable, Sendable {
        public let media: MediaAsset
        public let filename: String?
        public let cache: CacheHint?
        public let providerMetadata: ProviderMetadata?

        public init(
            media: MediaAsset,
            filename: String? = nil,
            cache: CacheHint? = nil,
            providerMetadata: ProviderMetadata? = nil
        ) {
            self.media = media
            self.filename = filename
            self.cache = cache
            self.providerMetadata = providerMetadata
        }
    }

    public struct ToolCallPart: Equatable, Hashable, Sendable {
        public let id: String
        public let name: String
        public let namespace: String?
        public let input: JSONValue
        public let providerExecuted: Bool?
        public let providerMetadata: ProviderMetadata?

        public init(
            id: String,
            name: String,
            namespace: String? = nil,
            input: JSONValue = .object([:]),
            providerExecuted: Bool? = nil,
            providerMetadata: ProviderMetadata? = nil
        ) {
            self.id = id
            self.name = name
            self.namespace = namespace
            self.input = input
            self.providerExecuted = providerExecuted
            self.providerMetadata = providerMetadata
        }
    }

    public struct ToolResultPart: Equatable, Hashable, Sendable {
        public let id: String
        public let name: String
        public let namespace: String?
        public let result: ToolResultValue
        public let providerExecuted: Bool?
        public let cache: CacheHint?
        public let providerMetadata: ProviderMetadata?

        public init(
            id: String,
            name: String,
            namespace: String? = nil,
            result: ToolResultValue,
            providerExecuted: Bool? = nil,
            cache: CacheHint? = nil,
            providerMetadata: ProviderMetadata? = nil
        ) {
            self.id = id
            self.name = name
            self.namespace = namespace
            self.result = result
            self.providerExecuted = providerExecuted
            self.cache = cache
            self.providerMetadata = providerMetadata
        }
    }

    public struct CompactionPart: Equatable, Hashable, Sendable {
        public let provider: String
        public let id: String?
        public let text: String?
        public let encrypted: String?

        public init(provider: String, id: String? = nil, text: String? = nil, encrypted: String? = nil) {
            self.provider = provider
            self.id = id
            self.text = text
            self.encrypted = encrypted
        }
    }

    public enum ContentPart: Equatable, Hashable, Sendable {
        case text(TextPart)
        case reasoning(ReasoningPart)
        case media(MediaPart)
        case toolCall(ToolCallPart)
        case toolResult(ToolResultPart)
        case compaction(CompactionPart)

        public var typeName: String {
            switch self {
            case .text: return "text"
            case .reasoning: return "reasoning"
            case .media: return "media"
            case .toolCall: return "tool-call"
            case .toolResult: return "tool-result"
            case .compaction: return "compaction"
            }
        }
    }

    public enum MessageRole: String, Equatable, Hashable, Sendable, Codable {
        case system
        case user
        case assistant
        case tool
    }

    public struct Message: Equatable, Hashable, Sendable {
        public let role: MessageRole
        public let content: [ContentPart]
        public let providerMetadata: ProviderMetadata?

        public init(role: MessageRole, content: [ContentPart], providerMetadata: ProviderMetadata? = nil) {
            self.role = role
            self.content = content
            self.providerMetadata = providerMetadata
        }

        public static func user(_ text: String, cache: CacheHint? = nil) -> Message {
            Message(role: .user, content: [.text(TextPart(text: text, cache: cache))])
        }

        public static func assistant(_ text: String, cache: CacheHint? = nil) -> Message {
            Message(role: .assistant, content: [.text(TextPart(text: text, cache: cache))])
        }

        public static func system(_ text: String, cache: CacheHint? = nil) -> Message {
            Message(role: .system, content: [.text(TextPart(text: text, cache: cache))])
        }

        public static func tool(_ results: [ToolResultPart]) -> Message {
            Message(role: .tool, content: results.map { .toolResult($0) })
        }
    }

    public enum FreeformFormat: Equatable, Hashable, Sendable {
        case text
        case regex(String)
        case lark(String)
    }

    public struct ToolDefinition: Equatable, Hashable, Sendable {
        public let name: String
        public let description: String
        public let inputSchema: [String: JSONValue]
        public let cache: CacheHint?
        public let freeform: FreeformFormat?
        public let native: [String: JSONValue]?

        public init(
            name: String,
            description: String = "",
            inputSchema: [String: JSONValue] = ["type": .string("object"), "properties": .object([:])],
            cache: CacheHint? = nil,
            freeform: FreeformFormat? = nil,
            native: [String: JSONValue]? = nil
        ) {
            self.name = name
            self.description = description
            self.inputSchema = inputSchema
            self.cache = cache
            self.freeform = freeform
            self.native = native
        }

        public static func freeformField(_ schema: [String: JSONValue]) -> String? {
            guard case .object(let props) = schema["properties"], props.count == 1,
                  let (fieldName, fieldSchema) = props.first,
                  case .object(let fieldObj) = fieldSchema,
                  case .string("string") = fieldObj["type"],
                  case .array(let req) = schema["required"],
                  req.count == 1, case .string(fieldName) = req[0]
            else {
                return nil
            }
            return fieldName
        }
    }

    public enum ToolEntry: Equatable, Hashable, Sendable {
        case tool(ToolDefinition)
        case namespace(name: String, description: String?, tools: [ToolEntry])
    }

    public struct ToolChoice: Equatable, Hashable, Sendable {
        public enum Kind: String, Equatable, Hashable, Sendable {
            case auto
            case none
            case required
            case tool
        }

        public let type: Kind
        public let name: String?
        public let disableParallelToolUse: Bool?

        public init(type: Kind, name: String? = nil, disableParallelToolUse: Bool? = nil) {
            self.type = type
            self.name = name
            self.disableParallelToolUse = disableParallelToolUse
        }

        public static let auto = ToolChoice(type: .auto)
        public static let none = ToolChoice(type: .none)
        public static let required = ToolChoice(type: .required)
        public static func tool(_ name: String, disableParallelToolUse: Bool? = nil) -> ToolChoice {
            ToolChoice(type: .tool, name: name, disableParallelToolUse: disableParallelToolUse)
        }
    }

    public struct ModelCompatibility: Equatable, Hashable, Sendable {
        public var reasoningField: String?
        public var requireReasoning: Bool?
        public var maxTokensField: String?
        public var requireFinishReason: Bool?
        public var requireAssistantAfterTool: Bool?
        public var cacheFormat: String?
        public var supportsThinkingBlockBinding: Bool?
        public var requireSignature: Bool?
        public var zaiToolStream: Bool?
        public var sanitizer: String?
        public var mediaInput: String?

        public init(
            reasoningField: String? = nil,
            requireReasoning: Bool? = nil,
            maxTokensField: String? = nil,
            requireFinishReason: Bool? = nil,
            requireAssistantAfterTool: Bool? = nil,
            cacheFormat: String? = nil,
            supportsThinkingBlockBinding: Bool? = nil,
            requireSignature: Bool? = nil,
            zaiToolStream: Bool? = nil,
            sanitizer: String? = nil,
            mediaInput: String? = nil
        ) {
            self.reasoningField = reasoningField
            self.requireReasoning = requireReasoning
            self.maxTokensField = maxTokensField
            self.requireFinishReason = requireFinishReason
            self.requireAssistantAfterTool = requireAssistantAfterTool
            self.cacheFormat = cacheFormat
            self.supportsThinkingBlockBinding = supportsThinkingBlockBinding
            self.requireSignature = requireSignature
            self.zaiToolStream = zaiToolStream
            self.sanitizer = sanitizer
            self.mediaInput = mediaInput
        }
    }

    public struct ModelCapabilities: Equatable, Hashable, Sendable {
        public var promptCacheKey: Bool?
        public var store: Bool?
        public var streamUsage: Bool?
        public var strictTools: Bool?
        public var systemUpdates: Bool?
        public var reasoningUpdates: Bool?

        public init(
            promptCacheKey: Bool? = nil,
            store: Bool? = nil,
            streamUsage: Bool? = nil,
            strictTools: Bool? = nil,
            systemUpdates: Bool? = nil,
            reasoningUpdates: Bool? = nil
        ) {
            self.promptCacheKey = promptCacheKey
            self.store = store
            self.streamUsage = streamUsage
            self.strictTools = strictTools
            self.systemUpdates = systemUpdates
            self.reasoningUpdates = reasoningUpdates
        }
    }

    public struct ModelDescriptor: Equatable, Hashable, Sendable {
        public let id: String
        public let provider: String
        public let routeID: String
        public let providerMetadataKey: String?
        public let baseURL: String?
        public let sanitizer: String?
        public let compatibility: ModelCompatibility?
        public let capabilities: ModelCapabilities?

        public init(
            id: String,
            provider: String,
            routeID: String = "",
            providerMetadataKey: String? = nil,
            baseURL: String? = nil,
            sanitizer: String? = nil,
            compatibility: ModelCompatibility? = nil,
            capabilities: ModelCapabilities? = nil
        ) {
            self.id = id
            self.provider = provider
            self.routeID = routeID.isEmpty ? provider : routeID
            self.providerMetadataKey = providerMetadataKey
            self.baseURL = baseURL
            self.sanitizer = sanitizer
            self.compatibility = compatibility
            self.capabilities = capabilities
        }
    }

    public struct HTTPOverlay: Equatable, Hashable, Sendable {
        public let headers: [String: String]?
        public let body: [String: JSONValue]?
        public let query: [String: String]?
        public let encoding: String?

        public init(
            headers: [String: String]? = nil,
            body: [String: JSONValue]? = nil,
            query: [String: String]? = nil,
            encoding: String? = nil
        ) {
            self.headers = headers
            self.body = body
            self.query = query
            self.encoding = encoding
        }
    }

    public enum CacheSetting: Equatable, Hashable, Sendable {
        case auto
        case none
        case configured(ttl: CacheTTL?)
    }

    public struct LLMRequest: Equatable, Hashable, Sendable {
        public var model: ModelDescriptor
        public var system: [TextPart]
        public var messages: [Message]
        public var tools: [ToolEntry]
        public var toolChoice: ToolChoice?
        public var maxTokens: Int?
        public var temperature: Double?
        public var topP: Double?
        public var topK: Int?
        public var frequencyPenalty: Double?
        public var presencePenalty: Double?
        public var seed: Int?
        public var stop: [String]?
        public var cache: CacheSetting
        public var promptCacheKey: String?
        public var providerOptions: [String: JSONValue]?
        public var http: HTTPOverlay?

        public init(
            model: ModelDescriptor,
            system: [TextPart] = [],
            messages: [Message] = [],
            tools: [ToolEntry] = [],
            toolChoice: ToolChoice? = nil,
            maxTokens: Int? = nil,
            temperature: Double? = nil,
            topP: Double? = nil,
            topK: Int? = nil,
            frequencyPenalty: Double? = nil,
            presencePenalty: Double? = nil,
            seed: Int? = nil,
            stop: [String]? = nil,
            cache: CacheSetting = .auto,
            promptCacheKey: String? = nil,
            providerOptions: [String: JSONValue]? = nil,
            http: HTTPOverlay? = nil
        ) {
            self.model = model
            self.system = system
            self.messages = messages
            self.tools = tools
            self.toolChoice = toolChoice
            self.maxTokens = maxTokens
            self.temperature = temperature
            self.topP = topP
            self.topK = topK
            self.frequencyPenalty = frequencyPenalty
            self.presencePenalty = presencePenalty
            self.seed = seed
            self.stop = stop
            self.cache = cache
            self.promptCacheKey = promptCacheKey
            self.providerOptions = providerOptions
            self.http = http
        }
    }

    // MARK: Finish Reasons, Usage & Stream Events

    public enum FinishReason: String, Equatable, Hashable, Sendable, Codable {
        case stop
        case length
        case toolCalls = "tool-calls"
        case contentFilter = "content-filter"
        case error
        case unknown
    }

    public struct FinishReasonDetails: Equatable, Hashable, Sendable, Codable {
        public let normalized: FinishReason
        public let raw: String?
        public let category: String?
        public let explanation: String?

        public init(
            normalized: FinishReason,
            raw: String? = nil,
            category: String? = nil,
            explanation: String? = nil
        ) {
            self.normalized = normalized
            self.raw = raw
            self.category = category
            self.explanation = explanation
        }
    }

    public struct Usage: Equatable, Hashable, Sendable {
        public let inputTokens: Double?
        public let outputTokens: Double?
        public let contextTokens: Double?
        public let nonCachedInputTokens: Double?
        public let cacheReadInputTokens: Double?
        public let cacheWriteInputTokens: Double?
        public let reasoningTokens: Double?
        public let totalTokens: Double?
        public let cost: Double?
        public let providerMetadata: ProviderMetadata?

        public init(
            inputTokens: Double? = nil,
            outputTokens: Double? = nil,
            contextTokens: Double? = nil,
            nonCachedInputTokens: Double? = nil,
            cacheReadInputTokens: Double? = nil,
            cacheWriteInputTokens: Double? = nil,
            reasoningTokens: Double? = nil,
            totalTokens: Double? = nil,
            cost: Double? = nil,
            providerMetadata: ProviderMetadata? = nil
        ) {
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.contextTokens = contextTokens
            self.nonCachedInputTokens = nonCachedInputTokens
            self.cacheReadInputTokens = cacheReadInputTokens
            self.cacheWriteInputTokens = cacheWriteInputTokens
            self.reasoningTokens = reasoningTokens
            self.totalTokens = totalTokens
            self.cost = cost
            self.providerMetadata = providerMetadata
        }
    }

    public enum LLMEvent: Equatable, Hashable, Sendable {
        case stepStart(index: Int)
        case textStart(id: String, providerMetadata: ProviderMetadata? = nil)
        case textDelta(id: String, text: String, providerMetadata: ProviderMetadata? = nil)
        case textEnd(id: String, text: String? = nil, providerMetadata: ProviderMetadata? = nil)
        case reasoningStart(id: String, providerMetadata: ProviderMetadata? = nil)
        case reasoningDelta(id: String, text: String, providerMetadata: ProviderMetadata? = nil)
        case reasoningEnd(id: String, text: String? = nil, providerMetadata: ProviderMetadata? = nil)
        case toolInputStart(id: String, name: String, namespace: String? = nil, providerExecuted: Bool? = nil, providerMetadata: ProviderMetadata? = nil)
        case toolInputDelta(id: String, name: String, namespace: String? = nil, text: String, partialInput: JSONValue? = nil)
        case toolInputEnd(id: String, name: String, namespace: String? = nil, providerMetadata: ProviderMetadata? = nil)
        case toolCall(id: String, name: String, namespace: String? = nil, input: JSONValue, providerExecuted: Bool? = nil, providerMetadata: ProviderMetadata? = nil)
        case toolInputError(id: String, name: String, namespace: String? = nil, raw: String)
        case toolResult(id: String, name: String, result: ToolResultValue, providerExecuted: Bool? = nil, providerMetadata: ProviderMetadata? = nil)
        case media(media: MediaAsset, providerMetadata: ProviderMetadata? = nil)
        case compaction(provider: String, id: String? = nil, text: String? = nil, encrypted: String? = nil)
        case stepFinish(index: Int, reason: FinishReasonDetails, usage: Usage? = nil, providerMetadata: ProviderMetadata? = nil)
        case finish(reason: FinishReasonDetails, usage: Usage? = nil, providerMetadata: ProviderMetadata? = nil)

        public var isFinish: Bool {
            if case .finish = self { return true }
            return false
        }

        public var isToolCallOrError: Bool {
            switch self {
            case .toolCall, .toolInputError: return true
            default: return false
            }
        }
    }

    // MARK: Media Usage & Media Stream Events

    public enum MediaUsage: Equatable, Hashable, Sendable {
        case tokens(input: Double?, output: Double?, total: Double?, details: [String: JSONValue]?)
        case characters(Double)
        case credits(Double)
        case seconds(Double)
    }

    public struct SpeechTimestampItem: Equatable, Hashable, Sendable, Codable {
        public let text: String
        public let startSeconds: Double
        public let endSeconds: Double

        public init(text: String, startSeconds: Double, endSeconds: Double) {
            self.text = text
            self.startSeconds = startSeconds
            self.endSeconds = endSeconds
        }
    }

    public enum SpeechEvent: Equatable, Hashable, Sendable {
        case audioDelta([UInt8])
        case timestamps([SpeechTimestampItem])
        case finish(audio: MediaAsset, usage: MediaUsage?, providerMetadata: ProviderMetadata?)
    }

    public struct TranscriptionSegment: Equatable, Hashable, Sendable, Codable {
        public let text: String
        public let start: Double
        public let end: Double
        public let speaker: String?

        public init(text: String, start: Double, end: Double, speaker: String? = nil) {
            self.text = text
            self.start = start
            self.end = end
            self.speaker = speaker
        }
    }

    public enum TranscriptionEvent: Equatable, Hashable, Sendable {
        case textDelta(String)
        case segment(TranscriptionSegment)
        case finish(
            text: String,
            language: String?,
            durationSeconds: Double?,
            segments: [TranscriptionSegment],
            usage: MediaUsage?,
            providerMetadata: ProviderMetadata?
        )
    }

    public struct MediaIdentity: Equatable, Hashable, Sendable {
        public let id: String
        public let name: String
        public let provider: String

        public init(id: String, name: String, provider: String) {
            self.id = id
            self.name = name
            self.provider = provider
        }

        public func unsupported(_ operation: String, _ message: String) -> ProtocolError {
            ProtocolError(kind: .unsupportedOperation, message: message, route: id, provider: provider, operation: operation)
        }

        public func frameError(_ message: String, body: String? = nil) -> ProtocolError {
            ProtocolError(kind: .invalidProviderOutput, message: message, route: id, provider: provider, body: body)
        }

        public func incomplete(_ message: String? = nil) -> ProtocolError {
            ProtocolError(
                kind: .invalidProviderOutput,
                message: message ?? "\(name) stream ended unexpectedly",
                route: id,
                provider: provider,
                classification: "incomplete-stream"
            )
        }
    }

    // MARK: Server-Sent Events (SSE) Incremental Parser

    public struct SSEFrame: Equatable, Hashable, Sendable {
        public let event: String?
        public let data: String
        public let id: String?

        public init(event: String? = nil, data: String, id: String? = nil) {
            self.event = event
            self.data = data
            self.id = id
        }
    }

    public struct SSEParser: Sendable {
        private var lineBuffer: [UInt8] = []
        private var currentEvent: String?
        private var currentID: String?
        private var dataLines: [String] = []
        private var sawCR = false

        public init() {}

        public mutating func feed(_ bytes: [UInt8]) -> [SSEFrame] {
            var frames: [SSEFrame] = []
            for byte in bytes {
                if sawCR {
                    sawCR = false
                    if byte == 0x0A { continue }
                }
                if byte == 0x0D {
                    sawCR = true
                    processLine(into: &frames)
                } else if byte == 0x0A {
                    processLine(into: &frames)
                } else {
                    lineBuffer.append(byte)
                }
            }
            return frames
        }

        public mutating func feed(_ text: String) -> [SSEFrame] {
            feed(Array(text.utf8))
        }

        public mutating func finish() -> [SSEFrame] {
            var frames: [SSEFrame] = []
            if !lineBuffer.isEmpty {
                processLine(into: &frames)
            }
            if !dataLines.isEmpty {
                frames.append(SSEFrame(event: currentEvent, data: dataLines.joined(separator: "\n"), id: currentID))
                dataLines.removeAll(keepingCapacity: true)
                currentEvent = nil
            }
            return frames
        }

        private mutating func processLine(into frames: inout [SSEFrame]) {
            var line = String(decoding: lineBuffer, as: UTF8.self)
            lineBuffer.removeAll(keepingCapacity: true)
            if line.hasPrefix("\u{FEFF}") {
                line.removeFirst()
            }
            if line.isEmpty {
                if !dataLines.isEmpty {
                    frames.append(SSEFrame(event: currentEvent, data: dataLines.joined(separator: "\n"), id: currentID))
                    dataLines.removeAll(keepingCapacity: true)
                }
                currentEvent = nil
                return
            }
            if line.hasPrefix(":") {
                return
            }
            let field: String
            let value: String
            if let colon = line.firstIndex(of: ":") {
                field = String(line[..<colon])
                let afterColon = line.index(after: colon)
                if afterColon < line.endIndex && line[afterColon] == " " {
                    value = String(line[line.index(after: afterColon)...])
                } else {
                    value = String(line[afterColon...])
                }
            } else {
                field = line
                value = ""
            }
            switch field {
            case "event":
                currentEvent = value
            case "data":
                dataLines.append(value)
            case "id":
                currentID = value
            default:
                break
            }
        }
    }

    // MARK: Auth Strategy Descriptor

    public enum AuthStrategy: Sendable {
        case none
        case bearer(String)
        case header(name: String, value: String)
        case remove(String)
        case sigV4(BedrockAuth.Credentials, service: String, name: String)
        case custom(@Sendable (HTTPRequest) throws -> HTTPRequest)
        case sequence([AuthStrategy])

        public func apply(to request: HTTPRequest, timestampEpochSeconds: Int64 = 1_700_000_000) throws -> HTTPRequest {
            switch self {
            case .none:
                return request
            case .bearer(let token):
                var headers = request.headers
                headers["authorization"] = "Bearer \(token)"
                return HTTPRequest(method: request.method, url: request.url, headers: headers, body: request.body)
            case .header(let name, let value):
                var headers = request.headers
                headers[name] = value
                return HTTPRequest(method: request.method, url: request.url, headers: headers, body: request.body)
            case .remove(let name):
                let target = name.lowercased()
                let filtered = request.headers.filter { $0.key.lowercased() != target }
                return HTTPRequest(method: request.method, url: request.url, headers: filtered, body: request.body)
            case .sigV4(let credentials, let service, let name):
                var headers = request.headers
                headers["content-type"] = "application/json"
                let signed = try BedrockAuth.signRequest(
                    method: request.method,
                    url: request.url,
                    body: request.body ?? [],
                    headers: headers,
                    credentials: credentials,
                    service: service,
                    name: name,
                    timestampEpochSeconds: timestampEpochSeconds
                )
                return HTTPRequest(method: request.method, url: request.url, headers: signed, body: request.body)
            case .custom(let fn):
                return try fn(request)
            case .sequence(let steps):
                var current = request
                for step in steps {
                    current = try step.apply(to: current, timestampEpochSeconds: timestampEpochSeconds)
                }
                return current
            }
        }
    }

    // MARK: - ProviderShared (packages/ai/src/protocols/shared.ts — 42 symbols)

    public enum ProviderShared {
        public struct SchemaTag: Equatable, Hashable, Sendable {
            public let name: String
            public init(_ name: String) { self.name = name }
        }

        // parity: ai/src/protocols/shared.ts#Json [status=implemented hash=dc95134c3b7b]
        public typealias Json = AIUtils.Json

        // parity: ai/src/protocols/shared.ts#decodeJson [status=implemented hash=dc95134c3b7b]
        public static func decodeJson(_ text: String) throws -> JSONValue {
            try AIUtils.decodeJson(text)
        }

        // parity: ai/src/protocols/shared.ts#encodeJson [status=implemented hash=dc95134c3b7b]
        public static func encodeJson(_ value: JSONValue) throws -> String {
            try AIUtils.encodeJson(value)
        }

        // parity: ai/src/protocols/shared.ts#isRecord [status=implemented hash=dc95134c3b7b]
        public static func isRecord(_ value: JSONValue?) -> Bool {
            AIUtils.isRecord(value)
        }

        // parity: ai/src/protocols/shared.ts#JsonObject [status=implemented hash=f1fd80b88596]
        public typealias JsonObject = [String: JSONValue]

        // parity: ai/src/protocols/shared.ts#optionalArray [status=adapted hash=0fb9a925c7ef]
        public static func optionalArray<T>(_ value: [T]?) -> [T]? {
            value
        }

        // parity: ai/src/protocols/shared.ts#optionalNull [status=adapted hash=14b007c7abdd]
        public static func optionalNull<T>(_ value: T?) -> T? {
            value
        }

        // parity: ai/src/protocols/shared.ts#optionalNullish [status=adapted hash=9e4345b8f70a]
        public static func optionalNullish(_ value: JSONValue?) -> JSONValue? {
            guard let value, value != .null else { return nil }
            return value
        }

        // parity: ai/src/protocols/shared.ts#lenient [status=adapted hash=1d1249fbd510]
        public static func lenient<T>(_ decode: () throws -> T?) -> T? {
            (try? decode()) ?? nil
        }

        // parity: ai/src/protocols/shared.ts#ReportedBilling [status=implemented hash=3b7abda3ef27]
        public struct ReportedBilling: Equatable, Hashable, Sendable, Codable {
            public let cost: Double?

            public init(cost: Double? = nil) {
                if let cost, cost.isFinite && cost >= 0 {
                    self.cost = cost
                } else {
                    self.cost = nil
                }
            }
        }

        // parity: ai/src/protocols/shared.ts#reportedBilling [status=implemented hash=693ee1c02017]
        public static func reportedBilling(usage: JSONValue?, frames: [JSONValue] = []) -> ReportedBilling {
            if let obj = JSONCodec.objectValue(usage),
               let cost = JSONCodec.doubleValue(obj["cost"]),
               cost.isFinite && cost >= 0 {
                return ReportedBilling(cost: cost)
            }
            for frame in frames {
                if let obj = JSONCodec.objectValue(frame),
                   let copilot = JSONCodec.objectValue(obj["copilot_usage"]),
                   let nanoAiu = JSONCodec.doubleValue(copilot["total_nano_aiu"]),
                   nanoAiu.isFinite && nanoAiu >= 0 {
                    return ReportedBilling(cost: nanoAiu / 100_000_000_000.0)
                }
            }
            return ReportedBilling(cost: nil)
        }

        // parity: ai/src/protocols/shared.ts#contentFilterCategory [status=implemented hash=1f8b3a30fa12]
        public static func contentFilterCategory(_ sources: JSONValue?...) -> String? {
            for source in sources {
                guard let obj = JSONCodec.objectValue(source) else { continue }
                for key in obj.keys.sorted() {
                    let value = obj[key]!
                    if let inner = JSONCodec.objectValue(value), let filtered = inner["filtered"] {
                        if case .bool(true) = filtered { return key }
                    } else if isTruthy(value) {
                        return key
                    }
                }
            }
            return nil
        }

        private static func isTruthy(_ value: JSONValue) -> Bool {
            switch value {
            case .null: return false
            case .bool(let b): return b
            case .int(let i): return i != 0
            case .double(let d): return d != 0 && !d.isNaN
            case .string(let s): return !s.isEmpty
            case .array, .object: return true
            }
        }

        // parity: ai/src/protocols/shared.ts#withUntypedFrames [status=implemented hash=6680be0be19f]
        public static func withUntypedFrames(_ frame: [String: JSONValue]) -> [String: JSONValue] {
            if frame["type"] != nil { return frame }
            var copy = frame
            let hasError = frame["error"] != nil && frame["error"] != .null
            copy["type"] = .string(hasError ? "error" : "ignored")
            return copy
        }

        // parity: ai/src/protocols/shared.ts#knownString [status=adapted hash=9bf779f28392]
        public static func knownString(_ value: JSONValue?) -> String? {
            JSONCodec.stringValue(value)
        }

        // parity: ai/src/protocols/shared.ts#OPENAI_PROMPT_CACHE_KEY_MAX_LENGTH [status=implemented hash=30bac79c57af]
        public static let OPENAI_PROMPT_CACHE_KEY_MAX_LENGTH = 64

        // parity: ai/src/protocols/shared.ts#sendsPromptCacheKey [status=implemented hash=e0b476c8f3c4]
        public static func sendsPromptCacheKey(_ request: LLMRequest) -> Bool {
            request.cache != .none && request.model.capabilities?.promptCacheKey != false
        }

        // parity: ai/src/protocols/shared.ts#promptCacheKey [status=implemented hash=507920edb8a5]
        public static func promptCacheKey(_ request: LLMRequest) -> String? {
            guard sendsPromptCacheKey(request), let key = request.promptCacheKey else { return nil }
            let scalars = Array(key.unicodeScalars)
            if scalars.count <= OPENAI_PROMPT_CACHE_KEY_MAX_LENGTH { return key }
            return String(String.UnicodeScalarView(scalars.prefix(OPENAI_PROMPT_CACHE_KEY_MAX_LENGTH)))
        }

        // parity: ai/src/protocols/shared.ts#ToolAccumulator [status=implemented hash=230d860fd869]
        public struct ToolAccumulator: Equatable, Hashable, Sendable {
            public let id: String
            public let name: String
            public let namespace: String?
            public let input: String

            public init(id: String, name: String, namespace: String? = nil, input: String = "") {
                self.id = id
                self.name = name
                self.namespace = namespace
                self.input = input
            }
        }

        // parity: ai/src/protocols/shared.ts#totalTokens [status=implemented hash=7ccdd15e918e]
        public static func totalTokens(_ inputTokens: Double?, _ outputTokens: Double?, _ total: Double?) -> Double? {
            if let total { return total }
            if inputTokens == nil && outputTokens == nil { return nil }
            return (inputTokens ?? 0) + (outputTokens ?? 0)
        }

        // parity: ai/src/protocols/shared.ts#subtractTokens [status=implemented hash=23fd8e77243a]
        public static func subtractTokens(_ total: Double?, _ subtrahend: Double?) -> Double? {
            guard let total else { return nil }
            guard let subtrahend else { return total }
            return max(0, total - subtrahend)
        }

        // parity: ai/src/protocols/shared.ts#sumTokens [status=implemented hash=4237920505ac]
        public static func sumTokens(_ values: Double?...) -> Double? {
            sumTokens(values)
        }

        public static func sumTokens(_ values: [Double?]) -> Double? {
            if values.allSatisfy({ $0 == nil }) { return nil }
            return values.reduce(0.0) { $0 + ($1 ?? 0) }
        }

        // parity: ai/src/protocols/shared.ts#fitThinkingBudget [status=implemented hash=c5d9c9cc2e5e]
        public static func fitThinkingBudget(_ budget: Int, maxTokens: Int?, minimum: Int = 1) -> Int {
            guard let maxTokens else { return budget }
            let half = maxTokens / 2
            if Double(budget) <= Double(maxTokens) / 2.0 { return budget }
            return max(minimum, half)
        }

        // parity: ai/src/protocols/shared.ts#eventError [status=implemented hash=0457bb1076df]
        public static func eventError(_ route: String, _ message: String, body: String? = nil) -> ProtocolError {
            ProtocolError(kind: .invalidProviderOutput, message: message, route: route, body: body)
        }

        // parity: ai/src/protocols/shared.ts#parseJson [status=implemented hash=9c4bab29d763]
        public static func parseJson(route: String, input: String, message: String) throws(ProtocolError) -> JSONValue {
            guard let parsed = PureJSON.parse(input) else {
                throw eventError(route, message, body: input)
            }
            return JSONCodec.fromPureJSON(parsed)
        }

        // parity: ai/src/protocols/shared.ts#joinText [status=implemented hash=56cdf1ea1ec0]
        public static func joinText(_ parts: [TextPart]) -> String {
            parts.map(\.text).joined(separator: "\n")
        }

        private static func escapeSystemUpdateText(_ text: String) -> String {
            text
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }

        // parity: ai/src/protocols/shared.ts#wrapSystemUpdate [status=implemented hash=cf4c8f79ac49]
        public static func wrapSystemUpdate(_ parts: [TextPart]) -> String {
            "<system-update>\n\(escapeSystemUpdateText(joinText(parts)))\n</system-update>"
        }

        // parity: ai/src/protocols/shared.ts#systemUpdateText [status=implemented hash=3c2b8a74a49e]
        public static func systemUpdateText(route: String, message: Message) throws(ProtocolError) -> [TextPart] {
            var out: [TextPart] = []
            for part in message.content {
                guard case .text(let textPart) = part else {
                    throw unsupportedContent(route: route, role: .system, types: ["text"])
                }
                out.append(textPart)
            }
            return out
        }

        // parity: ai/src/protocols/shared.ts#wrappedSystemUpdate [status=implemented hash=08c43235bc78]
        public static func wrappedSystemUpdate(route: String, message: Message) throws(ProtocolError) -> TextPart {
            let content = try systemUpdateText(route: route, message: message)
            return TextPart(text: wrapSystemUpdate(content), cache: content.last?.cache)
        }

        // parity: ai/src/protocols/shared.ts#parseToolInput [status=implemented hash=ba473fa8016e]
        public static func parseToolInput(route: String, name: String, raw: String) throws(ProtocolError) -> JSONValue {
            try parseJson(
                route: route,
                input: raw.isEmpty ? "{}" : raw,
                message: "Invalid JSON input for \(route) tool call \(name)"
            )
        }

        // parity: ai/src/protocols/shared.ts#requireInlineMedia [status=implemented hash=a449b2659d8c]
        public static func requireInlineMedia(route: String, asset: MediaAsset) throws(ProtocolError) -> InlineMedia {
            guard let inline = asset.inline() else {
                throw inlineRequired(route: route, asset: asset)
            }
            return inline
        }

        // parity: ai/src/protocols/shared.ts#inlineRequired [status=implemented hash=39738b2f0695]
        public static func inlineRequired(route: String, asset: MediaAsset) -> ProtocolError {
            invalidRequest("\(route) requires inline media (bytes or base64); \(asset.source.typeName) sources must be materialized first")
        }

        // parity: ai/src/protocols/shared.ts#mediaUrl [status=implemented hash=e601ede7f826]
        public static func mediaUrl(_ asset: MediaAsset) -> String? {
            if case .url(let url) = asset.source { return url }
            return nil
        }

        // parity: ai/src/protocols/shared.ts#MediaReference [status=implemented hash=49ee769f0f28]
        public struct MediaReference: Equatable, Hashable, Sendable {
            public enum Kind: String, Equatable, Hashable, Sendable {
                case dataUrl
                case url
                case ref
            }

            public let type: Kind
            public let value: String

            public init(type: Kind, value: String) {
                self.type = type
                self.value = value
            }
        }

        // parity: ai/src/protocols/shared.ts#mediaReference [status=implemented hash=50841ac557a2]
        public static func mediaReference(
            asset: MediaAsset,
            provider: String?,
            label: String
        ) throws(ProtocolError) -> MediaReference {
            if let inline = asset.inline() {
                return MediaReference(type: .dataUrl, value: inline.dataUrl)
            }
            if let url = mediaUrl(asset) {
                return MediaReference(type: .url, value: url)
            }
            if let provider, case .ref(let refProvider, let id) = asset.source, refProvider == provider {
                return MediaReference(type: .ref, value: id)
            }
            let accepted = provider.map { ", and \($0) references" } ?? ""
            let got: String
            if case .ref(let refProvider, let id) = asset.source {
                got = "; got \(refProvider):\(id)"
            } else {
                got = ""
            }
            throw invalidRequest("\(label) accepts inline bytes, data URLs, http(s) URLs\(accepted)\(got)")
        }

        // parity: ai/src/protocols/shared.ts#toolFileMedia [status=implemented hash=f9695e397f5d]
        public static func toolFileMedia(_ item: ToolFileContent) -> MediaPart {
            let asset: MediaAsset
            if let parsed = MediaAsset.parseDataUrl(item.uri) {
                asset = MediaAsset(source: parsed.source, mediaType: item.mime)
            } else if item.uri.contains("://") {
                asset = MediaAsset.url(item.uri, mediaType: item.mime)
            } else {
                asset = MediaAsset.base64(item.uri, mediaType: item.mime)
            }
            return MediaPart(media: asset, filename: item.name)
        }

        // parity: ai/src/protocols/shared.ts#toolResultText [status=implemented hash=ff9a73cf0bb7]
        public static func toolResultText(_ part: ToolResultPart) -> String {
            switch part.result {
            case .text(let s):
                return s
            case .error(let value):
                switch value {
                case .string(let s): return s
                case .array, .object: return JSONCodec.encode(value)
                default: return JSONCodec.encode(value)
                }
            case .json(let value):
                return JSONCodec.encode(value)
            case .content(let items):
                return items.compactMap {
                    if case .text(let s) = $0 { return s }
                    return nil
                }.joined(separator: "\n")
            }
        }

        // parity: ai/src/protocols/shared.ts#errorText [status=implemented hash=44f982a9bb61]
        public static func errorText(_ error: Any?) -> String {
            guard let error else { return "undefined" }
            if let protoErr = error as? ProtocolError { return protoErr.message }
            if let s = error as? String { return s }
            if let convertible = error as? CustomStringConvertible { return convertible.description }
            return "Unknown stream error"
        }

        // parity: ai/src/protocols/shared.ts#invalidRequest [status=implemented hash=a4c017ddc4e5]
        public static func invalidRequest(_ message: String) -> ProtocolError {
            ProtocolError(kind: .invalidRequest, message: message)
        }

        // parity: ai/src/protocols/shared.ts#unsupportedOperation [status=implemented hash=bc3e569d035b]
        public static func unsupportedOperation(
            operation: String,
            message: String,
            provider: String? = nil,
            route: String? = nil
        ) -> ProtocolError {
            ProtocolError(
                kind: .unsupportedOperation,
                message: message,
                route: route,
                provider: provider,
                operation: operation
            )
        }

        // parity: ai/src/protocols/shared.ts#flattenTools [status=implemented hash=fe9dd53c92ee]
        public static func flattenTools(_ tools: [ToolEntry], path: [String] = []) -> [ToolDefinition] {
            var flat: [ToolDefinition] = []
            for entry in tools {
                switch entry {
                case .namespace(let name, _, let nested):
                    flat.append(contentsOf: flattenTools(nested, path: path + [name]))
                case .tool(let def):
                    if path.isEmpty {
                        flat.append(def)
                    } else {
                        let joined = (path + [def.name]).joined(separator: "_")
                        flat.append(ToolDefinition(
                            name: joined,
                            description: def.description,
                            inputSchema: def.inputSchema,
                            cache: def.cache,
                            freeform: def.freeform,
                            native: def.native
                        ))
                    }
                }
            }
            var seen: [String: Int] = [:]
            var deduplicated: [ToolDefinition] = []
            for tool in flat {
                if let idx = seen[tool.name] {
                    deduplicated[idx] = tool
                } else {
                    seen[tool.name] = deduplicated.count
                    deduplicated.append(tool)
                }
            }
            return deduplicated
        }

        // parity: ai/src/protocols/shared.ts#flattenToolRequest [status=implemented hash=e6dee10c5693]
        public static func flattenToolRequest(_ request: LLMRequest) -> (tools: [ToolDefinition], request: LLMRequest) {
            let messages = request.messages.map { message -> Message in
                switch message.role {
                case .assistant:
                    let content = message.content.map { part -> ContentPart in
                        switch part {
                        case .toolCall(let call) where call.namespace != nil:
                            return .toolCall(ToolCallPart(
                                id: call.id,
                                name: "\(call.namespace!)_\(call.name)",
                                namespace: nil,
                                input: call.input,
                                providerExecuted: call.providerExecuted,
                                providerMetadata: call.providerMetadata
                            ))
                        case .toolResult(let res) where res.namespace != nil:
                            return .toolResult(ToolResultPart(
                                id: res.id,
                                name: "\(res.namespace!)_\(res.name)",
                                namespace: nil,
                                result: res.result,
                                providerExecuted: res.providerExecuted,
                                cache: res.cache,
                                providerMetadata: res.providerMetadata
                            ))
                        default:
                            return part
                        }
                    }
                    return Message(role: .assistant, content: content, providerMetadata: message.providerMetadata)
                case .tool:
                    let content = message.content.map { part -> ContentPart in
                        if case .toolResult(let res) = part, let ns = res.namespace {
                            return .toolResult(ToolResultPart(
                                id: res.id,
                                name: "\(ns)_\(res.name)",
                                namespace: nil,
                                result: res.result,
                                providerExecuted: res.providerExecuted,
                                cache: res.cache,
                                providerMetadata: res.providerMetadata
                            ))
                        }
                        return part
                    }
                    return Message(role: .tool, content: content, providerMetadata: message.providerMetadata)
                case .system, .user:
                    return message
                }
            }
            var updated = request
            updated.messages = messages
            return (tools: flattenTools(request.tools), request: updated)
        }

        // parity: ai/src/protocols/shared.ts#matchToolChoice [status=implemented hash=d85de3e942a7]
        public static func matchToolChoice<R>(
            route: String,
            toolChoice: ToolChoice,
            auto: () -> R,
            none: () -> R,
            required: () -> R,
            tool: (String) -> R
        ) throws(ProtocolError) -> R {
            switch toolChoice.type {
            case .auto: return auto()
            case .none: return none()
            case .required: return required()
            case .tool:
                guard let name = toolChoice.name, !name.isEmpty else {
                    throw invalidRequest("\(route) tool choice requires a tool name")
                }
                return tool(name)
            }
        }

        // parity: ai/src/protocols/shared.ts#supportsContent [status=implemented hash=24f11427046d]
        public static func supportsContent(_ part: ContentPart, types: [String]) -> Bool {
            types.contains(part.typeName)
        }

        private static func formatContentTypes(_ types: [String]) -> String {
            if types.count <= 1 { return types.first ?? "" }
            if types.count == 2 { return "\(types[0]) and \(types[1])" }
            return "\(types.dropLast().joined(separator: ", ")), and \(types.last!)"
        }

        // parity: ai/src/protocols/shared.ts#unsupportedContent [status=implemented hash=aed9d71b03c1]
        public static func unsupportedContent(route: String, role: MessageRole, types: [String]) -> ProtocolError {
            invalidRequest("\(route) \(role.rawValue) messages only support \(formatContentTypes(types)) content for now")
        }

        // parity: ai/src/protocols/shared.ts#validateWith [status=adapted hash=bdc726bcc44f]
        public static func validateWith<Input, Output>(
            _ decode: @escaping @Sendable (Input) throws -> Output
        ) -> @Sendable (Input) throws(ProtocolError) -> Output {
            { input throws(ProtocolError) in
                do {
                    return try decode(input)
                } catch let err as ProtocolError {
                    throw err
                } catch {
                    throw invalidRequest(errorText(error))
                }
            }
        }

        // parity: ai/src/protocols/shared.ts#jsonPost [status=implemented hash=14563d9608a0]
        public static func jsonPost(
            url: String,
            body: String,
            headers: [String: String] = [:],
            encoding: String? = nil
        ) -> HTTPRequest {
            var mergedHeaders = headers
            // Remove any stale casing of content-type before setting canonical header.
            for key in mergedHeaders.keys where key.lowercased() == "content-type" {
                mergedHeaders.removeValue(forKey: key)
            }
            mergedHeaders["content-type"] = "application/json"
            _ = encoding // Plain UTF-8 JSON fallback when zlib is absent in portable tier.
            return HTTPRequest(method: "POST", url: url, headers: mergedHeaders, body: Array(body.utf8))
        }
    }

    // MARK: - BedrockAuth (packages/ai/src/protocols/utils/bedrock-auth.ts — 10 symbols)

    public enum BedrockAuth {
        // parity: ai/src/protocols/utils/bedrock-auth.ts#Credentials [status=implemented hash=6c92854166eb]
        public struct Credentials: Equatable, Hashable, Sendable {
            public let region: String
            public let accessKeyId: String
            public let secretAccessKey: String
            public let sessionToken: String?

            public init(
                region: String,
                accessKeyId: String,
                secretAccessKey: String,
                sessionToken: String? = nil
            ) {
                self.region = region
                self.accessKeyId = accessKeyId
                self.secretAccessKey = secretAccessKey
                self.sessionToken = sessionToken
            }
        }

        // parity: ai/src/protocols/utils/bedrock-auth.ts#CredentialSource [status=adapted hash=1dde412e0469]
        public enum CredentialSource: Sendable {
            case staticCredentials(Credentials)
            case resolver(@Sendable () throws -> Credentials)
        }

        // parity: ai/src/protocols/utils/bedrock-auth.ts#DefaultChainOptions [status=implemented hash=5ae41bd7ab9e]
        public struct DefaultChainOptions: Equatable, Hashable, Sendable {
            public let region: String
            public let profile: String?

            public init(region: String, profile: String? = nil) {
                self.region = region
                self.profile = profile
            }
        }

        // parity: ai/src/protocols/utils/bedrock-auth.ts#defaultChain [status=adapted hash=d19800c4c1a3]
        public static func defaultChain(
            _ options: DefaultChainOptions,
            environment: any EnvironmentProviding = SystemEnvironment.shared
        ) -> CredentialSource {
            .resolver {
                guard let accessKey = environment.variable("AWS_ACCESS_KEY_ID"), !accessKey.isEmpty,
                      let secretKey = environment.variable("AWS_SECRET_ACCESS_KEY"), !secretKey.isEmpty
                else {
                    throw ProtocolError(
                        kind: .authentication,
                        message: "AWS default credential chain failed: missing AWS_ACCESS_KEY_ID or AWS_SECRET_ACCESS_KEY"
                    )
                }
                return Credentials(
                    region: options.region,
                    accessKeyId: accessKey,
                    secretAccessKey: secretKey,
                    sessionToken: environment.variable("AWS_SESSION_TOKEN")
                )
            }
        }

        // parity: ai/src/protocols/utils/bedrock-auth.ts#sigV4 [status=implemented hash=7b15fea51930]
        public static func sigV4(
            _ source: CredentialSource?,
            service: String = "bedrock",
            name: String = "Bedrock Converse",
            timestampEpochSeconds: Int64 = 1_700_000_000
        ) -> AuthStrategy {
            .custom { request in
                guard let source else {
                    throw ProviderShared.invalidRequest(
                        "\(name) requires either route bearer auth or AWS credentials configured on the route"
                    )
                }
                let creds: Credentials
                switch source {
                case .staticCredentials(let c): creds = c
                case .resolver(let fn): creds = try fn()
                }
                var headers = request.headers
                headers["content-type"] = "application/json"
                let signed = try signRequest(
                    method: request.method,
                    url: request.url,
                    body: request.body ?? [],
                    headers: headers,
                    credentials: creds,
                    service: service,
                    name: name,
                    timestampEpochSeconds: timestampEpochSeconds
                )
                return HTTPRequest(method: request.method, url: request.url, headers: signed, body: request.body)
            }
        }

        // parity: ai/src/protocols/utils/bedrock-auth.ts#auth [status=implemented hash=a73757d95202]
        public static let auth: AuthStrategy = sigV4(nil)

        // parity: ai/src/protocols/utils/bedrock-auth.ts#resolveRegion [status=implemented hash=c74a4f8dc6b9]
        public static func resolveRegion(
            region: String? = nil,
            credentialsRegion: String? = nil,
            environment: any EnvironmentProviding = SystemEnvironment.shared
        ) -> String {
            region
                ?? credentialsRegion
                ?? environment.variable("AWS_REGION")
                ?? environment.variable("AWS_DEFAULT_REGION")
                ?? "us-east-1"
        }

        // parity: ai/src/protocols/utils/bedrock-auth.ts#ResolveAuthInput [status=implemented hash=54711af8c355]
        public struct ResolveAuthInput: Equatable, Hashable, Sendable {
            public let apiKey: String?
            public let credentials: Credentials?
            public let profile: String?

            public init(apiKey: String? = nil, credentials: Credentials? = nil, profile: String? = nil) {
                self.apiKey = apiKey
                self.credentials = credentials
                self.profile = profile
            }
        }

        // parity: ai/src/protocols/utils/bedrock-auth.ts#ResolveAuthOptions [status=implemented hash=6a824e17d0ea]
        public struct ResolveAuthOptions: Equatable, Hashable, Sendable {
            public enum Mode: String, Equatable, Hashable, Sendable {
                case bearer
                case sigv4
            }

            public let service: String?
            public let name: String?
            public let mode: Mode?

            public init(service: String? = nil, name: String? = nil, mode: Mode? = nil) {
                self.service = service
                self.name = name
                self.mode = mode
            }
        }

        // parity: ai/src/protocols/utils/bedrock-auth.ts#resolveAuth [status=implemented hash=9ed8699d69ce]
        public static func resolveAuth(
            _ input: ResolveAuthInput,
            region: String,
            options: ResolveAuthOptions = ResolveAuthOptions(),
            environment: any EnvironmentProviding = SystemEnvironment.shared
        ) -> AuthStrategy {
            let apiKey = options.mode == .sigv4
                ? nil
                : (input.apiKey ?? environment.variable("AWS_BEARER_TOKEN_BEDROCK"))
            if let apiKey {
                return .bearer(apiKey)
            }
            let service = options.service ?? "bedrock"
            let name = options.name ?? "Bedrock Converse"
            if let creds = input.credentials {
                let scoped = Credentials(
                    region: region,
                    accessKeyId: creds.accessKeyId,
                    secretAccessKey: creds.secretAccessKey,
                    sessionToken: creds.sessionToken
                )
                return sigV4(.staticCredentials(scoped), service: service, name: name)
            }
            return sigV4(
                defaultChain(DefaultChainOptions(region: region, profile: input.profile), environment: environment),
                service: service,
                name: name
            )
        }

        /// Pure-Swift AWS Signature Version 4 request signer (RFC 2104 HMAC-SHA256 + SHA-256).
        public static func signRequest(
            method: String,
            url: String,
            body: [UInt8],
            headers: [String: String],
            credentials: Credentials,
            service: String = "bedrock",
            name: String = "Bedrock Converse",
            timestampEpochSeconds: Int64 = 1_700_000_000
        ) throws(ProtocolError) -> [String: String] {
            guard let parsed = parseHTTPURL(url) else {
                throw ProviderShared.invalidRequest("\(name) SigV4 signing failed: invalid URL '\(url)'")
            }
            let (amzDate, dateStamp) = formatSigV4Date(timestampEpochSeconds)
            let payloadHash = Hash.sha256(body)

            var canonicalHeaderMap: [String: String] = [:]
            for (k, v) in headers {
                canonicalHeaderMap[k.lowercased()] = v.trimmingASCIIWhitespace()
            }
            canonicalHeaderMap["host"] = parsed.host
            canonicalHeaderMap["x-amz-date"] = amzDate
            canonicalHeaderMap["x-amz-content-sha256"] = payloadHash
            if let token = credentials.sessionToken, !token.isEmpty {
                canonicalHeaderMap["x-amz-security-token"] = token
            }

            let sortedKeys = canonicalHeaderMap.keys.sorted()
            let canonicalHeaders = sortedKeys.map { "\($0):\(canonicalHeaderMap[$0]!)\n" }.joined()
            let signedHeaders = sortedKeys.joined(separator: ";")
            let canonicalQuery = parsed.canonicalQuery
            let canonicalRequest = [
                method.uppercased(),
                parsed.path,
                canonicalQuery,
                canonicalHeaders,
                signedHeaders,
                payloadHash,
            ].joined(separator: "\n")

            let credentialScope = "\(dateStamp)/\(credentials.region)/\(service)/aws4_request"
            let stringToSign = [
                "AWS4-HMAC-SHA256",
                amzDate,
                credentialScope,
                Hash.sha256(canonicalRequest),
            ].joined(separator: "\n")

            let kDate = JSONCodec.hmacSHA256(
                key: Array(("AWS4" + credentials.secretAccessKey).utf8),
                message: Array(dateStamp.utf8)
            )
            let kRegion = JSONCodec.hmacSHA256(key: kDate, message: Array(credentials.region.utf8))
            let kService = JSONCodec.hmacSHA256(key: kRegion, message: Array(service.utf8))
            let kSigning = JSONCodec.hmacSHA256(key: kService, message: Array("aws4_request".utf8))
            let signature = JSONCodec.bytesToHex(JSONCodec.hmacSHA256(key: kSigning, message: Array(stringToSign.utf8)))

            let authorization = "AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyId)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
            var out = headers
            out["host"] = parsed.host
            out["x-amz-date"] = amzDate
            out["x-amz-content-sha256"] = payloadHash
            if let token = credentials.sessionToken, !token.isEmpty {
                out["x-amz-security-token"] = token
            }
            out["authorization"] = authorization
            return out
        }

        private struct ParsedURL {
            let host: String
            let path: String
            let canonicalQuery: String
        }

        private static func parseHTTPURL(_ url: String) -> ParsedURL? {
            guard let schemeRange = url.range(of: "://") else { return nil }
            let afterScheme = url[schemeRange.upperBound...]
            let authorityEnd = afterScheme.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? afterScheme.endIndex
            let host = String(afterScheme[..<authorityEnd])
            guard !host.isEmpty else { return nil }
            let rest = afterScheme[authorityEnd...]
            let fragmentSplit = rest.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            let pathAndQuery = fragmentSplit.first ?? ""
            let querySplit = pathAndQuery.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            let rawPath = querySplit.first.map(String.init) ?? ""
            let path = rawPath.isEmpty ? "/" : rawPath
            let rawQuery = querySplit.count > 1 ? String(querySplit[1]) : ""
            let canonicalQuery: String
            if rawQuery.isEmpty {
                canonicalQuery = ""
            } else {
                var pairs: [(String, String)] = []
                for item in rawQuery.split(separator: "&") {
                    let kv = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    let k = String(kv[0])
                    let v = kv.count > 1 ? String(kv[1]) : ""
                    pairs.append((k, v))
                }
                pairs.sort { lhs, rhs in
                    lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 < rhs.0
                }
                canonicalQuery = pairs.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
            }
            return ParsedURL(host: host, path: path, canonicalQuery: canonicalQuery)
        }

        /// Howard Hinnant's civil-from-days conversion: pure calendar arithmetic for AWS SigV4 timestamps.
        static func formatSigV4Date(_ epochSeconds: Int64) -> (amzDate: String, dateStamp: String) {
            let secondsPerDay: Int64 = 86_400
            var days = epochSeconds / secondsPerDay
            var rem = epochSeconds % secondsPerDay
            if rem < 0 {
                rem += secondsPerDay
                days -= 1
            }
            let z = days + 719_468
            let era = (z >= 0 ? z : z - 146_096) / 146_097
            let doe = z - era * 146_097
            let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
            var y = yoe + era * 400
            let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
            let mp = (5 * doy + 2) / 153
            let d = doy - (153 * mp + 2) / 5 + 1
            let m = mp + (mp < 10 ? 3 : -9)
            if m <= 2 { y += 1 }

            let hour = rem / 3600
            let minute = (rem % 3600) / 60
            let second = rem % 60

            func pad(_ value: Int64, _ width: Int) -> String {
                let s = String(value)
                return s.count >= width ? s : String(repeating: "0", count: width - s.count) + s
            }

            let dateStamp = "\(pad(y, 4))\(pad(m, 2))\(pad(d, 2))"
            let amzDate = "\(dateStamp)T\(pad(hour, 2))\(pad(minute, 2))\(pad(second, 2))Z"
            return (amzDate, dateStamp)
        }
    }

    // MARK: - Cache (packages/ai/src/protocols/utils/cache.ts — 6 symbols)

    public enum Cache {
        // parity: ai/src/protocols/utils/cache.ts#Breakpoints [status=implemented hash=00f5a367c0dd]
        public struct Breakpoints: Equatable, Hashable, Sendable {
            public var remaining: Int
            public var dropped: Int

            public init(remaining: Int, dropped: Int = 0) {
                self.remaining = remaining
                self.dropped = dropped
            }
        }

        // parity: ai/src/protocols/utils/cache.ts#newBreakpoints [status=implemented hash=5fb737a7f538]
        public static func newBreakpoints(_ cap: Int) -> Breakpoints {
            Breakpoints(remaining: cap, dropped: 0)
        }

        // parity: ai/src/protocols/utils/cache.ts#take [status=implemented hash=86012ccc8985]
        public static func take(_ breakpoints: inout Breakpoints) -> Bool {
            if breakpoints.remaining <= 0 {
                breakpoints.dropped += 1
                return false
            }
            breakpoints.remaining -= 1
            return true
        }

        // parity: ai/src/protocols/utils/cache.ts#warnDropped [status=implemented hash=d7eb8f01b7ea]
        public static func warnDropped(_ breakpoints: Breakpoints, protocolName: String, cap: Int) -> String? {
            guard breakpoints.dropped > 0 else { return nil }
            return "\(protocolName): dropped \(breakpoints.dropped) cache breakpoint(s); the API allows at most \(cap) per request."
        }

        // parity: ai/src/protocols/utils/cache.ts#cacheControl [status=implemented hash=9aad1911ba1a]
        public static func cacheControl() -> (inout Breakpoints, CacheHint?) -> [String: JSONValue]? {
            { breakpoints, cache in
                guard let cache, take(&breakpoints) else { return nil }
                var obj: [String: JSONValue] = ["type": .string("ephemeral")]
                if let ttl = cache.ttl { obj["ttl"] = .string(ttl) }
                return obj
            }
        }

        // parity: ai/src/protocols/utils/cache.ts#openAIRequestTTL [status=implemented hash=18e1afe81472]
        public static func openAIRequestTTL(_ ttl: CacheTTL?) -> [String: JSONValue] {
            guard let ttl else { return [:] }
            if ttl == "24h" {
                return ["prompt_cache_retention": .string(ttl)]
            }
            return ["prompt_cache_options": .object(["ttl": .string(ttl)])]
        }
    }

    // MARK: - BedrockCache (packages/ai/src/protocols/utils/bedrock-cache.ts — 5 symbols)

    public enum BedrockCache {
        // parity: ai/src/protocols/utils/bedrock-cache.ts#CachePointBlock [status=implemented hash=ed0c8eb1bae9]
        public struct CachePointBlock: Equatable, Hashable, Sendable, Codable {
            public struct CachePoint: Equatable, Hashable, Sendable, Codable {
                public let type: String
                public let ttl: CacheTTL?

                public init(type: String = "default", ttl: CacheTTL? = nil) {
                    self.type = type
                    self.ttl = ttl
                }
            }

            public let cachePoint: CachePoint

            public init(ttl: CacheTTL? = nil) {
                self.cachePoint = CachePoint(type: "default", ttl: ttl)
            }

            public var jsonValue: JSONValue {
                var inner: [String: JSONValue] = ["type": .string(cachePoint.type)]
                if let ttl = cachePoint.ttl { inner["ttl"] = .string(ttl) }
                return .object(["cachePoint": .object(inner)])
            }
        }

        private static let legacyClaude = [
            "anthropic.claude-instant",
            "anthropic.claude-v1",
            "anthropic.claude-v2",
            "anthropic.claude-3-",
        ]

        private static let claude5m = [
            "anthropic.claude-3-5-sonnet-20241022-v2:0",
            "anthropic.claude-3-5-haiku-20241022-v1:0",
            "anthropic.claude-3-7-sonnet-20250219-v1:0",
            "anthropic.claude-sonnet-4-20250514-v1:0",
            "anthropic.claude-opus-4-20250514-v1:0",
            "anthropic.claude-opus-4-1-20250805-v1:0",
        ]

        // parity: ai/src/protocols/utils/bedrock-cache.ts#BEDROCK_BREAKPOINT_CAP [status=implemented hash=7aef5f0c7af6]
        public static let BEDROCK_BREAKPOINT_CAP = 4

        // parity: ai/src/protocols/utils/bedrock-cache.ts#Breakpoints [status=implemented hash=e95c17a5934c]
        public struct Breakpoints: Equatable, Hashable, Sendable {
            public var state: Cache.Breakpoints
            public let supported: Bool
            public let ttl1h: Bool

            public init(state: Cache.Breakpoints, supported: Bool, ttl1h: Bool) {
                self.state = state
                self.supported = supported
                self.ttl1h = ttl1h
            }
        }

        // parity: ai/src/protocols/utils/bedrock-cache.ts#breakpoints [status=implemented hash=e685a04aa4e0]
        public static func breakpoints(for model: ModelDescriptor) -> Breakpoints {
            let short = claude5m.contains { model.id.contains($0) }
            let supported =
                model.compatibility?.cacheFormat == "anthropic"
                || (model.id.contains("anthropic.claude-") && (short || !legacyClaude.contains { model.id.contains($0) }))
            return Breakpoints(
                state: Cache.newBreakpoints(BEDROCK_BREAKPOINT_CAP),
                supported: supported,
                ttl1h: !short
            )
        }

        // parity: ai/src/protocols/utils/bedrock-cache.ts#block [status=implemented hash=e22977b0d6c4]
        public static func block(_ breakpoints: inout Breakpoints, cache: CacheHint?) -> CachePointBlock? {
            guard breakpoints.supported else { return nil }
            guard let cache, cache.type == "ephemeral" || cache.type == "persistent" else { return nil }
            guard Cache.take(&breakpoints.state) else { return nil }
            let ttl = (cache.ttl == "1h" && !breakpoints.ttl1h) ? nil : cache.ttl
            return CachePointBlock(ttl: ttl)
        }
    }

    // MARK: - BedrockMedia (packages/ai/src/protocols/utils/bedrock-media.ts — 5 symbols)

    public enum BedrockMedia {
        // parity: ai/src/protocols/utils/bedrock-media.ts#ImageFormat [status=implemented hash=dd0f2c69d363]
        public enum ImageFormat: String, Equatable, Hashable, Sendable, Codable {
            case png
            case jpeg
            case gif
            case webp
        }

        // parity: ai/src/protocols/utils/bedrock-media.ts#ImageBlock [status=implemented hash=e4ac4f42754a]
        public struct ImageBlock: Equatable, Hashable, Sendable, Codable {
            public let format: ImageFormat
            public let bytes: String

            public init(format: ImageFormat, bytes: String) {
                self.format = format
                self.bytes = bytes
            }

            public var jsonValue: JSONValue {
                .object([
                    "image": .object([
                        "format": .string(format.rawValue),
                        "source": .object(["bytes": .string(bytes)]),
                    ]),
                ])
            }
        }

        // parity: ai/src/protocols/utils/bedrock-media.ts#DocumentFormat [status=implemented hash=d3a5af67876c]
        public enum DocumentFormat: String, Equatable, Hashable, Sendable, Codable {
            case pdf, csv, doc, docx, xls, xlsx, html, txt, md
        }

        // parity: ai/src/protocols/utils/bedrock-media.ts#DocumentBlock [status=implemented hash=5e0351f64a75]
        public struct DocumentBlock: Equatable, Hashable, Sendable, Codable {
            public let format: DocumentFormat
            public let name: String
            public let bytes: String

            public init(format: DocumentFormat, name: String, bytes: String) {
                self.format = format
                self.name = name
                self.bytes = bytes
            }

            public var jsonValue: JSONValue {
                .object([
                    "document": .object([
                        "format": .string(format.rawValue),
                        "name": .string(name),
                        "source": .object(["bytes": .string(bytes)]),
                    ]),
                ])
            }
        }

        private static let imageFormats: [String: ImageFormat] = [
            "image/png": .png,
            "image/jpeg": .jpeg,
            "image/jpg": .jpeg,
            "image/gif": .gif,
            "image/webp": .webp,
        ]

        private static let documentFormats: [String: DocumentFormat] = [
            "application/pdf": .pdf,
            "text/csv": .csv,
            "application/msword": .doc,
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document": .docx,
            "application/vnd.ms-excel": .xls,
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": .xlsx,
            "text/html": .html,
            "text/plain": .txt,
            "text/markdown": .md,
        ]

        private static func documentName(_ filename: String?, names: inout Set<String>) -> String {
            var stem = filename ?? ""
            if let dot = stem.lastIndex(of: ".") {
                stem = String(stem[..<dot])
            }
            var sanitized = ""
            var lastWasSpace = false
            for scalar in stem.unicodeScalars {
                let v = scalar.value
                let allowed =
                    (v >= 0x41 && v <= 0x5A)
                    || (v >= 0x61 && v <= 0x7A)
                    || (v >= 0x30 && v <= 0x39)
                    || v == 0x20 || v == 0x28 || v == 0x29 || v == 0x5B || v == 0x5D || v == 0x2D
                if allowed && v != 0x20 {
                    sanitized.unicodeScalars.append(scalar)
                    lastWasSpace = false
                } else if !lastWasSpace {
                    sanitized.append(" ")
                    lastWasSpace = true
                }
            }
            let trimmed = sanitized.trimmingASCIIWhitespace()
            let base = String(trimmed.prefix(200)).trimmingASCIIWhitespace()
            let resolvedBase = base.isEmpty ? "document" : base
            var candidate = resolvedBase
            var index = 2
            while names.contains(candidate) {
                let suffix = " \(index)"
                let maxPrefix = max(1, 200 - suffix.count)
                candidate = String(resolvedBase.prefix(maxPrefix)).trimmingTrailingASCIIWhitespace() + suffix
                index += 1
            }
            names.insert(candidate)
            return candidate
        }

        private static func validatedBase64(_ part: MediaPart) throws(ProtocolError) -> String {
            let media = try ProviderShared.requireInlineMedia(route: "Bedrock Converse", asset: part.media)
            do {
                let rawBytes = try base64ToBytes(media.base64)
                return bytesToBase64(rawBytes)
            } catch {
                throw ProviderShared.invalidRequest("Bedrock Converse media data must be valid base64")
            }
        }

        // parity: ai/src/protocols/utils/bedrock-media.ts#lower [status=implemented hash=226ecd916c91]
        public static func lower(_ part: MediaPart, documentNames: inout Set<String>) throws(ProtocolError) -> [JSONValue] {
            let mime = part.media.mediaType.lowercased()
            if let imageFormat = imageFormats[mime] {
                let b64 = try validatedBase64(part)
                return [ImageBlock(format: imageFormat, bytes: b64).jsonValue]
            }
            if mime.hasPrefix("image/") {
                throw ProviderShared.invalidRequest("Bedrock Converse does not support image media type \(part.media.mediaType)")
            }
            if let docFormat = documentFormats[mime] {
                let name = documentName(part.filename, names: &documentNames)
                let b64 = try validatedBase64(part)
                let block = DocumentBlock(format: docFormat, name: name, bytes: b64).jsonValue
                if let filename = part.filename, filename != name {
                    let note = "Attached file \(JSONCodec.encode(.string(filename))) has document label \(JSONCodec.encode(.string(name)))."
                    return [.object(["text": .string(note)]), block]
                }
                return [block]
            }
            throw ProviderShared.invalidRequest("Bedrock Converse does not support media type \(part.media.mediaType)")
        }
    }

    // MARK: - ClaudeModel (packages/ai/src/protocols/utils/claude-model.ts — 3 symbols)

    public enum ClaudeModel {
        // parity: ai/src/protocols/utils/claude-model.ts#THINKING_BINDING_BETA [status=implemented hash=7086437b3544]
        public static let THINKING_BINDING_BETA = "thinking-binding-controls-2026-08-01"

        public struct Version: Equatable, Hashable, Sendable {
            public let family: String
            public let major: Int
            public let minor: Int

            public init(family: String, major: Int, minor: Int) {
                self.family = family
                self.major = major
                self.minor = minor
            }
        }

        // parity: ai/src/protocols/utils/claude-model.ts#claudeVersion [status=implemented hash=cedf0a2cffb9]
        public static func claudeVersion(_ id: String) -> Version? {
            let bytes = Array(id.lowercased().utf8)
            let needle = Array("claude-".utf8)
            var searchStart = 0
            while searchStart + needle.count <= bytes.count {
                // Find "claude-" at index 0 or preceded by '.' or '/'
                var matched = false
                if searchStart == 0 || bytes[searchStart - 1] == 0x2E || bytes[searchStart - 1] == 0x2F {
                    matched = true
                    for j in 0..<needle.count {
                        if bytes[searchStart + j] != needle[j] {
                            matched = false
                            break
                        }
                    }
                }
                if matched {
                    var i = searchStart + needle.count
                    let familyStart = i
                    while i < bytes.count && bytes[i] >= 0x61 && bytes[i] <= 0x7A { i += 1 }
                    guard i > familyStart, i < bytes.count, bytes[i] == 0x2D else {
                        searchStart += 1
                        continue
                    }
                    let family = String(decoding: bytes[familyStart..<i], as: UTF8.self)
                    i += 1
                    let majorStart = i
                    while i < bytes.count && bytes[i] >= 0x30 && bytes[i] <= 0x39 { i += 1 }
                    guard i > majorStart,
                          let major = Int(String(decoding: bytes[majorStart..<i], as: UTF8.self))
                    else {
                        searchStart += 1
                        continue
                    }
                    var minor = 0
                    if i < bytes.count && (bytes[i] == 0x2E || bytes[i] == 0x2D) {
                        let sepIdx = i
                        var mIdx = i + 1
                        while mIdx < bytes.count && bytes[mIdx] >= 0x30 && bytes[mIdx] <= 0x39 { mIdx += 1 }
                        let digitCount = mIdx - (sepIdx + 1)
                        let endValid = mIdx == bytes.count || bytes[mIdx] == 0x2D || bytes[mIdx] == 0x3A || bytes[mIdx] == 0x40
                        if digitCount >= 1 && digitCount <= 2 && endValid,
                           let parsedMinor = Int(String(decoding: bytes[(sepIdx + 1)..<mIdx], as: UTF8.self)) {
                            minor = parsedMinor
                            i = mIdx
                        }
                    }
                    if i == bytes.count || bytes[i] == 0x2D || bytes[i] == 0x3A || bytes[i] == 0x40 {
                        return Version(family: family, major: major, minor: minor)
                    }
                }
                searchStart += 1
            }
            return nil
        }

        // parity: ai/src/protocols/utils/claude-model.ts#supportsThinkingBlockBinding [status=implemented hash=6b84b77ad74d]
        public static func supportsThinkingBlockBinding(_ model: ModelDescriptor) -> Bool {
            if let override = model.compatibility?.supportsThinkingBlockBinding { return override }
            guard let version = claudeVersion(model.id) else { return false }
            return version.major > 5 || (version.major == 5 && version.minor >= 1)
        }
    }

    // MARK: - GatewayProtocol (packages/ai/src/protocols/utils/gateway-protocol.ts — 1 symbol)

    public enum GatewayProtocol {
        public struct Wrapper: Sendable {
            public let id: String
            public let innerProtocolID: String
            public let prepare: @Sendable (LLMRequest) throws(ProtocolError) -> (request: LLMRequest, bodyOverlay: [String: JSONValue])

            public init(
                id: String,
                innerProtocolID: String,
                prepare: @escaping @Sendable (LLMRequest) throws(ProtocolError) -> (request: LLMRequest, bodyOverlay: [String: JSONValue])
            ) {
                self.id = id
                self.innerProtocolID = innerProtocolID
                self.prepare = prepare
            }

            public static func extractGatewayMetadata(from event: [String: JSONValue]) -> [String: JSONValue]? {
                var merged: [String: JSONValue]? = nil
                func take(_ holder: [String: JSONValue]?) {
                    guard let pm = JSONCodec.objectValue(holder?["provider_metadata"]),
                          let gw = JSONCodec.objectValue(pm["gateway"]) else { return }
                    merged = JSONCodec.mergeObjects(merged, gw)
                }
                take(event)
                take(JSONCodec.objectValue(event["response"]))
                if let choices = JSONCodec.arrayValue(event["choices"]) {
                    for choice in choices {
                        take(JSONCodec.objectValue(JSONCodec.objectValue(choice)?["delta"]))
                    }
                }
                return merged
            }

            public static func attachGatewayMetadata(
                _ events: [LLMEvent],
                gateway: [String: JSONValue]?
            ) -> [LLMEvent] {
                guard let gateway, events.contains(where: \.isFinish) else { return events }
                return events.map { event in
                    guard case .finish(let reason, let usage, let existing) = event else { return event }
                    var meta = existing ?? [:]
                    meta["gateway"] = gateway
                    return .finish(reason: reason, usage: usage, providerMetadata: meta)
                }
            }
        }

        // parity: ai/src/protocols/utils/gateway-protocol.ts#gatewayProtocol [status=adapted hash=6a971fca7535]
        public static func gatewayProtocol(
            id: String,
            innerProtocolID: String,
            prepare: @escaping @Sendable (LLMRequest) throws(ProtocolError) -> (request: LLMRequest, bodyOverlay: [String: JSONValue])
        ) -> Wrapper {
            Wrapper(id: id, innerProtocolID: innerProtocolID, prepare: prepare)
        }
    }

    // MARK: - GeminiGenerateContent (packages/ai/src/protocols/utils/gemini-generate-content.ts — 12 symbols)

    public enum GeminiGenerateContent {
        public struct UsageMetadata: Equatable, Hashable, Sendable, Codable {
            public let promptTokenCount: Double?
            public let candidatesTokenCount: Double?
            public let totalTokenCount: Double?

            public init(promptTokenCount: Double? = nil, candidatesTokenCount: Double? = nil, totalTokenCount: Double? = nil) {
                self.promptTokenCount = promptTokenCount
                self.candidatesTokenCount = candidatesTokenCount
                self.totalTokenCount = totalTokenCount
            }
        }

        public struct Candidate: Equatable, Hashable, Sendable {
            public let parts: [JSONValue]
            public let finishReason: String?

            public init(parts: [JSONValue] = [], finishReason: String? = nil) {
                self.parts = parts
                self.finishReason = finishReason
            }
        }

        public struct PromptFeedback: Equatable, Hashable, Sendable, Codable {
            public let blockReason: String?
            public let blockReasonMessage: String?

            public init(blockReason: String? = nil, blockReasonMessage: String? = nil) {
                self.blockReason = blockReason
                self.blockReasonMessage = blockReasonMessage
            }
        }

        public struct Chunk: Equatable, Hashable, Sendable {
            public let candidates: [Candidate]
            public let promptFeedback: PromptFeedback?
            public let usageMetadata: UsageMetadata?
            public let modelVersion: String?
            public let responseId: String?

            public init(
                candidates: [Candidate] = [],
                promptFeedback: PromptFeedback? = nil,
                usageMetadata: UsageMetadata? = nil,
                modelVersion: String? = nil,
                responseId: String? = nil
            ) {
                self.candidates = candidates
                self.promptFeedback = promptFeedback
                self.usageMetadata = usageMetadata
                self.modelVersion = modelVersion
                self.responseId = responseId
            }
        }

        // parity: ai/src/protocols/utils/gemini-generate-content.ts#chunk [status=implemented hash=073312d213cf]
        public static func chunk(from json: [String: JSONValue]) -> Chunk {
            let candidates: [Candidate] = (JSONCodec.arrayValue(json["candidates"]) ?? []).map { entry in
                let obj = JSONCodec.objectValue(entry) ?? [:]
                let content = JSONCodec.objectValue(obj["content"])
                let parts = JSONCodec.arrayValue(content?["parts"]) ?? []
                let finishReason = JSONCodec.stringValue(obj["finishReason"])
                return Candidate(parts: parts, finishReason: finishReason)
            }
            let feedback: PromptFeedback? = JSONCodec.objectValue(json["promptFeedback"]).map { fb in
                PromptFeedback(
                    blockReason: JSONCodec.stringValue(fb["blockReason"]),
                    blockReasonMessage: JSONCodec.stringValue(fb["blockReasonMessage"])
                )
            }
            let usageMeta: UsageMetadata? = JSONCodec.objectValue(json["usageMetadata"]).map { u in
                UsageMetadata(
                    promptTokenCount: JSONCodec.doubleValue(u["promptTokenCount"]),
                    candidatesTokenCount: JSONCodec.doubleValue(u["candidatesTokenCount"]),
                    totalTokenCount: JSONCodec.doubleValue(u["totalTokenCount"])
                )
            }
            return Chunk(
                candidates: candidates,
                promptFeedback: feedback,
                usageMetadata: usageMeta,
                modelVersion: JSONCodec.stringValue(json["modelVersion"]),
                responseId: JSONCodec.stringValue(json["responseId"])
            )
        }

        // parity: ai/src/protocols/utils/gemini-generate-content.ts#Metadata [status=implemented hash=16468a4596a5]
        public struct Metadata: Equatable, Hashable, Sendable {
            public let usage: UsageMetadata?
            public let finishReason: String?
            public let modelVersion: String?
            public let responseId: String?

            public init(
                usage: UsageMetadata? = nil,
                finishReason: String? = nil,
                modelVersion: String? = nil,
                responseId: String? = nil
            ) {
                self.usage = usage
                self.finishReason = finishReason
                self.modelVersion = modelVersion
                self.responseId = responseId
            }
        }

        // parity: ai/src/protocols/utils/gemini-generate-content.ts#track [status=implemented hash=c90f61666699]
        public static func track(_ state: Metadata, chunk: Chunk) -> Metadata {
            Metadata(
                usage: chunk.usageMetadata ?? state.usage,
                finishReason: chunk.candidates.first?.finishReason ?? state.finishReason,
                modelVersion: chunk.modelVersion ?? state.modelVersion,
                responseId: chunk.responseId ?? state.responseId
            )
        }

        // parity: ai/src/protocols/utils/gemini-generate-content.ts#blocked [status=implemented hash=93497cf1734d]
        public static func blocked(name: String, chunk: Chunk, frame: String) -> ProtocolError? {
            guard let reason = chunk.promptFeedback?.blockReason else { return nil }
            let suffix = chunk.promptFeedback?.blockReasonMessage.map { ": \($0)" } ?? ""
            return ProtocolError(kind: .contentPolicy, message: "\(name) blocked the request (\(reason))\(suffix)", body: frame)
        }

        private static let contentFilterReasons: Set<String> = [
            "IMAGE_SAFETY",
            "RECITATION",
            "SAFETY",
            "BLOCKLIST",
            "PROHIBITED_CONTENT",
            "SPII",
            "MODEL_ARMOR",
            "IMAGE_PROHIBITED_CONTENT",
            "IMAGE_RECITATION",
            "LANGUAGE",
        ]

        // parity: ai/src/protocols/utils/gemini-generate-content.ts#contentFiltered [status=implemented hash=66295919fab9]
        public static func contentFiltered(_ finishReason: String?) -> Bool {
            guard let finishReason else { return false }
            return contentFilterReasons.contains(finishReason)
        }

        // parity: ai/src/protocols/utils/gemini-generate-content.ts#withheld [status=implemented hash=d2f5a08f4a42]
        public static func withheld(name: String, chunk: Chunk, frame: String) -> ProtocolError? {
            guard let reason = chunk.candidates.first?.finishReason, contentFiltered(reason) else { return nil }
            return ProtocolError(kind: .contentPolicy, message: "\(name) withheld its output (\(reason))", body: frame)
        }

        // parity: ai/src/protocols/utils/gemini-generate-content.ts#usage [status=implemented hash=b9d6bd77749a]
        public static func usage(_ usage: UsageMetadata?) -> MediaUsage? {
            guard let usage else { return nil }
            var details: [String: JSONValue] = [:]
            if let p = usage.promptTokenCount { details["promptTokenCount"] = .double(p) }
            if let c = usage.candidatesTokenCount { details["candidatesTokenCount"] = .double(c) }
            if let t = usage.totalTokenCount { details["totalTokenCount"] = .double(t) }
            return .tokens(
                input: usage.promptTokenCount,
                output: usage.candidatesTokenCount,
                total: ProviderShared.totalTokens(usage.promptTokenCount, usage.candidatesTokenCount, usage.totalTokenCount),
                details: ["google": .object(details)]
            )
        }

        // parity: ai/src/protocols/utils/gemini-generate-content.ts#providerMetadata [status=implemented hash=b34c63f847c8]
        public static func providerMetadata(_ state: Metadata) -> ProviderMetadata {
            var google: [String: JSONValue] = [:]
            if let f = state.finishReason { google["finishReason"] = .string(f) }
            if let m = state.modelVersion { google["modelVersion"] = .string(m) }
            if let r = state.responseId { google["responseId"] = .string(r) }
            return ["google": google]
        }

        // parity: ai/src/protocols/utils/gemini-generate-content.ts#path [status=implemented hash=6112e7276861]
        public static func path(model: String, streaming: Bool) -> String {
            streaming ? "/models/\(model):streamGenerateContent?alt=sse" : "/models/\(model):generateContent"
        }

        // parity: ai/src/protocols/utils/gemini-generate-content.ts#frames [status=adapted hash=00d8d4812298]
        public static func frames(from bytes: [UInt8], streaming: Bool) -> [String] {
            if !streaming {
                return [String(decoding: bytes, as: UTF8.self)]
            }
            var parser = SSEParser()
            var out = parser.feed(bytes).map(\.data)
            out.append(contentsOf: parser.finish().map(\.data))
            return out
        }

        // parity: ai/src/protocols/utils/gemini-generate-content.ts#toolMedia [status=implemented hash=339567eb2f10]
        public static func toolMedia(_ item: ToolFileContent) -> MediaAsset {
            if item.mime.hasPrefix("video/") && item.uri.hasPrefix("gs://") {
                return MediaAsset.ref(provider: "google", id: item.uri, mediaType: item.mime)
            }
            return ProviderShared.toolFileMedia(item).media
        }

        // parity: ai/src/protocols/utils/gemini-generate-content.ts#mediaPart [status=implemented hash=5a23bf3e58c2]
        public static func mediaPart(route: String, asset: MediaAsset) throws(ProtocolError) -> [String: JSONValue] {
            let fileUri: String?
            if asset.kind == .video, case .url(let u) = asset.source,
               u.lowercased().hasPrefix("http://") || u.lowercased().hasPrefix("https://") {
                fileUri = u
            } else {
                fileUri = MediaInput.refID(asset, provider: "google")
            }
            if let fileUri {
                return ["fileData": .object(["mimeType": .string(asset.mediaType), "fileUri": .string(fileUri)])]
            }
            let inline = try ProviderShared.requireInlineMedia(route: route, asset: asset)
            return ["inlineData": .object(["mimeType": .string(inline.mime), "data": .string(inline.base64)])]
        }
    }

    // MARK: - GeminiJsonSchema (packages/ai/src/protocols/utils/gemini-json-schema.ts — 4 symbols)

    public enum GeminiJsonSchema {
        // parity: ai/src/protocols/utils/gemini-json-schema.ts#SCHEMA_MAPS [status=implemented hash=471a16c1c421]
        public static let SCHEMA_MAPS: Set<String> = [
            "properties",
            "patternProperties",
            "$defs",
            "definitions",
            "dependentSchemas",
            "dependencies",
        ]

        // parity: ai/src/protocols/utils/gemini-json-schema.ts#VALUES [status=implemented hash=6e1213663106]
        public static let VALUES: Set<String> = [
            "const",
            "default",
            "enum",
            "examples",
            "dependentRequired",
        ]

        // parity: ai/src/protocols/utils/gemini-json-schema.ts#mapValues [status=implemented hash=bb13e241a0b8]
        public static func mapValues(
            _ record: [String: JSONValue],
            _ transform: (JSONValue, String) -> JSONValue
        ) -> [String: JSONValue] {
            var result: [String: JSONValue] = [:]
            result.reserveCapacity(record.count)
            for (k, v) in record {
                result[k] = transform(v, k)
            }
            return result
        }

        private static func normalizeNode(_ schema: JSONValue) -> JSONValue {
            switch schema {
            case .array(let items):
                return .array(items.map(normalizeNode))
            case .object(let obj):
                let properties = JSONCodec.objectValue(obj["properties"])
                var out: [String: JSONValue] = [:]
                for (key, value) in obj {
                    if VALUES.contains(key) {
                        out[key] = value
                        continue
                    }
                    if SCHEMA_MAPS.contains(key), case .object(let sub) = value {
                        out[key] = .object(mapValues(sub) { v, _ in normalizeNode(v) })
                        continue
                    }
                    if key == "required", let properties, case .array(let req) = value {
                        let filtered = req.filter {
                            if case .string(let name) = $0 { return properties[name] != nil }
                            return false
                        }
                        out[key] = .array(filtered)
                        continue
                    }
                    if key == "exclusiveMinimum", case .bool(let b) = value {
                        if b, let minVal = obj["minimum"], JSONCodec.doubleValue(minVal) != nil {
                            out[key] = minVal
                        }
                        continue
                    }
                    if key == "exclusiveMaximum", case .bool(let b) = value {
                        if b, let maxVal = obj["maximum"], JSONCodec.doubleValue(maxVal) != nil {
                            out[key] = maxVal
                        }
                        continue
                    }
                    if key == "minimum", case .bool(true) = obj["exclusiveMinimum"] {
                        continue
                    }
                    if key == "maximum", case .bool(true) = obj["exclusiveMaximum"] {
                        continue
                    }
                    if key == "items", case .array(let tupleItems) = value {
                        out["prefixItems"] = .array(tupleItems.map(normalizeNode))
                        continue
                    }
                    if key == "additionalItems", case .array = obj["items"] {
                        out["items"] = normalizeNode(value)
                        continue
                    }
                    out[key] = normalizeNode(value)
                }
                return .object(out)
            default:
                return schema
            }
        }

        private static func cutLoops(_ schema: JSONValue, target: String, safe: Bool) -> JSONValue {
            switch schema {
            case .array(let items):
                return .array(items.map { cutLoops($0, target: target, safe: safe) })
            case .object(let obj):
                if case .string(target) = obj["$ref"], !safe {
                    return .object([:])
                }
                let requiredNames: Set<String> = Set((JSONCodec.arrayValue(obj["required"]) ?? []).compactMap {
                    JSONCodec.stringValue($0)
                })
                let minItemsPositive = (JSONCodec.doubleValue(obj["minItems"]) ?? 0) > 0
                return .object(mapValues(obj) { value, key in
                    if VALUES.contains(key) { return value }
                    if key == "items" {
                        return cutLoops(value, target: target, safe: safe || !minItemsPositive)
                    }
                    if key == "properties", case .object(let props) = value {
                        return .object(mapValues(props) { child, name in
                            cutLoops(child, target: target, safe: safe || !requiredNames.contains(name))
                        })
                    }
                    if SCHEMA_MAPS.contains(key), case .object(let sub) = value {
                        return .object(mapValues(sub) { child, _ in cutLoops(child, target: target, safe: safe) })
                    }
                    return cutLoops(value, target: target, safe: safe)
                })
            default:
                return schema
            }
        }

        // parity: ai/src/protocols/utils/gemini-json-schema.ts#normalize [status=implemented hash=ec0d7918f47e]
        public static func normalize(_ schema: [String: JSONValue]) -> [String: JSONValue] {
            guard case .object(let normalized) = normalizeNode(.object(schema)) else { return [:] }
            let withDefsCut = mapValues(normalized) { value, key in
                if (key == "$defs" || key == "definitions"), case .object(let defs) = value {
                    return .object(mapValues(defs) { def, name in
                        cutLoops(def, target: "#/\(key)/\(name)", safe: false)
                    })
                }
                return value
            }
            guard case .object(let result) = cutLoops(.object(withDefsCut), target: "#", safe: false) else {
                return [:]
            }
            return result
        }
    }

    // MARK: - ImageSizing (packages/ai/src/protocols/utils/image-sizing.ts — 8 symbols)

    public enum ImageSizing {
        // parity: ai/src/protocols/utils/image-sizing.ts#Size [status=implemented hash=94be494f81be]
        public struct Size: Equatable, Hashable, Sendable, Codable {
            public let width: Int
            public let height: Int

            public init(width: Int, height: Int) {
                self.width = width
                self.height = height
            }
        }

        // parity: ai/src/protocols/utils/image-sizing.ts#Shape [status=implemented hash=5aaca0cfda33]
        public struct Shape: Equatable, Hashable, Sendable, Codable {
            public let aspect: String?
            public let resolution: String?

            public init(aspect: String? = nil, resolution: String? = nil) {
                self.aspect = aspect
                self.resolution = resolution
            }
        }

        // parity: ai/src/protocols/utils/image-sizing.ts#Limits [status=implemented hash=d26f475fe581]
        public struct Limits: Equatable, Hashable, Sendable, Codable {
            public let multiple: Int
            public let minEdge: Int?
            public let maxEdge: Int?
            public let minPixels: Int?
            public let maxPixels: Int?
            public let maxRatio: Double?

            public init(
                multiple: Int,
                minEdge: Int? = nil,
                maxEdge: Int? = nil,
                minPixels: Int? = nil,
                maxPixels: Int? = nil,
                maxRatio: Double? = nil
            ) {
                self.multiple = multiple
                self.minEdge = minEdge
                self.maxEdge = maxEdge
                self.minPixels = minPixels
                self.maxPixels = maxPixels
                self.maxRatio = maxRatio
            }
        }

        // parity: ai/src/protocols/utils/image-sizing.ts#isRequested [status=implemented hash=453d310eae69]
        public static func isRequested(_ shape: Shape) -> Bool {
            shape.aspect != nil || shape.resolution != nil
        }

        // parity: ai/src/protocols/utils/image-sizing.ts#tier [status=implemented hash=dc676e412275]
        public static func tier(_ resolution: String) -> Double? {
            let lower = resolution.lowercased()
            guard lower.hasSuffix("k") else { return nil }
            let numStr = String(lower.dropLast())
            let bytes = Array(numStr.utf8)
            guard let first = bytes.first, let last = bytes.last,
                  first >= 0x30 && first <= 0x39,
                  last >= 0x30 && last <= 0x39
            else {
                return nil
            }
            var sawDot = false
            for byte in bytes {
                if byte == 0x2E {
                    if sawDot { return nil }
                    sawDot = true
                } else if byte < 0x30 || byte > 0x39 {
                    return nil
                }
            }
            return Double(numStr)
        }

        private static func aspectRatio(_ shape: Shape) -> Double {
            let parts = (shape.aspect ?? "1:1").split(separator: ":")
            guard parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]), h > 0 else {
                return 1.0
            }
            return w / h
        }

        private static func targetPixels(_ shape: Shape) -> Double {
            let edge = (tier(shape.resolution ?? "1K") ?? 1.0) * 1024.0
            return edge * edge
        }

        // parity: ai/src/protocols/utils/image-sizing.ts#fit [status=implemented hash=2fe52554051b]
        public static func fit(_ shape: Shape, limits: Limits) -> Size {
            let maxRatio = limits.maxRatio ?? Double.infinity
            let ratio = min(maxRatio, max(1.0 / maxRatio, aspectRatio(shape)))
            let area = targetPixels(shape)
            let width = (area * ratio).squareRoot()
            let height = (area / ratio).squareRoot()
            let upEdge = Double(limits.minEdge ?? 0) / min(width, height)
            let upPixels = (Double(limits.minPixels ?? 0) / area).squareRoot()
            let up = max(upEdge, upPixels)
            let scaled = max(1.0, up)
            let downEdge = (limits.maxEdge.map(Double.init) ?? Double.infinity) / (max(width, height) * scaled)
            let downPixels = ((limits.maxPixels.map(Double.init) ?? Double.infinity) / area).squareRoot() / scaled
            let down = min(downEdge, downPixels)
            let mult = Double(limits.multiple)

            func snap(_ edge: Double) -> Int {
                let raw = (edge * scaled * min(1.0, down)) / mult
                let fixed = (raw * 1_000_000.0).rounded(.toNearestOrAwayFromZero) / 1_000_000.0
                let rounded: Double
                if down <= 1.0 {
                    rounded = fixed.rounded(.down)
                } else if up >= 1.0 {
                    rounded = fixed.rounded(.up)
                } else {
                    rounded = (fixed + 0.5).rounded(.down)
                }
                return max(limits.multiple, Int(rounded) * limits.multiple)
            }

            return Size(width: snap(width), height: snap(height))
        }

        // parity: ai/src/protocols/utils/image-sizing.ts#nearest [status=implemented hash=a27ae97ff808]
        public static func nearest(_ shape: Shape, sizes: [Size]) -> Size {
            precondition(!sizes.isEmpty, "ImageSizing.nearest requires at least one candidate size")
            let targetRatio = naturalLog(aspectRatio(shape))
            let targetArea = naturalLog(targetPixels(shape))
            func distance(_ size: Size) -> (Double, Double) {
                (
                    abs(naturalLog(Double(size.width) / Double(size.height)) - targetRatio),
                    abs(naturalLog(Double(size.width * size.height)) - targetArea)
                )
            }
            var best = sizes[0]
            var bestDist = distance(best)
            for candidate in sizes.dropFirst() {
                let candDist = distance(candidate)
                if abs(candDist.0 - bestDist.0) > 1e-9 {
                    if candDist.0 < bestDist.0 {
                        best = candidate
                        bestDist = candDist
                    }
                } else if candDist.1 < bestDist.1 {
                    best = candidate
                    bestDist = candDist
                }
            }
            return best
        }

        private static func gcd(_ a: Int, _ b: Int) -> Int {
            b == 0 ? a : gcd(b, a % b)
        }

        private static func formatTwoDecimal(_ value: Double) -> String {
            let hundredths = Int((value * 100.0).rounded(.toNearestOrAwayFromZero))
            let whole = hundredths / 100
            let frac = abs(hundredths % 100)
            let fracStr = frac < 10 ? "0\(frac)" : "\(frac)"
            return "\(whole).\(fracStr)"
        }

        private static func describePure(_ size: Size) -> String {
            let d = gcd(size.width, size.height)
            let w = size.width / d
            let h = size.height / d
            let ratio = (w <= 32 && h <= 32) ? "\(w):\(h)" : "\(formatTwoDecimal(Double(size.width) / Double(size.height))):1"
            return "\(size.width)x\(size.height) (\(ratio))"
        }

        private static func missed(_ shape: Shape, _ size: Size) -> String? {
            let aspectMissed = shape.aspect != nil
                && abs(naturalLog((Double(size.width) / Double(size.height)) / aspectRatio(shape))) > 0.02
            let reqTier = shape.resolution.flatMap(tier)
            let resolutionMissed: Bool
            if shape.resolution != nil {
                if let reqTier {
                    resolutionMissed = abs(logBase2(Double(size.width * size.height).squareRoot() / (reqTier * 1024.0))) > 0.5
                } else {
                    resolutionMissed = true
                }
            } else {
                resolutionMissed = false
            }
            if !aspectMissed && !resolutionMissed { return nil }
            return [shape.aspect, shape.resolution].compactMap { $0 }.joined(separator: " at ")
        }

        // parity: ai/src/protocols/utils/image-sizing.ts#exact [status=implemented hash=10d09319d83f]
        public static func exact(route: MediaIdentity, shape: Shape, limits: Limits) throws(ProtocolError) -> Size? {
            guard isRequested(shape) else { return nil }
            let size = fit(shape, limits: limits)
            if let requested = missed(shape, size) {
                throw route.unsupported(
                    shape.resolution == nil ? "media.aspect" : "media.resolution",
                    "\(route.name) can't render \(requested); the closest size it takes is \(describePure(size)). Change aspect or resolution, or set the size in providerOptions"
                )
            }
            return size
        }
    }

    // MARK: - Lifecycle (packages/ai/src/protocols/utils/lifecycle.ts — 10 symbols)

    public enum Lifecycle {
        // parity: ai/src/protocols/utils/lifecycle.ts#State [status=implemented hash=b1c7cda6a5fb]
        public struct State: Equatable, Hashable, Sendable {
            public let stepStarted: Bool
            public let text: Set<String>
            public let reasoning: Set<String>
            // Preserve insertion order for deterministic block closing on finish.
            public let textOrder: [String]
            public let reasoningOrder: [String]

            public init(
                stepStarted: Bool = false,
                text: Set<String> = [],
                reasoning: Set<String> = [],
                textOrder: [String] = [],
                reasoningOrder: [String] = []
            ) {
                self.stepStarted = stepStarted
                self.text = text
                self.reasoning = reasoning
                self.textOrder = textOrder
                self.reasoningOrder = reasoningOrder
            }
        }

        // parity: ai/src/protocols/utils/lifecycle.ts#initial [status=implemented hash=2d2426124295]
        public static func initial() -> State {
            State()
        }

        // parity: ai/src/protocols/utils/lifecycle.ts#stepStart [status=implemented hash=07ea9a381eaa]
        public static func stepStart(_ state: State, events: inout [LLMEvent]) -> State {
            if state.stepStarted { return state }
            events.append(.stepStart(index: 0))
            return State(
                stepStarted: true,
                text: state.text,
                reasoning: state.reasoning,
                textOrder: state.textOrder,
                reasoningOrder: state.reasoningOrder
            )
        }

        // parity: ai/src/protocols/utils/lifecycle.ts#textStart [status=implemented hash=ac856506825b]
        public static func textStart(
            _ state: State,
            events: inout [LLMEvent],
            id: String,
            providerMetadata: ProviderMetadata? = nil
        ) -> State {
            if state.text.contains(id) { return state }
            let stepped = stepStart(state, events: &events)
            events.append(.textStart(id: id, providerMetadata: providerMetadata))
            var nextText = stepped.text
            nextText.insert(id)
            return State(
                stepStarted: stepped.stepStarted,
                text: nextText,
                reasoning: stepped.reasoning,
                textOrder: stepped.textOrder + [id],
                reasoningOrder: stepped.reasoningOrder
            )
        }

        // parity: ai/src/protocols/utils/lifecycle.ts#textDelta [status=implemented hash=9cac67e319b4]
        public static func textDelta(
            _ state: State,
            events: inout [LLMEvent],
            id: String,
            text: String,
            providerMetadata: ProviderMetadata? = nil
        ) -> State {
            let started = textStart(state, events: &events, id: id)
            events.append(.textDelta(id: id, text: text, providerMetadata: providerMetadata))
            return started
        }

        // parity: ai/src/protocols/utils/lifecycle.ts#reasoningStart [status=implemented hash=f6e0dedf81ab]
        public static func reasoningStart(
            _ state: State,
            events: inout [LLMEvent],
            id: String,
            providerMetadata: ProviderMetadata? = nil
        ) -> State {
            if state.reasoning.contains(id) { return state }
            let stepped = stepStart(state, events: &events)
            events.append(.reasoningStart(id: id, providerMetadata: providerMetadata))
            var nextReasoning = stepped.reasoning
            nextReasoning.insert(id)
            return State(
                stepStarted: stepped.stepStarted,
                text: stepped.text,
                reasoning: nextReasoning,
                textOrder: stepped.textOrder,
                reasoningOrder: stepped.reasoningOrder + [id]
            )
        }

        // parity: ai/src/protocols/utils/lifecycle.ts#reasoningDelta [status=implemented hash=5e57b0e6264c]
        public static func reasoningDelta(
            _ state: State,
            events: inout [LLMEvent],
            id: String,
            text: String,
            providerMetadata: ProviderMetadata? = nil
        ) -> State {
            let started = reasoningStart(state, events: &events, id: id, providerMetadata: providerMetadata)
            events.append(.reasoningDelta(id: id, text: text, providerMetadata: providerMetadata))
            return started
        }

        // parity: ai/src/protocols/utils/lifecycle.ts#reasoningEnd [status=implemented hash=75288d840501]
        public static func reasoningEnd(
            _ state: State,
            events: inout [LLMEvent],
            id: String,
            providerMetadata: ProviderMetadata? = nil,
            text: String? = nil
        ) -> State {
            guard state.reasoning.contains(id) else { return state }
            let stepped = stepStart(state, events: &events)
            events.append(.reasoningEnd(id: id, text: text, providerMetadata: providerMetadata))
            var nextReasoning = stepped.reasoning
            nextReasoning.remove(id)
            return State(
                stepStarted: stepped.stepStarted,
                text: stepped.text,
                reasoning: nextReasoning,
                textOrder: stepped.textOrder,
                reasoningOrder: stepped.reasoningOrder.filter { $0 != id }
            )
        }

        // parity: ai/src/protocols/utils/lifecycle.ts#textEnd [status=implemented hash=9a2376bc57a7]
        public static func textEnd(
            _ state: State,
            events: inout [LLMEvent],
            id: String,
            providerMetadata: ProviderMetadata? = nil,
            text: String? = nil
        ) -> State {
            guard state.text.contains(id) else { return state }
            let stepped = stepStart(state, events: &events)
            events.append(.textEnd(id: id, text: text, providerMetadata: providerMetadata))
            var nextText = stepped.text
            nextText.remove(id)
            return State(
                stepStarted: stepped.stepStarted,
                text: nextText,
                reasoning: stepped.reasoning,
                textOrder: stepped.textOrder.filter { $0 != id },
                reasoningOrder: stepped.reasoningOrder
            )
        }

        // parity: ai/src/protocols/utils/lifecycle.ts#finish [status=implemented hash=8bc9fd9876f7]
        public static func finish(
            _ state: State,
            events: inout [LLMEvent],
            reason: FinishReasonDetails,
            usage: Usage? = nil,
            providerMetadata: ProviderMetadata? = nil
        ) -> State {
            let stepped = stepStart(state, events: &events)
            for id in stepped.reasoningOrder {
                events.append(.reasoningEnd(id: id))
            }
            for id in stepped.textOrder {
                events.append(.textEnd(id: id))
            }
            events.append(.stepFinish(index: 0, reason: reason, usage: usage, providerMetadata: providerMetadata))
            events.append(.finish(reason: reason, usage: usage, providerMetadata: providerMetadata))
            return State(stepStarted: false, text: [], reasoning: [], textOrder: [], reasoningOrder: [])
        }
    }

    // MARK: - MediaInput (packages/ai/src/protocols/utils/media-input.ts — 7 symbols)

    public enum MediaInput {
        public struct MultipartField: Equatable, Hashable, Sendable {
            public let name: String
            public let value: String

            public init(name: String, value: String) {
                self.name = name
                self.value = value
            }
        }

        public struct BinaryBlob: Equatable, Hashable, Sendable {
            public let data: [UInt8]
            public let mediaType: String

            public init(data: [UInt8], mediaType: String) {
                self.data = data
                self.mediaType = mediaType
            }
        }

        // parity: ai/src/protocols/utils/media-input.ts#inlineBytes [status=implemented hash=39e5a5fcb1cd]
        public static func inlineBytes(route: String, asset: MediaAsset) throws(ProtocolError) -> [UInt8] {
            if case .bytes(let data) = asset.source { return data }
            guard let inline = asset.inline() else {
                throw ProviderShared.inlineRequired(route: route, asset: asset)
            }
            do {
                return try base64ToBytes(inline.base64)
            } catch {
                throw ProviderShared.invalidRequest("\(route) media contains invalid base64 data")
            }
        }

        // parity: ai/src/protocols/utils/media-input.ts#blob [status=implemented hash=9aaa88f42bac]
        public static func blob(data: [UInt8], mediaType: String) -> BinaryBlob {
            BinaryBlob(data: data, mediaType: mediaType)
        }

        private static func scalarString(_ value: JSONValue) -> String? {
            switch value {
            case .string(let s): return s
            case .int(let i): return String(i)
            case .double(let d): return String(d)
            case .bool(let b): return b ? "true" : "false"
            default: return nil
            }
        }

        // parity: ai/src/protocols/utils/media-input.ts#query [status=implemented hash=ade77bf45194]
        public static func query(route: String, values: [String: JSONValue]) throws(ProtocolError) -> [String: [String]] {
            var out: [String: [String]] = [:]
            for (key, value) in values {
                if case .null = value { continue }
                if let scalar = scalarString(value) {
                    out[key] = [scalar]
                } else if case .array(let arr) = value {
                    var rendered: [String] = []
                    for item in arr {
                        guard let s = scalarString(item) else {
                            throw ProviderShared.invalidRequest("\(route) cannot send \"\(key)\" as a query parameter")
                        }
                        rendered.append(s)
                    }
                    out[key] = rendered
                } else {
                    throw ProviderShared.invalidRequest("\(route) cannot send \"\(key)\" as a query parameter")
                }
            }
            return out
        }

        // parity: ai/src/protocols/utils/media-input.ts#refID [status=implemented hash=5a1693ebceff]
        public static func refID(_ asset: MediaAsset, provider: String) -> String? {
            if case .ref(let refProvider, let id) = asset.source, refProvider == provider {
                return id
            }
            return nil
        }

        // parity: ai/src/protocols/utils/media-input.ts#decodedAsset [status=implemented hash=a308ee0c1c43]
        public static func decodedAsset(
            invalid: (String) -> ProtocolError,
            label: String,
            data: String,
            mediaType: String?,
            providerMetadata: ProviderMetadata? = nil
        ) throws(ProtocolError) -> MediaAsset {
            let bytes: [UInt8]
            do {
                bytes = try base64ToBytes(data)
            } catch {
                throw invalid("\(label) contains invalid base64 data")
            }
            return MediaAsset.bytes(bytes, mediaType: mediaType, providerMetadata: providerMetadata)
        }

        // parity: ai/src/protocols/utils/media-input.ts#imageOutput [status=implemented hash=4819a7948112]
        public static func imageOutput(
            invalid: (String) -> ProtocolError,
            label: String,
            b64Json: String?,
            url: String?,
            mediaType: String?,
            providerMetadata: ProviderMetadata? = nil
        ) throws(ProtocolError) -> MediaAsset {
            if let b64 = b64Json, !b64.isEmpty {
                return try decodedAsset(invalid: invalid, label: label, data: b64, mediaType: mediaType, providerMetadata: providerMetadata)
            }
            if let url, url.hasPrefix("data:") {
                guard let parsed = MediaAsset.parseDataUrl(url, providerMetadata: providerMetadata) else {
                    throw invalid("\(label) has an invalid data URL")
                }
                return parsed
            }
            if let url, !url.isEmpty {
                return MediaAsset.url(url, mediaType: mediaType ?? "application/octet-stream", providerMetadata: providerMetadata)
            }
            throw invalid("\(label) has neither image data nor a URL")
        }

        // parity: ai/src/protocols/utils/media-input.ts#appendFields [status=implemented hash=56cd8440ebbf]
        public static func appendFields(
            fields: [String: JSONValue],
            overlay: [String: JSONValue]? = nil,
            reserved: Set<String> = [],
            repeatArrays: String? = nil
        ) -> [MultipartField] {
            let filteredOverlay = overlay?.filter { !reserved.contains($0.key) }
            let merged = JSONCodec.mergeObjects(fields, filteredOverlay)
            var out: [MultipartField] = []
            for key in merged.keys.sorted() {
                let value = merged[key]!
                if let repeatArrays, case .array(let items) = value {
                    let scalars = items.compactMap(scalarString)
                    if scalars.count == items.count {
                        let partName = repeatArrays == "key[]" ? "\(key)[]" : key
                        for s in scalars {
                            out.append(MultipartField(name: partName, value: s))
                        }
                        continue
                    }
                }
                if case .string(let s) = value {
                    out.append(MultipartField(name: key, value: s))
                } else {
                    out.append(MultipartField(name: key, value: JSONCodec.encode(value)))
                }
            }
            return out
        }
    }

    // MARK: - MistralToolID (packages/ai/src/protocols/utils/mistral-tool-id.ts — 3 symbols)

    public enum MistralToolID {
        // parity: ai/src/protocols/utils/mistral-tool-id.ts#valid [status=implemented hash=e1e33ff32c76]
        public static func valid(_ value: String) -> Bool {
            let bytes = Array(value.utf8)
            guard bytes.count == 9 else { return false }
            return bytes.allSatisfy { b in
                (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
            }
        }

        // parity: ai/src/protocols/utils/mistral-tool-id.ts#hash [status=implemented hash=4f4ae5a34478]
        public static func hash(_ value: String) -> String {
            func fnv(_ seed: UInt32) -> String {
                var result = Int32(bitPattern: seed)
                // Iterate over Unicode scalars matching JS `for (const char of value) char.charCodeAt(0)`
                for scalar in value.unicodeScalars {
                    let firstUnit: UInt16
                    if scalar.value <= 0xFFFF {
                        firstUnit = UInt16(scalar.value)
                    } else {
                        firstUnit = UInt16(0xD800 + ((scalar.value - 0x10000) >> 10))
                    }
                    result = (result ^ Int32(firstUnit)) &* 16_777_619
                }
                let unsigned = UInt32(bitPattern: result)
                let base36 = String(unsigned, radix: 36)
                return base36.count >= 7 ? base36 : String(repeating: "0", count: 7 - base36.count) + base36
            }
            let combined = fnv(2_166_136_261) + fnv(2_246_822_519)
            return String(combined.suffix(9))
        }

        // parity: ai/src/protocols/utils/mistral-tool-id.ts#normalizer [status=implemented hash=5fc8fd595dba]
        public static func normalizer(for request: LLMRequest) -> Normalizer {
            var used = Set<String>()
            for message in request.messages {
                for part in message.content {
                    switch part {
                    case .toolCall(let call) where valid(call.id):
                        used.insert(call.id)
                    case .toolResult(let res) where valid(res.id):
                        used.insert(res.id)
                    default:
                        break
                    }
                }
            }
            return Normalizer(used: used)
        }

        public struct Normalizer: Sendable {
            private var used: Set<String>
            private var normalized: [String: String] = [:]

            public init(used: Set<String> = []) {
                self.used = used
            }

            public mutating func normalize(_ id: String) -> String {
                if MistralToolID.valid(id) { return id }
                if let existing = normalized[id] { return existing }
                var attempt = 0
                var candidate = MistralToolID.hash(id)
                while used.contains(candidate) {
                    attempt += 1
                    candidate = MistralToolID.hash("\(id):\(attempt)")
                }
                used.insert(candidate)
                normalized[id] = candidate
                return candidate
            }
        }
    }

    // MARK: - OpenResponsesOptions (packages/ai/src/protocols/utils/open-responses-options.ts — 17 symbols)

    public enum OpenResponsesOptions {
        // parity: ai/src/protocols/utils/open-responses-options.ts#ReasoningEffort [status=implemented hash=c67b1b57bf74]
        public typealias ReasoningEffort = AISchema.ReasoningEffort

        // parity: ai/src/protocols/utils/open-responses-options.ts#ReasoningEfforts [status=implemented hash=c67b1b57bf74]
        public static let ReasoningEfforts: [String] = AISchema.ReasoningEfforts

        // parity: ai/src/protocols/utils/open-responses-options.ts#TextVerbosities [status=implemented hash=0eb20fbe2334]
        public static let TextVerbosities: [String] = ["low", "medium", "high"]

        // parity: ai/src/protocols/utils/open-responses-options.ts#TextVerbosity [status=implemented hash=0f57a3d33fd6]
        public typealias TextVerbosity = String

        // parity: ai/src/protocols/utils/open-responses-options.ts#ResponseIncludables [status=implemented hash=88f584d1a2c0]
        public static let ResponseIncludables: [String] = [
            "file_search_call.results",
            "web_search_call.results",
            "web_search_call.action.sources",
            "message.input_image.image_url",
            "computer_call_output.output.image_url",
            "code_interpreter_call.outputs",
            "reasoning.encrypted_content",
            "message.output_text.logprobs",
        ]

        // parity: ai/src/protocols/utils/open-responses-options.ts#ResponseIncludable [status=implemented hash=572b4387000d]
        public typealias ResponseIncludable = String

        // parity: ai/src/protocols/utils/open-responses-options.ts#ServiceTiers [status=implemented hash=f0f2c9afacff]
        public static let ServiceTiers: [String] = ["auto", "default", "flex", "priority"]

        // parity: ai/src/protocols/utils/open-responses-options.ts#ServiceTier [status=implemented hash=1d63cc48102f]
        public typealias ServiceTier = String

        // parity: ai/src/protocols/utils/open-responses-options.ts#Truncations [status=implemented hash=d3b58afc584b]
        public static let Truncations: [String] = ["auto", "disabled"]

        // parity: ai/src/protocols/utils/open-responses-options.ts#Truncation [status=implemented hash=174e78a9c376]
        public enum Truncation: String, Equatable, Hashable, Sendable, Codable {
            case auto
            case disabled
        }

        // parity: ai/src/protocols/utils/open-responses-options.ts#TextVerbositySchema [status=implemented hash=c554264beb07]
        public static let TextVerbositySchema = TextVerbosities

        // parity: ai/src/protocols/utils/open-responses-options.ts#ResponseIncludableSchema [status=implemented hash=0fa052423b60]
        public static let ResponseIncludableSchema = ResponseIncludables

        // parity: ai/src/protocols/utils/open-responses-options.ts#ServiceTierSchema [status=implemented hash=bb7a63bbb022]
        public static let ServiceTierSchema = ServiceTiers

        // parity: ai/src/protocols/utils/open-responses-options.ts#TruncationSchema [status=implemented hash=ba09833ba7ec]
        public static let TruncationSchema = Truncations

        // parity: ai/src/protocols/utils/open-responses-options.ts#AllowedTools [status=implemented hash=69372a877990]
        public struct AllowedTools: Equatable, Hashable, Sendable, Codable {
            public let toolNames: [String]
            public let mode: String?

            public init(toolNames: [String], mode: String? = nil) {
                self.toolNames = toolNames
                self.mode = mode
            }
        }

        // parity: ai/src/protocols/utils/open-responses-options.ts#StreamOptions [status=implemented hash=fd1cba63eb49]
        public struct StreamOptions: Equatable, Hashable, Sendable, Codable {
            public let includeObfuscation: Bool?

            public init(includeObfuscation: Bool? = nil) {
                self.includeObfuscation = includeObfuscation
            }
        }

        // parity: ai/src/protocols/utils/open-responses-options.ts#Options [status=implemented hash=5308b9e144a8]
        public struct Options: Equatable, Hashable, Sendable, Codable {
            public var store: Bool?
            public var metadata: [String: String]?
            public var safetyIdentifier: String?
            public var streamOptions: StreamOptions?
            public var topLogprobs: Int?
            public var reasoningEffort: String?
            public var reasoningSummary: String?
            public var include: [ResponseIncludable]?
            public var textVerbosity: TextVerbosity?
            public var serviceTier: ServiceTier?
            public var truncation: Truncation?
            public var allowedTools: AllowedTools?
            public var maxToolCalls: Int?
            public var parallelToolCalls: Bool?

            public init(
                store: Bool? = nil,
                metadata: [String: String]? = nil,
                safetyIdentifier: String? = nil,
                streamOptions: StreamOptions? = nil,
                topLogprobs: Int? = nil,
                reasoningEffort: String? = nil,
                reasoningSummary: String? = nil,
                include: [ResponseIncludable]? = nil,
                textVerbosity: TextVerbosity? = nil,
                serviceTier: ServiceTier? = nil,
                truncation: Truncation? = nil,
                allowedTools: AllowedTools? = nil,
                maxToolCalls: Int? = nil,
                parallelToolCalls: Bool? = nil
            ) {
                self.store = store
                self.metadata = metadata
                self.safetyIdentifier = safetyIdentifier
                self.streamOptions = streamOptions
                self.topLogprobs = topLogprobs
                self.reasoningEffort = reasoningEffort
                self.reasoningSummary = reasoningSummary
                self.include = include
                self.textVerbosity = textVerbosity
                self.serviceTier = serviceTier
                self.truncation = truncation
                self.allowedTools = allowedTools
                self.maxToolCalls = maxToolCalls
                self.parallelToolCalls = parallelToolCalls
            }
        }

        // parity: ai/src/protocols/utils/open-responses-options.ts#Resolved [status=implemented hash=8e8b6ac1b2d5]
        public struct Resolved: Equatable, Hashable, Sendable {
            public var options: Options
            public var resolvedAllowedTools: (toolNames: [String], mode: String)? {
                guard let allowed = options.allowedTools, !allowed.toolNames.isEmpty else { return nil }
                return (allowed.toolNames, allowed.mode ?? "auto")
            }

            public init(options: Options) {
                self.options = options
            }
        }

        // parity: ai/src/protocols/utils/open-responses-options.ts#resolve [status=implemented hash=dc917cda64b7]
        public static func resolve(_ request: LLMRequest) -> Resolved {
            let raw = request.providerOptions ?? [:]
            let store = JSONCodec.boolValue(raw["store"])
            let metadata: [String: String]? = JSONCodec.objectValue(raw["metadata"]).flatMap { obj in
                var dict: [String: String] = [:]
                for (k, v) in obj {
                    guard case .string(let s) = v else { return nil }
                    dict[k] = s
                }
                return dict
            }
            let safetyIdentifier = JSONCodec.stringValue(raw["safetyIdentifier"])
            let streamOptions: StreamOptions? = JSONCodec.objectValue(raw["streamOptions"]).map { obj in
                StreamOptions(includeObfuscation: JSONCodec.boolValue(obj["includeObfuscation"]))
            }
            let topLogprobs: Int? = JSONCodec.intValue(raw["topLogprobs"]).flatMap { (0...20).contains($0) ? $0 : nil }
            let reasoningEffort = JSONCodec.stringValue(raw["reasoningEffort"])
            let reasoningSummary = JSONCodec.stringValue(raw["reasoningSummary"]).flatMap {
                ["auto", "concise", "detailed"].contains($0) ? $0 : nil
            }
            let rawInclude: [String]? = JSONCodec.arrayValue(raw["include"]).flatMap { arr in
                let strings = arr.compactMap(JSONCodec.stringValue)
                return strings.count == arr.count && !strings.isEmpty ? strings : nil
            }
            let textVerbosity = JSONCodec.stringValue(raw["textVerbosity"])
            let serviceTier = JSONCodec.stringValue(raw["serviceTier"])
            let truncation = JSONCodec.stringValue(raw["truncation"]).flatMap(Truncation.init(rawValue:))
            let allowedTools: AllowedTools? = JSONCodec.objectValue(raw["allowedTools"]).flatMap { obj in
                guard let namesArr = JSONCodec.arrayValue(obj["toolNames"]) else { return nil }
                let names = namesArr.compactMap(JSONCodec.stringValue)
                guard names.count == namesArr.count, !names.isEmpty else { return nil }
                let mode = JSONCodec.stringValue(obj["mode"]).flatMap {
                    ["auto", "none", "required"].contains($0) ? $0 : nil
                } ?? "auto"
                return AllowedTools(toolNames: names, mode: mode)
            }
            let maxToolCalls = JSONCodec.intValue(raw["maxToolCalls"])
            let parallelToolCalls = JSONCodec.boolValue(raw["parallelToolCalls"])
            return Resolved(options: Options(
                store: store,
                metadata: metadata,
                safetyIdentifier: safetyIdentifier,
                streamOptions: streamOptions,
                topLogprobs: topLogprobs,
                reasoningEffort: reasoningEffort,
                reasoningSummary: reasoningSummary,
                include: rawInclude,
                textVerbosity: textVerbosity,
                serviceTier: serviceTier,
                truncation: truncation,
                allowedTools: allowedTools,
                maxToolCalls: maxToolCalls,
                parallelToolCalls: parallelToolCalls
            ))
        }
    }

    // MARK: - PartialJSONOptions (packages/ai/src/protocols/utils/partial-json-options.ts — 3 symbols)

    public enum PartialJSONOptions {
        // parity: ai/src/protocols/utils/partial-json-options.ts#STR [status=implemented hash=926dd4b71aec]
        public static let STR = 0b000000001
        // parity: ai/src/protocols/utils/partial-json-options.ts#NUM [status=implemented hash=200ae6656d8e]
        public static let NUM = 0b000000010
        // parity: ai/src/protocols/utils/partial-json-options.ts#ARR [status=implemented hash=347bfd6f8c6d]
        public static let ARR = 0b000000100
        // parity: ai/src/protocols/utils/partial-json-options.ts#OBJ [status=implemented hash=5837fa52b179]
        public static let OBJ = 0b000001000
        // parity: ai/src/protocols/utils/partial-json-options.ts#NULL [status=implemented hash=f2128941d24e]
        public static let NULL = 0b000010000
        // parity: ai/src/protocols/utils/partial-json-options.ts#BOOL [status=implemented hash=d9c71c8452b4]
        public static let BOOL = 0b000100000
        // parity: ai/src/protocols/utils/partial-json-options.ts#NAN [status=implemented hash=4f5f1f9d3242]
        public static let NAN = 0b001000000
        // parity: ai/src/protocols/utils/partial-json-options.ts#INFINITY [status=implemented hash=34657046c1c7]
        public static let INFINITY = 0b010000000
        // parity: ai/src/protocols/utils/partial-json-options.ts#_INFINITY [status=implemented hash=980498db451a]
        public static let _INFINITY = 0b100000000
        // parity: ai/src/protocols/utils/partial-json-options.ts#INF [status=implemented hash=5e5826bccacb]
        public static let INF = INFINITY | _INFINITY
        // parity: ai/src/protocols/utils/partial-json-options.ts#SPECIAL [status=implemented hash=54c3850d93cb]
        public static let SPECIAL = NULL | BOOL | INF | NAN
        // parity: ai/src/protocols/utils/partial-json-options.ts#ATOM [status=implemented hash=d16d52b8a834]
        public static let ATOM = STR | NUM | SPECIAL
        // parity: ai/src/protocols/utils/partial-json-options.ts#COLLECTION [status=implemented hash=9f2eec2d6299]
        public static let COLLECTION = ARR | OBJ
        // parity: ai/src/protocols/utils/partial-json-options.ts#ALL [status=implemented hash=0357a381c34d]
        public static let ALL = ATOM | COLLECTION

        public struct AllowFlags: Equatable, Hashable, Sendable {
            public let STR: Int
            public let NUM: Int
            public let ARR: Int
            public let OBJ: Int
            public let NULL: Int
            public let BOOL: Int
            public let NAN: Int
            public let INFINITY: Int
            public let _INFINITY: Int
            public let INF: Int
            public let SPECIAL: Int
            public let ATOM: Int
            public let COLLECTION: Int
            public let ALL: Int

            public init(
                STR: Int = PartialJSONOptions.STR,
                NUM: Int = PartialJSONOptions.NUM,
                ARR: Int = PartialJSONOptions.ARR,
                OBJ: Int = PartialJSONOptions.OBJ,
                NULL: Int = PartialJSONOptions.NULL,
                BOOL: Int = PartialJSONOptions.BOOL,
                NAN: Int = PartialJSONOptions.NAN,
                INFINITY: Int = PartialJSONOptions.INFINITY,
                _INFINITY: Int = PartialJSONOptions._INFINITY,
                INF: Int = PartialJSONOptions.INF,
                SPECIAL: Int = PartialJSONOptions.SPECIAL,
                ATOM: Int = PartialJSONOptions.ATOM,
                COLLECTION: Int = PartialJSONOptions.COLLECTION,
                ALL: Int = PartialJSONOptions.ALL
            ) {
                self.STR = STR
                self.NUM = NUM
                self.ARR = ARR
                self.OBJ = OBJ
                self.NULL = NULL
                self.BOOL = BOOL
                self.NAN = NAN
                self.INFINITY = INFINITY
                self._INFINITY = _INFINITY
                self.INF = INF
                self.SPECIAL = SPECIAL
                self.ATOM = ATOM
                self.COLLECTION = COLLECTION
                self.ALL = ALL
            }
        }

        // parity: ai/src/protocols/utils/partial-json-options.ts#Allow [status=implemented hash=f4e960c339d3]
        public static let Allow = AllowFlags()
    }

    // MARK: - PartialJSONParser (packages/ai/src/protocols/utils/partial-json.ts — 4 symbols)

    public enum PartialJSONParser {
        // parity: ai/src/protocols/utils/partial-json.ts#PartialJSON [status=implemented hash=d5cc35193a6c]
        public struct PartialJSON: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
            public let message: String
            public init(_ message: String) { self.message = message }
            public var description: String { message }
        }

        // parity: ai/src/protocols/utils/partial-json.ts#MalformedJSON [status=implemented hash=c203144a1a7e]
        public struct MalformedJSON: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
            public let message: String
            public init(_ message: String) { self.message = message }
            public var description: String { message }
        }

        // parity: ai/src/protocols/utils/partial-json.ts#parseJSON [status=implemented hash=f92ca8c50212]
        public static func parseJSON(_ jsonString: String, allowPartial: Int = PartialJSONOptions.ALL) throws -> JSONValue {
            let input = jsonString.trimmingASCIIWhitespace()
            if input.isEmpty {
                throw MalformedJSON("\(jsonString) is empty")
            }
            if let complete = PureJSON.parse(input) {
                return JSONCodec.fromPureJSON(complete)
            }
            let repaired = repairJSON(input)
            if repaired != input, let parsed = PureJSON.parse(repaired) {
                return JSONCodec.fromPureJSON(parsed)
            }
            var state = ParserState(input: input, allow: allowPartial)
            do {
                return try state.parseAny()
            } catch {
                if repaired != input {
                    var repairedState = ParserState(input: repaired, allow: allowPartial)
                    return try repairedState.parseAny()
                }
                throw error
            }
        }

        // parity: ai/src/protocols/utils/partial-json.ts#parse [status=implemented hash=81ba7d37aec5]
        public static func parse(_ jsonString: String, allowPartial: Int = PartialJSONOptions.ALL) throws -> JSONValue {
            try parseJSON(jsonString, allowPartial: allowPartial)
        }

        private static func repairJSON(_ input: String) -> String {
            let chars = Array(input.unicodeScalars)
            var out = ""
            out.reserveCapacity(input.utf8.count)
            var quoted = false
            var index = 0
            let validEscapes: Set<UInt32> = [0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74, 0x75]
            let hexDigits: [UInt8] = Array("0123456789abcdef".utf8)
            func isHexScalar(_ s: UnicodeScalar) -> Bool {
                let v = s.value
                return (v >= 0x30 && v <= 0x39) || (v >= 0x61 && v <= 0x66) || (v >= 0x41 && v <= 0x46)
            }
            while index < chars.count {
                let c = chars[index]
                if !quoted {
                    out.unicodeScalars.append(c)
                    if c == "\"" { quoted = true }
                    index += 1
                    continue
                }
                if c == "\"" {
                    out.unicodeScalars.append(c)
                    quoted = false
                    index += 1
                    continue
                }
                if c == "\\" {
                    if index + 1 < chars.count {
                        let next = chars[index + 1]
                        if next == "u", index + 5 < chars.count,
                           isHexScalar(chars[index + 2]), isHexScalar(chars[index + 3]),
                           isHexScalar(chars[index + 4]), isHexScalar(chars[index + 5]) {
                            for k in index...(index + 5) { out.unicodeScalars.append(chars[k]) }
                            index += 6
                            continue
                        }
                        if validEscapes.contains(next.value) {
                            out.append("\\")
                            out.unicodeScalars.append(next)
                            index += 2
                            continue
                        }
                    }
                    out.append("\\\\")
                    index += 1
                    continue
                }
                if c.value <= 0x1F {
                    let v = Int(c.value)
                    out.append("\\u00")
                    out.append(Character(UnicodeScalar(hexDigits[(v >> 4) & 0xF])))
                    out.append(Character(UnicodeScalar(hexDigits[v & 0xF])))
                } else {
                    out.unicodeScalars.append(c)
                }
                index += 1
            }
            return out
        }

        private struct ParserState {
            let scalars: [UnicodeScalar]
            let allow: Int
            var index = 0

            init(input: String, allow: Int) {
                self.scalars = Array(input.unicodeScalars)
                self.allow = allow
            }

            mutating func skipBlank() {
                while index < scalars.count {
                    let v = scalars[index].value
                    if v == 0x20 || v == 0x0A || v == 0x0D || v == 0x09 {
                        index += 1
                    } else {
                        break
                    }
                }
            }

            func remainingString(maxLen: Int? = nil) -> String {
                let end = maxLen.map { min(scalars.count, index + $0) } ?? scalars.count
                return String(String.UnicodeScalarView(scalars[index..<end]))
            }

            mutating func parseAny() throws -> JSONValue {
                skipBlank()
                guard index < scalars.count else {
                    throw PartialJSON("Unexpected end of input at position \(index)")
                }
                let ch = scalars[index]
                if ch == "\"" { return .string(try parseStr()) }
                if ch == "{" { return .object(try parseObj()) }
                if ch == "[" { return .array(try parseArr()) }
                let rem4 = remainingString(maxLen: 4)
                if rem4 == "null" || ((allow & PartialJSONOptions.NULL) != 0 && scalars.count - index < 4 && "null".hasPrefix(remainingString())) {
                    index = min(scalars.count, index + 4)
                    return .null
                }
                if rem4 == "true" || ((allow & PartialJSONOptions.BOOL) != 0 && scalars.count - index < 4 && "true".hasPrefix(remainingString())) {
                    index = min(scalars.count, index + 4)
                    return .bool(true)
                }
                let rem5 = remainingString(maxLen: 5)
                if rem5 == "false" || ((allow & PartialJSONOptions.BOOL) != 0 && scalars.count - index < 5 && "false".hasPrefix(remainingString())) {
                    index = min(scalars.count, index + 5)
                    return .bool(false)
                }
                let rem8 = remainingString(maxLen: 8)
                if rem8 == "Infinity" || ((allow & PartialJSONOptions.INFINITY) != 0 && scalars.count - index < 8 && "Infinity".hasPrefix(remainingString())) {
                    index = min(scalars.count, index + 8)
                    return .double(.infinity)
                }
                let rem9 = remainingString(maxLen: 9)
                if rem9 == "-Infinity" || ((allow & PartialJSONOptions._INFINITY) != 0 && scalars.count - index > 1 && scalars.count - index < 9 && "-Infinity".hasPrefix(remainingString())) {
                    index = min(scalars.count, index + 9)
                    return .double(-.infinity)
                }
                let rem3 = remainingString(maxLen: 3)
                if rem3 == "NaN" || ((allow & PartialJSONOptions.NAN) != 0 && scalars.count - index < 3 && "NaN".hasPrefix(remainingString())) {
                    index = min(scalars.count, index + 3)
                    return .double(.nan)
                }
                return try parseNum()
            }

            mutating func parseStr() throws -> String {
                let start = index
                var escape = false
                index += 1
                while index < scalars.count && (scalars[index] != "\"" || (escape && scalars[index - 1] == "\\")) {
                    escape = scalars[index] == "\\" ? !escape : false
                    index += 1
                }
                if index < scalars.count && scalars[index] == "\"" {
                    let endIdx = index + 1 - (escape ? 1 : 0)
                    index += 1
                    let slice = String(String.UnicodeScalarView(scalars[start..<endIdx]))
                    guard let parsed = PureJSON.parse(slice), case .string(let s) = parsed else {
                        throw MalformedJSON("Invalid string literal at position \(start)")
                    }
                    return s
                }
                if (allow & PartialJSONOptions.STR) != 0 {
                    let endIdx = index - (escape ? 1 : 0)
                    let candidate = String(String.UnicodeScalarView(scalars[start..<endIdx])) + "\""
                    if let parsed = PureJSON.parse(candidate), case .string(let s) = parsed {
                        return s
                    }
                    if let lastSlash = scalars[start..<index].lastIndex(of: "\\") {
                        let truncated = String(String.UnicodeScalarView(scalars[start..<lastSlash])) + "\""
                        if let parsed = PureJSON.parse(truncated), case .string(let s) = parsed {
                            return s
                        }
                    }
                    return ""
                }
                throw PartialJSON("Unterminated string literal at position \(index)")
            }

            mutating func parseObj() throws -> [String: JSONValue] {
                index += 1
                skipBlank()
                var obj: [String: JSONValue] = [:]
                while index < scalars.count && scalars[index] != "}" {
                    skipBlank()
                    if index >= scalars.count {
                        if (allow & PartialJSONOptions.OBJ) != 0 { return obj }
                        throw PartialJSON("Expected '}' at end of object at position \(index)")
                    }
                    if scalars[index] == "}" { break }
                    let key: String
                    do {
                        key = try parseStr()
                    } catch {
                        if (allow & PartialJSONOptions.OBJ) != 0 { return obj }
                        throw error
                    }
                    skipBlank()
                    if index >= scalars.count || scalars[index] != ":" {
                        if (allow & PartialJSONOptions.OBJ) != 0 { return obj }
                        throw PartialJSON("Expected ':' after object key at position \(index)")
                    }
                    index += 1
                    do {
                        obj[key] = try parseAny()
                    } catch {
                        if (allow & PartialJSONOptions.OBJ) != 0 { return obj }
                        throw error
                    }
                    skipBlank()
                    if index < scalars.count && scalars[index] == "," {
                        index += 1
                    }
                }
                if index >= scalars.count {
                    if (allow & PartialJSONOptions.OBJ) != 0 { return obj }
                    throw PartialJSON("Expected '}' at end of object at position \(index)")
                }
                index += 1
                return obj
            }

            mutating func parseArr() throws -> [JSONValue] {
                index += 1
                var arr: [JSONValue] = []
                while index < scalars.count && scalars[index] != "]" {
                    skipBlank()
                    if index >= scalars.count {
                        if (allow & PartialJSONOptions.ARR) != 0 { return arr }
                        throw PartialJSON("Expected ']' at end of array at position \(index)")
                    }
                    if scalars[index] == "]" { break }
                    do {
                        arr.append(try parseAny())
                    } catch {
                        if (allow & PartialJSONOptions.ARR) != 0 { return arr }
                        throw error
                    }
                    skipBlank()
                    if index < scalars.count && scalars[index] == "," {
                        index += 1
                    }
                }
                if index >= scalars.count {
                    if (allow & PartialJSONOptions.ARR) != 0 { return arr }
                    throw PartialJSON("Expected ']' at end of array at position \(index)")
                }
                index += 1
                return arr
            }

            mutating func parseNum() throws -> JSONValue {
                let start = index
                if index < scalars.count && scalars[index] == "-" {
                    index += 1
                }
                while index < scalars.count {
                    let c = scalars[index]
                    if c == "," || c == "]" || c == "}" || c == " " || c == "\n" || c == "\r" || c == "\t" {
                        break
                    }
                    index += 1
                }
                if index == scalars.count && (allow & PartialJSONOptions.NUM) == 0 {
                    throw PartialJSON("Unterminated number literal at position \(index)")
                }
                var token = String(String.UnicodeScalarView(scalars[start..<index]))
                if token == "-" {
                    throw PartialJSON("Not sure what '-' is at position \(start)")
                }
                if let parsed = PureJSON.parse(token) {
                    return JSONCodec.fromPureJSON(parsed)
                }
                if (allow & PartialJSONOptions.NUM) != 0 {
                    while token.hasSuffix(".") || token.hasSuffix("e") || token.hasSuffix("E") || token.hasSuffix("+") || token.hasSuffix("-") {
                        token.removeLast()
                    }
                    if let parsed = PureJSON.parse(token) {
                        return JSONCodec.fromPureJSON(parsed)
                    }
                }
                throw MalformedJSON("Invalid number '\(token)' at position \(start)")
            }
        }
    }

    // MARK: - ResponsesCheckpoint (packages/ai/src/protocols/utils/responses-checkpoint.ts — 1 symbol)

    public enum ResponsesCheckpoint {
        public struct CheckpointResult: Equatable, Hashable, Sendable {
            public let checkpoint: CompactionPart
            public let responseID: String
            public let usage: Usage?

            public init(checkpoint: CompactionPart, responseID: String, usage: Usage? = nil) {
                self.checkpoint = checkpoint
                self.responseID = responseID
                self.usage = usage
            }
        }

        public struct Runner: Sendable {
            public let buildBody: @Sendable (LLMRequest) throws(ProtocolError) -> [String: JSONValue]

            public init(buildBody: @escaping @Sendable (LLMRequest) throws(ProtocolError) -> [String: JSONValue]) {
                self.buildBody = buildBody
            }

            public func collect(
                frames: [[String: JSONValue]],
                routeID: String,
                provider: String
            ) throws(ProtocolError) -> CheckpointResult {
                var responseID: String?
                var outputItems: [Int: String] = [:]
                var checkpoints: [String: CompactionPart] = [:]
                var finalUsage: Usage?

                func handleItem(_ item: [String: JSONValue], index: Int?) throws(ProtocolError) {
                    let itemID = (index.flatMap { outputItems[$0] }) ?? JSONCodec.stringValue(item["id"]) ?? "cmp_\(uuid())"
                    if let index, outputItems[index] == nil {
                        outputItems[index] = itemID
                    }
                    guard JSONCodec.stringValue(item["type"]) == "compaction" else { return }
                    if let index, outputItems.contains(where: { $0.value == itemID && $0.key != index }) {
                        throw ProviderShared.eventError(routeID, "Compaction checkpoint appeared in multiple output slots")
                    }
                    guard let encrypted = JSONCodec.stringValue(item["encrypted_content"]), !encrypted.isEmpty else {
                        throw ProviderShared.eventError(routeID, "Compaction output is missing its encrypted content")
                    }
                    if let prev = checkpoints[itemID] {
                        if prev.encrypted != encrypted {
                            throw ProviderShared.eventError(routeID, "Compaction output changed after completion")
                        }
                        return
                    }
                    checkpoints[itemID] = CompactionPart(provider: provider, id: itemID, encrypted: encrypted)
                }

                for frame in frames {
                    let type = JSONCodec.stringValue(frame["type"]) ?? ""
                    let resp = JSONCodec.objectValue(frame["response"])
                    if let rid = JSONCodec.stringValue(resp?["id"]) {
                        if let existing = responseID, existing != rid {
                            throw ProviderShared.eventError(routeID, "Compaction response ID changed during execution")
                        }
                        if type == "response.created" { responseID = rid }
                    }
                    if type == "error" || type == "response.failed" {
                        throw ProviderShared.eventError(routeID, "Compaction request failed", body: JSONCodec.encodeObject(frame))
                    }
                    if type == "response.incomplete" {
                        throw ProviderShared.eventError(routeID, "Compaction response was incomplete")
                    }
                    if type == "response.output_item.added" {
                        if let item = JSONCodec.objectValue(frame["item"]),
                           let index = JSONCodec.intValue(frame["output_index"]),
                           let id = JSONCodec.stringValue(item["id"]) {
                            outputItems[index] = id
                        }
                    } else if type == "response.output_item.done" {
                        if let item = JSONCodec.objectValue(frame["item"]) {
                            try handleItem(item, index: JSONCodec.intValue(frame["output_index"]))
                        }
                    } else if type == "response.completed" {
                        guard let rid = JSONCodec.stringValue(resp?["id"]), !rid.trimmingASCIIWhitespace().isEmpty else {
                            throw ProviderShared.eventError(routeID, "Compaction response is missing its response ID")
                        }
                        if let status = JSONCodec.stringValue(resp?["status"]), status != "completed" {
                            throw ProviderShared.eventError(routeID, "Compaction response did not complete successfully")
                        }
                        for (idx, elem) in (JSONCodec.arrayValue(resp?["output"]) ?? []).enumerated() {
                            if let item = JSONCodec.objectValue(elem) {
                                try handleItem(item, index: idx)
                            }
                        }
                        if let usageObj = JSONCodec.objectValue(resp?["usage"]) {
                            let inputTokens = JSONCodec.doubleValue(usageObj["input_tokens"])
                            let outputTokens = JSONCodec.doubleValue(usageObj["output_tokens"])
                            let totalTokens = ProviderShared.totalTokens(inputTokens, outputTokens, JSONCodec.doubleValue(usageObj["total_tokens"]))
                            finalUsage = Usage(inputTokens: inputTokens, outputTokens: outputTokens, totalTokens: totalTokens)
                        }
                        responseID = rid
                    }
                }
                guard let rid = responseID, checkpoints.count == 1, let checkpoint = checkpoints.values.first else {
                    throw ProviderShared.eventError(routeID, "Compaction response must contain exactly one checkpoint")
                }
                return CheckpointResult(checkpoint: checkpoint, responseID: rid, usage: finalUsage)
            }
        }

        // parity: ai/src/protocols/utils/responses-checkpoint.ts#make [status=adapted hash=f5f80550dd87]
        public static func make(
            body: @escaping @Sendable (LLMRequest) throws(ProtocolError) -> [String: JSONValue]
        ) -> Runner {
            Runner(buildBody: body)
        }
    }

    // MARK: - ResponsesCompaction (packages/ai/src/protocols/utils/responses-compaction.ts — 1 symbol)

    public enum ResponsesCompaction {
        public struct CompactionResult: Equatable, Hashable, Sendable {
            public let replacement: [Message]
            public let usage: Usage?

            public init(replacement: [Message], usage: Usage? = nil) {
                self.replacement = replacement
                self.usage = usage
            }
        }

        public struct Operation: Sendable {
            public let providerName: String
            public let buildBody: @Sendable (LLMRequest) throws(ProtocolError) -> [String: JSONValue]

            public init(
                providerName: String,
                buildBody: @escaping @Sendable (LLMRequest) throws(ProtocolError) -> [String: JSONValue]
            ) {
                self.providerName = providerName
                self.buildBody = buildBody
            }

            public func endpointURL(baseURL: String, path: String = "/responses") -> String {
                let trimmedBase = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
                let trimmedPath = path.hasSuffix("/") ? String(path.dropLast()) : path
                return "\(trimmedBase)\(trimmedPath)/compact"
            }

            public func decodeResponse(_ text: String, model: ModelDescriptor) throws(ProtocolError) -> CompactionResult {
                let value = try ProviderShared.parseJson(route: model.routeID, input: text, message: "Invalid compaction response")
                guard let obj = JSONCodec.objectValue(value),
                      JSONCodec.stringValue(obj["object"]) == "response.compaction",
                      let output = JSONCodec.arrayValue(obj["output"]) else {
                    throw ProviderShared.eventError(model.routeID, "Invalid compaction response", body: text)
                }
                let hasCompaction = output.contains { JSONCodec.stringValue(JSONCodec.objectValue($0)?["type"]) == "compaction" }
                if !hasCompaction {
                    throw ProviderShared.eventError(model.routeID, "Compaction response did not contain a checkpoint", body: text)
                }
                let metaKey = model.providerMetadataKey ?? "openresponses"
                var replacement: [Message] = []
                for entry in output {
                    guard let item = JSONCodec.objectValue(entry), let itemType = JSONCodec.stringValue(item["type"]) else {
                        continue
                    }
                    if itemType == "compaction", let enc = JSONCodec.stringValue(item["encrypted_content"]) {
                        replacement.append(Message(
                            role: .assistant,
                            content: [.compaction(CompactionPart(provider: model.provider, id: JSONCodec.stringValue(item["id"]), encrypted: enc))]
                        ))
                    } else if itemType == "reasoning" {
                        let summaryItems = JSONCodec.arrayValue(item["summary"]) ?? []
                        var meta: [String: JSONValue] = [:]
                        if let id = item["id"] { meta["itemId"] = id }
                        if let enc = item["encrypted_content"] { meta["reasoningEncryptedContent"] = enc }
                        let texts = summaryItems.compactMap { JSONCodec.stringValue(JSONCodec.objectValue($0)?["text"]) }
                        let parts: [ContentPart] = (texts.isEmpty ? [""] : texts).map {
                            .reasoning(ReasoningPart(text: $0, providerMetadata: [metaKey: meta]))
                        }
                        replacement.append(Message(role: .assistant, content: parts))
                    } else if itemType == "message" {
                        let roleStr = JSONCodec.stringValue(item["role"]) ?? ""
                        if roleStr == "developer" { continue }
                        let role: MessageRole = roleStr == "assistant" ? .assistant : .user
                        var parts: [ContentPart] = []
                        for p in JSONCodec.arrayValue(item["content"]) ?? [] {
                            guard let pObj = JSONCodec.objectValue(p), let pType = JSONCodec.stringValue(pObj["type"]) else { continue }
                            if pType == "input_text" || pType == "output_text", let t = JSONCodec.stringValue(pObj["text"]) {
                                parts.append(.text(TextPart(text: t)))
                            } else if pType == "input_image", let url = JSONCodec.stringValue(pObj["image_url"]) {
                                let asset = MediaAsset.parseDataUrl(url) ?? MediaAsset.url(url, mediaType: "image/*")
                                parts.append(.media(MediaPart(media: asset)))
                            } else if pType == "input_file" {
                                let raw = JSONCodec.stringValue(pObj["file_url"]) ?? JSONCodec.stringValue(pObj["file_data"]) ?? ""
                                let asset = MediaAsset.parseDataUrl(raw) ?? MediaAsset.url(raw, mediaType: "application/octet-stream")
                                parts.append(.media(MediaPart(media: asset, filename: JSONCodec.stringValue(pObj["filename"]))))
                            }
                        }
                        replacement.append(Message(role: role, content: parts))
                    }
                }
                let usageObj = JSONCodec.objectValue(obj["usage"])
                let usage = usageObj.map { u -> Usage in
                    let inp = JSONCodec.doubleValue(u["input_tokens"])
                    let out = JSONCodec.doubleValue(u["output_tokens"])
                    return Usage(inputTokens: inp, outputTokens: out, totalTokens: ProviderShared.totalTokens(inp, out, JSONCodec.doubleValue(u["total_tokens"])))
                }
                return CompactionResult(replacement: replacement, usage: usage)
            }
        }

        // parity: ai/src/protocols/utils/responses-compaction.ts#make [status=adapted hash=06f072baca16]
        public static func make(
            providerName: String,
            buildBody: @escaping @Sendable (LLMRequest) throws(ProtocolError) -> [String: JSONValue]
        ) -> Operation {
            Operation(providerName: providerName, buildBody: buildBody)
        }
    }

    // MARK: - ResponsesHostedTools (packages/ai/src/protocols/utils/responses-hosted-tools.ts — 7 symbols)

    public enum ResponsesHostedTools {
        // parity: ai/src/protocols/utils/responses-hosted-tools.ts#Item [status=implemented hash=64edd9bbe52d]
        public struct Item: Equatable, Hashable, Sendable {
            public let id: String
            public let type: String
            public let raw: [String: JSONValue]

            public init(id: String, type: String, raw: [String: JSONValue]) {
                self.id = id
                self.type = type
                self.raw = raw
            }
        }

        // parity: ai/src/protocols/utils/responses-hosted-tools.ts#Definition [status=implemented hash=0961751b44eb]
        public struct Definition: Sendable {
            public let name: String
            public let input: @Sendable (Item) -> JSONValue
            public let result: (@Sendable (Item) throws(ProtocolError) -> ToolResultValue)?

            public init(
                name: String,
                input: @escaping @Sendable (Item) -> JSONValue,
                result: (@Sendable (Item) throws(ProtocolError) -> ToolResultValue)? = nil
            ) {
                self.name = name
                self.input = input
                self.result = result
            }
        }

        // parity: ai/src/protocols/utils/responses-hosted-tools.ts#Definitions [status=implemented hash=889a8cdbd672]
        public typealias Definitions = [String: Definition]

        // parity: ai/src/protocols/utils/responses-hosted-tools.ts#common [status=implemented hash=5b90102e087f]
        public static let common: Definitions = [
            "web_search_call": Definition(name: "web_search") { item in
                item.raw["action"] ?? .object([:])
            },
            "file_search_call": Definition(name: "file_search") { item in
                .object(["queries": item.raw["queries"] ?? .array([])])
            },
            "code_interpreter_call": Definition(name: "code_interpreter") { item in
                var obj: [String: JSONValue] = [:]
                if let code = item.raw["code"] { obj["code"] = code }
                if let cid = item.raw["container_id"] { obj["container_id"] = cid }
                return .object(obj)
            },
            "mcp_call": Definition(name: "mcp") { item in
                var obj: [String: JSONValue] = [:]
                if let sl = item.raw["server_label"] { obj["server_label"] = sl }
                if let n = item.raw["name"] { obj["name"] = n }
                if let args = item.raw["arguments"] { obj["arguments"] = args }
                return .object(obj)
            },
        ]

        // parity: ai/src/protocols/utils/responses-hosted-tools.ts#isItem [status=implemented hash=70ad71758494]
        public static func isItem(_ item: Item, in tools: Definitions) -> Bool {
            tools[item.type] != nil
        }

        // parity: ai/src/protocols/utils/responses-hosted-tools.ts#stream [status=adapted hash=6372af6099dc]
        public static func stream(
            tools: Definitions
        ) -> @Sendable (Lifecycle.State, Item, String) throws(ProtocolError) -> (Lifecycle.State, [LLMEvent]) {
            { lifecycle, item, metadataKey throws(ProtocolError) in
                try onDone(lifecycle: lifecycle, item: item, tools: tools, providerMetadataKey: metadataKey)
            }
        }

        // parity: ai/src/protocols/utils/responses-hosted-tools.ts#onDone [status=implemented hash=6697b2ca2ec1]
        public static func onDone(
            lifecycle: Lifecycle.State,
            item: Item,
            tools: Definitions,
            providerMetadataKey: String
        ) throws(ProtocolError) -> (Lifecycle.State, [LLMEvent]) {
            guard let tool = tools[item.type] else { return (lifecycle, []) }
            let providerMeta: ProviderMetadata = [providerMetadataKey: ["itemId": .string(item.id)]]
            var events: [LLMEvent] = []
            let nextLifecycle = Lifecycle.stepStart(lifecycle, events: &events)
            let toolResult: ToolResultValue
            if let customResult = tool.result {
                toolResult = try customResult(item)
            } else if let err = item.raw["error"], err != .null {
                toolResult = .error(err)
            } else {
                toolResult = .json(.object(item.raw))
            }
            events.append(.toolCall(
                id: item.id,
                name: tool.name,
                input: tool.input(item),
                providerExecuted: true,
                providerMetadata: providerMeta
            ))
            events.append(.toolResult(
                id: item.id,
                name: tool.name,
                result: toolResult,
                providerExecuted: true,
                providerMetadata: providerMeta
            ))
            return (nextLifecycle, events)
        }
    }

    // MARK: - SpeakerTurns (packages/ai/src/protocols/utils/speaker-turns.ts — 1 symbol)

    public enum SpeakerTurns {
        // parity: ai/src/protocols/utils/speaker-turns.ts#group [status=implemented hash=542e337b11b3]
        public static func group<Item, Speaker: Equatable>(
            _ items: [Item],
            speaker: (Item) -> Speaker
        ) -> [[Item]] {
            var turns: [[Item]] = []
            for item in items {
                if let last = turns.last, let first = last.first, speaker(first) == speaker(item) {
                    turns[turns.count - 1].append(item)
                } else {
                    turns.append([item])
                }
            }
            return turns
        }
    }

    // MARK: - SpeechStream (packages/ai/src/protocols/utils/speech-stream.ts — 12 symbols)

    public enum SpeechStream {
        // parity: ai/src/protocols/utils/speech-stream.ts#Audio [status=implemented hash=47c96c3b8647]
        public struct Audio: Equatable, Hashable, Sendable {
            public var chunks: [[UInt8]]

            public init(chunks: [[UInt8]] = []) {
                self.chunks = chunks
            }
        }

        // parity: ai/src/protocols/utils/speech-stream.ts#StepResult [status=implemented hash=d6913dfc76f8]
        public typealias StepResult<State> = (State, [SpeechEvent])

        // parity: ai/src/protocols/utils/speech-stream.ts#delta [status=implemented hash=46c7804012c4]
        public static func delta(_ audio: inout Audio, chunk: [UInt8]) -> [SpeechEvent] {
            guard !chunk.isEmpty else { return [] }
            audio.chunks.append(chunk)
            return [.audioDelta(chunk)]
        }

        public enum Frame: Equatable, Sendable {
            case text(String)
            case bytes([UInt8])
        }

        // parity: ai/src/protocols/utils/speech-stream.ts#step [status=implemented hash=78e69a5f12cc]
        public static func step(
            onRecord: @escaping @Sendable (inout Audio, String) throws(ProtocolError) -> [SpeechEvent]
        ) -> @Sendable (inout Audio, Frame) throws(ProtocolError) -> [SpeechEvent] {
            { audio, frame throws(ProtocolError) in
                switch frame {
                case .text(let record):
                    return try onRecord(&audio, record)
                case .bytes(let bytes):
                    return delta(&audio, chunk: bytes)
                }
            }
        }

        // parity: ai/src/protocols/utils/speech-stream.ts#timestamps [status=implemented hash=48d8c8a70c71]
        public static func timestamps(texts: [String], starts: [Double], ends: [Double]) -> [SpeechEvent] {
            guard !texts.isEmpty else { return [] }
            let items = texts.enumerated().map { idx, text in
                SpeechTimestampItem(
                    text: text,
                    startSeconds: idx < starts.count ? starts[idx] : 0,
                    endSeconds: idx < ends.count ? ends[idx] : 0
                )
            }
            return [.timestamps(items)]
        }

        // parity: ai/src/protocols/utils/speech-stream.ts#voiceID [status=implemented hash=7aaa33466870]
        public static func voiceID(_ voice: JSONValue?) -> String? {
            if case .string(let s) = voice { return s }
            if case .object(let obj) = voice { return JSONCodec.stringValue(obj["id"]) }
            return nil
        }

        private static let containerMediaTypes: [String: String] = [
            "mp3": "audio/mpeg",
            "wav": "audio/wav",
            "opus": "audio/ogg",
            "aac": "audio/aac",
            "flac": "audio/flac",
        ]

        public struct FormatMetadata: Equatable, Hashable, Sendable {
            public let mediaType: String?
            public let info: [String: JSONValue]

            public init(mediaType: String?, info: [String: JSONValue]) {
                self.mediaType = mediaType
                self.info = info
            }
        }

        // parity: ai/src/protocols/utils/speech-stream.ts#container [status=implemented hash=31461ff3c05e]
        public static func container(format: String, sampleRate: Int? = nil) -> FormatMetadata {
            var info: [String: JSONValue] = ["format": .string(format)]
            if let sampleRate { info["sampleRate"] = .int(Int64(sampleRate)) }
            return FormatMetadata(mediaType: containerMediaTypes[format], info: info)
        }

        // parity: ai/src/protocols/utils/speech-stream.ts#PcmEncoding [status=implemented hash=e0b7a76cae00]
        public enum PcmEncoding: String, Equatable, Hashable, Sendable, Codable {
            case pcm_s16le
            case pcm_f32le
            case pcm_mulaw
            case pcm_alaw

            public var defaultMediaType: String {
                switch self {
                case .pcm_s16le, .pcm_f32le: return "audio/pcm"
                case .pcm_mulaw: return "audio/mulaw"
                case .pcm_alaw: return "audio/alaw"
                }
            }
        }

        // parity: ai/src/protocols/utils/speech-stream.ts#pcm [status=implemented hash=57f204835d00]
        public static func pcm(encoding: PcmEncoding, sampleRate: Int?, mediaType: String? = nil) -> FormatMetadata {
            var info: [String: JSONValue] = [
                "format": .string("pcm"),
                "encoding": .string(encoding.rawValue),
                "channels": .int(1),
            ]
            if let sampleRate { info["sampleRate"] = .int(Int64(sampleRate)) }
            return FormatMetadata(mediaType: mediaType ?? encoding.defaultMediaType, info: info)
        }

        // parity: ai/src/protocols/utils/speech-stream.ts#sampleRate [status=implemented hash=1ed0ad959de6]
        public static func sampleRate(from mediaType: String?) -> Int? {
            guard let mediaType else { return nil }
            let lower = mediaType.lowercased()
            guard let range = lower.range(of: "rate=") else { return nil }
            let digits = lower[range.upperBound...].prefix { $0 >= "0" && $0 <= "9" }
            return Int(digits)
        }

        // parity: ai/src/protocols/utils/speech-stream.ts#finish [status=implemented hash=4f2f80feaa38]
        public static func finish(
            route: MediaIdentity,
            state: Audio,
            mediaType: String?,
            info: [String: JSONValue]? = nil,
            usage: MediaUsage? = nil,
            providerMetadata: ProviderMetadata? = nil,
            detail: String? = nil
        ) throws(ProtocolError) -> [SpeechEvent] {
            if state.chunks.isEmpty {
                let suffix = detail.map { " (\($0))" } ?? ""
                throw route.frameError("The provider returned no audio\(suffix)")
            }
            var combined: [UInt8] = []
            combined.reserveCapacity(state.chunks.reduce(0) { $0 + $1.count })
            for chunk in state.chunks { combined.append(contentsOf: chunk) }
            return [
                .finish(
                    audio: MediaAsset.bytes(combined, mediaType: mediaType, info: info),
                    usage: usage,
                    providerMetadata: providerMetadata
                ),
            ]
        }

        // parity: ai/src/protocols/utils/speech-stream.ts#headerUsage [status=implemented hash=dd344eea2ac2]
        public static func headerUsage(type: String, value: String?) -> MediaUsage? {
            guard let value, let amount = Double(value), amount.isFinite else { return nil }
            return type == "credits" ? .credits(amount) : .characters(amount)
        }
    }

    // MARK: - ToolSchema (packages/ai/src/protocols/utils/tool-schema.ts — 1 symbol)

    // parity: ai/src/protocols/utils/tool-schema.ts#ToolSchemaProjection [status=implemented hash=1dfa54def43f]
    public enum ToolSchemaProjection {
        public static func gemini(_ schema: [String: JSONValue]) -> [String: JSONValue] {
            GeminiJsonSchema.normalize(schema)
        }

        private static func tupleItemsSchema(_ items: [JSONValue]) -> JSONValue {
            let projected = items.map(moonshotNode)
            if projected.isEmpty { return .object([:]) }
            if projected.count == 1 { return projected[0] }
            return .object(["anyOf": .array(projected)])
        }

        private static func enumType(_ values: [JSONValue]) -> JSONValue? {
            var types: [String] = []
            for value in values {
                let t: String
                switch value {
                case .null: t = "null"
                case .bool: t = "boolean"
                case .int, .double: t = "number"
                case .string: t = "string"
                case .array: t = "array"
                case .object: t = "object"
                }
                if !types.contains(t) { types.append(t) }
            }
            if types.count == 1 { return .string(types[0]) }
            if types.count == 2 && types.contains("null") {
                let nonNull = types.filter { $0 != "null" }
                return .array((nonNull + ["null"]).map(JSONValue.string))
            }
            return nil
        }

        private static func moonshotNode(_ schema: JSONValue) -> JSONValue {
            switch schema {
            case .array(let items):
                return .array(items.map(moonshotNode))
            case .object(let obj):
                if case .string(let ref) = obj["$ref"] {
                    return .object(["$ref": .string(ref)])
                }
                var out: [String: JSONValue] = [:]
                if obj["type"] == nil, case .array(let enumValues) = obj["enum"], let inferred = enumType(enumValues) {
                    out["type"] = inferred
                }
                for (key, value) in obj {
                    if GeminiJsonSchema.VALUES.contains(key) {
                        out[key] = value
                        continue
                    }
                    if GeminiJsonSchema.SCHEMA_MAPS.contains(key), case .object(let sub) = value {
                        out[key] = .object(GeminiJsonSchema.mapValues(sub) { v, _ in moonshotNode(v) })
                        continue
                    }
                    if key == "items" {
                        if case .array = obj["prefixItems"] { continue }
                        if case .array(let tupleItems) = value {
                            out[key] = tupleItemsSchema(tupleItems)
                            continue
                        }
                    }
                    if key == "prefixItems" {
                        if case .array(let prefix) = value {
                            let rest: [JSONValue]
                            if case .object = obj["items"] {
                                rest = [obj["items"]!]
                            } else if case .array(let itemsArr) = obj["items"] {
                                rest = itemsArr
                            } else {
                                rest = []
                            }
                            out["items"] = tupleItemsSchema(prefix + rest)
                        } else if obj["items"] == nil {
                            out["items"] = .object([:])
                        }
                        continue
                    }
                    if key == "unevaluatedItems" { continue }
                    out[key] = moonshotNode(value)
                }
                return .object(out)
            default:
                return schema
            }
        }

        public static func moonshot(_ schema: [String: JSONValue]) -> [String: JSONValue] {
            guard case .object(let projected) = moonshotNode(.object(schema)) else { return [:] }
            return projected
        }

        public static func objectRoot(_ schema: [String: JSONValue]) -> [String: JSONValue] {
            if (schema["type"] == nil || schema["type"] == .string("object")),
               case .object(let notObj) = schema["not"],
               notObj.count == 1, notObj["type"] == .string("null") {
                var copy = schema
                copy.removeValue(forKey: "not")
                copy["type"] = .string("object")
                return copy
            }
            if schema["type"] != nil { return schema }
            if case .array(let branches) = schema["anyOf"],
               branches.contains(where: {
                   if case .object(let b) = $0, b.count == 1, b["type"] == .string("object") { return true }
                   return false
               }) {
                var copy = schema
                copy.removeValue(forKey: "anyOf")
                copy["type"] = .string("object")
                return copy
            }
            var copy = schema
            copy["type"] = .string("object")
            return copy
        }

        public static func project(_ schema: [String: JSONValue], for model: ModelDescriptor) -> [String: JSONValue] {
            let root = objectRoot(schema)
            let sanitizer = model.compatibility?.sanitizer ?? model.sanitizer ?? {
                let lower = model.id.lowercased()
                if lower.contains("gemini") { return "gemini" }
                if lower.contains("kimi") { return "moonshot" }
                return nil
            }()
            switch sanitizer {
            case "gemini": return gemini(root)
            case "moonshot": return moonshot(root)
            default: return root
            }
        }

        public static func tools(_ entries: [ToolEntry], for model: ModelDescriptor) -> [ToolEntry] {
            entries.map { entry in
                switch entry {
                case .tool(let def):
                    return .tool(ToolDefinition(
                        name: def.name,
                        description: def.description,
                        inputSchema: project(def.inputSchema, for: model),
                        cache: def.cache,
                        freeform: def.freeform,
                        native: def.native
                    ))
                case .namespace(let name, let desc, let nested):
                    return .namespace(name: name, description: desc, tools: tools(nested, for: model))
                }
            }
        }
    }

    // MARK: - ToolStream (packages/ai/src/protocols/utils/tool-stream.ts — 11 symbols)

    public enum ToolStream {
        // parity: ai/src/protocols/utils/tool-stream.ts#PendingTool [status=implemented hash=2fc7a7903238]
        public struct PendingTool: Equatable, Hashable, Sendable {
            public let id: String
            public let name: String
            public let namespace: String?
            public let input: String
            public let providerExecuted: Bool?
            public let providerMetadata: ProviderMetadata?

            public init(
                id: String,
                name: String,
                namespace: String? = nil,
                input: String = "",
                providerExecuted: Bool? = nil,
                providerMetadata: ProviderMetadata? = nil
            ) {
                self.id = id
                self.name = name
                self.namespace = namespace
                self.input = input
                self.providerExecuted = providerExecuted
                self.providerMetadata = providerMetadata
            }
        }

        // parity: ai/src/protocols/utils/tool-stream.ts#State [status=implemented hash=80b6bf437b2e]
        public typealias State<K: Hashable & Sendable> = [K: PendingTool]

        // parity: ai/src/protocols/utils/tool-stream.ts#AppendOutcome [status=implemented hash=532dafb78a96]
        public struct AppendOutcome<K: Hashable & Sendable>: Equatable, Sendable {
            public let tools: State<K>
            public let tool: PendingTool
            public let events: [LLMEvent]

            public init(tools: State<K>, tool: PendingTool, events: [LLMEvent]) {
                self.tools = tools
                self.tool = tool
                self.events = events
            }
        }

        public enum AppendResult<K: Hashable & Sendable>: Sendable {
            case ok(AppendOutcome<K>)
            case error(ProtocolError)
        }

        // parity: ai/src/protocols/utils/tool-stream.ts#empty [status=implemented hash=db1e4b48606d]
        public static func empty<K: Hashable & Sendable>() -> State<K> {
            [:]
        }

        // parity: ai/src/protocols/utils/tool-stream.ts#isError [status=implemented hash=fad15e3f97ca]
        public static func isError<K: Hashable & Sendable>(_ result: AppendResult<K>) -> Bool {
            if case .error = result { return true }
            return false
        }

        private static func inputStart(_ tool: PendingTool) -> LLMEvent {
            .toolInputStart(
                id: tool.id,
                name: tool.name,
                namespace: tool.namespace,
                providerExecuted: tool.providerExecuted == true ? true : nil,
                providerMetadata: tool.providerMetadata
            )
        }

        private static func inputDelta(_ tool: PendingTool, text: String) -> LLMEvent {
            let partial = (try? PartialJSONParser.parse(tool.input)) ?? .object([:])
            return .toolInputDelta(
                id: tool.id,
                name: tool.name,
                namespace: tool.namespace,
                text: text,
                partialInput: partial
            )
        }

        private static func makeToolCall(
            route: String,
            tool: PendingTool,
            inputOverride: String? = nil
        ) throws(ProtocolError) -> LLMEvent {
            let raw = inputOverride ?? tool.input
            do {
                let parsed = try ProviderShared.parseToolInput(route: route, name: tool.name, raw: raw)
                return .toolCall(
                    id: tool.id,
                    name: tool.name,
                    namespace: tool.namespace,
                    input: parsed,
                    providerExecuted: tool.providerExecuted == true ? true : nil,
                    providerMetadata: tool.providerMetadata
                )
            } catch {
                if tool.providerExecuted == true { throw error }
                return .toolInputError(id: tool.id, name: tool.name, namespace: tool.namespace, raw: raw)
            }
        }

        private static func finishEvents(tool: PendingTool, event: LLMEvent) -> [LLMEvent] {
            [
                .toolInputEnd(
                    id: tool.id,
                    name: tool.name,
                    namespace: tool.namespace,
                    providerMetadata: tool.providerMetadata
                ),
                event,
            ]
        }

        private static func appendTool<K: Hashable & Sendable>(
            _ tools: State<K>,
            key: K,
            tool: PendingTool,
            text: String
        ) -> AppendOutcome<K> {
            var events: [LLMEvent] = []
            if tools[key] == nil { events.append(inputStart(tool)) }
            if !text.isEmpty { events.append(inputDelta(tool, text: text)) }
            var next = tools
            next[key] = tool
            return AppendOutcome(tools: next, tool: tool, events: events)
        }

        // parity: ai/src/protocols/utils/tool-stream.ts#start [status=implemented hash=d6cc33086f7e]
        public static func start<K: Hashable & Sendable>(
            _ tools: State<K>,
            key: K,
            tool: PendingTool
        ) -> State<K> {
            var next = tools
            next[key] = tool
            return next
        }

        // parity: ai/src/protocols/utils/tool-stream.ts#appendOrStart [status=implemented hash=adc5c0df8e02]
        public static func appendOrStart<K: Hashable & Sendable>(
            route: String,
            tools: State<K>,
            key: K,
            id: String?,
            name: String?,
            text: String,
            providerMetadata: ProviderMetadata? = nil,
            missingToolMessage: String
        ) -> AppendResult<K> {
            let current = tools[key]
            guard let resolvedID = current?.id ?? id, !resolvedID.isEmpty,
                  let resolvedName = current?.name ?? name, !resolvedName.isEmpty else {
                return .error(ProviderShared.eventError(route, missingToolMessage))
            }
            let tool = PendingTool(
                id: resolvedID,
                name: resolvedName,
                namespace: current?.namespace,
                input: (current?.input ?? "") + text,
                providerExecuted: current?.providerExecuted,
                providerMetadata: current?.providerMetadata ?? providerMetadata
            )
            if let current, text.isEmpty, current.id == resolvedID, current.name == resolvedName {
                return .ok(AppendOutcome(tools: tools, tool: current, events: []))
            }
            return .ok(appendTool(tools, key: key, tool: tool, text: text))
        }

        // parity: ai/src/protocols/utils/tool-stream.ts#append [status=implemented hash=3b236aaff6d4]
        public static func append<K: Hashable & Sendable>(
            _ tools: State<K>,
            key: K,
            text: String
        ) -> AppendOutcome<K>? {
            guard let current = tools[key] else { return nil }
            if text.isEmpty { return AppendOutcome(tools: tools, tool: current, events: []) }
            let updated = PendingTool(
                id: current.id,
                name: current.name,
                namespace: current.namespace,
                input: current.input + text,
                providerExecuted: current.providerExecuted,
                providerMetadata: current.providerMetadata
            )
            return appendTool(tools, key: key, tool: updated, text: text)
        }

        // parity: ai/src/protocols/utils/tool-stream.ts#appendExisting [status=implemented hash=561d5036dbaa]
        public static func appendExisting<K: Hashable & Sendable>(
            route: String,
            tools: State<K>,
            key: K,
            text: String,
            missingToolMessage: String
        ) -> AppendResult<K> {
            if let outcome = append(tools, key: key, text: text) {
                return .ok(outcome)
            }
            return .error(ProviderShared.eventError(route, missingToolMessage))
        }

        // parity: ai/src/protocols/utils/tool-stream.ts#finish [status=implemented hash=1bf189a7f098]
        public static func finish<K: Hashable & Sendable>(
            route: String,
            tools: State<K>,
            key: K,
            input: String? = nil
        ) throws(ProtocolError) -> (tools: State<K>, events: [LLMEvent]) {
            guard let tool = tools[key] else { return (tools, []) }
            var next = tools
            next.removeValue(forKey: key)
            let event = try makeToolCall(route: route, tool: tool, inputOverride: input)
            return (next, finishEvents(tool: tool, event: event))
        }

        // parity: ai/src/protocols/utils/tool-stream.ts#finishAll [status=implemented hash=782f1ad44f5a]
        public static func finishAll<K: Hashable & Sendable & Comparable>(
            route: String,
            tools: State<K>
        ) throws(ProtocolError) -> (tools: State<K>, events: [LLMEvent]) {
            var events: [LLMEvent] = []
            for key in tools.keys.sorted() {
                guard let tool = tools[key] else { continue }
                let event = try makeToolCall(route: route, tool: tool)
                events.append(contentsOf: finishEvents(tool: tool, event: event))
            }
            return (empty(), events)
        }
    }
}

// MARK: - BedrockEventStream (packages/ai/src/protocols/bedrock-event-stream.ts — 2 symbols + Full Binary CRC32 Codec)

/// Real binary AWS EventStream encoder and incremental decoder with IEEE 802.3 CRC32 verification
/// for both prelude CRC and message CRC, full 10-type header support, and Bedrock `:event-type` rewrapping.
public enum BedrockEventStream {

    /// IEEE 802.3 / ISO 3309 CRC32 lookup table (polynomial 0xEDB88320).
    private static let crc32Table: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()

    /// Computes standard IEEE 802.3 CRC32 used by AWS EventStream framing.
    public static func crc32(_ bytes: [UInt8]) -> UInt32 {
        crc32(bytes[...])
    }

    public static func crc32(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            let idx = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = crc32Table[idx] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    public enum HeaderValue: Equatable, Hashable, Sendable {
        case boolTrue
        case boolFalse
        case byte(Int8)
        case int16(Int16)
        case int32(Int32)
        case int64(Int64)
        case bytes([UInt8])
        case string(String)
        case timestamp(Int64)
        case uuid([UInt8]) // 16 bytes

        public var stringValue: String? {
            if case .string(let s) = self { return s }
            return nil
        }

        public var jsonValue: JSONValue {
            switch self {
            case .boolTrue: return .object(["type": .string("boolean"), "value": .bool(true)])
            case .boolFalse: return .object(["type": .string("boolean"), "value": .bool(false)])
            case .byte(let v): return .object(["type": .string("byte"), "value": .int(Int64(v))])
            case .int16(let v): return .object(["type": .string("short"), "value": .int(Int64(v))])
            case .int32(let v): return .object(["type": .string("integer"), "value": .int(Int64(v))])
            case .int64(let v): return .object(["type": .string("long"), "value": .int(v)])
            case .bytes(let b): return .object(["type": .string("binary"), "value": .string(bytesToBase64(b))])
            case .string(let s): return .object(["type": .string("string"), "value": .string(s)])
            case .timestamp(let t): return .object(["type": .string("timestamp"), "value": .int(t)])
            case .uuid(let u): return .object(["type": .string("uuid"), "value": .string(AIProtocolUtils.JSONCodec.bytesToHex(u))])
            }
        }
    }

    public struct BinaryMessage: Equatable, Hashable, Sendable {
        public let headers: [String: HeaderValue]
        public let body: [UInt8]

        public init(headers: [String: HeaderValue], body: [UInt8]) {
            self.headers = headers
            self.body = body
        }
    }

    private static func appendUInt16BE(_ value: UInt16, to out: inout [UInt8]) {
        out.append(UInt8((value >> 8) & 0xFF))
        out.append(UInt8(value & 0xFF))
    }

    private static func appendUInt32BE(_ value: UInt32, to out: inout [UInt8]) {
        out.append(UInt8((value >> 24) & 0xFF))
        out.append(UInt8((value >> 16) & 0xFF))
        out.append(UInt8((value >> 8) & 0xFF))
        out.append(UInt8(value & 0xFF))
    }

    private static func appendUInt64BE(_ value: UInt64, to out: inout [UInt8]) {
        appendUInt32BE(UInt32((value >> 32) & 0xFFFF_FFFF), to: &out)
        appendUInt32BE(UInt32(value & 0xFFFF_FFFF), to: &out)
    }

    private static func readUInt16BE(_ bytes: ArraySlice<UInt8>, at offset: Int) -> UInt16 {
        let base = bytes.startIndex + offset
        return (UInt16(bytes[base]) << 8) | UInt16(bytes[base + 1])
    }

    private static func readUInt32BE(_ bytes: ArraySlice<UInt8>, at offset: Int) -> UInt32 {
        let base = bytes.startIndex + offset
        return (UInt32(bytes[base]) << 24)
            | (UInt32(bytes[base + 1]) << 16)
            | (UInt32(bytes[base + 2]) << 8)
            | UInt32(bytes[base + 3])
    }

    private static func readUInt64BE(_ bytes: ArraySlice<UInt8>, at offset: Int) -> UInt64 {
        let hi = UInt64(readUInt32BE(bytes, at: offset))
        let lo = UInt64(readUInt32BE(bytes, at: offset + 4))
        return (hi << 32) | lo
    }

    /// Encodes a `BinaryMessage` into an AWS EventStream frame:
    /// `[totalLength:4][headersLength:4][preludeCRC:4][headers][payload][messageCRC:4]`.
    public static func encodeMessage(_ message: BinaryMessage) -> [UInt8] {
        var encodedHeaders: [UInt8] = []
        for name in message.headers.keys.sorted() {
            let nameBytes = Array(name.utf8)
            guard nameBytes.count <= 255 else { continue }
            encodedHeaders.append(UInt8(nameBytes.count))
            encodedHeaders.append(contentsOf: nameBytes)
            switch message.headers[name]! {
            case .boolTrue:
                encodedHeaders.append(0)
            case .boolFalse:
                encodedHeaders.append(1)
            case .byte(let v):
                encodedHeaders.append(2)
                encodedHeaders.append(UInt8(bitPattern: v))
            case .int16(let v):
                encodedHeaders.append(3)
                appendUInt16BE(UInt16(bitPattern: v), to: &encodedHeaders)
            case .int32(let v):
                encodedHeaders.append(4)
                appendUInt32BE(UInt32(bitPattern: v), to: &encodedHeaders)
            case .int64(let v):
                encodedHeaders.append(5)
                appendUInt64BE(UInt64(bitPattern: v), to: &encodedHeaders)
            case .bytes(let b):
                encodedHeaders.append(6)
                appendUInt16BE(UInt16(b.count), to: &encodedHeaders)
                encodedHeaders.append(contentsOf: b)
            case .string(let s):
                let strBytes = Array(s.utf8)
                encodedHeaders.append(7)
                appendUInt16BE(UInt16(strBytes.count), to: &encodedHeaders)
                encodedHeaders.append(contentsOf: strBytes)
            case .timestamp(let t):
                encodedHeaders.append(8)
                appendUInt64BE(UInt64(bitPattern: t), to: &encodedHeaders)
            case .uuid(let u):
                encodedHeaders.append(9)
                encodedHeaders.append(contentsOf: u.prefix(16))
                if u.count < 16 {
                    encodedHeaders.append(contentsOf: repeatElement(UInt8(0), count: 16 - u.count))
                }
            }
        }

        let headersLength = UInt32(encodedHeaders.count)
        let totalLength = UInt32(16 + encodedHeaders.count + message.body.count)

        var frame: [UInt8] = []
        frame.reserveCapacity(Int(totalLength))
        appendUInt32BE(totalLength, to: &frame)
        appendUInt32BE(headersLength, to: &frame)
        let preludeCRC = crc32(frame[0..<8])
        appendUInt32BE(preludeCRC, to: &frame)
        frame.append(contentsOf: encodedHeaders)
        frame.append(contentsOf: message.body)
        let messageCRC = crc32(frame[...])
        appendUInt32BE(messageCRC, to: &frame)
        return frame
    }

    /// Decodes a single complete AWS EventStream binary frame and verifies both prelude and message CRC32 checksums.
    public static func decodeMessage(
        _ frame: ArraySlice<UInt8>,
        route: String = "bedrock-converse"
    ) throws(AIProtocolUtils.ProtocolError) -> BinaryMessage {
        guard frame.count >= 16 else {
            throw AIProtocolUtils.ProviderShared.eventError(
                route,
                "Failed to decode Bedrock Converse event-stream frame: frame shorter than 16 bytes (\(frame.count))",
                body: bytesToBase64(Array(frame))
            )
        }
        let totalLength = Int(readUInt32BE(frame, at: 0))
        let headersLength = Int(readUInt32BE(frame, at: 4))
        let expectedPreludeCRC = readUInt32BE(frame, at: 8)
        guard totalLength == frame.count, totalLength >= 16, headersLength <= totalLength - 16 else {
            throw AIProtocolUtils.ProviderShared.eventError(
                route,
                "Failed to decode Bedrock Converse event-stream frame: invalid frame lengths (total=\(totalLength), headers=\(headersLength), actual=\(frame.count))",
                body: bytesToBase64(Array(frame))
            )
        }
        let preludeEnd = frame.startIndex + 8
        let computedPreludeCRC = crc32(frame[frame.startIndex..<preludeEnd])
        guard computedPreludeCRC == expectedPreludeCRC else {
            throw AIProtocolUtils.ProviderShared.eventError(
                route,
                "Failed to decode Bedrock Converse event-stream frame: prelude CRC32 mismatch (expected=\(expectedPreludeCRC), computed=\(computedPreludeCRC))",
                body: bytesToBase64(Array(frame))
            )
        }
        let messageBodyEnd = frame.startIndex + totalLength - 4
        let expectedMessageCRC = readUInt32BE(frame, at: totalLength - 4)
        let computedMessageCRC = crc32(frame[frame.startIndex..<messageBodyEnd])
        guard computedMessageCRC == expectedMessageCRC else {
            throw AIProtocolUtils.ProviderShared.eventError(
                route,
                "Failed to decode Bedrock Converse event-stream frame: message CRC32 mismatch (expected=\(expectedMessageCRC), computed=\(computedMessageCRC))",
                body: bytesToBase64(Array(frame))
            )
        }

        var headers: [String: HeaderValue] = [:]
        var cursor = 12
        let headersEnd = 12 + headersLength
        while cursor < headersEnd {
            let nameLen = Int(frame[frame.startIndex + cursor])
            cursor += 1
            guard cursor + nameLen + 1 <= headersEnd else {
                throw AIProtocolUtils.ProviderShared.eventError(route, "Failed to decode Bedrock Converse event-stream frame: truncated header name")
            }
            let nameSlice = frame[(frame.startIndex + cursor)..<(frame.startIndex + cursor + nameLen)]
            let name = String(decoding: nameSlice, as: UTF8.self)
            cursor += nameLen
            let valueType = frame[frame.startIndex + cursor]
            cursor += 1
            switch valueType {
            case 0:
                headers[name] = .boolTrue
            case 1:
                headers[name] = .boolFalse
            case 2:
                guard cursor + 1 <= headersEnd else {
                    throw AIProtocolUtils.ProviderShared.eventError(route, "Failed to decode Bedrock Converse event-stream frame: truncated byte header")
                }
                headers[name] = .byte(Int8(bitPattern: frame[frame.startIndex + cursor]))
                cursor += 1
            case 3:
                guard cursor + 2 <= headersEnd else {
                    throw AIProtocolUtils.ProviderShared.eventError(route, "Failed to decode Bedrock Converse event-stream frame: truncated int16 header")
                }
                headers[name] = .int16(Int16(bitPattern: readUInt16BE(frame, at: cursor)))
                cursor += 2
            case 4:
                guard cursor + 4 <= headersEnd else {
                    throw AIProtocolUtils.ProviderShared.eventError(route, "Failed to decode Bedrock Converse event-stream frame: truncated int32 header")
                }
                headers[name] = .int32(Int32(bitPattern: readUInt32BE(frame, at: cursor)))
                cursor += 4
            case 5:
                guard cursor + 8 <= headersEnd else {
                    throw AIProtocolUtils.ProviderShared.eventError(route, "Failed to decode Bedrock Converse event-stream frame: truncated int64 header")
                }
                headers[name] = .int64(Int64(bitPattern: readUInt64BE(frame, at: cursor)))
                cursor += 8
            case 6:
                guard cursor + 2 <= headersEnd else {
                    throw AIProtocolUtils.ProviderShared.eventError(route, "Failed to decode Bedrock Converse event-stream frame: truncated bytes length")
                }
                let len = Int(readUInt16BE(frame, at: cursor))
                cursor += 2
                guard cursor + len <= headersEnd else {
                    throw AIProtocolUtils.ProviderShared.eventError(route, "Failed to decode Bedrock Converse event-stream frame: truncated bytes payload")
                }
                headers[name] = .bytes(Array(frame[(frame.startIndex + cursor)..<(frame.startIndex + cursor + len)]))
                cursor += len
            case 7:
                guard cursor + 2 <= headersEnd else {
                    throw AIProtocolUtils.ProviderShared.eventError(route, "Failed to decode Bedrock Converse event-stream frame: truncated string length")
                }
                let len = Int(readUInt16BE(frame, at: cursor))
                cursor += 2
                guard cursor + len <= headersEnd else {
                    throw AIProtocolUtils.ProviderShared.eventError(route, "Failed to decode Bedrock Converse event-stream frame: truncated string payload")
                }
                let strSlice = frame[(frame.startIndex + cursor)..<(frame.startIndex + cursor + len)]
                headers[name] = .string(String(decoding: strSlice, as: UTF8.self))
                cursor += len
            case 8:
                guard cursor + 8 <= headersEnd else {
                    throw AIProtocolUtils.ProviderShared.eventError(route, "Failed to decode Bedrock Converse event-stream frame: truncated timestamp header")
                }
                headers[name] = .timestamp(Int64(bitPattern: readUInt64BE(frame, at: cursor)))
                cursor += 8
            case 9:
                guard cursor + 16 <= headersEnd else {
                    throw AIProtocolUtils.ProviderShared.eventError(route, "Failed to decode Bedrock Converse event-stream frame: truncated uuid header")
                }
                headers[name] = .uuid(Array(frame[(frame.startIndex + cursor)..<(frame.startIndex + cursor + 16)]))
                cursor += 16
            default:
                throw AIProtocolUtils.ProviderShared.eventError(route, "Failed to decode Bedrock Converse event-stream frame: unknown header type \(valueType)")
            }
        }

        let payloadStart = frame.startIndex + 12 + headersLength
        let body = Array(frame[payloadStart..<messageBodyEnd])
        return BinaryMessage(headers: headers, body: body)
    }

    // parity: ai/src/protocols/bedrock-event-stream.ts#Frame [status=implemented hash=6668d5647fee]
    public struct Frame: Equatable, Hashable, Sendable {
        public let event: [String: JSONValue]
        public let rawBody: String

        public init(event: [String: JSONValue], rawBody: String) {
            self.event = event
            self.rawBody = rawBody
        }
    }

    public struct FramingDefinition: Sendable {
        public let id: String
        public let route: String

        public init(route: String) {
            self.id = "aws-event-stream"
            self.route = route
        }

        public func makeDecoder() -> FrameDecoder {
            FrameDecoder(route: route)
        }

        public func decodeAll(_ bytes: [UInt8]) throws(AIProtocolUtils.ProtocolError) -> [Frame] {
            var decoder = FrameDecoder(route: route)
            let frames = try decoder.feed(bytes)
            try decoder.finish()
            return frames
        }
    }

    public struct FrameDecoder: Sendable {
        public let route: String
        private var buffer: [UInt8] = []
        private var offset = 0

        public init(route: String = "bedrock-converse") {
            self.route = route
        }

        public mutating func feed(_ chunk: [UInt8]) throws(AIProtocolUtils.ProtocolError) -> [Frame] {
            if offset > 0 {
                buffer = Array(buffer[offset...])
                offset = 0
            }
            buffer.append(contentsOf: chunk)

            var out: [Frame] = []
            while buffer.count - offset >= 4 {
                let remaining = buffer[offset...]
                let totalLength = Int(
                    (UInt32(remaining[remaining.startIndex]) << 24)
                        | (UInt32(remaining[remaining.startIndex + 1]) << 16)
                        | (UInt32(remaining[remaining.startIndex + 2]) << 8)
                        | UInt32(remaining[remaining.startIndex + 3])
                )
                if totalLength < 16 {
                    throw AIProtocolUtils.ProviderShared.eventError(
                        route,
                        "Failed to decode Bedrock Converse event-stream frame: invalid total length \(totalLength)"
                    )
                }
                if remaining.count < totalLength { break }

                let frameSlice = buffer[offset..<(offset + totalLength)]
                let decoded = try BedrockEventStream.decodeMessage(frameSlice, route: route)
                offset += totalLength

                let payload = String(decoding: decoded.body, as: UTF8.self)
                var headerJSON: [String: JSONValue] = [:]
                for (k, v) in decoded.headers { headerJSON[k] = v.jsonValue }
                let rawBody = AIProtocolUtils.JSONCodec.encodeObject([
                    "headers": .object(headerJSON),
                    "body": .string(payload),
                ])

                let messageType = decoded.headers[":message-type"]?.stringValue
                if messageType == "error" {
                    let code = decoded.headers[":error-code"]?.stringValue
                    let msg = decoded.headers[":error-message"]?.stringValue
                    let parts = [code, msg].compactMap { $0 }
                    let text = parts.isEmpty ? "Bedrock Converse event-stream error" : parts.joined(separator: ": ")
                    throw AIProtocolUtils.ProviderShared.eventError(route, text, body: rawBody)
                }

                let eventType: String?
                if messageType == "event" {
                    eventType = decoded.headers[":event-type"]?.stringValue
                } else if messageType == "exception" {
                    eventType = decoded.headers[":exception-type"]?.stringValue
                } else {
                    eventType = nil
                }
                guard let eventType, !payload.isEmpty else { continue }

                let parsed = try AIProtocolUtils.ProviderShared.parseJson(
                    route: route,
                    input: payload,
                    message: "Failed to parse Bedrock Converse event-stream payload"
                )
                guard var record = AIProtocolUtils.JSONCodec.objectValue(parsed) else {
                    throw AIProtocolUtils.ProviderShared.eventError(
                        route,
                        "Failed to parse Bedrock Converse event-stream payload",
                        body: rawBody
                    )
                }
                // Strip AWS padding field `"p"`.
                record.removeValue(forKey: "p")

                let wrapped: [String: JSONValue]
                if messageType == "exception" {
                    wrapped = ["exception": .object(["type": .string(eventType), "details": .object(record)])]
                } else {
                    wrapped = [eventType: .object(record)]
                }
                out.append(Frame(event: wrapped, rawBody: rawBody))
            }
            return out
        }

        public mutating func finish() throws(AIProtocolUtils.ProtocolError) {
            let remaining = buffer.count - offset
            if remaining > 0 {
                throw AIProtocolUtils.ProtocolError(
                    kind: .invalidProviderOutput,
                    message: "Incomplete Bedrock Converse event-stream frame: \(remaining) buffered bytes remain at end of stream",
                    route: route,
                    body: bytesToBase64(Array(buffer[offset...])),
                    classification: "incomplete-stream"
                )
            }
        }
    }

    // parity: ai/src/protocols/bedrock-event-stream.ts#framing [status=implemented hash=f961b50c4327]
    public static func framing(route: String = "bedrock-converse") -> FramingDefinition {
        FramingDefinition(route: route)
    }
}

// MARK: - Internal String Helpers (Pure Stdlib, Zero Foundation Dependency)

extension String {
    func trimmingASCIIWhitespace() -> String {
        var start = startIndex
        var end = endIndex
        while start < end && isASCIIOrUnicodeWhitespace(self[start]) {
            start = index(after: start)
        }
        while end > start {
            let prev = index(before: end)
            if isASCIIOrUnicodeWhitespace(self[prev]) {
                end = prev
            } else {
                break
            }
        }
        return String(self[start..<end])
    }

    func trimmingTrailingASCIIWhitespace() -> String {
        var end = endIndex
        while end > startIndex {
            let prev = index(before: end)
            if isASCIIOrUnicodeWhitespace(self[prev]) {
                end = prev
            } else {
                break
            }
        }
        return String(self[..<end])
    }

    func replacingOccurrences(of target: String, with replacement: String) -> String {
        guard !target.isEmpty else { return self }
        var out = ""
        var current = startIndex
        while let range = self.findFirstRange(of: target, startingAt: current) {
            out.append(contentsOf: self[current..<range.lowerBound])
            out.append(replacement)
            current = range.upperBound
        }
        out.append(contentsOf: self[current..<endIndex])
        return out
    }

    private func findFirstRange(of needle: String, startingAt start: Index) -> Range<Index>? {
        let needleCount = needle.count
        var i = start
        while i < endIndex {
            var j = i
            var k = needle.startIndex
            var matched = 0
            while j < endIndex && k < needle.endIndex && self[j] == needle[k] {
                j = index(after: j)
                k = needle.index(after: k)
                matched += 1
            }
            if matched == needleCount {
                return i..<j
            }
            i = index(after: i)
        }
        return nil
    }

    func range(of needle: String) -> Range<Index>? {
        findFirstRange(of: needle, startingAt: startIndex)
    }

    private func isASCIIOrUnicodeWhitespace(_ ch: Character) -> Bool {
        ch.isWhitespace || ch == "\u{FEFF}"
    }
}
