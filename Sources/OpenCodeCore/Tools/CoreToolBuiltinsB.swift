#if canImport(Foundation)
import Foundation
#elseif canImport(FoundationEssentials)
import FoundationEssentials
#endif
import OpenCodeAI
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

// MARK: - Built-In Core Tools Part B (webfetch, websearch, todo, question, subagent, skill, artifact, automation, image-generate, mcp-events, mcp-resource, opencode)

extension CoreTool {

    // MARK: - WebFetchTool (`core/src/tool/plugin/webfetch.ts`)

    public enum WebFetchTool {
        // parity: core/src/tool/plugin/webfetch.ts#convertHTMLToMarkdown [status=implemented hash=04571e154c5a]
        public static func convertHTMLToMarkdown(_ html: String) -> String {
            CoreToolOutput.HTMLMarkdown.convertHTMLToMarkdown(html)
        }

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

        // parity: core/src/tool/plugin/webfetch.ts#Input [status=implemented hash=87c87465fb64]
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

        // parity: core/src/tool/plugin/webfetch.ts#Plugin [status=adapted hash=474eddeeb5f4]
        public static let Plugin = ToolPluginDescriptor(id: "opencode.tool.webfetch") { editor, env in
            // Registered whatever full_codemode says; `ModelPolicy.modelTools` hides it under full Code Mode, whose
            // programs fetch through their `fetch` global.
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

        // parity: core/src/tool/plugin/websearch.ts#Input [status=implemented hash=5d2c31906901]
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
                let published = hit.time.published.map {
                    "\nPublished: \(CoreTool.formatToolISO8601UTC(epochMillis: Int64($0)))"
                } ?? ""
                let body = hit.content.map { "\n\n\($0)" } ?? ""
                return "## [\(title)](\(hit.url))\(published)\(body)"
            }.joined(separator: "\n\n")
        }

