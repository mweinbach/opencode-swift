#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

enum StdinConformanceStep: Sendable {
    case bytes([UInt8])
    case timeout
}

struct StdinConformanceContext: Sendable {
    let kitty: Bool
    let pending: [String]
}

struct StdinConformanceRow: Sendable {
    let index: Int
    let name: String
    let steps: [StdinConformanceStep]
    let expected: [String]
    let issue: String?
    let context: StdinConformanceContext
}

private enum RawJSONValue: Decodable {
    case null
    case bool(Bool)
    case int(Int)
    case string(String)
    case array([RawJSONValue])
    case object([String: RawJSONValue])

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
        } else if let a = try? c.decode([RawJSONValue].self) {
            self = .array(a)
        } else if let o = try? c.decode([String: RawJSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
        }
    }
}

private struct RawConformanceFile: Decodable {
    let rows: [[RawJSONValue]]
}

enum StdinConformanceLoaderError: Error {
    case malformedRow(Int, String)
}

enum StdinConformanceLoader {
    static func load(relativeTo filePath: String = #filePath) throws -> [StdinConformanceRow] {
        // filePath = .../Packages/OpenTUI/Tests/OpenTUICoreTests/StdinConformanceLoader.swift
        let repoRoot = URL(fileURLWithPath: filePath)
            .deletingLastPathComponent() // OpenTUICoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // OpenTUI
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repo root

        let upstreamURL = repoRoot
            .appendingPathComponent("upstream")
            .appendingPathComponent("opentui")
            .appendingPathComponent("packages")
            .appendingPathComponent("core")
            .appendingPathComponent("src")
            .appendingPathComponent("lib")
            .appendingPathComponent("stdin-parser.conformance.json")

        let conformanceURL = FileManager.default.fileExists(atPath: upstreamURL.path)
            ? upstreamURL
            : URL(fileURLWithPath: filePath)
                .deletingLastPathComponent()
                .appendingPathComponent("Fixtures")
                .appendingPathComponent("stdin-parser.conformance.json")

        let data = try Data(contentsOf: conformanceURL)
        let decoded = try JSONDecoder().decode(RawConformanceFile.self, from: data)

        return try decoded.rows.enumerated().map { index, rawRow in
            guard rawRow.count >= 3 else {
                throw StdinConformanceLoaderError.malformedRow(index, "expected at least 3 elements")
            }
            guard case .string(let name) = rawRow[0] else {
                throw StdinConformanceLoaderError.malformedRow(index, "row[0] must be string name")
            }
            guard case .array(let rawSteps) = rawRow[1] else {
                throw StdinConformanceLoaderError.malformedRow(index, "row[1] must be steps array")
            }
            let steps: [StdinConformanceStep] = try rawSteps.map { step in
                switch step {
                case .null:
                    return .timeout
                case .string(let text):
                    return .bytes(Array(text.utf8))
                case .array(let nums):
                    let bytes: [UInt8] = try nums.map { num in
                        guard case .int(let value) = num, value >= 0, value <= 255 else {
                            throw StdinConformanceLoaderError.malformedRow(index, "step byte out of range")
                        }
                        return UInt8(value)
                    }
                    return .bytes(bytes)
                default:
                    throw StdinConformanceLoaderError.malformedRow(index, "unsupported step type")
                }
            }

            guard case .array(let rawExpected) = rawRow[2] else {
                throw StdinConformanceLoaderError.malformedRow(index, "row[2] must be expected array")
            }
            let expected: [String] = try rawExpected.map { item in
                guard case .string(let str) = item else {
                    throw StdinConformanceLoaderError.malformedRow(index, "expected item must be string")
                }
                return str
            }

            var issue: String? = nil
            if rawRow.count >= 4 {
                if case .string(let issueStr) = rawRow[3] {
                    issue = issueStr
                }
            }

            var kitty = false
            var pending: [String] = []
            if rawRow.count >= 5, case .object(let ctxObj) = rawRow[4] {
                if case .bool(let k) = ctxObj["kitty"] {
                    kitty = k
                }
                if case .array(let pendingArr) = ctxObj["pending"] {
                    for p in pendingArr {
                        if case .string(let q) = p {
                            pending.append(q)
                        }
                    }
                }
            }

            return StdinConformanceRow(
                index: index,
                name: name,
                steps: steps,
                expected: expected,
                issue: issue,
                context: StdinConformanceContext(kitty: kitty, pending: pending)
            )
        }
    }
}
