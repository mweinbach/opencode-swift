/// Pure-Swift ASCII banner font measurement, hit-testing, and framebuffer rendering
/// matching `packages/core/src/lib/ascii.font.ts`.

// MARK: - Font Types

// parity: core/src/lib/ascii.font.ts#ASCIIFontName [status=implemented hash=00a7847f1df2]
public enum ASCIIFontName: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
    case tiny
    case block
    case shade
    case slick
    case huge
    case grid
    case pallet
}

/// Horizontal alignment when rendering an ASCII font into a framebuffer region.
public enum ASCIIFontAlignment: String, Equatable, Hashable, Sendable, Codable {
    case left
    case center
    case right
}

/// Raw cfonts font definition with embedded `<cN>...</cN>` color tags.
public struct ASCIIFontDefinition: Equatable, Hashable, Sendable {
    public let name: String
    public let lines: Int
    public let letterspaceSize: Int
    public let letterspace: [String]
    public let colors: Int
    public let chars: [String: [String]]

    public init(
        name: String,
        lines: Int,
        letterspaceSize: Int,
        letterspace: [String],
        colors: Int = 1,
        chars: [String: [String]]
    ) {
        self.name = name
        self.lines = lines
        self.letterspaceSize = letterspaceSize
        self.letterspace = letterspace
        self.colors = max(1, colors)
        self.chars = chars
    }
}

/// Single color-tagged text run inside one row of a parsed ASCII font glyph.
public struct ASCIIFontSegment: Equatable, Hashable, Sendable {
    public let text: String
    public let colorIndex: Int

    public init(text: String, colorIndex: Int) {
        self.text = text
        self.colorIndex = colorIndex
    }
}

/// Pre-parsed font definition with `<cN>` color tags resolved into `ASCIIFontSegment` runs.
public struct ParsedASCIIFontDefinition: Equatable, Hashable, Sendable {
    public let name: String
    public let lines: Int
    public let letterspaceSize: Int
    public let letterspace: [String]
    public let colors: Int
    public let chars: [String: [[ASCIIFontSegment]]]

    public init(definition: ASCIIFontDefinition) {
        self.name = definition.name
        self.lines = definition.lines
        self.letterspaceSize = definition.letterspaceSize
        self.letterspace = definition.letterspace
        self.colors = max(1, definition.colors)
        var parsed: [String: [[ASCIIFontSegment]]] = [:]
        parsed.reserveCapacity(definition.chars.count)
        for (key, glyphLines) in definition.chars {
            parsed[key] = glyphLines.map { parseASCIIFontColorTags($0) }
        }
        self.chars = parsed
    }
}

/// Measured cell dimensions of a rendered ASCII font string.
public struct ASCIIFontMeasurement: Equatable, Hashable, Sendable, Codable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// Options struct for `renderFontToFrameBuffer(_:options:)`.
public struct RenderFontOptions: Equatable, Sendable {
    public var text: String
    public var x: Int
    public var y: Int
    public var colors: [RGBA]
    public var backgroundColor: RGBA
    public var font: ASCIIFontName
    public var alignment: ASCIIFontAlignment
    public var maxWidth: Int?

    public init(
        text: String,
        x: Int = 0,
        y: Int = 0,
        colors: [RGBA] = [RGBA.fromInts(255, 255, 255, 255)],
        backgroundColor: RGBA = RGBA.fromInts(0, 0, 0, 255),
        font: ASCIIFontName = .tiny,
        alignment: ASCIIFontAlignment = .left,
        maxWidth: Int? = nil
    ) {
        self.text = text
        self.x = x
        self.y = y
        self.colors = colors.isEmpty ? [RGBA.fromInts(255, 255, 255, 255)] : colors
        self.backgroundColor = backgroundColor
        self.font = font
        self.alignment = alignment
        self.maxWidth = maxWidth
    }

    public init(
        text: String,
        x: Int = 0,
        y: Int = 0,
        color: RGBA,
        backgroundColor: RGBA = RGBA.fromInts(0, 0, 0, 255),
        font: ASCIIFontName = .tiny,
        alignment: ASCIIFontAlignment = .left,
        maxWidth: Int? = nil
    ) {
        self.init(
            text: text,
            x: x,
            y: y,
            colors: [color],
            backgroundColor: backgroundColor,
            font: font,
            alignment: alignment,
            maxWidth: maxWidth
        )
    }
}

// MARK: - Embedded Font Registry

