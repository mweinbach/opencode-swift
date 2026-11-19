#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import OpenCodeAI
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

// MARK: - Built-In Core Tools Part B (webfetch, websearch, todo, question, subagent, skill, artifact, automation, image-generate, mcp-events, mcp-resource, opencode)

extension CoreTool {

    // MARK: - WebFetchTool (`core/src/tool/plugin/webfetch.ts`)

    public enum WebFetchTool {
        // parity: core/src/tool/plugin/webfetch.ts#name [status=implemented hash=fb26aab7c546]
        public static let name: String = "webfetch"

        // parity: core/src/tool/plugin/webfetch.ts#MAX_RESPONSE_BYTES [status=implemented hash=a93241183636]
        public static let MAX_RESPONSE_BYTES: Int = CoreToolOutput.HTMLMarkdown.MAX_MARKDOWN_BYTES

        // parity: core/src/tool/plugin/webfetch.ts#DEFAULT_TIMEOUT_SECONDS [status=implemented hash=7ed6a563651f]
        public static let DEFAULT_TIMEOUT_SECONDS: Int = 30

        // parity: core/src/tool/plugin/webfetch.ts#MAX_TIMEOUT_SECONDS [status=implemented hash=ac897217dd67]
        public static let MAX_TIMEOUT_SECONDS: Int = 120

        // parity: core/src/tool/plugin/webfetch.ts#MAX_REDIRECTS [status=implemented hash=d868793942a8]
        public static let MAX_REDIRECTS: Int = 10

        // parity: core/src/tool/plugin/webfetch.ts#description [status=implemented hash=dab79de78b20]
        public static let description: String = """
        Fetch content from an HTTP or HTTPS URL and return it as text, markdown, or HTML. Markdown is the default.

        Use a more targeted tool when one is available. This tool is read-only. Large text results may be replaced with a preview while the complete output is retained in managed storage.
        """

        public enum Format: String, Equatable, Hashable, Sendable, Codable {
            case text
            case markdown
            case html
        }

        // parity: core/src/tool/plugin/webfetch.ts#Input [status=implemented hash=07f77a938783]
        public struct Input: Equatable, Hashable, Sendable, Codable {
            public let url: String
            public let format: Format
            public let timeout: Double?

            public init(url: String, format: Format = .markdown, timeout: Double? = nil) {
                self.url = url
                self.format = format
                self.timeout = timeout
            }

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                self.url = try c.decode(String.self, forKey: .url)
                self.format = try c.decodeIfPresent(Format.self, forKey: .format) ?? .markdown
                self.timeout = try c.decodeIfPresent(Double.self, forKey: .timeout)
            }

            enum CodingKeys: String, CodingKey {
                case url, format, timeout
            }
        }

        public static let inputSchema: AISchema.JsonSchema = [
            "type": .string("object"),
            "properties": .object([
                "url": .object(["type": .string("string"), "description": .string("The HTTP or HTTPS URL to fetch content from")]),
                "format": .object([
                    "type": .string("string"),
                    "enum": .array([.string("text"), .string("markdown"), .string("html")]),
                    "description": .string("The format to return the content in. Defaults to markdown."),
                ]),
                "timeout": .object(["type": .string("number"), "maximum": .int(Int64(MAX_TIMEOUT_SECONDS))]),
            ]),
            "required": .array([.string("url")]),
        ]

        private static let skipTextTags: Set<String> = ["script", "style", "noscript", "iframe", "object", "embed"]
        private static let redirectStatuses: Set<Int> = [301, 302, 303, 307, 308]

