#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(CRT)
import CRT
#endif

import OpenCodePlatform
import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeUtil

/// Generic JSON value for NDJSON differential parity dispatch.
enum JSONValue: Equatable, Sendable, Codable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int64.self) {
            self = .int(i)
        } else if let d = try? container.decode(Double.self) {
            self = .double(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let arr = try? container.decode([JSONValue].self) {
            self = .array(arr)
        } else if let obj = try? container.decode([String: JSONValue].self) {
            self = .object(obj)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let b): try container.encode(b)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .string(let s): try container.encode(s)
        case .array(let arr): try container.encode(arr)
        case .object(let obj): try container.encode(obj)
        }
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    var intValue: Int? {
        switch self {
        case .int(let i): return Int(i)
        case .double(let d): return Int(d)
        default: return nil
        }
    }

    var int64Value: Int64? {
        switch self {
        case .int(let i): return i
        case .double(let d): return Int64(d)
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default: return nil
        }
    }

    var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    var byteArrayValue: [UInt8]? {
        guard case .array(let arr) = self else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(arr.count)
        for item in arr {
            guard let n = item.intValue, n >= 0, n <= 255 else { return nil }
            out.append(UInt8(n))
        }
        return out
    }
}

struct ParityRequest: Decodable {
    let id: String
    let fn: String
    let args: [JSONValue]
}

struct ParityResponse: Encodable {
    let id: String
    let ok: Bool
    let value: JSONValue?
    let error: String?
}

enum DispatchError: Error, CustomStringConvertible {
    case unknownFunction(String)
    case invalidArguments(String)

    var description: String {
        switch self {
        case .unknownFunction(let name): "Unknown function: \(name)"
        case .invalidArguments(let msg): "Invalid arguments: \(msg)"
        }
    }
}

func requireString(_ args: [JSONValue], _ idx: Int) throws -> String {
    guard idx < args.count, let s = args[idx].stringValue else {
        throw DispatchError.invalidArguments("Expected string at arg \(idx)")
    }
    return s
}

func optionalString(_ args: [JSONValue], _ idx: Int) -> String? {
    guard idx < args.count else { return nil }
    if case .null = args[idx] { return nil }
    return args[idx].stringValue
}

func requireBool(_ args: [JSONValue], _ idx: Int) throws -> Bool {
    guard idx < args.count, let b = args[idx].boolValue else {
        throw DispatchError.invalidArguments("Expected bool at arg \(idx)")
    }
    return b
}

func requireInt(_ args: [JSONValue], _ idx: Int) throws -> Int {
    guard idx < args.count, let n = args[idx].intValue else {
        throw DispatchError.invalidArguments("Expected int at arg \(idx)")
    }
    return n
}

func requireDouble(_ args: [JSONValue], _ idx: Int) throws -> Double {
    guard idx < args.count, let d = args[idx].doubleValue else {
        throw DispatchError.invalidArguments("Expected number at arg \(idx)")
    }
    return d
}

func requireBytes(_ args: [JSONValue], _ idx: Int) throws -> [UInt8] {
    guard idx < args.count, let bytes = args[idx].byteArrayValue else {
        throw DispatchError.invalidArguments("Expected byte array at arg \(idx)")
    }
    return bytes
}