// parity: core/src/lib/ascii.font.ts#fonts [status=implemented hash=a1d083bb4317]
public let asciiFonts: [ASCIIFontName: ASCIIFontDefinition] = [
    .tiny: ASCIIFontTables.tiny,
    .block: ASCIIFontTables.block,
    .shade: ASCIIFontTables.shade,
    .slick: ASCIIFontTables.slick,
    .huge: ASCIIFontTables.huge,
    .grid: ASCIIFontTables.grid,
    .pallet: ASCIIFontTables.pallet,
]

private let parsedASCIIFontCache: [ASCIIFontName: ParsedASCIIFontDefinition] = {
    var cache: [ASCIIFontName: ParsedASCIIFontDefinition] = [:]
    cache.reserveCapacity(ASCIIFontName.allCases.count)
    for name in ASCIIFontName.allCases {
        cache[name] = ParsedASCIIFontDefinition(definition: ASCIIFontTables.definition(for: name))
    }
    return cache
}()

/// Returns the parsed, color-tag-resolved font definition for `font`.
public func parsedASCIIFont(_ font: ASCIIFontName) -> ParsedASCIIFontDefinition {
    parsedASCIIFontCache[font] ?? ParsedASCIIFontDefinition(definition: ASCIIFontTables.definition(for: font))
}

// MARK: - Color Tag Parser

/// Pure-Swift parser matching upstream `/<c(\d+)>(.*?)<\/c\d+>/g`.
public func parseASCIIFontColorTags(_ text: String) -> [ASCIIFontSegment] {
    let scalars = Array(text.unicodeScalars)
    let count = scalars.count
    var segments: [ASCIIFontSegment] = []
    var lastIndex = 0
    var i = 0

    @inline(__always)
    func isAsciiDigit(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 0x30 && scalar.value <= 0x39
    }

    while i < count {
        // Match `<c(\d+)>`
        if scalars[i] == "<", i + 2 < count, scalars[i + 1] == "c", isAsciiDigit(scalars[i + 2]) {
            var numEnd = i + 2
            var colorNum = 0
            while numEnd < count && isAsciiDigit(scalars[numEnd]) {
                colorNum = colorNum * 10 + Int(scalars[numEnd].value - 0x30)
                numEnd += 1
            }
            if numEnd < count && scalars[numEnd] == ">" {
                let contentStart = numEnd + 1
                // Search forward for earliest `</c\d+>` without crossing newline
                var search = contentStart
                var closeStart: Int? = nil
                var closeEnd: Int? = nil

                while search < count {
                    let s = scalars[search]
                    if s == "\n" || s == "\r" { break }
                    if s == "<",
                       search + 3 < count,
                       scalars[search + 1] == "/",
                       scalars[search + 2] == "c",
                       isAsciiDigit(scalars[search + 3])
                    {
                        var cEnd = search + 3
                        while cEnd < count && isAsciiDigit(scalars[cEnd]) {
                            cEnd += 1
                        }
                        if cEnd < count && scalars[cEnd] == ">" {
                            closeStart = search
                            closeEnd = cEnd + 1
                            break
                        }
                    }
                    search += 1
                }

                if let cStart = closeStart, let cEnd = closeEnd {
                    if i > lastIndex {
                        let plain = String(String.UnicodeScalarView(scalars[lastIndex..<i]))
                        if !plain.isEmpty {
                            segments.append(ASCIIFontSegment(text: plain, colorIndex: 0))
                        }
                    }
                    let tagged = String(String.UnicodeScalarView(scalars[contentStart..<cStart]))
                    segments.append(ASCIIFontSegment(text: tagged, colorIndex: max(0, colorNum - 1)))
                    lastIndex = cEnd
                    i = cEnd
                    continue
                }
            }
        }
        i += 1
    }

    if lastIndex < count {
        let remaining = String(String.UnicodeScalarView(scalars[lastIndex..<count]))
        if !remaining.isEmpty {
            segments.append(ASCIIFontSegment(text: remaining, colorIndex: 0))
        }
    }

    return segments
}

// MARK: - Internal Helpers

@inline(__always)
private func uppercaseKeyForUTF16Unit(_ unit: UInt16) -> String {
    if unit >= 0x61 && unit <= 0x7A {
        return String(Unicode.Scalar(UInt32(unit - 0x20))!)
    }
    if let scalar = Unicode.Scalar(UInt32(unit)) {
        return String(scalar).uppercased()
    }
    return ""
}

@inline(__always)
private func segmentLineWidth(_ segments: [ASCIIFontSegment]) -> Int {
    var total = 0
    for segment in segments {
        total += segment.text.utf16.count
    }
    return total
}

