#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(CRT)
import CRT
#elseif canImport(WASILibc)
import WASILibc
#endif
import OpenTUICore

// MARK: - OKLCH Color Space (`packages/theme/src/tui/color.ts`)

/// Perceptually uniform OKLCH color representation (`l` in `0...1`, `c >= 0`, `h` in `0..<360`).
public struct OklchColor: Equatable, Hashable, Sendable, Codable {
    public var l: Double
    public var c: Double
    public var h: Double

    public init(l: Double, c: Double, h: Double) {
        self.l = l
        self.c = c
        self.h = h
    }
}

@inline(__always)
private func clampDouble(_ value: Double, _ low: Double, _ high: Double) -> Double {
    max(low, min(high, value))
}

@inline(__always)
private func wrapHue(_ value: Double) -> Double {
    let mod = value.truncatingRemainder(dividingBy: 360.0)
    let wrapped = (mod + 360.0).truncatingRemainder(dividingBy: 360.0)
    return wrapped == 0 ? 0 : wrapped
}

@inline(__always)
private func linearToSrgb(_ value: Double) -> Double {
    if value <= 0.0031308 { return value * 12.92 }
    return 1.055 * pow(value, 1.0 / 2.4) - 0.055
}

@inline(__always)
private func srgbToLinear(_ value: Double) -> Double {
    if value <= 0.04045 { return value / 12.92 }
    return pow((value + 0.055) / 1.055, 2.4)
}

@inline(__always)
private func jsRoundByte(_ value: Double) -> Int {
    Int((value + 0.5).rounded(.down))
}

/// Converts normalized sRGB channels (`0...1`) into OKLCH.
// parity: theme/src/tui/color.ts#rgbToOklch [status=implemented hash=78e1cb80eb84]
public func rgbToOklch(_ red: Double, _ green: Double, _ blue: Double) -> OklchColor {
    let linearRed = srgbToLinear(red)
    let linearGreen = srgbToLinear(green)
    let linearBlue = srgbToLinear(blue)
    let lRoot = cbrt(0.4122214708 * linearRed + 0.5363325363 * linearGreen + 0.0514459929 * linearBlue)
    let mRoot = cbrt(0.2119034982 * linearRed + 0.6806995451 * linearGreen + 0.1073969566 * linearBlue)
    let sRoot = cbrt(0.0883024619 * linearRed + 0.2817188376 * linearGreen + 0.6299787005 * linearBlue)
    let lightness = 0.2104542553 * lRoot + 0.793617785 * mRoot - 0.0040720468 * sRoot
    let a = 1.9779984951 * lRoot - 2.428592205 * mRoot + 0.4505937099 * sRoot
    let b = 0.0259040371 * lRoot + 0.7827717662 * mRoot - 0.808675766 * sRoot
    let chroma = sqrt(a * a + b * b)
    let angle = atan2(b, a) * (180.0 / Double.pi)
    return OklchColor(l: lightness, c: chroma, h: angle < 0 ? angle + 360.0 : angle)
}

private func oklchToRgb(_ color: OklchColor) -> (r: Double, g: Double, b: Double) {
    let radians = (color.h * Double.pi) / 180.0
    let a = color.c * cos(radians)
    let b = color.c * sin(radians)
    let lRoot = color.l + 0.3963377774 * a + 0.2158037573 * b
    let mRoot = color.l - 0.1055613458 * a - 0.0638541728 * b
    let sRoot = color.l - 0.0894841775 * a - 1.291485548 * b
    let l = lRoot * lRoot * lRoot
    let m = mRoot * mRoot * mRoot
    let s = sRoot * sRoot * sRoot
    return (
        r: linearToSrgb(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
        g: linearToSrgb(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
        b: linearToSrgb(-0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s)
    )
}

private func fitOklch(_ color: OklchColor) -> OklchColor {
    let base = OklchColor(l: clampDouble(color.l, 0, 1), c: max(0, color.c), h: wrapHue(color.h))
    let rgb = oklchToRgb(base)
    if rgb.r >= 0 && rgb.r <= 1 && rgb.g >= 0 && rgb.g <= 1 && rgb.b >= 0 && rgb.b <= 1 {
        return base
    }
    for index in 0..<24 {
        let next = OklchColor(l: base.l, c: base.c * pow(0.9, Double(index + 1)), h: base.h)
        let output = oklchToRgb(next)
        if output.r >= 0 && output.r <= 1 && output.g >= 0 && output.g <= 1 && output.b >= 0 && output.b <= 1 {
            return next
        }
    }
    return OklchColor(l: base.l, c: 0, h: base.h)
}

/// Converts an OKLCH color to a `#rrggbb` lowercase hex string with gamut fitting.
// parity: theme/src/tui/color.ts#oklchToHex [status=implemented hash=4641f6aea3ee]
public func oklchToHex(_ color: OklchColor) -> String {
    let rgb = oklchToRgb(fitOklch(color))
    let r = byte(jsRoundByte(clampDouble(rgb.r, 0, 1) * 255.0))
    let g = byte(jsRoundByte(clampDouble(rgb.g, 0, 1) * 255.0))
    let b = byte(jsRoundByte(clampDouble(rgb.b, 0, 1) * 255.0))
    return "#\(r)\(g)\(b)"
}

// MARK: - V1 Migration (`packages/theme/src/tui/v1-migrate.ts`)

/// Color key alias used by V1 theme migration.
// parity: theme/src/tui/v1-migrate.ts#ThemeColor [status=implemented hash=410e4b7935a5]
public typealias V1MigrateThemeColor = V1ThemeColor

/// Named chromatic hue families inferred during V1 migration.
public enum ChromaticHue: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
    case red
    case orange
    case yellow
    case green
    case cyan
    case blue
    case purple
}

/// Semantic V1 hue tokens used to infer categorical scales.
public enum V1HueToken: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
    case secondary
    case accent
    case success
    case warning
    case primary
    case error
    case info
}

/// Result of `inferHues(_:)`, mapping inferred chromatic hues and source V1 tokens.
public struct InferredHues: Equatable, Sendable {
    public struct Match: Equatable, Sendable {
        public let color: RGBA
        public let distance: Double

        public init(color: RGBA, distance: Double) {
            self.color = color
            self.distance = distance
        }
    }

    public var byHue: [ChromaticHue: Match]
    public var byToken: [V1HueToken: ChromaticHue]

    public init(byHue: [ChromaticHue: Match] = [:], byToken: [V1HueToken: ChromaticHue] = [:]) {
        self.byHue = byHue
        self.byToken = byToken
    }
}

/// Ordered list of chromatic hue families used during V1 migration.
// parity: theme/src/tui/v1-migrate.ts#chromaticHues [status=implemented hash=f8e35912685b]
public let chromaticHues: [ChromaticHue] = [.red, .orange, .yellow, .green, .cyan, .blue, .purple]

/// Priority-ordered V1 tokens mapped into categorical hues.
// parity: theme/src/tui/v1-migrate.ts#categoricalTokens [status=implemented hash=93a72f21bd69]
public let categoricalTokens: [V1HueToken] = [.secondary, .accent, .success, .warning, .primary, .error, .info]

private let minimumChroma = 0.03
private let lightThreshold = 0.6

private let lightHueAngles: [ChromaticHue: Double] = [
    .red: toOklch(RGBA.fromHex("#fca5a5")).h,
    .orange: toOklch(RGBA.fromHex("#fdba74")).h,
    .yellow: toOklch(RGBA.fromHex("#fde047")).h,
    .green: toOklch(RGBA.fromHex("#86efac")).h,
    .cyan: toOklch(RGBA.fromHex("#67e8f9")).h,
    .blue: toOklch(RGBA.fromHex("#93c5fd")).h,
    .purple: toOklch(RGBA.fromHex("#d8b4fe")).h,
]

private let darkHueAngles: [ChromaticHue: Double] = [
    .red: toOklch(RGBA.fromHex("#b91c1c")).h,
    .orange: toOklch(RGBA.fromHex("#c2410c")).h,
    .yellow: toOklch(RGBA.fromHex("#a16207")).h,
    .green: toOklch(RGBA.fromHex("#15803d")).h,
    .cyan: toOklch(RGBA.fromHex("#0e7490")).h,
    .blue: toOklch(RGBA.fromHex("#1d4ed8")).h,
    .purple: toOklch(RGBA.fromHex("#7e22ce")).h,
]

/// Migrates a legacy V1 JSON theme into a V2 `ThemeDocument`.
// parity: theme/src/tui/v1-migrate.ts#migrateV1 [status=implemented hash=f9691ed5b5d4]
public func migrateV1(_ theme: ThemeV1Json) throws -> ThemeDocument {
    let light = try resolveV1(theme, mode: .light)
    let dark = try resolveV1(theme, mode: .dark)
    if light.background.a > 0 && dark.background.a > 0 && light.background.equals(dark.background) {
        let lightMode = detectMode(light)
        let darkMode = detectMode(dark)
        if lightMode == darkMode {
            let definition = migrateModeV1(lightMode == .light ? light : dark, mode: lightMode)
            if lightMode == .light {
                return ThemeDocument(base: themeBase(definition), light: ModeDefinition(hue: definition.hue))
            }
            return ThemeDocument(base: themeBase(definition), dark: ModeDefinition(hue: definition.hue))
        }
    }
    let lightDefinition = migrateModeV1(light, mode: .light)
    let darkDefinition = migrateModeV1(dark, mode: .dark)
    return ThemeDocument(
        base: themeBase(lightDefinition),
        light: ModeDefinition(hue: lightDefinition.hue),
        dark: ModeDefinition(from: darkDefinition)
    )
}

/// Extracts the `BaseThemeDefinition` (everything except `hue`) from a `ThemeDefinition`.
// parity: theme/src/tui/v1-migrate.ts#base [status=implemented hash=e7dd3de26b24]
public func themeBase(_ definition: ThemeDefinition) -> BaseThemeDefinition {
    BaseThemeDefinition(
        categorical: definition.categorical,
        text: definition.text,
        background: definition.background,
        border: definition.border,
        scrollbar: definition.scrollbar,
        diff: definition.diff,
        syntax: definition.syntax,
        markdown: definition.markdown,
        dialog: definition.dialog
    )
}

/// Detects whether a resolved V1 theme is light or dark from text vs background luma.
// parity: theme/src/tui/v1-migrate.ts#detectMode [status=implemented hash=742491ba806b]
public func detectMode(_ theme: V1Theme) -> Mode {
    v1Luminance(theme.text) > v1Luminance(theme.background) ? .dark : .light
}

private func v1Luminance(_ color: RGBA) -> Double {
    0.299 * color.r + 0.587 * color.g + 0.114 * color.b
}

