import OpenTUICore
import OpenTUIKeymap
import OpenTUILayout

// MARK: - EmbeddedTerminal Types

/// Source of outgoing byte payloads emitted by `EmbeddedTerminalRenderable.onData`.
// parity: core/src/renderables/EmbeddedTerminal.ts#EmbeddedTerminalDataSource [status=implemented hash=1a99824a36ce]
public enum EmbeddedTerminalDataSource: String, Equatable, Hashable, Sendable, Codable {
    case input
    case response
}

/// Cursor snapshot reported by `EmbeddedTerminalScreen`.
public struct EmbeddedTerminalCursor: Equatable, Hashable, Sendable, Codable {
    public var x: Int
    public var y: Int
    public var visible: Bool
    public var style: CursorStyle
    public var blinking: Bool

    public init(
        x: Int = 0,
        y: Int = 0,
        visible: Bool = true,
        style: CursorStyle = .block,
        blinking: Bool = false
    ) {
        self.x = x
        self.y = y
        self.visible = visible
        self.style = style
        self.blinking = blinking
    }
}

/// Textual and geometric snapshot of an embedded terminal's visible screen.
// parity: core/src/renderables/EmbeddedTerminal.ts#EmbeddedTerminalScreen [status=implemented hash=3eecda2f3b03]
public struct EmbeddedTerminalScreen: Equatable, Hashable, Sendable, Codable {
    public var text: String
    public var lines: [String]
    public var columns: Int
    public var rows: Int
    public var cursor: EmbeddedTerminalCursor

    public init(
        text: String,
        lines: [String],
        columns: Int,
        rows: Int,
        cursor: EmbeddedTerminalCursor
    ) {
        self.text = text
        self.lines = lines
        self.columns = columns
        self.rows = rows
        self.cursor = cursor
    }
}

/// Scrollbar state for `EmbeddedTerminalRenderable.getScroll()`.
public struct EmbeddedTerminalScrollState: Equatable, Hashable, Sendable, Codable {
    public var offset: Int
    public var total: Int
    public var visible: Int

    public init(offset: Int = 0, total: Int = 0, visible: Int = 0) {
        self.offset = offset
        self.total = total
        self.visible = visible
    }
}

/// Configuration options for `EmbeddedTerminalRenderable`.
// parity: core/src/renderables/EmbeddedTerminal.ts#EmbeddedTerminalOptions [status=implemented hash=411d3e224c83]
public struct EmbeddedTerminalOptions {
    public var base: RenderableOptions
    public var cols: Int?
    public var rows: Int?
    public var maxScrollback: Int?
    public var transparentBackground: Bool?
    public var onData: (([UInt8], EmbeddedTerminalDataSource) -> Void)?
    public var onTerminalResize: ((Int, Int) -> Void)?
    public var onScreenChange: (() -> Void)?
    public var selectable: Bool?

    public init(
        id: String? = nil,
        width: FlexValue? = nil,
        height: FlexValue? = nil,
        minWidth: FlexValue? = nil,
        maxWidth: FlexValue? = nil,
        minHeight: FlexValue? = nil,
        maxHeight: FlexValue? = nil,
        flexGrow: Float? = nil,
        flexShrink: Float? = nil,
        position: PositionType? = nil,
        top: FlexValue? = nil,
        right: FlexValue? = nil,
        bottom: FlexValue? = nil,
        left: FlexValue? = nil,
        margin: FlexValue? = nil,
        padding: FlexValue? = nil,
        zIndex: Int? = nil,
        visible: Bool? = nil,
        cols: Int? = nil,
        rows: Int? = nil,
        maxScrollback: Int? = nil,
        transparentBackground: Bool? = nil,
        onData: (([UInt8], EmbeddedTerminalDataSource) -> Void)? = nil,
        onTerminalResize: ((Int, Int) -> Void)? = nil,
        onScreenChange: (() -> Void)? = nil,
        selectable: Bool? = nil,
        onMouseDown: ((MouseEvent) -> Void)? = nil,
        onMouseUp: ((MouseEvent) -> Void)? = nil,
        onMouseMove: ((MouseEvent) -> Void)? = nil,
        onMouseDrag: ((MouseEvent) -> Void)? = nil,
        onMouseScroll: ((MouseEvent) -> Void)? = nil
    ) {
        self.base = RenderableOptions(
            id: id,
            width: width,
            height: height,
            minWidth: minWidth,
            maxWidth: maxWidth,
            minHeight: minHeight,
            maxHeight: maxHeight,
            flexGrow: flexGrow,
            flexShrink: flexShrink,
            position: position,
            top: top,
            right: right,
            bottom: bottom,
            left: left,
            margin: margin,
            padding: padding,
            zIndex: zIndex,
            visible: visible,
            focusable: true,
            selectable: selectable,
            buffered: true,
            onMouseDown: onMouseDown,
            onMouseUp: onMouseUp,
            onMouseMove: onMouseMove,
            onMouseDrag: onMouseDrag,
            onMouseScroll: onMouseScroll
        )
        self.cols = cols
        self.rows = rows
        self.maxScrollback = maxScrollback
        self.transparentBackground = transparentBackground
        self.onData = onData
        self.onTerminalResize = onTerminalResize
        self.onScreenChange = onScreenChange
        self.selectable = selectable
    }
}

// MARK: - Pure-Swift VT/ANSI Terminal Emulator

private final class EmbeddedTerminalEmulator {
    private enum ParserState {
        case ground
        case escape
        case csi
        case osc
        case oscEscape
    }

