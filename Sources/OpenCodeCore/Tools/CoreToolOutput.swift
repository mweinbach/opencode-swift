#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Synchronization
import OpenCodeAI
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

// MARK: - CoreToolOutput (`tool-output.ts`, `tool/html-markdown.ts`, `tool/http-body.ts`, `tool/read-filesystem.ts`, `tool/search.ts`)

public enum CoreToolOutput {
    // parity: core/src/tool-output.ts#MAX_LINES [status=implemented hash=1c5fa06ac334]
    public static let MAX_LINES: Int = 2_000

    // parity: core/src/tool-output.ts#MAX_BYTES [status=implemented hash=963b0fb92666]
    public static let MAX_BYTES: Int = 50 * 1024

    /// 7 days retention in milliseconds.
    // parity: core/src/tool-output.ts#RETENTION [status=implemented hash=0e2a7fe20d74]
    public static let RETENTION: Int64 = 7 * 24 * 60 * 60 * 1_000

    // parity: core/src/tool-output.ts#DIRECTORY [status=implemented hash=791b2ebd1e87]
    public static let DIRECTORY: String = "tool-output"

    // parity: core/src/tool-output.ts#fileName [status=implemented hash=b31a25104b78]
    public static func fileName(timestamp: Int64? = nil) -> String {
        "tool_" + Identifier.create(descending: false, timestamp: timestamp)
    }

    public struct Limits: Equatable, Hashable, Sendable, Codable {
        public var maxLines: Int
        public var maxBytes: Int

        public init(maxLines: Int = CoreToolOutput.MAX_LINES, maxBytes: Int = CoreToolOutput.MAX_BYTES) {
            self.maxLines = maxLines
            self.maxBytes = maxBytes
        }
    }

    // parity: core/src/tool-output.ts#Editor [status=adapted hash=b5d7c466a43a]
    public final class Editor: @unchecked Sendable {
        public private(set) var limits: Limits

        public init(limits: Limits = Limits()) {
            self.limits = limits
        }

        public func configure(maxLines: Int? = nil, maxBytes: Int? = nil) {
            if let maxLines { limits.maxLines = maxLines }
            if let maxBytes { limits.maxBytes = maxBytes }
        }
    }

    public struct NormalizedResult: Equatable, Hashable, Sendable, Codable {
        public let output: JSONValue?
        public let content: [ToolSchema.Content]
        public let metadata: ToolSchema.Metadata?

        public init(
            output: JSONValue? = nil,
            content: [ToolSchema.Content],
            metadata: ToolSchema.Metadata? = nil
        ) {
            self.output = output
            self.content = content
            self.metadata = metadata
        }
    }

    // parity: core/src/tool-output.ts#Interface [status=adapted hash=b6106be6fbf8]
    public protocol Interface: Sendable {
        func transform(_ fn: @escaping @Sendable (Editor) -> Void) async -> CoreFilesystem.LocationWatcherPolicy.Registration
        func reload() async
        func truncate(_ result: NormalizedResult) async -> NormalizedResult
        func save(_ bytes: [UInt8], extension ext: String) async throws -> String
        func cleanup() async
    }

    // parity: core/src/tool-output.ts#Service [status=adapted hash=8a206892538c]
    public final class Service: Interface, Sendable {
        public static let serviceKey = "@opencode/ToolOutput"

        private struct State: Sendable {
            var limits = Limits()
            var transforms: [UInt64: @Sendable (Editor) -> Void] = [:]
            var order: [UInt64] = []
            var nextID: UInt64 = 1
        }

        private let directory: String
        private let fileSystem: any OpenCodeFileSystem
        private let nowMs: @Sendable () -> Int64
        private let state = Mutex(State())

        public init(
            globalPaths: Global.Interface = Global.make(),
            fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
            limits: Limits = Limits(),
            nowMs: @escaping @Sendable () -> Int64 = { Flock.currentEpochMs() }
        ) {
            self.directory = CoreConfigDiscovery.joinPath(globalPaths.data, CoreToolOutput.DIRECTORY)
            self.fileSystem = fileSystem
            self.nowMs = nowMs
            self.state.withLock { $0.limits = limits }
        }

        public func transform(
            _ fn: @escaping @Sendable (Editor) -> Void
        ) async -> CoreFilesystem.LocationWatcherPolicy.Registration {
            let id = state.withLock { s -> UInt64 in
                let id = s.nextID
                s.nextID &+= 1
                s.transforms[id] = fn
                s.order.append(id)
                return id
            }
            await reload()
            return CoreFilesystem.LocationWatcherPolicy.Registration { [weak self] in
                self?.state.withLock { s in
                    _ = s.transforms.removeValue(forKey: id)
                    s.order.removeAll { $0 == id }
                }
            }
        }

