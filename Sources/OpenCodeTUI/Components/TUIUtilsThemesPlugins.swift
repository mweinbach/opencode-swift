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
#if canImport(WinSDK)
import WinSDK
#endif
import Foundation
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil
import OpenTUICore
import OpenTUIKeymap
import OpenTUILayout
import OpenTUIRenderables
import OpenTUIView
import Synchronization

private extension JSONValue {
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}

// MARK: - TUIUtil (`packages/tui/src/util/*`, 34 files / 122 symbols)

/// Cross-platform TUI utility functions (`packages/tui/src/util/*`).
public enum TUIUtil {

    // MARK: String Width (`src/util/string-width.bun.ts`, `src/util/string-width.node.ts`)

    /// Measures terminal cell width of `value` after stripping ANSI escape sequences (Bun/native width parity).
    // parity: tui/src/util/string-width.bun.ts#stringWidth [status=implemented hash=3b535cc64737]
    public static func stringWidth(_ value: String) -> Int {
        stringWidthNode(value)
    }

    /// Measures terminal cell width of `value` with ANSI stripping and text-presentation emoji handling.
    // parity: tui/src/util/string-width.node.ts#stringWidth [status=implemented hash=6eb7330d5d82]
    public static func stringWidthNode(_ value: String) -> Int {
        let stripped = stripAnsiSequences(value)
        var total = 0
        for grapheme in graphemes(stripped) {
            let measured = OpenTUICore.stringWidth(grapheme, widthMethod: .unicode)
            if measured == 2,
               let first = grapheme.unicodeScalars.first,
               !grapheme.contains("\u{FE0F}"),
               !grapheme.contains("\u{20E3}"),
               !grapheme.contains("\u{200D}"),
               first.properties.isEmoji,
               !first.properties.isEmojiPresentation,
               !isEastAsianWideScalar(first.value)
            {
                total += 1
            } else {
                total += measured
            }
        }
        return total
    }

    private static func isEastAsianWideScalar(_ v: UInt32) -> Bool {
        (0x1100...0x115F).contains(v)
            || (0x2329...0x232A).contains(v)
            || (0x2E80...0x303E).contains(v)
            || (0x3040...0xA4CF).contains(v)
            || (0xAC00...0xD7A3).contains(v)
            || (0xF900...0xFAFF).contains(v)
            || (0xFE10...0xFE19).contains(v)
            || (0xFE30...0xFE6F).contains(v)
            || (0xFF00...0xFF60).contains(v)
            || (0xFFE0...0xFFE6).contains(v)
            || (0x20000...0x3FFFD).contains(v)
    }

    // MARK: Record (`src/util/record.ts`)

    /// Returns whether a `JSONValue` is a JSON object dictionary (non-null, non-array).
    // parity: tui/src/util/record.ts#isRecord [status=implemented hash=74b817bec81a]
    public static func isRecord(_ value: JSONValue?) -> Bool {
        if case .object = value { return true }
        return false
    }

    public static func asRecord(_ value: JSONValue?) -> [String: JSONValue]? {
        if case .object(let dict) = value { return dict }
        return nil
    }

    // MARK: Locale (`src/util/locale.ts`)

    /// Uppercases the first character of every ASCII word boundary.
    // parity: tui/src/util/locale.ts#titlecase [status=implemented hash=13588092ae8d]
    public static func titlecase(_ str: String) -> String {
        var result = ""
        result.reserveCapacity(str.count)
        var inWord = false
        for ch in str {
            let isWordChar = ch.isLetter || ch.isNumber || ch == "_"
            if isWordChar && !inWord {
                result.append(contentsOf: String(ch).uppercased())
            } else {
                result.append(ch)
            }
            inWord = isWordChar
        }
        return result
    }

