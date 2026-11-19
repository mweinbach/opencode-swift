#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import OpenCodeSchema
import OpenTUICore

// MARK: - Expansion & Deep Merging (`packages/theme/src/tui/expand.ts`)

/// Expands shorthand token defaults across a `ThemeDefinition` and its `@dialog` / `@footer` surfaces.
// parity: theme/src/tui/expand.ts#expandTheme [status=implemented hash=cb51fca76d85]
public func expandTheme(_ definition: ThemeDefinition) -> ThemeDefinition {
    let expanded = expandTokens(definition.tokens)
    return ThemeDefinition(
        hue: definition.hue,
        categorical: definition.categorical,
        text: expanded.text ?? definition.text,
        background: expanded.background ?? definition.background,
        border: expanded.border ?? definition.border,
        scrollbar: expanded.scrollbar ?? definition.scrollbar,
        diff: expanded.diff ?? definition.diff,
        syntax: expanded.syntax ?? definition.syntax,
        markdown: expanded.markdown ?? definition.markdown,
        dialog: definition.dialog.map(expandDialog)
    )
}

/// Expands shorthand token defaults across a `ModeDefinition` and its `@dialog` / `@footer` surfaces.
public func expandTheme(_ definition: ModeDefinition) -> ModeDefinition {
    let tok = ThemeTokensDefinition(
        text: definition.text,
        background: definition.background,
        border: definition.border,
        scrollbar: definition.scrollbar,
        diff: definition.diff,
        syntax: definition.syntax,
        markdown: definition.markdown
    )
    let expanded = expandTokens(tok)
    return ModeDefinition(
        hue: definition.hue,
        categorical: definition.categorical,
        text: expanded.text,
        background: expanded.background,
        border: expanded.border,
        scrollbar: expanded.scrollbar,
        diff: expanded.diff,
        syntax: expanded.syntax,
        markdown: expanded.markdown,
        dialog: definition.dialog.map(expandDialog)
    )
}

private func expandDialog(_ definition: DialogTokensDefinition) -> DialogTokensDefinition {
    let expanded = expandTokens(definition.asTokens)
    return DialogTokensDefinition(
        text: expanded.text,
        background: expanded.background,
        border: expanded.border,
        scrollbar: expanded.scrollbar,
        diff: expanded.diff,
        syntax: expanded.syntax,
        markdown: expanded.markdown,
        footer: definition.footer.map(expandTokens)
    )
}

/// Expands shorthand defaults on a `ThemeTokensDefinition` (`text.muted`, `text.faint`, action/formfield states, feedback muted).
// parity: theme/src/tui/expand.ts#expandTokens [status=implemented hash=222a8d069896]
public func expandTokens(_ definition: ThemeTokensDefinition) -> ThemeTokensDefinition {
    ThemeTokensDefinition(
        text: expandText(definition.text),
        background: expandBackground(definition.background),
        border: definition.border,
        scrollbar: definition.scrollbar,
        diff: definition.diff,
        syntax: definition.syntax,
        markdown: definition.markdown
    )
}

private func expandText(_ definition: TextDefinition?) -> TextDefinition? {
    guard let definition else { return nil }
    let muted = definition.muted ?? (definition.base != nil ? "$text.base" : nil)
    let faint = definition.faint ?? ((definition.muted != nil || definition.base != nil) ? "$text.muted" : nil)
    let feedback: TextFeedbackDefinition? = definition.feedback.map { fb in
        func expandItem(_ item: TextFeedbackItemDefinition?, kind: FeedbackKind) -> TextFeedbackItemDefinition? {
            guard let item else { return nil }
            let itemMuted = item.muted ?? (item.base != nil ? "$text.feedback.\(kind.rawValue).base" : nil)
            return TextFeedbackItemDefinition(base: item.base, muted: itemMuted)
        }
        return TextFeedbackDefinition(
            error: expandItem(fb.error, kind: .error),
            warning: expandItem(fb.warning, kind: .warning),
            success: expandItem(fb.success, kind: .success),
            info: expandItem(fb.info, kind: .info)
        )
    }
    return TextDefinition(
        base: definition.base,
        muted: muted,
        faint: faint,
        action: expandActions(definition.action, path: "text.action"),
        formfield: expandFormfield(definition.formfield, path: "text.formfield"),
        feedback: feedback
    )
}

private func expandBackground(_ definition: BackgroundDefinition?) -> BackgroundDefinition? {
    guard let definition else { return nil }
    return BackgroundDefinition(
        base: definition.base,
        raised: definition.raised,
        action: expandActions(definition.action, path: "background.action"),
        formfield: expandFormfield(definition.formfield, path: "background.formfield"),
        feedback: definition.feedback
    )
}

private func expandFormfield(_ definition: StatefulColorDefinition?, path: String) -> StatefulColorDefinition? {
    guard var result = definition, result.base != nil else { return definition }
    let fallback = "$\(path).base"
    for state in ActionState.literals {
        if result[state] == nil {
            result[state] = fallback
        }
    }
    return result
}

private func expandActions(_ definition: ActionColorDefinition?, path: String) -> ActionColorDefinition? {
    guard var result = definition else { return nil }
    for variant in ActionVariant.literals {
        guard var val = result[variant], val.base != nil else { continue }
        let fallback = "$\(path).\(variant.rawValue).base"
        for state in ActionState.literals {
            if val[state] == nil {
                val[state] = fallback
            }
        }
        result[variant] = val
    }
    return result
}

/// Recursively deep-merges JSON object records (matching upstream `expand.ts#mergeTheme`).
// parity: theme/src/tui/expand.ts#mergeTheme [status=implemented hash=006c58be7608]
public func mergeTheme(_ values: JSONValue...) -> [String: JSONValue] {
    mergeTheme(values)
}

/// Recursively deep-merges an array of `JSONValue` objects.
public func mergeTheme(_ values: [JSONValue]) -> [String: JSONValue] {
    var result: [String: JSONValue] = [:]
    for value in values {
        guard case .object(let dict) = value else { continue }
        for (key, item) in dict {
            if case .object = item, let existing = result[key], case .object = existing {
                result[key] = .object(mergeTheme([existing, item]))
            } else {
                result[key] = item
            }
        }
    }
    return result
}

// MARK: - Typed Deep Merge Helpers

private func mergeStateful(_ base: StatefulColorDefinition?, _ override: StatefulColorDefinition?) -> StatefulColorDefinition? {
    guard let override else { return base }
    guard let base else { return override }
    return StatefulColorDefinition(
        base: override.base ?? base.base,
        hovered: override.hovered ?? base.hovered,
        focused: override.focused ?? base.focused,
        pressed: override.pressed ?? base.pressed,
        selected: override.selected ?? base.selected,
        disabled: override.disabled ?? base.disabled
    )
}

private func mergeActions(_ base: ActionColorDefinition?, _ override: ActionColorDefinition?) -> ActionColorDefinition? {
    guard let override else { return base }
    guard let base else { return override }
    return ActionColorDefinition(
        primary: mergeStateful(base.primary, override.primary),
        secondary: mergeStateful(base.secondary, override.secondary),
        destructive: mergeStateful(base.destructive, override.destructive)
    )
}

