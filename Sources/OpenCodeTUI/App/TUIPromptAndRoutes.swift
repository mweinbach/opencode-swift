#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Synchronization
import OpenCodeClient
import OpenCodeCore
import OpenCodePlatform
import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeUtil
import OpenTUICore
import OpenTUIKeymap
import OpenTUILayout
import OpenTUIRenderables
import OpenTUITerminal
import OpenTUIView

// MARK: - Prompt Engine (`packages/tui/src/prompt/*`)

/// Prompt parsing, history, stash, frecency, attachments, mentions, directory completion, and composer traits.
public enum TUIPrompt {
    public enum PromptError: Error, Equatable, Sendable, CustomStringConvertible {
        case unsupportedInlineAttachment(String)
        case missingMedia(String)

        public var description: String {
            switch self {
            case .unsupportedInlineAttachment(let uri): return "Unsupported inline attachment: \(uri)"
            case .missingMedia(let uri): return "Media is no longer stored: \(uri)"
            }
        }
    }

    // MARK: - Content (`packages/tui/src/prompt/content.ts`)

    /// Strips a single trailing newline (`\r\n` or `\n`) from single-line editor content while preserving multiline text.
    // parity: tui/src/prompt/content.ts#normalizePromptContent [status=implemented hash=6d25c66376fb]
    public static func normalizePromptContent(_ content: String) -> String {
        if content.hasSuffix("\r\n") {
            let body = String(content.dropLast(2))
            return (!body.contains("\n") && !body.contains("\r")) ? body : content
        }
        if content.hasSuffix("\n") {
            let body = String(content.dropLast(1))
            return (!body.contains("\n") && !body.contains("\r")) ? body : content
        }
        return content
    }

    // MARK: - Parse (`packages/tui/src/prompt/parse.ts`)

    public struct FileLineRange: Equatable, Hashable, Sendable, Codable {
        public let startLine: Int
        public let endLine: Int?

        public init(startLine: Int, endLine: Int? = nil) {
            self.startLine = startLine
            self.endLine = endLine
        }
    }

    public struct ParsedFileLineRange: Equatable, Hashable, Sendable, Codable {
        public let base: String
        public let lineRange: FileLineRange?

        public init(base: String, lineRange: FileLineRange? = nil) {
            self.base = base
            self.lineRange = lineRange
        }
    }

    /// Parses `path#start` or `path#start-end` suffixes.
    // parity: tui/src/prompt/parse.ts#parseFileLineRange [status=implemented hash=52865c9f06e7]
    public static func parseFileLineRange(_ input: String) -> ParsedFileLineRange {
        guard let hashIdx = input.lastIndex(of: "#"), hashIdx > input.startIndex else {
            return ParsedFileLineRange(base: input)
        }
        let suffix = String(input[input.index(after: hashIdx)...])
        let parts = suffix.split(separator: "-", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2 else {
            return ParsedFileLineRange(base: input)
        }
        let firstStr = String(parts[0])
        guard !firstStr.isEmpty, firstStr.allSatisfy({ $0 >= "0" && $0 <= "9" }), let startLine = Int(firstStr) else {
            return ParsedFileLineRange(base: input)
        }
        var endLine: Int? = nil
        if parts.count == 2 {
            let secondStr = String(parts[1])
            if !secondStr.isEmpty {
                guard secondStr.allSatisfy({ $0 >= "0" && $0 <= "9" }), let parsedEnd = Int(secondStr) else {
                    return ParsedFileLineRange(base: input)
                }
                if startLine < parsedEnd {
                    endLine = parsedEnd
                }
            }
        }
        return ParsedFileLineRange(
            base: String(input[..<hashIdx]),
            lineRange: FileLineRange(startLine: startLine, endLine: endLine)
        )
    }

    // parity: tui/src/prompt/parse.ts#stripFileLineRange [status=implemented hash=1361864424ea]
    public static func stripFileLineRange(_ input: String) -> String {
        parseFileLineRange(input).base
    }

    public struct SlashHead: Equatable, Hashable, Sendable, Codable {
        public let name: String
        public let arguments: String
        public let end: Int

        public init(name: String, arguments: String, end: Int) {
            self.name = name
            self.arguments = arguments
            self.end = end
        }
    }

    /// Parses leading `/command arguments` header using UTF-16 offsets matching JavaScript `String.length`.
    // parity: tui/src/prompt/parse.ts#parseSlashHead [status=implemented hash=f6a1ed498cd7]
    public static func parseSlashHead(_ text: String, allowAnyWhitespace: Bool = false) -> SlashHead? {
        guard text.hasPrefix("/") else { return nil }
        let u = Array(text.utf16)
        var split = -1
        for i in 1..<u.count {
            let c = u[i]
            let isSep = allowAnyWhitespace
                ? (c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x0B || c == 0x0C)
                : (c == 0x20 || c == 0x09 || c == 0x0A)
            if isSep {
                split = i
                break
            }
        }
        if split == -1 {
            return SlashHead(name: String(decoding: u[1..<u.count], as: UTF16.self), arguments: "", end: u.count)
        }
        return SlashHead(
            name: String(decoding: u[1..<split], as: UTF16.self),
            arguments: String(decoding: u[(split + 1)..<u.count], as: UTF16.self),
            end: split
        )
    }

    // MARK: - Display Width & Trigger Offsets (`packages/tui/src/prompt/display.ts`)

    private static func textWidthMethod(_ widthMethod: WidthMethod) -> TextWidthMethod {
        widthMethod == .wcwidth ? .wcwidth : .unicode
    }

    /// Returns the UTF-16 index of the last grapheme boundary in `value` whose editor display offset is at most `offset`.
    // parity: tui/src/prompt/display.ts#promptOffsetIndex [status=implemented hash=e8029a8a0679]
    public static func promptOffsetIndex(_ value: String, offset: Int, widthMethod: WidthMethod = .unicode) -> Int {
        var boundaries: [Int] = []
        var utf16Pos = 0
        for ch in value {
            boundaries.append(utf16Pos)
            utf16Pos += ch.utf16.count
        }
        boundaries.append(utf16Pos)
        let u = Array(value.utf16)
        let method = textWidthMethod(widthMethod)
        var low = 0
        var high = boundaries.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            let prefix = String(decoding: u[0..<boundaries[middle]], as: UTF16.self)
            if measureEditText(prefix, widthMethod: method) > offset {
                high = middle - 1
            } else {
                low = middle
            }
        }
        return boundaries[low]
    }

    /// Returns the measured editor offset of an active `@mention` trigger, or `nil`.
    // parity: tui/src/prompt/display.ts#mentionTriggerIndex [status=implemented hash=c2a40aff1e1e]
    public static func mentionTriggerIndex(_ text: String, widthMethod: WidthMethod = .unicode) -> Int? {
        guard let atIdx = text.lastIndex(of: "@") else { return nil }
        let before: Character? = atIdx == text.startIndex ? nil : text[text.index(before: atIdx)]
        let query = text[atIdx...]
        let beforeOK = before == nil || before!.isWhitespace
        let queryHasSpace = query.contains(where: \.isWhitespace)
        guard beforeOK && !queryHasSpace else { return nil }
        return measureEditText(String(text[..<atIdx]), widthMethod: textWidthMethod(widthMethod))
    }

    /// Returns the measured editor offset of an active `/command` trigger, or `nil`.
    // parity: tui/src/prompt/display.ts#slashTriggerIndex [status=implemented hash=13b0b19085a8]
    public static func slashTriggerIndex(_ text: String, widthMethod: WidthMethod = .unicode) -> Int? {
        var searchEnd = text.endIndex
        while searchEnd > text.startIndex {
            guard let slashIdx = text[..<searchEnd].lastIndex(of: "/") else { return nil }
            let before: Character? = slashIdx == text.startIndex ? nil : text[text.index(before: slashIdx)]
            if let before, !before.isWhitespace {
                searchEnd = slashIdx
                continue
            }
            let query = text[slashIdx...]
            if query.contains(where: \.isWhitespace) || query.dropFirst().contains("/") {
                return nil
            }
            return measureEditText(String(text[..<slashIdx]), widthMethod: textWidthMethod(widthMethod))
        }
        return nil
    }

    // MARK: - Pasted Parts (`packages/tui/src/prompt/part.ts`)

    public struct TrackedPastedRange: Equatable, Hashable, Sendable, Codable {
        public let start: Int
        public let end: Int
        public let text: String

        public init(start: Int, end: Int, text: String) {
            self.start = start
            self.end = end
            self.text = text
        }
    }

    // parity: tui/src/prompt/part.ts#expandPastedTextPlaceholders [status=implemented hash=0ab1dec08e5b]
    public static func expandPastedTextPlaceholders(
        _ text: String,
        pasted: [PastedText]
    ) -> String {
        let sorted = pasted.sorted { $0.source.start < $1.source.start }
        var cursor = text.startIndex
        var result = ""
        for part in sorted {
            guard !part.source.text.isEmpty,
                  let range = text[cursor...].range(of: part.source.text)
            else { continue }
            result += text[cursor..<range.lowerBound]
            result += part.text
            cursor = range.upperBound
        }
        result += text[cursor...]
        return result
    }

    // parity: tui/src/prompt/part.ts#expandTrackedPastedText [status=implemented hash=9b9af09e545f]
    public static func expandTrackedPastedText(
        _ text: String,
        ranges: [TrackedPastedRange],
        widthMethod: WidthMethod = .unicode
    ) -> String {
        let sorted = ranges.sorted { $0.start > $1.start }
        var resultUTF16 = Array(text.utf16)
        for part in sorted {
            let s = min(resultUTF16.count, promptOffsetIndex(text, offset: part.start, widthMethod: widthMethod))
            let e = min(resultUTF16.count, max(s, promptOffsetIndex(text, offset: part.end, widthMethod: widthMethod)))
            resultUTF16.replaceSubrange(s..<e, with: part.text.utf16)
        }
        return String(decoding: resultUTF16, as: UTF16.self)
    }

    // MARK: - History & Prompt Models (`packages/tui/src/prompt/history.tsx`)

    // parity: tui/src/prompt/history.tsx#PastedText [status=implemented hash=581d911043ff]
    public struct PastedText: Equatable, Hashable, Sendable, Codable {
        public struct Source: Equatable, Hashable, Sendable, Codable {
            public var start: Int
            public var end: Int
            public var text: String

            public init(start: Int, end: Int, text: String) {
                self.start = start
                self.end = end
                self.text = text
            }
        }

        public var text: String
        public var source: Source

        public init(text: String, source: Source) {
            self.text = text
            self.source = source
        }
    }

    // parity: tui/src/prompt/history.tsx#PromptFile [status=implemented hash=a6337e577677]
    public struct PromptFile: Equatable, Hashable, Sendable, Codable {
        public var uri: String
        public var source: PromptSchema.FileSource?
        public var name: String?
        public var description: String?
        public var mention: PromptSchema.PromptMention?
        public var path: String?

        public init(
            uri: String,
            source: PromptSchema.FileSource? = nil,
            name: String? = nil,
            description: String? = nil,
            mention: PromptSchema.PromptMention? = nil,
            path: String? = nil
        ) {
            self.uri = uri
            self.source = source
            self.name = name
            self.description = description
            self.mention = mention
            self.path = path
        }

        public var asSchemaAttachment: PromptInputSchema.FileAttachment {
            PromptInputSchema.FileAttachment(uri: uri, source: source, name: name, description: description, mention: mention)
        }
    }

    // parity: tui/src/prompt/history.tsx#PromptInfo [status=implemented hash=29c648fd2131]
    public struct PromptInfo: Equatable, Hashable, Sendable, Codable {
        public var text: String
        public var files: [PromptFile]
        public var agents: [PromptSchema.AgentAttachment]
        public var skills: [PromptInputSchema.SkillAttachment]
        public var pasted: [PastedText]
        public var mode: PromptMode?

        public init(
            text: String = "",
            files: [PromptFile] = [],
            agents: [PromptSchema.AgentAttachment] = [],
            skills: [PromptInputSchema.SkillAttachment] = [],
            pasted: [PastedText] = [],
            mode: PromptMode? = nil
        ) {
            self.text = text
            self.files = files
            self.agents = agents
            self.skills = skills
            self.pasted = pasted
            self.mode = mode
        }
    }

    // parity: tui/src/prompt/history.tsx#PromptPartRef [status=implemented hash=7c4a68ba9c03]
    public struct PromptPartRef: Equatable, Hashable, Sendable, Codable {
        public enum Kind: String, Equatable, Hashable, Sendable, Codable {
            case file, agent, skill, pasted
        }

        public let type: Kind
        public let index: Int

        public init(type: Kind, index: Int) {
            self.type = type
            self.index = index
        }
    }

    // parity: tui/src/prompt/history.tsx#emptyPrompt [status=implemented hash=8b8932d42d3c]
    public static func emptyPrompt() -> PromptInfo {
        PromptInfo()
    }

    // parity: tui/src/prompt/history.tsx#appendPrompt [status=implemented hash=5426a6ee7581]
    public static func appendPrompt(
        _ prompt: PromptInfo,
        following: PromptInfo,
        widthMethod: WidthMethod = .unicode
    ) -> PromptInfo {
        let prefix = prompt.text.isEmpty ? "" : "\(prompt.text)\n\n"
        let offset = measureEditText(prefix, widthMethod: textWidthMethod(widthMethod))
        func shiftMention(_ m: PromptSchema.PromptMention?, by delta: Int) -> PromptSchema.PromptMention? {
            m.map { PromptSchema.PromptMention(start: $0.start + delta, end: $0.end + delta, text: $0.text) }
        }
        let files = prompt.files + following.files.map { f in
            PromptFile(uri: f.uri, source: f.source, name: f.name, description: f.description, mention: shiftMention(f.mention, by: offset), path: f.path)
        }
        let agents = prompt.agents + following.agents.map { a in
            PromptSchema.AgentAttachment(name: a.name, mention: shiftMention(a.mention, by: offset))
        }
        let skills = prompt.skills + following.skills.map { s in
            PromptInputSchema.SkillAttachment(id: s.id, mention: shiftMention(s.mention, by: offset))
        }
        let pasted = prompt.pasted + following.pasted.map { p in
            PastedText(
                text: p.text,
                source: PastedText.Source(start: p.source.start + offset, end: p.source.end + offset, text: p.source.text)
            )
        }
        return PromptInfo(text: prefix + following.text, files: files, agents: agents, skills: skills, pasted: pasted)
    }

    // parity: tui/src/prompt/history.tsx#MAX_HISTORY_ENTRIES [status=implemented hash=3e703d2771ee]
    public static let MAX_HISTORY_ENTRIES = 50

    // parity: tui/src/prompt/history.tsx#parsePromptInfo [status=implemented hash=06b528f219f7]
    public static func parsePromptInfo(_ value: JSONValue) -> PromptInfo? {
        guard case .object(let dict) = value,
              case .string = dict["text"],
              case .array = dict["pasted"]
        else { return nil }
        guard let data = try? JSONEncoder().encode(value),
              let decoded = try? JSONDecoder().decode(PromptInfo.self, from: data)
        else { return nil }
        return decoded
    }

