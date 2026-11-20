import OpenTUICore

extension Merman {
    // parity: merman/src/core/drawing.ts#DiagramLineCornerStyle [status=implemented hash=9337a2b6dbd0]
    public enum DiagramLineCornerStyle: String, Equatable, Hashable, Sendable, Codable {
        case square
        case rounded
    }

    // parity: merman/src/core/drawing.ts#DiagramLineStyle [status=implemented hash=caee101c0b73]
    public enum DiagramLineStyle: String, Equatable, Hashable, Sendable, Codable {
        case single
        case heavy
        case dashed
    }

    // parity: merman/src/core/drawing.ts#DiagramArrowHeadStyle [status=implemented hash=ca83e46ec8b8]
    public enum DiagramArrowHeadStyle: String, Equatable, Hashable, Sendable, Codable {
        case filled
        case line
    }

    // parity: merman/src/core/drawing.ts#DiagramDiamondCharacters [status=implemented hash=7ce7cf1f3e38]
    public struct DiagramDiamondCharacters: Equatable, Hashable, Sendable, Codable {
        public let topLeft: String
        public let topRight: String
        public let upperLeft: String
        public let upperLeftJoin: String
        public let upperRightJoin: String
        public let upperRight: String
        public let vertical: String
        public let lowerLeft: String
        public let lowerLeftJoin: String
        public let lowerRightJoin: String
        public let lowerRight: String
        public let bottomLeft: String
        public let bottomRight: String
        public let horizontal: String

        public init(
            topLeft: String,
            topRight: String,
            upperLeft: String,
            upperLeftJoin: String,
            upperRightJoin: String,
            upperRight: String,
            vertical: String,
            lowerLeft: String,
            lowerLeftJoin: String,
            lowerRightJoin: String,
            lowerRight: String,
            bottomLeft: String,
            bottomRight: String,
            horizontal: String
        ) {
            self.topLeft = topLeft
            self.topRight = topRight
            self.upperLeft = upperLeft
            self.upperLeftJoin = upperLeftJoin
            self.upperRightJoin = upperRightJoin
            self.upperRight = upperRight
            self.vertical = vertical
            self.lowerLeft = lowerLeft
            self.lowerLeftJoin = lowerLeftJoin
            self.lowerRightJoin = lowerRightJoin
            self.lowerRight = lowerRight
            self.bottomLeft = bottomLeft
            self.bottomRight = bottomRight
            self.horizontal = horizontal
        }
    }

    // parity: merman/src/core/drawing.ts#DIAGRAM_ARROW_HEADS [status=implemented hash=a15edf5731b2]
    public static let DIAGRAM_ARROW_HEADS: Set<String> = ["▶", "◀", "▼", "▲", "→", "←", "↓", "↑"]

    private static let heavyLineGlyphs: Set<String> = {
        let h = BorderChars.heavy
        return [h.topLeft, h.topRight, h.bottomLeft, h.bottomRight, h.horizontal, h.vertical, h.topT, h.bottomT, h.leftT, h.rightT, h.cross]
    }()

    // parity: merman/src/core/drawing.ts#DIAGRAM_DIAMOND_CHARS [status=implemented hash=f712359b8af2]
    public static let DIAGRAM_DIAMOND_CHARS = DiagramDiamondCharacters(
        topLeft: "╭",
        topRight: "╮",
        upperLeft: "╭",
        upperLeftJoin: "╯",
        upperRightJoin: "╰",
        upperRight: "╮",
        vertical: "│",
        lowerLeft: "╰",
        lowerLeftJoin: "╮",
        lowerRightJoin: "╭",
        lowerRight: "╯",
        bottomLeft: "╰",
        bottomRight: "╯",
        horizontal: "─"
    )

    // parity: merman/src/core/drawing.ts#diagramDiamondCharactersFromBorder [status=implemented hash=bfaafb2ae435]
    public static func diagramDiamondCharactersFromBorder(_ chars: BorderCharacters) -> DiagramDiamondCharacters {
        DiagramDiamondCharacters(
            topLeft: chars.topLeft,
            topRight: chars.topRight,
            upperLeft: chars.topLeft,
            upperLeftJoin: chars.bottomRight,
            upperRightJoin: chars.bottomLeft,
            upperRight: chars.topRight,
            vertical: chars.vertical,
            lowerLeft: chars.bottomLeft,
            lowerLeftJoin: chars.topRight,
            lowerRightJoin: chars.topLeft,
            lowerRight: chars.bottomRight,
            bottomLeft: chars.bottomLeft,
            bottomRight: chars.bottomRight,
            horizontal: chars.horizontal
        )
    }