private func migrateModeV1(_ theme: V1Theme, mode: Mode) -> ThemeDefinition {
    func color(_ key: V1ThemeColor) -> String { hex(theme[key]) }
    let selected = hex(selectedForeground(theme, background: theme.primary))
    let destructive = hex(selectedForeground(theme, background: theme.error))
    let hues = inferHues(theme)
    var uniqueCategorical: [String] = []
    for token in categoricalTokens {
        if let h = hues.byToken[token]?.rawValue, !uniqueCategorical.contains(h) {
            uniqueCategorical.append(h)
        }
    }
    let text = "$hue.neutral.200"
    let textMuted = "$hue.neutral.400"
    let primary = "$hue.interactive.200"
    let background = "$hue.neutral.800"
    let backgroundPanel = "$hue.neutral.700"
    let backgroundMenu = "$hue.neutral.600"
    let backgroundRaisedMax = "$hue.neutral.500"

    var hueValues: [HueName: HueValueDefinition] = ["gray": .scale(neutralScaleV1(theme))]
    var hueOrder: [HueName] = ["gray"]
    for name in chromaticHues {
        if let match = hues.byHue[name] {
            hueValues[name.rawValue] = .scale(hueScaleV1(match.color, mode: mode))
            hueOrder.append(name.rawValue)
        }
    }
    hueValues["accent"] = .alias(hues.byToken[.accent].map { "$hue.\($0.rawValue)" } ?? "$hue.gray")
    hueValues["interactive"] = .alias(hues.byToken[.primary].map { "$hue.\($0.rawValue)" } ?? "$hue.gray")
    hueValues["neutral"] = .alias("$hue.gray")
    hueOrder.append(contentsOf: ["accent", "interactive", "neutral"])

    let definition = ThemeDefinition(
        hue: HueDefinition(hueValues, keyOrder: hueOrder),
        categorical: uniqueCategorical.isEmpty ? ["neutral"] : uniqueCategorical,
        text: TextDefinition(
            base: text,
            muted: textMuted,
            action: ActionColorDefinition(
                primary: StatefulColorDefinition(
                    base: "$text.base",
                    focused: selected,
                    selected: primary,
                    disabled: textMuted
                ),
                secondary: StatefulColorDefinition(
                    base: "$text.muted",
                    hovered: "$text.base"
                ),
                destructive: StatefulColorDefinition(
                    base: destructive,
                    disabled: textMuted
                )
            ),
            formfield: StatefulColorDefinition(
                base: text,
                hovered: primary,
                focused: primary,
                pressed: primary,
                selected: primary,
                disabled: textMuted
            ),
            feedback: TextFeedbackDefinition(
                error: TextFeedbackItemDefinition(base: color(.error)),
                warning: TextFeedbackItemDefinition(base: color(.warning)),
                success: TextFeedbackItemDefinition(base: color(.success)),
                info: TextFeedbackItemDefinition(base: color(.info))
            )
        ),
        background: BackgroundDefinition(
            base: background,
            raised: RaisedBackgroundDefinition(
                base: backgroundPanel,
                high: backgroundMenu,
                max: backgroundRaisedMax
            ),
            action: ActionColorDefinition(
                primary: StatefulColorDefinition(
                    base: "transparent",
                    hovered: backgroundPanel,
                    focused: primary,
                    selected: "transparent"
                ),
                secondary: StatefulColorDefinition(base: "transparent"),
                destructive: StatefulColorDefinition(base: color(.error))
            ),
            formfield: StatefulColorDefinition(base: "$background.base"),
            feedback: BackgroundFeedbackDefinition(
                error: BackgroundFeedbackItemDefinition(base: "$background.base"),
                warning: BackgroundFeedbackItemDefinition(base: "$background.base"),
                success: BackgroundFeedbackItemDefinition(base: "$background.base"),
                info: BackgroundFeedbackItemDefinition(base: "$background.base")
            )
        ),
        border: SingleColorDefinition(base: color(.border)),
        scrollbar: SingleColorDefinition(base: color(.borderActive)),
        diff: DiffDefinition(
            text: DiffDefinition.Text(
                added: color(.diffAdded),
                removed: color(.diffRemoved),
                context: color(.diffContext),
                hunkHeader: color(.diffHunkHeader)
            ),
            background: DiffDefinition.Background(
                added: color(.diffAddedBg),
                removed: color(.diffRemovedBg),
                context: color(.diffContextBg)
            ),
            highlight: DiffDefinition.Highlight(
                added: color(.diffHighlightAdded),
                removed: color(.diffHighlightRemoved)
            ),
            lineNumber: DiffDefinition.LineNumber(
                text: color(.diffLineNumber),
                background: DiffDefinition.LineNumber.LineNumberBackground(
                    added: color(.diffAddedLineNumberBg),
                    removed: color(.diffRemovedLineNumberBg)
                )
            )
        ),
        syntax: [
            .comment: color(.syntaxComment),
            .keyword: color(.syntaxKeyword),
            .function: color(.syntaxFunction),
            .variable: color(.syntaxVariable),
            .string: color(.syntaxString),
            .number: color(.syntaxNumber),
            .type: color(.syntaxType),
            .operator: color(.syntaxOperator),
            .punctuation: color(.syntaxPunctuation),
        ],
        markdown: [
            .text: color(.markdownText),
            .heading: color(.markdownHeading),
            .link: color(.markdownLink),
            .linkText: color(.markdownLinkText),
            .code: color(.markdownCode),
            .blockQuote: color(.markdownBlockQuote),
            .emphasis: color(.markdownEmph),
            .strong: color(.markdownStrong),
            .horizontalRule: color(.markdownHorizontalRule),
            .listItem: color(.markdownListItem),
            .listEnumeration: color(.markdownListEnumeration),
            .image: color(.markdownImage),
            .imageText: color(.markdownImageText),
            .codeBlock: color(.markdownCodeBlock),
        ],
        dialog: DialogTokensDefinition(
            background: BackgroundDefinition(
                base: dialogBackground(theme),
                action: ActionColorDefinition(
                    primary: StatefulColorDefinition(hovered: "$background.raised.high")
                )
            )
        )
    )
    return referenceHues(definition)
}

/// Computes an opaque dialog surface background color token for a V1 theme.
// parity: theme/src/tui/v1-migrate.ts#dialogBackground [status=implemented hash=0718935323d2]
public func dialogBackground(_ theme: V1Theme) -> String {
    if theme.backgroundPanel.a == 1 { return "$background.raised.base" }
    let candidates = [theme.backgroundPanel, theme.backgroundMenu, theme.backgroundElement, theme.background]
    guard let visible = candidates.first(where: { $0.a > 0 }) else {
        return v1Luminance(theme.text) > 0.5 ? "#000000" : "#ffffff"
    }
    let (red, green, blue, _) = visible.toInts()
    return hexInts(Int(red), Int(green), Int(blue), 255)
}

/// Replaces literal hex tokens in a `ThemeDefinition` with matching `$hue.<name>.<step>` references.
// parity: theme/src/tui/v1-migrate.ts#referenceHues [status=implemented hash=c9cfe2876e58]
public func referenceHues(_ theme: ThemeDefinition) -> ThemeDefinition {
    let definitions = theme.hue.values
    var scales: [String: [HueStep: String]] = [:]

    func resolve(_ name: String, chain: [String] = []) -> [HueStep: String]? {
        if let cached = scales[name] { return cached }
        if chain.contains(name) { return nil }
        guard let value = definitions[name] else { return nil }
        switch value {
        case .scale(let map):
            scales[name] = map
            return map
        case .alias(let ref):
            guard ref.hasPrefix("$hue.") else { return nil }
            let target = String(ref.dropFirst(5))
            guard !target.isEmpty, !target.contains(".") else { return nil }
            guard let resolved = resolve(target, chain: chain + [name]) else { return nil }
            scales[name] = resolved
            return resolved
        }
    }

    var references: [String: String] = [:]
    func index(_ name: String, overwrite: Bool) {
        guard let scale = resolve(name) else { return }
        for step in HueStep.literals {
            guard let color = scale[step] else { continue }
            let lower = color.lowercased()
            if !overwrite && references[lower] != nil { continue }
            references[lower] = "$hue.\(name).\(step.rawValue)"
        }
    }

    for name in chromaticHues { index(name.rawValue, overwrite: false) }
    index("gray", overwrite: false)
    index("accent", overwrite: true)
    index("interactive", overwrite: true)
    index("neutral", overwrite: true)

    func replace(_ value: String?) -> String? {
        guard let value else { return nil }
        return references[value.lowercased()] ?? value
    }

    func replaceStateful(_ s: StatefulColorDefinition?) -> StatefulColorDefinition? {
        guard let s else { return nil }
        return StatefulColorDefinition(
            base: replace(s.base),
            hovered: replace(s.hovered),
            focused: replace(s.focused),
            pressed: replace(s.pressed),
            selected: replace(s.selected),
            disabled: replace(s.disabled)
        )
    }

    func replaceActions(_ a: ActionColorDefinition?) -> ActionColorDefinition? {
        guard let a else { return nil }
        return ActionColorDefinition(
            primary: replaceStateful(a.primary),
            secondary: replaceStateful(a.secondary),
            destructive: replaceStateful(a.destructive)
        )
    }

    func replaceText(_ t: TextDefinition?) -> TextDefinition? {
        guard let t else { return nil }
        return TextDefinition(
            base: replace(t.base),
            muted: replace(t.muted),
            faint: replace(t.faint),
            action: replaceActions(t.action),
            formfield: replaceStateful(t.formfield),
            feedback: t.feedback.map { fb in
                TextFeedbackDefinition(
                    error: fb.error.map { TextFeedbackItemDefinition(base: replace($0.base), muted: replace($0.muted)) },
                    warning: fb.warning.map { TextFeedbackItemDefinition(base: replace($0.base), muted: replace($0.muted)) },
                    success: fb.success.map { TextFeedbackItemDefinition(base: replace($0.base), muted: replace($0.muted)) },
                    info: fb.info.map { TextFeedbackItemDefinition(base: replace($0.base), muted: replace($0.muted)) }
                )
            }
        )
    }

    func replaceBackground(_ b: BackgroundDefinition?) -> BackgroundDefinition? {
        guard let b else { return nil }
        return BackgroundDefinition(
            base: replace(b.base),
            raised: b.raised.map {
                RaisedBackgroundDefinition(base: replace($0.base), high: replace($0.high), max: replace($0.max))
            },
            action: replaceActions(b.action),
            formfield: replaceStateful(b.formfield),
            feedback: b.feedback.map { fb in
                BackgroundFeedbackDefinition(
                    error: fb.error.map { BackgroundFeedbackItemDefinition(base: replace($0.base)) },
                    warning: fb.warning.map { BackgroundFeedbackItemDefinition(base: replace($0.base)) },
                    success: fb.success.map { BackgroundFeedbackItemDefinition(base: replace($0.base)) },
                    info: fb.info.map { BackgroundFeedbackItemDefinition(base: replace($0.base)) }
                )
            }
        )
    }

    func replaceSingle(_ s: SingleColorDefinition?) -> SingleColorDefinition? {
        s.map { SingleColorDefinition(base: replace($0.base)) }
    }

    func replaceDiff(_ d: DiffDefinition?) -> DiffDefinition? {
        guard let d else { return nil }
        return DiffDefinition(
            text: d.text.map {
                DiffDefinition.Text(
                    added: replace($0.added),
                    removed: replace($0.removed),
                    context: replace($0.context),
                    hunkHeader: replace($0.hunkHeader)
                )
            },
            background: d.background.map {
                DiffDefinition.Background(
                    added: replace($0.added),
                    removed: replace($0.removed),
                    context: replace($0.context)
                )
            },
            highlight: d.highlight.map {
                DiffDefinition.Highlight(added: replace($0.added), removed: replace($0.removed))
            },
            lineNumber: d.lineNumber.map { ln in
                DiffDefinition.LineNumber(
                    text: replace(ln.text),
                    background: ln.background.map {
                        DiffDefinition.LineNumber.LineNumberBackground(
                            added: replace($0.added),
                            removed: replace($0.removed)
                        )
                    }
                )
            }
        )
    }

    func replaceSyntax(_ s: SyntaxDefinition?) -> SyntaxDefinition? {
        s.map { dict in
            var out: SyntaxDefinition = [:]
            for (k, v) in dict {
                out[k] = references[v.lowercased()] ?? v
            }
            return out
        }
    }

    func replaceMarkdown(_ m: MarkdownDefinition?) -> MarkdownDefinition? {
        m.map { dict in
            var out: MarkdownDefinition = [:]
            for (k, v) in dict {
                out[k] = references[v.lowercased()] ?? v
            }
            return out
        }
    }

    func replaceTokens(_ tok: ThemeTokensDefinition?) -> ThemeTokensDefinition? {
        guard let tok else { return nil }
        return ThemeTokensDefinition(
            text: replaceText(tok.text),
            background: replaceBackground(tok.background),
            border: replaceSingle(tok.border),
            scrollbar: replaceSingle(tok.scrollbar),
            diff: replaceDiff(tok.diff),
            syntax: replaceSyntax(tok.syntax),
            markdown: replaceMarkdown(tok.markdown)
        )
    }

    func replaceDialog(_ dlg: DialogTokensDefinition?) -> DialogTokensDefinition? {
        guard let dlg else { return nil }
        return DialogTokensDefinition(
            text: replaceText(dlg.text),
            background: replaceBackground(dlg.background),
            border: replaceSingle(dlg.border),
            scrollbar: replaceSingle(dlg.scrollbar),
            diff: replaceDiff(dlg.diff),
            syntax: replaceSyntax(dlg.syntax),
            markdown: replaceMarkdown(dlg.markdown),
            footer: replaceTokens(dlg.footer)
        )
    }

    return ThemeDefinition(
        hue: theme.hue,
        categorical: theme.categorical,
        text: replaceText(theme.text) ?? theme.text,
        background: replaceBackground(theme.background) ?? theme.background,
        border: replaceSingle(theme.border) ?? theme.border,
        scrollbar: replaceSingle(theme.scrollbar) ?? theme.scrollbar,
        diff: replaceDiff(theme.diff) ?? theme.diff,
        syntax: replaceSyntax(theme.syntax) ?? theme.syntax,
        markdown: replaceMarkdown(theme.markdown) ?? theme.markdown,
        dialog: replaceDialog(theme.dialog)
    )
}