    private static let defaultFg = RGBA.defaultForeground()
    private static let defaultBg = RGBA.defaultBackground()
    private static let ansi16Colors: [RGBA] = [
        RGBA.fromInts(0x00, 0x00, 0x00, 255),
        RGBA.fromInts(0x80, 0x00, 0x00, 255),
        RGBA.fromInts(0x00, 0x80, 0x00, 255),
        RGBA.fromInts(0x80, 0x80, 0x00, 255),
        RGBA.fromInts(0x00, 0x00, 0x80, 255),
        RGBA.fromInts(0x80, 0x00, 0x80, 255),
        RGBA.fromInts(0x00, 0x80, 0x80, 255),
        RGBA.fromInts(0xC0, 0xC0, 0xC0, 255),
        RGBA.fromInts(0x80, 0x80, 0x80, 255),
        RGBA.fromInts(0xFF, 0x00, 0x00, 255),
        RGBA.fromInts(0x00, 0xFF, 0x00, 255),
        RGBA.fromInts(0xFF, 0xFF, 0x00, 255),
        RGBA.fromInts(0x00, 0x00, 0xFF, 255),
        RGBA.fromInts(0xFF, 0x00, 0xFF, 255),
        RGBA.fromInts(0x00, 0xFF, 0xFF, 255),
        RGBA.fromInts(0xFF, 0xFF, 0xFF, 255),
    ]

    var cols: Int
    var rows: Int
    let maxScrollback: Int

    var grid: [[TerminalCell]]
    var scrollback: [[TerminalCell]] = []
    var scrollOffset: Int = 0

    var cursorX: Int = 0
    var cursorY: Int = 0
    var cursorVisible: Bool = true
    var cursorStyle: CursorStyle = .block
    var cursorBlinking: Bool = false
    var wrapPending: Bool = false

    private var savedCursorX: Int = 0
    private var savedCursorY: Int = 0
    private var savedPrimaryGrid: [[TerminalCell]]? = nil
    private var savedPrimaryCursor: (x: Int, y: Int)? = nil
    var isAltScreen: Bool = false

    var currentFg: RGBA = defaultFg
    var currentBg: RGBA = defaultBg
    var currentAttributes: UInt32 = TextAttributes.none

    var bracketedPasteMode: Bool = false
    var focusReportingMode: Bool = false
    var mouseReportingMode: Bool = false
    var sgrMouseMode: Bool = false

    var transparentBackground: Bool = false

    var selectionStart: SelectionPoint? = nil
    var selectionEnd: SelectionPoint? = nil

    private var parserState: ParserState = .ground
    private var csiBuffer: [UInt8] = []
    private var pendingUTF8: [UInt8] = []
    private var pendingResponses: [UInt8] = []

    init(cols: Int, rows: Int, maxScrollback: Int = 1000) {
        self.cols = max(1, cols)
        self.rows = max(1, rows)
        self.maxScrollback = max(0, maxScrollback)
        self.grid = Self.makeBlankGrid(cols: self.cols, rows: self.rows)
    }

    private static func blankCell(bg: RGBA = defaultBg) -> TerminalCell {
        TerminalCell(
            scalar: defaultSpaceChar,
            foreground: defaultFg,
            background: bg,
            attributes: TextAttributes.none
        )
    }

    private static func makeBlankRow(cols: Int, bg: RGBA = defaultBg) -> [TerminalCell] {
        Array(repeating: blankCell(bg: bg), count: max(1, cols))
    }

    private static func makeBlankGrid(cols: Int, rows: Int, bg: RGBA = defaultBg) -> [[TerminalCell]] {
        Array(repeating: makeBlankRow(cols: cols, bg: bg), count: max(1, rows))
    }

    func reset() {
        grid = Self.makeBlankGrid(cols: cols, rows: rows)
        scrollback.removeAll()
        scrollOffset = 0
        cursorX = 0
        cursorY = 0
        cursorVisible = true
        cursorStyle = .block
        cursorBlinking = false
        wrapPending = false
        currentFg = Self.defaultFg
        currentBg = Self.defaultBg
        currentAttributes = TextAttributes.none
        bracketedPasteMode = false
        focusReportingMode = false
        mouseReportingMode = false
        sgrMouseMode = false
        isAltScreen = false
        savedPrimaryGrid = nil
        savedPrimaryCursor = nil
    }

    func resize(cols newCols: Int, rows newRows: Int) {
        let targetCols = max(1, newCols)
        let targetRows = max(1, newRows)
        guard targetCols != cols || targetRows != rows else { return }

        var nextGrid: [[TerminalCell]] = []
        nextGrid.reserveCapacity(targetRows)
        for r in 0..<targetRows {
            if r < grid.count {
                var row = grid[r]
                if row.count < targetCols {
                    row.append(contentsOf: Array(repeating: Self.blankCell(), count: targetCols - row.count))
                } else if row.count > targetCols {
                    row.removeLast(row.count - targetCols)
                }
                nextGrid.append(row)
            } else {
                nextGrid.append(Self.makeBlankRow(cols: targetCols))
            }
        }
        grid = nextGrid
        cols = targetCols
        rows = targetRows
        cursorX = max(0, min(cursorX, cols - 1))
        cursorY = max(0, min(cursorY, rows - 1))
        wrapPending = false
        scrollOffset = min(scrollOffset, scrollback.count)
    }

    func scrollViewport(delta: Int) {
        guard !isAltScreen else { return }
        // Negative delta scrolls up into scrollback (increasing scrollOffset); positive scrolls down toward live (0).
        let next = scrollOffset - delta
        scrollOffset = max(0, min(next, scrollback.count))
    }

    func scrollState() -> EmbeddedTerminalScrollState {
        let total = isAltScreen ? rows : (scrollback.count + rows)
        return EmbeddedTerminalScrollState(offset: scrollOffset, total: total, visible: rows)
    }

    func drainResponses() -> [UInt8] {
        guard !pendingResponses.isEmpty else { return [] }
        let out = pendingResponses
        pendingResponses.removeAll(keepingCapacity: true)
        return out
    }

    func write(_ bytes: [UInt8]) {
        for byte in bytes {
            feedByte(byte)
        }
        flushPendingUTF8IfComplete()
    }