func dispatch(_ req: ParityRequest) throws -> JSONValue {
    let args = req.args
    switch req.fn {
    // MARK: base64.ts
    case "util/src/base64.ts#bytesToBase64":
        return .string(bytesToBase64(try requireBytes(args, 0)))

    case "util/src/base64.ts#base64ToBytes":
        let bytes = try base64ToBytes(try requireString(args, 0))
        return .array(bytes.map { .int(Int64($0)) })

    // MARK: binary.ts
    case "util/src/binary.ts#Binary.search":
        guard let arr = args.first?.arrayValue else {
            throw DispatchError.invalidArguments("Expected string array at arg 0")
        }
        let items = try arr.map { v -> String in
            guard let s = v.stringValue else { throw DispatchError.invalidArguments("Expected strings in array") }
            return s
        }
        let target = try requireString(args, 1)
        let res = Binary.search(items, id: target) { $0 }
        return .object(["found": .bool(res.found), "index": .int(Int64(res.index))])

    case "util/src/binary.ts#Binary.insert":
        guard let arr = args.first?.arrayValue else {
            throw DispatchError.invalidArguments("Expected string array at arg 0")
        }
        let items = try arr.map { v -> String in
            guard let s = v.stringValue else { throw DispatchError.invalidArguments("Expected strings in array") }
            return s
        }
        let item = try requireString(args, 1)
        let updated = Binary.insert(items, item: item) { $0 }
        return .array(updated.map { .string($0) })

    // MARK: bom.ts
    case "util/src/bom.ts#split":
        let res = Bom.split(try requireString(args, 0))
        return .object(["bom": .bool(res.bom), "text": .string(res.text)])

    case "util/src/bom.ts#join":
        return .string(Bom.join(try requireString(args, 0), bom: try requireBool(args, 1)))

    case "util/src/bom.ts#has":
        return .bool(Bom.has(try requireBytes(args, 0)))

    case "util/src/bom.ts#decodeBytes":
        let res = Bom.decodeBytes(try requireBytes(args, 0))
        return .object(["bom": .bool(res.bom), "text": .string(res.text)])

    case "util/src/bom.ts#syncBytes":
        let res = Bom.syncBytes(try requireBytes(args, 0), bom: try requireBool(args, 1))
        return .object([
            "text": .string(res.text),
            "bytes": res.bytes.map { .array($0.map { .int(Int64($0)) }) } ?? .null,
        ])

    // MARK: duration.ts
    case "util/src/duration.ts#duration":
        return .string(duration(try requireDouble(args, 0)))

    // MARK: encode.ts
    case "util/src/encode.ts#base64Encode":
        return .string(base64Encode(try requireString(args, 0)))

    case "util/src/encode.ts#base64Decode":
        return .string(try base64Decode(try requireString(args, 0)))

    case "util/src/encode.ts#checksum":
        return checksum(try requireString(args, 0)).map { .string($0) } ?? .null

    case "util/src/encode.ts#sampledChecksum":
        let input = try requireString(args, 0)
        let limit = args.count > 1 ? (args[1].intValue ?? 500_000) : 500_000
        return sampledChecksum(input, limit: limit).map { .string($0) } ?? .null

    // MARK: hash.ts
    case "util/src/hash.ts#Hash.fast":
        return .string(Hash.fast(try requireString(args, 0)))

    case "util/src/hash.ts#Hash.sha256":
        return .string(Hash.sha256(try requireString(args, 0)))

    // MARK: path.ts
    case "util/src/path.ts#getFilename":
        return .string(getFilename(optionalString(args, 0)))

    case "util/src/path.ts#getDirectory":
        return .string(getDirectory(optionalString(args, 0)))

    case "util/src/path.ts#getFilenameTruncated":
        let maxLength = args.count > 1 ? (args[1].intValue ?? 20) : 20
        return .string(getFilenameTruncated(optionalString(args, 0), maxLength: maxLength))

    case "util/src/path.ts#truncateMiddle":
        let maxLength = args.count > 1 ? (args[1].intValue ?? 20) : 20
        return .string(truncateMiddle(try requireString(args, 0), maxLength: maxLength))

    case "util/src/path.ts#comparablePath":
        return .string(comparablePath(try requireString(args, 0)))

    case "util/src/path.ts#containsDirectory":
        return .bool(containsDirectory(try requireString(args, 0), try requireString(args, 1)))

    case "util/src/path.ts#sameDirectory":
        return .bool(sameDirectory(try requireString(args, 0), try requireString(args, 1)))

    case "util/src/path.ts#encodeFilePath":
        return .string(encodeFilePath(try requireString(args, 0)))

    case "util/src/path.ts#isLineRangeHash":
        return .bool(isLineRangeHash(try requireString(args, 0)))

    case "util/src/path.ts#parsePathLineSuffix":
        let parsed = parsePathLineSuffix(try requireString(args, 0))
        let sel: JSONValue = parsed.selection.map {
            .object(["start": .int(Int64($0.start)), "end": .int(Int64($0.end))])
        } ?? .null
        return .object(["path": .string(parsed.path), "selection": sel])

    // MARK: session-mention.ts
    case "util/src/session-mention.ts#sessionMentions":
        let matches = sessionMentions(try requireString(args, 0))
        return .array(matches.map {
            .object([
                "id": .string($0.id),
                "text": .string($0.text),
                "start": .int(Int64($0.start)),
                "end": .int(Int64($0.end)),
            ])
        })

    case "util/src/session-mention.ts#parseSessionMention":
        if let parsed = parseSessionMention(try requireString(args, 0)) {
            return .object(["id": .string(parsed.id)])
        }
        return .null

    case "util/src/session-mention.ts#serializeSessionMention":
        guard let obj = args.first?.objectValue, let id = obj["id"]?.stringValue else {
            throw DispatchError.invalidArguments("Expected { id } object")
        }
        return .string(serializeSessionMention(SessionMention(id: id)))

    // MARK: session-title-fallback.ts
    case "util/src/session-title-fallback.ts#withTimestampedFallback":
        guard let obj = args.first?.objectValue,
              let timeObj = obj["time"]?.objectValue,
              let created = timeObj["created"]?.int64Value else {
            throw DispatchError.invalidArguments("Expected Info object with time.created")
        }
        let info = SessionTitleFallback.Info(
            title: obj["title"]?.stringValue,
            parentID: obj["parentID"]?.stringValue,
            time: .init(created: created)
        )
        return .string(SessionTitleFallback.withTimestampedFallback(info))

    case "util/src/session-title-fallback.ts#displayLabel":
        guard let obj = args.first?.objectValue else {
            throw DispatchError.invalidArguments("Expected object with title/parentID")
        }
        return .string(
            SessionTitleFallback.displayLabel(
                title: obj["title"]?.stringValue,
                parentID: obj["parentID"]?.stringValue
            )
        )

    case "util/src/session-title-fallback.ts#isFallbackTitle":
        return .bool(SessionTitleFallback.isFallbackTitle(optionalString(args, 0)))

    case "util/src/session-title-fallback.ts#isExactRootFallback":
        guard let obj = args.first?.objectValue,
              let timeObj = obj["time"]?.objectValue,
              let created = timeObj["created"]?.int64Value else {
            throw DispatchError.invalidArguments("Expected object with title and time.created")
        }
        return .bool(
            SessionTitleFallback.isExactRootFallback(
                title: obj["title"]?.stringValue,
                created: created
            )
        )

    // MARK: text-boundary.ts
    case "util/src/text-boundary.ts#head":
        return .string(TextBoundary.head(try requireString(args, 0), limit: try requireInt(args, 1)))

    case "util/src/text-boundary.ts#tail":
        return .string(TextBoundary.tail(try requireString(args, 0), limit: try requireInt(args, 1)))

    case "util/src/text-boundary.ts#utf8Tail":
        return .string(TextBoundary.utf8Tail(try requireBytes(args, 0), limit: try requireInt(args, 1)))

    // MARK: uuid.ts
    case "util/src/uuid.ts#uuid":
        return .string(uuid())

    // MARK: schema/identifier.ts
    case "schema/src/identifier.ts#create":
        let desc = try requireBool(args, 0)
        let ts = args.count > 1 ? (args[1].int64Value ?? 0) : 0
        return .string(Identifier.create(descending: desc, timestamp: ts))

    case "schema/src/identifier.ts#ascending":
        return .string(Identifier.ascending())

    case "schema/src/identifier.ts#descending":
        return .string(Identifier.descending())

    default:
        throw DispatchError.unknownFunction(req.fn)
    }
}

@main
struct OpenCodeParityRunnerMain {
    static func main() {
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        while let line = readLine(strippingNewline: true) {
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            guard let data = line.data(using: .utf8) else { continue }
            do {
                let req = try decoder.decode(ParityRequest.self, from: data)
                do {
                    let result = try dispatch(req)
                    let resp = ParityResponse(id: req.id, ok: true, value: result, error: nil)
                    let out = try encoder.encode(resp)
                    print(String(decoding: out, as: UTF8.self))
                } catch {
                    let resp = ParityResponse(id: req.id, ok: false, value: nil, error: String(describing: error))
                    let out = try encoder.encode(resp)
                    print(String(decoding: out, as: UTF8.self))
                }
            } catch {
                let resp = ParityResponse(id: "decode-error", ok: false, value: nil, error: String(describing: error))
                if let out = try? encoder.encode(resp) {
                    print(String(decoding: out, as: UTF8.self))
                }
            }
            #if canImport(Darwin) || canImport(Glibc) || canImport(Musl) || canImport(CRT)
            fflush(stdout)
            #endif
        }
    }
}