    // parity: tui/src/prompt/history.tsx#parsePromptHistory [status=implemented hash=24e3d5cbb351]
    public static func parsePromptHistory(_ text: String) -> [PromptInfo] {
        let parsed: [PromptInfo] = text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            guard let json = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)) else { return nil }
            return parsePromptInfo(json)
        }
        return Array(parsed.suffix(MAX_HISTORY_ENTRIES))
    }

    // parity: tui/src/prompt/history.tsx#isDuplicateEntry [status=implemented hash=25fdaeed54ad]
    public static func isDuplicateEntry(_ previous: PromptInfo?, _ next: PromptInfo) -> Bool {
        guard let previous else { return false }
        return previous == next
    }

    public final class PromptHistoryController: @unchecked Sendable {
        private struct State: Sendable {
            var entries: [PromptInfo]
            var index: Int = 0
            var draft: PromptInfo? = nil
        }

        private let state: Mutex<State>
        private let currentDraft: @Sendable () -> PromptInfo

        public init(
            initial: [PromptInfo] = [],
            currentDraft: @escaping @Sendable () -> PromptInfo = TUIPrompt.emptyPrompt
        ) {
            self.state = Mutex(State(entries: Array(initial.suffix(MAX_HISTORY_ENTRIES))))
            self.currentDraft = currentDraft
        }

        public var entries: [PromptInfo] { state.withLock { $0.entries } }

        public func reset() {
            state.withLock {
                $0.index = 0
                $0.draft = nil
            }
        }

        public func append(_ item: PromptInfo) {
            state.withLock { s in
                s.index = 0
                s.draft = nil
                if isDuplicateEntry(s.entries.last, item) { return }
                s.entries.append(item)
                if s.entries.count > MAX_HISTORY_ENTRIES {
                    s.entries = Array(s.entries.suffix(MAX_HISTORY_ENTRIES))
                }
            }
        }

        public func move(direction: Int, input: String) -> PromptInfo? {
            let dir = direction >= 0 ? 1 : -1
            return state.withLock { s in
                let next = s.index + dir
                if next < -s.entries.count || next > 0 { return nil }
                if s.index < 0 && !input.isEmpty {
                    let existingIdx = s.entries.count + s.index
                    if existingIdx >= 0 && existingIdx < s.entries.count && s.entries[existingIdx].text != input {
                        return nil
                    }
                }
                if s.index == 0 {
                    var d = currentDraft()
                    d.text = input
                    s.draft = d
                }
                s.index = next
                if next != 0 {
                    let targetIdx = s.entries.count + next
                    return (targetIdx >= 0 && targetIdx < s.entries.count) ? s.entries[targetIdx] : nil
                }
                let restored = s.draft
                s.draft = nil
                return restored
            }
        }
    }

    // parity: tui/src/prompt/history.tsx#usePromptHistory [status=adapted hash=d7c291c3d0bb]
    public static func usePromptHistory(
        initial: [PromptInfo] = [],
        currentDraft: @escaping @Sendable () -> PromptInfo = emptyPrompt
    ) -> PromptHistoryController {
        PromptHistoryController(initial: initial, currentDraft: currentDraft)
    }

    // MARK: - Attachments (`packages/tui/src/prompt/attachment.ts`)

    public struct ProjectedFile: Equatable, Hashable, Sendable, Codable {
        public let mime: String
        public let source: PromptSchema.FileSource
        public let name: String?
        public let description: String?
        public let mention: PromptSchema.PromptMention?
        public let payload: String

        public init(
            mime: String,
            source: PromptSchema.FileSource,
            name: String? = nil,
            description: String? = nil,
            mention: PromptSchema.PromptMention? = nil,
            payload: String
        ) {
            self.mime = mime
            self.source = source
            self.name = name
            self.description = description
            self.mention = mention
            self.payload = payload
        }
    }

    private static func attachmentKind(_ uri: String) -> String? {
        if uri.hasPrefix("data:image/") { return "Image" }
        if uri.hasPrefix("data:application/pdf;") { return "PDF" }
        return nil
    }

    private static func attachmentMetaKey(name: String?, description: String?) -> String {
        "\(name ?? "\u{1}")\u{0}\(description ?? "\u{1}")"
    }

    // parity: tui/src/prompt/attachment.ts#deduplicatePromptImages [status=implemented hash=a688038db23a]
    public static func deduplicatePromptImages(_ files: [PromptInputSchema.FileAttachment]?) -> [PromptInputSchema.FileAttachment]? {
        guard let files, files.count >= 2 else { return files }
        var seen: [String: Set<String>] = [:]
        return files.filter { file in
            guard file.uri.hasPrefix("data:image/"), let mText = file.mention?.text, !mText.isEmpty else {
                return true
            }
            let meta = "\(attachmentMetaKey(name: file.name, description: file.description))\u{0}\(mText)"
            if seen[meta]?.contains(file.uri) == true { return false }
            seen[meta, default: []].insert(file.uri)
            return true
        }
    }

    // parity: tui/src/prompt/attachment.ts#preserveMentionlessPromptAttachments [status=implemented hash=bf07d507dce5]
    public static func preserveMentionlessPromptAttachments(
        _ files: [PromptInputSchema.FileAttachment]?,
        mentioned: [PromptInputSchema.FileAttachment]
    ) -> [PromptInputSchema.FileAttachment] {
        guard let files else { return mentioned }
        var idx = 0
        var out: [PromptInputSchema.FileAttachment] = []
        for file in files {
            if file.mention?.text.isEmpty != false {
                out.append(file)
            } else if idx < mentioned.count {
                out.append(mentioned[idx])
                idx += 1
            }
        }
        return out
    }

    // parity: tui/src/prompt/attachment.ts#deduplicateVisibleImages [status=implemented hash=50eda16714b5]
    public static func deduplicateVisibleImages(_ files: [ProjectedFile]) -> [ProjectedFile] {
        var seen: [String: Set<String>] = [:]
        return files.filter { file in
            guard file.mime.hasPrefix("image/"),
                  case .inline = file.source,
                  let mText = file.mention?.text, !mText.isEmpty
            else { return true }
            let meta = "\(file.mime)\u{0}\(attachmentMetaKey(name: file.name, description: file.description))\u{0}\(mText)"
            if seen[meta]?.contains(file.payload) == true { return false }
            seen[meta, default: []].insert(file.payload)
            return true
        }
    }

    // parity: tui/src/prompt/attachment.ts#promptAttachmentLabel [status=implemented hash=c690e02ff07f]
    public static func promptAttachmentLabel(
        _ files: [PromptInputSchema.FileAttachment]?,
        uri: String,
        name: String? = nil,
        description: String? = nil
    ) throws(PromptError) -> String {
        guard let kind = attachmentKind(uri) else {
            throw .unsupportedInlineAttachment(uri)
        }
        let meta = attachmentMetaKey(name: name, description: description)
        if kind == "Image", let files {
            if let existing = files.first(where: { candidate in
                candidate.uri == uri
                    && attachmentMetaKey(name: candidate.name, description: candidate.description) == meta
                    && candidate.mention?.text.isEmpty == false
            })?.mention?.text {
                return existing
            }
        }
        let prefix = "[\(kind) "
        var highest = 0
        for candidate in files ?? [] {
            guard let text = candidate.mention?.text,
                  text.hasPrefix(prefix),
                  text.hasSuffix("]")
            else { continue }
            let numStr = String(text.dropFirst(prefix.count).dropLast())
            if !numStr.isEmpty, numStr.allSatisfy({ $0 >= "0" && $0 <= "9" }), let n = Int(numStr) {
                highest = max(highest, n)
            }
        }
        return "[\(kind) \(highest + 1)]"
    }

    // MARK: - Codec & Restore (`packages/tui/src/prompt/codec.ts`, `restore.ts`)

    // parity: tui/src/prompt/codec.ts#EditablePromptInput [status=implemented hash=e821e88fc5b3]
    public typealias EditablePromptInput = PromptInputSchema.Prompt

    // parity: tui/src/prompt/codec.ts#ProjectedPrompt [status=implemented hash=252f8be636c2]
    public struct ProjectedPrompt: Equatable, Hashable, Sendable, Codable {
        public let text: String
        public let files: [PromptSchema.Attachment]?
        public let agents: [PromptSchema.AgentAttachment]?
        public let skills: [PromptInputSchema.SkillAttachment]?

        public init(
            text: String,
            files: [PromptSchema.Attachment]? = nil,
            agents: [PromptSchema.AgentAttachment]? = nil,
            skills: [PromptInputSchema.SkillAttachment]? = nil
        ) {
            self.text = text
            self.files = files
            self.agents = agents
            self.skills = skills
        }
    }

    // parity: tui/src/prompt/codec.ts#projectedPromptInput [status=implemented hash=a2d3e6a15521]
    public static func projectedPromptInput(_ input: ProjectedPrompt) -> EditablePromptInput {
        let mappedFiles: [PromptInputSchema.FileAttachment]? = input.files?.map { attachment in
            switch attachment {
            case .file(let file):
                let uri: String
                switch file.source {
                case .uri(let u): uri = u
                case .inline: uri = "data:\(file.mime);base64,\(file.data.rawValue)"
                }
                return PromptInputSchema.FileAttachment(
                    uri: uri,
                    name: file.name,
                    description: file.description,
                    mention: file.mention
                )
            case .media(let media):
                let uri: String
                switch media.source {
                case .uri(let u): uri = u
                case .inline: uri = media.uri.rawValue
                }
                return PromptInputSchema.FileAttachment(
                    uri: uri,
                    name: media.name,
                    description: media.description,
                    mention: media.mention
                )
            }
        }
        return PromptInputSchema.Prompt(
            text: input.text,
            files: mappedFiles,
            agents: input.agents,
            skills: input.skills
        )
    }

    // parity: tui/src/prompt/codec.ts#restoredPromptInput [status=implemented hash=2085beb1a89d]
    public static func restoredPromptInput(
        _ input: ProjectedPrompt,
        read: @Sendable (String) async throws -> [UInt8]?
    ) async throws -> EditablePromptInput {
        let output = projectedPromptInput(input)
        guard let files = output.files, files.contains(where: { $0.uri.hasPrefix("media:") }) else {
            return output
        }
        var restored: [PromptInputSchema.FileAttachment] = []
        for (index, file) in files.enumerated() {
            guard file.uri.hasPrefix("media:") else {
                restored.append(file)
                continue
            }
            guard let bytes = try await read(file.uri) else { continue }
            let mime: String
            if let orig = input.files, index < orig.count {
                switch orig[index] {
                case .file(let f): mime = f.mime
                case .media(let m): mime = m.mime
                }
            } else {
                mime = "application/octet-stream"
            }
            restored.append(PromptInputSchema.FileAttachment(
                uri: "data:\(mime);base64,\(bytesToBase64(bytes))",
                source: file.source,
                name: file.name,
                description: file.description,
                mention: file.mention
            ))
        }
        return PromptInputSchema.Prompt(
            text: output.text,
            files: restored,
            agents: output.agents,
            skills: output.skills
        )
    }

    // parity: tui/src/prompt/restore.ts#usePromptRestore [status=adapted hash=e123a7544d6e]
    public static func usePromptRestore(
        readMedia: @escaping @Sendable (String) async throws -> [UInt8]?,
        onWarning: @escaping @Sendable (String) -> Void = { _ in }
    ) -> @Sendable (ProjectedPrompt, Bool) async throws -> PromptInfo {
        { input, allowMissing in
            let missingCount = Mutex<Int>(0)
            let restored = try await restoredPromptInput(input) { uri in
                do {
                    return try await readMedia(uri)
                } catch {
                    if !allowMissing { throw error }
                    missingCount.withLock { $0 += 1 }
                    return nil
                }
            }
            let missing = missingCount.withLock { $0 }
            if missing > 0 {
                let msg = missing == 1
                    ? "An image in this message is no longer stored, so it can't be restored"
                    : "\(missing) images in this message are no longer stored, so they can't be restored"
                onWarning(msg)
            }
            let promptFiles = (restored.files ?? []).map {
                PromptFile(uri: $0.uri, source: $0.source, name: $0.name, description: $0.description, mention: $0.mention)
            }
            return PromptInfo(
                text: restored.text,
                files: promptFiles,
                agents: restored.agents ?? [],
                skills: restored.skills ?? [],
                pasted: []
            )
        }
    }

    // MARK: - Mention Realignment (`packages/tui/src/prompt/mention.ts`)

    private struct TextRange {
        let start: Int
        let end: Int
        let offset: Int
    }

    private struct MentionItem {
        let index: Int
        let mention: PromptSchema.PromptMention
    }

    private struct DPResult {
        let matches: Int
        let cost: Int
        let pairs: [(MentionItem, TextRange)]
    }

    private static func findMentionRanges(_ content: String, _ text: String, _ widthMethod: WidthMethod) -> [TextRange] {
        guard !text.isEmpty else { return [] }
        let cUTF16 = Array(content.utf16)
        let tUTF16 = Array(text.utf16)
        guard tUTF16.count <= cUTF16.count else { return [] }
        var ranges: [TextRange] = []
        var pos = 0
        while pos <= cUTF16.count - tUTF16.count {
            var matched = true
            for j in 0..<tUTF16.count where cUTF16[pos + j] != tUTF16[j] {
                matched = false
                break
            }
            if matched {
                let prefix = String(decoding: cUTF16[0..<pos], as: UTF16.self)
                let offset = measureEditText(prefix, widthMethod: textWidthMethod(widthMethod))
                ranges.append(TextRange(start: pos, end: pos + tUTF16.count, offset: offset))
                pos += tUTF16.count
            } else {
                pos += 1
            }
        }
        return ranges
    }

    private static func assignMentions(_ items: [MentionItem], _ candidates: [TextRange]) -> [(MentionItem, TextRange)] {
        let ordered = items.sorted {
            $0.mention.start != $1.mention.start ? $0.mention.start < $1.mention.start : $0.index < $1.index
        }
        var memo: [String: DPResult] = [:]
        func solve(_ i: Int, _ c: Int) -> DPResult {
            if i >= ordered.count || c >= candidates.count {
                return DPResult(matches: 0, cost: 0, pairs: [])
            }
            let key = "\(i):\(c)"
            if let hit = memo[key] { return hit }
            let tail = solve(i + 1, c + 1)
            let cur = ordered[i]
            let range = candidates[c]
            let matched = DPResult(
                matches: tail.matches + 1,
                cost: tail.cost + abs(range.offset - cur.mention.start),
                pairs: [(cur, range)] + tail.pairs
            )
            let skipItem = solve(i + 1, c)
            let skipCand = solve(i, c + 1)
            var best = matched
            for option in [skipItem, skipCand] {
                if option.matches > best.matches || (option.matches == best.matches && option.cost < best.cost) {
                    best = option
                }
            }
            memo[key] = best
            return best
        }
        return solve(0, 0).pairs
    }

    /// Optimal DP realignment of mention ranges against edited prompt text.
    // parity: tui/src/prompt/mention.ts#realignPromptMentions [status=implemented hash=dec618ffff89]
    public static func realignPromptMentions(
        _ content: String,
        mentions: [PromptSchema.PromptMention?],
        widthMethod: WidthMethod = .unicode
    ) -> [PromptSchema.PromptMention?] {
        var protectedRanges: [TextRange] = []
        var aligned: [PromptSchema.PromptMention?] = mentions.map { m in
            guard let m, m.text.isEmpty else { return nil }
            return m
        }
        var groups: [String: [MentionItem]] = [:]
        for (index, mention) in mentions.enumerated() {
            guard let mention, !mention.text.isEmpty else { continue }
            groups[mention.text, default: []].append(MentionItem(index: index, mention: mention))
        }
        let sortedGroups = groups.sorted { lhs, rhs in
            if lhs.key.utf16.count != rhs.key.utf16.count { return lhs.key.utf16.count > rhs.key.utf16.count }
            return lhs.key < rhs.key
        }
        for (text, items) in sortedGroups {
            let candidates = findMentionRanges(content, text, widthMethod)
            let available = candidates.filter { cand in
                !protectedRanges.contains { $0.start < cand.end && $0.end > cand.start }
            }
            let textWidth = measureEditText(text, widthMethod: textWidthMethod(widthMethod))
            for (item, cand) in assignMentions(items, available) {
                aligned[item.index] = PromptSchema.PromptMention(
                    start: cand.offset,
                    end: cand.offset + textWidth,
                    text: text
                )
            }
            protectedRanges.append(contentsOf: candidates)
        }
        return aligned
    }

    // parity: tui/src/prompt/mention.ts#realignPromptInputMentions [status=implemented hash=57e96c74b3d2]
    public static func realignPromptInputMentions(
        _ content: String,
        input: PromptInputSchema.Prompt,
        widthMethod: WidthMethod = .unicode
    ) -> EditablePromptInput {
        let files = input.files ?? []
        let agents = input.agents ?? []
        let skills = input.skills ?? []
        let allMentions: [PromptSchema.PromptMention?] =
            files.map(\.mention) + agents.map(\.mention) + skills.map(\.mention)
        let aligned = realignPromptMentions(content, mentions: allMentions, widthMethod: widthMethod)

        let nextFiles: [PromptInputSchema.FileAttachment]? = input.files.map { list in
            list.enumerated().compactMap { idx, item in
                guard let m = item.mention, !m.text.isEmpty else { return item }
                guard let updated = aligned[idx] else { return nil }
                return PromptInputSchema.FileAttachment(
                    uri: item.uri, source: item.source, name: item.name, description: item.description, mention: updated
                )
            }
        }
        let agentOffset = files.count
        let nextAgents: [PromptSchema.AgentAttachment]? = input.agents.map { list in
            list.enumerated().compactMap { idx, item in
                guard let m = item.mention, !m.text.isEmpty else { return item }
                guard let updated = aligned[agentOffset + idx] else { return nil }
                return PromptSchema.AgentAttachment(name: item.name, mention: updated)
            }
        }
        let skillOffset = files.count + agents.count
        let nextSkills: [PromptInputSchema.SkillAttachment]? = input.skills.map { list in
            list.enumerated().compactMap { idx, item in
                guard let m = item.mention, !m.text.isEmpty else { return item }
                guard let updated = aligned[skillOffset + idx] else { return nil }
                return PromptInputSchema.SkillAttachment(id: item.id, mention: updated)
            }
        }
        return PromptInputSchema.Prompt(text: content, files: nextFiles, agents: nextAgents, skills: nextSkills)
    }

    // parity: tui/src/prompt/mention.ts#expandPromptInputPastedText [status=implemented hash=21dd6a2bbe60]
    public static func expandPromptInputPastedText(
        _ input: PromptInputSchema.Prompt,
        pasted: [PastedText],
        widthMethod: WidthMethod = .unicode
    ) -> EditablePromptInput {
        let ranges = pasted.map { TrackedPastedRange(start: $0.source.start, end: $0.source.end, text: $0.text) }
        func shift(_ mention: PromptSchema.PromptMention?) -> PromptSchema.PromptMention? {
            guard let mention else { return nil }
            let delta = ranges
                .filter { $0.end <= mention.start }
                .reduce(0) { total, r in
                    total + measureEditText(r.text, widthMethod: textWidthMethod(widthMethod)) - (r.end - r.start)
                }
            return PromptSchema.PromptMention(start: mention.start + delta, end: mention.end + delta, text: mention.text)
        }
        return PromptInputSchema.Prompt(
            text: expandTrackedPastedText(input.text, ranges: ranges, widthMethod: widthMethod),
            files: input.files?.map {
                PromptInputSchema.FileAttachment(uri: $0.uri, source: $0.source, name: $0.name, description: $0.description, mention: shift($0.mention))
            },
            agents: input.agents?.map {
                PromptSchema.AgentAttachment(name: $0.name, mention: shift($0.mention))
            },
            skills: input.skills?.map {
                PromptInputSchema.SkillAttachment(id: $0.id, mention: shift($0.mention))
            }
        )
    }

    // MARK: - Directory Autocomplete & Recents (`directory-completion.ts`, `directory-recents.ts`)

    public struct DirectorySearch: Equatable, Hashable, Sendable {
        public let directory: String
        public let prefix: String
        public let query: String

        public init(directory: String, prefix: String, query: String) {
            self.directory = directory
            self.prefix = prefix
            self.query = query
        }
    }

    public struct DirectoryAutocompleteItem: Equatable, Hashable, Sendable {
        public let value: String
        public let absolute: String

        public init(value: String, absolute: String) {
            self.value = value
            self.absolute = absolute
        }
    }

    public struct SlashArgumentMatch: Equatable, Hashable, Sendable {
        public let type: String
        public let index: Int

        public init(type: String, index: Int) {
            self.type = type
            self.index = index
        }
    }

    private static func resolvePath(_ base: String, _ relative: String) -> String {
        if relative.hasPrefix("/") { return comparablePath(relative) }
        let combined = base.hasSuffix("/") ? "\(base)\(relative)" : "\(base)/\(relative)"
        var segments: [String] = []
        let absolute = combined.hasPrefix("/")
        for part in combined.split(separator: "/") {
            if part == "." || part.isEmpty { continue }
            if part == ".." {
                if !segments.isEmpty && segments.last != ".." {
                    segments.removeLast()
                } else if !absolute {
                    segments.append("..")
                }
            } else {
                segments.append(String(part))
            }
        }
        let joined = segments.joined(separator: "/")
        return absolute ? "/\(joined)" : joined
    }

    private static func directorySearch(_ query: String, root: String, prefix: String) -> DirectorySearch {
        guard let slash = query.lastIndex(of: "/") else {
            return DirectorySearch(directory: root, prefix: prefix, query: query)
        }
        let parentEnd = query.index(after: slash)
        let parent = String(query[..<parentEnd])
        let rest = String(query[parentEnd...])
        return DirectorySearch(
            directory: resolvePath(root, parent),
            prefix: prefix + parent,
            query: rest
        )
    }

    // parity: tui/src/prompt/directory-completion.ts#directoryAutocompleteSearch [status=implemented hash=164c83bd46f3]
    public static func directoryAutocompleteSearch(_ query: String, directory: String, home: String) -> DirectorySearch {
        if query == "~" { return DirectorySearch(directory: home, prefix: "~/", query: "") }
        if query.hasPrefix("~/") { return directorySearch(String(query.dropFirst(2)), root: home, prefix: "~/") }
        let dotParts = query.split(separator: "/", omittingEmptySubsequences: false)
        if !dotParts.isEmpty && dotParts.allSatisfy({ $0 == ".." }) {
            return DirectorySearch(directory: resolvePath(directory, query), prefix: "\(query)/", query: "")
        }
        if query.hasPrefix("/") {
            return directorySearch(String(query.dropFirst()), root: "/", prefix: "/")
        }
        return directorySearch(query, root: directory, prefix: "")
    }

    // parity: tui/src/prompt/directory-completion.ts#directoryAutocompleteResultValue [status=implemented hash=3b19dcfb227b]
    public static func directoryAutocompleteResultValue(_ directory: String, search: DirectorySearch) -> String {
        var trimmed = directory
        while trimmed.hasPrefix("/") || trimmed.hasPrefix("\\") { trimmed.removeFirst() }
        return search.prefix + trimmed
    }

    // parity: tui/src/prompt/directory-completion.ts#directoryAutocompleteExactValue [status=implemented hash=60ad0ac3dbcb]
    public static func directoryAutocompleteExactValue(_ value: String, search: DirectorySearch) -> String? {
        if value.isEmpty || search.prefix.isEmpty || !search.query.isEmpty { return nil }
        return value
    }

    // parity: tui/src/prompt/directory-completion.ts#directoryAutocompleteMatches [status=implemented hash=e72cf9095a7a]
    public static func directoryAutocompleteMatches(_ directory: String, query: String) -> Bool {
        var value = directory
        while value.hasPrefix("/") || value.hasPrefix("\\") { value.removeFirst() }
        if query.isEmpty && value.hasPrefix(".") { return false }
        return value.lowercased().hasPrefix(query.lowercased())
    }

    // parity: tui/src/prompt/directory-completion.ts#directoryRecentValue [status=implemented hash=cc20f82e81b9]
    public static func directoryRecentValue(_ directory: String, home: String) -> String {
        let normHome = comparablePath(home)
        let normDir = comparablePath(directory)
        if normDir == normHome { return "~" }
        let prefix = normHome.hasSuffix("/") ? normHome : "\(normHome)/"
        if normDir.hasPrefix(prefix) {
            return "~/\(normDir.dropFirst(prefix.count))"
        }
        return directory
    }

    // parity: tui/src/prompt/directory-completion.ts#directoryAutocomplete [status=implemented hash=ea6cce20c495]
    public static func directoryAutocomplete(
        listDirectories: @Sendable (String) async throws -> [String],
        locationDirectory: String,
        query: String,
        home: String
    ) async throws -> [DirectoryAutocompleteItem] {
        let search = directoryAutocompleteSearch(query, directory: locationDirectory, home: home)
        let entries = try await listDirectories(search.directory)
        var results: [DirectoryAutocompleteItem] = []
        if let exact = directoryAutocompleteExactValue(query, search: search) {
            results.append(DirectoryAutocompleteItem(value: exact, absolute: search.directory))
        }
        for entry in entries {
            let absolute = resolvePath(search.directory, entry)
            let base = getFilename(absolute)
            if directoryAutocompleteMatches(base, query: search.query) {
                results.append(DirectoryAutocompleteItem(
                    value: directoryAutocompleteResultValue("\(base)/", search: search),
                    absolute: absolute
                ))
            }
        }
        return results
    }

    // parity: tui/src/prompt/directory-completion.ts#slashArgumentAutocomplete [status=implemented hash=92af129f8a4f]
    public static func slashArgumentAutocomplete(
        _ beforeCursor: String,
        widthMethod: WidthMethod = .unicode,
        commands: [PluginTui.KeymapCommand],
        autocomplete: (PluginTui.KeymapCommand) -> String?
    ) -> SlashArgumentMatch? {
        guard let head = parseSlashHead(beforeCursor, allowAnyWhitespace: true),
              head.end < beforeCursor.utf16.count
        else { return nil }
        guard let command = commands.first(where: { cmd in
            guard let slash = cmd.slash, slash.arguments == true else { return false }
            return slash.name == head.name || (slash.aliases?.contains(head.name) == true)
        }) else { return nil }
        guard let type = autocomplete(command) else { return nil }
        let prefix = String(decoding: Array(beforeCursor.utf16)[0..<(head.end + 1)], as: UTF16.self)
        return SlashArgumentMatch(type: type, index: measureEditText(prefix, widthMethod: textWidthMethod(widthMethod)))
    }

    public struct RecentDirectory: Equatable, Hashable, Sendable, Codable {
        public let directory: String
        public let usedAt: Int64

        public init(directory: String, usedAt: Int64) {
            self.directory = directory
            self.usedAt = usedAt
        }
    }

    public final class DirectoryRecentsStore: @unchecked Sendable {
        private let projects = Mutex<[String: [RecentDirectory]]>([:])

        public init() {}

        public func list(projectID: String) -> [RecentDirectory] {
            projects.withLock { ($0[projectID] ?? []).sorted { $0.usedAt > $1.usedAt } }
        }

        public func touch(projectID: String, directory: String, nowMs: Int64 = Flock.currentEpochMs()) {
            projects.withLock { map in
                let filtered = (map[projectID] ?? []).filter { $0.directory != directory }
                map[projectID] = Array(([RecentDirectory(directory: directory, usedAt: nowMs)] + filtered).prefix(10))
            }
        }

        public func remove(projectID: String, directory: String) {
            projects.withLock { map in
                map[projectID] = (map[projectID] ?? []).filter { $0.directory != directory }
            }
        }
    }

    // parity: tui/src/prompt/directory-recents.ts#useDirectoryRecents [status=adapted hash=2ecdc09529e0]
    public static func useDirectoryRecents() -> DirectoryRecentsStore {
        DirectoryRecentsStore()
    }

    // MARK: - Frecency (`packages/tui/src/prompt/frecency.tsx`)

    public struct FrecencyEntry: Equatable, Hashable, Sendable, Codable {
        public var path: String
        public var frequency: Int
        public var lastOpen: Int64

        public init(path: String, frequency: Int, lastOpen: Int64) {
            self.path = path
            self.frequency = frequency
            self.lastOpen = lastOpen
        }
    }

    // parity: tui/src/prompt/frecency.tsx#MAX_FRECENCY_ENTRIES [status=implemented hash=ea11b5139c39]
    public static let MAX_FRECENCY_ENTRIES = 1000

    // parity: tui/src/prompt/frecency.tsx#parseFrecency [status=implemented hash=aceea2a6a74e]
    public static func parseFrecency(_ text: String) -> [FrecencyEntry] {
        var latest: [String: FrecencyEntry] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if let entry = try? JSONDecoder().decode(FrecencyEntry.self, from: Data(line.utf8)) {
                latest[entry.path] = entry
            }
        }
        return Array(latest.values.sorted { $0.lastOpen > $1.lastOpen }.prefix(MAX_FRECENCY_ENTRIES))
    }

    public final class FrecencyStore: @unchecked Sendable {
        private let cwd: String
        private let dataMap: Mutex<[String: FrecencyEntry]>

        public init(cwd: String = "", initial: [FrecencyEntry] = []) {
            self.cwd = cwd
            var map: [String: FrecencyEntry] = [:]
            for e in initial { map[e.path] = e }
            self.dataMap = Mutex(map)
        }

        public func updateFrecency(_ filePath: String, nowMs: Int64 = Flock.currentEpochMs()) {
            let abs = cwd.isEmpty ? filePath : resolvePath(cwd, filePath)
            dataMap.withLock { map in
                let freq = (map[abs]?.frequency ?? 0) + 1
                map[abs] = FrecencyEntry(path: abs, frequency: freq, lastOpen: nowMs)
                if map.count > MAX_FRECENCY_ENTRIES {
                    let top = map.values.sorted { $0.lastOpen > $1.lastOpen }.prefix(MAX_FRECENCY_ENTRIES)
                    map = Dictionary(uniqueKeysWithValues: top.map { ($0.path, $0) })
                }
            }
        }

        public func getFrecency(_ filePath: String, nowMs: Int64 = Flock.currentEpochMs()) -> Double {
            let abs = cwd.isEmpty ? filePath : resolvePath(cwd, filePath)
            guard let entry = dataMap.withLock({ $0[abs] }) else { return 0 }
            let daysSince = Double(nowMs - entry.lastOpen) / 86_400_000.0
            return Double(entry.frequency) / (1.0 + max(0, daysSince))
        }
    }

    // MARK: - Stash (`packages/tui/src/prompt/stash.tsx`)

    // parity: tui/src/prompt/stash.tsx#StashEntry [status=implemented hash=d5c6ca77b1a4]
    public struct StashEntry: Equatable, Hashable, Sendable, Codable {
        public var prompt: PromptInfo
        public var timestamp: Int64

        public init(prompt: PromptInfo, timestamp: Int64) {
            self.prompt = prompt
            self.timestamp = timestamp
        }
    }

    // parity: tui/src/prompt/stash.tsx#MAX_STASH_ENTRIES [status=implemented hash=28652ac467b4]
    public static let MAX_STASH_ENTRIES = 50

    // parity: tui/src/prompt/stash.tsx#parsePromptStash [status=implemented hash=4f6ce2ce3239]
    public static func parsePromptStash(_ text: String) -> [StashEntry] {
        let parsed: [StashEntry] = text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            guard let json = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)),
                  case .object(let dict) = json,
                  let promptVal = dict["prompt"],
                  let prompt = parsePromptInfo(promptVal)
            else { return nil }
            let ts: Int64
            switch dict["timestamp"] {
            case .int(let i): ts = i
            case .double(let d): ts = Int64(d)
            default: return nil
            }
            return StashEntry(prompt: prompt, timestamp: ts)
        }
        return Array(parsed.suffix(MAX_STASH_ENTRIES))
    }

    public final class PromptStashStore: @unchecked Sendable {
        private let entriesLock = Mutex<[StashEntry]>([])

        public init(initial: [StashEntry] = []) {
            self.entriesLock.withLock { $0 = Array(initial.suffix(MAX_STASH_ENTRIES)) }
        }

        public func list() -> [StashEntry] { entriesLock.withLock { $0 } }

        public func push(_ prompt: PromptInfo, timestamp: Int64 = Flock.currentEpochMs()) {
            entriesLock.withLock { list in
                list.append(StashEntry(prompt: prompt, timestamp: timestamp))
                if list.count > MAX_STASH_ENTRIES {
                    list = Array(list.suffix(MAX_STASH_ENTRIES))
                }
            }
        }

        public func pop() -> StashEntry? {
            entriesLock.withLock { $0.popLast() }
        }

        public func remove(at index: Int) {
            entriesLock.withLock { list in
                guard index >= 0 && index < list.count else { return }
                list.remove(at: index)
            }
        }
    }

    // MARK: - Traits (`packages/tui/src/prompt/traits.ts`)

    // parity: tui/src/prompt/traits.ts#PromptMode [status=implemented hash=170ef83d71e8]
    public enum PromptMode: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
        case normal
        case shell
    }

    // parity: tui/src/prompt/traits.ts#PromptTraitsInput [status=implemented hash=094709abea5a]
    public struct PromptTraitsInput: Equatable, Hashable, Sendable, Codable {
        public let mode: PromptMode
        public let autocompleteVisible: Bool

        public init(mode: PromptMode, autocompleteVisible: Bool) {
            self.mode = mode
            self.autocompleteVisible = autocompleteVisible
        }
    }

    // parity: tui/src/prompt/traits.ts#PromptTraits [status=implemented hash=7baa731b6c20]
    public struct PromptTraits: Equatable, Hashable, Sendable, Codable {
        public let capture: [String]?
        public let status: String?
        public let owner: String
        public let role: String

        public init(capture: [String]?, status: String?, owner: String = "opencode", role: String = "prompt") {
            self.capture = capture
            self.status = status
            self.owner = owner
            self.role = role
        }
    }

    // parity: tui/src/prompt/traits.ts#computePromptTraits [status=implemented hash=9acd2b30ac0c]
    public static func computePromptTraits(_ input: PromptTraitsInput) -> PromptTraits {
        let capture: [String]? = input.mode == .normal
            ? (input.autocompleteVisible ? ["escape", "navigate", "submit", "tab"] : ["tab"])
            : nil
        return PromptTraits(
            capture: capture,
            status: input.mode == .shell ? "SHELL" : nil,
            owner: "opencode",
            role: "prompt"
        )
    }
}

