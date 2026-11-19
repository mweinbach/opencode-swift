import OpenCodeTUI
import OpenTUICore

#if canImport(SwiftUI)
import SwiftUI
#endif

/// Cross-platform resolved theme palette bridging `OpenCodeTUI.ThemeDefaults` & `TUIThemeBridge`
/// semantic tokens into deterministic `OpenTUICore.RGBA` values (and SwiftUI `Color` on Apple OSes).
public struct AppResolvedPalette: Equatable, Hashable, Sendable {
    public let themeName: String
    public let effectiveMode: Mode
    public let resolvedTheme: ResolvedTheme

    public init(themeName: String = "opencode", mode: Mode = .dark) {
        self.themeName = themeName
        self.effectiveMode = mode
        self.resolvedTheme = Self.resolveDocument(named: themeName, mode: mode)
    }

    public init(themeName: String = "opencode", preference: AppThemeMode, systemIsDark: Bool) {
        let mode = preference.resolvedMode(systemIsDark: systemIsDark)
        self.init(themeName: themeName, mode: mode)
    }

    /// Available built-in theme names surfaced in `SettingsSheet`.
    public static var availableThemeNames: [String] {
        var names = Set(TUIThemeBridge.allThemes().keys)
        names.insert("opencode")
        names.insert("opencode2")
        names.remove("system")
        let preferred = ["opencode", "opencode2"]
        let rest = names.filter { !preferred.contains($0) }.sorted()
        return preferred.filter { names.contains($0) } + rest
    }

    /// Resolves a named theme via `OpenCodeTUI.ThemeDefaults` / `TUIThemeBridge` with safe fallback.
    public static func resolveDocument(named name: String, mode: Mode) -> ResolvedTheme {
        if name == "opencode" {
            return ThemeDefaults.resolveOrDefault(ThemeDefaults.opencode, mode: mode)
        }
        if name == "opencode2" {
            return ThemeDefaults.resolveOrDefault(ThemeDefaults.opencode2, mode: mode)
        }
        let all = TUIThemeBridge.allThemes()
        if let source = all[name], let doc = try? TUIThemeBridge.parseTheme(source, name: name) {
            return ThemeDefaults.resolveOrDefault(doc, mode: mode)
        }
        return ThemeDefaults.resolveOrDefault(ThemeDefaults.opencode, mode: mode)
    }

    // MARK: - Semantic RGBA Tokens (Portable Across Every Swift Platform)

    public var isDark: Bool { effectiveMode == .dark }
    public var background: RGBA { resolvedTheme.background.base }
    public var surfaceRaised: RGBA { resolvedTheme.background.raised.base }
    public var surfaceHigh: RGBA { resolvedTheme.background.raised.high }
    public var surfaceMax: RGBA { resolvedTheme.background.raised.max }
    public var dialogBackground: RGBA { resolvedTheme.surface(.dialog).background.base }

    public var textPrimary: RGBA { resolvedTheme.text.base }
    public var textMuted: RGBA { resolvedTheme.text.muted }
    public var textFaint: RGBA { resolvedTheme.text.faint }

    public var accent: RGBA { resolvedTheme.hue.accent[.s200] }
    public var interactive: RGBA { resolvedTheme.text.action.primary.selected }
    public var border: RGBA { resolvedTheme.border.base }

    public var success: RGBA { resolvedTheme.text.feedback.success.base }
    public var warning: RGBA { resolvedTheme.text.feedback.warning.base }
    public var error: RGBA { resolvedTheme.text.feedback.error.base }
    public var info: RGBA { resolvedTheme.text.feedback.info.base }

    public var diffAddedText: RGBA { resolvedTheme.diff.text.added }
    public var diffAddedBackground: RGBA { resolvedTheme.diff.background.added }
    public var diffRemovedText: RGBA { resolvedTheme.diff.text.removed }
    public var diffRemovedBackground: RGBA { resolvedTheme.diff.background.removed }
    public var diffContextText: RGBA { resolvedTheme.diff.text.context }
    public var diffHunkHeader: RGBA { resolvedTheme.diff.text.hunkHeader }
    public var diffLineNumber: RGBA { resolvedTheme.diff.lineNumber.text }

    public var markdownHeading: RGBA { resolvedTheme.markdown.heading }
    public var markdownCode: RGBA { resolvedTheme.markdown.code }
    public var markdownLink: RGBA { resolvedTheme.markdown.link }
    public var markdownQuote: RGBA { resolvedTheme.markdown.blockQuote }
    public var markdownEmphasis: RGBA { resolvedTheme.markdown.emphasis }
    public var markdownStrong: RGBA { resolvedTheme.markdown.strong }

