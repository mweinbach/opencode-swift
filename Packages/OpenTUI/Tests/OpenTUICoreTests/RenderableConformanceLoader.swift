#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// MARK: - Diff Conformance Loader

enum DiffConformanceExpected: Equatable, Sendable {
    case error
    case hunks([[String]])
}

struct DiffConformanceRow: Sendable {
    let index: Int
    let name: String
    let diff: String
    let expected: DiffConformanceExpected
    let coreDefect: String?
}

// MARK: - Markdown Conformance Loader

struct MarkdownConformanceRow: Sendable {
    let index: Int
    let name: String
    let chunks: [String]
    let expectedHTML: String
    let fails: [String]

    var source: String {
        chunks.joined()
    }
}

// MARK: - Generic JSON Decoding Helper

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

private struct RawRowsFile: Decodable {
    let rows: [[ConformanceJSONValue]]
}

enum RenderableConformanceLoaderError: Error {
    case malformedRow(file: String, index: Int, detail: String)
}

enum RenderableConformanceLoader {
    private static func upstreamRenderablesDir(relativeTo filePath: String) -> URL {
        // filePath = .../Packages/OpenTUI/Tests/OpenTUICoreTests/RenderableConformanceLoader.swift
        URL(fileURLWithPath: filePath)
            .deletingLastPathComponent() // OpenTUICoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // OpenTUI
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("upstream")
            .appendingPathComponent("opentui")
            .appendingPathComponent("packages")
            .appendingPathComponent("core")
            .appendingPathComponent("src")
            .appendingPathComponent("renderables")
    }

    static func loadDiffConformance(relativeTo filePath: String = #filePath) throws -> [DiffConformanceRow] {
        let url = upstreamRenderablesDir(relativeTo: filePath).appendingPathComponent("diff.conformance.json")
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(RawRowsFile.self, from: data)

        return try decoded.rows.enumerated().map { index, rawRow in
            guard rawRow.count >= 3 else {
                throw RenderableConformanceLoaderError.malformedRow(
                    file: "diff.conformance.json",
                    index: index,
                    detail: "expected at least 3 elements"
                )
            }
            guard case .string(let name) = rawRow[0] else {
                throw RenderableConformanceLoaderError.malformedRow(
                    file: "diff.conformance.json",
                    index: index,
                    detail: "row[0] must be name string"
                )
            }
            guard case .string(let diff) = rawRow[1] else {
                throw RenderableConformanceLoaderError.malformedRow(
                    file: "diff.conformance.json",
                    index: index,
                    detail: "row[1] must be diff string"
                )
            }

            let expected: DiffConformanceExpected
            switch rawRow[2] {
            case .string(let tag) where tag == "error":
                expected = .error
            case .array(let rawHunks):
                let hunks: [[String]] = try rawHunks.map { rawHunk in
                    guard case .array(let rawLines) = rawHunk else {
                        throw RenderableConformanceLoaderError.malformedRow(
                            file: "diff.conformance.json",
                            index: index,
                            detail: "hunk entry must be array"
                        )
                    }
                    return try rawLines.map { rawLine in
                        guard case .string(let line) = rawLine else {
                            throw RenderableConformanceLoaderError.malformedRow(
                                file: "diff.conformance.json",
                                index: index,
                                detail: "hunk line must be string"
                            )
                        }
                        return line
                    }
                }
                expected = .hunks(hunks)
            default:
                throw RenderableConformanceLoaderError.malformedRow(
                    file: "diff.conformance.json",
                    index: index,
                    detail: "row[2] must be \"error\" or hunks array"
                )
            }

            var coreDefect: String? = nil
            if rawRow.count >= 4, case .string(let defect) = rawRow[3] {
                coreDefect = defect
            }

            return DiffConformanceRow(
                index: index,
                name: name,
                diff: diff,
                expected: expected,
                coreDefect: coreDefect
            )
        }
    }

    static func loadMarkdownConformance(relativeTo filePath: String = #filePath) throws -> [MarkdownConformanceRow] {
        let url = upstreamRenderablesDir(relativeTo: filePath).appendingPathComponent("markdown.conformance.json")
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(RawRowsFile.self, from: data)

        return try decoded.rows.enumerated().map { index, rawRow in
            guard rawRow.count >= 4 else {
                throw RenderableConformanceLoaderError.malformedRow(
                    file: "markdown.conformance.json",
                    index: index,
                    detail: "expected at least 4 elements"
                )
            }
            guard case .string(let name) = rawRow[0] else {
                throw RenderableConformanceLoaderError.malformedRow(
                    file: "markdown.conformance.json",
                    index: index,
                    detail: "row[0] must be name string"
                )
            }
            guard case .array(let rawChunks) = rawRow[1] else {
                throw RenderableConformanceLoaderError.malformedRow(
                    file: "markdown.conformance.json",
                    index: index,
                    detail: "row[1] must be chunks array"
                )
            }
            let chunks: [String] = try rawChunks.map { item in
                guard case .string(let s) = item else {
                    throw RenderableConformanceLoaderError.malformedRow(
                        file: "markdown.conformance.json",
                        index: index,
                        detail: "chunk must be string"
                    )
                }
                return s
            }
            guard case .string(let expectedHTML) = rawRow[2] else {
                throw RenderableConformanceLoaderError.malformedRow(
                    file: "markdown.conformance.json",
                    index: index,
                    detail: "row[2] must be expected HTML string"
                )
            }
            guard case .array(let rawFails) = rawRow[3] else {
                throw RenderableConformanceLoaderError.malformedRow(
                    file: "markdown.conformance.json",
                    index: index,
                    detail: "row[3] must be fails array"
                )
            }
            let fails: [String] = rawFails.compactMap { item in
                if case .string(let s) = item { return s }
                return nil
            }

            return MarkdownConformanceRow(
                index: index,
                name: name,
                chunks: chunks,
                expectedHTML: expectedHTML,
                fails: fails
            )
        }
    }
}