        // parity: core/src/tool/plugin/websearch.ts#Plugin [status=adapted hash=d3c1c18eb929]
        public static let Plugin = ToolPluginDescriptor(id: "opencode.tool.websearch") { editor, env in
            // Whether a model is offered this tool (no provider, or search disabled) is `ModelPolicy.modelTools` with
            // `WebSearch.available()`, not a session hook.
            editor.add(RegisteredTool(
                name: name,
                description: description,
                inputSchema: inputSchema,
                outputSchema: ["type": .string("array")],
                options: ToolSchema.Options(codemode: env.fullCodeMode)
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

                guard let webSearch = env.webSearch else {
                    throw AISchema.ToolFailure(message: "Web search service is not configured")
                }

                let response: WebSearchSchema.Response
                do {
                    response = try await webSearch.query(
                        WebSearchSchema.Input(query: input.query),
                        sessionID: context.sessionID
                    )
                } catch is CoreIntegration.WebSearch.ProviderRequiredError {
                    guard let form = env.form else {
                        throw AISchema.ToolFailure(message: "Unable to search the web for \(input.query): no web search provider is configured")
                    }
                    let providers = await webSearch.providers()
                    guard !providers.isEmpty else {
                        throw AISchema.ToolFailure(message: "Unable to search the web for \(input.query): no web search provider is available")
                    }
                    let choiceFields = FormSchema.Fields(first: .string(FormSchema.StringField(
                        key: "choice",
                        description: "Allow OpenCode to search the web for up-to-date information?",
                        required: true,
                        options: [
                            FormSchema.Option(
                                value: "allow",
                                label: "Allow search via \(providers.map(\.name).joined(separator: ", "))"
                            ),
                            FormSchema.Option(value: "choose", label: "Choose another provider"),
                            FormSchema.Option(value: "disable", label: "Disable web search"),
                        ],
                        custom: false
                    )))
                    let decision = try await form.ask(CoreIntegration.Form.CreateInput(
                        sessionID: context.sessionID.rawValue,
                        title: "Web Search",
                        metadata: ["kind": .string("websearch.provider")],
                        fields: choiceFields
                    ))
                    guard case .answered(let answer) = decision, case .string(let choice) = answer["choice"] else {
                        throw AISchema.ToolFailure(message: "Web search cancelled")
                    }
                    if choice == "disable" {
                        try? await webSearch.select(.disabled)
                        throw AISchema.ToolFailure(message: "Web search is disabled")
                    }
                    var selectedID: WebSearchSchema.ID? = nil
                    if choice == "choose" {
                        let providerFields = FormSchema.Fields(first: .string(FormSchema.StringField(
                            key: "provider",
                            description: "Choose a provider for web search.",
                            required: true,
                            options: providers.map { FormSchema.Option(value: $0.id.rawValue, label: $0.name) },
                            custom: false
                        )))
                        let pick = try await form.ask(CoreIntegration.Form.CreateInput(
                            sessionID: context.sessionID.rawValue,
                            title: "Choose a web search provider",
                            metadata: ["kind": .string("websearch.provider")],
                            fields: providerFields
                        ))
                        guard case .answered(let pickAns) = pick, case .string(let picked) = pickAns["provider"],
                              let matched = providers.first(where: { $0.id.rawValue == picked })
                        else {
                            throw AISchema.ToolFailure(message: "Web search cancelled")
                        }
                        try await webSearch.select(.provider(matched.id))
                        selectedID = matched.id
                    } else {
                        try await webSearch.select(.random)
                    }
                    do {
                        response = try await webSearch.query(
                            WebSearchSchema.Input(query: input.query, providerID: selectedID),
                            sessionID: context.sessionID
                        )
                    } catch let err as CoreIntegration.WebSearch.RequestError {
                        throw AISchema.ToolFailure(message: err.description)
                    } catch {
                        throw AISchema.ToolFailure(message: "Unable to search the web for \(input.query): \(error)")
                    }
                } catch is CoreIntegration.WebSearch.DisabledError {
                    throw AISchema.ToolFailure(message: "Web search is disabled")
                } catch let err as CoreIntegration.WebSearch.RequestError {
                    throw AISchema.ToolFailure(message: err.description)
                } catch let err as CorePermission.DeclinedError {
                    throw err
                } catch let err as AISchema.ToolFailure {
                    throw err
                } catch {
                    throw AISchema.ToolFailure(message: "Unable to search the web for \(input.query): \(error)")
                }

                await context.progress(["provider": .string(response.providerID.rawValue)])
                let outputItems: [JSONValue] = response.results.map { hit in
                    var obj: [String: JSONValue] = ["url": .string(hit.url)]
                    if let title = hit.title { obj["title"] = .string(title) }
                    if let content = hit.content { obj["content"] = .string(content) }
                    if let published = hit.time.published { obj["published"] = .double(published) }
                    return .object(obj)
                }
                return ToolSchema.Result(
                    output: .array(outputItems),
                    content: .text(formatResults(response)),
                    metadata: ["provider": .string(response.providerID.rawValue)]
                )
            })
        }
    }

    // MARK: - TodoTool (`core/src/tool/plugin/todo.ts`)

    public enum TodoTool {
        // parity: core/src/tool/plugin/todo.ts#name [status=implemented hash=85c0d95a46d3]
        public static let name: String = "todowrite"

        // parity: core/src/tool/plugin/todo.ts#Info [status=implemented hash=c38cd86f2e01]
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

        // parity: core/src/tool/plugin/todo.ts#Input [status=implemented hash=701cbc444c22]
        public struct Input: Equatable, Hashable, Sendable, Codable {
            public let todos: [Info]

            public init(todos: [Info]) {
                self.todos = todos
            }
        }

        // parity: core/src/tool/plugin/todo.ts#Output [status=implemented hash=4efeb6bdb587]
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

        // parity: core/src/tool/plugin/question.ts#Input [status=implemented hash=1556f5615115]
        public struct Input: Equatable, Hashable, Sendable, Codable {
            public let questions: [QuestionSchema.Prompt]

            public init(questions: [QuestionSchema.Prompt]) {
                self.questions = questions
            }
        }

        // parity: core/src/tool/plugin/question.ts#Output [status=implemented hash=ba0a42c51d75]
        public struct Output: Equatable, Hashable, Sendable, Codable {
            public let answers: [QuestionSchema.Answer]

            public init(answers: [QuestionSchema.Answer]) {
                self.answers = answers
            }
        }

        // parity: core/src/tool/plugin/question.ts#CancelledError [status=implemented hash=df815d778c94]
        public struct CancelledError: Swift.Error, Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
            public static let tag = "QuestionTool.CancelledError"
            public init() {}
            // parity: core/src/tool/plugin/question.ts#CancelledError.message [status=implemented hash=7eebb160f569]
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
                guard !input.questions.isEmpty else {
                    throw AISchema.ToolFailure(message: "At least one question is required")
                }
                let inv = CorePermission.invocation(context)
                do {
                    try await env.permission.assert(CorePermission.AssertInput(
                        sessionID: inv.sessionID,
                        agent: inv.agent,
                        action: name,
                        resources: ["*"],
                        source: inv.source
                    ))
                } catch let err as CorePermission.DeclinedError {
                    throw err
                } catch {
                    throw AISchema.ToolFailure(message: "Permission denied: question")
                }

                guard let form = env.form else {
                    throw AISchema.ToolFailure(message: "Form service is not configured")
                }

                let fieldsArray: [FormSchema.Field] = input.questions.enumerated().map { idx, q in
                    let opts = q.options.map {
                        FormSchema.Option(value: $0.label, label: $0.label, description: $0.description)
                    }
                    if q.multiple == true {
                        return .multiselect(FormSchema.MultiselectField(
                            key: "q\(idx)",
                            title: q.header,
                            description: q.question,
                            options: opts,
                            custom: true
                        ))
                    } else {
                        return .string(FormSchema.StringField(
                            key: "q\(idx)",
                            title: q.header,
                            description: q.question,
                            options: opts,
                            custom: true
                        ))
                    }
                }
                guard let formFields = FormSchema.Fields(fieldsArray) else {
                    throw AISchema.ToolFailure(message: "At least one question is required")
                }

                let terminal = try await form.ask(CoreIntegration.Form.CreateInput(
                    sessionID: context.sessionID.rawValue,
                    title: "Questions",
                    metadata: [
                        "kind": .string("question"),
                        "tool": .object([
                            "messageID": .string(context.messageID),
                            "id": .string(context.id.rawValue),
                        ]),
                    ],
                    fields: formFields
                ))

                switch terminal {
                case .cancelled(let message):
                    if let message {
                        throw AISchema.ToolFailure(message: message)
                    }
                    throw CancelledError()
                case .answered(let answerMap):
                    let answers: [QuestionSchema.Answer] = input.questions.indices.map { idx in
                        guard let value = answerMap["q\(idx)"] else { return [] }
                        switch value {
                        case .string(let s): return [s]
                        case .strings(let arr): return arr
                        case .number(let n): return [String(n)]
                        case .bool(let b): return [b ? "true" : "false"]
                        }
                    }
                    let out = Output(answers: answers)
                    return ToolSchema.Result(
                        output: encodeToolJSON(out),
                        content: .text(toModelContent(questions: input.questions, answers: answers)),
                        metadata: ["answers": encodeToolJSON(answers, fallback: .array([]))]
                    )
                }
            })
        }
    }

    // MARK: - SubagentTool (`core/src/tool/plugin/subagent.ts`)

    public enum SubagentTool {
        // parity: core/src/tool/plugin/subagent.ts#name [status=implemented hash=1514a97a53f8]
        public static let name: String = "subagent"

        // parity: core/src/tool/plugin/subagent.ts#description [status=implemented hash=894e80feb010]
        public static let description: String = [
            "Spawns an agent in a child session to work on the specified task.",
            "Subagents always run in the background: the call returns immediately with a sessionID, and you receive a `<background-result kind=\"subagent\">` message each time the child goes idle, including after later work.",
            "Keep working on non-overlapping tasks, or briefly tell the user what you launched and end your response. Do not sleep, poll, or proactively check on the child's progress.",
            "New child sessions start with fresh context, so include all relevant context and instructions when you don't pass a sessionID.",
            "Pass the returned sessionID to continue that specific child conversation. A follow-up to a running child joins its current run.",
        ].joined(separator: "\n")

        // parity: core/src/tool/plugin/subagent.ts#Input [status=implemented hash=1a257b27bb1b]
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

        // parity: core/src/tool/plugin/subagent.ts#Output [status=implemented hash=f0cb2f14c927]
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

        // parity: core/src/tool/plugin/subagent.ts#Plugin [status=adapted hash=fc197ee730ed]
        public static let Plugin = ToolPluginDescriptor(id: "opencode.tool.subagent") { editor, env in
            editor.add(RegisteredTool(
                name: name,
                description: description,
                inputSchema: inputSchema,
                outputSchema: ["type": .string("object")],
                options: ToolSchema.Options(codemode: false)
            ) { rawInput, context in
                let input = try decodeToolJSON(Input.self, from: rawInput, toolName: name)
                guard let sessionService = env.session else {
                    throw AISchema.ToolFailure(message: "Session service is not configured")
                }

                let parent: SessionSchema.Info
                do {
                    parent = try sessionService.get(context.sessionID)
                } catch {
                    throw AISchema.ToolFailure(message: "Parent session not found: \(context.sessionID.rawValue)")
                }

                let resolvedAgentID: String
                var agentDefaultModel: SessionSchema.ModelRef? = nil
                if let agentService = env.agent {
                    guard let agentInfo = await agentService.resolve(input.agent) else {
                        throw AISchema.ToolFailure(message: "Unknown agent: \(input.agent)")
                    }
                    if agentInfo.mode == .primary {
                        throw AISchema.ToolFailure(message: "Agent \(input.agent) cannot run as a subagent")
                    }
                    resolvedAgentID = agentInfo.id.rawValue
                    if let m = agentInfo.model {
                        agentDefaultModel = SessionSchema.ModelRef(
                            id: m.id.rawValue,
                            providerID: m.providerID.rawValue,
                            variant: m.variant?.rawValue
                        )
                    }
                } else {
                    resolvedAgentID = input.agent
                }

                let inv = CorePermission.invocation(context)
                try await env.permission.assert(CorePermission.AssertInput(
                    sessionID: inv.sessionID,
                    agent: inv.agent,
                    action: name,
                    resources: [resolvedAgentID],
                    save: [resolvedAgentID],
                    source: inv.source
                ))

                let existing: SessionSchema.Info?
                if let requestedID = input.sessionID {
                    let found: SessionSchema.Info
                    do {
                        found = try sessionService.get(requestedID)
                    } catch {
                        throw AISchema.ToolFailure(message: "Subagent session not found: \(requestedID.rawValue)")
                    }
                    guard found.parentID == context.sessionID else {
                        throw AISchema.ToolFailure(message: "Session \(found.id.rawValue) is not a child of the current session")
                    }
                    existing = found
                } else {
                    existing = nil
                }

                var modelOverride: SessionSchema.ModelRef? = nil
                if let modelStr = input.model, !modelStr.isEmpty {
                    let ref: ModelSchema.Ref
                    do {
                        ref = try ModelSchema.Ref.parse(modelStr)
                    } catch {
                        throw AISchema.ToolFailure(
                            message: "Invalid model \"\(modelStr)\". Use \"providerID/modelID\" or \"providerID/modelID#variant\"."
                        )
                    }
                    if let modelService = env.model {
                        let availableChat = (try? await modelService.available(types: nil)) ?? []
                        guard let matched = availableChat.first(where: { $0.providerID == ref.providerID && $0.id == ref.id }) else {
                            let other = ((try? await modelService.available(types: [.image, .video, .decision])) ?? [])
                                .first(where: { $0.providerID == ref.providerID && $0.id == ref.id })
                            if let other {
                                let kind = other.type == .image ? "an image" : other.type == .video ? "a video" : "a decision"
                                throw AISchema.ToolFailure(
                                    message: "Model \"\(ref.providerID.rawValue)/\(ref.id.rawValue)\" is \(kind) model; subagents need a chat model. Use the models tool to find one."
                                )
                            }
                            throw AISchema.ToolFailure(
                                message: "Model \"\(ref.providerID.rawValue)/\(ref.id.rawValue)\" is not available. Use the models tool to see what is available."
                            )
                        }
                        if let variant = ref.variant, !matched.variants.contains(where: { $0.id == variant }) {
                            if matched.variants.isEmpty {
                                throw AISchema.ToolFailure(
                                    message: "Model \"\(ref.providerID.rawValue)/\(ref.id.rawValue)\" has no variants. Omit the variant."
                                )
                            }
                            throw AISchema.ToolFailure(
                                message: "Variant \"\(variant.rawValue)\" is not available for \"\(ref.providerID.rawValue)/\(ref.id.rawValue)\". Available: \(matched.variants.map(\.id.rawValue).joined(separator: ", "))."
                            )
                        }
                    }
                    modelOverride = SessionSchema.ModelRef(
                        id: ref.id.rawValue,
                        providerID: ref.providerID.rawValue,
                        variant: ref.variant?.rawValue
                    )
                }

                let child: SessionSchema.Info
                if let existing {
                    let switched = existing.agent != resolvedAgentID
                    let nextModel = modelOverride ?? (switched ? agentDefaultModel : nil)
                    do {
                        if switched {
                            try await sessionService.selectAgent(sessionID: existing.id, agent: resolvedAgentID)
                        }
                        if let nextModel {
                            try await sessionService.selectModel(sessionID: existing.id, model: nextModel)
                        }
                    } catch {
                        throw AISchema.ToolFailure(message: "Failed to switch subagent session: \(existing.id.rawValue)")
                    }
                    child = (try? sessionService.get(existing.id)) ?? existing
                } else {
                    do {
                        child = try await sessionService.create(CoreSession.CreateInput(
                            parentID: context.sessionID,
                            title: input.description,
                            agent: resolvedAgentID,
                            model: modelOverride ?? agentDefaultModel ?? parent.model
                        ))
                    } catch {
                        throw AISchema.ToolFailure(message: "Failed to create subagent session: \(error)")
                    }
                }

                await context.progress(["sessionID": .string(child.id.rawValue), "status": .string("running")])

                let promptText = existing == nil
                    ? "You are a subagent spawned by another session.\n\(input.prompt)"
                    : input.prompt
                do {
                    _ = try await sessionService.prompt(CoreSession.PromptRequest(
                        sessionID: child.id,
                        input: CoreSessionPrompt.Input(text: promptText)
                    ))
                } catch {
                    throw AISchema.ToolFailure(message: "Failed to prompt subagent: \(child.id.rawValue): \(error)")
                }

                let msg = [
                    "The subagent is working in the background (sessionID: \(child.id.rawValue)). You will receive a <background-result kind=\"subagent\"> message when it goes idle, and again after each later round of work.",
                    "DO NOT sleep, poll, proactively check on its progress, or duplicate this subagent's work.",
                    "Work on non-overlapping tasks, or briefly tell the user what you launched and end your response.",
                    "To send it follow-ups or change its instructions while it runs, call subagent again with this sessionID.",
                ].joined(separator: "\n")
                let out = Output(sessionID: child.id, status: "running", output: msg)
                return ToolSchema.Result(
                    output: encodeToolJSON(out),
                    content: .text(msg),
                    metadata: ["sessionID": .string(child.id.rawValue), "status": .string("running")]
                )
            })
        }
    }

    // MARK: - SkillTool (`core/src/tool/plugin/skill.ts`)

    public enum SkillTool {
        // parity: core/src/tool/plugin/skill.ts#name [status=implemented hash=60c5a1ea6cbd]
        public static let name: String = "skill"

        // parity: core/src/tool/plugin/skill.ts#description [status=implemented hash=2462f767ec89]
        public static let description: String = [
            "Load a specialized skill's instructions and resources into the current conversation when the task at hand matches its description.",
            "",
            "The skill ID must match an available skill or a skill explicitly referenced by the user.",
        ].joined(separator: "\n")

        // parity: core/src/tool/plugin/skill.ts#Input [status=implemented hash=697bb97d5a7c]
        public struct Input: Equatable, Hashable, Sendable, Codable {
            public let id: SkillSchema.ID

            public init(id: SkillSchema.ID) {
                self.id = id
            }
        }

        // parity: core/src/tool/plugin/skill.ts#Output [status=implemented hash=4ce560995419]
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
                guard let skillService = env.skill else {
                    throw AISchema.ToolFailure(message: "Skill service is not configured")
                }
                guard let skill = await skillService.get(input.id) else {
                    throw AISchema.ToolFailure(message: "Unable to load skill \(input.id.rawValue)")
                }
                let inv = CorePermission.invocation(context)
                do {
                    try await env.permission.assert(CorePermission.AssertInput(
                        sessionID: inv.sessionID,
                        agent: inv.agent,
                        action: name,
                        resources: [skill.id.rawValue],
                        save: [skill.id.rawValue],
                        source: inv.source
                    ))
                } catch let err as CorePermission.DeclinedError {
                    throw err
                } catch {
                    throw AISchema.ToolFailure(message: "Unable to load skill \(input.id.rawValue)")
                }

                let virtualFiles = await skillService.files(skill.id)
                let fsUtil = FSUtil.Service(fileSystem: env.fileSystem)
                let prepared = await CoreSkill.prepare(fs: fsUtil, skill: skill, virtualFiles: virtualFiles)
                let out = Output(directory: prepared.directory, content: prepared.output)
                return ToolSchema.Result(
                    output: encodeToolJSON(out),
                    content: .text(prepared.output),
                    metadata: [
                        "name": .string(skill.name.rawValue),
                        "directory": .string(prepared.directory),
                    ]
                )
            })
        }
    }

    // MARK: - ArtifactTools (`core/src/tool/plugin/artifact.ts`)

    public enum ArtifactTools {
        // parity: core/src/tool/plugin/artifact.ts#CreateToolInput [status=implemented hash=9cf2f78f9288]
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

        // parity: core/src/tool/plugin/artifact.ts#ReadToolInput [status=implemented hash=2a459cfd8139]
        public struct ReadToolInput: Equatable, Hashable, Sendable, Codable {
            public let id: ArtifactSchema.ID

            public init(id: ArtifactSchema.ID) {
                self.id = id
            }
        }

        // parity: core/src/tool/plugin/artifact.ts#UpdateToolInput [status=implemented hash=332058ea469f]
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

        // parity: core/src/tool/plugin/artifact.ts#DeleteToolInput [status=implemented hash=307072d13935]
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
        // parity: core/src/tool/plugin/automation.ts#View [status=implemented hash=a0ba3b93a6b8]
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

        // parity: core/src/tool/plugin/automation.ts#IDInput [status=implemented hash=99237fcbd627]
        public struct IDInput: Equatable, Hashable, Sendable, Codable {
            public let id: AutomationSchema.ID

            public init(id: AutomationSchema.ID) {
                self.id = id
            }
        }

        private static func toView(_ info: AutomationSchema.Info) -> View {
            View(
                id: info.id,
                name: info.name,
                trigger: info.trigger,
                tz: info.tz,
                action: info.action,
                status: info.status,
                nextDueAt: info.nextDueAt.map { CoreTool.formatToolISO8601UTC(epochMillis: Int64($0.epochMillis)) },
                expires: info.expires.map { CoreTool.formatToolISO8601UTC(epochMillis: Int64($0.epochMillis)) },
                runCount: info.runCount.rawValue,
                lastRunAt: info.lastRunAt.map { CoreTool.formatToolISO8601UTC(epochMillis: Int64($0.epochMillis)) },
                lastOutcome: info.lastOutcome,
                lastOutput: info.lastOutput,
                state: info.state
            )
        }

        private static func clip(_ text: String) -> String {
            text.count > 80 ? "\(text.prefix(79))…" : text
        }

        private static func summary(_ view: View) -> String {
            let triggerStr: String
            switch view.trigger {
            case .at(let a): triggerStr = "at \(a.at)"
            case .every(let e): triggerStr = "every \(e.every)"
            case .cron(let c): triggerStr = "cron \"\(c.cron)\""
            case .event(let ev): triggerStr = "on \(ev.server) \(ev.event)"
            }
            let actionStr: String
            switch view.action {
            case .prompt(let p):
                let targetDesc: String
                switch p.to {
                case .session(let sid): targetDesc = sid.rawValue
                case .subagent(let agent): targetDesc = "subagent \(agent.rawValue)"
                }
                actionStr = "prompt \(targetDesc): \"\(CoreConfigJSONC.encodeJSONStringContents(clip(p.prompt)))\""
            case .code(let c):
                let firstLine = c.code.split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .first(where: { !$0.isEmpty }) ?? ""
                actionStr = "code: \"\(CoreConfigJSONC.encodeJSONStringContents(clip(firstLine)))\""
            }
            var parts = ["\(view.id.rawValue) \"\(view.name)\": \(triggerStr) (\(view.tz))", view.status.rawValue]
            if let next = view.nextDueAt { parts.append("next \(next)") }
            if let exp = view.expires { parts.append("expires \(exp)") }
            parts.append(actionStr)
            if let out = view.lastOutput {
                parts.append("output: \"\(CoreConfigJSONC.encodeJSONStringContents(clip(out)))\"")
            }
            return parts.joined(separator: ", ")
        }

        private static func resolveCaller(
            env: BuiltinEnvironment,
            automations: any CoreAutomation.Interface,
            context: ToolSchema.Context
        ) async throws -> (projectID: ProjectID, directory: String) {
            let projectID: ProjectID
            let directory: String
            if let session = try? env.session?.get(context.sessionID) {
                projectID = session.projectID
                directory = session.location.directory
            } else if let session = try? env.sessionStore?.get(context.sessionID) {
                projectID = session.projectID
                directory = session.location.directory
            } else {
                projectID = env.projectID
                directory = env.directory
            }
            let enabled = await automations.enabled(directory: directory)
            guard enabled else {
                throw AISchema.ToolFailure(message: CoreAutomation.DisabledError().message)
            }
            return (projectID, directory)
        }

        private static func requireOwned(
            id: AutomationSchema.ID,
            automations: any CoreAutomation.Interface,
            projectID: ProjectID
        ) async throws -> AutomationSchema.Info {
            let info = try await automations.get(id)
            guard info.projectID == projectID else {
                throw CoreAutomation.NotFoundError(automationID: id)
            }
            return info
        }

        // parity: core/src/tool/plugin/automation.ts#Plugin [status=adapted hash=d7c6fac31ebf]
        public static let Plugin = ToolPluginDescriptor(id: "opencode.tool.automation") { editor, env in
            editor.add(RegisteredTool(
                name: "automation_create",
                description: "Run a prompt or Code Mode action on a timer or a connected MCP server's push event.",
                inputSchema: [
                    "type": .string("object"),
                    "properties": .object([
                        "name": .object(["type": .string("string")]),
                        "trigger": .object(["type": .string("object")]),
                        "action": .object(["type": .string("object")]),
                        "expires": .object(["type": .string("string")]),
                    ]),
                    "required": .array([.string("name"), .string("trigger"), .string("action")]),
                ],
                outputSchema: ["type": .string("object")],
                options: ToolSchema.Options(namespace: "opencode", codemode: true)
            ) { rawInput, context in
                guard let automations = env.automation else {
                    throw AISchema.ToolFailure(message: "Automation service is not configured")
                }
                let req = try decodeToolJSON(AutomationSchema.Request.self, from: rawInput, toolName: "automation_create")
                let caller = try await resolveCaller(env: env, automations: automations, context: context)
                do {
                    let info = try await automations.create(
                        AutomationSchema.CreateInput(
                            sessionID: context.sessionID,
                            directory: caller.directory,
                            name: req.name,
                            trigger: req.trigger,
                            action: req.action,
                            expires: req.expires
                        ),
                        projectID: caller.projectID,
                        directory: caller.directory,
                        invocation: CoreAutomation.Author.Invocation(
                            sessionID: context.sessionID,
                            agent: context.agent,
                            source: CorePermission.invocation(context).source
                        )
                    )
                    let view = toView(info)
                    return ToolSchema.Result(
                        output: encodeToolJSON(view),
                        content: .text("Created: \(summary(view))")
                    )
                } catch let err as AISchema.ToolFailure {
                    throw err
                } catch {
                    throw AISchema.ToolFailure(message: String(describing: error))
                }
            })

            editor.add(RegisteredTool(
                name: "automation_list",
                description: "List this project's automations with their status and next run, and the current time.",
                inputSchema: ["type": .string("object"), "properties": .object([:])],
                outputSchema: ["type": .string("object")],
                options: ToolSchema.Options(namespace: "opencode", codemode: true)
            ) { _, context in
                guard let automations = env.automation else {
                    throw AISchema.ToolFailure(message: "Automation service is not configured")
                }
                let caller = try await resolveCaller(env: env, automations: automations, context: context)
                do {
                    let now = CoreTool.formatToolISO8601UTC(epochMillis: Flock.currentEpochMs())
                    let views = try await automations.list(CoreAutomation.ListInput(projectID: caller.projectID)).map(toView)
                    let lines = ["Now: \(now)"] + (views.isEmpty ? ["No automations."] : views.map(summary))
                    return ToolSchema.Result(
                        output: .object([
                            "now": .string(now),
                            "automations": encodeToolJSON(views, fallback: .array([])),
                        ]),
                        content: .text(lines.joined(separator: "\n"))
                    )
                } catch let err as AISchema.ToolFailure {
                    throw err
                } catch {
                    throw AISchema.ToolFailure(message: String(describing: error))
                }
            })

            editor.add(RegisteredTool(
                name: "automation_pause",
                description: "Pause an automation. It keeps its settings and does not run until resumed.",
                inputSchema: [
                    "type": .string("object"),
                    "properties": .object(["id": .object(["type": .string("string")])]),
                    "required": .array([.string("id")]),
                ],
                outputSchema: ["type": .string("object")],
                options: ToolSchema.Options(namespace: "opencode", codemode: true)
            ) { rawInput, context in
                guard let automations = env.automation else {
                    throw AISchema.ToolFailure(message: "Automation service is not configured")
                }
                let input = try decodeToolJSON(IDInput.self, from: rawInput, toolName: "automation_pause")
                let caller = try await resolveCaller(env: env, automations: automations, context: context)
                do {
                    _ = try await requireOwned(id: input.id, automations: automations, projectID: caller.projectID)
                    let info = try await automations.pause(input.id)
                    let view = toView(info)
                    return ToolSchema.Result(
                        output: encodeToolJSON(view),
                        content: .text("Paused: \(summary(view))")
                    )
                } catch let err as AISchema.ToolFailure {
                    throw err
                } catch {
                    throw AISchema.ToolFailure(message: String(describing: error))
                }
            })

            editor.add(RegisteredTool(
                name: "automation_resume",
                description: "Resume a paused automation.",
                inputSchema: [
                    "type": .string("object"),
                    "properties": .object(["id": .object(["type": .string("string")])]),
                    "required": .array([.string("id")]),
                ],
                outputSchema: ["type": .string("object")],
                options: ToolSchema.Options(namespace: "opencode", codemode: true)
            ) { rawInput, context in
                guard let automations = env.automation else {
                    throw AISchema.ToolFailure(message: "Automation service is not configured")
                }
                let input = try decodeToolJSON(IDInput.self, from: rawInput, toolName: "automation_resume")
                let caller = try await resolveCaller(env: env, automations: automations, context: context)
                do {
                    _ = try await requireOwned(id: input.id, automations: automations, projectID: caller.projectID)
                    let info = try await automations.resume(input.id)
                    let view = toView(info)
                    return ToolSchema.Result(
                        output: encodeToolJSON(view),
                        content: .text("Resumed: \(summary(view))")
                    )
                } catch let err as AISchema.ToolFailure {
                    throw err
                } catch {
                    throw AISchema.ToolFailure(message: String(describing: error))
                }
            })

            editor.add(RegisteredTool(
                name: "automation_delete",
                description: "Delete an automation for good.",
                inputSchema: [
                    "type": .string("object"),
                    "properties": .object(["id": .object(["type": .string("string")])]),
                    "required": .array([.string("id")]),
                ],
                outputSchema: ["type": .string("object")],
                options: ToolSchema.Options(namespace: "opencode", codemode: true)
            ) { rawInput, context in
                guard let automations = env.automation else {
                    throw AISchema.ToolFailure(message: "Automation service is not configured")
                }
                let input = try decodeToolJSON(IDInput.self, from: rawInput, toolName: "automation_delete")
                let caller = try await resolveCaller(env: env, automations: automations, context: context)
                do {
                    _ = try await requireOwned(id: input.id, automations: automations, projectID: caller.projectID)
                    try await automations.remove(input.id)
                    return ToolSchema.Result(
                        output: .object(["id": .string(input.id.rawValue), "removed": .bool(true)]),
                        content: .text("Deleted automation \(input.id.rawValue).")
                    )
                } catch let err as AISchema.ToolFailure {
                    throw err
                } catch {
                    throw AISchema.ToolFailure(message: String(describing: error))
                }
            })
        }
    }

    // MARK: - ImageGenerateTool (`core/src/tool/plugin/image-generate.ts`)

    public enum ImageGenerateTool {
        // parity: core/src/tool/plugin/image-generate.ts#name [status=implemented hash=370408d3f824]
        public static let name: String = "experimental_image_generate"

        // parity: core/src/tool/plugin/image-generate.ts#MAX_INPUT_BYTES [status=implemented hash=d826de23135e]
        public static let MAX_INPUT_BYTES: Int = 20 * 1024 * 1024

        // parity: core/src/tool/plugin/image-generate.ts#description [status=implemented hash=45bf1d41dd48]
        public static let description: String = [
            "Generates a new image, or edits existing ones.",
            "Only call this when the user asks you to create or edit an image. If you think an image would help but the user didn't ask for one, ask them first instead of generating it.",
            "Images you pass are used as the source to edit, or as references for style and subject.",
            "Each call makes one image. For several images, call it once per image.",
            "It runs in the background: the call starts a job and returns right away, and you are notified automatically when the image is saved, with its path. Never poll, sleep, or check for the file while you wait.",
            "Don't repeat a request unless the user asks.",
        ].joined(separator: "\n")

        // parity: core/src/tool/plugin/image-generate.ts#Input [status=implemented hash=832a27a7d442]
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

        // parity: core/src/tool/plugin/image-generate.ts#Output [status=implemented hash=3e396b59bbc0]
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
        // parity: core/src/tool/plugin/image-generate.ts#defaultModel [status=implemented hash=98958ab33082]
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

        private static let acceptedInputMimes: Set<String> = [
            "image/png", "image/jpeg", "image/webp", "image/gif",
        ]

        private static let mimeExtensions: [String: String] = [
            "image/png": ".png",
            "image/jpeg": ".jpg",
            "image/webp": ".webp",
            "image/gif": ".gif",
        ]

        private static func stripExtension(_ absolutePath: String) -> String {
            let base = CoreConfigDiscovery.basename(absolutePath)
            guard let dot = base.lastIndex(of: "."), dot != base.startIndex else {
                return absolutePath
            }
            let extLen = base.distance(from: dot, to: base.endIndex)
            return String(absolutePath.dropLast(extLen))
        }

        private static func readInputImage(
            source: String,
            env: BuiltinEnvironment,
            context: ToolSchema.Context
        ) async throws -> GenerateSchema.File {
            let bytes: [UInt8]
            let lower = source.lowercased()
            if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
                let inv = CorePermission.invocation(context)
                try await env.permission.assert(CorePermission.AssertInput(
                    sessionID: inv.sessionID,
                    agent: inv.agent,
                    action: WebFetchTool.name,
                    resources: [source],
                    save: ["*"],
                    metadata: ["url": .string(source)],
                    source: inv.source
                ))
                guard let transport = env.httpTransport else {
                    throw AISchema.ToolFailure(message: "Unable to download \(source): HTTP transport is unavailable")
                }
                let resp = try await transport.send(HTTPRequest(method: "GET", url: source, headers: [:]))
                guard (200..<300).contains(resp.head.statusCode) else {
                    throw AISchema.ToolFailure(message: "Unable to download \(source): HTTP \(resp.head.statusCode)")
                }
                bytes = try CoreToolOutput.HTTPBody.collectBoundedResponseBody(
                    response: resp,
                    maximumBytes: MAX_INPUT_BYTES,
                    tooLarge: { AISchema.ToolFailure(message: "\(source) is larger than 20 MiB.") }
                )
            } else {
                let target = try await env.fileAccess.authorizeRead(source, context: context, options: nil)
                let stat: FileStat
                do {
                    stat = try await env.fileSystem.stat(at: target.absolute.rawValue)
                } catch {
                    throw AISchema.ToolFailure(message: "File not found: \(source)")
                }
                if stat.size > Int64(MAX_INPUT_BYTES) {
                    throw AISchema.ToolFailure(message: "\(source) is larger than 20 MiB.")
                }
                bytes = try await env.fileSystem.readFile(at: target.absolute.rawValue)
            }
            guard let mime = CoreFilesystem.Mime.detectMedia(bytes), acceptedInputMimes.contains(mime) else {
                throw AISchema.ToolFailure(message: "\(source) is not a PNG, JPEG, WebP or GIF image.")
            }
            return GenerateSchema.File(
                data: bytesToBase64(bytes),
                mime: mime,
                name: CoreConfigDiscovery.basename(source)
            )
        }

        // parity: core/src/tool/plugin/image-generate.ts#Plugin [status=adapted hash=f7b8b31a99c8]
        public static let Plugin = ToolPluginDescriptor(id: "opencode.tool.image-generate") { editor, env in
            // Input images and the saved image go through the target's own environment; every target here resolves on
            // this server's environment, so that is `env.fileSystem`.
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
                guard !input.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw AISchema.ToolFailure(message: "Prompt must not be empty")
                }
                guard let generateService = env.generate else {
                    throw AISchema.ToolFailure(message: "Image generation service is not configured")
                }

                let hasImages = !(input.images?.isEmpty ?? true)
                let resolvedRef: ModelSchema.Ref
                if let explicit = input.model, !explicit.isEmpty {
                    let parsed: ModelSchema.Ref
                    do {
                        parsed = try ModelSchema.Ref.parse(explicit)
                    } catch {
                        throw AISchema.ToolFailure(
                            message: "Invalid model \"\(explicit)\". Use \"providerID/modelID\" or \"providerID/modelID#variant\"."
                        )
                    }
                    if let modelService = env.model {
                        let available = (try? await modelService.available(types: [.image])) ?? []
                        guard let matched = available.first(where: { $0.providerID == parsed.providerID && $0.id == parsed.id }) else {
                            throw AISchema.ToolFailure(
                                message: "Model \"\(parsed.providerID.rawValue)/\(parsed.id.rawValue)\" is not an available image model. Use the models tool with type: \"image\" to see what is available."
                            )
                        }
                        if let variant = parsed.variant, !matched.variants.contains(where: { $0.id == variant }) {
                            if matched.variants.isEmpty {
                                throw AISchema.ToolFailure(
                                    message: "Model \"\(parsed.providerID.rawValue)/\(parsed.id.rawValue)\" has no variants. Omit the variant."
                                )
                            }
                            throw AISchema.ToolFailure(
                                message: "Variant \"\(variant.rawValue)\" is not available for \"\(parsed.providerID.rawValue)/\(parsed.id.rawValue)\". Available: \(matched.variants.map(\.id.rawValue).joined(separator: ", "))."
                            )
                        }
                        if hasImages && !matched.capabilities.input.contains(where: { $0.hasPrefix("image") }) {
                            throw AISchema.ToolFailure(
                                message: "Model \"\(parsed.providerID.rawValue)/\(parsed.id.rawValue)\" does not accept input images."
                            )
                        }
                    }
                    resolvedRef = parsed
                } else {
                    guard let modelService = env.model else {
                        throw AISchema.ToolFailure(message: "No image model is available.")
                    }
                    let available = (try? await modelService.available(types: [.image])) ?? []
                    let sessionProvider: ProviderSchema.ID? = {
                        if let s = try? env.session?.get(context.sessionID), let pid = s.model?.providerID {
                            return ProviderSchema.ID(rawValue: pid)
                        }
                        if let s = try? env.sessionStore?.get(context.sessionID), let pid = s.model?.providerID {
                            return ProviderSchema.ID(rawValue: pid)
                        }
                        return nil
                    }()
                    guard let chosen = defaultModel(available: available, providerID: sessionProvider, images: hasImages) else {
                        throw AISchema.ToolFailure(
                            message: hasImages
                                ? "None of the available image models accept input images."
                                : "No image model is available."
                        )
                    }
                    resolvedRef = ModelSchema.Ref(id: chosen.id, providerID: chosen.providerID)
                }

                let refString = "\(resolvedRef.providerID.rawValue)/\(resolvedRef.id.rawValue)\(resolvedRef.variant.map { "#\($0.rawValue)" } ?? "")"
                let jobID = "image_\(Identifier.ascending())"
                let target: CoreFilesystem.FileAccess.Target?
                let stem: String
                if let requestedPath = input.path {
                    let t = try await env.fileAccess.resolve(
                        CoreFilesystem.FileAccess.ResolveInput(path: requestedPath, kind: .file)
                    )
                    target = t
                    stem = stripExtension(t.absolute.rawValue)
                } else {
                    target = nil
                    stem = CoreConfigDiscovery.joinPath(
                        env.globalPaths.tmp,
                        "images/\(context.sessionID.rawValue)/\(jobID)"
                    )
                }

                let inv = CorePermission.invocation(context)
                try await env.permission.assert(CorePermission.AssertInput(
                    sessionID: inv.sessionID,
                    agent: inv.agent,
                    action: name,
                    resources: [refString],
                    save: ["*"],
                    metadata: ["prompt": .string(input.prompt), "model": .string(refString)],
                    source: inv.source
                ))
                if let target {
                    try await env.fileAccess.authorizeExternal([target], context: context, metadata: nil)
                    try await env.permission.assert(CorePermission.AssertInput(
                        sessionID: inv.sessionID,
                        agent: inv.agent,
                        action: "edit",
                        resources: [target.resource],
                        save: ["*"],
                        source: inv.source
                    ))
                }

                var loadedImages: [GenerateSchema.File]? = nil
                if let paths = input.images, !paths.isEmpty {
                    var loaded: [GenerateSchema.File] = []
                    for src in paths {
                        loaded.append(try await readInputImage(source: src, env: env, context: context))
                    }
                    loadedImages = loaded
                }

                let generated: GenerateSchema.ImageResult
                do {
                    generated = try await generateService.image(GenerateSchema.ImageRequest(
                        model: resolvedRef,
                        prompt: input.prompt,
                        images: loadedImages,
                        n: SchemaPrimitive.PositiveInt(rawValue: 1)
                    ))
                } catch let err as CorePermission.DeclinedError {
                    throw err
                } catch let err as AISchema.ToolFailure {
                    throw err
                } catch {
                    throw AISchema.ToolFailure(message: "Unable to generate image: \(error)")
                }

                guard let firstImage = generated.images.first else {
                    throw AISchema.ToolFailure(message: "\(refString) returned no image.")
                }
                guard let rawData = Data(base64Encoded: firstImage.data) else {
                    throw AISchema.ToolFailure(message: "\(refString) returned invalid base64 image data.")
                }
                let bytes = Array(rawData)
                let detectedMime = CoreFilesystem.Mime.detectMedia(bytes) ?? firstImage.mime
                let ext = mimeExtensions[detectedMime] ?? ".png"
                let finalFile = stem + ext
                try await env.fileSystem.writeFile(bytes, to: finalFile, createDirectories: true)

                let out = Output(id: jobID, path: finalFile, model: refString)
                return ToolSchema.Result(
                    output: encodeToolJSON(out),
                    content: .text("Image request finished. Saved image: \(finalFile) (\(refString)).\nUse the read tool on this path to view the image."),
                    metadata: ["path": .string(finalFile), "model": .string(refString), "jobID": .string(jobID)]
                )
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
                guard let mcp = env.mcp else {
                    throw AISchema.ToolFailure(message: "MCP registry service is not configured")
                }
                do {
                    guard let events = try await mcp.events(server: server) else {
                        throw AISchema.ToolFailure(message: "MCP server \"\(server)\" is not connected or sends no events")
                    }
                    let types = try await events.list().filter { $0.delivery?.contains("push") == true }
                    let encodedEvents: [JSONValue] = types.map { type in
                        var entry: [String: JSONValue] = [
                            "server": .string(server),
                            "event": .string(type.name),
                        ]
                        if let desc = type.description { entry["description"] = .string(desc) }
                        if let args = type.inputSchema { entry["args"] = .object(args) }
                        if let data = type.payloadSchema { entry["data"] = .object(data) }
                        return .object(entry)
                    }
                    return ToolSchema.Result(output: .object(["events": .array(encodedEvents)]))
                } catch let err as CorePermission.DeclinedError {
                    throw err
                } catch let err as AISchema.ToolFailure {
                    throw err
                } catch {
                    throw AISchema.ToolFailure(message: String(describing: error))
                }
            })
        }
    }

    // MARK: - McpResourceTools (`core/src/tool/plugin/mcp-resource.ts`)

    public enum McpResourceTools {
        // parity: core/src/tool/plugin/mcp-resource.ts#Plugin [status=adapted hash=a396cee19b09]
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
                guard let mcp = env.mcp else {
                    throw AISchema.ToolFailure(message: "MCP registry service is not configured")
                }
                let serverNames: [String]
                if let server {
                    serverNames = [server]
                } else {
                    serverNames = await mcp.servers().map(\.name)
                }
                let inv = CorePermission.invocation(context)
                try await env.permission.assert(CorePermission.AssertInput(
                    sessionID: inv.sessionID,
                    agent: inv.agent,
                    action: "opencode_list_mcp_resources",
                    resources: serverNames,
                    save: serverNames,
                    source: inv.source
                ))
                do {
                    let catalog: CoreMCP.Registry.ResourceCatalog
                    if let server {
                        catalog = try await mcp.resources(server: server)
                    } else {
                        catalog = await mcp.resourceCatalog()
                    }
                    return ToolSchema.Result(output: encodeToolJSON(catalog))
                } catch let err as CorePermission.DeclinedError {
                    throw err
                } catch let err as AISchema.ToolFailure {
                    throw err
                } catch {
                    throw AISchema.ToolFailure(message: String(describing: error))
                }
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
                guard let mcp = env.mcp else {
                    throw AISchema.ToolFailure(message: "MCP registry service is not configured")
                }
                do {
                    guard let resource = try await mcp.readResource(server: server, uri: uri) else {
                        throw AISchema.ToolFailure(message: "MCP server \"\(server)\" is not connected or does not expose resources")
                    }
                    let mediaParts: [ToolSchema.Content] = resource.contents.compactMap { part in
                        guard case .blob(_, let blob, let mime?) = part,
                              CoreToolOutput.ReadFilesystem.MEDIA_MIMES.contains(mime)
                        else { return nil }
                        return .file(ToolSchema.FileContent(uri: "data:\(mime);base64,\(blob)", mime: mime))
                    }
                    return ToolSchema.Result(
                        output: encodeToolJSON(resource),
                        content: mediaParts.isEmpty ? nil : .parts(mediaParts)
                    )
                } catch let err as CorePermission.DeclinedError {
                    throw err
                } catch let err as AISchema.ToolFailure {
                    throw err
                } catch {
                    throw AISchema.ToolFailure(message: "Unable to read MCP resource \(server):\(uri): \(error)")
                }
            })
        }
    }

    // MARK: - OpenCodeTools (`core/src/tool/plugin/opencode.ts`)

    public enum OpenCodeTools {
        // parity: core/src/tool/plugin/opencode.ts#RenameInput [status=implemented hash=a7a31bcc5e8c]
        public struct RenameInput: Equatable, Hashable, Sendable, Codable {
            public let sessionID: SessionID?
            public let title: String

            public init(sessionID: SessionID? = nil, title: String) {
                self.sessionID = sessionID
                self.title = title
            }
        }

        // parity: core/src/tool/plugin/opencode.ts#MoveInput [status=implemented hash=98cec273b70c]
        public struct MoveInput: Equatable, Hashable, Sendable, Codable {
            public let sessionID: SessionID?
            public let directory: SchemaPrimitive.AbsolutePath

            public init(sessionID: SessionID? = nil, directory: SchemaPrimitive.AbsolutePath) {
                self.sessionID = sessionID
                self.directory = directory
            }
        }

        // parity: core/src/tool/plugin/opencode.ts#WorktreeCreateInput [status=implemented hash=e5a7a096889f]
        public struct WorktreeCreateInput: Equatable, Hashable, Sendable, Codable {
            public let name: String

            public init(name: String) {
                self.name = name
            }
        }

        // parity: core/src/tool/plugin/opencode.ts#WorktreeRemoveInput [status=implemented hash=8de35485013d]
        public struct WorktreeRemoveInput: Equatable, Hashable, Sendable, Codable {
            public let directory: SchemaPrimitive.AbsolutePath
            public let force: Bool?

            public init(directory: SchemaPrimitive.AbsolutePath, force: Bool? = nil) {
                self.directory = directory
                self.force = force
            }
        }

        // parity: core/src/tool/plugin/opencode.ts#ModelsInput [status=implemented hash=936a5bc06ddf]
        public struct ModelsInput: Equatable, Hashable, Sendable, Codable {
            /// "chat": a language model (LLM). "image": generates or edits images. "video": generates videos.
            public enum ModelKind: String, Equatable, Hashable, Sendable, Codable {
                case chat
                case image
                case video
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

        private static func resolveProjectID(env: BuiltinEnvironment, context: ToolSchema.Context) -> ProjectID {
            if let s = try? env.session?.get(context.sessionID) {
                return s.projectID
            }
            if let s = try? env.sessionStore?.get(context.sessionID) {
                return s.projectID
            }
            return env.projectID
        }

        private static func removeFailureMessage(directory: String, error: any Error) -> String {
            if error is CoreWorktree.Directory.DirectoryUnavailableError {
                return "Unable to remove worktree \(directory): the directory does not exist or is not a directory."
            }
            if error is CoreWorktree.InvalidDirectoryError {
                return "Unable to remove \(directory): it is not a worktree of this project. Use worktree_list to see the project's worktrees."
            }
            if let stratErr = error as? CoreWorktree.StrategyUnavailableError {
                return "Unable to remove worktree \(directory): its worktree strategy \(stratErr.strategy.rawValue) is not available."
            }
            if let opErr = error as? WorktreeSchema.OperationError, opErr.forceRequired == true {
                return "Unable to remove worktree \(directory): it has modified or untracked files."
            }
            return "Unable to remove worktree \(directory): \(error)"
        }

        /// The system note the plugin's session `context` hook adds, worded for how the model reaches `session.move`:
        /// through Code Mode's `execute`, as the direct `opencode_session_move` tool, or not at all.
        public static func sessionMoveHint(tools: Set<String>) -> String? {
            if tools.contains("execute") {
                return "When you create a worktree outside the current working directory and intend to use it as your primary working directory, consider using `execute` to call `tools.opencode.session.move` and make the worktree the session's working directory."
            }
            if tools.contains("opencode_session_move") {
                return "When you create a worktree outside the current working directory and intend to use it as your primary working directory, consider calling `opencode_session_move` to make the worktree the session's working directory."
            }
            return nil
        }

        // parity: core/src/tool/plugin/opencode.ts#Plugin [status=adapted hash=beafff62f683]
        public static let Plugin = ToolPluginDescriptor(id: "opencode.tools") { editor, env in
            editor.namespace(ToolSchema.Namespace(
                name: "opencode",
                description: "Tools for managing OpenCode itself, such as working with sessions and worktrees, searching the available models, and reading MCP resources."
            ))

            editor.add(RegisteredTool(
                name: "rename",
                description: "Rename a session, or omit sessionID to rename the current session. Use a short, specific title that summarizes the work being done.",
                inputSchema: [
                    "type": .string("object"),
                    "properties": .object([
                        "sessionID": .object(["type": .string("string")]),
                        "title": .object(["type": .string("string")]),
                    ]),
                    "required": .array([.string("title")]),
                ],
                outputSchema: ["type": .string("object")],
                options: ToolSchema.Options(namespace: "opencode.session", codemode: true)
            ) { rawInput, context in
                let input = try decodeToolJSON(RenameInput.self, from: rawInput, toolName: "opencode_session_rename")
                let sid = input.sessionID ?? context.sessionID
                let title = input.title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else {
                    throw AISchema.ToolFailure(message: "Session title must not be empty")
                }
                guard let sessionService = env.session else {
                    throw AISchema.ToolFailure(message: "Session service is not configured")
                }
                do {
                    try await sessionService.rename(sessionID: sid, title: title)
                } catch {
                    throw AISchema.ToolFailure(message: "Unable to rename session \(sid.rawValue): \(error)")
                }
                return ToolSchema.Result(
                    output: .object(["sessionID": .string(sid.rawValue), "title": .string(title)]),
                    content: .text("Renamed session \(sid.rawValue) to \(title).")
                )
            })

            editor.add(RegisteredTool(
                name: "move",
                description: "Move a session to another directory, or omit sessionID to move the current session. The current session moves at the next safe boundary; do not run destination-dependent tools in the same execute call.",
                inputSchema: [
                    "type": .string("object"),
                    "properties": .object([
                        "sessionID": .object(["type": .string("string")]),
                        "directory": .object(["type": .string("string")]),
                    ]),
                    "required": .array([.string("directory")]),
                ],
                outputSchema: ["type": .string("object")],
                options: ToolSchema.Options(namespace: "opencode.session", codemode: true, pinned: true)
            ) { rawInput, context in
                let input = try decodeToolJSON(MoveInput.self, from: rawInput, toolName: "opencode_session_move")
                let sid = input.sessionID ?? context.sessionID
                guard let sessionMove = env.sessionMove else {
                    throw AISchema.ToolFailure(message: "Session move service is not configured")
                }
                let existingSession: SessionSchema.Info
                do {
                    if let sessionService = env.session {
                        existingSession = try sessionService.get(sid)
                    } else if let store = env.sessionStore, let found = try store.get(sid) {
                        existingSession = found
                    } else if let found = try sessionMove.store.get(sid) {
                        existingSession = found
                    } else {
                        throw CoreSessionErrors.NotFoundError(sessionID: sid)
                    }
                } catch {
                    throw AISchema.ToolFailure(message: "Unable to move session to \(input.directory.rawValue): \(error)")
                }

                let trimmedDir = input.directory.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
                let expandedDir: String
                if trimmedDir == "~" {
                    expandedDir = env.globalPaths.home
                } else if trimmedDir.hasPrefix("~/") {
                    expandedDir = CoreConfigDiscovery.joinPath(env.globalPaths.home, String(trimmedDir.dropFirst(2)))
                } else {
                    expandedDir = trimmedDir
                }
                let resolvedPath = CoreFilesystem.FileAccess.resolvePath(
                    directory: existingSession.location.directory,
                    input: expandedDir
                )
                let target = try await env.fileAccess.resolve(
                    CoreFilesystem.FileAccess.ResolveInput(path: resolvedPath, kind: .directory)
                )
                var isProjectWorktree = false
                if target.externalDirectory != nil, let worktreeService = env.worktree {
                    let worktrees = (try? await worktreeService.list(projectID: existingSession.projectID)) ?? []
                    isProjectWorktree = worktrees.contains {
                        FSPathUtil.contains(parent: $0.directory.rawValue, child: target.absolute.rawValue)
                    }
                }
                if !isProjectWorktree {
                    try await env.fileAccess.authorizeExternal([target], context: context, metadata: nil)
                }

                do {
                    try await sessionMove.move(CoreSessionMove.MoveInput(
                        sessionID: sid,
                        directory: target.absolute.rawValue
                    ))
                } catch let err as CorePermission.DeclinedError {
                    throw err
                } catch {
                    throw AISchema.ToolFailure(message: "Unable to move session to \(input.directory.rawValue): \(error)")
                }
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
            ) { rawInput, context in
                let input = try decodeToolJSON(WorktreeCreateInput.self, from: rawInput, toolName: "worktree_create")
                let trimmedName = input.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedName.isEmpty else {
                    throw AISchema.ToolFailure(message: "Worktree name must not be empty")
                }
                guard let worktreeService = env.worktree else {
                    throw AISchema.ToolFailure(message: "Worktree service is not configured")
                }
                let projectID = resolveProjectID(env: env, context: context)
                do {
                    let info = try await worktreeService.create(
                        WorktreeSchema.CreateInput(projectID: projectID, name: trimmedName),
                        strategies: env.worktreeStrategies
                    )
                    return ToolSchema.Result(
                        output: encodeToolJSON(info),
                        content: .text("Created worktree in \(info.directory.rawValue).")
                    )
                } catch {
                    throw AISchema.ToolFailure(message: "Unable to create worktree \(trimmedName): \(error)")
                }
            })

            editor.add(RegisteredTool(
                name: "worktree_list",
                description: "List a repository's worktrees.",
                inputSchema: ["type": .string("object"), "properties": .object([:])],
                outputSchema: ["type": .string("object")],
                options: ToolSchema.Options(namespace: "opencode", codemode: true, pinned: true)
            ) { _, context in
                guard let worktreeService = env.worktree else {
                    throw AISchema.ToolFailure(message: "Worktree service is not configured")
                }
                let projectID = resolveProjectID(env: env, context: context)
                do {
                    let worktrees = try await worktreeService.list(projectID: projectID)
                    return ToolSchema.Result(
                        output: .object(["worktrees": encodeToolJSON(worktrees, fallback: .array([]))])
                    )
                } catch {
                    throw AISchema.ToolFailure(message: "Unable to list worktrees: \(error)")
                }
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
                guard let worktreeService = env.worktree else {
                    throw AISchema.ToolFailure(message: "Worktree service is not configured")
                }
                let projectID = resolveProjectID(env: env, context: context)
                do {
                    try await worktreeService.remove(
                        WorktreeSchema.RemoveInput(
                            projectID: projectID,
                            directory: target.absolute,
                            force: input.force ?? false
                        ),
                        strategies: env.worktreeStrategies
                    )
                } catch let err as CorePermission.DeclinedError {
                    throw err
                } catch {
                    throw AISchema.ToolFailure(message: removeFailureMessage(directory: target.absolute.rawValue, error: error))
                }
                return ToolSchema.Result(
                    output: .object(["directory": .string(target.absolute.rawValue), "removed": .bool(true)]),
                    content: .text("Removed worktree \(target.absolute.rawValue).")
                )
            })

            editor.add(RegisteredTool(
                name: "models",
                description: "Search the models available to use. Use this to turn a model name the user mentions into an exact reference for a tool that takes a model. Check your own provider first.",
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
            ) { rawInput, context in
                let input = try decodeToolJSON(ModelsInput.self, from: rawInput, toolName: "models")
                guard let modelService = env.model else {
                    throw AISchema.ToolFailure(message: "Model service is not configured")
                }
                let offset = max(0, input.offset ?? 0)
                let limit = min(100, max(1, input.limit ?? 20))
                let ownProviderID: String? = {
                    if let s = try? env.session?.get(context.sessionID) { return s.model?.providerID }
                    if let s = try? env.sessionStore?.get(context.sessionID) { return s.model?.providerID }
                    return nil
                }()
                let terms = input.query?
                    .lowercased()
                    .split(whereSeparator: \.isWhitespace)
                    .map(String.init) ?? []

                var providerNames: [ProviderSchema.ID: String] = [:]
                if let providerService = env.provider {
                    let allProviders = await providerService.all()
                    for p in allProviders { providerNames[p.id] = p.name }
                    if let availProviders = try? await providerService.available() {
                        for p in availProviders { providerNames[p.id] = p.name }
                    }
                }

                let providerFilter = input.provider?.lowercased()
                let requestedType: ModelSchema.ModelType
                switch input.type ?? .chat {
                case .chat: requestedType = .chat
                case .image: requestedType = .image
                case .video: requestedType = .video
                }

                let rawModels: [ModelSchema.Info]
                do {
                    rawModels = try await modelService.available(types: [requestedType])
                } catch {
                    throw AISchema.ToolFailure(message: "Unable to list models: \(error)")
                }

                let filtered = rawModels
                    .filter { model in
                        guard let providerFilter else { return true }
                        return model.providerID.rawValue.lowercased() == providerFilter ||
                            providerNames[model.providerID]?.lowercased() == providerFilter
                    }
                    .filter { model in
                        guard !terms.isEmpty else { return true }
                        let haystack = "\(model.providerID.rawValue)/\(model.id.rawValue) \(model.name)".lowercased()
                        return terms.allSatisfy { haystack.contains($0) }
                    }
                    .sorted { lhs, rhs in
                        let lOwn = lhs.providerID.rawValue == ownProviderID
                        let rOwn = rhs.providerID.rawValue == ownProviderID
                        if lOwn != rOwn { return lOwn }
                        if lhs.providerID.rawValue != rhs.providerID.rawValue {
                            return lhs.providerID.rawValue < rhs.providerID.rawValue
                        }
                        if lhs.time.released != rhs.time.released {
                            return lhs.time.released > rhs.time.released
                        }
                        return lhs.id.rawValue < rhs.id.rawValue
                    }

                // When browsing, hide older versions only: a family's same-day siblings, like free and paid offerings,
                // stay listed. A search lists every match, so a version the user names is never hidden.
                let matching: [ModelSchema.Info]
                if input.all == true || !terms.isEmpty {
                    matching = filtered
                } else {
                    var newest: [String: Double] = [:]
                    for model in filtered {
                        guard let family = model.family else { continue }
                        let key = "\(model.providerID.rawValue)::\(family.rawValue)"
                        if newest[key] == nil { newest[key] = model.time.released }
                    }
                    matching = filtered.filter { model in
                        guard let family = model.family else { return true }
                        return newest["\(model.providerID.rawValue)::\(family.rawValue)"] == model.time.released
                    }
                }

                let page: [ModelSchema.Info] = offset < matching.count
                    ? Array(matching[offset..<min(matching.count, offset + limit)])
                    : []

                var orderedProviderIDs: [ProviderSchema.ID] = []
                var seenProviders: Set<ProviderSchema.ID> = []
                for m in page where seenProviders.insert(m.providerID).inserted {
                    orderedProviderIDs.append(m.providerID)
                }

                let providerEntries: [JSONValue] = orderedProviderIDs.map { pid in
                    let modelsForProvider = page.filter { $0.providerID == pid }.map { m -> JSONValue in
                        .object([
                            "id": .string("\(m.providerID.rawValue)/\(m.id.rawValue)"),
                            "name": .string(m.name),
                            "released": .double(m.time.released),
                            "variants": .array(m.variants.map { .string($0.id.rawValue) }),
                            "cost": encodeToolJSON(m.cost, fallback: .array([])),
                            "status": .string(m.status.rawValue),
                        ])
                    }
                    return .object([
                        "id": .string(pid.rawValue),
                        "name": .string(providerNames[pid] ?? pid.rawValue),
                        "models": .array(modelsForProvider),
                    ])
                }

                let nextOffset: JSONValue = (offset + limit < matching.count) ? .int(Int64(offset + limit)) : .null
                return ToolSchema.Result(output: .object([
                    "providers": .array(providerEntries),
                    "total": .int(Int64(matching.count)),
                    "next": nextOffset,
                ]))
            })
        }
    }

    /// Registers the complete built-in tool suite into `registry` using `environment`.
    public static func registerAllBuiltins(
        into registry: any CoreTool.Interface,
        environment: BuiltinEnvironment
    ) async -> CoreFilesystem.LocationWatcherPolicy.Registration {
        var resolving = environment
        resolving.fullCodeMode = await environment.flags.enabled(.fullCodemode)
        resolving.videoGenerate = await VideoGenerateTool.enabled(environment)
        let resolved = resolving
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
            VideoGenerateTool.Plugin,
            McpEventTools.Plugin,
            McpResourceTools.Plugin,
            OpenCodeTools.Plugin,
        ]
        return await registry.transform { editor in
            for plugin in plugins {
                plugin.register(editor, resolved)
            }
        }
    }
}
