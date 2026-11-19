import Foundation
import OpenCodeUtil

// MARK: - Open In External App (`file/apps.ts`, `file/path.ts`, `file/drag.ts`)

public enum OpenApp: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case vscode
    case cursor
    case zed
    case textmate
    case antigravity
    case finder
    case terminal
    case iterm2
    case ghostty
    case warp
    case xcode
    case androidStudio = "android-studio"
    case powershell
    case sublimeText = "sublime-text"
}

public struct OpenAppPreferences: Equatable, Hashable, Sendable, Codable {
    public let app: OpenApp

    public init(app: OpenApp = .finder) {
        self.app = app
    }
}

/// Non-DOM drag payload produced when dragging a file row in the workspace file tree (`file/drag.ts`).
public struct FileDragPayload: Equatable, Hashable, Sendable {
    public let path: String
    public let plainText: String
    public let uriList: String

    public init(path: String) {
        self.path = path
        self.plainText = "file:\(path)"
        self.uriList = FilePathHelper.pathToFileUrl(path)
    }
}

public enum FilePathHelper {
    public static func pathToFileUrl(_ filepath: String) -> String {
        "file://\(encodeFilePath(filepath))"
    }

    public static func fileTabID(resolvedPath: String) -> String {
        "//\(encodeFilePath(resolvedPath))"
    }

    public static func isFileTab(_ id: String) -> Bool {
        id.hasPrefix("//")
    }

    public static func workspaceFileUrl(root: String, path: String) -> String {
        let normalizedRoot = root
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingSuffixSlashes()
        return pathToFileUrl("\(normalizedRoot)/\(path)")
    }

    public static func resolveOpenInAppPath(root: String, path: String) -> String {
        if path.isEmpty { return root }
        if path.hasPrefix("skill://") { return path }

        let windowsRoot = root.hasPrefix("\\\\") || hasWindowsDrivePrefix(root)
        if path.hasPrefix("/") || (windowsRoot && path.hasPrefix("\\")) || hasWindowsDrivePrefix(path) {
            return path
        }
        if root.isEmpty { return path }

        let separator = root.contains("\\") ? "\\" : "/"
        let relative = windowsRoot ? path.trimmingLeadingPathSeparators() : path
        let normalizedRelative: String
        if windowsRoot {
            let from = separator == "\\" ? "/" : "\\"
            normalizedRelative = relative.replacingOccurrences(of: from, with: separator)
        } else {
            normalizedRelative = relative
        }
        return "\(root.trimmingTrailingPathSeparators())\(separator)\(normalizedRelative)"
    }

    public static func openInAppParentPath(_ path: String) -> String {
        let value = path.trimmingTrailingPathSeparators()
        let lastForward = value.lastIndex(of: "/")
        let lastBack = value.lastIndex(of: "\\")
        let lastSep: String.Index?
        switch (lastForward, lastBack) {
        case (let a?, let b?): lastSep = a > b ? a : b
        case (let a?, nil): lastSep = a
        case (nil, let b?): lastSep = b
        case (nil, nil): lastSep = nil
        }
        guard let sep = lastSep else { return path }
        let offset = value.distance(from: value.startIndex, to: sep)
        if offset == 0 {
            return String(value.prefix(1))
        }
        if offset == 2 && hasWindowsDrivePrefix(value) {
            return String(value.prefix(3))
        }
        return String(value[..<sep])
    }

    fileprivate static func hasWindowsDrivePrefix(_ value: String) -> Bool {
        let chars = Array(value)
        guard chars.count >= 3 else { return false }
        return chars[0].isLetter && chars[1] == ":" && (chars[2] == "\\" || chars[2] == "/")
    }
}

private extension String {
    func trimmingSuffixSlashes() -> String {
        var end = endIndex
        while end > startIndex {
            let prev = index(before: end)
            if self[prev] == "/" {
                end = prev
            } else {
                break
            }
        }
        return String(self[..<end])
    }

    func trimmingTrailingPathSeparators() -> String {
        var end = endIndex
        while end > startIndex {
            let prev = index(before: end)
            if self[prev] == "/" || self[prev] == "\\" {
                end = prev
            } else {
                break
            }
        }
        return String(self[..<end])
    }

    func trimmingLeadingPathSeparators() -> String {
        var start = startIndex
        while start < endIndex && (self[start] == "/" || self[start] == "\\") {
            start = index(after: start)
        }
        return String(self[start...])
    }
}

// MARK: - Artifact Content & Parsing Helpers (`file/artifact.ts`)

public struct GUIFileContent: Equatable, Hashable, Sendable, Codable {
    public enum ContentType: String, Equatable, Hashable, Sendable, Codable {
        case text
        case binary
    }

    public enum Encoding: String, Equatable, Hashable, Sendable, Codable {
        case utf8
        case base64
    }

    public let type: ContentType
    public let content: String
    public let encoding: Encoding?
    public let mimeType: String?
    public let bytes: [UInt8]?
    public let size: Int?

    public init(
        type: ContentType,
        content: String = "",
        encoding: Encoding? = nil,
        mimeType: String? = nil,
        bytes: [UInt8]? = nil,
        size: Int? = nil
    ) {
        self.type = type
        self.content = content
        self.encoding = encoding
        self.mimeType = mimeType
        self.bytes = bytes
        self.size = size
    }
}

public struct DelimitedTable: Equatable, Sendable {
    public let rows: [[String]]
    public let total: Int
    public let columns: Int

    public init(rows: [[String]], total: Int, columns: Int) {
        self.rows = rows
        self.total = total
        self.columns = columns
    }
}

public struct FrontmatterProperty: Equatable, Hashable, Sendable {
    public let key: String
    public let value: String
    public let code: Bool

    public init(key: String, value: String, code: Bool) {
        self.key = key
        self.value = value
        self.code = code
    }
}

public struct FrontmatterSplit: Equatable, Sendable {
    public let properties: [FrontmatterProperty]?
    public let body: String

    public init(properties: [FrontmatterProperty]? = nil, body: String) {
        self.properties = properties
        self.body = body
    }
}

public enum ArtifactHelper {
    public static func contentBytes(_ content: GUIFileContent) -> Int {
        if let size = content.size { return size }
        if let bytes = content.bytes { return bytes.count }
        if content.encoding == .base64 {
            let padding = content.content.hasSuffix("==") ? 2 : (content.content.hasSuffix("=") ? 1 : 0)
            return ((content.content.utf8.count * 3) / 4) - padding
        }
        return content.content.utf8.count
    }

    public static func bytesFromContent(_ content: GUIFileContent) throws(Base64Error) -> [UInt8] {
        if let bytes = content.bytes { return bytes }
        if content.encoding != .base64 { return Array(content.content.utf8) }
        return try base64ToBytes(content.content)
    }

    /// Parses RFC 4180 delimited text (CSV/TSV). Rows beyond `limit` are counted in `total` but omitted from `rows`.
    public static func parseDelimited(_ text: String, delimiter: Character, limit: Int = 1000) -> DelimitedTable {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var total = 0

        func endRow() {
            row.append(field)
            field = ""
            let blank = row.count == 1 && row[0].isEmpty
            if !blank {
                total += 1
                if rows.count < limit {
                    rows.append(row)
                }
            }
            row = []
        }

        let chars = Array(text)
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if quoted {
                if char != "\"" {
                    field.append(char)
                    index += 1
                    continue
                }
                if index + 1 < chars.count && chars[index + 1] == "\"" {
                    field.append("\"")
                    index += 2
                    continue
                }
                quoted = false
                index += 1
                continue
            }

            if char == "\"" && field.isEmpty {
                quoted = true
                index += 1
                continue
            }

            if char == delimiter {
                row.append(field)
                field = ""
                index += 1
                continue
            }

            if char == "\r" {
                index += 1
                continue
            }

            if char == "\n" {
                endRow()
                index += 1
                continue
            }

            field.append(char)
            index += 1
        }