        public func reload() async {
            state.withLock { s in
                let editor = Editor()
                for id in s.order { s.transforms[id]?(editor) }
                s.limits = editor.limits
            }
        }

        public func truncate(_ result: NormalizedResult) async -> NormalizedResult {
            if result.metadata?["truncated"] != nil { return result }

            var joined = ""
            for item in result.content {
                guard case .text(let tc) = item else { continue }
                if joined.isEmpty || joined.hasSuffix("\n") {
                    joined += tc.text
                } else {
                    joined += "\n" + tc.text
                }
            }

            let limits = state.withLock { $0.limits }
            let totalLines = Self.countLines(joined)
            if totalLines <= limits.maxLines && joined.utf8.count <= limits.maxBytes {
                var meta = result.metadata ?? [:]
                meta["truncated"] = .bool(false)
                return NormalizedResult(output: result.output, content: result.content, metadata: meta)
            }

            let lineCut = Self.afterLines(joined, count: limits.maxLines)
            let byteCut = Self.byteBoundary(joined, budget: limits.maxBytes)
            let cutIdx = lineCut < byteCut ? lineCut : byteCut

            let rawShown = String(joined[..<cutIdx])
            let shown: String
            if rawShown.hasSuffix("\r\n") {
                shown = String(rawShown.dropLast(2))
            } else if rawShown.hasSuffix("\n") {
                shown = String(rawShown.dropLast(1))
            } else {
                shown = rawShown
            }

            let file = CoreConfigDiscovery.joinPath(directory, CoreToolOutput.fileName())
            var saveError: String? = nil
            do {
                try await fileSystem.makeDirectory(at: directory, recursive: true)
                try await fileSystem.writeFile(Array(joined.utf8), to: file, createDirectories: true)
            } catch {
                saveError = String(describing: error).split(separator: "\n").first.map(String.init) ?? String(describing: error)
            }

            let shownLines = Self.countLines(rawShown)
            let rest = joined[shown.endIndex...]
            let lastLineCut = shownLines > 0 && !rest.isEmpty && !rest.hasPrefix("\n") && !rest.hasPrefix("\r\n")
            let rangeLabel = shownLines == 0 ? "0 lines" : "lines 1-\(shownLines)"
            let suffix = saveError == nil
                ? "full output saved to \(file)"
                : "full output could not be saved: \(saveError!)"
            let marker = "[showing \(rangeLabel) of \(totalLines)\(lastLineCut ? " (last line cut)" : ""); \(suffix)]"

            var bounded: [ToolSchema.Content] = []
            var remaining = shown.utf16.count
            var needsSep = false
            var marked = false
            for item in result.content {
                switch item {
                case .file:
                    bounded.append(item)
                case .text(let tc):
                    if needsSep && remaining > 0 { remaining -= 1 }
                    needsSep = !tc.text.isEmpty && !tc.text.hasSuffix("\n")
                    let itemLen = tc.text.utf16.count
                    if !marked && remaining >= itemLen {
                        bounded.append(item)
                        remaining -= itemLen
                    } else {
                        if remaining > 0 {
                            let prefixText = TextBoundary.head(tc.text, limit: remaining)
                            bounded.append(.text(ToolSchema.TextContent(text: prefixText)))
                        }
                        if !marked {
                            bounded.append(.text(ToolSchema.TextContent(text: marker)))
                        }
                        remaining = 0
                        marked = true
                    }
                }
            }
            if !marked {
                bounded.append(.text(ToolSchema.TextContent(text: marker)))
            }

            var meta = result.metadata ?? [:]
            meta["truncated"] = .bool(true)
            if saveError == nil {
                meta["outputPath"] = .string(file)
            }
            return NormalizedResult(output: result.output, content: bounded, metadata: meta)
        }

        public func save(_ bytes: [UInt8], extension ext: String) async throws -> String {
            let file = CoreConfigDiscovery.joinPath(directory, CoreToolOutput.fileName() + ext)
            try await fileSystem.writeFile(bytes, to: file, createDirectories: true)
            return file
        }

        public func cleanup() async {
            guard let names = try? await fileSystem.readDirectory(at: directory) else { return }
            let targets = names
                .filter { $0.hasPrefix("tool_") }
                .map { CoreConfigDiscovery.joinPath(directory, $0) }
            await CoreFilesystem.FileRetention.cleanup(
                fileSystem: fileSystem,
                files: targets,
                retentionMs: CoreToolOutput.RETENTION,
                nowMs: nowMs()
            )
        }

        private static func countLines(_ text: String) -> Int {
            if text.isEmpty { return 0 }
            let bytes = Array(text.utf8)
            var count = 1
            for i in 0..<(bytes.count - 1) where bytes[i] == 0x0A {
                count += 1
            }
            return count
        }