// MARK: - TUI Routes (`packages/tui/src/routes/*`)

/// Home route, Session route, transcript grouping tree, timeline anchors, mount budget, message navigation,
/// composer tabs, dialogs, permissions, forms, and OpenTUI renderable builders.
public enum TUIRoutes {
    public enum GroupError: Error, Equatable, Sendable {
        case invalidSplitCount(Int)
        case splitInsideEntry
        case splitExceedsCount
    }

    // MARK: - Generic Grouping Tree (`packages/tui/src/routes/session/grouping/tree.ts`)

    // parity: tui/src/routes/session/grouping/tree.ts#GroupNode [status=implemented hash=3b67cf408b49]
    public indirect enum GroupNode<Entry: Equatable & Sendable, Kind: Hashable & Sendable>: Equatable, Sendable {
        case entry(Entry)
        case group(kind: Kind, children: [GroupNode<Entry, Kind>], size: Int)

        public var size: Int {
            switch self {
            case .entry: return 1
            case .group(_, _, let s): return s
            }
        }
    }

    private static func appendEntryToNodes<Entry: Equatable & Sendable, Kind: Hashable & Sendable>(
        _ nodes: inout [GroupNode<Entry, Kind>],
        entry: Entry,
        path: [Kind],
        depth: Int = 0
    ) {
        guard depth < path.count else {
            nodes.append(.entry(entry))
            return
        }
        let kind = path[depth]
        if let last = nodes.last, case .group(let prevKind, var children, let prevSize) = last, prevKind == kind {
            appendEntryToNodes(&children, entry: entry, path: path, depth: depth + 1)
            nodes[nodes.count - 1] = .group(kind: prevKind, children: children, size: prevSize + 1)
            return
        }
        var children: [GroupNode<Entry, Kind>] = []
        appendEntryToNodes(&children, entry: entry, path: path, depth: depth + 1)
        nodes.append(.group(kind: kind, children: children, size: 1))
    }