        if !field.isEmpty || !row.isEmpty {
            endRow()
        }
        let columns = rows.reduce(0) { max($0, $1.count) }
        return DelimitedTable(rows: rows, total: total, columns: columns)
    }

    /// Resolves a relative link against `base`; returns `nil` when `href` is absolute or escapes past the base root.
    public static func resolveArtifactPath(base: String, href: String) -> String? {
        let target = href.replacingOccurrences(of: "\\", with: "/")
        if target.hasPrefix("/") { return nil }
        let dir = base.replacingOccurrences(of: "\\", with: "/")
        var segments = dir.split(separator: "/").map(String.init).filter { !$0.isEmpty }

        for rawSegment in target.split(separator: "/", omittingEmptySubsequences: false) {
            let segment = String(rawSegment)
            if segment.isEmpty || segment == "." { continue }
            if segment != ".." {
                segments.append(segment)
                continue
            }
            if segments.isEmpty { return nil }
            segments.removeLast()
        }

        let prefix = dir.hasPrefix("/") ? "/" : ""
        return "\(prefix)\(segments.joined(separator: "/"))"
    }

    /// Splits a leading YAML frontmatter block from Markdown, extracting top-level properties or falling back to a yaml fence.
    public static func splitFrontmatter(_ text: String) -> FrontmatterSplit {
        var cursor = text.startIndex
        if cursor < text.endIndex && text[cursor] == "\u{FEFF}" {
            cursor = text.index(after: cursor)
        }
        let rest = String(text[cursor...])
        let lines = splitPreservingLines(rest)
        guard let first = lines.first, isDelimiterLine(first.content) else {
            return FrontmatterSplit(properties: nil, body: text)
        }

        var closingIndex: Int?
        if lines.count >= 2 {
            for idx in 1..<lines.count {
                if isDelimiterLine(lines[idx].content) {
                    closingIndex = idx
                    break
                }
            }
        }
        guard let closeIdx = closingIndex else {
            return FrontmatterSplit(properties: nil, body: text)
        }

        let yamlLines = lines[1..<closeIdx].map(\.content)
        let yaml = yamlLines.joined(separator: "\n")
        let body = lines[(closeIdx + 1)...].map { $0.content + $0.newline }.joined()

        if yaml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return FrontmatterSplit(properties: nil, body: body)
        }

        if let properties = readProperties(yaml: yaml) {
            return FrontmatterSplit(properties: properties, body: body)
        }

        let longest = longestBacktickRun(in: yaml)
        let fence = String(repeating: "`", count: max(3, longest + 1))
        let block = "\(fence)yaml\n\(yaml)\n\(fence)"
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return FrontmatterSplit(properties: nil, body: trimmedBody.isEmpty ? block : "\(block)\n\n\(body)")
    }

    private struct LinePiece {
        let content: String
        let newline: String
    }

    private static func splitPreservingLines(_ text: String) -> [LinePiece] {
        var result: [LinePiece] = []
        var line = ""
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch == "\r" {
                if i + 1 < chars.count && chars[i + 1] == "\n" {
                    result.append(LinePiece(content: line, newline: "\r\n"))
                    line = ""
                    i += 2
                    continue
                }
                result.append(LinePiece(content: line, newline: "\r"))
                line = ""
                i += 1
                continue
            }
            if ch == "\n" {
                result.append(LinePiece(content: line, newline: "\n"))
                line = ""
                i += 1
                continue
            }
            line.append(ch)
            i += 1
        }
        if !line.isEmpty || result.isEmpty {
            result.append(LinePiece(content: line, newline: ""))
        }
        return result
    }

    private static func isDelimiterLine(_ line: String) -> Bool {
        guard line.hasPrefix("---") else { return false }
        return line.dropFirst(3).allSatisfy { $0 == " " || $0 == "\t" }
    }

    private static func longestBacktickRun(in value: String) -> Int {
        var best = 0
        var run = 0
        for ch in value {
            if ch == "`" {
                run += 1
                if run > best { best = run }
            } else {
                run = 0
            }
        }
        return best
    }

    private static func readProperties(yaml: String) -> [FrontmatterProperty]? {
        let lines = yaml.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.hasPrefix("#") }

        var starts: [Int] = []
        for (index, line) in lines.enumerated() {
            guard let first = line.first else { continue }
            if !first.isWhitespace && first != "-" {
                starts.append(index)
            } else if first == "-" {
                let second = line.dropFirst().first
                if let second, !second.isWhitespace {
                    starts.append(index)
                }
            }
        }

        guard let firstStart = starts.first else { return nil }
        if lines[0..<firstStart].contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return nil
        }

        var properties: [FrontmatterProperty] = []
        for (idx, start) in starts.enumerated() {
            let end = (idx + 1 < starts.count) ? starts[idx + 1] : lines.count
            let rest = (start + 1 < end) ? Array(lines[(start + 1)..<end]) : []
            guard let prop = readProperty(head: lines[start], rest: rest) else { return nil }
            properties.append(prop)
        }
        return properties
    }

    private static func readProperty(head: String, rest: [String]) -> FrontmatterProperty? {
        guard let colonIndex = head.firstIndex(of: ":") else { return nil }
        let key = String(head[..<colonIndex])
        guard !key.isEmpty, let firstChar = key.first, !firstChar.isWhitespace else { return nil }

        let afterColon = head[head.index(after: colonIndex)...]
        let rawValue: String
        if afterColon.isEmpty {
            rawValue = ""
        } else if afterColon.first == " " || afterColon.first == "\t" {
            rawValue = String(afterColon).trimmingCharacters(in: .whitespaces)
        } else {
            return nil
        }

        var lastNonEmpty = -1
        for (idx, line) in rest.enumerated() where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            lastNonEmpty = idx
        }
        let block = lastNonEmpty >= 0 ? Array(rest[0...lastNonEmpty]) : []

        if rawValue.hasPrefix("\"") || rawValue.hasPrefix("'") {
            guard block.isEmpty else { return nil }
            if rawValue.hasPrefix("\""), rawValue.hasSuffix("\""), rawValue.count >= 2 {
                let inner = String(rawValue.dropFirst().dropLast())
                guard !inner.contains("\""), !inner.contains("\\") else { return nil }
                return FrontmatterProperty(key: key, value: inner, code: false)
            }
            if rawValue.hasPrefix("'"), rawValue.hasSuffix("'"), rawValue.count >= 2 {
                let inner = String(rawValue.dropFirst().dropLast())
                guard !inner.contains("'") else { return nil }
                return FrontmatterProperty(key: key, value: inner, code: false)
            }
            return nil
        }

        if containsYAMLComment(rawValue) { return nil }
        if block.isEmpty {
            return FrontmatterProperty(key: key, value: rawValue, code: false)
        }

        let indents = block.compactMap { line -> Int? in
            if line.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
            return line.prefix(while: { $0.isWhitespace }).count
        }
        let indent = indents.min() ?? 0
        let unindented = block.map { line -> String in
            line.count >= indent ? String(line.dropFirst(indent)) : ""
        }

        if isBlockIndicator(rawValue, scalar: "|") {
            return FrontmatterProperty(key: key, value: unindented.joined(separator: "\n"), code: false)
        }

        if !rawValue.isEmpty {
            let folded = isBlockIndicator(rawValue, scalar: ">")
            if !folded && unindented.contains(where: containsYAMLComment) {
                return nil
            }
            let words = ([folded ? "" : rawValue] + unindented.map { $0.trimmingCharacters(in: .whitespaces) })
                .filter { !$0.isEmpty }
            return FrontmatterProperty(key: key, value: words.joined(separator: " "), code: false)
        }

        return FrontmatterProperty(key: key, value: unindented.joined(separator: "\n"), code: true)
    }

    private static func containsYAMLComment(_ value: String) -> Bool {
        var prevWasWhitespace = true
        for ch in value {
            if ch == "#" && prevWasWhitespace { return true }
            prevWasWhitespace = ch.isWhitespace
        }
        return false
    }

    private static func isBlockIndicator(_ value: String, scalar: Character) -> Bool {
        let chars = Array(value)
        guard chars.first == scalar else { return false }
        let rest = chars.dropFirst()
        if rest.isEmpty { return true }
        var idx = rest.startIndex
        if rest[idx] == "+" || rest[idx] == "-" {
            idx = rest.index(after: idx)
        }
        if idx == rest.endIndex { return true }
        let ch = rest[idx]
        return ch.isNumber && rest.index(after: idx) == rest.endIndex
    }
}

// MARK: - Artifact Viewer, Image Stage & Video Overlay Machines (`file/artifact-view-machine.ts`)

public enum ArtifactMode: String, Equatable, Hashable, Sendable, Codable {
    case preview
    case source
}

public struct ArtifactInfo: Equatable, Hashable, Sendable {
    public let width: Double?
    public let height: Double?
    public let duration: Double?
    public let rows: Int?
    public let columns: Int?
    public let details: [String]?

    public init(
        width: Double? = nil,
        height: Double? = nil,
        duration: Double? = nil,
        rows: Int? = nil,
        columns: Int? = nil,
        details: [String]? = nil
    ) {
        self.width = width
        self.height = height
        self.duration = duration
        self.rows = rows
        self.columns = columns
        self.details = details
    }
}

public enum ArtifactStageKind: Equatable, Hashable, Sendable {
    case artifact(ArtifactKind)
    case binary
}

public enum ArtifactViewerMachine {
    public enum State: Equatable, Sendable {
        case preview(content: GUIFileContent, info: ArtifactInfo)
        case source(content: GUIFileContent, info: ArtifactInfo)
        case undecodable(content: GUIFileContent, mode: ArtifactMode, reason: String?)

        public var content: GUIFileContent {
            switch self {
            case .preview(let c, _), .source(let c, _), .undecodable(let c, _, _): return c
            }
        }
    }

    public enum Event: Equatable, Sendable {
        case modeChanged(ArtifactMode)
        case infoReported(content: GUIFileContent, info: ArtifactInfo)
        case decodeFailed(content: GUIFileContent, reason: String?)
    }

    private static let previewableKinds: Set<ArtifactKind> = [.svg, .html, .markdown, .mermaid, .table]

    public static func createState(content: GUIFileContent) -> State {
        .preview(content: content, info: ArtifactInfo())
    }

    public static func reduce(state: State, content: GUIFileContent, event: Event) -> State {
        let base = current(state, for: content)
        switch event {
        case .modeChanged(let mode):
            if selectMode(state: base, content: content) == mode { return base }
            switch base {
            case .undecodable(let c, _, let reason):
                return .undecodable(content: c, mode: mode, reason: reason)
            case .preview(_, let info), .source(_, let info):
                return mode == .preview ? .preview(content: content, info: info) : .source(content: content, info: info)
            }

        case .infoReported(let eventContent, let info):
            guard eventContent == content else { return base }
            switch base {
            case .undecodable: return base
            case .preview: return .preview(content: content, info: info)
            case .source: return .source(content: content, info: info)
            }

        case .decodeFailed(let eventContent, let reason):
            guard eventContent == content else { return base }
            if case .undecodable(_, _, let currentReason) = base, currentReason == reason {
                return base
            }
            return .undecodable(content: content, mode: selectMode(state: base, content: content), reason: reason)
        }
    }

