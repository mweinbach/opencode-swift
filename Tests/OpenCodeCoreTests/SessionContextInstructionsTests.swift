import Testing
import OpenCodeCore
import OpenCodePlatform
import OpenCodeSchema
import Synchronization

/// `core/src/session/context.ts#node`: `select` combines the Location's instruction services into the Session's
/// baseline in prompt-cache order, and later changes reconcile through `InstructionState` as durable updates.
@Suite("Session context instruction baseline (core/src/session/context.ts)")
struct SessionContextInstructionsTests {
    typealias Instructions = CoreInstruction.Instructions

    /// The upstream `Instructions.combine([...])` order in `SessionContext.select`.
    static let baselineOrder = [
        "core/codemode",
        "core/mcp-guidance",
        "core/reference-guidance",
        "core/skill-guidance",
        "core/machines",
        "core/instructions",
        "core/date",
        "core/environment",
        "api/rules",
    ]

    static let executeDenied: PermissionSchema.Ruleset = [
        PermissionSchema.Rule(action: "execute", resource: "*", effect: .deny),
    ]

    /// Mutable instruction-file content standing in for the instruction plugin's rescans.
    final class DiscoveryFiles: Sendable {
        let files = Mutex<[CoreInstruction.Discovery.File]>([])
        let unavailable = Mutex(false)
        let service = CoreInstruction.Discovery.Service()

        func start() async throws {
            _ = try await service.transform { [self] editor in
                if self.unavailable.withLock({ $0 }) {
                    editor.unavailable()
                    return
                }
                for file in self.files.withLock({ $0 }) { editor.add(file) }
            }
        }

        func set(_ files: [CoreInstruction.Discovery.File]) async {
            self.files.withLock { $0 = files }
            await service.reload()
        }
    }

    static func keyed(_ key: String, _ text: String) -> Instructions.List {
        Instructions.make(Instructions.Source.Definition<String>(
            key: Instructions.Key(rawValue: key)!,
            read: { .value(text) },
            renderInitial: { $0 },
            renderChanged: { _, next in next }
        ))
    }

    static func codeModeRegistry() async -> CoreTool.Service {
        let registry = CoreTool.Service(codeMode: CoreTool.CodeModeHost(transport: CoreToolsSyncFixture.transport))
        _ = await registry.transform { editor in
            editor.add(CoreToolsSyncFixture.tool("lookup", options: ToolSchema.Options(codemode: true)))
            editor.add(CoreToolsSyncFixture.tool("glob", options: ToolSchema.Options(codemode: false)))
        }
        return registry
    }

    static func instructionSources(discovery: DiscoveryFiles) async throws -> CoreSessionContext.InstructionSources {
        let skills = CoreSkill.Service()
        _ = try await skills.transform { editor in
            editor.add(SkillSchema.Info(
                id: .init(rawValue: "tidy"),
                name: .init(rawValue: "Tidy"),
                description: "Tidies Swift sources",
                path: SchemaPrimitive.AbsolutePath(rawValue: "/skills/tidy/SKILL.md"),
                content: "Run swift format"
            ))
        }
        let references = CoreInstruction.Reference.Service()
        _ = try await references.transform { editor in
            editor.add(name: "docs", source: .local(ReferenceSchema.LocalSource(
                path: SchemaPrimitive.AbsolutePath(rawValue: "/refs/docs"),
                description: "Product documentation"
            )))
        }
        let builtins = CoreInstruction.BuiltIns.Service(
            workingDirectory: "/workspace/ctx",
            workspaceRoot: "/workspace",
            tmpDirectory: "/tmp/opencode",
            dateStringProvider: { "Fri Nov 20 2026" }
        )
        let sources = CoreSessionContext.InstructionSources.services(
            builtins: builtins,
            discovery: discovery.service,
            skills: CoreSkill.SkillInstructions.Service(skills: skills),
            references: CoreInstruction.Reference.ReferenceInstructions.Service(references: references)
        )
        return CoreSessionContext.InstructionSources(
            builtins: sources.builtins,
            discovery: sources.discovery,
            skills: sources.skills,
            references: sources.references,
            mcp: { _ in keyed("core/mcp-guidance", "<mcp_instructions>stub</mcp_instructions>") },
            machines: { keyed("core/machines", "Other machines are available: lab.") }
        )
    }