        private static func afterLines(_ text: String, count: Int) -> String.Index {
            var idx = text.startIndex
            var lines = 0
            while lines < count && idx < text.endIndex {
                if let nl = text[idx...].firstIndex(of: "\n") {
                    idx = text.index(after: nl)
                    lines += 1
                } else {
                    return text.endIndex
                }
            }
            return idx
        }

        /// Longest prefix of `text` fitting within `budget` UTF-8 bytes without splitting a grapheme cluster.
        private static func byteBoundary(_ text: String, budget: Int) -> String.Index {
            guard budget > 0 else { return text.startIndex }
            var used = 0
            var idx = text.startIndex
            while idx < text.endIndex {
                let next = text.index(after: idx)
                let chBytes = text[idx..<next].utf8.count
                if used + chBytes > budget { break }
                used += chBytes
                idx = next
            }
            return idx
        }
    }

    // parity: core/src/tool-output.ts#node [status=adapted hash=0075e8c51dfe]
    public static let node: LayerNode.Provider = AppNode.makeLocationNode(
        Service.serviceKey,
        LayerNode.ExecutableLayer { deps, _ in
            let global = deps.get(Global.Service.serviceKey, as: Global.Service.self)?.paths ?? Global.make()
            let fsUtil = deps.get(FSUtil.Service.serviceKey, as: FSUtil.Service.self)
            let svc = Service(globalPaths: global, fileSystem: fsUtil?.fileSystem ?? LocalFileSystem.shared)
            return LayerNode.Output([Service.serviceKey: svc as any Interface])
        },
        [FSUtil.node, Global.node]
    )

    // MARK: - HTML to Markdown Converter (`core/src/tool/html-markdown.ts`)

    public enum HTMLMarkdown {
        // parity: core/src/tool/html-markdown.ts#MAX_MARKDOWN_BYTES [status=implemented hash=ed2ec21c08ef]
        public static let MAX_MARKDOWN_BYTES: Int = 5 * 1024 * 1024

        private static let omittedTags: Set<String> = [
            "script", "style", "noscript", "iframe", "object", "embed", "meta", "link", "template", "head",
        ]
        private static let blockTags: Set<String> = [
            "address", "article", "aside", "details", "dialog", "div", "dl", "fieldset",
            "figcaption", "figure", "footer", "form", "header", "main", "nav", "p", "section", "summary",
        ]

