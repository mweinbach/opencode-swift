import Synchronization
import Testing
import OpenCodeAI
import OpenCodeCore
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

@Suite("Database, Event Bus, V1 Compat & Session Core")
struct SessionDatabaseTests {
    // MARK: - 1. Database Schema, WAL Store & Migrations

    @Test("SQLite bootstrap creates all 24 schema tables and migrations are idempotent")
    func databaseBootstrapAndIdempotentMigrations() async throws {
        let path = SessionDatabaseHelper.makeTempDBPath(prefix: "opencode-wal-test")
        defer { SessionDatabaseHelper.cleanupTempDB(at: path) }

        let service = try await CoreDatabaseStore.open(
            options: CoreDatabaseStore.Options(path: path),
            legacyCredentials: false
        )
        defer { try? service.db.close() }

        let journalMode = try service.db.queryScalar("PRAGMA journal_mode")?.stringValue?.lowercased()
        #expect(journalMode == "wal")

        let tables = try service.db.query(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
        ).compactMap { $0.string("name") }
        let tableSet = Set(tables)

        for expected in [
            "account", "account_state", "automation", "blob", "blob_ref",
            "control_account", "credential", "event", "event_sequence",
            "instruction_blob", "instruction_entry", "instruction_state",
            "job", "kv", "machine", "migration", "permission", "project", "project_directory",
            "session_inbox", "session_message", "session_part", "session_v2",
            "workspace", "worktree",
        ] {
            #expect(tableSet.contains(expected), "Missing table: \(expected)")
        }

        // Re-applying migrations must be a clean no-op with stable migration table count.
        let beforeCount = try service.db.queryScalar("SELECT count(*) FROM `migration`")?.int64Value
        try CoreDatabaseMigration.apply(service.db)
        let afterCount = try service.db.queryScalar("SELECT count(*) FROM `migration`")?.int64Value
        #expect(beforeCount == Int64(CoreDatabaseMigration.migrations.count))
        #expect(afterCount == beforeCount)

        // Verify Drizzle query-builder layer insert + select.
        let drizzle = CoreDatabaseDrizzle.SQLiteEffectDatabase(
            session: CoreDatabaseDrizzle.SQLiteEffectSession(client: service.db)
        )
        _ = try drizzle.insert(into: CoreDatabaseSchema.eventSequenceTable).values([
            "aggregate_id": .text("agg_test"),
            "seq": .integer(42),
        ]).run()

        let found = try drizzle.select()
            .from(CoreDatabaseSchema.eventSequenceTable)
            .where("`aggregate_id` = ?", parameters: [.text("agg_test")])
            .all()
        #expect(found.count == 1)
        #expect(found.first?.int64("seq") == 42)

        // Verify batch splitting (MAX_VARIABLES = 100 -> 20 items per batch for perItem: 5 -> 13 batches for 250 items)
        // and storage failure classification.
        let batches = CoreDatabaseSchema.batches(Array(0..<250), perItem: 5)
        #expect(batches.count == 13)
        #expect(batches.flatMap { $0 }.count == 250)
        #expect(CoreDatabaseStorageFailure.message(SQLiteError.executionFailed(sql: "", code: 13, message: "disk full")) == "Storage is full")
        #expect(CoreDatabaseStorageFailure.message(SQLiteError.executionFailed(sql: "", code: 8, message: "readonly")) == "Storage is read-only")
    }

    // MARK: - 2. V1 Config & V1->V2 Session Migration

    @Test("V1 config migrators transform agents, permissions, MCP, providers, and commands")
    func v1ConfigMigration() throws {
        // Normalize V1 tool/permission action renames.
        #expect(CoreV1Config.Migrate.normalizeAction("write") == "edit")
        #expect(CoreV1Config.Migrate.normalizeAction("bash") == "shell")
        #expect(CoreV1Config.Migrate.normalizeAction("task") == "subagent")
        #expect(CoreV1Config.Migrate.normalizeAction("read") == "read")

        // Migrate V1 agent config.
        let agentJSON = """
        {
          "model": "openai/gpt-5",
          "prompt": "Review carefully",
          "mode": "subagent",
          "steps": 12,
          "permission": { "bash": "ask", "read": "allow" }
        }
        """
        let v1Agent = try SessionDatabaseHelper.decodeJSON(agentJSON, as: CoreV1Config.Agent.Info.self)
        let v2Agent = CoreV1Config.Migrate.migrateAgent(v1Agent)
        #expect(v2Agent.steps?.rawValue == 12)
        #expect(v2Agent.system == "Review carefully")
        let rules: [PermissionSchema.Rule] = v2Agent.permissions ?? []
        var hasShellAsk = false
        for rule in rules {
            if rule.action == "shell" && rule.effect == .ask {
                hasShellAsk = true
            }
        }
        #expect(hasShellAsk)

        // Migrate V1 command config.
        let cmdJSON = #"{"template":"Review $ARGUMENTS","description":"Code review"}"#
        let v1Cmd = try SessionDatabaseHelper.decodeJSON(cmdJSON, as: CoreV1Config.Command.Info.self)
        let v2Cmd = CoreV1Config.Migrate.migrateCommand(v1Cmd)
        #expect(v2Cmd.template == "Review $ARGUMENTS")
        #expect(v2Cmd.description == "Code review")

        // Migrate V1 local & remote MCP configs.
        let localMcpJSON = #"{"type":"local","command":["npx","-y","server"],"enabled":true,"timeout":5000}"#
        let v1LocalMcp = try SessionDatabaseHelper.decodeJSON(localMcpJSON, as: CoreV1Config.MCP.Info.self)
        let v2LocalMcp = CoreV1Config.Migrate.migrateMcp(v1LocalMcp)
        if case .local(let localCfg) = v2LocalMcp {
            #expect(localCfg.command == ["npx", "-y", "server"])
            #expect(localCfg.disabled == false)
        } else {
            Issue.record("Expected local MCP config")
        }

        let remoteMcpJSON = #"{"type":"remote","url":"https://mcp.example.com","enabled":false,"oauth":false}"#
        let v1RemoteMcp = try SessionDatabaseHelper.decodeJSON(remoteMcpJSON, as: CoreV1Config.MCP.Info.self)
        let v2RemoteMcp = CoreV1Config.Migrate.migrateMcp(v1RemoteMcp)
        if case .remote(let remoteCfg) = v2RemoteMcp {
            #expect(remoteCfg.url == "https://mcp.example.com")
            #expect(remoteCfg.disabled == true)
            #expect(remoteCfg.oauth == .disabled)
        } else {
            Issue.record("Expected remote MCP config")
        }

        // Migrate V1 provider config.
        let providerJSON = #"{"name":"Custom","api":"https://api.example.com","npm":"@ai-sdk/openai-compatible"}"#
        let v1Prov = try SessionDatabaseHelper.decodeJSON(providerJSON, as: CoreV1Config.Provider.Info.self)
        let v2Prov = CoreV1Config.Migrate.migrateProvider(sourceID: "custom", info: v1Prov)
        #expect(v2Prov.name == "Custom")
        #expect(v2Prov.package == "aisdk:@ai-sdk/openai-compatible")
    }

