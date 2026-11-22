#if canImport(Foundation)
import Foundation
#elseif canImport(FoundationEssentials)
import FoundationEssentials
#endif
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

// MARK: - Session Search (`core/src/session/search.ts`)

public enum SessionSearch {
    /// Characters of context on each side of a snippet's match.
    private static let snippetContext = 120
    /// Characters of a tool's input shown in its one-line summary. Full text goes through the tool output limit.
    private static let toolSummaryInput = 120
    private static let maxMatchesPerSession = 3

    private static let visibleTypes: [String] = ["user", "assistant", "compaction", "shell", "synthetic", "skill"]
    private static let visibleWithSystem: [String] = visibleTypes + ["system"]

    // MARK: Errors

    // parity: core/src/session/search.ts#IndexUnavailableError [status=implemented hash=fa269abd006a]
    public struct IndexUnavailableError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public static let tag = "SessionSearch.IndexUnavailableError"
        public let reason: String

        public init(reason: String) {
            self.reason = reason
        }

        // parity: core/src/session/search.ts#IndexUnavailableError.message [status=implemented hash=8eadea097e1c]
        public var message: String { reason }
        public var description: String { message }
    }

    // parity: core/src/session/search.ts#SessionNotFoundError [status=implemented hash=ea2540b37473]
    public struct SessionNotFoundError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public static let tag = "SessionSearch.SessionNotFoundError"
        public let sessionID: SessionID

        public init(sessionID: SessionID) {
            self.sessionID = sessionID
        }

        // parity: core/src/session/search.ts#SessionNotFoundError.message [status=implemented hash=b55fba65b7c9]
        public var message: String { "Session not found: \(sessionID.rawValue)" }
        public var description: String { message }
    }

    // parity: core/src/session/search.ts#MessageNotFoundError [status=implemented hash=136d7290610d]
    public struct MessageNotFoundError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public static let tag = "SessionSearch.MessageNotFoundError"
        public let sessionID: SessionID
        public let messageID: SessionMessageSchema.ID

        public init(sessionID: SessionID, messageID: SessionMessageSchema.ID) {
            self.sessionID = sessionID
            self.messageID = messageID
        }

        // parity: core/src/session/search.ts#MessageNotFoundError.message [status=implemented hash=af5bfdab14d8]
        public var message: String { "Message \(messageID.rawValue) not found in session \(sessionID.rawValue)" }
        public var description: String { message }
    }

    // parity: core/src/session/search.ts#Error [status=implemented hash=01f559e03356]
    public enum Error: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        case indexUnavailable(IndexUnavailableError)
        case sessionNotFound(SessionNotFoundError)
        case messageNotFound(MessageNotFoundError)

        public var message: String {
            switch self {
            case .indexUnavailable(let e): e.message
            case .sessionNotFound(let e): e.message
            case .messageNotFound(let e): e.message
            }
        }

        public var description: String { message }
    }

    // MARK: Schemas / Types

    // parity: core/src/session/search.ts#SessionSummary [status=implemented hash=354a07dd7639]
    public struct SessionSummary: Equatable, Hashable, Sendable, Codable {
        public let sessionID: SessionID
        public let title: String
        public let directory: String
        public let created: String
        public let updated: String
        public let parentID: SessionID?

        public init(
            sessionID: SessionID,
            title: String,
            directory: String,
            created: String,
            updated: String,
            parentID: SessionID? = nil
        ) {
            self.sessionID = sessionID
            self.title = title
            self.directory = directory
            self.created = created
            self.updated = updated
            self.parentID = parentID
        }
    }

    // parity: core/src/session/search.ts#Match [status=implemented hash=447d126c7563]
    public struct Match: Equatable, Hashable, Sendable, Codable {
        public let messageID: SessionMessageSchema.ID?
        public let type: String
        public let time: String
        public let snippet: String

        public init(
            messageID: SessionMessageSchema.ID? = nil,
            type: String,
            time: String,
            snippet: String
        ) {
            self.messageID = messageID
            self.type = type
            self.time = time
            self.snippet = snippet
        }
    }

    // parity: core/src/session/search.ts#SearchResult [status=implemented hash=df7ef1b667a9]
    public struct SearchResult: Equatable, Hashable, Sendable, Codable {
        public let sessionID: SessionID
        public let title: String
        public let directory: String
        public let created: String
        public let updated: String
        public let parentID: SessionID?
        public let matches: [Match]

        public init(
            sessionID: SessionID,
            title: String,
            directory: String,
            created: String,
            updated: String,
            parentID: SessionID? = nil,
            matches: [Match]
        ) {
            self.sessionID = sessionID
            self.title = title
            self.directory = directory
            self.created = created
            self.updated = updated
            self.parentID = parentID
            self.matches = matches
        }
    }

    // parity: core/src/session/search.ts#SearchOutput [status=implemented hash=82e9072fd137]
    public struct SearchOutput: Equatable, Hashable, Sendable, Codable {
        public let next: Int?
        public let results: [SearchResult]?
        public let sessions: [SessionSummary]?

        public init(
            results: [SearchResult]? = nil,
            sessions: [SessionSummary]? = nil,
            next: Int? = nil
        ) {
            self.next = next
            self.results = results
            self.sessions = sessions
        }

        private enum CodingKeys: String, CodingKey {
            case next
            case results
            case sessions
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.next = try container.decodeIfPresent(Int.self, forKey: .next)
            self.results = try container.decodeIfPresent([SearchResult].self, forKey: .results)
            self.sessions = try container.decodeIfPresent([SessionSummary].self, forKey: .sessions)
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            // Cursor precedes the result arrays so it survives truncation at the tool output limit.
            if let sessions {
                if let next {
                    try container.encode(next, forKey: .next)
                } else {
                    try container.encodeNil(forKey: .next)
                }
                try container.encodeIfPresent(results, forKey: .results)
                try container.encode(sessions, forKey: .sessions)
            } else {
                try container.encodeIfPresent(next, forKey: .next)
                try container.encodeIfPresent(results, forKey: .results)
            }
        }
    }

    // parity: core/src/session/search.ts#CallDetail [status=implemented hash=e3c312017b04]
    public struct CallDetail: Equatable, Hashable, Sendable, Codable {
        public let name: String
        public let status: String
        public let error: String?
        public let input: String?
        public let output: String?

        public init(
            name: String,
            status: String,
            input: String? = nil,
            output: String? = nil,
            error: String? = nil
        ) {
            self.name = name
            self.status = status
            self.error = error
            self.input = input
            self.output = output
        }

        private enum CodingKeys: String, CodingKey {
            case name
            case status
            case error
            case input
            case output
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.name = try container.decode(String.self, forKey: .name)
            self.status = try container.decode(String.self, forKey: .status)
            self.error = try container.decodeIfPresent(String.self, forKey: .error)
            self.input = try container.decodeIfPresent(String.self, forKey: .input)
            self.output = try container.decodeIfPresent(String.self, forKey: .output)
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .name)
            try container.encode(status, forKey: .status)
            try container.encodeIfPresent(error, forKey: .error)
            try container.encodeIfPresent(input, forKey: .input)
            try container.encodeIfPresent(output, forKey: .output)
        }
    }

    public enum CallEntry: Equatable, Hashable, Sendable, Codable {
        case summary(String)
        case detail(CallDetail)

        public init(from decoder: any Decoder) throws {
            if let single = try? decoder.singleValueContainer(),
               let text = try? single.decode(String.self)
            {
                self = .summary(text)
                return
            }
            self = .detail(try CallDetail(from: decoder))
        }

        public func encode(to encoder: any Encoder) throws {
            switch self {
            case .summary(let text):
                var container = encoder.singleValueContainer()
                try container.encode(text)
            case .detail(let detail):
                try detail.encode(to: encoder)
            }
        }
    }

    // parity: core/src/session/search.ts#ReadMessage [status=implemented hash=c658b8e9b151]
    public struct ReadMessage: Equatable, Hashable, Sendable, Codable {
        public let messageID: SessionMessageSchema.ID
        public let type: String
        public let time: String
        public let text: String?
        public let calls: [CallEntry]?

        public init(
            messageID: SessionMessageSchema.ID,
            type: String,
            time: String,
            text: String? = nil,
            calls: [CallEntry]? = nil
        ) {
            self.messageID = messageID
            self.type = type
            self.time = time
            self.text = text
            self.calls = calls
        }
    }

    /// The cursors come before messages, so they survive when a long page is cut at the tool output limit.
    // parity: core/src/session/search.ts#ReadOutput [status=implemented hash=a2415b6c318a]
    public struct ReadOutput: Equatable, Hashable, Sendable, Codable {
        public let session: SessionSummary
        public let older: SessionMessageSchema.ID?
        public let newer: SessionMessageSchema.ID?
        public let messages: [ReadMessage]

        public init(
            session: SessionSummary,
            older: SessionMessageSchema.ID? = nil,
            newer: SessionMessageSchema.ID? = nil,
            messages: [ReadMessage]
        ) {
            self.session = session
            self.older = older
            self.newer = newer
            self.messages = messages
        }

        private enum CodingKeys: String, CodingKey {
            case session
            case older
            case newer
            case messages
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(session, forKey: .session)
            try container.encodeIfPresent(older, forKey: .older)
            try container.encodeIfPresent(newer, forKey: .newer)
            try container.encode(messages, forKey: .messages)
        }
    }

    public enum Direction: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
        case around
        case before
        case after
    }

    // parity: core/src/session/search.ts#SearchInput [status=implemented hash=5b9926bc8aba]
    public struct SearchInput: Equatable, Hashable, Sendable, Codable {
        public let query: String?
        /// Only sessions in this project. Ignored when `sessionID` is set.
        public let projectID: ProjectID?
        public let sessionID: SessionID?
        public let directory: String?
        public let subagents: Bool?
        public let limit: Int?
        public let offset: Int?

        public init(
            query: String? = nil,
            projectID: ProjectID? = nil,
            sessionID: SessionID? = nil,
            directory: String? = nil,
            subagents: Bool? = nil,
            limit: Int? = nil,
            offset: Int? = nil
        ) {
            self.query = query
            self.projectID = projectID
            self.sessionID = sessionID
            self.directory = directory
            self.subagents = subagents
            self.limit = limit
            self.offset = offset
        }
    }

    // parity: core/src/session/search.ts#ReadInput [status=implemented hash=6e01e426fbce]
    public struct ReadInput: Equatable, Hashable, Sendable, Codable {
        public let sessionID: SessionID
        public let messageID: SessionMessageSchema.ID?
        public let direction: Direction?
        public let limit: Int?
        public let full: Bool?

        public init(
            sessionID: SessionID,
            messageID: SessionMessageSchema.ID? = nil,
            direction: Direction? = nil,
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

    // MARK: Service & Layer

    // parity: core/src/session/search.ts#Interface [status=implemented hash=ca89196a05c8]
    public protocol Interface: Sendable {
        func search(_ input: SearchInput) async throws -> SearchOutput
        func read(_ input: ReadInput) async throws -> ReadOutput
    }

    // parity: core/src/session/search.ts#Service [status=adapted hash=f7da9097a7ca]
    public final class Service: Interface, Sendable {
        public static let serviceKey = "@opencode/SessionSearch"

        private let db: any SQLiteDatabase

        public init(db: any SQLiteDatabase) {
            self.db = db
        }

        public func search(_ input: SearchInput = SearchInput()) async throws -> SearchOutput {
            let trimmed = input.query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if trimmed.isEmpty {
                return try SessionSearch.listSessions(db: db, input: input)
            }
            return try SessionSearch.searchSessions(db: db, input: input, query: trimmed)
        }

        public func read(_ input: ReadInput) async throws -> ReadOutput {
            try SessionSearch.readSession(db: db, input: input)
        }
    }

    // parity: core/src/session/search.ts#layer [status=adapted hash=62c3abb544e1]
    public static let layer: LayerNode.ExecutableLayer = LayerNode.ExecutableLayer { deps, _ in
        let database = deps.get(CoreDatabaseStore.Service.serviceKey, as: (any CoreDatabaseStore.Interface).self)
        let db: any SQLiteDatabase
        if let database {
            db = database.db
        } else {
            db = try await CoreDatabaseStore.open().db
        }
        return LayerNode.Output([Service.serviceKey: Service(db: db) as any Interface])
    }

    // parity: core/src/session/search.ts#node [status=adapted hash=17762735ab32]
    public static let node: LayerNode.Provider = AppNode.makeGlobalNode(
        Service.serviceKey,
        layer,
        [CoreDatabaseStore.node]
    )

    // MARK: Internal Query Implementation

    private struct SessionRow {
        let id: SessionID
        let title: String?
        let directory: String
        let timeCreated: Int64
        let timeUpdated: Int64
        let parentID: SessionID?

        init?(_ row: SQLiteRow) {
            guard let idStr = row.string("id"),
                  let id = SessionID(rawValue: idStr),
                  let directory = row.string("directory"),
                  let timeCreated = row.int64("time_created"),
                  let timeUpdated = row.int64("time_updated")
            else { return nil }
            self.id = id
            self.title = row.string("title")
            self.directory = directory
            self.timeCreated = timeCreated
            self.timeUpdated = timeUpdated
            self.parentID = row.string("parent_id").flatMap(SessionID.init(rawValue:))
        }
    }

    private struct DecodedRow {
        let row: CoreSessionBlob.StoredMessageRow
        let message: SessionMessageSchema.MediaInfo
    }

    private static func listSessions(
        db: any SQLiteDatabase,
        input: SearchInput
    ) throws -> SearchOutput {
        let limit = clamp(input.limit ?? 20, min: 1, max: 100)
        let offset = max(0, input.offset ?? 0)
        let cond = sessionConditions(
            sessionID: input.sessionID,
            projectID: input.sessionID != nil ? nil : input.projectID,
            directory: input.directory,
            subagents: input.sessionID != nil ? true : (input.subagents ?? false)
        )
        let whereSQL = cond.clauses.isEmpty ? "" : " WHERE \(cond.clauses.joined(separator: " AND "))"
        let sql = """
            SELECT `id`, `title`, `directory`, `time_created`, `time_updated`, `parent_id`
            FROM `session_v2`\(whereSQL)
            ORDER BY `time_updated` DESC, `id` DESC
            LIMIT ? OFFSET ?
            """
        var params = cond.parameters
        params.append(.integer(Int64(limit + 1)))
        params.append(.integer(Int64(offset)))
        let rows = try db.query(sql, parameters: params).compactMap(SessionRow.init)
        let page = rows.prefix(limit).map(toSummary)
        let next = rows.count > limit ? offset + limit : nil
        return SearchOutput(sessions: Array(page), next: next)
    }

    private static func searchSessions(
        db: any SQLiteDatabase,
        input: SearchInput,
        query: String
    ) throws -> SearchOutput {
        let folded = SessionSearchIndex.foldText(query)
        guard let fallback = plainOrQuery(folded) else {
            return SearchOutput(results: [])
        }

        let limit = clamp(input.limit ?? 5, min: 1, max: 20)
        let hitLimit = min(400, max(100, limit * 20))
        let cond = sessionConditions(
            sessionID: input.sessionID,
            projectID: input.sessionID != nil ? nil : input.projectID,
            directory: input.directory,
            subagents: input.sessionID != nil ? true : (input.subagents ?? true)
        )
        let filterSQL = cond.clauses.isEmpty ? "" : " AND \(cond.clauses.joined(separator: " AND "))"

        func runMatch(_ expression: String) throws -> [(sourceID: String, sessionID: String)] {
            let sql = """
                SELECT d.source_id AS source_id, d.session_id AS session_id,
                  bm25(session_search, 3.0, 2.0, 1.5, 1.0) AS score
                FROM session_search
                JOIN session_search_document AS d ON d.id = session_search.rowid
                JOIN session_v2 ON session_v2.id = d.session_id
                WHERE session_search MATCH ?\(filterSQL)
                ORDER BY score
                LIMIT ?
                """
            var params: [SQLiteValue] = [.text(expression)]
            params.append(contentsOf: cond.parameters)
            params.append(.integer(Int64(hitLimit)))
            return try db.query(sql, parameters: params).compactMap { row in
                guard let sourceID = row.string("source_id"),
                      let sessionID = row.string("session_id")
                else { return nil }
                return (sourceID, sessionID)
            }
        }

        let raw = hasFtsSyntax(folded) ? folded : fallback
        let hits: [(sourceID: String, sessionID: String)]
        do {
            hits = try runMatch(raw)
        } catch {
            guard SessionSearchIndex.isQueryError(error) else { throw error }
            if raw != fallback {
                do {
                    hits = try runMatch(fallback)
                } catch let retryError {
                    guard SessionSearchIndex.isQueryError(retryError) else { throw retryError }
                    throw IndexUnavailableError(reason: "Session search index is unavailable.")
                }
            } else {
                throw IndexUnavailableError(reason: "Session search index is unavailable.")
            }
        }

        var groupedOrder: [SessionID] = []
        var groupedSources: [SessionID: [String]] = [:]
        for hit in hits {
            guard let sessionID = SessionID(rawValue: hit.sessionID) else { continue }
            if var list = groupedSources[sessionID] {
                if list.count < maxMatchesPerSession && !list.contains(hit.sourceID) {
                    list.append(hit.sourceID)
                    groupedSources[sessionID] = list
                }
                continue
            }
            if groupedOrder.count >= limit { continue }
            groupedOrder.append(sessionID)
            groupedSources[sessionID] = [hit.sourceID]
        }
        if groupedOrder.isEmpty {
            return SearchOutput(results: [])
        }

        var sessionMap: [SessionID: SessionRow] = [:]
        for batch in CoreDatabaseSchema.batches(groupedOrder.map(\.rawValue), perItem: 1) {
            let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ", ")
            let rows = try db.query(
                """
                SELECT `id`, `title`, `directory`, `time_created`, `time_updated`, `parent_id`
                FROM `session_v2` WHERE `id` IN (\(placeholders))
                """,
                parameters: batch.map(SQLiteValue.text)
            )
            for row in rows {
                if let parsed = SessionRow(row) {
                    sessionMap[parsed.id] = parsed
                }
            }
        }

        let messageIDs: [String] = groupedOrder.flatMap { sessionID in
            (groupedSources[sessionID] ?? []).compactMap { source in
                source == sessionID.rawValue ? nil : source
            }
        }

        var rawMessageRows: [SQLiteRow] = []
        if !messageIDs.isEmpty {
            for batch in CoreDatabaseSchema.batches(messageIDs, perItem: 1) {
                let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ", ")
                let rows = try db.query(
                    "SELECT * FROM `session_message` WHERE `id` IN (\(placeholders))",
                    parameters: batch.map(SQLiteValue.text)
                )
                rawMessageRows.append(contentsOf: rows)
            }
        }

        var messageMap: [SessionMessageSchema.ID: DecodedRow] = [:]
        for decoded in decodeWindowRows(db: db, rows: rawMessageRows) {
            messageMap[decoded.row.id] = decoded
        }

        var results: [SearchResult] = []
        for sessionID in groupedOrder {
            guard let session = sessionMap[sessionID] else { continue }
            let sources = groupedSources[sessionID] ?? []
            var matches: [Match] = []
            for source in sources {
                if source == sessionID.rawValue {
                    guard let title = session.title, !title.isEmpty else { continue }
                    matches.append(Match(
                        messageID: nil,
                        type: "title",
                        time: formatTime(session.timeCreated),
                        snippet: makeSnippet(title, query: query)
                    ))
                    continue
                }
                guard let msgID = SessionMessageSchema.ID(rawValue: source),
                      let decoded = messageMap[msgID]
                else { continue }
                let text = extractIndexedText(decoded.message)
                guard !text.isEmpty else { continue }
                matches.append(Match(
                    messageID: decoded.row.id,
                    type: decoded.row.type.rawValue,
                    time: formatTime(decoded.row.timeCreated),
                    snippet: makeSnippet(text, query: query)
                ))
            }
            if matches.isEmpty { continue }
            let summary = toSummary(session)
            results.append(SearchResult(
                sessionID: summary.sessionID,
                title: summary.title,
                directory: summary.directory,
                created: summary.created,
                updated: summary.updated,
                parentID: summary.parentID,
                matches: matches
            ))
        }

        return SearchOutput(results: results)
    }

    /// Reads up to `limit` messages around, before or after `messageID`, or from the newest (around, before) or oldest
    /// (after) message without one. Before and after exclude the anchor, and the cursors are the oldest and newest
    /// message returned, so passing one back with the same direction never repeats a message.
    private static func readSession(
        db: any SQLiteDatabase,
        input: ReadInput
    ) throws -> ReadOutput {
        guard let sessionSQLRow = try db.queryOne(
            "SELECT `id`, `title`, `directory`, `time_created`, `time_updated`, `parent_id` FROM `session_v2` WHERE `id` = ?",
            parameters: [.text(input.sessionID.rawValue)]
        ),
            let session = SessionRow(sessionSQLRow)
        else {
            throw SessionNotFoundError(sessionID: input.sessionID)
        }

        let full = input.full == true
        let visible = full ? visibleWithSystem : visibleTypes
        let typePlaceholders = Array(repeating: "?", count: visible.count).joined(separator: ", ")
        let limit = clamp(input.limit ?? 7, min: 1, max: 50)
        let direction = input.direction ?? .around

        func queryOlder(seq: Int64?, count: Int) throws -> [SQLiteRow] {
            var params: [SQLiteValue] = [.text(input.sessionID.rawValue)]
            params.append(contentsOf: visible.map(SQLiteValue.text))
            var whereSQL = "`session_id` = ? AND `type` IN (\(typePlaceholders))"
            if let seq {
                whereSQL += " AND `seq` < ?"
                params.append(.integer(seq))
            }
            params.append(.integer(Int64(count + 1)))
            return try db.query(
                "SELECT * FROM `session_message` WHERE \(whereSQL) ORDER BY `seq` DESC LIMIT ?",
                parameters: params
            )
        }

        func queryNewer(seq: Int64?, count: Int) throws -> [SQLiteRow] {
            var params: [SQLiteValue] = [.text(input.sessionID.rawValue)]
            params.append(contentsOf: visible.map(SQLiteValue.text))
            var whereSQL = "`session_id` = ? AND `type` IN (\(typePlaceholders))"
            if let seq {
                whereSQL += " AND `seq` > ?"
                params.append(.integer(seq))
            }
            params.append(.integer(Int64(count + 1)))
            return try db.query(
                "SELECT * FROM `session_message` WHERE \(whereSQL) ORDER BY `seq` ASC LIMIT ?",
                parameters: params
            )
        }

        let anchor: SQLiteRow?
        if let messageID = input.messageID {
            anchor = try db.queryOne(
                "SELECT * FROM `session_message` WHERE `session_id` = ? AND `id` = ?",
                parameters: [.text(input.sessionID.rawValue), .text(messageID.rawValue)]
            )
            if anchor == nil {
                throw MessageNotFoundError(sessionID: input.sessionID, messageID: messageID)
            }
        } else {
            anchor = nil
        }

        let anchorSeq = anchor?.int64("seq")
        let anchorID = anchor?.string("id").flatMap(SessionMessageSchema.ID.init(rawValue:))

        if let anchor, let anchorSeq, direction == .around {
            let beforeCount = (limit - 1) / 2
            let afterCount = limit - 1 - beforeCount
            let before = try queryOlder(seq: anchorSeq, count: beforeCount)
            let after = try queryNewer(seq: anchorSeq, count: afterCount)
            let rows = Array(before.prefix(beforeCount).reversed()) + [anchor] + Array(after.prefix(afterCount))
            let olderCursor = before.count > beforeCount ? rows.first?.string("id").flatMap(SessionMessageSchema.ID.init(rawValue:)) : nil
            let newerCursor = after.count > afterCount ? rows.last?.string("id").flatMap(SessionMessageSchema.ID.init(rawValue:)) : nil
            return formatReadOutput(
                session: session,
                rows: decodeWindowRows(db: db, rows: rows),
                full: full,
                older: olderCursor,
                newer: newerCursor
            )
        }

        if direction == .after {
            let rows = try queryNewer(seq: anchorSeq, count: limit)
            let page = Array(rows.prefix(limit))
            let olderCursor: SessionMessageSchema.ID? = anchorID != nil
                ? (page.first?.string("id").flatMap(SessionMessageSchema.ID.init(rawValue:)) ?? anchorID)
                : nil
            let newerCursor: SessionMessageSchema.ID? = rows.count > limit
                ? page.last?.string("id").flatMap(SessionMessageSchema.ID.init(rawValue:))
                : nil
            return formatReadOutput(
                session: session,
                rows: decodeWindowRows(db: db, rows: page),
                full: full,
                older: olderCursor,
                newer: newerCursor
            )
        }

        let rows = try queryOlder(seq: anchorSeq, count: limit)
        let page = Array(rows.prefix(limit).reversed())
        let olderCursor: SessionMessageSchema.ID? = rows.count > limit
            ? page.first?.string("id").flatMap(SessionMessageSchema.ID.init(rawValue:))
            : nil
        let newerCursor: SessionMessageSchema.ID? = anchorID != nil
            ? (page.last?.string("id").flatMap(SessionMessageSchema.ID.init(rawValue:)) ?? anchorID)
            : nil
        return formatReadOutput(
            session: session,
            rows: decodeWindowRows(db: db, rows: page),
            full: full,
            older: olderCursor,
            newer: newerCursor
        )
    }

    /// Decodes rows without hydrating media blobs. A row that no longer decodes is skipped instead of failing the page.
    private static func decodeWindowRows(db: any SQLiteDatabase, rows: [SQLiteRow]) -> [DecodedRow] {
        var result: [DecodedRow] = []
        for rawRow in rows {
            guard let stored = try? CoreSessionHistory.parseMessageRow(rawRow),
                  let decoded = try? CoreSessionHistory.decodeMessageRowsWithRefs(db, rows: [stored]),
                  let message = decoded.first
            else { continue }
            result.append(DecodedRow(row: stored, message: message))
        }
        return result
    }

    private static func formatReadOutput(
        session: SessionRow,
        rows: [DecodedRow],
        full: Bool,
        older: SessionMessageSchema.ID?,
        newer: SessionMessageSchema.ID?
    ) -> ReadOutput {
        ReadOutput(
            session: toSummary(session),
            older: older,
            newer: newer,
            messages: rows.map { formatMessage(row: $0.row, message: $0.message, full: full) }
        )
    }

    private static func formatMessage(
        row: CoreSessionBlob.StoredMessageRow,
        message: SessionMessageSchema.MediaInfo,
        full: Bool
    ) -> ReadMessage {
        let time = formatTime(row.timeCreated)
        switch message {
        case .user(let u):
            return ReadMessage(messageID: row.id, type: row.type.rawValue, time: time, text: nonEmpty(u.text))
        case .synthetic(let s):
            return ReadMessage(messageID: row.id, type: row.type.rawValue, time: time, text: nonEmpty(s.text))
        case .system(let s):
            return ReadMessage(messageID: row.id, type: row.type.rawValue, time: time, text: nonEmpty(s.text))
        case .skill(let s):
            return ReadMessage(messageID: row.id, type: row.type.rawValue, time: time, text: nonEmpty(s.text))
        case .compaction(let c):
            let raw: String
            switch c {
            case .completed(let done): raw = done.summary
            case .failed(let failed): raw = failed.error.message
            case .running: raw = "(compaction running)"
            }
            return ReadMessage(messageID: row.id, type: row.type.rawValue, time: time, text: nonEmpty(raw))
        case .shell(let sh):
            let raw: String
            if full, let outputText = sh.output?.output, !outputText.isEmpty {
                raw = "$ \(sh.command)\n\(outputText)"
            } else {
                raw = "$ \(sh.command)"
            }
            return ReadMessage(messageID: row.id, type: row.type.rawValue, time: time, text: nonEmpty(raw))
        case .assistant(let a):
            let joined = a.content.compactMap { part -> String? in
                guard case .text(let t) = part,
                      !t.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { return nil }
                return t.text
            }.joined(separator: "\n\n")
            let calls: [CallEntry] = a.content.compactMap { part in
                guard case .tool(let t) = part else { return nil }
                return formatCall(t, full: full)
            }
            return ReadMessage(
                messageID: row.id,
                type: row.type.rawValue,
                time: time,
                text: nonEmpty(joined),
                calls: calls.isEmpty ? nil : calls
            )
        case .agentSelected, .modelSelected, .locationSwitched, .idle:
            return ReadMessage(messageID: row.id, type: row.type.rawValue, time: time)
        }
    }

    private static func formatCall(_ part: SessionMessageSchema.AssistantTool, full: Bool) -> CallEntry {
        let inputText: String
        switch part.state {
        case .streaming(let s):
            inputText = s.input
        case .running(let r):
            inputText = encodeInputObject(r.input)
        case .completed(let c):
            inputText = encodeInputObject(c.input)
        case .error(let e):
            inputText = encodeInputObject(e.input)
        }

        if !full {
            let args = cap(inputText, max: toolSummaryInput) ?? ""
            let suffix = part.state.statusTag == "error" ? " → error" : ""
            return .summary("\(part.name)(\(args))\(suffix)")
        }

        let input = nonEmpty(inputText)
        var output: String? = nil
        var errorMessage: String? = nil
        switch part.state {
        case .completed(let c):
            output = nonEmpty(toolContentText(c.content))
        case .error(let e):
            errorMessage = nonEmpty(e.error.message)
            if let content = e.content {
                output = nonEmpty(toolContentText(content))
            }
        case .streaming, .running:
            break
        }
        return .detail(CallDetail(
            name: part.name,
            status: part.state.statusTag,
            input: input,
            output: output,
            error: errorMessage
        ))
    }

    private static func encodeInputObject(_ input: [String: JSONValue]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(JSONValue.object(input)) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func toolContentText(_ content: [SessionMessageSchema.ToolContent]) -> String {
        content.map { item in
            switch item {
            case .text(let text): return text
            case .file(_, let mime, let name): return "[file: \(name ?? mime)]"
            }
        }.joined(separator: "\n")
    }

    private static func extractIndexedText(_ message: SessionMessageSchema.MediaInfo) -> String {
        let maxText = SessionSearchIndex.maxText
        switch message {
        case .user(let u):
            return sliceUTF16Prefix(u.text, maxLength: maxText)
        case .compaction(.completed(let c)):
            return sliceUTF16Prefix(c.summary, maxLength: maxText)
        case .assistant(let a):
            let joined = a.content.compactMap { part -> String? in
                guard case .text(let t) = part,
                      !t.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { return nil }
                return sliceUTF16Prefix(t.text, maxLength: maxText)
            }.joined(separator: "\n\n")
            return sliceUTF16Prefix(joined, maxLength: maxText)
        default:
            return ""
        }
    }

    private static func toSummary(_ row: SessionRow) -> SessionSummary {
        let title = (row.title?.isEmpty == false) ? row.title! : "(untitled)"
        return SessionSummary(
            sessionID: row.id,
            title: title,
            directory: row.directory,
            created: formatTime(row.timeCreated),
            updated: formatTime(row.timeUpdated),
            parentID: row.parentID
        )
    }

    private static func formatTime(_ ms: Int64) -> String {
        let iso = CoreTool.formatToolISO8601UTC(epochMillis: ms)
        return String(iso.prefix(16)).replacingOccurrences(of: "T", with: " ")
    }

    private static func sessionConditions(
        sessionID: SessionID?,
        projectID: ProjectID?,
        directory: String?,
        subagents: Bool
    ) -> (clauses: [String], parameters: [SQLiteValue]) {
        var clauses: [String] = []
        var params: [SQLiteValue] = []
        if let sessionID {
            clauses.append("session_v2.id = ?")
            params.append(.text(sessionID.rawValue))
        }
        if let projectID {
            clauses.append("session_v2.project_id = ?")
            params.append(.text(projectID.rawValue))
        }
        if let directory, !directory.isEmpty {
            let dir = normalizeDir(directory)
            let prefix = dir == "/" ? "/%" : "\(escapeLike(dir))/%"
            clauses.append("(session_v2.directory = ? OR session_v2.directory LIKE ? ESCAPE '\\')")
            params.append(.text(dir))
            params.append(.text(prefix))
        }
        if !subagents {
            clauses.append("session_v2.parent_id IS NULL")
        }
        return (clauses, params)
    }

    private static func normalizeDir(_ directory: String) -> String {
        var slashed = directory
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
        while slashed.hasSuffix("/") {
            slashed.removeLast()
        }
        return slashed.isEmpty ? "/" : slashed
    }

    private static func escapeLike(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private static func hasFtsSyntax(_ query: String) -> Bool {
        if query.contains("\"") || query.contains("*") {
            return true
        }
        return query.range(of: #"\b(?:AND|OR|NOT)\b"#, options: .regularExpression) != nil
    }

    private static func plainOrQuery(_ folded: String) -> String? {
        let rawTokens = folded.split(whereSeparator: { $0.isWhitespace })
        let terms: [String] = rawTokens.compactMap { raw in
            let cleaned = String(raw).replacingOccurrences(of: "\"", with: "")
            guard cleaned.unicodeScalars.contains(where: isLetterOrNumber) else { return nil }
            return "\"\(cleaned)\""
        }
        return terms.isEmpty ? nil : terms.joined(separator: " OR ")
    }

    /// Normalizes `text` the same way FTS5 + `Folds` index it while keeping a map back to original UTF-16 offsets,
    /// so the returned excerpt centers on accented or stemmed matches while preserving the original spelling.
    static func makeSnippet(_ text: String, query: String) -> String {
        let (normalized, offsets) = normalizeWithOffsets(text)
        let normalizedQuery = normalizeText(query)
        var seen: Set<String> = []
        var uniqueTerms: [String] = []
        for token in splitLetterNumberTokens(normalizedQuery) {
            guard !token.isEmpty, token != "and", token != "or", token != "not" else { continue }
            if seen.insert(token).inserted {
                uniqueTerms.append(token)
            }
        }
        let terms = uniqueTerms.enumerated().sorted { lhs, rhs in
            let l = lhs.element.utf16.count
            let r = rhs.element.utf16.count
            return l == r ? lhs.offset < rhs.offset : l > r
        }.map(\.element)

        let exact = terms.lazy.compactMap { utf16IndexOf($0, in: normalized) }.first
        let stemmed = exact ?? terms.lazy.compactMap { utf16IndexOf(stemPrefix($0), in: normalized) }.first
        let origin: Int
        if let stemmed, stemmed < offsets.count {
            origin = offsets[stemmed]
        } else {
            origin = 0
        }

        let units = Array(text.utf16)
        let start = max(0, origin - snippetContext)
        let end = min(units.count, origin + snippetContext)
        let rawSlice = String(decoding: units[start..<end], as: UTF16.self)
        let body = collapseWhitespace(rawSlice)
        return "\(start > 0 ? "…" : "")\(body)\(end < units.count ? "…" : "")"
    }

    /// Strips common English inflection suffixes (including doubled consonants like `running` -> `run`) for snippet centering.
    private static func stemPrefix(_ term: String) -> String {
        let suffixes = ["tion", "ment", "ness", "ies", "ing", "est", "ed", "es", "ly", "er", "s"]
        var stripped = term
        for suffix in suffixes {
            if term.hasSuffix(suffix) {
                if term.utf16.count - suffix.utf16.count >= 3 {
                    stripped = String(term.dropLast(suffix.count))
                }
                break
            }
        }
        var base = stripped
        if base.utf16.count >= 4 {
            let scalars = Array(base.unicodeScalars)
            if scalars.count >= 2 {
                let last = scalars[scalars.count - 1]
                let prev = scalars[scalars.count - 2]
                if last == prev && isASCIIConsonant(last) {
                    base.removeLast()
                }
            }
        }
        return base
    }

    private static func normalizeText(_ value: String) -> String {
        let folded = SessionSearchIndex.foldText(value)
        #if canImport(Foundation)
        let decomposed = folded.decomposedStringWithCanonicalMapping
        #else
        let decomposed = folded
        #endif
        var stripped = String.UnicodeScalarView()
        stripped.reserveCapacity(decomposed.unicodeScalars.count)
        for scalar in decomposed.unicodeScalars {
            if !scalar.properties.isDiacritic {
                stripped.append(scalar)
            }
        }
        return String(stripped).lowercased()
    }

    private static func normalizeWithOffsets(_ value: String) -> (normalized: String, offsets: [Int]) {
        var normalized = ""
        var offsets: [Int] = []
        var offset = 0
        for scalar in value.unicodeScalars {
            let piece = normalizeText(String(scalar))
            let pieceUnits = piece.utf16.count
            if pieceUnits > 0 {
                normalized.append(piece)
                for _ in 0..<pieceUnits {
                    offsets.append(offset)
                }
            }
            offset += scalar.utf16.count
        }
        return (normalized, offsets)
    }

    private static func isLetterOrNumber(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber:
            return true
        default:
            return false
        }
    }

    private static func isASCIIConsonant(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x62, 0x63, 0x64, 0x66, 0x67, 0x68, 0x6A, 0x6B, 0x6C, 0x6D,
             0x6E, 0x70, 0x71, 0x72, 0x73, 0x74, 0x76, 0x77, 0x78, 0x79, 0x7A:
            return true
        default:
            return false
        }
    }

    private static func splitLetterNumberTokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if isLetterOrNumber(scalar) {
                current.append(scalar)
            } else if !current.isEmpty {
                tokens.append(String(current))
                current = String.UnicodeScalarView()
            }
        }
        if !current.isEmpty {
            tokens.append(String(current))
        }
        return tokens
    }

    private static func utf16IndexOf(_ needle: String, in haystack: String) -> Int? {
        guard !needle.isEmpty else { return 0 }
        guard let range = haystack.range(of: needle) else { return nil }
        return haystack.utf16.distance(from: haystack.utf16.startIndex, to: range.lowerBound)
    }

    private static func collapseWhitespace(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var pendingSpace = false
        for char in text {
            if char.isWhitespace {
                if !result.isEmpty { pendingSpace = true }
            } else {
                if pendingSpace {
                    result.append(" ")
                    pendingSpace = false
                }
                result.append(char)
            }
        }
        return result
    }

    private static func sliceUTF16Prefix(_ text: String, maxLength: Int) -> String {
        let units = Array(text.utf16)
        guard units.count > maxLength else { return text }
        return String(decoding: units[0..<maxLength], as: UTF16.self)
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    private static func cap(_ text: String?, max: Int) -> String? {
        guard let text, !text.isEmpty else { return nil }
        let units = Array(text.utf16)
        guard units.count > max else { return text }
        let prefix = String(decoding: units[0..<max], as: UTF16.self)
        return "\(prefix)… [\(units.count - max) more chars]"
    }

    private static func clamp(_ value: Int, min minValue: Int, max maxValue: Int) -> Int {
        Swift.min(maxValue, Swift.max(minValue, value))
    }
}