private func mergeTextFeedback(_ base: TextFeedbackDefinition?, _ override: TextFeedbackDefinition?) -> TextFeedbackDefinition? {
    guard let override else { return base }
    guard let base else { return override }
    func mergeItem(_ a: TextFeedbackItemDefinition?, _ b: TextFeedbackItemDefinition?) -> TextFeedbackItemDefinition? {
        guard let b else { return a }
        guard let a else { return b }
        return TextFeedbackItemDefinition(base: b.base ?? a.base, muted: b.muted ?? a.muted)
    }
    return TextFeedbackDefinition(
        error: mergeItem(base.error, override.error),
        warning: mergeItem(base.warning, override.warning),
        success: mergeItem(base.success, override.success),
        info: mergeItem(base.info, override.info)
    )
}

private func mergeBackgroundFeedback(
    _ base: BackgroundFeedbackDefinition?,
    _ override: BackgroundFeedbackDefinition?
) -> BackgroundFeedbackDefinition? {
    guard let override else { return base }
    guard let base else { return override }
    func mergeItem(
        _ a: BackgroundFeedbackItemDefinition?,
        _ b: BackgroundFeedbackItemDefinition?
    ) -> BackgroundFeedbackItemDefinition? {
        guard let b else { return a }
        guard let a else { return b }
        return BackgroundFeedbackItemDefinition(base: b.base ?? a.base)
    }
    return BackgroundFeedbackDefinition(
        error: mergeItem(base.error, override.error),
        warning: mergeItem(base.warning, override.warning),
        success: mergeItem(base.success, override.success),
        info: mergeItem(base.info, override.info)
    )
}

private func mergeText(_ base: TextDefinition?, _ override: TextDefinition?) -> TextDefinition? {
    guard let override else { return base }
    guard let base else { return override }
    return TextDefinition(
        base: override.base ?? base.base,
        muted: override.muted ?? base.muted,
        faint: override.faint ?? base.faint,
        action: mergeActions(base.action, override.action),
        formfield: mergeStateful(base.formfield, override.formfield),
        feedback: mergeTextFeedback(base.feedback, override.feedback)
    )
}

private func mergeBackground(_ base: BackgroundDefinition?, _ override: BackgroundDefinition?) -> BackgroundDefinition? {
    guard let override else { return base }
    guard let base else { return override }
    let raised: RaisedBackgroundDefinition?
    if let r2 = override.raised {
        if let r1 = base.raised {
            raised = RaisedBackgroundDefinition(
                base: r2.base ?? r1.base,
                high: r2.high ?? r1.high,
                max: r2.max ?? r1.max
            )
        } else {
            raised = r2
        }
    } else {
        raised = base.raised
    }
    return BackgroundDefinition(
        base: override.base ?? base.base,
        raised: raised,
        action: mergeActions(base.action, override.action),
        formfield: mergeStateful(base.formfield, override.formfield),
        feedback: mergeBackgroundFeedback(base.feedback, override.feedback)
    )
}

private func mergeSingle(_ base: SingleColorDefinition?, _ override: SingleColorDefinition?) -> SingleColorDefinition? {
    guard let override else { return base }
    guard let base else { return override }
    return SingleColorDefinition(base: override.base ?? base.base)
}

private func mergeDiff(_ base: DiffDefinition?, _ override: DiffDefinition?) -> DiffDefinition? {
    guard let override else { return base }
    guard let base else { return override }
    let text: DiffDefinition.Text? = override.text.map { o in
        let b = base.text
        return DiffDefinition.Text(
            added: o.added ?? b?.added,
            removed: o.removed ?? b?.removed,
            context: o.context ?? b?.context,
            hunkHeader: o.hunkHeader ?? b?.hunkHeader
        )
    } ?? base.text
    let background: DiffDefinition.Background? = override.background.map { o in
        let b = base.background
        return DiffDefinition.Background(
            added: o.added ?? b?.added,
            removed: o.removed ?? b?.removed,
            context: o.context ?? b?.context
        )
    } ?? base.background
    let highlight: DiffDefinition.Highlight? = override.highlight.map { o in
        let b = base.highlight
        return DiffDefinition.Highlight(added: o.added ?? b?.added, removed: o.removed ?? b?.removed)
    } ?? base.highlight
    let lineNumber: DiffDefinition.LineNumber? = override.lineNumber.map { o in
        let b = base.lineNumber
        let bg: DiffDefinition.LineNumber.LineNumberBackground? = o.background.map { ob in
            let bb = b?.background
            return DiffDefinition.LineNumber.LineNumberBackground(
                added: ob.added ?? bb?.added,
                removed: ob.removed ?? bb?.removed
            )
        } ?? b?.background
        return DiffDefinition.LineNumber(text: o.text ?? b?.text, background: bg)
    } ?? base.lineNumber
    return DiffDefinition(text: text, background: background, highlight: highlight, lineNumber: lineNumber)
}

private func mergeSyntax(_ base: SyntaxDefinition?, _ override: SyntaxDefinition?) -> SyntaxDefinition? {
    guard let override else { return base }
    guard var result = base else { return override }
    for (k, v) in override { result[k] = v }
    return result
}

private func mergeMarkdown(_ base: MarkdownDefinition?, _ override: MarkdownDefinition?) -> MarkdownDefinition? {
    guard let override else { return base }
    guard var result = base else { return override }
    for (k, v) in override { result[k] = v }
    return result
}

private func mergeTokens(_ base: ThemeTokensDefinition, _ override: ThemeTokensDefinition) -> ThemeTokensDefinition {
    ThemeTokensDefinition(
        text: mergeText(base.text, override.text),
        background: mergeBackground(base.background, override.background),
        border: mergeSingle(base.border, override.border),
        scrollbar: mergeSingle(base.scrollbar, override.scrollbar),
        diff: mergeDiff(base.diff, override.diff),
        syntax: mergeSyntax(base.syntax, override.syntax),
        markdown: mergeMarkdown(base.markdown, override.markdown)
    )
}

private func mergeDialog(_ base: DialogTokensDefinition?, _ override: DialogTokensDefinition?) -> DialogTokensDefinition? {
    guard let override else { return base }
    guard let base else { return override }
    let mergedTok = mergeTokens(base.asTokens, override.asTokens)
    let mergedFooter: ThemeTokensDefinition?
    if let f2 = override.footer {
        mergedFooter = base.footer.map { mergeTokens($0, f2) } ?? f2
    } else {
        mergedFooter = base.footer
    }
    return DialogTokensDefinition(
        text: mergedTok.text,
        background: mergedTok.background,
        border: mergedTok.border,
        scrollbar: mergedTok.scrollbar,
        diff: mergedTok.diff,
        syntax: mergedTok.syntax,
        markdown: mergedTok.markdown,
        footer: mergedFooter
    )
}

// MARK: - Mode Selection (`packages/theme/src/tui/select.ts`)

/// Result returned by `selectThemeMode(_:mode:)`.
public struct SelectedThemeMode: Equatable, Hashable, Sendable {
    public let theme: ThemeDefinition
    public let mode: Mode

    public init(theme: ThemeDefinition, mode: Mode) {
        self.theme = theme
        self.mode = mode
    }
}

/// Selects and merges the requested `mode` (or fallback available mode) from a `ThemeDocument`.
// parity: theme/src/tui/select.ts#selectTheme [status=implemented hash=f4e261bad561]
public func selectTheme(_ document: ThemeDocument, mode: Mode = .light) throws -> ThemeDefinition {
    try selectThemeMode(document, mode: mode).theme
}

