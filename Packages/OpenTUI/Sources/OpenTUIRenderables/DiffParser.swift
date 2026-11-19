import OpenTUICore

/// Kind of line inside a parsed unified diff hunk or view projection.
public enum DiffLineKind: String, Equatable, Hashable, Sendable, Codable {
    case context
    case added
    case removed
    case empty
}

/// Diff presentation layout mode.
public enum DiffViewMode: String, Equatable, Hashable, Sendable, Codable {
    case unified
    case split
}

/// Gutter layout configuration for diff line numbers and signs.
// parity: core/src/renderables/Diff.ts#DiffGutterOptions [status=implemented hash=b6201690d626]
public struct DiffGutterOptions: Equatable, Hashable, Sendable, Codable {
    /// Columns before the line numbers, painted in each row's gutter color. Defaults to 1.
    public let paddingLeft: Int
    /// Columns after the line numbers and signs. Defaults to 1.
    public let paddingRight: Int
    /// Reserve room for at least this many line-number digits and always reserve the sign column.
    public let minDigits: Int?

    public init(paddingLeft: Int = 1, paddingRight: Int = 1, minDigits: Int? = nil) {
        self.paddingLeft = paddingLeft
        self.paddingRight = paddingRight
        self.minDigits = minDigits
    }
}

/// A single logical line in a diff hunk or projected unified/split view.
public struct DiffLine: Equatable, Hashable, Sendable, Codable {
    public let kind: DiffLineKind
    public let content: String
    public let oldLineNumber: Int?
    public let newLineNumber: Int?

    public init(
        kind: DiffLineKind,
        content: String,
        oldLineNumber: Int? = nil,
        newLineNumber: Int? = nil
    ) {
        self.kind = kind
        self.content = content
        self.oldLineNumber = oldLineNumber
        self.newLineNumber = newLineNumber
    }

    /// Leading sign prefix (`" "`, `"+"`, `"-"`) followed by `content`.
    public var signedLine: String {
        switch kind {
        case .context:
            return " " + content
        case .added:
            return "+" + content
        case .removed:
            return "-" + content
        case .empty:
            return ""
        }
    }
}

/// A parsed unified diff hunk (`@@ -oldStart,oldCount +newStart,newCount @@`).
public struct DiffHunk: Equatable, Hashable, Sendable, Codable {
    public let oldStart: Int
    public let oldCount: Int
    public let newStart: Int
    public let newCount: Int
    public let header: String
    public let lines: [DiffLine]

    public init(
        oldStart: Int,
        oldCount: Int,
        newStart: Int,
        newCount: Int,
        header: String = "",
        lines: [DiffLine]
    ) {
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.header = header
        self.lines = lines
    }
}

/// First file parsed from a unified diff patch.
public struct ParsedDiff: Equatable, Hashable, Sendable, Codable {
    public let oldFileName: String?
    public let newFileName: String?
    public let hunks: [DiffHunk]

    public init(oldFileName: String? = nil, newFileName: String? = nil, hunks: [DiffHunk]) {
        self.oldFileName = oldFileName
        self.newFileName = newFileName
        self.hunks = hunks
    }
}

/// Structured error reported when a unified diff contains malformed hunks or count mismatches.
public enum DiffParseError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
    case malformedHunkHeader(line: Int, text: String)
    case prematureHunkEnd(line: Int)
    case unknownHunkLine(line: Int, text: String)
    case lineCountOverflow(line: Int, text: String)
    case incompleteLastHunk

    public var description: String {
        switch self {
        case .malformedHunkHeader(let line, let text):
            return "unknown hunk header on line \(line): \(text)"
        case .prematureHunkEnd(let line):
            return "the hunk before line \(line) ends before its line counts"
        case .unknownHunkLine(let line, let text):
            return "unknown line \(line) in a hunk: \(text)"
        case .lineCountOverflow(let line, let text):
            return "line \(line) does not fit the hunk's line counts: \(text)"
        case .incompleteLastHunk:
            return "the last hunk ends before its line counts"
        }
    }
}

/// Splits input text into lines matching Rust `str::lines()` semantics:
/// splits on `\n`, strips a trailing `\r`, and omits an empty trailing slice after a final `\n`.
private func splitDiffLines(_ text: String) -> [Substring] {
    if text.isEmpty { return [] }
    var lines: [Substring] = []
    var start = text.startIndex
    var index = start

    while index < text.endIndex {
        if text[index] == "\n" {
            var lineEnd = index
            if lineEnd > start {
                let prev = text.index(before: lineEnd)
                if text[prev] == "\r" {
                    lineEnd = prev
                }
            }
            lines.append(text[start..<lineEnd])
            index = text.index(after: index)
            start = index
        } else {
            index = text.index(after: index)
        }
    }

    if start < text.endIndex {
        var lineEnd = text.endIndex
        if lineEnd > start {
            let prev = text.index(before: lineEnd)
            if text[prev] == "\r" {
                lineEnd = prev
            }
        }
        lines.append(text[start..<lineEnd])
    }

    return lines
}