/// Classifies V1 semantic accent/status colors into the nearest canonical chromatic hue families.
// parity: theme/src/tui/v1-migrate.ts#inferHues [status=implemented hash=c059b4aa50bf]
public func inferHues(_ theme: V1Theme) -> InferredHues {
    let colors: [(V1HueToken, RGBA)] = [
        (.accent, theme.accent),
        (.success, theme.success),
        (.warning, theme.warning),
        (.primary, theme.primary),
        (.error, theme.error),
        (.info, theme.info),
        (.secondary, theme.secondary),
    ]
    var result = InferredHues()
    for (token, color) in colors {
        guard let nearest = inferSingleHue(color) else { continue }
        if let current = result.byHue[nearest.name], current.distance <= nearest.distance {
            // keep closer match
        } else {
            result.byHue[nearest.name] = InferredHues.Match(color: color, distance: nearest.distance)
        }
        result.byToken[token] = nearest.name
    }
    let priority: [(V1HueToken, RGBA)] = [
        (.accent, theme.accent),
        (.primary, theme.primary),
    ]
    for (token, color) in priority {
        guard let nearest = inferSingleHue(color) else { continue }
        result.byHue[nearest.name] = InferredHues.Match(color: color, distance: nearest.distance)
        result.byToken[token] = nearest.name
    }
    return result
}

private func inferSingleHue(_ color: RGBA) -> (name: ChromaticHue, distance: Double)? {
    let value = toOklch(color)
    if isAmbiguousChroma(color, chroma: value.c) { return nil }
    let reference = value.l >= lightThreshold ? lightHueAngles : darkHueAngles
    var best: (name: ChromaticHue, distance: Double)? = nil
    for name in chromaticHues {
        let dist = hueDistance(value.h, reference[name]!)
        if best == nil || dist < best!.distance {
            best = (name, dist)
        }
    }
    return best
}

private func hueDistance(_ first: Double, _ second: Double) -> Double {
    let difference = abs(first - second)
    return min(difference, 360.0 - difference)
}

private func isAmbiguousChroma(_ color: RGBA, chroma: Double) -> Bool {
    color.toInts().3 == 0 || chroma < minimumChroma
}

/// Resolves a V1 JSON theme definition for `mode` (`light` or `dark`) into a concrete `V1Theme`.
// parity: theme/src/tui/v1-migrate.ts#resolveV1 [status=implemented hash=7aadead5a760]
public func resolveV1(_ theme: ThemeV1Json, mode: Mode) throws -> V1Theme {
    let defs = theme.defs ?? [:]

    func resolveColor(_ value: V1ColorValue, chain: [String] = []) throws -> RGBA {
        switch value {
        case .rgba(let rgba):
            return rgba
        case .ansi(let code):
            return ansiColorV1(code)
        case .variant(let variant):
            let selected = mode == .dark ? variant.dark : variant.light
            return try resolveColor(.string(selected), chain: chain)
        case .string(let str):
            if str == "transparent" || str == "none" {
                return RGBA.fromInts(0, 0, 0, 0)
            }
            if str.hasPrefix("#") {
                return RGBA.fromHex(str)
            }
            if chain.contains(str) {
                throw ThemeError("Circular color reference: \((chain + [str]).joined(separator: " -> "))")
            }
            if let defTarget = defs[str] {
                return try resolveColor(.string(defTarget), chain: chain + [str])
            }
            if let token = V1ThemeColor(rawValue: str), let next = theme.theme[token] {
                return try resolveColor(next, chain: chain + [str])
            }
            throw ThemeError("Color reference \"\(str)\" not found in defs or theme")
        }
    }

    var resolved: [V1ThemeColor: RGBA] = [:]
    for colorKey in V1ThemeColor.allCases {
        if colorKey == .selectedListItemText || colorKey == .backgroundMenu { continue }
        guard let value = theme.theme[colorKey] else {
            throw ThemeError("Missing required V1 theme color \"\(colorKey.rawValue)\"")
        }
        resolved[colorKey] = try resolveColor(value)
    }

    let hasSelectedListItemText = theme.theme[.selectedListItemText] != nil
    let selectedListItemText: RGBA
    if let val = theme.theme[.selectedListItemText] {
        selectedListItemText = try resolveColor(val)
    } else {
        selectedListItemText = resolved[.background]!
    }

    let backgroundMenu: RGBA
    if let val = theme.theme[.backgroundMenu] {
        backgroundMenu = try resolveColor(val)
    } else {
        backgroundMenu = resolved[.backgroundElement]!
    }

    return V1Theme(
        primary: resolved[.primary]!,
        secondary: resolved[.secondary]!,
        accent: resolved[.accent]!,
        error: resolved[.error]!,
        warning: resolved[.warning]!,
        success: resolved[.success]!,
        info: resolved[.info]!,
        text: resolved[.text]!,
        textMuted: resolved[.textMuted]!,
        selectedListItemText: selectedListItemText,
        background: resolved[.background]!,
        backgroundPanel: resolved[.backgroundPanel]!,
        backgroundElement: resolved[.backgroundElement]!,
        backgroundMenu: backgroundMenu,
        border: resolved[.border]!,
        borderActive: resolved[.borderActive]!,
        borderSubtle: resolved[.borderSubtle]!,
        diffAdded: resolved[.diffAdded]!,
        diffRemoved: resolved[.diffRemoved]!,
        diffContext: resolved[.diffContext]!,
        diffHunkHeader: resolved[.diffHunkHeader]!,
        diffHighlightAdded: resolved[.diffHighlightAdded]!,
        diffHighlightRemoved: resolved[.diffHighlightRemoved]!,
        diffAddedBg: resolved[.diffAddedBg]!,
        diffRemovedBg: resolved[.diffRemovedBg]!,
        diffContextBg: resolved[.diffContextBg]!,
        diffLineNumber: resolved[.diffLineNumber]!,
        diffAddedLineNumberBg: resolved[.diffAddedLineNumberBg]!,
        diffRemovedLineNumberBg: resolved[.diffRemovedLineNumberBg]!,
        markdownText: resolved[.markdownText]!,
        markdownHeading: resolved[.markdownHeading]!,
        markdownLink: resolved[.markdownLink]!,
        markdownLinkText: resolved[.markdownLinkText]!,
        markdownCode: resolved[.markdownCode]!,
        markdownBlockQuote: resolved[.markdownBlockQuote]!,
        markdownEmph: resolved[.markdownEmph]!,
        markdownStrong: resolved[.markdownStrong]!,
        markdownHorizontalRule: resolved[.markdownHorizontalRule]!,
        markdownListItem: resolved[.markdownListItem]!,
        markdownListEnumeration: resolved[.markdownListEnumeration]!,
        markdownImage: resolved[.markdownImage]!,
        markdownImageText: resolved[.markdownImageText]!,
        markdownCodeBlock: resolved[.markdownCodeBlock]!,
        syntaxComment: resolved[.syntaxComment]!,
        syntaxKeyword: resolved[.syntaxKeyword]!,
        syntaxFunction: resolved[.syntaxFunction]!,
        syntaxVariable: resolved[.syntaxVariable]!,
        syntaxString: resolved[.syntaxString]!,
        syntaxNumber: resolved[.syntaxNumber]!,
        syntaxType: resolved[.syntaxType]!,
        syntaxOperator: resolved[.syntaxOperator]!,
        syntaxPunctuation: resolved[.syntaxPunctuation]!,
        thinkingOpacity: theme.thinkingOpacity ?? 0.6,
        _hasSelectedListItemText: hasSelectedListItemText
    )
}

