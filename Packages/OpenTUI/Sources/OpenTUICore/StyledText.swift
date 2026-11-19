/// Hyperlink metadata attached to a `TextChunk`.
public struct TextChunkLink: Equatable, Hashable, Sendable, Codable {
    public var url: String

    public init(url: String) {
        self.url = url
    }
}

/// A styled segment of text with optional foreground/background colors, attribute bitmask, and hyperlink target.
// parity: core/src/text-buffer.ts#TextChunk [status=implemented hash=84faa7634ae2]
public struct TextChunk: Equatable, Hashable, Sendable, Codable {
    public var text: String
    public var fg: RGBA?
    public var bg: RGBA?
    public var attributes: UInt32?
    public var link: TextChunkLink?

    public init(
        text: String,
        fg: RGBA? = nil,
        bg: RGBA? = nil,
        attributes: UInt32? = nil,
        link: TextChunkLink? = nil
    ) {
        self.text = text
        self.fg = fg
        self.bg = bg
        self.attributes = attributes
        self.link = link
    }
}

/// Color value accepted by `StyledText` builders: either a CSS/hex color string or a pre-packed `RGBA`.
// parity: core/src/lib/styled-text.ts#Color [status=implemented hash=2efadaa60218]
public enum Color: Equatable, Hashable, Sendable, ExpressibleByStringLiteral {
    case string(String)
    case rgba(RGBA)

    public init(stringLiteral value: String) {
        self = .string(value)
    }

    public func resolved() -> RGBA {
        switch self {
        case .string(let value):
            return parseColor(value)
        case .rgba(let rgba):
            return rgba
        }
    }
}

/// Types convertible to `Color` for ergonomic `fg(...)` and `bg(...)` builder calls.
public protocol ColorConvertible: Sendable {
    func asColor() -> Color
}

extension Color: ColorConvertible {
    public func asColor() -> Color { self }
}

extension String: ColorConvertible {
    public func asColor() -> Color { .string(self) }
}

extension RGBA: ColorConvertible {
    public func asColor() -> Color { .rgba(self) }
}

/// Declarative style attributes used to style text chunks.
// parity: core/src/lib/styled-text.ts#StyleAttrs [status=implemented hash=c08154f1f865]
public struct StyleAttrs: Equatable, Hashable, Sendable {
    public var fg: Color?
    public var bg: Color?
    public var bold: Bool?
    public var italic: Bool?
    public var underline: Bool?
    public var strikethrough: Bool?
    public var dim: Bool?
    public var reverse: Bool?
    public var inverse: Bool?
    public var blink: Bool?
    public var hidden: Bool?

    public init(
        fg: Color? = nil,
        bg: Color? = nil,
        bold: Bool? = nil,
        italic: Bool? = nil,
        underline: Bool? = nil,
        strikethrough: Bool? = nil,
        dim: Bool? = nil,
        reverse: Bool? = nil,
        inverse: Bool? = nil,
        blink: Bool? = nil,
        hidden: Bool? = nil
    ) {
        self.fg = fg
        self.bg = bg
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.strikethrough = strikethrough
        self.dim = dim
        self.reverse = reverse
        self.inverse = inverse
        self.blink = blink
        self.hidden = hidden
    }
}

/// Returns `true` if `value` is a `StyledText` instance.
// parity: core/src/lib/styled-text.ts#isStyledText [status=implemented hash=ac0864df2df4]
public func isStyledText(_ value: Any?) -> Bool {
    value is StyledText
}

/// Container of styled `TextChunk` segments.
// parity: core/src/lib/styled-text.ts#StyledText [status=implemented hash=d05769e46cd6]
public struct StyledText: Equatable, Hashable, Sendable, Codable {
    public var chunks: [TextChunk]

    public init(_ chunks: [TextChunk] = []) {
        self.chunks = chunks
    }

    public init(chunks: [TextChunk]) {
        self.chunks = chunks
    }

    /// Concatenated plain text of all chunks.
    public var plainText: String {
        chunks.map(\.text).joined()
    }
}