    private func feedByte(_ byte: UInt8) {
        switch parserState {
        case .ground:
            if byte == 0x1B {
                flushPendingUTF8()
                parserState = .escape
            } else if byte < 0x20 || byte == 0x7F {
                flushPendingUTF8()
                handleControlByte(byte)
            } else if byte < 0x80 {
                flushPendingUTF8()
                putScalar(Unicode.Scalar(byte))
            } else {
                pendingUTF8.append(byte)
                flushPendingUTF8IfComplete()
            }

        case .escape:
            if byte == 0x5B { // '['
                csiBuffer.removeAll(keepingCapacity: true)
                parserState = .csi
            } else if byte == 0x5D { // ']'
                parserState = .osc
            } else if byte == 0x37 { // '7' DECSC
                savedCursorX = cursorX
                savedCursorY = cursorY
                parserState = .ground
            } else if byte == 0x38 { // '8' DECRC
                cursorX = max(0, min(savedCursorX, cols - 1))
                cursorY = max(0, min(savedCursorY, rows - 1))
                wrapPending = false
                parserState = .ground
            } else if byte == 0x63 { // 'c' RIS
                reset()
                parserState = .ground
            } else if byte == 0x4D { // 'M' RI
                if cursorY > 0 {
                    cursorY -= 1
                } else {
                    scrollDown(lines: 1)
                }
                wrapPending = false
                parserState = .ground
            } else {
                parserState = .ground
            }

        case .csi:
            if byte >= 0x40 && byte <= 0x7E {
                dispatchCSI(finalByte: byte)
                csiBuffer.removeAll(keepingCapacity: true)
                parserState = .ground
            } else if byte == 0x1B {
                csiBuffer.removeAll(keepingCapacity: true)
                parserState = .escape
            } else {
                if csiBuffer.count < 256 {
                    csiBuffer.append(byte)
                }
            }

        case .osc:
            if byte == 0x07 { // BEL terminates OSC
                parserState = .ground
            } else if byte == 0x1B {
                parserState = .oscEscape
            }

        case .oscEscape:
            if byte == 0x5C { // '\' ST terminates OSC
                parserState = .ground
            } else {
                parserState = .osc
            }
        }
    }

    private func expectedUTF8Length(lead: UInt8) -> Int {
        if lead & 0xE0 == 0xC0 { return 2 }
        if lead & 0xF0 == 0xE0 { return 3 }
        if lead & 0xF8 == 0xF0 { return 4 }
        return 1
    }

    private func flushPendingUTF8IfComplete() {
        guard let first = pendingUTF8.first else { return }
        let expected = expectedUTF8Length(lead: first)
        if pendingUTF8.count >= expected {
            flushPendingUTF8()
        }
    }

    private func flushPendingUTF8() {
        guard !pendingUTF8.isEmpty else { return }
        let decoded = String(decoding: pendingUTF8, as: UTF8.self)
        pendingUTF8.removeAll(keepingCapacity: true)
        for scalar in decoded.unicodeScalars {
            putScalar(scalar)
        }
    }

    private func handleControlByte(_ byte: UInt8) {
        switch byte {
        case 0x0D: // CR
            cursorX = 0
            wrapPending = false
        case 0x0A, 0x0B, 0x0C: // LF / VT / FF
            lineFeed()
        case 0x08: // BS
            if cursorX > 0 {
                cursorX -= 1
            }
            wrapPending = false
        case 0x09: // TAB
            let nextTab = ((cursorX / 8) + 1) * 8
            cursorX = min(cols - 1, nextTab)
            wrapPending = false
        default:
            break
        }
    }

    private func lineFeed() {
        wrapPending = false
        if cursorY + 1 < rows {
            cursorY += 1
        } else {
            scrollUp(lines: 1)
        }
    }

    private func scrollUp(lines: Int) {
        let count = max(1, lines)
        for _ in 0..<count {
            guard !grid.isEmpty else { break }
            let removed = grid.removeFirst()
            if !isAltScreen && maxScrollback > 0 {
                scrollback.append(removed)
                if scrollback.count > maxScrollback {
                    scrollback.removeFirst(scrollback.count - maxScrollback)
                }
            }
            grid.append(Self.makeBlankRow(cols: cols, bg: currentBg))
        }
    }

    private func scrollDown(lines: Int) {
        let count = max(1, lines)
        for _ in 0..<count {
            guard !grid.isEmpty else { break }
            grid.removeLast()
            grid.insert(Self.makeBlankRow(cols: cols, bg: currentBg), at: 0)
        }
    }

    private func putScalar(_ scalar: Unicode.Scalar) {
        let width = Int(calculateTextWidth(String(scalar), tabWidth: 8, controlDisplay: .hidden, widthMethod: .unicode))
        if width <= 0 { return }

        if wrapPending {
            cursorX = 0
            lineFeed()
        }

        if cursorX + width > cols {
            cursorX = 0
            lineFeed()
        }

        guard cursorY >= 0 && cursorY < rows && cursorX >= 0 && cursorX < cols else { return }
        grid[cursorY][cursorX] = TerminalCell(
            scalar: scalar.value,
            foreground: currentFg,
            background: currentBg,
            attributes: currentAttributes
        )
        if width > 1 && cursorX + 1 < cols {
            grid[cursorY][cursorX + 1] = TerminalCell(
                scalar: defaultSpaceChar,
                foreground: currentFg,
                background: currentBg,
                attributes: currentAttributes
            )
        }

        if cursorX + width >= cols {
            cursorX = cols - 1
            wrapPending = true
        } else {
            cursorX += width
            wrapPending = false
        }
    }

    private func dispatchCSI(finalByte: UInt8) {
        let raw = String(decoding: csiBuffer, as: UTF8.self)
        let isPrivate = raw.hasPrefix("?")
        let hasSpaceIntermediate = raw.hasSuffix(" ")
        var paramStr = raw
        if isPrivate { paramStr = String(paramStr.dropFirst()) }
        if hasSpaceIntermediate { paramStr = String(paramStr.dropLast()) }

        let params: [Int] = paramStr.isEmpty
            ? []
            : paramStr.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }

        func param(_ index: Int, default defaultValue: Int) -> Int {
            guard index < params.count, params[index] > 0 else { return defaultValue }
            return params[index]
        }

