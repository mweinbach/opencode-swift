import OpenCodeAI
import OpenCodeSchema

// MARK: - SessionSearchTools (`core/src/tool/plugin/session-search.ts`)

extension CoreTool {
    public enum SessionSearchTools {
        public enum Scope: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
            case project
            case all
        }

        // parity: core/src/tool/plugin/session-search.ts#SearchInput [status=implemented hash=9c9baddb0058]
        public struct SearchInput: Equatable, Hashable, Sendable, Codable {
            public let query: String?
            public let scope: Scope?
            public let sessionID: SessionID?
            public let directory: String?
            public let subagents: Bool?
            public let limit: Int?
            public let offset: Int?

            public init(
                query: String? = nil,
                scope: Scope? = nil,
                sessionID: SessionID? = nil,
                directory: String? = nil,
                subagents: Bool? = nil,
                limit: Int? = nil,
                offset: Int? = nil
            ) {
                self.query = query
                self.scope = scope
                self.sessionID = sessionID
                self.directory = directory
                self.subagents = subagents
                self.limit = limit
                self.offset = offset
            }
        }

        // parity: core/src/tool/plugin/session-search.ts#ReadInput [status=implemented hash=3a8b01b9f5a4]
        public struct ReadInput: Equatable, Hashable, Sendable, Codable {
            public let sessionID: SessionID
            public let messageID: SessionMessageSchema.ID?
            public let direction: SessionSearch.Direction?
            public let limit: Int?
            public let full: Bool?

            public init(
                sessionID: SessionID,
                messageID: SessionMessageSchema.ID? = nil,
                direction: SessionSearch.Direction? = nil,
                limit: Int? = nil,
                full: Bool? = nil
            ) {
                self.sessionID = sessionID
                self.messageID = messageID
                self.direction = direction
                self.limit = limit
                self.full = full
            }
        }

        private static let searchInputSchema: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object([
                "query": .object([
                    "type": .string("string"),
                    "description": .string("Distinctive keywords, names, numbers or phrases. Omit to list sessions."),
                ]),
                "scope": .object([
                    "type": .string("string"),
                    "enum": .array([.string("project"), .string("all")]),
                    "description": .string(#"Which sessions to cover: "project" (default) for this project, "all" for every project."#),
                ]),
                "sessionID": .object([
                    "type": .string("string"),
                    "description": .string("Search only inside this session, in any project."),
                ]),
                "directory": .object([
                    "type": .string("string"),
                    "description": .string("Only sessions in this directory or below it."),
                ]),
                "subagents": .object([
                    "type": .string("boolean"),
                    "description": .string("When listing, include subagent sessions (default false). Searches include them by default."),
                ]),
                "limit": .object([
                    "type": .string("integer"),
                    "description": .string("Max sessions. Default 5 when searching (max 20), 20 when listing (max 100)."),
                ]),
                "offset": .object([
                    "type": .string("integer"),
                    "minimum": .int(0),
                    "description": .string("When listing, skip this many sessions."),
                ]),
            ]),
        ]

        private static let readInputSchema: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object([
                "sessionID": .object([
                    "type": .string("string"),
                    "description": .string("Session to read."),
                ]),
                "messageID": .object([
                    "type": .string("string"),
                    "description": .string("Anchor message, from session.search or a cursor. Omit to start from the newest or oldest message."),
                ]),
                "direction": .object([
                    "type": .string("string"),
                    "enum": .array([.string("around"), .string("before"), .string("after")]),
                    "description": .string(#"Which messages to read relative to the anchor (default "around"). Without messageID, "around" and "before" read the newest messages and "after" the oldest."#),
                ]),
                "limit": .object([
                    "type": .string("integer"),
                    "description": .string("Number of messages. Default 7, at most 50."),
                ]),
                "full": .object([
                    "type": .string("boolean"),
                    "description": .string("Show each tool call's full input, output and error, and include system messages. Default false."),
                ]),
            ]),
            "required": .array([.string("sessionID")]),
        ]

        // parity: core/src/tool/plugin/session-search.ts#Plugin [status=adapted hash=31bbf19f5b2d]
        public static let Plugin = ToolPluginDescriptor(id: "opencode.tool.session-search") { editor, env in
            guard env.sqliteFts else { return }

            editor.add(RegisteredTool(
                name: "search",
                description: #"Find the user's past sessions, in this project unless scope is "all". With query: full-text search over session titles, user and assistant messages, and compaction summaries. Matches any query word, ranked so messages with more and rarer words come first; supports "exact phrase", prefix*, AND, OR, NOT. Returns the best-matching sessions with up to 3 snippets and messageIDs each. Without query: lists sessions, most recently updated first. Filter either way by directory. Follow up with opencode.session.read({ sessionID, messageID })."#,
                inputSchema: searchInputSchema,
                outputSchema: ["type": .string("object")],
                options: ToolSchema.Options(namespace: "opencode.session", codemode: true)
            ) { rawInput, _ in
                guard let search = env.sessionSearch else {
                    throw AISchema.ToolFailure(message: "Session search service is not configured")
                }
                let input = try decodeToolJSON(SearchInput.self, from: rawInput, toolName: "opencode.session.search")
                if let offset = input.offset, offset < 0 {
                    throw AISchema.ToolFailure(message: "offset must be >= 0")
                }
                do {
                    let output = try await search.search(SessionSearch.SearchInput(
                        query: input.query,
                        projectID: input.scope == .all ? nil : env.projectID,
                        sessionID: input.sessionID,
                        directory: input.directory,
                        subagents: input.subagents,
                        limit: input.limit,
                        offset: input.offset
                    ))
                    return ToolSchema.Result(output: encodeToolJSON(output))
                } catch let err as SessionSearch.IndexUnavailableError {
                    throw AISchema.ToolFailure(message: err.message)
                } catch let err as AISchema.ToolFailure {
                    throw err
                } catch {
                    throw AISchema.ToolFailure(message: String(describing: error))
                }
            })

            editor.add(RegisteredTool(
                name: "read",
                description: #"Read messages from one session, including history from before compaction. With messageID (from opencode.session.search), returns messages around it; direction "before" or "after" reads only one side. Without messageID, reads the newest messages, or the oldest with direction "after". Tool calls are one-line summaries in calls unless full is true. To keep reading, pass older as messageID with direction "before", or newer with direction "after"; pages never repeat."#,
                inputSchema: readInputSchema,
                outputSchema: ["type": .string("object")],
                options: ToolSchema.Options(namespace: "opencode.session", codemode: true)
            ) { rawInput, _ in
                guard let search = env.sessionSearch else {
                    throw AISchema.ToolFailure(message: "Session search service is not configured")
                }
                let input = try decodeToolJSON(ReadInput.self, from: rawInput, toolName: "opencode.session.read")
                do {
                    let output = try await search.read(SessionSearch.ReadInput(
                        sessionID: input.sessionID,
                        messageID: input.messageID,
                        direction: input.direction,
                        limit: input.limit,
                        full: input.full
                    ))
                    return ToolSchema.Result(output: encodeToolJSON(output))
                } catch let err as SessionSearch.SessionNotFoundError {
                    throw AISchema.ToolFailure(message: err.message)
                } catch let err as SessionSearch.MessageNotFoundError {
                    throw AISchema.ToolFailure(message: err.message)
                } catch let err as AISchema.ToolFailure {
                    throw err
                } catch {
                    throw AISchema.ToolFailure(message: String(describing: error))
                }
            })
        }
    }
}