/// Wraps a plain string in a single-chunk `StyledText`.
// parity: core/src/lib/styled-text.ts#stringToStyledText [status=implemented hash=46d042e70483]
public func stringToStyledText(_ content: String) -> StyledText {
    StyledText(chunks: [TextChunk(text: content)])
}

/// Input accepted by styled-text builder functions: string, number, boolean, or an existing `TextChunk`.
// parity: core/src/lib/styled-text.ts#StylableInput [status=implemented hash=b4632f91496e]
public enum StylableInput: Equatable, Hashable, Sendable,
    ExpressibleByStringLiteral,
    ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral
{
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case chunk(TextChunk)

    public init(stringLiteral value: String) {
        self = .string(value)
    }

    public init(integerLiteral value: Int) {
        self = .int(value)
    }

    public init(floatLiteral value: Double) {
        self = .double(value)
    }

    public init(booleanLiteral value: Bool) {
        self = .bool(value)
    }

    internal var plainTextString: String {
        switch self {
        case .string(let s):
            return s
        case .int(let n):
            return String(n)
        case .double(let d):
            if d == 0 {
                return "0"
            }
            if d.isFinite && d.rounded(.towardZero) == d && d >= Double(Int64.min) && d <= Double(Int64.max) {
                return String(Int64(d))
            }
            return String(d)
        case .bool(let b):
            return b ? "true" : "false"
        case .chunk(let chunk):
            return chunk.text
        }
    }
}

/// Protocol unifying `String`, `Int`, `Double`, `Bool`, `TextChunk`, and `StylableInput` for style builder calls.
public protocol StylableInputConvertible: Sendable {
    func asStylableInput() -> StylableInput
}

extension StylableInput: StylableInputConvertible {
    public func asStylableInput() -> StylableInput { self }
}

extension String: StylableInputConvertible {
    public func asStylableInput() -> StylableInput { .string(self) }
}

extension Int: StylableInputConvertible {
    public func asStylableInput() -> StylableInput { .int(self) }
}

extension Double: StylableInputConvertible {
    public func asStylableInput() -> StylableInput { .double(self) }
}

extension Bool: StylableInputConvertible {
    public func asStylableInput() -> StylableInput { .bool(self) }
}

extension TextChunk: StylableInputConvertible {
    public func asStylableInput() -> StylableInput { .chunk(self) }
}

private func resolveNonEmptyColor(_ color: Color?) -> RGBA? {
    guard let color else { return nil }
    switch color {
    case .string(let s):
        return s.isEmpty ? nil : parseColor(s)
    case .rgba(let rgba):
        return rgba
    }
}

/// Applies `style` to a plain value or merges it into an existing `TextChunk`.
public func applyStyle<T: StylableInputConvertible>(_ input: T, _ style: StyleAttrs) -> TextChunk {
    let stylable = input.asStylableInput()
    let newAttrs = createTextAttributes(
        bold: style.bold ?? false,
        italic: style.italic ?? false,
        underline: style.underline ?? false,
        dim: style.dim ?? false,
        blink: style.blink ?? false,
        inverse: style.inverse ?? false,
        reverse: style.reverse ?? false,
        hidden: style.hidden ?? false,
        strikethrough: style.strikethrough ?? false
    )
    let resolvedFg = resolveNonEmptyColor(style.fg)
    let resolvedBg = resolveNonEmptyColor(style.bg)

    if case .chunk(let existing) = stylable {
        let fg = resolvedFg ?? existing.fg
        let bg = resolvedBg ?? existing.bg
        let mergedAttrs = existing.attributes.map { $0 | newAttrs } ?? newAttrs
        return TextChunk(
            text: existing.text,
            fg: fg,
            bg: bg,
            attributes: mergedAttrs,
            link: existing.link
        )
    }

    return TextChunk(
        text: stylable.plainTextString,
        fg: resolvedFg,
        bg: resolvedBg,
        attributes: newAttrs
    )
}

/// Curried style transform returned by `fg(...)`, `bg(...)`, and `link(...)`.
public struct StyleTransform: Sendable {
    private let transform: @Sendable (StylableInput) -> TextChunk