        if isPrivate {
            let enable = (finalByte == 0x68) // 'h'
            let disable = (finalByte == 0x6C) // 'l'
            guard enable || disable else { return }
            let on = enable
            for code in params {
                switch code {
                case 25:
                    cursorVisible = on
                case 1000, 1002, 1003:
                    mouseReportingMode = on
                case 1006:
                    sgrMouseMode = on
                case 1004:
                    focusReportingMode = on
                case 2004:
                    bracketedPasteMode = on
                case 1049:
                    if on && !isAltScreen {
                        savedPrimaryGrid = grid
                        savedPrimaryCursor = (cursorX, cursorY)
                        grid = Self.makeBlankGrid(cols: cols, rows: rows)
                        cursorX = 0
                        cursorY = 0
                        isAltScreen = true
                        scrollOffset = 0
                    } else if !on && isAltScreen {
                        if let saved = savedPrimaryGrid {
                            grid = saved
                            resize(cols: cols, rows: rows)
                        }
                        if let cur = savedPrimaryCursor {
                            cursorX = max(0, min(cur.x, cols - 1))
                            cursorY = max(0, min(cur.y, rows - 1))
                        }
                        savedPrimaryGrid = nil
                        savedPrimaryCursor = nil
                        isAltScreen = false
                    }
                default:
                    break
                }
            }
            return
        }