    public static func fixedMode(path: String, content: GUIFileContent) -> ArtifactMode? {
        if content.type == .binary { return .preview }
        let kind = artifactKind(path)
        if kind == .text { return .source }
        if !previewableKinds.contains(kind) { return .preview }
        return nil
    }

    public static func selectMode(state: State, content: GUIFileContent) -> ArtifactMode {
        switch current(state, for: content) {
        case .preview: return .preview
        case .source: return .source
        case .undecodable(_, let mode, _): return mode
        }
    }

    public static func selectStageKind(state: State, path: String, content: GUIFileContent) -> ArtifactStageKind {
        if content.type == .binary && content.mimeType == nil { return .binary }
        if case .undecodable = current(state, for: content) { return .binary }
        return .artifact(artifactKind(path))
    }

    public static func selectInfo(state: State, content: GUIFileContent) -> ArtifactInfo {
        switch current(state, for: content) {
        case .preview(_, let info), .source(_, let info): return info
        case .undecodable: return ArtifactInfo()
        }
    }

    public static func selectReason(state: State, content: GUIFileContent) -> String? {
        if case .undecodable(_, _, let reason) = current(state, for: content) {
            return reason
        }
        return nil
    }

    private static func current(_ state: State, for content: GUIFileContent) -> State {
        state.content == content ? state : createState(content: content)
    }
}

public enum ImageStageGestureMachine: GUIStateMachine {
    public static let dragThresholdPx: Double = 3

    public enum Cursor: String, Equatable, Hashable, Sendable {
        case grab
        case grabbing
    }

    public enum State: Equatable, Sendable {
        case idle
        case panning(pointerID: Int, moved: Bool)
        case suppressClick
        case disposed
    }

    public enum Event: Equatable, Sendable {
        case pointerDown(pointerID: Int, button: Int, primary: Bool, zoomed: Bool)
        case pointerMoved(pointerID: Int)
        case pointerUp(pointerID: Int)
        case pointerCancel(pointerID: Int)
        case zoomChanged(zoomed: Bool)
        case click
        case disposed
    }

    public enum Effect: Equatable, Sendable {
        case pointerCapture(pointerID: Int)
        case pointerRelease(pointerID: Int)
    }

    public static let initialState: State = .idle

    public static func reduce(state: State, event: Event) -> GUIStateTransition<State, Effect> {
        if case .disposed = state { return GUIStateTransition(state: state) }

        let activePan: (pointerID: Int, moved: Bool)?
        if case .panning(let id, let moved) = state {
            activePan = (id, moved)
        } else {
            activePan = nil
        }

        switch event {
        case .disposed:
            return GUIStateTransition(
                state: .disposed,
                effects: activePan.map { [.pointerRelease(pointerID: $0.pointerID)] } ?? []
            )

        case .pointerDown(let pointerID, let button, let primary, let zoomed):
            if let pan = activePan, pan.pointerID != pointerID {
                return GUIStateTransition(state: state)
            }
            if primary && button == 0 && zoomed {
                return GUIStateTransition(
                    state: .panning(pointerID: pointerID, moved: false),
                    effects: [.pointerCapture(pointerID: pointerID)]
                )
            }
            return GUIStateTransition(state: state == .suppressClick ? .idle : state)

        case .pointerMoved(let pointerID):
            guard let pan = activePan, pan.pointerID == pointerID, !pan.moved else {
                return GUIStateTransition(state: state)
            }
            return GUIStateTransition(state: .panning(pointerID: pointerID, moved: true))

        case .pointerUp(let pointerID):
            guard let pan = activePan, pan.pointerID == pointerID else {
                return GUIStateTransition(state: state)
            }
            return GUIStateTransition(state: pan.moved ? .suppressClick : .idle)

        case .pointerCancel(let pointerID):
            guard let pan = activePan, pan.pointerID == pointerID else {
                return GUIStateTransition(state: state)
            }
            return GUIStateTransition(state: .idle, effects: [.pointerRelease(pointerID: pointerID)])

        case .zoomChanged(let zoomed):
            guard let pan = activePan, !zoomed else {
                return GUIStateTransition(state: state)
            }
            return GUIStateTransition(state: .idle, effects: [.pointerRelease(pointerID: pan.pointerID)])

        case .click:
            return GUIStateTransition(state: state == .suppressClick ? .idle : state)
        }
    }

    public static func panPointer(_ state: State, pointerID: Int) -> Bool {
        if case .panning(let current, _) = state { return current == pointerID }
        return false
    }

    public static func panMoved(_ state: State) -> Bool {
        if case .panning(_, let moved) = state { return moved }
        return false
    }

    public static func clickSuppressed(_ state: State) -> Bool {
        state == .suppressClick
    }

    public static func cursor(_ state: State, zoomed: Bool) -> Cursor? {
        guard zoomed else { return nil }
        if case .panning = state { return .grabbing }
        return .grab
    }
}

public enum VideoOverlayMachine: GUIStateMachine {
    public static let idleMs = 2_500

    public enum State: Equatable, Sendable {
        case loading(paused: Bool, issued: Int)
        case paused(issued: Int)
        case playingActive(issued: Int)
        case playingIdle(issued: Int)
        case expanded(issued: Int, paused: Bool)
        case disposed
    }

    public enum Event: Equatable, Sendable {
        case mediaLoaded(paused: Bool)
        case playbackChanged(paused: Bool)
        case pointerMoved
        case pointerLeft
        case idleElapsed(attempt: Int)
        case expandRequested(canExpand: Bool)
        case previewReturned(attempt: Int)
        case disposed
    }

    public enum Effect: Equatable, Sendable {
        case idleSchedule(attempt: Int, delayMs: Int)
        case idleClear
        case previewOpen(attempt: Int)
        case previewRelease(attempt: Int)
        case previewClose(attempt: Int)
    }

    public static func createState() -> State {
        .loading(paused: true, issued: 0)
    }

    public static func reduce(state: State, event: Event) -> GUIStateTransition<State, Effect> {
        if case .disposed = state { return GUIStateTransition(state: state) }

        switch event {
        case .disposed:
            switch state {
            case .playingActive:
                return GUIStateTransition(state: .disposed, effects: [.idleClear])
            case .expanded(let issued, _):
                return GUIStateTransition(state: .disposed, effects: [.previewClose(attempt: issued)])
            default:
                return GUIStateTransition(state: .disposed)
            }

        case .mediaLoaded(let paused):
            guard case .loading(_, let issued) = state else { return GUIStateTransition(state: state) }
            return paused ? GUIStateTransition(state: .paused(issued: issued)) : activate(issued: issued)

        case .playbackChanged(let paused):
            switch state {
            case .loading(let currentPaused, let issued):
                return currentPaused == paused ? GUIStateTransition(state: state) : GUIStateTransition(state: .loading(paused: paused, issued: issued))
            case .expanded(let issued, let currentPaused):
                return currentPaused == paused ? GUIStateTransition(state: state) : GUIStateTransition(state: .expanded(issued: issued, paused: paused))
            case .paused(let issued):
                return paused ? GUIStateTransition(state: state) : activate(issued: issued)
            case .playingActive(let issued):
                return paused ? GUIStateTransition(state: .paused(issued: issued), effects: [.idleClear]) : GUIStateTransition(state: state)
            case .playingIdle(let issued):
                return paused ? GUIStateTransition(state: .paused(issued: issued)) : GUIStateTransition(state: state)
            case .disposed:
                return GUIStateTransition(state: state)
            }

        case .pointerMoved:
            switch state {
            case .playingActive(let issued), .playingIdle(let issued):
                return activate(issued: issued)
            default:
                return GUIStateTransition(state: state)
            }

        case .pointerLeft:
            guard case .playingActive(let issued) = state else { return GUIStateTransition(state: state) }
            return GUIStateTransition(state: .playingIdle(issued: issued), effects: [.idleClear])

        case .idleElapsed(let attempt):
            guard case .playingActive(let issued) = state, issued == attempt else {
                return GUIStateTransition(state: state)
            }
            return GUIStateTransition(state: .playingIdle(issued: issued))

        case .expandRequested(let canExpand):
            guard canExpand else { return GUIStateTransition(state: state) }
            switch state {
            case .paused(let issued):
                let attempt = issued + 1
                return GUIStateTransition(state: .expanded(issued: attempt, paused: true), effects: [.previewOpen(attempt: attempt)])
            case .playingActive(let issued):
                let attempt = issued + 1
                return GUIStateTransition(state: .expanded(issued: attempt, paused: false), effects: [.idleClear, .previewOpen(attempt: attempt)])
            case .playingIdle(let issued):
                let attempt = issued + 1
                return GUIStateTransition(state: .expanded(issued: attempt, paused: false), effects: [.previewOpen(attempt: attempt)])
            default:
                return GUIStateTransition(state: state)
            }

        case .previewReturned(let attempt):
            guard case .expanded(let issued, let paused) = state, issued == attempt else {
                return GUIStateTransition(state: state)
            }
            return GUIStateTransition(
                state: paused ? .paused(issued: issued) : .playingIdle(issued: issued),
                effects: [.previewRelease(attempt: issued)]
            )
        }
    }

    public static func isLoading(_ state: State) -> Bool {
        if case .loading = state { return true }
        return false
    }

    public static func controlsVisible(_ state: State) -> Bool {
        switch state {
        case .paused, .playingActive: return true
        default: return false
        }
    }