    /// Formats epoch milliseconds as a locale short time string.
    // parity: tui/src/util/locale.ts#time [status=implemented hash=099a2958ef28]
    public static func time(_ inputMs: Double) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: Date(timeIntervalSince1970: inputMs / 1000.0))
    }

    /// Formats epoch milliseconds as `<time> · <date>`.
    // parity: tui/src/util/locale.ts#datetime [status=implemented hash=40bf448073d6]
    public static func datetime(_ inputMs: Double) -> String {
        let date = Date(timeIntervalSince1970: inputMs / 1000.0)
        let localTime = time(inputMs)
        let dateFmt = DateFormatter()
        dateFmt.dateStyle = .short
        dateFmt.timeStyle = .none
        let localDate = dateFmt.string(from: date)
        return "\(localTime) · \(localDate)"
    }

    /// Compact human number formatting (`1.0K`, `1.0M` at `>= 999950`).
    // parity: tui/src/util/locale.ts#number [status=implemented hash=e963d003c1b9]
    public static func number(_ num: Double) -> String {
        if num >= 999_950 {
            return formatFixed1(num / 1_000_000.0) + "M"
        } else if num >= 1_000 {
            return formatFixed1(num / 1_000.0) + "K"
        }
        if num.rounded(.towardZero) == num {
            return String(Int64(num))
        }
        return String(num)
    }

    public static func number(_ num: Int) -> String {
        number(Double(num))
    }

    private static func formatFixed1(_ value: Double) -> String {
        let rounded = (value * 10.0).rounded() / 10.0
        let whole = Int64(rounded)
        let frac = abs(Int(((rounded - Double(whole)) * 10.0).rounded())) % 10
        return "\(whole).\(frac)"
    }

    /// Truncates a string to `len` UTF-16 code units with trailing ellipsis `…`.
    // parity: tui/src/util/locale.ts#truncate [status=implemented hash=7bbc093d2753]
    public static func truncate(_ str: String, _ len: Int) -> String {
        let u16 = str.utf16
        if u16.count <= len { return str }
        let keep = max(0, len - 1)
        let end = u16.index(u16.startIndex, offsetBy: keep)
        return String(str[..<end]) + "…"
    }

    /// Splits a string into extended grapheme cluster strings.
    // parity: tui/src/util/locale.ts#graphemes [status=implemented hash=3d3fe97e557c]
    public static func graphemes(_ str: String) -> [String] {
        str.map(String.init)
    }

    /// Takes leading grapheme clusters fitting within `width` display columns.
    // parity: tui/src/util/locale.ts#takeWidth [status=implemented hash=e97553c7db96]
    public static func takeWidth(_ str: String, _ width: Int) -> String {
        if width <= 0 { return "" }
        if stringWidth(str) <= width { return str }
        var out = ""
        var used = 0
        for seg in graphemes(str) {
            let next = stringWidth(seg)
            if used + next > width { break }
            out.append(seg)
            used += next
        }
        return out
    }

    /// Truncates a string to fit within `width` display columns, appending `…`.
    // parity: tui/src/util/locale.ts#truncateWidth [status=implemented hash=89a2b7f9911f]
    public static func truncateWidth(_ str: String, _ width: Int) -> String {
        if width <= 0 { return "" }
        if stringWidth(str) <= width { return str }
        if width == 1 { return "…" }
        return takeWidth(str, width - 1) + "…"
    }

    /// Truncates a string from the left to `len` UTF-16 code units with leading `…`.
    // parity: tui/src/util/locale.ts#truncateLeft [status=implemented hash=2cca30ca37a0]
    public static func truncateLeft(_ str: String, _ len: Int) -> String {
        let u16 = str.utf16
        if u16.count <= len { return str }
        let keep = max(0, len - 1)
        let start = u16.index(u16.endIndex, offsetBy: -keep)
        return "…" + String(str[start...])
    }

    /// Truncates the middle of a string to `maxLength` UTF-16 code units.
    // parity: tui/src/util/locale.ts#truncateMiddle [status=implemented hash=46aa4a840101]
    public static func truncateMiddle(_ str: String, maxLength: Int = 35) -> String {
        if maxLength <= 0 { return "" }
        let u16 = str.utf16
        if u16.count <= maxLength { return str }
        let ellipsis = "…"
        let available = maxLength - ellipsis.utf16.count
        let keepStart = Int(ceil(Double(available) / 2.0))
        let keepEnd = Int(floor(Double(available) / 2.0))
        let startEnd = u16.index(u16.startIndex, offsetBy: max(0, keepStart))
        if keepEnd <= 0 {
            return String(str[..<startEnd]) + ellipsis
        }
        let tailStart = u16.index(u16.endIndex, offsetBy: -keepEnd)
        return String(str[..<startEnd]) + ellipsis + String(str[tailStart...])
    }

    // MARK: Collapse Tool & Shell Output (`src/util/collapse-tool-output.ts`)

    public struct CollapsedOutput: Equatable, Hashable, Sendable {
        public let output: String
        public let overflow: Bool

        public init(output: String, overflow: Bool) {
            self.output = output
            self.overflow = overflow
        }
    }

    public struct CollapsedShellOutput: Equatable, Hashable, Sendable {
        public let input: String
        public let output: String
        public let overflow: Bool

        public init(input: String, output: String, overflow: Bool) {
            self.input = input
            self.output = output
            self.overflow = overflow
        }
    }

    /// Collapses multiline tool output to `maxLines` lines and `maxChars` Unicode scalars.
    // parity: tui/src/util/collapse-tool-output.ts#collapseToolOutput [status=implemented hash=8dd678cbd810]
    public static func collapseToolOutput(_ output: String, maxLines: Int, maxChars: Int) -> CollapsedOutput {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let scalars = Array(output.unicodeScalars)
        if lines.count <= maxLines && scalars.count <= maxChars {
            return CollapsedOutput(output: output, overflow: false)
        }
        var visible = Array(lines.prefix(max(0, maxLines)))
        if lines.count > maxLines && !visible.isEmpty {
            visible[visible.count - 1] += "…"
        }
        let preview = visible.joined(separator: "\n")
        let previewScalars = Array(preview.unicodeScalars)
        if previewScalars.count > maxChars {
            let cut = String(String.UnicodeScalarView(previewScalars.prefix(max(0, maxChars - 1)))) + "…"
            return CollapsedOutput(output: cut, overflow: true)
        }
        return CollapsedOutput(output: preview, overflow: true)
    }

    /// Collapses a shell command and its tail output to fit within `maxLines` and `maxChars`.
    // parity: tui/src/util/collapse-tool-output.ts#collapseShellOutput [status=implemented hash=1556b8c05d41]
    public static func collapseShellOutput(
        input: String,
        output: String,
        maxLines: Int,
        maxChars: Int
    ) -> CollapsedShellOutput {
        if input.isEmpty {
            let collapsed = collapseToolOutput(output, maxLines: maxLines, maxChars: maxChars)
            return CollapsedShellOutput(
                input: input,
                output: collapsed.overflow ? collapseTail(output, maxLines: maxLines, maxChars: maxChars) : output,
                overflow: collapsed.overflow
            )
        }
        let commandLines = min(2, maxLines)
        let lineChars = max(1, maxChars / max(1, maxLines))
        let command = collapseShellCommand(input, maxLines: commandLines, lineWidth: lineChars)
        if output.isEmpty {
            return CollapsedShellOutput(input: command.output, output: output, overflow: command.overflow)
        }
        let lines = max(1, maxLines - command.lines - 1)
        let chars = max(1, maxChars - command.output.unicodeScalars.count - 2)
        let collapsed = collapseToolOutput(output, maxLines: lines, maxChars: chars)
        return CollapsedShellOutput(
            input: command.output,
            output: collapsed.overflow ? collapseTail(output, maxLines: lines, maxChars: chars) : output,
            overflow: command.overflow || collapsed.overflow
        )
    }

    private static func collapseShellCommand(_ input: String, maxLines: Int, lineWidth: Int) -> (output: String, overflow: Bool, lines: Int) {
        var visible: [String] = []
        var lines = 1
        var width = 0
        var overflow = false
        for segment in graphemes(input) {
            if segment == "\n" {
                if lines >= maxLines {
                    overflow = true
                    break
                }
                visible.append(segment)
                lines += 1
                width = 0
                continue
            }
            let next = stringWidth(segment)
            if width + next > lineWidth {
                if lines >= maxLines {
                    overflow = true
                    break
                }
                lines += 1
                width = 0
            }
            visible.append(segment)
            width += next
        }
        if !overflow {
            return (input, false, lines)
        }
        if width >= lineWidth, let removed = visible.popLast(), removed != "\n" {
            width -= stringWidth(removed)
        }
        return (visible.joined() + "…", true, lines)
    }

    private static func collapseTail(_ output: String, maxLines: Int, maxChars: Int) -> String {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.count <= maxLines && output.unicodeScalars.count <= maxChars {
            return output
        }
        let count = max(1, lines.count - max(0, maxLines - 1))
        let label = "(\(count) earlier \(count == 1 ? "line" : "lines"))"
        if maxLines <= 1 { return label }
        let preview = Array(lines.suffix(maxLines - 1).joined(separator: "\n").unicodeScalars)
        let available = maxChars - label.unicodeScalars.count - 1
        if available <= 0 { return label }
        let tail = String(String.UnicodeScalarView(preview.suffix(available)))
        return "\(label)\n\(tail)"
    }

    // MARK: Config Directories (`src/util/config-directories.ts`)

    private static func ancestorDirectories(_ cwd: String) -> [String] {
        var dirs: [String] = []
        var seen = Set<String>()
        var current = URL(fileURLWithPath: cwd).standardized.path
        while !current.isEmpty && seen.insert(current).inserted {
            dirs.append(current)
            let parent = URL(fileURLWithPath: current).deletingLastPathComponent().standardized.path
            if parent.isEmpty || parent == current { break }
            current = parent
        }
        return dirs.reversed()
    }

    // parity: tui/src/util/config-directories.ts#configDirectories [status=implemented hash=9eae9f97239d]
    public static func configDirectories(config: String, cwd: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        let candidates = [config] + ancestorDirectories(cwd).map {
            URL(fileURLWithPath: $0).appendingPathComponent(".opencode").path
        }
        for dir in candidates where seen.insert(dir).inserted {
            result.append(dir)
        }
        return result
    }

    // parity: tui/src/util/config-directories.ts#projectConfigDirectories [status=implemented hash=5e9abf864494]
    public static func projectConfigDirectories(project: String, cwd: String) -> [String] {
        let dirs = ancestorDirectories(cwd)
        let resolvedProject = URL(fileURLWithPath: project).standardized.path
        let start = dirs.firstIndex(of: resolvedProject) ?? 0
        return dirs[start...].map { URL(fileURLWithPath: $0).appendingPathComponent(".opencode").path }
    }

    // parity: tui/src/util/config-directories.ts#localProjectDirectory [status=implemented hash=e1a78d6bc467]
    public static func localProjectDirectory(_ cwd: String) async throws -> String {
        let fm = FileManager.default
        let dirs = ancestorDirectories(cwd)
        for dir in dirs.reversed() {
            let gitPath = URL(fileURLWithPath: dir).appendingPathComponent(".git").path
            let hgPath = URL(fileURLWithPath: dir).appendingPathComponent(".hg").path
            if fm.fileExists(atPath: gitPath) || fm.fileExists(atPath: hgPath) {
                return dir
            }
        }
        return URL(fileURLWithPath: cwd).standardized.path
    }

    // parity: tui/src/util/config-directories.ts#isMissingPath [status=implemented hash=0302dfb28dc1]
    public static func isMissingPath(_ error: any Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            return nsError.code == NSFileReadNoSuchFileError || nsError.code == NSFileNoSuchFileError
        }
        if nsError.domain == NSPOSIXErrorDomain {
            return nsError.code == Int(ENOENT) || nsError.code == Int(ENOTDIR)
        }
        let desc = String(describing: error)
        return desc.contains("ENOENT") || desc.contains("ENOTDIR")
    }

    // MARK: Connected Provider (`src/util/connected-provider.ts`)

    public struct IntegrationConnectionsSummary: Equatable, Hashable, Sendable {
        public let connectionCount: Int

        public init(connectionCount: Int) {
            self.connectionCount = connectionCount
        }
    }

    // parity: tui/src/util/connected-provider.ts#hasConnectedProvider [status=implemented hash=41e1009bd99c]
    public static func hasConnectedProvider(_ integrations: [IntegrationConnectionsSummary]) -> Bool {
        integrations.contains { $0.connectionCount > 0 }
    }

    // MARK: Delayed Presence (`src/util/delayed-presence.ts`)

    public final class DelayedPresenceController<Value: Sendable>: Sendable {
        private struct State: Sendable {
            var current: Value? = nil
            var visible: Bool = false
            var revealAtMs: Double? = nil
        }

        private let delayFn: @Sendable (Value) -> Double
        private let equalsFn: (@Sendable (Value, Value) -> Bool)?
        private let state = Mutex(State())

        public init(
            delay: @escaping @Sendable (Value) -> Double,
            equals: (@Sendable (Value, Value) -> Bool)? = nil
        ) {
            self.delayFn = delay
            self.equalsFn = equals
        }

        public var isVisible: Bool { state.withLock { $0.visible } }

        public func update(_ next: Value?, at nowMs: Double) {
            state.withLock { s in
                if let prev = s.current, let n = next, let eq = equalsFn, eq(prev, n) {
                    return
                }
                s.current = next
                s.visible = false
                s.revealAtMs = nil
                guard let next else { return }
                let remaining = delayFn(next)
                if remaining <= 0 {
                    s.visible = true
                } else {
                    s.revealAtMs = nowMs + remaining
                }
            }
        }

        public func tick(at nowMs: Double) {
            state.withLock { s in
                if let reveal = s.revealAtMs, nowMs >= reveal {
                    s.visible = true
                    s.revealAtMs = nil
                }
            }
        }
    }

    // parity: tui/src/util/delayed-presence.ts#createDelayedPresence [status=adapted hash=30d0676af373]
    public static func createDelayedPresence<Value: Sendable>(
        delay: @escaping @Sendable (Value) -> Double,
        equals: (@Sendable (Value, Value) -> Bool)? = nil
    ) -> DelayedPresenceController<Value> {
        DelayedPresenceController(delay: delay, equals: equals)
    }

    // MARK: Diff Patch Splitting (`src/util/diff.ts`)

    // parity: tui/src/util/diff.ts#PatchHunk [status=implemented hash=25a28da79309]
    public struct PatchHunk: Equatable, Hashable, Sendable {
        public let patch: String
        public let header: String?
        public let rows: Int?

        public init(patch: String, header: String? = nil, rows: Int? = nil) {
            self.patch = patch
            self.header = header
            self.rows = rows
        }
    }

    // parity: tui/src/util/diff.ts#AddedPatchChunk [status=implemented hash=65726f18c8e8]
    public struct AddedPatchChunk: Equatable, Hashable, Sendable {
        public let patch: String
        public let lines: [String]
        public let rows: Int

        public init(patch: String, lines: [String], rows: Int) {
            self.patch = patch
            self.lines = lines
            self.rows = rows
        }
    }

    /// Splits a pure new-file (`@@ -0,0 +1,N @@`) patch into chunks of `size` lines.
    // parity: tui/src/util/diff.ts#splitAddedPatch [status=implemented hash=57b369333b2b]
    public static func splitAddedPatch(_ patch: String, size: Int) -> [AddedPatchChunk]? {
        guard size > 0 else { return nil }
        let pattern = #"(?m)^@@ -0,0 \+1,(\d+) @@[^\n]*\n"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: patch, range: NSRange(patch.startIndex..., in: patch)),
              let fullRange = Range(match.range, in: patch),
              let countRange = Range(match.range(at: 1), in: patch),
              let count = Int(patch[countRange])
        else {
            return nil
        }
        var body = String(patch[fullRange.upperBound...])
        if body.hasSuffix("\n") { body.removeLast() }
        var lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var marker: String? = nil
        if let last = lines.last, last.hasPrefix("\\ No newline at end of file") {
            marker = lines.removeLast()
        }
        guard lines.count == count, lines.allSatisfy({ $0.hasPrefix("+") }) else {
            return nil
        }
        let prefix = String(patch[..<fullRange.lowerBound])
        let chunkCount = (count + size - 1) / size
        return (0..<chunkCount).map { index in
            let start = index * size
            let end = min(count, start + size)
            let slice = Array(lines[start..<end])
            let suffix = (marker != nil && start + size >= count) ? "\n\(marker!)" : ""
            let chunkPatch = "\(prefix)@@ -0,0 +\(start + 1),\(slice.count) @@\n\(slice.joined(separator: "\n"))\(suffix)"
            return AddedPatchChunk(patch: chunkPatch, lines: slice, rows: slice.count)
        }
    }

    /// Splits a multi-hunk unified diff patch into standalone `PatchHunk` entries with side-by-side row counts.
    // parity: tui/src/util/diff.ts#splitPatchHunks [status=implemented hash=cc448b4a0047]
    public static func splitPatchHunks(_ patch: String) -> [PatchHunk] {
        let pattern = #"(?m)^@@ -\d+(?:,\d+)? \+\d+(?:,\d+)? @@.*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [PatchHunk(patch: patch)]
        }
        let matches = regex.matches(in: patch, range: NSRange(patch.startIndex..., in: patch))
        let starts: [String.Index] = matches.compactMap { Range($0.range, in: patch)?.lowerBound }
        if starts.count <= 1 {
            return [PatchHunk(patch: patch)]
        }
        let prefix = String(patch[..<starts[0]])
        return starts.enumerated().map { idx, start in
            let end = idx + 1 < starts.count ? starts[idx + 1] : patch.endIndex
            let hunkBody = String(patch[start..<end])
            let headerEnd = hunkBody.firstIndex(of: "\n") ?? hunkBody.endIndex
            let header = String(hunkBody[..<headerEnd])
            return PatchHunk(
                patch: prefix + hunkBody,
                header: header,
                rows: splitDiffRows(hunkBody)
            )
        }
    }

    private static func splitDiffRows(_ hunk: String) -> Int {
        var trimmed = hunk
        if trimmed.hasSuffix("\n") { trimmed.removeLast() }
        let allLines = trimmed.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let lines = Array(allLines.dropFirst())
        var rows = 0
        var index = 0
        while index < lines.count {
            let first = lines[index].first
            if first == " " || first == nil {
                rows += 1
                index += 1
                continue
            }
            if first == "\\" {
                index += 1
                continue
            }
            var additions = 0
            var deletions = 0
            while index < lines.count, let ch = lines[index].first, (ch == "+" || ch == "-") {
                if ch == "+" { additions += 1 }
                if ch == "-" { deletions += 1 }
                index += 1
            }
            rows += max(additions, deletions)
        }
        return rows
    }

    // MARK: Error Details & Formatting (`src/util/error-details.ts`, `src/util/error.ts`)

    public struct ErrorDetailsResult: Equatable, Hashable, Sendable {
        public let text: String
        public let prompt: String

        public init(text: String, prompt: String) {
            self.text = text
            self.prompt = prompt
        }
    }

    // parity: tui/src/util/error-details.ts#errorDetails [status=implemented hash=ad2420a7204b]
    public static func errorDetails(
        title: String,
        error: String,
        context: String? = nil,
        diagnosticRef: String? = nil
    ) -> ErrorDetailsResult {
        var textParts = [title]
        if let context, !context.isEmpty { textParts.append(context) }
        textParts.append("Error: \(error)")
        if let diagnosticRef, !diagnosticRef.isEmpty { textParts.append("Reference: \(diagnosticRef)") }
        let text = textParts.joined(separator: "\n")

        var promptParts = [
            "Investigate why this OpenCode component failed in the current project.",
            text,
        ]
        if let diagnosticRef, !diagnosticRef.isEmpty {
            promptParts.append(
                "Find the server log entry matching reference \(diagnosticRef) and inspect its original cause. If the server logs are not accessible from this session, say so and ask for the matching log entry; do not infer the cause from the reference alone."
            )
        }
        promptParts.append(
            "Inspect the relevant project and global OpenCode configuration, startup or loading behavior, required environment variables or credentials, dependencies, and logs. Identify the root cause and recommend a fix. Do not expose credentials."
        )
        return ErrorDetailsResult(text: text, prompt: promptParts.joined(separator: "\n\n"))
    }

    /// Formats structured OpenCode CLI / config / provider JSON errors into human-readable messages.
    // parity: tui/src/util/error.ts#cliErrorMessage [status=implemented hash=7f1c98f746df]
    public static func cliErrorMessage(_ input: JSONValue) -> String? {
        guard case .object(let dict) = input else { return nil }
        if case .object(let cause) = dict["cause"], let body = cause["body"],
           let formatted = cliErrorMessage(body)
        {
            return formatted
        }
        let tag = dict["_tag"]?.stringValue
        let name = dict["name"]?.stringValue
        if tag == "CliError" || tag == "AccountServiceError" || tag == "AccountTransportError" {
            return dict["message"]?.stringValue ?? ""
        }
        func configData(_ expected: String) -> [String: JSONValue]? {
            if name == expected, case .object(let data) = dict["data"] { return data }
            if tag == expected { return dict }
            return nil
        }
        if let model = configData("ProviderModelNotFoundError") {
            let pid = model["providerID"]?.stringValue ?? ""
            let mid = model["modelID"]?.stringValue ?? ""
            var lines = ["Model not found: \(pid)/\(mid)"]
            if case .array(let items) = model["suggestions"] {
                let suggestions = items.compactMap(\.stringValue)
                if !suggestions.isEmpty {
                    lines.append("Did you mean: " + suggestions.joined(separator: ", "))
                }
            }
            lines.append("Try: `opencode models` to list available models")
            lines.append("Or check your config (opencode.json) provider/model names")
            return lines.joined(separator: "\n")
        }
        if let provider = configData("ProviderInitError") {
            let pid = provider["providerID"]?.stringValue ?? ""
            return "Failed to initialize provider \"\(pid)\". Check credentials and configuration."
        }
        if let jsonErr = configData("ConfigJsonError") {
            let path = jsonErr["path"]?.stringValue ?? ""
            let msg = jsonErr["message"]?.stringValue
            return "Config file at \(path) is not valid JSON(C)" + (msg.map { ": \($0)" } ?? "")
        }
        if let dirErr = configData("ConfigDirectoryTypoError") {
            let dir = dirErr["dir"]?.stringValue ?? ""
            let path = dirErr["path"]?.stringValue ?? ""
            let suggestion = dirErr["suggestion"]?.stringValue ?? ""
            return "Directory \"\(dir)\" in \(path) is not valid. Rename the directory to \"\(suggestion)\" or remove it. This is a common typo."
        }
        if let fmErr = configData("ConfigFrontmatterError") {
            return fmErr["message"]?.stringValue ?? ""
        }
        if let invalid = configData("ConfigInvalidError") {
            let path = invalid["path"]?.stringValue
            let msg = invalid["message"]?.stringValue
            let atPath = (path != nil && path != "config") ? " at \(path!)" : ""
            var lines = ["Configuration is invalid\(atPath)" + (msg.map { ": \($0)" } ?? "")]
            if case .array(let rawIssues) = invalid["issues"] {
                for item in rawIssues {
                    if case .object(let obj) = item,
                       let issueMsg = obj["message"]?.stringValue,
                       case .array(let pathItems) = obj["path"]
                    {
                        let segs = pathItems.compactMap(\.stringValue)
                        if segs.count == pathItems.count {
                            lines.append("↳ \(issueMsg) \(segs.joined(separator: "."))")
                        }
                    }
                }
            }
            return lines.joined(separator: "\n")
        }
        if tag == "UICancelledError" || name == "UICancelledError" {
            return ""
        }
        return nil
    }

    // parity: tui/src/util/error.ts#errorFormat [status=implemented hash=f3d562c3386d]
    public static func errorFormat(_ error: any Error) -> String {
        let desc = String(describing: error)
        if !desc.isEmpty { return desc }
        return error.localizedDescription
    }

    public static func errorFormat(_ value: JSONValue) -> String {
        switch value {
        case .string(let s): return s
        case .object(let dict) where dict.isEmpty: return "Error (no message)"
        default:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(value), let str = String(data: data, encoding: .utf8) {
                return str
            }
            return "Unexpected error (unserializable)"
        }
    }

    // parity: tui/src/util/error.ts#errorMessage [status=implemented hash=66fa43f2cfd3]
    public static func errorMessage(_ error: any Error) -> String {
        if let te = error as? ThemeError, !te.message.isEmpty {
            return te.message
        }
        let localized = error.localizedDescription
        if !localized.isEmpty { return localized }
        let desc = String(describing: error)
        return desc.isEmpty ? "unknown error" : desc
    }

    public static func errorMessage(_ value: JSONValue) -> String {
        if case .object(let dict) = value {
            if let msg = dict["message"]?.stringValue, !msg.isEmpty { return msg }
            if case .object(let data) = dict["data"], let msg = data["message"]?.stringValue, !msg.isEmpty {
                return msg
            }
        }
        if case .string(let s) = value, !s.isEmpty { return s }
        let formatted = errorFormat(value)
        return formatted.isEmpty ? "unknown error" : formatted
    }

    // MARK: Filetype Mapping (`src/util/filetype.ts`)

    // parity: tui/src/util/filetype.ts#LANGUAGE_EXTENSIONS [status=implemented hash=433eba6a7a75]
    public static let LANGUAGE_EXTENSIONS: [String: String] = [
        ".abap": "abap", ".bat": "bat", ".bib": "bibtex", ".bibtex": "bibtex",
        ".clj": "clojure", ".cljs": "clojure", ".cljc": "clojure", ".edn": "clojure",
        ".coffee": "coffeescript", ".c": "c", ".cpp": "cpp", ".cxx": "cpp", ".cc": "cpp",
        ".c++": "cpp", ".cppm": "cpp", ".ccm": "cpp", ".cxxm": "cpp", ".c++m": "cpp",
        ".ixx": "cpp", ".cs": "csharp", ".csx": "csharp", ".css": "css", ".d": "d",
        ".pas": "pascal", ".pascal": "pascal", ".diff": "diff", ".patch": "diff",
        ".dart": "dart", ".dockerfile": "dockerfile", ".ex": "elixir", ".exs": "elixir",
        ".erl": "erlang", ".ets": "typescript", ".hrl": "erlang", ".fs": "fsharp",
        ".fsi": "fsharp", ".fsx": "fsharp", ".fsscript": "fsharp",
        ".gitcommit": "git-commit", ".gitrebase": "git-rebase", ".go": "go",
        ".groovy": "groovy", ".gleam": "gleam", ".hbs": "handlebars",
        ".handlebars": "handlebars", ".hs": "haskell", ".lhs": "haskell",
        ".html": "html", ".htm": "html", ".ini": "ini", ".java": "java", ".jl": "julia",
        ".js": "javascript", ".kt": "kotlin", ".kts": "kotlin", ".jsx": "javascriptreact",
        ".json": "json", ".tex": "latex", ".latex": "latex", ".less": "less", ".lua": "lua",
        ".makefile": "makefile", "makefile": "makefile", ".md": "markdown",
        ".markdown": "markdown", ".m": "objective-c", ".mm": "objective-cpp",
        ".pl": "perl", ".pm": "perl", ".pm6": "perl6", ".php": "php",
        ".ps1": "powershell", ".psm1": "powershell", ".pug": "jade", ".jade": "jade",
        ".py": "python", ".r": "r", ".cshtml": "razor", ".razor": "razor",
        ".rb": "ruby", ".rake": "ruby", ".gemspec": "ruby", ".ru": "ruby",
        ".erb": "erb", ".html.erb": "erb", ".js.erb": "erb", ".css.erb": "erb", ".json.erb": "erb",
        ".rs": "rust", ".scss": "scss", ".sass": "sass", ".scala": "scala",
        ".shader": "shaderlab", ".sh": "bash", ".bash": "bash", ".zsh": "bash", ".ksh": "bash",
        ".sql": "sql", ".svelte": "svelte", ".swift": "swift", ".ts": "typescript",
        ".tsx": "typescriptreact", ".mts": "typescript", ".cts": "typescript",
        ".mtsx": "typescriptreact", ".ctsx": "typescriptreact", ".xml": "xml",
        ".xsl": "xsl", ".yaml": "yaml", ".yml": "yaml", ".mjs": "javascript",
        ".cjs": "javascript", ".vue": "vue", ".zig": "zig", ".zon": "zig",
        ".astro": "astro", ".ml": "ocaml", ".mli": "ocaml", ".tf": "terraform",
        ".tfvars": "terraform-vars", ".hcl": "hcl", ".nix": "nix",
        ".typ": "typst", ".typc": "typst",
    ]

    // parity: tui/src/util/filetype.ts#filetype [status=implemented hash=4c6421d8ee2d]
    public static func filetype(_ input: String?) -> String? {
        guard let input, !input.isEmpty else { return "none" }
        let base = URL(fileURLWithPath: input).lastPathComponent
        let ext: String
        if let dot = base.lastIndex(of: "."), dot > base.startIndex {
            ext = String(base[dot...])
        } else {
            ext = ""
        }
        guard let language = LANGUAGE_EXTENSIONS[ext] else { return nil }
        if language == "typescriptreact" || language == "javascriptreact" || language == "javascript" {
            return "typescript"
        }
        return language
    }

    // MARK: Form Helpers (`src/util/form.ts`)

    public struct FormOption: Equatable, Hashable, Sendable, Codable {
        public let value: String
        public let label: String
        public let description: String?

        public init(value: String, label: String, description: String? = nil) {
            self.value = value
            self.label = label
            self.description = description
        }
    }

    public enum FormValue: Equatable, Hashable, Sendable, Codable {
        case string(String)
        case number(Double)
        case bool(Bool)
        case strings([String])
    }

    public enum FormField: Equatable, Hashable, Sendable {
        case string(
            key: String,
            title: String? = nil,
            required: Bool = false,
            defaultValue: FormValue? = nil,
            minLength: Int? = nil,
            maxLength: Int? = nil,
            pattern: String? = nil,
            format: String? = nil,
            options: [FormOption]? = nil,
            custom: Bool = false
        )
        case number(
            key: String,
            title: String? = nil,
            required: Bool = false,
            defaultValue: FormValue? = nil,
            minimum: Double? = nil,
            maximum: Double? = nil
        )
        case integer(
            key: String,
            title: String? = nil,
            required: Bool = false,
            defaultValue: FormValue? = nil,
            minimum: Double? = nil,
            maximum: Double? = nil
        )
        case boolean(
            key: String,
            title: String? = nil,
            required: Bool = false,
            defaultValue: FormValue? = nil
        )
        case multiselect(
            key: String,
            title: String? = nil,
            required: Bool = false,
            defaultValue: FormValue? = nil,
            options: [FormOption],
            minItems: Int? = nil,
            maxItems: Int? = nil,
            custom: Bool = false
        )
        case external(url: String, title: String? = nil)

        public var key: String? {
            switch self {
            case .string(let k, _, _, _, _, _, _, _, _, _),
                 .number(let k, _, _, _, _, _),
                 .integer(let k, _, _, _, _, _),
                 .boolean(let k, _, _, _),
                 .multiselect(let k, _, _, _, _, _, _, _):
                return k
            case .external:
                return nil
            }
        }

        public var title: String? {
            switch self {
            case .string(_, let t, _, _, _, _, _, _, _, _),
                 .number(_, let t, _, _, _, _),
                 .integer(_, let t, _, _, _, _),
                 .boolean(_, let t, _, _),
                 .multiselect(_, let t, _, _, _, _, _, _),
                 .external(_, let t):
                return t
            }
        }

        public var defaultValue: FormValue? {
            switch self {
            case .string(_, _, _, let d, _, _, _, _, _, _),
                 .number(_, _, _, let d, _, _),
                 .integer(_, _, _, let d, _, _),
                 .boolean(_, _, _, let d),
                 .multiselect(_, _, _, let d, _, _, _, _):
                return d
            case .external:
                return nil
            }
        }
    }

    // parity: tui/src/util/form.ts#FormAnswerField [status=implemented hash=d67349cdb8df]
    public typealias FormAnswerField = FormField

    public enum FormRowValue: Equatable, Hashable, Sendable {
        case string(String)
        case bool(Bool)
    }

    // parity: tui/src/util/form.ts#FormRow [status=implemented hash=b1296cb4ef17]
    public struct FormRow: Equatable, Hashable, Sendable {
        public let value: FormRowValue
        public let label: String
        public let description: String?

        public init(value: FormRowValue, label: String, description: String? = nil) {
            self.value = value
            self.label = label
            self.description = description
        }
    }

    // parity: tui/src/util/form.ts#isFormAnswerField [status=implemented hash=87e2ab5f8ead]
    public static func isFormAnswerField(_ field: FormField) -> Bool {
        if case .external = field { return false }
        return true
    }

    // parity: tui/src/util/form.ts#formLabel [status=implemented hash=f0f36c5d02ba]
    public static func formLabel(_ field: FormField) -> String {
        if let title = field.title { return title }
        if case .external(let url, _) = field { return url }
        return field.key ?? ""
    }

    // parity: tui/src/util/form.ts#formInitialValues [status=implemented hash=16d8789c7d3b]
    public static func formInitialValues(_ fields: [FormField]) -> (answers: [String: FormValue], custom: [String: String]) {
        var answers: [String: FormValue] = [:]
        var custom: [String: String] = [:]
        for field in fields {
            if isFormAnswerField(field), let key = field.key, let def = field.defaultValue {
                answers[key] = def
            }
            if case .string(let key, _, _, let def, _, _, _, _, let options?, let isCustom) = field,
               isCustom,
               case .string(let defStr) = def,
               !options.contains(where: { $0.value == defStr })
            {
                custom[key] = defStr
            }
        }
        return (answers, custom)
    }

    // parity: tui/src/util/form.ts#formTextual [status=implemented hash=5c2bc233a065]
    public static func formTextual(_ field: FormField?) -> Bool {
        guard let field else { return false }
        switch field {
        case .number, .integer: return true
        case .string(_, _, _, _, _, _, _, _, let options, _): return options == nil
        default: return false
        }
    }

    // parity: tui/src/util/form.ts#formCustom [status=implemented hash=6c6edd145aa5]
    public static func formCustom(_ field: FormField?) -> Bool {
        guard let field else { return false }
        switch field {
        case .string(_, _, _, _, _, _, _, _, let options, let custom): return options != nil && custom
        case .multiselect(_, _, _, _, _, _, _, let custom): return custom
        default: return false
        }
    }

    // parity: tui/src/util/form.ts#formRows [status=implemented hash=c24be40c9b19]
    public static func formRows(_ field: FormField?) -> [FormRow] {
        guard let field else { return [] }
        switch field {
        case .boolean:
            return [
                FormRow(value: .bool(true), label: "Yes"),
                FormRow(value: .bool(false), label: "No"),
            ]
        case .multiselect(_, _, _, _, let options, _, _, _):
            return options.map { FormRow(value: .string($0.value), label: $0.label, description: $0.description) }
        case .string(_, _, _, _, _, _, _, _, let options?, _):
            return options.map { FormRow(value: .string($0.value), label: $0.label, description: $0.description) }
        default:
            return []
        }
    }

    // parity: tui/src/util/form.ts#formSelected [status=implemented hash=37be96c2dbd0]
    public static func formSelected(_ field: FormField?, value: FormValue?) -> Int {
        guard let field, let value else { return 0 }
        if case .strings = value { return 0 }
        let rows = formRows(field)
        let rowVal: FormRowValue?
        switch value {
        case .string(let s): rowVal = .string(s)
        case .bool(let b): rowVal = .bool(b)
        default: rowVal = nil
        }
        if let rowVal, let idx = rows.firstIndex(where: { $0.value == rowVal }) {
            return idx
        }
        if case .string = value, formCustom(field) {
            return rows.count
        }
        return 0
    }

    // parity: tui/src/util/form.ts#formValidateValue [status=implemented hash=dfce773bac53]
    public static func formValidateValue(_ field: FormAnswerField, value: FormValue?) -> String? {
        switch field {
        case .external:
            return nil
        case .string(_, _, let required, _, let minLen, let maxLen, let pattern, let format, let options, let custom):
            guard let value else { return required ? "Answer required" : nil }
            guard case .string(let text) = value else { return "Expected text" }
            if required && text.isEmpty { return "Answer required" }
            if let minLen, text.utf16.count < minLen { return "Must be at least \(minLen) characters" }
            if let maxLen, text.utf16.count > maxLen { return "Must be at most \(maxLen) characters" }
            if let pattern {
                guard let regex = try? NSRegularExpression(pattern: pattern) else {
                    return "Invalid pattern: \(pattern)"
                }
                if regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) == nil {
                    return "Must match pattern: \(pattern)"
                }
            }
            if format == "email",
               let rx = try? NSRegularExpression(pattern: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#),
               rx.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) == nil
            {
                return "Expected an email address"
            }
            if format == "uri" && !isValidURI(text) { return "Expected a URL" }
            if format == "date" && !isValidISODate(text) { return "Expected a date (YYYY-MM-DD)" }
            if format == "date-time" && !isValidISODateTime(text) { return "Expected a date and time" }
            if let options, !custom, !options.contains(where: { $0.value == text }) {
                return "Select an available option"
            }
            return nil

        case .number(_, _, let required, _, let minimum, let maximum):
            guard let value else { return required ? "Answer required" : nil }
            guard case .number(let num) = value, num.isFinite else { return "Expected a number" }
            if let minimum, num < minimum { return "Must be at least \(formatMinMax(minimum))" }
            if let maximum, num > maximum { return "Must be at most \(formatMinMax(maximum))" }
            return nil

        case .integer(_, _, let required, _, let minimum, let maximum):
            guard let value else { return required ? "Answer required" : nil }
            guard case .number(let num) = value, num.isFinite else { return "Expected a number" }
            if num.rounded(.towardZero) != num { return "Expected an integer" }
            if let minimum, num < minimum { return "Must be at least \(formatMinMax(minimum))" }
            if let maximum, num > maximum { return "Must be at most \(formatMinMax(maximum))" }
            return nil

        case .boolean(_, _, let required, _):
            guard let value else { return required ? "Answer required" : nil }
            guard case .bool = value else { return "Expected yes or no" }
            return nil

        case .multiselect(_, _, let required, _, let options, let minItems, let maxItems, let custom):
            guard let value else { return required ? "Answer required" : nil }
            guard case .strings(let items) = value else { return "Expected selections" }
            if required && items.isEmpty { return "Select at least one option" }
            if let minItems, items.count < minItems { return "Select at least \(minItems)" }
            if let maxItems, items.count > maxItems { return "Select at most \(maxItems)" }
            if !custom, items.contains(where: { item in !options.contains(where: { $0.value == item }) }) {
                return "Select only available options"
            }
            return nil
        }
    }

    private static func formatMinMax(_ v: Double) -> String {
        v.rounded(.towardZero) == v ? String(Int64(v)) : String(v)
    }

    private static func isValidURI(_ value: String) -> Bool {
        guard let url = URL(string: value), let scheme = url.scheme, !scheme.isEmpty else { return false }
        return true
    }

    private static func isValidISODate(_ value: String) -> Bool {
        let parts = value.split(separator: "-")
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day)
        else { return false }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        guard let date = cal.date(from: comps) else { return false }
        let check = cal.dateComponents([.year, .month, .day], from: date)
        return check.year == year && check.month == month && check.day == day
    }

    private static func isValidISODateTime(_ value: String) -> Bool {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if iso.date(from: value) != nil { return true }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: value) != nil
    }

    // parity: tui/src/util/form.ts#formDisplayValue [status=implemented hash=b98cae5bfae8]
    public static func formDisplayValue(
        _ field: FormAnswerField,
        value: FormValue?,
        emptyMultiselect: String
    ) -> String {
        guard let value else { return "" }
        let rows = formRows(field)
        func labelFor(_ val: FormRowValue, fallback: String) -> String {
            rows.first(where: { $0.value == val })?.label ?? fallback
        }
        switch value {
        case .strings(let items):
            if items.isEmpty { return emptyMultiselect }
            return items.map { labelFor(.string($0), fallback: $0) }.joined(separator: ", ")
        case .string(let s):
            return labelFor(.string(s), fallback: s)
        case .bool(let b):
            return labelFor(.bool(b), fallback: b ? "true" : "false")
        case .number(let n):
            return formatMinMax(n)
        }
    }

    // parity: tui/src/util/form.ts#formToggleMultiselect [status=implemented hash=d904a5353410]
    public static func formToggleMultiselect(_ value: FormValue?, item: String) -> [String] {
        var values: [String]
        if case .strings(let existing) = value { values = existing } else { values = [] }
        if let idx = values.firstIndex(of: item) {
            values.remove(at: idx)
        } else {
            values.append(item)
        }
        return values
    }

    // parity: tui/src/util/form.ts#formSetMultiselectCustom [status=implemented hash=3ba2ee7db24b]
    public static func formSetMultiselectCustom(
        _ value: FormValue?,
        previous: String?,
        next: String
    ) -> [String] {
        var values: [String]
        if case .strings(let existing) = value { values = existing } else { values = [] }
        if let previous, !previous.isEmpty, let idx = values.firstIndex(of: previous) {
            values.remove(at: idx)
        }
        if !next.isEmpty && !values.contains(next) {
            values.append(next)
        }
        return values
    }

    // MARK: Highlights (`src/util/highlights.ts`)

    // parity: tui/src/util/highlights.ts#HighlightsInput [status=implemented hash=92c3d13745ce]
    public struct HighlightsInput: Equatable, Hashable, Sendable {
        public let version: String
        public let count: Int
        public let history: Bool

        public init(version: String, count: Int, history: Bool) {
            self.version = version
            self.count = count
            self.history = history
        }
    }

    public enum HighlightsDecision: String, Equatable, Hashable, Sendable {
        case show
        case record
        case none
    }

    // parity: tui/src/util/highlights.ts#decide [status=implemented hash=c668959ab1bb]
    public static func decide(_ input: HighlightsInput, seen: String? = nil) -> HighlightsDecision {
        guard let current = parseStableSemver(input.version) else { return .none }
        let seenParts = seen.flatMap(parseStableSemver)
        if seenParts == nil && !input.history { return .record }
        if let seenParts, !isNewerSemver(current, than: seenParts) { return .none }
        return input.count > 0 ? .show : .record
    }

    public final class HighlightsStore: Sendable {
        private let seenState: Mutex<String?>

        public init(seen: String? = nil) {
            self.seenState = Mutex(seen)
        }

        public var seen: String? { seenState.withLock { $0 } }

        public func update(_ body: (inout String?) -> Void) {
            seenState.withLock { body(&$0) }
        }
    }

    // parity: tui/src/util/highlights.ts#claim [status=adapted hash=0739d4679d3a]
    public static func claim(store: HighlightsStore, input: HighlightsInput) async -> Bool {
        if decide(input, seen: store.seen) == .none { return false }
        var action: HighlightsDecision = .none
        store.update { draft in
            action = decide(input, seen: draft)
            if action != .none {
                draft = input.version
            }
        }
        return action == .show
    }

    private static func parseStableSemver(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var nums: [Int] = []
        for p in parts {
            guard !p.isEmpty, p.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(p) else { return nil }
            nums.append(n)
        }
        return nums
    }

    private static func isNewerSemver(_ current: [Int], than seen: [Int]) -> Bool {
        for (a, b) in zip(current, seen) {
            if a != b { return a > b }
        }
        return false
    }

    // MARK: Marquee (`src/util/marquee.ts`)

    private static let marqueeGap = " · "

    // parity: tui/src/util/marquee.ts#MarqueeTextPart [status=implemented hash=143e2a21471c]
    public struct MarqueeTextPart: Equatable, Hashable, Sendable {
        public let value: String
        public let separator: Bool

        public init(value: String, separator: Bool) {
            self.value = value
            self.separator = separator
        }
    }

    // parity: tui/src/util/marquee.ts#marqueeCycleWidth [status=implemented hash=22b672ef69ba]
    public static func marqueeCycleWidth(_ value: String) -> Int {
        stringWidth(value + marqueeGap)
    }

    // parity: tui/src/util/marquee.ts#marqueeOverflows [status=implemented hash=8c77ee44a288]
    public static func marqueeOverflows(_ value: String, width: Int) -> Bool {
        stringWidth(value) > width
    }

    // parity: tui/src/util/marquee.ts#marqueeText [status=implemented hash=79a8f7e75cd8]
    public static func marqueeText(_ value: String, width: Int, offset: Int) -> String {
        marqueeTextParts(value, width: width, offset: offset).map(\.value).joined()
    }

    // parity: tui/src/util/marquee.ts#marqueeTextParts [status=implemented hash=81675f4e6736]
    public static func marqueeTextParts(_ value: String, width: Int, offset: Int) -> [MarqueeTextPart] {
        if width <= 0 { return [] }
        if stringWidth(value) <= width || offset <= 0 {
            return graphemes(takeWidth(value, width)).map { MarqueeTextPart(value: $0, separator: false) }
        }
        let loop = graphemes(value).map { MarqueeTextPart(value: $0, separator: false) }
            + graphemes(marqueeGap).map { MarqueeTextPart(value: $0, separator: $0 == "·") }
        let cycle = max(1, marqueeCycleWidth(value))
        let cursor = offset % cycle
        let parts = loop + loop
        var startIndex = 0
        var accWidth = 0
        for (idx, part) in parts.enumerated() {
            if accWidth >= cursor { break }
            startIndex = idx + 1
            accWidth += stringWidth(part.value)
        }
        var visible: [MarqueeTextPart] = []
        var usedWidth = 0
        for part in parts.dropFirst(startIndex) {
            let next = stringWidth(part.value)
            if usedWidth + next > width { break }
            visible.append(part)
            usedWidth += next
        }
        return visible
    }

    // MARK: Media Cache (`src/util/media.ts`)

    // parity: tui/src/util/media.ts#MediaCache [status=adapted hash=cdac34c9c1ac]
    public actor MediaCache {
        public typealias FetchHandler = @Sendable (String) async throws -> [UInt8]

        private let fetcher: FetchHandler
        private var bytes: [String: [UInt8]] = [:]
        private var inflight: [String: Task<[UInt8], any Error>] = [:]

        public init(fetcher: @escaping FetchHandler) {
            self.fetcher = fetcher
        }

        public func peek(_ uri: String) -> [UInt8]? {
            guard let hash = Self.mediaHash(from: uri) else { return nil }
            return bytes[hash]
        }

        public func read(_ uri: String) async throws -> [UInt8] {
            guard let hash = Self.mediaHash(from: uri) else {
                throw ThemeError("Not a media ref: \(uri)")
            }
            if let cached = bytes[hash] { return cached }
            if let existing = inflight[hash] { return try await existing.value }
            let fetch = fetcher
            let task = Task<[UInt8], any Error> { try await fetch(hash) }
            inflight[hash] = task
            do {
                let data = try await task.value
                bytes[hash] = data
                inflight.removeValue(forKey: hash)
                return data
            } catch {
                inflight.removeValue(forKey: hash)
                throw error
            }
        }

        public static func mediaHash(from uri: String) -> String? {
            guard uri.hasPrefix("media:") else { return nil }
            let hash = String(uri.dropFirst("media:".count))
            return hash.isEmpty ? nil : hash
        }
    }

    // parity: tui/src/util/media.ts#createMediaCache [status=adapted hash=dc600f038e2d]
    public static func createMediaCache(fetcher: @escaping MediaCache.FetchHandler) -> MediaCache {
        MediaCache(fetcher: fetcher)
    }

    public struct MissingMediaError: Error, Equatable, Sendable {
        public let name: String = "FileNotFoundError"
        public let message: String

        public init(_ message: String = "File not found") {
            self.message = message
        }
    }

    // parity: tui/src/util/media.ts#isMissingMedia [status=implemented hash=10873a9c00ea]
    public static func isMissingMedia(_ error: any Error) -> Bool {
        if error is MissingMediaError { return true }
        return String(describing: error).contains("FileNotFoundError")
    }

    // MARK: Model Reference Formatting (`src/util/model.ts`)

    public struct ModelRef: Equatable, Hashable, Sendable {
        public let providerID: String
        public let id: String
        public let variant: String?

        public init(providerID: String, id: String, variant: String? = nil) {
            self.providerID = providerID
            self.id = id
            self.variant = variant
        }
    }

    public struct NamedModelRef: Equatable, Hashable, Sendable {
        public let providerID: String
        public let id: String
        public let name: String

        public init(providerID: String, id: String, name: String) {
            self.providerID = providerID
            self.id = id
            self.name = name
        }
    }

    // parity: tui/src/util/model.ts#parse [status=implemented hash=ac3a115a8ff6]
    public static func parseModel(_ value: String) -> (providerID: String, modelID: String) {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let providerID = parts.first ?? ""
        let modelID = parts.dropFirst().joined(separator: "/")
        return (providerID, modelID)
    }

    // parity: tui/src/util/model.ts#formatRef [status=implemented hash=79f8fe4e3ec3]
    public static func formatRef(_ model: ModelRef) -> String {
        var parts = [model.providerID, model.id]
        if let variant = model.variant { parts.append(variant) }
        return parts.joined(separator: "/")
    }

    // parity: tui/src/util/model.ts#switchLabel [status=implemented hash=533a0bf097ea]
    public static func switchLabel(
        _ model: ModelRef,
        models: [NamedModelRef]? = nil,
        previous: ModelRef? = nil
    ) -> String {
        if previous?.providerID == model.providerID && previous?.id == model.id {
            return "Switched variant to \(model.variant ?? "default")"
        }
        guard let display = models?.first(where: { $0.providerID == model.providerID && $0.id == model.id })?.name else {
            return "Switched model to \(formatRef(model))"
        }
        let variant = (model.variant != nil && model.variant != "default") ? " (\(model.variant!))" : ""
        return "Switched model to \(display)\(variant)"
    }

    // MARK: Path Formatting & Normalization (`src/util/path-format.ts`, `src/util/path.ts`)

    private static func isWindowsPath(_ input: String) -> Bool {
        if input.hasPrefix("\\\\") { return true }
        let chars = Array(input)
        return chars.count >= 3 && chars[0].isASCII && chars[0].isLetter && chars[1] == ":" && (chars[2] == "\\" || chars[2] == "/")
    }

    private static func splitNormalizedSegments(_ path: String, windows: Bool) -> (root: String, segments: [String]) {
        let normalized = windows ? path.replacingOccurrences(of: "/", with: "\\") : path
        let sep: Character = windows ? "\\" : "/"
        var root = ""
        var rest = normalized
        if windows {
            let chars = Array(normalized)
            if chars.count >= 2 && chars[0].isASCII && chars[0].isLetter && chars[1] == ":" {
                root = String(chars[0..<2]).uppercased() + "\\"
                rest = String(normalized.dropFirst(chars.count >= 3 && chars[2] == "\\" ? 3 : 2))
            } else if normalized.hasPrefix("\\\\") {
                root = "\\\\"
                rest = String(normalized.dropFirst(2))
            }
        } else if normalized.hasPrefix("/") {
            root = "/"
            rest = String(normalized.dropFirst())
        }
        var stack: [String] = []
        for seg in rest.split(separator: sep, omittingEmptySubsequences: true) {
            if seg == "." { continue }
            if seg == ".." {
                if !stack.isEmpty && stack.last != ".." {
                    stack.removeLast()
                } else if root.isEmpty {
                    stack.append("..")
                }
            } else {
                stack.append(String(seg))
            }
        }
        return (root, stack)
    }

    private static func relativePath(from base: String, to target: String, windows: Bool) -> String {
        let sep = windows ? "\\" : "/"
        let b = splitNormalizedSegments(base, windows: windows)
        let t = splitNormalizedSegments(target, windows: windows)
        if b.root.lowercased() != t.root.lowercased() {
            return target
        }
        var common = 0
        while common < b.segments.count && common < t.segments.count {
            let eq = windows
                ? b.segments[common].lowercased() == t.segments[common].lowercased()
                : b.segments[common] == t.segments[common]
            if !eq { break }
            common += 1
        }
        let ups = Array(repeating: "..", count: b.segments.count - common)
        let downs = Array(t.segments[common...])
        return (ups + downs).joined(separator: sep)
    }

    // parity: tui/src/util/path-format.ts#abbreviateHome [status=implemented hash=95e11ad401bc]
    public static func abbreviateHome(_ input: String, home: String) -> String {
        guard !home.isEmpty else { return input }
        let windows = isWindowsPath(home)
        let sep = windows ? "\\" : "/"
        let rel = relativePath(from: home, to: input, windows: windows)
        if rel.isEmpty { return "~" }
        if rel == ".." || rel.hasPrefix("..\(sep)") || rel.hasPrefix("/") || isWindowsPath(rel) {
            return input
        }
        return "~/" + rel.split(separator: Character(sep), omittingEmptySubsequences: false).joined(separator: "/")
    }

    // parity: tui/src/util/path-format.ts#formatPath [status=implemented hash=1e3dec18a5b6]
    public static func formatPath(
        _ input: String?,
        base: String,
        home: String? = nil,
        forwardSlashes: Bool = false
    ) -> String {
        guard let input, !input.isEmpty else { return "" }
        let windows = isWindowsPath(base)
        if !windows && isWindowsPath(input) {
            return forwardSlashes ? input.replacingOccurrences(of: "\\", with: "/") : input
        }
        let sep = windows ? "\\" : "/"
        let isAbs = windows ? isWindowsPath(input) : input.hasPrefix("/")
        let absolute: String
        if isAbs {
            absolute = input
        } else {
            let joined = base.hasSuffix(sep) ? base + input : base + sep + input
            let norm = splitNormalizedSegments(joined, windows: windows)
            absolute = norm.root + norm.segments.joined(separator: sep)
        }
        let rel = relativePath(from: base, to: absolute, windows: windows)
        let formatted: String
        if rel.isEmpty {
            formatted = "."
        } else if rel != ".." && !rel.hasPrefix("..\(sep)") && !(windows ? isWindowsPath(rel) : rel.hasPrefix("/")) {
            formatted = rel
        } else if let home {
            formatted = abbreviateHome(absolute, home: home)
        } else {
            formatted = absolute
        }
        return forwardSlashes ? formatted.replacingOccurrences(of: "\\", with: "/") : formatted
    }

    // parity: tui/src/util/path.ts#normalizePath [status=implemented hash=52d2d34dc35c]
    public static func normalizePath(_ input: String, platform: String) -> String {
        if platform != "win32" { return input }
        let replaced = input.replacingOccurrences(of: "/", with: "\\")
        let norm = splitNormalizedSegments(replaced, windows: true)
        return norm.root + norm.segments.joined(separator: "\\")
    }

    // MARK: Tool Display Helpers (`src/util/tool-display.ts`)

    // parity: tui/src/util/tool-display.ts#canonicalToolName [status=implemented hash=6e38a406869b]
    public static func canonicalToolName(_ name: String) -> String {
        switch name {
        case "bash": return "shell"
        case "task": return "subagent"
        case "apply_patch": return "patch"
        default: return name
        }
    }

    // parity: tui/src/util/tool-display.ts#finiteNumber [status=implemented hash=5d20dd2513fd]
    public static func finiteNumber(_ value: JSONValue?) -> Double? {
        guard let value else { return nil }
        switch value {
        case .int(let i): return Double(i)
        case .double(let d) where d.isFinite: return d
        default: return nil
        }
    }

    // parity: tui/src/util/tool-display.ts#primitiveInputSummary [status=implemented hash=aaa16a71fb93]
    public static func primitiveInputSummary(_ input: [String: JSONValue], omit: [String] = []) -> String {
        let omitSet = Set(omit)
        let entries: [(String, String)] = input.keys.sorted().compactMap { key -> (String, String)? in
            guard !omitSet.contains(key), let value = input[key] else { return nil }
            switch value {
            case .string(let s): return (key, s)
            case .int(let i): return (key, String(i))
            case .double(let n): return (key, n.rounded(.towardZero) == n ? String(Int64(n)) : String(n))
            case .bool(let b): return (key, b ? "true" : "false")
            default: return nil
            }
        }
        if entries.isEmpty { return "" }
        return "[\(entries.map { "\($0.0)=\($0.1)" }.joined(separator: ", "))]"
    }

    public enum ExecuteCallStatus: String, Equatable, Hashable, Sendable, Codable {
        case running
        case completed
        case error
    }

    // parity: tui/src/util/tool-display.ts#ExecuteCall [status=implemented hash=bb4b56425686]
    public struct ExecuteCall: Equatable, Hashable, Sendable {
        public let tool: String
        public let status: ExecuteCallStatus
        public let input: [String: JSONValue]?

        public init(tool: String, status: ExecuteCallStatus, input: [String: JSONValue]? = nil) {
            self.tool = tool
            self.status = status
            self.input = input
        }
    }

    // parity: tui/src/util/tool-display.ts#executeCalls [status=implemented hash=d50bbc37f84e]
    public static func executeCalls(_ value: JSONValue?) -> [ExecuteCall] {
        guard case .array(let items) = value else { return [] }
        return items.compactMap { item in
            guard case .object(let obj) = item,
                  let tool = obj["tool"]?.stringValue,
                  let statusRaw = obj["status"]?.stringValue,
                  let status = ExecuteCallStatus(rawValue: statusRaw)
            else { return nil }
            let input: [String: JSONValue]?
            if case .object(let dict) = obj["input"] { input = dict } else { input = nil }
            return ExecuteCall(tool: tool, status: status, input: input)
        }
    }

    // parity: tui/src/util/tool-display.ts#executeCallSummary [status=implemented hash=253bb5c25cca]
    public static func executeCallSummary(_ call: ExecuteCall) -> String {
        let rawArgs = primitiveInputSummary(call.input ?? [:])
        let args = rawArgs.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return args.isEmpty ? call.tool : "\(call.tool) \(args)"
    }

    // parity: tui/src/util/tool-display.ts#webSearchProviderName [status=implemented hash=216741fbd9fe]
    public static func webSearchProviderName(_ provider: String?) -> String {
        guard let provider, !provider.isEmpty else { return "" }
        if provider == "opencode" { return "OpenCode" }
        return provider.prefix(1).uppercased() + provider.dropFirst()
    }

    // parity: tui/src/util/tool-display.ts#webSearchProviderLabel [status=implemented hash=a743ac651a2b]
    public static func webSearchProviderLabel(_ provider: String?) -> String {
        let name = webSearchProviderName(provider)
        return name.isEmpty ? "Web Search" : "Web Search via \(name)"
    }

    // parity: tui/src/util/tool-display.ts#toolDisplayMetadata [status=implemented hash=84605f1596d9]
    public static func toolDisplayMetadata(_ state: JSONValue?) -> [String: JSONValue] {
        guard case .object(let obj) = state,
              let status = obj["status"]?.stringValue,
              status != "streaming",
              case .object(let metadata) = obj["metadata"]
        else { return [:] }
        return metadata
    }

    // parity: tui/src/util/tool-display.ts#toolDisplayContent [status=implemented hash=d34ff3bf20eb]
    public static func toolDisplayContent(_ state: JSONValue?) -> [JSONValue] {
        guard case .object(let obj) = state,
              let status = obj["status"]?.stringValue,
              status != "streaming",
              status != "running",
              case .array(let content) = obj["content"]
        else { return [] }
        return content
    }

    // parity: tui/src/util/tool-display.ts#nonEmptyToolContent [status=implemented hash=00b3e3071d66]
    public static func nonEmptyToolContent<T>(_ content: [T]?) -> [T]? {
        guard let content, !content.isEmpty else { return nil }
        return content
    }

    // MARK: Permission Presentation (`src/util/permission.ts`)

    // parity: tui/src/util/permission.ts#PermissionPresentation [status=implemented hash=b3f3e6b337c6]
    public struct PermissionPresentation: Equatable, Hashable, Sendable {
        public let icon: String
        public let title: String
        public let lines: [String]
        public let diff: String?
        public let patch: String?
        public let file: String?

        public init(
            icon: String,
            title: String,
            lines: [String],
            diff: String? = nil,
            patch: String? = nil,
            file: String? = nil
        ) {
            self.icon = icon
            self.title = title
            self.lines = lines
            self.diff = diff
            self.patch = patch
            self.file = file
        }
    }

    // parity: tui/src/util/permission.ts#PermissionPresentationInput [status=implemented hash=8dbcc62bcd47]
    public struct PermissionPresentationInput: Equatable, Sendable {
        public let action: String
        public let resources: [String]
        public let metadata: [String: JSONValue]
        public let input: [String: JSONValue]
        public let toolMetadata: [String: JSONValue]

        public init(
            action: String,
            resources: [String] = [],
            metadata: [String: JSONValue] = [:],
            input: [String: JSONValue] = [:],
            toolMetadata: [String: JSONValue] = [:]
        ) {
            self.action = action
            self.resources = resources
            self.metadata = metadata
            self.input = input
            self.toolMetadata = toolMetadata
        }
    }

    // parity: tui/src/util/permission.ts#permissionPresentation [status=implemented hash=b275e4c723fd]
    public static func permissionPresentation(
        _ source: PermissionPresentationInput,
        formatPath fmt: (String) -> String = { $0 }
    ) -> PermissionPresentation {
        let action = canonicalToolName(source.action)
        var input = source.input
        let normPath = input["path"]?.stringValue ?? input["filePath"]?.stringValue ?? input["filepath"]?.stringValue ?? ""
        if ["read", "edit", "list", "lsp"].contains(action) && !normPath.isEmpty {
            input["path"] = .string(normPath)
        }
        let normAgent = input["agent"]?.stringValue ?? input["subagent_type"]?.stringValue ?? ""
        if action == "subagent" && !normAgent.isEmpty {
            input["agent"] = .string(normAgent)
        }
        var metadata = source.toolMetadata
        for (k, v) in source.metadata { metadata[k] = v }

        switch action {
        case "edit":
            let file = input["path"]?.stringValue ?? source.resources.first ?? ""
            var diff: String? = nil
            if case .array(let files) = metadata["files"], case .object(let first) = files.first {
                diff = first["patch"]?.stringValue ?? first["diff"]?.stringValue
            }
            if diff == nil { diff = metadata["diff"]?.stringValue }
            let patch = diff == nil ? input["patchText"]?.stringValue : nil
            return PermissionPresentation(icon: "→", title: "Edit \(fmt(file))", lines: [], diff: diff, patch: patch, file: file)
        case "read", "list":
            let value = input["path"]?.stringValue ?? source.resources.first ?? ""
            let label = action == "read" ? "Read" : "List"
            return PermissionPresentation(icon: "→", title: "\(label) \(fmt(value))", lines: value.isEmpty ? [] : ["Path: \(fmt(value))"])
        case "glob", "grep":
            let pattern = input["pattern"]?.stringValue ?? source.resources.first ?? ""
            let label = action == "glob" ? "Glob" : "Grep"
            return PermissionPresentation(icon: "✱", title: "\(label) \"\(pattern)\"", lines: pattern.isEmpty ? [] : ["Pattern: \(pattern)"])
        case "shell":
            let cmd = input["command"]?.stringValue ?? ""
            return PermissionPresentation(icon: "#", title: "Shell command", lines: cmd.isEmpty ? source.resources.map { "- \($0)" } : ["$ \(cmd)"])
        case "subagent":
            let agent = input["agent"]?.stringValue ?? "general"
            let desc = input["description"]?.stringValue ?? ""
            return PermissionPresentation(icon: "#", title: "\(titlecase(agent)) Subagent", lines: desc.isEmpty ? [] : ["◉ \(desc)"])
        case "webfetch":
            let url = input["url"]?.stringValue ?? metadata["url"]?.stringValue ?? ""
            return PermissionPresentation(icon: "%", title: "WebFetch \(url)", lines: url.isEmpty ? [] : ["URL: \(url)"])
        case "websearch":
            let query = input["query"]?.stringValue ?? metadata["query"]?.stringValue ?? ""
            let label = webSearchProviderLabel(metadata["provider"]?.stringValue)
            return PermissionPresentation(icon: "◈", title: query.isEmpty ? label : "\(label) \"\(query)\"", lines: query.isEmpty ? [] : ["Query: \(query)"])
        case "lsp":
            let file = input["path"]?.stringValue ?? ""
            let op = input["operation"]?.stringValue ?? "request"
            let line = finiteNumber(input["line"]).map { Int($0) }
            let char = finiteNumber(input["character"]).map { Int($0) }
            let pos = (line != nil && char != nil) ? "\(line!):\(char!)" : nil
            var lines: [String] = []
            if input["operation"] != nil { lines.append("Operation: \(op)") }
            if !file.isEmpty { lines.append("Path: \(fmt(file))") }
            if let pos { lines.append("Position: \(pos)") }
            let suffix = file.isEmpty ? "" : " \(fmt(file))\(pos.map { ":\($0)" } ?? "")"
            return PermissionPresentation(icon: "→", title: "LSP \(op)\(suffix)", lines: lines)
        case "external_directory":
            let raw = metadata["parentDir"]?.stringValue ?? metadata["filepath"]?.stringValue ?? source.resources.first ?? ""
            let dir = wildcardDirectory(raw)
            return PermissionPresentation(icon: "←", title: "Access external directory \(fmt(dir))", lines: source.resources.map { "- \($0)" })
        case "doom_loop":
            return PermissionPresentation(icon: "⟳", title: "Continue after repeated failures", lines: ["This keeps the session running despite repeated failures."])
        default:
            return PermissionPresentation(icon: "⚙", title: "Call tool \(source.action)", lines: ["Tool: \(source.action)"])
        }
    }

    private static func wildcardDirectory(_ value: String) -> String {
        guard let star = value.firstIndex(of: "*") else { return value }
        var prefix = String(value[..<star])
        if prefix == "/" || prefix == "\\" || (prefix.count == 3 && isWindowsPath(prefix)) { return prefix }
        while prefix.hasSuffix("/") || prefix.hasSuffix("\\") { prefix.removeLast() }
        return prefix
    }

    // parity: tui/src/util/permission.ts#permissionAlwaysLines [status=implemented hash=699d6fca70ac]
    public static func permissionAlwaysLines(action: String, save: [String] = []) -> [String] {
        if save.count == 1 && save[0] == "*" {
            return ["This will always allow \(action) for this project."]
        }
        return ["This will always allow the following patterns for this project."] + save.map { "- \($0)" }
    }

    public enum PermissionOption: String, Equatable, Hashable, Sendable {
        case once
        case always
        case reject
        case confirm
        case cancel
    }

    // parity: tui/src/util/permission.ts#permissionOptionLabel [status=implemented hash=d9868c546582]
    public static func permissionOptionLabel(_ option: PermissionOption) -> String {
        switch option {
        case .once: return "Allow once"
        case .always: return "Always allow"
        case .reject: return "Reject"
        case .confirm: return "Confirm"
        case .cancel: return "Cancel"
        }
    }

    // MARK: Persistence (`src/util/persistence.ts`)

    // parity: tui/src/util/persistence.ts#readText [status=implemented hash=93b89c31fc5a]
    public static func readText(_ filePath: String) async throws -> String {
        try String(contentsOfFile: filePath, encoding: .utf8)
    }

    // parity: tui/src/util/persistence.ts#readJson [status=implemented hash=8f8349f2f679]
    public static func readJson<T: Decodable>(_ filePath: String, as type: T.Type = T.self) async throws -> T {
        let data = try Data(contentsOf: URL(fileURLWithPath: filePath))
        return try JSONDecoder().decode(T.self, from: data)
    }

    // parity: tui/src/util/persistence.ts#writeText [status=implemented hash=1457589630b7]
    public static func writeText(_ filePath: String, content: String) async throws {
        let url = URL(fileURLWithPath: filePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
    }

    // parity: tui/src/util/persistence.ts#appendText [status=implemented hash=a8e0977de356]
    public static func appendText(_ filePath: String, content: String) async throws {
        let url = URL(fileURLWithPath: filePath)
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: filePath) {
            try Data(content.utf8).write(to: url)
            return
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(content.utf8))
    }

    // parity: tui/src/util/persistence.ts#writeJsonAtomic [status=implemented hash=894ac209279e]
    public static func writeJsonAtomic<T: Encodable>(_ filePath: String, value: T) async throws {
        let url = URL(fileURLWithPath: filePath)
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(value)
        let tempPath = "\(filePath).\(ProcessInfo.processInfo.processIdentifier).\(UUID().uuidString).tmp"
        let tempURL = URL(fileURLWithPath: tempPath)
        do {
            try data.write(to: tempURL, options: .atomic)
        } catch {
            try? fm.removeItem(at: tempURL)
            throw error
        }
        do {
            try await replaceFile(fm, source: tempURL, target: url, sourcePath: tempPath, targetPath: filePath)
        } catch {
            try? fm.removeItem(at: tempURL)
            throw error
        }
    }

    /// Windows refuses to rename onto a file that is open, as it briefly is while another TUI reloads it, so a
    /// permission or busy failure retries up to 20 times, 10 ms apart.
    private static func replaceFile(
        _ fm: FileManager,
        source: URL,
        target: URL,
        sourcePath: String,
        targetPath: String
    ) async throws {
        var attempt = 0
        while true {
            do {
                #if os(Windows)
                _ = (fm, source, target)
                let srcWide = Array(sourcePath.utf16) + [0]
                let dstWide = Array(targetPath.utf16) + [0]
                let ok = srcWide.withUnsafeBufferPointer { sPtr in
                    dstWide.withUnsafeBufferPointer { dPtr in
                        MoveFileExW(
                            sPtr.baseAddress,
                            dPtr.baseAddress,
                            DWORD(MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)
                        )
                    }
                }
                if !ok {
                    let err = GetLastError()
                    if err == DWORD(ERROR_ACCESS_DENIED)
                        || err == DWORD(ERROR_SHARING_VIOLATION)
                        || err == DWORD(ERROR_LOCK_VIOLATION)
                    {
                        throw NSError(domain: NSPOSIXErrorDomain, code: 16, userInfo: nil)
                    }
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(err), userInfo: nil)
                }
                #else
                _ = (sourcePath, targetPath)
                if fm.fileExists(atPath: target.path) {
                    _ = try fm.replaceItemAt(target, withItemAt: source)
                } else {
                    try fm.moveItem(at: source, to: target)
                }
                #endif
                return
            } catch {
                guard attempt < 20, isTransientReplaceError(error) else { throw error }
                attempt += 1
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
    }

    /// `EPERM`, `EACCES` or `EBUSY`, also when wrapped as the underlying error of a Cocoa file error.
    private static func isTransientReplaceError(_ error: any Error) -> Bool {
        let ns = error as NSError
        // POSIX EPERM (1), EACCES (13), EBUSY (16).
        if ns.domain == NSPOSIXErrorDomain, [1, 13, 16].contains(ns.code) { return true }
        if ns.domain == NSCocoaErrorDomain, ns.code == CocoaError.fileWriteNoPermission.rawValue { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError { return isTransientReplaceError(underlying) }
        return false
    }

    // MARK: Presentation Epilogue (`src/util/presentation.ts`)

    internal static let logoLeft = [
        "                   ",
        "█▀▀█ █▀▀█ █▀▀█ █▀▀▄",
        "█__█ █__█ █^^^ █__█",
        "▀▀▀▀ █▀▀▀ ▀▀▀▀ ▀~~▀",
    ]
    internal static let logoRight = [
        "             ▄     ",
        "█▀▀▀ █▀▀█ █▀▀█ █▀▀█",
        "█___ █__█ █__█ █^^^",
        "▀▀▀▀ ▀▀▀▀ ▀▀▀▀ ▀▀▀▀",
    ]

    // parity: tui/src/util/presentation.ts#SessionEpilogue [status=implemented hash=4309e1404ded]
    public struct SessionEpilogue: Equatable, Hashable, Sendable {
        public let title: String
        public let sessionID: String?

        public init(title: String, sessionID: String? = nil) {
            self.title = title
            self.sessionID = sessionID
        }
    }

    // parity: tui/src/util/presentation.ts#epilogue [status=implemented hash=295f98f572be]
    public static func epilogue(session: SessionEpilogue? = nil, updatedVersion: String? = nil) -> String? {
        if session == nil && updatedVersion == nil { return nil }
        let reset = "\u{1B}[0m"
        let bold = "\u{1B}[1m"
        let dim = "\u{1B}[90m"
        func draw(_ line: String, fg: String, shadow: String, bg: String) -> String {
            line.map { ch -> String in
                switch ch {
                case "_": return "\(bg) \(reset)"
                case "^": return "\(fg)\(bg)▀\(reset)"
                case "~": return "\(shadow)▀\(reset)"
                case " ": return " "
                default: return "\(fg)\(ch)\(reset)"
                }
            }.joined()
        }
        var lines: [String] = logoLeft.enumerated().map { idx, leftLine in
            let l = draw(leftLine, fg: dim, shadow: "\u{1B}[38;5;235m", bg: "\u{1B}[48;5;235m")
            let r = draw(idx < logoRight.count ? logoRight[idx] : "", fg: reset, shadow: "\u{1B}[38;5;238m", bg: "\u{1B}[48;5;238m")
            return "  \(l) \(r)"
        }
        lines.append("")
        if let updatedVersion {
            lines.append("  \(dim)Run \(reset)\(bold)opencode\(reset)\(dim) to use \(reset)\(bold)\(updatedVersion)\(reset)")
            lines.append("")
        }
        if let session {
            func row(_ label: String, _ value: String) -> String {
                let padded = label + String(repeating: " ", count: max(0, 10 - label.count))
                return "  \(dim)\(padded)\(reset)\(bold)\(value)\(reset)"
            }
            lines.append(row("Session", session.title))
            lines.append(row("Continue", "opencode -s \(session.sessionID ?? "")"))
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Project Name (`src/util/project.ts`)

    // parity: tui/src/util/project.ts#projectName [status=implemented hash=6c1fb5f736db]
    public static func projectName(canonical: String? = nil, name: String? = nil, fallback: String = "") -> String? {
        let resolved = canonical ?? fallback
        if resolved == "/" {
            return fallback.isEmpty ? nil : URL(fileURLWithPath: fallback).lastPathComponent
        }
        if let name, !name.isEmpty { return name }
        return resolved.isEmpty ? "" : URL(fileURLWithPath: resolved).lastPathComponent
    }

    // MARK: Renderer Helpers (`src/util/renderer.ts`)

    // parity: tui/src/util/renderer.ts#setTerminalTitle [status=implemented hash=57330791cef6]
    public static func setTerminalTitle(_ renderer: CliRenderer, title: String) {
        if renderer.isDestroyed || renderer.controlState == .explicitSuspended { return }
        let sanitized = title.unicodeScalars.map { scalar -> String in
            let v = scalar.value
            if v <= 0x1F || (v >= 0x7F && v <= 0x9F) { return " " }
            return String(scalar)
        }.joined()
        renderer.setTerminalTitle(sanitized)
    }

    // parity: tui/src/util/renderer.ts#destroyRenderer [status=implemented hash=0ab2a7504287]
    public static func destroyRenderer(_ renderer: CliRenderer) {
        if renderer.isDestroyed { return }
        setTerminalTitle(renderer, title: "")
        renderer.destroy()
    }

    // MARK: Scroll Acceleration (`src/util/scroll.ts`)

    // parity: tui/src/util/scroll.ts#ScrollConfig [status=implemented hash=51509381671f]
    public struct ScrollConfig: Equatable, Hashable, Sendable, Codable {
        public var acceleration: Bool?
        public var speed: Double?

        public init(acceleration: Bool? = nil, speed: Double? = nil) {
            self.acceleration = acceleration
            self.speed = speed
        }
    }

    // parity: tui/src/util/scroll.ts#CustomSpeedScroll [status=implemented hash=ec8f08925f13]
    public struct CustomSpeedScroll: ScrollAcceleration, Equatable, Hashable, Sendable {
        public let speed: Double

        public init(speed: Double) {
            self.speed = speed
        }

        // parity: tui/src/util/scroll.ts#CustomSpeedScroll.tick [status=implemented hash=807a8ca03294]
        public mutating func tick(now: Double = 0) -> Double {
            speed
        }

        // parity: tui/src/util/scroll.ts#CustomSpeedScroll.reset [status=implemented hash=970cb8d0b1d5]
        public mutating func reset() {}
    }

    // parity: tui/src/util/scroll.ts#getScrollAcceleration [status=implemented hash=995cb143be22]
    public static func getScrollAcceleration(_ config: ScrollConfig? = nil) -> any ScrollAcceleration {
        if config?.acceleration == true {
            return MacOSScrollAccel()
        }
        if let speed = config?.speed {
            return CustomSpeedScroll(speed: speed)
        }
        return CustomSpeedScroll(speed: 3)
    }

    // MARK: Selection Copy & Key Handling (`src/util/selection.ts`)

    // parity: tui/src/util/selection.ts#copyOnSelectRelease [status=adapted hash=ff45ab319be2]
    public static func copyOnSelectRelease(
        isDragging: Bool,
        renderer: CliRenderer,
        toast: TUIPrimitive.ToastContext,
        writeClipboard: @escaping @Sendable (String) -> Void
    ) -> Bool {
        guard isDragging else { return false }
        return copy(renderer: renderer, toast: toast, writeClipboard: writeClipboard)
    }

    // parity: tui/src/util/selection.ts#copy [status=adapted hash=0aa6e1fc6922]
    public static func copy(
        renderer: CliRenderer,
        toast: TUIPrimitive.ToastContext,
        writeClipboard: @escaping @Sendable (String) -> Void
    ) -> Bool {
        guard let selection = renderer.getSelection() else { return false }
        if selection.isStart && selection.behavior == .cell { return false }
        let text = selection.getSelectedText()
        guard !text.isEmpty else { return false }
        writeClipboard(text)
        toast.show(TUIPrimitive.ToastOptions(message: "Copied to clipboard", variant: .info))
        return true
    }

    // parity: tui/src/util/selection.ts#handleSelectionKey [status=adapted hash=86ce2d3750e9]
    public static func handleSelectionKey(
        renderer: CliRenderer,
        toast: TUIPrimitive.ToastContext,
        event: KeyEvent,
        copyOnSelect: Bool,
        isFocusedEditorSelecting: Bool = false,
        writeClipboard: @escaping @Sendable (String) -> Void
    ) {
        guard let selection = renderer.getSelection() else { return }
        if event.ctrl && (event.name == "c" || event.baseCode == 99 || event.baseCode == 67) {
            if (copyOnSelect && !isFocusedEditorSelecting) || !copy(renderer: renderer, toast: toast, writeClipboard: writeClipboard) {
                renderer.clearSelection()
                return
            }
            event.preventDefault()
            event.stopPropagation()
            return
        }
        if event.name == "escape" {
            let text = (selection.isStart && selection.behavior == .cell) ? "" : selection.getSelectedText()
            renderer.clearSelection()
            if text.isEmpty { return }
            event.preventDefault()
            event.stopPropagation()
            return
        }
        if isFocusedEditorSelecting { return }
        renderer.clearSelection()
    }

    // MARK: Session Family & Context Usage (`src/util/session.ts`)

    public struct SessionTreeNode: Equatable, Hashable, Sendable {
        public let id: String
        public let parentID: String?
        public let title: String?

        public init(id: String, parentID: String? = nil, title: String? = nil) {
            self.id = id
            self.parentID = parentID
            self.title = title
        }
    }

    public struct SessionFamilyEntry: Equatable, Hashable, Sendable {
        public let session: SessionTreeNode
        public let prefix: String

        public init(session: SessionTreeNode, prefix: String) {
            self.session = session
            self.prefix = prefix
        }
    }

    // parity: tui/src/util/session.ts#sessionFamily [status=implemented hash=3f459a081cb1]
    public static func sessionFamily(sessions: [SessionTreeNode], sessionID: String) -> [SessionFamilyEntry] {
        let byID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        guard let current = byID[sessionID] else { return [] }
        var children: [String: [SessionTreeNode]] = [:]
        for s in sessions {
            if let pid = s.parentID, !pid.isEmpty {
                children[pid, default: []].append(s)
            }
        }
        var root = current
        var visited = Set<String>([root.id])
        while let pid = root.parentID, let parent = byID[pid], visited.insert(parent.id).inserted {
            root = parent
        }
        func walk(_ parentID: String, ancestors: [Bool]) -> [SessionFamilyEntry] {
            let group = children[parentID] ?? []
            var out: [SessionFamilyEntry] = []
            for (index, item) in group.enumerated() {
                let last = index == group.count - 1
                let prefix: String
                if ancestors.isEmpty {
                    prefix = ""
                } else {
                    prefix = ancestors.dropFirst().map { $0 ? "   " : "│  " }.joined() + (last ? "└─ " : "├─ ")
                }
                out.append(SessionFamilyEntry(session: item, prefix: prefix))
                out.append(contentsOf: walk(item.id, ancestors: ancestors + [last]))
            }
            return out
        }
        return walk(root.id, ancestors: [])
    }

    public struct ContextUsageSummary: Equatable, Hashable, Sendable {
        public let tokens: Int
        public let percent: Int?

        public init(tokens: Int, percent: Int? = nil) {
            self.tokens = tokens
            self.percent = percent
        }
    }

    public struct AssistantUsageMessage: Equatable, Hashable, Sendable {
        public let id: String
        public let providerID: String
        public let modelID: String
        public let inputTokens: Int
        public let outputTokens: Int
        public let reasoningTokens: Int
        public let cacheReadTokens: Int
        public let cacheWriteTokens: Int

        public init(
            id: String,
            providerID: String,
            modelID: String,
            inputTokens: Int,
            outputTokens: Int,
            reasoningTokens: Int = 0,
            cacheReadTokens: Int = 0,
            cacheWriteTokens: Int = 0
        ) {
            self.id = id
            self.providerID = providerID
            self.modelID = modelID
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.reasoningTokens = reasoningTokens
            self.cacheReadTokens = cacheReadTokens
            self.cacheWriteTokens = cacheWriteTokens
        }

        public var totalTokens: Int {
            inputTokens + outputTokens + reasoningTokens + cacheReadTokens + cacheWriteTokens
        }
    }

    // parity: tui/src/util/session.ts#contextUsage [status=implemented hash=db1ba8c73280]
    public static func contextUsage(
        messages: [AssistantUsageMessage],
        modelContextLimits: [String: Int],
        boundary: String? = nil
    ) -> ContextUsageSummary? {
        let slice: ArraySlice<AssistantUsageMessage>
        if let boundary, let idx = messages.firstIndex(where: { $0.id == boundary }) {
            slice = messages[..<idx]
        } else {
            slice = messages[...]
        }
        guard let last = slice.last(where: { $0.totalTokens > 0 }) else { return nil }
        let key = "\(last.providerID)/\(last.modelID)"
        let limit = modelContextLimits[key]
        let percent = limit.flatMap { $0 > 0 ? Int((Double(last.totalTokens) / Double($0) * 100.0).rounded()) : nil }
        return ContextUsageSummary(tokens: last.totalTokens, percent: percent)
    }

    // parity: tui/src/util/session.ts#formatContextUsage [status=implemented hash=a8b634949111]
    public static func formatContextUsage(tokens: Int, percent: Int? = nil) -> String {
        let value = number(tokens)
        guard let percent else { return value }
        return "\(value) (\(percent)%)"
    }

    /// The fields every job kind carries, read straight from the tagged union.
    public struct JobFields: Equatable, Hashable, Sendable {
        public let id: String
        public let sessionID: String
        public let kind: JobSchema.Kind
        public let title: String?
        public let started: Double
        /// The child session a subagent job runs in; `nil` for every other kind.
        public let childSessionID: String?

        public init(_ job: JobSchema.Info) {
            switch job {
            case .shell(let v):
                (id, sessionID, kind, title, started, childSessionID) = (v.id, v.sessionID.rawValue, .shell, v.title, v.time.started, nil)
            case .subagent(let v):
                (id, sessionID, kind, title, started, childSessionID) =
                    (v.id, v.sessionID.rawValue, .subagent, v.title, v.time.started, v.childSessionID.rawValue)
            case .image(let v):
                (id, sessionID, kind, title, started, childSessionID) = (v.id, v.sessionID.rawValue, .image, v.title, v.time.started, nil)
            case .codemode(let v):
                (id, sessionID, kind, title, started, childSessionID) =
                    (v.id, v.sessionID.rawValue, .codemode, v.title, v.time.started, nil)
            case .video(let v):
                (id, sessionID, kind, title, started, childSessionID) = (v.id, v.sessionID.rawValue, .video, v.title, v.time.started, nil)
            }
        }
    }

    /// Running jobs in a session's tree. A subagent job belongs to the child it runs.
    // parity: tui/src/util/session.ts#ownedJobs [status=implemented hash=fb080adc82a9]
    public static func ownedJobs(
        _ jobs: [JobSchema.Info],
        sessionID: String,
        parentID: (String) -> String?
    ) -> [JobSchema.Info] {
        jobs.filter { job in
            let fields = JobFields(job)
            var seen = Set<String>()
            var current: String? = fields.kind == .subagent ? fields.childSessionID : fields.sessionID
            while let id = current, !id.isEmpty, !seen.contains(id) {
                if id == sessionID { return true }
                seen.insert(id)
                // A subagent job runs in the direct child of the session that started it.
                current = parentID(id)
                    ?? (fields.kind == .subagent && id == fields.childSessionID ? fields.sessionID : nil)
            }
            return false
        }
    }

    /// A script moved to the background ends its execute call with the job's id; its first line of code names it.
    // parity: tui/src/util/session.ts#scriptLabel [status=implemented hash=28512fd0686a]
    public static func scriptLabel(_ messages: [SessionMessageSchema.Info], job: JobSchema.Info) -> String {
        let fields = JobFields(job)
        let code = messages
            .flatMap { message -> [SessionMessageSchema.AssistantContent] in
                if case .assistant(let assistant) = message { return assistant.content }
                return []
            }
            .compactMap { part -> String? in
                guard case .tool(let tool) = part, tool.name == "execute",
                      case .completed(let state) = tool.state,
                      case .string(let jobID)? = state.metadata?["jobID"], jobID == fields.id,
                      case .string(let code)? = state.input["code"]
                else { return nil }
                return code
            }
            .last
        let line = code?
            // Split on LF scalars like JavaScript, so a CRLF line keeps its CR for trim() to drop.
            .unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String(String.UnicodeScalarView($0)).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return line ?? fields.title ?? "Script"
    }

    // MARK: Debounced Signal & FadeIn (`src/util/signal.ts`)

    public final class DebouncedValue<Value: Sendable>: Sendable {
        private struct State: Sendable {
            var current: Value
            var pending: Value?
            var dueAtMs: Double?
        }

        private let delayMs: Double
        private let state: Mutex<State>

        public init(initial: Value, ms: Double) {
            self.delayMs = ms
            self.state = Mutex(State(current: initial, pending: nil, dueAtMs: nil))
        }

        public var value: Value { state.withLock { $0.current } }

        public func set(_ next: Value, at nowMs: Double) {
            state.withLock { s in
                if delayMs <= 0 {
                    s.current = next
                    s.pending = nil
                    s.dueAtMs = nil
                } else {
                    s.pending = next
                    s.dueAtMs = nowMs + delayMs
                }
            }
        }

        public func tick(at nowMs: Double) {
            state.withLock { s in
                if let due = s.dueAtMs, nowMs >= due, let pending = s.pending {
                    s.current = pending
                    s.pending = nil
                    s.dueAtMs = nil
                }
            }
        }
    }

    // parity: tui/src/util/signal.ts#createDebouncedSignal [status=adapted hash=a175a2ee979f]
    public static func createDebouncedSignal<Value: Sendable>(_ initial: Value, ms: Double) -> DebouncedValue<Value> {
        DebouncedValue(initial: initial, ms: ms)
    }

    public final class FadeInController: Sendable {
        private let animatable: TUIPrimitive.AnimatableHandle
        private let revealed: Mutex<Bool>

        public init(show: Bool, enabled: @escaping @Sendable () -> Bool) {
            self.animatable = TUIPrimitive.createAnimatable(
                ["value": .scalar(show ? 1.0 : 0.0)],
                transition: TUIPrimitive.tween(duration: 0.16),
                enabled: enabled
            )
            self.revealed = Mutex(show)
        }

        public var alpha: Double {
            animatable.value()["value"]?.scalarValue ?? 0.0
        }

        public func update(show: Bool, enabled: Bool, at nowMs: Double) {
            if !show {
                animatable.jump(to: ["value": .scalar(0.0)], at: nowMs)
                return
            }
            let already = revealed.withLock { r -> Bool in
                let prev = r
                r = true
                return prev
            }
            if !enabled || already {
                animatable.jump(to: ["value": .scalar(1.0)], at: nowMs)
            } else {
                animatable.animate(to: ["value": .scalar(1.0)], at: nowMs)
            }
        }

        public func step(at nowMs: Double) {
            animatable.step(at: nowMs)
        }
    }

    // parity: tui/src/util/signal.ts#createFadeIn [status=adapted hash=2f6757323ec4]
    public static func createFadeIn(show: Bool, enabled: @escaping @Sendable () -> Bool = { true }) -> FadeInController {
        FadeInController(show: show, enabled: enabled)
    }

    // MARK: Single-Flight (`src/util/single-flight.ts`)

    public actor SingleFlight<Key: Hashable & Sendable> {
        private var pending: Set<Key> = []

        public init() {}

        public func run<Value: Sendable>(key: Key, operation: @Sendable () async throws -> Value) async throws -> Value? {
            if pending.contains(key) { return nil }
            pending.insert(key)
            defer { pending.remove(key) }
            return try await operation()
        }
    }

    // parity: tui/src/util/single-flight.ts#createSingleFlight [status=implemented hash=4e0715a3dc37]
    public static func createSingleFlight<Key: Hashable & Sendable>(_ keyType: Key.Type = Key.self) -> SingleFlight<Key> {
        SingleFlight<Key>()
    }

    // MARK: System Description (`src/util/system.ts`)

    // parity: tui/src/util/system.ts#describeOS [status=implemented hash=71498122fd70]
    public static func describeOS() -> String {
        let name: String
        #if os(macOS)
        name = "macOS"
        #elseif os(Windows)
        name = "Windows"
        #elseif os(Linux)
        name = "Linux"
        #else
        name = Platform.current.rawValue
        #endif
        let arch: String
        #if arch(arm64)
        arch = "arm64"
        #elseif arch(x86_64)
        arch = "x64"
        #else
        arch = "unknown"
        #endif
        let version = ProcessInfo.processInfo.operatingSystemVersionString
        return "\(name) \(version) (\(arch))"
    }

    // parity: tui/src/util/system.ts#describeTerminal [status=implemented hash=62834238e676]
    public static func describeTerminal(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let program = environment["TERM_PROGRAM"] ?? environment["TERM"] ?? "unknown"
        let version = environment["TERM_PROGRAM_VERSION"].map { $0.isEmpty ? "" : " \($0)" } ?? ""
        let mux = (environment["TMUX"] != nil && !environment["TMUX"]!.isEmpty)
            ? " in tmux"
            : ((environment["STY"] != nil && !environment["STY"]!.isEmpty) ? " in screen" : "")
        return "\(program)\(version)\(mux)"
    }

    // MARK: Todos (`src/util/todo.ts`)

    // parity: tui/src/util/todo.ts#TodoStatus [status=implemented hash=500df7812dd4]
    public enum TodoStatus: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
        case pending
        case inProgress = "in_progress"
        case completed
        case cancelled
    }

    // parity: tui/src/util/todo.ts#Todo [status=implemented hash=62ad81302616]
    public struct Todo: Equatable, Hashable, Sendable, Codable {
        public let content: String
        public let status: TodoStatus

        public init(content: String, status: TodoStatus = .pending) {
            self.content = content
            self.status = status
        }
    }

    // parity: tui/src/util/todo.ts#parseTodos [status=implemented hash=062d84e6deb3]
    public static func parseTodos(_ value: JSONValue?) -> [Todo] {
        guard case .array(let items) = value else { return [] }
        return items.compactMap { item in
            guard case .object(let obj) = item,
                  let content = obj["content"]?.stringValue,
                  !content.isEmpty
            else { return nil }
            let status = obj["status"]?.stringValue.flatMap(TodoStatus.init(rawValue:)) ?? .pending
            return Todo(content: content, status: status)
        }
    }

    // parity: tui/src/util/todo.ts#todoMarker [status=implemented hash=1e0eb46767c6]
    public static func todoMarker(_ status: TodoStatus, ascii: Bool = false) -> String {
        switch status {
        case .completed: return ascii ? "[x]" : "[✓]"
        case .inProgress: return ascii ? "[>]" : "[•]"
        case .cancelled: return "[-]"
        case .pending: return "[ ]"
        }
    }

    public struct SessionToolCallRecord: Equatable, Sendable {
        public let messageID: String
        public let toolName: String
        public let completed: Bool
        public let input: [String: JSONValue]

        public init(messageID: String, toolName: String, completed: Bool, input: [String: JSONValue]) {
            self.messageID = messageID
            self.toolName = toolName
            self.completed = completed
            self.input = input
        }
    }

    // parity: tui/src/util/todo.ts#sessionTodos [status=implemented hash=aee1411d7323]
    public static func sessionTodos(_ toolCalls: [SessionToolCallRecord], boundary: String? = nil) -> [Todo] {
        let filtered: ArraySlice<SessionToolCallRecord>
        if let boundary, let idx = toolCalls.firstIndex(where: { $0.messageID == boundary }) {
            filtered = toolCalls[..<idx]
        } else {
            filtered = toolCalls[...]
        }
        guard let latest = filtered.last(where: { $0.toolName == "todowrite" && $0.completed }) else {
            return []
        }
        return parseTodos(latest.input["todos"])
    }

    // MARK: Usage Limits (`src/util/usage-limits.ts`)

    // parity: tui/src/util/usage-limits.ts#LimitedModel [status=implemented hash=db6862f961d4]
    public struct LimitedModel: Equatable, Hashable, Sendable {
        public let id: String
        public let providerID: String
        public let inputCosts: [Double]
        public let contextLimit: Int

        public init(id: String, providerID: String, inputCosts: [Double], contextLimit: Int) {
            self.id = id
            self.providerID = providerID
            self.inputCosts = inputCosts
            self.contextLimit = contextLimit
        }
    }

    // parity: tui/src/util/usage-limits.ts#LimitedProvider [status=implemented hash=39db8ccb55f8]
    public struct LimitedProvider: Equatable, Hashable, Sendable {
        public let id: String
        public let integrationID: String?

        public init(id: String, integrationID: String? = nil) {
            self.id = id
            self.integrationID = integrationID
        }
    }

    // parity: tui/src/util/usage-limits.ts#ModelLimit [status=implemented hash=afe2725c25aa]
    public struct ModelLimit: Equatable, Hashable, Sendable {
        public let budget: UsageLimitsSchema.Budget
        public let spent: Double
        public let left: Double

        public init(budget: UsageLimitsSchema.Budget, spent: Double, left: Double) {
            self.budget = budget
            self.spent = spent
            self.left = left
        }
    }

    // parity: tui/src/util/usage-limits.ts#ModelUsage [status=implemented hash=35c4a57a8ad5]
    public struct ModelUsage: Equatable, Hashable, Sendable {
        public let left: Double
        public let reached: Bool
        public let resetsAt: Double
        public let limits: [ModelLimit]

        public init(left: Double, reached: Bool, resetsAt: Double, limits: [ModelLimit]) {
            self.left = left
            self.reached = reached
            self.resetsAt = resetsAt
            self.limits = limits
        }
    }

    // parity: tui/src/util/usage-limits.ts#UsageLevel [status=implemented hash=5f5ac4b9d209]
    public enum UsageLevel: String, Equatable, Hashable, Sendable {
        case plenty
        case low
        case out
        case reached
    }

    // parity: tui/src/util/usage-limits.ts#servedByConsole [status=implemented hash=792d1cfaebd4]
    public static func servedByConsole(_ provider: LimitedProvider?) -> Bool {
        provider?.integrationID == "opencode" && provider?.id != "opencode-go"
    }

    // parity: tui/src/util/usage-limits.ts#modelUsage [status=implemented hash=51c012a8e24c]
    public static func modelUsage(
        budgets: [UsageLimitsSchema.Budget],
        model: LimitedModel,
        provider: LimitedProvider?
    ) -> ModelUsage? {
        if !model.inputCosts.isEmpty && model.inputCosts.allSatisfy({ $0 == 0 }) {
            return nil
        }
        let limits: [ModelLimit] = budgets.compactMap { budget in
            if budget.coverage == .all {
                guard servedByConsole(provider) else { return nil }
                let spent = budget.spent.rawValue
                return ModelLimit(budget: budget, spent: spent, left: max(0, budget.limit.rawValue - spent))
            }
            guard let entry = budget.models.first(where: { $0.providerID.rawValue == model.providerID && $0.modelID.rawValue == model.id }) else {
                return nil
            }
            let spent = budget.per == .model ? (entry.spent?.rawValue ?? 0) : budget.spent.rawValue
            return ModelLimit(budget: budget, spent: spent, left: max(0, budget.limit.rawValue - spent))
        }.sorted { $0.left < $1.left }
        guard let binding = limits.first else { return nil }
        return ModelUsage(
            left: binding.left,
            reached: limits.contains { $0.spent >= $0.budget.limit.rawValue },
            resetsAt: limits.map(\.budget.resetsAt).min() ?? binding.budget.resetsAt,
            limits: limits
        )
    }

    // parity: tui/src/util/usage-limits.ts#usageLevel [status=implemented hash=42a3b61f340b]
    public static func usageLevel(_ usage: ModelUsage, model: LimitedModel) -> UsageLevel {
        if usage.reached || usage.left <= 0 { return .reached }
        let requestCost = (Double(model.contextLimit) / 1_000_000.0) * (model.inputCosts.first ?? 0)
        if usage.left < requestCost { return .out }
        if usage.left < requestCost * 3.0 { return .low }
        return .plenty
    }

    // parity: tui/src/util/usage-limits.ts#formatDollars [status=implemented hash=688765698752]
    public static func formatDollars(_ value: Double) -> String {
        if value > 0 && value < 0.01 { return "<$0.01" }
        let fmt = NumberFormatter()
        fmt.locale = Locale(identifier: "en_US")
        fmt.numberStyle = .currency
        fmt.currencyCode = "USD"
        fmt.currencySymbol = "$"
        let isWhole = value.rounded(.towardZero) == value
        fmt.minimumFractionDigits = isWhole ? 0 : 2
        fmt.maximumFractionDigits = 2
        return fmt.string(from: NSNumber(value: value)) ?? "$\(value)"
    }

    // parity: tui/src/util/usage-limits.ts#formatReset [status=implemented hash=be3a2c9c10c5]
    public static func formatReset(_ atMs: Double, now: Date = Date()) -> String {
        let date = Date(timeIntervalSince1970: atMs / 1000.0)
        let timeFmt = DateFormatter()
        timeFmt.locale = Locale(identifier: "en_US")
        timeFmt.dateFormat = "h:mm a"
        let timeStr = timeFmt.string(from: date).replacingOccurrences(of: "\u{202F}", with: " ")
        let cal = Calendar.current
        if cal.isDate(date, inSameDayAs: now) {
            return "\(timeStr) today"
        }
        let dayFmt = DateFormatter()
        dayFmt.locale = Locale(identifier: "en_US")
        dayFmt.dateFormat = "MMM d"
        let dayStr = dayFmt.string(from: date)
        let comps = cal.dateComponents([.hour, .minute], from: date)
        return (comps.hour == 0 && comps.minute == 0) ? dayStr : "\(dayStr), \(timeStr)"
    }

    // parity: tui/src/util/usage-limits.ts#refusalReset [status=implemented hash=d64f9b1d8197]
    public static func refusalReset(responseBody: String?) -> Double? {
        guard let body = responseBody,
              let rx = try? NSRegularExpression(pattern: #""resetsAt"\s*:\s*"([^"]+)""#),
              let match = rx.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
              let range = Range(match.range(at: 1), in: body)
        else { return nil }
        let isoStr = String(body[range])
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: isoStr) { return d.timeIntervalSince1970 * 1000.0 }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: isoStr) { return d.timeIntervalSince1970 * 1000.0 }
        return nil
    }

    // parity: tui/src/util/usage-limits.ts#retryReset [status=implemented hash=6d9d385481be]
    public static func retryReset(retryAfterMs: Double?, baseMs: Double) -> Double? {
        guard let delay = retryAfterMs, delay.isFinite, delay >= 0, delay <= 45.0 * 86_400_000.0 else {
            return nil
        }
        let at = baseMs + delay
        return at.isFinite ? at : nil
    }

    // parity: tui/src/util/usage-limits.ts#goLimitName [status=implemented hash=5e2f34539f80]
    public static func goLimitName(responseBody: String?) -> String? {
        guard let body = responseBody,
              let rx = try? NSRegularExpression(pattern: #""limitName"\s*:\s*"([^"]+)""#),
              let match = rx.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
              let range = Range(match.range(at: 1), in: body)
        else { return nil }
        return String(body[range])
    }

    // parity: tui/src/util/usage-limits.ts#goLimitLink [status=implemented hash=1fdbc7cb6063]
    public static func goLimitLink(responseBody: String?) -> String {
        if let body = responseBody,
           let rx = try? NSRegularExpression(pattern: #""workspace"\s*:\s*"((?:org|wrk)_[\w-]+)""#),
           let match = rx.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
           let range = Range(match.range(at: 1), in: body)
        {
            return "https://opencode.ai/console/\(body[range])/go"
        }
        return "https://opencode.ai/console"
    }

    // parity: tui/src/util/usage-limits.ts#limitScope [status=implemented hash=fa26e0da3096]
    public static func limitScope(_ budget: UsageLimitsSchema.Budget, workspace: String?) -> String {
        let who: String
        if budget.scope == .each {
            who = "Only you"
        } else if budget.shared {
            who = "Everyone in \(workspace ?? "the workspace")"
        } else {
            who = "You and others"
        }
        if budget.per == .model { return who }
        return "\(who) · \(limitModels(budget))"
    }

    private static func limitModels(_ budget: UsageLimitsSchema.Budget) -> String {
        if budget.coverage == .all { return "All models" }
        let vendors = budget.vendors.isEmpty ? nil : englishConjunctionList(budget.vendors)
        let price = budget.inputPriceAtLeast.map { "\(formatDollars($0.rawValue)) per 1M" }
        if let vendors, let price { return "\(vendors) models over \(price)" }
        if let vendors { return "All \(vendors) models" }
        if let price { return "Models over \(price)" }
        let names = budget.models.map(\.name)
        if names.count > 3 {
            return "\(names.prefix(3).joined(separator: ", ")) +\(names.count - 3) more"
        }
        return names.joined(separator: ", ")
    }

    private static func englishConjunctionList(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default: return "\(items.dropLast().joined(separator: ", ")), and \(items.last!)"
        }
    }

    // MARK: Safe File Watcher (`src/util/watch.ts`)

    public final class SafeWatchHandle: Sendable {
        private let closed = Mutex(false)
        private let onCloseFn: @Sendable () -> Void

        public init(onClose: @escaping @Sendable () -> Void = {}) {
            self.onCloseFn = onClose
        }

        public var isClosed: Bool { closed.withLock { $0 } }

        public func close() {
            let shouldRun = closed.withLock { flag -> Bool in
                if flag { return false }
                flag = true
                return true
            }
            if shouldRun { onCloseFn() }
        }
    }

    /// Safe filesystem watch helper honoring `OPENCODE_FILEWATCHER_DISABLE` / `OPENCODE_DISABLE_FILEWATCHER`.
    // parity: tui/src/util/watch.ts#safeWatch [status=adapted hash=bdc5afb65b37]
    public static func safeWatch(
        target: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        listener: @escaping @Sendable (String, String?) -> Void
    ) -> SafeWatchHandle? {
        let disabled = environment["OPENCODE_FILEWATCHER_DISABLE"] ?? environment["OPENCODE_DISABLE_FILEWATCHER"]
        if disabled == "1" || disabled?.lowercased() == "true" { return nil }
        guard FileManager.default.fileExists(atPath: target) else { return nil }
        let _ = listener
        return SafeWatchHandle()
    }
}

// MARK: - TUIThemeBridge (`packages/tui/src/theme/*`, 7 files / 20 symbols)

/// Theme bridge integrating built-in V1/V2 themes, terminal system theme generation, custom theme discovery,
/// and reactive theme subscriptions with `OpenCodeTUI/Theme`.
public enum TUIThemeBridge {

    // MARK: Color Helpers (`src/theme/color.ts`)

    // parity: tui/src/theme/color.ts#ansiToRgba [status=implemented hash=eaaa53390348]
    public static func ansiToRgba(_ code: Int) -> RGBA {
        if code >= 0 && code < 16 {
            let ansiColors = [
                "#000000", "#800000", "#008000", "#808000",
                "#000080", "#800080", "#008080", "#c0c0c0",
                "#808080", "#ff0000", "#00ff00", "#ffff00",
                "#0000ff", "#ff00ff", "#00ffff", "#ffffff",
            ]
            return RGBA.fromHex(ansiColors[code])
        }
        if code >= 16 && code < 232 {
            let index = code - 16
            let b = index % 6
            let g = (index / 6) % 6
            let r = index / 36
            func val(_ x: Int) -> Int { x == 0 ? 0 : x * 40 + 55 }
            return RGBA.fromInts(val(r), val(g), val(b))
        }
        if code >= 232 && code < 256 {
            let gray = (code - 232) * 10 + 8
            return RGBA.fromInts(gray, gray, gray)
        }
        return RGBA.fromInts(0, 0, 0)
    }

    // parity: tui/src/theme/color.ts#tint [status=implemented hash=0842eaaa5aae]
    public static func tint(_ base: RGBA, overlay: RGBA, alpha: Double) -> RGBA {
        let r = base.r + (overlay.r - base.r) * alpha
        let g = base.g + (overlay.g - base.g) * alpha
        let b = base.b + (overlay.b - base.b) * alpha
        return RGBA.fromInts(
            Int((r * 255.0).rounded()),
            Int((g * 255.0).rounded()),
            Int((b * 255.0).rounded())
        )
    }

    // MARK: Component Theme Wrapper (`src/theme/component.ts`)

    // parity: tui/src/theme/component.ts#ComponentTheme [status=implemented hash=bebb06b8d8fc]
    public typealias ComponentTheme = ResolvedTheme

    // parity: tui/src/theme/component.ts#createComponentTheme [status=adapted hash=5d323067c465]
    public static func createComponentTheme(_ view: @escaping @Sendable () -> ResolvedTheme) -> ComponentTheme {
        view()
    }

    // MARK: V1 Color Resolution (`src/theme/resolve.ts`)

    public struct ResolvedV1ColorsResult: Equatable, Sendable {
        public let theme: V1Theme
        public let hasSelectedListItemText: Bool
        public let thinkingOpacity: Double

        public init(theme: V1Theme, hasSelectedListItemText: Bool, thinkingOpacity: Double) {
            self.theme = theme
            self.hasSelectedListItemText = hasSelectedListItemText
            self.thinkingOpacity = thinkingOpacity
        }
    }

    // parity: tui/src/theme/resolve.ts#resolveThemeColors [status=implemented hash=552753ee0656]
    public static func resolveThemeColors(
        _ theme: ThemeV1Json,
        mode: Mode,
        resolveAnsi: (Int) -> RGBA = ansiToRgba
    ) throws -> ResolvedV1ColorsResult {
        let _ = resolveAnsi
        let resolved = try resolveV1(theme, mode: mode)
        return ResolvedV1ColorsResult(
            theme: resolved,
            hasSelectedListItemText: resolved._hasSelectedListItemText,
            thinkingOpacity: resolved.thinkingOpacity
        )
    }

    // MARK: System Terminal Theme (`src/theme/system.ts`)

    // parity: tui/src/theme/system.ts#terminalMode [status=implemented hash=8d21436e4c43]
    public static func terminalMode(_ colors: TerminalColors) -> Mode? {
        guard let bg = colors.defaultBackground, !bg.isEmpty else { return nil }
        let rgba = RGBA.fromHex(bg)
        return (0.299 * rgba.r + 0.587 * rgba.g + 0.114 * rgba.b) > 0.5 ? .light : .dark
    }

    // parity: tui/src/theme/system.ts#generateSystem [status=implemented hash=b52bcfed439b]
    public static func generateSystem(_ colors: TerminalColors, mode: Mode) -> ThemeV1Json {
        let bgHex = colors.defaultBackground ?? (colors.palette.indices.contains(0) ? colors.palette[0] : nil) ?? (mode == .dark ? "#000000" : "#ffffff")
        let fgHex = colors.defaultForeground ?? (colors.palette.indices.contains(7) ? colors.palette[7] : nil) ?? (mode == .dark ? "#ffffff" : "#000000")
        let bg = RGBA.fromHex(bgHex)
        let fg = RGBA.fromHex(fgHex)
        let transparent = RGBA.fromValues(bg.r, bg.g, bg.b, 0)
        let isDark = mode == .dark

        func col(_ index: Int) -> RGBA {
            if colors.palette.indices.contains(index), let hex = colors.palette[index], !hex.isEmpty {
                return RGBA.fromHex(hex)
            }
            return ansiToRgba(index)
        }

        let grays = generateGrayScale(bg: bg, isDark: isDark)
        let textMuted = generateMutedTextColor(bg: bg, isDark: isDark)
        let red = col(1), green = col(2), yellow = col(3), blue = col(4), magenta = col(5), cyan = col(6)
        let redBright = col(9), greenBright = col(10)
        let diffAlpha = isDark ? 0.22 : 0.14
        let diffAddedBg = tint(bg, overlay: green, alpha: diffAlpha)
        let diffRemovedBg = tint(bg, overlay: red, alpha: diffAlpha)
        let diffContextBg = grays[2] ?? bg
        let diffAddedLineNumberBg = tint(diffContextBg, overlay: green, alpha: diffAlpha)
        let diffRemovedLineNumberBg = tint(diffContextBg, overlay: red, alpha: diffAlpha)

        return ThemeV1Json(theme: [
            .primary: .rgba(cyan), .secondary: .rgba(magenta), .accent: .rgba(cyan),
            .error: .rgba(red), .warning: .rgba(yellow), .success: .rgba(green), .info: .rgba(cyan),
            .text: .rgba(fg), .textMuted: .rgba(textMuted), .selectedListItemText: .rgba(bg),
            .background: .rgba(transparent),
            .backgroundPanel: .rgba(grays[2] ?? bg),
            .backgroundElement: .rgba(grays[3] ?? bg),
            .backgroundMenu: .rgba(grays[3] ?? bg),
            .borderSubtle: .rgba(grays[6] ?? fg),
            .border: .rgba(grays[7] ?? fg),
            .borderActive: .rgba(grays[8] ?? fg),
            .diffAdded: .rgba(green), .diffRemoved: .rgba(red),
            .diffContext: .rgba(grays[7] ?? textMuted), .diffHunkHeader: .rgba(grays[7] ?? textMuted),
            .diffHighlightAdded: .rgba(greenBright), .diffHighlightRemoved: .rgba(redBright),
            .diffAddedBg: .rgba(diffAddedBg), .diffRemovedBg: .rgba(diffRemovedBg), .diffContextBg: .rgba(diffContextBg),
            .diffLineNumber: .rgba(textMuted),
            .diffAddedLineNumberBg: .rgba(diffAddedLineNumberBg),
            .diffRemovedLineNumberBg: .rgba(diffRemovedLineNumberBg),
            .markdownText: .rgba(fg), .markdownHeading: .rgba(fg),
            .markdownLink: .rgba(blue), .markdownLinkText: .rgba(cyan),
            .markdownCode: .rgba(green), .markdownBlockQuote: .rgba(yellow),
            .markdownEmph: .rgba(yellow), .markdownStrong: .rgba(fg),
            .markdownHorizontalRule: .rgba(grays[7] ?? textMuted),
            .markdownListItem: .rgba(blue), .markdownListEnumeration: .rgba(cyan),
            .markdownImage: .rgba(blue), .markdownImageText: .rgba(cyan), .markdownCodeBlock: .rgba(fg),
            .syntaxComment: .rgba(textMuted), .syntaxKeyword: .rgba(magenta),
            .syntaxFunction: .rgba(blue), .syntaxVariable: .rgba(fg),
            .syntaxString: .rgba(green), .syntaxNumber: .rgba(yellow),
            .syntaxType: .rgba(cyan), .syntaxOperator: .rgba(cyan), .syntaxPunctuation: .rgba(fg),
        ])
    }

    private static func generateGrayScale(bg: RGBA, isDark: Bool) -> [Int: RGBA] {
        var grays: [Int: RGBA] = [:]
        let bgR = bg.r * 255.0, bgG = bg.g * 255.0, bgB = bg.b * 255.0
        let lum = 0.299 * bgR + 0.587 * bgG + 0.114 * bgB
        for i in 1...12 {
            let factor = Double(i) / 12.0
            if isDark && lum < 10 {
                let g = Int(floor(factor * 0.4 * 255.0))
                grays[i] = RGBA.fromInts(g, g, g)
                continue
            }
            if !isDark && lum > 245 {
                let g = Int(floor(255.0 - factor * 0.4 * 255.0))
                grays[i] = RGBA.fromInts(g, g, g)
                continue
            }
            let next = isDark ? lum + (255.0 - lum) * factor * 0.4 : lum * (1.0 - factor * 0.4)
            let ratio = lum == 0 ? 1.0 : next / lum
            grays[i] = RGBA.fromInts(
                Int(floor(min(max(bgR * ratio, 0), 255))),
                Int(floor(min(max(bgG * ratio, 0), 255))),
                Int(floor(min(max(bgB * ratio, 0), 255)))
            )
        }
        return grays
    }

    private static func generateMutedTextColor(bg: RGBA, isDark: Bool) -> RGBA {
        let lum = 0.299 * bg.r * 255.0 + 0.587 * bg.g * 255.0 + 0.114 * bg.b * 255.0
        if isDark {
            let gray = lum < 10 ? 180 : min(Int(floor(160.0 + lum * 0.3)), 200)
            return RGBA.fromInts(gray, gray, gray)
        }
        let gray = lum > 245 ? 75 : max(Int(floor(100.0 - (255.0 - lum) * 0.2)), 60)
        return RGBA.fromInts(gray, gray, gray)
    }

    // MARK: Built-In V1 Presets (`src/theme/v1.ts`)

    private static func v1Preset(
        bg: String, panel: String, elem: String, text: String, muted: String,
        primary: String, secondary: String, accent: String,
        error: String = "#e06c75", warning: String = "#e5c07b", success: String = "#98c379", info: String = "#56b6c2"
    ) -> ThemeV1Json {
        ThemeV1Json(theme: [
            .primary: .string(primary), .secondary: .string(secondary), .accent: .string(accent),
            .error: .string(error), .warning: .string(warning), .success: .string(success), .info: .string(info),
            .text: .string(text), .textMuted: .string(muted), .selectedListItemText: .string(bg),
            .background: .string(bg), .backgroundPanel: .string(panel), .backgroundElement: .string(elem), .backgroundMenu: .string(elem),
            .border: .string(muted), .borderActive: .string(primary), .borderSubtle: .string(elem),
            .diffAdded: .string(success), .diffRemoved: .string(error), .diffContext: .string(muted), .diffHunkHeader: .string(info),
            .diffHighlightAdded: .string(success), .diffHighlightRemoved: .string(error),
            .diffAddedBg: .string(panel), .diffRemovedBg: .string(panel), .diffContextBg: .string(bg),
            .diffLineNumber: .string(muted), .diffAddedLineNumberBg: .string(panel), .diffRemovedLineNumberBg: .string(panel),
            .markdownText: .string(text), .markdownHeading: .string(accent), .markdownLink: .string(primary), .markdownLinkText: .string(info),
            .markdownCode: .string(success), .markdownBlockQuote: .string(warning), .markdownEmph: .string(warning), .markdownStrong: .string(accent),
            .markdownHorizontalRule: .string(muted), .markdownListItem: .string(primary), .markdownListEnumeration: .string(info),
            .markdownImage: .string(primary), .markdownImageText: .string(info), .markdownCodeBlock: .string(text),
            .syntaxComment: .string(muted), .syntaxKeyword: .string(accent), .syntaxFunction: .string(primary),
            .syntaxVariable: .string(error), .syntaxString: .string(success), .syntaxNumber: .string(warning),
            .syntaxType: .string(secondary), .syntaxOperator: .string(info), .syntaxPunctuation: .string(text),
        ])
    }

    /// All 32 built-in V1 community theme presets matching `src/theme/v1.ts#DEFAULT_THEMES`.
    // parity: tui/src/theme/v1.ts#DEFAULT_THEMES [status=implemented hash=147c37293900]
    public static let DEFAULT_THEMES: [String: ThemeV1Json] = [
        "aura": v1Preset(bg: "#15141b", panel: "#1c1b22", elem: "#29263c", text: "#edecee", muted: "#6d6d6d", primary: "#a277ff", secondary: "#61ffca", accent: "#ffca85"),
        "ayu": v1Preset(bg: "#0b0e14", panel: "#11151c", elem: "#1a1f29", text: "#bfbdb6", muted: "#565b66", primary: "#ffb454", secondary: "#59c2ff", accent: "#d2a6ff"),
        "catppuccin": v1Preset(bg: "#1e1e2e", panel: "#181825", elem: "#313244", text: "#cdd6f4", muted: "#a6adc8", primary: "#89b4fa", secondary: "#cba6f7", accent: "#f5c2e7"),
        "catppuccin-frappe": v1Preset(bg: "#303446", panel: "#292c3c", elem: "#414559", text: "#c6d0f5", muted: "#a5adce", primary: "#8caaee", secondary: "#ca9ee6", accent: "#f4b8e4"),
        "catppuccin-macchiato": v1Preset(bg: "#24273a", panel: "#1e2030", elem: "#363a4f", text: "#cad3f5", muted: "#a5adcb", primary: "#8aadf4", secondary: "#c6a0f6", accent: "#f5bde6"),
        "cobalt2": v1Preset(bg: "#193549", panel: "#122738", elem: "#1f4662", text: "#ffffff", muted: "#adb7c9", primary: "#ffc600", secondary: "#0088ff", accent: "#ff9d00"),
        "cursor": v1Preset(bg: "#181818", panel: "#1f1f1f", elem: "#2b2b2b", text: "#e4e4e4", muted: "#888888", primary: "#83d6c5", secondary: "#efb080", accent: "#aaa0fa"),
        "dracula": v1Preset(bg: "#282a36", panel: "#21222c", elem: "#44475a", text: "#f8f8f2", muted: "#6272a4", primary: "#bd93f9", secondary: "#ff79c6", accent: "#8be9fd"),
        "everforest": v1Preset(bg: "#2d353b", panel: "#232a2e", elem: "#343f44", text: "#d3c6aa", muted: "#859289", primary: "#a7c080", secondary: "#7fbbb3", accent: "#d699b6"),
        "flexoki": v1Preset(bg: "#100f0f", panel: "#1c1b1a", elem: "#282726", text: "#cecdc3", muted: "#878580", primary: "#da702c", secondary: "#4385be", accent: "#8b7ec8"),
        "github": v1Preset(bg: "#0d1117", panel: "#161b22", elem: "#21262d", text: "#c9d1d9", muted: "#8b949e", primary: "#58a6ff", secondary: "#bc8cff", accent: "#39c5cf"),
        "gruvbox": v1Preset(bg: "#282828", panel: "#1d2021", elem: "#3c3836", text: "#ebdbb2", muted: "#928374", primary: "#83a598", secondary: "#d3869b", accent: "#fe8019"),
        "kanagawa": v1Preset(bg: "#1f1f28", panel: "#16161d", elem: "#2a2a37", text: "#dcd7ba", muted: "#727169", primary: "#7e9cd8", secondary: "#957fb8", accent: "#ffa066"),
        "material": v1Preset(bg: "#263238", panel: "#1e272c", elem: "#37474f", text: "#eeffff", muted: "#546e7a", primary: "#82aaff", secondary: "#c792ea", accent: "#89ddff"),
        "matrix": v1Preset(bg: "#0a0e0a", panel: "#0e130d", elem: "#141c12", text: "#62ff94", muted: "#2eff6a", primary: "#2eff6a", secondary: "#00efff", accent: "#c770ff"),
        "mercury": v1Preset(bg: "#171721", panel: "#1d1d29", elem: "#272735", text: "#dddde5", muted: "#787c99", primary: "#8da4f5", secondary: "#a48cf2", accent: "#77c5d5"),
        "monokai": v1Preset(bg: "#272822", panel: "#1e1f1c", elem: "#3e3d32", text: "#f8f8f2", muted: "#75715e", primary: "#66d9ef", secondary: "#ae81ff", accent: "#fd971f"),
        "nightowl": v1Preset(bg: "#011627", panel: "#0b253a", elem: "#1d3b53", text: "#d6deeb", muted: "#5f7e97", primary: "#82aaff", secondary: "#c792ea", accent: "#7fdbca"),
        "nord": v1Preset(bg: "#2e3440", panel: "#3b4252", elem: "#434c5e", text: "#eceff4", muted: "#88c0d0", primary: "#88c0d0", secondary: "#81a1c1", accent: "#b48ead"),
        "one-dark": v1Preset(bg: "#282c34", panel: "#21252b", elem: "#353b45", text: "#abb2bf", muted: "#5c6370", primary: "#61afef", secondary: "#c678dd", accent: "#56b6c2"),
        "osaka-jade": v1Preset(bg: "#111c18", panel: "#16241f", elem: "#23372b", text: "#c1c497", muted: "#53685b", primary: "#509475", secondary: "#2dd5b7", accent: "#549e6a"),
        "orng": v1Preset(bg: "#0a0a0a", panel: "#141414", elem: "#1e1e1e", text: "#eeeeee", muted: "#808080", primary: "#ec5b2b", secondary: "#ee7948", accent: "#fff7f1"),
        "lucent-orng": v1Preset(bg: "#0a0a0a", panel: "#141414", elem: "#1e1e1e", text: "#eeeeee", muted: "#808080", primary: "#ec5b2b", secondary: "#ee7948", accent: "#fff7f1"),
        "palenight": v1Preset(bg: "#292d3e", panel: "#1b1e2b", elem: "#32374d", text: "#a6accd", muted: "#676e95", primary: "#82aaff", secondary: "#c792ea", accent: "#89ddff"),
        "rosepine": v1Preset(bg: "#191724", panel: "#1f1d2e", elem: "#26233a", text: "#e0def4", muted: "#908caa", primary: "#ebbcba", secondary: "#c4a7e7", accent: "#9ccfd8"),
        "solarized": v1Preset(bg: "#002b36", panel: "#073642", elem: "#0b4656", text: "#839496", muted: "#586e75", primary: "#268bd2", secondary: "#6c71c4", accent: "#2aa198"),
        "synthwave84": v1Preset(bg: "#262335", panel: "#1e1a29", elem: "#34294f", text: "#ffffff", muted: "#848bbd", primary: "#36f9f6", secondary: "#ff7edb", accent: "#b084eb"),
        "tokyonight": v1Preset(bg: "#1a1b26", panel: "#16161e", elem: "#292e42", text: "#c0caf5", muted: "#565f89", primary: "#82aaff", secondary: "#bb9af7", accent: "#ff9e64"),
        "vesper": v1Preset(bg: "#101010", panel: "#161616", elem: "#232323", text: "#ffffff", muted: "#a0a0a0", primary: "#ffc799", secondary: "#99ffe4", accent: "#ffc799"),
        "vercel": v1Preset(bg: "#000000", panel: "#0a0a0a", elem: "#1a1a1a", text: "#ededed", muted: "#888888", primary: "#0070f3", secondary: "#52a8ff", accent: "#8e4ec6"),
        "zenburn": v1Preset(bg: "#3f3f3f", panel: "#353535", elem: "#4f4f4f", text: "#dcdccc", muted: "#7f9f7f", primary: "#8cd0d3", secondary: "#dc8cc3", accent: "#dfaf8f"),
        "carbonfox": v1Preset(bg: "#161616", panel: "#1f1f1f", elem: "#2a2a2a", text: "#f2f4f8", muted: "#7b7c7e", primary: "#78a9ff", secondary: "#be95ff", accent: "#33b1ff"),
    ]

    // MARK: Theme Discovery (`src/theme/discovery.ts`)

    // parity: tui/src/theme/discovery.ts#discoverThemes [status=implemented hash=5bfd098933a2]
    public static func discoverThemes(directories: [String]) async throws -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        let fm = FileManager.default
        for directory in directories {
            let themeDir = URL(fileURLWithPath: directory).appendingPathComponent("themes").path
            guard fm.fileExists(atPath: themeDir) else { continue }
            let items = try fm.contentsOfDirectory(atPath: themeDir).sorted()
            for item in items where item.hasSuffix(".json") {
                let fullPath = URL(fileURLWithPath: themeDir).appendingPathComponent(item).path
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: fullPath, isDirectory: &isDir), !isDir.boolValue else { continue }
                let data = try Data(contentsOf: URL(fileURLWithPath: fullPath))
                let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
                let name = String(item.dropLast(5))
                result[name] = decoded
            }
        }
        return result
    }

    // MARK: Theme Registry & Subscriptions (`src/theme/index.ts`)

    // parity: tui/src/theme/index.ts#ThemeDocumentSource [status=implemented hash=e62d9750ced9]
    public enum ThemeDocumentSource: Equatable, Sendable {
        case v2(ThemeDocument)
        case v1(ThemeV1Json)
        case raw(JSONValue)
    }

    private struct RegistryState: Sendable {
        var customThemes: [String: ThemeDocumentSource] = [:]
        var systemTheme: ThemeDocumentSource? = nil
        var nextListenerID: UInt64 = 1
        var listeners: [UInt64: @Sendable ([String: ThemeDocumentSource]) -> Void] = [:]
    }

    private static let registryState = Mutex(RegistryState())

    /// The default "opencode" theme.
    // parity: tui/src/theme/index.ts#getOpenCodeTheme [status=implemented hash=5447f380efc9]
    public static func getOpenCodeTheme() -> ThemeDocument {
        ThemeDefaults.opencode
    }

    /// The previous "opencode" theme, offered as "opencode-classic".
    // parity: tui/src/theme/index.ts#getOpenCodeClassicTheme [status=implemented hash=9cad9f14de3c]
    public static func getOpenCodeClassicTheme() -> ThemeDocument {
        ThemeDefaults.opencodeClassic
    }

    // parity: tui/src/theme/index.ts#allThemes [status=implemented hash=bde16313efa6]
    public static func allThemes() -> [String: ThemeDocumentSource] {
        registryState.withLock { state in
            var themes: [String: ThemeDocumentSource] = [:]
            for (k, v) in DEFAULT_THEMES {
                themes[k] = .v1(v)
            }
            themes["opencode"] = .v2(getOpenCodeTheme())
            themes["opencode-classic"] = .v2(getOpenCodeClassicTheme())
            for (k, v) in state.customThemes {
                themes[k] = v
            }
            themes["system"] = state.systemTheme ?? themes["system"] ?? themes["opencode"]
            return themes
        }
    }

    // parity: tui/src/theme/index.ts#isThemeSource [status=implemented hash=a260e572cd42]
    public static func isThemeSource(_ source: JSONValue) -> Bool {
        guard case .object(let dict) = source else { return false }
        return dict["theme"] != nil || dict["base"] != nil
    }

    // parity: tui/src/theme/index.ts#parseTheme [status=implemented hash=b8c46692a5a9]
    public static func parseTheme(
        _ source: ThemeDocumentSource,
        name: String = "theme",
        newDesigns: Bool = false
    ) throws -> ThemeDocument {
        switch source {
        case .v2(let doc):
            return doc
        case .v1(let v1):
            return newDesigns ? try migrateV1NewDesigns(v1) : try migrateV1(v1)
        case .raw(let json):
            if case .object(let dict) = json, dict["theme"] != nil {
                let data = try JSONEncoder().encode(json)
                let v1 = try JSONDecoder().decode(ThemeV1Json.self, from: data)
                return newDesigns ? try migrateV1NewDesigns(v1) : try migrateV1(v1)
            }
            return try parseThemeDocument(json, name: name)
        }
    }

    // parity: tui/src/theme/index.ts#subscribeThemes [status=implemented hash=0af435a95b8e]
    @discardableResult
    public static func subscribeThemes(
        _ listener: @escaping @Sendable ([String: ThemeDocumentSource]) -> Void
    ) -> @Sendable () -> Void {
        let id = registryState.withLock { state -> UInt64 in
            let current = state.nextListenerID
            state.nextListenerID += 1
            state.listeners[current] = listener
            return current
        }
        return {
            registryState.withLock { _ = $0.listeners.removeValue(forKey: id) }
        }
    }

    // parity: tui/src/theme/index.ts#setCustomThemes [status=implemented hash=32345799dd6d]
    public static func setCustomThemes(_ themes: [String: JSONValue]) {
        let filtered: [String: ThemeDocumentSource] = themes.reduce(into: [:]) { acc, entry in
            if isThemeSource(entry.value) {
                acc[entry.key] = .raw(entry.value)
            }
        }
        let callbacks = registryState.withLock { state -> [@Sendable ([String: ThemeDocumentSource]) -> Void] in
            state.customThemes = filtered
            return Array(state.listeners.values)
        }
        let snapshot = allThemes()
        for cb in callbacks { cb(snapshot) }
    }

    // parity: tui/src/theme/index.ts#setSystemTheme [status=implemented hash=5e7a3d5bb2cb]
    public static func setSystemTheme(_ theme: ThemeDocumentSource?) {
        let callbacks = registryState.withLock { state -> [@Sendable ([String: ThemeDocumentSource]) -> Void] in
            state.systemTheme = theme
            return Array(state.listeners.values)
        }
        let snapshot = allThemes()
        for cb in callbacks { cb(snapshot) }
    }

    // parity: tui/src/theme/index.ts#hasTheme [status=implemented hash=d70082ca8ef8]
    public static func hasTheme(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        return allThemes()[name] != nil
    }

    // parity: tui/src/theme/index.ts#resolveTheme [status=implemented hash=556ab501494f]
    public static func resolveTheme(_ theme: ThemeV1Json, mode: Mode) throws -> V1Theme {
        try resolveThemeColors(theme, mode: mode).theme
    }
}