    static func makeContext(
        harness: SessionDatabaseHelper.TestHarness,
        registry: CoreTool.Service,
        agentPermissions: PermissionSchema.Ruleset = [],
        instructions: CoreSessionContext.InstructionSources
    ) -> CoreSessionContext.Service {
        let model = SessionDatabaseHelper.makeResolvedModel()
        return CoreSessionContext.Service(
            db: harness.db,
            store: harness.store,
            models: CoreSessionRunnerModel.Service { _, _, _, _ in model },
            selectAgent: { _ in CoreSessionModelRequest.AgentProfile(id: "build", permissions: agentPermissions) },
            selectTools: { _, agent, _ in
                let snapshot = await registry.snapshot(permissions: agent.permissions, options: nil)
                return CoreSessionModelRequest.ToolSnapshot(
                    definitions: snapshot.definitions.map { .tool($0) },
                    codeModeCatalog: snapshot.codeModeCatalog
                )
            },
            instructions: instructions
        )
    }

    static func createSession(_ harness: SessionDatabaseHelper.TestHarness) async throws -> SessionID {
        try await harness.session.create(CoreSession.CreateInput(
            location: OpenCodeLocation(directory: "/workspace/ctx")
        )).id
    }

    @Test("select combines instruction sources in upstream's prompt-cache order, ending with Session entries")
    func combineOrder() async throws {
        let harness = try await SessionDatabaseHelper.makeHarness()
        let discovery = DiscoveryFiles()
        try await discovery.start()
        await discovery.set([CoreInstruction.Discovery.File(path: "/workspace/AGENTS.md", content: "Project rule v1")])
        let context = Self.makeContext(
            harness: harness,
            registry: await Self.codeModeRegistry(),
            instructions: try await Self.instructionSources(discovery: discovery)
        )
        let sid = try await Self.createSession(harness)
        try CoreSessionInstructionEntry.Service(db: harness.db).put(sessionID: sid, key: "rules", value: .string("Entry rule"))

        let selection = try await context.select(sid)
        #expect(selection.instructions.map(\.key) == Self.baselineOrder)

        try await CoreSessionInstructionState.prepare(db: harness.db, bus: harness.bus, sources: selection.instructions, sessionID: sid)
        let loaded = try await context.load(selection)
        #expect(loaded.initial.map(\.key) == Self.baselineOrder)
        let texts = loaded.initial.map(\.text)
        #expect(texts[0].contains("## Code Mode tools (call only inside `execute`)"))
        #expect(texts[2].contains("<available_references>"))
        #expect(texts[3].contains("<id>tidy</id>"))
        #expect(texts[5] == "Instructions from: /workspace/AGENTS.md\nProject rule v1")
        #expect(texts[6] == "Today's date: Fri Nov 20 2026")
        #expect(texts[7].contains("Working directory: /workspace/ctx"))
        #expect(texts[8] == "<context key=\"rules\">\nEntry rule\n</context>")

        // The baseline lands in the system prompt after the agent prompt, in the same order.
        let transcript = CoreSessionModelRequest.baseTranscript(
            agent: loaded.agent,
            model: loaded.model,
            tools: loaded.tools,
            initial: loaded.initial,
            messages: loaded.messages
        )
        let system = transcript.system.map(\.text).joined(separator: "\n\n")
        let anchors = ["# Code Mode", "<mcp_instructions>", "<available_references>", "<available_skills>",
                       "Other machines are available", "Instructions from:", "Today's date:", "<env>", "<context key="]
        let positions = anchors.compactMap { system.range(of: $0)?.lowerBound }
        #expect(positions.count == anchors.count)
        #expect(positions == positions.sorted())
    }