    public init(_ transform: @escaping @Sendable (StylableInput) -> TextChunk) {
        self.transform = transform
    }

    public func callAsFunction<T: StylableInputConvertible>(_ input: T) -> TextChunk {
        transform(input.asStylableInput())
    }
}

// MARK: - Foreground Color Functions

// parity: core/src/lib/styled-text.ts#black [status=implemented hash=27063f87a9b4]
public func black<T: StylableInputConvertible>(_ input: T) -> TextChunk {
    applyStyle(input, StyleAttrs(fg: "black"))
}

// parity: core/src/lib/styled-text.ts#red [status=implemented hash=37e0d9662b7c]
public func red<T: StylableInputConvertible>(_ input: T) -> TextChunk {
    applyStyle(input, StyleAttrs(fg: "red"))
}

// parity: core/src/lib/styled-text.ts#green [status=implemented hash=67d14d49f2d7]
public func green<T: StylableInputConvertible>(_ input: T) -> TextChunk {
    applyStyle(input, StyleAttrs(fg: "green"))
}

// parity: core/src/lib/styled-text.ts#yellow [status=implemented hash=84b27774fefe]
public func yellow<T: StylableInputConvertible>(_ input: T) -> TextChunk {
    applyStyle(input, StyleAttrs(fg: "yellow"))
}

// parity: core/src/lib/styled-text.ts#blue [status=implemented hash=22f7214f30eb]
public func blue<T: StylableInputConvertible>(_ input: T) -> TextChunk {
    applyStyle(input, StyleAttrs(fg: "blue"))
}

// parity: core/src/lib/styled-text.ts#magenta [status=implemented hash=c28fb5ad062a]
public func magenta<T: StylableInputConvertible>(_ input: T) -> TextChunk {
    applyStyle(input, StyleAttrs(fg: "magenta"))
}

// parity: core/src/lib/styled-text.ts#cyan [status=implemented hash=aee57bd92259]
public func cyan<T: StylableInputConvertible>(_ input: T) -> TextChunk {
    applyStyle(input, StyleAttrs(fg: "cyan"))
}

// parity: core/src/lib/styled-text.ts#white [status=implemented hash=c22e30dffe4f]
public func white<T: StylableInputConvertible>(_ input: T) -> TextChunk {
    applyStyle(input, StyleAttrs(fg: "white"))
}

// MARK: - Bright Foreground Color Functions

// parity: core/src/lib/styled-text.ts#brightBlack [status=implemented hash=237439d4d8cf]
public func brightBlack<T: StylableInputConvertible>(_ input: T) -> TextChunk {
    applyStyle(input, StyleAttrs(fg: "brightBlack"))
}

// parity: core/src/lib/styled-text.ts#brightRed [status=implemented hash=f769961a0380]
public func brightRed<T: StylableInputConvertible>(_ input: T) -> TextChunk {
    applyStyle(input, StyleAttrs(fg: "brightRed"))
}

// parity: core/src/lib/styled-text.ts#brightGreen [status=implemented hash=0e68a0ff734d]
public func brightGreen<T: StylableInputConvertible>(_ input: T) -> TextChunk {
    applyStyle(input, StyleAttrs(fg: "brightGreen"))
}

// parity: core/src/lib/styled-text.ts#brightYellow [status=implemented hash=31ad48cda620]
public func brightYellow<T: StylableInputConvertible>(_ input: T) -> TextChunk {
    applyStyle(input, StyleAttrs(fg: "brightYellow"))
}

// parity: core/src/lib/styled-text.ts#brightBlue [status=implemented hash=e4e58f353f1d]
public func brightBlue<T: StylableInputConvertible>(_ input: T) -> TextChunk {
    applyStyle(input, StyleAttrs(fg: "brightBlue"))
}

// parity: core/src/lib/styled-text.ts#brightMagenta [status=implemented hash=71f74aa11f8b]
public func brightMagenta<T: StylableInputConvertible>(_ input: T) -> TextChunk {
    applyStyle(input, StyleAttrs(fg: "brightMagenta"))
}

