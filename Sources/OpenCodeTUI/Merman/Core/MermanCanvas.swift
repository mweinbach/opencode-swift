import OpenTUICore

extension Merman {
    public struct EmptyCanvasMetadata: Equatable, Hashable, Sendable {
        public init() {}
    }

    // parity: merman/src/core/canvas.ts#DiagramCanvasCell [status=implemented hash=0c77ca1d85f3]
    public struct DiagramCanvasCell<Style: Hashable & Sendable, Metadata: Sendable>: Sendable {
        public var char: String
        public var style: Style?
        public var metadata: Metadata?

        public init(char: String = " ", style: Style? = nil, metadata: Metadata? = nil) {
            self.char = char
            self.style = style
            self.metadata = metadata
        }
    }

    // parity: merman/src/core/canvas.ts#DiagramCanvasRun [status=implemented hash=486c08e6587c]
    public struct DiagramCanvasRun<Style: Hashable & Sendable, Metadata: Sendable>: Sendable {
        public var text: String
        public var style: Style?
        public var cell: DiagramCanvasCell<Style, Metadata>

        public init(text: String, style: Style?, cell: DiagramCanvasCell<Style, Metadata>) {
            self.text = text
            self.style = style
            self.cell = cell
        }
    }

    // parity: merman/src/core/canvas.ts#DiagramCanvasOptions [status=implemented hash=1cb484128783]
    public struct DiagramCanvasOptions<Style: Hashable & Sendable, Metadata: Sendable> {
        public var measure: ((String) -> Int)?
        public var mergeCell: ((DiagramCanvasCell<Style, Metadata>, DiagramCanvasCell<Style, Metadata>) -> DiagramCanvasCell<Style, Metadata>)?

        public init(
            measure: ((String) -> Int)? = nil,
            mergeCell: ((DiagramCanvasCell<Style, Metadata>, DiagramCanvasCell<Style, Metadata>) -> DiagramCanvasCell<Style, Metadata>)? = nil
        ) {
            self.measure = measure
            self.mergeCell = mergeCell
        }
    }

    // parity: merman/src/core/canvas.ts#DiagramCanvasTextOptions [status=implemented hash=52f260300b41]
    public struct DiagramCanvasTextOptions: Equatable, Hashable, Sendable {
        public var trimTop: Bool
        public var trimBottom: Bool

        public init(trimTop: Bool = false, trimBottom: Bool = false) {
            self.trimTop = trimTop
            self.trimBottom = trimBottom
        }
    }

