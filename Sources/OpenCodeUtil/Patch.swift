public enum Patch {
    public enum BoundaryKind: String, Equatable, Hashable, Sendable, Codable {
        case first
        case last
    }

    // parity: util/src/patch.ts#BoundaryError [status=implemented hash=d8b10380018f]
    public struct BoundaryError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public let boundary: BoundaryKind

        public init(boundary: BoundaryKind) {
            self.boundary = boundary
        }

        // parity: util/src/patch.ts#BoundaryError.message [status=implemented hash=742e8bda16aa]
        public var message: String {
            "The \(boundary.rawValue) line of the patch must be '\(boundary == .first ? "*** Begin Patch" : "*** End Patch")'"
        }

        public var description: String { message }
    }

    // parity: util/src/patch.ts#InvalidHunkError [status=implemented hash=d8180e6898fc]
    public struct InvalidHunkError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public let line: String
        public let lineNumber: Int
        public let reason: String?

        public init(line: String, lineNumber: Int, reason: String? = nil) {
            self.line = line
            self.lineNumber = lineNumber
            self.reason = reason
        }

        // parity: util/src/patch.ts#InvalidHunkError.message [status=implemented hash=2d444a1b2abb]
        public var message: String {
            if let reason, !reason.isEmpty {
                return "Invalid hunk at line \(lineNumber): \(reason)"
            }
            return "Invalid hunk at line \(lineNumber): '\(line)' is not a valid hunk header. Valid hunk headers: '*** Add File: {path}', '*** Delete File: {path}', '*** Update File: {path}'"
        }

        public var description: String { message }
    }

    // parity: util/src/patch.ts#ParseError [status=implemented hash=3c6e05147cf9]
    public enum ParseError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        case boundary(BoundaryError)
        case invalidHunk(InvalidHunkError)

        public var message: String {
            switch self {
            case .boundary(let err): return err.message
            case .invalidHunk(let err): return err.message
            }
        }

        public var description: String { message }
    }

    public struct DeriveError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public let message: String

        public init(_ message: String) {
            self.message = message
        }

        public var description: String { message }
    }

    // parity: util/src/patch.ts#UpdateFileChunk [status=implemented hash=1e9ecd9db14b]
    public struct UpdateFileChunk: Equatable, Hashable, Sendable, Codable {
        public var oldLines: [String]
        public var newLines: [String]
        public var changeContext: String?
        public var endOfFile: Bool?

        public init(
            oldLines: [String],
            newLines: [String],
            changeContext: String? = nil,
            endOfFile: Bool? = nil
        ) {
            self.oldLines = oldLines
            self.newLines = newLines
            self.changeContext = changeContext
            self.endOfFile = endOfFile
        }
    }

    // parity: util/src/patch.ts#Hunk [status=implemented hash=b6a99b2507b7]
    public enum Hunk: Equatable, Hashable, Sendable {
        case add(path: String, contents: String)
        case delete(path: String)
        case update(path: String, movePath: String?, chunks: [UpdateFileChunk])
    }

    // parity: util/src/patch.ts#FileUpdate [status=implemented hash=71ee4894189e]
    public struct FileUpdate: Equatable, Hashable, Sendable, Codable {
        public let content: String
        public let bom: Bool

        public init(content: String, bom: Bool) {
            self.content = content
            self.bom = bom
        }
    }

    // parity: util/src/patch.ts#parse [status=implemented hash=384f45fd525e]
    public static func parse(_ patchText: String) -> Result<[Hunk], ParseError> {
        let stripped = stripHeredoc(trimBoth(patchText))
        let lines = splitLinesLF(stripped).map { line in
            line.hasSuffix("\r") ? String(line.dropLast()) : line
        }
        let begin = (!lines.isEmpty && trimBoth(lines[0]) == "*** Begin Patch") ? 0 : -1
        let end = (!lines.isEmpty && trimBoth(lines[lines.count - 1]) == "*** End Patch") ? lines.count - 1 : -1
        if begin == -1 {
            return .failure(.boundary(BoundaryError(boundary: .first)))
        }
        if end == -1 || begin >= end {
            return .failure(.boundary(BoundaryError(boundary: .last)))
        }

        var hunks: [Hunk] = []
        var index = begin + 1
        while index < end {
            let line = lines[index]
            let header = trimBoth(line)
            if index == begin + 1,
               header.hasPrefix("*** Environment ID:"),
               !trimBoth(String(header.dropFirst("*** Environment ID:".count))).isEmpty {
                index += 1
                continue
            }
            if header.hasPrefix("*** Add File: ") {
                let path = trimBoth(String(header.dropFirst("*** Add File: ".count)))
                switch parseAdd(lines: lines, start: index + 1, end: end, path: path) {
                case .failure(let err):
                    return .failure(.invalidHunk(err))
                case .success(let parsed):
                    hunks.append(.add(path: path, contents: parsed.content))
                    index = parsed.next
                }
                continue
            }
            if header.hasPrefix("*** Delete File: ") {
                let path = trimBoth(String(header.dropFirst("*** Delete File: ".count)))
                let nextLine = (index + 1 < lines.count) ? trimBoth(lines[index + 1]) : nil
                if index + 1 < end, let nextLine, !isBoundary(nextLine) {
                    if nextLine.hasPrefix("*** ") {
                        return .failure(.invalidHunk(InvalidHunkError(line: nextLine, lineNumber: index + 2)))
                    }
                    return .failure(.invalidHunk(InvalidHunkError(
                        line: nextLine,
                        lineNumber: index + 2,
                        reason: "Unexpected line after Delete File '\(path)': '\(nextLine)'. Delete hunks do not contain body lines"
                    )))
                }
                hunks.append(.delete(path: path))
                index += 1
                continue
            }
            if header.hasPrefix("*** Update File: ") {
                let path = trimBoth(String(header.dropFirst("*** Update File: ".count)))
                var next = index + 1
                var movePath: String? = nil
                while next < lines.count && trimEnd(lines[next]) == "*** End of File" {
                    next += 1
                }
                if next < lines.count {
                    let move = trimEnd(lines[next])
                    if move == "*** Move to:" || move.hasPrefix("*** Move to: ") {
                        let rest = move == "*** Move to:" ? "" : String(move.dropFirst("*** Move to: ".count))
                        let dest = trimBoth(rest)
                        if dest.isEmpty {
                            return .failure(.invalidHunk(InvalidHunkError(
                                line: trimBoth(lines[next]),
                                lineNumber: next + 1,
                                reason: "Move destination for '\(path)' must not be empty"
                            )))
                        }
                        movePath = dest
                        next += 1
                    }
                }
                switch parseUpdate(lines: lines, start: next, end: end, path: path, hunk: index) {
                case .failure(let err):
                    return .failure(.invalidHunk(err))
                case .success(let parsed):
                    hunks.append(.update(path: path, movePath: movePath, chunks: parsed.chunks))
                    index = parsed.next
                }
                continue
            }
            return .failure(.invalidHunk(InvalidHunkError(line: header, lineNumber: index + 1)))
        }
        return .success(hunks)
    }

    // parity: util/src/patch.ts#derive [status=implemented hash=be5f8ac74735]
    public static func derive(
        path: String,
        chunks: [UpdateFileChunk],
        original: String
    ) throws -> FileUpdate {
        let source = Bom.split(original)
        var lines = splitLinesLF(source.text)
        if lines.last == "" {
            lines.removeLast()
        }
        let replacements = try computeReplacements(lines: lines, path: path, chunks: chunks)
        for replacement in replacements.reversed() {
            lines.replaceSubrange(replacement.start..<(replacement.start + replacement.remove), with: replacement.insert)
        }
        if lines.last != "" {
            lines.append("")
        }
        let next = Bom.split(lines.joined(separator: "\n"))
        return FileUpdate(content: next.text, bom: source.bom || next.bom)
    }

    // parity: util/src/patch.ts#joinBom [status=implemented hash=644792e24478]
    public static func joinBom(_ text: String, bom: Bool) -> String {
        Bom.join(text, bom: bom)
    }

    // MARK: - Private Parsing Helpers

    private static func parseAdd(
        lines: [String],
        start: Int,
        end: Int,
        path: String
    ) -> Result<(content: String, next: Int), InvalidHunkError> {
        var content: [String] = []
        var index = start
        while index < end && !isBoundary(trimBoth(lines[index])) {
            let line = lines[index]
            if !line.hasPrefix("+") {
                let trimmed = trimBoth(line)
                return .failure(InvalidHunkError(
                    line: trimmed,
                    lineNumber: index + 1,
                    reason: "Invalid Add File line for '\(path)': expected a line starting with '+', got '\(trimmed)'"
                ))
            }
            content.append(String(line.dropFirst()))
            index += 1
        }
        return .success((content: content.joined(separator: "\n"), next: index))
    }

    private static func parseUpdate(
        lines: [String],
        start: Int,
        end: Int,
        path: String,
        hunk: Int
    ) -> Result<(chunks: [UpdateFileChunk], next: Int), InvalidHunkError> {
        var chunks: [UpdateFileChunk] = []
        var index = start
        var afterEndOfFile = false

        while index < end {
            let line = lines[index]
            let updateLine = trimEnd(line)
            if afterEndOfFile {
                if updateLine.isEmpty {
                    index += 1
                    continue
                }
                if updateLine == "@@" || updateLine.hasPrefix("@@ ") {
                    afterEndOfFile = false
                } else if isBoundary(updateLine) {
                    break
                } else {
                    return .failure(InvalidHunkError(
                        line: line,
                        lineNumber: index + 1,
                        reason: "Expected update hunk to start with a @@ context marker, got: '\(line)'"
                    ))
                }
            }
            if updateLine == "*** End of File" {
                if let last = chunks.last, last.oldLines.isEmpty && last.newLines.isEmpty {
                    return .failure(InvalidHunkError(
                        line: updateLine,
                        lineNumber: index + 1,
                        reason: "Update hunk does not contain any lines"
                    ))
                }
                if !chunks.isEmpty {
                    chunks[chunks.count - 1].endOfFile = true
                    afterEndOfFile = true
                }
                index += 1
                continue
            }
            if isBoundary(updateLine) {
                break
            }
            if updateLine == "@@" || updateLine.hasPrefix("@@ ") {
                if let previous = chunks.last, previous.oldLines.isEmpty && previous.newLines.isEmpty {
                    return .failure(InvalidHunkError(
                        line: line,
                        lineNumber: index + 1,
                        reason: "Unexpected line found in update hunk: '\(line)'. Every line should start with ' ' (context line), '+' (added line), or '-' (removed line)"
                    ))
                }
                let ctx: String? = updateLine == "@@" ? nil : String(updateLine.dropFirst("@@ ".count))
                chunks.append(UpdateFileChunk(oldLines: [], newLines: [], changeContext: ctx))
                index += 1
                continue
            }
            if chunks.isEmpty {
                chunks.append(UpdateFileChunk(oldLines: [], newLines: []))
            }
            let lastIdx = chunks.count - 1
            if line.isEmpty {
                chunks[lastIdx].oldLines.append("")
                chunks[lastIdx].newLines.append("")
                index += 1
                continue
            }
            if line.hasPrefix(" ") {
                let rest = String(line.dropFirst())
                chunks[lastIdx].oldLines.append(rest)
                chunks[lastIdx].newLines.append(rest)
                index += 1
                continue
            }
            if line.hasPrefix("-") {
                chunks[lastIdx].oldLines.append(String(line.dropFirst()))
                index += 1
                continue
            }
            if line.hasPrefix("+") {
                chunks[lastIdx].newLines.append(String(line.dropFirst()))
                index += 1
                continue
            }
            let populated = !chunks[lastIdx].oldLines.isEmpty || !chunks[lastIdx].newLines.isEmpty
            return .failure(InvalidHunkError(
                line: line,
                lineNumber: index + 1,
                reason: populated
                    ? "Expected update hunk to start with a @@ context marker, got: '\(line)'"
                    : "Unexpected line found in update hunk: '\(line)'. Every line should start with ' ' (context line), '+' (added line), or '-' (removed line)"
            ))
        }

        if chunks.isEmpty {
            return .failure(InvalidHunkError(
                line: trimBoth(lines[hunk]),
                lineNumber: hunk + 1,
                reason: "Update file hunk for path '\(path)' is empty"
            ))
        }
        let last = chunks[chunks.count - 1]
        if last.oldLines.isEmpty && last.newLines.isEmpty {
            let line = trimBoth(lines[index])
            return .failure(InvalidHunkError(
                line: line,
                lineNumber: index + 1,
                reason: line == "*** End Patch"
                    ? "Update hunk does not contain any lines"
                    : "Unexpected line found in update hunk: '\(line)'. Every line should start with ' ' (context line), '+' (added line), or '-' (removed line)"
            ))
        }
        return .success((chunks: chunks, next: index))
    }

    private static func isBoundary(_ line: String) -> Bool {
        line == "*** End Patch"
            || line.hasPrefix("*** Add File: ")
            || line.hasPrefix("*** Delete File: ")
            || line.hasPrefix("*** Update File: ")
    }

    private struct Replacement {
        let order: Int
        let start: Int
        let remove: Int
        let insert: [String]
    }

    private static func computeReplacements(
        lines: [String],
        path: String,
        chunks: [UpdateFileChunk]
    ) throws -> [Replacement] {
        var replacements: [Replacement] = []
        var lineIndex = 0
        for (order, chunk) in chunks.enumerated() {
            if let changeContext = chunk.changeContext, !changeContext.isEmpty {
                let context = seek(lines: lines, pattern: [changeContext], start: lineIndex, eof: false)
                if context == -1 {
                    throw DeriveError("Failed to find context '\(changeContext)' in \(path)")
                }
                lineIndex = context + 1
            }
            if chunk.oldLines.isEmpty {
                replacements.append(Replacement(order: order, start: lines.count, remove: 0, insert: chunk.newLines))
                continue
            }
            var oldLines = chunk.oldLines
            var newLines = chunk.newLines
            let eof = chunk.endOfFile ?? false
            var found = seek(lines: lines, pattern: oldLines, start: lineIndex, eof: eof)
            if found == -1 && oldLines.last == "" {
                oldLines = Array(oldLines.dropLast())
                if newLines.last == "" {
                    newLines = Array(newLines.dropLast())
                }
                found = seek(lines: lines, pattern: oldLines, start: lineIndex, eof: eof)
            }
            if found == -1 && chunk.oldLines.allSatisfy({ $0.isEmpty }) {
                let expected = chunk.oldLines.count == 1
                    ? "an expected blank line"
                    : "\(chunk.oldLines.count) consecutive blank lines"
                throw DeriveError("Failed to find \(expected) in \(path)")
            }
            if found == -1 {
                throw DeriveError("Failed to find expected lines in \(path):\n\(chunk.oldLines.joined(separator: "\n"))")
            }
            replacements.append(Replacement(order: order, start: found, remove: oldLines.count, insert: newLines))
            lineIndex = found + oldLines.count
        }
        return replacements.sorted { lhs, rhs in
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            return lhs.order < rhs.order
        }
    }

    private static func seek(lines: [String], pattern: [String], start: Int, eof: Bool) -> Int {
        guard !pattern.isEmpty else { return -1 }
        let comparators: [(String, String) -> Bool] = [
            { $0 == $1 },
            { trimEnd($0) == trimEnd($1) },
            { trimBoth($0) == trimBoth($1) },
            { normalize(trimBoth($0)) == normalize(trimBoth($1)) },
        ]
        if eof {
            let offset = lines.count - pattern.count
            if offset < start { return -1 }
            for compare in comparators {
                if matches(lines: lines, pattern: pattern, offset: offset, compare: compare) {
                    return offset
                }
            }
            return -1
        }
        let maxOffset = lines.count - pattern.count
        guard start <= maxOffset else { return -1 }
        for compare in comparators {
            for offset in start...maxOffset {
                if matches(lines: lines, pattern: pattern, offset: offset, compare: compare) {
                    return offset
                }
            }
        }
        return -1
    }

    private static func matches(
        lines: [String],
        pattern: [String],
        offset: Int,
        compare: (String, String) -> Bool
    ) -> Bool {
        for i in 0..<pattern.count {
            if !compare(lines[offset + i], pattern[i]) {
                return false
            }
        }
        return true
    }

    private static func normalize(_ value: String) -> String {
        var out = ""
        out.unicodeScalars.reserveCapacity(value.unicodeScalars.count)
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x2018, 0x2019, 0x201A, 0x201B:
                out.unicodeScalars.append("'")
            case 0x201C, 0x201D, 0x201E, 0x201F:
                out.unicodeScalars.append("\"")
            case 0x2010, 0x2011, 0x2012, 0x2013, 0x2014, 0x2015, 0x2212:
                out.unicodeScalars.append("-")
            case 0x00A0, 0x2002...0x200A, 0x202F, 0x205F, 0x3000:
                out.unicodeScalars.append(" ")
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// Matches `^(?:cat\s+)?<<(['"]?)(\w+)\1\s*\n([\s\S]*?)\n\2\s*$`
    private static func stripHeredoc(_ input: String) -> String {
        let scalars = Array(input.unicodeScalars)
        var i = 0
        // Optional "cat" followed by >=1 whitespace
        if scalars.count >= 4,
           scalars[0] == "c", scalars[1] == "a", scalars[2] == "t",
           isWhitespace(scalars[3]) {
            i = 4
            while i < scalars.count && isWhitespace(scalars[i]) { i += 1 }
        }
        guard i + 2 <= scalars.count, scalars[i] == "<", scalars[i + 1] == "<" else {
            return input
        }
        i += 2
        var quote: Unicode.Scalar? = nil
        if i < scalars.count && (scalars[i] == "'" || scalars[i] == "\"") {
            quote = scalars[i]
            i += 1
        }
        let delimStart = i
        while i < scalars.count && isWordChar(scalars[i]) { i += 1 }
        guard i > delimStart else { return input }
        let delimiter = Array(scalars[delimStart..<i])
        if let quote {
            guard i < scalars.count && scalars[i] == quote else { return input }
            i += 1
        }
        // `\s*\n`: consume whitespace until we can match a '\n'
        // Because `\s*` can include '\n', try the first '\n' at or after i while all intervening chars are whitespace.
        // Note: in `^(?:cat\s+)?<<(['"]?)(\w+)\1\s*\n([\s\S]*?)\n\2\s*$`, greedy `\s*` consumes as many whitespace
        // chars as possible before the final `\n` before body, unless body starts immediately after the first `\n`.
        // Specifically, `\s*\n` matches all whitespace up through the last `\n` in the contiguous whitespace run!
        let wsStart = i
        var lastNewlineAfterHeader: Int? = nil
        while i < scalars.count && isWhitespace(scalars[i]) {
            if scalars[i] == "\n" { lastNewlineAfterHeader = i }
            i += 1
        }
        guard lastNewlineAfterHeader != nil else { return input }
        // Wait: if the contiguous whitespace run contains multiple '\n' and the delimiter appears inside?
        // No, delimiter is `\w+` (non-whitespace), so all chars in wsStart..<i are whitespace.
        // Wait: if input is `<<EOF\n\nEOF`, greedy `\s*\n` consumes the first `\n`, leaving body empty?
        // Let's check: in JS, `<<EOF\n\nEOF` matches `\s*` = `""`, `\n` = first `\n`, body = `""`, `\n` = second `\n`, `EOF`.
        // Because we need `\n` before body AND `\n` before `EOF`, try the last valid newline in wsStart...firstBodyNewline
        // that still leaves a `\n` + delimiter + `\s*$` at the end!
        var end = scalars.count
        while end > 0 && isWhitespace(scalars[end - 1]) { end -= 1 }
        guard end >= delimiter.count + 1 else { return input }
        let delimEndStart = end - delimiter.count
        for k in 0..<delimiter.count where scalars[delimEndStart + k] != delimiter[k] {
            return input
        }
        guard scalars[delimEndStart - 1] == "\n" else { return input }
        let closingNewline = delimEndStart - 1

        // Find the rightmost '\n' in wsStart..<closingNewline where all chars in wsStart..<nl are whitespace.
        var headerNewline: Int? = nil
        var scan = wsStart
        while scan < closingNewline && isWhitespace(scalars[scan]) {
            if scalars[scan] == "\n" {
                headerNewline = scan
            }
            scan += 1
        }
        // Also check if closingNewline itself is preceded by another '\n' in the whitespace run: already handled by `scan < closingNewline`.
        guard let nl = headerNewline else { return input }
        let bodyStart = nl + 1
        if bodyStart > closingNewline { return input }
        return String(String.UnicodeScalarView(scalars[bodyStart..<closingNewline]))
    }

    private static func isWordChar(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        return (v >= 0x30 && v <= 0x39)
            || (v >= 0x41 && v <= 0x5A)
            || (v >= 0x61 && v <= 0x7A)
            || v == 0x5F
    }

    private static func isWhitespace(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        return v == 0x09 || v == 0x0A || v == 0x0B || v == 0x0C || v == 0x0D || v == 0x20
            || v == 0xA0 || v == 0x1680
            || (v >= 0x2000 && v <= 0x200A)
            || v == 0x2028 || v == 0x2029 || v == 0x202F || v == 0x205F || v == 0x3000 || v == 0xFEFF
    }

    private static func trimBoth(_ text: String) -> String {
        let scalars = text.unicodeScalars
        var start = scalars.startIndex
        var end = scalars.endIndex
        while start < end && isWhitespace(scalars[start]) {
            start = scalars.index(after: start)
        }
        while end > start {
            let prev = scalars.index(before: end)
            if isWhitespace(scalars[prev]) {
                end = prev
            } else {
                break
            }
        }
        return String(scalars[start..<end])
    }

    private static func trimEnd(_ text: String) -> String {
        let scalars = text.unicodeScalars
        var end = scalars.endIndex
        while end > scalars.startIndex {
            let prev = scalars.index(before: end)
            if isWhitespace(scalars[prev]) {
                end = prev
            } else {
                break
            }
        }
        return String(scalars[scalars.startIndex..<end])
    }

    private static func splitLinesLF(_ text: String) -> [String] {
        var result: [String] = []
        var start = text.utf8.startIndex
        var i = start
        while i < text.utf8.endIndex {
            if text.utf8[i] == 0x0A {
                result.append(String(decoding: text.utf8[start..<i], as: UTF8.self))
                i = text.utf8.index(after: i)
                start = i
            } else {
                i = text.utf8.index(after: i)
            }
        }
        result.append(String(decoding: text.utf8[start..<text.utf8.endIndex], as: UTF8.self))
        return result
    }
}