    private static func activate(issued: Int) -> GUIStateTransition<State, Effect> {
        let attempt = issued + 1
        return GUIStateTransition(
            state: .playingActive(issued: attempt),
            effects: [.idleSchedule(attempt: attempt, delayMs: idleMs)]
        )
    }
}

// MARK: - File Tree Model (`file/tree-model.ts`)

public enum TreeGitStatus: String, Equatable, Hashable, Sendable, Codable {
    case added
    case deleted
    case modified
    case ignored
}

public struct GUIFileNode: Equatable, Hashable, Sendable, Codable {
    public enum NodeType: String, Equatable, Hashable, Sendable, Codable {
        case file
        case directory
    }

    public let name: String
    public let path: String
    public let type: NodeType
    public let ignored: Bool

    public init(name: String, path: String, type: NodeType, ignored: Bool = false) {
        self.name = name
        self.path = path
        self.type = type
        self.ignored = ignored
    }
}

public struct AllowedTreeInput: Equatable, Sendable {
    public let paths: [String]
    public let originalByPath: [String: String]
    public let directories: Set<String>
    public let untrackedDirs: Set<String>
    public let files: Set<String>
    public let total: Int
}

public struct LiveTreeInput: Equatable, Sendable {
    public let paths: [String]
    public let pathSet: Set<String>
    public let expandedDirs: [String]
    public let expandedSet: Set<String>
    public let nodesByPath: [String: GUIFileNode]
    public let ignoredPaths: Set<String>
    public let orderByPath: [String: Int]
}

public struct GitStatusPatchEntry: Equatable, Hashable, Sendable {
    public let path: String
    public let status: TreeGitStatus

    public init(path: String, status: TreeGitStatus) {
        self.path = path
        self.status = status
    }
}

public struct GitStatusPatch: Equatable, Sendable {
    public let remove: [String]
    public let set: [GitStatusPatchEntry]

    public init(remove: [String], set: [GitStatusPatchEntry]) {
        self.remove = remove
        self.set = set
    }
}

public enum FileTreeModel {
    public static let rowHeight = 28

    public static func normalizePath(_ value: String) -> String {
        if !value.contains("\\") && !value.hasPrefix("/") && !value.hasSuffix("/") && !value.contains("//") {
            return value
        }
        return ReviewPathHelper.normalizePath(value)
    }

    public static func kindChange(_ kind: ReviewChangeKind) -> TreeGitStatus {
        switch kind {
        case .add: return .added
        case .del: return .deleted
        case .mix: return .modified
        }
    }

    public static func buildAllowedTreeInput(paths rawPaths: [String]) -> AllowedTreeInput {
        var list: [String] = []
        var originalByPath: [String: String] = [:]
        var directories: Set<String> = []
        var untrackedDirs: Set<String> = []
        var files: Set<String> = []
        var seenDirs: Set<String> = []

        for raw in rawPaths {
            let isDir = raw.hasSuffix("/") || raw.hasSuffix("\\")
            let normalized = normalizePath(raw)
            if normalized.isEmpty { continue }

            var searchIndex = normalized.startIndex
            while let slash = normalized[searchIndex...].firstIndex(of: "/") {
                directories.insert(String(normalized[..<slash]))
                searchIndex = normalized.index(after: slash)
            }

            if isDir {
                directories.insert(normalized)
                untrackedDirs.insert(normalized)
                let canonical = "\(normalized)/"
                if seenDirs.insert(canonical).inserted {
                    list.append(canonical)
                }
                continue
            }

            if !files.insert(normalized).inserted { continue }
            if raw != normalized {
                originalByPath[normalized] = raw
            }
            list.append(normalized)
        }

        return AllowedTreeInput(
            paths: list,
            originalByPath: originalByPath,
            directories: directories,
            untrackedDirs: untrackedDirs,
            files: files,
            total: directories.count + files.count
        )
    }

    public static func collectAllowedCollapsedDirs(
        model: AllowedTreeInput,
        expanded: (String) -> Bool?
    ) -> Set<String> {
        var collapsed: Set<String> = []
        for dir in model.directories {
            let isOpen = model.untrackedDirs.contains(dir) ? (expanded(dir) == true) : (expanded(dir) != false)
            if !isOpen {
                collapsed.insert(dir)
            }
        }
        return collapsed
    }

    public static func buildLiveTreeInput(
        children: (String) -> [GUIFileNode],
        expanded: (String) -> Bool
    ) -> LiveTreeInput {
        var paths: [String] = []
        var pathSet: Set<String> = []
        var expandedDirs: [String] = []
        var expandedSet: Set<String> = []
        var nodesByPath: [String: GUIFileNode] = [:]
        var ignoredPaths: Set<String> = []
        var orderByPath: [String: Int] = [:]
        var seen: Set<String> = []
        var queue = [""]
        var head = 0

        while head < queue.count {
            let dir = queue[head]
            head += 1
            for node in children(dir) {
                let norm = normalizePath(node.path)
                guard !norm.isEmpty, seen.insert(norm).inserted else { continue }
                nodesByPath[norm] = node
                orderByPath[norm] = orderByPath.count

                if node.type == .directory {
                    let canonical = "\(norm)/"
                    paths.append(canonical)
                    pathSet.insert(canonical)
                    if node.ignored { ignoredPaths.insert(canonical) }
                    if expanded(norm) {
                        expandedDirs.append(canonical)
                        expandedSet.insert(canonical)
                        queue.append(node.path)
                    }
                    continue
                }

                paths.append(norm)
                pathSet.insert(norm)
                if node.ignored { ignoredPaths.insert(norm) }
            }
        }

        return LiveTreeInput(
            paths: paths,
            pathSet: pathSet,
            expandedDirs: expandedDirs,
            expandedSet: expandedSet,
            nodesByPath: nodesByPath,
            ignoredPaths: ignoredPaths,
            orderByPath: orderByPath
        )
    }

    public static func buildKindsStatus(_ kinds: [String: ReviewChangeKind]?) -> [String: TreeGitStatus] {
        guard let kinds else { return [:] }
        var out: [String: TreeGitStatus] = [:]
        for (raw, kind) in kinds {
            let path = normalizePath(raw)
            if !path.isEmpty {
                out[path] = kindChange(kind)
            }
        }
        return out
    }

    public static func buildGitStatusMap(
        kindsStatus: [String: TreeGitStatus],
        ignoredPaths: Set<String>
    ) -> [String: TreeGitStatus] {
        var out: [String: TreeGitStatus] = [:]
        for path in ignoredPaths {
            out[path] = .ignored
        }
        for (path, status) in kindsStatus {
            out[path] = status
        }
        return out
    }

    public static func diffGitStatusPatch(
        previous: [String: TreeGitStatus],
        next: [String: TreeGitStatus]
    ) -> GitStatusPatch {
        let removed = previous.keys.filter { next[$0] == nil }.sorted()
        let set = next.keys.sorted().compactMap { key -> GitStatusPatchEntry? in
            guard let status = next[key], previous[key] != status else { return nil }
            return GitStatusPatchEntry(path: key, status: status)
        }
        return GitStatusPatch(remove: removed, set: set)
    }

    public static func diffStatusLayers(
        previousKinds: [String: TreeGitStatus],
        previousIgnored: Set<String>,
        nextKinds: [String: TreeGitStatus],
        nextIgnored: Set<String>
    ) -> GitStatusPatch {
        if previousKinds != nextKinds {
            return diffGitStatusPatch(
                previous: buildGitStatusMap(kindsStatus: previousKinds, ignoredPaths: previousIgnored),
                next: buildGitStatusMap(kindsStatus: nextKinds, ignoredPaths: nextIgnored)
            )
        }
        let remove = previousIgnored.filter { !nextIgnored.contains($0) && nextKinds[$0] == nil }.sorted()
        let set = nextIgnored.filter { !previousIgnored.contains($0) && nextKinds[$0] == nil }.sorted().map {
            GitStatusPatchEntry(path: $0, status: .ignored)
        }
        return GitStatusPatch(remove: remove, set: set)
    }
}

// MARK: - Open In App, Picker, Search, Link Exists & Link Open Machines

public enum OpenInAppMachine: GUIStateMachine {
    public static let checkTimeoutMs = 10_000
    public static let launchTimeoutMs = 10_000

    public enum AppCheck: Equatable, Sendable {
        case checking(attempt: Int)
        case settled(installed: Bool)
    }

    public enum LaunchState: Equatable, Sendable {
        case idle
        case launching(attempt: Int, app: OpenApp)
    }

    public enum State: Equatable, Sendable {
        case active(issued: Int, apps: [String: AppCheck], launch: LaunchState)
        case disposed
    }

    public enum Event: Equatable, Sendable {
        case appsRequested(openWith: [String])
        case appChecked(attempt: Int, openWith: String, installed: Bool)
        case appCheckDropped(attempt: Int, openWith: String)
        case launchRequested(app: OpenApp, target: String, openWith: String?, reveal: Bool)
        case launchSucceeded(attempt: Int)
        case launchFailed(attempt: Int, error: String)
        case launchTimedOut(attempt: Int)
        case disposed
    }

    public enum Effect: Equatable, Sendable {
        case checkApp(attempt: Int, openWith: String, timeoutMs: Int)
        case runLaunch(attempt: Int, target: String, openWith: String?, reveal: Bool, timeoutMs: Int)
        case clearTimer(attempt: Int)
        case toastFailed(error: String)
    }

    public static func createState() -> State {
        .active(issued: 0, apps: [:], launch: .idle)
    }