// MARK: - TUIPluginHost (`packages/tui/src/plugin/*`, 8 files / 28 symbols)

/// TUI plugin host runtime: pure slot-tree placement resolver, plugin discovery/merging,
/// markdown code-block renderer dispatch, plugin context & dialog API, crash boundaries, and builtins registry.
public enum TUIPluginHost {

    // MARK: Slot Structure & Resolution (`src/plugin/structure.ts`)

    // parity: tui/src/plugin/structure.ts#PlacementKind [status=implemented hash=0a4114e760b8]
    public enum PlacementKind: String, Equatable, Hashable, Sendable, CaseIterable {
        case prepend
        case append
        case before
        case after
        case replace
    }

    // parity: tui/src/plugin/structure.ts#Placement [status=implemented hash=c187f40b0a05]
    public struct Placement: Equatable, Hashable, Sendable {
        public let kind: PlacementKind
        public let target: String

        public init(kind: PlacementKind, target: String) {
            self.kind = kind
            self.target = target
        }
    }

    // parity: tui/src/plugin/structure.ts#Claim [status=implemented hash=a457ae4a8b60]
    public struct Claim<Render: Sendable>: Sendable {
        public let key: String
        public let plugin: String
        public let placement: Placement
        public let render: Render

        public init(key: String, plugin: String, placement: Placement, render: Render) {
            self.key = key
            self.plugin = plugin
            self.placement = placement
            self.render = render
        }
    }

