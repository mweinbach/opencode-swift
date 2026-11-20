import Synchronization
import Testing
import OpenCodePlatform
import OpenCodeUtil

private struct SyntheticTestError: Error, Equatable, Sendable {
    let reason: String
}

@Suite("Phase 2 Cross-Platform Runtime Engines Tests")
struct PlatformPhase2Tests {

    // MARK: - HTTP Transport (MockHTTPTransport + URLSessionHTTPTransport)

    @Test("MockHTTPTransport records requests, serves FIFO stubs, fallbacks, and errors")
    func mockHTTPTransportUnary() async throws {
        let mock = MockHTTPTransport()
        mock.enqueueResponse(statusCode: 201, headers: ["X-Test": "alpha"], text: "created")
        mock.enqueueError(HTTPTransportError.networkFailure("offline"))
        #expect(mock.remainingStubCount == 2)

        let req1 = HTTPRequest(method: "POST", url: "https://api.example.test/v1/items", headers: ["Authorization": "Bearer secret"], body: Array("{\"k\":1}".utf8))
        let res1 = try await mock.send(req1)
        #expect(res1.head.statusCode == 201)
        #expect(res1.head.headers["X-Test"] == "alpha")
        #expect(String(decoding: res1.body, as: UTF8.self) == "created")

        let req2 = HTTPRequest(method: "GET", url: "https://api.example.test/v1/fail")
        await #expect(throws: HTTPTransportError.networkFailure("offline")) {
            _ = try await mock.send(req2)
        }