/// Selects and merges the requested `mode` (or first supported mode) from a `ThemeDocument`, returning both theme and resolved mode.
// parity: theme/src/tui/select.ts#selectThemeMode [status=implemented hash=494ed9fe9ca3]
public func selectThemeMode(_ document: ThemeDocument, mode: Mode = .light) throws -> SelectedThemeMode {
    let modes = themeModes(document)
    guard let firstMode = modes.first else {
        throw ThemeError("Theme must provide at least one mode")
    }
    let selectedMode = modes.contains(mode) ? mode : firstMode
    guard let selected = (selectedMode == .light ? document.light : document.dark) else {
        throw ThemeError("Theme must provide at least one mode")
    }
    let merged = ThemeDefinition(
        hue: selected.hue,
        categorical: selected.categorical ?? document.base.categorical,
        text: mergeText(document.base.text, selected.text) ?? document.base.text,
        background: mergeBackground(document.base.background, selected.background) ?? document.base.background,
        border: mergeSingle(document.base.border, selected.border) ?? document.base.border,
        scrollbar: mergeSingle(document.base.scrollbar, selected.scrollbar) ?? document.base.scrollbar,
        diff: mergeDiff(document.base.diff, selected.diff) ?? document.base.diff,
        syntax: mergeSyntax(document.base.syntax, selected.syntax) ?? document.base.syntax,
        markdown: mergeMarkdown(document.base.markdown, selected.markdown) ?? document.base.markdown,
        dialog: mergeDialog(document.base.dialog, selected.dialog)
    )
    return SelectedThemeMode(theme: merged, mode: selectedMode)
}

/// Returns the appearance modes (`[.light]`, `[.dark]`, or `[.light, .dark]`) provided by `document`.
// parity: theme/src/tui/select.ts#themeModes [status=implemented hash=c8b5b59757ed]
public func themeModes(_ document: ThemeDocument) -> [Mode] {
    var modes: [Mode] = []
    if document.light != nil { modes.append(.light) }
    if document.dark != nil { modes.append(.dark) }
    return modes
}

/// Returns whether `document` explicitly defines `mode`.
// parity: theme/src/tui/select.ts#supportsThemeMode [status=implemented hash=30241a7a8df3]
public func supportsThemeMode(_ document: ThemeDocument, mode: Mode) -> Bool {
    themeModes(document).contains(mode)
}

// MARK: - Resolution & Validation (`packages/theme/src/tui/resolve.ts`)

/// Wraps a theme schema or resolution error with the canonical `"Invalid theme: <name> <value> is an invalid value"` diagnostic.
// parity: theme/src/tui/resolve.ts#themeDecodeError [status=implemented hash=136a336855f0]
public func themeDecodeError(_ error: any Error, name: String = "theme") -> ThemeError {
    let message: String
    if let te = error as? ThemeError {
        message = te.message
    } else {
        message = String(describing: error)
    }
    let extracted = extractGotValue(from: message) ?? "value"
    return ThemeError("Invalid theme: \(name) \(extracted) is an invalid value", underlyingDescription: message)
}

private func extractGotValue(from message: String) -> String? {
    let utf8 = Array(message.utf8)
    let needle: [UInt8] = Array("got ".utf8)
    guard utf8.count >= needle.count else { return nil }
    for i in 0...(utf8.count - needle.count) {
        var matched = true
        for j in 0..<needle.count {
            if utf8[i + j] != needle[j] { matched = false; break }
        }
        if !matched { continue }
        let start = i + needle.count
        guard start < utf8.count else { return nil }
        if utf8[start] == 0x22 /* " */ {
            var end = start + 1
            while end < utf8.count && utf8[end] != 0x22 { end += 1 }
            if end < utf8.count {
                return String(decoding: utf8[start...end], as: UTF8.self)
            }
        }
        var end = start
        while end < utf8.count && utf8[end] != 0x20 && utf8[end] != 0x09 && utf8[end] != 0x0A && utf8[end] != 0x0D {
            end += 1
        }
        if end > start {
            return String(decoding: utf8[start..<end], as: UTF8.self)
        }
    }
    return nil
}

/// Validates and parses a `ThemeDocument` from a `JSONValue`, resolving every mode it provides.
// parity: theme/src/tui/resolve.ts#parseThemeDocument [status=implemented hash=587dad9bc55c]
public func parseThemeDocument(_ input: JSONValue, name: String = "theme") throws -> ThemeDocument {
    do {
        let data = try JSONEncoder().encode(input)
        return try parseThemeDocument(data: data, name: name)
    } catch let error as ThemeError {
        if error.message.hasPrefix("Invalid theme: ") { throw error }
        throw themeDecodeError(error, name: name)
    } catch {
        throw themeDecodeError(error, name: name)
    }
}

/// Validates and parses a `ThemeDocument` from raw UTF-8 JSON `Data`, resolving every mode it provides.
public func parseThemeDocument(data: Data, name: String = "theme") throws -> ThemeDocument {
    do {
        let document = try JSONDecoder().decode(ThemeDocument.self, from: data)
        try validateThemeDocument(document)
        for mode in themeModes(document) {
            _ = try resolveThemeDocument(document, mode: mode)
        }
        return document
    } catch {
        throw themeDecodeError(error, name: name)
    }
}

/// Validates and parses a `ThemeDocument` from a JSON string, resolving every mode it provides.
public func parseThemeDocument(json: String, name: String = "theme") throws -> ThemeDocument {
    try parseThemeDocument(data: Data(json.utf8), name: name)
}

/// Selects `mode` from `document`, expands shorthand tokens, and resolves all colors and surfaces.
// parity: theme/src/tui/resolve.ts#resolveThemeDocument [status=implemented hash=572ad80d4c3b]
public func resolveThemeDocument(_ document: ThemeDocument, mode: Mode = .light) throws -> ResolvedTheme {
    let selected = try selectThemeMode(document, mode: mode)
    let definition = expandTheme(selected.theme)
    return try resolveExpandedTheme(definition)
}

/// Validates, expands, and resolves a complete `ThemeDefinition` into a `ResolvedTheme`.
// parity: theme/src/tui/resolve.ts#resolveTheme [status=implemented hash=d49e75244323]
public func resolveTheme(_ definition: ThemeDefinition) throws -> ResolvedTheme {
    do {
        try validateThemeDefinition(definition)
    } catch {
        throw themeDecodeError(error, name: "theme")
    }
    return try resolveExpandedTheme(expandTheme(definition))
}

// MARK: - Schema Validation

private func isHexColor(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    guard bytes.count >= 4, bytes[0] == 0x23 /* # */ else { return false }
    let digits = bytes.count - 1
    guard digits == 3 || digits == 4 || digits == 6 || digits == 8 else { return false }
    for b in bytes.dropFirst() {
        let isDigit = b >= 0x30 && b <= 0x39
        let isUpper = b >= 0x41 && b <= 0x46
        let isLower = b >= 0x61 && b <= 0x66
        if !isDigit && !isUpper && !isLower { return false }
    }
    return true
}

private func isColorValue(_ value: String) -> Bool {
    if value == "transparent" { return true }
    if isHexColor(value) { return true }
    return value.hasPrefix("$") && value.count > 1
}

private func isHueColorValue(_ value: String) -> Bool {
    if isHexColor(value) { return true }
    guard value.hasPrefix("$hue.") else { return false }
    let rest = value.dropFirst(5)
    guard let dot = rest.lastIndex(of: ".") else { return false }
    let name = rest[..<dot]
    let stepStr = rest[rest.index(after: dot)...]
    guard !name.isEmpty, let stepInt = Int(stepStr), HueStep(rawValue: stepInt) != nil else { return false }
    return true
}