    // parity: tui/src/routes/session/grouping/tree.ts#groupEntries [status=implemented hash=ea2431019082]
    public static func groupEntries<Entry: Equatable & Sendable, Kind: Hashable & Sendable>(
        _ entries: [Entry],
        path: (Entry) -> [Kind]
    ) -> [GroupNode<Entry, Kind>] {
        var result: [GroupNode<Entry, Kind>] = []
        for entry in entries {
            appendEntryToNodes(&result, entry: entry, path: path(entry))
        }
        return result
    }

    // parity: tui/src/routes/session/grouping/tree.ts#mergeGroups [status=implemented hash=47a29aac30ed]
    public static func mergeGroups<Entry: Equatable & Sendable, Kind: Hashable & Sendable>(
        _ left: [GroupNode<Entry, Kind>],
        _ right: [GroupNode<Entry, Kind>]
    ) -> [GroupNode<Entry, Kind>] {
        if left.isEmpty { return right }
        if right.isEmpty { return left }
        guard case .group(let ak, let aChildren, let aSize) = left.last!,
              case .group(let bk, let bChildren, let bSize) = right.first!,
              ak == bk
        else {
            return left + right
        }
        let merged = GroupNode<Entry, Kind>.group(
            kind: ak,
            children: mergeGroups(aChildren, bChildren),
            size: aSize + bSize
        )
        return Array(left.dropLast()) + [merged] + Array(right.dropFirst())
    }

    // parity: tui/src/routes/session/grouping/tree.ts#splitGroups [status=implemented hash=f17c2e5f9070]
    public static func splitGroups<Entry: Equatable & Sendable, Kind: Hashable & Sendable>(
        _ nodes: [GroupNode<Entry, Kind>],
        count: Int
    ) throws(GroupError) -> ([GroupNode<Entry, Kind>], [GroupNode<Entry, Kind>]) {
        guard count >= 0 else { throw .invalidSplitCount(count) }
        if count == 0 { return ([], nodes) }
        var offset = 0
        for (index, node) in nodes.enumerated() {
            let end = offset + node.size
            if count == end {
                return (Array(nodes[0...index]), Array(nodes[(index + 1)...]))
            }
            if count < end {
                guard case .group(let kind, let children, let nodeSize) = node else {
                    throw .splitInsideEntry
                }
                let size = count - offset
                let (left, right) = try splitGroups(children, count: size)
                return (
                    Array(nodes[0..<index]) + [.group(kind: kind, children: left, size: size)],
                    [.group(kind: kind, children: right, size: nodeSize - size)] + Array(nodes[(index + 1)...])
                )
            }
            offset = end
        }
        throw .splitExceedsCount
    }

    // MARK: - Session Grouping (`packages/tui/src/routes/session/grouping/session.ts`)

    // parity: tui/src/routes/session/grouping/session.ts#PartRef [status=implemented hash=7878586ff69c]
    public struct PartRef: Equatable, Hashable, Sendable, Codable {
        public let messageID: String
        public let partID: String

        public init(messageID: String, partID: String) {
            self.messageID = messageID
            self.partID = partID
        }
    }

    // parity: tui/src/routes/session/grouping/session.ts#CacheUsage [status=implemented hash=1d3e7078bbd9]
    public struct CacheUsage: Equatable, Hashable, Sendable, Codable {
        public let read: Int
        public let model: SessionSchema.ModelRef

        public init(read: Int, model: SessionSchema.ModelRef) {
            self.read = read
            self.model = model
        }
    }

    // parity: tui/src/routes/session/grouping/session.ts#SessionEntry [status=implemented hash=13395a4d760e]
    public enum SessionEntry: Equatable, Hashable, Sendable, Codable {
        case message(messageID: String)
        case compactionQueued(inboxID: String)
        case part(ref: PartRef)
        case assistantFooter(messageID: String)
        case turnUsage(messageIDs: [String], previousCache: CacheUsage?)
    }