    // parity: merman/src/core/canvas.ts#DiagramCanvasTextSize [status=implemented hash=be51d0e51408]
    public struct DiagramCanvasTextSize: Equatable, Hashable, Sendable, Codable {
        public var width: Int
        public var height: Int

        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }
    }

    // parity: merman/src/core/canvas.ts#DiagramCanvasTextMetadata [status=implemented hash=141c7cc6a67d]
    public enum DiagramCanvasTextMetadata<Metadata: Sendable> {
        case fixed(Metadata)
        case perCell((Int, Int) -> Metadata?)
    }

    // parity: merman/src/core/canvas.ts#DiagramCanvasRunOptions [status=implemented hash=ce0b5382eabc]
    public struct DiagramCanvasRunOptions<Style: Hashable & Sendable, Metadata: Sendable> {
        public var key: ((DiagramCanvasCell<Style, Metadata>) -> [AnyHashable])?
        public var trimTop: Bool
        public var trimBottom: Bool

        public init(
            key: ((DiagramCanvasCell<Style, Metadata>) -> [AnyHashable])? = nil,
            trimTop: Bool = false,
            trimBottom: Bool = false
        ) {
            self.key = key
            self.trimTop = trimTop
            self.trimBottom = trimBottom
        }
    }

    private static let maxDiagramCells: Int = 250_000

    // parity: merman/src/core/canvas.ts#DiagramCanvasSizeError [status=implemented hash=9a3a6d4b3047]
    public struct DiagramCanvasSizeError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public let name: String = "DiagramCanvasSizeError"
        public let width: Int
        public let height: Int
        public let message: String

        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
            let invalid = width < 0 || height < 0
            self.message = invalid
                ? "Diagram canvas dimensions must be non-negative safe integers, received \(width)x\(height)"
                : "Diagram canvas \(width)x\(height) exceeds the 250,000 cell limit"
        }

        public var description: String { message }
    }

    // parity: merman/src/core/canvas.ts#DiagramCanvas [status=implemented hash=23f7c145add6]
    public final class DiagramCanvas<Style: Hashable & Sendable, Metadata: Sendable> {
        public let width: Int
        public let height: Int
        private var cells: [[DiagramCanvasCell<Style, Metadata>]]
        private let measure: (String) -> Int
        private let usesDefaultMeasure: Bool
        private let mergeCell: ((DiagramCanvasCell<Style, Metadata>, DiagramCanvasCell<Style, Metadata>) -> DiagramCanvasCell<Style, Metadata>)?
        private var rowEnds: [Int]

        public init(
            width: Int,
            height: Int,
            options: DiagramCanvasOptions<Style, Metadata> = DiagramCanvasOptions()
        ) throws {
            if width < 0 || height < 0 {
                throw DiagramCanvasSizeError(width: width, height: height)
            }
            let (product, overflow) = width.multipliedReportingOverflow(by: height)
            if overflow || product > Merman.maxDiagramCells {
                throw DiagramCanvasSizeError(width: width, height: height)
            }
            self.width = width
            self.height = height
            if let customMeasure = options.measure {
                self.measure = customMeasure
                self.usesDefaultMeasure = false
            } else {
                self.measure = { stringWidth($0) }
                self.usesDefaultMeasure = true
            }
            self.mergeCell = options.mergeCell
            let emptyRow = Array(repeating: DiagramCanvasCell<Style, Metadata>(char: " "), count: width)
            self.cells = Array(repeating: emptyRow, count: height)
            self.rowEnds = Array(repeating: 0, count: height)
        }

        // parity: merman/src/core/canvas.ts#DiagramCanvas.rows [status=implemented hash=050045e8e461]
        public var rows: [[DiagramCanvasCell<Style, Metadata>]] {
            cells
        }

        private func rowText(_ row: [DiagramCanvasCell<Style, Metadata>], rowEnd: Int) -> String {
            guard rowEnd > 0 else { return "" }
            var out = ""
            out.reserveCapacity(rowEnd)
            for idx in 0..<rowEnd {
                out.append(row[idx].char)
            }
            return out
        }

        private func textRowRange(trimTop: Bool, trimBottom: Bool) -> (start: Int, end: Int) {
            var start = 0
            var end = cells.count
            if trimTop {
                while start < end && rowEnds[start] == 0 { start += 1 }
            }
            if trimBottom {
                while end > start && rowEnds[end - 1] == 0 { end -= 1 }
            }
            return (start, end)
        }

        // parity: merman/src/core/canvas.ts#DiagramCanvas.setCell [status=implemented hash=8416f0b4966f]
        public func setCell(_ x: Int, _ y: Int, _ char: String, style: Style? = nil, metadata: Metadata? = nil) {
            writeCell(x, y, char, style: style, metadata: metadata, merge: true)
        }

        // parity: merman/src/core/canvas.ts#DiagramCanvas.replaceCell [status=implemented hash=eab0a6d33b66]
        public func replaceCell(_ x: Int, _ y: Int, _ char: String, style: Style? = nil, metadata: Metadata? = nil) {
            writeCell(x, y, char, style: style, metadata: metadata, merge: false)
        }

        private func writeCell(
            _ x: Int,
            _ y: Int,
            _ char: String,
            style: Style?,
            metadata: Metadata?,
            merge: Bool
        ) {
            guard y >= 0, y < cells.count, x >= 0, x < cells[y].count else { return }
            let incoming = DiagramCanvasCell<Style, Metadata>(char: char, style: style, metadata: metadata)
            let cell: DiagramCanvasCell<Style, Metadata>
            if merge, let merger = mergeCell {
                cell = merger(cells[y][x], incoming)
            } else {
                cell = incoming
            }
            cells[y][x] = cell
            if cell.char != " " {
                if x + 1 > rowEnds[y] {
                    rowEnds[y] = x + 1
                }
            } else if rowEnds[y] == x + 1 {
                var end = x
                while end > 0 && cells[y][end - 1].char == " " {
                    end -= 1
                }
                rowEnds[y] = end
            }
        }

        // parity: merman/src/core/canvas.ts#DiagramCanvas.getCell [status=implemented hash=8dacc236a03c]
        public func getCell(_ x: Int, _ y: Int) -> DiagramCanvasCell<Style, Metadata>? {
            guard y >= 0, y < cells.count, x >= 0, x < cells[y].count else { return nil }
            return cells[y][x]
        }

        // parity: merman/src/core/canvas.ts#DiagramCanvas.setText [status=implemented hash=ee96780ac15e]
        public func setText(
            _ x: Int,
            _ y: Int,
            _ text: String,
            style: Style? = nil,
            metadata: DiagramCanvasTextMetadata<Metadata>? = nil
        ) {
            func metadataAt(_ cellX: Int) -> Metadata? {
                guard let metadata else { return nil }
                switch metadata {
                case .fixed(let value): return value
                case .perCell(let fn): return fn(cellX, y)
                }
            }

            if usesDefaultMeasure && text.utf8.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E }) {
                var index = 0
                for byte in text.utf8 {
                    let ch = String(UnicodeScalar(byte))
                    setCell(x + index, y, ch, style: style, metadata: metadataAt(x + index))
                    index += 1
                }
                return
            }

            var offset = 0
            for grapheme in diagramTextGraphemes(text) {
                let w = max(1, measure(grapheme))
                if x + offset < 0 || x + offset + w > width {
                    offset += w
                    continue
                }
                setCell(x + offset, y, grapheme, style: style, metadata: metadataAt(x + offset))
                if w > 1 {
                    for continuation in 1..<w {
                        setCell(x + offset + continuation, y, "", style: style, metadata: metadataAt(x + offset + continuation))
                    }
                }
                offset += w
            }
        }

        // parity: merman/src/core/canvas.ts#DiagramCanvas.toString [status=implemented hash=3adc818f1e73]
        public func toString(_ options: DiagramCanvasTextOptions = DiagramCanvasTextOptions()) -> String {
            let range = textRowRange(trimTop: options.trimTop, trimBottom: options.trimBottom)
            var lines: [String] = []
            lines.reserveCapacity(max(0, range.end - range.start))
            for rowIndex in range.start..<range.end {
                lines.append(rowText(cells[rowIndex], rowEnd: rowEnds[rowIndex]))
            }
            return lines.joined(separator: "\n")
        }

        // parity: merman/src/core/canvas.ts#DiagramCanvas.getTextSize [status=implemented hash=29890fbb70dc]
        public func getTextSize(_ options: DiagramCanvasTextOptions = DiagramCanvasTextOptions()) -> DiagramCanvasTextSize {
            let range = textRowRange(trimTop: options.trimTop, trimBottom: options.trimBottom)
            var maxWidth = 0
            for rowIndex in range.start..<range.end {
                let rowEnd = rowEnds[rowIndex]
                if rowEnd > 0 {
                    maxWidth = max(maxWidth, measure(rowText(cells[rowIndex], rowEnd: rowEnd)))
                }
            }
            return DiagramCanvasTextSize(width: maxWidth, height: range.end - range.start)
        }

        // parity: merman/src/core/canvas.ts#DiagramCanvas.getTextHeight [status=implemented hash=f62f06320765]
        public func getTextHeight(_ options: DiagramCanvasTextOptions = DiagramCanvasTextOptions()) -> Int {
            let range = textRowRange(trimTop: options.trimTop, trimBottom: options.trimBottom)
            return range.end - range.start
        }

        // parity: merman/src/core/canvas.ts#DiagramCanvas.forEachRun [status=implemented hash=2206e5453d8a]
        public func forEachRun(
            _ onRun: (DiagramCanvasRun<Style, Metadata>) -> Void,
            onLineEnd: () -> Void,
            options: DiagramCanvasRunOptions<Style, Metadata> = DiagramCanvasRunOptions()
        ) {
            let keyFn = options.key
            let range = textRowRange(trimTop: options.trimTop, trimBottom: options.trimBottom)

            for rowIndex in range.start..<range.end {
                let row = cells[rowIndex]
                var rowEnd = rowEnds[rowIndex]
                while rowEnd < row.count && row[rowEnd].style != nil {
                    rowEnd += 1
                }

                var currentCell: DiagramCanvasCell<Style, Metadata>?
                var currentKey: [AnyHashable]?
                var currentText = ""

                func flush() {
                    guard !currentText.isEmpty, let cell = currentCell else { return }
                    onRun(DiagramCanvasRun(text: currentText, style: cell.style, cell: cell))
                    currentText = ""
                }

                for x in 0..<rowEnd {
                    let cell = row[x]
                    let nextKey = keyFn?(cell)
                    let sameRun: Bool
                    if let cur = currentCell {
                        if let nextKey {
                            sameRun = currentKey == nextKey
                        } else {
                            sameRun = cur.style == cell.style
                        }
                    } else {
                        sameRun = false
                    }
                    if !sameRun {
                        flush()
                        currentCell = cell
                        currentKey = nextKey
                    }
                    currentText.append(cell.char)
                }

                flush()
                if rowIndex < range.end - 1 {
                    onLineEnd()
                }
            }
        }
    }

    // MARK: - Grid StyledText Rendering (`core/render-grid.ts`)

    // parity: merman/src/core/render-grid.ts#renderDiagramGridStyledText [status=implemented hash=d5207ddbbb69]
    public static func renderDiagramGridStyledText<Style: Hashable & Sendable, Metadata: Sendable>(
        _ grid: DiagramCanvas<Style, Metadata>,
        fg: (DiagramCanvasRun<Style, Metadata>) -> RGBA?,
        bg: ((DiagramCanvasRun<Style, Metadata>) -> RGBA?)? = nil,
        options: DiagramCanvasRunOptions<Style, Metadata> = DiagramCanvasRunOptions(),
        attributes: ((DiagramCanvasRun<Style, Metadata>) -> UInt32?)? = nil
    ) -> StyledText {
        var chunks: [TextChunk] = []
        grid.forEachRun(
            { run in
                chunks.append(TextChunk(
                    text: run.text,
                    fg: fg(run),
                    bg: bg?(run),
                    attributes: attributes?(run)
                ))
            },
            onLineEnd: {
                chunks.append(TextChunk(text: "\n"))
            },
            options: options
        )
        return StyledText(chunks: chunks)
    }

    // parity: merman/src/core/render-grid.ts#renderDiagramGridStyledTextByStyle [status=implemented hash=a21fbfefbc4e]
    public static func renderDiagramGridStyledTextByStyle<Style: Hashable & Sendable, Metadata: Sendable>(
        _ grid: DiagramCanvas<Style, Metadata>,
        foregrounds: [Style: RGBA],
        backgrounds: [Style: RGBA]? = nil,
        options: DiagramCanvasRunOptions<Style, Metadata> = DiagramCanvasRunOptions(),
        attributes: ((DiagramCanvasRun<Style, Metadata>) -> UInt32?)? = nil
    ) -> StyledText {
        let hasBg = backgrounds.map { !$0.isEmpty } ?? false
        let bgFn: ((DiagramCanvasRun<Style, Metadata>) -> RGBA?)? = hasBg
            ? { run in run.style.flatMap { backgrounds?[$0] } }
            : nil
        return renderDiagramGridStyledText(
            grid,
            fg: { run in run.style.flatMap { foregrounds[$0] } },
            bg: bgFn,
            options: options,
            attributes: attributes
        )
    }
}