    // parity: tui/src/plugin/structure.ts#Slotted [status=implemented hash=3c343edbef17]
    public struct Slotted<Render: Sendable>: Sendable {
        public var before: [Claim<Render>]
        public var prepend: [Claim<Render>]
        public var append: [Claim<Render>]
        public var after: [Claim<Render>]
        public var replace: Claim<Render>?

        public init(
            before: [Claim<Render>] = [],
            prepend: [Claim<Render>] = [],
            append: [Claim<Render>] = [],
            after: [Claim<Render>] = [],
            replace: Claim<Render>? = nil
        ) {
            self.before = before
            self.prepend = prepend
            self.append = append
            self.after = after
            self.replace = replace
        }
    }

    // parity: tui/src/plugin/structure.ts#Suppressed [status=implemented hash=f3f3c4746799]
    public struct Suppressed<Render: Sendable>: Sendable {
        public let claim: Claim<Render>
        public let by: Claim<Render>?

        public init(claim: Claim<Render>, by: Claim<Render>? = nil) {
            self.claim = claim
            self.by = by
        }
    }

    // parity: tui/src/plugin/structure.ts#Degraded [status=implemented hash=4514a22657bb]
    public struct Degraded<Render: Sendable>: Sendable {
        public let claim: Claim<Render>
        public let to: String

