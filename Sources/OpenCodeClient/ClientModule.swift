#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import OpenCodePlatform
import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeUtil

/// Entry module for `OpenCodeClient` (port of `packages/client`: typed HTTP/SSE/WS client,
/// background service discovery, Effect-style service layer, and reactive state stores).
/// Portable tier: depends only on `OpenCodeUtil`, `OpenCodeSchema`, `OpenCodeProtocol`,
/// and `OpenCodePlatform` — never `OpenCodeCore`, `OpenCodeServer`, or OS C-libs.
public enum OpenCodeClientModule {
    public static let upstreamPackage = "client"

    /// Re-exported protocol contract surface matching `packages/client/src/contract.ts`.
    public static let api: ProtocolApi = OpenCodeProtocol.ClientApi
    public static let groupNames: [String: String] = OpenCodeProtocol.groupNames
    public static let promiseOmitEndpoints: Set<String> = OpenCodeProtocol.promiseOmitEndpoints
    public static let effectOmitEndpoints: Set<String> = OpenCodeProtocol.effectOmitEndpoints

    public static func clientNamespace(path: String) -> String? {
        OpenCodeProtocol.clientNamespace(path: path)
    }

    public static func clientNamespace(_ endpoint: EndpointDescriptor) -> String? {
        OpenCodeProtocol.clientNamespace(endpoint)
    }
}

// MARK: - Portable Clock

public enum ClientClock {
    public static func nowEpochMs() -> Int64 {
        Flock.currentEpochMs()
    }
}

// MARK: - Portable JSON Codec

public enum ClientCodec {
    public static func encode<T: Encodable>(_ value: T) throws -> [UInt8] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return Array(try encoder.encode(value))
    }

    public static func encodeString<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try encode(value), as: UTF8.self)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from bytes: [UInt8]) throws -> T {
        try JSONDecoder().decode(type, from: Data(bytes))
    }

    public static func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(text.utf8))
    }

    public static func toJSONValue<T: Encodable>(_ value: T) throws -> JSONValue {
        let bytes = try encode(value)
        return try decode(JSONValue.self, from: bytes)
    }

    public static func fromJSONValue<T: Decodable>(_ type: T.Type, value: JSONValue) throws -> T {
        let bytes = try encode(value)
        return try decode(type, from: bytes)
    }
}

// MARK: - Portable URL, Path & Query Encoding

public enum ClientURLBuilder {
    /// Joins a leading-slash `path` relative to `baseUrl`, preserving any base path prefix
    /// (matching upstream `new URL(descriptor.path.slice(1), baseUrlWithTrailingSlash)`).
    public static func join(
        baseUrl: String,
        path: String,
        query: [(String, JSONValue?)] = []
    ) -> String {
        let (baseWithoutFragment, _) = splitOnce(baseUrl, separator: "#")
        let (basePathPart, baseQueryPart) = splitOnce(baseWithoutFragment, separator: "?")

        let trimmedBase = basePathPart.hasSuffix("/") ? String(basePathPart.dropLast()) : basePathPart
        let normalizedPath: String
        if path.isEmpty {
            normalizedPath = ""
        } else if path.hasPrefix("/") {
            normalizedPath = path
        } else {
            normalizedPath = "/" + path
        }

        var queryItems: [(String, String)] = []
        if let baseQueryPart, !baseQueryPart.isEmpty {
            for pair in baseQueryPart.split(separator: "&", omittingEmptySubsequences: true) {
                let (k, v) = splitOnce(String(pair), separator: "=")
                queryItems.append((decodeFormComponent(k), decodeFormComponent(v ?? "")))
            }
        }
        for (key, value) in query {
            appendQuery(items: &queryItems, key: key, value: value)
        }

        let joinedPath = trimmedBase + normalizedPath
        if queryItems.isEmpty {
            return joinedPath
        }
        return joinedPath + "?" + encodeFormQuery(queryItems)
    }

