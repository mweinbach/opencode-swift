#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

struct InputMaxLengthConformanceRow: Sendable {
    let index: Int
    let name: String
    let value: String
    let maxLength: Int
    let select: Int
    let insert: String
    let expected: String
    let issue: String?
}

private enum ConformanceJSONValue: Decodable {
    case null
    case bool(Bool)
    case int(Int)
    case string(String)
    case array([ConformanceJSONValue])
    case object([String: ConformanceJSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? c.decode(Int.self) {
            self = .int(i)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([ConformanceJSONValue].self) {
            self = .array(a)
        } else if let o = try? c.decode([String: ConformanceJSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
        }
    }
}

private struct RawInputMaxLengthFile: Decodable {
    let rows: [[ConformanceJSONValue]]
}

enum TextEngineConformanceLoaderError: Error {
    case malformedRow(Int, String)
}

enum TextEngineConformanceLoader {
    static func loadInputMaxLength(relativeTo filePath: String = #filePath) throws -> [InputMaxLengthConformanceRow] {
        // filePath = .../Packages/OpenTUI/Tests/OpenTUICoreTests/TextEngineConformanceLoader.swift
        let repoRoot = URL(fileURLWithPath: filePath)
            .deletingLastPathComponent() // OpenTUICoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // OpenTUI
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repo root

        let conformanceURL = repoRoot
            .appendingPathComponent("upstream")
            .appendingPathComponent("opentui")
            .appendingPathComponent("packages")
            .appendingPathComponent("core")
            .appendingPathComponent("src")
            .appendingPathComponent("renderables")
            .appendingPathComponent("input-max-length.conformance.json")

        let data = try Data(contentsOf: conformanceURL)
        let decoded = try JSONDecoder().decode(RawInputMaxLengthFile.self, from: data)

        return try decoded.rows.enumerated().map { index, rawRow in
            guard rawRow.count >= 6 else {
                throw TextEngineConformanceLoaderError.malformedRow(index, "expected at least 6 elements")
            }
            guard case .string(let name) = rawRow[0] else {
                throw TextEngineConformanceLoaderError.malformedRow(index, "row[0] must be string name")
            }
            guard case .string(let value) = rawRow[1] else {
                throw TextEngineConformanceLoaderError.malformedRow(index, "row[1] must be string value")
            }
            guard case .int(let maxLength) = rawRow[2] else {
                throw TextEngineConformanceLoaderError.malformedRow(index, "row[2] must be int maxLength")
            }
            guard case .int(let select) = rawRow[3] else {
                throw TextEngineConformanceLoaderError.malformedRow(index, "row[3] must be int select")
            }
            guard case .string(let insert) = rawRow[4] else {
                throw TextEngineConformanceLoaderError.malformedRow(index, "row[4] must be string insert")
            }
            guard case .string(let expected) = rawRow[5] else {
                throw TextEngineConformanceLoaderError.malformedRow(index, "row[5] must be string expected")
            }
            var issue: String? = nil
            if rawRow.count >= 7, case .string(let issueStr) = rawRow[6] {
                issue = issueStr
            }

            return InputMaxLengthConformanceRow(
                index: index,
                name: name,
                value: value,
                maxLength: maxLength,
                select: select,
                insert: insert,
                expected: expected,
                issue: issue
            )
        }
    }
}
