import Foundation
import OpenCodeSchema
import OpenCodeTUI
import OpenTUICore

/// Foundation / filesystem / JSON helpers for `TUIComponentsPluginsTests` (isolated from `import Testing`
/// per macOS Command Line Tools cross-import overlay rules).
enum TUIComponentsTestHelper {
    static func withTempDirectory(_ body: (String) async throws -> Void) async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-opencode-tui-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try await body(base.path)
    }

    static func writeFile(dir: String, relativePath: String, content: String) throws -> String {
        let url = URL(fileURLWithPath: dir).appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
        return url.path
    }

    static func createDirectory(dir: String, relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: dir).appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    static func makeSampleThemeJSON(primary: String = "#ff8800") -> String {
        """
        {
          "theme": {
            "primary": "\(primary)",
            "secondary": "#0088ff",
            "accent": "#aa55ff",
            "error": "#ff4444",
            "warning": "#ffaa00",
            "success": "#44cc66",
            "info": "#44aaff",
            "text": "#eeeeee",
            "textMuted": "#888888",
            "background": "#111111",
            "backgroundPanel": "#1a1a1a",
            "backgroundElement": "#222222",
            "border": "#444444",
            "borderActive": "#666666",
            "borderSubtle": "#333333",
            "diffAdded": "#44cc66",
            "diffRemoved": "#ff4444",
            "diffContext": "#888888",
            "diffHunkHeader": "#888888",
            "diffHighlightAdded": "#66ee88",
            "diffHighlightRemoved": "#ff6666",
            "diffAddedBg": "#112211",
            "diffRemovedBg": "#221111",
            "diffContextBg": "#151515",
            "diffLineNumber": "#666666",
            "diffAddedLineNumberBg": "#112211",
            "diffRemovedLineNumberBg": "#221111",
            "markdownText": "#eeeeee",
            "markdownHeading": "#aa55ff",
            "markdownLink": "#0088ff",
            "markdownLinkText": "#44aaff",
            "markdownCode": "#44cc66",
            "markdownBlockQuote": "#ffaa00",
            "markdownEmph": "#ffaa00",
            "markdownStrong": "#ff8800",
            "markdownHorizontalRule": "#555555",
            "markdownListItem": "#0088ff",
            "markdownListEnumeration": "#44aaff",
            "markdownImage": "#0088ff",
            "markdownImageText": "#44aaff",
            "markdownCodeBlock": "#eeeeee",
            "syntaxComment": "#666666",
            "syntaxKeyword": "#aa55ff",
            "syntaxFunction": "#ff8800",
            "syntaxVariable": "#ff4444",
            "syntaxString": "#44cc66",
            "syntaxNumber": "#ffaa00",
            "syntaxType": "#44aaff",
            "syntaxOperator": "#44aaff",
            "syntaxPunctuation": "#eeeeee"
          }
        }
        """
    }

    static func decodeJSON(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    static func defaultDarkTheme() throws -> ResolvedTheme {
        try resolveThemeDocument(ThemeDefaults.opencode, mode: .dark)
    }

    static func defaultLightTheme() throws -> ResolvedTheme {
        try resolveThemeDocument(ThemeDefaults.opencode, mode: .light)
    }

    static func makeBudget(
        id: String = "b1",
        limit: Double = 10.0,
        spent: Double = 9.2,
        scope: UsageLimitsSchema.Budget.Scope = .each,
        per: UsageLimitsSchema.Budget.Per = .set,
        coverage: UsageLimitsSchema.Budget.Coverage = .all,
        models: [UsageLimitsSchema.BudgetModel] = [],
        vendors: [String] = [],
        shared: Bool = false,
        resetsAt: Double = 1_800_000_000_000
    ) throws -> UsageLimitsSchema.Budget {
        UsageLimitsSchema.Budget(
            id: id,
            limit: try MoneySchema.USD(validating: limit),
            spent: try MoneySchema.USD(validating: spent),
            scope: scope,
            per: per,
            coverage: coverage,
            models: models,
            vendors: vendors,
            inputPriceAtLeast: nil,
            picked: false,
            shared: shared,
            resetsAt: resetsAt
        )
    }
}
