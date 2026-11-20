#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

// MARK: - Session Search Index (`core/src/session/search-index.ts`)

/// A full-text index of session titles and message text that SQLite maintains itself. Triggers on the source tables
/// reindex changed rows from the `session_search_source` view, so the extraction rules live in one place and no process
/// has to keep up. The `compact` layout is a contentless FTS5 table that removes entries by rowid (contentless_delete,
/// SQLite 3.43+). Older SQLite needs the indexed text to remove an entry, so the `text` layout keeps it in
/// `session_search_document`, at about three times the size. Nothing here uses `->>`: SQLite before 3.38 could not even
/// open a schema containing it.
public enum SessionSearchIndex {
    /// Bump when the columns, tokenizer, triggers or extracted text change, so `ensure` rebuilds.
    // parity: core/src/session/search-index.ts#Version [status=implemented hash=08ce94e77443]
    public static let version = 1

    // parity: core/src/session/search-index.ts#Layout [status=implemented hash=93ad109a62b5]
    public enum Layout: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
        case compact
        case text
    }

    /// Whether each message type's text is indexed. Exhaustive over `SessionMessageSchema.MessageType`: a new type
    /// fails to compile here until it is decided.
    // parity: core/src/session/search-index.ts#MessageTypes [status=adapted hash=7cb05839ae36]
    public static func indexes(_ type: SessionMessageSchema.MessageType) -> Bool {
        switch type {
        case .user: return true
        case .assistant: return true
        case .compaction: return true
        case .agentSelected: return false
        case .modelSelected: return false
        case .locationSwitched: return false
        case .synthetic: return false
        case .system: return false
        case .skill: return false
        case .shell: return false
        case .idle: return false
        }
    }

    /// Characters indexed per column. Longer text is nearly always a pasted log or file; its start is enough to find it.
    // parity: core/src/session/search-index.ts#MaxText [status=implemented hash=855c5fc2e285]
    public static let maxText = 64 * 1024

    /// Stored bytes a build chunk reads at most, beyond its first message.
    // parity: core/src/session/search-index.ts#MaxChunkBytes [status=implemented hash=74182763d8bb]
    public static let maxChunkBytes = 1024 * 1024

    // parity: core/src/session/search-index.ts#ChunkLimit [status=implemented hash=1d319925e253]
    public static let chunkLimit = 50

    // parity: core/src/session/search-index.ts#State [status=implemented hash=e3427da7efb5]
    public struct State: Equatable, Hashable, Sendable, Codable {
        public enum Status: String, Equatable, Hashable, Sendable, Codable {
            case building
            case done
            case failed
        }

        /// Titles go first, ascending ID (newest first); then messages, descending ID (newest first).
        public enum Phase: String, Equatable, Hashable, Sendable, Codable {
            case titles
            case messages
        }

        public var version: Int
        public var layout: Layout
        public var status: Status
        public var phase: Phase
        public var after: String?
        /// Sessions and messages visited, of `total` counted when the build started.
        public var processed: Int
        public var total: Int
        public var skipped: Int
        public var error: String?

        public init(
            version: Int,
            layout: Layout,
            status: Status,
            phase: Phase,
            after: String? = nil,
            processed: Int,
            total: Int,
            skipped: Int,
            error: String? = nil
        ) {
            self.version = version
            self.layout = layout
            self.status = status
            self.phase = phase
            self.after = after
            self.processed = processed
            self.total = total
            self.skipped = skipped
            self.error = error
        }
    }

    // parity: core/src/session/search-index.ts#Ensured [status=implemented hash=ddac89b4f72e]
    public enum Ensured: Equatable, Sendable {
        case newer
        case unsupported(reason: String)
        case ready(state: State)
    }

    /// A stored state: the full state when this version can decode it, otherwise only its version, so a newer index is
    /// still recognized.
    public enum StoredState: Equatable, Sendable {
        case state(State)
        case versionOnly(Int)

        public var version: Int {
            switch self {
            case .state(let state): return state.version
            case .versionOnly(let version): return version
            }
        }
    }

    /// Creates the index and its triggers, or recreates them when the version is older or an object is gone, and starts a
    /// build. An index from a newer version is left alone so two versions sharing a database don't keep rebuilding it.
    // parity: core/src/session/search-index.ts#ensure [status=implemented hash=5e2850146633]
    public static func ensure(_ db: any SQLiteDatabase) throws -> Ensured {
        let objects = try db.query(
            "SELECT name FROM sqlite_master WHERE name GLOB 'session_search*' AND type IN ('table', 'view', 'trigger')",
            parameters: []
        )
        let names = Set(objects.compactMap { $0.string("name") })
        if let unsupported = try probe(db, index: names.contains("session_search")) {
            return .unsupported(reason: unsupported)
        }
        let before = try readState(db)
        if let before, before.version > version { return .newer }
        if let state = current(before), expected(state.layout).allSatisfy(names.contains) {
            return .ready(state: state)
        }
        // An index this version built keeps its layout while this SQLite can still create it.
        var kept: Layout? = nil
        if let state = current(before), try creatable(db, state.layout) == nil {
            kept = state.layout
        }
        let layout: Layout
        if let kept {
            layout = kept
        } else {
            switch try pick(db) {
            case .success(let picked): layout = picked
            case .failure(let reason): return .unsupported(reason: reason.reason)
            }
        }
        return try immediate(db) {
            // Another server may have rebuilt it meanwhile.
            let state = try readState(db)
            if let state, state.version > version { return .newer }
            let present = Set(try db.query("SELECT name FROM sqlite_master WHERE name GLOB 'session_search*'", parameters: [])
                .compactMap { $0.string("name") })
            if let state = current(state), state.layout == layout, expected(layout).allSatisfy(present.contains) {
                return .ready(state: state)
            }
            try reset(db, layout)
            let next = State(
                version: version,
                layout: layout,
                status: .building,
                phase: .titles,
                processed: 0,
                total: try total(db),
                skipped: 0
            )
            try writeState(db, next)
            return .ready(state: next)
        }
    }

    public struct ChunkResult: Equatable, Hashable, Sendable {
        public let done: Bool

        public init(done: Bool) {
            self.done = done
        }
    }

    /// Indexes the next chunk of the build and advances the cursor in the same IMMEDIATE transaction, so concurrent
    /// servers share one cursor. Titles are indexed 50 at a time; messages also stop at `maxChunkBytes` of stored rows,
    /// the first always fitting. `skip` passes the next row without indexing it, for a row that fails on its own.
    // parity: core/src/session/search-index.ts#buildChunk [status=implemented hash=0eef64fa57ea]
    public static func buildChunk(_ db: any SQLiteDatabase, limit: Int? = nil, skip: Bool = false) throws -> ChunkResult {
        let limit = limit ?? chunkLimit
        return try immediate(db) {
            guard let state = current(try readState(db)), state.status == .building else { return ChunkResult(done: true) }
            func counted(_ next: inout State, _ visited: Int) {
                next.processed = state.processed + visited
                if skip { next.skipped = state.skipped + visited }
            }
            if state.phase == .titles {
                // Session IDs descend over time, so ascending order is newest first.
                let rows: [SQLiteRow]
                if let after = state.after {
                    rows = try db.query(
                        "SELECT id FROM session_v2 WHERE id > ? ORDER BY id LIMIT ?",
                        parameters: [.text(after), .integer(Int64(limit))]
                    )
                } else {
                    rows = try db.query(
                        "SELECT id FROM session_v2 WHERE 1 = 1 ORDER BY id LIMIT ?",
                        parameters: [.integer(Int64(limit))]
                    )
                }
                let ids = rows.compactMap { $0.string("id") }
                if !ids.isEmpty && !skip {
                    try reindexBatch(db, state.layout, ids.map { (id: $0, session: $0) })
                }
                var next = state
                counted(&next, ids.count)
                if ids.count < limit {
                    next.phase = .messages
                    next.after = nil
                } else {
                    next.after = ids.last
                }
                try writeState(db, next)
                return ChunkResult(done: false)
            }
            // Message IDs ascend over time, so descending order is newest first. `octet_length` reads only the record
            // header but needs SQLite 3.43+, like the compact layout.
            let size = state.layout == .compact ? "octet_length" : "length"
            let before = state.after == nil ? "1 = 1" : "id < ?"
            let sql = """
                SELECT message.id, message.session_id AS session,
                  CASE WHEN message.type IN (\(indexed)) THEN 1 ELSE 0 END AS indexed,
                  CASE WHEN message.type IN (\(indexed)) THEN \(size)(message.data) + coalesce((
                    SELECT sum(\(size)(part.data)) FROM session_part AS part WHERE part.message_id = message.id
                  ), 0) ELSE 0 END AS bytes
                FROM session_message AS message WHERE \(before)
                ORDER BY message.id DESC LIMIT ?
                """
            var parameters: [SQLiteValue] = []
            if let after = state.after { parameters.append(.text(after)) }
            parameters.append(.integer(Int64(limit)))
            let candidates = try db.query(sql, parameters: parameters).map { row in
                Candidate(
                    id: row.string("id") ?? "",
                    session: row.string("session") ?? "",
                    indexed: row.int64("indexed") == 1,
                    bytes: Int(row.int64("bytes") ?? 0)
                )
            }
            let picked = budget(candidates)
            let indexedRows = picked.filter(\.indexed)
            if !indexedRows.isEmpty && !skip {
                try reindexBatch(db, state.layout, indexedRows.map { (id: $0.id, session: $0.session) })
            }
            let done = picked.last == nil || (candidates.count < limit && picked.count == candidates.count)
            var next = state
            counted(&next, picked.count)
            if done {
                next.status = .done
            } else {
                next.after = picked.last?.id
            }
            try writeState(db, next)
            return ChunkResult(done: done)
        }
    }

    /// Marks the build failed for this version, so it is not retried until the version changes or `retry`.
    // parity: core/src/session/search-index.ts#fail [status=implemented hash=b238e806e65c]
    public static func fail(_ db: any SQLiteDatabase, error: String) throws {
        try update(db) { state in
            guard state.status == .building else { return nil }
            var next = state
            next.status = .failed
            next.error = error
            return next
        }
    }

    /// Restarts a failed build from the beginning: rows skipped just before it failed were probably victims of the same
    /// failure. Reindexing replaces existing entries, so the index stays usable meanwhile.
    // parity: core/src/session/search-index.ts#retry [status=implemented hash=bee5619226d8]
    public static func retry(_ db: any SQLiteDatabase) throws {
        try update(db) { state in
            guard state.status == .failed else { return nil }
            var next = state
            next.status = .building
            next.phase = .titles
            next.after = nil
            next.processed = 0
            next.skipped = 0
            next.error = nil
            return next
        }
    }

    // parity: core/src/session/search-index.ts#state [status=implemented hash=c319acc64a67]
    public static func state(_ db: any SQLiteDatabase) throws -> StoredState? {
        try readState(db)
    }

    /// SQLITE_BUSY or SQLITE_LOCKED: another connection held the write lock past busy_timeout. Worth waiting out, unlike
    /// a failing row.
    // parity: core/src/session/search-index.ts#isBusy [status=implemented hash=52b3e659d775]
    public static func isBusy(_ error: any Swift.Error) -> Bool {
        let code = primaryCode(error)
        return code == 5 || code == 6
    }

    /// A state this version wrote and can read.
    // parity: core/src/session/search-index.ts#current [status=implemented hash=5110492fec54]
    public static func current(_ state: StoredState?) -> State? {
        guard case .state(let value) = state, value.version == version else { return nil }
        return value
    }

    // MARK: Internals

    private struct Candidate {
        let id: String
        let session: String
        let indexed: Bool
        let bytes: Int
    }

    private struct UnsupportedReason: Swift.Error {
        let reason: String
    }

    static let columns = "title, summary, user_text, assistant_text"
    private static let tokenizer = "tokenize='porter unicode61 remove_diacritics 2'"
    private static let indexed: String = SessionMessageSchema.MessageType.allCases
        .filter(indexes)
        .map { "'\($0.rawValue)'" }
        .joined(separator: ", ")

    /// Letters the tokenizer's remove_diacritics leaves alone because they aren't a base letter plus a mark, as in
    /// Lucene's ASCII folding: "hóa đơn" is indexed as "hoa don". A search has to fold its words the same way.
    static let folds: [(String, String)] = [
        ("đ", "d"), ("Đ", "D"), ("ð", "d"), ("Ð", "D"), ("ł", "l"), ("Ł", "L"), ("ø", "o"), ("Ø", "O"),
        ("ħ", "h"), ("Ħ", "H"), ("ı", "i"), ("ŋ", "n"), ("Ŋ", "N"), ("ß", "ss"), ("æ", "ae"), ("Æ", "AE"),
        ("œ", "oe"), ("Œ", "OE"), ("þ", "th"), ("Þ", "TH"),
    ]

    private static func fold(_ column: String) -> String {
        let expression = folds.reduce(column) { text, pair in "replace(\(text), '\(pair.0)', '\(pair.1)')" }
        return "\(expression) AS \(column)"
    }

    /// One row per title or message with text to index: user text, a finished assistant's text (part rows, then inline
    /// content), a completed compaction's summary. Rows that are not JSON objects are passed rather than failing the
    /// write that queued them; each column keeps its first `maxText` characters.
    private static var sourceView: String {
        """
        CREATE VIEW session_search_source AS
        SELECT source_id, session_id, \(fold("title")), \(fold("summary")), \(fold("user_text")), \(fold("assistant_text")) FROM (
          SELECT id AS source_id, id AS session_id, substr(title, 1, \(maxText)) AS title, NULL AS summary, NULL AS user_text, NULL AS assistant_text
          FROM session_v2 WHERE trim(coalesce(title, '')) <> ''
          UNION ALL
          SELECT m.id, m.session_id, NULL,
            CASE WHEN m.type = 'compaction' AND json_extract(m.data, '$.status') = 'completed'
              THEN nullif(substr(json_extract(m.data, '$.summary'), 1, \(maxText)), '') END,
            CASE WHEN m.type = 'user' THEN nullif(substr(json_extract(m.data, '$.text'), 1, \(maxText)), '') END,
            CASE WHEN m.type = 'assistant' AND json_extract(m.data, '$.time.completed') IS NOT NULL THEN substr((
              SELECT group_concat(t, char(10) || char(10)) FROM (
                SELECT 0 AS o, p.ordinal AS k, substr(json_extract(p.data, '$.text'), 1, \(maxText)) AS t
                FROM session_part AS p WHERE p.message_id = m.id AND p.type = 'text' AND json_valid(p.data)
                UNION ALL
                SELECT 1, c.key, substr(json_extract(m.data, c.fullkey || '.text'), 1, \(maxText))
                FROM json_each(m.data, '$.content') AS c WHERE json_extract(m.data, c.fullkey || '.type') = 'text'
                ORDER BY 1, 2
              ) WHERE trim(t) <> ''
            ), 1, \(maxText)) END
          FROM session_message AS m
          WHERE m.type IN (\(indexed)) AND json_valid(m.data) AND json_type(m.data) = 'object'
        ) WHERE coalesce(title, summary, user_text, assistant_text) IS NOT NULL
        """
    }

    // OR and CASE short-circuit, so json_extract never sees invalid JSON.
    private static func finished(_ row: String) -> String {
        "(\(row).type <> 'assistant' OR NOT json_valid(\(row).data) OR json_extract(\(row).data, '$.time.completed') IS NOT NULL)"
    }

    private static func parentFinished(_ row: String) -> String {
        "EXISTS (SELECT 1 FROM session_message AS m WHERE m.id = \(row).message_id AND m.type = 'assistant' AND json_valid(m.data) AND json_extract(m.data, '$.time.completed') IS NOT NULL)"
    }

    private static func remove(_ layout: Layout, _ id: String) -> String {
        switch layout {
        case .compact:
            return """
                DELETE FROM session_search WHERE rowid = (SELECT id FROM session_search_document WHERE source_id = \(id));
                       DELETE FROM session_search_document WHERE source_id = \(id);
                """
        case .text:
            return "DELETE FROM session_search_document WHERE source_id = \(id);"
        }
    }

    // Compact inserts a document row per existing source, even one without text, so the index row can be written from
    // one view read. Each read filters by `source.source_id` so SQLite pushes it into both arms of
    // `session_search_source`.
    private static func reindex(_ layout: Layout, _ id: String, _ session: String) -> String {
        switch layout {
        case .compact:
            return """
                \(remove(.compact, id))
                       INSERT INTO session_search_document (source_id, session_id) VALUES (\(id), \(session));
                       INSERT INTO session_search (rowid, \(columns))
                         SELECT document.id, source.title, source.summary, source.user_text, source.assistant_text
                         FROM session_search_source AS source, session_search_document AS document
                         WHERE source.source_id = \(id) AND document.source_id = \(id);
                """
        case .text:
            return """
                DELETE FROM session_search_document WHERE source_id = \(id);
                       INSERT INTO session_search_document (source_id, session_id, \(columns))
                         SELECT source_id, session_id, \(columns) FROM session_search_source WHERE source_id = \(id);
                """
        }
    }

    /// A streaming assistant is not indexed until it finishes, so it keeps its last finished text meanwhile. Ordered as
    /// upstream declares them.
    private static func sourceTriggers(_ layout: Layout) -> [(String, String)] {
        [
            ("session_search_message_insert", "AFTER INSERT ON session_message WHEN NEW.type IN (\(indexed)) AND \(finished("NEW")) BEGIN \(reindex(layout, "NEW.id", "NEW.session_id")) END"),
            ("session_search_message_update", "AFTER UPDATE OF type, data ON session_message WHEN (NEW.type IN (\(indexed)) AND \(finished("NEW"))) OR (OLD.type IN (\(indexed)) AND NEW.type NOT IN (\(indexed))) BEGIN \(reindex(layout, "NEW.id", "NEW.session_id")) END"),
            ("session_search_message_delete", "AFTER DELETE ON session_message WHEN OLD.type IN (\(indexed)) BEGIN \(remove(layout, "OLD.id")) END"),
            ("session_search_part_insert", "AFTER INSERT ON session_part WHEN NEW.type = 'text' AND \(parentFinished("NEW")) BEGIN \(reindex(layout, "NEW.message_id", "NEW.session_id")) END"),
            ("session_search_part_update", "AFTER UPDATE OF type, data, ordinal ON session_part WHEN (NEW.type = 'text' OR OLD.type = 'text') AND \(parentFinished("NEW")) BEGIN \(reindex(layout, "NEW.message_id", "NEW.session_id")) END"),
            // In a cascade from session_message or session_v2, the parent row is already gone, so this is skipped and
            // the message's own trigger removes the entry.
            ("session_search_part_delete", "AFTER DELETE ON session_part WHEN OLD.type = 'text' AND EXISTS (SELECT 1 FROM session_v2 AS s WHERE s.id = OLD.session_id) AND \(parentFinished("OLD")) BEGIN \(reindex(layout, "OLD.message_id", "OLD.session_id")) END"),
            ("session_search_session_insert", "AFTER INSERT ON session_v2 WHEN trim(coalesce(NEW.title, '')) <> '' BEGIN \(reindex(layout, "NEW.id", "NEW.id")) END"),
            ("session_search_session_update", "AFTER UPDATE OF title ON session_v2 WHEN NEW.title IS NOT OLD.title BEGIN \(reindex(layout, "NEW.id", "NEW.id")) END"),
            ("session_search_session_delete", "AFTER DELETE ON session_v2 BEGIN \(remove(layout, "OLD.id")) END"),
        ]
    }

    private static func fts(_ name: String, _ layout: Layout) -> String {
        switch layout {
        case .compact:
            return "CREATE VIRTUAL TABLE \(name) USING fts5(\(columns), content='', contentless_delete=1, \(tokenizer))"
        case .text:
            return "CREATE VIRTUAL TABLE \(name) USING fts5(\(columns), content='session_search_document', content_rowid='id', \(tokenizer))"
        }
    }

    /// Per layout: the document table.
    private static func documentTable(_ layout: Layout) -> String {
        switch layout {
        case .compact:
            return "CREATE TABLE session_search_document (id INTEGER PRIMARY KEY, source_id TEXT NOT NULL UNIQUE, session_id TEXT NOT NULL)"
        case .text:
            return "CREATE TABLE session_search_document (id INTEGER PRIMARY KEY, source_id TEXT NOT NULL UNIQUE, session_id TEXT NOT NULL, \(columns))"
        }
    }

    /// Per layout: any triggers on the document table. External content: removing an entry takes the text it was
    /// indexed with.
    private static func layoutTriggers(_ layout: Layout) -> [(String, String)] {
        switch layout {
        case .compact:
            return []
        case .text:
            return [
                ("session_search_document_insert", """
                    AFTER INSERT ON session_search_document BEGIN
                            INSERT INTO session_search (rowid, \(columns)) VALUES (NEW.id, NEW.title, NEW.summary, NEW.user_text, NEW.assistant_text);
                          END
                    """),
                ("session_search_document_delete", """
                    AFTER DELETE ON session_search_document BEGIN
                            INSERT INTO session_search (session_search, rowid, \(columns)) VALUES ('delete', OLD.id, OLD.title, OLD.summary, OLD.user_text, OLD.assistant_text);
                          END
                    """),
            ]
        }
    }

    private static let tables = ["session_search", "session_search_document"]

    static func expected(_ layout: Layout) -> [String] {
        tables + ["session_search_source"] + sourceTriggers(layout).map(\.0) + layoutTriggers(layout).map(\.0)
    }

    private static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }

    /// Bulk-reindexes a batch of sources using bound `IN (?, ...)` lists (not subqueries) on `source.source_id`, so
    /// SQLite pushes `id = ?` into both arms of `session_search_source` on SQLite < 3.46 as well.
    private static func reindexBatch(
        _ db: any SQLiteDatabase,
        _ layout: Layout,
        _ rows: [(id: String, session: String)]
    ) throws {
        var start = 0
        while start < rows.count {
            let batch = Array(rows[start..<min(rows.count, start + chunkLimit)])
            start += chunkLimit
            let ids: [SQLiteValue] = batch.map { .text($0.id) }
            let list = placeholders(batch.count)
            if layout == .text {
                _ = try db.execute("DELETE FROM session_search_document WHERE source_id IN (\(list))", parameters: ids)
                _ = try db.execute(
                    """
                    INSERT INTO session_search_document (source_id, session_id, \(columns))
                    SELECT source_id, session_id, \(columns) FROM session_search_source WHERE source_id IN (\(list))
                    """,
                    parameters: ids
                )
                continue
            }
            let values = Array(repeating: "(?, ?)", count: batch.count).joined(separator: ", ")
            let valueParameters: [SQLiteValue] = batch.flatMap { [SQLiteValue.text($0.id), .text($0.session)] }
            _ = try db.execute(
                "DELETE FROM session_search WHERE rowid IN (SELECT id FROM session_search_document WHERE source_id IN (\(list)))",
                parameters: ids
            )
            _ = try db.execute("DELETE FROM session_search_document WHERE source_id IN (\(list))", parameters: ids)
            _ = try db.execute("INSERT INTO session_search_document (source_id, session_id) VALUES \(values)", parameters: valueParameters)
            _ = try db.execute(
                """
                INSERT INTO session_search (rowid, \(columns))
                SELECT document.id, source.title, source.summary, source.user_text, source.assistant_text
                FROM session_search_source AS source
                JOIN session_search_document AS document ON document.source_id = source.source_id
                WHERE source.source_id IN (\(list))
                """,
                parameters: ids
            )
        }
    }

    private static func reset(_ db: any SQLiteDatabase, _ layout: Layout) throws {
        try unlink(db)
        for name in tables { _ = try db.execute("DROP TABLE IF EXISTS \(name)", parameters: []) }
        _ = try db.execute(documentTable(layout), parameters: [])
        _ = try db.execute(fts("session_search", layout), parameters: [])
        try link(db, layout)
    }

    /// Drops the view and every search trigger.
    private static func unlink(_ db: any SQLiteDatabase) throws {
        let triggers = try db.query(
            "SELECT name FROM sqlite_master WHERE type = 'trigger' AND name GLOB 'session_search*'",
            parameters: []
        )
        for row in triggers {
            if let name = row.string("name") { _ = try db.execute("DROP TRIGGER \(name)", parameters: []) }
        }
        _ = try db.execute("DROP VIEW IF EXISTS session_search_source", parameters: [])
    }

    private static func link(_ db: any SQLiteDatabase, _ layout: Layout) throws {
        _ = try db.execute(sourceView, parameters: [])
        for (name, body) in layoutTriggers(layout) + sourceTriggers(layout) {
            _ = try db.execute("CREATE TRIGGER \(name) \(body)", parameters: [])
        }
    }

    private static func total(_ db: any SQLiteDatabase) throws -> Int {
        let row = try db.queryOne(
            "SELECT (SELECT count(*) FROM session_v2) + (SELECT count(*) FROM session_message) AS count",
            parameters: []
        )
        return Int(row?.int64("count") ?? 0)
    }

    /// Batches read, then write. A deferred transaction that has read gets SQLITE_BUSY at once when it needs the write
    /// lock while another connection writes, skipping busy_timeout; IMMEDIATE takes the lock up front and waits instead.
    /// `SQLiteDatabase.transaction` opens with `BEGIN IMMEDIATE` on a writable connection.
    private static func immediate<T>(_ db: any SQLiteDatabase, _ body: () throws -> T) throws -> T {
        try db.transaction(body)
    }

    /// The triggers read sources with the JSON functions, and the index must open. Returns why not, if not.
    private static func probe(_ db: any SQLiteDatabase, index: Bool) throws -> String? {
        if let json = try capability({
            _ = try db.query(
                "SELECT json_extract('{\"a\":[1]}', '$.a'), json_valid('{}'), json_type('{}'), (SELECT count(*) FROM json_each('[1]'))",
                parameters: []
            )
        }) {
            return json
        }
        if !index { return nil }
        return try capability { _ = try db.query("SELECT rowid FROM session_search WHERE rowid = 0", parameters: []) }
    }

    private static func pick(_ db: any SQLiteDatabase) throws -> Result<Layout, UnsupportedReason> {
        if try creatable(db, .compact) == nil { return .success(.compact) }
        if let reason = try creatable(db, .text) { return .failure(UnsupportedReason(reason: reason)) }
        return .success(.text)
    }

    /// Nil when this SQLite can create the layout's FTS table, otherwise why not.
    private static func creatable(_ db: any SQLiteDatabase, _ layout: Layout) throws -> String? {
        try capability {
            try db.transaction {
                _ = try db.execute(fts("session_search_probe", layout), parameters: [])
                _ = try db.execute("DROP TABLE session_search_probe", parameters: [])
            }
        }
    }

    /// Only a generic SQLITE_ERROR (unknown module, option or function) means unsupported; locks, read-only files and
    /// corruption are rethrown. A driver without the statement at all (the WASI fallback) is unsupported too.
    private static func capability(_ body: () throws -> Void) throws -> String? {
        do {
            try body()
            return nil
        } catch let error as SQLiteError {
            if case .unsupportedSQL = error { return error.description }
            guard primaryCode(error) == 1 else { throw error }
            return sqliteMessage(error) ?? error.description
        }
    }

    private static func sqliteMessage(_ error: SQLiteError) -> String? {
        switch error {
        case .prepareFailed(_, _, let message), .stepFailed(_, _, let message), .executionFailed(_, _, let message):
            return message
        default:
            return nil
        }
    }

    /// The SQLite primary result code (extended code & 0xff) of a driver error.
    private static func primaryCode(_ error: any Swift.Error) -> Int32? {
        guard let error = error as? SQLiteError else { return nil }
        switch error {
        case .openFailed(_, let code, _), .prepareFailed(_, let code, _), .bindFailed(_, let code, _),
            .stepFailed(_, let code, _), .executionFailed(_, let code, _), .constraintViolation(let code, _):
            return code & 0xff
        default:
            return nil
        }
    }

    private static let stateKey = "session.search"

    private struct VersionOnly: Decodable {
        let version: Int
    }

    /// A state this version can't decode still reports its version, so a newer index is recognized.
    private static func readState(_ db: any SQLiteDatabase) throws -> StoredState? {
        guard let row = try db.queryOne("SELECT value FROM kv WHERE key = ?", parameters: [.text(stateKey)]),
              let value = row.string("value")
        else { return nil }
        let data = Data(value.utf8)
        if let state = try? JSONDecoder().decode(State.self, from: data) { return .state(state) }
        if let version = try? JSONDecoder().decode(VersionOnly.self, from: data) { return .versionOnly(version.version) }
        return nil
    }

    private static func writeState(_ db: any SQLiteDatabase, _ state: State) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let value = String(decoding: try encoder.encode(state), as: UTF8.self)
        let now = Int64(Flock.currentEpochMs())
        _ = try db.execute(
            """
            INSERT INTO kv (key, value, time_created, time_updated) VALUES (?, ?, ?, ?)
            ON CONFLICT (key) DO UPDATE SET value = excluded.value, time_updated = ?
            """,
            parameters: [.text(stateKey), .text(value), .integer(now), .integer(now), .integer(now)]
        )
    }

    private static func update(_ db: any SQLiteDatabase, _ change: (State) -> State?) throws {
        try immediate(db) {
            guard let state = current(try readState(db)), let next = change(state) else { return }
            try writeState(db, next)
        }
    }

    /// The first message always fits, so a larger one still progresses.
    private static func budget(_ rows: [Candidate]) -> [Candidate] {
        var picked: [Candidate] = []
        var bytes = 0
        for row in rows {
            if !picked.isEmpty && bytes + row.bytes > maxChunkBytes { break }
            picked.append(row)
            bytes += row.bytes
        }
        return picked
    }
}