private func validateHueDefinition(_ hue: HueDefinition) throws {
    for name in hue.values.keys {
        if name.isEmpty {
            throw ThemeError("Hue name must be non-empty, got \"\"")
        }
    }
    let missing = SemanticHue.allCases.map(\.rawValue).filter { hue.values[$0] == nil }
    if !missing.isEmpty {
        throw ThemeError("Missing required semantic hues: \(missing.joined(separator: ", "))")
    }
    for (name, val) in hue.values {
        switch val {
        case .alias(let ref):
            guard ref.hasPrefix("$hue.") && ref.count > 5 else {
                throw ThemeError("Hue alias got \"\(ref)\"")
            }
        case .scale(let map):
            for step in HueStep.literals {
                guard let color = map[step], isHexColor(color) else {
                    throw ThemeError("Invalid hue color at \"hue.\(name).\(step.rawValue)\", got \"\(map[step] ?? "undefined")\"")
                }
            }
        }
    }
}

private func validateOptionalColor(_ value: String?, path: String) throws {
    guard let value else { return }
    guard isColorValue(value) else {
        throw ThemeError("Invalid color at \"\(path)\", got \"\(value)\"")
    }
}

private func validateRequiredColor(_ value: String?, path: String) throws {
    guard let value, isColorValue(value) else {
        throw ThemeError("Invalid color at \"\(path)\", got \"\(value ?? "undefined")\"")
    }
}

private func validateStateful(_ def: StatefulColorDefinition?, requiredBase: Bool, path: String) throws {
    guard let def else {
        if requiredBase { throw ThemeError("Missing required stateful color at \"\(path)\"") }
        return
    }
    if requiredBase {
        try validateRequiredColor(def.base, path: "\(path).base")
    } else {
        try validateOptionalColor(def.base, path: "\(path).base")
    }
    for state in ActionState.literals {
        try validateOptionalColor(def[state], path: "\(path).$\(state.rawValue)")
    }
}

private func validateThemeTokens(_ tokens: ThemeTokensDefinition, complete: Bool, prefix: String) throws {
    if complete {
        guard let text = tokens.text else { throw ThemeError("Missing required \"\(prefix).text\"") }
        try validateRequiredColor(text.base, path: "\(prefix).text.base")
        try validateRequiredColor(text.muted, path: "\(prefix).text.muted")
        try validateOptionalColor(text.faint, path: "\(prefix).text.faint")
        guard let textAction = text.action else { throw ThemeError("Missing required \"\(prefix).text.action\"") }
        for v in ActionVariant.literals {
            try validateStateful(textAction[v], requiredBase: true, path: "\(prefix).text.action.\(v.rawValue)")
        }
        try validateStateful(text.formfield, requiredBase: true, path: "\(prefix).text.formfield")
        guard let textFb = text.feedback else { throw ThemeError("Missing required \"\(prefix).text.feedback\"") }
        for k in FeedbackKind.literals {
            guard let item = textFb[k] else { throw ThemeError("Missing required \"\(prefix).text.feedback.\(k.rawValue)\"") }
            try validateRequiredColor(item.base, path: "\(prefix).text.feedback.\(k.rawValue).base")
            try validateOptionalColor(item.muted, path: "\(prefix).text.feedback.\(k.rawValue).muted")
        }

        guard let bg = tokens.background else { throw ThemeError("Missing required \"\(prefix).background\"") }
        try validateRequiredColor(bg.base, path: "\(prefix).background.base")
        guard let raised = bg.raised else { throw ThemeError("Missing required \"\(prefix).background.raised\"") }
        try validateRequiredColor(raised.base, path: "\(prefix).background.raised.base")
        try validateRequiredColor(raised.high, path: "\(prefix).background.raised.high")
        try validateRequiredColor(raised.max, path: "\(prefix).background.raised.max")
        guard let bgAction = bg.action else { throw ThemeError("Missing required \"\(prefix).background.action\"") }
        for v in ActionVariant.literals {
            try validateStateful(bgAction[v], requiredBase: true, path: "\(prefix).background.action.\(v.rawValue)")
        }
        try validateStateful(bg.formfield, requiredBase: true, path: "\(prefix).background.formfield")
        guard let bgFb = bg.feedback else { throw ThemeError("Missing required \"\(prefix).background.feedback\"") }
        for k in FeedbackKind.literals {
            guard let item = bgFb[k] else { throw ThemeError("Missing required \"\(prefix).background.feedback.\(k.rawValue)\"") }
            try validateRequiredColor(item.base, path: "\(prefix).background.feedback.\(k.rawValue).base")
        }

        try validateRequiredColor(tokens.border?.base, path: "\(prefix).border.base")
        try validateRequiredColor(tokens.scrollbar?.base, path: "\(prefix).scrollbar.base")

        guard let diff = tokens.diff else { throw ThemeError("Missing required \"\(prefix).diff\"") }
        try validateRequiredColor(diff.text?.added, path: "\(prefix).diff.text.added")
        try validateRequiredColor(diff.text?.removed, path: "\(prefix).diff.text.removed")
        try validateRequiredColor(diff.text?.context, path: "\(prefix).diff.text.context")
        try validateRequiredColor(diff.text?.hunkHeader, path: "\(prefix).diff.text.hunkHeader")
        try validateRequiredColor(diff.background?.added, path: "\(prefix).diff.background.added")
        try validateRequiredColor(diff.background?.removed, path: "\(prefix).diff.background.removed")
        try validateRequiredColor(diff.background?.context, path: "\(prefix).diff.background.context")
        try validateRequiredColor(diff.highlight?.added, path: "\(prefix).diff.highlight.added")
        try validateRequiredColor(diff.highlight?.removed, path: "\(prefix).diff.highlight.removed")
        try validateRequiredColor(diff.lineNumber?.text, path: "\(prefix).diff.lineNumber.text")
        try validateRequiredColor(diff.lineNumber?.background?.added, path: "\(prefix).diff.lineNumber.background.added")
        try validateRequiredColor(diff.lineNumber?.background?.removed, path: "\(prefix).diff.lineNumber.background.removed")

        guard let syntax = tokens.syntax else { throw ThemeError("Missing required \"\(prefix).syntax\"") }
        for token in SyntaxToken.literals {
            guard let v = syntax[token], isHueColorValue(v) else {
                throw ThemeError("Invalid syntax color at \"\(prefix).syntax.\(token.rawValue)\", got \"\(syntax[token] ?? "undefined")\"")
            }
        }
        guard let markdown = tokens.markdown else { throw ThemeError("Missing required \"\(prefix).markdown\"") }
        for token in MarkdownToken.literals {
            guard let v = markdown[token], isHueColorValue(v) else {
                throw ThemeError("Invalid markdown color at \"\(prefix).markdown.\(token.rawValue)\", got \"\(markdown[token] ?? "undefined")\"")
            }
        }
    } else {
        if let text = tokens.text {
            try validateOptionalColor(text.base, path: "\(prefix).text.base")
            try validateOptionalColor(text.muted, path: "\(prefix).text.muted")
            try validateOptionalColor(text.faint, path: "\(prefix).text.faint")
            if let action = text.action {
                for v in ActionVariant.literals {
                    try validateStateful(action[v], requiredBase: false, path: "\(prefix).text.action.\(v.rawValue)")
                }
            }
            try validateStateful(text.formfield, requiredBase: false, path: "\(prefix).text.formfield")
            if let fb = text.feedback {
                for k in FeedbackKind.literals {
                    try validateOptionalColor(fb[k]?.base, path: "\(prefix).text.feedback.\(k.rawValue).base")
                    try validateOptionalColor(fb[k]?.muted, path: "\(prefix).text.feedback.\(k.rawValue).muted")
                }
            }
        }
        if let bg = tokens.background {
            try validateOptionalColor(bg.base, path: "\(prefix).background.base")
            try validateOptionalColor(bg.raised?.base, path: "\(prefix).background.raised.base")
            try validateOptionalColor(bg.raised?.high, path: "\(prefix).background.raised.high")
            try validateOptionalColor(bg.raised?.max, path: "\(prefix).background.raised.max")
            if let action = bg.action {
                for v in ActionVariant.literals {
                    try validateStateful(action[v], requiredBase: false, path: "\(prefix).background.action.\(v.rawValue)")
                }
            }
            try validateStateful(bg.formfield, requiredBase: false, path: "\(prefix).background.formfield")
            if let fb = bg.feedback {
                for k in FeedbackKind.literals {
                    try validateOptionalColor(fb[k]?.base, path: "\(prefix).background.feedback.\(k.rawValue).base")
                }
            }
        }
        try validateOptionalColor(tokens.border?.base, path: "\(prefix).border.base")
        try validateOptionalColor(tokens.scrollbar?.base, path: "\(prefix).scrollbar.base")
        if let diff = tokens.diff {
            try validateOptionalColor(diff.text?.added, path: "\(prefix).diff.text.added")
            try validateOptionalColor(diff.text?.removed, path: "\(prefix).diff.text.removed")
            try validateOptionalColor(diff.text?.context, path: "\(prefix).diff.text.context")
            try validateOptionalColor(diff.text?.hunkHeader, path: "\(prefix).diff.text.hunkHeader")
            try validateOptionalColor(diff.background?.added, path: "\(prefix).diff.background.added")
            try validateOptionalColor(diff.background?.removed, path: "\(prefix).diff.background.removed")
            try validateOptionalColor(diff.background?.context, path: "\(prefix).diff.background.context")
            try validateOptionalColor(diff.highlight?.added, path: "\(prefix).diff.highlight.added")
            try validateOptionalColor(diff.highlight?.removed, path: "\(prefix).diff.highlight.removed")
            try validateOptionalColor(diff.lineNumber?.text, path: "\(prefix).diff.lineNumber.text")
            try validateOptionalColor(diff.lineNumber?.background?.added, path: "\(prefix).diff.lineNumber.background.added")
            try validateOptionalColor(diff.lineNumber?.background?.removed, path: "\(prefix).diff.lineNumber.background.removed")
        }
        if let syntax = tokens.syntax {
            for (token, v) in syntax where !isHueColorValue(v) {
                throw ThemeError("Invalid syntax color at \"\(prefix).syntax.\(token.rawValue)\", got \"\(v)\"")
            }
        }
        if let markdown = tokens.markdown {
            for (token, v) in markdown where !isHueColorValue(v) {
                throw ThemeError("Invalid markdown color at \"\(prefix).markdown.\(token.rawValue)\", got \"\(v)\"")
            }
        }
    }
}