    public var syntaxKeyword: RGBA { resolvedTheme.syntax.keyword }
    public var syntaxString: RGBA { resolvedTheme.syntax.string }
    public var syntaxComment: RGBA { resolvedTheme.syntax.comment }
    public var syntaxFunction: RGBA { resolvedTheme.syntax.function }
    public var syntaxType: RGBA { resolvedTheme.syntax.type }
    public var syntaxNumber: RGBA { resolvedTheme.syntax.number }

    /// Resolves an accent `RGBA` color for an agent (explicit hex override or categorical scale).
    public func agentRGBA(colorHex: String?, index: Int) -> RGBA {
        if let colorHex, colorHex.hasPrefix("#") {
            return RGBA.fromHex(colorHex)
        }
        let scales = resolvedTheme.categorical
        guard !scales.isEmpty else { return interactive }
        return scales[max(0, index) % scales.count][.s200]
    }
}

#if canImport(SwiftUI)
public extension RGBA {
    /// Converts an `OpenTUICore.RGBA` theme token into a SwiftUI `Color` in sRGB space.
    var swiftUIColor: SwiftUI.Color {
        SwiftUI.Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

public extension AppResolvedPalette {
    /// Preferred SwiftUI `ColorScheme` override for explicit `.light`/`.dark` selection, or `nil` for `.system`.
    static func preferredColorScheme(for mode: AppThemeMode) -> ColorScheme? {
        switch mode {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var backgroundColor: SwiftUI.Color { background.swiftUIColor }
    var surfaceRaisedColor: SwiftUI.Color { surfaceRaised.swiftUIColor }
    var surfaceHighColor: SwiftUI.Color { surfaceHigh.swiftUIColor }
    var surfaceMaxColor: SwiftUI.Color { surfaceMax.swiftUIColor }
    var dialogBackgroundColor: SwiftUI.Color { dialogBackground.swiftUIColor }

    var textPrimaryColor: SwiftUI.Color { textPrimary.swiftUIColor }
    var textMutedColor: SwiftUI.Color { textMuted.swiftUIColor }
    var textFaintColor: SwiftUI.Color { textFaint.swiftUIColor }

    var accentColor: SwiftUI.Color { accent.swiftUIColor }
    var interactiveColor: SwiftUI.Color { interactive.swiftUIColor }
    var borderColor: SwiftUI.Color { border.swiftUIColor }

    var successColor: SwiftUI.Color { success.swiftUIColor }
    var warningColor: SwiftUI.Color { warning.swiftUIColor }
    var errorColor: SwiftUI.Color { error.swiftUIColor }
    var infoColor: SwiftUI.Color { info.swiftUIColor }

    var diffAddedTextColor: SwiftUI.Color { diffAddedText.swiftUIColor }
    var diffAddedBackgroundColor: SwiftUI.Color { diffAddedBackground.swiftUIColor }
    var diffRemovedTextColor: SwiftUI.Color { diffRemovedText.swiftUIColor }
    var diffRemovedBackgroundColor: SwiftUI.Color { diffRemovedBackground.swiftUIColor }
    var diffContextTextColor: SwiftUI.Color { diffContextText.swiftUIColor }
    var diffHunkHeaderColor: SwiftUI.Color { diffHunkHeader.swiftUIColor }
    var diffLineNumberColor: SwiftUI.Color { diffLineNumber.swiftUIColor }

    var markdownHeadingColor: SwiftUI.Color { markdownHeading.swiftUIColor }
    var markdownCodeColor: SwiftUI.Color { markdownCode.swiftUIColor }
    var markdownLinkColor: SwiftUI.Color { markdownLink.swiftUIColor }
    var markdownQuoteColor: SwiftUI.Color { markdownQuote.swiftUIColor }
    var markdownEmphasisColor: SwiftUI.Color { markdownEmphasis.swiftUIColor }
    var markdownStrongColor: SwiftUI.Color { markdownStrong.swiftUIColor }

    var syntaxKeywordColor: SwiftUI.Color { syntaxKeyword.swiftUIColor }
    var syntaxStringColor: SwiftUI.Color { syntaxString.swiftUIColor }
    var syntaxCommentColor: SwiftUI.Color { syntaxComment.swiftUIColor }
    var syntaxFunctionColor: SwiftUI.Color { syntaxFunction.swiftUIColor }
    var syntaxTypeColor: SwiftUI.Color { syntaxType.swiftUIColor }
    var syntaxNumberColor: SwiftUI.Color { syntaxNumber.swiftUIColor }

    func agentColor(colorHex: String?, index: Int) -> SwiftUI.Color {
        agentRGBA(colorHex: colorHex, index: index).swiftUIColor
    }
}
#endif