    public static func reduce(state: State, event: Event) -> GUIStateTransition<State, Effect> {
        guard case .active(var issued, var apps, let launch) = state else {
            return GUIStateTransition(state: state)
        }
        switch event {
        case .disposed:
            var effects: [Effect] = []
            for key in apps.keys.sorted() {
                if case .checking(let attempt) = apps[key] {
                    effects.append(.clearTimer(attempt: attempt))
                }
            }
            if case .launching(let attempt, _) = launch {
                effects.append(.clearTimer(attempt: attempt))
            }
            return GUIStateTransition(state: .disposed, effects: effects)

        case .appsRequested(let openWith):
            var seen: Set<String> = []
            let missing = openWith.filter { seen.insert($0).inserted && apps[$0] == nil }
            guard !missing.isEmpty else { return GUIStateTransition(state: state) }
            var effects: [Effect] = []
            for key in missing {
                issued += 1
                apps[key] = .checking(attempt: issued)
                effects.append(.checkApp(attempt: issued, openWith: key, timeoutMs: checkTimeoutMs))
            }
            return GUIStateTransition(state: .active(issued: issued, apps: apps, launch: launch), effects: effects)

        case .appChecked(let attempt, let openWith, let installed):
            guard case .checking(let currentAttempt) = apps[openWith], currentAttempt == attempt else {
                return GUIStateTransition(state: state)
            }
            apps[openWith] = .settled(installed: installed)
            return GUIStateTransition(
                state: .active(issued: issued, apps: apps, launch: launch),
                effects: [.clearTimer(attempt: attempt)]
            )

        case .appCheckDropped(let attempt, let openWith):
            guard case .checking(let currentAttempt) = apps[openWith], currentAttempt == attempt else {
                return GUIStateTransition(state: state)
            }
            apps.removeValue(forKey: openWith)
            return GUIStateTransition(
                state: .active(issued: issued, apps: apps, launch: launch),
                effects: [.clearTimer(attempt: attempt)]
            )

        case .launchRequested(let app, let target, let openWith, let reveal):
            guard !target.isEmpty, case .idle = launch else { return GUIStateTransition(state: state) }
            issued += 1
            return GUIStateTransition(
                state: .active(issued: issued, apps: apps, launch: .launching(attempt: issued, app: app)),
                effects: [
                    .runLaunch(
                        attempt: issued,
                        target: target,
                        openWith: openWith,
                        reveal: app == .finder && reveal,
                        timeoutMs: launchTimeoutMs
                    ),
                ]
            )

        case .launchSucceeded(let attempt), .launchTimedOut(let attempt):
            guard case .launching(let currentAttempt, _) = launch, currentAttempt == attempt else {
                return GUIStateTransition(state: state)
            }
            return GUIStateTransition(
                state: .active(issued: issued, apps: apps, launch: .idle),
                effects: [.clearTimer(attempt: attempt)]
            )

        case .launchFailed(let attempt, let error):
            guard case .launching(let currentAttempt, _) = launch, currentAttempt == attempt else {
                return GUIStateTransition(state: state)
            }
            return GUIStateTransition(
                state: .active(issued: issued, apps: apps, launch: .idle),
                effects: [.clearTimer(attempt: attempt), .toastFailed(error: error)]
            )
        }
    }

    public static func isAppInstalled(_ state: State, openWith: String) -> Bool {
        guard case .active(_, let apps, _) = state, case .settled(let installed) = apps[openWith] else {
            return false
        }
        return installed
    }

    public static func isLaunching(_ state: State) -> Bool {
        if case .active(_, _, .launching) = state { return true }
        return false
    }
}

public enum FilePickerMachine: GUIStateMachine {
    public static let maxSessions = 40
    public static let focusTimeoutMs = 2_000

    public struct Filter: Equatable, Hashable, Sendable {
        public let text: String
        public let browsing: Bool

        public init(text: String, browsing: Bool) {
            self.text = text
            self.browsing = browsing
        }
    }

    public enum FocusTarget: Equatable, Hashable, Sendable {
        case launcher(tabID: String)
        case mobile
    }

    public enum Focus: Equatable, Sendable {
        case none
        case requested(request: Int, sessionKey: String, target: FocusTarget)
    }

    public enum View: Equatable, Sendable {
        case side(sessionKey: String, tabID: String, visible: Bool)
        case mobile(sessionKey: String, browsing: Bool, visible: Bool)
    }

    public enum State: Equatable, Sendable {
        case active(issued: Int, filters: [String: Filter], order: [String], focus: Focus)
        case disposed
    }

    public enum Event: Equatable, Sendable {
        case pickerOpened(sessionKey: String, query: String, target: FocusTarget, background: Bool)
        case filterChanged(sessionKey: String, text: String)
        case browsingSet(sessionKey: String, browsing: Bool)
        case fileOpened(sessionKey: String)
        case launcherClosed(sessionKey: String, tabID: String)
        case focusEnded(request: Int)
        case disposed
    }

    public enum Effect: Equatable, Sendable {
        case startFocusTimer(request: Int, timeoutMs: Int)
        case cancelFocusTimer
    }

    public static func createState() -> State {
        .active(issued: 0, filters: [:], order: [], focus: .none)
    }

    public static func reduce(state: State, event: Event) -> GUIStateTransition<State, Effect> {
        guard case .active(let issued, let filters, let order, let focus) = state else {
            return GUIStateTransition(state: state)
        }
        switch event {
        case .disposed:
            let cancel: [Effect] = if case .requested = focus { [.cancelFocusTimer] } else { [] }
            return GUIStateTransition(state: .disposed, effects: cancel)

        case .pickerOpened(let sessionKey, let query, let target, let background):
            let patched = patchFilters(filters: filters, order: order, sessionKey: sessionKey, text: query, browsing: true)
            if background {
                let nextFocus = ownedBy(focus, sessionKey: sessionKey) ? Focus.none : focus
                return update(
                    issued: issued,
                    currentFilters: filters,
                    currentOrder: order,
                    currentFocus: focus,
                    nextFilters: patched.filters,
                    nextOrder: patched.order,
                    nextFocus: nextFocus
                )
            }
            let request = issued + 1
            return GUIStateTransition(
                state: .active(
                    issued: request,
                    filters: patched.filters,
                    order: patched.order,
                    focus: .requested(request: request, sessionKey: sessionKey, target: target)
                ),
                effects: [.startFocusTimer(request: request, timeoutMs: focusTimeoutMs)]
            )

        case .filterChanged(let sessionKey, let text):
            let patched = patchFilters(filters: filters, order: order, sessionKey: sessionKey, text: text, browsing: nil)
            return update(
                issued: issued,
                currentFilters: filters,
                currentOrder: order,
                currentFocus: focus,
                nextFilters: patched.filters,
                nextOrder: patched.order,
                nextFocus: focus
            )

        case .browsingSet(let sessionKey, let browsing):
            let patched = patchFilters(filters: filters, order: order, sessionKey: sessionKey, text: nil, browsing: browsing)
            let cancel: Bool
            if !browsing, case .requested(_, let owner, .mobile) = focus, owner == sessionKey {
                cancel = true
            } else {
                cancel = false
            }
            return update(
                issued: issued,
                currentFilters: filters,
                currentOrder: order,
                currentFocus: focus,
                nextFilters: patched.filters,
                nextOrder: patched.order,
                nextFocus: cancel ? .none : focus
            )

        case .fileOpened(let sessionKey):
            let patched = patchFilters(filters: filters, order: order, sessionKey: sessionKey, text: nil, browsing: false)
            let nextFocus = ownedBy(focus, sessionKey: sessionKey) ? Focus.none : focus
            return update(
                issued: issued,
                currentFilters: filters,
                currentOrder: order,
                currentFocus: focus,
                nextFilters: patched.filters,
                nextOrder: patched.order,
                nextFocus: nextFocus
            )

        case .launcherClosed(let sessionKey, let tabID):
            let cancel: Bool
            if case .requested(_, let owner, .launcher(let targetTab)) = focus, owner == sessionKey, targetTab == tabID {
                cancel = true
            } else {
                cancel = false
            }
            return update(
                issued: issued,
                currentFilters: filters,
                currentOrder: order,
                currentFocus: focus,
                nextFilters: filters,
                nextOrder: order,
                nextFocus: cancel ? .none : focus
            )

        case .focusEnded(let request):
            let ended: Bool
            if case .requested(let currentRequest, _, _) = focus, currentRequest == request {
                ended = true
            } else {
                ended = false
            }
            return update(
                issued: issued,
                currentFilters: filters,
                currentOrder: order,
                currentFocus: focus,
                nextFilters: filters,
                nextOrder: order,
                nextFocus: ended ? .none : focus
            )
        }
    }

    public static func filterText(_ state: State, sessionKey: String) -> String {
        guard case .active(_, let filters, _, _) = state else { return "" }
        return filters[sessionKey]?.text ?? ""
    }

    public static func browsing(_ state: State, sessionKey: String) -> Bool {
        guard case .active(_, let filters, _, _) = state else { return false }
        return filters[sessionKey]?.browsing ?? false
    }

    public static func focusRequest(_ state: State, view: View) -> Int? {
        guard case .active(_, _, _, .requested(let request, let sessionKey, let target)) = state else {
            return nil
        }
        switch view {
        case .side(let viewSession, let tabID, let visible):
            guard visible, viewSession == sessionKey, case .launcher(let targetTab) = target, targetTab == tabID else {
                return nil
            }
            return request
        case .mobile(let viewSession, let browsing, let visible):
            guard visible, viewSession == sessionKey, browsing, case .mobile = target else {
                return nil
            }
            return request
        }
    }