    @Test("V1 to V2 session migration converts legacy session/message/part tables into session_v2")
    func v1ToV2SessionMigration() async throws {
        let harness = try await SessionDatabaseHelper.makeHarness()
        let db = harness.db
        let now = Flock.currentEpochMs()

        // Create legacy V1 tables.
        try db.execute("""
            CREATE TABLE `session` (
                `id` TEXT PRIMARY KEY,
                `project_id` TEXT NOT NULL,
                `workspace_id` TEXT,
                `parent_id` TEXT,
                `slug` TEXT NOT NULL,
                `directory` TEXT NOT NULL,
                `path` TEXT,
                `title` TEXT NOT NULL,
                `version` TEXT NOT NULL,
                `time_created` INTEGER NOT NULL,
                `time_updated` INTEGER NOT NULL,
                `agent` TEXT,
                `model` TEXT
            )
            """)
        try db.execute("""
            CREATE TABLE `message` (
                `id` TEXT PRIMARY KEY,
                `session_id` TEXT NOT NULL,
                `time_created` INTEGER NOT NULL,
                `time_updated` INTEGER NOT NULL,
                `data` TEXT NOT NULL
            )
            """)
        try db.execute("""
            CREATE TABLE `part` (
                `id` TEXT PRIMARY KEY,
                `message_id` TEXT NOT NULL,
                `session_id` TEXT NOT NULL,
                `time_created` INTEGER NOT NULL,
                `time_updated` INTEGER NOT NULL,
                `data` TEXT NOT NULL
            )
            """)

        let sid = SessionID.create()
        try db.execute(
            "INSERT INTO `project` (`id`, `worktree`, `time_created`, `time_updated`, `sandboxes`) VALUES ('global', '/repo', ?, ?, '[]')",
            parameters: [.integer(now), .integer(now)]
        )
        try db.execute(
            "INSERT INTO `session` VALUES (?, 'global', NULL, NULL, 'legacy-slug', '/repo', '', 'Legacy Title', '1.0.0', ?, ?, 'build', NULL)",
            parameters: [.text(sid.rawValue), .integer(now), .integer(now)]
        )

        let uMsgID = SessionMessageSchema.ID.create()
        let aMsgID = SessionMessageSchema.ID.create()
        try db.execute(
            "INSERT INTO `message` VALUES (?, ?, ?, ?, ?)",
            parameters: [
                .text(uMsgID.rawValue),
                .text(sid.rawValue),
                .integer(now),
                .integer(now),
                .text(#"{"role":"user","agent":"build","model":{"providerID":"openai","modelID":"gpt-5"}}"#),
            ]
        )
        try db.execute(
            "INSERT INTO `part` VALUES ('prt_1', ?, ?, ?, ?, ?)",
            parameters: [
                .text(uMsgID.rawValue),
                .text(sid.rawValue),
                .integer(now),
                .integer(now),
                .text(#"{"type":"text","text":"Hello legacy"}"#),
            ]
        )
        try db.execute(
            "INSERT INTO `message` VALUES (?, ?, ?, ?, ?)",
            parameters: [
                .text(aMsgID.rawValue),
                .text(sid.rawValue),
                .integer(now + 10),
                .integer(now + 20),
                .text(#"{"role":"assistant","agent":"build","providerID":"openai","modelID":"gpt-5","finish":"stop","cost":0.05,"tokens":{"input":100,"output":40,"reasoning":0,"cache":{"read":10,"write":0}},"time":{"created":1,"completed":2}}"#),
            ]
        )
        try db.execute(
            "INSERT INTO `part` VALUES ('prt_2', ?, ?, ?, ?, ?)",
            parameters: [
                .text(aMsgID.rawValue),
                .text(sid.rawValue),
                .integer(now + 10),
                .integer(now + 20),
                .text(#"{"type":"text","text":"Hi from V1"}"#),
            ]
        )

        let result = try await CoreDatabaseV1Migration.run(db: db, globalRoot: "/repo")
        #expect(result.status == "completed")

        let migrated = try #require(try harness.store.get(sid))
        #expect(migrated.title == "Legacy Title")
        #expect(migrated.cost == 0.05)
        #expect(migrated.tokens.input == 100)
        #expect(migrated.tokens.output == 40)

        let msgs = try harness.store.messages(CoreSessionStore.MessagesInput(sessionID: sid, order: .asc))
        #expect(msgs.count == 2)
    }

    // MARK: - 3. Durable Bus, Same-Transaction Projections & Replay

    @Test("CoreBus persists durable events, runs projectors atomically, rolls back on error, and replays with synced marker")
    func busDurabilityAtomicityAndReplay() async throws {
        let harness = try await SessionDatabaseHelper.makeHarness(persistEvents: true)
        let location = OpenCodeLocation(directory: "/workspace/alpha")

        let created = try await harness.session.create(CoreSession.CreateInput(
            location: location,
            title: "Initial"
        ))
        try await harness.session.rename(sessionID: created.id, title: "Updated")

        let fetched = try harness.session.get(created.id)
        #expect(fetched.title == "Updated")

        // Verify durable event log and 0-based per-aggregate sequence numbers (matching upstream bus.ts).
        #expect(try CoreBus.latestSequence(db: harness.db, aggregateID: created.id.rawValue) == 1)
        let eventRows = try harness.db.query(
            "SELECT `type`, `seq` FROM `event` WHERE `aggregate_id` = ? ORDER BY `seq` ASC",
            parameters: [.text(created.id.rawValue)]
        )
        #expect(eventRows.count == 2)
        #expect(eventRows[0].string("type") == "session.created.1")
        #expect(eventRows[0].int64("seq") == 0)
        #expect(eventRows[1].string("type") == "session.renamed.1")
        #expect(eventRows[1].int64("seq") == 1)

        // Verify rollback when a commit hook throws: neither event nor session_v2 should change.
        struct BoomError: Error {}
        var threw = false
        do {
            _ = try await harness.bus.publish(
                SessionEventSchema.Renamed,
                data: SessionEventSchema.RenamedData(sessionID: created.id, title: "ShouldRollback"),
                options: CoreBus.PublishOptions(commit: { _ in throw BoomError() })
            )
        } catch is BoomError {
            threw = true
        }
        #expect(threw)
        #expect(try harness.session.get(created.id).title == "Updated")
        #expect(try CoreBus.latestSequence(db: harness.db, aggregateID: created.id.rawValue) == 1)

        // Verify replay-to-live log stream emits replayed items followed by `.synced`.
        var seenTypes: [String] = []
        var sawSynced = false
        for await item in harness.bus.log(CoreBus.LogInput(aggregateID: created.id.rawValue, follow: false)) {
            switch item {
            case .event(let ev):
                seenTypes.append(ev.type)
            case .synced:
                sawSynced = true
            }
        }
        #expect(sawSynced)
        #expect(seenTypes == ["session.created", "session.renamed"])
    }

    // MARK: - 4. Session ID Adoption, Prompt Admission, Idempotency & Delivery Ordering

    @Test("Session ID adoption, admit-only resume:false, and idempotent user/synthetic ID reuse (pending & delivered)")
    func adoptionIdempotencyAndAdmitOnly() async throws {
        let harness = try await SessionDatabaseHelper.makeHarness()
        let sid = SessionID.create()
        let loc = OpenCodeLocation(directory: "/workspace/idem")

        let first = try await harness.session.create(CoreSession.CreateInput(id: sid, location: loc, title: "First"))
        let adopted = try await harness.session.create(CoreSession.CreateInput(id: sid, location: loc, title: "Ignored"))
        #expect(adopted.id == first.id)
        #expect(adopted.title == "First")

        // Admit-only prompt (`resume: false`) must record inbox row WITHOUT waking execution.
        let msgID = SessionMessageSchema.ID.create()
        let admitted1 = try await harness.session.prompt(CoreSession.PromptRequest(
            sessionID: sid,
            id: msgID,
            input: CoreSessionPrompt.Input(text: "Original prompt", delivery: .queue),
            resume: false
        ))
        #expect(harness.wakeLog.snapshot().isEmpty)
        #expect(try harness.inbox.list(sid).count == 1)

        // Retrying same ID on same Session+type while pending returns original (first admission wins).
        let admitted2 = try await harness.session.prompt(CoreSession.PromptRequest(
            sessionID: sid,
            id: msgID,
            input: CoreSessionPrompt.Input(text: "Different retry text", delivery: .steer),
            resume: false
        ))
        #expect(admitted2 == admitted1)
        if case .user(let u) = admitted2 {
            #expect(u.payload.text == "Original prompt")
            #expect(u.delivery == .queue)
        } else {
            Issue.record("Expected user inbox item")
        }

        // Cross-session reuse with same ID MUST fail with PromptConflictError.
        let other = try await harness.session.create(CoreSession.CreateInput(location: loc))
        var crossSessionConflict = false
        do {
            _ = try await harness.session.prompt(CoreSession.PromptRequest(
                sessionID: other.id,
                id: msgID,
                input: CoreSessionPrompt.Input(text: "Steal ID"),
                resume: false
            ))
        } catch is CoreSessionErrors.PromptConflictError {
            crossSessionConflict = true
        }
        #expect(crossSessionConflict)

        // Cross-type reuse (synthetic with existing user ID) MUST fail with SyntheticConflictError.
        var crossTypeConflict = false
        do {
            _ = try await harness.session.synthetic(CoreSessionSynthetic.Request(
                sessionID: sid,
                id: msgID,
                text: "Wrong type",
                resume: false
            ))
        } catch is CoreSessionErrors.SyntheticConflictError {
            crossTypeConflict = true
        }
        #expect(crossTypeConflict)

        // Deliver the pending prompt into visible `session_message` (removing from `session_inbox`).
        let promoted = try await CoreSessionInbox.promote(db: harness.db, bus: harness.bus, sessionID: sid, scope: .input)
        #expect(promoted == 1)
        #expect(try harness.inbox.list(sid).isEmpty)
        let messages = try harness.session.messages(CoreSessionStore.MessagesInput(sessionID: sid, order: .asc))
        #expect(messages.count == 1)

        // Retrying same ID AFTER delivery reconciles idempotently from `session_message`!
        let reconciledAfterDelivery = try await harness.session.prompt(CoreSession.PromptRequest(
            sessionID: sid,
            id: msgID,
            input: CoreSessionPrompt.Input(text: "Post-delivery retry"),
            resume: false
        ))
        if case .user(let u) = reconciledAfterDelivery {
            #expect(u.id == msgID)
            #expect(u.payload.text == "Original prompt")
        } else {
            Issue.record("Expected reconciled user item after delivery")
        }
        #expect(try harness.inbox.list(sid).isEmpty)

        // Normal prompt (resume omitted / true) DOES schedule execution wake.
        _ = try await harness.session.prompt(CoreSession.PromptRequest(
            sessionID: sid,
            input: CoreSessionPrompt.Input(text: "Wake me up")
        ))
        #expect(harness.wakeLog.snapshot() == [sid])
    }

    @Test("Inbox delivery ordering: steered compaction hoists ahead of steers but never across a steered move")
    func inboxOrderingAndSteerQueueControlRules() async throws {
        let harness = try await SessionDatabaseHelper.makeHarness()
        let sid = (try await harness.session.create(CoreSession.CreateInput(
            location: OpenCodeLocation(directory: "/workspace/order")
        ))).id

        let q1 = SessionMessageSchema.ID.create()
        let s1 = SessionMessageSchema.ID.create()
        let comp = SessionMessageSchema.ID.create()

        _ = try await harness.inbox.admit(
            id: q1,
            sessionID: sid,
            item: .user(payload: SessionInboxSchema.UserPayload(text: "queued 1"), delivery: .queue)
        )
        _ = try await harness.inbox.admit(
            id: s1,
            sessionID: sid,
            item: .user(payload: SessionInboxSchema.UserPayload(text: "steer 1"), delivery: .steer)
        )
        _ = try await harness.inbox.admitCompaction(id: comp, sessionID: sid, delivery: .steer)

        // Steered compaction must hoist ahead of steered user prompt `s1`.
        let next1 = try CoreSessionInbox.nextPromotable(db: harness.db, sessionID: sid, promotable: .steer)
        #expect(next1?.id == comp)

        // Cancel compaction, then verify steer `s1` precedes queued `q1`, and `.steer` scope leaves `q1` parked.
        try await harness.inbox.cancel(sessionID: sid, id: comp)
        let promotedSteers = try await CoreSessionInbox.promote(db: harness.db, bus: harness.bus, sessionID: sid, scope: .steer)
        #expect(promotedSteers == 1)
        #expect(try harness.inbox.list(sid).count == 1)

        // Now test that a steered `move` blocks hoisting a later steered `compaction` across it.
        let s2 = SessionMessageSchema.ID.create()
        let moveID = SessionMessageSchema.ID.create()
        let compAfterMove = SessionMessageSchema.ID.create()
        _ = try await harness.inbox.admit(
            id: s2,
            sessionID: sid,
            item: .user(payload: SessionInboxSchema.UserPayload(text: "before move"), delivery: .steer)
        )
        _ = try await harness.inbox.admit(
            id: moveID,
            sessionID: sid,
            item: .move(
                payload: SessionInboxSchema.MovePayload(
                    location: OpenCodeLocation(directory: "/workspace/new"),
                    projectID: ProjectID.global,
                    subpath: ""
                ),
                delivery: .steer
            )
        )
        _ = try await harness.inbox.admitCompaction(id: compAfterMove, sessionID: sid, delivery: .steer)

        // `s2` must remain first (compaction must NOT jump over `moveID`).
        let nextBeforeMove = try CoreSessionInbox.nextPromotable(db: harness.db, sessionID: sid, promotable: .steer)
        #expect(nextBeforeMove?.id == s2)

        // Converting queued `q1` to steer and back to queue updates delivery cleanly.
        try await harness.inbox.steer(sessionID: sid, id: q1)
        try await harness.inbox.queue(sessionID: sid, id: q1)
    }

    // MARK: - 5. Blob Externalization, Hydration, GC & Instruction Epochs

    @Test("Blob externalization deduplicates attachments, keeps refs, hydrates, and GCs on session delete")
    func blobExternalizationAndGC() async throws {
        let harness = try await SessionDatabaseHelper.makeHarness(
            projectorOptions: CoreSessionProjector.Options(partRowsEnabled: true, mediaBlobEnabled: true)
        )
        let sid = (try await harness.session.create(CoreSession.CreateInput(
            location: OpenCodeLocation(directory: "/workspace/blobs")
        ))).id

        let dataURL = SessionDatabaseHelper.makeSampleDataURL()
        _ = try await harness.session.prompt(CoreSession.PromptRequest(
            sessionID: sid,
            input: CoreSessionPrompt.Input(
                text: "Inspect image",
                files: [PromptInputSchema.FileAttachment(uri: dataURL, name: "sample.png")]
            ),
            resume: false
        ))

        let blobCountBefore = try harness.db.queryScalar("SELECT count(*) FROM `blob`")?.int64Value
        let refCountBefore = try harness.db.queryScalar("SELECT count(*) FROM `blob_ref`")?.int64Value
        #expect(blobCountBefore == 1)
        #expect(refCountBefore == 1)

        // Deliver prompt -> visible message still hydrates inline base64 transparently.
        _ = try await CoreSessionInbox.promote(db: harness.db, bus: harness.bus, sessionID: sid, scope: .input)
        let msgs = try harness.store.messages(CoreSessionStore.MessagesInput(sessionID: sid, order: .asc))
        #expect(msgs.count == 1)
        if case .user(let u) = msgs[0] {
            #expect(u.files?.first?.mime == "image/png")
            #expect(u.files?.first?.data.rawValue == bytesToBase64(SessionDatabaseHelper.makeSamplePNGBytes()))
        } else {
            Issue.record("Expected hydrated user message")
        }

        // Deleting the session releases blob_ref rows and GCs the unreferenced blob.
        try await harness.session.remove(sid)
        let blobCountAfter = try harness.db.queryScalar("SELECT count(*) FROM `blob`")?.int64Value
        let refCountAfter = try harness.db.queryScalar("SELECT count(*) FROM `blob_ref`")?.int64Value
        #expect(refCountAfter == 0)
        #expect(blobCountAfter == 0)
    }

    @Test("Instruction entries enforce 64KiB limit and InstructionState tracks deltas and epochs")
    func instructionEntriesAndState() async throws {
        let harness = try await SessionDatabaseHelper.makeHarness()
        let sid = (try await harness.session.create(CoreSession.CreateInput(
            location: OpenCodeLocation(directory: "/workspace/instr")
        ))).id

        let entrySvc = CoreSessionInstructionEntry.Service(db: harness.db)
        try entrySvc.put(sessionID: sid, key: "project-rules", value: .string("Follow Swift 6 strict concurrency"))
        let listed = try entrySvc.list(sid)
        #expect(listed.count == 1)
        #expect(listed[0].key == "project-rules")

        // Exceeding 64KiB throws ValueTooLargeError.
        let oversized = String(repeating: "a", count: CoreSessionInstructionEntry.maxValueBytes + 10)
        var tooLarge = false
        do {
            try entrySvc.put(sessionID: sid, key: "big", value: .string(oversized))
        } catch is CoreSessionInstructionEntry.ValueTooLargeError {
            tooLarge = true
        }
        #expect(tooLarge)

        // First prepare records initial instruction baseline without emitting an update system message.
        let sources1 = try entrySvc.load(sid)
        try await CoreSessionInstructionState.prepare(db: harness.db, bus: harness.bus, sources: sources1, sessionID: sid)
        let initialRendered = try CoreSessionInstructionState.initial(db: harness.db, sessionID: sid, sources: sources1)
        #expect(initialRendered.count == 1)
        #expect(initialRendered[0].text.contains("Follow Swift 6 strict concurrency"))

        // Updating an entry emits a durable system update message on the next prepare.
        try entrySvc.put(sessionID: sid, key: "project-rules", value: .string("Use Swift Testing only"))
        let sources2 = try entrySvc.load(sid)
        try await CoreSessionInstructionState.prepare(db: harness.db, bus: harness.bus, sources: sources2, sessionID: sid)
        let msgs = try harness.store.messages(CoreSessionStore.MessagesInput(sessionID: sid, order: .asc))
        #expect(msgs.contains { if case .system = $0 { return true }; return false })
    }

    // MARK: - 6. Single-Step Runner, Tool Execution & Write-Ahead Execution Claim

    @Test("CoreSessionRunner executes one explicit LLM stream per step, runs local tools, reloads SQLite history, and releases claim on completion")
    func singleStepRunnerWithToolCallAndReloadedHistory() async throws {
        let harness = try await SessionDatabaseHelper.makeHarness(
            projectorOptions: CoreSessionProjector.Options(partRowsEnabled: true, mediaBlobEnabled: false)
        )

        let price = MoneySchema.USDPerMillionTokens(rawValue: 2.0)!
        let model = SessionDatabaseHelper.makeResolvedModel(
            provider: "mock",
            id: "mock-1",
            costs: [ModelSchema.Cost(
                tier: nil,
                input: price,
                output: price,
                cache: ModelSchema.Cost.Cache(read: price, write: price)
            )]
        )

        let toolCalledLog = Mutex<[String]>([])
        let llm = SessionDatabaseHelper.ScriptedLLMClient(scripts: [
            // Step 1: streams reasoning + a local tool call `echo_tool`.
            .events([
                .reasoningStart(AISchema.ReasoningStart(id: "r1")),
                .reasoningDelta(AISchema.ReasoningDelta(id: "r1", text: "Let me call echo_tool.")),
                .reasoningEnd(AISchema.ReasoningEnd(id: "r1")),
                .toolCall(AISchema.ToolCall(
                    id: "call_1",
                    name: "echo_tool",
                    input: .object(["value": .string("hello-sqlite")])
                )),
                .stepFinish(AISchema.StepFinish(
                    index: 0,
                    reason: AISchema.FinishReasonDetails(normalized: .toolCalls),
                    usage: AISchema.Usage(outputTokens: 50, nonCachedInputTokens: 100, reasoningTokens: 10)
                )),
            ]),
            // Step 2: receives reloaded history including tool result, streams final text answer.
            .events([
                .textStart(AISchema.TextStart(id: "t1")),
                .textDelta(AISchema.TextDelta(id: "t1", text: "Echo returned: hello-sqlite")),
                .textEnd(AISchema.TextEnd(id: "t1")),
                .finish(AISchema.Finish(
                    reason: AISchema.FinishReasonDetails(normalized: .stop),
                    usage: AISchema.Usage(outputTokens: 30, nonCachedInputTokens: 200)
                )),
            ]),
        ])

        let modelsSvc = CoreSessionRunnerModel.Service { _, _, _, _ in model }
        let contextSvc = CoreSessionContext.Service(
            db: harness.db,
            store: harness.store,
            models: modelsSvc,
            selectTools: { _, _ in
                CoreSessionModelRequest.ToolSnapshot(
                    definitions: [
                        .tool(AISchema.ToolDefinition(
                            name: "echo_tool",
                            description: "Echoes value",
                            inputSchema: ["type": .string("object")]
                        )),
                    ],
                    execute: { toolInput in
                        toolCalledLog.withLock { $0.append(toolInput.call.name) }
                        return CoreSessionModelRequest.NormalizedToolResult(
                            content: [.text("echoed:hello-sqlite")]
                        )
                    }
                )
            }
        )
        let compactionSvc = CoreSessionCompaction.Service(bus: harness.bus, llm: llm)
        let runner = CoreSessionRunner.Service(
            db: harness.db,
            bus: harness.bus,
            store: harness.store,
            context: contextSvc,
            llm: llm,
            compaction: compactionSvc
        )
        let execution = CoreSessionExecution.Service(
            db: harness.db,
            store: harness.store,
            bus: harness.bus,
            inbox: harness.inbox,
            runnerForLocation: { _ in runner }
        )
        let sessionSvc = CoreSession.Service(
            db: harness.db,
            bus: harness.bus,
            store: harness.store,
            inbox: harness.inbox,
            execution: execution
        )

        let created = try await sessionSvc.create(CoreSession.CreateInput(
            location: OpenCodeLocation(directory: "/workspace/run"),
            title: "Runner Test"
        ))

        // Idle interruption on known session returns false; unknown session throws NotFoundError.
        #expect(try await sessionSvc.interrupt(created.id) == false)
        var unknownThrew = false
        do {
            _ = try await sessionSvc.interrupt(SessionID.create())
        } catch is CoreSessionErrors.NotFoundError {
            unknownThrew = true
        }
        #expect(unknownThrew)

        // Admit prompt and await idle completion through real CoreSessionExecution.
        _ = try await sessionSvc.prompt(CoreSession.PromptRequest(
            sessionID: created.id,
            input: CoreSessionPrompt.Input(text: "Please echo hello-sqlite")
        ))
        try await sessionSvc.awaitIdle(created.id)

        // Verify two explicit LLM stream requests were dispatched (one per step).
        let requests = llm.capturedRequests()
        #expect(requests.count == 2)
        // Step 2 must have received reloaded history containing the assistant tool call AND the tool result!
        let step2Roles: [AISchema.MessageRole] = requests[1].messages.map { $0.role }
        #expect(step2Roles.contains(AISchema.MessageRole.user))
        #expect(step2Roles.contains(AISchema.MessageRole.assistant))
        #expect(step2Roles.contains(AISchema.MessageRole.tool))
        #expect(toolCalledLog.withLock { $0 } == ["echo_tool"])

        // Verify session_v2 projections: usage accumulated, outcome succeeded, write-ahead claim released!
        let finalInfo = try sessionSvc.get(created.id)
        #expect(finalInfo.outcome == SessionSchema.Outcome.succeeded)
        #expect(finalInfo.tokens.input == 300)
        #expect(finalInfo.tokens.output == 70) // visibleOutputTokens = (50-10) + 30
        #expect(finalInfo.tokens.reasoning == 10)
        #expect(finalInfo.cost > 0)
        #expect(try harness.store.listSuspended().isEmpty)

        // Verify visible projected messages include user, 2 assistants, and idle marker.
        let msgs = try sessionSvc.messages(CoreSessionStore.MessagesInput(sessionID: created.id, order: .asc))
        let types: [SessionMessageSchema.MessageType] = msgs.map { $0.messageType }
        let expectedTypes: [SessionMessageSchema.MessageType] = [.user, .assistant, .assistant, .idle]
        #expect(types == expectedTypes)
    }

    // MARK: - 7. Write-Ahead Claim Preservation on Shutdown & Restart Recovery

    @Test("Shutdown interruption preserves write-ahead claim and CoreSessionRestart enforces maxAttempts")
    func shutdownClaimPreservationAndRestartRecovery() async throws {
        let harness = try await SessionDatabaseHelper.makeHarness()
        let sid = (try await harness.session.create(CoreSession.CreateInput(
            location: OpenCodeLocation(directory: "/workspace/restart")
        ))).id

        // Simulate a write-ahead claim left behind by crash or shutdown interruption.
        try harness.store.claim(sid)
        #expect(try harness.store.listSuspended() == [sid])

        let woke = SessionDatabaseHelper.SessionIDLog()
        let restartSvc = CoreSessionRestart.Service(
            db: harness.db,
            store: harness.store,
            execution: SessionDatabaseHelper.RecordingExecution(log: woke),
            bus: harness.bus,
            options: CoreSessionRestart.Options(maxAttempts: 2)
        )

        // Attempt 1 & 2: inject synthetic continuation notice and wake.
        try await restartSvc.resumeSuspendedSessions()
        try await restartSvc.resumeSuspendedSessions()
        #expect(woke.snapshot().count == 2)
        #expect(try harness.store.listSuspended() == [sid]) // claim still held until terminal

        // Attempt 3 (> maxAttempts 2): terminalizes with Execution.Failed and releases claim!
        try await restartSvc.resumeSuspendedSessions()
        #expect(woke.snapshot().count == 2)
        #expect(try harness.store.listSuspended().isEmpty)

        let info = try harness.session.get(sid)
        #expect(info.outcome == SessionSchema.Outcome.failed)
    }

    @Test("Live CoreSessionExecution preserves claim on shutdown interrupt and releases claim on user interrupt")
    func liveExecutionInterruptClaimSemantics() async throws {
        // 1) Shutdown interruption preserves write-ahead claim (`time_suspended IS NOT NULL`).
        do {
            let harness = try await SessionDatabaseHelper.makeHarness()
            let llm = SessionDatabaseHelper.ScriptedLLMClient(scripts: [
                .delayedEvents(delayMs: 5_000, events: []),
            ])
            let model = SessionDatabaseHelper.makeResolvedModel()
            let ctx = CoreSessionContext.Service(
                db: harness.db,
                store: harness.store,
                models: CoreSessionRunnerModel.Service { _, _, _, _ in model }
            )
            let runner = CoreSessionRunner.Service(
                db: harness.db,
                bus: harness.bus,
                store: harness.store,
                context: ctx,
                llm: llm
            )
            let execution = CoreSessionExecution.Service(
                db: harness.db,
                store: harness.store,
                bus: harness.bus,
                inbox: harness.inbox,
                runnerForLocation: { _ in runner }
            )
            let sessionSvc = CoreSession.Service(
                db: harness.db,
                bus: harness.bus,
                store: harness.store,
                inbox: harness.inbox,
                execution: execution
            )
            let created = try await sessionSvc.create(CoreSession.CreateInput(
                location: OpenCodeLocation(directory: "/workspace/shutdown")
            ))
            _ = try await sessionSvc.prompt(CoreSession.PromptRequest(
                sessionID: created.id,
                input: CoreSessionPrompt.Input(text: "Long running work")
            ))
            // Wait briefly until the execution starts and writes its claim.
            for _ in 0..<50 {
                if try !harness.store.listSuspended().isEmpty { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(try harness.store.listSuspended() == [created.id])
            let interrupted = await execution.shutdownInterrupt(created.id)
            #expect(interrupted)
            await execution.awaitIdle(created.id)
            // Shutdown interruption MUST preserve the write-ahead claim!
            #expect(try harness.store.listSuspended() == [created.id])
        }

        // 2) User interruption releases write-ahead claim and records `outcome == .interrupted`.
        do {
            let harness = try await SessionDatabaseHelper.makeHarness()
            let llm = SessionDatabaseHelper.ScriptedLLMClient(scripts: [
                .delayedEvents(delayMs: 5_000, events: []),
            ])
            let model = SessionDatabaseHelper.makeResolvedModel()
            let ctx = CoreSessionContext.Service(
                db: harness.db,
                store: harness.store,
                models: CoreSessionRunnerModel.Service { _, _, _, _ in model }
            )
            let runner = CoreSessionRunner.Service(
                db: harness.db,
                bus: harness.bus,
                store: harness.store,
                context: ctx,
                llm: llm
            )
            let execution = CoreSessionExecution.Service(
                db: harness.db,
                store: harness.store,
                bus: harness.bus,
                inbox: harness.inbox,
                runnerForLocation: { _ in runner }
            )
            let sessionSvc = CoreSession.Service(
                db: harness.db,
                bus: harness.bus,
                store: harness.store,
                inbox: harness.inbox,
                execution: execution
            )
            let created = try await sessionSvc.create(CoreSession.CreateInput(
                location: OpenCodeLocation(directory: "/workspace/user-interrupt")
            ))
            _ = try await sessionSvc.prompt(CoreSession.PromptRequest(
                sessionID: created.id,
                input: CoreSessionPrompt.Input(text: "Cancel me")
            ))
            for _ in 0..<50 {
                if try !harness.store.listSuspended().isEmpty { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(try harness.store.listSuspended() == [created.id])
            let interrupted = try await sessionSvc.interrupt(created.id)
            #expect(interrupted)
            try await sessionSvc.awaitIdle(created.id)
            // User interruption MUST release the claim and project `.interrupted`.
            #expect(try harness.store.listSuspended().isEmpty)
            #expect(try sessionSvc.get(created.id).outcome == SessionSchema.Outcome.interrupted)
        }
    }

    // MARK: - 8. Revert, Fork, Transfer, Compaction, Stats, Generate, Title & Subagents

    @Test("Revert stage/clear/commit, fork, transfer export/import, compaction, stats, generate, and subagent helpers")
    func revertForkTransferCompactionAndStats() async throws {
        let harness = try await SessionDatabaseHelper.makeHarness()
        let loc = OpenCodeLocation(directory: "/workspace/full")
        let created = try await harness.session.create(CoreSession.CreateInput(location: loc, title: "Original"))

        let m1 = SessionMessageSchema.ID.create()
        let m2 = SessionMessageSchema.ID.create()
        _ = try await harness.session.prompt(CoreSession.PromptRequest(
            sessionID: created.id,
            id: m1,
            input: CoreSessionPrompt.Input(text: "Turn one"),
            resume: false
        ))
        _ = try await CoreSessionInbox.promote(db: harness.db, bus: harness.bus, sessionID: created.id, scope: .input)

        _ = try await harness.session.prompt(CoreSession.PromptRequest(
            sessionID: created.id,
            id: m2,
            input: CoreSessionPrompt.Input(text: "Turn two"),
            resume: false
        ))
        _ = try await CoreSessionInbox.promote(db: harness.db, bus: harness.bus, sessionID: created.id, scope: .input)

        // Fork session before `m2` -> forked session only has `m1`.
        let forked = try await harness.session.fork(sessionID: created.id, before: m2)
        #expect(forked.fork?.sessionID == created.id)
        #expect(forked.title == "Original (fork #1)")
        let forkedMsgs = try harness.session.messages(CoreSessionStore.MessagesInput(sessionID: forked.id, order: .asc))
        #expect(forkedMsgs.count == 1)

        // Stage revert at `m2`, clear it, re-stage and commit -> `m2` deleted.
        let staged = try await CoreSessionRevert.stage(
            db: harness.db,
            bus: harness.bus,
            session: try harness.session.get(created.id),
            messageID: m2
        )
        #expect(staged.messageID == m2)
        #expect(try harness.session.get(created.id).revert?.messageID == m2)

        try await CoreSessionRevert.clear(bus: harness.bus, session: try harness.session.get(created.id))
        #expect(try harness.session.get(created.id).revert == nil)

        _ = try await CoreSessionRevert.stage(
            db: harness.db,
            bus: harness.bus,
            session: try harness.session.get(created.id),
            messageID: m2
        )
        try await CoreSessionRevert.commit(bus: harness.bus, session: try harness.session.get(created.id))
        #expect(try harness.session.get(created.id).revert == nil)
        let afterCommit = try harness.session.messages(CoreSessionStore.MessagesInput(sessionID: created.id, order: .asc))
        #expect(afterCommit.count == 1)

        // Export & import into a fresh DB via CoreSessionTransfer.
        let transfer = CoreSessionTransfer.Service(db: harness.db, bus: harness.bus, store: harness.store)
        let bundle = try transfer.export(sessionID: created.id, sanitize: true)
        #expect(bundle.info.location.directory == "/sanitized")
        #expect(bundle.messages.count == 1)

        // Importing duplicate ID into same DB throws ImportConflictError.
        var importConflict = false
        do {
            _ = try await transfer.import(data: bundle, location: loc)
        } catch is CoreSessionTransfer.ImportConflictError {
            importConflict = true
        }
        #expect(importConflict)

        let harness2 = try await SessionDatabaseHelper.makeHarness()
        let transfer2 = CoreSessionTransfer.Service(db: harness2.db, bus: harness2.bus, store: harness2.store)
        let imported = try await transfer2.import(data: bundle, location: loc)
        #expect(imported.id == created.id)
        #expect(try harness2.store.messages(CoreSessionStore.MessagesInput(sessionID: imported.id, order: .asc)).count == 1)

        // Stats aggregation.
        let stats = try CoreSessionStats.get(db: harness.db)
        #expect(stats.sessions >= 1)
        #expect(stats.prompts >= 1)

        // Non-mutating generate & title generation + compaction prompt/usage helpers.
        let llm = SessionDatabaseHelper.ScriptedLLMClient(scripts: [
            .events([
                .textStart(AISchema.TextStart(id: "g1")),
                .textDelta(AISchema.TextDelta(id: "g1", text: "Generated summary")),
                .textEnd(AISchema.TextEnd(id: "g1")),
                .finish(AISchema.Finish(
                    reason: AISchema.FinishReasonDetails(normalized: .stop),
                    usage: AISchema.Usage(outputTokens: 15, nonCachedInputTokens: 50)
                )),
            ]),
            .events([
                .textStart(AISchema.TextStart(id: "t1")),
                .textDelta(AISchema.TextDelta(id: "t1", text: "Concise Generated Title")),
                .textEnd(AISchema.TextEnd(id: "t1")),
                .finish(AISchema.Finish(reason: AISchema.FinishReasonDetails(normalized: .stop))),
            ]),
        ])
        let model = SessionDatabaseHelper.makeResolvedModel()
        let ctxSvc = CoreSessionContext.Service(
            db: harness.db,
            store: harness.store,
            models: CoreSessionRunnerModel.Service { _, _, _, _ in model }
        )
        let genRes = try await CoreSessionGenerate.generate(
            session: try harness.session.get(created.id),
            prompt: "Summarize",
            db: harness.db,
            bus: harness.bus,
            context: ctxSvc,
            llm: llm
        )
        #expect(genRes.text == "Generated summary")
        #expect(try harness.session.messages(CoreSessionStore.MessagesInput(sessionID: created.id)).count == 1)

        let titleSvc = CoreSessionTitle.Service(
            db: harness.db,
            bus: harness.bus,
            store: harness.store,
            context: ctxSvc,
            llm: llm
        )
        try await titleSvc.generate(created.id)
        #expect(try harness.session.get(created.id).title == "Concise Generated Title")

        // Compaction prompt & subagent depth/completion formatting.
        #expect(CoreSessionCompaction.buildPrompt(update: false).contains("## Objective"))
        #expect(CoreSessionCompaction.buildPrompt(update: true, legacy: true).contains("earlier format"))

        let child = try await harness.session.create(CoreSession.CreateInput(parentID: created.id, title: "Child"))
        #expect(try CoreSessionSubagentDepth.reached(parent: created, store: harness.store, limit: 1) == nil)
        #expect(try CoreSessionSubagentDepth.reached(parent: child, store: harness.store, limit: 1) == 1)

        let body = CoreSessionSubagentCompletion.formatBody(
            "Done",
            childSessionID: child.id,
            background: [.shell(sessionID: child.id, shellID: "sh_1", command: "sleep   10")]
        )
        #expect(body.contains("Background work still running:"))
        #expect(body.contains("sleep 10"))

        // Error mapping coverage.
        let rateErr = AISchema.AIError(reason: .rateLimit(AISchema.RateLimitError(message: "Slow down", retryAfterMs: 1500)))
        let mapped = CoreSessionErrorMapping.toSessionError(rateErr)
        #expect(mapped.type == "provider.rate-limit")
        #expect(mapped.retryAfterMs == 1500)
    }
}