        switch finalByte {
        case 0x6D: // 'm' SGR
            applySGR(params.isEmpty ? [0] : params)
        case 0x41: // 'A' CUU
            cursorY = max(0, cursorY - param(0, default: 1))
            wrapPending = false
        case 0x42: // 'B' CUD
            cursorY = min(rows - 1, cursorY + param(0, default: 1))
            wrapPending = false
        case 0x43: // 'C' CUF
            cursorX = min(cols - 1, cursorX + param(0, default: 1))
            wrapPending = false
        case 0x44: // 'D' CUB
            cursorX = max(0, cursorX - param(0, default: 1))
            wrapPending = false
        case 0x45: // 'E' CNL
            cursorY = min(rows - 1, cursorY + param(0, default: 1))
            cursorX = 0
            wrapPending = false
        case 0x46: // 'F' CPL
            cursorY = max(0, cursorY - param(0, default: 1))
            cursorX = 0
            wrapPending = false
        case 0x47: // 'G' CHA
            cursorX = max(0, min(cols - 1, param(0, default: 1) - 1))
            wrapPending = false
        case 0x48, 0x66: // 'H', 'f' CUP
            let r = param(0, default: 1) - 1
            let c = param(1, default: 1) - 1
            cursorY = max(0, min(rows - 1, r))
            cursorX = max(0, min(cols - 1, c))
            wrapPending = false
        case 0x4A: // 'J' ED
            let mode = params.first ?? 0
            eraseInDisplay(mode: mode)
        case 0x4B: // 'K' EL
            let mode = params.first ?? 0
            eraseInLine(mode: mode)
        case 0x4C: // 'L' IL
            let count = param(0, default: 1)
            for _ in 0..<count {
                grid.removeLast()
                grid.insert(Self.makeBlankRow(cols: cols, bg: currentBg), at: cursorY)
            }
        case 0x4D: // 'M' DL
            let count = param(0, default: 1)
            for _ in 0..<count where cursorY < grid.count {
                grid.remove(at: cursorY)
                grid.append(Self.makeBlankRow(cols: cols, bg: currentBg))
            }
        case 0x53: // 'S' SU
            scrollUp(lines: param(0, default: 1))
        case 0x54: // 'T' SD
            scrollDown(lines: param(0, default: 1))
        case 0x73: // 's' Save cursor
            savedCursorX = cursorX
            savedCursorY = cursorY
        case 0x75: // 'u' Restore cursor
            cursorX = max(0, min(savedCursorX, cols - 1))
            cursorY = max(0, min(savedCursorY, rows - 1))
            wrapPending = false
        case 0x6E: // 'n' DSR
            if params.first == 6 {
                let response = "\u{1B}[\(cursorY + 1);\(cursorX + 1)R"
                pendingResponses.append(contentsOf: response.utf8)
            }
        case 0x71: // 'q' DECSCUSR
            if hasSpaceIntermediate {
                let code = params.first ?? 0
                switch code {
                case 0, 1:
                    cursorStyle = .block
                    cursorBlinking = true
                case 2:
                    cursorStyle = .block
                    cursorBlinking = false
                case 3:
                    cursorStyle = .underline
                    cursorBlinking = true
                case 4:
                    cursorStyle = .underline
                    cursorBlinking = false
                case 5:
                    cursorStyle = .line
                    cursorBlinking = true
                case 6:
                    cursorStyle = .line
                    cursorBlinking = false
                default:
                    break
                }
            }
        default:
            break
        }
    }

    private func eraseInDisplay(mode: Int) {
        let blank = Self.blankCell(bg: currentBg)
        switch mode {
        case 0:
            eraseInLine(mode: 0)
            if cursorY + 1 < rows {
                for r in (cursorY + 1)..<rows {
                    grid[r] = Array(repeating: blank, count: cols)
                }
            }
        case 1:
            if cursorY > 0 {
                for r in 0..<cursorY {
                    grid[r] = Array(repeating: blank, count: cols)
                }
            }
            eraseInLine(mode: 1)
        case 2, 3:
            grid = Self.makeBlankGrid(cols: cols, rows: rows, bg: currentBg)
            if mode == 3 {
                scrollback.removeAll()
                scrollOffset = 0
            }
        default:
            break
        }
    }

    private func eraseInLine(mode: Int) {
        guard cursorY >= 0 && cursorY < rows else { return }
        let blank = Self.blankCell(bg: currentBg)
        switch mode {
        case 0:
            for c in cursorX..<cols {
                grid[cursorY][c] = blank
            }
        case 1:
            for c in 0...min(cursorX, cols - 1) {
                grid[cursorY][c] = blank
            }
        case 2:
            grid[cursorY] = Array(repeating: blank, count: cols)
        default:
            break
        }
    }

    private func applySGR(_ params: [Int]) {
        var i = 0
        while i < params.count {
            let p = params[i]
            switch p {
            case 0:
                currentFg = Self.defaultFg
                currentBg = Self.defaultBg
                currentAttributes = TextAttributes.none
            case 1: currentAttributes |= TextAttributes.bold
            case 2: currentAttributes |= TextAttributes.dim
            case 3: currentAttributes |= TextAttributes.italic
            case 4: currentAttributes |= TextAttributes.underline
            case 5: currentAttributes |= TextAttributes.blink
            case 7: currentAttributes |= TextAttributes.inverse
            case 8: currentAttributes |= TextAttributes.hidden
            case 9: currentAttributes |= TextAttributes.strikethrough
            case 22: currentAttributes &= ~(TextAttributes.bold | TextAttributes.dim)
            case 23: currentAttributes &= ~TextAttributes.italic
            case 24: currentAttributes &= ~TextAttributes.underline
            case 25: currentAttributes &= ~TextAttributes.blink
            case 27: currentAttributes &= ~TextAttributes.inverse
            case 28: currentAttributes &= ~TextAttributes.hidden
            case 29: currentAttributes &= ~TextAttributes.strikethrough
            case 30...37:
                currentFg = Self.ansi16Colors[p - 30]
            case 39:
                currentFg = Self.defaultFg
            case 40...47:
                currentBg = Self.ansi16Colors[p - 40]
            case 49:
                currentBg = Self.defaultBg
            case 90...97:
                currentFg = Self.ansi16Colors[8 + (p - 90)]
            case 100...107:
                currentBg = Self.ansi16Colors[8 + (p - 100)]
            case 38, 48:
                let isFg = (p == 38)
                if i + 2 < params.count && params[i + 1] == 5 {
                    let idx = params[i + 2]
                    if let rgb = try? ansi256IndexToRgb(idx) {
                        let color = RGBA.fromInts(Int(rgb.r), Int(rgb.g), Int(rgb.b), 255)
                        if isFg { currentFg = color } else { currentBg = color }
                    }
                    i += 2
                } else if i + 4 < params.count && params[i + 1] == 2 {
                    let color = RGBA.fromInts(params[i + 2], params[i + 3], params[i + 4], 255)
                    if isFg { currentFg = color } else { currentBg = color }
                    i += 4
                }
            default:
                break
            }
            i += 1
        }
    }

    func visibleRow(at viewportRow: Int) -> [TerminalCell] {
        if isAltScreen || scrollOffset == 0 {
            guard viewportRow >= 0 && viewportRow < grid.count else { return Self.makeBlankRow(cols: cols) }
            return grid[viewportRow]
        }
        let totalScrollback = scrollback.count
        let startIndex = max(0, totalScrollback - scrollOffset)
        let combinedIndex = startIndex + viewportRow
        if combinedIndex < totalScrollback {
            return scrollback[combinedIndex]
        }
        let liveIdx = combinedIndex - totalScrollback
        guard liveIdx >= 0 && liveIdx < grid.count else { return Self.makeBlankRow(cols: cols) }
        return grid[liveIdx]
    }

    private func normalizedSelection() -> (start: SelectionPoint, end: SelectionPoint)? {
        guard let a = selectionStart, let b = selectionEnd else { return nil }
        if a.y < b.y || (a.y == b.y && a.x <= b.x) {
            return (a, b)
        }
        return (b, a)
    }

    func isCellSelected(x: Int, y: Int) -> Bool {
        guard let sel = normalizedSelection() else { return false }
        if y < sel.start.y || y > sel.end.y { return false }
        if sel.start.y == sel.end.y {
            return x >= sel.start.x && x <= sel.end.x
        }
        if y == sel.start.y { return x >= sel.start.x }
        if y == sel.end.y { return x <= sel.end.x }
        return true
    }

    func getSelectedText() -> String {
        guard let sel = normalizedSelection() else { return "" }
        var outLines: [String] = []
        let minY = max(0, sel.start.y)
        let maxY = min(rows - 1, sel.end.y)
        guard minY <= maxY else { return "" }

        for r in minY...maxY {
            let row = visibleRow(at: r)
            let startCol = (r == sel.start.y) ? max(0, sel.start.x) : 0
            let endCol = (r == sel.end.y) ? min(row.count - 1, sel.end.x) : (row.count - 1)
            guard startCol <= endCol && startCol < row.count else {
                outLines.append("")
                continue
            }
            var line = ""
            for c in startCol...endCol {
                let scalarVal = row[c].scalar
                if let scalar = Unicode.Scalar(scalarVal) {
                    line.unicodeScalars.append(scalar)
                } else {
                    line.append(" ")
                }
            }
            while line.last == " " {
                line.removeLast()
            }
            outLines.append(line)
        }
        return outLines.joined(separator: "\n")
    }

    func compose(into buffer: OptimizedBuffer, destX: Int, destY: Int) {
        let drawRows = min(rows, buffer.height - destY)
        let drawCols = min(cols, buffer.width - destX)
        guard drawRows > 0 && drawCols > 0 else { return }

        for r in 0..<drawRows {
            let row = visibleRow(at: r)
            let limit = min(drawCols, row.count)
            for c in 0..<limit {
                var cell = row[c]
                if transparentBackground && cell.background.intent == .default {
                    cell.background = RGBA.fromInts(0, 0, 0, 0)
                }
                if isCellSelected(x: c, y: r) {
                    let fgColor = cell.foreground
                    let bgColor = cell.background.a > 0 ? cell.background : RGBA.fromInts(0, 0, 0, 255)
                    cell.foreground = bgColor
                    cell.background = fgColor
                }
                buffer.setCell(x: destX + c, y: destY + r, cell: cell)
            }
        }
    }

    func screenSnapshot() -> EmbeddedTerminalScreen {
        var lines: [String] = []
        lines.reserveCapacity(rows)
        for r in 0..<rows {
            let row = visibleRow(at: r)
            var line = ""
            line.reserveCapacity(row.count)
            for cell in row {
                if let scalar = Unicode.Scalar(cell.scalar) {
                    line.unicodeScalars.append(scalar)
                } else {
                    line.append(" ")
                }
            }
            while line.last == " " {
                line.removeLast()
            }
            lines.append(line)
        }
        while lines.last == "" {
            lines.removeLast()
        }
        return EmbeddedTerminalScreen(
            text: lines.joined(separator: "\n"),
            lines: lines,
            columns: cols,
            rows: rows,
            cursor: EmbeddedTerminalCursor(
                x: cursorX,
                y: cursorY,
                visible: cursorVisible && scrollOffset == 0,
                style: cursorStyle,
                blinking: cursorBlinking
            )
        )
    }
}