// MARK: - Session Search Build (`core/src/session/search-build.ts`)

public enum SessionSearchBuild {
    // parity: core/src/session/search-build.ts#Interface [status=adapted hash=cd781bf01743]
    public protocol Interface: Sendable {
        /// Waits for `start`, then runs the one-time build of existing history until it is done, from its persisted
        /// cursor; triggers keep the index current after that. The server runs it once per process. A build that
        /// failed before is retried once.
        func run() async
        /// Lets `run` go, once a location has the `sqlite_fts` flag on. Later calls do nothing.
        func start() async
    }

    public enum Outcome: String, Equatable, Hashable, Sendable {
        case done
        case failed
    }

    /// Pause between transactions so requests waiting on the write lock get a turn.
    static let pauseNanoseconds: UInt64 = 5_000_000
    static let busyNanoseconds: UInt64 = 1_000_000_000
    /// Rows in a row that fail on their own before the failure is taken to be the database's, not the rows'.
    static let maxFailures = 3

    /// A one-shot gate: `wait` suspends until `open`, which releases every waiter and every later `wait` at once. A
    /// cancelled waiter is released too, and then sees its cancellation.
    actor Latch {
        private var opened = false
        private var nextID = 0
        private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]

        func open() {
            guard !opened else { return }
            opened = true
            let pending = waiters.values
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }

        func wait() async {
            if opened { return }
            let id = nextID
            nextID += 1
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    if opened || Task.isCancelled {
                        continuation.resume()
                    } else {
                        waiters[id] = continuation
                    }
                }
            } onCancel: {
                Task { await self.cancel(id) }
            }
        }

        private func cancel(_ id: Int) {
            waiters.removeValue(forKey: id)?.resume()
        }
    }

    // parity: core/src/session/search-build.ts#Service [status=adapted hash=ac03e046075c]
    public final class Service: Interface, Sendable {
        public static let serviceKey = "@opencode/SessionSearchBuild"

        private let db: any SQLiteDatabase
        private let started = Latch()
        private let log: (any LogSink)?

        public init(db: any SQLiteDatabase, log: (any LogSink)? = nil) {
            self.db = db
            self.log = log
        }

        public func start() async {
            await started.open()
        }

        public func run() async {
            await started.wait()
            if Task.isCancelled { return }
            do {
                let ensured = try await retryOnBusy { try SessionSearchIndex.ensure(self.db) }
                switch ensured {
                case .unsupported(let reason):
                    await emit(.warn, "session search is not supported by this SQLite", ["reason": reason])
                    return
                case .newer:
                    return
                case .ready(let state):
                    if state.status == .done { return }
                    if state.status == .failed {
                        try await retryOnBusy { try SessionSearchIndex.retry(self.db) }
                    }
                }
                _ = try await build()
            } catch is CancellationError {
                return
            } catch {
                await emit(.error, "session search build stopped", ["cause": String(describing: error)])
            }
        }

        /// Runs the build to its end and reports how it ended.
        @discardableResult
        func build() async throws -> Outcome {
            let begun = Flock.currentEpochMs()
            var chunks = 0
            var slowest: Int64 = 0
            var single = 0
            var failures = 0
            await emit(.info, "session search build started", [:])
            while true {
                try Task.checkCancellation()
                // A row that fails on its own is retried alone, so one bad row only skips itself.
                let limit = single > 0 ? 1 : nil
                do {
                    let chunkStart = Flock.currentEpochMs()
                    let result = try await retryOnBusy { try SessionSearchIndex.buildChunk(self.db, limit: limit) }
                    chunks += 1
                    slowest = max(slowest, Flock.currentEpochMs() - chunkStart)
                    single = max(0, single - 1)
                    failures = 0
                    if result.done {
                        let state = try await retryOnBusy { try SessionSearchIndex.state(self.db) }
                        let skipped: Int
                        if case .state(let value) = state { skipped = value.skipped } else { skipped = 0 }
                        await emit(.info, "session search build finished", [
                            "ms": String(Flock.currentEpochMs() - begun),
                            "chunks": String(chunks),
                            "slowestChunkMs": String(slowest),
                            "skipped": String(skipped),
                        ])
                        return .done
                    }
                    try await Task.sleep(nanoseconds: SessionSearchBuild.pauseNanoseconds)
                    continue
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    if single == 0 {
                        single = SessionSearchIndex.chunkLimit
                        continue
                    }
                    failures += 1
                    if failures >= SessionSearchBuild.maxFailures {
                        let message = String(describing: error)
                        try await retryOnBusy { try SessionSearchIndex.fail(self.db, error: message) }
                        await emit(.error, "session search build failed", ["cause": message])
                        return .failed
                    }
                    await emit(.warn, "session search skipped a row it could not index", ["cause": String(describing: error)])
                    _ = try await retryOnBusy { try SessionSearchIndex.buildChunk(self.db, limit: 1, skip: true) }
                }
            }
        }

        /// Waits out SQLITE_BUSY/SQLITE_LOCKED, retrying after a second each time; other failures propagate.
        private func retryOnBusy<T>(_ body: @Sendable () throws -> T) async throws -> T {
            while true {
                do {
                    return try body()
                } catch {
                    guard SessionSearchIndex.isBusy(error) else { throw error }
                    try await Task.sleep(nanoseconds: SessionSearchBuild.busyNanoseconds)
                }
            }
        }

        private func emit(_ level: OpenCodeLogLevel, _ message: String, _ fields: [String: String]) async {
            guard let log else { return }
            await log.log(StructuredLogRecord(
                timestamp: String(Flock.currentEpochMs()),
                level: level,
                message: message,
                fields: fields.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
            ))
        }
    }

    // parity: core/src/session/search-build.ts#layer [status=adapted hash=9278df9054d2]
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

    // parity: core/src/session/search-build.ts#node [status=adapted hash=b827f9c24490]
    public static let node: LayerNode.Provider = AppNode.makeGlobalNode(
        Service.serviceKey,
        layer,
        [CoreDatabaseStore.node]
    )
}