        // Empty queue without fallback throws noStubbedResponse
        let req3 = HTTPRequest(method: "GET", url: "https://api.example.test/v1/empty")
        await #expect(throws: HTTPTransportError.noStubbedResponse(method: "GET", url: "https://api.example.test/v1/empty")) {
            _ = try await mock.send(req3)
        }

        // Fallback handler activates when queue is empty
        mock.setFallbackHandler { req in
            HTTPResponse(
                head: HTTPResponseHead(statusCode: 200, headers: ["X-Fallback": req.method]),
                body: Array(req.url.utf8)
            )
        }
        let res4 = try await mock.send(HTTPRequest(method: "DELETE", url: "https://api.example.test/v1/42"))
        #expect(res4.head.statusCode == 200)
        #expect(res4.head.headers["X-Fallback"] == "DELETE")
        #expect(String(decoding: res4.body, as: UTF8.self) == "https://api.example.test/v1/42")

        #expect(mock.recordedRequests.count == 4)
        #expect(mock.recordedRequests[0] == req1)
        #expect(mock.recordedRequests[1] == req2)
        #expect(mock.recordedRequests[2] == req3)

        mock.reset()
        #expect(mock.recordedRequests.isEmpty)
        #expect(mock.remainingStubCount == 0)
    }

    @Test("MockHTTPTransport streams incremental chunks and propagates mid-stream errors")
    func mockHTTPTransportStreaming() async throws {
        let mock = MockHTTPTransport()
        mock.enqueueStream(
            statusCode: 200,
            headers: ["Content-Type": "text/event-stream"],
            chunks: [
                Array("data: chunk-1\n\n".utf8),
                Array("data: chunk-2\n\n".utf8),
                Array("data: [DONE]\n\n".utf8),
            ]
        )

        let streamResp = try await mock.stream(HTTPRequest(method: "POST", url: "https://llm.example.test/stream"))
        #expect(streamResp.head.statusCode == 200)
        #expect(streamResp.head.headers["Content-Type"] == "text/event-stream")

        var received: [String] = []
        for try await chunk in streamResp.chunks {
            received.append(String(decoding: chunk, as: UTF8.self))
        }
        #expect(received == ["data: chunk-1\n\n", "data: chunk-2\n\n", "data: [DONE]\n\n"])

        // Mid-stream trailing error after yielding initial chunk
        mock.enqueueStream(
            statusCode: 200,
            chunks: [Array("partial".utf8)],
            trailingError: SyntheticTestError(reason: "connection reset")
        )
        let failingStream = try await mock.stream(HTTPRequest(method: "GET", url: "https://llm.example.test/drop"))
        var sawPartial = false
        var caughtError: SyntheticTestError?
        do {
            for try await chunk in failingStream.chunks {
                if String(decoding: chunk, as: UTF8.self) == "partial" {
                    sawPartial = true
                }
            }
        } catch let err as SyntheticTestError {
            caughtError = err
        }
        #expect(sawPartial)
        #expect(caughtError == SyntheticTestError(reason: "connection reset"))
    }

    @Test("URLSessionHTTPTransport validates URLs and performs real loopback send + incremental stream")
    func urlSessionHTTPTransportLoopback() async throws {
        let transport = URLSessionHTTPTransport(configuration: .init(
            timeoutIntervalForRequest: 5,
            timeoutIntervalForResource: 15,
            defaultHeaders: ["X-Client": "swift-opencode"]
        ))
        defer { transport.invalidateAndCancel() }

        await #expect(throws: HTTPTransportError.invalidURL("not a valid url")) {
            _ = try await transport.send(HTTPRequest(method: "GET", url: "not a valid url"))
        }

        guard let server = try PlatformPhase2Helper.LoopbackHTTPServer.start(handler: { requestText, write in
            if requestText.contains("GET /stream ") {
                let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
                write(Array(head.utf8))
                let c1 = "event: one\n\n"
                write(Array("\(String(c1.utf8.count, radix: 16))\r\n\(c1)\r\n".utf8))
                PlatformPhase2Helper.sleepMs(25)
                let c2 = "event: two\n\n"
                write(Array("\(String(c2.utf8.count, radix: 16))\r\n\(c2)\r\n".utf8))
                write(Array("0\r\n\r\n".utf8))
            } else {
                let body = "{\"ok\":true}"
                let resp = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nX-Echo: yes\r\nConnection: close\r\n\r\n\(body)"
                write(Array(resp.utf8))
            }
        }) else {
            return
        }
        defer { server.stop() }

        let unary = try await transport.send(HTTPRequest(
            method: "POST",
            url: "http://127.0.0.1:\(server.port)/unary",
            headers: ["X-Request": "123"],
            body: Array("ping".utf8)
        ))
        #expect(unary.head.statusCode == 200)
        #expect(String(decoding: unary.body, as: UTF8.self) == "{\"ok\":true}")

        let streaming = try await transport.stream(HTTPRequest(
            method: "GET",
            url: "http://127.0.0.1:\(server.port)/stream"
        ))
        #expect(streaming.head.statusCode == 200)
        var allBytes: [UInt8] = []
        var chunkCount = 0
        for try await chunk in streaming.chunks {
            chunkCount += 1
            allBytes.append(contentsOf: chunk)
        }
        #expect(chunkCount >= 1)
        #expect(String(decoding: allBytes, as: UTF8.self) == "event: one\n\nevent: two\n\n")
    }

    // MARK: - SQLite3 Database Engine (Native C SQLite3 + InMemorySQLiteFallback)

    @Test("NativeSQLiteDatabase creates WAL temp DB with parameterized CRUD, blobs, FK, savepoints, rollback, and migrations")
    func nativeSQLiteDatabaseComprehensive() throws {
        #if canImport(SQLite3)
        let dir = try PlatformPhase2Helper.makeTempDirectory(prefix: "opencode-sqlite")
        defer { PlatformPhase2Helper.removeItemIfExists(at: dir) }
        let dbPath = "\(dir)/state.sqlite"

        let db = try NativeSQLiteDatabase(path: dbPath)
        defer { try? db.close() }

        // Verify WAL mode, foreign_keys=ON, busy_timeout
        #expect(try db.currentJournalMode().lowercased() == "wal")
        #expect(try db.queryScalar("PRAGMA foreign_keys")?.int64Value == 1)
        #expect(try db.queryScalar("PRAGMA busy_timeout")?.int64Value == 5_000)

        // Migrations (applied once, idempotent on re-run)
        let migrations = [
            SQLiteMigration(
                version: 1,
                name: "create_sessions",
                sql: """
                CREATE TABLE sessions (
                    id TEXT PRIMARY KEY,
                    title TEXT NOT NULL,
                    score REAL,
                    count INTEGER NOT NULL,
                    payload BLOB,
                    note TEXT
                );
                """
            ),
            SQLiteMigration(
                version: 2,
                name: "create_messages",
                sql: """
                CREATE TABLE messages (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                    body TEXT NOT NULL
                );
                """
            ),
        ]
        #expect(try db.migrate(migrations) == [1, 2])
        #expect(try db.migrate(migrations) == [])
        #expect(try db.appliedMigrations() == [1, 2])

        // Parameterized INSERT with null, int64, double, text, non-empty blob, and empty blob
        let binaryPayload: [UInt8] = [0x00, 0x01, 0x7F, 0x80, 0xFF]
        let insertRes = try db.execute(
            "INSERT INTO sessions (id, title, score, count, payload, note) VALUES (?, ?, ?, ?, ?, ?)",
            parameters: [
                .text("ses_1"),
                .text("Phase 2 🚀"),
                .real(98.5),
                .integer(42),
                .blob(binaryPayload),
                .null,
            ]
        )
        #expect(insertRes.rowsAffected == 1)

        // Empty blob must stay .blob([]) and not turn into .null
        _ = try db.execute(
            "INSERT INTO sessions (id, title, score, count, payload, note) VALUES (?, ?, ?, ?, ?, ?)",
            parameters: [.text("ses_empty"), .text("Empty"), .null, .integer(0), .blob([]), .text("ok")]
        )

        let row1 = try #require(try db.queryOne("SELECT * FROM sessions WHERE id = ?", parameters: [.text("ses_1")]))
        #expect(row1.string("title") == "Phase 2 🚀")
        #expect(row1.double("score") == 98.5)
        #expect(row1.int64("count") == 42)
        #expect(row1.blob("payload") == binaryPayload)
        #expect(row1.isNull("note"))

        let rowEmpty = try #require(try db.queryOne("SELECT payload FROM sessions WHERE id = ?", parameters: [.text("ses_empty")]))
        #expect(rowEmpty[0] == .blob([]))

        // UPDATE & DELETE
        let updateRes = try db.execute(
            "UPDATE sessions SET count = ?, note = ? WHERE id = ?",
            parameters: [.integer(99), .text("updated"), .text("ses_1")]
        )
        #expect(updateRes.rowsAffected == 1)
        #expect(try db.queryScalar("SELECT count FROM sessions WHERE id = ?", parameters: [.text("ses_1")]) == .integer(99))

        // Foreign key enforcement
        #expect(throws: SQLiteError.self) {
            _ = try db.execute(
                "INSERT INTO messages (session_id, body) VALUES (?, ?)",
                parameters: [.text("ses_nonexistent"), .text("orphan")]
            )
        }
        _ = try db.execute(
            "INSERT INTO messages (session_id, body) VALUES (?, ?)",
            parameters: [.text("ses_1"), .text("hello world")]
        )
        #expect(try db.queryScalar("SELECT COUNT(*) FROM messages")?.int64Value == 1)

        // Transaction rollback on error
        #expect(throws: SyntheticTestError(reason: "abort tx")) {
            try db.transaction {
                _ = try db.execute(
                    "INSERT INTO messages (session_id, body) VALUES (?, ?)",
                    parameters: [.text("ses_1"), .text("should rollback")]
                )
                throw SyntheticTestError(reason: "abort tx")
            }
        }
        #expect(try db.queryScalar("SELECT COUNT(*) FROM messages")?.int64Value == 1)

        // Savepoint rollback inside committed outer transaction
        try db.transaction {
            _ = try db.execute(
                "INSERT INTO messages (session_id, body) VALUES (?, ?)",
                parameters: [.text("ses_1"), .text("kept outer")]
            )
            do {
                try db.savepoint("inner_sp") {
                    _ = try db.execute(
                        "INSERT INTO messages (session_id, body) VALUES (?, ?)",
                        parameters: [.text("ses_1"), .text("reverted inner")]
                    )
                    throw SyntheticTestError(reason: "undo savepoint")
                }
            } catch is SyntheticTestError {}
        }
        let bodies = try db.query("SELECT body FROM messages ORDER BY id ASC").compactMap { $0.string("body") }
        #expect(bodies == ["hello world", "kept outer"])

        // Delete parent cascades to messages
        let delRes = try db.execute("DELETE FROM sessions WHERE id = ?", parameters: [.text("ses_1")])
        #expect(delRes.rowsAffected == 1)
        #expect(try db.queryScalar("SELECT COUNT(*) FROM messages")?.int64Value == 0)

        // Failing migration rolls back atomically
        #expect(throws: SQLiteError.self) {
            _ = try db.migrate([
                SQLiteMigration(version: 3, name: "broken_migration", sql: "CREATE TABLE temp_ok (x INT); INVALID SQL HERE;")
            ])
        }
        #expect(try db.appliedMigrations() == [1, 2])

        // Close prevents further operations
        try db.close()
        #expect(throws: SQLiteError.databaseClosed) {
            _ = try db.query("SELECT 1")
        }
        #endif
    }

    @Test("InMemorySQLiteFallback supports CRUD, FK enforcement, rollback, savepoints, and migrations on every platform")
    func inMemorySQLiteFallback() throws {
        let db = try InMemorySQLiteFallback(path: ":memory:")
        #expect(try db.queryScalar("PRAGMA foreign_keys")?.int64Value == 1)

        let applied = try db.migrate([
            SQLiteMigration(version: 1, name: "init", sql: "CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT NOT NULL, data BLOB);"),
            SQLiteMigration(version: 2, name: "tags", sql: "CREATE TABLE tags (id INTEGER PRIMARY KEY, item_id INTEGER REFERENCES items(id), label TEXT);"),
        ])
        #expect(applied == [1, 2])
        #expect(try db.appliedMigrations() == [1, 2])

        _ = try db.execute(
            "INSERT INTO items (id, name, data) VALUES (?, ?, ?)",
            parameters: [.integer(1), .text("alpha"), .blob([0xDE, 0xAD])]
        )
        _ = try db.execute(
            "INSERT INTO items (id, name, data) VALUES (?, ?, ?)",
            parameters: [.integer(2), .text("beta"), .blob([])]
        )

        let rows = try db.query("SELECT id, name, data FROM items ORDER BY id DESC")
        #expect(rows.count == 2)
        #expect(rows[0].string("name") == "beta")
        #expect(rows[1].blob("data") == [0xDE, 0xAD])

        // Foreign key enforcement
        #expect(throws: SQLiteError.self) {
            _ = try db.execute("INSERT INTO tags (id, item_id, label) VALUES (?, ?, ?)", parameters: [.integer(1), .integer(999), .text("bad")])
        }
        _ = try db.execute("INSERT INTO tags (id, item_id, label) VALUES (?, ?, ?)", parameters: [.integer(1), .integer(1), .text("good")])

        // Transaction rollback
        #expect(throws: SyntheticTestError(reason: "rollback")) {
            try db.transaction {
                _ = try db.execute("UPDATE items SET name = ? WHERE id = ?", parameters: [.text("changed"), .integer(1)])
                throw SyntheticTestError(reason: "rollback")
            }
        }
        #expect(try db.queryScalar("SELECT name FROM items WHERE id = ?", parameters: [.integer(1)]) == .text("alpha"))

        // Savepoint rollback inside outer transaction
        try db.transaction {
            _ = try db.execute("UPDATE items SET name = ? WHERE id = ?", parameters: [.text("outer"), .integer(1)])
            do {
                try db.savepoint("sp1") {
                    _ = try db.execute("DELETE FROM items WHERE id = ?", parameters: [.integer(2)])
                    throw SyntheticTestError(reason: "undo delete")
                }
            } catch is SyntheticTestError {}
        }
        #expect(try db.queryScalar("SELECT name FROM items WHERE id = ?", parameters: [.integer(1)]) == .text("outer"))
        #expect(try db.queryScalar("SELECT COUNT(*) FROM items")?.int64Value == 2)
    }

    // MARK: - ProcessDaemon Protocol v9 & Ownership State Machine

    @Test("ProcessDaemon Protocol v9 encodes/decodes frames, binary output frames, and non-fatal unknown requests")
    func protocolV9FramingAndEnvelope() throws {
        #expect(ProcessDaemon.PROTOCOL_VERSION == 9)
        #expect(ProcessDaemon.features().isEmpty)

        // JSON Request / Response round-trip over ByteBufferStream
        let stream = ProcessDaemon.ByteBufferStream()
        let req = ProcessDaemon.Request.createPipe(
            program: "/bin/sh",
            args: ["-c", "echo hi"],
            cwd: "/",
            env: ["FOO": "bar"],
            groupId: "proj_1",
            outputPath: "/tmp/out.log",
            metadata: ["command": .string("echo hi"), "attempt": .integer(2)]
        )
        try ProcessDaemon.write_frame(stream, value: ProcessDaemon.Envelope(token: "tok-1", request: req))
        let (tok, parsed) = try ProcessDaemon.read_envelope(stream)
        #expect(tok == "tok-1")
        #expect(try parsed.get() == req)

        // Unknown op is reported non-fatally so clients can probe capabilities
        let probeBuf = ProcessDaemon.ByteBufferStream()
        let rawUnknown: [String: ProcessDaemon.JSONValue] = [
            "token": .string("tok-2"),
            "request": .object(["op": .string("teleport"), "id": .integer(1)]),
        ]
        try ProcessDaemon.write_frame(probeBuf, value: rawUnknown)
        let (tok2, unknownResult) = try ProcessDaemon.read_envelope(probeBuf)
        #expect(tok2 == "tok-2")
        if case .failure(let err) = unknownResult {
            #expect(err.message == "unsupported request: teleport")
        } else {
            Issue.record("Expected unsupported request failure")
        }

        // Invalid fields on a known op report "invalid <op> request: ..."
        let badSigBuf = ProcessDaemon.ByteBufferStream()
        let rawBadSig: [String: ProcessDaemon.JSONValue] = [
            "token": .string("tok-3"),
            "request": .object(["op": .string("signal"), "id": .integer(1), "signal": .string("SIGHUP")]),
        ]
        try ProcessDaemon.write_frame(badSigBuf, value: rawBadSig)
        let (_, badSigResult) = try ProcessDaemon.read_envelope(badSigBuf)
        if case .failure(let err) = badSigResult {
            #expect(err.message.hasPrefix("invalid signal request:"))
        } else {
            Issue.record("Expected invalid signal request failure")
        }

        // Binary output frame interleaved with JSON response frame on subscription stream
        let subStream = ProcessDaemon.ByteBufferStream()
        let rawPayload: [UInt8] = [0x00, 0x1B, 0x5B, 0x33, 0x31, 0x6D, 0xFF, 0xFE]
        try ProcessDaemon.write_output_frame(subStream, start: 100, end: 108, bytes: rawPayload)
        try ProcessDaemon.write_frame(
            subStream,
            value: ProcessDaemon.Response.exited(
                exitCode: 0,
                signal: nil,
                finalOffset: 108,
                outputLines: nil,
                outputError: nil,
                exitedAt: 12345
            )
        )
        let ev1 = try ProcessDaemon.read_subscription_event(subStream)
        #expect(ev1 == .output(start: 100, end: 108, bytes: rawPayload))
        let ev2 = try ProcessDaemon.read_subscription_event(subStream)
        #expect(ev2 == .response(.exited(
            exitCode: 0,
            signal: nil,
            finalOffset: 108,
            outputLines: nil,
            outputError: nil,
            exitedAt: 12345
        )))
    }

    @Test("ProcessDaemon Ownership enforces exclusivity, non-renewing handoff tickets, and generation fencing")
    func ownershipStateMachine() throws {
        var owner = ProcessDaemon.Ownership.with_timeouts(nowMs: 1_000, acquireMs: 5_000, handoffMs: 120_000)
        #expect(owner.deadline() == 6_000)

        // Cannot claim with bogus ticket while starting
        #expect(throws: ProcessDaemon.DaemonError.self) {
            _ = try owner.claim(ticket: "unexpected", nowMs: 1_000)
        }

        // Initial owner claims generation 1
        let gen1 = try owner.claim(ticket: nil, nowMs: 1_500)
        #expect(gen1 == 1)
        #expect(owner.is_owner(gen1))
        #expect(owner.deadline() == nil)

        // Duplicate claim rejected
        #expect(throws: ProcessDaemon.DaemonError.self) {
            _ = try owner.claim(ticket: nil, nowMs: 1_600)
        }

        // Prepare handoff is idempotent (non-renewing)
        let handoff = try owner.prepare(generation: gen1, nowMs: 2_000, unixMs: 10_000)
        #expect(handoff.expiresAt == 130_000)
        let sameHandoff = try owner.prepare(generation: gen1, nowMs: 50_000, unixMs: 58_000)
        #expect(sameHandoff == handoff)

        // Valid ticket replaces live owner immediately and fences old generation
        let gen2 = try owner.claim(ticket: handoff.ticket, nowMs: 55_000)
        #expect(gen2 == 2)
        #expect(!owner.is_owner(gen1))
        #expect(owner.is_owner(gen2))

        // Consumed ticket cannot be reused; old owner cannot prepare or stop daemon
        #expect(throws: ProcessDaemon.DaemonError.self) {
            _ = try owner.claim(ticket: handoff.ticket, nowMs: 55_000)
        }
        #expect(throws: ProcessDaemon.DaemonError.self) {
            _ = try owner.prepare(generation: gen1, nowMs: 55_000, unixMs: 63_000)
        }
        owner.disconnect(generation: gen1, nowMs: 56_000)
        let stoppedAfterOldDisconnect = owner.tick(nowMs: 56_000)
        #expect(!stoppedAfterOldDisconnect)
        #expect(owner.is_owner(gen2))

        // Disconnecting current owner without handoff stops daemon
        owner.disconnect(generation: gen2, nowMs: 60_000)
        let stoppedAfterOwnerDisconnect = owner.tick(nowMs: 60_000)
        #expect(stoppedAfterOwnerDisconnect)
    }

    // MARK: - ProcessDaemon VT Screen, Scrollback, Reflow, DSR & Alternate Screen

    @Test("ProcessDaemon Ghostty VT engine handles DSR, OSC titles, scrollback, reflow, alt screen, and selection")
    func vtEngineComprehensive() throws {
        // DSR queries produce PTY write replies
        let dsr = try ProcessDaemon.Ghostty.Terminal.new(.init(cols: 10, rows: 3, maxScrollback: 4096))
        dsr.vt_write(Array("\u{1B}[5n\u{1B}[6n".utf8))
        let replies = dsr.take_writes()
        #expect(replies == [Array("\u{1B}[0n".utf8), Array("\u{1B}[1;1R".utf8)])
        #expect(dsr.take_writes().isEmpty)

        // OSC 0/2 titles
        dsr.vt_write(Array("\u{1B}]2;vim src/main.swift\u{07}".utf8))
        #expect(dsr.take_title() == "vim src/main.swift")
        #expect(dsr.take_title() == nil)

        // Scrollback history + blank row preservation + trailing whitespace trim
        let hist = try ProcessDaemon.Ghostty.Terminal.new(.init(cols: 10, rows: 3, maxScrollback: 65_536))
        hist.vt_write(Array("one\r\ntwo\r\nthree\r\nfour\r\nfive".utf8))
        #expect(try hist.total_rows() == 5)
        var rowBuf = [UInt8](repeating: 0, count: 64)
        var readLines: [String] = []
        for y in 0..<5 {
            let len = try hist.format_row(UInt32(y), buffer: &rowBuf)
            readLines.append(String(decoding: rowBuf[0..<len], as: UTF8.self))
        }
        #expect(readLines == ["one", "two", "three", "four", "five"])

        // Viewport scroll + selection untouched by format_row
        hist.scroll_to_top()
        #expect(try hist.viewport_row() == 0)
        try hist.set_selection(start: (0, 0), end: (2, 0))
        var selBuf = [UInt8](repeating: 0, count: 32)
        let selLen = try #require(try hist.selection_text(buffer: &selBuf))
        #expect(String(decoding: selBuf[0..<selLen], as: UTF8.self) == "one")

        // Alternate screen isolates from primary scrollback and restores primary on exit
        hist.vt_write(Array("\u{1B}[?1049hA\r\nB\r\nC\r\nD\r\nE".utf8))
        #expect(try hist.total_rows() == 3)
        let altPlain = String(decoding: try hist.format(.plain), as: UTF8.self)
        #expect(altPlain == "C\nD\nE")
        hist.vt_write(Array("\u{1B}[?1049l".utf8))
        #expect(try hist.total_rows() == 5)

        // Physical wrap + combining marks + wide CJK graphemes
        let unicode = try ProcessDaemon.Ghostty.Terminal.new(.init(cols: 4, rows: 3, maxScrollback: 4096))
        unicode.vt_write(Array("a\u{301}\u{754c}bc".utf8))
        var uLines: [String] = []
        for y in 0..<3 {
            let n = try unicode.format_row(UInt32(y), buffer: &rowBuf)
            uLines.append(String(decoding: rowBuf[0..<n], as: UTF8.self))
        }
        #expect(uLines == ["a\u{301}\u{754c}b", "c", ""])

        // Resize & reflow across width changes
        let reflow = try ProcessDaemon.Ghostty.Terminal.new(.init(cols: 4, rows: 3, maxScrollback: 4096))
        reflow.vt_write(Array("abcdefghij".utf8))
        try reflow.resize(cols: 6, rows: 4)
        var rLines: [String] = []
        for y in 0..<(try reflow.total_rows()) {
            let n = try reflow.format_row(UInt32(y), buffer: &rowBuf)
            rLines.append(String(decoding: rowBuf[0..<n], as: UTF8.self))
        }
        #expect(rLines == ["abcdef", "ghij", "", ""])

        try reflow.resize(cols: 4, rows: 2)
        #expect(try reflow.total_rows() == 3)
        var rLines2: [String] = []
        for y in 0..<3 {
            let n = try reflow.format_row(UInt32(y), buffer: &rowBuf)
            rLines2.append(String(decoding: rowBuf[0..<n], as: UTF8.self))
        }
        #expect(rLines2 == ["abcd", "efgh", "ij"])
    }

    // MARK: - ProcessDaemon TerminalService Lifecycle (PTY & Pipe)

    @Test("TerminalService manages PTY lifecycle, replay truncation, titles, attach/detach, resize, and controller promotion")
    func terminalServicePtyLifecycle() throws {
        let writtenInputs = Mutex<[[UInt8]]>([])
        let service = ProcessDaemon.TerminalService.new(
            replayCapacity: 16,
            backend: .simulated(onWrite: { _, bytes, actor in
                writtenInputs.withLock { $0.append(bytes) }
                actor.emitOutput(bytes)
            })
        )
        defer { service.shutdown() }

        let pty = try service.create_pty(.init(
            program: "zsh",
            args: ["-l"],
            cwd: "/workspace",
            groupId: "sess_1",
            title: "initial",
            cols: 20,
            rows: 4
        ))
        #expect(pty.mode == .pty)
        #expect(pty.pty?.title == "initial")
        #expect(try service.list(.pty).count == 1)
        #expect(try service.list(.pipe).isEmpty)

        // Attach controller + observer
        let ctrl = try service.attach(id: pty.id, offset: 0, attachmentId: "ctrl-1", role: .controller, takeover: false)
        let obs = try service.attach(id: pty.id, offset: 0, attachmentId: "obs-1", role: .observer, takeover: false)

        // Second controller without takeover fails
        #expect(throws: ProcessDaemon.DaemonError.self) {
            _ = try service.attach(id: pty.id, offset: 0, attachmentId: "ctrl-2", role: .controller, takeover: false)
        }

        // Observer cannot write directly via write_for
        #expect(throws: ProcessDaemon.DaemonError.self) {
            try service.write_for(id: pty.id, attachmentId: "obs-1", bytes: Array("blocked".utf8))
        }

        // Controller writes bytes -> echoed into VT screen & replay buffer
        try service.write_for(id: pty.id, attachmentId: "ctrl-1", bytes: Array("0123456789abcdefghij".utf8))
        let snap = try service.snapshot(pty.id)
        #expect(snap.text == "0123456789abcdefghij")

        // Bounded replay (capacity=16, written=20) reports truncation and tail 4..20
        let rep = try service.replay(id: pty.id, offset: 0)
        #expect(rep.truncated)
        #expect(rep.availableOffset == 4)
        #expect(rep.endOffset == 20)
        #expect(String(decoding: rep.bytes, as: UTF8.self) == "456789abcdefghij")

        // User title overrides OSC title until cleared
        let actor = try #require(service.sessionActor(for: pty.id))
        actor.emitOutput(Array("\u{1B}]2;osc-shell\u{07}".utf8))
        #expect(try service.get(pty.id).pty?.title == "osc-shell")
        try service.rename(id: pty.id, title: "custom-tab")
        #expect(try service.get(pty.id).pty?.title == "custom-tab")
        actor.emitOutput(Array("\u{1B}]2;osc-vim\u{07}".utf8))
        #expect(try service.get(pty.id).pty?.title == "custom-tab")
        try service.rename(id: pty.id, title: nil)
        #expect(try service.get(pty.id).pty?.title == "osc-vim")

        // Atomic control + resize promotes obs-1 to controller and publishes Resized checkpoint
        try service.control(id: pty.id, attachmentId: "obs-1", cols: 40, rows: 10)
        #expect(try service.get(pty.id).pty?.cols == 40)
        #expect(try service.get(pty.id).pty?.rows == 10)
        let ctrlEvents = ctrl.drainEvents()
        #expect(ctrlEvents.contains { ev in
            if case let .resized(cols, rows, _, checkpoint) = ev {
                return cols == 40 && rows == 10 && !checkpoint.isEmpty
            }
            return false
        })

        // Distinct child exit and reader EOF
        actor.emitChildExit(exitCode: 7)
        #expect(try service.get(pty.id).lifecycle == .running)
        actor.emitReaderEof()
        #expect(try service.get(pty.id).lifecycle == .exited(exitCode: 7, signal: nil))

        // Late attacher still receives Exited event
        let late = try service.attach(id: pty.id, offset: 20, attachmentId: "late-1", role: .observer, takeover: false)
        let lateEvents = late.drainEvents()
        #expect(lateEvents.contains { ev in
            if case .exited(let exit) = ev { return exit.exitCode == 7 }
            return false
        })

        ctrl.detach()
        obs.detach()
        late.detach()
        try service.terminate(pty.id)
        #expect(try service.list(.pty).isEmpty)
    }

    @Test("TerminalService runs real native PTY and pipe processes with output file, signals, metadata, and wait")
    func terminalServiceNativePtyAndPipe() throws {
        #if os(macOS) || os(Linux)
        let dir = try PlatformPhase2Helper.makeTempDirectory(prefix: "opencode-pty-native")
        defer { PlatformPhase2Helper.removeItemIfExists(at: dir) }

        let service = ProcessDaemon.TerminalService.new(backend: .native)
        defer { service.shutdown() }

        // 1. Real pipe process writing to output file
        let outFile = "\(dir)/pipe.out"
        let pipeInfo = try service.create_pipe(.init(
            program: "/bin/sh",
            args: ["-c", "printf 'line1\\nline2\\n'; exit 3"],
            cwd: dir,
            env: ["PATH": "/usr/bin:/bin"],
            groupId: "g1",
            outputPath: outFile,
            metadata: ["cmd": .string("printf")]
        ))
        #expect(pipeInfo.mode == .pipe)
        #expect(pipeInfo.pipe?.metadata["cmd"] == .string("printf"))

        // PTY-only ops reject pipe processes
        #expect(throws: ProcessDaemon.DaemonError.self) {
            _ = try service.snapshot(pipeInfo.id)
        }

        try service.set_metadata(id: pipeInfo.id, metadata: ["cmd": .string("printf"), "updated": .bool(true)])
        #expect(try service.get(pipeInfo.id).pipe?.metadata["updated"] == .bool(true))

        let waitHandle = try service.wait(pipeInfo.id)
        let exit = try waitHandle.recv(timeoutMs: 5_000)
        #expect(exit.exitCode == 3)
        #expect(exit.outputLines == 2)
        #expect(exit.finalOffset == 12)
        #expect(try PlatformPhase2Helper.readTextFile(at: outFile) == "line1\nline2\n")

        // 2. Real pipe process stopped via signal(.term)
        let sigOut = "\(dir)/sig.out"
        let sleeper = try service.create_pipe(.init(
            program: "/bin/sh",
            args: ["-c", "sleep 30"],
            cwd: dir,
            env: ["PATH": "/usr/bin:/bin"],
            groupId: "g1",
            outputPath: sigOut,
            metadata: [:]
        ))
        let sigWait = try service.wait(sleeper.id)
        PlatformPhase2Helper.sleepMs(50)
        try service.signal(id: sleeper.id, signal: .term)
        let sigExit = try sigWait.recv(timeoutMs: 5_000)
        #expect(sigExit.signal == "SIGTERM")
        #expect(sigExit.exitCode == nil)

        // 3. Real kernel PTY via posix_openpt
        let realPty = try service.create_pty(.init(
            program: "/bin/sh",
            args: ["-c", "printf 'HELLO_REAL_PTY\\n'"],
            cwd: dir,
            env: [:],
            groupId: "g1",
            title: "real-sh",
            cols: 80,
            rows: 24
        ))
        // Pipe-only ops reject PTYs
        #expect(throws: ProcessDaemon.DaemonError.self) {
            _ = try service.wait(realPty.id)
        }
        let sub = try service.attach(id: realPty.id, offset: 0, attachmentId: "obs", role: .observer, takeover: false)
        var sawExit = false
        for _ in 0..<200 {
            if let ev = sub.nextEvent(timeoutMs: 25) {
                if case .exited = ev {
                    sawExit = true
                    break
                }
            } else if try service.get(realPty.id).exitedAt != nil {
                sawExit = true
                break
            }
        }
        #expect(sawExit)
        let ptySnap = try service.snapshot(realPty.id)
        #expect(ptySnap.text.contains("HELLO_REAL_PTY"))
        sub.detach()
        #endif
    }

    // MARK: - Full Client / Server Daemon IPC Round-Trips (In-Memory & Unix Socket)

    @Test("Full ProcessDaemon client/server lifecycle round-trip over deterministic in-memory transport")
    func clientServerInMemoryRoundTrip() throws {
        let service = ProcessDaemon.TerminalService.new(
            backend: .simulated(onWrite: { _, bytes, actor in
                actor.emitOutput(bytes)
            })
        )
        let server = try ProcessDaemon.Daemon.Server.startBackground(
            useInMemoryEndpoint: true,
            service: service
        )
        defer { server.stopAndWait() }

        let client = ProcessDaemon.TerminalClient(registration: server.registration)

        // Claim initial ownership, prepare handoff, and transfer ownership cleanly
        let owner1 = try client.claimOwnership(ticket: nil)
        let handoff = try owner1.prepareHandoff()
        let owner2 = try client.claimOwnership(ticket: handoff.ticket)
        owner1.releaseOwnership() // old owner disconnect must NOT stop daemon!
        PlatformPhase2Helper.sleepMs(100)


        // Ping verifies protocol v9 & registration match
        let pong = try client.ping()
        if case let .pong(instanceId, pid, proto, features) = pong {
            #expect(instanceId == server.registration.instanceId)
            #expect(pid == server.registration.pid)
            #expect(proto == ProcessDaemon.PROTOCOL_VERSION)
            #expect(features.isEmpty)
        } else {
            Issue.record("Expected Pong response")
        }

        // Create PTY over IPC, subscribe, write, resize, read_rows, snapshot, replay, terminate
        let created = try client.create_pty(.init(
            program: "sh",
            cwd: "/",
            groupId: "ipc-test",
            title: "ipc-pty",
            cols: 12,
            rows: 3
        ))
        #expect(try client.list(.pty).map(\.id) == [created.id])

        let sub = try client.subscribe(
            id: created.id,
            offset: 0,
            attachmentId: "client-ctrl",
            role: .controller,
            takeover: false
        )
        #expect(sub.role == .controller)
        #expect(sub.terminal.id == created.id)

        // First event on controller subscribe is controller_changed
        let firstEv = try sub.next_event()
        if case .response(.controllerChanged(let attId, _)) = firstEv {
            #expect(attId == "client-ctrl")
        } else {
            Issue.record("Expected controller_changed event, got \(firstEv)")
        }

        // Send input through IPC -> receives binary output frame over subscription!
        try client.write_for(id: created.id, attachmentId: "client-ctrl", data: Array("hello-ipc\r\nline-2".utf8))
        let outEv = try sub.next_event()
        #expect(outEv == .output(start: 0, end: 17, bytes: Array("hello-ipc\r\nline-2".utf8)))

        // Resize over IPC -> receives Resized frame with VT checkpoint
        try client.resize_for(id: created.id, attachmentId: "client-ctrl", cols: 24, rows: 6)
        let resizeEv = try sub.next_event()
        if case .response(.resized(let cols, let rows, _, let cp)) = resizeEv {
            #expect(cols == 24)
            #expect(rows == 6)
            #expect(!cp.isEmpty)
        } else {
            Issue.record("Expected resized event, got \(resizeEv)")
        }

        // Snapshot, read_rows, replay
        let remoteSnap = try client.snapshot(created.id)
        #expect(remoteSnap.text == "hello-ipc\nline-2")
        let remoteRows = try client.read_rows(id: created.id, rows: 2)
        #expect(remoteRows.lines.count == 2)
        let remoteReplay = try client.replay(id: created.id, offset: 6)
        #expect(String(decoding: remoteReplay.bytes, as: UTF8.self) == "ipc\r\nline-2")

        // Wrong token is rejected with authentication failed
        let badClient = ProcessDaemon.TerminalClient(registration: ProcessDaemon.Registration(
            instanceId: server.registration.instanceId,
            pid: server.registration.pid,
            socket: server.registration.socket,
            token: "wrong-token"
        ))
        #expect(throws: ProcessDaemon.DaemonError("authentication failed")) {
            _ = try badClient.ping()
        }

        sub.close()
        try client.terminate(created.id)
        #expect(try client.list(.pty).isEmpty)

        // Shutdown stops daemon cleanly
        try client.shutdown()
        #expect(server.waitUntilStopped(timeoutMs: 2_000))
        owner2.releaseOwnership()
    }

    @Test("ProcessDaemon runs end-to-end over real Unix domain socket with discovery, Windows pipe validation, and CLI")
    func unixSocketDiscoveryAndTransportContracts() throws {
        // Runtime name validation
        #expect(try ProcessDaemon.Daemon.runtime_dir(root: "/state", name: "valid.name_1-a") == "/state/valid.name_1-a")
        for badName in ["", ".", "..", "a/b", "../escape", "has space"] {
            #expect(throws: ProcessDaemon.DaemonError.self) {
                _ = try ProcessDaemon.Daemon.runtime_dir(root: "/state", name: badName)
            }
        }

        // Windows named pipe endpoint validation, PID verification, wide UTF-16 & PrivateSecurity
        for badPipe in [#"\\remote\pipe\opencode-pty-x"#, #"C:\tmp\pipe"#, #"\\.\pipe\opencode-pty-a\b"#] {
            #expect(throws: ProcessDaemon.DaemonError.self) {
                _ = try ProcessDaemon.Transport.Windows.Listener.bind(badPipe)
            }
        }
        let pipeEndpoint = #"\\.\pipe\opencode-pty-test-\#(UInt64.random(in: 1...UInt64.max))"#
        let winListener = try ProcessDaemon.Transport.Windows.Listener.bind(pipeEndpoint)
        let winClient = try ProcessDaemon.Transport.Windows.Connection.connect(pipeEndpoint)
        var acceptedWin: ProcessDaemon.Transport.Windows.Connection? = nil
        for _ in 0..<200 {
            if let conn = try winListener.accept() {
                acceptedWin = conn
                break
            }
            PlatformPhase2Helper.sleepMs(5)
        }
        let winServer = try #require(acceptedWin)
        try ProcessDaemon.write_frame(winClient, value: ProcessDaemon.Response.owned)
        let receivedWin: ProcessDaemon.Response = try ProcessDaemon.read_frame(winServer)
        #expect(receivedWin == .owned)
        winClient.closeConnection()
        winServer.closeConnection()
        winListener.stop()

        let wide = try ProcessDaemon.Transport.Windows.wide("abc")
        #expect(wide == [97, 98, 99, 0])
        #expect(throws: ProcessDaemon.DaemonError.self) {
            _ = try ProcessDaemon.Transport.Windows.wide("a\0b")
        }

        let sec = try ProcessDaemon.Transport.WindowsSecurity.PrivateSecurity.new()
        #expect(sec.attributes().protectedDACL)
        #if !os(Windows)
        #expect(throws: ProcessDaemon.DaemonError.self) {
            try sec.check_private(42)
        }
        try sec.make_private(42)
        try sec.check_private(42)
        #endif

        // Control missed-wake detector
        let wake = try ProcessDaemon.Transport.Unix.Wake.new()
        let control = ProcessDaemon.Daemon.Control.new(wake: wake, ownership: .new(nowMs: 0))
        var snap = ProcessDaemon.OwnershipSnapshot()
        _ = try control.tick(nowMs: 100, last: &snap, timedOut: false)
        #expect(control.set_stop_without_wake())
        #expect(throws: ProcessDaemon.DaemonError("missed wake detected")) {
            _ = try control.tick(nowMs: 200, last: &snap, timedOut: true, failOnMissedWake: true)
        }
        #expect(control.stats.missedWakes == 1)

        // Retained pointer owner
        let retained = ProcessDaemon.Transport.Retained.new(UInt64(0xCAFE_BABE))
        #expect(retained.as_ptr().pointee == 0xCAFE_BABE)

        // CLI version output
        #expect(try ProcessDaemon.TerminalClient.run_cli(arguments: ["--version"]).contains("protocol 9"))

        // Real Unix domain socket daemon server + file-based discovery + cleanup
        #if os(macOS) || os(Linux)
        let dir = try PlatformPhase2Helper.makeTempDirectory(prefix: "opencode-uds")
        defer { PlatformPhase2Helper.removeItemIfExists(at: dir) }
        let runtimePath = "\(dir)/run1"

        let udsServer = try ProcessDaemon.Daemon.Server.startBackground(
            directory: runtimePath,
            useInMemoryEndpoint: false,
            service: ProcessDaemon.TerminalService.new(backend: .simulated(onWrite: nil))
        )
        defer { udsServer.stopAndWait() }

        let discovered = try ProcessDaemon.TerminalClient.discover(runtimePath)
        #expect(discovered.registration.instanceId == udsServer.registration.instanceId)
        let owner = try discovered.claimOwnership(ticket: nil)
        let term = try discovered.create_pty(.init(program: "sh", cwd: "/", title: "uds-term", cols: 80, rows: 24))
        #expect(try discovered.get(term.id).pty?.title == "uds-term")
        try discovered.shutdown()
        #expect(udsServer.waitUntilStopped(timeoutMs: 3_000))
        owner.releaseOwnership()
        #expect(!PlatformPhase2Helper.fileExists(at: ProcessDaemon.Daemon.registration_path(runtimePath)))
        #endif
    }
}