// MARK: - EmbeddedTerminalRenderable

/// Embeds a virtual terminal screen/cell grid with ANSI/VT parsing, cursor rendering,
/// scrollback, resize notifications, focus/key/paste forwarding, and text selection.
// parity: core/src/renderables/EmbeddedTerminal.ts#EmbeddedTerminalRenderable [status=implemented hash=8ef940486369]
open class EmbeddedTerminalRenderable: Renderable, @unchecked Sendable {
    private let emulator: EmbeddedTerminalEmulator
    private var _onData: (([UInt8], EmbeddedTerminalDataSource) -> Void)?
    private var _onTerminalResize: ((Int, Int) -> Void)?
    private var _onScreenChange: (() -> Void)?
    private var keyreleaseToken: KeyHandlerToken? = nil
    private var hasActiveSelection: Bool = false
    private var _transparentBackground: Bool = false

    public init(ctx: any RenderContext, options: EmbeddedTerminalOptions = EmbeddedTerminalOptions()) {
        let resolvedCols: Int = {
            if let c = options.cols { return max(1, c) }
            if case .point(let w) = options.base.width, w > 0 { return max(1, Int(w.rounded(.down))) }
            return 80
        }()
        let resolvedRows: Int = {
            if let r = options.rows { return max(1, r) }
            if case .point(let h) = options.base.height, h > 0 { return max(1, Int(h.rounded(.down))) }
            return 24
        }()

        self.emulator = EmbeddedTerminalEmulator(
            cols: resolvedCols,
            rows: resolvedRows,
            maxScrollback: options.maxScrollback ?? 1000
        )
        self._onData = options.onData
        self._onTerminalResize = options.onTerminalResize
        self._onScreenChange = options.onScreenChange
        self._transparentBackground = options.transparentBackground ?? false
        self.emulator.transparentBackground = self._transparentBackground

        var baseOptions = options.base
        baseOptions.width = baseOptions.width ?? .point(Float(resolvedCols))
        baseOptions.height = baseOptions.height ?? .point(Float(resolvedRows))
        baseOptions.buffered = true
        baseOptions.focusable = true
        baseOptions.selectable = options.selectable ?? true

        let userMouseDown = baseOptions.onMouseDown
        let userMouseUp = baseOptions.onMouseUp
        let userMouseMove = baseOptions.onMouseMove
        let userMouseDrag = baseOptions.onMouseDrag
        let userMouseScroll = baseOptions.onMouseScroll
        baseOptions.onMouseDown = nil
        baseOptions.onMouseUp = nil
        baseOptions.onMouseMove = nil
        baseOptions.onMouseDrag = nil
        baseOptions.onMouseScroll = nil

        super.init(ctx: ctx, options: baseOptions)
        self.selectable = options.selectable ?? true

        setupMouse(
            onMouseDown: userMouseDown,
            onMouseUp: userMouseUp,
            onMouseMove: userMouseMove,
            onMouseDrag: userMouseDrag,
            onMouseScroll: userMouseScroll
        )
    }

    // MARK: - Callbacks & Properties

    // parity: core/src/renderables/EmbeddedTerminal.ts#EmbeddedTerminalRenderable.onData [status=implemented hash=ed469cf60540]
    public var onData: (([UInt8], EmbeddedTerminalDataSource) -> Void)? {
        get { _onData }
        set { _onData = newValue }
    }

    // parity: core/src/renderables/EmbeddedTerminal.ts#EmbeddedTerminalRenderable.onTerminalResize [status=implemented hash=783037b6483e]
    public var onTerminalResize: ((Int, Int) -> Void)? {
        get { _onTerminalResize }
        set { _onTerminalResize = newValue }
    }

    // parity: core/src/renderables/EmbeddedTerminal.ts#EmbeddedTerminalRenderable.onScreenChange [status=implemented hash=7f7e69fdf9cf]
    public var onScreenChange: (() -> Void)? {
        get { _onScreenChange }
        set { _onScreenChange = newValue }
    }

    // parity: core/src/renderables/EmbeddedTerminal.ts#EmbeddedTerminalRenderable.transparentBackground [status=implemented hash=4fc4a33eac7a]
    public var transparentBackground: Bool {
        get { _transparentBackground }
        set {
            guard _transparentBackground != newValue else { return }
            _transparentBackground = newValue
            emulator.transparentBackground = newValue
            requestRender()
        }
    }

    // MARK: - Terminal Operations

    // parity: core/src/renderables/EmbeddedTerminal.ts#EmbeddedTerminalRenderable.screen [status=implemented hash=2b9dc9668840]
    public func screen() -> EmbeddedTerminalScreen {
        emulator.screenSnapshot()
    }

    // parity: core/src/renderables/EmbeddedTerminal.ts#EmbeddedTerminalRenderable.getScroll [status=implemented hash=b1268e6f4029]
    public func getScroll() -> EmbeddedTerminalScrollState {
        emulator.scrollState()
    }

    // parity: core/src/renderables/EmbeddedTerminal.ts#EmbeddedTerminalRenderable.write [status=implemented hash=221db068cdf6]
    public func write(_ data: String) {
        write(Array(data.utf8))
    }

    public func write(_ bytes: [UInt8]) {
        guard !isDestroyed else { return }
        emulator.write(bytes)
        flushResponses()
        requestRender()
    }