private func validateDialog(_ dialog: DialogTokensDefinition?, prefix: String) throws {
    guard let dialog else { return }
    try validateThemeTokens(dialog.asTokens, complete: false, prefix: "\(prefix).@dialog")
    if let footer = dialog.footer {
        try validateThemeTokens(footer, complete: false, prefix: "\(prefix).@dialog.@footer")
    }
}

private func validateThemeDefinition(_ definition: ThemeDefinition) throws {
    try validateHueDefinition(definition.hue)
    guard !definition.categorical.isEmpty, definition.categorical.allSatisfy({ !$0.isEmpty }) else {
        throw ThemeError("Categorical must be a non-empty array of hue names")
    }
    try validateThemeTokens(definition.tokens, complete: true, prefix: "theme")
    try validateDialog(definition.dialog, prefix: "theme")
}

private func validateThemeDocument(_ document: ThemeDocument) throws {
    guard document.light != nil || document.dark != nil else {
        throw ThemeError("Theme must provide at least one mode")
    }
    guard !document.base.categorical.isEmpty, document.base.categorical.allSatisfy({ !$0.isEmpty }) else {
        throw ThemeError("Base categorical must be a non-empty array of hue names")
    }
    let baseTokens = ThemeTokensDefinition(
        text: document.base.text,
        background: document.base.background,
        border: document.base.border,
        scrollbar: document.base.scrollbar,
        diff: document.base.diff,
        syntax: document.base.syntax,
        markdown: document.base.markdown
    )
    try validateThemeTokens(baseTokens, complete: true, prefix: "base")
    try validateDialog(document.base.dialog, prefix: "base")

    for (modeName, modeDef) in [("light", document.light), ("dark", document.dark)] {
        guard let modeDef else { continue }
        try validateHueDefinition(modeDef.hue)
        if let cat = modeDef.categorical {
            guard !cat.isEmpty, cat.allSatisfy({ !$0.isEmpty }) else {
                throw ThemeError("Mode \(modeName) categorical must be a non-empty array of hue names")
            }
        }
        let tok = ThemeTokensDefinition(
            text: modeDef.text,
            background: modeDef.background,
            border: modeDef.border,
            scrollbar: modeDef.scrollbar,
            diff: modeDef.diff,
            syntax: modeDef.syntax,
            markdown: modeDef.markdown
        )
        try validateThemeTokens(tok, complete: false, prefix: modeName)
        try validateDialog(modeDef.dialog, prefix: modeName)
    }
}

// MARK: - Resolution Pipeline

private func resolveExpandedTheme(_ definition: ThemeDefinition) throws -> ResolvedTheme {
    let hue = try resolveHue(definition.hue)
    var categorical: Categorical = []
    categorical.reserveCapacity(definition.categorical.count)
    for name in definition.categorical {
        guard let scale = hue[name] else {
            throw ThemeError("Categorical hue \"\(name)\" was not found")
        }
        categorical.append(scale)
    }
    let hueIndex = HueStepIndex(hue: hue, orderedNames: definition.hue.orderedNames)
    let base = definition.tokens
    let dialogDef = definition.dialog
    let dialogTokens = dialogDef.map { contextualize(base, $0.asTokens) } ?? base
    let baseResolved = try resolveView(base, hue: hue, categorical: categorical, hueIndex: hueIndex)
    let dialogResolved = try resolveView(dialogTokens, hue: hue, categorical: categorical, hueIndex: hueIndex)
    let footerResolved: ResolvedThemeTokens
    if let footer = dialogDef?.footer {
        let footerTokens = contextualize(dialogTokens, footer)
        footerResolved = try resolveView(footerTokens, hue: hue, categorical: categorical, hueIndex: hueIndex)
    } else {
        footerResolved = dialogResolved
    }
    let surfaceTokens: [SurfaceName: ResolvedThemeTokens] = [
        .dialog: dialogResolved,
        .dialogFooter: footerResolved,
    ]
    return ResolvedTheme(tokens: baseResolved, surfaceTokens: surfaceTokens)
}