/// Computes the foreground color to render on top of a selected/accented `background` in a V1 theme.
// parity: theme/src/tui/v1-migrate.ts#selectedForeground [status=implemented hash=eac9bfb1d066]
public func selectedForeground(_ theme: V1Theme, background: RGBA) -> RGBA {
    if theme._hasSelectedListItemText { return theme.selectedListItemText }
    if theme.background.a != 0 { return theme.background }
    return (0.299 * background.r + 0.587 * background.g + 0.114 * background.b) > 0.5
        ? RGBA.fromInts(0, 0, 0)
        : RGBA.fromInts(255, 255, 255)
}

private func hueScaleV1(_ color: RGBA, mode: Mode) -> [HueStep: String] {
    let value = toOklch(color)
    let anchor = 200
    let endpoint = mode == .light ? max(0.97, value.l) : min(0.18, value.l)
    let alpha = Int(color.toInts().3)
    var out: [HueStep: String] = [:]
    for step in HueStep.literals {
        if step.rawValue == anchor {
            out[step] = hex(color)
        } else {
            let progress = Double(step.rawValue - anchor) / Double(900 - anchor)
            let generated = oklchToHex(
                OklchColor(
                    l: value.l + (endpoint - value.l) * progress,
                    c: value.c * (1.0 - progress * 0.5),
                    h: value.h
                )
            )
            out[step] = alpha == 255 ? generated : "\(generated)\(byte(alpha))"
        }
    }
    return out
}

private func neutralScaleV1(_ theme: V1Theme) -> [HueStep: String] {
    let anchors: [(step: HueStep, color: RGBA)] = [
        (.s200, theme.text),
        (.s400, theme.textMuted),
        (.s600, theme.backgroundElement),
        (.s700, theme.backgroundPanel),
        (.s800, theme.background),
    ]
    var out: [HueStep: String] = [:]
    for step in HueStep.literals {
        if let exact = anchors.first(where: { $0.step == step }) {
            out[step] = hex(exact.color)
            continue
        }
        let first = anchors[0]
        let last = anchors[anchors.count - 1]
        let lower: (step: HueStep, color: RGBA)
        let upper: (step: HueStep, color: RGBA)
        if step.rawValue < first.step.rawValue {
            lower = first
            upper = anchors[1]
        } else if step.rawValue > last.step.rawValue {
            lower = anchors[anchors.count - 2]
            upper = last
        } else {
            lower = anchors.last(where: { $0.step.rawValue < step.rawValue })!
            upper = anchors.first(where: { $0.step.rawValue > step.rawValue })!
        }
        let amount = Double(step.rawValue - lower.step.rawValue) / Double(upper.step.rawValue - lower.step.rawValue)
        out[step] = interpolateOklch(lower.color, upper.color, amount: amount)
    }
    return out
}

private func interpolateOklch(_ first: RGBA, _ second: RGBA, amount: Double) -> String {
    let start = toOklch(first)
    let end = toOklch(second)
    let startHue = start.h.isFinite ? start.h : (end.h.isFinite ? end.h : 0)
    let endHue = end.h.isFinite ? end.h : startHue
    let diff = (endHue - startHue).truncatingRemainder(dividingBy: 360.0)
    let deltaHue = (diff + 540.0).truncatingRemainder(dividingBy: 360.0) - 180.0
    let generated = oklchToHex(
        OklchColor(
            l: start.l + (end.l - start.l) * amount,
            c: start.c + (end.c - start.c) * amount,
            h: startHue + deltaHue * amount
        )
    )
    let a0 = Double(first.toInts().3)
    let a1 = Double(second.toInts().3)
    let alpha = max(0, min(255, jsRoundByte(a0 + (a1 - a0) * amount)))
    return alpha == 255 ? generated : "\(generated)\(byte(alpha))"
}

/// Converts an `OpenTUICore.RGBA` color into OKLCH.
// parity: theme/src/tui/v1-migrate.ts#toOklch [status=implemented hash=91ddb8444e40]
public func toOklch(_ color: RGBA) -> OklchColor {
    let (red, green, blue, _) = color.toInts()
    return rgbToOklch(Double(red) / 255.0, Double(green) / 255.0, Double(blue) / 255.0)
}

/// Formats an `OpenTUICore.RGBA` color as `#rrggbb` (or `#rrggbbaa` when `a != 255`).
// parity: theme/src/tui/v1-migrate.ts#hex [status=implemented hash=c1d65d3cda9b]
public func hex(_ color: RGBA) -> String {
    let (r, g, b, a) = color.toInts()
    return hexInts(Int(r), Int(g), Int(b), Int(a))
}

private func hexInts(_ r: Int, _ g: Int, _ b: Int, _ a: Int) -> String {
    "#\(byte(r))\(byte(g))\(byte(b))\(a == 255 ? "" : byte(a))"
}

private let lowerHexDigits: [UInt8] = Array("0123456789abcdef".utf8)

/// Formats an integer value as lowercase hexadecimal padded to at least 2 characters (`value.toString(16).padStart(2, "0")`).
// parity: theme/src/tui/v1-migrate.ts#byte [status=implemented hash=e096e963051b]
public func byte(_ value: Int) -> String {
    if value >= 0 && value <= 255 {
        return String(decoding: [lowerHexDigits[value >> 4], lowerHexDigits[value & 0x0F]], as: UTF8.self)
    }
    let hex = String(value, radix: 16, uppercase: false)
    if hex.count < 2 {
        return String(repeating: "0", count: 2 - hex.count) + hex
    }
    return hex
}

public func byte(_ value: UInt8) -> String {
    byte(Int(value))
}

private func ansiColorV1(_ code: Int) -> RGBA {
    if code >= 0 && code < 16 {
        let colors = [
            "#000000", "#800000", "#008000", "#808000",
            "#000080", "#800080", "#008080", "#c0c0c0",
            "#808080", "#ff0000", "#00ff00", "#ffff00",
            "#0000ff", "#ff00ff", "#00ffff", "#ffffff",
        ]
        return RGBA.fromHex(colors[code])
    }
    if code >= 16 && code < 232 {
        let index = code - 16
        func partValue(_ part: Int) -> Int { part == 0 ? 0 : part * 40 + 55 }
        return RGBA.fromInts(partValue(index / 36), partValue((index / 6) % 6), partValue(index % 6))
    }
    if code >= 232 && code < 256 {
        let gray = (code - 232) * 10 + 8
        return RGBA.fromInts(gray, gray, gray)
    }
    return RGBA.fromInts(0, 0, 0)
}

// MARK: - V1 New-Designs Migration (`packages/theme/src/tui/v1-migrate-new-designs.ts`)

private struct NewDesignProfile {
    let surface: [HueStep: Double]
    let text: [HueStep: Double]
    let hueLightness: [HueStep: Double]
    let hueChroma: [HueStep: Double]
    let hueMid: Double
    let readable: [HueStep: Double]
    let readableHue: [HueStep: Double]
}

private let newDesignDarkProfile = NewDesignProfile(
    surface: [.s900: 0, .s800: 0.039, .s700: 0.057, .s600: 0.11, .s500: 0.175, .s400: 0.253],
    text: [.s200: 0.719, .s300: 0.538],
    hueLightness: [.s100: -0.035, .s200: -0.023, .s300: -0.003, .s600: 0.095, .s700: 0.071, .s800: 0.024, .s900: 0.012],
    hueChroma: [.s100: 0.1, .s200: 0.24, .s300: 0.22, .s500: 0.64, .s600: 0.2, .s700: 0.14, .s800: 0.09, .s900: 0.07],
    hueMid: 0.55,
    readable: [.s800: 0.95, .s700: 0.92, .s600: 0.81, .s500: 0.66, .s900: 0.99],
    readableHue: [.s600: 0.7, .s700: 0.82, .s800: 0.92, .s900: 0.99]
)

private let newDesignLightProfile = NewDesignProfile(
    surface: [.s900: 0, .s800: -0.015, .s700: -0.039, .s600: -0.102, .s500: -0.145, .s400: -0.227],
    text: [.s200: 0.688, .s300: 0.484],
    hueLightness: [.s100: 0.083, .s200: 0.13, .s300: 0.116, .s600: 0.021, .s700: -0.002, .s800: -0.004, .s900: -0.008],
    hueChroma: [.s100: 0.19, .s200: 0.12, .s300: 0.16, .s500: 0.38, .s600: 0.17, .s700: 0.1, .s800: 0.05, .s900: 0.02],
    hueMid: 0.65,
    readable: [.s800: 0.96, .s700: 0.89, .s600: 0.74, .s500: 0.64, .s900: 0.97],
    readableHue: [.s600: 0.78, .s700: 0.88, .s800: 0.93, .s900: 0.97]
)

private let minimumSurfaceContrast = 4.5
private let maximumDimming = 0.6

private let newDesignLightDialog = DialogTokensDefinition(
    background: BackgroundDefinition(
        base: "$hue.neutral.800",
        raised: RaisedBackgroundDefinition(high: "$hue.neutral.700"),
        action: ActionColorDefinition(
            primary: StatefulColorDefinition(hovered: "$hue.neutral.600"),
            secondary: StatefulColorDefinition(hovered: "$hue.neutral.600")
        )
    )
)

/// Migrates a legacy V1 JSON theme onto the `opencode2` step layout with contrast-preserving dimming.
// parity: theme/src/tui/v1-migrate-new-designs.ts#migrateV1NewDesigns [status=implemented hash=69b9aae3549f]
public func migrateV1NewDesigns(_ theme: ThemeV1Json) throws -> ThemeDocument {
    let light = try resolveV1(theme, mode: .light)
    let dark = try resolveV1(theme, mode: .dark)
    if light.background.a > 0 && dark.background.a > 0 && light.background.equals(dark.background) {
        let lightMode = detectMode(light)
        let darkMode = detectMode(dark)
        if lightMode == darkMode {
            let definition = migrateModeNewDesigns(lightMode == .light ? light : dark, mode: lightMode)
            if lightMode == .light {
                return ThemeDocument(base: themeBase(definition), light: newDesignLightOverrides(definition, light))
            }
            return ThemeDocument(base: themeBase(definition), dark: ModeDefinition(hue: definition.hue))
        }
    }
    let lightDefinition = migrateModeNewDesigns(light, mode: .light)
    let darkDefinition = migrateModeNewDesigns(dark, mode: .dark)
    return ThemeDocument(
        base: themeBase(lightDefinition),
        light: newDesignLightOverrides(lightDefinition, light),
        dark: ModeDefinition(from: darkDefinition)
    )
}