    // parity: core/src/renderables/EmbeddedTerminal.ts#EmbeddedTerminalRenderable.invalidate [status=implemented hash=dc23151f5c22]
    public func invalidate() {
        guard !isDestroyed else { return }
        requestRender()
    }

    // parity: core/src/renderables/EmbeddedTerminal.ts#EmbeddedTerminalRenderable.encodeKey [status=implemented hash=874885893746]
    public func encodeKey(_ key: KeyEvent) -> [UInt8] {
        guard !isDestroyed else { return [] }
        if key.eventType == .release {
            return []
        }

        let name = key.name.lowercased()
        if name == "linefeed" {
            return [0x0A]
        }

        if key.ctrl && name.count == 1, let scalar = name.unicodeScalars.first {
            if scalar.value >= 0x61 && scalar.value <= 0x7A {
                let ctrlByte = UInt8(scalar.value - 0x60)
                return key.meta || key.option ? [0x1B, ctrlByte] : [ctrlByte]
            }
        }

        let sequence: String
        switch name {
        case "return", "enter": sequence = "\r"
        case "backspace": sequence = "\u{7F}"
        case "tab": sequence = key.shift ? "\u{1B}[Z" : "\t"
        case "escape": sequence = "\u{1B}"
        case "space": sequence = " "
        case "up": sequence = "\u{1B}[A"
        case "down": sequence = "\u{1B}[B"
        case "right": sequence = "\u{1B}[C"
        case "left": sequence = "\u{1B}[D"
        case "home": sequence = "\u{1B}[H"
        case "end": sequence = "\u{1B}[F"
        case "insert": sequence = "\u{1B}[2~"
        case "delete": sequence = "\u{1B}[3~"
        case "pageup": sequence = "\u{1B}[5~"
        case "pagedown": sequence = "\u{1B}[6~"
        case "f1": sequence = "\u{1B}OP"
        case "f2": sequence = "\u{1B}OQ"
        case "f3": sequence = "\u{1B}OR"
        case "f4": sequence = "\u{1B}OS"
        case "f5": sequence = "\u{1B}[15~"
        case "f6": sequence = "\u{1B}[17~"
        case "f7": sequence = "\u{1B}[18~"
        case "f8": sequence = "\u{1B}[19~"
        case "f9": sequence = "\u{1B}[20~"
        case "f10": sequence = "\u{1B}[21~"
        case "f11": sequence = "\u{1B}[23~"
        case "f12": sequence = "\u{1B}[24~"
        default:
            if !key.sequence.isEmpty {
                sequence = key.sequence
            } else if key.name.count == 1 {
                sequence = key.shift ? key.name.uppercased() : key.name
            } else {
                sequence = ""
            }
        }

        guard !sequence.isEmpty else { return [] }
        if (key.meta || key.option) && !sequence.hasPrefix("\u{1B}") {
            return Array(("\u{1B}" + sequence).utf8)
        }
        return Array(sequence.utf8)
    }

    // parity: core/src/renderables/EmbeddedTerminal.ts#EmbeddedTerminalRenderable.encodePaste [status=implemented hash=2ae60b15bdb5]
    public func encodePaste(_ bytes: [UInt8]) -> [UInt8] {
        guard !isDestroyed else { return [] }
        if emulator.bracketedPasteMode {
            var out: [UInt8] = []
            out.reserveCapacity(bytes.count + 12)
            out.append(contentsOf: "\u{1B}[200~".utf8)
            out.append(contentsOf: bytes)
            out.append(contentsOf: "\u{1B}[201~".utf8)
            return out
        }
        return bytes
    }

    // MARK: - Selection

    // parity: core/src/renderables/EmbeddedTerminal.ts#EmbeddedTerminalRenderable.shouldStartSelection [status=implemented hash=b4c77c0780cc]
    open override func shouldStartSelection(x: Int, y: Int) -> Bool {
        guard selectable else { return false }
        let localX = x - self.x
        let localY = y - self.y
        return localX >= 0 && localX < width && localY >= 0 && localY < height
    }

    // parity: core/src/renderables/EmbeddedTerminal.ts#EmbeddedTerminalRenderable.onSelectionChanged [status=implemented hash=90a5acc39003]
    @discardableResult
    open override func onSelectionChanged(_ selection: Selection?) -> Bool {
        guard !isDestroyed else { return false }
        let local = convertGlobalToLocalSelection(selection, localX: self.x, localY: self.y)
        guard let local, local.isActive else {
            guard hasActiveSelection else { return false }
            emulator.selectionStart = nil
            emulator.selectionEnd = nil
            hasActiveSelection = false
            requestRender()
            return false
        }

        if !hasActiveSelection
            && local.behavior == .cell
            && local.anchorX == local.focusX
            && local.anchorY == local.focusY
        {
            return false
        }

        let maxX = max(0, emulator.cols - 1)
        let maxY = max(0, emulator.rows - 1)
        func clampPoint(_ px: Int, _ py: Int) -> SelectionPoint {
            if py < 0 { return SelectionPoint(x: 0, y: 0) }
            if py > maxY { return SelectionPoint(x: maxX, y: maxY) }
            return SelectionPoint(x: max(0, min(maxX, px)), y: py)
        }

        emulator.selectionStart = clampPoint(local.anchorX, local.anchorY)
        emulator.selectionEnd = clampPoint(local.focusX, local.focusY)
        hasActiveSelection = true
        requestRender()
        return true
    }

    // parity: core/src/renderables/EmbeddedTerminal.ts#EmbeddedTerminalRenderable.hasSelection [status=implemented hash=1dd48ee9bd2e]
    open override func hasSelection() -> Bool {
        hasActiveSelection
    }

    // parity: core/src/renderables/EmbeddedTerminal.ts#EmbeddedTerminalRenderable.getSelectedText [status=implemented hash=72c848f87182]
    open override func getSelectedText() -> String {
        guard !isDestroyed && hasActiveSelection else { return "" }
        return emulator.getSelectedText()
    }

    // MARK: - Focus & Input Forwarding

