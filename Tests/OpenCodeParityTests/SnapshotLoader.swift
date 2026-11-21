#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

enum SnapshotJSON: Equatable, Decodable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([SnapshotJSON])
    case object([String: SnapshotJSON])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let i = try? c.decode(Int64.self) { self = .int(i) }
        else if let d = try? c.decode(Double.self) { self = .double(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([SnapshotJSON].self) { self = .array(a) }
        else if let o = try? c.decode([String: SnapshotJSON].self) { self = .object(o) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON") }
    }

    var str: String? { if case .string(let s) = self { return s }; return nil }
    var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    var int: Int? {
        switch self {
        case .int(let i): return Int(i)
        case .double(let d): return Int(d)
        default: return nil
        }
    }
    var int64: Int64? {
        switch self {
        case .int(let i): return i
        case .double(let d): return Int64(d)
        default: return nil
        }
    }
    var dbl: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default: return nil
        }
    }
    var bytes: [UInt8]? {
        guard case .array(let a) = self else { return nil }
        return a.compactMap(\.int).map(UInt8.init)
    }
    var arr: [SnapshotJSON]? { if case .array(let a) = self { return a }; return nil }
    var obj: [String: SnapshotJSON]? { if case .object(let o) = self { return o }; return nil }

    /// Compares two snapshot values while permitting minor cross-platform `libm` ULP variance
    /// (`pow`/`cbrt`/`atan2`) on floating-point leaves.
    func matches(_ other: SnapshotJSON, floatTolerance: Double) -> Bool {
        switch (self, other) {
        case (.null, .null):
            return true
        case let (.bool(a), .bool(b)):
            return a == b
        case let (.int(a), .int(b)):
            return a == b
        case let (.string(a), .string(b)):
            return a == b
        case let (.double(a), .double(b)):
            if a == b { return true }
            let scale = max(1.0, max(abs(a), abs(b)))
            return abs(a - b) <= floatTolerance * scale
        case let (.array(a), .array(b)):
            guard a.count == b.count else { return false }
            return zip(a, b).allSatisfy { $0.matches($1, floatTolerance: floatTolerance) }
        case let (.object(a), .object(b)):
            guard a.count == b.count else { return false }
            for (k, v) in a {
                guard let bv = b[k], v.matches(bv, floatTolerance: floatTolerance) else { return false }
            }
            return true
        default:
            return false
        }
    }
}

struct SnapshotCase: Decodable {
    let fn: String
    let name: String
    let args: [SnapshotJSON]
    let compare: String
    let expectedOk: Bool
    let expectedValue: SnapshotJSON
}

struct SnapshotFile: Decodable {
    let upstreamCommit: String
    let vectorCount: Int
    let cases: [SnapshotCase]
}

enum SnapshotLoader {
    static func load(relativeTo filePath: String) throws -> SnapshotFile {
        let fixtureURL = URL(fileURLWithPath: filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("oracle-snapshots.json")
        let data = try Data(contentsOf: fixtureURL)
        return try JSONDecoder().decode(SnapshotFile.self, from: data)
    }
}