@inline(__always)
private func fallbackSpaceWidth(in fontDef: ParsedASCIIFontDefinition) -> Int {
    if let spaceChar = fontDef.chars[" "], let firstLine = spaceChar.first {
        return segmentLineWidth(firstLine)
    }
    return 1
}

// MARK: - Measurement, Positions, Hit-Testing & Rendering

/// Measures the cell width and height of `text` rendered in `font`.
// parity: core/src/lib/ascii.font.ts#measureText [status=implemented hash=9e2eb8274717]
public func measureAsciiText(_ text: String, font: ASCIIFontName = .tiny) -> ASCIIFontMeasurement {
    let fontDef = parsedASCIIFont(font)
    let units = Array(text.utf16)
    var currentX = 0

    for i in 0..<units.count {
        let key = uppercaseKeyForUTF16Unit(units[i])
        guard let charDef = fontDef.chars[key] else {
            currentX += fallbackSpaceWidth(in: fontDef)
            continue
        }

        let charWidth = charDef.first.map(segmentLineWidth) ?? 0
        currentX += charWidth

        if i < units.count - 1 {
            currentX += fontDef.letterspaceSize
        }
    }

    return ASCIIFontMeasurement(width: currentX, height: fontDef.lines)
}

/// Returns cumulative horizontal cell boundaries for each character index in `text`
/// (`positions.count == text.utf16.count + 1`).
// parity: core/src/lib/ascii.font.ts#getCharacterPositions [status=implemented hash=bccf4c5db820]
public func getCharacterPositions(_ text: String, font: ASCIIFontName = .tiny) -> [Int] {
    let fontDef = parsedASCIIFont(font)
    let units = Array(text.utf16)
    var positions: [Int] = [0]
    positions.reserveCapacity(units.count + 1)
    var currentX = 0

    for i in 0..<units.count {
        let key = uppercaseKeyForUTF16Unit(units[i])
        let charWidth: Int
        if let charDef = fontDef.chars[key] {
            charWidth = charDef.first.map(segmentLineWidth) ?? 0
        } else {
            charWidth = fallbackSpaceWidth(in: fontDef)
        }

        currentX += charWidth

        if i < units.count - 1 {
            currentX += fontDef.letterspaceSize
        }

        positions.append(currentX)
    }

    return positions
}

/// Maps a local horizontal cell coordinate `x` to the nearest character index in `text`.
// parity: core/src/lib/ascii.font.ts#coordinateToCharacterIndex [status=implemented hash=215e11f0d073]
public func coordinateToCharacterIndex(_ x: Int, text: String, font: ASCIIFontName = .tiny) -> Int {
    let positions = getCharacterPositions(text, font: font)

    if x < 0 {
        return 0
    }

    if positions.count >= 2 {
        for i in 0..<(positions.count - 1) {
            let currentPos = positions[i]
            let nextPos = positions[i + 1]

            if x >= currentPos && x < nextPos {
                let charMidpoint = Double(currentPos) + Double(nextPos - currentPos) / 2.0
                return Double(x) < charMidpoint ? i : i + 1
            }
        }
    }

    if let last = positions.last, x >= last {
        return text.utf16.count
    }

    return 0
}

