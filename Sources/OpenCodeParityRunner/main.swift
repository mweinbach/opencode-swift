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

import OpenCodeAI
import OpenCodeCLIKit
import OpenCodeCore
import OpenCodePlatform
import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeServer
import OpenCodeTUI
import OpenCodeUtil
import Synchronization

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

func jsonNumber(_ d: Double) -> JSONValue {
    if d.isFinite && d.rounded(.towardZero) == d && abs(d) < 9_007_199_254_740_992.0 {
        return .int(Int64(d))
    }
    return .double(d)
}

func toSchemaJSON(_ value: JSONValue) -> OpenCodeSchema.JSONValue {
    switch value {
    case .null: return .null
    case .bool(let b): return .bool(b)
    case .int(let i): return .int(i)
    case .double(let d): return .double(d)
    case .string(let s): return .string(s)
    case .array(let arr): return .array(arr.map(toSchemaJSON))
    case .object(let obj): return .object(obj.mapValues(toSchemaJSON))
    }
}

func fromSchemaJSON(_ value: OpenCodeSchema.JSONValue) -> JSONValue {
    switch value {
    case .null: return .null
    case .bool(let b): return .bool(b)
    case .int(let i): return .int(i)
    case .double(let d): return jsonNumber(d)
    case .string(let s): return .string(s)
    case .array(let arr): return .array(arr.map(fromSchemaJSON))
    case .object(let obj): return .object(obj.mapValues(fromSchemaJSON))
    }
}

func toPureJSON(_ value: JSONValue) -> PureJSONValue {
    switch value {
    case .null: return .null
    case .bool(let b): return .bool(b)
    case .int(let i): return .number(Double(i))
    case .double(let d): return .number(d)
    case .string(let s): return .string(s)
    case .array(let arr): return .array(arr.map(toPureJSON))
    case .object(let obj):
        return .object(obj.keys.sorted().map { ($0, toPureJSON(obj[$0]!)) })
    }
}

func fromPureJSON(_ value: PureJSONValue) -> JSONValue {
    switch value {
    case .null: return .null
    case .bool(let b): return .bool(b)
    case .number(let d): return jsonNumber(d)
    case .string(let s): return .string(s)
    case .array(let arr): return .array(arr.map(fromPureJSON))
    case .object(let entries):
        var dict: [String: JSONValue] = [:]
        for (k, v) in entries {
            dict[k] = fromPureJSON(v)
        }
        return .object(dict)
    }
}