        /// Converts HTML into clean Markdown (stripping scripts/styles, rendering headings, links, images,
        /// code blocks, lists, quotes, and tables, bounded to `MAX_MARKDOWN_BYTES`).
        // parity: core/src/tool/html-markdown.ts#convertHTMLToMarkdown [status=implemented hash=44b23bbffe82]
        public static func convertHTMLToMarkdown(_ html: String) -> String {
            var out = ""
            var skipDepth = 0
            var inPre = false
            var inCode = false
            var codeBuffer = ""
            var codeLang = ""
            var linkHref: String? = nil
            var linkText = ""
            var listStack: [(ordered: Bool, index: Int)] = []
            var quoteDepth = 0

            let chars = Array(html)
            var i = 0

            func appendBlockBreak() {
                if !out.isEmpty && !out.hasSuffix("\n\n") {
                    out += out.hasSuffix("\n") ? "\n" : "\n\n"
                }
            }

            func quotePrefix() -> String {
                quoteDepth > 0 ? String(repeating: "> ", count: min(8, quoteDepth)) : ""
            }

            func appendText(_ raw: String) {
                let decoded = decodeHTMLEntities(raw)
                if inPre || inCode {
                    codeBuffer += decoded
                    return
                }
                if linkHref != nil {
                    linkText += collapseWhitespace(decoded)
                    return
                }
                let collapsed = collapseWhitespace(decoded)
                if collapsed.isEmpty { return }
                if collapsed == " " && (out.isEmpty || out.hasSuffix(" ") || out.hasSuffix("\n")) { return }
                if out.hasSuffix("\n") || out.isEmpty {
                    let trimmed = collapsed.drop(while: { $0 == " " })
                    if trimmed.isEmpty { return }
                    out += quotePrefix() + trimmed
                } else {
                    out += collapsed
                }
            }

            while i < chars.count && out.utf8.count < MAX_MARKDOWN_BYTES {
                if chars[i] == "<" {
                    // Comment <!-- ... -->
                    if i + 3 < chars.count && chars[i + 1] == "!" && chars[i + 2] == "-" && chars[i + 3] == "-" {
                        i += 4
                        while i + 2 < chars.count && !(chars[i] == "-" && chars[i + 1] == "-" && chars[i + 2] == ">") {
                            i += 1
                        }
                        i = min(chars.count, i + 3)
                        continue
                    }
                    // Find closing '>'
                    var end = i + 1
                    var quote: Character? = nil
                    while end < chars.count {
                        let c = chars[end]
                        if let q = quote {
                            if c == q { quote = nil }
                        } else if c == "\"" || c == "'" {
                            quote = c
                        } else if c == ">" {
                            break
                        }
                        end += 1
                    }
                    if end >= chars.count {
                        appendText(String(chars[i...]))
                        break
                    }
                    let tagBody = String(chars[(i + 1)..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                    i = end + 1

                    let isClosing = tagBody.hasPrefix("/")
                    let isSelfClosing = tagBody.hasSuffix("/")
                    let cleaned = tagBody
                        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let nameEnd = cleaned.firstIndex(where: { $0.isWhitespace }) ?? cleaned.endIndex
                    let tagName = String(cleaned[..<nameEnd]).lowercased()
                    let attrsStr = nameEnd < cleaned.endIndex ? String(cleaned[nameEnd...]) : ""
                    let attrs = parseHTMLAttributes(attrsStr)

                    if isClosing {
                        if skipDepth > 0 {
                            if omittedTags.contains(tagName) { skipDepth -= 1 }
                            continue
                        }
                        switch tagName {
                        case "pre":
                            inPre = false
                            appendBlockBreak()
                            out += "```\(codeLang)\n\(codeBuffer)\(codeBuffer.hasSuffix("\n") ? "" : "\n")```\n\n"
                            codeBuffer = ""
                            codeLang = ""
                        case "code":
                            if !inPre && inCode {
                                inCode = false
                                let snippet = "`\(codeBuffer)`"
                                if linkHref != nil { linkText += snippet } else { out += snippet }
                                codeBuffer = ""
                            }
                        case "strong", "b":
                            if linkHref != nil { linkText += "**" } else { out += "**" }
                        case "em", "i":
                            if linkHref != nil { linkText += "*" } else { out += "*" }
                        case "s", "strike", "del":
                            if linkHref != nil { linkText += "~~" } else { out += "~~" }
                        case "a":
                            if let href = linkHref {
                                let label = linkText.trimmingCharacters(in: .whitespacesAndNewlines)
                                out += "[\(label)](\(href))"
                                linkHref = nil
                                linkText = ""
                            }
                        case "blockquote":
                            quoteDepth = max(0, quoteDepth - 1)
                            appendBlockBreak()
                        case "ul", "ol":
                            if !listStack.isEmpty { listStack.removeLast() }
                            appendBlockBreak()
                        case "li":
                            if !out.hasSuffix("\n") { out += "\n" }
                        case "h1", "h2", "h3", "h4", "h5", "h6":
                            appendBlockBreak()
                        case "tr":
                            if !out.hasSuffix("\n") { out += " |\n" }
                        case "table":
                            appendBlockBreak()
                        default:
                            if blockTags.contains(tagName) { appendBlockBreak() }
                        }
                        continue
                    }

                    // Opening tag
                    if skipDepth > 0 || omittedTags.contains(tagName) {
                        if !isSelfClosing && omittedTags.contains(tagName) { skipDepth += 1 }
                        continue
                    }

                    switch tagName {
                    case "h1", "h2", "h3", "h4", "h5", "h6":
                        appendBlockBreak()
                        let level = Int(String(tagName.dropFirst())) ?? 1
                        out += quotePrefix() + String(repeating: "#", count: level) + " "
                    case "br":
                        if inPre { codeBuffer += "\n" } else { out += "  \n" }
                    case "hr":
                        appendBlockBreak()
                        out += "---\n\n"
                    case "pre":
                        inPre = true
                        codeBuffer = ""
                        codeLang = ""
                    case "code":
                        if inPre {
                            if let cls = attrs["class"], let range = cls.range(of: "language-") {
                                codeLang = String(cls[range.upperBound...].prefix(while: { !$0.isWhitespace }))
                            }
                        } else {
                            inCode = true
                            codeBuffer = ""
                        }
                    case "strong", "b":
                        if linkHref != nil { linkText += "**" } else { out += "**" }
                    case "em", "i":
                        if linkHref != nil { linkText += "*" } else { out += "*" }
                    case "s", "strike", "del":
                        if linkHref != nil { linkText += "~~" } else { out += "~~" }
                    case "a":
                        linkHref = attrs["href"] ?? ""
                        linkText = ""
                    case "img":
                        let alt = attrs["alt"] ?? ""
                        let src = attrs["src"] ?? ""
                        out += "![\(alt)](\(src))"
                    case "blockquote":
                        appendBlockBreak()
                        quoteDepth += 1
                    case "ul":
                        appendBlockBreak()
                        listStack.append((ordered: false, index: 1))
                    case "ol":
                        appendBlockBreak()
                        let start = attrs["start"].flatMap(Int.init) ?? 1
                        listStack.append((ordered: true, index: start))
                    case "li":
                        if !out.isEmpty && !out.hasSuffix("\n") { out += "\n" }
                        let indent = String(repeating: "  ", count: max(0, listStack.count - 1))
                        if !listStack.isEmpty {
                            let lastIdx = listStack.count - 1
                            if listStack[lastIdx].ordered {
                                let num = listStack[lastIdx].index
                                listStack[lastIdx].index += 1
                                out += "\(quotePrefix())\(indent)\(num). "
                            } else {
                                out += "\(quotePrefix())\(indent)- "
                            }
                        } else {
                            out += "\(quotePrefix())- "
                        }
                    case "th", "td":
                        out += "| "
                    case "tr":
                        if !out.isEmpty && !out.hasSuffix("\n") { out += "\n" }
                    default:
                        if blockTags.contains(tagName) { appendBlockBreak() }
                    }
                } else {
                    var end = i
                    while end < chars.count && chars[end] != "<" { end += 1 }
                    if skipDepth == 0 {
                        appendText(String(chars[i..<end]))
                    }
                    i = end
                }
            }

            let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.utf8.count <= MAX_MARKDOWN_BYTES { return trimmed }
            return String(decoding: Array(trimmed.utf8.prefix(MAX_MARKDOWN_BYTES)), as: UTF8.self)
        }

        private static func collapseWhitespace(_ s: String) -> String {
            var out = ""
            var lastWasSpace = false
            for c in s {
                if c.isWhitespace {
                    if !lastWasSpace {
                        out.append(" ")
                        lastWasSpace = true
                    }
                } else {
                    out.append(c)
                    lastWasSpace = false
                }
            }
            return out
        }

        internal static func decodeHTMLEntities(_ s: String) -> String {
            s.replacing("&amp;", with: "&")
                .replacing("&lt;", with: "<")
                .replacing("&gt;", with: ">")
                .replacing("&quot;", with: "\"")
                .replacing("&#39;", with: "'")
                .replacing("&apos;", with: "'")
                .replacing("&nbsp;", with: " ")
        }

        private static func parseHTMLAttributes(_ str: String) -> [String: String] {
            var attrs: [String: String] = [:]
            let chars = Array(str)
            var i = 0
            while i < chars.count {
                while i < chars.count && chars[i].isWhitespace { i += 1 }
                let keyStart = i
                while i < chars.count && !chars[i].isWhitespace && chars[i] != "=" { i += 1 }
                guard i > keyStart else { i += 1; continue }
                let key = String(chars[keyStart..<i]).lowercased()
                while i < chars.count && chars[i].isWhitespace { i += 1 }
                guard i < chars.count && chars[i] == "=" else {
                    attrs[key] = ""
                    continue
                }
                i += 1
                while i < chars.count && chars[i].isWhitespace { i += 1 }
                guard i < chars.count else { break }
                let val: String
                if chars[i] == "\"" || chars[i] == "'" {
                    let q = chars[i]
                    i += 1
                    let valStart = i
                    while i < chars.count && chars[i] != q { i += 1 }
                    val = String(chars[valStart..<i])
                    if i < chars.count { i += 1 }
                } else {
                    let valStart = i
                    while i < chars.count && !chars[i].isWhitespace { i += 1 }
                    val = String(chars[valStart..<i])
                }
                attrs[key] = decodeHTMLEntities(val)
            }
            return attrs
        }
    }

    // MARK: - Bounded HTTP Body Collector (`core/src/tool/http-body.ts`)

    public enum HTTPBody {
        /// Collects an HTTP response body while enforcing a hard `maximumBytes` ceiling.
        // parity: core/src/tool/http-body.ts#collectBoundedResponseBody [status=implemented hash=16e4bcb3fdea]
        public static func collectBoundedResponseBody(
            headers: [String: String],
            chunks: AsyncThrowingStream<[UInt8], Swift.Error>,
            maximumBytes: Int,
            tooLarge: @Sendable () -> any Swift.Error
        ) async throws -> [UInt8] {
            if let lenHeader = headers.first(where: { $0.key.lowercased() == "content-length" })?.value,
               let declared = Int(lenHeader.trimmingCharacters(in: .whitespaces)),
               declared > maximumBytes
            {
                throw tooLarge()
            }
            var body: [UInt8] = []
            for try await chunk in chunks {
                if chunk.isEmpty { continue }
                if body.count + chunk.count > maximumBytes {
                    throw tooLarge()
                }
                body.append(contentsOf: chunk)
            }
            return body
        }

        public static func collectBoundedResponseBody(
            response: HTTPResponse,
            maximumBytes: Int,
            tooLarge: @Sendable () -> any Swift.Error
        ) throws -> [UInt8] {
            if let lenHeader = response.head.headers.first(where: { $0.key.lowercased() == "content-length" })?.value,
               let declared = Int(lenHeader.trimmingCharacters(in: .whitespaces)),
               declared > maximumBytes
            {
                throw tooLarge()
            }
            if response.body.count > maximumBytes {
                throw tooLarge()
            }
            return response.body
        }
    }

    // MARK: - ReadToolFileSystem (`core/src/tool/read-filesystem.ts`)

    public enum ReadFilesystem {
        // parity: core/src/tool/read-filesystem.ts#MAX_READ_LINES [status=implemented hash=eb8cb088d849]
        public static let MAX_READ_LINES: Int = 2_000

        // parity: core/src/tool/read-filesystem.ts#MAX_READ_BYTES [status=implemented hash=4705854aabb8]
        public static let MAX_READ_BYTES: Int = 50 * 1024

        // parity: core/src/tool/read-filesystem.ts#MAX_MEDIA_INGEST_BYTES [status=implemented hash=2dc39d0035f3]
        public static let MAX_MEDIA_INGEST_BYTES: Int = 20 * 1024 * 1024

        // parity: core/src/tool/read-filesystem.ts#MEDIA_MIMES [status=implemented hash=fa03c9ee6fbc]
        public static let MEDIA_MIMES: Set<String> = [
            "image/png", "image/jpeg", "image/gif", "image/webp", "application/pdf",
        ]

        private static let tailLines = 100
        private static let maxLineLength = 2_000
        private static let maxLineSuffix = "... (line truncated to \(maxLineLength) chars)"

        // parity: core/src/tool/read-filesystem.ts#BinaryFileError [status=implemented hash=99c59d9be13e]
        public struct BinaryFileError: Swift.Error, Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
            public static let tag = "ReadTool.BinaryFileError"
            public let resource: String
            public init(resource: String) { self.resource = resource }
            // parity: core/src/tool/read-filesystem.ts#BinaryFileError.message [status=implemented hash=e0d1a71aa1e3]
            public var message: String { "Cannot read binary file: \(resource)" }
            public var description: String { message }
        }

        // parity: core/src/tool/read-filesystem.ts#MediaIngestLimitError [status=implemented hash=205bbd9915d7]
        public struct MediaIngestLimitError: Swift.Error, Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
            public static let tag = "ReadTool.MediaIngestLimitError"
            public let resource: String
            public let maximumBytes: Int
            public init(resource: String, maximumBytes: Int) {
                self.resource = resource
                self.maximumBytes = maximumBytes
            }
            // parity: core/src/tool/read-filesystem.ts#MediaIngestLimitError.message [status=implemented hash=384923168980]
            public var message: String { "Media exceeds \(maximumBytes) byte ingestion limit: \(resource)" }
            public var description: String { message }
        }