    private static func ownedBy(_ focus: Focus, sessionKey: String) -> Bool {
        if case .requested(_, let owner, _) = focus { return owner == sessionKey }
        return false
    }

    private static func update(
        issued: Int,
        currentFilters: [String: Filter],
        currentOrder: [String],
        currentFocus: Focus,
        nextFilters: [String: Filter],
        nextOrder: [String],
        nextFocus: Focus
    ) -> GUIStateTransition<State, Effect> {
        if nextFilters == currentFilters && nextOrder == currentOrder && nextFocus == currentFocus {
            return GUIStateTransition(state: .active(issued: issued, filters: currentFilters, order: currentOrder, focus: currentFocus))
        }
        let effects: [Effect] = nextFocus == currentFocus ? [] : [.cancelFocusTimer]
        return GUIStateTransition(
            state: .active(issued: issued, filters: nextFilters, order: nextOrder, focus: nextFocus),
            effects: effects
        )
    }

    private static func patchFilters(
        filters: [String: Filter],
        order: [String],
        sessionKey: String,
        text changeText: String?,
        browsing changeBrowsing: Bool?
    ) -> (filters: [String: Filter], order: [String]) {
        let current = filters[sessionKey]
        let text = changeText ?? current?.text ?? ""
        let browsing = changeBrowsing ?? current?.browsing ?? false
        if current?.text == text && current?.browsing == browsing {
            return (filters, order)
        }
        if current == nil && text.isEmpty && !browsing {
            return (filters, order)
        }
        var nextFilters = filters
        var nextOrder = order.filter { $0 != sessionKey }
        if !text.isEmpty || browsing {
            nextFilters[sessionKey] = Filter(text: text, browsing: browsing)
            nextOrder.append(sessionKey)
        } else {
            nextFilters.removeValue(forKey: sessionKey)
        }
        while nextOrder.count > maxSessions {
            let evicted = nextOrder.removeFirst()
            nextFilters.removeValue(forKey: evicted)
        }
        return (nextFilters, nextOrder)
    }
}

public enum FileSearchMachine: GUIStateMachine {
    public static let timeoutMs = 10_000

    public struct Scope: Equatable, Hashable, Sendable {
        public let serverID: String
        public let root: String

        public init(serverID: String, root: String) {
            self.serverID = serverID
            self.root = root
        }
    }

    public struct Context: Equatable, Sendable {
        public let scope: Scope
        public let connected: Bool
        public let query: String

        public init(scope: Scope, connected: Bool, query: String) {
            self.scope = scope
            self.connected = connected
            self.query = query
        }
    }

    public enum Failure: Equatable, Hashable, Sendable {
        case rejected(message: String)
        case timeout
    }

    public struct Previous: Equatable, Sendable {
        public let query: String
        public let files: [String]

        public init(query: String, files: [String]) {
            self.query = query
            self.files = files
        }
    }

    public enum State: Equatable, Sendable {
        case idle(attempt: Int)
        case offline(scope: Scope, query: String, attempt: Int)
        case searching(scope: Scope, query: String, attempt: Int, previous: Previous?)
        case ready(scope: Scope, query: String, connected: Bool, attempt: Int, files: [String])
        case error(scope: Scope, query: String, attempt: Int, failure: Failure)
        case disposed(attempt: Int)

        public var attempt: Int {
            switch self {
            case .idle(let a), .offline(_, _, let a), .searching(_, _, let a, _), .ready(_, _, _, let a, _), .error(_, _, let a, _), .disposed(let a):
                return a
            }
        }
    }

    public enum Event: Equatable, Sendable {
        case contextChanged(Context)
        case retry
        case searchSucceeded(attempt: Int, files: [String])
        case searchFailed(attempt: Int, message: String)
        case searchTimedOut(attempt: Int)
        case disposed
    }

    public enum Effect: Equatable, Sendable {
        case search(scope: Scope, query: String, attempt: Int, timeoutMs: Int)
        case abort(attempt: Int)
    }

    public enum View: Equatable, Sendable {
        case tree
        case loading
        case offline
        case error(failure: Failure)
        case results(files: [String], stale: Bool)
    }

    public static let initialState: State = .idle(attempt: 0)

    public static func reduce(state: State, event: Event) -> GUIStateTransition<State, Effect> {
        if case .disposed = state { return GUIStateTransition(state: state) }

        switch event {
        case .disposed:
            return leave(state: state, next: .disposed(attempt: state.attempt))

        case .contextChanged(let context):
            return handleContextChanged(state: state, context: context)

        case .retry:
            if case .error(let scope, let query, _, _) = state {
                return startSearch(state: state, scope: scope, query: query, previous: nil)
            }
            return GUIStateTransition(state: state)

        case .searchSucceeded(let attempt, let files):
            guard case .searching(let scope, let query, let currentAttempt, _) = state, currentAttempt == attempt else {
                return GUIStateTransition(state: state)
            }
            var seen: Set<String> = []
            let unique = files.filter { seen.insert($0).inserted }
            return GUIStateTransition(
                state: .ready(scope: scope, query: query, connected: true, attempt: currentAttempt, files: unique)
            )

        case .searchFailed(let attempt, let message):
            guard case .searching(let scope, let query, let currentAttempt, _) = state, currentAttempt == attempt else {
                return GUIStateTransition(state: state)
            }
            return GUIStateTransition(
                state: .error(scope: scope, query: query, attempt: currentAttempt, failure: .rejected(message: message))
            )

        case .searchTimedOut(let attempt):
            guard case .searching(let scope, let query, let currentAttempt, _) = state, currentAttempt == attempt else {
                return GUIStateTransition(state: state)
            }
            return GUIStateTransition(
                state: .error(scope: scope, query: query, attempt: currentAttempt, failure: .timeout),
                effects: [.abort(attempt: currentAttempt)]
            )
        }
    }

    public static func view(_ state: State) -> View {
        switch state {
        case .idle, .disposed: return .tree
        case .offline: return .offline
        case .error(_, _, _, let failure): return .error(failure: failure)
        case .ready(_, _, _, _, let files): return .results(files: files, stale: false)
        case .searching(_, _, _, let previous):
            return previous.map { .results(files: $0.files, stale: true) } ?? .loading
        }
    }

    private static func handleContextChanged(state: State, context: Context) -> GUIStateTransition<State, Effect> {
        if context.query.isEmpty {
            if case .idle = state { return GUIStateTransition(state: state) }
            return leave(state: state, next: .idle(attempt: state.attempt))
        }

        let same: Bool
        switch state {
        case .offline(let s, let q, _), .searching(let s, let q, _, _), .ready(let s, let q, _, _, _), .error(let s, let q, _, _):
            same = (s == context.scope && q == context.query)
        case .idle, .disposed:
            same = false
        }

        if !context.connected {
            if same, case .ready(let s, let q, let connected, let a, let files) = state {
                return connected
                    ? GUIStateTransition(state: .ready(scope: s, query: q, connected: false, attempt: a, files: files))
                    : GUIStateTransition(state: state)
            }
            if same, case .offline = state { return GUIStateTransition(state: state) }
            return leave(state: state, next: .offline(scope: context.scope, query: context.query, attempt: state.attempt))
        }

        if same {
            switch state {
            case .searching, .error: return GUIStateTransition(state: state)
            case .ready(_, _, true, _, _): return GUIStateTransition(state: state)
            default: break
            }
        }

        let previous: Previous?
        switch state {
        case .ready(let s, let q, _, _, let files) where s == context.scope:
            previous = Previous(query: q, files: files)
        case .searching(let s, _, _, let prev) where s == context.scope:
            previous = prev
        default:
            previous = nil
        }
        return startSearch(state: state, scope: context.scope, query: context.query, previous: previous)
    }

    private static func startSearch(
        state: State,
        scope: Scope,
        query: String,
        previous: Previous?
    ) -> GUIStateTransition<State, Effect> {
        let nextAttempt = state.attempt + 1
        let begin: Effect = .search(scope: scope, query: query, attempt: nextAttempt, timeoutMs: timeoutMs)
        let effects: [Effect]
        if case .searching(_, _, let prevAttempt, _) = state {
            effects = [.abort(attempt: prevAttempt), begin]
        } else {
            effects = [begin]
        }
        return GUIStateTransition(
            state: .searching(scope: scope, query: query, attempt: nextAttempt, previous: previous),
            effects: effects
        )
    }

    private static func leave(state: State, next: State) -> GUIStateTransition<State, Effect> {
        if case .searching(_, _, let attempt, _) = state {
            return GUIStateTransition(state: next, effects: [.abort(attempt: attempt)])
        }
        return GUIStateTransition(state: next)
    }
}

public struct ParsedFileLink: Equatable, Sendable {
    public let path: String
    public let selection: LineRangeSelection?

    public init(path: String, selection: LineRangeSelection?) {
        self.path = path
        self.selection = selection
    }
}

public enum FileLinkTarget: Equatable, Hashable, Sendable {
    case file(path: String)
    case picker(query: String)
}

public enum FileLinkResolver {
    public static func parseFileLink(_ href: String) -> ParsedFileLink {
        let raw = href.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\\", with: "/")
        let isFileURL = raw.lowercased().hasPrefix("file://")
        let extracted = extractLineSelection(raw, isFileURL: isFileURL)
        return ParsedFileLink(
            path: normalizeRelativeSegments(extracted.path, decode: isFileURL),
            selection: extracted.selection
        )
    }

