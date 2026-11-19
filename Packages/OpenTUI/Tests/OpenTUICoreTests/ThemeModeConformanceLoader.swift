#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

struct ThemeModeConformanceRow: Sendable {
    let index: Int
    let name: String
    let reply: String
    let expectedMode: String
    let issue: String?
}

private struct RawThemeModeConformanceFile: Decodable {
    let rows: [[String]]
}

enum ThemeModeConformanceLoaderError: Error {
    case malformedRow(Int, String)
}

enum ThemeModeConformanceLoader {
    static func load(relativeTo filePath: String = #filePath) throws -> [ThemeModeConformanceRow] {
        // filePath = .../Packages/OpenTUI/Tests/OpenTUICoreTests/ThemeModeConformanceLoader.swift
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
            .appendingPathComponent("theme-mode.conformance.json")

        let data = try Data(contentsOf: conformanceURL)
        let decoded = try JSONDecoder().decode(RawThemeModeConformanceFile.self, from: data)

        return try decoded.rows.enumerated().map { index, row in
            guard row.count >= 3 else {
                throw ThemeModeConformanceLoaderError.malformedRow(index, "expected at least 3 elements")
            }
            return ThemeModeConformanceRow(
                index: index,
                name: row[0],
                reply: row[1],
                expectedMode: row[2],
                issue: row.count >= 4 ? row[3] : nil
            )
        }
    }
}