    /// Builds a WebSocket (`ws:` / `wss:`) URL from an HTTP(S) or WS(S) `baseUrl` and relative path.
    public static func webSocketURL(
        baseUrl: String,
        relativePath: String,
        query: [(String, String)] = [],
        preserveBaseQuery: Bool = false
    ) -> String {
        let (baseWithoutFragment, _) = splitOnce(baseUrl, separator: "#")
        let (basePathPart, baseQueryPart) = splitOnce(baseWithoutFragment, separator: "?")

        let trimmedBase = basePathPart.hasSuffix("/") ? String(basePathPart.dropLast()) : basePathPart
        let rel = relativePath.hasPrefix("/") ? relativePath : "/" + relativePath
        var combined = trimmedBase + rel

        if combined.lowercased().hasPrefix("https://") {
            combined = "wss://" + combined.dropFirst("https://".count)
        } else if combined.lowercased().hasPrefix("http://") {
            combined = "ws://" + combined.dropFirst("http://".count)
        }

        var items: [(String, String)] = []
        if preserveBaseQuery, let baseQueryPart, !baseQueryPart.isEmpty {
            for pair in baseQueryPart.split(separator: "&", omittingEmptySubsequences: true) {
                let (k, v) = splitOnce(String(pair), separator: "=")
                items.append((decodeFormComponent(k), decodeFormComponent(v ?? "")))
            }
        }
        for (k, v) in query {
            if let existing = items.firstIndex(where: { $0.0 == k }) {
                items[existing] = (k, v)
            } else {
                items.append((k, v))
            }
        }

        if items.isEmpty {
            return combined
        }
        return combined + "?" + encodeFormQuery(items)
    }

    /// Matches JavaScript `encodeURIComponent(value)`.
    public static func encodeURIComponent(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.utf8.count)
        for byte in value.utf8 {
            if isURIComponentUnreserved(byte) {
                out.append(Character(UnicodeScalar(byte)))
            } else {
                out.append("%")
                out.append(hexUpper(byte >> 4))
                out.append(hexUpper(byte & 0x0F))
            }
        }
        return out
    }

    /// Matches upstream `encodePath(value)` (`value.split("/").map(encodeURIComponent).join("/")`).
    public static func encodePath(_ value: String) -> String {
        value
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { encodeURIComponent(String($0)) }
            .joined(separator: "/")
    }

    /// Matches upstream `appendQuery(params, key, value)` including OpenAPI `deepObject` encoding
    /// (e.g. `location[directory]=/repo`), arrays, `null`, and primitives.
    public static func appendQuery(
        items: inout [(String, String)],
        key: String,
        value: JSONValue?
    ) {
        guard let value else { return }
        switch value {
        case .null:
            items.append((key, "null"))
        case .bool(let b):
            items.append((key, b ? "true" : "false"))
        case .int(let i):
            items.append((key, String(i)))
        case .double(let d):
            if d.isFinite && d.rounded(.towardZero) == d && abs(d) < Double(Int64.max) {
                items.append((key, String(Int64(d))))
            } else {
                items.append((key, String(d)))
            }
        case .string(let s):
            items.append((key, s))
        case .array(let arr):
            for item in arr {
                appendQuery(items: &items, key: key, value: item)
            }
        case .object(let obj):
            for child in obj.keys.sorted() {
                if let childVal = obj[child] {
                    appendQuery(items: &items, key: "\(key)[\(child)]", value: childVal)
                }
            }
        }
    }

    /// Encodes query pairs in `application/x-www-form-urlencoded` form matching WHATWG `URLSearchParams`.
    public static func encodeFormQuery(_ items: [(String, String)]) -> String {
        items
            .map { "\(encodeFormComponent($0.0))=\(encodeFormComponent($0.1))" }
            .joined(separator: "&")
    }

    private static func encodeFormComponent(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.utf8.count)
        for byte in value.utf8 {
            if byte == 0x20 {
                out.append("+")
            } else if isFormUnreserved(byte) {
                out.append(Character(UnicodeScalar(byte)))
            } else {
                out.append("%")
                out.append(hexUpper(byte >> 4))
                out.append(hexUpper(byte & 0x0F))
            }
        }
        return out
    }

    private static func decodeFormComponent(_ value: String) -> String {
        let bytes = Array(value.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x2B { // '+'
                out.append(0x20)
                i += 1
            } else if b == 0x25, i + 2 < bytes.count,
                      let hi = hexNibble(bytes[i + 1]),
                      let lo = hexNibble(bytes[i + 2]) {
                out.append((hi << 4) | lo)
                i += 3
            } else {
                out.append(b)
                i += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func splitOnce(_ text: String, separator: Character) -> (String, String?) {
        guard let idx = text.firstIndex(of: separator) else {
            return (text, nil)
        }
        return (String(text[..<idx]), String(text[text.index(after: idx)...]))
    }

    private static func isURIComponentUnreserved(_ b: UInt8) -> Bool {
        (b >= 0x41 && b <= 0x5A) // A-Z
            || (b >= 0x61 && b <= 0x7A) // a-z
            || (b >= 0x30 && b <= 0x39) // 0-9
            || b == 0x2D || b == 0x5F || b == 0x2E // - _ .
            || b == 0x21 || b == 0x7E || b == 0x2A // ! ~ *
            || b == 0x27 || b == 0x28 || b == 0x29 // ' ( )
    }

    private static func isFormUnreserved(_ b: UInt8) -> Bool {
        (b >= 0x41 && b <= 0x5A)
            || (b >= 0x61 && b <= 0x7A)
            || (b >= 0x30 && b <= 0x39)
            || b == 0x2A || b == 0x2D || b == 0x2E || b == 0x5F // * - . _
    }

    private static func hexUpper(_ nibble: UInt8) -> Character {
        let table: [Character] = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "A", "B", "C", "D", "E", "F"]
        return table[Int(nibble & 0x0F)]
    }

    private static func hexNibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: byte - 0x30
        case 0x41...0x46: byte - 0x37
        case 0x61...0x66: byte - 0x57
        default: nil
        }
    }
}