    // parity: tui/src/routes/session/grouping/session.ts#GroupKind [status=implemented hash=a2674e015f8d]
    public enum GroupKind: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
        case activity
        case reasoning
        case exploration
        case instructions
    }

    // parity: tui/src/routes/session/grouping/session.ts#SessionNode [status=implemented hash=5f0a2593328d]
    public typealias SessionNode = GroupNode<SessionEntry, GroupKind>

    // parity: tui/src/routes/session/grouping/session.ts#SessionGroup [status=implemented hash=845fcfb31d43]
    public struct SessionGroup: Equatable, Sendable {
        public var kind: GroupKind
        public var children: [SessionNode]
        public var size: Int
        public var completed: Bool
        public var pending: [PartRef]

        public init(
            kind: GroupKind,
            children: [SessionNode],
            size: Int,
            completed: Bool,
            pending: [PartRef] = []
        ) {
            self.kind = kind
            self.children = children
            self.size = size
            self.completed = completed
            self.pending = pending
        }

        public var asNode: SessionNode {
            .group(kind: kind, children: children, size: size)
        }
    }

    // parity: tui/src/routes/session/grouping/session.ts#Verbosity [status=implemented hash=05c7d88caf78]
    public enum Verbosity: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
        case low
        case medium
        case high
    }

    // parity: tui/src/routes/session/grouping/session.ts#defaultVerbosity [status=implemented hash=81a55c89ec8c]
    public static let defaultVerbosity: Verbosity = .low

    // parity: tui/src/routes/session/grouping/session.ts#SessionRow [status=implemented hash=fde9da97e66b]
    public enum SessionRow: Equatable, Sendable {
        case entry(SessionEntry)
        case group(SessionGroup)
    }

    // parity: tui/src/routes/session/grouping/session.ts#AppendPart [status=implemented hash=89caff8ffc07]
    public enum AppendPart: Equatable, Hashable, Sendable {
        case text
        case reasoning(completedAt: Int64?)
        case tool(name: String)
    }

    // parity: tui/src/routes/session/grouping/session.ts#ProjectionEntry [status=implemented hash=59bb1760d10f]
    public struct ProjectionEntry: Equatable, Sendable {
        public let entry: SessionEntry
        public let part: AppendPart?
        public let path: [GroupKind]
        public let closesPrevious: Bool

        public init(
            entry: SessionEntry,
            part: AppendPart? = nil,
            path: [GroupKind] = [],
            closesPrevious: Bool = true
        ) {
            self.entry = entry
            self.part = part
            self.path = path
            self.closesPrevious = closesPrevious
        }
    }

    private static func unwrapProjectionNode(_ node: GroupNode<ProjectionEntry, GroupKind>) -> SessionNode {
        switch node {
        case .entry(let pe): return .entry(pe.entry)
        case .group(let kind, let children, let size):
            return .group(kind: kind, children: children.map(unwrapProjectionNode), size: size)
        }
    }

    // parity: tui/src/routes/session/grouping/session.ts#projectEntries [status=implemented hash=e56df5b5618c]
    public static func projectEntries(_ entries: [ProjectionEntry]) -> [SessionRow] {
        let nodes = groupEntries(entries) { $0.path }
        return nodes.enumerated().map { index, node in
            switch node {
            case .entry(let pe):
                return .entry(pe.entry)
            case .group(let kind, let children, let size):
                let next: GroupNode<ProjectionEntry, GroupKind>? = index + 1 < nodes.count ? nodes[index + 1] : nil
                let closedByNext: Bool
                if let next {
                    switch next {
                    case .group: closedByNext = true
                    case .entry(let nextPe): closedByNext = nextPe.closesPrevious
                    }
                } else {
                    closedByNext = false
                }
                let reasoningAllDone = kind == .reasoning && children.allSatisfy { child in
                    guard case .entry(let pe) = child, case .reasoning(let completedAt) = pe.part else { return false }
                    return completedAt != nil
                }
                return .group(SessionGroup(
                    kind: kind,
                    children: children.map(unwrapProjectionNode),
                    size: size,
                    completed: closedByNext || reasoningAllDone,
                    pending: []
                ))
            }
        }
    }

    private static let explorationTools: Set<String> = ["read", "glob", "grep", "webfetch", "websearch"]

    // parity: tui/src/routes/session/grouping/session.ts#partPath [status=implemented hash=a2cd48802c0d]
    public static func partPath(_ part: AppendPart, verbosity: Verbosity) -> [GroupKind] {
        if case .tool(let name) = part, name.lowercased() == "question" { return [] }
        let activity: [GroupKind]
        if verbosity == .low {
            if case .text = part { activity = [] } else { activity = [.activity] }
        } else {
            activity = []
        }
        switch part {
        case .reasoning:
            return activity + [.reasoning]
        case .tool(let name) where explorationTools.contains(name.lowercased()):
            return activity + [.exploration]
        default:
            return activity
        }
    }

    // parity: tui/src/routes/session/grouping/session.ts#instructionPaths [status=implemented hash=89e467b88507]
    public static func instructionPaths(_ message: SessionMessageSchema.Info?) -> [String] {
        guard case .synthetic(let syn) = message,
              case .object(let instruction) = syn.metadata?["instruction"],
              case .array(let paths) = instruction["paths"]
        else { return [] }
        return paths.compactMap { item in
            if case .string(let s) = item { return s }
            return nil
        }
    }

    // parity: tui/src/routes/session/grouping/session.ts#messagePath [status=implemented hash=cdc4a94bb8dd]
    public static func messagePath(_ message: SessionMessageSchema.Info, verbosity: Verbosity) -> [GroupKind] {
        if instructionPaths(message).isEmpty { return [] }
        return verbosity == .low ? [.activity, .instructions] : [.instructions]
    }

    // parity: tui/src/routes/session/grouping/session.ts#completePrevious [status=implemented hash=a7356fc7c20b]
    public static func completePrevious(_ rows: inout [SessionRow], index: Int? = nil) {
        let idx = (index ?? rows.count) - 1
        guard idx >= 0 && idx < rows.count, case .group(var group) = rows[idx] else { return }
        group.completed = true
        rows[idx] = .group(group)
    }

    // parity: tui/src/routes/session/grouping/session.ts#append [status=implemented hash=f578f2efcb93]
    public static func append(
        _ rows: inout [SessionRow],
        ref: PartRef,
        part: AppendPart,
        index: Int? = nil,
        verbosity: Verbosity = defaultVerbosity
    ) {
        let insertAt = index ?? rows.count
        let grouped = groupEntries([SessionEntry.part(ref: ref)]) { _ in partPath(part, verbosity: verbosity) }
        guard let node = grouped.first else { return }
        if case .entry(let entry) = node {
            completePrevious(&rows, index: insertAt)
            rows.insert(.entry(entry), at: insertAt)
            return
        }
        guard case .group(let nodeKind, let nodeChildren, let nodeSize) = node else { return }
        if insertAt - 1 >= 0 && insertAt - 1 < rows.count,
           case .group(var previous) = rows[insertAt - 1],
           previous.kind == nodeKind
        {
            let pendingCount = previous.kind == .exploration ? previous.pending.count : 0
            if let (left, right) = try? splitGroups([previous.asNode], count: max(0, previous.size - pendingCount)),
               case .group(_, let mergedChildren, let mergedSize) = mergeGroups(mergeGroups(left, [node]), right).first
            {
                previous.children = mergedChildren
                previous.size = mergedSize
                if case .reasoning(let completedAt) = part {
                    previous.completed = previous.completed && (completedAt != nil)
                }
                rows[insertAt - 1] = .group(previous)
                return
            }
        }
        completePrevious(&rows, index: insertAt)
        let isCompleted: Bool
        if nodeKind == .reasoning, case .reasoning(let completedAt) = part {
            isCompleted = completedAt != nil
        } else {
            isCompleted = false
        }
        rows.insert(
            .group(SessionGroup(kind: nodeKind, children: nodeChildren, size: nodeSize, completed: isCompleted)),
            at: insertAt
        )
    }

    // parity: tui/src/routes/session/grouping/session.ts#groupRefs [status=implemented hash=9b9c90e1dffb]
    public static func groupRefs(_ row: SessionGroup, includePending: Bool = false) -> [PartRef] {
        let pending = (!includePending && (row.kind == .exploration || row.kind == .activity)) ? row.pending : []
        func visit(_ nodes: [SessionNode]) -> [PartRef] {
            nodes.flatMap { node -> [PartRef] in
                switch node {
                case .group(_, let children, _):
                    return visit(children)
                case .entry(.part(let ref)):
                    if pending.contains(ref) { return [] }
                    return [ref]
                case .entry:
                    return []
                }
            }
        }
        return visit(row.children)
    }

    // parity: tui/src/routes/session/grouping/session.ts#partitionPending [status=implemented hash=85d0ce8d2261]
    public static func partitionPending(_ rows: inout [SessionRow], pending: Set<String>) {
        for idx in rows.indices {
            guard case .group(var group) = rows[idx],
                  group.kind == .exploration || group.kind == .activity
            else { continue }
            if group.kind == .exploration {
                func isBlocked(_ node: SessionNode) -> Bool {
                    if case .entry(.part(let ref)) = node { return pending.contains(ref.partID) }
                    return false
                }
                group.children = group.children.filter { !isBlocked($0) } + group.children.filter { isBlocked($0) }
            }
            group.pending = groupRefs(group, includePending: true).filter { pending.contains($0.partID) }
            rows[idx] = .group(group)
        }
    }

    // parity: tui/src/routes/session/grouping/session.ts#hasPart [status=implemented hash=19402a3c39f1]
    public static func hasPart(_ rows: [SessionRow], ref: PartRef) -> Bool {
        rows.contains { row in
            switch row {
            case .entry(.part(let r)): return r == ref
            case .group(let g): return groupRefs(g, includePending: true).contains(ref)
            default: return false
            }
        }
    }

    // MARK: - Anchors & Anchor Views (`anchors.ts`, `anchor-view.tsx`)

    // parity: tui/src/routes/session/anchors.ts#AnchorTarget [status=implemented hash=665b03429d35]
    public enum AnchorTarget: Equatable, Hashable, Sendable, Codable {
        case part(ref: PartRef)
        case group(groupID: String)
    }

    public struct TimelineAnchor: @unchecked Sendable {
        public let target: AnchorTarget
        public let node: Renderable

        public init(target: AnchorTarget, node: Renderable) {
            self.target = target
            self.node = node
        }
    }

    // parity: tui/src/routes/session/anchors.ts#anchorKey [status=implemented hash=b779ed8db03f]
    public static func anchorKey(_ target: AnchorTarget) -> String {
        switch target {
        case .part(let ref):
            return "[\"part\",\"\(ref.messageID)\",\"\(ref.partID)\"]"
        case .group(let groupID):
            return "[\"group\",\"\(groupID)\"]"
        }
    }

    // parity: tui/src/routes/session/anchors.ts#entryRef [status=implemented hash=178c51cba90d]
    public static func entryRef(_ entry: SessionEntry) -> PartRef? {
        switch entry {
        case .part(let ref): return ref
        case .message(let messageID): return PartRef(messageID: messageID, partID: "message")
        default: return nil
        }
    }

    private static func firstAnchorRef(_ nodes: [SessionNode]) -> PartRef? {
        for node in nodes {
            switch node {
            case .entry(let e):
                if let ref = entryRef(e) { return ref }
            case .group(_, let children, _):
                if let ref = firstAnchorRef(children) { return ref }
            }
        }
        return nil
    }

    // parity: tui/src/routes/session/anchors.ts#groupID [status=implemented hash=c0eaf4416f06]
    public static func groupID(kind: GroupKind, children: [SessionNode], level: Int) -> String? {
        guard let ref = firstAnchorRef(children) else { return nil }
        return "[\"\(ref.messageID)\",\"\(ref.partID)\",\"\(kind.rawValue)\",\(level)]"
    }

    // parity: tui/src/routes/session/anchors.ts#containsAnchor [status=implemented hash=c0df1162b031]
    public static func containsAnchor(_ node: SessionNode, target: AnchorTarget, level: Int = 0) -> Bool {
        switch node {
        case .group(let kind, let children, _):
            if case .group(let targetID) = target, groupID(kind: kind, children: children, level: level) == targetID {
                return true
            }
            return children.contains { containsAnchor($0, target: target, level: level + 1) }
        case .entry(let entry):
            guard case .part(let targetRef) = target, let ref = entryRef(entry) else { return false }
            return ref == targetRef
        }
    }

    public final class TimelineAnchors: @unchecked Sendable {
        private var entries: [String: TimelineAnchor] = [:]

        public init() {}

        public func register(_ anchor: TimelineAnchor) -> () -> Void {
            let key = anchorKey(anchor.target)
            entries[key] = anchor
            return { [weak self] in
                if self?.entries[key]?.node === anchor.node {
                    self?.entries.removeValue(forKey: key)
                }
            }
        }

        public func get(_ target: AnchorTarget) -> TimelineAnchor? {
            guard let anchor = entries[anchorKey(target)], !anchor.node.isDestroyed, anchor.node.height > 0 else {
                return nil
            }
            return anchor
        }

        public func list() -> [TimelineAnchor] {
            entries.values
                .filter { !$0.node.isDestroyed && $0.node.height > 0 }
                .sorted { $0.node.y < $1.node.y }
        }

        public func forMessage(_ messageID: String) -> TimelineAnchor? {
            list().first { anchor in
                if case .part(let ref) = anchor.target { return ref.messageID == messageID }
                return false
            }
        }

        public func messagePositions() -> [(id: String, y: Int)] {
            var seen = Set<String>()
            var out: [(id: String, y: Int)] = []
            for anchor in list() {
                if case .part(let ref) = anchor.target, seen.insert(ref.messageID).inserted {
                    out.append((id: ref.messageID, y: anchor.node.y))
                }
            }
            return out
        }
    }

    // parity: tui/src/routes/session/anchors.ts#createTimelineAnchors [status=implemented hash=3c541edcad1f]
    public static func createTimelineAnchors() -> TimelineAnchors {
        TimelineAnchors()
    }

    // parity: tui/src/routes/session/anchor-view.tsx#visitEntries [status=implemented hash=5fe723a3d3d0]
    public static func visitEntries(_ nodes: [SessionNode], _ visit: (SessionEntry) -> Void) {
        for node in nodes {
            switch node {
            case .entry(let e): visit(e)
            case .group(_, let children, _): visitEntries(children, visit)
            }
        }
    }

    // parity: tui/src/routes/session/anchor-view.tsx#useEntryAnchor [status=adapted hash=8f6552f5dffc]
    public static func useEntryAnchor(
        anchors: TimelineAnchors,
        entry: SessionEntry,
        node: BoxRenderable
    ) -> (() -> Void)? {
        guard let ref = entryRef(entry) else { return nil }
        return anchors.register(TimelineAnchor(target: .part(ref: ref), node: node))
    }

    // parity: tui/src/routes/session/anchor-view.tsx#EntryAnchor [status=adapted hash=76878194fa6e]
    public static func EntryAnchor(
        ctx: any RenderContext,
        anchors: TimelineAnchors,
        entry: SessionEntry,
        marginTop: Int? = nil,
        children: [Renderable] = []
    ) -> BoxRenderable {
        let box = BoxRenderable(ctx: ctx, options: BoxOptions(
            flexShrink: 0,
            marginTop: marginTop.map { .point(Float($0)) }
        ))
        for child in children { box.add(child) }
        _ = useEntryAnchor(anchors: anchors, entry: entry, node: box)
        return box
    }

    // parity: tui/src/routes/session/anchor-view.tsx#GroupAnchor [status=adapted hash=3bdb299f515d]
    public static func GroupAnchor(
        ctx: any RenderContext,
        anchors: TimelineAnchors,
        groupID: String?,
        active: Bool,
        children: [Renderable] = []
    ) -> BoxRenderable {
        let box = BoxRenderable(ctx: ctx, options: BoxOptions(flexShrink: 0, flexDirection: .column))
        for child in children { box.add(child) }
        if active, let groupID {
            _ = anchors.register(TimelineAnchor(target: .group(groupID: groupID), node: box))
        }
        return box
    }

    // MARK: - Activity Summary (`packages/tui/src/routes/session/activity-summary.ts`)

    public struct ActivityItem: Equatable, Sendable {
        public let message: SessionMessageSchema.Assistant
        public let part: SessionMessageSchema.AssistantContent

        public init(message: SessionMessageSchema.Assistant, part: SessionMessageSchema.AssistantContent) {
            self.message = message
            self.part = part
        }
    }

    public struct ActivitySummaryResult: Equatable, Hashable, Sendable {
        public let label: String
        public let active: Bool

        public init(label: String, active: Bool) {
            self.label = label
            self.active = active
        }
    }

    private static func canonicalToolNameLocal(_ name: String) -> String {
        switch name.lowercased() {
        case "bash": return "shell"
        case "apply_patch": return "patch"
        case "task": return "subagent"
        default: return name.lowercased()
        }
    }

    private static func isActivityItemActive(_ item: ActivityItem, closed: Bool) -> Bool {
        switch item.part {
        case .reasoning(let r):
            return !closed && r.time?.completed == nil && item.message.time.completed == nil
        case .tool(let t):
            switch t.state {
            case .streaming, .running: return true
            case .completed, .error: return false
            }
        case .text:
            return false
        }
    }

    // parity: tui/src/routes/session/activity-summary.ts#busyLabel [status=implemented hash=227e5f2f250e]
    public static func busyLabel(_ part: SessionMessageSchema.AssistantContent) -> String {
        switch part {
        case .reasoning: return "Thinking…"
        case .tool(let tool):
            let name = canonicalToolNameLocal(tool.name)
            let noun = name == "shell" ? "command" : name == "execute" ? "code" : name
            let verb: String
            if case .streaming = tool.state { verb = "Preparing" } else { verb = "Running" }
            return "\(verb) \(noun)…"
        case .text:
            return ""
        }
    }

    // parity: tui/src/routes/session/activity-summary.ts#activitySummary [status=implemented hash=4bd01c48473f]
    public static func activitySummary(
        _ items: [ActivityItem],
        instructions: Int,
        closed: Bool = false
    ) -> ActivitySummaryResult {
        var commands = 0
        var edits = 0
        var thoughts = 0
        var reads = 0
        var tools = 0
        for item in items {
            switch item.part {
            case .reasoning(let r):
                if !isActivityItemActive(item, closed: closed) && !reasoningContent(r).isEmpty {
                    thoughts += 1
                }
            case .tool(let t):
                let name = canonicalToolNameLocal(t.name)
                if name == "execute" {
                    var finishedNested = 0
                    let meta: [String: JSONValue]?
                    switch t.state {
                    case .running(let s): meta = s.metadata
                    case .completed(let s): meta = s.metadata
                    case .error(let s): meta = s.metadata
                    case .streaming: meta = nil
                    }
                    if case .array(let calls) = meta?["toolCalls"] {
                        for call in calls {
                            if case .object(let dict) = call,
                               case .string(let st) = dict["status"], st != "running",
                               case .string(let toolName) = dict["tool"]
                            {
                                finishedNested += 1
                                if canonicalToolNameLocal(toolName) == "read" { reads += 1 } else { tools += 1 }
                            }
                        }
                    }
                    if finishedNested == 0 && !isActivityItemActive(item, closed: closed) {
                        tools += 1
                    }
                } else if !isActivityItemActive(item, closed: closed) {
                    if name == "shell" { commands += 1 }
                    else if name == "read" { reads += 1 }
                    else if name == "edit" || name == "write" || name == "patch" { edits += 1 }
                    else { tools += 1 }
                }
            case .text:
                break
            }
        }
        let pairs: [(String, Int)] = [
            ("command", commands),
            ("edit", edits),
            ("thought", thoughts),
            ("read", reads),
            ("tool", tools),
            ("instruction", instructions),
        ]
        let label = pairs
            .filter { $0.1 > 0 }
            .map { "\($0.1) \($0.0)\($0.1 == 1 ? "" : "s")" }
            .joined(separator: ", ")
        let active = items.contains { isActivityItemActive($0, closed: closed) }
        return ActivitySummaryResult(label: label, active: active)
    }

    // parity: tui/src/routes/session/activity-summary.ts#summarizeActivity [status=implemented hash=1a70e4e92f00]
    public static func summarizeActivity(
        children: [SessionNode],
        message: (String) -> SessionMessageSchema.Info?,
        pending: [PartRef],
        closed: Bool
    ) -> ActivitySummaryResult {
        var entries: [SessionEntry] = []
        visitEntries(children) { entries.append($0) }
        var items: [ActivityItem] = []
        var instructionFiles = Set<String>()
        for entry in entries {
            switch entry {
            case .part(let ref):
                if pending.contains(ref) { continue }
                guard case .assistant(let assistant) = message(ref.messageID),
                      let part = resolvePart(assistant, partID: ref.partID)
                else { continue }
                switch part {
                case .reasoning, .tool: items.append(ActivityItem(message: assistant, part: part))
                case .text: break
                }
            case .message(let mid):
                for p in instructionPaths(message(mid)) { instructionFiles.insert(p) }
            default:
                break
            }
        }
        let summary = activitySummary(items, instructions: instructionFiles.count, closed: closed)
        if !summary.label.isEmpty { return summary }
        let current = items.first { isActivityItemActive($0, closed: closed) }
        return ActivitySummaryResult(
            label: current.map { busyLabel($0.part) } ?? "",
            active: summary.active
        )
    }

    // MARK: - Mount Budget & Message Navigation (`mount-budget.ts`, `message-navigation.ts`, `history.ts`)

    // parity: tui/src/routes/session/mount-budget.ts#rowWeight [status=implemented hash=bc75a6ed301e]
    public static func rowWeight(
        _ row: SessionRow,
        expanded: (String, GroupKind) -> Bool,
        grouped: (GroupKind) -> Bool
    ) -> Int {
        guard case .group(let g) = row else { return 1 }
        func visit(_ kind: GroupKind, _ children: [SessionNode], _ size: Int, _ level: Int) -> Int {
            if !grouped(kind) { return size }
            guard let id = groupID(kind: kind, children: children, level: level),
                  expanded(id, kind)
            else { return 1 }
            return children.reduce(1) { total, child in
                switch child {
                case .group(let ck, let cc, let cs): return total + visit(ck, cc, cs, level + 1)
                case .entry: return total + 1
                }
            }
        }
        return visit(g.kind, g.children, g.size, 0)
    }

    // parity: tui/src/routes/session/mount-budget.ts#rowsBefore [status=implemented hash=c70c5478212a]
    public static func rowsBefore(_ weights: [Int], end: Int, budget: Int) -> Int {
        var index = min(end, weights.count)
        var spent = 0
        while index > 0 && spent < budget {
            index -= 1
            spent += weights[index]
        }
        return index
    }

    // parity: tui/src/routes/session/mount-budget.ts#rowsAfter [status=implemented hash=6c22150ace2b]
    public static func rowsAfter(_ weights: [Int], start: Int, budget: Int) -> Int {
        var index = max(0, start)
        var spent = 0
        while index < weights.count && spent < budget {
            spent += weights[index]
            index += 1
        }
        return index
    }

    // parity: tui/src/routes/session/message-navigation.ts#messageNavigationSlack [status=implemented hash=d24f6c7e4ce8]
    public static func messageNavigationSlack(
        top: Int,
        viewportHeight: Int,
        scrollHeight: Int,
        currentSlack: Int
    ) -> Int {
        let contentHeight = scrollHeight - currentSlack
        return max(0, top + viewportHeight - contentHeight)
    }

    public struct MessageChildPosition: Equatable, Hashable, Sendable {
        public let id: String?
        public let y: Int

        public init(id: String?, y: Int) {
            self.id = id
            self.y = y
        }
    }

    public struct MessageBoundary: Equatable, Hashable, Sendable {
        public let id: String
        public let y: Int
        public let top: Int

        public init(id: String, y: Int, top: Int) {
            self.id = id
            self.y = y
            self.top = top
        }
    }

    // parity: tui/src/routes/session/message-navigation.ts#findMessageBoundary [status=implemented hash=7932dd6e5ecc]
    public static func findMessageBoundary(
        direction: String,
        children: [MessageChildPosition],
        messages: [SessionMessageSchema.Info],
        scrollTop: Int,
        viewportY: Int,
        currentID: String? = nil,
        userOnly: Bool = false
    ) -> MessageBoundary? {
        let byID = Dictionary(uniqueKeysWithValues: messages.map { ($0.id.rawValue, $0) })
        let visible: [MessageBoundary] = children.compactMap { child in
            guard let id = child.id, let msg = byID[id] else { return nil }
            switch msg {
            case .user(let u) where !u.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                let y = scrollTop + child.y - viewportY
                return MessageBoundary(id: id, y: y, top: y)
            case .assistant(let a) where !userOnly:
                let hasText = a.content.contains { part in
                    if case .text(let t) = part {
                        return !t.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    }
                    return false
                }
                guard hasText else { return nil }
                let y = scrollTop + child.y - viewportY
                return MessageBoundary(id: id, y: y, top: max(0, y - 1))
            default:
                return nil
            }
        }.sorted { $0.y < $1.y }

        if let currentID, let idx = visible.firstIndex(where: { $0.id == currentID }) {
            let targetIdx = idx + (direction == "next" ? 1 : -1)
            return (targetIdx >= 0 && targetIdx < visible.count) ? visible[targetIdx] : nil
        }
        if direction == "next" {
            return visible.first { $0.y > scrollTop }
        }
        return visible.last { $0.y < scrollTop }
    }

    public final class HistoryPrependController: @unchecked Sendable {
        private let sessionID: @Sendable () -> String
        private let more: @Sendable (String) -> Bool
        private let loadMore: @Sendable (String) async throws -> Void
        private let active: @Sendable (String) -> Bool
        private let scrollBy: @Sendable (Int) -> Void
        private let state = Mutex<Bool>(false)

        public init(
            sessionID: @escaping @Sendable () -> String,
            more: @escaping @Sendable (String) -> Bool,
            loadMore: @escaping @Sendable (String) async throws -> Void,
            active: @escaping @Sendable (String) -> Bool,
            scrollBy: @escaping @Sendable (Int) -> Void
        ) {
            self.sessionID = sessionID
            self.more = more
            self.loadMore = loadMore
            self.active = active
            self.scrollBy = scrollBy
        }

        public func trigger(scrollDelta: Int = 0) async -> Bool {
            let sid = sessionID()
            let canStart = state.withLock { busy -> Bool in
                if busy { return false }
                busy = true
                return true
            }
            guard canStart else { return false }
            defer { state.withLock { $0 = false } }
            guard more(sid) else { return false }
            try? await loadMore(sid)
            if active(sid) { scrollBy(scrollDelta) }
            return true
        }
    }

    // parity: tui/src/routes/session/history.ts#createHistoryPrepend [status=adapted hash=e27f75365698]
    public static func createHistoryPrepend(
        sessionID: @escaping @Sendable () -> String,
        more: @escaping @Sendable (String) -> Bool,
        loadMore: @escaping @Sendable (String) async throws -> Void,
        active: @escaping @Sendable (String) -> Bool,
        scrollBy: @escaping @Sendable (Int) -> Void
    ) -> HistoryPrependController {
        HistoryPrependController(
            sessionID: sessionID,
            more: more,
            loadMore: loadMore,
            active: active,
            scrollBy: scrollBy
        )
    }

    // MARK: - Session Rows (`packages/tui/src/routes/session/rows.ts`)

    // parity: tui/src/routes/session/rows.ts#completeGroupBoundary [status=implemented hash=c7eeecd2f62b]
    public static func completeGroupBoundary(
        rows: @Sendable () -> [SessionRow],
        messagesCount: @Sendable () -> Int,
        more: @Sendable () -> Bool,
        loadMore: @Sendable () async throws -> Void,
        active: @Sendable () -> Bool
    ) async throws {
        while active() && more() {
            guard case .group = rows().first else { break }
            let before = messagesCount()
            try await loadMore()
            if messagesCount() == before { return }
        }
    }

    private static func tokenTotal(_ tokens: SessionSchema.TokenUsage) -> Double {
        tokens.input + tokens.output + tokens.reasoning + tokens.cache.read + tokens.cache.write
    }

    // parity: tui/src/routes/session/rows.ts#reduceSessionRows [status=implemented hash=21f707f56dfb]
    public static func reduceSessionRows(
        _ messages: [SessionMessageSchema.Info],
        inputs: Set<String> = [],
        turnTokens: Bool = false,
        verbosity: Verbosity = defaultVerbosity
    ) -> [SessionRow] {
        let pendingCompactions = messages.filter {
            if case .compaction(.running) = $0 { return true }
            return false
        }
        var pendingIDs = inputs
        for c in pendingCompactions { pendingIDs.insert(c.id.rawValue) }

        var steps: [SessionMessageSchema.Assistant] = []
        var previousTurnCache: CacheUsage? = nil
        let legacy = !messages.contains {
            if case .idle = $0 { return true }
            return false
        }

        func flushTurn(_ entries: inout [ProjectionEntry]) {
            guard turnTokens else { return }
            let withTokens = steps.filter { msg in
                guard let t = msg.tokens else { return false }
                return tokenTotal(t) > 0
            }
            steps.removeAll()
            guard let last = withTokens.last, let lastTokens = last.tokens else { return }
            entries.append(ProjectionEntry(
                entry: .turnUsage(messageIDs: withTokens.map(\.id.rawValue), previousCache: previousTurnCache)
            ))
            previousTurnCache = CacheUsage(read: Int(lastTokens.cache.read), model: last.model)
        }

        let ordered = messages.filter { !pendingIDs.contains($0.id.rawValue) }
            + pendingCompactions
            + messages.filter { inputs.contains($0.id.rawValue) }

        var shownError: SessionErrorSchema.Error? = nil
        var entries: [ProjectionEntry] = []

        for message in ordered {
            switch message {
            case .idle(let idle):
                if let err = idle.error, err.type != shownError?.type || err.message != shownError?.message {
                    entries.append(ProjectionEntry(entry: .message(messageID: idle.id.rawValue), path: [], closesPrevious: true))
                }
                shownError = nil
                flushTurn(&entries)
            case .synthetic(let syn):
                if syn.description?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true { continue }
                entries.append(ProjectionEntry(
                    entry: .message(messageID: syn.id.rawValue),
                    path: messagePath(message, verbosity: verbosity),
                    closesPrevious: !pendingIDs.contains(syn.id.rawValue)
                ))
            case .compaction(let comp):
                switch comp {
                case .running:
                    break
                case .completed:
                    shownError = nil
                    if turnTokens { previousTurnCache = nil }
                case .failed(let failed):
                    shownError = failed.error
                }
                entries.append(ProjectionEntry(
                    entry: .message(messageID: comp.id.rawValue),
                    path: messagePath(message, verbosity: verbosity),
                    closesPrevious: !pendingIDs.contains(comp.id.rawValue)
                ))
            case .assistant(let assistant):
                if turnTokens { steps.append(assistant) }
                shownError = assistant.error
                var textOrd = 0
                var reasonOrd = 0
                for part in assistant.content {
                    switch part {
                    case .text(let t):
                        let partID = "text:\(textOrd)"
                        textOrd += 1
                        if t.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                        entries.append(ProjectionEntry(
                            entry: .part(ref: PartRef(messageID: assistant.id.rawValue, partID: partID)),
                            part: .text,
                            path: partPath(.text, verbosity: verbosity)
                        ))
                    case .reasoning(let r):
                        let partID = "reasoning:\(reasonOrd)"
                        reasonOrd += 1
                        if r.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                        let ap = AppendPart.reasoning(completedAt: r.time?.completed)
                        entries.append(ProjectionEntry(
                            entry: .part(ref: PartRef(messageID: assistant.id.rawValue, partID: partID)),
                            part: ap,
                            path: partPath(ap, verbosity: verbosity)
                        ))
                    case .tool(let tool):
                        let ap = AppendPart.tool(name: tool.name)
                        entries.append(ProjectionEntry(
                            entry: .part(ref: PartRef(messageID: assistant.id.rawValue, partID: tool.id)),
                            part: ap,
                            path: partPath(ap, verbosity: verbosity)
                        ))
                    }
                }
                let isNonTerminalFinish = assistant.finish == .toolCalls || assistant.finish == .unknown
                let terminal = (assistant.finish != nil && !isNonTerminalFinish) || assistant.error != nil
                if terminal || assistant.retry != nil {
                    entries.append(ProjectionEntry(entry: .assistantFooter(messageID: assistant.id.rawValue)))
                }
                if terminal && legacy { flushTurn(&entries) }
            default:
                entries.append(ProjectionEntry(
                    entry: .message(messageID: message.id.rawValue),
                    path: messagePath(message, verbosity: verbosity),
                    closesPrevious: !pendingIDs.contains(message.id.rawValue)
                ))
            }
        }
        return projectEntries(entries)
    }

    // parity: tui/src/routes/session/rows.ts#createSessionRows [status=adapted hash=7cb85753233c]
    public static func createSessionRows(
        messages: [SessionMessageSchema.Info],
        inputs: Set<String> = [],
        pendingPermissions: Set<String> = [],
        turnTokens: Bool = false,
        verbosity: Verbosity = defaultVerbosity
    ) -> [SessionRow] {
        var rows = reduceSessionRows(messages, inputs: inputs, turnTokens: turnTokens, verbosity: verbosity)
        partitionPending(&rows, pending: pendingPermissions)
        return rows
    }

    // parity: tui/src/routes/session/rows.ts#cacheReuseDrop [status=implemented hash=1d9d0c69c3cc]
    public static func cacheReuseDrop(previous: CacheUsage?, current: CacheUsage) -> Int? {
        guard let previous else { return nil }
        guard previous.model.providerID == current.model.providerID,
              previous.model.id == current.model.id,
              previous.model.variant == current.model.variant
        else { return nil }
        let drop = previous.read - current.read
        if current.model.providerID == "openai" && drop >= 1_024 && drop <= 2_048 { return nil }
        return drop > 0 ? drop : nil
    }

    private static func rowBoundaryMessageID(
        _ row: SessionRow,
        messages: [String: SessionMessageSchema.Info]
    ) -> String? {
        switch row {
        case .entry(.message(let mid)):
            if case .user(let u) = messages[mid], !u.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return mid
            }
            return nil
        case .entry(.part(let ref)):
            if case .assistant = messages[ref.messageID] { return ref.messageID }
            return nil
        case .group(let g):
            guard let mid = groupRefs(g).first?.messageID, case .assistant = messages[mid] else { return nil }
            return mid
        case .entry(.assistantFooter(let mid)):
            if case .assistant = messages[mid] { return mid }
            return nil
        case .entry(.turnUsage(let mids, _)):
            guard let mid = mids.first, case .assistant = messages[mid] else { return nil }
            return mid
        case .entry(.compactionQueued):
            return nil
        }
    }

    // parity: tui/src/routes/session/rows.ts#messageBoundaryIDs [status=implemented hash=6906b50f1199]
    public static func messageBoundaryIDs(
        _ rows: [SessionRow],
        messages: [SessionMessageSchema.Info]
    ) -> [String?] {
        let byID = Dictionary(uniqueKeysWithValues: messages.map { ($0.id.rawValue, $0) })
        var seen = Set<String>()
        return rows.map { row in
            guard let id = rowBoundaryMessageID(row, messages: byID), seen.insert(id).inserted else { return nil }
            return id
        }
    }

    // parity: tui/src/routes/session/rows.ts#sessionRowID [status=implemented hash=166beb75f9c2]
    public static func sessionRowID(_ row: SessionRow, boundaryID: String? = nil) -> String? {
        if let boundaryID { return boundaryID }
        if case .entry(.part(let ref)) = row {
            return "session-part:\(ref.messageID):\(ref.partID)"
        }
        return nil
    }

    // parity: tui/src/routes/session/rows.ts#resolvePart [status=implemented hash=f40e4ec13843]
    public static func resolvePart(
        _ message: SessionMessageSchema.Assistant,
        partID: String
    ) -> SessionMessageSchema.AssistantContent? {
        for part in message.content {
            if case .tool(let t) = part, t.id == partID { return part }
        }
        if partID.hasPrefix("text:"), let ordinal = Int(partID.dropFirst(5)) {
            let texts = message.content.filter { if case .text = $0 { return true }; return false }
            return (ordinal >= 0 && ordinal < texts.count) ? texts[ordinal] : nil
        }
        if partID.hasPrefix("reasoning:"), let ordinal = Int(partID.dropFirst(10)) {
            let reasonings = message.content.filter { if case .reasoning = $0 { return true }; return false }
            return (ordinal >= 0 && ordinal < reasonings.count) ? reasonings[ordinal] : nil
        }
        return nil
    }

    // MARK: - Session Helpers (`index.tsx`, `message-parts.tsx`, `thinking-syntax.ts`, `permission.tsx`, `render-context.tsx`)

    // parity: tui/src/routes/session/message-parts.tsx#INLINE_TOOL_ICON_WIDTH [status=implemented hash=c897fa61f188]
    public static let INLINE_TOOL_ICON_WIDTH = 2

    private static let knownToolDisplays: Set<String> = [
        "shell", "glob", "read", "grep", "webfetch", "websearch",
        "write", "edit", "subagent", "execute", "patch", "todowrite", "question", "skill",
    ]

    // parity: tui/src/routes/session/message-parts.tsx#toolDisplay [status=implemented hash=b630c271910c]
    public static func toolDisplay(_ tool: String) -> String {
        let normalized = canonicalToolNameLocal(tool)
        return knownToolDisplays.contains(normalized) ? normalized : "generic"
    }

    // parity: tui/src/routes/session/message-parts.tsx#reasoningContent [status=implemented hash=a7ad682c7a4b]
    public static func reasoningContent(_ part: SessionMessageSchema.AssistantReasoning) -> String {
        part.text.replacingOccurrences(of: "[REDACTED]", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // parity: tui/src/routes/session/thinking-syntax.ts#generateThinkingSyntax [status=implemented hash=8408232937e9]
    public static func generateThinkingSyntax(_ syntax: SyntaxStyle, foreground: RGBA) -> SyntaxStyle {
        var styles: [String: StyleDefinitionInput] = [:]
        for name in syntax.getRegisteredNames() {
            if let existing = syntax.getStyle(name) {
                styles[name] = StyleDefinitionInput(
                    fg: .rgba(foreground),
                    bg: existing.bg.map { .rgba($0) },
                    bold: existing.bold,
                    italic: existing.italic,
                    underline: existing.underline,
                    dim: existing.dim,
                    strikethrough: existing.strikethrough
                )
            }
        }
        return SyntaxStyle.fromStyles(styles)
    }

    // parity: tui/src/routes/session/index.tsx#genericToolSummary [status=implemented hash=1a6857b7b7be]
    public static func genericToolSummary(_ tool: String, input: [String: JSONValue]) -> String {
        let parts = input.keys.sorted().compactMap { key -> String? in
            switch input[key] {
            case .string(let s): return "\(key)=\(s)"
            case .int(let i): return "\(key)=\(i)"
            case .double(let d): return "\(key)=\(d)"
            case .bool(let b): return "\(key)=\(b)"
            default: return nil
            }
        }
        let args = parts.joined(separator: ", ").replacingOccurrences(of: "\n", with: " ")
        return args.isEmpty ? tool : "\(tool) \(args)"
    }

    public struct SubagentModelDescriptor: Equatable, Hashable, Sendable {
        public let providerID: String
        public let id: String
        public let name: String

        public init(providerID: String, id: String, name: String) {
            self.providerID = providerID
            self.id = id
            self.name = name
        }
    }

    // parity: tui/src/routes/session/index.tsx#subagentModelLabel [status=implemented hash=953340d168e6]
    public static func subagentModelLabel(_ value: String?, models: [SubagentModelDescriptor]? = nil) -> String? {
        guard let value, !value.isEmpty else { return nil }
        let hashParts = value.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let reference = String(hashParts[0])
        let variant: String? = hashParts.count > 1 && !hashParts[1].isEmpty ? String(hashParts[1]) : nil
        let providerID: String
        let modelID: String
        if let slash = reference.firstIndex(of: "/") {
            providerID = String(reference[..<slash])
            modelID = String(reference[reference.index(after: slash)...])
        } else {
            providerID = ""
            modelID = reference
        }
        let name = models?.first(where: { $0.providerID == providerID && $0.id == modelID })?.name
        return "\(name ?? reference)\(variant.map { " (\($0))" } ?? "")"
    }

    public struct ParsedApplyPatchFile: Equatable, Hashable, Sendable {
        public let type: String
        public let relativePath: String
        public let filePath: String
        public let patch: String
        public let additions: Int
        public let deletions: Int
        public let movePath: String?
    }

    // parity: tui/src/routes/session/index.tsx#parseApplyPatchFiles [status=implemented hash=3fb666ffeb40]
    public static func parseApplyPatchFiles(_ value: JSONValue?) -> [ParsedApplyPatchFile] {
        guard case .array(let items) = value else { return [] }
        return items.compactMap { item in
            guard case .object(let dict) = item else { return nil }
            let status: String? = if case .string(let s) = dict["status"] { s } else { nil }
            let rawType: String? = if case .string(let s) = dict["type"] { s } else { nil }
            let mappedType = rawType ?? (status == "added" ? "add" : status == "deleted" ? "delete" : status == "modified" ? "update" : nil)
            let fileVal: String? = if case .string(let s) = dict["file"] { s } else { nil }
            let relPathVal: String? = if case .string(let s) = dict["relativePath"] { s } else { nil }
            let filePathVal: String? = if case .string(let s) = dict["filePath"] { s } else { nil }
            let rel = fileVal ?? relPathVal
            let fp = filePathVal ?? rel
            let patch: String? = if case .string(let s) = dict["patch"] { s } else { nil }
            let additions: Int? = switch dict["additions"] { case .int(let i): Int(i); case .double(let d) where d.isFinite: Int(d); default: nil }
            let deletions: Int? = switch dict["deletions"] { case .int(let i): Int(i); case .double(let d) where d.isFinite: Int(d); default: nil }
            let movePath: String? = if case .string(let s) = dict["movePath"] { s } else { nil }
            guard let type = mappedType, let relativePath = rel, let filePath = fp,
                  let patch, let additions, let deletions
            else { return nil }
            return ParsedApplyPatchFile(
                type: type, relativePath: relativePath, filePath: filePath,
                patch: patch, additions: additions, deletions: deletions, movePath: movePath
            )
        }
    }

    // parity: tui/src/routes/session/index.tsx#parseQuestions [status=implemented hash=acfa0626915c]
    public static func parseQuestions(_ value: JSONValue?) -> [String] {
        guard case .array(let items) = value else { return [] }
        return items.compactMap { item in
            guard case .object(let dict) = item, case .string(let q) = dict["question"], !q.isEmpty else { return nil }
            return q
        }
    }

    // parity: tui/src/routes/session/index.tsx#parseQuestionAnswers [status=implemented hash=d3a73f39e604]
    public static func parseQuestionAnswers(_ value: JSONValue?) -> [[String]]? {
        guard case .array(let items) = value else { return nil }
        return items.map { item in
            guard case .array(let arr) = item else { return [] }
            return arr.compactMap { elem in
                if case .string(let s) = elem { return s }
                return nil
            }
        }
    }

    public struct ParsedDiagnostic: Equatable, Hashable, Sendable {
        public let line: Int
        public let character: Int
        public let message: String
    }

    // parity: tui/src/routes/session/index.tsx#parseDiagnostics [status=implemented hash=adb837cc68f1]
    public static func parseDiagnostics(_ value: JSONValue?, filePath: String) -> [ParsedDiagnostic] {
        guard case .object(let map) = value, case .array(let list) = map[filePath] else { return [] }
        return Array(list.compactMap { item -> ParsedDiagnostic? in
            guard case .object(let diag) = item else { return nil }
            let sev: Int? = switch diag["severity"] { case .int(let i): Int(i); case .double(let d): Int(d); default: nil }
            guard sev == 1,
                  case .object(let range) = diag["range"],
                  case .object(let start) = range["start"],
                  case .string(let msg) = diag["message"], !msg.isEmpty
            else { return nil }
            let line: Int? = switch start["line"] { case .int(let i): Int(i); case .double(let d) where d.isFinite: Int(d); default: nil }
            let char: Int? = switch start["character"] { case .int(let i): Int(i); case .double(let d) where d.isFinite: Int(d); default: nil }
            guard let line, let char else { return nil }
            return ParsedDiagnostic(line: line, character: char, message: msg)
        }.prefix(3))
    }

    // parity: tui/src/routes/session/permission.tsx#permissionSemanticLabel [status=implemented hash=3c3b1c35d000]
    public static func permissionSemanticLabel(action: String, title: String? = nil) -> String {
        "Permission required: \(title ?? action)"
    }

    // parity: tui/src/routes/session/form.tsx#FORM_MODE [status=implemented hash=657631d97dc0]
    public static let FORM_MODE = "form"

    // parity: tui/src/routes/session/render-context.tsx#PendingAction [status=implemented hash=09f343259d1c]
    public enum PendingAction: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
        case steer
        case queue
        case cancel
    }

    public struct SessionRenderContextValue: @unchecked Sendable {
        public let width: Int
        public let terminalWidth: Int
        public let terminalHeight: Int
        public let sessionID: String
        public let anchors: TimelineAnchors
        public let thinkingMode: TUIContext.ThinkingMode
        public let markdownMode: String
        public let groupExploration: Bool
        public let diffWrapMode: String
        public let config: TUIConfig.Resolved

        public init(
            width: Int,
            terminalWidth: Int = 80,
            terminalHeight: Int = 24,
            sessionID: String,
            anchors: TimelineAnchors = createTimelineAnchors(),
            thinkingMode: TUIContext.ThinkingMode = .show,
            markdownMode: String = "rendered",
            groupExploration: Bool = true,
            diffWrapMode: String = "word",
            config: TUIConfig.Resolved = TUIConfig.resolve(TUIConfig.Info())
        ) {
            self.width = width
            self.terminalWidth = terminalWidth
            self.terminalHeight = terminalHeight
            self.sessionID = sessionID
            self.anchors = anchors
            self.thinkingMode = thinkingMode
            self.markdownMode = markdownMode
            self.groupExploration = groupExploration
            self.diffWrapMode = diffWrapMode
            self.config = config
        }
    }

    // parity: tui/src/routes/session/render-context.tsx#context [status=adapted hash=d533aa6e82ef]
    public static let context = TUIContext.createSimpleContext(name: "SessionRenderContext") as TUIContext.SimpleContext<SessionRenderContextValue>

    // parity: tui/src/routes/session/render-context.tsx#use [status=adapted hash=e3f41a80aea0]
    public static func use() throws(TUIConfig.ConfigError) -> SessionRenderContextValue {
        try context.use()
    }

    // MARK: - Composer Context & Tabs (`packages/tui/src/routes/session/composer/*`)

    // parity: tui/src/routes/session/composer/context.ts#ComposerHint [status=implemented hash=c9ec3beb97d0]
    public struct ComposerHint: Equatable, Hashable, Sendable, Codable {
        public let label: String
        public let shortcut: String

        public init(label: String, shortcut: String) {
            self.label = label
            self.shortcut = shortcut
        }
    }

    // parity: tui/src/routes/session/composer/context.ts#ComposerTab [status=implemented hash=68f6e49c938a]
    public struct ComposerTab: Sendable {
        public let id: String
        public let label: String
        public let hints: @Sendable () -> [ComposerHint]

        public init(id: String, label: String, hints: @escaping @Sendable () -> [ComposerHint] = { [] }) {
            self.id = id
            self.label = label
            self.hints = hints
        }
    }

    public final class ComposerTabController: @unchecked Sendable {
        private struct State: Sendable {
            var tabs: [ComposerTab] = []
            var activeID: String = ""
            var open: Bool = false
        }

        private let state = Mutex(State())
        private let onCloseCallback: @Sendable () -> Void

        public init(open: Bool = false, onClose: @escaping @Sendable () -> Void = {}) {
            self.state.withLock { $0.open = open }
            self.onCloseCallback = onClose
        }

        public func register(_ tab: ComposerTab) -> @Sendable () -> Void {
            state.withLock { s in
                if let idx = s.tabs.firstIndex(where: { $0.id == tab.id }) {
                    s.tabs[idx] = tab
                } else {
                    s.tabs.append(tab)
                }
                if s.activeID.isEmpty { s.activeID = tab.id }
            }
            return { [weak self] in
                self?.state.withLock { $0.tabs.removeAll { $0.id == tab.id } }
            }
        }

        public func active(_ id: String) -> Bool {
            state.withLock { $0.open && $0.activeID == id }
        }

        public func select(_ id: String) {
            state.withLock { $0.activeID = id }
        }

        public func close() {
            state.withLock { $0.open = false }
            onCloseCallback()
        }

        public var tabs: [ComposerTab] { state.withLock { $0.tabs } }
        public var activeID: String { state.withLock { $0.activeID } }
    }

    // parity: tui/src/routes/session/composer/context.ts#ComposerContext [status=adapted hash=6064d5547261]
    public static let ComposerContext = TUIContext.createSimpleContext(name: "Composer") as TUIContext.SimpleContext<ComposerTabController>

    // parity: tui/src/routes/session/composer/context.ts#useComposerTab [status=adapted hash=0bd711d38775]
    public static func useComposerTab() throws(TUIConfig.ConfigError) -> ComposerTabController {
        try ComposerContext.use()
    }

    // parity: tui/src/routes/session/composer/index.tsx#ComposerProps [status=implemented hash=b5fc0a3a3c81]
    public struct ComposerProps: Equatable, Hashable, Sendable {
        public let sessionID: String
        public let open: Bool
        public let defaultTab: String?
        public let terminals: Bool
        public let visibleTerminalID: String?

        public init(
            sessionID: String,
            open: Bool = true,
            defaultTab: String? = nil,
            terminals: Bool = false,
            visibleTerminalID: String? = nil
        ) {
            self.sessionID = sessionID
            self.open = open
            self.defaultTab = defaultTab
            self.terminals = terminals
            self.visibleTerminalID = visibleTerminalID
        }
    }

    // MARK: - OpenTUI Renderable Builders (Home, Session, Sidebar, Composer, Parts, Permissions, Forms, Dialogs)

    private static func defaultTheme(_ theme: ResolvedTheme?) -> ResolvedTheme {
        theme ?? (try! resolveThemeDocument(ThemeDefaults.opencode, mode: .dark))
    }

    /// Builds the OpenTUI renderable tree for the Home route (logo + prompt + update notice + footer).
    // parity: tui/src/routes/home.tsx#Home [status=adapted hash=05cfe2cc478a]
    public static func Home(
        ctx: any RenderContext,
        theme: ResolvedTheme? = nil,
        promptText: String = "",
        placeholder: String = "Fix a TODO in the codebase",
        updateNotice: String? = nil,
        footerText: String = "OpenCode"
    ) -> BoxRenderable {
        let t = defaultTheme(theme)
        let root = BoxRenderable(ctx: ctx, options: BoxOptions(
            id: "route-home",
            width: .percent(100),
            height: .percent(100),
            flexDirection: .column,
            alignItems: .center,
            justifyContent: .spaceBetween,
            paddingX: .point(2),
            backgroundColor: .rgba(t.background.base)
        ))
        let center = BoxRenderable(ctx: ctx, options: BoxOptions(
            id: "home-center",
            width: .percent(100),
            flexGrow: 1,
            flexDirection: .column,
            alignItems: .center,
            justifyContent: .center,
            gap: .point(1)
        ))
        let logoBox = BoxRenderable(ctx: ctx, options: BoxOptions(id: "home-logo", flexDirection: .column))
        for i in 0..<TUILogo.logo.left.count {
            let line = "\(TUILogo.logo.left[i]) \(TUILogo.logo.right[i])"
            logoBox.add(TextRenderable(ctx: ctx, options: TextOptions(
                content: .string(line),
                fg: .rgba(t.text.base),
                wrapMode: TextWrapMode.none
            )))
        }
        center.add(logoBox)
        if let updateNotice, !updateNotice.isEmpty {
            center.add(TextRenderable(ctx: ctx, options: TextOptions(
                id: "home-update-notice",
                content: .string(updateNotice),
                fg: .rgba(t.text.action.primary.selected)
            )))
        }
        let promptBox = BoxRenderable(ctx: ctx, options: BoxOptions(
            id: "home-prompt-box",
            width: .percent(100),
            maxWidth: .point(75),
            paddingX: .point(1),
            backgroundColor: .rgba(t.background.raised.base),
            borderStyle: .single,
            border: .sides([.left]),
            borderColor: .rgba(t.border.base)
        ))
        let displayPrompt = promptText.isEmpty ? placeholder : promptText
        let promptColor = promptText.isEmpty ? t.text.muted : t.text.base
        promptBox.add(TextRenderable(ctx: ctx, options: TextOptions(
            id: "home-prompt-text",
            content: .string("› \(displayPrompt)"),
            fg: .rgba(promptColor)
        )))
        center.add(promptBox)
        root.add(center)

        let footer = BoxRenderable(ctx: ctx, options: BoxOptions(
            id: "home-footer",
            width: .percent(100),
            height: .point(1)
        ))
        footer.add(TextRenderable(ctx: ctx, options: TextOptions(
            content: .string(footerText),
            fg: .rgba(t.text.muted),
            wrapMode: TextWrapMode.none
        )))
        root.add(footer)
        return root
    }

    /// Builds the OpenTUI renderable tree for the Session route (header + transcript rows + optional sidebar + prompt).
    // parity: tui/src/routes/session/index.tsx#Session [status=adapted hash=d706cdd70ba1]
    public static func Session(
        ctx: any RenderContext,
        sessionID: String,
        title: String,
        messages: [SessionMessageSchema.Info] = [],
        showSidebar: Bool = false,
        promptText: String = "",
        theme: ResolvedTheme? = nil
    ) -> BoxRenderable {
        let t = defaultTheme(theme)
        let root = BoxRenderable(ctx: ctx, options: BoxOptions(
            id: "route-session-\(sessionID)",
            width: .percent(100),
            height: .percent(100),
            flexDirection: .row,
            backgroundColor: .rgba(t.background.base)
        ))
        let main = BoxRenderable(ctx: ctx, options: BoxOptions(
            id: "session-main",
            flexGrow: 1,
            flexDirection: .column,
            paddingX: .point(1)
        ))
        main.add(TextRenderable(ctx: ctx, options: TextOptions(
            id: "session-header",
            content: .string(title),
            fg: .rgba(t.text.base),
            attributes: createTextAttributes(bold: true),
            wrapMode: TextWrapMode.none
        )))

        let transcript = BoxRenderable(ctx: ctx, options: BoxOptions(
            id: "session-transcript",
            flexGrow: 1,
            flexDirection: .column,
            gap: .point(1)
        ))
        for msg in messages {
            switch msg {
            case .user(let u):
                transcript.add(TextRenderable(ctx: ctx, options: TextOptions(
                    content: .string("› \(u.text)"),
                    fg: .rgba(t.text.base)
                )))
            case .assistant(let a):
                for part in a.content {
                    switch part {
                    case .text(let tp):
                        transcript.add(TextPart(ctx: ctx, part: tp, theme: t))
                    case .reasoning(let rp):
                        transcript.add(ReasoningPart(ctx: ctx, part: rp, message: a, theme: t))
                    case .tool(let tool):
                        transcript.add(InlineToolRow(
                            ctx: ctx,
                            icon: "⚙",
                            label: toolDisplay(tool.name),
                            complete: tool.state.statusTag == "completed",
                            failed: tool.state.statusTag == "error",
                            theme: t
                        ))
                    }
                }
            default:
                break
            }
        }
        main.add(transcript)
        let composer = BoxRenderable(ctx: ctx, options: BoxOptions(
            id: "session-prompt",
            width: .percent(100),
            height: .point(1),
            backgroundColor: .rgba(t.background.raised.base)
        ))
        composer.add(TextRenderable(ctx: ctx, options: TextOptions(
            content: .string(promptText.isEmpty ? "› Ask anything..." : "› \(promptText)"),
            fg: .rgba(promptText.isEmpty ? t.text.muted : t.text.base)
        )))
        main.add(composer)
        root.add(main)
        if showSidebar {
            root.add(Sidebar(ctx: ctx, sessionID: sessionID, title: title, theme: t))
        }
        return root
    }

    // parity: tui/src/routes/session/sidebar.tsx#Sidebar [status=adapted hash=3bf082882f65]
    public static func Sidebar(
        ctx: any RenderContext,
        sessionID: String,
        title: String,
        details: [String] = [],
        theme: ResolvedTheme? = nil
    ) -> BoxRenderable {
        let t = defaultTheme(theme)
        let sidebar = BoxRenderable(ctx: ctx, options: BoxOptions(
            id: "session-sidebar-\(sessionID)",
            width: .point(32),
            height: .percent(100),
            flexDirection: .column,
            paddingX: .point(2),
            paddingY: .point(1),
            gap: .point(1),
            backgroundColor: .rgba(t.background.raised.base)
        ))
        sidebar.add(TextRenderable(ctx: ctx, options: TextOptions(
            content: .string(title),
            fg: .rgba(t.text.base),
            attributes: createTextAttributes(bold: true)
        )))
        for detail in details {
            sidebar.add(TextRenderable(ctx: ctx, options: TextOptions(
                content: .string(detail),
                fg: .rgba(t.text.muted)
            )))
        }
        return sidebar
    }

    // parity: tui/src/routes/session/message-parts.tsx#ReasoningPart [status=adapted hash=4e247eb66643]
    public static func ReasoningPart(
        ctx: any RenderContext,
        part: SessionMessageSchema.AssistantReasoning,
        message: SessionMessageSchema.Assistant,
        thinkingMode: TUIContext.ThinkingMode = .show,
        theme: ResolvedTheme? = nil
    ) -> BoxRenderable {
        let t = defaultTheme(theme)
        let content = reasoningContent(part)
        let summary = TUIContext.reasoningSummary(content)
        let done = part.time?.completed != nil || message.time.completed != nil
        let box = BoxRenderable(ctx: ctx, options: BoxOptions(
            flexShrink: 0,
            flexDirection: .column,
            paddingLeft: .point(3)
        ))
        let header = done
            ? "Thought\(summary.title.map { ": \($0)" } ?? "")"
            : "Thinking\(summary.title.map { ": \($0)" } ?? "")"
        box.add(TextRenderable(ctx: ctx, options: TextOptions(
            content: .string(header),
            fg: .rgba(t.text.feedback.warning.base)
        )))
        if thinkingMode == .show && !content.isEmpty {
            box.add(TextRenderable(ctx: ctx, options: TextOptions(
                content: .string(content),
                fg: .rgba(t.text.muted)
            )))
        }
        return box
    }

    // parity: tui/src/routes/session/message-parts.tsx#TextPart [status=adapted hash=782a9fa5bc2d]
    public static func TextPart(
        ctx: any RenderContext,
        part: SessionMessageSchema.AssistantText,
        theme: ResolvedTheme? = nil
    ) -> BoxRenderable {
        let t = defaultTheme(theme)
        let box = BoxRenderable(ctx: ctx, options: BoxOptions(
            flexShrink: 0,
            flexDirection: .column,
            paddingLeft: .point(3)
        ))
        let trimmed = part.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            box.add(TextRenderable(ctx: ctx, options: TextOptions(
                content: .string(trimmed),
                fg: .rgba(t.markdown.text)
            )))
        }
        return box
    }

    // parity: tui/src/routes/session/message-parts.tsx#InlineToolRow [status=adapted hash=69f54666b5d8]
    public static func InlineToolRow(
        ctx: any RenderContext,
        icon: String,
        label: String,
        complete: Bool = true,
        failed: Bool = false,
        denied: Bool = false,
        error: String? = nil,
        theme: ResolvedTheme? = nil
    ) -> BoxRenderable {
        let t = defaultTheme(theme)
        let color = failed ? t.text.feedback.error.base : t.text.muted
        let attrs = denied ? createTextAttributes(strikethrough: true) : TextAttributes.none
        let row = BoxRenderable(ctx: ctx, options: BoxOptions(
            flexDirection: .column,
            paddingLeft: .point(3)
        ))
        let line = complete || failed ? "\(icon) \(label)" : "⋯ \(label)"
        row.add(TextRenderable(ctx: ctx, options: TextOptions(
            content: .string(line),
            fg: .rgba(color),
            attributes: attrs
        )))
        if failed, let error, !error.isEmpty {
            row.add(TextRenderable(ctx: ctx, options: TextOptions(
                content: .string("  \(error)"),
                fg: .rgba(t.text.feedback.error.base)
            )))
        }
        return row
    }

    // parity: tui/src/routes/session/group-view.tsx#SessionGroupView [status=adapted hash=bd63386bb333]
    public static func SessionGroupView(
        ctx: any RenderContext,
        row: SessionGroup,
        summaryLabel: String? = nil,
        theme: ResolvedTheme? = nil
    ) -> BoxRenderable {
        let t = defaultTheme(theme)
        let box = BoxRenderable(ctx: ctx, options: BoxOptions(
            flexDirection: .column,
            paddingLeft: .point(3)
        ))
        let header = summaryLabel ?? "\(row.kind.rawValue) (\(row.size))"
        box.add(TextRenderable(ctx: ctx, options: TextOptions(
            content: .string(header),
            fg: .rgba(t.text.muted)
        )))
        return box
    }

    // parity: tui/src/routes/session/permission.tsx#SessionQuestion [status=adapted hash=097989b1efaa]
    public static func SessionQuestion(
        ctx: any RenderContext,
        title: String,
        bodyLines: [String],
        options: [(key: String, label: String)],
        selectedKey: String? = nil,
        theme: ResolvedTheme? = nil
    ) -> BoxRenderable {
        let t = defaultTheme(theme)
        let box = BoxRenderable(ctx: ctx, options: BoxOptions(
            id: "session.permission",
            flexDirection: .column,
            paddingX: .point(2),
            paddingY: .point(1),
            gap: .point(1),
            backgroundColor: .rgba(t.background.raised.base),
            borderStyle: .single,
            border: .sides([.left]),
            borderColor: .rgba(t.background.action.primary.focused)
        ))
        box.add(TextRenderable(ctx: ctx, options: TextOptions(
            content: .string("△ \(title)"),
            fg: .rgba(t.text.base)
        )))
        for line in bodyLines {
            box.add(TextRenderable(ctx: ctx, options: TextOptions(
                content: .string(line),
                fg: .rgba(t.text.muted)
            )))
        }
        let activeKey = selectedKey ?? options.first?.key
        let choices = options.map { opt in
            opt.key == activeKey ? "[\(opt.label)]" : opt.label
        }.joined(separator: "  ")
        box.add(TextRenderable(ctx: ctx, options: TextOptions(
            content: .string(choices),
            fg: .rgba(t.text.action.primary.base)
        )))
        return box
    }

    // parity: tui/src/routes/session/permission.tsx#PermissionPrompt [status=adapted hash=ddb58e7c39de]
    public static func PermissionPrompt(
        ctx: any RenderContext,
        request: PermissionSchema.Request,
        theme: ResolvedTheme? = nil
    ) -> BoxRenderable {
        var opts: [(String, String)] = [("once", "Allow once")]
        if let save = request.save, !save.isEmpty {
            opts.append(("always", "Always allow"))
        }
        opts.append(("reject", "Reject"))
        return SessionQuestion(
            ctx: ctx,
            title: permissionSemanticLabel(action: request.action),
            bodyLines: request.resources,
            options: opts,
            theme: theme
        )
    }

    // parity: tui/src/routes/session/form.tsx#FormPrompt [status=adapted hash=a79e55cf760b]
    public static func FormPrompt(
        ctx: any RenderContext,
        form: FormSchema.Info,
        theme: ResolvedTheme? = nil
    ) -> BoxRenderable {
        let lines = form.fields.elements.map { field -> String in
            switch field {
            case .string(let f): return f.title ?? f.key
            case .number(let f): return f.title ?? f.key
            case .integer(let f): return f.title ?? f.key
            case .boolean(let f): return f.title ?? f.key
            case .multiselect(let f): return f.title ?? f.key
            case .external(let f): return f.title ?? f.key
            }
        }
        return SessionQuestion(
            ctx: ctx,
            title: form.title,
            bodyLines: lines,
            options: [("submit", "Submit"), ("cancel", "Cancel")],
            theme: theme
        )
    }

    // parity: tui/src/routes/session/location-missing.tsx#SessionLocationUnavailable [status=adapted hash=6168e661b342]
    public static func SessionLocationUnavailable(
        ctx: any RenderContext,
        directory: String,
        theme: ResolvedTheme? = nil
    ) -> BoxRenderable {
        SessionQuestion(
            ctx: ctx,
            title: "Session location unavailable",
            bodyLines: [truncateMiddle(directory, maxLength: 72), "Choose another directory to continue this session."],
            options: [("move", "Choose directory")],
            theme: theme
        )
    }

    // parity: tui/src/routes/session/location-missing.tsx#SessionLocationMissing [status=adapted hash=3e9fc458d70a]
    public static func SessionLocationMissing(
        ctx: any RenderContext,
        directory: String,
        projectID: String,
        sessionID: String,
        theme: ResolvedTheme? = nil
    ) -> BoxRenderable {
        SessionLocationUnavailable(ctx: ctx, directory: directory, theme: theme)
    }

    // parity: tui/src/routes/session/composer/index.tsx#Composer [status=adapted hash=a7e7c5191123]
    public static func Composer(
        ctx: any RenderContext,
        props: ComposerProps,
        tabs: [ComposerTab] = [],
        theme: ResolvedTheme? = nil
    ) -> BoxRenderable {
        let t = defaultTheme(theme)
        let box = BoxRenderable(ctx: ctx, options: BoxOptions(
            id: "session-composer-\(props.sessionID)",
            flexDirection: .column,
            paddingX: .point(1),
            visible: props.open,
            backgroundColor: .rgba(t.background.raised.base)
        ))
        let header = tabs.map(\.label).joined(separator: "  ")
        if !header.isEmpty {
            box.add(TextRenderable(ctx: ctx, options: TextOptions(
                content: .string(header),
                fg: .rgba(t.text.base),
                attributes: createTextAttributes(bold: true)
            )))
        }
        return box
    }

    // parity: tui/src/routes/session/composer/shell-tab.tsx#ShellTab [status=adapted hash=99d42c6d84be]
    public static func ShellTab(
        ctx: any RenderContext,
        sessionID: String,
        commands: [String] = [],
        theme: ResolvedTheme? = nil
    ) -> BoxRenderable {
        let t = defaultTheme(theme)
        let box = BoxRenderable(ctx: ctx, options: BoxOptions(id: "composer-shell-\(sessionID)", flexDirection: .column))
        for cmd in commands {
            box.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string("$ \(cmd)"), fg: .rgba(t.text.base))))
        }
        return box
    }

    // parity: tui/src/routes/session/composer/subagents-tab.tsx#SubagentsTab [status=adapted hash=82fb4df4148f]
    public static func SubagentsTab(
        ctx: any RenderContext,
        sessionID: String,
        subagents: [String] = [],
        theme: ResolvedTheme? = nil
    ) -> BoxRenderable {
        let t = defaultTheme(theme)
        let box = BoxRenderable(ctx: ctx, options: BoxOptions(id: "composer-subagents-\(sessionID)", flexDirection: .column))
        for sub in subagents {
            box.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string(sub), fg: .rgba(t.text.base))))
        }
        return box
    }

    // parity: tui/src/routes/session/composer/terminals-tab.tsx#TerminalsTab [status=adapted hash=ff3c5756ce86]
    public static func TerminalsTab(
        ctx: any RenderContext,
        sessionID: String,
        visibleTerminalID: String? = nil,
        terminals: [String] = [],
        theme: ResolvedTheme? = nil
    ) -> BoxRenderable {
        let t = defaultTheme(theme)
        let box = BoxRenderable(ctx: ctx, options: BoxOptions(id: "composer-terminals-\(sessionID)", flexDirection: .column))
        for term in terminals {
            let marker = term == visibleTerminalID ? "● " : "○ "
            box.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string("\(marker)\(term)"), fg: .rgba(t.text.base))))
        }
        return box
    }

    // parity: tui/src/routes/session/dialog-execute.tsx#DialogExecute [status=adapted hash=7ae6ca270401]
    public static func DialogExecute(
        ctx: any RenderContext,
        part: SessionMessageSchema.AssistantTool,
        theme: ResolvedTheme? = nil
    ) -> BoxRenderable {
        let t = defaultTheme(theme).surface(.dialog)
        let box = BoxRenderable(ctx: ctx, options: BoxOptions(
            id: "dialog-execute-\(part.id)",
            flexDirection: .column,
            padding: .point(1),
            backgroundColor: .rgba(t.background.base)
        ))
        box.add(TextRenderable(ctx: ctx, options: TextOptions(
            content: .string("Execute · \(part.state.statusTag)"),
            fg: .rgba(t.text.base),
            attributes: createTextAttributes(bold: true)
        )))
        return box
    }

    // parity: tui/src/routes/session/dialog-fork.tsx#DialogFork [status=adapted hash=27265904341b]
    public static func DialogFork(
        ctx: any RenderContext,
        sessionID: String,
        messageID: String? = nil,
        theme: ResolvedTheme? = nil
    ) -> BoxRenderable {
        let t = defaultTheme(theme).surface(.dialog)
        let box = BoxRenderable(ctx: ctx, options: BoxOptions(
            id: "dialog-fork-\(sessionID)",
            flexDirection: .column,
            padding: .point(1),
            backgroundColor: .rgba(t.background.base)
        ))
        box.add(TextRenderable(ctx: ctx, options: TextOptions(
            content: .string(messageID == nil ? "Fork session" : "Fork from \(messageID!)"),
            fg: .rgba(t.text.base)
        )))
        return box
    }

    // parity: tui/src/routes/session/dialog-message.tsx#DialogMessage [status=adapted hash=60b14226dbd3]
    public static func DialogMessage(
        ctx: any RenderContext,
        messageID: String,
        sessionID: String,
        theme: ResolvedTheme? = nil
    ) -> BoxRenderable {
        let t = defaultTheme(theme).surface(.dialog)
        let box = BoxRenderable(ctx: ctx, options: BoxOptions(
            id: "dialog-message-\(messageID)",
            flexDirection: .column,
            padding: .point(1),
            backgroundColor: .rgba(t.background.base)
        ))
        box.add(TextRenderable(ctx: ctx, options: TextOptions(
            content: .string("Message Actions (\(sessionID))"),
            fg: .rgba(t.text.base)
        )))
        return box
    }

    // parity: tui/src/routes/session/dialog-timeline.tsx#DialogTimeline [status=adapted hash=9bc91e36802f]
    public static func DialogTimeline(
        ctx: any RenderContext,
        sessionID: String,
        entries: [String] = [],
        theme: ResolvedTheme? = nil
    ) -> BoxRenderable {
        let t = defaultTheme(theme).surface(.dialog)
        let box = BoxRenderable(ctx: ctx, options: BoxOptions(
            id: "dialog-timeline-\(sessionID)",
            flexDirection: .column,
            padding: .point(1),
            backgroundColor: .rgba(t.background.base)
        ))
        box.add(TextRenderable(ctx: ctx, options: TextOptions(
            content: .string("Timeline"),
            fg: .rgba(t.text.base),
            attributes: createTextAttributes(bold: true)
        )))
        for entry in entries {
            box.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string(entry), fg: .rgba(t.text.muted))))
        }
        return box
    }
}