private func contextualize(
    _ base: ThemeTokensDefinition,
    _ override: ThemeTokensDefinition
) -> ThemeTokensDefinition {
    var result = mergeTokens(base, override)
    if var text = result.text {
        text.action = contextualActions(base: base.text?.action, surface: override.text?.action)
        result.text = text
    }
    if var bg = result.background {
        bg.action = contextualActions(base: base.background?.action, surface: override.background?.action)
        result.background = bg
    }
    return result
}

private func contextualActions(
    base: ActionColorDefinition?,
    surface: ActionColorDefinition?
) -> ActionColorDefinition {
    var result = ActionColorDefinition()
    for variant in ActionVariant.literals {
        let baseVariant = base?[variant]
        let surfaceVariant = surface?[variant]
        var stateDef = StatefulColorDefinition()
        stateDef.base = surfaceVariant?.base ?? baseVariant?.base
        for state in ActionState.literals {
            stateDef[state] = surfaceVariant?[state] ?? surfaceVariant?.base ?? baseVariant?[state] ?? baseVariant?.base
        }
        result[variant] = stateDef
    }
    return result
}

private func resolveHue(_ definition: HueDefinition) throws -> Hue {
    var cache: [String: HueScale] = [:]

    func resolve(_ name: String, stack: [String]) throws -> HueScale {
        if let hit = cache[name] { return hit }
        if stack.contains(name) {
            throw ThemeError("Circular hue reference: \((stack + [name]).joined(separator: " -> "))")
        }
        guard let value = definition.values[name] else {
            throw ThemeError("Hue \"\(name)\" was not found")
        }
        switch value {
        case .alias(let ref):
            guard ref.hasPrefix("$hue.") && ref.count > 5 else {
                throw ThemeError("Hue alias \"\(ref)\" must reference a hue scale")
            }
            let targetName = String(ref.dropFirst(5))
            guard definition.values[targetName] != nil else {
                throw ThemeError("Hue alias \"\(ref)\" references a missing hue")
            }
            let target = try resolve(targetName, stack: stack + [name])
            cache[name] = target
            return target
        case .scale(let map):
            var colors: [HueStep: RGBA] = [:]
            for step in HueStep.literals {
                guard let color = map[step], isHexColor(color) else {
                    throw ThemeError("Invalid hue color at \"hue.\(name).\(step.rawValue)\"")
                }
                colors[step] = RGBA.fromHex(color)
            }
            let scale = HueScale(
                s100: colors[.s100]!,
                s200: colors[.s200]!,
                s300: colors[.s300]!,
                s400: colors[.s400]!,
                s500: colors[.s500]!,
                s600: colors[.s600]!,
                s700: colors[.s700]!,
                s800: colors[.s800]!,
                s900: colors[.s900]!
            )
            cache[name] = scale
            return scale
        }
    }

    var resolved: [String: HueScale] = [:]
    for name in definition.orderedNames {
        resolved[name] = try resolve(name, stack: [])
    }
    guard let accent = resolved["accent"],
          let interactive = resolved["interactive"],
          let neutral = resolved["neutral"]
    else {
        throw ThemeError("Missing required semantic hues")
    }
    return Hue(accent: accent, interactive: interactive, neutral: neutral, scales: resolved)
}

private enum TokenNode {
    case color(RGBA)
    case raw(String)
    case group([String: TokenNode])
}

private func buildTokenTree(_ definition: ThemeTokensDefinition, hue: Hue) -> [String: TokenNode] {
    func statefulNode(_ def: StatefulColorDefinition?) -> TokenNode {
        var map: [String: TokenNode] = [:]
        if let base = def?.base { map["base"] = .raw(base) }
        for state in ActionState.literals {
            if let val = def?[state] {
                map["$\(state.rawValue)"] = .raw(val)
            }
        }
        return .group(map)
    }

    func actionsNode(_ def: ActionColorDefinition?) -> TokenNode {
        var map: [String: TokenNode] = [:]
        for variant in ActionVariant.literals {
            if let v = def?[variant] {
                map[variant.rawValue] = statefulNode(v)
            }
        }
        return .group(map)
    }

    var root: [String: TokenNode] = [:]

    var hueMap: [String: TokenNode] = [:]
    for (name, scale) in hue.scales {
        var stepMap: [String: TokenNode] = [:]
        for step in HueStep.literals {
            stepMap[String(step.rawValue)] = .color(scale[step])
        }
        hueMap[name] = .group(stepMap)
    }
    root["hue"] = .group(hueMap)

    if let text = definition.text {
        var textMap: [String: TokenNode] = [:]
        if let v = text.base { textMap["base"] = .raw(v) }
        if let v = text.muted { textMap["muted"] = .raw(v) }
        if let v = text.faint { textMap["faint"] = .raw(v) }
        if let a = text.action { textMap["action"] = actionsNode(a) }
        if let f = text.formfield { textMap["formfield"] = statefulNode(f) }
        if let fb = text.feedback {
            var fbMap: [String: TokenNode] = [:]
            for k in FeedbackKind.literals {
                if let item = fb[k] {
                    var itemMap: [String: TokenNode] = [:]
                    if let b = item.base { itemMap["base"] = .raw(b) }
                    if let m = item.muted { itemMap["muted"] = .raw(m) }
                    fbMap[k.rawValue] = .group(itemMap)
                }
            }
            textMap["feedback"] = .group(fbMap)
        }
        root["text"] = .group(textMap)
    }

    if let bg = definition.background {
        var bgMap: [String: TokenNode] = [:]
        if let v = bg.base { bgMap["base"] = .raw(v) }
        if let raised = bg.raised {
            var rMap: [String: TokenNode] = [:]
            if let v = raised.base { rMap["base"] = .raw(v) }
            if let v = raised.high { rMap["high"] = .raw(v) }
            if let v = raised.max { rMap["max"] = .raw(v) }
            bgMap["raised"] = .group(rMap)
        }
        if let a = bg.action { bgMap["action"] = actionsNode(a) }
        if let f = bg.formfield { bgMap["formfield"] = statefulNode(f) }
        if let fb = bg.feedback {
            var fbMap: [String: TokenNode] = [:]
            for k in FeedbackKind.literals {
                if let item = fb[k] {
                    var itemMap: [String: TokenNode] = [:]
                    if let b = item.base { itemMap["base"] = .raw(b) }
                    fbMap[k.rawValue] = .group(itemMap)
                }
            }
            bgMap["feedback"] = .group(fbMap)
        }
        root["background"] = .group(bgMap)
    }

    if let border = definition.border?.base {
        root["border"] = .group(["base": .raw(border)])
    }
    if let scrollbar = definition.scrollbar?.base {
        root["scrollbar"] = .group(["base": .raw(scrollbar)])
    }

    if let diff = definition.diff {
        var diffMap: [String: TokenNode] = [:]
        if let dt = diff.text {
            var m: [String: TokenNode] = [:]
            if let v = dt.added { m["added"] = .raw(v) }
            if let v = dt.removed { m["removed"] = .raw(v) }
            if let v = dt.context { m["context"] = .raw(v) }
            if let v = dt.hunkHeader { m["hunkHeader"] = .raw(v) }
            diffMap["text"] = .group(m)
        }
        if let db = diff.background {
            var m: [String: TokenNode] = [:]
            if let v = db.added { m["added"] = .raw(v) }
            if let v = db.removed { m["removed"] = .raw(v) }
            if let v = db.context { m["context"] = .raw(v) }
            diffMap["background"] = .group(m)
        }
        if let dh = diff.highlight {
            var m: [String: TokenNode] = [:]
            if let v = dh.added { m["added"] = .raw(v) }
            if let v = dh.removed { m["removed"] = .raw(v) }
            diffMap["highlight"] = .group(m)
        }
        if let dln = diff.lineNumber {
            var m: [String: TokenNode] = [:]
            if let v = dln.text { m["text"] = .raw(v) }
            if let bg = dln.background {
                var bm: [String: TokenNode] = [:]
                if let v = bg.added { bm["added"] = .raw(v) }
                if let v = bg.removed { bm["removed"] = .raw(v) }
                m["background"] = .group(bm)
            }
            diffMap["lineNumber"] = .group(m)
        }
        root["diff"] = .group(diffMap)
    }

    if let syntax = definition.syntax {
        var sMap: [String: TokenNode] = [:]
        for (k, v) in syntax { sMap[k.rawValue] = .raw(v) }
        root["syntax"] = .group(sMap)
    }

    if let markdown = definition.markdown {
        var mMap: [String: TokenNode] = [:]
        for (k, v) in markdown { mMap[k.rawValue] = .raw(v) }
        root["markdown"] = .group(mMap)
    }

    return root
}