// parity: core/src/lib/styled-text.ts#brightCyan [status=implemented hash=6e30a7a99d83]
public func brightCyan<T: StylableInputConvertible>(_ input: T) -> TextChunk {
    applyStyle(input, StyleAttrs(fg: "brightCyan"))
}

// parity: core/src/lib/styled-text.ts#brightWhite [status=implemented hash=82e9b71704c9]
public func brightWhite<T: StylableInputConvertible>(_ input: T) -> TextChunk {
    applyStyle(input, StyleAttrs(fg: "brightWhite"))
}

// MARK: - Background Color Functions

// parity: core/src/lib/styled-text.ts#bgBlack [status=implemented hash=f557df882b2f]
public func bgBlack<T: StylableInputConvertible>(_ input: T) -> TextChunk {
    applyStyle(input, StyleAttrs(bg: "black"))
}

// parity: core/src/lib/styled-text.ts#bgRed [status=implemented hash=2f35455f8f85]
public func bgRed<T: StylableInputConvertible>(_ input: T) -> TextChunk {
    applyStyle(input, StyleAttrs(bg: "red"))
}

// parity: core/src/lib/styled-text.ts#bgGreen [status=implemented hash=09921d92f9b8]
public func bgGreen<T: StylableInputConvertible>(_ input: T) -> TextChunk {
    applyStyle(input, StyleAttrs(bg: "green"))
}

// parity: core/src/lib/styled-text.ts#bgYellow [status=implemented hash=35bd0ac79868]
public func bgYellow<T: StylableInputConvertible>(_ input: T) -> TextChunk {
    applyStyle(input, StyleAttrs(bg: "yellow"))
}

// parity: core/src/lib/styled-text.ts#bgBlue [status=implemented hash=3373b74930b5]
public func bgBlue<T: StylableInputConvertible>(_ input: T) -> TextChunk {
    applyStyle(input, StyleAttrs(bg: "blue"))
}

// parity: core/src/lib/styled-text.ts#bgMagenta [status=implemented hash=3c50e41467e4]
public func bgMagenta<T: StylableInputConvertible>(_ input: T) -> TextChunk {
    applyStyle(input, StyleAttrs(bg: "magenta"))
}

// parity: core/src/lib/styled-text.ts#bgCyan [status=implemented hash=f9171c1a5fe1]
public func bgCyan<T: StylableInputConvertible>(_ input: T) -> TextChunk {
    applyStyle(input, StyleAttrs(bg: "cyan"))
}

// parity: core/src/lib/styled-text.ts#bgWhite [status=implemented hash=9838f50be246]
public func bgWhite<T: StylableInputConvertible>(_ input: T) -> TextChunk {
    applyStyle(input, StyleAttrs(bg: "white"))
}

// MARK: - Attribute Style Functions

// parity: core/src/lib/styled-text.ts#bold [status=implemented hash=739671e84c24]
public func bold<T: StylableInputConvertible>(_ input: T) -> TextChunk {
    applyStyle(input, StyleAttrs(bold: true))
}

// parity: core/src/lib/styled-text.ts#italic [status=implemented hash=a80e6db5bdc3]
public func italic<T: StylableInputConvertible>(_ input: T) -> TextChunk {
    applyStyle(input, StyleAttrs(italic: true))
}

// parity: core/src/lib/styled-text.ts#underline [status=implemented hash=ad5ec0acec77]
public func underline<T: StylableInputConvertible>(_ input: T) -> TextChunk {
    applyStyle(input, StyleAttrs(underline: true))
}

// parity: core/src/lib/styled-text.ts#strikethrough [status=implemented hash=ab1de3ac6171]
public func strikethrough<T: StylableInputConvertible>(_ input: T) -> TextChunk {
    applyStyle(input, StyleAttrs(strikethrough: true))
}

// parity: core/src/lib/styled-text.ts#dim [status=implemented hash=56c7359eca79]
public func dim<T: StylableInputConvertible>(_ input: T) -> TextChunk {
    applyStyle(input, StyleAttrs(dim: true))
}