        public init(claim: Claim<Render>, to: String) {
            self.claim = claim
            self.to = to
        }
    }

    public struct ResolvedSlotsResult<Render: Sendable>: Sendable {
        public let slotted: [String: Slotted<Render>]
        public let suppressed: [Suppressed<Render>]
        public let degraded: [Degraded<Render>]

        public init(
            slotted: [String: Slotted<Render>],
            suppressed: [Suppressed<Render>],
            degraded: [Degraded<Render>]
        ) {
            self.slotted = slotted
            self.suppressed = suppressed
            self.degraded = degraded
        }
    }

    // parity: tui/src/plugin/structure.ts#emptySlotted [status=implemented hash=60e2584613a9]
    public static func emptySlotted<Render: Sendable>() -> Slotted<Render> {
        Slotted<Render>()
    }

    // parity: tui/src/plugin/structure.ts#contains [status=implemented hash=b4d82d1f43e4]
    public static func contains(ancestor: String, path: String) -> Bool {
        path.hasPrefix(ancestor + ".")
    }

    /// Pure slot-tree placement resolver enforcing replacement takeover, hierarchy-beats-timeline,
    /// last-enabled-wins, and missing-target ancestor degradation.
    // parity: tui/src/plugin/structure.ts#resolveSlots [status=implemented hash=a5a6cb3fa1c4]
    public static func resolveSlots<Render: Sendable>(
        paths: Set<String>,
        claims: [Claim<Render>]
    ) -> ResolvedSlotsResult<Render> {
        var suppressed: [Suppressed<Render>] = []
        var degraded: [Degraded<Render>] = []

        // Pass 1: replacement boundaries
        var winners: [String: Claim<Render>] = [:]
        for claim in claims where claim.placement.kind == .replace {
            let target = claim.placement.target
            if !paths.contains(target) {
                suppressed.append(Suppressed(claim: claim))
                continue
            }
            if let prior = winners[target] {
                suppressed.append(Suppressed(claim: prior, by: claim))
            }
            winners[target] = claim
        }
        var boundaries: [String: Claim<Render>] = [:]
        func containing(_ path: String) -> Claim<Render>? {
            for (boundary, winner) in boundaries where contains(ancestor: boundary, path: path) {
                return winner
            }
            return nil
        }
        let sortedWinners = winners.sorted { lhs, rhs in
            let dl = lhs.key.split(separator: ".").count
            let dr = rhs.key.split(separator: ".").count
            return dl == dr ? lhs.key < rhs.key : dl < dr
        }
        for (path, winner) in sortedWinners {
            if let outer = containing(path) {
                suppressed.append(Suppressed(claim: winner, by: outer))
                continue
            }
            boundaries[path] = winner
        }

        // Pass 2: additive claims in enable order
        var buckets: [String: Slotted<Render>] = [:]
        for claim in claims where claim.placement.kind != .replace {
            let kind = claim.placement.kind
            let target = claim.placement.target
            let inside = (kind == .prepend || kind == .append) ? boundaries[target] : nil
            if let outer = inside ?? containing(target) {
                suppressed.append(Suppressed(claim: claim, by: outer))
                continue
            }
            if paths.contains(target) {
                var b = buckets[target] ?? Slotted<Render>()
                switch kind {
                case .before: b.before.append(claim)
                case .prepend: b.prepend.append(claim)
                case .append: b.append.append(claim)
                case .after: b.after.append(claim)
                case .replace: break
                }
                buckets[target] = b
                continue
            }
            guard let ancestor = survivingAncestor(target, paths: paths) else {
                suppressed.append(Suppressed(claim: claim))
                continue
            }
            degraded.append(Degraded(claim: claim, to: ancestor))
            var b = buckets[ancestor] ?? Slotted<Render>()
            b.append.append(claim)
            buckets[ancestor] = b
        }

        var slotted = buckets
        for (path, winner) in boundaries {
            var entry = slotted[path] ?? Slotted<Render>()
            entry.replace = winner
            slotted[path] = entry
        }
        return ResolvedSlotsResult(slotted: slotted, suppressed: suppressed, degraded: degraded)
    }

    private static func survivingAncestor(_ path: String, paths: Set<String>) -> String? {
        var current = path
        while let dot = current.lastIndex(of: ".") {
            let ancestor = String(current[..<dot])
            if paths.contains(ancestor) { return ancestor }
            current = ancestor
        }
        return nil
    }

    // MARK: Plugin API (`src/plugin/api.tsx`)

    // parity: tui/src/plugin/api.tsx#Dispose [status=implemented hash=5b9f14922ae1]
    public typealias Dispose = @Sendable () async -> Void

    // parity: tui/src/plugin/api.tsx#SlotRender [status=adapted hash=cffb1e5a0953]
    public typealias SlotRender = @Sendable (any RenderContext, [String: JSONValue]) -> Renderable?

    // parity: tui/src/plugin/api.tsx#RegisteredSlot [status=implemented hash=c3ef58ca63fd]
    public struct RegisteredSlot: Sendable {
        public let placement: Placement
        public let render: SlotRender

        public init(placement: Placement, render: @escaping SlotRender) {
            self.placement = placement
            self.render = render
        }
    }

    public struct RegisteredRoute: Sendable {
        public let name: String
        public let render: @Sendable (any RenderContext, [String: JSONValue]) -> Renderable

        public init(name: String, render: @escaping @Sendable (any RenderContext, [String: JSONValue]) -> Renderable) {
            self.name = name
            self.render = render
        }
    }

    // parity: tui/src/plugin/api.tsx#Registry [status=adapted hash=c693fdee1109]
    public final class Registry: Sendable {
        private struct State: Sendable {
            var active: Bool = true
            var routes: [String: RegisteredRoute] = [:]
            var slots: [(key: String, slot: RegisteredSlot)] = []
            var markdown: [String: @Sendable (String) -> String] = [:]
        }

        private let state = Mutex(State())

        public init() {}

        public func isActive() -> Bool { state.withLock { $0.active } }
        public func setActive(_ active: Bool) { state.withLock { $0.active = active } }

        public func hasRoute(_ name: String) -> Bool { state.withLock { $0.routes[name] != nil } }
        public func setRoute(_ name: String, route: RegisteredRoute) { state.withLock { $0.routes[name] = route } }
        public func removeRoute(_ name: String) { state.withLock { _ = $0.routes.removeValue(forKey: name) } }
        public func route(_ name: String) -> RegisteredRoute? { state.withLock { $0.routes[name] } }

        public func setSlot(_ key: String, slot: RegisteredSlot) {
            state.withLock { s in
                if let idx = s.slots.firstIndex(where: { $0.key == key }) {
                    s.slots[idx] = (key, slot)
                } else {
                    s.slots.append((key, slot))
                }
            }
        }
        public func removeSlot(_ key: String) { state.withLock { $0.slots.removeAll { $0.key == key } } }
        public func allSlots() -> [(key: String, slot: RegisteredSlot)] { state.withLock { $0.slots } }

        public func hasMarkdown(_ lang: String) -> Bool { state.withLock { $0.markdown[lang] != nil } }
        public func setMarkdown(_ lang: String, render: @escaping @Sendable (String) -> String) {
            state.withLock { $0.markdown[lang] = render }
        }
        public func removeMarkdown(_ lang: String) { state.withLock { _ = $0.markdown.removeValue(forKey: lang) } }
        public func markdownRenderers() -> [String: @Sendable (String) -> String] { state.withLock { $0.markdown } }

        public func clearAll() {
            state.withLock { s in
                s.routes.removeAll()
                s.slots.removeAll()
                s.markdown.removeAll()
            }
        }
    }

    public struct HostServices: Sendable {
        public let version: String
        public let channel: String
        public let homeDirectory: String
        public let theme: @Sendable () -> ResolvedTheme
        public let themeMode: @Sendable () -> Mode
        public let dialog: TUIPrimitive.DialogContext
        public let toast: TUIPrimitive.ToastContext

        public init(
            version: String = "2.0.0",
            channel: String = "dev",
            homeDirectory: String = NSHomeDirectory(),
            theme: @escaping @Sendable () -> ResolvedTheme = {
                (try? resolveThemeDocument(ThemeDefaults.opencode, mode: .dark))!
            },
            themeMode: @escaping @Sendable () -> Mode = { .dark },
            dialog: TUIPrimitive.DialogContext = TUIPrimitive.DialogContext(),
            toast: TUIPrimitive.ToastContext = TUIPrimitive.ToastContext()
        ) {
            self.version = version
            self.channel = channel
            self.homeDirectory = homeDirectory
            self.theme = theme
            self.themeMode = themeMode
            self.dialog = dialog
            self.toast = toast
        }
    }

    // parity: tui/src/plugin/api.tsx#usePluginHost [status=adapted hash=d7773c6484eb]
    public static func usePluginHost(services: HostServices = HostServices()) -> HostServices {
        services
    }

    public struct PluginDialogAPI: Sendable {
        public let show: @Sendable (@escaping @Sendable (any RenderContext) -> BoxRenderable, (@Sendable () -> Void)?) -> Void
        public let set: @Sendable (TUIPrimitive.DialogSize, Bool) -> Void
        public let clear: @Sendable () -> Void
        public let alert: @Sendable (String, String, (@Sendable () -> Void)?) -> Void
        public let confirm: @Sendable (String, String, (@Sendable (Bool?) -> Void)?) -> Void
        public let prompt: @Sendable (String, String?, String?, (@Sendable (String?) -> Void)?) -> Void

        public init(
            show: @escaping @Sendable (@escaping @Sendable (any RenderContext) -> BoxRenderable, (@Sendable () -> Void)?) -> Void,
            set: @escaping @Sendable (TUIPrimitive.DialogSize, Bool) -> Void,
            clear: @escaping @Sendable () -> Void,
            alert: @escaping @Sendable (String, String, (@Sendable () -> Void)?) -> Void,
            confirm: @escaping @Sendable (String, String, (@Sendable (Bool?) -> Void)?) -> Void,
            prompt: @escaping @Sendable (String, String?, String?, (@Sendable (String?) -> Void)?) -> Void
        ) {
            self.show = show
            self.set = set
            self.clear = clear
            self.alert = alert
            self.confirm = confirm
            self.prompt = prompt
        }
    }

    // parity: tui/src/plugin/api.tsx#createDialogApi [status=adapted hash=2408fad1f4bb]
    public static func createDialogApi(
        dialog: TUIPrimitive.DialogContext,
        theme: @escaping @Sendable () -> ResolvedTheme
    ) -> PluginDialogAPI {
        PluginDialogAPI(
            show: { render, onClose in
                dialog.replace(onClose: onClose, render: render)
            },
            set: { size, centered in
                dialog.setSize(size)
                dialog.setCentered(centered)
            },
            clear: { dialog.clear() },
            alert: { title, message, done in
                let settled = Mutex(false)
                let finish: @Sendable () -> Void = {
                    if settled.withLock({ let p = $0; $0 = true; return !p }) { done?() }
                }
                dialog.replace(onClose: finish) { ctx in
                    TUIPrimitive.DialogAlert(
                        ctx: ctx,
                        props: TUIPrimitive.DialogAlertProps(title: title, message: message, onConfirm: finish),
                        dialog: dialog,
                        theme: theme()
                    )
                }
            },
            confirm: { title, message, done in
                let settled = Mutex(false)
                let finish: @Sendable (Bool?) -> Void = { val in
                    if settled.withLock({ let p = $0; $0 = true; return !p }) { done?(val) }
                }
                dialog.replace(onClose: { finish(nil) }) { ctx in
                    TUIPrimitive.DialogConfirm(
                        ctx: ctx,
                        props: TUIPrimitive.DialogConfirmProps(
                            title: title,
                            message: message,
                            onConfirm: { finish(true) },
                            onCancel: { finish(false) }
                        ),
                        dialog: dialog,
                        theme: theme()
                    )
                }
            },
            prompt: { title, placeholder, value, done in
                let settled = Mutex(false)
                let finish: @Sendable (String?) -> Void = { val in
                    if settled.withLock({ let p = $0; $0 = true; return !p }) { done?(val) }
                }
                dialog.replace(onClose: { finish(nil) }) { ctx in
                    TUIPrimitive.DialogPrompt(
                        ctx: ctx,
                        props: TUIPrimitive.DialogPromptProps(
                            title: title,
                            placeholder: placeholder ?? "Enter text",
                            value: value ?? "",
                            onConfirm: { text in
                                finish(text)
                                dialog.clear()
                            },
                            onCancel: { finish(nil) }
                        ),
                        dialog: dialog,
                        theme: theme()
                    )
                }
            }
        )
    }