// MARK: - HTTP Header & Content-Type Helpers

public enum ClientHTTPHeaders {
    public static func value(in headers: [String: String], for name: String) -> String? {
        if let exact = headers[name] { return exact }
        let target = name.lowercased()
        for (k, v) in headers where k.lowercased() == target {
            return v
        }
        return nil
    }

    public static func merge(_ layers: [String: String]?...) -> [String: String] {
        var result: [String: String] = [:]
        var canonicalKeyByLower: [String: String] = [:]
        for layer in layers {
            guard let layer else { continue }
            for (k, v) in layer {
                let lower = k.lowercased()
                if let existing = canonicalKeyByLower[lower], existing != k {
                    result.removeValue(forKey: existing)
                }
                canonicalKeyByLower[lower] = k
                result[k] = v
            }
        }
        return result
    }

    public static func isContentType(_ headers: [String: String], expected: String) -> Bool {
        guard let raw = value(in: headers, for: "content-type") else { return false }
        let mediaType = raw.split(separator: ";", maxSplits: 1).first.map(String.init) ?? raw
        return mediaType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == expected.lowercased()
    }

    public static func isJSONContentType(_ headers: [String: String]) -> Bool {
        if isContentType(headers, expected: "application/json") { return true }
        guard let raw = value(in: headers, for: "content-type") else { return false }
        let mediaType = raw.split(separator: ";", maxSplits: 1).first.map(String.init) ?? raw
        return mediaType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().contains("+json")
    }

    public static func basicAuthorization(username: String, password: String) -> String {
        "Basic " + base64Encode("\(username):\(password)")
    }
}

// MARK: - Incremental Server-Sent Events (SSE) Parser

/// Incremental SSE frame parser matching `packages/client/src/promise/generated/client.ts`.
public struct ClientSSEParser: Sendable {
    public static let maxSseEventBytes: Int = 16 * 1024 * 1024

    private var buffer: String = ""
    private var utf8Carry: [UInt8] = []

    public init() {}