    private static func lineDirections(_ char: String) -> [DiagramDirection]? {
        switch char {
        case "─", "━": return [.left, .right]
        case "│", "┃": return [.up, .down]
        case "┌", "╭", "┏": return [.right, .down]
        case "┐", "╮", "┓": return [.left, .down]
        case "└", "╰", "┗": return [.up, .right]
        case "┘", "╯", "┛": return [.up, .left]
        case "├", "┣": return [.up, .down, .right]
        case "┤", "┫": return [.up, .down, .left]
        case "┬", "┳": return [.left, .right, .down]
        case "┴", "┻": return [.left, .right, .up]
        case "┼", "╋": return [.up, .down, .left, .right]
        default: return nil
        }
    }

    // parity: merman/src/core/drawing.ts#diagramLineGlyph [status=implemented hash=90022839bde7]
    public static func diagramLineGlyph(
        _ directions: Set<DiagramDirection>,
        cornerStyle: DiagramLineCornerStyle = .square,
        lineStyle: DiagramLineStyle = .single
    ) -> String {
        let up = directions.contains(.up)
        let down = directions.contains(.down)
        let left = directions.contains(.left)
        let right = directions.contains(.right)
        if lineStyle == .heavy {
            let chars = BorderChars.heavy
            if up && down && left && right { return chars.cross }
            if up && down && right { return chars.leftT }
            if up && down && left { return chars.rightT }
            if left && right && down { return chars.topT }
            if left && right && up { return chars.bottomT }
            if up && right { return chars.bottomLeft }
            if up && left { return chars.bottomRight }
            if down && right { return chars.topLeft }
            if down && left { return chars.topRight }
            if up || down { return chars.vertical }
            return chars.horizontal
        }
        if up && down && left && right { return "┼" }
        if up && down && right { return "├" }
        if up && down && left { return "┤" }
        if left && right && down { return "┬" }
        if left && right && up { return "┴" }
        if up && right { return cornerStyle == .rounded ? "╰" : "└" }
        if up && left { return cornerStyle == .rounded ? "╯" : "┘" }
        if down && right { return cornerStyle == .rounded ? "╭" : "┌" }
        if down && left { return cornerStyle == .rounded ? "╮" : "┐" }
        if up || down { return "│" }
        return "─"
    }

    private static func isHeavyLineGlyph(_ char: String) -> Bool {
        heavyLineGlyphs.contains(char)
    }

    private static func segmentGlyph(_ direction: DiagramDirection, _ lineStyle: DiagramLineStyle?) -> String {
        let directions: Set<DiagramDirection> = (direction == .left || direction == .right) ? [.left, .right] : [.up, .down]
        return diagramLineGlyph(directions, cornerStyle: .square, lineStyle: lineStyle == .heavy ? .heavy : .single)
    }

    // parity: merman/src/core/drawing.ts#mergeDiagramLineGlyph [status=implemented hash=aee20e96a577]
    public static func mergeDiagramLineGlyph(
        _ existing: String,
        _ incoming: String,
        cornerStyle: DiagramLineCornerStyle = .square
    ) -> String? {
        guard let existingDirections = lineDirections(existing),
              let incomingDirections = lineDirections(incoming)
        else { return nil }
        var merged = Set(existingDirections)
        merged.formUnion(incomingDirections)
        return diagramLineGlyph(
            merged,
            cornerStyle: cornerStyle,
            lineStyle: (isHeavyLineGlyph(existing) && isHeavyLineGlyph(incoming)) ? .heavy : .single
        )
    }

    // parity: merman/src/core/drawing.ts#diagramArrowHead [status=implemented hash=a329d7f2c469]
    public static func diagramArrowHead(
        _ direction: DiagramDirection,
        style: DiagramArrowHeadStyle = .filled
    ) -> String {
        if style == .line {
            switch direction {
            case .right: return "→"
            case .left: return "←"
            case .up: return "↑"
            case .down: return "↓"
            }
        }
        switch direction {
        case .right: return "▶"
        case .left: return "◀"
        case .up: return "▲"
        case .down: return "▼"
        }
    }

    // parity: merman/src/core/drawing.ts#diagramArrowHeadBetween [status=implemented hash=bbb8f00824d1]
    public static func diagramArrowHeadBetween(
        _ from: DiagramPoint,
        _ to: DiagramPoint,
        style: DiagramArrowHeadStyle = .filled
    ) -> String {
        if let direction = directionBetween(from, to) {
            return diagramArrowHead(direction, style: style)
        }
        return diagramArrowHead(.right, style: style)
    }

    // parity: merman/src/core/drawing.ts#drawDiagramFrame [status=implemented hash=cd4c873e8880]
    public static func drawDiagramFrame(
        _ bounds: DiagramBounds,
        chars: BorderCharacters,
        setCell: (Int, Int, String) -> Void
    ) {
        setCell(bounds.left, bounds.top, chars.topLeft)
        setCell(bounds.left + bounds.width - 1, bounds.top, chars.topRight)
        setCell(bounds.left, bounds.top + bounds.height - 1, chars.bottomLeft)
        setCell(bounds.left + bounds.width - 1, bounds.top + bounds.height - 1, chars.bottomRight)
        if bounds.width > 2 {
            for x in (bounds.left + 1)..<(bounds.left + bounds.width - 1) {
                setCell(x, bounds.top, chars.horizontal)
                setCell(x, bounds.top + bounds.height - 1, chars.horizontal)
            }
        }
        if bounds.height > 2 {
            for y in (bounds.top + 1)..<(bounds.top + bounds.height - 1) {
                setCell(bounds.left, y, chars.vertical)
                setCell(bounds.left + bounds.width - 1, y, chars.vertical)
            }
        }
    }