    @Test("combine keeps list order and rejects a key two sources share")
    func combineRejectsDuplicates() throws {
        let combined = try CoreSessionContext.combine(
            codeMode: Self.keyed("core/codemode", "a"),
            mcp: Self.keyed("core/mcp-guidance", "b"),
            references: [],
            skills: Self.keyed("core/skill-guidance", "c"),
            machines: [],
            discovery: Self.keyed("core/instructions", "d"),
            builtins: Self.keyed("core/date", "e"),
            entries: Self.keyed("api/x", "f")
        )
        #expect(combined.map(\.key.rawValue) == ["core/codemode", "core/mcp-guidance", "core/skill-guidance", "core/instructions", "core/date", "api/x"])
        #expect(throws: Instructions.DuplicateKeyError.self) {
            _ = try CoreSessionContext.combine(
                codeMode: Self.keyed("core/codemode", "a"),
                mcp: [],
                references: [],
                skills: [],
                machines: [],
                discovery: [],
                builtins: [],
                entries: Self.keyed("core/codemode", "again")
            )
        }
    }

    @Test("Code Mode catalog instructions appear when execute is offered and are absent when it is denied")
    func codeModeCatalog() async throws {
        let harness = try await SessionDatabaseHelper.makeHarness()
        let registry = await Self.codeModeRegistry()

        let offered = await registry.snapshot(permissions: [], options: nil)
        #expect(offered.definitions.map(\.name).contains("execute"))
        let catalog = try #require(offered.codeModeCatalog)
        #expect(CoreCodemode.Catalog.summarize(catalog).total == 1)
        let denied = await registry.snapshot(permissions: Self.executeDenied, options: nil)
        #expect(!denied.definitions.map(\.name).contains("execute"))
        #expect(denied.codeModeCatalog == nil)

        let available = Self.makeContext(harness: harness, registry: registry, instructions: CoreSessionContext.InstructionSources())
        let sidA = try await Self.createSession(harness)
        let selectedA = try await available.select(sidA)
        let codeModeA = try #require(selectedA.instructions.first { $0.key == "core/codemode" })
        let valueA = try #require(codeModeA.value)
        let rendered = codeModeA.renderInitial(valueA)
        #expect(rendered.contains("# Code Mode"))
        #expect(rendered.contains("lookup"))
        try await CoreSessionInstructionState.prepare(db: harness.db, bus: harness.bus, sources: selectedA.instructions, sessionID: sidA)
        let loadedA = try await available.load(selectedA)
        #expect(loadedA.initial.first?.key == "core/codemode")

        let restricted = Self.makeContext(
            harness: harness,
            registry: registry,
            agentPermissions: Self.executeDenied,
            instructions: CoreSessionContext.InstructionSources()
        )
        let sidB = try await Self.createSession(harness)
        let selectedB = try await restricted.select(sidB)
        let codeModeB = try #require(selectedB.instructions.first { $0.key == "core/codemode" })
        #expect(codeModeB.value == nil)
        #expect(!codeModeB.unavailable)
        try await CoreSessionInstructionState.prepare(db: harness.db, bus: harness.bus, sources: selectedB.instructions, sessionID: sidB)
        let loadedB = try await restricted.load(selectedB)
        #expect(!loadedB.initial.contains { $0.key == "core/codemode" })
        #expect(!loadedB.initial.contains { $0.text.contains("# Code Mode") })
    }

    @Test("an instruction change after the baseline becomes a durable update; the baseline is not rewritten")
    func changeBecomesUpdate() async throws {
        let harness = try await SessionDatabaseHelper.makeHarness()
        let discovery = DiscoveryFiles()
        try await discovery.start()
        await discovery.set([CoreInstruction.Discovery.File(path: "/workspace/AGENTS.md", content: "Project rule v1")])
        let context = Self.makeContext(
            harness: harness,
            registry: await Self.codeModeRegistry(),
            instructions: try await Self.instructionSources(discovery: discovery)
        )
        let sid = try await Self.createSession(harness)

        let first = try await context.select(sid)
        try await CoreSessionInstructionState.prepare(db: harness.db, bus: harness.bus, sources: first.instructions, sessionID: sid)
        let baseline = try await context.load(first).initial

        await discovery.set([CoreInstruction.Discovery.File(path: "/workspace/AGENTS.md", content: "Project rule v2")])
        try CoreSessionInstructionEntry.Service(db: harness.db).put(sessionID: sid, key: "late", value: .string("Late entry"))
        let second = try await context.select(sid)
        try await CoreSessionInstructionState.prepare(db: harness.db, bus: harness.bus, sources: second.instructions, sessionID: sid)

        // The baseline still renders what the model first saw.
        let after = try await context.load(second).initial
        #expect(after == baseline)
        #expect(after.contains { $0.text.contains("Project rule v1") })
        #expect(!after.contains { $0.text.contains("Project rule v2") })

        // The change arrives as one system update, rendered in list order: discovery before the new entry,
        // which restates its initial block because the model never saw it.
        let messages = try harness.store.messages(CoreSessionStore.MessagesInput(sessionID: sid, order: .asc))
        let updates: [String] = messages.compactMap { message in
            if case .system(let system) = message { return system.text }
            return nil
        }
        #expect(updates.count == 1)
        let update = try #require(updates.first)
        #expect(update.contains("/workspace/AGENTS.md"))
        #expect(update.contains("Project rule v2") || update.contains("+Project rule v2"))
        #expect(update.contains("<context key=\"late\">\nLate entry\n</context>"))
        #expect(!update.contains("supersedes"))
        let discoveryIndex = try #require(update.range(of: "/workspace/AGENTS.md")?.lowerBound)
        let entryIndex = try #require(update.range(of: "<context key=\"late\">")?.lowerBound)
        #expect(discoveryIndex < entryIndex)

        // Nothing changed since: the next step adds no update.
        let third = try await context.select(sid)
        try await CoreSessionInstructionState.prepare(db: harness.db, bus: harness.bus, sources: third.instructions, sessionID: sid)
        let again = try harness.store.messages(CoreSessionStore.MessagesInput(sessionID: sid, order: .asc))
        #expect(again.filter { if case .system = $0 { return true }; return false }.count == 1)
    }

    @Test("an unavailable source blocks the first baseline, then keeps its previous value")
    func unavailableSource() async throws {
        let harness = try await SessionDatabaseHelper.makeHarness()
        let discovery = DiscoveryFiles()
        try await discovery.start()
        discovery.unavailable.withLock { $0 = true }
        await discovery.service.reload()
        let context = Self.makeContext(
            harness: harness,
            registry: await Self.codeModeRegistry(),
            instructions: CoreSessionContext.InstructionSources.services(discovery: discovery.service)
        )
        let sid = try await Self.createSession(harness)
        let blocked = try await context.select(sid)
        await #expect(throws: Instructions.InitializationBlocked.self) {
            try await CoreSessionInstructionState.prepare(db: harness.db, bus: harness.bus, sources: blocked.instructions, sessionID: sid)
        }

        discovery.unavailable.withLock { $0 = false }
        await discovery.set([CoreInstruction.Discovery.File(path: "/workspace/AGENTS.md", content: "Rule")])
        let ready = try await context.select(sid)
        try await CoreSessionInstructionState.prepare(db: harness.db, bus: harness.bus, sources: ready.instructions, sessionID: sid)

        // Unavailable again after the baseline: the previous value stands and no update is emitted.
        discovery.unavailable.withLock { $0 = true }
        await discovery.service.reload()
        let later = try await context.select(sid)
        try await CoreSessionInstructionState.prepare(db: harness.db, bus: harness.bus, sources: later.instructions, sessionID: sid)
        let messages = try harness.store.messages(CoreSessionStore.MessagesInput(sessionID: sid, order: .asc))
        #expect(!messages.contains { if case .system = $0 { return true }; return false })
        #expect(try await context.load(later).initial.contains { $0.text.contains("Rule") })
    }
}