    public static func isAbsoluteLink(_ path: String) -> Bool {
        let lower = path.lowercased()
        if lower.hasPrefix("skill://") || path.hasPrefix("/") { return true }
        let chars = Array(path)
        return chars.count >= 3 && chars[0].isLetter && chars[1] == ":" && chars[2] == "/"
    }

    public static func matchRelativeLink(path: String, searchResults: [String]) -> FileLinkTarget? {
        var query = path
        while query.hasPrefix("../") {
            query.removeFirst(3)
        }
        guard !query.isEmpty else { return nil }
        var seen: Set<String> = []
        let matches = searchResults.filter { seen.insert($0).inserted && ($0 == query || $0.hasSuffix("/\(query)")) }
        if let literal = matches.first(where: { $0 == query }) {
            return .file(path: literal)
        }
        if matches.count == 1, let only = matches.first {
            return .file(path: only)
        }
        if matches.count > 1 {
            return .picker(query: query)
        }
        return nil
    }

    private static func extractLineSelection(_ input: String, isFileURL: Bool) -> ParsedPathLineSuffix {
        let parsed = parsePathLineSuffix(input)
        if parsed.selection != nil || parsed.path != input {
            let cleanPath = isFileURL ? String(parsed.path.split(separator: "?", maxSplits: 1).first ?? "") : parsed.path
            return ParsedPathLineSuffix(path: cleanPath, selection: parsed.selection)
        }
        if !isFileURL {
            return ParsedPathLineSuffix(path: input, selection: nil)
        }
        var withoutFragment = input
        if let hashIndex = input.lastIndex(of: "#") {
            let tail = input[input.index(after: hashIndex)...]
            let before = input[..<hashIndex]
            if !tail.contains("/"), !tail.contains("."), let dot = before.lastIndex(of: ".") {
                let ext = before[before.index(after: dot)...]
                if !ext.isEmpty && ext.allSatisfy({ $0.isLetter || $0.isNumber }) {
                    withoutFragment = String(before)
                }
            }
        }
        let withoutQuery = String(withoutFragment.split(separator: "?", maxSplits: 1).first ?? "")
        return parsePathLineSuffix(withoutQuery)
    }

    private static func normalizeRelativeSegments(_ input: String, decode: Bool) -> String {
        let withoutProtocol: String
        let lower = input.lowercased()
        if lower.hasPrefix("file://") {
            let afterScheme = String(input.dropFirst("file://".count))
            let lowerAfter = afterScheme.lowercased()
            if lowerAfter.hasPrefix("localhost/") {
                let stripped = String(afterScheme.dropFirst("localhost".count))
                withoutProtocol = stripLeadingSlashBeforeDrive(stripped)
            } else if afterScheme.hasPrefix("/") {
                withoutProtocol = stripLeadingSlashBeforeDrive(afterScheme)
            } else if afterScheme.contains("/") {
                withoutProtocol = "//\(afterScheme)"
            } else {
                withoutProtocol = afterScheme
            }
        } else {
            withoutProtocol = input
        }

        let decoded = decode ? (withoutProtocol.removingPercentEncoding ?? withoutProtocol) : withoutProtocol
        var trimmed = decoded
        if trimmed.hasPrefix("./") {
            trimmed.removeFirst(2)
        }
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        if trimmed.isEmpty { return "" }

        let prefix: String
        let rest: String
        if trimmed.lowercased().hasPrefix("skill://") {
            prefix = "skill://"
            rest = String(trimmed.dropFirst("skill://".count))
        } else if trimmed.hasPrefix("//") {
            prefix = "//"
            rest = String(trimmed.dropFirst(2))
        } else if trimmed.count >= 3,
                  let c0 = trimmed.first, c0.isLetter,
                  trimmed[trimmed.index(after: trimmed.startIndex)] == ":",
                  trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)] == "/"
        {
            prefix = String(trimmed.prefix(3))
            rest = String(trimmed.dropFirst(3))
        } else if trimmed.hasPrefix("/") {
            prefix = "/"
            rest = String(trimmed.dropFirst(1))
        } else {
            prefix = ""
            rest = trimmed
        }

        var stack: [String] = []
        for rawPart in rest.split(separator: "/", omittingEmptySubsequences: false) {
            let part = String(rawPart)
            if part.isEmpty || part == "." { continue }
            if part == ".." {
                if let last = stack.last, last != ".." {
                    stack.removeLast()
                } else if prefix.isEmpty {
                    stack.append("..")
                }
                continue
            }
            stack.append(part)
        }
        return "\(prefix)\(stack.joined(separator: "/"))"
    }

    private static func stripLeadingSlashBeforeDrive(_ value: String) -> String {
        let chars = Array(value)
        if chars.count >= 4, chars[0] == "/", chars[1].isLetter, chars[2] == ":", chars[3] == "/" {
            return String(chars.dropFirst())
        }
        return value
    }
}

public enum LinkExistsMachine: GUIStateMachine {
    public static let positiveTTLMs = 60_000
    public static let negativeTTLMs = 5_000
    public static let timeoutMs = 15_000
    public static let maxEntries = 512

    public enum Entry: Equatable, Sendable {
        case checking(attempt: Int, deadline: Int)
        case revalidating(attempt: Int, deadline: Int)
        case stale
        case settled(exists: Bool, expiresAt: Int)
    }

    public struct State: Equatable, Sendable {
        public let issued: Int
        public let entries: [String: Entry]
        public let order: [String]

        public init(issued: Int = 0, entries: [String: Entry] = [:], order: [String] = []) {
            self.issued = issued
            self.entries = entries
            self.order = order
        }
    }

    public enum Event: Equatable, Sendable {
        case checkRequested(key: String, now: Int)
        case checkSettled(key: String, attempt: Int, exists: Bool, now: Int)
        case checkDropped(key: String, attempt: Int)
    }

    public enum Effect: Equatable, Sendable {
        case runCheck(key: String, attempt: Int, timeoutMs: Int)
        case abortCheck(attempt: Int)
    }

    public enum Answer: Equatable, Sendable {
        case value(Bool)
        case pending(attempt: Int)
    }

    public static func createState() -> State {
        State()
    }

    public static func reduce(state: State, event: Event) -> GUIStateTransition<State, Effect> {
        switch event {
        case .checkRequested(let key, let now):
            let existing = state.entries[key]
            if case .settled(_, let expiresAt) = existing, now < expiresAt {
                return GUIStateTransition(state: state)
            }
            switch existing {
            case .checking(_, let deadline) where now < deadline,
                 .revalidating(_, let deadline) where now < deadline:
                return GUIStateTransition(state: state)
            default:
                break
            }

            let attempt = state.issued + 1
            let deadline = now + timeoutMs
            let known: Bool
            switch existing {
            case .stale, .revalidating: known = true
            case .settled(true, _): known = true
            default: known = false
            }

            var nextEntries = state.entries
            var nextOrder = state.order.filter { $0 != key }
            nextEntries[key] = known ? .revalidating(attempt: attempt, deadline: deadline) : .checking(attempt: attempt, deadline: deadline)
            nextOrder.append(key)

            var aborts: [Effect] = []
            if case .checking(let oldAttempt, _) = existing {
                aborts.append(.abortCheck(attempt: oldAttempt))
            } else if case .revalidating(let oldAttempt, _) = existing {
                aborts.append(.abortCheck(attempt: oldAttempt))
            }

            while nextOrder.count > maxEntries {
                let evicted = nextOrder.removeFirst()
                if let evictedEntry = nextEntries.removeValue(forKey: evicted) {
                    switch evictedEntry {
                    case .checking(let oldAttempt, _), .revalidating(let oldAttempt, _):
                        aborts.append(.abortCheck(attempt: oldAttempt))
                    default:
                        break
                    }
                }
            }

            return GUIStateTransition(
                state: State(issued: attempt, entries: nextEntries, order: nextOrder),
                effects: aborts + [.runCheck(key: key, attempt: attempt, timeoutMs: timeoutMs)]
            )

        case .checkSettled(let key, let attempt, let exists, let now):
            guard let existing = state.entries[key], isMatchingInFlight(existing, attempt: attempt) else {
                return GUIStateTransition(state: state)
            }
            var nextEntries = state.entries
            nextEntries[key] = .settled(exists: exists, expiresAt: now + (exists ? positiveTTLMs : negativeTTLMs))
            return GUIStateTransition(
                state: State(issued: state.issued, entries: nextEntries, order: state.order),
                effects: [.abortCheck(attempt: attempt)]
            )

        case .checkDropped(let key, let attempt):
            guard let existing = state.entries[key], isMatchingInFlight(existing, attempt: attempt) else {
                return GUIStateTransition(state: state)
            }
            var nextEntries = state.entries
            var nextOrder = state.order
            if case .checking = existing {
                nextEntries.removeValue(forKey: key)
                nextOrder.removeAll { $0 == key }
            } else {
                nextEntries[key] = .stale
            }
            return GUIStateTransition(
                state: State(issued: state.issued, entries: nextEntries, order: nextOrder),
                effects: [.abortCheck(attempt: attempt)]
            )
        }
    }

    public static func answer(_ state: State, key: String) -> Answer {
        guard let entry = state.entries[key] else { return .value(false) }
        switch entry {
        case .checking(let attempt, _): return .pending(attempt: attempt)
        case .settled(let exists, _): return .value(exists)
        case .revalidating, .stale: return .value(true)
        }
    }

    private static func isMatchingInFlight(_ entry: Entry, attempt: Int) -> Bool {
        switch entry {
        case .checking(let a, _), .revalidating(let a, _): return a == attempt
        default: return false
        }
    }
}