    public final class PluginRuntimeContext: Sendable {
        public let id: String
        public let options: [String: JSONValue]
        public let host: HostServices
        public let dialog: PluginDialogAPI
        public let registry: Registry
        private let claimCounter: Mutex<Int>

        public init(id: String, options: [String: JSONValue], host: HostServices, registry: Registry) {
            self.id = id
            self.options = options
            self.host = host
            self.dialog = createDialogApi(dialog: host.dialog, theme: host.theme)
            self.registry = registry
            self.claimCounter = Mutex(0)
        }

        public func formatPath(_ value: String) -> String {
            TUIUtil.abbreviateHome(value, home: host.homeDirectory)
        }

        @discardableResult
        public func registerRoute(_ route: RegisteredRoute) throws -> @Sendable () -> Void {
            if registry.hasRoute(route.name) {
                throw ThemeError("Route already registered: \(route.name)")
            }
            registry.setRoute(route.name, route: route)
            let reg = registry
            let name = route.name
            return { if reg.isActive() { reg.removeRoute(name) } }
        }

        @discardableResult
        public func registerSlot(placement: Placement, render: @escaping SlotRender) -> @Sendable () -> Void {
            let key = claimCounter.withLock { c -> String in
                let k = "slot#\(c)"
                c += 1
                return k
            }
            registry.setSlot(key, slot: RegisteredSlot(placement: placement, render: render))
            let reg = registry
            return { if reg.isActive() { reg.removeSlot(key) } }
        }

        @discardableResult
        public func registerCodeBlockRenderer(
            language: String,
            render: @escaping @Sendable (String) -> String
        ) throws -> @Sendable () -> Void {
            let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw ThemeError("Markdown code-block language is required")
            }
            if registry.hasMarkdown(trimmed) {
                throw ThemeError("Markdown code-block renderer already registered: \(trimmed)")
            }
            registry.setMarkdown(trimmed, render: render)
            let reg = registry
            return { if reg.isActive() { reg.removeMarkdown(trimmed) } }
        }
    }

    // parity: tui/src/plugin/api.tsx#createPluginContext [status=adapted hash=c215e62e12c9]
    public static func createPluginContext(
        host: HostServices,
        id: String,
        options: [String: JSONValue] = [:],
        registry: Registry = Registry()
    ) -> PluginRuntimeContext {
        PluginRuntimeContext(id: id, options: options, host: host, registry: registry)
    }

    /// Isolates plugin render errors so one crashing plugin surfaces a single error toast instead of crashing the TUI.
    // parity: tui/src/plugin/api.tsx#PluginBoundary [status=adapted hash=989abc850004]
    public static func PluginBoundary(
        id: String,
        where location: String,
        toast: TUIPrimitive.ToastContext,
        onCrash: (@Sendable () -> Void)? = nil,
        body: () throws -> Renderable?
    ) -> Renderable? {
        do {
            return try body()
        } catch {
            toast.show(
                TUIPrimitive.ToastOptions(
                    title: "Plugin",
                    message: "\(id) crashed in \(location): \(TUIUtil.errorMessage(error))",
                    variant: .error
                )
            )
            onCrash?()
            return nil
        }
    }

    // MARK: Builtins Registry (`src/plugin/builtins.ts`)

    public struct BuiltinPluginDescriptor: Equatable, Hashable, Sendable {
        public let id: String
        public let defaultSlots: [String]
        public let routeName: String?

        public init(id: String, defaultSlots: [String] = [], routeName: String? = nil) {
            self.id = id
            self.defaultSlots = defaultSlots
            self.routeName = routeName
        }
    }

    /// Built-in TUI feature plugins matching `src/plugin/builtins.ts#builtins`.
    // parity: tui/src/plugin/builtins.ts#builtins [status=implemented hash=48988eb0bbc2]
    public static let builtins: [BuiltinPluginDescriptor] = [
        BuiltinPluginDescriptor(id: "opencode.home.footer", defaultSlots: ["home.footer"]),
        BuiltinPluginDescriptor(id: "opencode.prompt.footer", defaultSlots: ["prompt.footer"]),
        BuiltinPluginDescriptor(id: "opencode.btw", defaultSlots: ["prompt.footer.status", "app"]),
        BuiltinPluginDescriptor(id: "opencode.sidebar.context", defaultSlots: ["sidebar.content"]),
        BuiltinPluginDescriptor(id: "opencode.sidebar.limit", defaultSlots: ["sidebar.content"]),
        BuiltinPluginDescriptor(id: "opencode.sidebar.mcp", defaultSlots: ["sidebar.content"]),
        BuiltinPluginDescriptor(id: "opencode.sidebar.todo", defaultSlots: ["sidebar.content"]),
        BuiltinPluginDescriptor(id: "opencode.sidebar.footer", defaultSlots: ["sidebar.footer"]),
        BuiltinPluginDescriptor(id: "opencode.notifications", defaultSlots: ["app"]),
        BuiltinPluginDescriptor(id: "opencode.plugins", defaultSlots: ["app"]),
        BuiltinPluginDescriptor(id: "opencode.stats", defaultSlots: ["app"], routeName: "stats"),
        BuiltinPluginDescriptor(id: "opencode.merman", defaultSlots: []),
        BuiltinPluginDescriptor(id: "opencode.latex", defaultSlots: []),
        BuiltinPluginDescriptor(id: "opencode.diff-viewer", defaultSlots: ["app"], routeName: "diff"),
    ]

    // MARK: Plugin Discovery (`src/plugin/discovery.ts`)

    // parity: tui/src/plugin/discovery.ts#localSource [status=implemented hash=f75672fe177b]
    public static func localSource(_ spec: String, directory: String) -> URL? {
        if spec.hasPrefix("file://") {
            return URL(string: spec)
        }
        let isWindowsAbs: Bool = {
            if spec.hasPrefix("\\\\") { return true }
            let chars = Array(spec)
            guard chars.count >= 3 else { return false }
            return chars[0].isLetter && chars[1] == ":" && (chars[2] == "/" || chars[2] == "\\")
        }()
        if spec.hasPrefix("/") || isWindowsAbs {
            return URL(fileURLWithPath: spec).standardized
        }
        if spec.hasPrefix("./") || spec.hasPrefix("../") || spec.hasPrefix(".\\") || spec.hasPrefix("..\\") {
            return URL(fileURLWithPath: directory).appendingPathComponent(spec).standardized
        }
        return nil
    }

    // parity: tui/src/plugin/discovery.ts#localPluginDirectories [status=implemented hash=8d5571ee6478]
    public static func localPluginDirectories(cwd: String, configDirectory: String) async throws -> [String] {
        let projectDir = try await TUIUtil.localProjectDirectory(cwd)
        let projectConfig = URL(fileURLWithPath: projectDir).appendingPathComponent(".opencode").path
        let candidates = [configDirectory] + TUIUtil.projectConfigDirectories(project: projectDir, cwd: cwd)
        let fm = FileManager.default
        var results: [String] = []
        for dir in candidates {
            if dir == configDirectory || dir == projectConfig {
                results.append(URL(fileURLWithPath: dir).appendingPathComponent("plugins").path)
                continue
            }
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue {
                results.append(URL(fileURLWithPath: dir).appendingPathComponent("plugins").path)
            }
        }
        return results
    }

    // parity: tui/src/plugin/discovery.ts#discoverPluginTargets [status=implemented hash=22bcf015a982]
    public static func discoverPluginTargets(directories: [String]) async throws -> [String] {
        let fm = FileManager.default
        var discovered: [String] = []
        for dir in directories {
            guard fm.fileExists(atPath: dir) else { continue }
            let entries = try fm.contentsOfDirectory(atPath: dir).sorted()
            for name in entries {
                let fullPath = URL(fileURLWithPath: dir).appendingPathComponent(name).path
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue {
                    discovered.append(fullPath)
                }
            }
        }
        return discovered
    }

    public struct PluginTargetEntry: Equatable, Hashable, Sendable {
        public let spec: String
        public let install: Bool
        public let optional: Bool

        public init(spec: String, install: Bool = true, optional: Bool = true) {
            self.spec = spec
            self.install = install
            self.optional = optional
        }
    }

    // parity: tui/src/plugin/discovery.ts#mergePluginTargets [status=implemented hash=46fc162fae8e]
    public static func mergePluginTargets(_ targets: [PluginTargetEntry], directory: String) -> [PluginTargetEntry] {
        var order: [String] = []
        var map: [String: PluginTargetEntry] = [:]
        for target in targets {
            let key = localSource(target.spec, directory: directory)?.absoluteString ?? target.spec
            if map[key] == nil { order.append(key) }
            map[key] = target
        }
        return order.compactMap { map[$0] }
    }

    // MARK: Markdown Code-Block Renderer (`src/plugin/markdown.ts`)

    // parity: tui/src/plugin/markdown.ts#createMarkdownRenderer [status=adapted hash=13fad3cda053]
    public static func createMarkdownRenderer(
        sources: () -> [[String: @Sendable (String) -> String]]
    ) -> (@Sendable (String, String) -> String?)? {
        var merged: [String: @Sendable (String) -> String] = [:]
        for source in sources() {
            for (lang, fn) in source { merged[lang.lowercased()] = fn }
        }
        guard !merged.isEmpty else { return nil }
        let table = merged
        return { lang, code in
            table[lang.lowercased()]?(code)
        }
    }

    // MARK: Plugin Context, Provider, Render & Source Watcher (`src/plugin/context.tsx`, `render.tsx`, `watch.ts`)

    // parity: tui/src/plugin/context.tsx#PackageSource [status=adapted hash=095696de73ff]
    public protocol PackageSource: Sendable {
        func prepare(spec: String, install: Bool) async throws -> String
    }

    public struct PluginStatusEntry: Equatable, Hashable, Sendable {
        public let target: String
        public let id: String?
        public let status: String
        public let error: String?

        public init(target: String, id: String? = nil, status: String, error: String? = nil) {
            self.target = target
            self.id = id
            self.status = status
            self.error = error
        }
    }

    public struct RegisteredPluginSummary: Equatable, Hashable, Sendable {
        public let id: String
        public let source: String
        public let active: Bool

        public init(id: String, source: String, active: Bool) {
            self.id = id
            self.source = source
            self.active = active
        }
    }

    /// Host plugin manager coordinating registrations, activation/deactivation, slot mounts, and routes.
    public final class PluginManager: Sendable {
        private struct State: Sendable {
            var ready: Bool = false
            var states: [PluginStatusEntry] = []
            var registries: [(id: String, source: String, registry: Registry)] = []
            var mountedSlots: [String: Int] = [:]
        }

        private let state = Mutex(State())

        public init(loadBuiltins: Bool = true) {
            if loadBuiltins {
                state.withLock { s in
                    for builtin in builtins {
                        let reg = Registry()
                        reg.setActive(true)
                        s.registries.append((builtin.id, "builtin", reg))
                    }
                    s.ready = true
                }
            }
        }

        public var ready: Bool { state.withLock { $0.ready } }
        public var list: [PluginStatusEntry] { state.withLock { $0.states } }

        public var registered: [RegisteredPluginSummary] {
            state.withLock { s in
                s.registries.map { RegisteredPluginSummary(id: $0.id, source: $0.source, active: $0.registry.isActive()) }
            }
        }

        public func register(id: String, source: String = "external", registry: Registry = Registry()) {
            state.withLock { s in
                if let idx = s.registries.firstIndex(where: { $0.id == id }) {
                    s.registries[idx] = (id, source, registry)
                } else {
                    s.registries.append((id, source, registry))
                }
            }
        }

        @discardableResult
        public func activate(_ id: String) -> Bool {
            state.withLock { s in
                guard let entry = s.registries.first(where: { $0.id == id }) else { return false }
                entry.registry.setActive(true)
                return true
            }
        }

        @discardableResult
        public func deactivate(_ id: String) -> Bool {
            state.withLock { s in
                guard let entry = s.registries.first(where: { $0.id == id }) else { return false }
                entry.registry.setActive(false)
                return true
            }
        }

        public func route(id: String, name: String) -> RegisteredRoute? {
            state.withLock { s in
                guard let entry = s.registries.first(where: { $0.id == id }), entry.registry.isActive() else {
                    return nil
                }
                return entry.registry.route(name)
            }
        }

        public func mountSlot(_ path: String) -> @Sendable () -> Void {
            state.withLock { s in s.mountedSlots[path, default: 0] += 1 }
            return { [weak self] in
                self?.state.withLock { s in
                    let count = s.mountedSlots[path] ?? 0
                    if count > 1 { s.mountedSlots[path] = count - 1 } else { s.mountedSlots.removeValue(forKey: path) }
                }
            }
        }

        public func resolvedSlots() -> ResolvedSlotsResult<SlotRender> {
            let (paths, claims) = state.withLock { s -> (Set<String>, [Claim<SlotRender>]) in
                let p = Set(s.mountedSlots.keys)
                var c: [Claim<SlotRender>] = []
                for entry in s.registries where entry.registry.isActive() {
                    for (key, slot) in entry.registry.allSlots() {
                        c.append(Claim(key: "\(entry.id)/\(key)", plugin: entry.id, placement: slot.placement, render: slot.render))
                    }
                }
                return (p, c)
            }
            return resolveSlots(paths: paths, claims: claims)
        }
    }

    private static let activePluginManager = Mutex<PluginManager?>(nil)

    // parity: tui/src/plugin/context.tsx#PluginProvider [status=adapted hash=49931923899b]
    public static func PluginProvider(
        manager: PluginManager = PluginManager(),
        body: (PluginManager) -> Renderable
    ) -> Renderable {
        activePluginManager.withLock { $0 = manager }
        return body(manager)
    }

    // parity: tui/src/plugin/context.tsx#usePlugin [status=adapted hash=75526233fc1a]
    public static func usePlugin() -> PluginManager {
        if let existing = activePluginManager.withLock({ $0 }) { return existing }
        let created = PluginManager()
        activePluginManager.withLock { $0 = created }
        return created
    }

    // parity: tui/src/plugin/render.tsx#PluginRoute [status=adapted hash=77f0e8f4a476]
    public static func PluginRoute(
        ctx: any RenderContext,
        manager: PluginManager,
        id: String,
        name: String,
        data: [String: JSONValue] = [:],
        toast: TUIPrimitive.ToastContext,
        fallback: (String, String) -> Renderable
    ) -> Renderable {
        if let route = manager.route(id: id, name: name) {
            return PluginBoundary(id: id, where: "route", toast: toast) {
                route.render(ctx, data)
            } ?? fallback(id, name)
        }
        return fallback(id, name)
    }

    // parity: tui/src/plugin/render.tsx#Slot [status=adapted hash=f8c082d2b823]
    public static func Slot(
        ctx: any RenderContext,
        manager: PluginManager,
        path: String,
        parentPath: String? = nil,
        input: [String: JSONValue] = [:],
        toast: TUIPrimitive.ToastContext,
        hostChildren: [Renderable] = []
    ) throws -> BoxRenderable {
        if let parentPath, !contains(ancestor: parentPath, path: path) {
            throw ThemeError("Slot \"\(path)\" is mounted inside \"\(parentPath)\" but its path does not extend it")
        }
        let _ = manager.mountSlot(path)
        let resolved = manager.resolvedSlots().slotted[path] ?? emptySlotted()
        let container = BoxRenderable(ctx: ctx, options: BoxOptions(id: "slot-\(path)", flexDirection: .column))
        func renderClaim(_ claim: Claim<SlotRender>) {
            if let child = PluginBoundary(id: claim.plugin, where: "slot \(path)", toast: toast, body: { claim.render(ctx, input) }) {
                container.add(child)
            }
        }
        for claim in resolved.before { renderClaim(claim) }
        if let replacement = resolved.replace {
            renderClaim(replacement)
        } else {
            for claim in resolved.prepend { renderClaim(claim) }
            for child in hostChildren { container.add(child) }
            for claim in resolved.append { renderClaim(claim) }
        }
        for claim in resolved.after { renderClaim(claim) }
        return container
    }

    public final class SourceWatcherHandle: Sendable {
        private struct State: Sendable {
            var watched: Set<String> = []
            var missing: Set<String> = []
            var disposed: Bool = false
        }

        private let onChange: @Sendable () -> Void
        private let state = Mutex(State())

        public init(onChange: @escaping @Sendable () -> Void) {
            self.onChange = onChange
        }

        public func add(_ target: String) { arm(target, retry: false) }
        public func wait(_ target: String) { arm(target, retry: true) }

        public func arm(_ target: String, retry: Bool) {
            let fm = FileManager.default
            let exists = fm.fileExists(atPath: target)
            let appeared = state.withLock { s -> Bool in
                guard !s.disposed else { return false }
                if exists {
                    let wasMissing = s.missing.remove(target) != nil
                    s.watched.insert(target)
                    return wasMissing
                } else if retry {
                    s.missing.insert(target)
                }
                return false
            }
            if appeared { onChange() }
        }

        public func triggerChange() {
            let active = state.withLock { !$0.disposed }
            if active { onChange() }
        }

        public func dispose() {
            state.withLock { s in
                s.disposed = true
                s.watched.removeAll()
                s.missing.removeAll()
            }
        }

        public var watchedTargets: Set<String> { state.withLock { $0.watched } }
        public var missingTargets: Set<String> { state.withLock { $0.missing } }
    }

    // parity: tui/src/plugin/watch.ts#createSourceWatcher [status=adapted hash=7c5b7c299c6b]
    public static func createSourceWatcher(onChange: @escaping @Sendable () -> Void) -> SourceWatcherHandle {
        SourceWatcherHandle(onChange: onChange)
    }
}

// MARK: - TUIFeaturePlugin (`packages/tui/src/feature-plugins/*`, 28 files / 47 symbols)

/// Built-in TUI feature plugins: home footer, prompt footer/btw/goal, sidebar widgets,
/// diff viewer + file tree + image preview, plugins manager dialog, stats poster, and storybook catalog.
public enum TUIFeaturePlugin {

    // MARK: Home Footer (`src/feature-plugins/home/footer.tsx`)

    public struct HomeFooterVisibility: Equatable, Hashable, Sendable {
        public let mcpCommand: Bool
        public let pluginCommand: Bool
        public let version: Bool

        public init(mcpCommand: Bool, pluginCommand: Bool, version: Bool) {
            self.mcpCommand = mcpCommand
            self.pluginCommand = pluginCommand
            self.version = version
        }
    }

    // parity: tui/src/feature-plugins/home/footer.tsx#homeFooterVisibility [status=implemented hash=d1fd0c10b3ed]
    public static func homeFooterVisibility(width: Int) -> HomeFooterVisibility {
        HomeFooterVisibility(
            mcpCommand: width >= 64,
            pluginCommand: width >= 80,
            version: width >= 64
        )
    }

    // MARK: Prompt BTW, Footer & Goal (`src/feature-plugins/prompt/*`)