    /// Feeds a chunk of bytes (or flushes EOF when `isFinal == true`) and returns complete `data:` payloads.
    public mutating func feed(_ chunk: [UInt8], isFinal: Bool = false) throws(ClientError) -> [String] {
        if !chunk.isEmpty {
            utf8Carry.append(contentsOf: chunk)
        }
        let decoded = decodeAvailableUTF8(flush: isFinal)
        if !decoded.isEmpty {
            buffer.append(decoded)
        }
        if buffer.utf8.count > Self.maxSseEventBytes {
            throw ClientError(reason: .sseEventTooLarge)
        }

        let trailingCR = !isFinal && buffer.hasSuffix("\r")
        if trailingCR {
            buffer.removeLast()
        }
        buffer = buffer.replacing("\r\n", with: "\n").replacing("\r", with: "\n")
        if trailingCR {
            buffer.append("\r")
        }
        if isFinal && !buffer.isEmpty {
            buffer.append("\n\n")
        }

        var events: [String] = []
        while let range = buffer.range(of: "\n\n") {
            let block = String(buffer[..<range.lowerBound])
            buffer = String(buffer[range.upperBound...])
            let dataLines = block.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line -> String? in
                guard line.hasPrefix("data:") else { return nil }
                let rest = line.dropFirst(5)
                var start = rest.startIndex
                while start < rest.endIndex && (rest[start].isWhitespace || rest[start] == "\u{FEFF}") {
                    start = rest.index(after: start)
                }
                return String(rest[start...])
            }
            let data = dataLines.joined(separator: "\n")
            if !data.isEmpty {
                events.append(data)
            }
        }
        return events
    }

    private mutating func decodeAvailableUTF8(flush: Bool) -> String {
        guard !utf8Carry.isEmpty else { return "" }
        if flush {
            let text = String(decoding: utf8Carry, as: UTF8.self)
            utf8Carry.removeAll(keepingCapacity: false)
            return text
        }
        // Hold back any incomplete trailing multi-byte UTF-8 sequence across chunk boundaries.
        var validEnd = utf8Carry.count
        let checkLimit = min(4, utf8Carry.count)
        for back in 1...checkLimit {
            let idx = utf8Carry.count - back
            let b = utf8Carry[idx]
            if (b & 0x80) == 0 {
                // ASCII byte; everything up to and including it is complete.
                validEnd = utf8Carry.count
                break
            } else if (b & 0xC0) == 0xC0 {
                // Leading byte of a multi-byte sequence.
                let expectedLen: Int
                if (b & 0xE0) == 0xC0 { expectedLen = 2 }
                else if (b & 0xF0) == 0xE0 { expectedLen = 3 }
                else if (b & 0xF8) == 0xF0 { expectedLen = 4 }
                else { expectedLen = 1 }
                if back < expectedLen {
                    validEnd = idx
                } else {
                    validEnd = utf8Carry.count
                }
                break
            }
        }
        guard validEnd > 0 else { return "" }
        let slice = Array(utf8Carry[..<validEnd])
        utf8Carry.removeFirst(validEnd)
        return String(decoding: slice, as: UTF8.self)
    }
}

// MARK: - Declared API Error Envelope Decoding

/// Fallback error for any declared server error body whose `_tag` is not in the static `ProtocolErrorEnvelope` union.
public struct DeclaredAPIError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
    public let tag: String?
    public let message: String
    public let body: JSONValue

    public init(tag: String?, message: String, body: JSONValue) {
        self.tag = tag
        self.message = message
        self.body = body
    }

    public var description: String {
        if let tag { return "\(tag): \(message)" }
        return message
    }
}

public enum ClientDeclaredErrorDecoder {
    /// Decodes a declared HTTP error response body into `OpenCodeProtocol.ProtocolErrorEnvelope`,
    /// `InstructionEntrySchema.ValueTooLargeError`, or `DeclaredAPIError`.
    public static func decode(bytes: [UInt8]) throws(ClientError) -> any Error & Sendable {
        guard !bytes.isEmpty else {
            throw ClientError(reason: .malformedResponse, detail: "Empty error body")
        }
        if let envelope = try? ClientCodec.decode(ProtocolErrorEnvelope.self, from: bytes) {
            return envelope
        }
        if let tooLarge = try? ClientCodec.decode(InstructionEntrySchema.ValueTooLargeError.self, from: bytes) {
            return tooLarge
        }
        let json: JSONValue
        do {
            json = try ClientCodec.decode(JSONValue.self, from: bytes)
        } catch {
            throw ClientError(reason: .malformedResponse, detail: String(describing: error))
        }
        var tag: String?
        var message = ""
        if case .object(let obj) = json {
            if case .string(let t) = obj["_tag"] {
                tag = t
            }
            if case .string(let m) = obj["message"] {
                message = m
            } else if case .object(let dataObj) = obj["data"], case .string(let dm) = dataObj["message"] {
                message = dm
            }
        }
        return DeclaredAPIError(tag: tag, message: message, body: json)
    }
}

// MARK: - Portable WebSocket Abstraction

public enum ClientWebSocketMessage: Equatable, Sendable {
    case text(String)
    case binary([UInt8])
    case closed(code: Int?)
}

/// Portable WebSocket abstraction decoupled from OS/URLSession/Browser WebSocket implementations.
public protocol ClientWebSocket: Sendable {
    var isOpen: Bool { get }
    var messages: AsyncStream<ClientWebSocketMessage> { get }
    func send(text: String) async throws
    func send(binary: [UInt8]) async throws
    func close(code: Int) async
}

public protocol ClientWebSocketFactory: Sendable {
    func connect(url: String, headers: [String: String]) async throws -> any ClientWebSocket
}

/// Simple `204 No Content` / void response sentinel for Swift generic API operations.
public struct ClientEmptyResponse: Equatable, Hashable, Sendable, Codable {
    public init() {}
}