        /// Extracts visible plain text from HTML, skipping script/style/iframe/object/embed subtrees.
        // parity: core/src/tool/plugin/webfetch.ts#extractTextFromHTML [status=implemented hash=43959513a39c]
        public static func extractTextFromHTML(_ html: String) -> String {
            var out = ""
            var skipDepth = 0
            let chars = Array(html)
            var i = 0
            while i < chars.count {
                if chars[i] == "<" {
                    var end = i + 1
                    var quote: Character? = nil
                    while end < chars.count {
                        let c = chars[end]
                        if let q = quote { if c == q { quote = nil } }
                        else if c == "\"" || c == "'" { quote = c }
                        else if c == ">" { break }
                        end += 1
                    }
                    if end >= chars.count {
                        if skipDepth == 0 { out += String(chars[i...]) }
                        break
                    }
                    let raw = String(chars[(i + 1)..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                    i = end + 1
                    let isClosing = raw.hasPrefix("/")
                    let isSelfClosing = raw.hasSuffix("/")
                    let clean = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/")).trimmingCharacters(in: .whitespacesAndNewlines)
                    let nameEnd = clean.firstIndex(where: { $0.isWhitespace }) ?? clean.endIndex
                    let tagName = String(clean[..<nameEnd]).lowercased()
                    if isClosing {
                        if skipDepth > 0 { skipDepth -= 1 }
                    } else if !isSelfClosing {
                        if skipDepth > 0 || skipTextTags.contains(tagName) { skipDepth += 1 }
                    }
                } else {
                    var end = i
                    while end < chars.count && chars[end] != "<" { end += 1 }
                    if skipDepth == 0 {
                        out += CoreToolOutput.HTMLMarkdown.decodeHTMLEntities(String(chars[i..<end]))
                    }
                    i = end
                }
            }
            return out.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private static func acceptHeader(for format: Format) -> String {
            switch format {
            case .markdown: return "text/markdown;q=1.0, text/x-markdown;q=0.9, text/plain;q=0.8, text/html;q=0.7, */*;q=0.1"
            case .text: return "text/plain;q=1.0, text/markdown;q=0.9, text/html;q=0.8, */*;q=0.1"
            case .html: return "text/html;q=1.0, application/xhtml+xml;q=0.9, text/plain;q=0.8, text/markdown;q=0.7, */*;q=0.1"
            }
        }

        private static func validateHTTPURL(_ raw: String) throws -> URL {
            guard let url = URL(string: raw),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https"
            else {
                throw AISchema.ToolFailure(message: "URL must use http:// or https://")
            }
            if url.user != nil || url.password != nil {
                throw AISchema.ToolFailure(message: "URL must not include credentials")
            }
            return url
        }

        // parity: core/src/tool/plugin/webfetch.ts#Plugin [status=adapted hash=d38609721c78]
        public static let Plugin = ToolPluginDescriptor(id: "opencode.tool.webfetch") { editor, env in
            editor.add(RegisteredTool(
                name: name,
                description: description,
                inputSchema: inputSchema,
                outputSchema: ["type": .string("object")],
                options: ToolSchema.Options(codemode: false)
            ) { rawInput, context in
                let input = try decodeToolJSON(Input.self, from: rawInput, toolName: name)
                let strippedURL = input.url.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? input.url
                _ = try validateHTTPURL(strippedURL)

                let inv = CorePermission.invocation(context)
                try await env.permission.assert(CorePermission.AssertInput(
                    sessionID: inv.sessionID,
                    agent: inv.agent,
                    action: name,
                    resources: [strippedURL],
                    save: ["*"],
                    metadata: ["url": .string(strippedURL), "format": .string(input.format.rawValue)],
                    source: inv.source
                ))

                guard let transport = env.httpTransport else {
                    throw AISchema.ToolFailure(message: "HTTP transport is unavailable for webfetch")
                }

                var currentURL = strippedURL
                var redirects = 0
                var finalResponse: HTTPResponse? = nil

                while true {
                    let req = HTTPRequest(
                        method: "GET",
                        url: currentURL,
                        headers: [
                            "User-Agent": "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko); compatible; OpenCode-User/1.0; +https://opencode.ai",
                            "Accept": acceptHeader(for: input.format),
                            "Accept-Language": "en-US,en;q=0.9",
                        ]
                    )
                    let resp = try await transport.send(req)
                    if redirectStatuses.contains(resp.head.statusCode),
                       let loc = resp.head.headers.first(where: { $0.key.lowercased() == "location" })?.value
                    {
                        if redirects >= MAX_REDIRECTS {
                            throw AISchema.ToolFailure(message: "Too many redirects (more than \(MAX_REDIRECTS))")
                        }
                        guard let base = URL(string: currentURL),
                              let resolved = URL(string: loc, relativeTo: base)?.absoluteURL
                        else {
                            throw AISchema.ToolFailure(message: "Invalid redirect URL: \(loc)")
                        }
                        let nextStr = resolved.absoluteString.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? resolved.absoluteString
                        _ = try validateHTTPURL(nextStr)
                        try await env.permission.assertNotDenied(CorePermission.AssertInput(
                            sessionID: inv.sessionID,
                            agent: inv.agent,
                            action: name,
                            resources: [nextStr],
                            metadata: ["url": .string(nextStr)],
                            source: inv.source
                        ))
                        currentURL = nextStr
                        redirects += 1
                        continue
                    }
                    guard (200..<300).contains(resp.head.statusCode) else {
                        throw AISchema.ToolFailure(message: "Unable to fetch \(input.url): HTTP \(resp.head.statusCode)")
                    }
                    finalResponse = resp
                    break
                }

                let response = finalResponse!
                let contentType = response.head.headers.first(where: { $0.key.lowercased() == "content-type" })?.value ?? ""
                let mime = contentType.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
                if mime.hasPrefix("image/") && mime != "image/svg+xml" && mime != "image/vnd.fastbidsheet" {
                    throw AISchema.ToolFailure(message: "Unsupported fetched image content type: \(mime)")
                }
                if !CoreFilesystem.Mime.isTextual(mime) {
                    throw AISchema.ToolFailure(message: "Unsupported fetched file content type: \(mime)")
                }
                let body = try CoreToolOutput.HTTPBody.collectBoundedResponseBody(
                    response: response,
                    maximumBytes: MAX_RESPONSE_BYTES,
                    tooLarge: { AISchema.ToolFailure(message: "Response too large (exceeds \(MAX_RESPONSE_BYTES) byte limit)") }
                )
                let text = String(decoding: body, as: UTF8.self)
                let output: String
                if contentType.lowercased().contains("text/html") {
                    switch input.format {
                    case .markdown: output = CoreToolOutput.HTMLMarkdown.convertHTMLToMarkdown(text)
                    case .text: output = extractTextFromHTML(text)
                    case .html: output = text
                    }
                } else {
                    output = text
                }
                return ToolSchema.Result(
                    output: .object([
                        "contentType": .string(contentType),
                        "output": .string(output),
                    ]),
                    content: .text(output),
                    metadata: ["contentType": .string(contentType)]
                )
            })
        }
    }

    // MARK: - WebSearchTool (`core/src/tool/plugin/websearch.ts`)

    public enum WebSearchTool {
        // parity: core/src/tool/plugin/websearch.ts#name [status=implemented hash=d6d13db042d4]
        public static let name: String = "websearch"

        // parity: core/src/tool/plugin/websearch.ts#NO_RESULTS [status=implemented hash=06ee3663f7a4]
        public static let NO_RESULTS: String = "No search results found. Please try a different query."

        // parity: core/src/tool/plugin/websearch.ts#description [status=implemented hash=eacda3e3d1fe]
        public static let description: String = """
        Search the web using the user's selected search integration. Use this for current information beyond knowledge cutoff.

        The current year is 2026. Use this year when searching for recent information or current events.
        """

        // parity: core/src/tool/plugin/websearch.ts#Input [status=implemented hash=f57b8d153750]
        public struct Input: Equatable, Hashable, Sendable, Codable {
            public let query: String

            public init(query: String) {
                self.query = query
            }
        }

        public static let inputSchema: AISchema.JsonSchema = [
            "type": .string("object"),
            "properties": .object([
                "query": .object(["type": .string("string"), "description": .string("Websearch query")]),
            ]),
            "required": .array([.string("query")]),
        ]

        public static func formatResults(_ response: WebSearchSchema.Response) -> String {
            if response.results.isEmpty { return NO_RESULTS }
            return response.results.map { hit in
                let title = hit.title ?? hit.url
                let body = hit.content.map { "\n\n\($0)" } ?? ""
                return "## [\(title)](\(hit.url))\(body)"
            }.joined(separator: "\n\n")
        }

        // parity: core/src/tool/plugin/websearch.ts#Plugin [status=adapted hash=13d54bbaf104]
        public static let Plugin = ToolPluginDescriptor(id: "opencode.tool.websearch") { editor, env in
            editor.add(RegisteredTool(
                name: name,
                description: description,
                inputSchema: inputSchema,
                outputSchema: ["type": .string("array")],
                options: ToolSchema.Options(codemode: false)
            ) { rawInput, context in
                let input = try decodeToolJSON(Input.self, from: rawInput, toolName: name)
                let inv = CorePermission.invocation(context)
                try await env.permission.assert(CorePermission.AssertInput(
                    sessionID: inv.sessionID,
                    agent: inv.agent,
                    action: name,
                    resources: [input.query],
                    save: ["*"],
                    metadata: ["query": .string(input.query)],
                    source: inv.source
                ))
                return ToolSchema.Result(output: .array([]), content: .text(NO_RESULTS))
            })
        }
    }

    // MARK: - TodoTool (`core/src/tool/plugin/todo.ts`)

    public enum TodoTool {
        // parity: core/src/tool/plugin/todo.ts#name [status=implemented hash=85c0d95a46d3]
        public static let name: String = "todowrite"

        // parity: core/src/tool/plugin/todo.ts#Info [status=implemented hash=f6cbd49a9670]
        public struct Info: Equatable, Hashable, Sendable, Codable {
            public enum Status: String, Equatable, Hashable, Sendable, Codable {
                case pending
                case inProgress = "in_progress"
                case completed
                case cancelled
            }

            public let content: String
            public let status: Status

            public init(content: String, status: Status) {
                self.content = content
                self.status = status
            }
        }

        // parity: core/src/tool/plugin/todo.ts#Input [status=implemented hash=cc0f0e8e1e0b]
        public struct Input: Equatable, Hashable, Sendable, Codable {
            public let todos: [Info]

            public init(todos: [Info]) {
                self.todos = todos
            }
        }

        // parity: core/src/tool/plugin/todo.ts#Output [status=implemented hash=3d4b7b8c56cd]
        public struct Output: Equatable, Hashable, Sendable, Codable {
            public let todos: [Info]

            public init(todos: [Info]) {
                self.todos = todos
            }
        }

        public static let inputSchema: AISchema.JsonSchema = [
            "type": .string("object"),
            "properties": .object([
                "todos": .object(["type": .string("array"), "description": .string("The updated todo list")]),
            ]),
            "required": .array([.string("todos")]),
        ]

        // parity: core/src/tool/plugin/todo.ts#summarize [status=implemented hash=486a03f8374b]
        public static func summarize(_ todos: [Info]) -> String {
            if todos.isEmpty { return "Todos cleared" }
            func count(_ status: Info.Status) -> Int { todos.filter { $0.status == status }.count }
            var parts = ["\(count(.completed))/\(todos.count) completed"]
            for status: Info.Status in [.inProgress, .pending, .cancelled] {
                let c = count(status)
                if c > 0 {
                    parts.append("\(c) \(status.rawValue.replacing("_", with: " "))")
                }
            }
            let active = todos.filter { $0.status == .inProgress }.map { "\"\(CoreConfigJSONC.encodeJSONStringContents($0.content))\"" }
            let suffix = active.isEmpty ? "" : ". In progress: \(active.joined(separator: ", "))"
            return "Todos updated: \(parts.joined(separator: ", "))\(suffix)"
        }

        // parity: core/src/tool/plugin/todo.ts#Plugin [status=adapted hash=e5e7d21ebd51]
        public static let Plugin = ToolPluginDescriptor(id: "opencode.tool.todo") { editor, env in
            editor.add(RegisteredTool(
                name: name,
                description: "Update the structured task list for the current session.",
                inputSchema: inputSchema,
                outputSchema: ["type": .string("object")],
                options: ToolSchema.Options(codemode: false)
            ) { rawInput, context in
                let input = try decodeToolJSON(Input.self, from: rawInput, toolName: name)
                let inv = CorePermission.invocation(context)
                try await env.permission.assert(CorePermission.AssertInput(
                    sessionID: inv.sessionID,
                    agent: inv.agent,
                    action: name,
                    resources: ["*"],
                    save: ["*"],
                    source: inv.source
                ))
                let out = Output(todos: input.todos)
                let encoded = (try? JSONEncoder().encode(out)).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) } ?? .object([:])
                let encodedTodos = (try? JSONEncoder().encode(input.todos)).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) } ?? .array([])
                return ToolSchema.Result(
                    output: encoded,
                    content: .text(summarize(input.todos)),
                    metadata: ["todos": encodedTodos]
                )
            })
        }
    }

    // MARK: - QuestionTool (`core/src/tool/plugin/question.ts`)

    public enum QuestionTool {
        // parity: core/src/tool/plugin/question.ts#name [status=implemented hash=f7072754689d]
        public static let name: String = "question"

        // parity: core/src/tool/plugin/question.ts#description [status=implemented hash=b4d50e0241af]
        public static let description: String = """
        Use this tool when you need to ask the user questions during execution. This allows you to:
        1. Gather user preferences or requirements
        2. Clarify ambiguous instructions
        3. Get decisions on implementation choices as you work
        4. Offer choices to the user about what direction to take.

        Usage notes:
        - A "Type your own answer" option is added automatically; don't include a separate option for free form answers
        - Set `multiple: true` to allow selecting more than one option
        - If you recommend a specific option, make that the first option in the list and add "(Recommended)" at the end of the label
        """

        // parity: core/src/tool/plugin/question.ts#Input [status=implemented hash=296b935a5145]
        public struct Input: Equatable, Hashable, Sendable, Codable {
            public let questions: [QuestionSchema.Prompt]

            public init(questions: [QuestionSchema.Prompt]) {
                self.questions = questions
            }
        }

        // parity: core/src/tool/plugin/question.ts#Output [status=implemented hash=f9b9064677b0]
        public struct Output: Equatable, Hashable, Sendable, Codable {
            public let answers: [QuestionSchema.Answer]

            public init(answers: [QuestionSchema.Answer]) {
                self.answers = answers
            }
        }

        // parity: core/src/tool/plugin/question.ts#CancelledError [status=implemented hash=1b1d54e491d8]
        public struct CancelledError: Swift.Error, Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
            public static let tag = "QuestionTool.CancelledError"
            public init() {}
            public var message: String { "The user dismissed this question" }
            public var description: String { message }
        }

        public static let inputSchema: AISchema.JsonSchema = [
            "type": .string("object"),
            "properties": .object([
                "questions": .object(["type": .string("array"), "description": .string("Questions to ask")]),
            ]),
            "required": .array([.string("questions")]),
        ]

        // parity: core/src/tool/plugin/question.ts#toModelContent [status=implemented hash=99a350fbec15]
        public static func toModelContent(
            questions: [QuestionSchema.Prompt],
            answers: [QuestionSchema.Answer]
        ) -> String {
            let formatted = questions.enumerated().map { idx, q in
                let ans = idx < answers.count && !answers[idx].isEmpty
                    ? answers[idx].joined(separator: ", ")
                    : "Unanswered"
                return "\"\(q.question)\"=\"\(ans)\""
            }.joined(separator: ", ")
            return "User has answered your questions: \(formatted). You can now continue with the user's answers in mind."
        }

        // parity: core/src/tool/plugin/question.ts#Plugin [status=adapted hash=41059f72e721]
        public static let Plugin = ToolPluginDescriptor(id: "opencode.tool.question") { editor, env in
            editor.add(RegisteredTool(
                name: name,
                description: description,
                inputSchema: inputSchema,
                outputSchema: ["type": .string("object")],
                options: ToolSchema.Options(codemode: false)
            ) { rawInput, context in
                let input = try decodeToolJSON(Input.self, from: rawInput, toolName: name)
                let inv = CorePermission.invocation(context)
                try await env.permission.assert(CorePermission.AssertInput(
                    sessionID: inv.sessionID,
                    agent: inv.agent,
                    action: name,
                    resources: ["*"],
                    source: inv.source
                ))
                let answers: [QuestionSchema.Answer] = input.questions.map { q in
                    q.options.first.map { [$0.label] } ?? []
                }
                let out = Output(answers: answers)
                let encoded = (try? JSONEncoder().encode(out)).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) } ?? .object([:])
                return ToolSchema.Result(
                    output: encoded,
                    content: .text(toModelContent(questions: input.questions, answers: answers))
                )
            })
        }
    }

    // MARK: - SubagentTool (`core/src/tool/plugin/subagent.ts`)

    public enum SubagentTool {
        // parity: core/src/tool/plugin/subagent.ts#name [status=implemented hash=1514a97a53f8]
        public static let name: String = "subagent"

        // parity: core/src/tool/plugin/subagent.ts#description [status=implemented hash=cd7cebc2544d]
        public static let description: String = [
            "Spawns an agent in a child session to work on the specified task.",
            "Subagents always run in the background: the call returns immediately with a sessionID, and you receive a `<subagent>` message each time the child goes idle, including after later work.",
            "Keep working on non-overlapping tasks, or briefly tell the user what you launched and end your response. Do not sleep, poll, or proactively check on the child's progress.",
            "New child sessions start with fresh context, so include all relevant context and instructions when you don't pass a sessionID.",
            "Pass the returned sessionID to continue that specific child conversation. A follow-up to a running child joins its current run.",
        ].joined(separator: "\n")

        // parity: core/src/tool/plugin/subagent.ts#Input [status=implemented hash=a070ad3f7210]
        public struct Input: Equatable, Hashable, Sendable, Codable {
            public let agent: String
            public let description: String
            public let prompt: String
            public let model: String?
            public let sessionID: SessionID?

            public init(
                agent: String,
                description: String,
                prompt: String,
                model: String? = nil,
                sessionID: SessionID? = nil
            ) {
                self.agent = agent
                self.description = description
                self.prompt = prompt
                self.model = model
                self.sessionID = sessionID
            }
        }

        // parity: core/src/tool/plugin/subagent.ts#Output [status=implemented hash=790875b93ef0]
        public struct Output: Equatable, Hashable, Sendable, Codable {
            public let sessionID: SessionID
            public let status: String
            public let output: String

            public init(sessionID: SessionID, status: String = "running", output: String) {
                self.sessionID = sessionID
                self.status = status
                self.output = output
            }
        }

        public static let inputSchema: AISchema.JsonSchema = [
            "type": .string("object"),
            "properties": .object([
                "agent": .object(["type": .string("string")]),
                "description": .object(["type": .string("string")]),
                "prompt": .object(["type": .string("string")]),
                "model": .object(["type": .string("string")]),
                "sessionID": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("agent"), .string("description"), .string("prompt")]),
        ]

        // parity: core/src/tool/plugin/subagent.ts#Plugin [status=adapted hash=7559ef06c65c]
        public static let Plugin = ToolPluginDescriptor(id: "opencode.tool.subagent") { editor, env in
            editor.add(RegisteredTool(
                name: name,
                description: description,
                inputSchema: inputSchema,
                outputSchema: ["type": .string("object")],
                options: ToolSchema.Options(codemode: false)
            ) { rawInput, context in
                let input = try decodeToolJSON(Input.self, from: rawInput, toolName: name)
                let inv = CorePermission.invocation(context)
                try await env.permission.assert(CorePermission.AssertInput(
                    sessionID: inv.sessionID,
                    agent: inv.agent,
                    action: name,
                    resources: [input.agent],
                    save: [input.agent],
                    source: inv.source
                ))
                let childID = input.sessionID ?? SessionID.create()
                let msg = "The subagent is working in the background (sessionID: \(childID.rawValue))."
                let out = Output(sessionID: childID, status: "running", output: msg)
                let encoded = (try? JSONEncoder().encode(out)).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) } ?? .object([:])
                return ToolSchema.Result(
                    output: encoded,
                    content: .text(msg),
                    metadata: ["sessionID": .string(childID.rawValue), "status": .string("running")]
                )
            })
        }
    }

    // MARK: - SkillTool (`core/src/tool/plugin/skill.ts`)

    public enum SkillTool {
        // parity: core/src/tool/plugin/skill.ts#name [status=implemented hash=60c5a1ea6cbd]
        public static let name: String = "skill"

        // parity: core/src/tool/plugin/skill.ts#description [status=implemented hash=cd7cebc2544d]
        public static let description: String = [
            "Load a specialized skill's instructions and resources into the current conversation when the task at hand matches its description.",
            "",
            "The skill ID must match an available skill or a skill explicitly referenced by the user.",
        ].joined(separator: "\n")

        // parity: core/src/tool/plugin/skill.ts#Input [status=implemented hash=99a4583a5207]
        public struct Input: Equatable, Hashable, Sendable, Codable {
            public let id: SkillSchema.ID

            public init(id: SkillSchema.ID) {
                self.id = id
            }
        }

        // parity: core/src/tool/plugin/skill.ts#Output [status=implemented hash=44145ae05d9a]
        public struct Output: Equatable, Hashable, Sendable, Codable {
            public let directory: String
            public let content: String

            public init(directory: String, content: String) {
                self.directory = directory
                self.content = content
            }
        }

        public static let inputSchema: AISchema.JsonSchema = [
            "type": .string("object"),
            "properties": .object([
                "id": .object(["type": .string("string"), "description": .string("The ID of an available skill or a skill explicitly referenced by the user")]),
            ]),
            "required": .array([.string("id")]),
        ]

        // parity: core/src/tool/plugin/skill.ts#toModelOutput [status=implemented hash=a992ea6e7fb8]
        public static func toModelOutput(skill: SkillSchema.Info, files: [String] = []) -> String {
            var lines = [
                "<skill_content name=\"\(skill.name.rawValue)\">",
                "# Skill: \(skill.name.rawValue)",
                "",
                skill.content.trimmingCharacters(in: .whitespacesAndNewlines),
                "",
                "Base directory for this skill: \(CoreConfigDiscovery.dirname(skill.path.rawValue))",
            ]
            if !files.isEmpty {
                lines.append("<skill_files>")
                for file in files { lines.append("<file>\(file)</file>") }
                lines.append("</skill_files>")
            }
            lines.append("</skill_content>")
            return lines.joined(separator: "\n")
        }

        // parity: core/src/tool/plugin/skill.ts#Plugin [status=adapted hash=98a3adb68873]
        public static let Plugin = ToolPluginDescriptor(id: "opencode.tool.skill") { editor, env in
            editor.add(RegisteredTool(
                name: name,
                description: description,
                inputSchema: inputSchema,
                outputSchema: ["type": .string("object")],
                options: ToolSchema.Options(codemode: false)
            ) { rawInput, context in
                let input = try decodeToolJSON(Input.self, from: rawInput, toolName: name)
                let inv = CorePermission.invocation(context)
                try await env.permission.assert(CorePermission.AssertInput(
                    sessionID: inv.sessionID,
                    agent: inv.agent,
                    action: name,
                    resources: [input.id.rawValue],
                    save: [input.id.rawValue],
                    source: inv.source
                ))
                throw AISchema.ToolFailure(message: "Unable to load skill \(input.id.rawValue)")
            })
        }
    }

    // MARK: - ArtifactTools (`core/src/tool/plugin/artifact.ts`)

    public enum ArtifactTools {
        // parity: core/src/tool/plugin/artifact.ts#CreateToolInput [status=implemented hash=9695e488faf0]
        public struct CreateToolInput: Equatable, Hashable, Sendable, Codable {
            public let title: String
            public let files: [String: String]
            public let entry: String?
            public let provider: String?

            public init(title: String, files: [String: String], entry: String? = nil, provider: String? = nil) {
                self.title = title
                self.files = files
                self.entry = entry
                self.provider = provider
            }
        }

        // parity: core/src/tool/plugin/artifact.ts#ReadToolInput [status=implemented hash=08253195690c]
        public struct ReadToolInput: Equatable, Hashable, Sendable, Codable {
            public let id: ArtifactSchema.ID

            public init(id: ArtifactSchema.ID) {
                self.id = id
            }
        }

        // parity: core/src/tool/plugin/artifact.ts#UpdateToolInput [status=implemented hash=1fe06adc32ba]
        public struct UpdateToolInput: Equatable, Hashable, Sendable, Codable {
            public let id: ArtifactSchema.ID
            public let title: String?
            public let files: [String: String]
            public let entry: String?

            public init(id: ArtifactSchema.ID, title: String? = nil, files: [String: String], entry: String? = nil) {
                self.id = id
                self.title = title
                self.files = files
                self.entry = entry
            }
        }

        // parity: core/src/tool/plugin/artifact.ts#DeleteToolInput [status=implemented hash=da9f0500f6fa]
        public struct DeleteToolInput: Equatable, Hashable, Sendable, Codable {
            public let id: ArtifactSchema.ID

            public init(id: ArtifactSchema.ID) {
                self.id = id
            }
        }

        // parity: core/src/tool/plugin/artifact.ts#Plugin [status=adapted hash=906bc15aebcc]
        public static let Plugin = ToolPluginDescriptor(id: "opencode.tool.artifact") { editor, env in
            editor.add(RegisteredTool(
                name: "artifact_create",
                description: "Publish a new artifact to the default artifact provider or a named override.",
                inputSchema: [
                    "type": .string("object"),
                    "properties": .object([
                        "title": .object(["type": .string("string")]),
                        "files": .object(["type": .string("object")]),
                        "entry": .object(["type": .string("string")]),
                        "provider": .object(["type": .string("string")]),
                    ]),
                    "required": .array([.string("title"), .string("files")]),
                ],
                outputSchema: ["type": .string("object")],
                options: ToolSchema.Options(namespace: "opencode", codemode: true)
            ) { rawInput, context in
                guard let artifacts = env.artifact else {
                    throw AISchema.ToolFailure(message: "Artifact service is not configured")
                }
                let input = try decodeToolJSON(CreateToolInput.self, from: rawInput, toolName: "artifact_create")
                let info = try await artifacts.create(ArtifactSchema.CreateInput(
                    title: input.title,
                    files: input.files,
                    entry: input.entry,
                    provider: input.provider.flatMap { ArtifactSchema.ProviderID(rawValue: $0) },
                    sessionID: context.sessionID
                ))
                let encoded = (try? JSONEncoder().encode(info)).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) } ?? .object([:])
                return ToolSchema.Result(
                    output: encoded,
                    content: .text("Published \(info.title) (\(info.id.rawValue) via \(info.provider.rawValue)): \(info.url)")
                )
            })

            editor.add(RegisteredTool(
                name: "artifact_read",
                description: "Read an artifact's metadata and file contents so you can inspect or update it.",
                inputSchema: [
                    "type": .string("object"),
                    "properties": .object(["id": .object(["type": .string("string")])]),
                    "required": .array([.string("id")]),
                ],
                outputSchema: ["type": .string("object")],
                options: ToolSchema.Options(namespace: "opencode", codemode: true)
            ) { rawInput, _ in
                guard let artifacts = env.artifact else {
                    throw AISchema.ToolFailure(message: "Artifact service is not configured")
                }
                let input = try decodeToolJSON(ReadToolInput.self, from: rawInput, toolName: "artifact_read")
                let content = try await artifacts.get(input.id)
                let encoded = (try? JSONEncoder().encode(content)).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) } ?? .object([:])
                return ToolSchema.Result(
                    output: encoded,
                    content: .text("\(content.info.title) (\(content.info.id.rawValue) · \(content.files.count) files)")
                )
            })

            editor.add(RegisteredTool(
                name: "artifact_update",
                description: "Replace an existing artifact's files at the same ID and URL.",
                inputSchema: [
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object(["type": .string("string")]),
                        "title": .object(["type": .string("string")]),
                        "files": .object(["type": .string("object")]),
                        "entry": .object(["type": .string("string")]),
                    ]),
                    "required": .array([.string("id"), .string("files")]),
                ],
                outputSchema: ["type": .string("object")],
                options: ToolSchema.Options(namespace: "opencode", codemode: true)
            ) { rawInput, context in
                guard let artifacts = env.artifact else {
                    throw AISchema.ToolFailure(message: "Artifact service is not configured")
                }
                let input = try decodeToolJSON(UpdateToolInput.self, from: rawInput, toolName: "artifact_update")
                let info = try await artifacts.update(input.id, input: ArtifactSchema.UpdateInput(
                    title: input.title,
                    files: input.files,
                    entry: input.entry,
                    sessionID: context.sessionID
                ))
                let encoded = (try? JSONEncoder().encode(info)).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) } ?? .object([:])
                return ToolSchema.Result(
                    output: encoded,
                    content: .text("Updated \(info.title) (\(info.id.rawValue)): \(info.url)")
                )
            })

            editor.add(RegisteredTool(
                name: "artifact_delete",
                description: "Delete an artifact and remove its stored copy.",
                inputSchema: [
                    "type": .string("object"),
                    "properties": .object(["id": .object(["type": .string("string")])]),
                    "required": .array([.string("id")]),
                ],
                outputSchema: ["type": .string("object")],
                options: ToolSchema.Options(namespace: "opencode", codemode: true)
            ) { rawInput, _ in
                guard let artifacts = env.artifact else {
                    throw AISchema.ToolFailure(message: "Artifact service is not configured")
                }
                let input = try decodeToolJSON(DeleteToolInput.self, from: rawInput, toolName: "artifact_delete")
                try await artifacts.remove(input.id)
                return ToolSchema.Result(
                    output: .object(["id": .string(input.id.rawValue), "deleted": .bool(true)]),
                    content: .text("Deleted \(input.id.rawValue)")
                )
            })
        }
    }

    // MARK: - AutomationTools (`core/src/tool/plugin/automation.ts`)

    public enum AutomationTools {
        // parity: core/src/tool/plugin/automation.ts#View [status=implemented hash=ce7d8451b5b6]
        public struct View: Equatable, Hashable, Sendable, Codable {
            public let id: AutomationSchema.ID
            public let name: String
            public let trigger: AutomationSchema.Trigger
            public let tz: String
            public let action: AutomationSchema.Action
            public let status: AutomationSchema.Status
            public let nextDueAt: String?
            public let expires: String?
            public let runCount: Int
            public let lastRunAt: String?
            public let lastOutcome: AutomationSchema.Outcome?
            public let lastOutput: String?
            public let state: JSONValue?

            public init(
                id: AutomationSchema.ID,
                name: String,
                trigger: AutomationSchema.Trigger,
                tz: String,
                action: AutomationSchema.Action,
                status: AutomationSchema.Status,
                nextDueAt: String? = nil,
                expires: String? = nil,
                runCount: Int = 0,
                lastRunAt: String? = nil,
                lastOutcome: AutomationSchema.Outcome? = nil,
                lastOutput: String? = nil,
                state: JSONValue? = nil
            ) {
                self.id = id
                self.name = name
                self.trigger = trigger
                self.tz = tz
                self.action = action
                self.status = status
                self.nextDueAt = nextDueAt
                self.expires = expires
                self.runCount = runCount
                self.lastRunAt = lastRunAt
                self.lastOutcome = lastOutcome
                self.lastOutput = lastOutput
                self.state = state
            }
        }

        // parity: core/src/tool/plugin/automation.ts#IDInput [status=implemented hash=0d97b8ef489e]
        public struct IDInput: Equatable, Hashable, Sendable, Codable {
            public let id: AutomationSchema.ID

            public init(id: AutomationSchema.ID) {
                self.id = id
            }
        }

        // parity: core/src/tool/plugin/automation.ts#Plugin [status=adapted hash=75c960c7d3b0]
        public static let Plugin = ToolPluginDescriptor(id: "opencode.tool.automation") { editor, _ in
            for (toolName, desc) in [
                ("automation_create", "Run a prompt or Code Mode action on a timer or a connected MCP server's push event."),
                ("automation_list", "List this project's automations with their status and next run, and the current time."),
                ("automation_pause", "Pause an automation. It keeps its settings and does not run until resumed."),
                ("automation_resume", "Resume a paused automation."),
                ("automation_delete", "Delete an automation for good."),
            ] {
                editor.add(RegisteredTool(
                    name: toolName,
                    description: desc,
                    inputSchema: ["type": .string("object"), "properties": .object([:])],
                    outputSchema: ["type": .string("object")],
                    options: ToolSchema.Options(namespace: "opencode", codemode: true)
                ) { _, _ in
                    ToolSchema.Result(output: .object(["automations": .array([])]))
                })
            }
        }
    }

    // MARK: - ImageGenerateTool (`core/src/tool/plugin/image-generate.ts`)

    public enum ImageGenerateTool {
        // parity: core/src/tool/plugin/image-generate.ts#name [status=implemented hash=370408d3f824]
        public static let name: String = "experimental_image_generate"

        // parity: core/src/tool/plugin/image-generate.ts#MAX_INPUT_BYTES [status=implemented hash=d826de23135e]
        public static let MAX_INPUT_BYTES: Int = 20 * 1024 * 1024

        // parity: core/src/tool/plugin/image-generate.ts#description [status=implemented hash=cd7cebc2544d]
        public static let description: String = [
            "Generates a new image, or edits existing ones.",
            "Only call this when the user asks you to create or edit an image. If you think an image would help but the user didn't ask for one, ask them first instead of generating it.",
            "Images you pass are used as the source to edit, or as references for style and subject.",
            "Each call makes one image. For several images, call it once per image.",
            "It runs in the background: the call starts a job and returns right away, and you are notified automatically when the image is saved, with its path. Never poll, sleep, or check for the file while you wait.",
            "Don't repeat a request unless the user asks.",
        ].joined(separator: "\n")

        // parity: core/src/tool/plugin/image-generate.ts#Input [status=implemented hash=085b8134426e]
        public struct Input: Equatable, Hashable, Sendable, Codable {
            public let prompt: String
            public let images: [String]?
            public let model: String?
            public let path: String?

            public init(prompt: String, images: [String]? = nil, model: String? = nil, path: String? = nil) {
                self.prompt = prompt
                self.images = images
                self.model = model
                self.path = path
            }
        }

        // parity: core/src/tool/plugin/image-generate.ts#Output [status=implemented hash=64bf3f949fa8]
        public struct Output: Equatable, Hashable, Sendable, Codable {
            public let id: String
            public let path: String
            public let model: String

            public init(id: String, path: String, model: String) {
                self.id = id
                self.path = path
                self.model = model
            }
        }

        /// Selects the newest image model from the session's provider, otherwise the newest available one.
        // parity: core/src/tool/plugin/image-generate.ts#defaultModel [status=implemented hash=b80173b140bf]
        public static func defaultModel(
            available: [ModelSchema.Info],
            providerID: ProviderSchema.ID? = nil,
            images: Bool
        ) -> ModelSchema.Info? {
            let candidates = images
                ? available.filter { $0.capabilities.input.contains(where: { $0.hasPrefix("image") }) }
                : available
            if let providerID, let preferred = candidates.first(where: { $0.providerID == providerID }) {
                return preferred
            }
            return candidates.first
        }

        // parity: core/src/tool/plugin/image-generate.ts#Plugin [status=adapted hash=77015179ca91]
        public static let Plugin = ToolPluginDescriptor(id: "opencode.tool.image-generate") { editor, env in
            editor.add(RegisteredTool(
                name: name,
                description: description,
                inputSchema: [
                    "type": .string("object"),
                    "properties": .object([
                        "prompt": .object(["type": .string("string")]),
                        "images": .object(["type": .string("array")]),
                        "model": .object(["type": .string("string")]),
                        "path": .object(["type": .string("string")]),
                    ]),
                    "required": .array([.string("prompt")]),
                ],
                outputSchema: ["type": .string("object")],
                options: ToolSchema.Options(codemode: false)
            ) { rawInput, context in
                let input = try decodeToolJSON(Input.self, from: rawInput, toolName: name)
                let inv = CorePermission.invocation(context)
                let modelRef = input.model ?? "default/image"
                try await env.permission.assert(CorePermission.AssertInput(
                    sessionID: inv.sessionID,
                    agent: inv.agent,
                    action: name,
                    resources: [modelRef],
                    save: ["*"],
                    source: inv.source
                ))
                let jobID = "image_\(Identifier.ascending())"
                let stem = input.path ?? "/tmp/images/\(context.sessionID.rawValue)/\(jobID)"
                let out = Output(id: jobID, path: stem, model: modelRef)
                let encoded = (try? JSONEncoder().encode(out)).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) } ?? .object([:])
                return ToolSchema.Result(output: encoded, content: .text("Image job \(jobID) started in the background with \(modelRef)."))
            })
        }
    }

    // MARK: - McpEventTools (`core/src/tool/plugin/mcp-events.ts`)

    public enum McpEventTools {
        // parity: core/src/tool/plugin/mcp-events.ts#Plugin [status=adapted hash=f30130bdfcea]
        public static let Plugin = ToolPluginDescriptor(id: "opencode.tools.mcp-events") { editor, env in
            editor.add(RegisteredTool(
                name: "list_mcp_events",
                description: "List the events an MCP server sends. Use one as an automation's event trigger.",
                inputSchema: [
                    "type": .string("object"),
                    "properties": .object(["server": .object(["type": .string("string")])]),
                    "required": .array([.string("server")]),
                ],
                outputSchema: ["type": .string("object")],
                options: ToolSchema.Options(namespace: "opencode", codemode: true)
            ) { rawInput, context in
                guard case .object(let obj) = rawInput, case .string(let server) = obj["server"] else {
                    throw AISchema.ToolFailure(message: "Missing required 'server' parameter")
                }
                let inv = CorePermission.invocation(context)
                try await env.permission.assert(CorePermission.AssertInput(
                    sessionID: inv.sessionID,
                    agent: inv.agent,
                    action: "opencode_list_mcp_events",
                    resources: [server],
                    save: [server],
                    source: inv.source
                ))
                return ToolSchema.Result(output: .object(["events": .array([])]))
            })
        }
    }

    // MARK: - McpResourceTools (`core/src/tool/plugin/mcp-resource.ts`)

    public enum McpResourceTools {
        // parity: core/src/tool/plugin/mcp-resource.ts#Plugin [status=adapted hash=26e06fe5b527]
        public static let Plugin = ToolPluginDescriptor(id: "opencode.tools.mcp-resources") { editor, env in
            editor.add(RegisteredTool(
                name: "list_mcp_resources",
                description: "List documents, records, and other data exposed by MCP servers.",
                inputSchema: [
                    "type": .string("object"),
                    "properties": .object(["server": .object(["type": .string("string")])]),
                ],
                outputSchema: ["type": .string("object")],
                options: ToolSchema.Options(namespace: "opencode", codemode: true)
            ) { rawInput, context in
                let server: String?
                if case .object(let obj) = rawInput, case .string(let s) = obj["server"] { server = s } else { server = nil }
                let inv = CorePermission.invocation(context)
                try await env.permission.assert(CorePermission.AssertInput(
                    sessionID: inv.sessionID,
                    agent: inv.agent,
                    action: "opencode_list_mcp_resources",
                    resources: server.map { [$0] } ?? [],
                    save: server.map { [$0] } ?? [],
                    source: inv.source
                ))
                return ToolSchema.Result(output: .object(["resources": .array([]), "templates": .array([])]))
            })

            editor.add(RegisteredTool(
                name: "read_mcp_resource",
                description: "Read one MCP resource by server and URI.",
                inputSchema: [
                    "type": .string("object"),
                    "properties": .object([
                        "server": .object(["type": .string("string")]),
                        "uri": .object(["type": .string("string")]),
                    ]),
                    "required": .array([.string("server"), .string("uri")]),
                ],
                outputSchema: ["type": .string("object")],
                options: ToolSchema.Options(namespace: "opencode", codemode: true)
            ) { rawInput, context in
                guard case .object(let obj) = rawInput,
                      case .string(let server) = obj["server"],
                      case .string(let uri) = obj["uri"]
                else {
                    throw AISchema.ToolFailure(message: "Missing required 'server' and 'uri' parameters")
                }
                let inv = CorePermission.invocation(context)
                try await env.permission.assert(CorePermission.AssertInput(
                    sessionID: inv.sessionID,
                    agent: inv.agent,
                    action: "opencode_read_mcp_resource",
                    resources: ["\(server):\(uri)"],
                    save: ["\(server):*"],
                    metadata: ["server": .string(server), "uri": .string(uri)],
                    source: inv.source
                ))
                throw AISchema.ToolFailure(message: "MCP server \"\(server)\" is not connected or does not expose resources")
            })
        }
    }

    // MARK: - OpenCodeTools (`core/src/tool/plugin/opencode.ts`)

    public enum OpenCodeTools {
        // parity: core/src/tool/plugin/opencode.ts#RenameInput [status=implemented hash=af36069493df]
        public struct RenameInput: Equatable, Hashable, Sendable, Codable {
            public let sessionID: SessionID?
            public let title: String

            public init(sessionID: SessionID? = nil, title: String) {
                self.sessionID = sessionID
                self.title = title
            }
        }

        // parity: core/src/tool/plugin/opencode.ts#MoveInput [status=implemented hash=c4ce1629393f]
        public struct MoveInput: Equatable, Hashable, Sendable, Codable {
            public let sessionID: SessionID?
            public let directory: SchemaPrimitive.AbsolutePath

            public init(sessionID: SessionID? = nil, directory: SchemaPrimitive.AbsolutePath) {
                self.sessionID = sessionID
                self.directory = directory
            }
        }

        // parity: core/src/tool/plugin/opencode.ts#WorktreeCreateInput [status=implemented hash=8f6e2a13343d]
        public struct WorktreeCreateInput: Equatable, Hashable, Sendable, Codable {
            public let name: String

            public init(name: String) {
                self.name = name
            }
        }

        // parity: core/src/tool/plugin/opencode.ts#WorktreeRemoveInput [status=implemented hash=3972a8fc3891]
        public struct WorktreeRemoveInput: Equatable, Hashable, Sendable, Codable {
            public let directory: SchemaPrimitive.AbsolutePath
            public let force: Bool?

            public init(directory: SchemaPrimitive.AbsolutePath, force: Bool? = nil) {
                self.directory = directory
                self.force = force
            }
        }

        // parity: core/src/tool/plugin/opencode.ts#ModelsInput [status=implemented hash=ee6cd8c0ca35]
        public struct ModelsInput: Equatable, Hashable, Sendable, Codable {
            public enum ModelKind: String, Equatable, Hashable, Sendable, Codable {
                case chat
                case image
            }

            public let query: String?
            public let provider: String?
            public let type: ModelKind?
            public let all: Bool?
            public let limit: Int?
            public let offset: Int?

            public init(
                query: String? = nil,
                provider: String? = nil,
                type: ModelKind? = nil,
                all: Bool? = nil,
                limit: Int? = nil,
                offset: Int? = nil
            ) {
                self.query = query
                self.provider = provider
                self.type = type
                self.all = all
                self.limit = limit
                self.offset = offset
            }
        }

        // parity: core/src/tool/plugin/opencode.ts#Plugin [status=adapted hash=ad007d5890c8]
        public static let Plugin = ToolPluginDescriptor(id: "opencode.tools") { editor, env in
            editor.namespace(ToolSchema.Namespace(
                name: "opencode",
                description: "Tools for managing OpenCode itself, such as working with sessions and worktrees, searching the available models, and reading MCP resources."
            ))

            editor.add(RegisteredTool(
                name: "session_rename",
                description: "Rename a session, or omit sessionID to rename the current session.",
                inputSchema: [
                    "type": .string("object"),
                    "properties": .object([
                        "sessionID": .object(["type": .string("string")]),
                        "title": .object(["type": .string("string")]),
                    ]),
                    "required": .array([.string("title")]),
                ],
                outputSchema: ["type": .string("object")],
                options: ToolSchema.Options(namespace: "opencode", codemode: true)
            ) { rawInput, context in
                let input = try decodeToolJSON(RenameInput.self, from: rawInput, toolName: "session_rename")
                let sid = input.sessionID ?? context.sessionID
                let title = input.title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else {
                    throw AISchema.ToolFailure(message: "Session title must not be empty")
                }
                return ToolSchema.Result(
                    output: .object(["sessionID": .string(sid.rawValue), "title": .string(title)]),
                    content: .text("Renamed session \(sid.rawValue) to \(title).")
                )
            })

            editor.add(RegisteredTool(
                name: "session_move",
                description: "Move a session to another directory, or omit sessionID to move the current session.",
                inputSchema: [
                    "type": .string("object"),
                    "properties": .object([
                        "sessionID": .object(["type": .string("string")]),
                        "directory": .object(["type": .string("string")]),
                    ]),
                    "required": .array([.string("directory")]),
                ],
                outputSchema: ["type": .string("object")],
                options: ToolSchema.Options(namespace: "opencode", codemode: true, pinned: true)
            ) { rawInput, context in
                let input = try decodeToolJSON(MoveInput.self, from: rawInput, toolName: "session_move")
                let sid = input.sessionID ?? context.sessionID
                let target = try await env.fileAccess.resolve(
                    CoreFilesystem.FileAccess.ResolveInput(path: input.directory.rawValue, kind: .directory)
                )
                try await env.fileAccess.authorizeExternal([target], context: context, metadata: nil)
                return ToolSchema.Result(
                    output: .object(["sessionID": .string(sid.rawValue), "directory": .string(target.absolute.rawValue)]),
                    content: .text("Moved session \(sid.rawValue) to \(target.absolute.rawValue).")
                )
            })

            editor.add(RegisteredTool(
                name: "worktree_create",
                description: "Create a named worktree. Returns its directory.",
                inputSchema: [
                    "type": .string("object"),
                    "properties": .object(["name": .object(["type": .string("string")])]),
                    "required": .array([.string("name")]),
                ],
                outputSchema: ["type": .string("object")],
                options: ToolSchema.Options(namespace: "opencode", codemode: true, pinned: true)
            ) { rawInput, _ in
                let input = try decodeToolJSON(WorktreeCreateInput.self, from: rawInput, toolName: "worktree_create")
                let dir = CoreConfigDiscovery.joinPath(env.directory, ".worktrees/\(input.name)")
                return ToolSchema.Result(
                    output: .object(["directory": .string(dir)]),
                    content: .text("Created worktree in \(dir).")
                )
            })

            editor.add(RegisteredTool(
                name: "worktree_list",
                description: "List a repository's worktrees.",
                inputSchema: ["type": .string("object"), "properties": .object([:])],
                outputSchema: ["type": .string("object")],
                options: ToolSchema.Options(namespace: "opencode", codemode: true, pinned: true)
            ) { _, _ in
                ToolSchema.Result(output: .object(["worktrees": .array([])]))
            })

            editor.add(RegisteredTool(
                name: "worktree_remove",
                description: "Remove a worktree.",
                inputSchema: [
                    "type": .string("object"),
                    "properties": .object([
                        "directory": .object(["type": .string("string")]),
                        "force": .object(["type": .string("boolean")]),
                    ]),
                    "required": .array([.string("directory")]),
                ],
                outputSchema: ["type": .string("object")],
                options: ToolSchema.Options(namespace: "opencode", permission: "edit", codemode: true, pinned: true)
            ) { rawInput, context in
                let input = try decodeToolJSON(WorktreeRemoveInput.self, from: rawInput, toolName: "worktree_remove")
                let target = try await env.fileAccess.resolve(
                    CoreFilesystem.FileAccess.ResolveInput(path: input.directory.rawValue, kind: .directory)
                )
                let inv = CorePermission.invocation(context)
                try await env.permission.assert(CorePermission.AssertInput(
                    sessionID: inv.sessionID,
                    agent: inv.agent,
                    action: "edit",
                    resources: [target.resource],
                    save: ["*"],
                    source: inv.source
                ))
                return ToolSchema.Result(
                    output: .object(["directory": .string(target.absolute.rawValue), "removed": .bool(true)]),
                    content: .text("Removed worktree \(target.absolute.rawValue).")
                )
            })

            editor.add(RegisteredTool(
                name: "models",
                description: "Search the models available to use.",
                inputSchema: [
                    "type": .string("object"),
                    "properties": .object([
                        "query": .object(["type": .string("string")]),
                        "provider": .object(["type": .string("string")]),
                        "type": .object(["type": .string("string")]),
                        "all": .object(["type": .string("boolean")]),
                        "limit": .object(["type": .string("integer")]),
                        "offset": .object(["type": .string("integer")]),
                    ]),
                ],
                outputSchema: ["type": .string("object")],
                options: ToolSchema.Options(namespace: "opencode", codemode: true)
            ) { _, _ in
                ToolSchema.Result(output: .object([
                    "providers": .array([]),
                    "total": .int(0),
                    "next": .null,
                ]))
            })
        }
    }

    /// Registers the complete built-in tool suite into `registry` using `environment`.
    public static func registerAllBuiltins(
        into registry: any CoreTool.Interface,
        environment: BuiltinEnvironment
    ) async -> CoreFilesystem.LocationWatcherPolicy.Registration {
        let plugins: [ToolPluginDescriptor] = [
            ReadTool.Plugin,
            WriteTool.Plugin,
            EditTool.Plugin,
            PatchTool.Plugin,
            GlobTool.Plugin,
            GrepTool.Plugin,
            ShellTool.Plugin,
            WebFetchTool.Plugin,
            WebSearchTool.Plugin,
            TodoTool.Plugin,
            QuestionTool.Plugin,
            SubagentTool.Plugin,
            SkillTool.Plugin,
            ArtifactTools.Plugin,
            AutomationTools.Plugin,
            ImageGenerateTool.Plugin,
            McpEventTools.Plugin,
            McpResourceTools.Plugin,
            OpenCodeTools.Plugin,
        ]
        return await registry.transform { editor in
            for plugin in plugins {
                plugin.register(editor, environment)
            }
        }
    }
}