    /// The `/btw` answer dialog. The answer is concealed Markdown with grid tables on the raised overlay; `markdown`
    /// is the plugin block renderer (upstream `renderBlock={props.markdown()}`, e.g. Mermaid and LaTeX fences).
    // parity: tui/src/feature-plugins/prompt/btw.tsx#Answer [status=adapted hash=d53a152ebe45]
    public static func Answer(
        ctx: any RenderContext,
        question: String,
        answer: String,
        copied: Bool = false,
        theme: ResolvedTheme,
        syntax: SyntaxStyle? = nil,
        markdown: MarkdownRenderBlockCallback? = nil,
        onCopy: (@Sendable () -> Void)? = nil,
        onClose: (@Sendable () -> Void)? = nil
    ) -> BoxRenderable {
        let surface = theme.surface(.dialog)
        let body = BoxRenderable(ctx: ctx, options: BoxOptions(width: .percent(100), flexDirection: .column, gap: .point(1)))
        body.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string(question), fg: .rgba(surface.text.muted), wrapMode: .word)))
        body.add(MarkdownRenderable(ctx: ctx, options: MarkdownOptions(
            content: answer,
            syntaxStyle: syntax ?? generateSyntax(theme),
            fg: .rgba(surface.markdown.text),
            bg: .rgba(surface.background.raised.high),
            conceal: true,
            tableOptions: MarkdownTableOptions(style: .grid, cellPaddingX: 1),
            renderBlock: markdown
        )))
        return TUIPrimitive.DialogLayout(
            ctx: ctx,
            id: "btw-answer",
            header: TUIPrimitive.DialogHeader(ctx: ctx, title: "/btw", theme: theme, onClose: onClose),
            body: body,
            footer: TUIPrimitive.DialogFooter(
                ctx: ctx,
                props: TUIPrimitive.DialogFooterProps(
                    actions: TUIPrimitive.DialogFooterActions(
                        primary: [
                            copied
                                ? TUIPrimitive.DialogFooterAction(title: "copied", key: "✓", onTrigger: onCopy, color: surface.text.feedback.success.base)
                                : TUIPrimitive.DialogFooterAction(title: "copy", key: "c", onTrigger: onCopy),
                        ]
                    )
                ),
                theme: theme
            )
        )
    }

    /// `"3 subagents"`, or nil for none.
    private static func busyLabel(_ count: Int, _ noun: String) -> String? {
        count > 0 ? "\(count) \(noun)\(count == 1 ? "" : "s")" : nil
    }

    /// The live part of the prompt footer: what the session has running, in the picker's busy order (scripts,
    /// subagents, shells).
    public static func promptFooterLive(_ counts: TUIRoutes.BusyCounts) -> [String] {
        [busyLabel(counts.scripts, "script"), busyLabel(counts.subagents, "subagent"), busyLabel(counts.shells, "shell")]
            .compactMap { $0 }
    }

    /// The prompt footer. Clicking the live counts dispatches `session.child.first` through `onOpenChild` with the
    /// tab the picker should open on: the first busy one (``TUIRoutes/busyTab(_:)``).
    // parity: tui/src/feature-plugins/prompt/footer.tsx#PromptFooter [status=adapted hash=fb2d86185d4b]
    public static func PromptFooter(
        ctx: any RenderContext,
        usageText: String? = nil,
        costText: String? = nil,
        subagentCount: Int = 0,
        shellCount: Int = 0,
        scriptCount: Int = 0,
        commandShortcut: String? = "ctrl+p",
        childShortcut: String? = nil,
        theme: ResolvedTheme,
        onOpenChild: (@Sendable (String) -> Void)? = nil
    ) -> BoxRenderable {
        let row = BoxRenderable(ctx: ctx, options: BoxOptions(id: "prompt-footer", width: .percent(100), flexDirection: .row, justifyContent: .spaceBetween, gap: .point(2)))
        let counts = TUIRoutes.BusyCounts(scripts: scriptCount, subagents: subagentCount, shells: shellCount)
        let live = promptFooterLive(counts)
        let status = [usageText, costText].compactMap { $0 }.filter { !$0.isEmpty }
        let left = BoxRenderable(ctx: ctx, options: BoxOptions(minWidth: .point(0), flexShrink: 1, flexDirection: .row))
        if !live.isEmpty {
            let tab = TUIRoutes.busyTab(counts)
            let liveBox = BoxRenderable(ctx: ctx, options: BoxOptions(
                id: "prompt-footer-live",
                flexShrink: 0,
                flexDirection: .row,
                onMouseUp: { _ in onOpenChild?(tab) }
            ))
            if let childShortcut, !childShortcut.isEmpty {
                liveBox.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string("\(childShortcut) "), fg: .rgba(theme.text.base), wrapMode: TextWrapMode.none)))
            }
            liveBox.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string(live.joined(separator: " · ")), fg: .rgba(theme.text.muted), wrapMode: TextWrapMode.none)))
            left.add(liveBox)
        }
        if !status.isEmpty {
            let separator = live.isEmpty ? "" : " · "
            left.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string(separator + status.joined(separator: " · ")), fg: .rgba(theme.text.muted), wrapMode: TextWrapMode.none)))
        }
        row.add(left)
        if let commandShortcut, !commandShortcut.isEmpty {
            row.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string("\(commandShortcut) commands"), fg: .rgba(theme.text.muted), wrapMode: TextWrapMode.none)))
        }
        return row
    }

    public enum GoalStateStatus: String, Equatable, Hashable, Sendable {
        case active
        case paused
        case complete
    }

    public struct GoalState: Equatable, Hashable, Sendable {
        public let objective: String
        public let status: GoalStateStatus

        public init(objective: String, status: GoalStateStatus = .active) {
            self.objective = objective
            self.status = status
        }
    }

    public final class GoalController: Sendable {
        private let state = Mutex<GoalState?>(nil)

        public init(initial: GoalState? = nil) {
            state.withLock { $0 = initial }
        }

        public var current: GoalState? { state.withLock { $0 } }

        public func set(_ goal: GoalState?) {
            state.withLock { $0 = goal }
        }
    }

    // parity: tui/src/feature-plugins/prompt/goal.tsx#createGoal [status=adapted hash=fb5391293a62]
    public static func createGoal(initial: GoalState? = nil) -> GoalController {
        GoalController(initial: initial)
    }

    // parity: tui/src/feature-plugins/prompt/goal.tsx#GoalStatus [status=adapted hash=1bf7b768cc4d]
    public static func GoalStatus(
        ctx: any RenderContext,
        goal: GoalState?,
        hovered: Bool = false,
        theme: ResolvedTheme
    ) -> TextRenderable? {
        guard let goal else { return nil }
        let label: String
        let baseColor: RGBA
        switch goal.status {
        case .paused:
            label = "goal paused"
            baseColor = theme.text.feedback.warning.base
        case .complete:
            label = "goal met"
            baseColor = theme.text.feedback.success.base
        case .active:
            label = "goal"
            baseColor = theme.text.muted
        }
        return TextRenderable(
            ctx: ctx,
            options: TextOptions(
                id: "prompt-goal-status",
                content: .string("◎ \(label)"),
                fg: .rgba(hovered ? theme.text.base : baseColor),
                wrapMode: TextWrapMode.none
            )
        )
    }

    // MARK: Sidebar Widgets (`src/feature-plugins/sidebar/*`)

    // parity: tui/src/feature-plugins/sidebar/context.tsx#SidebarContext [status=adapted hash=3c28097e15bb]
    public static func SidebarContext(
        ctx: any RenderContext,
        usage: TUIUtil.ContextUsageSummary?,
        cost: Double = 0,
        theme: ResolvedTheme
    ) -> BoxRenderable? {
        guard usage != nil || cost > 0 else { return nil }
        let box = BoxRenderable(ctx: ctx, options: BoxOptions(id: "sidebar-context", flexDirection: .column))
        box.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string("Context"), fg: .rgba(theme.text.base), attributes: TextAttributes.bold)))
        if let usage {
            box.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string("\(usage.tokens) tokens"), fg: .rgba(theme.text.muted))))
            if let pct = usage.percent {
                box.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string("\(pct)% used"), fg: .rgba(theme.text.muted))))
            }
        }
        if cost > 0 {
            box.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string("\(TUIUtil.formatDollars(cost)) spent"), fg: .rgba(theme.text.muted))))
        }
        return box
    }

    // parity: tui/src/feature-plugins/sidebar/footer.tsx#SidebarOnboarding [status=adapted hash=2dec9cc2cf39]
    public static func SidebarOnboarding(
        ctx: any RenderContext,
        terminalHeight: Int,
        dismissed: Bool,
        hasConnectedProvider: Bool,
        theme: ResolvedTheme
    ) -> BoxRenderable? {
        guard terminalHeight >= 22, !dismissed, !hasConnectedProvider else { return nil }
        let box = BoxRenderable(
            ctx: ctx,
            options: BoxOptions(
                id: "sidebar.footer.getting-started",
                flexDirection: .column,
                paddingTop: .point(1),
                paddingRight: .point(2),
                paddingBottom: .point(1),
                paddingLeft: .point(2),
                gap: .point(1),
                backgroundColor: .rgba(theme.background.raised.high)
            )
        )
        box.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string("⬖ Getting started"), fg: .rgba(theme.text.base), attributes: TextAttributes.bold)))
        box.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string("OpenCode includes free models so you can start immediately."), fg: .rgba(theme.text.muted), wrapMode: .word)))
        box.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string("Connect provider /connect"), fg: .rgba(theme.text.base))))
        return box
    }

    // parity: tui/src/feature-plugins/sidebar/limit.tsx#SidebarLimit [status=adapted hash=63163f9f56dc]
    public static func SidebarLimit(
        ctx: any RenderContext,
        usage: TUIUtil.ModelUsage?,
        model: TUIUtil.LimitedModel?,
        theme: ResolvedTheme
    ) -> BoxRenderable? {
        guard let usage, let model else { return nil }
        let level = TUIUtil.usageLevel(usage, model: model)
        let danger = level == .out || level == .reached
        let box = BoxRenderable(ctx: ctx, options: BoxOptions(id: "sidebar-limit", flexDirection: .column))
        box.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string("Limit"), fg: .rgba(theme.text.base), attributes: TextAttributes.bold)))
        box.add(
            TextRenderable(
                ctx: ctx,
                options: TextOptions(
                    content: .string("\(TUIUtil.formatDollars(usage.left)) remaining"),
                    fg: .rgba(danger ? theme.text.feedback.error.base : theme.text.muted)
                )
            )
        )
        return box
    }

    public struct SidebarMcpServer: Equatable, Hashable, Sendable {
        public let name: String
        public let status: String

        public init(name: String, status: String) {
            self.name = name
            self.status = status
        }
    }

    // parity: tui/src/feature-plugins/sidebar/mcp.tsx#SidebarMcp [status=adapted hash=6a843b1247c7]
    public static func SidebarMcp(
        ctx: any RenderContext,
        servers: [SidebarMcpServer],
        open: Bool = true,
        theme: ResolvedTheme
    ) -> BoxRenderable? {
        guard !servers.isEmpty else { return nil }
        let box = BoxRenderable(ctx: ctx, options: BoxOptions(id: "sidebar-mcp", flexDirection: .column))
        let onCount = servers.filter { $0.status == "connected" }.count
        let badCount = servers.filter { $0.status == "failed" || $0.status == "needs_auth" }.count
        let prefix = servers.count > 2 ? (open ? "▼ " : "▶ ") : ""
        let collapsedSuffix = !open ? " (\(onCount) active\(badCount > 0 ? ", \(badCount) error\(badCount > 1 ? "s" : "")" : ""))" : ""
        box.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string("\(prefix)MCP\(collapsedSuffix)"), fg: .rgba(theme.text.base), attributes: TextAttributes.bold)))
        if servers.count <= 2 || open {
            for srv in servers {
                let statusLabel: String
                switch srv.status {
                case "connected": statusLabel = "Connected"
                case "pending": statusLabel = "Connecting"
                case "failed": statusLabel = "Error"
                case "disabled": statusLabel = "Disabled"
                case "needs_auth": statusLabel = "Sign in"
                default: statusLabel = srv.status
                }
                let fg = srv.status == "failed" ? theme.text.feedback.error.base : theme.text.muted
                box.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string("• \(srv.name) \(statusLabel)"), fg: .rgba(fg), wrapMode: TextWrapMode.none)))
            }
        }
        return box
    }

    // parity: tui/src/feature-plugins/sidebar/todo.tsx#SidebarTodo [status=adapted hash=9d264c0b8235]
    public static func SidebarTodo(
        ctx: any RenderContext,
        todos: [TUIUtil.Todo],
        open: Bool = true,
        theme: ResolvedTheme
    ) -> BoxRenderable? {
        guard !todos.isEmpty else { return nil }
        let remaining = todos.filter { $0.status == .pending || $0.status == .inProgress }.count
        let box = BoxRenderable(ctx: ctx, options: BoxOptions(id: "sidebar-todo", flexDirection: .column))
        let prefix = todos.count > 2 ? (open ? "▼ " : "▶ ") : ""
        let suffix = (todos.count > 2 && !open) ? " (\(remaining) remaining)" : ""
        box.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string("\(prefix)Todo\(suffix)"), fg: .rgba(theme.text.base), attributes: TextAttributes.bold)))
        if todos.count <= 2 || open {
            for item in todos {
                let marker = TUIUtil.todoMarker(item.status)
                let color: RGBA = item.status == .inProgress
                    ? theme.text.feedback.warning.base
                    : (item.status == .completed || item.status == .cancelled ? theme.text.muted : theme.text.base)
                box.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string("\(marker) \(item.content)"), fg: .rgba(color), wrapMode: .word)))
            }
        }
        return box
    }

    // MARK: Diff Viewer File Tree & Utilities (`src/feature-plugins/system/diff-viewer*`)

    public enum DiffFileStatus: String, Equatable, Hashable, Sendable, Codable {
        case added
        case deleted
        case modified
    }

    // parity: tui/src/feature-plugins/system/diff-viewer.tsx#DiffFile [status=implemented hash=a7a2341098e9]
    public struct DiffFile: Equatable, Hashable, Sendable, Codable {
        public let file: String
        public let patch: String?
        public let additions: Int
        public let deletions: Int
        public let status: DiffFileStatus

        public init(file: String, patch: String? = nil, additions: Int = 0, deletions: Int = 0, status: DiffFileStatus = .modified) {
            self.file = file
            self.patch = patch
            self.additions = additions
            self.deletions = deletions
            self.status = status
        }
    }

    // parity: tui/src/feature-plugins/system/diff-viewer-file-tree-utils.ts#FileTreeItem [status=implemented hash=55b38bc03670]
    public struct FileTreeItem: Equatable, Hashable, Sendable {
        public let file: String
        public let status: DiffFileStatus?

        public init(file: String, status: DiffFileStatus? = nil) {
            self.file = file
            self.status = status
        }
    }

    public enum FileTreeNodeKind: String, Equatable, Hashable, Sendable {
        case directory
        case file
    }

    // parity: tui/src/feature-plugins/system/diff-viewer-file-tree-utils.ts#FileTreeNode [status=implemented hash=587e77a5b608]
    public struct FileTreeNode: Equatable, Hashable, Sendable {
        public let id: Int
        public let name: String
        public let parent: Int?
        public var children: [Int]
        public let depth: Int
        public let kind: FileTreeNodeKind
        public let fileIndex: Int?

        public init(
            id: Int,
            name: String,
            parent: Int?,
            children: [Int] = [],
            depth: Int,
            kind: FileTreeNodeKind,
            fileIndex: Int? = nil
        ) {
            self.id = id
            self.name = name
            self.parent = parent
            self.children = children
            self.depth = depth
            self.kind = kind
            self.fileIndex = fileIndex
        }
    }

    // parity: tui/src/feature-plugins/system/diff-viewer-file-tree-utils.ts#FileTree [status=implemented hash=239744c3aa9c]
    public struct FileTree: Equatable, Hashable, Sendable {
        public var roots: [Int]
        public var nodes: [FileTreeNode]

        public init(roots: [Int] = [], nodes: [FileTreeNode] = []) {
            self.roots = roots
            self.nodes = nodes
        }
    }

    // parity: tui/src/feature-plugins/system/diff-viewer-file-tree-utils.ts#FileTreeRow [status=implemented hash=74230416e4b0]
    public struct FileTreeRow: Equatable, Hashable, Sendable {
        public let id: Int
        public let depth: Int
        public let kind: FileTreeNodeKind
        public let name: String
        public let fileIndex: Int?

        public init(id: Int, depth: Int, kind: FileTreeNodeKind, name: String, fileIndex: Int? = nil) {
            self.id = id
            self.depth = depth
            self.kind = kind
            self.name = name
            self.fileIndex = fileIndex
        }
    }

    // parity: tui/src/feature-plugins/system/diff-viewer-file-tree-utils.ts#buildFileTree [status=implemented hash=8923d7b12f41]
    public static func buildFileTree(_ files: [FileTreeItem]) -> FileTree {
        var roots: [Int] = []
        var nodes: [FileTreeNode] = []
        var dirByPath: [String: Int] = [:]

        func addNode(name: String, parent: Int?, depth: Int, kind: FileTreeNodeKind, fileIndex: Int? = nil) -> Int {
            let id = nodes.count
            nodes.append(FileTreeNode(id: id, name: name, parent: parent, children: [], depth: depth, kind: kind, fileIndex: fileIndex))
            if let parent {
                nodes[parent].children.append(id)
            } else {
                roots.append(id)
            }
            return id
        }

        for (fileIndex, file) in files.enumerated() {
            let segments = file.file.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard !segments.isEmpty else { continue }
            var parentID: Int? = nil
            var path = ""
            var depth = 0
            for seg in segments.dropLast() {
                path = path.isEmpty ? seg : "\(path)/\(seg)"
                if let existing = dirByPath[path] {
                    parentID = existing
                } else {
                    let id = addNode(name: seg, parent: parentID, depth: depth, kind: .directory)
                    dirByPath[path] = id
                    parentID = id
                }
                depth += 1
            }
            _ = addNode(name: segments.last!, parent: parentID, depth: depth, kind: .file, fileIndex: fileIndex)
        }

        var tree = FileTree(roots: roots, nodes: nodes)
        let rootSnapshot = tree
        tree.roots.sort { compareFileTreeNodes(rootSnapshot, left: $0, right: $1) < 0 }
        for i in 0..<tree.nodes.count {
            let snapshot = tree
            tree.nodes[i].children.sort { compareFileTreeNodes(snapshot, left: $0, right: $1) < 0 }
        }
        return tree
    }

    // parity: tui/src/feature-plugins/system/diff-viewer-file-tree-utils.ts#compareFileTreeNodes [status=implemented hash=8bc5aa5f6742]
    public static func compareFileTreeNodes(_ tree: FileTree, left: Int, right: Int) -> Int {
        let l = tree.nodes[left]
        let r = tree.nodes[right]
        if l.kind != r.kind { return l.kind == .directory ? -1 : 1 }
        if l.name < r.name { return -1 }
        if l.name > r.name { return 1 }
        return left - right
    }

    // parity: tui/src/feature-plugins/system/diff-viewer-file-tree-utils.ts#flattenFileTree [status=implemented hash=879b650ffa28]
    public static func flattenFileTree(_ tree: FileTree, expanded: Set<Int>? = nil) -> [FileTreeRow] {
        var rows: [FileTreeRow] = []
        func collapsedChain(_ id: Int) -> [FileTreeNode] {
            let node = tree.nodes[id]
            if node.children.count == 1 {
                let child = tree.nodes[node.children[0]]
                if child.kind == .directory {
                    return [node] + collapsedChain(child.id)
                }
            }
            return [node]
        }
        func visit(_ id: Int, depth: Int) {
            let node = tree.nodes[id]
            if node.kind == .file {
                rows.append(FileTreeRow(id: node.id, depth: depth, kind: .file, name: node.name, fileIndex: node.fileIndex))
                return
            }
            let chain = collapsedChain(node.id)
            let last = chain.last!
            rows.append(FileTreeRow(id: node.id, depth: depth, kind: .directory, name: chain.map(\.name).joined(separator: "/"), fileIndex: node.fileIndex))
            if expanded == nil || expanded!.contains(node.id) {
                for child in last.children { visit(child, depth: depth + 1) }
            }
        }
        for root in tree.roots { visit(root, depth: 0) }
        return rows
    }

    // parity: tui/src/feature-plugins/system/diff-viewer-file-tree-utils.ts#fileTreeFileSelection [status=implemented hash=20c79cf800c8]
    public static func fileTreeFileSelection(_ tree: FileTree, fileIndex: Int) -> Set<Int>? {
        guard let node = tree.nodes.first(where: { $0.kind == .file && $0.fileIndex == fileIndex }) else {
            return nil
        }
        var parents = Set<Int>()
        var parent = node.parent
        while let p = parent {
            parents.insert(p)
            parent = tree.nodes[p].parent
        }
        return parents
    }

    // parity: tui/src/feature-plugins/system/diff-viewer-file-tree-utils.ts#singlePatchFileIndex [status=implemented hash=5d7ad061756f]
    public static func singlePatchFileIndex(selected: Int?, current: Int?, first: Int?) -> Int? {
        selected ?? current ?? first
    }

    // parity: tui/src/feature-plugins/system/diff-viewer-file-tree-utils.ts#orderedPatchFileIndexes [status=implemented hash=8c37406444ab]
    public static func orderedPatchFileIndexes(_ rows: [FileTreeRow]) -> [Int] {
        rows.compactMap(\.fileIndex)
    }

    // parity: tui/src/feature-plugins/system/diff-viewer-file-tree-utils.ts#showDiffViewerFileTree [status=implemented hash=0aea51201c82]
    public static func showDiffViewerFileTree(_ showFileTree: Bool, fileCount: Int) -> Bool {
        showFileTree && fileCount > 0
    }

    // parity: tui/src/feature-plugins/system/diff-viewer-file-tree-utils.ts#movePatchFileIndex [status=implemented hash=be38c3b73c8f]
    public static func movePatchFileIndex(_ fileIndexes: [Int], current: Int?, offset: Int) -> Int? {
        guard !fileIndexes.isEmpty else { return nil }
        guard let current, let idx = fileIndexes.firstIndex(of: current) else { return fileIndexes[0] }
        return fileIndexes[max(0, min(fileIndexes.count - 1, idx + offset))]
    }

    // parity: tui/src/feature-plugins/system/diff-viewer-file-tree-utils.ts#allExpandedFileTreeDirectories [status=implemented hash=2857052e1028]
    public static func allExpandedFileTreeDirectories(_ tree: FileTree) -> Set<Int> {
        Set(tree.nodes.filter { $0.kind == .directory }.map(\.id))
    }

    // parity: tui/src/feature-plugins/system/diff-viewer-file-tree-utils.ts#toggleFileTreeDirectory [status=implemented hash=a340a988220a]
    public static func toggleFileTreeDirectory(_ tree: FileTree, expanded: Set<Int>, selected: Int?) -> Set<Int> {
        guard let selected, tree.nodes.indices.contains(selected), tree.nodes[selected].kind == .directory else {
            return expanded
        }
        var next = expanded
        if next.contains(selected) { next.remove(selected) } else { next.insert(selected) }
        return next
    }

    // parity: tui/src/feature-plugins/system/diff-viewer-file-menu.tsx#DiffFileMenu [status=adapted hash=7b58662ba782]
    public static func DiffFileMenu(
        ctx: any RenderContext,
        x: Int,
        y: Int,
        reviewed: Bool,
        terminalWidth: Int = 80,
        terminalHeight: Int = 24,
        theme: ResolvedTheme,
        onToggle: (@Sendable () -> Void)? = nil
    ) -> BoxRenderable {
        let label = reviewed ? "Mark incomplete" : "Mark complete"
        let width = min(19, terminalWidth)
        let menu = BoxRenderable(
            ctx: ctx,
            options: BoxOptions(
                id: "diff-file-menu",
                width: .point(Float(width)),
                height: .point(1),
                position: .absolute,
                top: .point(Float(max(0, min(y + 1, terminalHeight - 1)))),
                left: .point(Float(max(0, min(x, terminalWidth - width)))),
                paddingRight: .point(1),
                paddingLeft: .point(1),
                zIndex: 2600,
                onMouseUp: { _ in onToggle?() },
                backgroundColor: .rgba(theme.background.raised.high)
            )
        )
        menu.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string(label), fg: .rgba(theme.text.base), wrapMode: TextWrapMode.none, truncate: true)))
        return menu
    }

    // parity: tui/src/feature-plugins/system/diff-viewer-file-tree.tsx#DiffViewerFileTreeProps [status=implemented hash=da2b48e1632f]
    public struct DiffViewerFileTreeProps: Sendable {
        public let width: Int
        public let files: [FileTreeItem]
        public let loading: Bool
        public let errorMessage: String?
        public let layout: String
        public let selectedFileIndex: Int?
        public let reviewedFileNames: Set<String>
        public let expandedNodes: Set<Int>?
        public let source: String?

        public init(
            width: Int = 34,
            files: [FileTreeItem],
            loading: Bool = false,
            errorMessage: String? = nil,
            layout: String = "tree",
            selectedFileIndex: Int? = nil,
            reviewedFileNames: Set<String> = [],
            expandedNodes: Set<Int>? = nil,
            source: String? = nil
        ) {
            self.width = width
            self.files = files
            self.loading = loading
            self.errorMessage = errorMessage
            self.layout = layout
            self.selectedFileIndex = selectedFileIndex
            self.reviewedFileNames = reviewedFileNames
            self.expandedNodes = expandedNodes
            self.source = source
        }
    }

    // parity: tui/src/feature-plugins/system/diff-viewer-file-tree.tsx#DiffViewerFileTree [status=adapted hash=cdfcd8733dc5]
    public static func DiffViewerFileTree(
        ctx: any RenderContext,
        props: DiffViewerFileTreeProps,
        theme: ResolvedTheme
    ) -> BoxRenderable {
        let tree = buildFileTree(props.files)
        let rows = props.layout == "list"
            ? flattenFileTree(tree).filter { $0.fileIndex != nil }
            : flattenFileTree(tree, expanded: props.expandedNodes)
        let container = BoxRenderable(
            ctx: ctx,
            options: BoxOptions(
                id: "diff-viewer-file-tree",
                width: .point(Float(props.width)),
                flexDirection: .column,
                paddingRight: .point(2),
                paddingBottom: .point(1),
                paddingLeft: .point(2),
                backgroundColor: .rgba(theme.background.raised.base)
            )
        )
        if let source = props.source {
            container.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string(source), fg: .rgba(theme.text.base), attributes: TextAttributes.bold)))
        }
        for row in rows {
            let indent = String(repeating: "  ", count: row.depth)
            let isSelected = row.fileIndex != nil && row.fileIndex == props.selectedFileIndex
            let prefix = row.kind == .directory ? "▾ " : ""
            container.add(
                TextRenderable(
                    ctx: ctx,
                    options: TextOptions(
                        content: .string("\(indent)\(prefix)\(row.name)"),
                        fg: .rgba(isSelected ? theme.text.action.primary.focused : theme.text.base),
                        bg: isSelected ? .rgba(theme.background.action.primary.focused) : nil,
                        wrapMode: TextWrapMode.none,
                        truncate: true
                    )
                )
            )
        }
        return container
    }

    // parity: tui/src/feature-plugins/system/diff-viewer-image.tsx#isDiffImageFile [status=implemented hash=8fa90777b4ce]
    public static func isDiffImageFile(_ file: String) -> Bool {
        let lower = file.lowercased()
        return lower.hasSuffix(".png") || lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg")
            || lower.hasSuffix(".webp") || lower.hasSuffix(".gif")
    }

    // parity: tui/src/feature-plugins/system/diff-viewer-image.tsx#DiffViewerImage [status=adapted hash=033bb783b6b4]
    public static func DiffViewerImage(
        ctx: any RenderContext,
        file: String,
        label: String = "Working tree preview",
        dimensionsText: String? = nil,
        error: String? = nil,
        theme: ResolvedTheme
    ) -> BoxRenderable {
        let box = BoxRenderable(ctx: ctx, options: BoxOptions(id: "diff-image-\(file)", width: .percent(100), flexDirection: .column, gap: .point(1)))
        box.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string(label), fg: .rgba(theme.text.muted))))
        if let error {
            box.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string(error), fg: .rgba(theme.text.feedback.error.base))))
        } else if let dimensionsText {
            box.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string("\(file) (\(dimensionsText))"), fg: .rgba(theme.text.base))))
        } else {
            box.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string("Loading image…"), fg: .rgba(theme.text.muted))))
        }
        return box
    }

    // MARK: Plugins Manager Dialog (`src/feature-plugins/system/plugins.tsx`)

    // parity: tui/src/feature-plugins/system/plugins.tsx#PluginsDialog [status=adapted hash=ba4c113bc03a]
    public static func PluginsDialog(
        ctx: any RenderContext,
        manager: TUIPluginHost.PluginManager,
        showInternal: Bool = false,
        dialog: TUIPrimitive.DialogContext,
        theme: ResolvedTheme
    ) -> BoxRenderable {
        dialog.setSize(.large)
        let options: [TUIPrimitive.DialogSelectOption<String>] = manager.registered
            .filter { showInternal || $0.source != "builtin" }
            .sorted { $0.id < $1.id }
            .map { item in
                TUIPrimitive.DialogSelectOption(
                    title: item.id,
                    value: item.id,
                    description: item.source,
                    footer: item.active ? "active" : "inactive",
                    category: "TUI Plugins"
                )
            }
        return TUIPrimitive.DialogSelect(
            ctx: ctx,
            props: TUIPrimitive.DialogSelectProps(title: "Plugins", options: options),
            dialog: dialog,
            theme: theme
        )
    }

    // MARK: Stats Poster & Metrics (`src/feature-plugins/system/stats-data.ts`, `stats.tsx`)

    public struct StatsMetric: Equatable, Hashable, Sendable {
        public let label: String
        public let value: Int

        public init(label: String, value: Int) {
            self.label = label
            self.value = value
        }
    }

    public struct StatsPosterInput: Equatable, Sendable {
        public let tokens: Int
        public let streak: Int
        public let activeDays: Int
        public let sessions: Int
        public let activity: [ActivityDayInput]
        public let fromMs: Int64
        public let toMs: Int64

        public init(
            tokens: Int,
            streak: Int,
            activeDays: Int,
            sessions: Int,
            activity: [ActivityDayInput] = [],
            fromMs: Int64 = 0,
            toMs: Int64 = 0
        ) {
            self.tokens = tokens
            self.streak = streak
            self.activeDays = activeDays
            self.sessions = sessions
            self.activity = activity
            self.fromMs = fromMs
            self.toMs = toMs
        }
    }

    // parity: tui/src/feature-plugins/system/stats-data.ts#statsMetrics [status=implemented hash=3673a2adb52d]
    public static func statsMetrics(_ stats: StatsPosterInput) -> [StatsMetric] {
        [
            StatsMetric(label: "tokens", value: stats.tokens),
            StatsMetric(label: "best streak", value: stats.streak),
            StatsMetric(label: "active days", value: stats.activeDays),
            StatsMetric(label: "sessions", value: stats.sessions),
        ]
    }

    // parity: tui/src/feature-plugins/system/stats-data.ts#statsNumber [status=implemented hash=52d9f1b06f3f]
    public static func statsNumber(_ value: Int) -> String {
        let absVal = abs(Double(value))
        let sign = value < 0 ? "-" : ""
        if absVal >= 1_000_000_000_000 { return "\(sign)\(compactDecimal(absVal / 1_000_000_000_000))T" }
        if absVal >= 1_000_000_000 { return "\(sign)\(compactDecimal(absVal / 1_000_000_000))B" }
        if absVal >= 1_000_000 { return "\(sign)\(compactDecimal(absVal / 1_000_000))M" }
        if absVal >= 1_000 { return "\(sign)\(compactDecimal(absVal / 1_000))K" }
        return String(value)
    }

    private static func compactDecimal(_ value: Double) -> String {
        let rounded = (value * 10.0).rounded() / 10.0
        if rounded.rounded(.towardZero) == rounded {
            return String(Int64(rounded))
        }
        let whole = Int64(rounded)
        let frac = abs(Int(((rounded - Double(whole)) * 10.0).rounded())) % 10
        return "\(whole).\(frac)"
    }

    // parity: tui/src/feature-plugins/system/stats.tsx#StatsPoster [status=adapted hash=173d166dc292]
    public static func StatsPoster(
        ctx: any RenderContext,
        stats: StatsPosterInput,
        terminalWidth: Int = 80,
        theme: ResolvedTheme
    ) -> BoxRenderable {
        let width = max(12, min(110, terminalWidth - 8))
        let metrics = statsMetrics(stats)
        let cal = activityCalendar(
            ActivityCalendarInput(activity: stats.activity, from: stats.fromMs, to: stats.toMs, maxWeeks: max(1, (width - 4) / 2))
        )
        let poster = BoxRenderable(
            ctx: ctx,
            options: BoxOptions(id: "stats-poster", width: .point(Float(width)), flexDirection: .column, alignItems: .center, gap: .point(1))
        )
        poster.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string("opencode / stats"), fg: .rgba(theme.text.base), attributes: TextAttributes.bold)))
        poster.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string("\(statsNumber(metrics[0].value)) TOKENS"), fg: .rgba(theme.text.base), attributes: TextAttributes.bold)))
        let summaryLine = metrics.dropFirst().map { "\($0.label): \(statsNumber($0.value))" }.joined(separator: "  ")
        poster.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string(summaryLine), fg: .rgba(theme.text.muted))))
        if !cal.weeks.isEmpty {
            poster.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string("\(cal.weeks.count) weeks activity"), fg: .rgba(theme.text.muted))))
        }
        return poster
    }

    // MARK: Storybook Fixtures & Catalog (`src/feature-plugins/system/storybook/*`)

    // parity: tui/src/feature-plugins/system/storybook/footer.tsx#StoryFooterControl [status=implemented hash=f41d7ca5bfee]
    public struct StoryFooterControl: Equatable, Hashable, Sendable {
        public let shortcut: String
        public let label: String

        public init(shortcut: String, label: String) {
            self.shortcut = shortcut
            self.label = label
        }
    }

    // parity: tui/src/feature-plugins/system/storybook/footer.tsx#StoryFooter [status=adapted hash=5ba63d274935]
    public static func StoryFooter(
        ctx: any RenderContext,
        title: String,
        details: [String] = [],
        status: String? = nil,
        message: String? = nil,
        controls: [StoryFooterControl],
        theme: ResolvedTheme
    ) -> BoxRenderable {
        let footer = BoxRenderable(
            ctx: ctx,
            options: BoxOptions(id: "story-footer", width: .percent(100), flexDirection: .column, backgroundColor: .rgba(theme.background.raised.base))
        )
        let detailText = details.isEmpty ? title : "\(title) · \(details.joined(separator: " · "))"
        footer.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string(detailText), fg: .rgba(theme.text.base))))
        if status != nil || message != nil {
            let line = [status, message].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            footer.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string(line), fg: .rgba(theme.text.muted))))
        }
        let controlsLine = controls.map { "\($0.shortcut) \($0.label)" }.joined(separator: "  ")
        footer.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string(controlsLine), fg: .rgba(theme.text.base))))
        return footer
    }

    // parity: tui/src/feature-plugins/system/storybook/index.tsx#Story [status=implemented hash=30c67b007903]
    public struct Story: Sendable {
        public let id: String
        public let title: String
        public let render: @Sendable (any RenderContext, ResolvedTheme) -> BoxRenderable

        public init(id: String, title: String, render: @escaping @Sendable (any RenderContext, ResolvedTheme) -> BoxRenderable) {
            self.id = id
            self.title = title
            self.render = render
        }
    }

    // parity: tui/src/feature-plugins/system/storybook/one-cell-spinner.fixtures.ts#SpinnerFixture [status=implemented hash=c78cb82d8d19]
    public struct SpinnerFixture: Equatable, Hashable, Sendable {
        public let name: String
        public let description: String
        public let motion: TUIPrimitive.OneCellMotion
        public let launch: TUIPrimitive.OneCellMotion?

        public init(name: String, description: String, motion: TUIPrimitive.OneCellMotion, launch: TUIPrimitive.OneCellMotion? = nil) {
            self.name = name
            self.description = description
            self.motion = motion
            self.launch = launch
        }
    }

    // parity: tui/src/feature-plugins/system/storybook/subcell-spinner.fixtures.ts#SUBCELL_SPINNERS [status=implemented hash=68a25297647a]
    public static let SUBCELL_SPINNERS: [SpinnerFixture] = {
        let perimeter = [0, 1, 3, 5, 7, 6, 4, 2]
        func braille(_ mask: Int) -> String {
            let order = [0, 3, 1, 4, 2, 5, 6, 7]
            var dots = 0
            for (index, bit) in order.enumerated() {
                dots |= ((mask >> index) & 1) << bit
            }
            return String(UnicodeScalar(0x2800 + dots)!)
        }
        let cometMasks = perimeter.enumerated().map { idx, pt in
            (1 << pt) | (1 << perimeter[(idx + 7) % 8]) | (1 << perimeter[(idx + 6) % 8])
        }
        let orbitMasks = perimeter.enumerated().map { idx, pt in
            (1 << pt) | (1 << perimeter[(idx + 7) % 8])
        }
        let scanMasks = [0, 0, 1, 2, 3, 3, 2, 1].map { 3 << ($0 * 2) }
        var out: [SpinnerFixture] = []
        for (name, desc, interval, masks) in [
            ("comet", "Three pixels chase the edge.", 100.0, cometMasks),
            ("orbit", "Two pixels keep a steady orbit.", 140.0, orbitMasks),
            ("scan", "A row sweeps down, pauses, and returns.", 130.0, scanMasks),
        ] {
            out.append(SpinnerFixture(name: "block \(name)", description: "\(desc) 2x4 octants need a recent font.", motion: TUIPrimitive.OneCellMotion(frames: masks.map(TUIPrimitive.octantGlyph), interval: interval), launch: TUIPrimitive.SEED_LAUNCH))
            out.append(SpinnerFixture(name: "dot \(name)", description: "\(desc) 2x4 braille dots.", motion: TUIPrimitive.OneCellMotion(frames: masks.map(braille), interval: interval), launch: TUIPrimitive.SEED_LAUNCH))
        }
        out.append(SpinnerFixture(name: "block low comet", description: "The tail recedes before the head moves.", motion: TUIPrimitive.BLOCK_LOW_COMET, launch: TUIPrimitive.SEED_LAUNCH))
        out.append(SpinnerFixture(name: "block soft sweep", description: "A staggered wipe crosses the middle four.", motion: TUIPrimitive.BLOCK_SOFT_SWEEP, launch: TUIPrimitive.SEED_LAUNCH))
        out.append(SpinnerFixture(name: "block soft slide", description: "The middle bar softens before each sideways step.", motion: TUIPrimitive.BLOCK_SOFT_SLIDE, launch: TUIPrimitive.SEED_LAUNCH))
        return out
    }()

    // parity: tui/src/feature-plugins/system/storybook/one-cell-spinner.fixtures.ts#ONE_CELL_SPINNERS [status=implemented hash=8d8dde8b4bff]
    public static let ONE_CELL_SPINNERS: [SpinnerFixture] = [
        SpinnerFixture(name: "Small toggle", description: "A small square opens and closes in an even rhythm.", motion: TUIPrimitive.WORK_SPINNERS["small-toggle"]!),
        SpinnerFixture(name: "Square toggle", description: "A larger square opens and closes at a slower pace.", motion: TUIPrimitive.WORK_SPINNERS["square-toggle"]!),
        SpinnerFixture(name: "Grow / shrink", description: "An outline fills, grows, and returns to a seed.", motion: TUIPrimitive.WORK_SPINNERS["grow-shrink"]!),
        SpinnerFixture(name: "Quadrant orbit", description: "Four corners take their turn, clockwise.", motion: TUIPrimitive.WORK_SPINNERS["quadrant-orbit"]!),
        SpinnerFixture(name: "Crosshatch", description: "Diagonal threads cross, then change direction.", motion: TUIPrimitive.WORK_SPINNERS["crosshatch"]!),
        SpinnerFixture(name: "Density wave", description: "Grain gathers into a block, then thins.", motion: TUIPrimitive.WORK_SPINNERS["density-wave"]!),
        SpinnerFixture(name: "Seed handoff", description: "A spark lingers, then the breath grows quiet.", motion: TUIPrimitive.SEED_WORK, launch: TUIPrimitive.SEED_LAUNCH),
    ] + SUBCELL_SPINNERS

    // parity: tui/src/feature-plugins/system/storybook/highlights.tsx#highlightsStory [status=adapted hash=be8fb338d408]
    public static let highlightsStory = Story(id: "highlights", title: "Release highlights") { ctx, theme in
        StoryFooter(ctx: ctx, title: "storybook / release highlights", controls: [
            StoryFooterControl(shortcut: "o", label: "five highlights"),
            StoryFooterControl(shortcut: "t", label: "two highlights"),
            StoryFooterControl(shortcut: "esc", label: "back"),
        ], theme: theme)
    }

    // parity: tui/src/feature-plugins/system/storybook/link-clicks.tsx#linkClicksStory [status=adapted hash=5ea2f8a8db8d]
    public static let linkClicksStory = Story(id: "link-clicks", title: "Link clicks") { ctx, theme in
        StoryFooter(ctx: ctx, title: "storybook / Link clicks", details: ["48 cols", "rendered"], controls: [
            StoryFooterControl(shortcut: "w", label: "narrow/full width"),
            StoryFooterControl(shortcut: "m", label: "rendered/source"),
            StoryFooterControl(shortcut: "esc", label: "back"),
        ], theme: theme)
    }

    // parity: tui/src/feature-plugins/system/storybook/merman-layouts.tsx#mermanLayoutsStory [status=adapted hash=cf3d239e6d78]
    public static let mermanLayoutsStory = Story(id: "merman-layouts", title: "Merman layouts") { ctx, theme in
        StoryFooter(ctx: ctx, title: "storybook / Merman layouts", controls: [
            StoryFooterControl(shortcut: "←/→", label: "switch fixture"),
            StoryFooterControl(shortcut: "r", label: "reset"),
            StoryFooterControl(shortcut: "esc", label: "back"),
        ], theme: theme)
    }

    // parity: tui/src/feature-plugins/system/storybook/one-cell-spinner.tsx#oneCellSpinnerStory [status=adapted hash=b385ebb15199]
    public static let oneCellSpinnerStory = Story(id: "one-cell-spinner", title: "One-cell spinners") { ctx, theme in
        StoryFooter(ctx: ctx, title: "storybook / one-cell spinners", details: ["\(ONE_CELL_SPINNERS.count) presets"], controls: [
            StoryFooterControl(shortcut: "↑/↓", label: "select"),
            StoryFooterControl(shortcut: "s", label: "speed"),
            StoryFooterControl(shortcut: "esc", label: "back"),
        ], theme: theme)
    }

    // parity: tui/src/feature-plugins/system/storybook/session-location-missing.tsx#sessionLocationMissingStory [status=adapted hash=44184763c281]
    public static let sessionLocationMissingStory = Story(id: "session-location-missing", title: "Missing session directory") { ctx, theme in
        StoryFooter(ctx: ctx, title: "storybook / missing session directory", status: "Choose another directory to continue", controls: [
            StoryFooterControl(shortcut: "enter", label: "confirm"),
            StoryFooterControl(shortcut: "esc", label: "back"),
        ], theme: theme)
    }

    // parity: tui/src/feature-plugins/system/storybook/session-tabs.tsx#sessionTabsStory [status=adapted hash=27ba5cae600a]
    public static let sessionTabsStory = Story(id: "session-tabs", title: "Session tabs") { ctx, theme in
        StoryFooter(ctx: ctx, title: "storybook / session tabs", controls: [
            StoryFooterControl(shortcut: "v", label: "orientation"),
            StoryFooterControl(shortcut: "esc", label: "back"),
        ], theme: theme)
    }

    // parity: tui/src/feature-plugins/system/storybook/todo.tsx#todoStory [status=adapted hash=bc2c2f3c88f5]
    public static let todoStory = Story(id: "todo", title: "Todo sidebar") { ctx, theme in
        StoryFooter(ctx: ctx, title: "storybook / todo sidebar", message: "Hidden when there are no pending or in-progress todos", controls: [
            StoryFooterControl(shortcut: "↑↓", label: "select"),
            StoryFooterControl(shortcut: "s", label: "cycle status"),
            StoryFooterControl(shortcut: "esc", label: "back"),
        ], theme: theme)
    }

    public static let allStories: [Story] = [
        highlightsStory,
        linkClicksStory,
        mermanLayoutsStory,
        oneCellSpinnerStory,
        sessionLocationMissingStory,
        sessionTabsStory,
        todoStory,
    ]

    // MARK: - Diff Viewer Content (`src/feature-plugins/system/diff-viewer.tsx`)

    public enum DiffMode: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
        case turn
        case session
        case working
        case branch
    }

    public enum DiffView: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
        case unified
        case split
    }

    public struct DiffPreferences: Equatable, Hashable, Sendable, Codable {
        public var tree: Bool?
        public var single: Bool?
        public var view: String?
        public var fullscreen: Bool?

        public init(tree: Bool? = nil, single: Bool? = nil, view: String? = nil, fullscreen: Bool? = nil) {
            self.tree = tree
            self.single = single
            self.view = view
            self.fullscreen = fullscreen
        }
    }

    public struct DiffViewerContentProps: Sendable {
        public let files: [DiffFile]
        public let loading: Bool
        public let error: String?
        public let mode: DiffMode
        public let sources: [DiffMode]
        public let sourceDetail: String?
        public let unavailable: Bool
        public let width: Int
        public let docked: Bool
        public let selectedFileIndex: Int?
        public let preferences: DiffPreferences
        public let onClose: (@Sendable () -> Void)?
        public let onSwitchSource: (@Sendable (DiffMode) -> Void)?

        public init(
            files: [DiffFile],
            loading: Bool = false,
            error: String? = nil,
            mode: DiffMode = .working,
            sources: [DiffMode] = [.working, .branch],
            sourceDetail: String? = nil,
            unavailable: Bool = false,
            width: Int = 120,
            docked: Bool = false,
            selectedFileIndex: Int? = nil,
            preferences: DiffPreferences = DiffPreferences(),
            onClose: (@Sendable () -> Void)? = nil,
            onSwitchSource: (@Sendable (DiffMode) -> Void)? = nil
        ) {
            self.files = files
            self.loading = loading
            self.error = error
            self.mode = mode
            self.sources = sources
            self.sourceDetail = sourceDetail
            self.unavailable = unavailable
            self.width = width
            self.docked = docked
            self.selectedFileIndex = selectedFileIndex
            self.preferences = preferences
            self.onClose = onClose
            self.onSwitchSource = onSwitchSource
        }
    }

    /// Renders the full diff viewer layout (header, optional file tree sidebar, patch cards or image previews, and footer).
    // parity: tui/src/feature-plugins/system/diff-viewer.tsx#DiffViewerContent [status=adapted hash=c27d5a4f4bf8]
    public static func DiffViewerContent(
        ctx: any RenderContext,
        props: DiffViewerContentProps,
        theme: ResolvedTheme
    ) -> BoxRenderable {
        let fullLayoutMinWidth = 80
        let fileTreeMinWidth = 24
        let fileTreeMaxWidth = 36
        let minSplitWidth = 100
        let fullInset = 2

        let compact = props.docked || props.width < fullLayoutMinWidth
        let surfaceBg = props.docked ? theme.background.raised.base : theme.background.base
        let inset = compact ? 0 : fullInset
        let fileTreeEnabled = props.preferences.tree ?? true
        let showTree = !compact && showDiffViewerFileTree(fileTreeEnabled, fileCount: props.files.count)
        let treeWidth = max(fileTreeMinWidth, min(fileTreeMaxWidth, props.width / 4))
        let patchPaneWidth = props.width - (showTree ? treeWidth : 0) - inset * 2
        let splitAvailable = patchPaneWidth >= minSplitWidth
        let resolvedView: DiffView = {
            guard splitAvailable else { return .unified }
            if props.preferences.view == "unified" { return .unified }
            return .split
        }()
        let singlePatch = props.preferences.single ?? false

        let root = BoxRenderable(
            ctx: ctx,
            options: BoxOptions(
                id: "diff-viewer-content",
                width: .percent(100),
                height: .percent(100),
                flexDirection: .column,
                backgroundColor: .rgba(surfaceBg)
            )
        )

        let totalAdditions = props.files.reduce(0) { $0 + $1.additions }
        let totalDeletions = props.files.reduce(0) { $0 + $1.deletions }
        let sourceTitle = props.sourceDetail.map { "\(props.mode.rawValue) (\($0))" } ?? props.mode.rawValue
        let headerRow = BoxRenderable(
            ctx: ctx,
            options: BoxOptions(
                id: "diff-viewer-header",
                width: .percent(100),
                flexDirection: .row,
                justifyContent: .spaceBetween,
                paddingRight: .point(Float(max(1, inset))),
                paddingLeft: .point(Float(max(1, inset)))
            )
        )
        headerRow.add(TextRenderable(
            ctx: ctx,
            options: TextOptions(
                content: .string("Diffs · \(sourceTitle) · \(props.files.count) files (+\(totalAdditions) -\(totalDeletions)) [\(resolvedView.rawValue)]"),
                fg: .rgba(theme.text.base),
                attributes: TextAttributes.bold
            )
        ))
        root.add(headerRow)

        if props.loading {
            root.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string("Loading diffs…"), fg: .rgba(theme.text.muted))))
            return root
        }
        if let err = props.error, !err.isEmpty {
            root.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string(err), fg: .rgba(theme.text.feedback.error.base))))
            return root
        }
        if props.unavailable {
            root.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string("Diff source unavailable"), fg: .rgba(theme.text.muted))))
            return root
        }
        if props.files.isEmpty {
            root.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string("No changes"), fg: .rgba(theme.text.muted))))
            return root
        }

        let fileItems = props.files.map { FileTreeItem(file: $0.file, status: $0.status) }
        let tree = buildFileTree(fileItems)
        let expanded = allExpandedFileTreeDirectories(tree)
        let rows = flattenFileTree(tree, expanded: expanded)
        let orderedIndexes = orderedPatchFileIndexes(rows)
        let activeSingleIndex = singlePatch
            ? singlePatchFileIndex(selected: props.selectedFileIndex, current: nil, first: orderedIndexes.first)
            : nil
        let visibleIndexes = activeSingleIndex.map { [$0] } ?? orderedIndexes

        let bodyRow = BoxRenderable(
            ctx: ctx,
            options: BoxOptions(
                id: "diff-viewer-body",
                width: .percent(100),
                flexGrow: 1,
                flexDirection: .row,
                gap: .point(1)
            )
        )

        if showTree {
            let treeView = DiffViewerFileTree(
                ctx: ctx,
                props: DiffViewerFileTreeProps(
                    width: treeWidth,
                    files: fileItems,
                    selectedFileIndex: activeSingleIndex ?? props.selectedFileIndex,
                    expandedNodes: expanded,
                    source: props.mode.rawValue
                ),
                theme: theme
            )
            bodyRow.add(treeView)
        }

        let patchPane = BoxRenderable(
            ctx: ctx,
            options: BoxOptions(
                id: "diff-viewer-patches",
                flexGrow: 1,
                flexDirection: .column,
                gap: .point(1)
            )
        )
        for fileIndex in visibleIndexes where props.files.indices.contains(fileIndex) {
            let file = props.files[fileIndex]
            let card = BoxRenderable(
                ctx: ctx,
                options: BoxOptions(
                    id: "diff-file-\(fileIndex)",
                    width: .percent(100),
                    flexDirection: .column,
                    backgroundColor: .rgba(theme.background.raised.base)
                )
            )
            card.add(TextRenderable(
                ctx: ctx,
                options: TextOptions(
                    content: .string("\(file.file)  +\(file.additions) -\(file.deletions)"),
                    fg: .rgba(theme.text.base),
                    attributes: TextAttributes.bold
                )
            ))
            if isDiffImageFile(file.file) {
                card.add(DiffViewerImage(ctx: ctx, file: file.file, theme: theme))
            } else if let patch = file.patch, !patch.isEmpty {
                for line in patch.split(separator: "\n", omittingEmptySubsequences: false).prefix(200) {
                    let text = String(line)
                    let fg: RGBA
                    if text.hasPrefix("+") && !text.hasPrefix("+++") {
                        fg = theme.diff.text.added
                    } else if text.hasPrefix("-") && !text.hasPrefix("---") {
                        fg = theme.diff.text.removed
                    } else if text.hasPrefix("@@") {
                        fg = theme.text.muted
                    } else {
                        fg = theme.diff.text.context
                    }
                    card.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string(text), fg: .rgba(fg), wrapMode: TextWrapMode.none)))
                }
            }
            patchPane.add(card)
        }
        bodyRow.add(patchPane)
        root.add(bodyRow)

        let footerText = props.sources.count > 1
            ? "tab switch source · v toggle view · t toggle tree · esc close"
            : "v toggle view · t toggle tree · esc close"
        root.add(TextRenderable(
            ctx: ctx,
            options: TextOptions(id: "diff-viewer-footer", content: .string(footerText), fg: .rgba(theme.text.muted))
        ))
        return root
    }

    // MARK: - Built-in Feature Plugin Modules (`export default Plugin.define(...)`)

    /// Built-in TUI feature plugin definition matching upstream `Plugin.define({ id, setup })`.
    public struct FeaturePluginModule: Sendable {
        public let id: String
        public let setup: @Sendable (TUIPluginHost.PluginRuntimeContext) -> (@Sendable () -> Void)?

        public init(
            id: String,
            setup: @escaping @Sendable (TUIPluginHost.PluginRuntimeContext) -> (@Sendable () -> Void)?
        ) {
            self.id = id
            self.setup = setup
        }
    }

    // parity: tui/src/feature-plugins/home/footer.tsx#default [status=adapted hash=57d2755d3e7e]
    public static let homeFooterPlugin = FeaturePluginModule(id: "opencode.home.footer") { context in
        context.registerSlot(placement: TUIPluginHost.Placement(kind: .append, target: "home.footer")) { ctx, input in
            let width: Int
            if case .int(let w) = input["width"] { width = Int(w) } else { width = 80 }
            let visibility = homeFooterVisibility(width: width)
            let theme = context.host.theme()
            let row = BoxRenderable(ctx: ctx, options: BoxOptions(id: "home-footer-plugin", width: .percent(100), flexDirection: .row, gap: .point(2)))
            if visibility.version {
                row.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string(context.host.version), fg: .rgba(theme.text.muted))))
            }
            return row
        }
    }

    // parity: tui/src/feature-plugins/prompt/btw.tsx#default [status=adapted hash=546808382317]
    public static let promptBtwPlugin = FeaturePluginModule(id: "opencode.btw") { context in
        let offStatus = context.registerSlot(placement: TUIPluginHost.Placement(kind: .append, target: "prompt.footer.status")) { ctx, input in
            let theme = context.host.theme()
            let pending = (input["pending"] == .bool(true))
            let box = BoxRenderable(ctx: ctx, options: BoxOptions(id: "btw-status", flexShrink: 0, visible: pending))
            if pending {
                box.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string("/btw"), fg: .rgba(theme.text.muted))))
            }
            return box
        }
        let offApp = context.registerSlot(placement: TUIPluginHost.Placement(kind: .append, target: "app")) { ctx, input in
            if case .string(let question) = input["question"], case .string(let answer) = input["answer"] {
                return Answer(ctx: ctx, question: question, answer: answer, theme: context.host.theme())
            }
            return BoxRenderable(ctx: ctx, options: BoxOptions(id: "btw-commands", visible: false))
        }
        return {
            offApp()
            offStatus()
        }
    }

    // parity: tui/src/feature-plugins/prompt/footer.tsx#default [status=adapted hash=7c1b260fb8f3]
    public static let promptFooterPlugin = FeaturePluginModule(id: "opencode.prompt.footer") { context in
        context.registerSlot(placement: TUIPluginHost.Placement(kind: .append, target: "prompt.footer")) { ctx, input in
            let usage: String? = { if case .string(let s) = input["usage"] { return s }; return nil }()
            let cost: String? = { if case .string(let s) = input["cost"] { return s }; return nil }()
            let subagents: Int = { if case .int(let n) = input["subagents"] { return Int(n) }; return 0 }()
            let shells: Int = { if case .int(let n) = input["shells"] { return Int(n) }; return 0 }()
            let scripts: Int = { if case .int(let n) = input["scripts"] { return Int(n) }; return 0 }()
            return PromptFooter(
                ctx: ctx,
                usageText: usage,
                costText: cost,
                subagentCount: subagents,
                shellCount: shells,
                scriptCount: scripts,
                theme: context.host.theme()
            )
        }
    }

    // parity: tui/src/feature-plugins/sidebar/context.tsx#default [status=adapted hash=7a8d2c866bb2]
    public static let sidebarContextPlugin = FeaturePluginModule(id: "opencode.sidebar.context") { context in
        context.registerSlot(placement: TUIPluginHost.Placement(kind: .append, target: "sidebar.content")) { ctx, input in
            let tokens: Int = { if case .int(let n) = input["tokens"] { return Int(n) }; return 0 }()
            let percent: Int? = { if case .int(let n) = input["percent"] { return Int(n) }; return nil }()
            let cost: Double = {
                switch input["cost"] {
                case .double(let d): return d
                case .int(let i): return Double(i)
                default: return 0
                }
            }()
            let summary = tokens > 0 ? TUIUtil.ContextUsageSummary(tokens: tokens, percent: percent) : nil
            return SidebarContext(ctx: ctx, usage: summary, cost: cost, theme: context.host.theme())
                ?? BoxRenderable(ctx: ctx, options: BoxOptions(id: "sidebar-context-empty", visible: false))
        }
    }

    // parity: tui/src/feature-plugins/sidebar/footer.tsx#default [status=adapted hash=19aa1c6c6932]
    public static let sidebarFooterPlugin = FeaturePluginModule(id: "opencode.sidebar.footer") { context in
        context.registerSlot(placement: TUIPluginHost.Placement(kind: .append, target: "sidebar.footer")) { ctx, input in
            let theme = context.host.theme()
            let container = BoxRenderable(ctx: ctx, options: BoxOptions(id: "sidebar-footer-plugin", flexDirection: .column, gap: .point(1)))
            let height: Int = { if case .int(let h) = input["height"] { return Int(h) }; return 24 }()
            let dismissed = (input["dismissed"] == .bool(true))
            let hasProvider = (input["hasConnectedProvider"] == .bool(true))
            if let onboarding = SidebarOnboarding(
                ctx: ctx,
                terminalHeight: height,
                dismissed: dismissed,
                hasConnectedProvider: hasProvider,
                theme: theme
            ) {
                container.add(onboarding)
            }
            if case .string(let dir) = input["directory"], !dir.isEmpty {
                let formatted = context.formatPath(dir)
                let label: String
                if case .string(let branch) = input["branch"], !branch.isEmpty {
                    label = "\(formatted):\(branch)"
                } else {
                    label = formatted
                }
                container.add(TextRenderable(ctx: ctx, options: TextOptions(id: "sidebar.footer.location", content: .string(label), fg: .rgba(theme.text.muted))))
            }
            return container
        }
    }

    // parity: tui/src/feature-plugins/sidebar/limit.tsx#default [status=adapted hash=bea1e2800dcd]
    public static let sidebarLimitPlugin = FeaturePluginModule(id: "opencode.sidebar.limit") { context in
        context.registerSlot(placement: TUIPluginHost.Placement(kind: .append, target: "sidebar.content")) { ctx, input in
            let left: Double? = {
                switch input["left"] {
                case .double(let d): return d
                case .int(let i): return Double(i)
                default: return nil
                }
            }()
            let limit: Double = {
                switch input["limit"] {
                case .double(let d): return d
                case .int(let i): return Double(i)
                default: return 0
                }
            }()
            let reached = input["reached"] == .bool(true)
            let usage = left.map { TUIUtil.ModelUsage(left: $0, reached: reached, resetsAt: 0, limits: []) }
            let model = left != nil ? TUIUtil.LimitedModel(id: "model", providerID: "provider", inputCosts: [limit], contextLimit: 200_000) : nil
            return SidebarLimit(ctx: ctx, usage: usage, model: model, theme: context.host.theme())
                ?? BoxRenderable(ctx: ctx, options: BoxOptions(id: "sidebar-limit-empty", visible: false))
        }
    }

    // parity: tui/src/feature-plugins/sidebar/mcp.tsx#default [status=adapted hash=77bb8dcd3be9]
    public static let sidebarMcpPlugin = FeaturePluginModule(id: "opencode.sidebar.mcp") { context in
        context.registerSlot(placement: TUIPluginHost.Placement(kind: .append, target: "sidebar.content")) { ctx, input in
            var servers: [SidebarMcpServer] = []
            if case .array(let arr) = input["servers"] {
                for entry in arr {
                    if case .object(let dict) = entry,
                       case .string(let name) = dict["name"],
                       case .string(let status) = dict["status"]
                    {
                        servers.append(SidebarMcpServer(name: name, status: status))
                    }
                }
            }
            let open = input["open"] != .bool(false)
            return SidebarMcp(ctx: ctx, servers: servers, open: open, theme: context.host.theme())
                ?? BoxRenderable(ctx: ctx, options: BoxOptions(id: "sidebar-mcp-empty", visible: false))
        }
    }

    // parity: tui/src/feature-plugins/sidebar/todo.tsx#default [status=adapted hash=b6fa1eed33f3]
    public static let sidebarTodoPlugin = FeaturePluginModule(id: "opencode.sidebar.todo") { context in
        context.registerSlot(placement: TUIPluginHost.Placement(kind: .append, target: "sidebar.content")) { ctx, input in
            var todos: [TUIUtil.Todo] = []
            if case .array(let arr) = input["todos"] {
                for entry in arr {
                    if case .object(let dict) = entry,
                       case .string(let content) = dict["content"],
                       case .string(let rawStatus) = dict["status"],
                       let status = TUIUtil.TodoStatus(rawValue: rawStatus)
                    {
                        todos.append(TUIUtil.Todo(content: content, status: status))
                    }
                }
            }
            let open = input["open"] != .bool(false)
            return SidebarTodo(ctx: ctx, todos: todos, open: open, theme: context.host.theme())
                ?? BoxRenderable(ctx: ctx, options: BoxOptions(id: "sidebar-todo-empty", visible: false))
        }
    }

    // parity: tui/src/feature-plugins/system/diff-viewer.tsx#default [status=adapted hash=f34d6eca6f64]
    public static let diffViewerPlugin = FeaturePluginModule(id: "opencode.diffs") { context in
        let offPanel = context.registerSlot(placement: TUIPluginHost.Placement(kind: .append, target: "session.panel")) { ctx, input in
            let width: Int = { if case .int(let w) = input["width"] { return Int(w) }; return 80 }()
            let mode: DiffMode = {
                if case .string(let raw) = input["mode"], let m = DiffMode(rawValue: raw) { return m }
                return .working
            }()
            return DiffViewerContent(
                ctx: ctx,
                props: DiffViewerContentProps(files: [], mode: mode, width: width, docked: true),
                theme: context.host.theme()
            )
        }
        let offRoute = try? context.registerRoute(TUIPluginHost.RegisteredRoute(name: "diffs") { ctx, data in
            let mode: DiffMode = {
                if case .string(let raw) = data["mode"], let m = DiffMode(rawValue: raw) { return m }
                return .working
            }()
            return DiffViewerContent(
                ctx: ctx,
                props: DiffViewerContentProps(files: [], mode: mode, docked: false),
                theme: context.host.theme()
            )
        })
        let offApp = context.registerSlot(placement: TUIPluginHost.Placement(kind: .append, target: "app")) { ctx, _ in
            BoxRenderable(ctx: ctx, options: BoxOptions(id: "diff-viewer-commands", visible: false))
        }
        return {
            offApp()
            offRoute?()
            offPanel()
        }
    }

    // parity: tui/src/feature-plugins/system/notifications.ts#default [status=adapted hash=a35ddc8a0fbc]
    public static let notificationsPlugin = FeaturePluginModule(id: "opencode.notifications") { context in
        let hub = TUIContext.useEvent()
        let toast = context.host.toast
        let unsub = hub.on("session.execution.failed") { payload, _ in
            let errorType: String?
            let message: String?
            if case .object(let err) = payload.data["error"] {
                errorType = { if case .string(let s) = err["type"] { return s }; return nil }()
                message = { if case .string(let s) = err["message"] { return s }; return nil }()
            } else {
                errorType = nil
                message = nil
            }
            guard errorType != "provider.free-limit", errorType != "provider.go-limit", let message else { return }
            toast.show(TUIPrimitive.ToastOptions(title: "Session failed", message: message, variant: .error))
        }
        let offSlot = context.registerSlot(placement: TUIPluginHost.Placement(kind: .append, target: "app")) { ctx, _ in
            BoxRenderable(ctx: ctx, options: BoxOptions(id: "notifications-plugin", visible: false))
        }
        return {
            offSlot()
            unsub()
        }
    }

    // parity: tui/src/feature-plugins/system/plugins.tsx#default [status=adapted hash=f9770b64c917]
    public static let pluginsManagerPlugin = FeaturePluginModule(id: "opencode.plugins") { context in
        context.registerSlot(placement: TUIPluginHost.Placement(kind: .append, target: "app")) { ctx, input in
            if input["open"] == .bool(true) {
                return PluginsDialog(
                    ctx: ctx,
                    manager: TUIPluginHost.usePlugin(),
                    showInternal: input["showInternal"] == .bool(true),
                    dialog: context.host.dialog,
                    theme: context.host.theme()
                )
            }
            return BoxRenderable(ctx: ctx, options: BoxOptions(id: "plugins-commands", visible: false))
        }
    }

    // parity: tui/src/feature-plugins/system/stats.tsx#default [status=adapted hash=893b0bd4a10e]
    public static let statsPlugin = FeaturePluginModule(id: "opencode.stats") { context in
        let offRoute = try? context.registerRoute(TUIPluginHost.RegisteredRoute(name: "stats") { ctx, data in
            let width: Int = { if case .int(let w) = data["width"] { return Int(w) }; return 80 }()
            let statsInput = StatsPosterInput(
                tokens: 0,
                streak: 0,
                activeDays: 0,
                sessions: 0,
                activity: [],
                fromMs: 0,
                toMs: 0
            )
            return StatsPoster(ctx: ctx, stats: statsInput, terminalWidth: width, theme: context.host.theme())
        })
        let offApp = context.registerSlot(placement: TUIPluginHost.Placement(kind: .append, target: "app")) { ctx, _ in
            BoxRenderable(ctx: ctx, options: BoxOptions(id: "stats-commands", visible: false))
        }
        return {
            offApp()
            offRoute?()
        }
    }

    // parity: tui/src/feature-plugins/system/storybook/index.tsx#default [status=adapted hash=cf2ac9de3d4e]
    public static let storybookPlugin = FeaturePluginModule(id: "opencode.storybook") { context in
        let offRoute = try? context.registerRoute(TUIPluginHost.RegisteredRoute(name: "storybook") { ctx, data in
            let theme = context.host.theme()
            if case .string(let storyID) = data["story"],
               let story = allStories.first(where: { $0.id == storyID })
            {
                return story.render(ctx, theme)
            }
            let indexBox = BoxRenderable(
                ctx: ctx,
                options: BoxOptions(id: "storybook-index", width: .percent(100), flexDirection: .column, backgroundColor: .rgba(theme.background.base))
            )
            indexBox.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string("storybook"), fg: .rgba(theme.text.base), attributes: TextAttributes.bold)))
            for (idx, story) in allStories.enumerated() {
                indexBox.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string("\(idx + 1) \(story.title)"), fg: .rgba(theme.text.muted))))
            }
            indexBox.add(StoryFooter(
                ctx: ctx,
                title: "storybook",
                controls: [
                    StoryFooterControl(shortcut: "↑/↓", label: "select"),
                    StoryFooterControl(shortcut: "enter", label: "open"),
                    StoryFooterControl(shortcut: "esc", label: "home"),
                ],
                theme: theme
            ))
            return indexBox
        })
        let offApp = context.registerSlot(placement: TUIPluginHost.Placement(kind: .append, target: "app")) { ctx, _ in
            BoxRenderable(ctx: ctx, options: BoxOptions(id: "storybook-commands", visible: false))
        }
        return {
            offApp()
            offRoute?()
        }
    }

    /// All 13 core built-in TUI feature plugin modules ready to install into a `TUIPluginHost.PluginManager`.
    public static let builtinFeaturePlugins: [FeaturePluginModule] = [
        homeFooterPlugin,
        promptBtwPlugin,
        promptFooterPlugin,
        sidebarContextPlugin,
        sidebarFooterPlugin,
        sidebarLimitPlugin,
        sidebarMcpPlugin,
        sidebarTodoPlugin,
        diffViewerPlugin,
        notificationsPlugin,
        pluginsManagerPlugin,
        statsPlugin,
        storybookPlugin,
    ]
}