/// Renders an ASCII banner font directly into `buffer` with `<c1>`/`<c2>` multi-color support,
/// optional horizontal alignment, and alpha blending.
// parity: core/src/lib/ascii.font.ts#renderFontToFrameBuffer [status=implemented hash=724f026224e8]
@discardableResult
public func renderFontToFrameBuffer(
    _ buffer: OptimizedBuffer,
    text: String,
    x: Int = 0,
    y: Int = 0,
    colors: [RGBA] = [RGBA.fromInts(255, 255, 255, 255)],
    backgroundColor: RGBA = RGBA.fromInts(0, 0, 0, 255),
    font: ASCIIFontName = .tiny,
    alignment: ASCIIFontAlignment = .left,
    maxWidth: Int? = nil
) -> ASCIIFontMeasurement {
    let width = buffer.width
    let height = buffer.height
    let fontDef = parsedASCIIFont(font)
    let resolvedColors = colors.isEmpty ? [RGBA.fromInts(255, 255, 255, 255)] : colors

    let startX: Int
    switch alignment {
    case .left:
        startX = x
    case .center:
        let measured = measureAsciiText(text, font: font)
        let areaWidth = maxWidth ?? max(0, width - x)
        startX = x + max(0, (areaWidth - measured.width) / 2)
    case .right:
        let measured = measureAsciiText(text, font: font)
        let areaWidth = maxWidth ?? max(0, width - x)
        startX = x + max(0, areaWidth - measured.width)
    }

    var currentX = startX
    let units = Array(text.utf16)

    for i in 0..<units.count {
        let key = uppercaseKeyForUTF16Unit(units[i])
        guard let charDef = fontDef.chars[key] else {
            currentX += fallbackSpaceWidth(in: fontDef)
            continue
        }

        let charWidth = charDef.first.map(segmentLineWidth) ?? 0
        if currentX >= width { break }
        if currentX + charWidth < 0 {
            currentX += charWidth + fontDef.letterspaceSize
            continue
        }

        let rowLimit = min(fontDef.lines, charDef.count)
        for lineIdx in 0..<rowLimit {
            let renderY = y + lineIdx
            guard renderY >= 0 && renderY < height else { continue }

            let segments = charDef[lineIdx]
            var segmentX = currentX

            for segment in segments {
                let segmentColor = segment.colorIndex < resolvedColors.count
                    ? resolvedColors[segment.colorIndex]
                    : resolvedColors[0]

                var charOffset = 0
                for scalar in segment.text.unicodeScalars {
                    let renderX = segmentX + charOffset
                    if renderX >= 0 && renderX < width && scalar != " " {
                        buffer.setCellWithAlphaBlending(
                            x: renderX,
                            y: renderY,
                            char: String(scalar),
                            fg: segmentColor,
                            bg: backgroundColor
                        )
                    }
                    charOffset += 1
                }

                segmentX += segment.text.utf16.count
            }
        }

        currentX += charWidth
        if i < units.count - 1 {
            currentX += fontDef.letterspaceSize
        }
    }

    return ASCIIFontMeasurement(width: currentX - startX, height: fontDef.lines)
}

/// Overload accepting a `RenderFontOptions` configuration struct.
@discardableResult
public func renderFontToFrameBuffer(
    _ buffer: OptimizedBuffer,
    options: RenderFontOptions
) -> ASCIIFontMeasurement {
    renderFontToFrameBuffer(
        buffer,
        text: options.text,
        x: options.x,
        y: options.y,
        colors: options.colors,
        backgroundColor: options.backgroundColor,
        font: options.font,
        alignment: options.alignment,
        maxWidth: options.maxWidth
    )
}

/// Overload accepting CSS/hex color strings (parsed via `parseColor`).
@discardableResult
public func renderFontToFrameBuffer(
    _ buffer: OptimizedBuffer,
    text: String,
    x: Int = 0,
    y: Int = 0,
    colorStrings: [String],
    backgroundColor: String = "#000000",
    font: ASCIIFontName = .tiny,
    alignment: ASCIIFontAlignment = .left,
    maxWidth: Int? = nil
) -> ASCIIFontMeasurement {
    let parsedColors = colorStrings.map { parseColor($0) }
    return renderFontToFrameBuffer(
        buffer,
        text: text,
        x: x,
        y: y,
        colors: parsedColors,
        backgroundColor: parseColor(backgroundColor),
        font: font,
        alignment: alignment,
        maxWidth: maxWidth
    )
}

/// Namespace facade mirroring `lib/ascii.font.ts` exports.
public enum ASCIIFont {
    public static var fonts: [ASCIIFontName: ASCIIFontDefinition] {
        asciiFonts
    }

    public static func definition(for font: ASCIIFontName) -> ASCIIFontDefinition {
        ASCIIFontTables.definition(for: font)
    }

    public static func parsedDefinition(for font: ASCIIFontName) -> ParsedASCIIFontDefinition {
        parsedASCIIFont(font)
    }

    public static func measureText(_ text: String, font: ASCIIFontName = .tiny) -> ASCIIFontMeasurement {
        measureAsciiText(text, font: font)
    }

    public static func getCharacterPositions(_ text: String, font: ASCIIFontName = .tiny) -> [Int] {
        OpenTUICore.getCharacterPositions(text, font: font)
    }

    public static func coordinateToCharacterIndex(_ x: Int, text: String, font: ASCIIFontName = .tiny) -> Int {
        OpenTUICore.coordinateToCharacterIndex(x, text: text, font: font)
    }

    @discardableResult
    public static func renderToFrameBuffer(
        _ buffer: OptimizedBuffer,
        options: RenderFontOptions
    ) -> ASCIIFontMeasurement {
        renderFontToFrameBuffer(buffer, options: options)
    }
}
