import Testing
import OpenCodeSchema

@Suite("Session, Message, Event & Manifest Schema Tests")
struct SessionEventSchemaTests {
    // MARK: - Test Fixtures

    private static let sampleSessionID = SessionID(rawValue: "ses_00000000000000000000000001")!
    private static let sampleParentSessionID = SessionID(rawValue: "ses_00000000000000000000000002")!
    private static let sampleWorkspaceID = WorkspaceID(rawValue: "wrk_00000000000000000000000001")!
    private static let sampleMessageID = SessionMessageSchema.ID(rawValue: "msg_00000000000000000000000001")!
    private static let sampleMessageID2 = SessionMessageSchema.ID(rawValue: "msg_00000000000000000000000002")!
    private static let sampleEventID = EventSchema.ID(rawValue: "evt_00000000000000000000000001")!
    private static let sampleHash64 = String(repeating: "a", count: 64)
    private static let sampleModel = SessionSchema.ModelRef(
        id: "claude-sonnet-4-5",
        providerID: "anthropic",
        variant: "high"
    )
    private static let sampleTokens = SessionSchema.TokenUsage(
        input: 1200,
        output: 450,
        reasoning: 100,
        cache: .init(read: 300, write: 50)
    )
    private static let sampleLocation = OpenCodeLocation(
        directory: "/workspace/app",
        workspaceID: sampleWorkspaceID
    )
    private static let sampleError = SessionErrorSchema.Error(
        type: "rate_limit",
        message: "Too many requests",
        status: 429,
        response: .init(body: "{\"error\":\"slow down\"}"),
        retryAfterMs: 1500
    )

    // MARK: - SessionCoreSchemas

    @Test("SessionSchema.Info encodes exact wire keys and omits absent optionals")
    func sessionInfoRoundTrip() throws {
        let info = SessionSchema.Info(
            id: Self.sampleSessionID,
            parentID: Self.sampleParentSessionID,
            fork: .init(
                sessionID: Self.sampleParentSessionID,
                boundary: .through(messageID: Self.sampleMessageID)
            ),
            projectID: ProjectID(rawValue: "proj_abc"),
            agent: "build",
            model: Self.sampleModel,
            cost: 0.042,
            tokens: Self.sampleTokens,
            outcome: .succeeded,
            time: .init(
                created: 1_700_000_000_000,
                updated: 1_700_000_005_000,
                busy: 1_700_000_001_000,
                idle: 1_700_000_004_000,
                viewed: 1_700_000_004_500
            ),
            title: "Port schemas",
            location: Self.sampleLocation,
            subpath: "packages/schema",
            metadata: ["env": .string("test"), "count": .int(3)],
            permissions: [.init(action: "read", resource: "*.env", effect: .ask)],
            revert: .init(
                messageID: Self.sampleMessageID,
                snapshot: "snap_1",
                files: [.init(file: "README.md", patch: "+hi", additions: 1, deletions: 0, status: .modified)]
            )
        )

        let (decoded, json) = try SessionEventCodecHelper.roundTrip(info)
        #expect(decoded == info)
        #expect(decoded.tokens.total == 2100)

        let obj = try SessionEventCodecHelper.decodeJSONObject(json)
        #expect(obj["id"] == .string(Self.sampleSessionID.rawValue))
        #expect(obj["outcome"] == .string("succeeded"))
        if case .object(let timeObj) = obj["time"] {
            #expect(timeObj["archived"] == nil)
            #expect(timeObj["idle"] == .int(1_700_000_004_000))
        } else {
            Issue.record("Expected time object in Session.Info JSON")
        }

        // Minimal session omits all optional keys
        let minimal = SessionSchema.Info(
            id: Self.sampleSessionID,
            projectID: .global,
            cost: 0,
            tokens: .zero,
            time: .init(created: 100, updated: 100),
            location: OpenCodeLocation(directory: "/tmp")
        )
        let (decodedMinimal, minimalJSON) = try SessionEventCodecHelper.roundTrip(minimal)
        #expect(decodedMinimal == minimal)
        let minimalObj = try SessionEventCodecHelper.decodeJSONObject(minimalJSON)
        #expect(minimalObj["parentID"] == nil)
        #expect(minimalObj["fork"] == nil)
        #expect(minimalObj["revert"] == nil)
        #expect(minimalObj["title"] == nil)
    }