        // parity: core/src/tool/read-filesystem.ts#PathKindError [status=implemented hash=86b84bd26894]
        public struct PathKindError: Swift.Error, Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
            public enum Expected: String, Equatable, Hashable, Sendable, Codable {
                case file = "a file"
                case fileOrDirectory = "a file or directory"
            }

            public static let tag = "ReadTool.PathKindError"
            public let resource: String
            public let expected: Expected
            public init(resource: String, expected: Expected) {
                self.resource = resource
                self.expected = expected
            }
            // parity: core/src/tool/read-filesystem.ts#PathKindError.message [status=implemented hash=8c3f7feace48]
            public var message: String { "Path is not \(expected.rawValue): \(resource)" }
            public var description: String { message }
        }

        // parity: core/src/tool/read-filesystem.ts#DirectoryOffsetError [status=implemented hash=e5272e6b261e]
        public struct DirectoryOffsetError: Swift.Error, Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
            public static let tag = "ReadTool.DirectoryOffsetError"
            public let resource: String
            public init(resource: String) { self.resource = resource }
            // parity: core/src/tool/read-filesystem.ts#DirectoryOffsetError.message [status=implemented hash=c8510c160d06]
            public var message: String { "A negative offset only works for files, and \(resource) is a directory" }
            public var description: String { message }
        }

        // parity: core/src/tool/read-filesystem.ts#ReadError [status=implemented hash=6819c24e3250]
        public enum ReadError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
            case notFound(String)
            case failed(String)
            case binaryFile(BinaryFileError)
            case mediaIngestLimit(MediaIngestLimitError)
            case pathKind(PathKindError)
            case directoryOffset(DirectoryOffsetError)

            public var description: String {
                switch self {
                case .notFound(let p): return "File not found: \(p)"
                case .failed(let m): return m
                case .binaryFile(let e): return e.message
                case .mediaIngestLimit(let e): return e.message
                case .pathKind(let e): return e.message
                case .directoryOffset(let e): return e.message
                }
            }
        }

        // parity: core/src/tool/read-filesystem.ts#PageInput [status=implemented hash=1ba10181b3fd]
        public struct PageInput: Equatable, Hashable, Sendable, Codable {
            public let offset: Int?
            public let limit: Int?

            public init(offset: Int? = nil, limit: Int? = nil) {
                self.offset = offset
                self.limit = limit
            }
        }

        // parity: core/src/tool/read-filesystem.ts#TextContent [status=implemented hash=9b0803d1ffcf]
        public struct TextContent: Equatable, Hashable, Sendable, Codable {
            public let content: String
            public let offset: Int
            public let lineCount: Int
            public let next: Int?

            public init(content: String, offset: Int, lineCount: Int, next: Int? = nil) {
                self.content = content
                self.offset = offset
                self.lineCount = lineCount
                self.next = next
            }
        }

        // parity: core/src/tool/read-filesystem.ts#DirectoryContent [status=implemented hash=943d847c7b0d]
        public struct DirectoryContent: Equatable, Hashable, Sendable, Codable {
            public let entries: [String]
            public let next: Int?

            public init(entries: [String], next: Int? = nil) {
                self.entries = entries
                self.next = next
            }
        }

        // parity: core/src/tool/read-filesystem.ts#MediaContent [status=implemented hash=246c93cac229]
        public struct MediaContent: Equatable, Hashable, Sendable, Codable {
            public let uri: String
            public let mime: String
            public let name: String?

            public init(uri: String, mime: String, name: String? = nil) {
                self.uri = uri
                self.mime = mime
                self.name = name
            }
        }

        // parity: core/src/tool/read-filesystem.ts#Media [status=implemented hash=3b42294f8058]
        public struct Media: Equatable, Sendable {
            public let uri: String
            public let mime: String
            public let name: String
            public let bytes: [UInt8]

            public init(uri: String, mime: String, name: String, bytes: [UInt8]) {
                self.uri = uri
                self.mime = mime
                self.name = name
                self.bytes = bytes
            }

            public var content: MediaContent {
                MediaContent(uri: uri, mime: mime, name: name)
            }
        }

        // parity: core/src/tool/read-filesystem.ts#Output [status=implemented hash=9c696ecd30b8]
        public enum Output: Equatable, Sendable {
            case text(TextContent)
            case directory(DirectoryContent)
            case media(Media)
        }

        public struct DirEntry: Equatable, Hashable, Sendable {
            public let name: String
            public let type: FileEntryType

            public init(name: String, type: FileEntryType) {
                self.name = name
                self.type = type
            }
        }

        /// Reads a file (text with pagination/clamping, or inline media) or directory listing.
        // parity: core/src/tool/read-filesystem.ts#read [status=implemented hash=eae022a720d4]
        public static func read(
            fileSystem: any OpenCodeFileSystem,
            path: SchemaPrimitive.AbsolutePath,
            resource: String,
            page: PageInput = PageInput()
        ) async throws -> Output {
            let st: FileStat
            do {
                st = try await fileSystem.stat(at: path.rawValue)
            } catch PlatformError.notFound {
                throw ReadError.notFound(resource)
            } catch {
                throw ReadError.failed(String(describing: error))
            }

            if st.type == .directory {
                if let off = page.offset, off < 0 {
                    throw DirectoryOffsetError(resource: resource)
                }
                let names = (try? await fileSystem.readDirectory(at: path.rawValue)) ?? []
                var entries: [(name: String, isDir: Bool)] = []
                for name in names {
                    let abs = CoreConfigDiscovery.joinPath(path.rawValue, name)
                    let childType = (try? await fileSystem.stat(at: abs).type) ?? .other
                    if childType == .other { continue }
                    let isDir = childType == .directory
                    entries.append((name: name + (isDir ? "/" : ""), isDir: isDir))
                }
                entries.sort { lhs, rhs in
                    if lhs.isDir != rhs.isDir { return lhs.isDir }
                    return lhs.name < rhs.name
                }
                let offset = max(1, page.offset ?? 1)
                let limit = min(page.limit ?? MAX_READ_LINES, MAX_READ_LINES)
                let startIdx = min(entries.count, offset - 1)
                let endIdx = min(entries.count, startIdx + limit)
                let selected = Array(entries[startIdx..<endIdx]).map(\.name)
                let next: Int? = endIdx < entries.count ? (offset + selected.count) : nil
                return .directory(DirectoryContent(entries: selected, next: next))
            }

            guard st.type == .file else {
                throw PathKindError(resource: resource, expected: .fileOrDirectory)
            }

            let bytes: [UInt8]
            do {
                bytes = try await fileSystem.readFile(at: path.rawValue)
            } catch PlatformError.notFound {
                throw ReadError.notFound(resource)
            } catch {
                throw ReadError.failed(String(describing: error))
            }

            if let mediaMime = CoreFilesystem.Mime.detectMedia(bytes), MEDIA_MIMES.contains(mediaMime) {
                if bytes.count > MAX_MEDIA_INGEST_BYTES {
                    throw MediaIngestLimitError(resource: resource, maximumBytes: MAX_MEDIA_INGEST_BYTES)
                }
                let isVirtual = resource.hasPrefix("skill://")
                let uri = isVirtual ? resource : "file://\(encodeFilePath(path.rawValue))"
                return .media(Media(
                    uri: uri,
                    mime: mediaMime,
                    name: CoreConfigDiscovery.basename(path.rawValue),
                    bytes: bytes
                ))
            }

            if bytes.contains(0) {
                throw BinaryFileError(resource: resource)
            }

            let decoded = Bom.decodeBytes(bytes).text
            let rawLines = decoded.split(separator: "\n", omittingEmptySubsequences: false).map { sub -> String in
                let s = String(sub)
                return s.hasSuffix("\r") ? String(s.dropLast()) : s
            }
            let totalLines: [String]
            if decoded.isEmpty {
                totalLines = []
            } else if rawLines.last == "" {
                totalLines = Array(rawLines.dropLast())
            } else {
                totalLines = rawLines
            }

            let paged = bytes.count > MAX_READ_BYTES || page.offset != nil || page.limit != nil
            if !paged && totalLines.count <= MAX_READ_LINES {
                let clamped = totalLines.map(clampLine)
                let body = decoded.hasSuffix("\n") ? clamped.joined(separator: "\n") + "\n" : clamped.joined(separator: "\n")
                if body.utf8.count <= MAX_READ_BYTES {
                    return .text(TextContent(content: body, offset: 1, lineCount: totalLines.count, next: nil))
                }
            }

            let requested = (page.offset == nil || page.offset == 0) ? 1 : page.offset!
            let limit = min((page.limit == nil || page.limit == 0) ? MAX_READ_LINES : page.limit!, MAX_READ_LINES)

            var from: Int
            var isTail = false
            if requested < 0 {
                from = max(1, totalLines.count + 1 + requested)
            } else if requested > totalLines.count {
                isTail = true
                let tailCount = min((page.limit == nil || page.limit == 0) ? tailLines : page.limit!, tailLines)
                from = max(1, totalLines.count + 1 - tailCount)
            } else {
                from = requested
            }

            var selected: [String] = []
            var usedBytes = 0
            var next: Int? = nil

            if from <= totalLines.count {
                for lineNum in from...totalLines.count {
                    if !isTail && selected.count >= limit {
                        next = lineNum
                        break
                    }
                    let line = clampLine(totalLines[lineNum - 1])
                    let cost = line.utf8.count + (selected.isEmpty ? 0 : 1)
                    if !isTail && usedBytes + cost > MAX_READ_BYTES {
                        next = lineNum
                        break
                    }
                    selected.append(line)
                    usedBytes += cost
                }
            }

            if isTail {
                while usedBytes > MAX_READ_BYTES && !selected.isEmpty {
                    let removed = selected.removeFirst()
                    usedBytes -= removed.utf8.count + 1
                    from += 1
                }
            }

            return .text(TextContent(
                content: selected.joined(separator: "\n"),
                offset: from,
                lineCount: selected.count,
                next: next
            ))
        }

        private static func clampLine(_ line: String) -> String {
            if line.utf16.count <= maxLineLength { return line }
            return TextBoundary.head(line, limit: maxLineLength) + maxLineSuffix
        }
    }

    // MARK: - Search Helpers (`core/src/tool/search.ts`)

    public enum Search {
        public struct BoundedResult<T: Sendable>: Sendable {
            public let items: [T]
            public let truncated: Bool

            public init(items: [T], truncated: Bool) {
                self.items = items
                self.truncated = truncated
            }
        }

        // parity: core/src/tool/search.ts#pathType [status=implemented hash=3ae86a02146e]
        public static func pathType(
            fileSystem: any OpenCodeFileSystem,
            absolute: String,
            display: String
        ) async throws -> FileEntryType {
            do {
                return try await fileSystem.stat(at: absolute).type
            } catch PlatformError.notFound {
                throw AISchema.ToolFailure(message: "Search path does not exist: \(display)")
            } catch {
                throw AISchema.ToolFailure(message: "Unable to inspect search path \(display): \(error)")
            }
        }

        /// Fetches `limit + 1` results to determine truncation without a second search pass.
        // parity: core/src/tool/search.ts#bounded [status=implemented hash=69f544b15436]
        public static func bounded<T: Sendable>(
            limit: Int,
            search: @Sendable (Int) async throws -> [T]
        ) async throws -> BoundedResult<T> {
            let items = try await search(limit + 1)
            return BoundedResult(
                items: Array(items.prefix(limit)),
                truncated: items.count > limit
            )
        }
    }
}
