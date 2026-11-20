import Foundation
import OpenTUICore

extension Merman {
    // MARK: - Text Lines (`core/text-lines.ts`)

    // parity: merman/src/core/text-lines.ts#DiagramTextRun [status=implemented hash=7ba9c65924ac]
    public struct DiagramTextRun: Equatable, Hashable, Sendable, Codable {
        public var text: String
        public var italic: Bool

        public init(text: String, italic: Bool) {
            self.text = text
            self.italic = italic
        }
    }

    // parity: merman/src/core/text-lines.ts#DiagramTextLine [status=implemented hash=6e30fca52bea]
    public struct DiagramTextLine: Equatable, Hashable, Sendable, Codable {
        public var text: String
        public var runs: [DiagramTextRun]

        public init(text: String, runs: [DiagramTextRun]) {
            self.text = text
            self.runs = runs
        }
    }

    // parity: merman/src/core/text-lines.ts#parseDiagramTextLines [status=implemented hash=e5913d88abf8]
    public static func parseDiagramTextLines(_ value: String) -> [DiagramTextLine] {
        let brMatches = regexAllMatches(#"<br\s*/?>"#, in: value, options: [.caseInsensitive])
        var rawLines: [String] = []
        var cursor = value.startIndex
        for match in brMatches {
            rawLines.append(String(value[cursor..<match.range.lowerBound]))
            cursor = match.range.upperBound
        }
        rawLines.append(String(value[cursor...]))

        return rawLines.map { line in
            var runs: [DiagramTextRun] = []
            let source = jsTrim(line)
            let tagMatches = regexAllMatches(#"</?(?:i|em)\s*>"#, in: source, options: [.caseInsensitive])
            var italic = false
            var offset = source.startIndex
            for match in tagMatches {
                if match.range.lowerBound > offset {
                    runs.append(DiagramTextRun(text: String(source[offset..<match.range.lowerBound]), italic: italic))
                }
                let matchedText = match.groups[0] ?? ""
                italic = !matchedText.hasPrefix("</")
                offset = match.range.upperBound
            }
            if offset < source.endIndex {
                runs.append(DiagramTextRun(text: String(source[offset...]), italic: italic))
            }
            return DiagramTextLine(text: runs.map(\.text).joined(), runs: runs)
        }
    }

    // parity: merman/src/core/text-lines.ts#splitDiagramLines [status=implemented hash=d3816f7b9f20]
    public static func splitDiagramLines(_ value: String) -> [String] {
        parseDiagramTextLines(value).map(\.text)
    }

    // MARK: - Text Measurement (`core/text.ts`)

    // parity: merman/src/core/text.ts#DiagramTextBoxSize [status=implemented hash=aee599cabb18]
    public struct DiagramTextBoxSize: Equatable, Hashable, Sendable, Codable {
        public var width: Int
        public var height: Int
        public var lines: [String]

        public init(width: Int, height: Int, lines: [String]) {
            self.width = width
            self.height = height
            self.lines = lines
        }
    }

    // parity: merman/src/core/text.ts#diagramTextWidth [status=implemented hash=52bdd7deb5cb]
    public static func diagramTextWidth(_ value: String) -> Int {
        stringWidth(value)
    }

    // parity: merman/src/core/text.ts#DIAGRAM_LABEL_PADDING_X [status=implemented hash=a985855b7ab1]
    public static let DIAGRAM_LABEL_PADDING_X: Int = 1

    // parity: merman/src/core/text.ts#padDiagramLabelLine [status=implemented hash=a9d99f14a314]
    public static func padDiagramLabelLine(_ value: String) -> String {
        let padding = String(repeating: " ", count: DIAGRAM_LABEL_PADDING_X)
        return "\(padding)\(value)\(padding)"
    }

    // parity: merman/src/core/text.ts#measureDiagramLabelWidth [status=implemented hash=0085d8b6e67b]
    public static func measureDiagramLabelWidth(
        _ value: String,
        measure: (String) -> Int = diagramTextWidth
    ) -> Int {
        splitDiagramLines(value)
            .map { measure($0) + DIAGRAM_LABEL_PADDING_X * 2 }
            .max() ?? (DIAGRAM_LABEL_PADDING_X * 2)
    }

    // parity: merman/src/core/text.ts#diagramTextGraphemes [status=implemented hash=40be3838746d]
    public static func diagramTextGraphemes(_ value: String) -> [String] {
        value.map { String($0) }
    }

    // parity: merman/src/core/text.ts#measureDiagramTextBox [status=implemented hash=b3a2ef828461]
    public static func measureDiagramTextBox(
        _ value: String,
        paddingX: Int = 0,
        paddingY: Int = 0,
        minInnerWidth: Int = 1
    ) -> DiagramTextBoxSize {
        let lines = splitDiagramLines(value)
        let innerWidth = max(lines.map(diagramTextWidth).max() ?? 0, minInnerWidth)
        return DiagramTextBoxSize(
            width: innerWidth + paddingX * 2,
            height: lines.count + paddingY * 2,
            lines: lines
        )
    }

    // MARK: - Mermaid Line Scanning & Entity Decoding (`core/mermaid.ts`)

    // parity: merman/src/core/mermaid.ts#NumberedMermaidLine [status=implemented hash=a517548200c6]
    public struct NumberedMermaidLine: Equatable, Hashable, Sendable, Codable {
        public let lineNumber: Int
        public let text: String

        public init(lineNumber: Int, text: String) {
            self.lineNumber = lineNumber
            self.text = text
        }
    }

    // parity: merman/src/core/mermaid.ts#numberedMermaidLines [status=implemented hash=b8df63a5a85f]
    public static func numberedMermaidLines(_ content: String) -> [NumberedMermaidLine] {
        let lines = splitCRLF(content)
        var result: [NumberedMermaidLine] = []
        result.reserveCapacity(lines.count)
        for index in 0..<lines.count {
            result.append(NumberedMermaidLine(lineNumber: index + 1, text: jsTrim(lines[index])))
        }
        return result
    }

    // parity: merman/src/core/mermaid.ts#meaningfulNumberedMermaidLines [status=implemented hash=0b50a89142c8]
    public static func meaningfulNumberedMermaidLines(_ content: String) -> [NumberedMermaidLine] {
        numberedMermaidLines(content).filter { !$0.text.isEmpty && !$0.text.hasPrefix("%%") }
    }

    // parity: merman/src/core/mermaid.ts#firstMeaningfulMermaidLine [status=implemented hash=56dbb6fcab3a]
    public static func firstMeaningfulMermaidLine(_ content: String) -> String? {
        for rawLine in splitCRLF(content) {
            let line = jsTrim(rawLine)
            if !line.isEmpty && !line.hasPrefix("%%") {
                return line
            }
        }
        return nil
    }

    // parity: merman/src/core/mermaid.ts#stripMermaidQuotes [status=implemented hash=32595de747ae]
    public static func stripMermaidQuotes(_ value: String) -> String {
        let trimmed = jsTrim(value)
        if trimmed.count >= 2 &&
            ((trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")) ||
             (trimmed.hasPrefix("'") && trimmed.hasSuffix("'")))
        {
            let inner = String(trimmed.dropFirst().dropLast())
            return decodeMermaidText(inner)
        }
        return decodeMermaidText(trimmed)
    }

    // parity: merman/src/core/mermaid.ts#decodeMermaidText [status=implemented hash=5070bf488e7b]
    public static func decodeMermaidText(_ value: String) -> String {
        guard value.contains("&") else { return value }
        var out = ""
        out.reserveCapacity(value.count)
        var i = value.startIndex
        while i < value.endIndex {
            if value[i] == "&" {
                var j = value.index(after: i)
                var count = 0
                var foundSemi: String.Index?
                while j < value.endIndex && count < 40 {
                    let ch = value[j]
                    if ch == ";" {
                        foundSemi = j
                        break
                    }
                    if ch == "&" || ch.isWhitespace {
                        break
                    }
                    j = value.index(after: j)
                    count += 1
                }
                if let semi = foundSemi {
                    let next = value.index(after: semi)
                    let candidate = String(value[i..<next])
                    let decoded = decodeEntity(candidate)
                    if decoded != candidate {
                        out.append(decoded)
                        i = next
                        continue
                    }
                }
            }
            out.append(value[i])
            i = value.index(after: i)
        }
        return out
    }
}