    @Test("SessionSchema.ListFilter and ListCursor match upstream wire encoding")
    func sessionListFilterAndCursor() throws {
        let filter = SessionSchema.ListFilter(
            order: .desc,
            search: "schema",
            parentID: .root,
            archived: false,
            directory: "/tmp/proj"
        )
        let (decodedFilter, filterJSON) = try SessionEventCodecHelper.roundTrip(filter)
        #expect(decodedFilter == filter)
        let filterObj = try SessionEventCodecHelper.decodeJSONObject(filterJSON)
        #expect(filterObj["parentID"] == .string("null"))
        #expect(filterObj["archived"] == .string("false"))

        // Verify interoperability with exact cursor produced by upstream TypeScript `Session.ListCursor.make`
        let exactUpstreamCursor = "eyJvcmRlciI6ImRlc2MiLCJwYXJlbnRJRCI6Im51bGwiLCJhcmNoaXZlZCI6ImZhbHNlIiwiZGlyZWN0b3J5IjoiL3RtcC9wcm9qIiwiYW5jaG9yIjp7ImlkIjoic2VzXzAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAxIiwidGltZSI6MTcwMDAwMDAwMDAwMCwiZGlyZWN0aW9uIjoibmV4dCJ9fQ"
        let parsedUpstream = try SessionSchema.ListCursor.parse(exactUpstreamCursor)
        #expect(parsedUpstream.order == .desc)
        #expect(parsedUpstream.parentID == .root)
        #expect(parsedUpstream.archived == false)
        #expect(parsedUpstream.scope == .directory("/tmp/proj"))
        #expect(parsedUpstream.anchor == .init(id: Self.sampleSessionID, time: 1_700_000_000_000, direction: .next))

        // Round-trip all 3 cursor scopes
        let scopes: [SessionSchema.ListCursor.Scope] = [
            .directory("/workspace/repo"),
            .project(ProjectID(rawValue: "proj_1"), subpath: "apps/cli"),
            .all,
        ]
        for scope in scopes {
            let payload = SessionSchema.ListCursor.Payload(
                order: .asc,
                search: "test",
                parentID: .session(Self.sampleParentSessionID),
                archived: true,
                scope: scope,
                anchor: .init(id: Self.sampleSessionID, time: 123_456, direction: .previous)
            )
            let cursor = try SessionSchema.ListCursor.make(payload)
            let parsed = try cursor.parse()
            #expect(parsed == payload)
        }

        // Invalid cursors fail cleanly
        #expect(throws: SessionSchema.ListCursor.CursorError.invalidCursor) {
            _ = try SessionSchema.ListCursor.parse("")
        }
        #expect(throws: SessionSchema.ListCursor.CursorError.invalidCursor) {
            _ = try SessionSchema.ListCursor.parse("%%%not-base64%%%")
        }
    }

    @Test("SessionErrorSchema validates HTTP status and non-negative retryAfterMs")
    func sessionErrorValidation() throws {
        let (decoded, _) = try SessionEventCodecHelper.roundTrip(Self.sampleError)
        #expect(decoded == Self.sampleError)

        #expect(throws: (any Error).self) {
            _ = try SessionEventCodecHelper.decodeFromString(
                SessionErrorSchema.Error.self,
                json: #"{"type":"err","message":"bad","status":99}"#
            )
        }
        #expect(throws: (any Error).self) {
            _ = try SessionEventCodecHelper.decodeFromString(
                SessionErrorSchema.Error.self,
                json: #"{"type":"err","message":"bad","status":600}"#
            )
        }
        #expect(throws: (any Error).self) {
            _ = try SessionEventCodecHelper.decodeFromString(
                SessionErrorSchema.Error.self,
                json: #"{"type":"err","message":"bad","retryAfterMs":-5}"#
            )
        }
    }

    @Test("SessionRevertSchema.PersistedRevert upgrades legacy RevertV1 to canonical Revert")
    func persistedRevertMigration() throws {
        let legacyJSON = """
        {
          "messageID": "\(Self.sampleMessageID.rawValue)",
          "partID": "prt_legacy",
          "snapshot": "",
          "diff": "old diff",
          "files": [
            {"path": "src/main.swift", "status": "modified", "additions": 4, "deletions": 2, "patch": "@@ -1 +1 @@"}
          ]
        }
        """
        let persisted = try SessionEventCodecHelper.decodeFromString(
            SessionRevertSchema.PersistedRevert.self,
            json: legacyJSON
        )
        #expect(persisted.revert.messageID == Self.sampleMessageID)
        #expect(persisted.revert.partID == "prt_legacy")
        #expect(persisted.revert.snapshot == nil)
        #expect(persisted.revert.files?.count == 1)
        #expect(persisted.revert.files?.first?.file == "src/main.swift")

        let reencoded = try SessionEventCodecHelper.encodeToString(persisted)
        let obj = try SessionEventCodecHelper.decodeJSONObject(reencoded)
        #expect(obj["diff"] == nil)
        #expect(obj["snapshot"] == nil)
        if case .array(let files) = obj["files"], case .object(let first) = files.first {
            #expect(first["file"] == .string("src/main.swift"))
            #expect(first["path"] == nil)
        } else {
            Issue.record("Expected canonical files array with 'file' key")
        }
    }

    @Test("SessionStatsSchema.Info and Tools union round-trip cleanly")
    func sessionStatsRoundTrip() throws {
        let totals = SessionStatsSchema.ToolTotals(calls: 10, succeeded: 8, failed: 1, unfinished: 1)
        let usage = [
            SessionStatsSchema.ToolUsage(
                name: "read",
                calls: 6,
                succeeded: 6,
                failed: 0,
                unfinished: 0,
                durationP50: 12.5
            ),
        ]
        for tools in [
            SessionStatsSchema.Tools.none,
            .summary(totals: totals),
            .detail(totals: totals, usage: usage),
        ] {
            let stats = SessionStatsSchema.Info(
                range: .init(from: 1_700_000_000_000, to: 1_700_086_400_000),
                sessions: 3,
                subagents: 1,
                prompts: 9,
                steps: 15,
                tokens: Self.sampleTokens,
                cost: 0.25,
                tools: tools,
                activeDays: 2,
                streak: 2,
                activity: [.init(date: "2026-11-18", steps: 15)],
                models: [.init(model: Self.sampleModel, steps: 15, tokens: Self.sampleTokens, cost: 0.25)]
            )
            let (decoded, _) = try SessionEventCodecHelper.roundTrip(stats)
            #expect(decoded == stats)
        }
    }

    @Test("SessionLegacySchema upgrades pre-v2.1 events, messages, and parts")
    func sessionLegacyUpgrades() {
        // Event field renames + current name precedence
        let renamedText = SessionLegacySchema.event(
            type: "session.text.ended",
            data: .object(["text": .string("hi"), "state": .object(["sig": .string("abc")])])
        )
        #expect(renamedText == .object(["text": .string("hi"), "native": .object(["sig": .string("abc")])]))

        let currentWins = SessionLegacySchema.event(
            type: "session.step.ended",
            data: .object([
                "providerState": .object(["old": .bool(true)]),
                "native": .object(["new": .bool(true)]),
            ])
        )
        #expect(currentWins == .object(["native": .object(["new": .bool(true)])]))

        // Compaction ended upgrades providerContext including pre-2.0.15 media parts and omits recent
        let compactionEvent = SessionLegacySchema.event(
            type: "session.compaction.ended",
            data: .object([
                "recent": .string("old text"),
                "providerContext": .object([
                    "messages": .array([
                        .object([
                            "role": .string("user"),
                            "content": .array([
                                .object([
                                    "type": .string("media"),
                                    "mediaType": .string("image/png"),
                                    "data": .string("YQ=="),
                                ]),
                            ]),
                        ]),
                    ]),
                ]),
            ])
        )
        if case .object(let dict) = compactionEvent {
            #expect(dict["recent"] == nil)
            #expect(dict["providerContext"] == nil)
            if case .object(let native) = dict["native"],
               case .array(let msgs) = native["messages"],
               case .object(let msg) = msgs.first,
               case .array(let content) = msg["content"],
               case .object(let part) = content.first,
               case .object(let media) = part["media"],
               case .object(let source) = media["source"]
            {
                #expect(source["type"] == .string("base64"))
                #expect(source["data"] == .string("YQ=="))
                #expect(source["mediaType"] == .string("image/png"))
            } else {
                Issue.record("Expected upgraded media source inside native.messages")
            }
        } else {
            Issue.record("Expected object from SessionLegacySchema.event")
        }

        // Messages upgrade assistant tool providerState + providerResultState merge, and compaction recent -> metadata.recent
        let upgradedMessages = SessionLegacySchema.messages([
            .object([
                "type": .string("assistant"),
                "providerState": .object(["stepKey": .int(1)]),
                "content": .array([
                    .object([
                        "type": .string("tool"),
                        "state": .object(["status": .string("completed")]),
                        "providerState": .object(["call": .string("c1"), "shared": .string("call")]),
                        "providerResultState": .object(["res": .string("r1"), "shared": .string("result")]),
                    ]),
                ]),
            ]),
            .object([
                "type": .string("compaction"),
                "recent": .string("kept summary"),
                "metadata": .object(["other": .bool(true)]),
            ]),
        ])
        if case .object(let assistant) = upgradedMessages[0],
           case .array(let parts) = assistant["content"],
           case .object(let toolPart) = parts[0],
           case .object(let native) = toolPart["native"]
        {
            #expect(assistant["native"] == .object(["stepKey": .int(1)]))
            #expect(toolPart["state"] == .object(["status": .string("completed")]))
            #expect(native["call"] == .string("c1"))
            #expect(native["res"] == .string("r1"))
            #expect(native["shared"] == .string("result"))
        } else {
            Issue.record("Expected upgraded assistant message")
        }

        if case .object(let compaction) = upgradedMessages[1],
           case .object(let meta) = compaction["metadata"]
        {
            #expect(compaction["recent"] == nil)
            #expect(meta["recent"] == .string("kept summary"))
            #expect(meta["other"] == .bool(true))
        } else {
            Issue.record("Expected upgraded compaction message")
        }
    }

    // MARK: - Prompt & SessionMessage & SessionInbox

    @Test("PromptSchema validates Base64, MediaRef, attachments, and PromptInput")
    func promptSchemasAndValidation() throws {
        #expect(PromptSchema.Base64(rawValue: "") != nil)
        #expect(PromptSchema.Base64(rawValue: "YQ==") != nil)
        #expect(PromptSchema.Base64(rawValue: "YWI=") != nil)
        #expect(PromptSchema.Base64(rawValue: "YWJj") != nil)
        #expect(PromptSchema.Base64(rawValue: "==") == nil)
        #expect(PromptSchema.Base64(rawValue: "====") == nil)
        #expect(PromptSchema.Base64(rawValue: "Y===") == nil)
        #expect(PromptSchema.Base64(rawValue: "Y=WI") == nil)
        #expect(PromptSchema.Base64(rawValue: "YW-j") == nil)

        let validMedia = "media:" + Self.sampleHash64
        #expect(PromptSchema.MediaRef(rawValue: validMedia) != nil)
        #expect(PromptSchema.MediaRef(rawValue: "media:" + String(repeating: "A", count: 64)) == nil)
        #expect(PromptSchema.MediaRef(rawValue: "media:1234") == nil)
        #expect(PromptSchema.MediaRef(rawValue: "file:" + Self.sampleHash64) == nil)

        let fileAttachment = PromptSchema.FileAttachment.create(
            .init(
                data: try PromptSchema.Base64(validating: "YWJj"),
                mime: "text/plain",
                source: .uri("file:///a.txt"),
                name: "a.txt",
                mention: .init(start: 0, end: 6, text: "@a.txt")
            )
        )
        let mediaAttachment = PromptSchema.MediaFileAttachment(
            mime: "image/png",
            source: .inline,
            name: "shot.png",
            uri: try PromptSchema.MediaRef(validating: validMedia),
            bytes: 1024,
            width: 800,
            height: 600
        )

        let attachments: [PromptSchema.Attachment] = [.file(fileAttachment), .media(mediaAttachment)]
        let (decodedAttachments, _) = try SessionEventCodecHelper.roundTrip(attachments)
        #expect(decodedAttachments == attachments)

        let prompt = PromptSchema.Prompt(
            text: "Inspect @a.txt",
            files: [fileAttachment],
            agents: [.init(name: "explore")],
            skills: [.init(id: "sk_1", name: "swift", text: "instructions")]
        )
        let (decodedPrompt, _) = try SessionEventCodecHelper.roundTrip(prompt)
        #expect(PromptSchema.Prompt.equivalence(decodedPrompt, prompt))

        let input = PromptInputSchema.Prompt(
            text: "Hello",
            files: [.init(uri: "file:///a.txt", source: .inline, name: "a.txt")],
            agents: [.init(name: "build")],
            skills: [.init(id: "sk_1")]
        )
        let (decodedInput, _) = try SessionEventCodecHelper.roundTrip(input)
        #expect(decodedInput == input)
    }

    @Test("SessionMessageSchema round-trips all 11 Info union cases, AssistantContent parts, and ToolState transitions")
    func sessionMessageUnionsRoundTrip() throws {
        let generatedID = SessionMessageSchema.ID.create()
        #expect(generatedID.rawValue.hasPrefix("msg_"))
        let fromEventID = try SessionMessageSchema.ID.fromEvent("evt_00000000000000000000000099")
        #expect(fromEventID.rawValue == "msg_00000000000000000000000099")
        #expect(SessionMessageSchema.ID(rawValue: "bad_123") == nil)

        let t = SessionMessageSchema.TimeCreated(created: 1_700_000_000_000)
        let toolParts: [SessionMessageSchema.AssistantContent] = [
            .text(.init(text: "Checking files", native: ["id": .string("txt_1")])),
            .reasoning(.init(text: "Think step by step", time: .init(created: 10, completed: 20))),
            .tool(.init(
                id: "call_1",
                name: "read",
                state: .streaming(.init(input: "{\"path\":")),
                time: .init(created: 21)
            )),
            .tool(.init(
                id: "call_2",
                name: "read",
                executed: true,
                state: .running(.init(input: ["path": .string("Package.swift")], metadata: ["line": .int(1)])),
                time: .init(created: 22, ran: 23)
            )),
            .tool(.init(
                id: "call_3",
                name: "read",
                executed: true,
                state: .completed(.init(
                    input: ["path": .string("Package.swift")],
                    content: [.text("swift-tools-version: 6.2"), .file(uri: "file:///a", mime: "text/plain", name: "a")],
                    metadata: ["bytes": .int(42)]
                )),
                time: .init(created: 24, ran: 25, completed: 26)
            )),
            .tool(.init(
                id: "call_4",
                name: "bash",
                executed: true,
                state: .error(.init(
                    input: ["command": .string("false")],
                    error: Self.sampleError,
                    content: [.text("stderr")],
                    metadata: ["exit": .int(1)]
                )),
                time: .init(created: 27, ran: 28, completed: 29)
            )),
        ]

        let messages: [SessionMessageSchema.Info] = [
            .agentSelected(.init(id: Self.sampleMessageID, time: t, agent: "build", previous: "plan")),
            .modelSelected(.init(id: Self.sampleMessageID, time: t, model: Self.sampleModel, previous: nil)),
            .locationSwitched(.init(
                id: Self.sampleMessageID,
                time: t,
                location: Self.sampleLocation,
                projectID: .global,
                subpath: "sub",
                previous: .init(location: OpenCodeLocation(directory: "/old"))
            )),
            .user(.init(id: Self.sampleMessageID, time: t, text: "Hello world")),
            .synthetic(.init(id: Self.sampleMessageID, time: t, text: "Auto note", description: "hint")),
            .system(.init(id: Self.sampleMessageID, time: t, text: "Instructions updated", description: "policy")),
            .skill(.init(id: Self.sampleMessageID, time: t, skill: "sk_swift", name: "Swift", text: "Use Swift 6.2")),
            .shell(.init(
                id: Self.sampleMessageID,
                shellID: "sh_1",
                command: "swift test",
                status: .exited,
                exit: 0,
                output: .init(output: "ok", cursor: 2, size: 2, truncated: false),
                time: .init(created: 100, completed: 200)
            )),
            .assistant(.init(
                id: Self.sampleMessageID,
                agent: "build",
                model: Self.sampleModel,
                content: toolParts,
                snapshot: .init(start: "snap_0", end: "snap_1", files: ["a.swift"]),
                finish: .toolCalls,
                rawFinish: "tool_use",
                native: ["provider": .string("anthropic")],
                cost: 0.01,
                tokens: Self.sampleTokens,
                retry: .init(attempt: 1, at: 500, error: Self.sampleError),
                time: .init(created: 1, firstToken: 2, streamed: 3, completed: 4)
            )),
            .compaction(.running(.init(id: Self.sampleMessageID, time: t, reason: .auto, summary: "partial"))),
            .compaction(.completed(.init(
                id: Self.sampleMessageID,
                time: t,
                reason: .manual,
                model: Self.sampleModel,
                summary: "full summary",
                cost: 0.002,
                tokens: Self.sampleTokens
            ))),
            .compaction(.failed(.init(
                id: Self.sampleMessageID,
                time: t,
                reason: .auto,
                error: Self.sampleError,
                cost: 0.001
            ))),
            .idle(.init(id: Self.sampleMessageID, time: t, outcome: .succeeded)),
        ]

        let (decoded, _) = try SessionEventCodecHelper.roundTrip(messages)
        #expect(decoded == messages)
        #expect(SessionMessageSchema.MessageType.allCases.count == 11)

        // Empty content in completed tool state must fail decoding
        #expect(throws: (any Error).self) {
            _ = try SessionEventCodecHelper.decodeFromString(
                SessionMessageSchema.ToolStateCompleted.self,
                json: #"{"status":"completed","input":{},"content":[]}"#
            )
        }

        // MediaInfo round-trip with server-stored MediaRef attachment
        let mediaMsg = SessionMessageSchema.MediaInfo.user(
            .init(
                id: Self.sampleMessageID,
                time: t,
                text: "See image",
                files: [
                    .media(.init(
                        mime: "image/png",
                        source: .inline,
                        uri: try PromptSchema.MediaRef(validating: "media:" + Self.sampleHash64),
                        bytes: 512
                    )),
                ]
            )
        )
        let (decodedMedia, _) = try SessionEventCodecHelper.roundTrip(mediaMsg)
        #expect(decodedMedia == mediaMsg)
    }

    @Test("SessionInboxSchema round-trips Delivery modes, Item union, Info, and MediaInfo")
    func sessionInboxRoundTrip() throws {
        let t = SessionMessageSchema.TimeCreated(created: 1_700_000_000_000)
        let items: [SessionInboxSchema.Item] = [
            .user(payload: .init(text: "Steer this", metadata: ["k": .int(1)]), delivery: .steer),
            .synthetic(payload: .init(text: "Injected", description: "timer"), delivery: .queue),
            .compaction(payload: .init(), delivery: .steer),
            .move(payload: .init(location: Self.sampleLocation, projectID: .global, subpath: "pkg"), delivery: .queue),
        ]
        let (decodedItems, _) = try SessionEventCodecHelper.roundTrip(items)
        #expect(decodedItems == items)

        let records: [SessionInboxSchema.Info] = [
            .user(.init(
                id: Self.sampleMessageID,
                sessionID: Self.sampleSessionID,
                time: t,
                payload: .init(text: "Hi"),
                delivery: .steer
            )),
            .synthetic(.init(
                id: Self.sampleMessageID,
                sessionID: Self.sampleSessionID,
                time: t,
                payload: .init(text: "Ping"),
                delivery: .queue
            )),
            .compaction(.init(
                id: Self.sampleMessageID,
                sessionID: Self.sampleSessionID,
                time: t,
                delivery: .steer
            )),
            .move(.init(
                id: Self.sampleMessageID,
                sessionID: Self.sampleSessionID,
                time: t,
                payload: .init(location: Self.sampleLocation, projectID: .global),
                delivery: .queue
            )),
        ]
        let (decodedRecords, _) = try SessionEventCodecHelper.roundTrip(records)
        #expect(decodedRecords == records)
        #expect(SessionInboxSchema.Delivery.allCases == [.steer, .queue])

        let mediaInbox = SessionInboxSchema.MediaInfo.user(
            .init(
                id: Self.sampleMessageID,
                sessionID: Self.sampleSessionID,
                time: t,
                payload: .init(
                    text: "Media prompt",
                    files: [.media(.init(mime: "image/webp", source: .inline, uri: try PromptSchema.MediaRef(validating: "media:" + Self.sampleHash64)))]
                ),
                delivery: .steer
            )
        )
        let (decodedMediaInbox, _) = try SessionEventCodecHelper.roundTrip(mediaInbox)
        #expect(decodedMediaInbox == mediaInbox)
    }

    // MARK: - SessionEventSchemas

    @Test("SessionEventSchema covers all 54 session events (48 durable + 6 ephemeral) with exact versions")
    func sessionEventsFullRoundTripAndVersioning() throws {
        #expect(SessionEventSchema.Definitions.count == 52)
        #expect(SessionEventSchema.DurableDefinitions.count == 48)
        #expect(SessionEventSchema.EphemeralDefinitions.count == 6)
        #expect(SessionEventSchema.All.count == 54)
        #expect(SessionEventSchema.EventType.allCases.count == 54)

        let publicTypes = Set(SessionEventSchema.Definitions.map(\.type))
        #expect(!publicTypes.contains("session.usage.recorded"))
        #expect(!publicTypes.contains("session.message.content.updated"))

        let seq0 = try EventSchema.Seq(validating: 0)
        let sid = Self.sampleSessionID
        let mid = Self.sampleMessageID
        let eid = Self.sampleEventID
        let shellInfo = SessionMessageSchema.ShellInfo(
            id: "sh_01",
            status: .running,
            command: "echo hi",
            cwd: "/workspace/app",
            shell: "/bin/zsh",
            file: "/tmp/sh_01.log",
            time: .init(started: 1_700_000_000_000)
        )

        let allEvents: [SessionEventSchema.Event] = [
            .durable(.created(SessionEventSchema.Created.makeEnvelope(
                id: eid, created: 1, aggregateID: sid.rawValue, seq: seq0,
                data: .init(sessionID: sid, projectID: .global, location: Self.sampleLocation, slug: "s1", version: "2.1.0")
            ))),
            .durable(.agentSelected(SessionEventSchema.AgentSelected.makeEnvelope(
                id: eid, created: 2, aggregateID: sid.rawValue, seq: seq0,
                data: .init(sessionID: sid, agent: "build", previous: "plan")
            ))),
            .durable(.modelSelected(SessionEventSchema.ModelSelected.makeEnvelope(
                id: eid, created: 3, aggregateID: sid.rawValue, seq: seq0,
                data: .init(sessionID: sid, model: Self.sampleModel)
            ))),
            .durable(.moved(SessionEventSchema.Moved.makeEnvelope(
                id: eid, created: 4, aggregateID: sid.rawValue, seq: seq0,
                data: .init(sessionID: sid, location: Self.sampleLocation, projectID: .global, subpath: "a/b")
            ))),
            .durable(.renamed(SessionEventSchema.Renamed.makeEnvelope(
                id: eid, created: 5, aggregateID: sid.rawValue, seq: seq0,
                data: .init(sessionID: sid, title: "New Title")
            ))),
            .durable(.metadataUpdated(SessionEventSchema.MetadataUpdated.makeEnvelope(
                id: eid, created: 6, aggregateID: sid.rawValue, seq: seq0,
                data: .init(sessionID: sid, metadata: ["tag": .string("v2")])
            ))),
            .durable(.permissions(SessionEventSchema.Permissions.makeEnvelope(
                id: eid, created: 7, aggregateID: sid.rawValue, seq: seq0,
                data: .init(sessionID: sid, permissions: [.init(action: "*", resource: "*", effect: .allow)])
            ))),
            .durable(.viewed(SessionEventSchema.Viewed.makeEnvelope(
                id: eid, created: 8, aggregateID: sid.rawValue, seq: seq0,
                data: .init(sessionID: sid, idle: 1_700_000_000_000)
            ))),
            .durable(.archived(SessionEventSchema.Archived.makeEnvelope(
                id: eid, created: 9, aggregateID: sid.rawValue, seq: seq0,
                data: .init(sessionID: sid)
            ))),
            .durable(.unarchived(SessionEventSchema.Unarchived.makeEnvelope(
                id: eid, created: 10, aggregateID: sid.rawValue, seq: seq0,
                data: .init(sessionID: sid)
            ))),
            .durable(.deleted(SessionEventSchema.Deleted.makeEnvelope(
                id: eid, created: 11, aggregateID: sid.rawValue, seq: seq0,
                data: .init(sessionID: sid)
            ))),
            .durable(.forked(SessionEventSchema.Forked.makeEnvelope(
                id: eid, created: 12, aggregateID: sid.rawValue, seq: seq0,
                data: .init(
                    sessionID: sid,
                    parentID: Self.sampleParentSessionID,
                    boundary: .before(messageID: mid),
                    instructions: ["api/rules": Self.sampleHash64],
                    instructionEntries: [.init(key: "rules", value: .string("strict"), removed: false)]
                )
            ))),
            .durable(.inboxDelivered(SessionEventSchema.InboxDelivered.makeEnvelope(
                id: eid, created: 13, aggregateID: sid.rawValue, seq: seq0,
                data: .init(sessionID: sid, inboxID: mid)
            ))),
            .durable(.inboxEnqueued(SessionEventSchema.InboxEnqueued.makeEnvelope(
                id: eid, created: 14, aggregateID: sid.rawValue, seq: seq0,
                data: .init(sessionID: sid, inboxID: mid, item: .user(payload: .init(text: "Go"), delivery: .steer))
            ))),
            .durable(.inboxCancelled(SessionEventSchema.InboxCancelled.makeEnvelope(
                id: eid, created: 15, aggregateID: sid.rawValue, seq: seq0,
                data: .init(sessionID: sid, inboxID: mid)
            ))),
            .durable(.inboxDeliveryChanged(SessionEventSchema.InboxDeliveryChanged.makeEnvelope(
                id: eid, created: 16, aggregateID: sid.rawValue, seq: seq0,
                data: .init(sessionID: sid, inboxID: mid, delivery: .queue)
            ))),
            .durable(.executionStarted(SessionEventSchema.Execution.Started.makeEnvelope(
                id: eid, created: 17, aggregateID: sid.rawValue, seq: seq0, data: .init(sessionID: sid)
            ))),
            .durable(.executionSucceeded(SessionEventSchema.Execution.Succeeded.makeEnvelope(
                id: eid, created: 18, aggregateID: sid.rawValue, seq: seq0, data: .init(sessionID: sid)
            ))),
            .durable(.executionFailed(SessionEventSchema.Execution.Failed.makeEnvelope(
                id: eid, created: 19, aggregateID: sid.rawValue, seq: seq0, data: .init(sessionID: sid, error: Self.sampleError)
            ))),
            .durable(.executionInterrupted(SessionEventSchema.Execution.Interrupted.makeEnvelope(
                id: eid, created: 20, aggregateID: sid.rawValue, seq: seq0, data: .init(sessionID: sid, reason: .user)
            ))),
            .durable(.instructionsUpdated(SessionEventSchema.InstructionsUpdated.makeEnvelope(
                id: eid, created: 21, aggregateID: sid.rawValue, seq: seq0,
                data: .init(sessionID: sid, delta: ["api/a": .hash(Self.sampleHash64), "api/b": .removed], text: "updated")
            ))),
            .durable(.synthetic(SessionEventSchema.Synthetic.makeEnvelope(
                id: eid, created: 22, aggregateID: sid.rawValue, seq: seq0,
                data: .init(sessionID: sid, text: "synthetic note", description: "desc")
            ))),
            .durable(.skillActivated(SessionEventSchema.Skill.Activated.makeEnvelope(
                id: eid, created: 23, aggregateID: sid.rawValue, seq: seq0,
                data: .init(sessionID: sid, id: "sk_1", name: "swift", text: "guide")
            ))),
            .durable(.shellStarted(SessionEventSchema.Shell.Started.makeEnvelope(
                id: eid, created: 24, aggregateID: sid.rawValue, seq: seq0,
                data: .init(sessionID: sid, shell: shellInfo)
            ))),
            .durable(.shellEnded(SessionEventSchema.Shell.Ended.makeEnvelope(
                id: eid, created: 25, aggregateID: sid.rawValue, seq: seq0,
                data: .init(sessionID: sid, shell: shellInfo, output: .init(output: "hi", cursor: 2, size: 2, truncated: false))
            ))),
            .durable(.stepStarted(SessionEventSchema.Step.Started.makeEnvelope(
                id: eid, created: 26, aggregateID: sid.rawValue, seq: seq0,
                data: .init(sessionID: sid, assistantMessageID: mid, agent: "build", model: Self.sampleModel, started: 100)
            ))),
            .durable(.stepFirstToken(SessionEventSchema.Step.FirstToken.makeEnvelope(
                id: eid, created: 27, aggregateID: sid.rawValue, seq: seq0,
                data: .init(sessionID: sid, assistantMessageID: mid)
            ))),
            .durable(.stepStreamed(SessionEventSchema.Step.Streamed.makeEnvelope(
                id: eid, created: 28, aggregateID: sid.rawValue, seq: seq0,
                data: .init(sessionID: sid, assistantMessageID: mid)
            ))),
            .durable(.stepEnded(SessionEventSchema.Step.Ended.makeEnvelope(
                id: eid, created: 29, aggregateID: sid.rawValue, seq: seq0,
                data: .init(sessionID: sid, assistantMessageID: mid, finish: .stop, cost: 0.01, tokens: Self.sampleTokens)
            ))),
            .durable(.stepFailed(SessionEventSchema.Step.Failed.makeEnvelope(
                id: eid, created: 30, aggregateID: sid.rawValue, seq: seq0,
                data: .init(sessionID: sid, assistantMessageID: mid, error: Self.sampleError, finish: .contentFilter)
            ))),
            .durable(.textStarted(SessionEventSchema.Text.Started.makeEnvelope(
                id: eid, created: 31, aggregateID: sid.rawValue, seq: seq0,
                data: .init(sessionID: sid, assistantMessageID: mid, ordinal: 0)
            ))),
            .textDelta(SessionEventSchema.Text.Delta.makeEnvelope(
                id: eid, created: 32,
                data: .init(sessionID: sid, assistantMessageID: mid, ordinal: 0, delta: "Hel")
            )),
            .durable(.textEnded(SessionEventSchema.Text.Ended.makeEnvelope(
                id: eid, created: 33, aggregateID: sid.rawValue, seq: seq0,
                data: .init(sessionID: sid, assistantMessageID: mid, ordinal: 0, text: "Hello")
            ))),
            .durable(.reasoningStarted(SessionEventSchema.Reasoning.Started.makeEnvelope(
                id: eid, created: 34, aggregateID: sid.rawValue, seq: seq0,
                data: .init(sessionID: sid, assistantMessageID: mid, ordinal: 0)
            ))),
            .reasoningDelta(SessionEventSchema.Reasoning.Delta.makeEnvelope(
                id: eid, created: 35,
                data: .init(sessionID: sid, assistantMessageID: mid, ordinal: 0, delta: "hmm")
            )),
            .durable(.reasoningEnded(SessionEventSchema.Reasoning.Ended.makeEnvelope(
                id: eid, created: 36, aggregateID: sid.rawValue, seq: seq0,
                data: .init(sessionID: sid, assistantMessageID: mid, ordinal: 0, text: "hmm done")
            ))),
            .durable(.toolInputStarted(SessionEventSchema.Tool.Input.Started.makeEnvelope(
                id: eid, created: 37, aggregateID: sid.rawValue, seq: seq0,
                data: .init(sessionID: sid, assistantMessageID: mid, id: "call_1", name: "read")
            ))),
            .toolInputDelta(SessionEventSchema.Tool.Input.Delta.makeEnvelope(
                id: eid, created: 38,
                data: .init(sessionID: sid, assistantMessageID: mid, id: "call_1", delta: "{\"path\":")
            )),
            .durable(.toolInputEnded(SessionEventSchema.Tool.Input.Ended.makeEnvelope(
                id: eid, created: 39, aggregateID: sid.rawValue, seq: seq0,
                data: .init(sessionID: sid, assistantMessageID: mid, id: "call_1", text: "{\"path\":\"a\"}")
            ))),
            .durable(.toolCalled(SessionEventSchema.Tool.Called.makeEnvelope(
                id: eid, created: 40, aggregateID: sid.rawValue, seq: seq0,
                data: .init(sessionID: sid, assistantMessageID: mid, id: "call_1", input: ["path": .string("a")], executed: true)
            ))),
            .toolProgress(SessionEventSchema.Tool.Progress.makeEnvelope(
                id: eid, created: 41,
                data: .init(sessionID: sid, assistantMessageID: mid, id: "call_1", metadata: ["pct": .int(50)])
            )),
            .durable(.toolSuccess(SessionEventSchema.Tool.Success.makeEnvelope(
                id: eid, created: 42, aggregateID: sid.rawValue, seq: seq0,
                data: .init(sessionID: sid, assistantMessageID: mid, id: "call_1", content: [.text("ok")], executed: true)
            ))),
            .durable(.toolFailed(SessionEventSchema.Tool.Failed.makeEnvelope(
                id: eid, created: 43, aggregateID: sid.rawValue, seq: seq0,
                data: .init(sessionID: sid, assistantMessageID: mid, id: "call_1", error: Self.sampleError, executed: true)
            ))),
            .durable(.retryScheduled(SessionEventSchema.RetryScheduled.makeEnvelope(
                id: eid, created: 44, aggregateID: sid.rawValue, seq: seq0,
                data: .init(sessionID: sid, assistantMessageID: mid, attempt: 2, at: 1_700_000_005_000, error: Self.sampleError)
            ))),
            .durable(.compactionStarted(SessionEventSchema.Compaction.Started.makeEnvelope(
                id: eid, created: 45, aggregateID: sid.rawValue, seq: seq0,
                data: .init(sessionID: sid, reason: .auto, inputID: mid)
            ))),
            .compactionDelta(SessionEventSchema.Compaction.Delta.makeEnvelope(
                id: eid, created: 46,
                data: .init(sessionID: sid, text: "summary chunk")
            )),
            .durable(.compactionEnded(SessionEventSchema.Compaction.Ended.makeEnvelope(
                id: eid, created: 47, aggregateID: sid.rawValue, seq: seq0,
                data: .init(sessionID: sid, reason: .auto, model: Self.sampleModel, text: "summary", cost: 0.005, tokens: Self.sampleTokens)
            ))),
            .durable(.compactionFailed(SessionEventSchema.Compaction.Failed.makeEnvelope(
                id: eid, created: 48, aggregateID: sid.rawValue, seq: seq0,
                data: .init(sessionID: sid, reason: .manual, error: Self.sampleError, inputID: mid)
            ))),
            .durable(.revertStaged(SessionEventSchema.RevertEvent.Staged.makeEnvelope(
                id: eid, created: 49, aggregateID: sid.rawValue, seq: seq0,
                data: .init(sessionID: sid, revert: .init(messageID: mid))
            ))),
            .durable(.revertCleared(SessionEventSchema.RevertEvent.Cleared.makeEnvelope(
                id: eid, created: 50, aggregateID: sid.rawValue, seq: seq0,
                data: .init(sessionID: sid)
            ))),
            .durable(.revertCommitted(SessionEventSchema.RevertEvent.Committed.makeEnvelope(
                id: eid, created: 51, aggregateID: sid.rawValue, seq: seq0,
                data: .init(sessionID: sid, to: Self.sampleMessageID2)
            ))),
            .durable(.usageRecorded(SessionEventSchema.UsageRecorded.makeEnvelope(
                id: eid, created: 52, aggregateID: sid.rawValue, seq: seq0,
                data: .init(sessionID: sid, source: .title, cost: 0.0005, tokens: Self.sampleTokens)
            ))),
            .durable(.messageContentUpdated(SessionEventSchema.MessageContentUpdated.makeEnvelope(
                id: eid, created: 53, aggregateID: sid.rawValue, seq: seq0,
                data: .init(sessionID: sid, messageID: mid, content: [.text(.init(text: "replaced"))])
            ))),
            .usageUpdated(SessionEventSchema.UsageUpdated.makeEnvelope(
                id: eid, created: 54,
                data: .init(sessionID: sid, cost: 0.05, tokens: Self.sampleTokens)
            )),
        ]

        #expect(allEvents.count == 54)
        #expect(Set(allEvents.map(\.eventType)).count == 54)

        let (decodedAll, _) = try SessionEventCodecHelper.roundTrip(allEvents)
        #expect(decodedAll == allEvents)

        // Confirm version mismatch is rejected (e.g. session.deleted requires version 2)
        let badDeletedV1 = """
        {
          "id": "\(eid.rawValue)",
          "created": 100,
          "type": "session.deleted",
          "durable": {"aggregateID": "\(sid.rawValue)", "seq": 0, "version": 1},
          "data": {"sessionID": "\(sid.rawValue)"}
        }
        """
        #expect(throws: (any Error).self) {
            _ = try SessionEventCodecHelper.decodeFromString(SessionEventSchema.DurableEvent.self, json: badDeletedV1)
        }
    }

    @Test("SessionStatusEventSchema encodes idle, busy, and retry statuses with action metadata")
    func sessionStatusEvents() throws {
        #expect(SessionStatusEventSchema.Status.identifier == "SessionStatusUpdated")
        #expect(SessionStatusEventSchema.Definitions.count == 2)

        let retry = SessionStatusEventSchema.Info.retry(
            attempt: 2,
            message: "Retrying after 429",
            action: .init(
                reason: "quota",
                provider: "anthropic",
                title: "Rate limited",
                message: "Upgrade plan",
                label: "Billing",
                link: "https://example.com"
            ),
            next: 1_700_000_010_000
        )
        let statusEvent = SessionStatusEventSchema.Status.makeEnvelope(
            id: Self.sampleEventID,
            created: 1_700_000_000_000,
            data: .init(sessionID: Self.sampleSessionID, status: retry)
        )
        let (decoded, _) = try SessionEventCodecHelper.roundTrip(statusEvent)
        #expect(decoded == statusEvent)
    }

    // MARK: - EventManifestSchemas & Domain Events

    @Test("EventSchema registries enforce latest version resolution and duplicate checks")
    func eventSchemaRegistries() throws {
        let id = EventSchema.ID.create()
        #expect(id.rawValue.hasPrefix("evt_"))
        #expect(EventSchema.Seq(rawValue: -1) == nil)
        #expect(EventSchema.Version(rawValue: 0) == nil)
        #expect(EventSchema.versionedType("session.deleted", version: 2) == "session.deleted.2")

        let v1 = EventSchema.Definition.durable(type: "custom.ev", aggregate: "id", version: 1)
        let v2 = EventSchema.Definition.durable(type: "custom.ev", aggregate: "id", version: 2)
        let eph = EventSchema.Definition.ephemeral(type: "custom.ping")

        let latest = try EventSchema.latest([v1, v2, eph, v2])
        #expect(latest["custom.ev"]?.durable?.version == 2)
        #expect(latest["custom.ping"]?.durability == .ephemeral)

        let dMap = try EventSchema.durableMap([v1, v2, eph])
        #expect(dMap.count == 2)
        #expect(dMap["custom.ev.1"] == v1)
        #expect(dMap["custom.ev.2"] == v2)

        #expect(throws: EventSchema.RegistryError.duplicateDurableDefinition(key: "custom.ev.1")) {
            _ = try EventSchema.durableMap([v1, v1])
        }

        let conflicting = EventSchema.Definition.durable(type: "custom.ev", aggregate: "other", version: 1)
        #expect(throws: EventSchema.RegistryError.duplicateLatestDefinition(type: "custom.ev")) {
            _ = try EventSchema.latest([v1, conflicting])
        }
    }

    @Test("EventManifestSchema and DurableEventManifestSchema match exact upstream counts and lookups")
    func eventManifestAndDurableManifest() throws {
        #expect(EventManifestSchema.ServerDefinitions.count == 98)
        #expect(EventManifestSchema.Server.count == 98)
        #expect(EventManifestSchema.Definitions.count == 110)
        #expect(EventManifestSchema.Latest.count == 110)
        #expect(DurableEventManifestSchema.Durable.count == 49)
        #expect(EventManifestSchema.Durable == DurableEventManifestSchema.Durable)

        // Server manifest membership checks
        #expect(EventManifestSchema.isServer(type: "session.created"))
        #expect(EventManifestSchema.isServer(type: "session.inbox.enqueued"))
        #expect(EventManifestSchema.isServer(type: "session.inbox.delivered"))
        #expect(EventManifestSchema.isServer(type: "session.status"))
        #expect(EventManifestSchema.isServer(type: "worktree.resolved"))
        #expect(EventManifestSchema.isServer(type: "mcp.status.changed"))
        #expect(EventManifestSchema.isServer(type: "mcp.resources.changed"))
        #expect(EventManifestSchema.isServer(type: "experimental.mcp.event"))
        #expect(EventManifestSchema.isServer(type: "tui.toast.show"))

        // Non-server events (compatibility / internal / client-only)
        #expect(!EventManifestSchema.isServer(type: "lsp.updated"))
        #expect(!EventManifestSchema.isServer(type: "mcp.tools.changed"))
        #expect(!EventManifestSchema.isServer(type: "experimental.mcp.subscription.changed"))
        #expect(!EventManifestSchema.isServer(type: "server.connected"))
        #expect(!EventManifestSchema.isServer(type: "global.disposed"))
        #expect(!EventManifestSchema.isServer(type: "command.executed"))
        #expect(!EventManifestSchema.isServer(type: "file.edited"))
        #expect(!EventManifestSchema.isServer(type: "workspace.ready"))
        #expect(!EventManifestSchema.isServer(type: "worktree.ready"))
        #expect(!EventManifestSchema.isServer(type: "session.usage.recorded"))
        #expect(!EventManifestSchema.isServer(type: "session.message.content.updated"))
        #expect(!EventManifestSchema.isServer(type: "unknown.event"))

        // Durable manifest lookups
        #expect(DurableEventManifestSchema.Durable["session.created.1"]?.durable?.aggregate == "sessionID")
        #expect(DurableEventManifestSchema.Durable["session.deleted.2"]?.durable?.version == 2)
        #expect(DurableEventManifestSchema.Durable["session.forked.2"]?.durable?.version == 2)
        #expect(DurableEventManifestSchema.Durable["session.instructions.updated.2"]?.durable?.version == 2)
        #expect(DurableEventManifestSchema.Durable["session.tool.success.2"]?.durable?.version == 2)
        #expect(DurableEventManifestSchema.Durable["session.tool.failed.2"]?.durable?.version == 2)
        #expect(DurableEventManifestSchema.Durable["session.usage.recorded.1"] != nil)
        #expect(DurableEventManifestSchema.Durable["session.message.content.updated.1"] != nil)
        #expect(DurableEventManifestSchema.Durable["worktree.resolved.1"]?.durable?.aggregate == "projectID")
        #expect(DurableEventManifestSchema.Durable["session.text.delta.1"] == nil)

        // ServerEvent validates event type and durability
        let validServerJSON = """
        {
          "id": "\(Self.sampleEventID.rawValue)",
          "created": 1700000000000,
          "type": "vcs.branch.updated",
          "data": {"branch": "main"}
        }
        """
        let serverEvent = try SessionEventCodecHelper.decodeFromString(
            EventManifestSchema.ServerEvent.self,
            json: validServerJSON
        )
        #expect(serverEvent.type == "vcs.branch.updated")
        #expect(EventManifestSchema.isServer(serverEvent.payload))

        let nonServerJSON = """
        {
          "id": "\(Self.sampleEventID.rawValue)",
          "created": 1700000000000,
          "type": "server.connected",
          "data": {}
        }
        """
        #expect(throws: (any Error).self) {
            _ = try SessionEventCodecHelper.decodeFromString(
                EventManifestSchema.ServerEvent.self,
                json: nonServerJSON
            )
        }
    }

    @Test("Domain event payloads preserve explicit null cursor, toast defaults, and custom TUI commands")
    func domainEventWireEdgeCases() throws {
        // McpEvent.ExperimentalEvent encodes explicit `"cursor": null`
        let mcpData = McpEventSchema.ExperimentalEventData(
            id: "sub_1",
            server: "github",
            name: "pr.opened",
            eventId: "ev_1",
            timestamp: "2026-11-18T00:00:00Z",
            data: .object(["number": .int(42)]),
            cursor: nil
        )
        let (decodedMcp, mcpJSON) = try SessionEventCodecHelper.roundTrip(mcpData)
        #expect(decodedMcp == mcpData)
        let mcpObj = try SessionEventCodecHelper.decodeJSONObject(mcpJSON)
        #expect(mcpObj["cursor"] == .null)
        #expect(mcpObj["truncated"] == nil)

        // TuiEvent.ToastShow defaults duration to 5000 when omitted
        let toastJSON = #"{"message":"Saved","variant":"success"}"#
        let decodedToast = try SessionEventCodecHelper.decodeFromString(
            TuiEventSchema.ToastShowData.self,
            json: toastJSON
        )
        #expect(decodedToast.duration == 5000)
        #expect(decodedToast.variant == .success)

        // TuiEvent.CommandExecute supports known literals and arbitrary custom commands
        let knownCmd = try SessionEventCodecHelper.roundTrip(
            TuiEventSchema.CommandExecuteData(command: .sessionCompact)
        )
        #expect(knownCmd.decoded.command == .sessionCompact)
        let customCmd = try SessionEventCodecHelper.roundTrip(
            TuiEventSchema.CommandExecuteData(command: .custom("plugin.custom.action"))
        )
        #expect(customCmd.decoded.command == .custom("plugin.custom.action"))

        // EventLog.Synced with and without seq
        let syncedEmpty = EventLogSchema.Synced(aggregateID: Self.sampleSessionID.rawValue)
        let (decodedSyncedEmpty, syncedJSON) = try SessionEventCodecHelper.roundTrip(syncedEmpty)
        #expect(decodedSyncedEmpty == syncedEmpty)
        let syncedObj = try SessionEventCodecHelper.decodeJSONObject(syncedJSON)
        #expect(syncedObj["type"] == .string("log.synced"))
        #expect(syncedObj["seq"] == nil)

        let syncedSeq = EventLogSchema.Synced(
            aggregateID: Self.sampleSessionID.rawValue,
            seq: try EventSchema.Seq(validating: 42)
        )
        let (decodedSyncedSeq, _) = try SessionEventCodecHelper.roundTrip(syncedSeq)
        #expect(decodedSyncedSeq == syncedSeq)

        // WorkspaceEvent & WorktreeEvent & SessionTransfer
        let wsStatus = WorkspaceEventSchema.ConnectionStatus(
            workspaceID: Self.sampleWorkspaceID,
            status: .connected
        )
        #expect(try SessionEventCodecHelper.roundTrip(wsStatus).decoded == wsStatus)

        let wtReady = WorktreeEventSchema.ReadyData(name: "feat-x", branch: "feat-x")
        #expect(try SessionEventCodecHelper.roundTrip(wtReady).decoded == wtReady)

        let transfer = SessionTransferSchema.Data(
            info: .init(
                id: Self.sampleSessionID,
                projectID: .global,
                cost: 0,
                tokens: .zero,
                time: .init(created: 1, updated: 1),
                location: Self.sampleLocation
            ),
            messages: [
                .user(.init(id: Self.sampleMessageID, time: .init(created: 1), text: "Exported")),
            ]
        )
        #expect(try SessionEventCodecHelper.roundTrip(transfer).decoded == transfer)
    }
}