private func resolveView(
    _ definition: ThemeTokensDefinition,
    hue: Hue,
    categorical: Categorical,
    hueIndex: HueStepIndex
) throws -> ResolvedThemeTokens {
    let source = buildTokenTree(definition, hue: hue)
    var cache: [String: RGBA] = [:]

    func readNode(_ path: String) throws -> TokenNode {
        if path.hasPrefix("hue.") {
            let rest = path.dropFirst(4)
            if let dot = rest.lastIndex(of: ".") {
                let hueName = String(rest[..<dot])
                let stepStr = String(rest[rest.index(after: dot)...])
                if let stepInt = Int(stepStr), let step = HueStep(rawValue: stepInt) {
                    if let scale = hue[hueName] {
                        return .color(scale[step])
                    }
                    throw ThemeError("Theme reference \"$\(path)\" was not found")
                }
            }
        }
        var current: TokenNode = .group(source)
        for segment in path.split(separator: ".", omittingEmptySubsequences: false) {
            let key = String(segment)
            guard case .group(let dict) = current, let next = dict[key] else {
                throw ThemeError("Theme reference \"$\(path)\" was not found")
            }
            current = next
        }
        return current
    }

    func resolveNode(_ node: TokenNode, path: String, stack: [String]) throws -> RGBA {
        switch node {
        case .color(let rgba):
            return rgba
        case .raw(let value):
            return try resolveString(value, path: path, stack: stack)
        case .group:
            throw ThemeError("Theme reference at \"\(path)\" is not a color")
        }
    }

    func resolveString(_ value: String, path: String, stack: [String]) throws -> RGBA {
        if value == "transparent" { return RGBA.fromInts(0, 0, 0, 0) }
        if isHexColor(value) { return RGBA.fromHex(value) }
        guard value.hasPrefix("$") else {
            throw ThemeError("Invalid color \"\(value)\" at \"\(path)\"")
        }
        let target = String(value.dropFirst())
        if let hit = cache[target] { return hit }
        if stack.contains(target) {
            throw ThemeError("Circular theme reference: \((stack + [target]).joined(separator: " -> "))")
        }
        let node = try readNode(target)
        let resolved: RGBA
        switch node {
        case .color(let rgba):
            resolved = rgba
        case .raw(let rawStr):
            resolved = try resolveString(rawStr, path: target, stack: stack + [target])
        case .group:
            throw ThemeError("Theme reference \"\(value)\" at \"\(path)\" is not a color")
        }
        cache[target] = resolved
        return resolved
    }

    func resolvePath(_ path: String) throws -> RGBA {
        let node = try readNode(path)
        return try resolveNode(node, path: path, stack: [])
    }

    func resolveStateful(prefix: String) throws -> StatefulColor {
        StatefulColor(
            base: try resolvePath("\(prefix).base"),
            disabled: try resolvePath("\(prefix).$disabled"),
            pressed: try resolvePath("\(prefix).$pressed"),
            focused: try resolvePath("\(prefix).$focused"),
            selected: try resolvePath("\(prefix).$selected"),
            hovered: try resolvePath("\(prefix).$hovered")
        )
    }

    func resolveActions(prefix: String) throws -> ResolvedActionColors {
        ResolvedActionColors(
            primary: try resolveStateful(prefix: "\(prefix).primary"),
            secondary: try resolveStateful(prefix: "\(prefix).secondary"),
            destructive: try resolveStateful(prefix: "\(prefix).destructive")
        )
    }

    let text = ResolvedTextTokens(
        base: try resolvePath("text.base"),
        muted: try resolvePath("text.muted"),
        faint: try resolvePath("text.faint"),
        action: try resolveActions(prefix: "text.action"),
        formfield: try resolveStateful(prefix: "text.formfield"),
        feedback: ResolvedTextFeedback(
            error: ResolvedTextFeedbackColor(
                base: try resolvePath("text.feedback.error.base"),
                muted: try resolvePath("text.feedback.error.muted")
            ),
            warning: ResolvedTextFeedbackColor(
                base: try resolvePath("text.feedback.warning.base"),
                muted: try resolvePath("text.feedback.warning.muted")
            ),
            success: ResolvedTextFeedbackColor(
                base: try resolvePath("text.feedback.success.base"),
                muted: try resolvePath("text.feedback.success.muted")
            ),
            info: ResolvedTextFeedbackColor(
                base: try resolvePath("text.feedback.info.base"),
                muted: try resolvePath("text.feedback.info.muted")
            )
        )
    )

    let background = ResolvedBackgroundTokens(
        base: try resolvePath("background.base"),
        raised: ResolvedRaisedBackground(
            base: try resolvePath("background.raised.base"),
            high: try resolvePath("background.raised.high"),
            max: try resolvePath("background.raised.max")
        ),
        action: try resolveActions(prefix: "background.action"),
        formfield: try resolveStateful(prefix: "background.formfield"),
        feedback: ResolvedBackgroundFeedback(
            error: ResolvedBaseColor(base: try resolvePath("background.feedback.error.base")),
            warning: ResolvedBaseColor(base: try resolvePath("background.feedback.warning.base")),
            success: ResolvedBaseColor(base: try resolvePath("background.feedback.success.base")),
            info: ResolvedBaseColor(base: try resolvePath("background.feedback.info.base"))
        )
    )

    let border = ResolvedBaseColor(base: try resolvePath("border.base"))
    let scrollbar = ResolvedBaseColor(base: try resolvePath("scrollbar.base"))

    let diff = ResolvedDiffTokens(
        text: ResolvedDiffTokens.Text(
            added: try resolvePath("diff.text.added"),
            removed: try resolvePath("diff.text.removed"),
            context: try resolvePath("diff.text.context"),
            hunkHeader: try resolvePath("diff.text.hunkHeader")
        ),
        background: ResolvedDiffTokens.Background(
            added: try resolvePath("diff.background.added"),
            removed: try resolvePath("diff.background.removed"),
            context: try resolvePath("diff.background.context")
        ),
        highlight: ResolvedDiffTokens.Highlight(
            added: try resolvePath("diff.highlight.added"),
            removed: try resolvePath("diff.highlight.removed")
        ),
        lineNumber: ResolvedDiffTokens.LineNumber(
            text: try resolvePath("diff.lineNumber.text"),
            background: ResolvedDiffTokens.LineNumber.Background(
                added: try resolvePath("diff.lineNumber.background.added"),
                removed: try resolvePath("diff.lineNumber.background.removed")
            )
        )
    )

    let syntax = ResolvedSyntaxTokens(
        comment: try resolvePath("syntax.comment"),
        keyword: try resolvePath("syntax.keyword"),
        function: try resolvePath("syntax.function"),
        variable: try resolvePath("syntax.variable"),
        string: try resolvePath("syntax.string"),
        number: try resolvePath("syntax.number"),
        type: try resolvePath("syntax.type"),
        operator: try resolvePath("syntax.operator"),
        punctuation: try resolvePath("syntax.punctuation")
    )

    let markdown = ResolvedMarkdownTokens(
        text: try resolvePath("markdown.text"),
        heading: try resolvePath("markdown.heading"),
        link: try resolvePath("markdown.link"),
        linkText: try resolvePath("markdown.linkText"),
        code: try resolvePath("markdown.code"),
        blockQuote: try resolvePath("markdown.blockQuote"),
        emphasis: try resolvePath("markdown.emphasis"),
        strong: try resolvePath("markdown.strong"),
        horizontalRule: try resolvePath("markdown.horizontalRule"),
        listItem: try resolvePath("markdown.listItem"),
        listEnumeration: try resolvePath("markdown.listEnumeration"),
        image: try resolvePath("markdown.image"),
        imageText: try resolvePath("markdown.imageText"),
        codeBlock: try resolvePath("markdown.codeBlock")
    )

    return ResolvedThemeTokens(
        hue: hue,
        categorical: categorical,
        text: text,
        background: background,
        border: border,
        scrollbar: scrollbar,
        diff: diff,
        syntax: syntax,
        markdown: markdown,
        hueIndex: hueIndex
    )
}