private func parseHunkRange(_ text: Substring) -> (start: Int, count: Int)? {
    if let comma = text.firstIndex(of: ",") {
        let startPart = text[..<comma]
        let countPart = text[text.index(after: comma)...]
        guard !startPart.isEmpty, !countPart.isEmpty,
              let start = Int(startPart), start >= 0,
              let count = Int(countPart), count >= 0
        else {
            return nil
        }
        return (start, count)
    }
    guard !text.isEmpty, let start = Int(text), start >= 0 else {
        return nil
    }
    return (start, 1)
}

private func parseHunkHeader(_ line: Substring) -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int)? {
    guard line.hasPrefix("@@ ") else { return nil }
    let afterPrefix = line.dropFirst(3)

    // Find closing " @@"
    var searchStart = afterPrefix.startIndex
    var closingStart: Substring.Index?
    while searchStart < afterPrefix.endIndex {
        guard let spaceIdx = afterPrefix[searchStart...].firstIndex(of: " ") else { break }
        let afterSpace = afterPrefix.index(after: spaceIdx)
        if afterPrefix[afterSpace...].hasPrefix("@@") {
            closingStart = spaceIdx
            break
        }
        searchStart = afterSpace
    }
    guard let closeIdx = closingStart else { return nil }
    let ranges = afterPrefix[..<closeIdx]

    guard let sepIdx = ranges.firstIndex(of: " ") else { return nil }
    let oldPart = ranges[..<sepIdx]
    let newPart = ranges[ranges.index(after: sepIdx)...]

    guard oldPart.hasPrefix("-"), newPart.hasPrefix("+"),
          let oldRange = parseHunkRange(oldPart.dropFirst()),
          let newRange = parseHunkRange(newPart.dropFirst())
    else {
        return nil
    }
    return (oldRange.start, oldRange.count, newRange.start, newRange.count)
}

private func stripFileHeaderName(_ line: Substring, prefix: String) -> String? {
    guard line.hasPrefix(prefix) else { return nil }
    let rest = line.dropFirst(prefix.count)
    guard let first = rest.first, first == " " || first == "\t" else { return nil }
    let afterSep = rest.dropFirst()
    if let tabIdx = afterSep.firstIndex(of: "\t") {
        return String(afterSep[..<tabIdx])
    }
    return String(afterSep)
}