private func newDesignLightOverrides(_ definition: ThemeDefinition, _ theme: V1Theme) -> ModeDefinition {
    if theme.backgroundPanel.a == 1 {
        return ModeDefinition(hue: definition.hue, dialog: newDesignLightDialog)
    }
    var dialog = newDesignLightDialog
    var bg = dialog.background ?? BackgroundDefinition()
    bg.base = dialogBackground(theme)
    dialog.background = bg
    return ModeDefinition(hue: definition.hue, dialog: dialog)
}

private func wcagContrast(_ first: RGBA, _ second: RGBA) -> Double {
    func relLum(_ color: RGBA) -> Double {
        func channel(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(color.r) + 0.7152 * channel(color.g) + 0.0722 * channel(color.b)
    }
    let l1 = relLum(first)
    let l2 = relLum(second)
    let lighter = max(l1, l2)
    let darker = min(l1, l2)
    return (lighter + 0.05) / (darker + 0.05)
}

private func mixOklch(_ start: OklchColor, _ end: OklchColor, amount: Double) -> OklchColor {
    let startHue = start.c > 0.002 ? start.h : end.h
    let endHue = end.c > 0.002 ? end.h : startHue
    let diff = (endHue - startHue).truncatingRemainder(dividingBy: 360.0)
    let deltaHue = (diff + 540.0).truncatingRemainder(dividingBy: 360.0) - 180.0
    return OklchColor(
        l: start.l + (end.l - start.l) * amount,
        c: start.c + (end.c - start.c) * amount,
        h: startHue + deltaHue * amount
    )
}

private struct NewDesignNeutralResult {
    let scale: [HueStep: String]
    let lightness: [HueStep: Double]
    let readable: (OklchColor, Double) -> OklchColor
}

private func newDesignNeutralScale(_ theme: V1Theme, mode: Mode) -> NewDesignNeutralResult {
    let profile = mode == .dark ? newDesignDarkProfile : newDesignLightProfile
    func isOpaque(_ color: RGBA) -> Bool { color.toInts().3 > 0 }
    let element: RGBA? = [theme.backgroundElement, theme.backgroundMenu].first(where: isOpaque)
    let sources: [(step: HueStep, color: RGBA?)] = [
        (.s900, theme.background),
        (.s700, theme.backgroundPanel),
        (.s600, element),
    ]
    let reference = sources.first { pair in
        guard let c = pair.color else { return false }
        return isOpaque(c)
    }
    let page: OklchColor
    if let reference, let refColor = reference.color {
        page = toOklch(refColor)
    } else {
        page = toOklch(mode == .dark ? RGBA.fromInts(0, 0, 0) : RGBA.fromInts(255, 255, 255))
    }
    let pageLightness = page.l - (reference.map { profile.surface[$0.step]! } ?? 0)

    func tint(_ colors: RGBA?...) -> OklchColor {
        for c in colors {
            if let c, isOpaque(c) { return toOklch(c) }
        }
        return page
    }

    let surfaceTint: [HueStep: OklchColor] = [
        .s900: tint(theme.background, theme.backgroundPanel, element),
        .s800: tint(theme.backgroundPanel, theme.background, element),
        .s700: tint(theme.backgroundPanel, theme.background, element),
        .s600: tint(element, theme.backgroundPanel, theme.background),
        .s500: tint(element, theme.backgroundPanel, theme.background),
        .s400: tint(element, theme.backgroundPanel, theme.background),
    ]

    var lightness: [HueStep: Double] = [:]
    var planned: [HueStep: Double] = [:]
    var scale: [HueStep: String] = [:]
    let text = toOklch(theme.text)
    var pageColor = surfaceTint[.s900]!
    pageColor.l = pageLightness
    let pageContrast = wcagContrast(theme.text, RGBA.fromHex(oklchToHex(pageColor)))

    let readable: (OklchColor, Double) -> OklchColor = { color, share in
        let target = max(pageContrast * share, min(minimumSurfaceContrast, pageContrast * 0.95))
        func passes(_ amount: Double) -> Bool {
            wcagContrast(theme.text, RGBA.fromHex(oklchToHex(mixOklch(color, pageColor, amount: amount)))) >= target
        }
        if passes(0) { return color }
        if !passes(maximumDimming) { return mixOklch(color, pageColor, amount: maximumDimming) }
        var low = 0.0
        var high = maximumDimming
        for _ in 0..<12 {
            let amount = (low + high) / 2.0
            if passes(amount) { high = amount } else { low = amount }
        }
        return mixOklch(color, pageColor, amount: high)
    }

    for step in [HueStep.s800, .s700, .s600, .s500, .s400] {
        var generated = surfaceTint[step]!
        generated.l = pageLightness + profile.surface[step]!
        let color = step == .s400 ? generated : readable(generated, profile.readable[step]!)
        planned[step] = generated.l
        lightness[step] = color.l
        scale[step] = oklchToHex(color)
    }

    lightness[.s900] = pageLightness
    scale[.s900] = hex(theme.background)
    for (step, color) in [(HueStep.s800, theme.backgroundPanel), (.s700, theme.backgroundPanel), (.s600, theme.backgroundElement)] {
        if !isOpaque(color) { scale[step] = hex(color) }
    }
    lightness[.s100] = text.l
    scale[.s100] = hex(theme.text)
    for step in [HueStep.s200, .s300] {
        let generated = mixOklch(pageColor, text, amount: profile.text[step]!)
        lightness[step] = generated.l
        scale[step] = oklchToHex(generated)
    }
    let muted = toOklch(theme.textMuted)
    let mutedStep: HueStep = abs(muted.l - lightness[.s200]!) <= abs(muted.l - lightness[.s300]!) ? .s200 : .s300
    lightness[mutedStep] = muted.l
    scale[mutedStep] = hex(theme.textMuted)

    var mergedLightness = lightness
    for (k, v) in planned { mergedLightness[k] = v }
    return NewDesignNeutralResult(scale: scale, lightness: mergedLightness, readable: readable)
}

private func newDesignHueScale(_ color: RGBA, mode: Mode, neutral: NewDesignNeutralResult) -> [HueStep: String] {
    let profile = mode == .dark ? newDesignDarkProfile : newDesignLightProfile
    let anchor = toOklch(color)
    let alpha = Int(color.toInts().3)
    func generate(_ generated: OklchColor) -> String {
        let value = oklchToHex(generated)
        return alpha == 255 ? value : "\(value)\(byte(alpha))"
    }
    func stepLightness(_ step: HueStep) -> Double {
        neutral.lightness[step]! + profile.hueLightness[step]!
    }
    var out: [HueStep: String] = [:]
    for step in HueStep.literals {
        if step == .s400 {
            out[step] = hex(color)
            continue
        }
        let lVal = step == .s500
            ? anchor.l + (stepLightness(.s600) - anchor.l) * profile.hueMid
            : stepLightness(step)
        let generated = OklchColor(l: lVal, c: anchor.c * profile.hueChroma[step]!, h: anchor.h)
        if step == .s600 || step == .s700 || step == .s800 || step == .s900 {
            out[step] = generate(neutral.readable(generated, profile.readableHue[step]!))
        } else {
            out[step] = generate(generated)
        }
    }
    return out
}

private func migrateModeNewDesigns(_ theme: V1Theme, mode: Mode) -> ThemeDefinition {
    func color(_ key: V1ThemeColor) -> String { hex(theme[key]) }
    let neutral = newDesignNeutralScale(theme, mode: mode)
    let primary = "$hue.interactive.400"
    let hues = inferHues(theme)

    var uniqueCategorical: [String] = []
    for token in categoricalTokens {
        if let h = hues.byToken[token]?.rawValue, !uniqueCategorical.contains(h) {
            uniqueCategorical.append(h)
        }
    }

    var hueValues: [HueName: HueValueDefinition] = ["gray": .scale(neutral.scale)]
    var hueOrder: [HueName] = ["gray"]
    for name in chromaticHues {
        if let match = hues.byHue[name] {
            hueValues[name.rawValue] = .scale(newDesignHueScale(match.color, mode: mode, neutral: neutral))
            hueOrder.append(name.rawValue)
        }
    }
    hueValues["accent"] = .alias(hues.byToken[.accent].map { "$hue.\($0.rawValue)" } ?? "$hue.gray")
    hueValues["interactive"] = .alias(hues.byToken[.primary].map { "$hue.\($0.rawValue)" } ?? "$hue.gray")
    hueValues["neutral"] = .alias("$hue.gray")
    hueOrder.append(contentsOf: ["accent", "interactive", "neutral"])

    let definition = ThemeDefinition(
        hue: HueDefinition(hueValues, keyOrder: hueOrder),
        categorical: uniqueCategorical.isEmpty ? ["neutral"] : uniqueCategorical,
        text: TextDefinition(
            base: "$hue.neutral.100",
            muted: "$hue.neutral.200",
            faint: "$hue.neutral.300",
            action: ActionColorDefinition(
                primary: StatefulColorDefinition(
                    base: "$text.base",
                    focused: "$text.base",
                    selected: primary,
                    disabled: "$text.faint"
                ),
                secondary: StatefulColorDefinition(
                    base: "$text.muted",
                    hovered: "$text.base",
                    focused: "$hue.interactive.200"
                ),
                destructive: StatefulColorDefinition(
                    base: hex(selectedForeground(theme, background: theme.error)),
                    disabled: "$text.faint"
                )
            ),
            formfield: StatefulColorDefinition(
                base: "$text.base",
                hovered: primary,
                focused: primary,
                pressed: primary,
                selected: primary,
                disabled: "$text.faint"
            ),
            feedback: TextFeedbackDefinition(
                error: TextFeedbackItemDefinition(base: color(.error)),
                warning: TextFeedbackItemDefinition(base: color(.warning)),
                success: TextFeedbackItemDefinition(base: color(.success)),
                info: TextFeedbackItemDefinition(base: color(.info))
            )
        ),
        background: BackgroundDefinition(
            base: "$hue.neutral.900",
            raised: RaisedBackgroundDefinition(
                base: "$hue.neutral.700",
                high: "$hue.neutral.600",
                max: "$hue.neutral.500"
            ),
            action: ActionColorDefinition(
                primary: StatefulColorDefinition(
                    base: "transparent",
                    hovered: "$hue.neutral.700",
                    focused: "$hue.interactive.600",
                    selected: "transparent"
                ),
                secondary: StatefulColorDefinition(base: "transparent"),
                destructive: StatefulColorDefinition(base: color(.error))
            ),
            formfield: StatefulColorDefinition(base: "$background.base"),
            feedback: BackgroundFeedbackDefinition(
                error: BackgroundFeedbackItemDefinition(base: "$background.base"),
                warning: BackgroundFeedbackItemDefinition(base: "$background.base"),
                success: BackgroundFeedbackItemDefinition(base: "$background.base"),
                info: BackgroundFeedbackItemDefinition(base: "$background.base")
            )
        ),
        border: SingleColorDefinition(base: color(.border)),
        scrollbar: SingleColorDefinition(base: color(.borderActive)),
        diff: DiffDefinition(
            text: DiffDefinition.Text(
                added: color(.diffAdded),
                removed: color(.diffRemoved),
                context: color(.diffContext),
                hunkHeader: color(.diffHunkHeader)
            ),
            background: DiffDefinition.Background(
                added: color(.diffAddedBg),
                removed: color(.diffRemovedBg),
                context: color(.diffContextBg)
            ),
            highlight: DiffDefinition.Highlight(
                added: color(.diffHighlightAdded),
                removed: color(.diffHighlightRemoved)
            ),
            lineNumber: DiffDefinition.LineNumber(
                text: color(.diffLineNumber),
                background: DiffDefinition.LineNumber.LineNumberBackground(
                    added: color(.diffAddedLineNumberBg),
                    removed: color(.diffRemovedLineNumberBg)
                )
            )
        ),
        syntax: [
            .comment: color(.syntaxComment),
            .keyword: color(.syntaxKeyword),
            .function: color(.syntaxFunction),
            .variable: color(.syntaxVariable),
            .string: color(.syntaxString),
            .number: color(.syntaxNumber),
            .type: color(.syntaxType),
            .operator: color(.syntaxOperator),
            .punctuation: color(.syntaxPunctuation),
        ],
        markdown: [
            .text: color(.markdownText),
            .heading: color(.markdownHeading),
            .link: color(.markdownLink),
            .linkText: color(.markdownLinkText),
            .code: color(.markdownCode),
            .blockQuote: color(.markdownBlockQuote),
            .emphasis: color(.markdownEmph),
            .strong: color(.markdownStrong),
            .horizontalRule: color(.markdownHorizontalRule),
            .listItem: color(.markdownListItem),
            .listEnumeration: color(.markdownListEnumeration),
            .image: color(.markdownImage),
            .imageText: color(.markdownImageText),
            .codeBlock: color(.markdownCodeBlock),
        ],
        dialog: DialogTokensDefinition(
            background: BackgroundDefinition(
                base: dialogBackground(theme),
                action: ActionColorDefinition(
                    primary: StatefulColorDefinition(hovered: "$background.raised.max"),
                    secondary: StatefulColorDefinition(hovered: "$background.raised.max")
                )
            )
        )
    )
    return referenceHues(definition)
}

// MARK: - Built-in Default Themes (`opencode`, `opencode-classic`, and V1 `opencode`)

/// Built-in default light and dark TUI theme documents matching upstream `packages/tui/src/theme/assets/`.
public enum ThemeDefaults {
    /// `opencode2` was the new theme's name before it became `opencode`; the name stays an alias of it.
    public static var opencode2: ThemeDocument { opencode }

    /// Built-in V2 `opencode-classic` theme document (light + dark): the previous default `opencode` theme
    /// (`packages/tui/src/theme/assets/v2/opencode-classic.json`).
    public static let opencodeClassic = ThemeDocument(
        schema: "https://opencode.ai/theme.json",
        base: BaseThemeDefinition(
            categorical: ["blue", "purple", "green", "orange", "red"],
            text: TextDefinition(
                base: "$hue.neutral.200",
                muted: "$hue.neutral.400",
                action: ActionColorDefinition(
                    primary: StatefulColorDefinition(
                        base: "$text.base",
                        focused: "$hue.neutral.800",
                        selected: "$hue.interactive.200",
                        disabled: "$hue.neutral.400"
                    ),
                    secondary: StatefulColorDefinition(
                        base: "$text.muted",
                        hovered: "$text.base"
                    ),
                    destructive: StatefulColorDefinition(
                        base: "$hue.neutral.800",
                        disabled: "$hue.neutral.400"
                    )
                ),
                formfield: StatefulColorDefinition(
                    base: "$hue.neutral.200",
                    hovered: "$hue.interactive.200",
                    focused: "$hue.interactive.200",
                    pressed: "$hue.interactive.200",
                    selected: "$hue.interactive.200",
                    disabled: "$hue.neutral.400"
                ),
                feedback: TextFeedbackDefinition(
                    error: TextFeedbackItemDefinition(base: "$hue.red.200"),
                    warning: TextFeedbackItemDefinition(base: "#f5a742"),
                    success: TextFeedbackItemDefinition(base: "$hue.green.200"),
                    info: TextFeedbackItemDefinition(base: "$hue.cyan.200")
                )
            ),
            background: BackgroundDefinition(
                base: "$hue.neutral.800",
                raised: RaisedBackgroundDefinition(
                    base: "$hue.neutral.700",
                    high: "$hue.neutral.600",
                    max: "$hue.neutral.500"
                ),
                action: ActionColorDefinition(
                    primary: StatefulColorDefinition(
                        base: "transparent",
                        hovered: "$hue.neutral.700",
                        focused: "$hue.interactive.200",
                        selected: "transparent"
                    ),
                    secondary: StatefulColorDefinition(base: "transparent"),
                    destructive: StatefulColorDefinition(base: "$hue.red.200")
                ),
                formfield: StatefulColorDefinition(base: "$background.base"),
                feedback: BackgroundFeedbackDefinition(
                    error: BackgroundFeedbackItemDefinition(base: "$background.base"),
                    warning: BackgroundFeedbackItemDefinition(base: "$background.base"),
                    success: BackgroundFeedbackItemDefinition(base: "$background.base"),
                    info: BackgroundFeedbackItemDefinition(base: "$background.base")
                )
            ),
            border: SingleColorDefinition(base: "#484848"),
            scrollbar: SingleColorDefinition(base: "#606060"),
            diff: DiffDefinition(
                text: DiffDefinition.Text(
                    added: "#4fd6be",
                    removed: "#c53b53",
                    context: "#828bb8",
                    hunkHeader: "#828bb8"
                ),
                background: DiffDefinition.Background(
                    added: "#20303b",
                    removed: "#37222c",
                    context: "$hue.neutral.700"
                ),
                highlight: DiffDefinition.Highlight(
                    added: "#b8db87",
                    removed: "#e26a75"
                ),
                lineNumber: DiffDefinition.LineNumber(
                    text: "#8f8f8f",
                    background: DiffDefinition.LineNumber.LineNumberBackground(
                        added: "#1b2b34",
                        removed: "#2d1f26"
                    )
                )
            ),
            syntax: [
                .comment: "$hue.neutral.400",
                .keyword: "$hue.accent.200",
                .function: "$hue.interactive.200",
                .variable: "$hue.red.200",
                .string: "$hue.green.200",
                .number: "#f5a742",
                .type: "#e5c07b",
                .operator: "$hue.cyan.200",
                .punctuation: "$hue.neutral.200",
            ],
            markdown: [
                .text: "$hue.neutral.200",
                .heading: "$hue.accent.200",
                .link: "$hue.interactive.200",
                .linkText: "$hue.cyan.200",
                .code: "$hue.green.200",
                .blockQuote: "#e5c07b",
                .emphasis: "#e5c07b",
                .strong: "#f5a742",
                .horizontalRule: "$hue.neutral.400",
                .listItem: "$hue.interactive.200",
                .listEnumeration: "$hue.cyan.200",
                .image: "$hue.interactive.200",
                .imageText: "$hue.cyan.200",
                .codeBlock: "$hue.neutral.200",
            ],
            dialog: DialogTokensDefinition(
                background: BackgroundDefinition(
                    base: "$background.raised.base",
                    action: ActionColorDefinition(
                        primary: StatefulColorDefinition(hovered: "$background.raised.high")
                    )
                )
            )
        ),
        light: ModeDefinition(
            hue: HueDefinition(
                [
                    "gray": .scale([
                        .s100: "#000000", .s200: "#1a1a1a", .s300: "#4e4e4e",
                        .s400: "#8a8a8a", .s500: "#bebebe", .s600: "#f5f5f5",
                        .s700: "#fafafa", .s800: "#ffffff", .s900: "#ffffff",
                    ]),
                    "red": .scale([
                        .s100: "#c20f26", .s200: "#d1383d", .s300: "#e05352",
                        .s400: "#ee6b68", .s500: "#fc837d", .s600: "#fda19b",
                        .s700: "#fcbeb9", .s800: "#fed8d5", .s900: "#fff2f0",
                    ]),
                    "orange": .scale([
                        .s100: "#c7811e", .s200: "#d68c27", .s300: "#df9a44",
                        .s400: "#e8a85c", .s500: "#f1b671", .s600: "#fac386",
                        .s700: "#fcd4a8", .s800: "#fee3c7", .s900: "#fef3e7",
                    ]),
                    "green": .scale([
                        .s100: "#1f8c44", .s200: "#3d9a57", .s300: "#55a96a",
                        .s400: "#6cb77c", .s500: "#81c68f", .s600: "#96d5a3",
                        .s700: "#ace4b6", .s800: "#c1f3ca", .s900: "#e1fee6",
                    ]),
                    "cyan": .scale([
                        .s100: "#077786", .s200: "#318795", .s300: "#4c97a4",
                        .s400: "#64a8b4", .s500: "#7bb8c4", .s600: "#92c9d4",
                        .s700: "#a8dbe4", .s800: "#bfecf4", .s900: "#e3fafe",
                    ]),
                    "blue": .scale([
                        .s100: "#226bcc", .s200: "#3b7dd8", .s300: "#518ee4",
                        .s400: "#67a0f0", .s500: "#7db1fc", .s600: "#9cc3fa",
                        .s700: "#b7d4fd", .s800: "#d4e5fd", .s900: "#f0f6fe",
                    ]),
                    "purple": .scale([
                        .s100: "#6b47a7", .s200: "#7b5bb6", .s300: "#8c6fc5",
                        .s400: "#9d83d4", .s500: "#af98e3", .s600: "#c1acf2",
                        .s700: "#d3c3fc", .s800: "#e4dbfd", .s900: "#f6f3ff",
                    ]),
                    "accent": .alias("$hue.orange"),
                    "interactive": .alias("$hue.blue"),
                    "neutral": .alias("$hue.gray"),
                ],
                keyOrder: ["gray", "red", "orange", "green", "cyan", "blue", "purple", "accent", "interactive", "neutral"]
            ),
            categorical: ["purple", "orange", "green", "blue", "red"],
            text: TextDefinition(
                action: ActionColorDefinition(
                    primary: StatefulColorDefinition(focused: "$hue.neutral.900"),
                    destructive: StatefulColorDefinition(base: "$hue.neutral.900")
                ),
                feedback: TextFeedbackDefinition(
                    warning: TextFeedbackItemDefinition(base: "$hue.accent.200")
                )
            ),
            border: SingleColorDefinition(base: "#b8b8b8"),
            scrollbar: SingleColorDefinition(base: "#a0a0a0"),
            diff: DiffDefinition(
                text: DiffDefinition.Text(
                    added: "#1e725c",
                    context: "#7086b5",
                    hunkHeader: "#7086b5"
                ),
                background: DiffDefinition.Background(
                    added: "#d5e5d5",
                    removed: "#f7d8db"
                ),
                highlight: DiffDefinition.Highlight(
                    added: "#4db380",
                    removed: "#f52a65"
                ),
                lineNumber: DiffDefinition.LineNumber(
                    text: "#595959",
                    background: DiffDefinition.LineNumber.LineNumberBackground(
                        added: "#c5d5c5",
                        removed: "#e7c8cb"
                    )
                )
            ),
            syntax: [
                .number: "$hue.accent.200",
                .type: "#b0851f",
            ],
            markdown: [
                .blockQuote: "#b0851f",
                .emphasis: "#b0851f",
                .strong: "$hue.accent.200",
            ]
        ),
        dark: ModeDefinition(
            hue: HueDefinition(
                [
                    "gray": .scale([
                        .s100: "#ffffff", .s200: "#eeeeee", .s300: "#b5b5b5",
                        .s400: "#808080", .s500: "#4c4c4c", .s600: "#1e1e1e",
                        .s700: "#141414", .s800: "#0a0a0a", .s900: "#030303",
                    ]),
                    "red": .scale([
                        .s100: "#fd7e87", .s200: "#e06c75", .s300: "#c35a63",
                        .s400: "#a74952", .s500: "#8c3941", .s600: "#722931",
                        .s700: "#591921", .s800: "#410a13", .s900: "#280207",
                    ]),
                    "orange": .scale([
                        .s100: "#fddac5", .s200: "#fab283", .s300: "#d8976c",
                        .s400: "#b67c56", .s500: "#966341", .s600: "#774a2c",
                        .s700: "#593319", .s800: "#3d1d06", .s900: "#1f0b01",
                    ]),
                    "green": .scale([
                        .s100: "#96f7a7", .s200: "#7fd88f", .s300: "#68b977",
                        .s400: "#539c61", .s500: "#3d7f4b", .s600: "#296336",
                        .s700: "#144922", .s800: "#00300f", .s900: "#011705",
                    ]),
                    "cyan": .scale([
                        .s100: "#68d0dd", .s200: "#56b6c2", .s300: "#449da7",
                        .s400: "#33848e", .s500: "#226c75", .s600: "#0f555d",
                        .s700: "#093e44", .s800: "#02292e", .s900: "#001518",
                    ]),
                    "blue": .scale([
                        .s100: "#82b4fb", .s200: "#5c9cf5", .s300: "#4c86d6",
                        .s400: "#3c70b8", .s500: "#2c5b9b", .s600: "#1d477f",
                        .s700: "#0f3364", .s800: "#02214a", .s900: "#01112b",
                    ]),
                    "purple": .scale([
                        .s100: "#b38ff4", .s200: "#9d7cd8", .s300: "#8869bd",
                        .s400: "#7357a2", .s500: "#5f4688", .s600: "#4b356f",
                        .s700: "#392557", .s800: "#271640", .s900: "#17072b",
                    ]),
                    "accent": .alias("$hue.purple"),
                    "interactive": .alias("$hue.orange"),
                    "neutral": .alias("$hue.gray"),
                ],
                keyOrder: ["gray", "red", "orange", "green", "cyan", "blue", "purple", "accent", "interactive", "neutral"]
            )
        )
    )

    /// Built-in V2 `opencode` theme document (light + dark, including `@dialog.@footer`): the new default theme,
    /// formerly the `opencode2` new-designs theme (`packages/tui/src/theme/assets/v2/opencode.json`).
    public static let opencode = ThemeDocument(
        schema: "https://opencode.ai/theme.json",
        base: BaseThemeDefinition(
            categorical: ["blue", "purple", "green", "orange", "red"],
            text: TextDefinition(
                base: "$hue.neutral.100",
                muted: "$hue.neutral.300",
                action: ActionColorDefinition(
                    primary: StatefulColorDefinition(
                        base: "$text.base",
                        focused: "$text.base",
                        selected: "$hue.interactive.400",
                        disabled: "$text.muted"
                    ),
                    secondary: StatefulColorDefinition(
                        base: "$text.muted",
                        hovered: "$text.base",
                        focused: "$hue.interactive.200"
                    ),
                    destructive: StatefulColorDefinition(
                        base: "$hue.neutral.900",
                        disabled: "$text.muted"
                    )
                ),
                formfield: StatefulColorDefinition(
                    base: "$text.base",
                    hovered: "$hue.interactive.400",
                    focused: "$hue.interactive.400",
                    pressed: "$hue.interactive.400",
                    selected: "$hue.interactive.400",
                    disabled: "$text.muted"
                ),
                feedback: TextFeedbackDefinition(
                    error: TextFeedbackItemDefinition(base: "$hue.red.400"),
                    warning: TextFeedbackItemDefinition(base: "#f5a742"),
                    success: TextFeedbackItemDefinition(base: "$hue.green.400"),
                    info: TextFeedbackItemDefinition(base: "$hue.blue.400")
                )
            ),
            background: BackgroundDefinition(
                base: "$hue.neutral.900",
                raised: RaisedBackgroundDefinition(
                    base: "$hue.neutral.700",
                    high: "$hue.neutral.600",
                    max: "$hue.neutral.500"
                ),
                action: ActionColorDefinition(
                    primary: StatefulColorDefinition(
                        base: "transparent",
                        hovered: "$hue.neutral.700",
                        focused: "$hue.interactive.600",
                        selected: "transparent"
                    ),
                    secondary: StatefulColorDefinition(base: "transparent"),
                    destructive: StatefulColorDefinition(base: "$hue.red.400")
                ),
                formfield: StatefulColorDefinition(base: "$background.base"),
                feedback: BackgroundFeedbackDefinition(
                    error: BackgroundFeedbackItemDefinition(base: "$background.base"),
                    warning: BackgroundFeedbackItemDefinition(base: "$background.base"),
                    success: BackgroundFeedbackItemDefinition(base: "$background.base"),
                    info: BackgroundFeedbackItemDefinition(base: "$background.base")
                )
            ),
            border: SingleColorDefinition(base: "#484848"),
            scrollbar: SingleColorDefinition(base: "#606060"),
            diff: DiffDefinition(
                text: DiffDefinition.Text(
                    added: "#4fd6be",
                    removed: "#c53b53",
                    context: "#828bb8",
                    hunkHeader: "#828bb8"
                ),
                background: DiffDefinition.Background(
                    added: "#20303b",
                    removed: "#37222c",
                    context: "$hue.neutral.700"
                ),
                highlight: DiffDefinition.Highlight(
                    added: "#b8db87",
                    removed: "#e26a75"
                ),
                lineNumber: DiffDefinition.LineNumber(
                    text: "#8f8f8f",
                    background: DiffDefinition.LineNumber.LineNumberBackground(
                        added: "#1b2b34",
                        removed: "#2d1f26"
                    )
                )
            ),
            syntax: [
                .comment: "#808080",
                .keyword: "#9d7cd8",
                .function: "#fab283",
                .variable: "#e06c75",
                .string: "#7fd88f",
                .number: "#f5a742",
                .type: "#e5c07b",
                .operator: "#56b6c2",
                .punctuation: "#eeeeee",
            ],
            markdown: [
                .text: "#eeeeee",
                .heading: "#9d7cd8",
                .link: "#fab283",
                .linkText: "#56b6c2",
                .code: "#7fd88f",
                .blockQuote: "#e5c07b",
                .emphasis: "#e5c07b",
                .strong: "#f5a742",
                .horizontalRule: "#808080",
                .listItem: "#fab283",
                .listEnumeration: "#56b6c2",
                .image: "#fab283",
                .imageText: "#56b6c2",
                .codeBlock: "#eeeeee",
            ],
            dialog: DialogTokensDefinition(
                background: BackgroundDefinition(
                    base: "$background.raised.base",
                    action: ActionColorDefinition(
                        primary: StatefulColorDefinition(hovered: "$background.raised.max"),
                        secondary: StatefulColorDefinition(hovered: "$background.raised.max")
                    )
                ),
                footer: ThemeTokensDefinition(
                    text: TextDefinition(muted: "$hue.neutral.200")
                )
            )
        ),
        light: ModeDefinition(
            hue: HueDefinition(
                [
                    "gray": .scale([
                        .s100: "#101010", .s200: "#505050", .s300: "#808080",
                        .s400: "#b5b5b5", .s500: "#e6e6e6", .s600: "#eeeeee",
                        .s700: "#f2f2f2", .s800: "#fafafa", .s900: "#ffffff",
                    ]),
                    "blue": .scale([
                        .s100: "#1b1f2e", .s200: "#6e7380", .s300: "#9ba1b2",
                        .s400: "#6c8ffe", .s500: "#b9c9f5", .s600: "#d3ddf8",
                        .s700: "#eaf0ff", .s800: "#f4f7ff", .s900: "#fbfcff",
                    ]),
                    "orange": .scale([
                        .s100: "#2e241b", .s200: "#7d7670", .s300: "#afa49d",
                        .s400: "#c4713a", .s500: "#e8c7ad", .s600: "#f0dcce",
                        .s700: "#fcf2ea", .s800: "#fdf8f4", .s900: "#fefdfb",
                    ]),
                    "purple": .scale([
                        .s100: "#231b2e", .s200: "#74707c", .s300: "#a29dae",
                        .s400: "#9d78df", .s500: "#cdbee7", .s600: "#e8e0f8",
                        .s700: "#f0ebfa", .s800: "#f8f5fc", .s900: "#fcfbfe",
                    ]),
                    "red": .scale([
                        .s100: "#2e1b1b", .s200: "#7e6d6d", .s300: "#b09999",
                        .s400: "#ec6262", .s500: "#eab8b8", .s600: "#fbdada",
                        .s700: "#fdeaea", .s800: "#fff6f6", .s900: "#fffbfb",
                    ]),
                    "green": .scale([
                        .s100: "#1b2e1b", .s200: "#6d7e6d", .s300: "#99b099",
                        .s400: "#62ec62", .s500: "#b8eab8", .s600: "#dafbda",
                        .s700: "#eafdea", .s800: "#f6fff6", .s900: "#fbfffb",
                    ]),
                    "accent": .alias("$hue.blue"),
                    "interactive": .alias("$hue.blue"),
                    "neutral": .alias("$hue.gray"),
                ],
                keyOrder: ["gray", "blue", "orange", "purple", "red", "green", "accent", "interactive", "neutral"]
            ),
            text: TextDefinition(
                feedback: TextFeedbackDefinition(
                    warning: TextFeedbackItemDefinition(base: "#d68c27")
                )
            ),
            border: SingleColorDefinition(base: "#b8b8b8"),
            scrollbar: SingleColorDefinition(base: "#a0a0a0"),
            diff: DiffDefinition(
                text: DiffDefinition.Text(
                    added: "#1e725c",
                    removed: "#c53b53",
                    context: "#7086b5",
                    hunkHeader: "#7086b5"
                ),
                background: DiffDefinition.Background(
                    added: "#d5e5d5",
                    removed: "#f7d8db",
                    context: "$hue.neutral.700"
                ),
                highlight: DiffDefinition.Highlight(
                    added: "#4db380",
                    removed: "#f52a65"
                ),
                lineNumber: DiffDefinition.LineNumber(
                    text: "#595959",
                    background: DiffDefinition.LineNumber.LineNumberBackground(
                        added: "#c5d5c5",
                        removed: "#e7c8cb"
                    )
                )
            ),
            syntax: [
                .comment: "#8a8a8a",
                .keyword: "#d68c27",
                .function: "#3b7dd8",
                .variable: "#d1383d",
                .string: "#3d9a57",
                .number: "#d68c27",
                .type: "#b0851f",
                .operator: "#318795",
                .punctuation: "#1a1a1a",
            ],
            markdown: [
                .text: "#1a1a1a",
                .heading: "#d68c27",
                .link: "#3b7dd8",
                .linkText: "#318795",
                .code: "#3d9a57",
                .blockQuote: "#b0851f",
                .emphasis: "#b0851f",
                .strong: "#d68c27",
                .horizontalRule: "#8a8a8a",
                .listItem: "#3b7dd8",
                .listEnumeration: "#318795",
                .image: "#3b7dd8",
                .imageText: "#318795",
                .codeBlock: "#1a1a1a",
            ],
            dialog: DialogTokensDefinition(
                background: BackgroundDefinition(
                    base: "$hue.neutral.800",
                    raised: RaisedBackgroundDefinition(high: "$hue.neutral.700"),
                    action: ActionColorDefinition(
                        primary: StatefulColorDefinition(hovered: "$hue.neutral.600"),
                        secondary: StatefulColorDefinition(hovered: "$hue.neutral.600")
                    )
                )
            )
        ),
        dark: ModeDefinition(
            hue: HueDefinition(
                [
                    "gray": .scale([
                        .s100: "#ffffff", .s200: "#b0b0b0", .s300: "#808080",
                        .s400: "#444444", .s500: "#303030", .s600: "#202020",
                        .s700: "#141414", .s800: "#101010", .s900: "#080808",
                    ]),
                    "blue": .scale([
                        .s100: "#f1f4ff", .s200: "#93a2b7", .s300: "#6d7a8d",
                        .s400: "#7699fe", .s500: "#426097", .s600: "#23344b",
                        .s700: "#162333", .s800: "#0d1621", .s900: "#050a12",
                    ]),
                    "orange": .scale([
                        .s100: "#f6f0eb", .s200: "#b09c8d", .s300: "#807770",
                        .s400: "#ecb081", .s500: "#896b50", .s600: "#42372c",
                        .s700: "#2c241d", .s800: "#1b1612", .s900: "#0d0907",
                    ]),
                    "purple": .scale([
                        .s100: "#f7f2ff", .s200: "#af9eba", .s300: "#7d7492",
                        .s400: "#a383e2", .s500: "#685588", .s600: "#3b3347",
                        .s700: "#241e2c", .s800: "#130f18", .s900: "#0c080e",
                    ]),
                    "red": .scale([
                        .s100: "#fff2f2", .s200: "#b09492", .s300: "#90706f",
                        .s400: "#ef6c6c", .s500: "#90494a", .s600: "#4a2e2e",
                        .s700: "#2e1f1f", .s800: "#1a1313", .s900: "#0d0909",
                    ]),
                    "green": .scale([
                        .s100: "#f1f1f1", .s200: "#c5cfc5", .s300: "#8f9c8f",
                        .s400: "#9ee77a", .s500: "#499049", .s600: "#2c422c",
                        .s700: "#1f2e1f", .s800: "#131a13", .s900: "#090d09",
                    ]),
                    "accent": .alias("$hue.blue"),
                    "interactive": .alias("$hue.blue"),
                    "neutral": .alias("$hue.gray"),
                ],
                keyOrder: ["gray", "blue", "orange", "purple", "red", "green", "accent", "interactive", "neutral"]
            )
        )
    )

    /// Built-in V1 `opencode` legacy JSON theme matching upstream `packages/tui/src/theme/assets/opencode.json`.
    public static let opencodeV1 = ThemeV1Json(
        schema: "https://opencode.ai/theme.json",
        defs: [
            "darkStep1": "#0a0a0a", "darkStep2": "#141414", "darkStep3": "#1e1e1e",
            "darkStep4": "#282828", "darkStep5": "#323232", "darkStep6": "#3c3c3c",
            "darkStep7": "#484848", "darkStep8": "#606060", "darkStep9": "#fab283",
            "darkStep10": "#ffc09f", "darkStep11": "#808080", "darkStep12": "#eeeeee",
            "darkSecondary": "#5c9cf5", "darkAccent": "#9d7cd8", "darkRed": "#e06c75",
            "darkOrange": "#f5a742", "darkGreen": "#7fd88f", "darkCyan": "#56b6c2",
            "darkYellow": "#e5c07b",
            "lightStep1": "#ffffff", "lightStep2": "#fafafa", "lightStep3": "#f5f5f5",
            "lightStep4": "#ebebeb", "lightStep5": "#e1e1e1", "lightStep6": "#d4d4d4",
            "lightStep7": "#b8b8b8", "lightStep8": "#a0a0a0", "lightStep9": "#3b7dd8",
            "lightStep10": "#2968c3", "lightStep11": "#8a8a8a", "lightStep12": "#1a1a1a",
            "lightSecondary": "#7b5bb6", "lightAccent": "#d68c27", "lightRed": "#d1383d",
            "lightOrange": "#d68c27", "lightGreen": "#3d9a57", "lightCyan": "#318795",
            "lightYellow": "#b0851f",
        ],
        theme: [
            .primary: .variant(dark: "darkStep9", light: "lightStep9"),
            .secondary: .variant(dark: "darkSecondary", light: "lightSecondary"),
            .accent: .variant(dark: "darkAccent", light: "lightAccent"),
            .error: .variant(dark: "darkRed", light: "lightRed"),
            .warning: .variant(dark: "darkOrange", light: "lightOrange"),
            .success: .variant(dark: "darkGreen", light: "lightGreen"),
            .info: .variant(dark: "darkCyan", light: "lightCyan"),
            .text: .variant(dark: "darkStep12", light: "lightStep12"),
            .textMuted: .variant(dark: "darkStep11", light: "lightStep11"),
            .background: .variant(dark: "darkStep1", light: "lightStep1"),
            .backgroundPanel: .variant(dark: "darkStep2", light: "lightStep2"),
            .backgroundElement: .variant(dark: "darkStep3", light: "lightStep3"),
            .border: .variant(dark: "darkStep7", light: "lightStep7"),
            .borderActive: .variant(dark: "darkStep8", light: "lightStep8"),
            .borderSubtle: .variant(dark: "darkStep6", light: "lightStep6"),
            .diffAdded: .variant(dark: "#4fd6be", light: "#1e725c"),
            .diffRemoved: .variant(dark: "#c53b53", light: "#c53b53"),
            .diffContext: .variant(dark: "#828bb8", light: "#7086b5"),
            .diffHunkHeader: .variant(dark: "#828bb8", light: "#7086b5"),
            .diffHighlightAdded: .variant(dark: "#b8db87", light: "#4db380"),
            .diffHighlightRemoved: .variant(dark: "#e26a75", light: "#f52a65"),
            .diffAddedBg: .variant(dark: "#20303b", light: "#d5e5d5"),
            .diffRemovedBg: .variant(dark: "#37222c", light: "#f7d8db"),
            .diffContextBg: .variant(dark: "darkStep2", light: "lightStep2"),
            .diffLineNumber: .variant(dark: "#8f8f8f", light: "#595959"),
            .diffAddedLineNumberBg: .variant(dark: "#1b2b34", light: "#c5d5c5"),
            .diffRemovedLineNumberBg: .variant(dark: "#2d1f26", light: "#e7c8cb"),
            .markdownText: .variant(dark: "darkStep12", light: "lightStep12"),
            .markdownHeading: .variant(dark: "darkAccent", light: "lightAccent"),
            .markdownLink: .variant(dark: "darkStep9", light: "lightStep9"),
            .markdownLinkText: .variant(dark: "darkCyan", light: "lightCyan"),
            .markdownCode: .variant(dark: "darkGreen", light: "lightGreen"),
            .markdownBlockQuote: .variant(dark: "darkYellow", light: "lightYellow"),
            .markdownEmph: .variant(dark: "darkYellow", light: "lightYellow"),
            .markdownStrong: .variant(dark: "darkOrange", light: "lightOrange"),
            .markdownHorizontalRule: .variant(dark: "darkStep11", light: "lightStep11"),
            .markdownListItem: .variant(dark: "darkStep9", light: "lightStep9"),
            .markdownListEnumeration: .variant(dark: "darkCyan", light: "lightCyan"),
            .markdownImage: .variant(dark: "darkStep9", light: "lightStep9"),
            .markdownImageText: .variant(dark: "darkCyan", light: "lightCyan"),
            .markdownCodeBlock: .variant(dark: "darkStep12", light: "lightStep12"),
            .syntaxComment: .variant(dark: "darkStep11", light: "lightStep11"),
            .syntaxKeyword: .variant(dark: "darkAccent", light: "lightAccent"),
            .syntaxFunction: .variant(dark: "darkStep9", light: "lightStep9"),
            .syntaxVariable: .variant(dark: "darkRed", light: "lightRed"),
            .syntaxString: .variant(dark: "darkGreen", light: "lightGreen"),
            .syntaxNumber: .variant(dark: "darkOrange", light: "lightOrange"),
            .syntaxType: .variant(dark: "darkYellow", light: "lightYellow"),
            .syntaxOperator: .variant(dark: "darkCyan", light: "lightCyan"),
            .syntaxPunctuation: .variant(dark: "darkStep12", light: "lightStep12"),
        ]
    )

    /// Resolves the built-in default `opencode` theme for the given mode (`light` or `dark`).
    public static func resolveDefault(mode: Mode = .dark) throws -> ResolvedTheme {
        try resolveThemeDocument(opencode, mode: mode)
    }

    /// Resolves a custom theme document with automatic fallback to the built-in default if resolution fails.
    public static func resolveOrDefault(_ document: ThemeDocument?, mode: Mode = .dark) -> ResolvedTheme {
        if let document, let resolved = try? resolveThemeDocument(document, mode: mode) {
            return resolved
        }
        return try! resolveThemeDocument(opencode, mode: mode)
    }
}