func decodeJSONCFormattingOptions(_ obj: [String: JSONValue]?) -> JSONC.FormattingOptions? {
    guard let obj else { return nil }
    return JSONC.FormattingOptions(
        tabSize: obj["tabSize"]?.intValue,
        insertSpaces: obj["insertSpaces"]?.boolValue,
        eol: obj["eol"]?.stringValue,
        insertFinalNewline: obj["insertFinalNewline"]?.boolValue,
        keepLines: obj["keepLines"]?.boolValue
    )
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

func decodeStringMap(_ value: JSONValue) throws -> [String: String] {
    guard let obj = value.objectValue else {
        throw DispatchError.invalidArguments("Expected string dictionary")
    }
    var out: [String: String] = [:]
    for (k, v) in obj {
        if let s = v.stringValue {
            out[k] = s
        }
    }
    return out
}

func decodeCorsOptions(_ args: [JSONValue], _ idx: Int) -> CorsOptions? {
    guard idx < args.count, let obj = args[idx].objectValue, let arr = obj["cors"]?.arrayValue else {
        return nil
    }
    return CorsOptions(cors: arr.compactMap(\.stringValue))
}

func decodePlatformOS(_ raw: String) -> PlatformOS {
    switch raw {
    case "darwin": return .macOS
    case "win32": return .windows
    case "linux": return .linux
    default: return .unknown
    }
}

func decodeSessionTurnMessage(_ value: JSONValue) throws -> SessionTurn.Message {
    guard let obj = value.objectValue,
          let id = obj["id"]?.stringValue,
          let type = obj["type"]?.stringValue,
          let timeObj = obj["time"]?.objectValue,
          let created = timeObj["created"]?.doubleValue else {
        throw DispatchError.invalidArguments("Invalid SessionTurn.Message")
    }
    let time = SessionTurn.Time(
        created: created,
        firstToken: timeObj["firstToken"]?.doubleValue,
        streamed: timeObj["streamed"]?.doubleValue,
        completed: timeObj["completed"]?.doubleValue
    )
    let tokens: SessionTurn.Tokens?
    if let tokObj = obj["tokens"]?.objectValue,
       let output = tokObj["output"]?.doubleValue,
       let reasoning = tokObj["reasoning"]?.doubleValue {
        tokens = SessionTurn.Tokens(output: output, reasoning: reasoning)
    } else {
        tokens = nil
    }
    return SessionTurn.Message(id: id, type: type, time: time, tokens: tokens)
}

func decodeSessionTurnOptions(_ args: [JSONValue], _ idx: Int) -> SessionTurn.Options {
    guard idx < args.count, let obj = args[idx].objectValue else {
        return SessionTurn.Options()
    }
    return SessionTurn.Options(
        index: obj["index"]?.intValue,
        legacy: obj["legacy"]?.boolValue
    )
}

func decodeUpdateChunks(_ value: JSONValue) throws -> [Patch.UpdateFileChunk] {
    guard let arr = value.arrayValue else {
        throw DispatchError.invalidArguments("Expected chunks array")
    }
    return try arr.map { item in
        guard let obj = item.objectValue,
              let oldArr = obj["oldLines"]?.arrayValue,
              let newArr = obj["newLines"]?.arrayValue else {
            throw DispatchError.invalidArguments("Invalid UpdateFileChunk")
        }
        let oldLines = try oldArr.map { v -> String in
            guard let s = v.stringValue else { throw DispatchError.invalidArguments("Expected string in oldLines") }
            return s
        }
        let newLines = try newArr.map { v -> String in
            guard let s = v.stringValue else { throw DispatchError.invalidArguments("Expected string in newLines") }
            return s
        }
        return Patch.UpdateFileChunk(
            oldLines: oldLines,
            newLines: newLines,
            changeContext: obj["changeContext"]?.stringValue,
            endOfFile: obj["endOfFile"]?.boolValue
        )
    }
}

func dispatch(_ req: ParityRequest) throws -> JSONValue {
    let args = req.args
    switch req.fn {
    // MARK: activity-calendar.ts
    case "util/src/activity-calendar.ts#activityCalendar":
        guard let obj = args.first?.objectValue,
              let actArr = obj["activity"]?.arrayValue,
              let from = obj["from"]?.int64Value,
              let to = obj["to"]?.int64Value,
              let maxWeeks = obj["maxWeeks"]?.doubleValue else {
            throw DispatchError.invalidArguments("Expected ActivityCalendarInput object")
        }
        let activity = try actArr.map { item -> ActivityDayInput in
            guard let d = item.objectValue,
                  let date = d["date"]?.stringValue,
                  let steps = d["steps"]?.intValue else {
                throw DispatchError.invalidArguments("Invalid ActivityDayInput")
            }
            return ActivityDayInput(date: date, steps: steps)
        }
        let res = activityCalendar(ActivityCalendarInput(activity: activity, from: from, to: to, maxWeeks: maxWeeks))
        return .object([
            "clipped": .bool(res.clipped),
            "months": .array(res.months.map {
                .object([
                    "label": .string($0.label),
                    "span": .int(Int64($0.span)),
                    "week": .int(Int64($0.week)),
                ])
            }),
            "weeks": .array(res.weeks.map { week in
                .array(week.map { cell in
                    .object([
                        "date": .string(cell.date),
                        "level": .int(Int64(cell.level)),
                        "steps": .int(Int64(cell.steps)),
                    ])
                })
            }),
        ])

    // MARK: artifact.ts
    case "util/src/artifact.ts#artifactMime":
        return artifactMime(try requireString(args, 0)).map { .string($0) } ?? .null

    case "util/src/artifact.ts#artifactKind":
        return .string(artifactKind(try requireString(args, 0)).rawValue)

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

    // MARK: execute-output.ts
    case "util/src/execute-output.ts#formatExecuteOutput":
        let res = formatExecuteOutput(try requireString(args, 0))
        return .object([
            "json": res.json.map { .string($0) } ?? .null,
            "rest": res.rest.map { .string($0) } ?? .null,
            "text": .string(res.text),
        ])

    // MARK: fs-util.ts
    case "util/src/fs-util.ts#FSUtil.windowsPath":
        return .string(FSPathUtil.windowsPath(try requireString(args, 0)))

    case "util/src/fs-util.ts#FSUtil.contains":
        return .bool(FSPathUtil.contains(parent: try requireString(args, 0), child: try requireString(args, 1)))

    case "util/src/fs-util.ts#FSUtil.overlaps":
        return .bool(FSPathUtil.overlaps(try requireString(args, 0), try requireString(args, 1)))

    // MARK: hash.ts
    case "util/src/hash.ts#Hash.fast":
        return .string(Hash.fast(try requireString(args, 0)))

    case "util/src/hash.ts#Hash.sha256":
        return .string(Hash.sha256(try requireString(args, 0)))

    // MARK: npm.ts
    case "util/src/npm.ts#sanitize":
        return .string(NpmSpec.sanitize(try requireString(args, 0)))

    // MARK: patch.ts
    case "util/src/patch.ts#parse":
        switch Patch.parse(try requireString(args, 0)) {
        case .success(let hunks):
            return .object([
                "ok": .bool(true),
                "hunks": .array(hunks.map { hunk in
                    switch hunk {
                    case let .add(path, contents):
                        return .object(["type": .string("add"), "path": .string(path), "contents": .string(contents)])
                    case let .delete(path):
                        return .object(["type": .string("delete"), "path": .string(path)])
                    case let .update(path, movePath, chunks):
                        return .object([
                            "type": .string("update"),
                            "path": .string(path),
                            "movePath": movePath.map { .string($0) } ?? .null,
                            "chunks": .array(chunks.map { c in
                                .object([
                                    "oldLines": .array(c.oldLines.map { .string($0) }),
                                    "newLines": .array(c.newLines.map { .string($0) }),
                                    "changeContext": c.changeContext.map { .string($0) } ?? .null,
                                    "endOfFile": c.endOfFile.map { .bool($0) } ?? .null,
                                ])
                            }),
                        ])
                    }
                }),
            ])
        case .failure(let err):
            let tag: String
            switch err {
            case .boundary: tag = "Patch.BoundaryError"
            case .invalidHunk: tag = "Patch.InvalidHunkError"
            }
            return .object([
                "ok": .bool(false),
                "tag": .string(tag),
                "message": .string(err.message),
            ])
        }

    case "util/src/patch.ts#derive":
        let path = try requireString(args, 0)
        guard args.count >= 3 else {
            throw DispatchError.invalidArguments("Expected 3 arguments for Patch.derive")
        }
        let chunks = try decodeUpdateChunks(args[1])
        let original = try requireString(args, 2)
        let res = try Patch.derive(path: path, chunks: chunks, original: original)
        return .object(["content": .string(res.content), "bom": .bool(res.bom)])

    case "util/src/patch.ts#joinBom":
        return .string(Patch.joinBom(try requireString(args, 0), bom: try requireBool(args, 1)))

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

    // MARK: qr.ts
    case "util/src/qr.ts#encode":
        let matrix = try QR.encode(try requireString(args, 0))
        return .array(matrix.map { row in .array(row.map { .bool($0) }) })

    case "util/src/qr.ts#renderSVG":
        let text = try requireString(args, 0)
        let opts = args.count > 1 ? args[1].objectValue : nil
        let border = opts?["border"]?.intValue ?? 1
        let blackColor = opts?["blackColor"]?.stringValue ?? "black"
        let whiteColor = opts?["whiteColor"]?.stringValue ?? "white"
        return .string(try QR.renderSVG(text, border: border, blackColor: blackColor, whiteColor: whiteColor))

    case "util/src/qr.ts#renderUnicodeCompact":
        let text = try requireString(args, 0)
        let opts = args.count > 1 ? args[1].objectValue : nil
        let border = opts?["border"]?.intValue ?? 1
        return .string(try QR.renderUnicodeCompact(text, border: border))

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

    // MARK: session-turn.ts
    case "util/src/session-turn.ts#duration":
        guard args.count >= 2, let arr = args[0].arrayValue else {
            throw DispatchError.invalidArguments("Expected messages array and message")
        }
        let messages = try arr.map(decodeSessionTurnMessage)
        let message = try decodeSessionTurnMessage(args[1])
        let opts = decodeSessionTurnOptions(args, 2)
        return jsonNumber(SessionTurn.duration(messages, message: message, options: opts))

    case "util/src/session-turn.ts#tokensPerSecond":
        guard args.count >= 2, let arr = args[0].arrayValue else {
            throw DispatchError.invalidArguments("Expected messages array and message")
        }
        let messages = try arr.map(decodeSessionTurnMessage)
        let message = try decodeSessionTurnMessage(args[1])
        let opts = decodeSessionTurnOptions(args, 2)
        return SessionTurn.tokensPerSecond(messages, message: message, options: opts).map(jsonNumber) ?? .null

    case "util/src/session-turn.ts#legacy":
        guard let arr = args.first?.arrayValue else {
            throw DispatchError.invalidArguments("Expected messages array")
        }
        let messages = try arr.map(decodeSessionTurnMessage)
        return .bool(SessionTurn.legacy(messages))

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

    // MARK: - packages/theme & packages/tui color
    case "theme/src/tui/color.ts#oklchToHex":
        guard let obj = args.first?.objectValue,
              let l = obj["l"]?.doubleValue,
              let c = obj["c"]?.doubleValue,
              let h = obj["h"]?.doubleValue else {
            throw DispatchError.invalidArguments("Expected { l, c, h } object")
        }
        return .string(OpenCodeTUI.oklchToHex(OklchColor(l: l, c: c, h: h)))

    case "theme/src/tui/color.ts#rgbToOklch":
        let res = OpenCodeTUI.rgbToOklch(try requireDouble(args, 0), try requireDouble(args, 1), try requireDouble(args, 2))
        return .object([
            "l": jsonNumber(res.l),
            "c": jsonNumber(res.c),
            "h": jsonNumber(res.h),
        ])

    case "theme/src/tui/expand.ts#mergeTheme":
        let merged = OpenCodeTUI.mergeTheme(args.map(toSchemaJSON))
        return fromSchemaJSON(.object(merged))

    case "theme/src/tui/v1-migrate.ts#byte":
        return .string(OpenCodeTUI.byte(try requireInt(args, 0)))

    case "tui/src/theme/color.ts#ansiToRgba":
        return .string(OpenCodeTUI.hex(TUIThemeBridge.ansiToRgba(try requireInt(args, 0))))

    case "tui/src/theme/color.ts#tint":
        let base = TUIThemeBridge.ansiToRgba(try requireInt(args, 0))
        let overlay = TUIThemeBridge.ansiToRgba(try requireInt(args, 1))
        let alpha = try requireDouble(args, 2)
        return .string(OpenCodeTUI.hex(TUIThemeBridge.tint(base, overlay: overlay, alpha: alpha)))

    // MARK: - packages/patchmark
    case "patchmark/src/entities.ts#decodeCodePoint":
        return .string(OpenCodeTUI.decodeCodePoint(try requireInt(args, 0)))

    case "patchmark/src/entities.ts#decodeEntity":
        return .string(OpenCodeTUI.decodeEntity(try requireString(args, 0)))

    case "patchmark/src/entities.ts#unescapeString":
        return .string(OpenCodeTUI.unescapeString(try requireString(args, 0)))

    case "patchmark/src/entities.ts#normalizeURI":
        return .string(OpenCodeTUI.normalizeURI(try requireString(args, 0)))

    case "patchmark/src/heal.ts#computeTailHeal":
        let heal = OpenCodeTUI.computeTailHeal(try requireString(args, 0))
        return .object([
            "strip": .int(Int64(heal.strip)),
            "append": .string(heal.append),
        ])

    case "patchmark/src/heal.ts#healStreamingInline":
        return .string(OpenCodeTUI.healStreamingInline(try requireString(args, 0)))

    case "patchmark/src/html.ts#escapeHtml":
        return .string(OpenCodeTUI.escapeHtml(try requireString(args, 0)))

    case "patchmark/src/html.ts#filterDisallowedRawHtml":
        return .string(OpenCodeTUI.filterDisallowedRawHtml(try requireString(args, 0)))

    case "patchmark/src/stream.ts#splitPendingMarker":
        let split = OpenCodeTUI.splitPendingMarker(try requireString(args, 0))
        return .object([
            "visible": .string(split.visible),
            "held": .string(split.held),
        ])

    case "patchmark/src/html.ts#renderBlocksToHtml":
        let md = try requireString(args, 0)
        let optsObj = args.count > 1 ? args[1].objectValue : nil
        let gfm = optsObj?["gfm"]?.boolValue ?? true
        let math = optsObj?["math"]?.boolValue ?? false
        let stream = PatchmarkStream(StreamOptions(gfm: gfm, math: math))
        stream.update(md, streaming: false)
        return .string(OpenCodeTUI.renderBlocksToHtml(stream.getBlocks(), options: HtmlRenderOptions(gfm: gfm, math: math)))

    // MARK: - packages/ai
    case "ai/src/protocols/utils/mistral-tool-id.ts#valid":
        return .bool(AIProtocolUtils.MistralToolID.valid(try requireString(args, 0)))

    case "ai/src/protocols/utils/mistral-tool-id.ts#hash":
        return .string(AIProtocolUtils.MistralToolID.hash(try requireString(args, 0)))

    case "ai/src/protocols/utils/claude-model.ts#claudeVersion":
        if let v = AIProtocolUtils.ClaudeModel.claudeVersion(try requireString(args, 0)) {
            return .object([
                "family": .string(v.family),
                "major": .int(Int64(v.major)),
                "minor": .int(Int64(v.minor)),
            ])
        }
        return .null

    case "ai/src/protocols/utils/claude-model.ts#supportsThinkingBlockBinding":
        guard let obj = args.first?.objectValue, let id = obj["id"]?.stringValue else {
            throw DispatchError.invalidArguments("Expected { id, supportsThinkingBlockBinding? }")
        }
        let compat = obj["supportsThinkingBlockBinding"]?.boolValue.map {
            AIProtocolUtils.ModelCompatibility(supportsThinkingBlockBinding: $0)
        }
        let desc = AIProtocolUtils.ModelDescriptor(id: id, provider: "anthropic", compatibility: compat)
        return .bool(AIProtocolUtils.ClaudeModel.supportsThinkingBlockBinding(desc))

    case "ai/src/protocols/utils/image-sizing.ts#tier":
        return AIProtocolUtils.ImageSizing.tier(try requireString(args, 0)).map(jsonNumber) ?? .null

    case "ai/src/protocols/utils/image-sizing.ts#fit":
        guard args.count >= 2,
              let shapeObj = args[0].objectValue,
              let limitsObj = args[1].objectValue,
              let multiple = limitsObj["multiple"]?.intValue else {
            throw DispatchError.invalidArguments("Expected (shape, limits)")
        }
        let shape = AIProtocolUtils.ImageSizing.Shape(
            aspect: shapeObj["aspect"]?.stringValue,
            resolution: shapeObj["resolution"]?.stringValue
        )
        let limits = AIProtocolUtils.ImageSizing.Limits(
            multiple: multiple,
            minEdge: limitsObj["minEdge"]?.intValue,
            maxEdge: limitsObj["maxEdge"]?.intValue,
            minPixels: limitsObj["minPixels"]?.intValue,
            maxPixels: limitsObj["maxPixels"]?.intValue,
            maxRatio: limitsObj["maxRatio"]?.doubleValue
        )
        let size = AIProtocolUtils.ImageSizing.fit(shape, limits: limits)
        return .object(["width": .int(Int64(size.width)), "height": .int(Int64(size.height))])

    case "ai/src/protocols/utils/image-sizing.ts#nearest":
        guard args.count >= 2,
              let shapeObj = args[0].objectValue,
              let sizesArr = args[1].arrayValue else {
            throw DispatchError.invalidArguments("Expected (shape, sizes)")
        }
        let shape = AIProtocolUtils.ImageSizing.Shape(
            aspect: shapeObj["aspect"]?.stringValue,
            resolution: shapeObj["resolution"]?.stringValue
        )
        let sizes = try sizesArr.map { item -> AIProtocolUtils.ImageSizing.Size in
            guard let o = item.objectValue,
                  let w = o["width"]?.intValue,
                  let h = o["height"]?.intValue else {
                throw DispatchError.invalidArguments("Invalid Size object")
            }
            return AIProtocolUtils.ImageSizing.Size(width: w, height: h)
        }
        let best = AIProtocolUtils.ImageSizing.nearest(shape, sizes: sizes)
        return .object(["width": .int(Int64(best.width)), "height": .int(Int64(best.height))])

    case "ai/src/protocols/utils/gemini-json-schema.ts#normalize":
        guard let obj = args.first?.objectValue else {
            throw DispatchError.invalidArguments("Expected schema object")
        }
        let schemaDict = obj.mapValues(toSchemaJSON)
        let res = AIProtocolUtils.GeminiJsonSchema.normalize(schemaDict)
        return fromSchemaJSON(.object(res))

    case "ai/src/protocols/utils/cache.ts#openAIRequestTTL":
        let res = AIProtocolUtils.Cache.openAIRequestTTL(optionalString(args, 0))
        return fromSchemaJSON(.object(res))

    case "ai/src/protocols/utils/partial-json.ts#parseJSON":
        let raw = try requireString(args, 0)
        let parsed: OpenCodeSchema.JSONValue
        if args.count > 1, let allow = args[1].intValue {
            parsed = try AIProtocolUtils.PartialJSONParser.parseJSON(raw, allowPartial: allow)
        } else {
            parsed = try AIProtocolUtils.PartialJSONParser.parseJSON(raw)
        }
        return fromSchemaJSON(parsed)

    case "ai/src/utils/media-type.ts#detectMediaType":
        return AIUtils.detectMediaType(try requireBytes(args, 0)).map { .string($0) } ?? .null

    case "ai/src/utils/media-type.ts#fileMediaType":
        return AIUtils.fileMediaType(try requireBytes(args, 0), path: try requireString(args, 1)).map { .string($0) } ?? .null

    case "ai/src/utils/media-type.ts#mediaTypeExtension":
        return AIUtils.mediaTypeExtension(try requireString(args, 0)).map { .string($0) } ?? .null

    case "ai/src/utils/provider-codes.ts#awsErrorType":
        return .array(AIUtils.awsErrorType(optionalString(args, 0)).map { .string($0) })

    case "ai/src/utils/provider-codes.ts#providerCodes":
        guard let first = args.first else {
            throw DispatchError.invalidArguments("Expected argument for providerCodes")
        }
        return .array(AIUtils.providerCodes(toSchemaJSON(first)).map { .string($0) })

    case "ai/src/route/endpoint.ts#trimBaseUrl":
        return .string(AIEndpoint.trimBaseUrl(try requireString(args, 0)))

    case "ai/src/protocols/shared.ts#wrapSystemUpdate":
        guard let arr = args.first?.arrayValue else {
            throw DispatchError.invalidArguments("Expected string array")
        }
        let parts = try arr.map { v -> AIProtocolUtils.TextPart in
            guard let s = v.stringValue else { throw DispatchError.invalidArguments("Expected strings") }
            return AIProtocolUtils.TextPart(text: s)
        }
        return .string(AIProtocolUtils.ProviderShared.wrapSystemUpdate(parts))

    case "ai/src/protocols/shared.ts#fitThinkingBudget":
        let budget = try requireInt(args, 0)
        let maxTokens: Int? = args.count > 1 ? args[1].intValue : nil
        let minimum: Int = args.count > 2 ? (args[2].intValue ?? 1) : 1
        return .int(Int64(AIProtocolUtils.ProviderShared.fitThinkingBudget(budget, maxTokens: maxTokens, minimum: minimum)))

    case "ai/src/protocols/shared.ts#promptCacheKey":
        guard let obj = args.first?.objectValue else {
            throw DispatchError.invalidArguments("Expected promptCacheKey config object")
        }
        let cacheSetting: AIProtocolUtils.CacheSetting
        switch obj["cache"]?.stringValue {
        case "none": cacheSetting = .none
        default: cacheSetting = .auto
        }
        let caps = obj["capabilityPromptCacheKey"]?.boolValue.map {
            AIProtocolUtils.ModelCapabilities(promptCacheKey: $0)
        }
        let req = AIProtocolUtils.LLMRequest(
            model: AIProtocolUtils.ModelDescriptor(id: "gpt-5", provider: "openai", capabilities: caps),
            cache: cacheSetting,
            promptCacheKey: obj["promptCacheKey"]?.stringValue
        )
        return AIProtocolUtils.ProviderShared.promptCacheKey(req).map { .string($0) } ?? .null

    case "ai/src/provider-error.ts#isContextOverflow":
        return .bool(AIErrorClassifier.isContextOverflow(try requireString(args, 0)))

    case "ai/src/protocols/shared.ts#flattenToolRequest":
        guard let obj = args.first?.objectValue,
              let rawTools = obj["tools"]?.arrayValue,
              let rawMsgs = obj["messages"]?.arrayValue else {
            throw DispatchError.invalidArguments("Expected { tools, messages } for flattenToolRequest")
        }
        func decodeToolEntry(_ val: JSONValue) throws -> AIProtocolUtils.ToolEntry {
            guard let o = val.objectValue, let type = o["type"]?.stringValue, let name = o["name"]?.stringValue else {
                throw DispatchError.invalidArguments("Invalid tool entry")
            }
            if type == "namespace" {
                let children = try (o["tools"]?.arrayValue ?? []).map(decodeToolEntry)
                return .namespace(name: name, description: nil, tools: children)
            }
            return .tool(AIProtocolUtils.ToolDefinition(name: name, description: "", inputSchema: [:]))
        }
        let tools = try rawTools.map(decodeToolEntry)
        let messages: [AIProtocolUtils.Message] = try rawMsgs.map { msgVal in
            guard let mo = msgVal.objectValue,
                  let roleStr = mo["role"]?.stringValue,
                  let partsArr = mo["parts"]?.arrayValue else {
                throw DispatchError.invalidArguments("Invalid message")
            }
            let role: AIProtocolUtils.MessageRole = roleStr == "tool" ? .tool : .assistant
            let parts: [AIProtocolUtils.ContentPart] = try partsArr.map { pv in
                guard let po = pv.objectValue,
                      let pt = po["type"]?.stringValue,
                      let pid = po["id"]?.stringValue,
                      let pname = po["name"]?.stringValue else {
                    throw DispatchError.invalidArguments("Invalid message part")
                }
                let ns = po["namespace"]?.stringValue
                if pt == "tool-result" {
                    return .toolResult(AIProtocolUtils.ToolResultPart(id: pid, name: pname, namespace: ns, result: .text("ok")))
                }
                return .toolCall(AIProtocolUtils.ToolCallPart(id: pid, name: pname, namespace: ns, input: .object([:])))
            }
            return AIProtocolUtils.Message(role: role, content: parts)
        }
        let req = AIProtocolUtils.LLMRequest(
            model: AIProtocolUtils.ModelDescriptor(id: "gpt-5", provider: "openai"),
            messages: messages,
            tools: tools
        )
        let flattened = AIProtocolUtils.ProviderShared.flattenToolRequest(req)
        return .object([
            "tools": .array(flattened.tools.map { .string($0.name) }),
            "messages": .array(flattened.request.messages.map { m in
                .object([
                    "role": .string(m.role.rawValue),
                    "parts": .array(m.content.compactMap { part -> JSONValue? in
                        switch part {
                        case .toolCall(let c):
                            return .object([
                                "type": .string("tool-call"),
                                "id": .string(c.id),
                                "name": .string(c.name),
                                "namespace": c.namespace.map { .string($0) } ?? .null,
                            ])
                        case .toolResult(let r):
                            return .object([
                                "type": .string("tool-result"),
                                "id": .string(r.id),
                                "name": .string(r.name),
                                "namespace": r.namespace.map { .string($0) } ?? .null,
                            ])
                        default:
                            return nil
                        }
                    }),
                ])
            }),
        ])

    // MARK: - packages/core
    case "core/src/util/wildcard.ts#match":
        let input = try requireString(args, 0)
        let pattern = try requireString(args, 1)
        let ignoreCase = args.count > 2 ? (args[2].boolValue ?? false) : false
        return .bool(CoreSubsystems.Util.Wildcard.match(input, pattern: pattern, ignoreCase: ignoreCase))

    case "core/src/util/canonical-json.ts#canonicalJson":
        guard let first = args.first else {
            throw DispatchError.invalidArguments("Expected JSON value")
        }
        return .string(CoreSubsystems.Util.canonicalJson(toSchemaJSON(first)))

    case "core/src/util/token.ts#estimate":
        return .int(Int64(CoreSubsystems.Util.Token.estimate(try requireString(args, 0))))

    case "core/src/mime.ts#detect":
        return .string(CoreFilesystem.Mime.detect(try requireBytes(args, 0)))

    case "core/src/mime.ts#detectMedia":
        return CoreFilesystem.Mime.detectMedia(try requireBytes(args, 0)).map { .string($0) } ?? .null

    case "core/src/mime.ts#isTextual":
        return .bool(CoreFilesystem.Mime.isTextual(try requireString(args, 0)))

    case "core/src/config/markdown.ts#sanitize":
        return .string(CoreConfigMarkdown.sanitize(try requireString(args, 0)))

    case "core/src/managed-policy.ts#decision":
        guard args.count >= 3, let arr = args[0].arrayValue else {
            throw DispatchError.invalidArguments("Expected (policies, action, resource)")
        }
        let policies = try arr.map { item -> ConfigPolicySchema.Info in
            guard let o = item.objectValue,
                  let actRaw = o["action"]?.stringValue,
                  let act = ConfigPolicySchema.Action(rawValue: actRaw),
                  let res = o["resource"]?.stringValue,
                  let effRaw = o["effect"]?.stringValue,
                  let eff = ConfigPolicySchema.Effect(rawValue: effRaw) else {
                throw DispatchError.invalidArguments("Invalid ConfigPolicySchema.Info")
            }
            return ConfigPolicySchema.Info(action: act, resource: res, effect: eff)
        }
        guard let action = ConfigPolicySchema.Action(rawValue: try requireString(args, 1)) else {
            throw DispatchError.invalidArguments("Invalid ConfigPolicySchema.Action")
        }
        let resource = try requireString(args, 2)
        return .string(CoreManagedPolicy.decision(policies, action: action, resource: resource).rawValue)

    case "core/src/flag.ts#resolve":
        guard let obj = args.first?.objectValue,
              let entriesArr = obj["entries"]?.arrayValue,
              let channel = obj["channel"]?.stringValue else {
            throw DispatchError.invalidArguments("Expected { entries, channel, overrides? }")
        }
        let entries: [CoreConfigEntry] = entriesArr.map { entryVal in
            let expObj = entryVal.objectValue?["experimental"]?.objectValue
            let exp = expObj.map { e in
                ConfigExperimentalSchema.Info(
                    allFlags: e["all_flags"]?.boolValue,
                    todo: e["todo"]?.boolValue,
                    mediaBlob: e["media_blob"]?.boolValue,
                    artifacts: e["artifacts"]?.boolValue,
                    videoGenerate: e["video_generate"]?.boolValue.map { .enabled($0) },
                    consoleWatches: e["console_watches"]?.boolValue,
                    recommendedApi: e["recommended_api"]?.boolValue,
                    fullCodemode: e["full_codemode"]?.boolValue,
                    machines: e["machines"]?.boolValue,
                    homeMemory: e["home_memory"]?.boolValue,
                    projectOverlay: e["project_overlay"]?.boolValue,
                    sqliteFts: e["sqlite_fts"]?.boolValue
                )
            }
            return .document(ConfigSchema.Document(info: ConfigSchema.Info(experimental: exp)))
        }
        let resolved = CoreFlag.resolve(CoreFlag.ResolveInput(
            entries: entries,
            channel: channel,
            overrides: obj["overrides"]?.stringValue
        ))
        var out: [String: JSONValue] = [:]
        for (key, state) in resolved {
            out[key.rawValue] = .object([
                "enabled": .bool(state.enabled),
                "source": .string(state.source.rawValue),
            ])
        }
        return .object(out)

    case "core/src/permission.ts#evaluate":
        guard args.count >= 3, let setsArr = args[2].arrayValue else {
            throw DispatchError.invalidArguments("Expected (action, resource, rulesets)")
        }
        let action = try requireString(args, 0)
        let resource = try requireString(args, 1)
        let rulesets: [PermissionSchema.Ruleset] = try setsArr.map { rsVal in
            guard let rs = rsVal.arrayValue else {
                throw DispatchError.invalidArguments("Expected ruleset array")
            }
            return try rs.map { ruleVal in
                guard let o = ruleVal.objectValue,
                      let rAct = o["action"]?.stringValue,
                      let rRes = o["resource"]?.stringValue,
                      let rEffRaw = o["effect"]?.stringValue,
                      let rEff = PermissionSchema.Effect(rawValue: rEffRaw) else {
                    throw DispatchError.invalidArguments("Invalid PermissionSchema.Rule")
                }
                return PermissionSchema.Rule(action: rAct, resource: rRes, effect: rEff)
            }
        }
        let result = CorePermission.evaluate(action: action, resource: resource, rulesets: rulesets)
        return .object([
            "action": .string(result.action),
            "resource": .string(result.resource),
            "effect": .string(result.effect.rawValue),
        ])

    // MARK: - packages/server
    case "server/src/range.ts#parse":
        let parsed = ByteRange.parse(optionalString(args, 0), size: try requireInt(args, 1))
        switch parsed {
        case nil: return .null
        case .unsatisfiable: return .string("unsatisfiable")
        case .range(let slice):
            return .object(["start": .int(Int64(slice.start)), "end": .int(Int64(slice.end))])
        }

    case "server/src/content-headers.ts#disposition":
        return .string(ContentHeaders.disposition(try requireString(args, 0)))

    case "server/src/content-headers.ts#download":
        guard let obj = args.first?.objectValue, let mime = obj["mime"]?.stringValue else {
            throw DispatchError.invalidArguments("Expected { path?, mime }")
        }
        let headers = ContentHeaders.download(path: obj["path"]?.stringValue, mime: mime)
        return .object(headers.mapValues { .string($0) })

    case "server/src/cors.ts#isAllowedCorsOrigin":
        return .bool(isAllowedCorsOrigin(optionalString(args, 0), opts: decodeCorsOptions(args, 1)))

    case "server/src/cors.ts#isAllowedRequestOrigin":
        return .bool(isAllowedRequestOrigin(optionalString(args, 0), host: optionalString(args, 1), opts: decodeCorsOptions(args, 2)))

    case "server/src/media-uri.ts#wantsMediaRefs":
        let headers = try decodeStringMap(args[0])
        return .bool(wantsMediaRefs(ServerHTTPRequest(method: "GET", url: "http://localhost/", headers: headers)))

    case "server/src/request-site.ts#rejected":
        guard let obj = args.first?.objectValue,
              let url = obj["url"]?.stringValue,
              let headersVal = obj["headers"] else {
            throw DispatchError.invalidArguments("Expected { url, headers }")
        }
        let headers = try decodeStringMap(headersVal)
        let req = ServerHTTPRequest(method: "GET", url: url, headers: headers)
        return .bool(RequestSite.rejected(req, options: decodeCorsOptions(args, 1)))

    // MARK: - packages/schema & packages/protocol
    case "schema/src/token-usage.ts#total":
        guard let obj = args.first?.objectValue,
              let input = obj["input"]?.doubleValue,
              let output = obj["output"]?.doubleValue,
              let reasoning = obj["reasoning"]?.doubleValue,
              let cacheObj = obj["cache"]?.objectValue,
              let read = cacheObj["read"]?.doubleValue,
              let write = cacheObj["write"]?.doubleValue else {
            throw DispatchError.invalidArguments("Expected TokenUsage.Info")
        }
        let total = TokenUsageSchema.total(TokenUsageSchema.Info(
            input: input,
            output: output,
            reasoning: reasoning,
            cache: TokenUsageSchema.Cache(read: read, write: write)
        ))
        return jsonNumber(total)

    case "schema/src/event.ts#versionedType":
        return .string(EventSchema.versionedType(try requireString(args, 0), version: try requireInt(args, 1)))

    case "schema/src/event-manifest.ts#isServer":
        return .bool(EventManifestSchema.isServer(type: try requireString(args, 0)))

    case "protocol/src/groups/event.ts#isOpenCodeEvent":
        return .bool(isOpenCodeEvent(type: try requireString(args, 0)))

    case "protocol/src/groups/server.ts#isPairingConnectURL":
        return .bool(isPairingConnectURL(try requireString(args, 0)))

    case "protocol/src/groups/pty.ts#hasPtyConnectTicketURL":
        return .bool(hasPtyConnectTicketURL(try requireString(args, 0)))

    case "protocol/src/groups/persistent-pty.ts#hasPersistentPtyConnectTicketURL":
        return .bool(hasPersistentPtyConnectTicketURL(try requireString(args, 0)))

    case "protocol/src/groups/mcp.ts#hasMcpClientTicketURL":
        return .bool(hasMcpClientTicketURL(try requireString(args, 0)))

    case "protocol/src/groups/machine.ts#isWebSocketUpgrade":
        guard let obj = args.first?.objectValue,
              let method = obj["method"]?.stringValue,
              let headersVal = obj["headers"] else {
            throw DispatchError.invalidArguments("Expected { method, headers }")
        }
        return .bool(isWebSocketUpgrade(method: method, headers: try decodeStringMap(headersVal)))

    case "protocol/src/groups/machine.ts#isMachineLinkUpgrade":
        guard let obj = args.first?.objectValue,
              let method = obj["method"]?.stringValue,
              let url = obj["url"]?.stringValue,
              let headersVal = obj["headers"] else {
            throw DispatchError.invalidArguments("Expected { method, url, headers }")
        }
        return .bool(isMachineLinkUpgrade(method: method, url: url, headers: try decodeStringMap(headersVal)))

    // MARK: - packages/cli
    case "cli/src/database-path.ts#databasePath":
        let data = try requireString(args, 0)
        let envMap = args.count > 1 ? (try decodeStringMap(args[1])) : [:]
        return .string(CLIUtil.databasePath(data, channel: "local", environment: DictionaryEnvironment(variables: envMap)))

    case "cli/src/services/updater-action.ts#parseReleaseVersion":
        if let v = CLIServices.UpdaterAction.parseReleaseVersion(try requireString(args, 0)) {
            return .object([
                "major": .string(v.major),
                "core": .string(v.core),
                "prerelease": .array(v.prerelease.map { .string($0) }),
            ])
        }
        return .null

    case "cli/src/services/updater-action.ts#action":
        let cur = try requireString(args, 0)
        let lat = try requireString(args, 1)
        guard let policy = CLIServices.UpdaterAction.Policy(rawValue: try requireString(args, 2)) else {
            throw DispatchError.invalidArguments("Invalid UpdaterAction.Policy")
        }
        return .string(CLIServices.UpdaterAction.action(current: cur, latest: lat, policy: policy).rawValue)

    case "cli/src/services/service-config.ts#filename":
        return .string(CLIServices.ServiceConfig.filename(channel: try requireString(args, 0)))

    case "cli/src/services/service-config.ts#defaultPort":
        let ch = try requireString(args, 0)
        let plat = decodePlatformOS(try requireString(args, 1))
        return .int(Int64(CLIServices.ServiceConfig.defaultPort(channel: ch, platform: plat)))

    case "cli/src/services/service-config.ts#legacyFilename":
        return CLIServices.ServiceConfig.legacyFilename(channel: try requireString(args, 0)).map { .string($0) } ?? .null

    case "cli/src/services/service-config.ts#versionBelongsToChannel":
        return .bool(CLIServices.ServiceConfig.versionBelongsToChannel(
            optionalString(args, 0),
            channel: try requireString(args, 1),
            installedVersion: try requireString(args, 2)
        ))

        case "cli/src/node/target.ts#nodeTarget":
        let t = try CLIUtil.Node.nodeTarget(platform: try requireString(args, 0), arch: try requireString(args, 1))
        return .object([
            "platform": .string(t.platform),
            "arch": .string(t.arch),
            "nodePtyPackage": .string(t.nodePtyPackage),
            "nodePtyEntryAsset": .string(t.nodePtyEntryAsset),
            "parcelWatcherPackage": .string(t.parcelWatcherPackage),
            "parcelWatcherAsset": .string(t.parcelWatcherAsset),
            "fffPackage": .string(t.fffPackage),
            "fffAsset": .string(t.fffAsset),
            "fffFfiPackage": .string(t.fffFfiPackage),
            "fffFfiAsset": .string(t.fffFfiAsset),
            "opencodePtyAsset": .string(t.opencodePtyAsset),
        ])

    case "cli/src/services/service-urls.ts#parseServerURL":
        return .string(try CLIServiceURLs.parseServerURL(try requireString(args, 0)))

    case "cli/src/services/service-urls.ts#isLoopback":
        return .bool(CLIServiceURLs.isLoopback(try requireString(args, 0)))

    // MARK: - packages/latex
    case "latex/src/render.ts#renderLatexToString":
        let latexSrc = try requireString(args, 0)
        var latexOpts = RenderLatexOptions()
        if args.count > 1, let o = args[1].objectValue {
            if let dm = o["displayMode"]?.boolValue { latexOpts.displayMode = dm }
            if let st = o["strict"]?.boolValue { latexOpts.strict = st }
        }
        return .string(try renderLatexToString(latexSrc, options: latexOpts))

    case "latex/src/parser.ts#expandLatexMacros":
        let macroSrc = try requireString(args, 0)
        let macros = try decodeStringMap(args[1])
        return .string(try expandLatexMacros(macroSrc, options: ParseOptions(macros: macros)))

    // MARK: - packages/merman
    case "merman/src/detect.ts#detectMermaidDiagram":
        return Merman.detectMermaidDiagram(try requireString(args, 0)).map { .string($0.rawValue) } ?? .null

    case "merman/src/flowchart/render.ts#renderFlowchartDiagram":
        return .string(try Merman.renderFlowchartDiagram(try requireString(args, 0)))

    case "merman/src/sequence/diagram.ts#renderSequenceDiagram":
        return .string(try Merman.renderSequenceDiagram(try requireString(args, 0)))

    case "merman/src/state/diagram.ts#renderStateDiagram":
        return .string(try Merman.renderStateDiagram(try requireString(args, 0)))

    case "merman/src/timeline/diagram.ts#renderTimelineDiagram":
        return .string(try Merman.renderTimelineDiagram(try requireString(args, 0)))

    case "merman/src/gitgraph/diagram.ts#renderGitGraphDiagram":
        return .string(try Merman.renderGitGraphDiagram(try requireString(args, 0)))

    case "merman/src/gantt/diagram.ts#renderGanttDiagram":
        return .string(try Merman.renderGanttDiagram(try requireString(args, 0)))

    // MARK: - packages/core/src/shell/scan.ts
    case "core/src/shell/scan.ts#scan":
        let cmd = try requireString(args, 0)
        let dialect: CoreShell.Scan.Dialect
        if let dStr = optionalString(args, 1), let d = CoreShell.Scan.Dialect(rawValue: dStr) {
            dialect = d
        } else {
            dialect = .posix
        }
        switch CoreShell.Scan.scan(cmd, dialect: dialect) {
        case .opaque(let reason):
            return .object(["kind": .string("opaque"), "reason": .string(reason.rawValue)])
        case .scanned(let commands):
            return .object([
                "kind": .string("scanned"),
                "commands": .array(commands.map { c in
                    .object([
                        "resource": .string(c.resource),
                        "words": .array(c.words.map { .string($0) }),
                        "rawWords": .array(c.rawWords.map { .string($0) }),
                    ])
                }),
            ])
        }

    case "core/src/shell/scan.ts#scanPowerShell":
        switch CoreShell.Scan.scanPowerShell(try requireString(args, 0)) {
        case .opaque(let reason):
            return .object(["kind": .string("opaque"), "reason": .string(reason.rawValue)])
        case .scanned(let commands):
            return .object([
                "kind": .string("scanned"),
                "commands": .array(commands.map { c in
                    .object([
                        "resource": .string(c.resource),
                        "words": .array(c.words.map { .string($0) }),
                        "rawWords": .array(c.rawWords.map { .string($0) }),
                    ])
                }),
            ])
        }

    // MARK: - jsonc-parser@3.3.1
    case "jsonc-parser#modifyAndApply":
        let text = try requireString(args, 0)
        guard args.count >= 3,
              let pathArr = args[1].arrayValue,
              let valueSpec = args[2].objectValue
        else {
            throw DispatchError.invalidArguments("Expected (text, path, valueSpec, options?) for jsonc-parser#modifyAndApply")
        }
        let path: [JSONC.PathSegment] = try pathArr.map { seg in
            if let s = seg.stringValue { return .key(s) }
            if let i = seg.intValue { return .index(i) }
            throw DispatchError.invalidArguments("Path segment must be string or int")
        }
        let value: PureJSONValue?
        if valueSpec["remove"]?.boolValue == true {
            value = nil
        } else if let rawJson = valueSpec["valueJson"]?.stringValue {
            guard let parsed = PureJSON.parse(rawJson) else {
                throw DispatchError.invalidArguments("Invalid valueJson: \(rawJson)")
            }
            value = parsed
        } else if let v = valueSpec["value"] {
            value = toPureJSON(v)
        } else {
            value = nil
        }
        var modOpts = JSONC.ModificationOptions()
        if args.count > 3, let rawOpts = args[3].objectValue {
            modOpts.formattingOptions = decodeJSONCFormattingOptions(rawOpts["formattingOptions"]?.objectValue)
            if let isIns = rawOpts["isArrayInsertion"]?.boolValue {
                modOpts.isArrayInsertion = isIns
            }
            if let idx = rawOpts["insertionIndex"]?.intValue {
                modOpts.getInsertionIndex = { _ in idx }
            }
        }
        let edits = try JSONC.modify(text, path: path, value: value, options: modOpts)
        let applied = try JSONC.applyEdits(text, edits: edits)
        return .object([
            "edits": .array(edits.map {
                .object([
                    "offset": .int(Int64($0.offset)),
                    "length": .int(Int64($0.length)),
                    "content": .string($0.content),
                ])
            }),
            "result": .string(applied),
        ])

    case "jsonc-parser#parse":
        let text = try requireString(args, 0)
        var parseOpts = JSONC.ParseOptions()
        if args.count > 1, let rawOpts = args[1].objectValue {
            if let v = rawOpts["allowTrailingComma"]?.boolValue { parseOpts.allowTrailingComma = v }
            if let v = rawOpts["disallowComments"]?.boolValue { parseOpts.disallowComments = v }
            if let v = rawOpts["allowEmptyContent"]?.boolValue { parseOpts.allowEmptyContent = v }
        }
        var errors: [JSONC.ParseError] = []
        let parsed = JSONC.parse(text, errors: &errors, options: parseOpts)
        return .object([
            "value": parsed.map(fromPureJSON) ?? .null,
            "errors": .array(errors.map {
                .object([
                    "error": .int(Int64($0.error.rawValue)),
                    "offset": .int(Int64($0.offset)),
                    "length": .int(Int64($0.length)),
                ])
            }),
        ])

    case "jsonc-parser#format":
        let text = try requireString(args, 0)
        let range: JSONC.Range?
        if args.count > 1, let rObj = args[1].objectValue,
           let offset = rObj["offset"]?.intValue,
           let length = rObj["length"]?.intValue
        {
            range = JSONC.Range(offset: offset, length: length)
        } else {
            range = nil
        }
        let fmtOpts = (args.count > 2 ? decodeJSONCFormattingOptions(args[2].objectValue) : nil) ?? JSONC.FormattingOptions()
        let edits = JSONC.format(text, range: range, options: fmtOpts)
        let applied = try JSONC.applyEdits(text, edits: edits)
        return .object([
            "edits": .array(edits.map {
                .object([
                    "offset": .int(Int64($0.offset)),
                    "length": .int(Int64($0.length)),
                    "content": .string($0.content),
                ])
            }),
            "result": .string(applied),
        ])

    default:
        throw DispatchError.unknownFunction(req.fn)
    }
}

// MARK: - psychoscript (Code Mode language) corpus

// Swift half of the psychoscript (Code Mode language) differential corpus, vector function
// `psychoscript/src/runtime.ts#execute` (`parity/vectors/psychoscript.json`).
//
// Mirrors `Tools/parity/psychoscript-oracle.ts`: the same fixed host globals, the same limits/translate options, and
// the same canonical outcome. A copy lives at `Tests/OpenCodeParityTests/PsychoscriptParity.swift` so the Bun-free
// golden snapshot test runs the corpus too; keep the two (and the oracle) in sync. (It stays inside main.swift because
// SwiftPM only treats a single-file executable target's `@main` as the entry point.)
enum PsychoscriptParity {
    static let executeFunction = "psychoscript/src/runtime.ts#execute"

    typealias Language = CodemodeLanguage

    final class CounterService: Sendable {
        private struct State: Sendable { var count = 0 }
        private let state = Mutex(State())
        func next() -> Int {
            state.withLock { s in
                s.count += 1
                return s.count
            }
        }
    }

    static let counterKey = Language.EffectServiceKey<CounterService>("Counter")

    struct Options: Sendable {
        var mode: String = "promise"
        var timeoutMs: Int?
        var maxOutputBytes: Int?
        var functions: Language.Translate.FunctionPolicy = .error
        var promises: Language.Translate.PromisePolicy = .error

        init(_ raw: OpenCodeSchema.JSONValue?) {
            guard case .object(let o)? = raw else { return }
            if case .string(let m)? = o["mode"] { mode = m }
            timeoutMs = Self.int(o["timeoutMs"])
            maxOutputBytes = Self.int(o["maxOutputBytes"])
            if case .object(let t)? = o["translate"] {
                if case .string(let f)? = t["functions"], let p = Language.Translate.FunctionPolicy(rawValue: f) { functions = p }
                if case .string(let p)? = t["promises"], let q = Language.Translate.PromisePolicy(rawValue: p) { promises = q }
            }
        }

        private static func int(_ v: OpenCodeSchema.JSONValue?) -> Int? {
            switch v {
            case .int(let i)?: return Int(i)
            case .double(let d)?: return Int(d)
            default: return nil
            }
        }
    }

    /// JS `Number(v)` for the primitive copies the corpus passes to host functions.
    private static func number(_ v: Language.Value?) -> Double {
        switch v {
        case .number(let d)?: return d
        case .bool(let b)?: return b ? 1 : 0
        case .null?: return 0
        case .string(let s)?:
            guard let wf = s.wellFormedString else { return .nan }
            return wf.isEmpty ? 0 : (Double(wf) ?? .nan)
        default: return .nan
        }
    }

    private static func showPrimitive(_ v: Language.Value?) -> String {
        switch v {
        case .string(let s)?: return s.toHostString()
        case .number(let d)?: return d == d.rounded() && abs(d) < 1e15 ? String(Int64(d)) : String(d)
        case .null?: return "null"
        case .bool(let b)?: return b ? "true" : "false"
        default: return "undefined"
        }
    }

    /// Promise-API host globals (mirrors `psychoscript-oracle.ts#promiseGlobals`).
    static func promiseGlobals() -> [String: Language.HostGlobalValue] {
        let double = Language.Host.fn({ args, _, _ in .number(number(args.first) * 2) }, options: .init(length: 1))
        let echo = Language.Host.fn({ args, _, _ in
            guard let first = args.first, !first.isUndefined else { return .null }
            return first
        }, options: .init(length: 1))
        let asyncDouble = Language.Host.fn({ args, _, _ in .number(number(args.first) * 2) }, options: .init(type: .async, length: 1))
        let lookup = Language.Host.fn({ args, _, _ in
            if case .string(let name)? = args.first, name == "a" || name == "b" { return .string("item:\(name)") }
            throw Language.Host.fail("NotFound", "No item \(showPrimitive(args.first))", suggestions: ["a", "b"])
        }, options: .init(length: 1))
        let add = Language.Host.fn({ args, _, _ in
            .number(number(args.first) + number(args.count > 1 ? args[1] : nil))
        }, options: .init(length: 1))
        let namedFn = Language.Host.fn({ args, _, _ in .number(Double(args.count)) }, options: .init(name: "original", length: 2))
        let declaredFn = Language.Host.fn({ args, _, _ in .number(number(args.first) + 1) }, options: .init(name: "customAdd", length: 1))
        let later = Language.Host.fnReturn({ args, _, builtins in
            let result = Language.Value.number(number(args.first) + 1)
            let p = Language.PromiseObj(proto: builtins.Promise)
            p.attachTask(Task { .fulfilled(result) })
            return .promise(p)
        }, options: .init(length: 1))
        let refuse = Language.Host.fnReturn({ _, _, builtins in
            let hf = Language.Host.fail("Refused", "no", suggestions: ["retry"])
            let p = Language.PromiseObj(proto: builtins.Promise)
            p.attachHostTask(Task { (.rejected(Language.materialize(builtins, hf)), hf) })
            return .promise(p)
        }, options: .init(length: 0))
        let boom = Language.Host.fn({ _, _, _ in
            throw Language.HostError("boom")
        }, options: .init(length: 0))
        let plainGreet = Language.Host.plainFn(name: "plainGreet", length: 1) { args, _ in
            .value(.string(Language.JSString("hi:\(showPrimitive(args.first))")))
        }
        let box = Language.Host.fn({ args, _, builtins in
            let label = showPrimitive(args.first)
            let obj = Language.Obj(proto: builtins.Object)
            Language.define(obj, "read", Language.Host.plainValue(builtins: builtins, name: "read", length: 0) { _, _ in
                .value(.string(Language.JSString("box:\(label)")))
            })
            Language.define(obj, "anon", Language.Host.plainValue(builtins: builtins, name: "", length: 2) { innerArgs, innerBuiltins in
                let a: Language.Value = (innerArgs.count > 0 && !innerArgs[0].isNullish) ? innerArgs[0] : .null
                let b: Language.Value = (innerArgs.count > 1 && !innerArgs[1].isNullish) ? innerArgs[1] : .null
                return .value(.object(Language.Arr(proto: innerBuiltins.Array, items: [a, b])))
            })
            return .object(obj)
        }, options: .init(type: .syncThenable, length: 1))
        return [
            "double": .fn(double),
            "echo": .fn(echo),
            "asyncDouble": .fn(asyncDouble),
            "lookup": .fn(lookup),
            "math2": .object(["add": .fn(add)]),
            "namedFn": .fn(namedFn),
            "declaredFn": .fn(declaredFn),
            "later": .fn(later),
            "refuse": .fn(refuse),
            "boom": .fn(boom),
            "plainGreet": .plainFn(plainGreet),
            "box": .fn(box),
        ]
    }

    /// Effect-API host globals (mirrors `psychoscript-oracle.ts#effectGlobals`).
    static func effectGlobals() -> [String: Language.HostGlobalValue] {
        @Sendable func readEffect(_ arg: Language.Value?) -> Language.EffectTask<Language.HostReturn> {
            let p = showPrimitive(arg)
            if p == "missing" {
                return .fail(Language.EffectHost.fail("NotFound", "no missing"))
            }
            if p == "die" {
                return .die(Language.HostError("plain-boom"))
            }
            return .service(counterKey) { counter in
                .value(.string(Language.JSString("\(p):\(counter.next())")))
            }
        }
        let double = Language.EffectHost.fn({ args, _, _ in .value(.number(number(args.first) * 2)) }, options: .init(length: 1))
        let echo = Language.EffectHost.fn({ args, _, _ in
            guard let first = args.first, !first.isUndefined else { return .value(.null) }
            return .value(first)
        }, options: .init(length: 1))
        let asyncDouble = Language.EffectHost.fn({ args, _, _ in
            Language.EffectTask.succeed(.number(number(args.first) * 2))
        }, options: .init(type: .async, length: 1))
        let lookup = Language.EffectHost.fn({ args, _, _ in
            if case .string(let name)? = args.first, name == "a" || name == "b" { return .value(.string("item:\(name)")) }
            throw Language.EffectHost.fail("NotFound", "No item \(showPrimitive(args.first))", suggestions: ["a", "b"])
        }, options: .init(length: 1))
        let add = Language.EffectHost.fn({ args, _, _ in
            .value(.number(number(args.first) + number(args.count > 1 ? args[1] : nil)))
        }, options: .init(length: 1))
        let effectNamed = Language.EffectHost.fn({ args, _, _ in
            Language.EffectTask.succeed(.number(Double(args.count)))
        }, options: .init(name: "original", length: 2))
        let effectDeclared = Language.EffectHost.fn({ _, _, _ in
            Language.EffectTask.succeed(.number(1))
        }, options: .init(name: "named", length: 1))
        let effectNext = Language.EffectHost.fn({ _, _, _ in
            Language.EffectTask.service(counterKey) { .number(Double($0.next())) }
        }, options: .init(type: .async, idempotent: true, length: 0))
        let effectFail = Language.EffectHost.fn({ _, _, _ in
            Language.EffectTask.fail(Language.EffectHost.fail("NotFound", "no such thing", suggestions: ["try another"]))
        }, options: .init(length: 0))
        let effectTypedFail = Language.EffectHost.fn({ _, _, _ in
            Language.EffectTask.fail(Language.HostError("tagged"))
        }, options: .init(length: 0))
        let effectDie = Language.EffectHost.fn({ _, _, _ in
            Language.EffectTask.die(Language.HostError("kaboom"))
        }, options: .init(length: 0))
        let effectThrown = Language.EffectHost.fn({ _, _, _ in
            Language.EffectTask.sync { throw Language.HostError("thrown") }
        }, options: .init(length: 0))
        let fileFn = Language.EffectHost.fn({ args, _, builtins in
            let p = args.first
            let obj = Language.Obj(proto: builtins.Object)
            Language.define(obj, "text", Language.Host.plainValue(builtins: builtins, name: "text", length: 0) { _, _ in
                .effect(readEffect(p))
            })
            Language.define(obj, "size", Language.Host.plainValue(builtins: builtins, name: "size", length: 0) { _, _ in
                .effect(.succeed(.value(.number(3))))
            })
            return .value(.object(obj))
        }, options: .init(type: .syncThenable, length: 1))
        let globFn = Language.EffectHost.fn({ args, _, builtins in
            let pattern = showPrimitive(args.first)
            let obj = Language.Obj(proto: builtins.Object)
            Language.define(obj, "scan", Language.Host.plainValue(builtins: builtins, name: "scan", length: 0) { _, innerBuiltins in
                .effect(.succeed(.value(.object(Language.Arr(proto: innerBuiltins.Array, items: [.string(Language.JSString(pattern))])))))
            })
            return .value(.object(obj))
        }, options: .init(constructible: true, length: 1))
        let plainRead = Language.Host.plainFn(name: "read", length: 1) { args, _ in
            .effect(readEffect(args.first))
        }
        return [
            "double": .fn(double),
            "echo": .fn(echo),
            "asyncDouble": .fn(asyncDouble),
            "lookup": .fn(lookup),
            "math2": .object(["add": .fn(add)]),
            "effectNamed": .fn(effectNamed),
            "effectDeclared": .fn(effectDeclared),
            "effectNext": .fn(effectNext),
            "effectFail": .fn(effectFail),
            "effectTypedFail": .fn(effectTypedFail),
            "effectDie": .fn(effectDie),
            "effectThrown": .fn(effectThrown),
            "fsBox": .object([
                "file": .fn(fileFn),
                "Glob": .fn(globFn),
                "read": .plainFn(plainRead),
            ]),
        ]
    }

    private static func diagnostic(_ d: Language.Diagnostic) -> OpenCodeSchema.JSONValue {
        var out: [String: OpenCodeSchema.JSONValue] = ["kind": .string(d.kind), "message": .string(d.message)]
        if let loc = d.location {
            out["location"] = .object(["line": .int(Int64(loc.line)), "column": .int(Int64(loc.column))])
        }
        if let s = d.suggestions, !s.isEmpty {
            out["suggestions"] = .array(s.map { .string($0) })
        }
        return .object(out)
    }

    private static func canonicalResult(_ result: Language.Result) -> OpenCodeSchema.JSONValue {
        switch result {
        case .success(let value, let warnings, let logs, let truncated, _):
            var out: [String: OpenCodeSchema.JSONValue] = [
                "ok": .bool(true),
                "value": value,
                "logs": .array((logs ?? []).map { .string($0) }),
                "warnings": .array((warnings ?? []).map(diagnostic)),
            ]
            if truncated == true { out["truncated"] = .bool(true) }
            return .object(out)
        case .failure(let error, let logs, let truncated, _):
            var out: [String: OpenCodeSchema.JSONValue] = [
                "ok": .bool(false),
                "error": diagnostic(error),
                "logs": .array((logs ?? []).map { .string($0) }),
            ]
            if truncated == true { out["truncated"] = .bool(true) }
            return .object(out)
        }
    }

    /// Runs `program` through `CodemodeLanguage.makeRuntime` (or `EffectRuntime.make` when `mode == "effect"`)
    /// and returns the canonical outcome.
    static func execute(_ program: String, options raw: OpenCodeSchema.JSONValue?) async throws -> OpenCodeSchema.JSONValue {
        let options = Options(raw)
        if options.mode == "effect" {
            let runtime = try Language.EffectRuntime.make(Language.RuntimeOptions(
                globals: { _ in effectGlobals() },
                limits: Language.Limits(timeoutMs: options.timeoutMs, maxOutputBytes: options.maxOutputBytes),
                translate: Language.Translate(functions: options.functions, promises: options.promises)
            ))
            let services = Language.EffectServices.empty.providing(counterKey, CounterService())
            let result = try await runtime.execute(program, nil).run(services: services)
            return canonicalResult(result)
        }
        let runtime = try Language.makeRuntime(Language.RuntimeOptions(
            globals: { _ in promiseGlobals() },
            limits: Language.Limits(timeoutMs: options.timeoutMs, maxOutputBytes: options.maxOutputBytes),
            translate: Language.Translate(functions: options.functions, promises: options.promises)
        ))
        let result = await runtime.execute(program, nil)
        return canonicalResult(result)
    }
}

/// Async-capable dispatch: psychoscript programs run on the async Code Mode runtime; everything else is synchronous.
func dispatchAsync(_ req: ParityRequest) async throws -> JSONValue {
    if req.fn == PsychoscriptParity.executeFunction {
        guard case .string(let program)? = req.args.first else {
            throw DispatchError.unknownFunction("\(req.fn): args[0] must be the program source")
        }
        let options = req.args.count > 1 ? toSchemaJSON(req.args[1]) : nil
        return fromSchemaJSON(try await PsychoscriptParity.execute(program, options: options))
    }
    return try dispatch(req)
}

@main
struct OpenCodeParityRunnerMain {
    static func main() async {
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        while let line = readLine(strippingNewline: true) {
            if line.allSatisfy(\.isWhitespace) { continue }
            let data = Data(line.utf8)
            do {
                let req = try decoder.decode(ParityRequest.self, from: data)
                do {
                    let result = try await dispatchAsync(req)
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
            fflush(nil)
            #endif
        }
    }
}