/// Parses the first file of a unified diff according to OpenTUI's unified diff conformance rules:
/// - Handles optional file headers (`diff ...`, `--- <name>`, `+++ <name>` with space or tab separators).
/// - Stops at the next file header so only the first file is parsed.
/// - Treats blank lines inside a hunk as empty context lines (`" "`).
/// - Strips `\ No newline at end of file` markers (any leading `\` line inside a hunk).
/// - Ignores trailing lines after a hunk's line counts up to the next hunk or file header.
/// - Reports errors on malformed hunk headers, premature hunk termination, unknown hunk line prefixes,
///   and line counts that do not match the hunk body.
public func parseUnifiedDiff(_ text: String) throws(DiffParseError) -> ParsedDiff {
    let rawLines = splitDiffLines(text)
    var oldFileName: String? = nil
    var newFileName: String? = nil
    var hunks: [DiffHunk] = []

    var remainingOld = 0
    var remainingNew = 0
    var currentOldStart = 0
    var currentOldCount = 0
    var currentNewStart = 0
    var currentNewCount = 0
    var currentHeader = ""
    var currentOldLine = 0
    var currentNewLine = 0
    var currentLines: [DiffLine] = []
    var inHunk = false

    func flushHunkIfOpen() {
        if inHunk {
            hunks.append(
                DiffHunk(
                    oldStart: currentOldStart,
                    oldCount: currentOldCount,
                    newStart: currentNewStart,
                    newCount: currentNewCount,
                    header: currentHeader,
                    lines: currentLines
                )
            )
            currentLines = []
            inHunk = false
        }
    }

    for (index, line) in rawLines.enumerated() {
        let lineNumber = index + 1

        if remainingOld == 0 && remainingNew == 0 {
            flushHunkIfOpen()

            if line.hasPrefix("@@ ") {
                guard let parsed = parseHunkHeader(line) else {
                    throw .malformedHunkHeader(line: lineNumber, text: String(line))
                }
                currentOldStart = parsed.oldStart
                currentOldCount = parsed.oldCount
                currentNewStart = parsed.newStart
                currentNewCount = parsed.newCount
                currentHeader = String(line)
                currentOldLine = parsed.oldStart
                currentNewLine = parsed.newStart
                currentLines = []
                remainingOld = parsed.oldCount
                remainingNew = parsed.newCount
                inHunk = true
                if remainingOld == 0 && remainingNew == 0 {
                    flushHunkIfOpen()
                }
            } else if !hunks.isEmpty {
                let startsNextFile: Bool
                if line.hasPrefix("diff ") {
                    startsNextFile = true
                } else if line.hasPrefix("---") {
                    let afterDashes = line.dropFirst(3)
                    startsNextFile = afterDashes.first == " " || afterDashes.first == "\t"
                } else {
                    startsNextFile = false
                }
                if startsNextFile {
                    break
                }
            } else {
                if let name = stripFileHeaderName(line, prefix: "---") {
                    oldFileName = name
                } else if let name = stripFileHeaderName(line, prefix: "+++") {
                    newFileName = name
                }
            }
            continue
        }

        if line.hasPrefix("@@") {
            throw .prematureHunkEnd(line: lineNumber)
        }

        let kind: DiffLineKind
        let content: String
        if let first = line.first {
            switch first {
            case "\\":
                continue
            case " ":
                kind = .context
                content = String(line.dropFirst())
            case "+":
                kind = .added
                content = String(line.dropFirst())
            case "-":
                kind = .removed
                content = String(line.dropFirst())
            default:
                throw .unknownHunkLine(line: lineNumber, text: String(line))
            }
        } else {
            // Blank line inside a hunk represents an empty context line without its leading space.
            kind = .context
            content = ""
        }

        let fits: Bool
        switch kind {
        case .context:
            fits = remainingOld > 0 && remainingNew > 0
        case .removed:
            fits = remainingOld > 0
        case .added:
            fits = remainingNew > 0
        case .empty:
            fits = false
        }

        guard fits else {
            throw .lineCountOverflow(line: lineNumber, text: String(line))
        }

        let oldNum: Int?
        let newNum: Int?
        switch kind {
        case .context:
            oldNum = currentOldLine
            newNum = currentNewLine
            currentOldLine = currentOldLine < Int.max ? currentOldLine + 1 : Int.max
            currentNewLine = currentNewLine < Int.max ? currentNewLine + 1 : Int.max
            remainingOld -= 1
            remainingNew -= 1
        case .removed:
            oldNum = currentOldLine
            newNum = nil
            currentOldLine = currentOldLine < Int.max ? currentOldLine + 1 : Int.max
            remainingOld -= 1
        case .added:
            oldNum = nil
            newNum = currentNewLine
            currentNewLine = currentNewLine < Int.max ? currentNewLine + 1 : Int.max
            remainingNew -= 1
        case .empty:
            oldNum = nil
            newNum = nil
        }

        currentLines.append(
            DiffLine(
                kind: kind,
                content: content,
                oldLineNumber: oldNum,
                newLineNumber: newNum
            )
        )

        if remainingOld == 0 && remainingNew == 0 {
            flushHunkIfOpen()
        }
    }

    if remainingOld != 0 || remainingNew != 0 {
        throw .incompleteLastHunk
    }
    flushHunkIfOpen()

    return ParsedDiff(oldFileName: oldFileName, newFileName: newFileName, hunks: hunks)
}

/// Projects parsed hunks into a single-column unified view stream and 0-based hunk start row offsets.
public func buildUnifiedDiffLines(_ parsed: ParsedDiff) -> (lines: [DiffLine], hunkRowOffsets: [Int]) {
    var lines: [DiffLine] = []
    var offsets: [Int] = []

    for hunk in parsed.hunks {
        offsets.append(lines.count)
        lines.append(contentsOf: hunk.lines)
    }

    return (lines, offsets)
}

/// Projects parsed hunks into paired left/right columns for split diff view, padding unequal
/// adjacent removed/added blocks with `.empty` placeholder rows.
public func buildSplitDiffLines(
    _ parsed: ParsedDiff
) -> (left: [DiffLine], right: [DiffLine], hunkRowOffsets: [Int]) {
    var left: [DiffLine] = []
    var right: [DiffLine] = []
    var offsets: [Int] = []
    let emptyLine = DiffLine(kind: .empty, content: "", oldLineNumber: nil, newLineNumber: nil)

    for hunk in parsed.hunks {
        offsets.append(left.count)
        var i = 0
        while i < hunk.lines.count {
            let line = hunk.lines[i]
            if line.kind == .context {
                left.append(line)
                right.append(line)
                i += 1
                continue
            }

            var removed: [DiffLine] = []
            var added: [DiffLine] = []
            while i < hunk.lines.count && hunk.lines[i].kind != .context {
                let change = hunk.lines[i]
                if change.kind == .removed {
                    removed.append(change)
                } else if change.kind == .added {
                    added.append(change)
                }
                i += 1
            }

            let rows = max(removed.count, added.count)
            for row in 0..<rows {
                left.append(row < removed.count ? removed[row] : emptyLine)
                right.append(row < added.count ? added[row] : emptyLine)
            }
        }
    }

    return (left, right, offsets)
}