public enum LinkOpenMachine: GUIStateMachine {
    public static let timeoutMs = 30_000

    public enum Resolution: Equatable, Sendable {
        case missing
        case picker(query: String)
        case browser(url: String)
        case file(path: String, selection: LineRangeSelection?)
    }

    public struct Route: Equatable, Sendable {
        public let sessionKey: String?
        public let root: String?
        public let sameScreen: Bool

        public init(sessionKey: String?, root: String?, sameScreen: Bool) {
            self.sessionKey = sessionKey
            self.root = root
            self.sameScreen = sameScreen
        }
    }

    public enum State: Equatable, Sendable {
        case idle(issued: Int)
        case resolving(attempt: Int, sessionKey: String, root: String, href: String, background: Bool)
        case loading(
            attempt: Int,
            sessionKey: String,
            root: String,
            background: Bool,
            path: String,
            selection: LineRangeSelection?
        )
        case disposed
    }

    public enum Event: Equatable, Sendable {
        case linkExact(href: String, path: String, background: Bool)
        case linkClicked(sessionKey: String, root: String, href: String, base: String?, background: Bool)
        case linkResolved(attempt: Int, route: Route, resolution: Resolution)
        case fileSynced(attempt: Int, route: Route, loaded: Bool, notFound: Bool, opened: Bool, error: String?)
        case linkFailed(attempt: Int, route: Route, error: String)
        case linkCancelled(attempt: Int)
        case linkTimedOut(attempt: Int)
        case disposed
    }

    public enum Effect: Equatable, Sendable {
        case resolve(attempt: Int, href: String, base: String?, background: Bool, timeoutMs: Int)
        case sync(attempt: Int, path: String)
        case abort(attempt: Int)
        case openExact(path: String, background: Bool)
        case openFile(path: String, selection: LineRangeSelection?, background: Bool)
        case openPicker(query: String, background: Bool)
        case openBrowser(url: String)
        case toastFailed(path: String, error: String?)
        case toastTimeout(path: String)
    }

    public static func createState() -> State {
        .idle(issued: 0)
    }

    public static func reduce(state: State, event: Event) -> GUIStateTransition<State, Effect> {
        if case .disposed = state { return GUIStateTransition(state: state) }

        switch event {
        case .disposed:
            return GUIStateTransition(state: .disposed, effects: abortActive(state))

        case .linkExact(let href, let path, let background):
            let nextIssued = lastAttempt(state) + 1
            let action: Effect = path.isEmpty
                ? .toastFailed(path: href, error: nil)
                : .openExact(path: path, background: background)
            return GUIStateTransition(state: .idle(issued: nextIssued), effects: abortActive(state) + [action])

        case .linkClicked(let sessionKey, let root, let href, let base, let background):
            let attempt = lastAttempt(state) + 1
            return GUIStateTransition(
                state: .resolving(attempt: attempt, sessionKey: sessionKey, root: root, href: href, background: background),
                effects: abortActive(state) + [.resolve(attempt: attempt, href: href, base: base, background: background, timeoutMs: timeoutMs)]
            )

        case .linkCancelled(let attempt):
            guard activeAttempt(state) == attempt else { return GUIStateTransition(state: state) }
            return finish(attempt: attempt, trailing: [])

        case .linkTimedOut(let attempt):
            guard activeAttempt(state) == attempt, let target = targetPath(state) else {
                return GUIStateTransition(state: state)
            }
            return finish(attempt: attempt, trailing: [.toastTimeout(path: target)])

        case .linkFailed(let attempt, let route, let error):
            guard activeAttempt(state) == attempt, let target = targetPath(state) else {
                return GUIStateTransition(state: state)
            }
            guard sameRoute(state: state, route: route) else {
                return finish(attempt: attempt, trailing: [])
            }
            return finish(attempt: attempt, trailing: [.toastFailed(path: target, error: error)])

        case .linkResolved(let attempt, let route, let resolution):
            guard case .resolving(let currentAttempt, let sessionKey, let root, let href, let background) = state,
                  currentAttempt == attempt
            else {
                return GUIStateTransition(state: state)
            }
            guard sameRoute(state: state, route: route) else {
                return finish(attempt: attempt, trailing: [])
            }
            switch resolution {
            case .missing:
                return finish(attempt: attempt, trailing: [.toastFailed(path: href, error: nil)])
            case .picker(let query):
                return finish(attempt: attempt, trailing: [.openPicker(query: query, background: background)])
            case .browser(let url):
                return finish(attempt: attempt, trailing: [.openBrowser(url: url)])
            case .file(let path, let selection):
                return GUIStateTransition(
                    state: .loading(
                        attempt: attempt,
                        sessionKey: sessionKey,
                        root: root,
                        background: background,
                        path: path,
                        selection: selection
                    ),
                    effects: [.sync(attempt: attempt, path: path)]
                )
            }

        case .fileSynced(let attempt, let route, let loaded, let notFound, let opened, let error):
            guard case .loading(let currentAttempt, _, _, let background, let path, let selection) = state,
                  currentAttempt == attempt
            else {
                return GUIStateTransition(state: state)
            }
            guard sameRoute(state: state, route: route) else {
                return finish(attempt: attempt, trailing: [])
            }
            let openEffect: Effect = .openFile(path: path, selection: selection, background: background)
            if loaded {
                let trailing: [Effect] = error.map { [openEffect, .toastFailed(path: path, error: $0)] } ?? [openEffect]
                return finish(attempt: attempt, trailing: trailing)
            }
            if notFound && opened {
                return finish(attempt: attempt, trailing: [openEffect])
            }
            return finish(attempt: attempt, trailing: [.toastFailed(path: path, error: error)])
        }
    }

    private static func finish(attempt: Int, trailing: [Effect]) -> GUIStateTransition<State, Effect> {
        GUIStateTransition(state: .idle(issued: attempt), effects: [.abort(attempt: attempt)] + trailing)
    }

    private static func abortActive(_ state: State) -> [Effect] {
        activeAttempt(state).map { [.abort(attempt: $0)] } ?? []
    }

    private static func activeAttempt(_ state: State) -> Int? {
        switch state {
        case .resolving(let a, _, _, _, _), .loading(let a, _, _, _, _, _): return a
        case .idle, .disposed: return nil
        }
    }

    private static func lastAttempt(_ state: State) -> Int {
        switch state {
        case .idle(let issued): return issued
        case .resolving(let a, _, _, _, _), .loading(let a, _, _, _, _, _): return a
        case .disposed: return 0
        }
    }

    private static func targetPath(_ state: State) -> String? {
        switch state {
        case .resolving(_, _, _, let href, _): return href
        case .loading(_, _, _, _, let path, _): return path
        case .idle, .disposed: return nil
        }
    }

    private static func sameRoute(state: State, route: Route) -> Bool {
        switch state {
        case .resolving(_, let s, let r, _, _), .loading(_, let s, let r, _, _, _):
            return route.sameScreen && route.sessionKey == s && route.root == r
        case .idle, .disposed:
            return false
        }
    }
}

// MARK: - File Browser Controller Actor

/// Actor coordinating file tree directory expansion, search, picker filters, artifact viewer state, and open-in-app state.
public actor FileBrowserController {
    private var expandedDirectories: Set<String> = []
    private var pickerState: FilePickerMachine.State = FilePickerMachine.createState()
    private var searchState: FileSearchMachine.State = FileSearchMachine.initialState
    private var openInAppState: OpenInAppMachine.State = OpenInAppMachine.createState()
    private var preferredApp: OpenApp = .finder

    public init(preferredApp: OpenApp = .finder) {
        self.preferredApp = preferredApp
    }

    public func isExpanded(_ directory: String) -> Bool {
        expandedDirectories.contains(FileTreeModel.normalizePath(directory))
    }

    public func toggleDirectory(_ directory: String) -> Bool {
        let norm = FileTreeModel.normalizePath(directory)
        if expandedDirectories.contains(norm) {
            expandedDirectories.remove(norm)
            return false
        }
        expandedDirectories.insert(norm)
        return true
    }

    public func setExpanded(_ directory: String, expanded: Bool) {
        let norm = FileTreeModel.normalizePath(directory)
        if expanded {
            expandedDirectories.insert(norm)
        } else {
            expandedDirectories.remove(norm)
        }
    }

    public func dispatchPicker(_ event: FilePickerMachine.Event) -> [FilePickerMachine.Effect] {
        let transition = FilePickerMachine.reduce(state: pickerState, event: event)
        pickerState = transition.state
        return transition.effects
    }

    public func dispatchSearch(_ event: FileSearchMachine.Event) -> [FileSearchMachine.Effect] {
        let transition = FileSearchMachine.reduce(state: searchState, event: event)
        searchState = transition.state
        return transition.effects
    }

    public func dispatchOpenInApp(_ event: OpenInAppMachine.Event) -> [OpenInAppMachine.Effect] {
        let transition = OpenInAppMachine.reduce(state: openInAppState, event: event)
        openInAppState = transition.state
        return transition.effects
    }

    public func setPreferredApp(_ app: OpenApp) {
        preferredApp = app
    }

    public func currentPreferredApp() -> OpenApp {
        preferredApp
    }

    public func currentSearchView() -> FileSearchMachine.View {
        FileSearchMachine.view(searchState)
    }

    public func currentPickerState() -> FilePickerMachine.State {
        pickerState
    }

    public func currentOpenInAppState() -> OpenInAppMachine.State {
        openInAppState
    }
}