// MARK: - SyntaxStyle Generation (`packages/theme/src/tui/syntax.ts`)

/// Generates an `OpenTUICore.SyntaxStyle` table from a resolved semantic theme token set.
// parity: theme/src/tui/syntax.ts#generateSyntax [status=implemented hash=24c6c8a18ec7]
public func generateSyntax(_ theme: ResolvedThemeTokens) -> SyntaxStyle {
    let step = HueStep.s200
    let syntax = theme.syntax
    let markdown = theme.markdown
    let feedback = theme.text.feedback

    func rule(
        _ scope: [String],
        _ foreground: RGBA,
        background: RGBA? = nil,
        bold: Bool? = nil,
        italic: Bool? = nil,
        underline: Bool? = nil
    ) -> ThemeTokenStyle {
        ThemeTokenStyle(
            scope: scope,
            style: ThemeTokenStyle.Style(
                foreground: .rgba(foreground),
                background: background.map { .rgba($0) },
                bold: bold,
                italic: italic,
                underline: underline
            )
        )
    }

    let firstCategorical = theme.categorical[0]
    let secondCategorical = theme.categorical.count > 1 ? theme.categorical[1] : firstCategorical

    let rules: [ThemeTokenStyle] = [
        rule(["default"], theme.text.base),
        rule(["prompt"], theme.hue.accent[step]),
        rule(["extmark.file"], feedback.warning.base, bold: true),
        rule(["extmark.agent"], firstCategorical[step], bold: true),
        rule(["extmark.skill"], secondCategorical[step], bold: true),
        rule(
            ["extmark.paste"],
            theme.background.base.a == 1 ? theme.background.base : theme.text.action.primary.focused,
            background: feedback.warning.base,
            bold: true
        ),
        rule(["comment", "comment.documentation"], syntax.comment, italic: true),
        rule(["string", "symbol", "character.special", "character"], syntax.string),
        rule(["number", "boolean", "constant", "float"], syntax.number),
        rule(["keyword.return", "keyword.conditional", "keyword.repeat", "keyword.coroutine"], syntax.keyword, italic: true),
        rule(["keyword.type"], syntax.type, bold: true, italic: true),
        rule(["keyword.function", "function.method"], syntax.function),
        rule(["keyword"], syntax.keyword, italic: true),
        rule(["keyword.import", "string.escape", "string.regexp", "tag.attribute", "keyword.export"], syntax.keyword),
        rule(["operator", "keyword.operator", "punctuation.delimiter", "keyword.conditional.ternary"], syntax.operator),
        rule(
            ["variable", "variable.parameter", "function.method.call", "function.call", "property", "parameter", "field"],
            syntax.variable
        ),
        rule(["variable.member", "function", "constructor"], syntax.function),
        rule(["type", "module", "class", "namespace"], syntax.type),
        rule(["type.definition"], syntax.type, bold: true),
        rule(["punctuation", "punctuation.bracket"], syntax.punctuation),
        rule(
            ["variable.builtin", "type.builtin", "function.builtin", "module.builtin", "constant.builtin", "variable.super"],
            feedback.error.base
        ),
        rule(["keyword.directive", "keyword.modifier", "keyword.exception"], syntax.keyword, italic: true),
        rule(["punctuation.special", "tag.delimiter"], syntax.operator),
        rule(
            [
                "markup.heading",
                "markup.heading.2",
                "markup.heading.3",
                "markup.heading.4",
                "markup.heading.5",
                "markup.heading.6",
            ],
            markdown.heading,
            bold: true
        ),
        rule(["markup.heading.1"], markdown.heading, bold: true, underline: true),
        rule(["markup.bold", "markup.strong"], markdown.strong, bold: true),
        rule(["markup.italic"], markdown.emphasis, italic: true),
        rule(["markup.list"], markdown.listItem),
        rule(["markup.quote"], markdown.blockQuote, italic: true),
        rule(["markup.raw", "markup.raw.block"], markdown.code),
        rule(["markup.raw.inline"], markdown.code, background: theme.background.base),
        rule(["markup.link", "markup.link.url", "string.special", "string.special.url"], markdown.link, underline: true),
        rule(["markup.link.label"], markdown.linkText, underline: true),
        rule(["label"], markdown.linkText),
        rule(["spell", "nospell"], theme.text.base),
        rule(["markup.underline"], theme.text.base, underline: true),
        rule(["comment.error"], feedback.error.base, bold: true, italic: true),
        rule(["comment.warning"], feedback.warning.base, bold: true, italic: true),
        rule(["comment.todo", "comment.note"], feedback.info.base, bold: true, italic: true),
        rule(["attribute", "annotation"], feedback.warning.base),
        rule(["tag"], feedback.error.base),
        rule(["markup.strikethrough", "markup.list.unchecked", "debug"], theme.text.muted),
        rule(["markup.list.checked"], feedback.success.base),
        rule(["diff.plus"], theme.diff.text.added, background: theme.diff.background.added),
        rule(["diff.minus"], theme.diff.text.removed, background: theme.diff.background.removed),
        rule(["diff.delta"], theme.diff.text.context, background: theme.diff.background.context),
        rule(["error"], feedback.error.base, bold: true),
        rule(["warning"], feedback.warning.base, bold: true),
        rule(["info"], feedback.info.base),
    ]
    return SyntaxStyle.fromTheme(rules)
}

/// Convenience overload accepting `ResolvedTheme`.
public func generateSyntax(_ theme: ResolvedTheme) -> SyntaxStyle {
    generateSyntax(theme.tokens)
}