// parity: core/src/lib/styled-text.ts#reverse [status=implemented hash=d54009cc6697]
public func reverse<T: StylableInputConvertible>(_ input: T) -> TextChunk {
    applyStyle(input, StyleAttrs(reverse: true))
}

// parity: core/src/lib/styled-text.ts#blink [status=implemented hash=7bd0d9d248ac]
public func blink<T: StylableInputConvertible>(_ input: T) -> TextChunk {
    applyStyle(input, StyleAttrs(blink: true))
}

/// Alias for `reverse(_:)`, applying `TextAttributes.inverse`.
public func inverse<T: StylableInputConvertible>(_ input: T) -> TextChunk {
    applyStyle(input, StyleAttrs(inverse: true))
}

/// Applies `TextAttributes.hidden` to a value or `TextChunk`.
public func hidden<T: StylableInputConvertible>(_ input: T) -> TextChunk {
    applyStyle(input, StyleAttrs(hidden: true))
}

// MARK: - Custom Color & Link Functions

// parity: core/src/lib/styled-text.ts#fg [status=implemented hash=8b3b863f95a6]
public func fg<C: ColorConvertible>(_ color: C) -> StyleTransform {
    let resolved = color.asColor()
    return StyleTransform { input in
        applyStyle(input, StyleAttrs(fg: resolved))
    }
}

// parity: core/src/lib/styled-text.ts#bg [status=implemented hash=dcca98de8678]
public func bg<C: ColorConvertible>(_ color: C) -> StyleTransform {
    let resolved = color.asColor()
    return StyleTransform { input in
        applyStyle(input, StyleAttrs(bg: resolved))
    }
}

// parity: core/src/lib/styled-text.ts#link [status=implemented hash=33d00d192be0]
public func link(_ url: String) -> StyleTransform {
    StyleTransform { input in
        var chunk: TextChunk
        if case .chunk(let existing) = input {
            chunk = existing
        } else {
            chunk = TextChunk(text: input.plainTextString)
        }
        chunk.link = TextChunkLink(url: url)
        return chunk
    }
}

// MARK: - Template / Interpolation Builder

/// Builds a `StyledText` from template string segments and interpolated values, matching JS tagged template `t`.
// parity: core/src/lib/styled-text.ts#t [status=implemented hash=ac4f80aaf2bb]
public func t(_ strings: [String], _ values: [StylableInput] = []) -> StyledText {
    var chunks: [TextChunk] = []
    chunks.reserveCapacity(strings.count + values.count)

    for index in strings.indices {
        let raw = strings[index]
        if !raw.isEmpty {
            chunks.append(TextChunk(text: raw, attributes: 0))
        }

        if index < values.count {
            let value = values[index]
            if case .chunk(let existing) = value {
                chunks.append(existing)
            } else {
                chunks.append(TextChunk(text: value.plainTextString, attributes: 0))
            }
        }
    }

    return StyledText(chunks: chunks)
}

/// Swift string-interpolation convenience matching JS `` t`...` ``: `t("Hello \(bold(red("world")))!")`.
public func t(_ styled: StyledText) -> StyledText {
    styled
}

extension StyledText: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    public struct StringInterpolation: StringInterpolationProtocol {
        internal var chunks: [TextChunk] = []

        public init(literalCapacity: Int, interpolationCount: Int) {
            chunks.reserveCapacity(interpolationCount * 2 + 1)
        }

        public mutating func appendLiteral(_ literal: String) {
            if !literal.isEmpty {
                chunks.append(TextChunk(text: literal, attributes: 0))
            }
        }

        public mutating func appendInterpolation<T: StylableInputConvertible>(_ value: T) {
            let input = value.asStylableInput()
            if case .chunk(let existing) = input {
                chunks.append(existing)
            } else {
                chunks.append(TextChunk(text: input.plainTextString, attributes: 0))
            }
        }
    }

    public init(stringLiteral value: String) {
        if value.isEmpty {
            self.chunks = []
        } else {
            self.chunks = [TextChunk(text: value, attributes: 0)]
        }
    }

    public init(stringInterpolation: StringInterpolation) {
        self.chunks = stringInterpolation.chunks
    }
}