    // parity: merman/src/core/drawing.ts#fillDiagramFrameInterior [status=implemented hash=026158acac52]
    public static func fillDiagramFrameInterior(
        _ bounds: DiagramBounds,
        setCell: (Int, Int) -> Void
    ) {
        guard bounds.height > 2, bounds.width > 2 else { return }
        for y in (bounds.top + 1)..<(bounds.top + bounds.height - 1) {
            for x in (bounds.left + 1)..<(bounds.left + bounds.width - 1) {
                setCell(x, y)
            }
        }
    }

    // parity: merman/src/core/drawing.ts#drawDiagramDiamond [status=implemented hash=0249dd9a26c2]
    public static func drawDiagramDiamond(
        _ bounds: DiagramBounds,
        setCell: (Int, Int, String) -> Void,
        chars: DiagramDiamondCharacters = DIAGRAM_DIAMOND_CHARS
    ) {
        let left = bounds.left
        let right = bounds.left + bounds.width - 1
        let top = bounds.top
        let bottom = bounds.top + bounds.height - 1
        let capInset = min(2, max(1, floorDiv(bounds.width - 1, 2)))
        let capLeft = left + capInset
        let capRight = right - capInset

        setCell(capLeft, top, chars.topLeft)
        if capLeft + 1 < capRight {
            for x in (capLeft + 1)..<capRight { setCell(x, top, chars.horizontal) }
        }
        setCell(capRight, top, chars.topRight)

        setCell(left, top + 1, chars.upperLeft)
        if left + 1 < capLeft {
            for x in (left + 1)..<capLeft { setCell(x, top + 1, chars.horizontal) }
        }
        setCell(capLeft, top + 1, chars.upperLeftJoin)
        setCell(capRight, top + 1, chars.upperRightJoin)
        if capRight + 1 < right {
            for x in (capRight + 1)..<right { setCell(x, top + 1, chars.horizontal) }
        }
        setCell(right, top + 1, chars.upperRight)

        if top + 2 < bottom - 1 {
            for y in (top + 2)..<(bottom - 1) {
                setCell(left, y, chars.vertical)
                setCell(right, y, chars.vertical)
            }
        }

        setCell(left, bottom - 1, chars.lowerLeft)
        if left + 1 < capLeft {
            for x in (left + 1)..<capLeft { setCell(x, bottom - 1, chars.horizontal) }
        }
        setCell(capLeft, bottom - 1, chars.lowerLeftJoin)
        setCell(capRight, bottom - 1, chars.lowerRightJoin)
        if capRight + 1 < right {
            for x in (capRight + 1)..<right { setCell(x, bottom - 1, chars.horizontal) }
        }
        setCell(right, bottom - 1, chars.lowerRight)

        setCell(capLeft, bottom, chars.bottomLeft)
        if capLeft + 1 < capRight {
            for x in (capLeft + 1)..<capRight { setCell(x, bottom, chars.horizontal) }
        }
        setCell(capRight, bottom, chars.bottomRight)
    }

    // parity: merman/src/core/drawing.ts#drawOrthogonalPath [status=implemented hash=9991f845b3eb]
    public static func drawOrthogonalPath(
        _ points: [DiagramPoint],
        setCell: (Int, Int, String) -> Void,
        cornerStyle: DiagramLineCornerStyle = .square,
        lineStyle: DiagramLineStyle = .single
    ) {
        if points.count >= 2 {
            for index in 1..<points.count {
                let from = points[index - 1]
                let to = points[index]
                guard let direction = directionBetween(from, to) else { continue }
                let glyph = segmentGlyph(direction, lineStyle)
                var step = index == 1 ? 0 : 1
                walkOrthogonalSegment(from, to, includeStart: index == 1) { pt in
                    if lineStyle != .dashed || step % 2 == 0 {
                        setCell(pt.x, pt.y, glyph)
                    }
                    step += 1
                }
            }
        }

        if points.count >= 3 {
            for index in 1..<(points.count - 1) {
                let previous = points[index - 1]
                let current = points[index]
                let next = points[index + 1]
                var directions = Set<DiagramDirection>()
                if let fromDir = directionBetween(current, previous) { directions.insert(fromDir) }
                if let toDir = directionBetween(current, next) { directions.insert(toDir) }
                setCell(
                    current.x,
                    current.y,
                    diagramLineGlyph(directions, cornerStyle: cornerStyle, lineStyle: lineStyle == .heavy ? .heavy : .single)
                )
            }
        }
    }
}