    // parity: core/src/renderables/EmbeddedTerminal.ts#EmbeddedTerminalRenderable.focus [status=implemented hash=e1fe197e50a3]
    open override func focus() {
        guard !focused else { return }
        super.focus()
        guard focused else { return }

        keyreleaseToken = ctx.internalKeyInput.onInternalKeyrelease { [weak self] key in
            _ = self?.handleKeyPress(key)
        }
        sendFocus(true)
    }

    // parity: core/src/renderables/EmbeddedTerminal.ts#EmbeddedTerminalRenderable.blur [status=implemented hash=d318a4db1392]
    open override func blur() {
        guard focused else { return }
        sendFocus(false)
        removeKeyreleaseHandler()
        super.blur()
        ctx.setCursorPosition(x: 0, y: 0, visible: false)
    }

    // parity: core/src/renderables/EmbeddedTerminal.ts#EmbeddedTerminalRenderable.handleKeyPress [status=implemented hash=dd919a17439f]
    @discardableResult
    open override func handleKeyPress(_ key: KeyEvent) -> Bool {
        let output = encodeKey(key)
        send(output, source: .input)
        return !output.isEmpty
    }

    // parity: core/src/renderables/EmbeddedTerminal.ts#EmbeddedTerminalRenderable.handlePaste [status=implemented hash=aaf53d203f5e]
    open override func handlePaste(_ event: PasteEvent) {
        send(encodePaste(event.bytes), source: .input)
    }

    open override func onResize(width: Int, height: Int) {
        super.onResize(width: width, height: height)
        guard !isDestroyed && width > 0 && height > 0 else { return }
        let cols = min(width, 0xFFFF)
        let rows = min(height, 0xFFFF)
        emulator.resize(cols: cols, rows: rows)
        flushResponses()
        _onTerminalResize?(cols, rows)
    }

    open override func renderSelf(buffer: OptimizedBuffer, deltaTime: Double) {
        guard visible && !isDestroyed else { return }
        let origin = paintOrigin(for: buffer)
        emulator.compose(into: buffer, destX: origin.x, destY: origin.y)
        _onScreenChange?()

        guard focused else { return }
        let cursorVisible = emulator.cursorVisible && emulator.scrollOffset == 0
        ctx.setCursorPosition(
            x: screenX + emulator.cursorX + 1,
            y: screenY + emulator.cursorY + 1,
            visible: cursorVisible
        )
        if cursorVisible {
            ctx.setCursorStyle(CursorStyleOptions(style: emulator.cursorStyle, blinking: emulator.cursorBlinking))
        }
    }

    open override func onRemove() {
        if focused {
            blur()
        }
    }

    open override func destroySelf() {
        hasActiveSelection = false
        removeKeyreleaseHandler()
        ctx.setCursorPosition(x: 0, y: 0, visible: false)
        super.destroySelf()
    }

    // MARK: - Private Mouse & Response Helpers

    private func setupMouse(
        onMouseDown: ((MouseEvent) -> Void)?,
        onMouseUp: ((MouseEvent) -> Void)?,
        onMouseMove: ((MouseEvent) -> Void)?,
        onMouseDrag: ((MouseEvent) -> Void)?,
        onMouseScroll: ((MouseEvent) -> Void)?
    ) {
        self.onMouseDown = { [weak self] event in
            self?.forwardMouse(event, isRelease: false)
            onMouseDown?(event)
        }
        self.onMouseUp = { [weak self] event in
            self?.forwardMouse(event, isRelease: true)
            onMouseUp?(event)
        }
        self.onMouseMove = { [weak self] event in
            self?.forwardMouse(event, isRelease: false)
            onMouseMove?(event)
        }
        self.onMouseDrag = { [weak self] event in
            self?.forwardMouse(event, isRelease: false)
            onMouseDrag?(event)
        }
        self.onMouseScroll = { [weak self] event in
            self?.forwardMouse(event, isRelease: false)
            onMouseScroll?(event)
        }
    }

    private func forwardMouse(_ event: MouseEvent, isRelease: Bool) {
        guard !isDestroyed else { return }
        if event.type == .down && event.button == MouseButton.left.rawValue {
            focus()
        }

        if event.type == .scroll && !emulator.mouseReportingMode {
            guard let dir = event.scroll?.direction else { return }
            if dir == .up || dir == .down {
                let delta = (dir == .up) ? -3 : 3
                emulator.scrollViewport(delta: delta)
                requestRender()
                event.preventDefault()
                event.stopPropagation()
            }
            return
        }

        guard emulator.mouseReportingMode else { return }
        let localX = max(0, event.x - screenX) + 1
        let localY = max(0, event.y - screenY) + 1
        var cb = event.button
        if event.modifiers.shift { cb |= 4 }
        if event.modifiers.alt { cb |= 8 }
        if event.modifiers.ctrl { cb |= 16 }
        if event.type == .move || event.type == .drag { cb |= 32 }

        let seq: String
        if emulator.sgrMouseMode {
            let suffix = isRelease ? "m" : "M"
            seq = "\u{1B}[<\(cb);\(localX);\(localY)\(suffix)"
        } else {
            let cx = min(223, localX) + 32
            let cy = min(223, localY) + 32
            seq = "\u{1B}[M\(Unicode.Scalar(cb + 32)!)\(Unicode.Scalar(cx)!)\(Unicode.Scalar(cy)!)"
        }

        event.preventDefault()
        event.stopPropagation()
        send(Array(seq.utf8), source: .input)
    }

    private func flushResponses() {
        let responses = emulator.drainResponses()
        send(responses, source: .response)
    }

    private func sendFocus(_ isFocused: Bool) {
        guard emulator.focusReportingMode else { return }
        let seq = isFocused ? "\u{1B}[I" : "\u{1B}[O"
        send(Array(seq.utf8), source: .input)
    }

    private func removeKeyreleaseHandler() {
        if let token = keyreleaseToken {
            keyreleaseToken = nil
            ctx.internalKeyInput.offInternal(token)
        }
    }

    private func send(_ data: [UInt8], source: EmbeddedTerminalDataSource) {
        if !data.isEmpty {
            _onData?(data, source)
        }
    }
}
