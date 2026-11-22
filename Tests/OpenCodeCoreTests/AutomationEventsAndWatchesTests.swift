import Testing
import Synchronization
import OpenCodeAI
import OpenCodeCore
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

// NOTE: Never import Foundation or FoundationEssentials in files that `import Testing` (macOS CLT cross-import rule).

@Suite("Automation Event Triggers, Watch Reconciliation, Rewake, Leader Election & Console Watches")
struct AutomationEventsAndWatchesTests {
    // MARK: - Test Doubles

    private final class ClockBox: Sendable {
        private let value: Mutex<Int64>

        init(_ initial: Int64 = 1_700_000_000_000) {
            self.value = Mutex(initial)
        }

        func now() -> Int64 { value.withLock { $0 } }
        func advance(ms: Int64) { value.withLock { $0 += ms } }
        func set(_ ms: Int64) { value.withLock { $0 = ms } }
    }

    private final class MockEventProducer: CoreMCP.Client.Events, Sendable {
        struct OpenedStream: Sendable {
            let id: Int
            let name: String
            let arguments: [String: JSONValue]?
            let cursor: String?
        }

        private struct State: Sendable {
            var nextID = 1
            var opened: [OpenedStream] = []
            var cancelledIDs: [Int] = []
            var continuations: [Int: AsyncThrowingStream<CoreMCP.Client.EventMessage, Swift.Error>.Continuation] = [:]
            var available: Bool = true
        }

        let types: [CoreMCP.Client.EventType]
        private let state = Mutex(State())

        init(types: [CoreMCP.Client.EventType]) {
            self.types = types
        }

        var openedStreams: [OpenedStream] { state.withLock { $0.opened } }
        var cancelledIDs: [Int] { state.withLock { $0.cancelledIDs } }
        var activeStreamCount: Int { state.withLock { $0.continuations.count } }

        func setAvailable(_ flag: Bool) {
            state.withLock { $0.available = flag }
        }

        func list() async throws -> [CoreMCP.Client.EventType] {
            types
        }

        func check(name: String, arguments: [String: JSONValue]?) async throws {
            guard let match = types.first(where: { $0.name == name }), match.delivery.contains("push") else {
                throw CoreMCP.Client.EventStreamRejectedError(
                    server: "ci",
                    code: -32023,
                    message: "No push event type \(name) on MCP server ci"
                )
            }
            guard let matcher = CoreMCP.Client.compileSchemaMatcher(match.inputSchema),
                  matcher(.object(arguments ?? [:]))
            else {
                throw CoreMCP.Client.EventStreamRejectedError(
                    server: "ci",
                    code: -32602,
                    message: "Arguments for \(name) do not match its inputSchema"
                )
            }
        }

        func stream(
            name: String,
            arguments: [String: JSONValue]?,
            cursor: String?,
            maxAgeMs: Int?
        ) async throws -> AsyncThrowingStream<CoreMCP.Client.EventMessage, Swift.Error> {
            _ = maxAgeMs
            try await check(name: name, arguments: arguments)
            let isAvail = state.withLock { $0.available }
            if !isAvail {
                throw PlatformError.ioFailure("producer offline")
            }
            let payloadMatcher = types.first(where: { $0.name == name }).flatMap { CoreMCP.Client.compileSchemaMatcher($0.payloadSchema) }
            return AsyncThrowingStream { continuation in
                let streamID: Int = state.withLock { s in
                    let id = s.nextID
                    s.nextID += 1
                    s.opened.append(OpenedStream(id: id, name: name, arguments: arguments, cursor: cursor))
                    s.continuations[id] = continuation
                    return id
                }
                _ = payloadMatcher
                continuation.onTermination = { [weak self] _ in
                    self?.state.withLock { s in
                        if s.continuations.removeValue(forKey: streamID) != nil {
                            s.cancelledIDs.append(streamID)
                        }
                    }
                }
            }
        }

        func emit(_ streamID: Int, _ message: CoreMCP.Client.EventMessage) {
            if case .event(_, let evName, _, let data, _) = message,
               let match = types.first(where: { $0.name == evName }),
               let matcher = CoreMCP.Client.compileSchemaMatcher(match.payloadSchema),
               !matcher(.object(data))
            {
                // Upstream McpClient drops events whose data does not match payloadSchema.
                return
            }
            let cont = state.withLock { $0.continuations[streamID] }
            cont?.yield(message)
        }

        func close(_ streamID: Int, throwing error: (any Swift.Error)? = nil) {
            let cont = state.withLock { $0.continuations.removeValue(forKey: streamID) }
            if let error {
                cont?.finish(throwing: error)
            } else {
                cont?.finish()
            }
        }
    }

    private func waitUntil(
        timeoutMs: Int = 5_000,
        _ predicate: @Sendable () async throws -> Bool
    ) async throws {
        let stepMs = 10
        let maxSteps = max(1, timeoutMs / stepMs)
        for _ in 0..<maxSteps {
            if try await predicate() { return }
            try await Task.sleep(for: .milliseconds(stepMs))
        }
        Issue.record("Timed out after \(timeoutMs)ms waiting for condition")
    }

    private func makeDefaultAgents() async throws -> CoreAgent.Agent.Service {
        let agents = CoreAgent.Agent.Service()
        _ = try await agents.transform { editor in
            editor.update(CoreAgent.Agent.defaultID) { info in
                AgentSchema.Info(
                    id: info.id,
                    name: info.name,
                    model: info.model,
                    request: info.request,
                    system: info.system,
                    description: info.description,
                    mode: .primary,
                    hidden: false,
                    color: info.color,
                    steps: info.steps,
                    permissions: [PermissionSchema.Rule(action: "*", resource: "*", effect: .allow)]
                )
            }
            editor.update(AgentSchema.ID(rawValue: "helper")) { info in
                AgentSchema.Info(
                    id: info.id,
                    name: info.name,
                    model: info.model,
                    request: info.request,
                    system: info.system,
                    description: info.description,
                    mode: .subagent,
                    hidden: false,
                    color: info.color,
                    steps: info.steps,
                    permissions: [PermissionSchema.Rule(action: "*", resource: "*", effect: .allow)]
                )
            }
        }
        return agents
    }

    private static let buildChangedType = CoreMCP.Client.EventType(
        name: "build.changed",
        delivery: ["push"],
        inputSchema: [
            "type": .string("object"),
            "properties": .object(["build": .object(["type": .string("integer")])]),
            "required": .array([.string("build")]),
            "additionalProperties": .bool(false),
        ],
        payloadSchema: [
            "type": .string("object"),
            "properties": .object(["status": .object(["type": .string("string")])]),
            "required": .array([.string("status")]),
        ]
    )

    // MARK: - 1. Event-triggered automation fires on matching bus event and not on non-matching one

    @Test("Event-triggered automation fires on a matching bus event and ignores non-matching bus events")
    func eventTriggerMatchingAndNonMatchingBusEvent() async throws {
        let harness = try await SessionDatabaseHelper.makeHarness()
        let clock = ClockBox()
        let dir = "/repo/events-bus"
        let owner = try await harness.session.create(CoreSession.CreateInput(
            location: OpenCodeLocation(directory: dir),
            permissions: [SessionSchema.PermissionRule(action: "*", resource: "*", effect: .allow)]
        ))
        let agents = try await makeDefaultAgents()
        let permission = CorePermission.Service()
        let tools = CoreTool.Service()
        let mcp = CoreMCP.Registry.Service(directory: dir, bus: harness.bus)
        let busEvents = CoreMCP.Client.BusEvents(
            server: "ci",
            types: [Self.buildChangedType],
            bus: harness.bus,
            location: owner.location,
            initialCursor: "c0"
        )
        mcp.registerEvents(server: "ci", events: busEvents)
        let lifecycle = CoreLocation.Lifecycle.Service()

        let svc = try CoreAutomation.Service(
            database: harness.db,
            clock: { clock.now() },
            sessions: harness.session,
            execution: harness.session.execution,
            bus: harness.bus,
            resolveLocation: { _ in
                CoreAutomation.LocationContext(
                    enabled: true,
                    projectID: owner.projectID,
                    mcp: mcp,
                    lifecycle: lifecycle,
                    agents: agents,
                    permission: permission,
                    tools: tools
                )
            },
            maxSleepMs: 25
        )

        let invocation = CoreAutomation.Author.Invocation(sessionID: owner.id, agent: CoreAgent.Agent.defaultID)
        let auto = try await svc.create(
            AutomationSchema.CreateInput(
                sessionID: owner.id,
                name: "Build watcher",
                trigger: .event(.init(server: "ci", event: "build.changed", args: ["build": .int(7)])),
                action: .prompt(.init(prompt: "Review build status."))
            ),
            projectID: owner.projectID,
            directory: dir,
            invocation: invocation
        )

        let runner = Task { await svc.run() }
        defer { runner.cancel() }

        try await waitUntil { svc.activeWatchIDs.contains(auto.id) && lifecycle.isRetained() }

        // Non-matching bus events: different event name, different server, and unrelated bus event type.
        await harness.bus.emit(
            McpEventSchema.ExperimentalEvent,
            data: McpEventSchema.ExperimentalEventData(
                id: "sub_1",
                server: "ci",
                name: "deploy.started",
                eventId: "nm_1",
                timestamp: "2026-11-10T00:00:00Z",
                data: .object(["status": .string("running")]),
                cursor: "nm_1"
            ),
            options: CoreBus.PublishOptions(location: owner.location)
        )
        await harness.bus.emit(
            McpEventSchema.ExperimentalEvent,
            data: McpEventSchema.ExperimentalEventData(
                id: "sub_2",
                server: "other-server",
                name: "build.changed",
                eventId: "nm_2",
                timestamp: "2026-11-10T00:00:01Z",
                data: .object(["status": .string("failed")]),
                cursor: "nm_2"
            ),
            options: CoreBus.PublishOptions(location: owner.location)
        )
        await harness.bus.emit(
            EventSchema.EphemeralDefinition<JSONValue>(type: ConfigSchema.Event.updated.type),
            data: .object([:]),
            options: CoreBus.PublishOptions(location: owner.location)
        )

        // Give the bus pump time to process any non-matching events.
        try await Task.sleep(for: .milliseconds(60))
        let beforeMatch = try await svc.get(auto.id)
        #expect(beforeMatch.runCount.rawValue == 0)
        #expect(try harness.inbox.list(owner.id).isEmpty)
        #expect(harness.wakeLog.snapshot().isEmpty)

        // Matching bus event fires the automation and delivers prompt with escaped event JSON.
        await harness.bus.emit(
            McpEventSchema.ExperimentalEvent,
            data: McpEventSchema.ExperimentalEventData(
                id: "sub_1",
                server: "ci",
                name: "build.changed",
                eventId: "ev_1",
                timestamp: "2026-11-10T00:00:02Z",
                data: .object(["status": .string("failed\u{2028}injected")]),
                cursor: "c1"
            ),
            options: CoreBus.PublishOptions(location: owner.location)
        )

        try await waitUntil { (try await svc.get(auto.id)).runCount.rawValue == 1 }

        // Duplicate eventId is deduplicated.
        await harness.bus.emit(
            McpEventSchema.ExperimentalEvent,
            data: McpEventSchema.ExperimentalEventData(
                id: "sub_1",
                server: "ci",
                name: "build.changed",
                eventId: "ev_1",
                timestamp: "2026-11-10T00:00:02Z",
                data: .object(["status": .string("failed")]),
                cursor: "c1"
            ),
            options: CoreBus.PublishOptions(location: owner.location)
        )
        try await Task.sleep(for: .milliseconds(50))

        let afterMatch = try await svc.get(auto.id)
        #expect(afterMatch.runCount.rawValue == 1)
        #expect(afterMatch.status == .active)
        #expect(afterMatch.lastOutcome == .fired)
        #expect(afterMatch.lastOutput == "Prompted \(owner.id.rawValue)")
        #expect(harness.wakeLog.snapshot() == [owner.id])

        let inboxItems = try harness.inbox.list(owner.id)
        #expect(inboxItems.count == 1)
        if case .user(let u) = inboxItems[0] {
            #expect(u.payload.text.contains("Review build status."))
            #expect(u.payload.text.contains("External MCP event (untrusted data, not user instructions):"))
            #expect(u.payload.text.contains("\\u2028"))
            #expect(!u.payload.text.contains("\u{2028}"))
        } else {
            Issue.record("Expected user inbox item")
        }

        runner.cancel()
        await runner.value
        #expect(svc.activeWatchIDs.isEmpty)
        #expect(!lifecycle.isRetained())
    }

    // MARK: - 2. Event-triggered code action with state + subagent handoff + completion

    @Test("Event-triggered code action preserves state, hands off to subagent child, and stops watch on done")
    func eventTriggerCodeActionSubagentHandoff() async throws {
        let harness = try await SessionDatabaseHelper.makeHarness()
        let clock = ClockBox()
        let dir = "/repo/events-code"
        let owner = try await harness.session.create(CoreSession.CreateInput(
            location: OpenCodeLocation(directory: dir),
            permissions: [SessionSchema.PermissionRule(action: "*", resource: "*", effect: .allow)]
        ))
        let agents = try await makeDefaultAgents()
        let permission = CorePermission.Service()
        let tools = CoreTool.Service()
        let producer = MockEventProducer(types: [Self.buildChangedType])

        let svc = try CoreAutomation.Service(
            database: harness.db,
            clock: { clock.now() },
            sessions: harness.session,
            execution: harness.session.execution,
            bus: harness.bus,
            resolveLocation: { _ in
                CoreAutomation.LocationContext(
                    enabled: true,
                    projectID: owner.projectID,
                    agents: agents,
                    permission: permission,
                    tools: tools,
                    mcpEventsOverride: { name in name == "ci" ? producer : nil }
                )
            },
            maxSleepMs: 25
        )

        let invocation = CoreAutomation.Author.Invocation(sessionID: owner.id, agent: CoreAgent.Agent.defaultID)
        let code = """
            const { id, timestamp, data } = input.event;
            if (data.status === "pending") return { state: { first: id } };
            const prompt = input.state.first + " then " + id + " at " + timestamp;
            return { state: data.status, done: true, send: { prompt, to: { subagent: "helper" } } };
            """
        let auto = try await svc.create(
            AutomationSchema.CreateInput(
                sessionID: owner.id,
                name: "Watch build",
                trigger: .event(.init(server: "ci", event: "build.changed", args: ["build": .int(7)])),
                action: .code(.init(code: code))
            ),
            projectID: owner.projectID,
            directory: dir,
            invocation: invocation
        )

        let runner = Task { await svc.run() }
        defer { runner.cancel() }

        try await waitUntil { producer.openedStreams.count == 1 }
        let streamID = producer.openedStreams[0].id
        producer.emit(streamID, .event(
            eventId: "p1",
            name: "build.changed",
            timestamp: "2026-11-10T00:00:00Z",
            data: ["status": .string("pending")],
            cursor: "p1"
        ))
        try await waitUntil { (try await svc.get(auto.id)).runCount.rawValue == 1 }
        let afterFirst = try await svc.get(auto.id)
        #expect(afterFirst.status == .active)
        #expect(afterFirst.state == .object(["first": .string("p1")]))
        #expect(harness.wakeLog.snapshot().isEmpty)

        producer.emit(streamID, .event(
            eventId: "t2",
            name: "build.changed",
            timestamp: "2026-11-10T00:00:00Z",
            data: ["status": .string("failure")],
            cursor: "t2"
        ))
        try await waitUntil { (try await svc.get(auto.id)).status == .done && producer.cancelledIDs.contains(streamID) }

        let expectedChild = AutomationSchema.runSessionID(auto.id, run: 2)
        let finalInfo = try await svc.get(auto.id)
        #expect(finalInfo.runCount.rawValue == 2)
        #expect(finalInfo.state == .string("failure"))
        #expect(finalInfo.lastOutcome == .fired)
        #expect(finalInfo.lastOutput == "Started subagent \(expectedChild.rawValue)")
        #expect(harness.wakeLog.snapshot() == [expectedChild])

        let child = try harness.session.get(expectedChild)
        #expect(child.parentID == owner.id)
        #expect(child.agent == "helper")
        #expect(child.permissions == owner.permissions)

        let childInbox = try harness.inbox.list(expectedChild)
        #expect(childInbox.count == 1)
        if case .user(let u) = childInbox[0] {
            #expect(u.payload.text == "p1 then t2 at 2026-11-10T00:00:00Z")
        } else {
            Issue.record("Expected user inbox item on child session")
        }

        runner.cancel()
        await runner.value
    }

    // MARK: - 3. Pause, resume, delete, and server stop reconcile watches

    @Test("Pause, resume, restart and delete cancel and reacquire exactly one watch from saved cursor")
    func pauseResumeRestartDeleteReconcileWatches() async throws {
        let harness = try await SessionDatabaseHelper.makeHarness()
        let clock = ClockBox()
        let dir = "/repo/reconcile"
        let owner = try await harness.session.create(CoreSession.CreateInput(
            location: OpenCodeLocation(directory: dir),
            permissions: [SessionSchema.PermissionRule(action: "*", resource: "*", effect: .allow)]
        ))
        let agents = try await makeDefaultAgents()
        let permission = CorePermission.Service()
        let tools = CoreTool.Service()
        let producer = MockEventProducer(types: [Self.buildChangedType])

        let svc = try CoreAutomation.Service(
            database: harness.db,
            clock: { clock.now() },
            sessions: harness.session,
            execution: harness.session.execution,
            bus: harness.bus,
            resolveLocation: { _ in
                CoreAutomation.LocationContext(
                    enabled: true,
                    projectID: owner.projectID,
                    agents: agents,
                    permission: permission,
                    tools: tools,
                    mcpEventsOverride: { name in name == "ci" ? producer : nil }
                )
            },
            maxSleepMs: 25
        )

        let invocation = CoreAutomation.Author.Invocation(sessionID: owner.id, agent: CoreAgent.Agent.defaultID)
        let auto = try await svc.create(
            AutomationSchema.CreateInput(
                sessionID: owner.id,
                name: "Watch lifecycle",
                trigger: .event(.init(server: "ci", event: "build.changed", args: ["build": .int(7)])),
                action: .code(.init(code: "return { state: input.event.id }"))
            ),
            projectID: owner.projectID,
            directory: dir,
            invocation: invocation
        )

        let firstRunner = Task { await svc.run() }
        try await waitUntil { producer.openedStreams.count == 1 }
        let s1 = producer.openedStreams[0]
        #expect(s1.cursor == nil)
        #expect(svc.activeWatchIDs == [auto.id])

        producer.emit(s1.id, .event(
            eventId: "p1",
            name: "build.changed",
            timestamp: "2026-11-10T00:00:00Z",
            data: ["status": .string("pending")],
            cursor: "p1"
        ))
        try await waitUntil { (try await svc.get(auto.id)).runCount.rawValue == 1 }

        // Pause cancels the active watch immediately; late events on old stream do not run.
        let paused = try await svc.pause(auto.id)
        #expect(paused.status == .paused)
        #expect(producer.cancelledIDs.contains(s1.id))
        #expect(svc.activeWatchIDs.isEmpty)
        producer.emit(s1.id, .event(
            eventId: "paused_ev",
            name: "build.changed",
            timestamp: "2026-11-10T00:00:01Z",
            data: ["status": .string("failure")],
            cursor: "paused_ev"
        ))
        try await Task.sleep(for: .milliseconds(30))
        #expect((try await svc.get(auto.id)).runCount.rawValue == 1)

        // Resume reacquires a single stream starting from the saved cursor "p1".
        let resumed = try await svc.resume(auto.id)
        #expect(resumed.status == .active)
        try await waitUntil { producer.openedStreams.count == 2 }
        let s2 = producer.openedStreams[1]
        #expect(s2.cursor == "p1")
        #expect(svc.activeWatchIDs == [auto.id])

        // Cancelling `run()` (server stop) cancels all watches cleanly.
        firstRunner.cancel()
        await firstRunner.value
        #expect(producer.cancelledIDs.contains(s2.id))
        #expect(svc.activeWatchIDs.isEmpty)

        // Restarting `run()` reacquires the watch from cursor "p1".
        let secondRunner = Task { await svc.run() }
        defer { secondRunner.cancel() }
        try await waitUntil { producer.openedStreams.count == 3 }
        let s3 = producer.openedStreams[2]
        #expect(s3.cursor == "p1")

        // Delete cancels the active watch and removes the automation.
        try await svc.remove(auto.id)
        #expect(producer.cancelledIDs.contains(s3.id))
        #expect(svc.activeWatchIDs.isEmpty)
        #expect(try await svc.list().isEmpty)

        secondRunner.cancel()
        await secondRunner.value
    }

    @Test("Out-of-band pause in SQLite is reconciled and cancels the watch")
    func outOfBandPauseReconciled() async throws {
        let harness = try await SessionDatabaseHelper.makeHarness()
        let clock = ClockBox()
        let dir = "/repo/reconcile-oob"
        let owner = try await harness.session.create(CoreSession.CreateInput(
            location: OpenCodeLocation(directory: dir),
            permissions: [SessionSchema.PermissionRule(action: "*", resource: "*", effect: .allow)]
        ))
        let agents = try await makeDefaultAgents()
        let permission = CorePermission.Service()
        let tools = CoreTool.Service()
        let producer = MockEventProducer(types: [Self.buildChangedType])

        let svc = try CoreAutomation.Service(
            database: harness.db,
            clock: { clock.now() },
            sessions: harness.session,
            execution: harness.session.execution,
            bus: harness.bus,
            resolveLocation: { _ in
                CoreAutomation.LocationContext(
                    enabled: true,
                    projectID: owner.projectID,
                    agents: agents,
                    permission: permission,
                    tools: tools,
                    mcpEventsOverride: { name in name == "ci" ? producer : nil }
                )
            },
            maxSleepMs: 25
        )

        let invocation = CoreAutomation.Author.Invocation(sessionID: owner.id, agent: CoreAgent.Agent.defaultID)
        let auto = try await svc.create(
            AutomationSchema.CreateInput(
                sessionID: owner.id,
                name: "Watch OOB",
                trigger: .event(.init(server: "ci", event: "build.changed", args: ["build": .int(7)])),
                action: .prompt(.init(prompt: "Check"))
            ),
            projectID: owner.projectID,
            directory: dir,
            invocation: invocation
        )

        let runner = Task { await svc.run() }
        defer { runner.cancel() }
        try await waitUntil { producer.openedStreams.count == 1 }

        // Pause directly in SQLite (simulating another process).
        _ = try harness.db.execute(
            "UPDATE automation SET status = 'paused' WHERE id = ?",
            parameters: [.text(auto.id.rawValue)]
        )
        svc.wake()
        try await waitUntil { svc.activeWatchIDs.isEmpty && producer.cancelledIDs.count == 1 }

        runner.cancel()
        await runner.value
    }

    // MARK: - 4. Rewake of an in-flight code run

    @Test("Rewake wakes pending child handoff from a code run on restart and reconciles crashed admission")
    func rewakeInFlightCodeRun() async throws {
        let harness = try await SessionDatabaseHelper.makeHarness()
        let clock = ClockBox()
        let dir = "/repo/rewake-code"
        let owner = try await harness.session.create(CoreSession.CreateInput(
            location: OpenCodeLocation(directory: dir),
            permissions: [SessionSchema.PermissionRule(action: "*", resource: "*", effect: .allow)]
        ))
        let agents = try await makeDefaultAgents()
        let permission = CorePermission.Service()
        let tools = CoreTool.Service()

        let makeService: @Sendable () throws -> CoreAutomation.Service = {
            try CoreAutomation.Service(
                database: harness.db,
                clock: { clock.now() },
                sessions: harness.session,
                execution: harness.session.execution,
                bus: harness.bus,
                resolveLocation: { _ in
                    CoreAutomation.LocationContext(
                        enabled: true,
                        projectID: owner.projectID,
                        agents: agents,
                        permission: permission,
                        tools: tools
                    )
                },
                maxSleepMs: 25
            )
        }

        let svc1 = try makeService()
        let auto = try await svc1.create(
            AutomationSchema.CreateInput(
                sessionID: owner.id,
                name: "checks",
                trigger: .every(.init(every: "1 minute")),
                action: .code(.init(code: #"return { done: runs === 1, send: { prompt: "Check " + runs, to: { subagent: "helper" } } }"#))
            ),
            projectID: owner.projectID,
            directory: dir
        )

        clock.advance(ms: 60_000)
        try await svc1.tick()
        clock.advance(ms: 60_000)
        try await svc1.tick()

        let child1 = AutomationSchema.runSessionID(auto.id, run: 1)
        let child2 = AutomationSchema.runSessionID(auto.id, run: 2)
        #expect(harness.wakeLog.snapshot() == [child1, child2])
        let doneInfo = try await svc1.get(auto.id)
        #expect(doneInfo.status == .done)
        #expect(doneInfo.runCount.rawValue == 2)

        // Simulate a server restart where the wake for `child2`'s pending inbox item was lost:
        // even with 0 active automations, the new leader claims leadership once and rewakes `child2`.
        let restartedWakes = SessionDatabaseHelper.SessionIDLog()
        let restartedExec = SessionDatabaseHelper.RecordingExecution(log: restartedWakes)
        let svc2 = try CoreAutomation.Service(
            database: harness.db,
            clock: { clock.now() },
            sessions: harness.session,
            execution: restartedExec,
            bus: harness.bus,
            resolveLocation: { _ in
                CoreAutomation.LocationContext(
                    enabled: true,
                    projectID: owner.projectID,
                    agents: agents,
                    permission: permission,
                    tools: tools
                )
            },
            maxSleepMs: 25
        )
        let runner = Task { await svc2.run() }
        defer { runner.cancel() }
        try await waitUntil { restartedWakes.snapshot().contains(child2) }
        #expect(restartedWakes.snapshot() == [child2])
        runner.cancel()
        await runner.value

        // Also test reconciling an in-flight code handoff whose child + prompt were admitted before a crash
        // (automation row still at runCount 0): next tick adopts the child, wakes it, and settles runCount = 1.
        let crashedAuto = try await svc1.create(
            AutomationSchema.CreateInput(
                sessionID: owner.id,
                name: "triage",
                trigger: .every(.init(every: "1 minute")),
                action: .code(.init(code: #"return { done: true, send: { to: { subagent: "helper" }, prompt: "Triage failure" } }"#))
            ),
            projectID: owner.projectID,
            directory: dir
        )
        let crashedChild = AutomationSchema.runSessionID(crashedAuto.id, run: 1)
        let crashedMsgID = SessionMessageSchema.ID(rawValue: "msg_\(crashedAuto.id.rawValue)_1_send")!
        _ = try await harness.session.create(CoreSession.CreateInput(
            id: crashedChild,
            parentID: owner.id,
            title: "triage",
            agent: "helper"
        ))
        _ = try await harness.session.prompt(CoreSession.PromptRequest(
            sessionID: crashedChild,
            id: crashedMsgID,
            input: CoreSessionPrompt.Input(text: "Triage failure", delivery: .steer),
            resume: false
        ))

        let beforeWakes = harness.wakeLog.snapshot().count
        clock.advance(ms: 60_000)
        try await svc1.tick()
        let settled = try await svc1.get(crashedAuto.id)
        #expect(settled.status == .done)
        #expect(settled.runCount.rawValue == 1)
        #expect(harness.wakeLog.snapshot().dropFirst(beforeWakes) == [crashedChild])
        #expect(try harness.inbox.list(crashedChild).count == 1)
    }

    // MARK: - 5. Console watch re-wakes after 30 quiet minutes (with injected clock) & unattended watch

    @Test("Console watch re-wakes a held watching session after 30 quiet minutes using an injected clock, and keeps unattended watches waking")
    func consoleWatchRewakesAfter30QuietMinutesAndUnattended() async throws {
        let harness = try await SessionDatabaseHelper.makeHarness()
        let clock = ClockBox(1_700_000_000_000)
        let dir = "/repo/console-watches"
        let session = try await harness.session.create(CoreSession.CreateInput(
            location: OpenCodeLocation(directory: dir)
        ))

        struct RecordedWake: Sendable {
            let id: SessionMessageSchema.ID?
            let sessionID: SessionID
            let text: String
            let description: String?
            let resume: Bool
        }
        let wakeRecords = Mutex<[RecordedWake]>([])
        let seenIDs = Mutex<Set<SessionMessageSchema.ID>>([])
        let replayCount = Mutex(0)
        let kv = CorePlugin.InMemoryKVStore()
        let host = CorePlugin.Host.Environment(
            location: LocationSchema.Info(
                directory: SchemaPrimitive.AbsolutePath(rawValue: dir),
                project: LocationSchema.ProjectRef(
                    id: session.projectID,
                    directory: SchemaPrimitive.AbsolutePath(rawValue: dir),
                    canonical: SchemaPrimitive.AbsolutePath(rawValue: dir)
                )
            ),
            kv: kv
        )
        host.registerSession(session)

        let baseCtx = CorePlugin.Host.make(environment: host, pluginID: "opencode.provider.opencode")
        let sessionDomain = PluginEffect.SessionDomain(
            hook: baseCtx.session.hook,
            list: baseCtx.session.list,
            get: { sid in try harness.session.get(sid) },
            create: baseCtx.session.create,
            update: baseCtx.session.update,
            remove: baseCtx.session.remove,
            prompt: baseCtx.session.prompt,
            synthetic: baseCtx.session.synthetic,
            syntheticRequest: { req in
                if let id = req.id {
                    let inserted = seenIDs.withLock { $0.insert(id).inserted }
                    if !inserted {
                        replayCount.withLock { $0 += 1 }
                        throw CoreSessionErrors.SyntheticConflictError(sessionID: req.sessionID, inputID: id)
                    }
                }
                wakeRecords.withLock {
                    $0.append(RecordedWake(
                        id: req.id,
                        sessionID: req.sessionID,
                        text: req.text,
                        description: req.description,
                        resume: req.resume ?? true
                    ))
                }
            },
            compact: baseCtx.session.compact,
            interrupt: baseCtx.session.interrupt
        )
        let ctx = PluginEffect.Context(
            app: baseCtx.app,
            location: baseCtx.location,
            options: baseCtx.options,
            agent: baseCtx.agent,
            aisdk: baseCtx.aisdk,
            command: baseCtx.command,
            credential: baseCtx.credential,
            event: baseCtx.event,
            experimental: baseCtx.experimental,
            integration: baseCtx.integration,
            mcp: baseCtx.mcp,
            model: baseCtx.model,
            permission: baseCtx.permission,
            plugin: baseCtx.plugin,
            provider: baseCtx.provider,
            reference: baseCtx.reference,
            rpc: baseCtx.rpc,
            session: sessionDomain,
            shell: baseCtx.shell,
            skill: baseCtx.skill,
            storage: baseCtx.storage,
            tool: baseCtx.tool,
            vcs: baseCtx.vcs,
            websearch: baseCtx.websearch,
            worktree: baseCtx.worktree,
            addFinalizer: baseCtx.addFinalizer
        )

        let postedBodies = Mutex<[String]>([])
        let http = LayerNodePlatform.FetchTransport { request in
            if request.method == "POST", request.url.hasSuffix("/api/event-watches") {
                if let body = request.body {
                    postedBodies.withLock { $0.append(String(decoding: body, as: UTF8.self)) }
                }
                let responseJSON = #"{"id":"ew_unattended","sessionID":"\#(session.id.rawValue)","routingKey":"mcp:abc:def","mode":"sliding","expiresAt":"2026-11-20T00:00:00Z","serverSlug":"slack","eventType":"slack.mention","arguments":{}}"#
                return HTTPResponse(head: HTTPResponseHead(statusCode: 200, headers: [:]), body: Array(responseJSON.utf8))
            }
            return HTTPResponse(head: HTTPResponseHead(statusCode: 204, headers: [:]), body: [])
        }

        let controller = await CorePlugin.OpencodeWatches.make(
            ctx: ctx,
            http: http,
            clock: { clock.now() },
            startPolling: false
        )
        await controller.sync(CorePlugin.OpencodeWatches.Console(baseURL: "https://console.test", token: "tok"))

        func makeEvent(_ id: String, watchID: String = "ew_1", kind: String = "review") -> CorePlugin.OpencodeWatches.WatchEvent {
            CorePlugin.OpencodeWatches.WatchEvent(
                id: id,
                watchID: watchID,
                sessionID: session.id.rawValue,
                source: "github",
                kind: kind,
                actor: .init(login: "octocat", bot: false),
                title: "acme/app#1",
                body: "update \(id)",
                url: "https://github.com/acme/app/pull/1",
                status: "approved"
            )
        }

        // Deliver 20 updates spaced 7 minutes apart -> all 20 wake (hitting PROMPT_LIMIT = 20).
        for idx in 0..<20 {
            let acked = await controller.deliver([makeEvent("evt_\(idx)")])
            #expect(acked == ["evt_\(idx)"])
            clock.advance(ms: 7 * 60_000)
        }

        // 21st update is held (`resume: false`) and records `last` at current clock time.
        let heldEvent = makeEvent("evt_held")
        #expect(await controller.deliver([heldEvent]) == ["evt_held"])
        let afterHeld = wakeRecords.withLock { $0 }
        #expect(afterHeld.count == 21)
        #expect(afterHeld.last?.resume == false)
        #expect(afterHeld.last?.description?.contains("(further updates wait for your next prompt)") == true)

        // Replays of `evt_held` at +10m, +20m, +30m conflict, are acknowledged, and do NOT reset/extend the quiet window.
        for _ in 0..<3 {
            clock.advance(ms: 10 * 60_000)
            #expect(await controller.deliver([heldEvent]) == ["evt_held"])
        }
        #expect(replayCount.withLock { $0 } == 3)
        #expect(wakeRecords.withLock { $0.count } == 21)

        // After 30 quiet minutes since `evt_held` was first delivered, a new update wakes the held session again!
        #expect(await controller.deliver([makeEvent("evt_after_30m")]) == ["evt_after_30m"])
        let afterQuiet = wakeRecords.withLock { $0 }
        #expect(afterQuiet.count == 22)
        #expect(afterQuiet.last?.resume == true)

        // Verify a held update counts toward the 30 quiet minutes: hit the 5-in-10m window, deliver a held update
        // 15m later, and verify another update 15m after THAT (30m after original, only 15m after held) is still
        // held until 30m after the held update — wait: 10m window already expired after 15m, so test with PROMPT_LIMIT!
        // Fill back up to 20 since prompt (already at count = 1 after quiet reset -> deliver 19 more spaced 7m apart).
        for idx in 1..<20 {
            clock.advance(ms: 7 * 60_000)
            _ = await controller.deliver([makeEvent("evt_fill_\(idx)")])
        }
        clock.advance(ms: 7 * 60_000)
        _ = await controller.deliver([makeEvent("evt_hold_a")])
        #expect(wakeRecords.withLock { $0.last?.resume } == false)
        // 20 minutes later, a new held event extends `last`.
        clock.advance(ms: 20 * 60_000)
        _ = await controller.deliver([makeEvent("evt_hold_b")])
        #expect(wakeRecords.withLock { $0.last?.resume } == false)
        // 15 minutes later (35m after hold_a, only 15m after hold_b) -> STILL held!
        clock.advance(ms: 15 * 60_000)
        _ = await controller.deliver([makeEvent("evt_hold_c")])
        #expect(wakeRecords.withLock { $0.last?.resume } == false)
        // Full 30 quiet minutes after hold_c -> wakes again!
        clock.advance(ms: 30 * 60_000)
        _ = await controller.deliver([makeEvent("evt_wake_again")])
        #expect(wakeRecords.withLock { $0.last?.resume } == true)

        // Register an unattended watch via the `console_watch.watch` tool:
        let watchTool = try #require(host.registeredTools().first { $0.options?.namespace == "console_watch" && $0.name == "watch" })
        let toolCtx = ToolSchema.Context(
            sessionID: session.id,
            agent: CoreAgent.Agent.defaultID,
            messageID: "msg_tool_watch",
            id: ToolSchema.CallID(rawValue: "call_watch_1"),
            progress: { _ in }
        )
        _ = try await watchTool.execute(
            .object([
                "server": .string("slack"),
                "event": .string("slack.mention"),
                "unattended": .bool(true),
            ]),
            toolCtx
        )
        // Console never hears of `unattended`; client stores `watch-unattended:<id>`.
        #expect(postedBodies.withLock { $0.first?.contains("unattended") == false })
        #expect(try await ctx.storage.get(CorePlugin.OpencodeWatches.unattendedKey("ew_unattended")) == .bool(true))

        // Unattended watch keeps waking past 20 since prompt (25 wakes spaced 7m apart all resume)...
        let beforeUnattended = wakeRecords.withLock { $0.count }
        for idx in 0..<25 {
            clock.advance(ms: 7 * 60_000)
            _ = await controller.deliver([makeEvent("evt_u_\(idx)", watchID: "ew_unattended")])
        }
        let unattendedResumes = wakeRecords.withLock { Array($0[beforeUnattended...]).map(\.resume) }
        #expect(unattendedResumes == Array(repeating: true, count: 25))

        // ...while a non-unattended watch is still held past PROMPT_LIMIT!
        _ = await controller.deliver([makeEvent("evt_regular_held", watchID: "ew_1")])
        #expect(wakeRecords.withLock { $0.last?.resume } == false)

        // ...and an unattended watch STILL respects the 5-in-10-minute window (even for CI events)!
        clock.advance(ms: 30 * 60_000)
        let beforeBurst = wakeRecords.withLock { $0.count }
        for idx in 0..<6 {
            _ = await controller.deliver([makeEvent("evt_burst_\(idx)", watchID: "ew_unattended", kind: "workflow_run")])
        }
        let burstResumes = wakeRecords.withLock { Array($0[beforeBurst...]).map(\.resume) }
        #expect(burstResumes == [true, true, true, true, true, false])

        await controller.close()
    }

    // MARK: - 6. Only the leader runs watches

    @Test("Only the leader runs watches, and a follower takes over when the leader releases or lease expires")
    func onlyLeaderRunsWatches() async throws {
        let harness = try await SessionDatabaseHelper.makeHarness()
        let clock = ClockBox()
        let dir = "/repo/leader-watches"
        let owner = try await harness.session.create(CoreSession.CreateInput(
            location: OpenCodeLocation(directory: dir),
            permissions: [SessionSchema.PermissionRule(action: "*", resource: "*", effect: .allow)]
        ))
        let agents = try await makeDefaultAgents()
        let permission = CorePermission.Service()
        let tools = CoreTool.Service()
        let producer = MockEventProducer(types: [Self.buildChangedType])

        let makeNode: @Sendable (String) throws -> CoreAutomation.Service = { ownerID in
            try CoreAutomation.Service(
                database: harness.db,
                clock: { clock.now() },
                sessions: harness.session,
                execution: harness.session.execution,
                bus: harness.bus,
                resolveLocation: { _ in
                    CoreAutomation.LocationContext(
                        enabled: true,
                        projectID: owner.projectID,
                        agents: agents,
                        permission: permission,
                        tools: tools,
                        mcpEventsOverride: { name in name == "ci" ? producer : nil }
                    )
                },
                maxSleepMs: 25,
                leaseOwner: ownerID
            )
        }

        let leaderSvc = try makeNode("server-A")
        let followerSvc = try makeNode("server-B")

        let invocation = CoreAutomation.Author.Invocation(sessionID: owner.id, agent: CoreAgent.Agent.defaultID)
        let auto = try await leaderSvc.create(
            AutomationSchema.CreateInput(
                sessionID: owner.id,
                name: "Leader-only watch",
                trigger: .event(.init(server: "ci", event: "build.changed", args: ["build": .int(7)])),
                action: .code(.init(code: "return { state: input.event.id }"))
            ),
            projectID: owner.projectID,
            directory: dir,
            invocation: invocation
        )

        // Start leader first: it claims `automation:leader` and opens the single watch stream.
        let leaderTask = Task { await leaderSvc.run() }
        try await waitUntil { leaderSvc.activeWatchIDs == [auto.id] && producer.openedStreams.count == 1 }

        // Start follower while leader's lease is active: follower MUST NOT open a watch stream.
        let followerTask = Task { await followerSvc.run() }
        defer { followerTask.cancel() }
        try await Task.sleep(for: .milliseconds(80))
        #expect(followerSvc.activeWatchIDs.isEmpty)
        #expect(producer.openedStreams.count == 1)

        // Deliver an event through leader's stream -> commits cursor "c1".
        let s1 = producer.openedStreams[0].id
        producer.emit(s1, .event(
            eventId: "c1",
            name: "build.changed",
            timestamp: "2026-11-10T00:00:00Z",
            data: ["status": .string("pending")],
            cursor: "c1"
        ))
        try await waitUntil { (try await leaderSvc.get(auto.id)).runCount.rawValue == 1 }

        // Stop leader: it cancels its watch and releases the KV lease; follower takes over and reopens from cursor "c1".
        leaderTask.cancel()
        await leaderTask.value
        #expect(leaderSvc.activeWatchIDs.isEmpty)
        #expect(producer.cancelledIDs.contains(s1))

        followerSvc.wake()
        try await waitUntil { followerSvc.activeWatchIDs == [auto.id] && producer.openedStreams.count == 2 }
        #expect(producer.openedStreams[1].cursor == "c1")

        // Deliver second event on follower's stream -> runs once.
        let s2 = producer.openedStreams[1].id
        producer.emit(s2, .event(
            eventId: "c2",
            name: "build.changed",
            timestamp: "2026-11-10T00:00:01Z",
            data: ["status": .string("success")],
            cursor: "c2"
        ))
        try await waitUntil { (try await followerSvc.get(auto.id)).runCount.rawValue == 2 }

        followerTask.cancel()
        await followerTask.value
        #expect(followerSvc.activeWatchIDs.isEmpty)

        // Simulate a crashed leader leaving an active lease in `kv`: a third node waits while the lease is valid,
        // then takes over as leader once the clock passes the lease expiry.
        let now = clock.now()
        let leaseUntil = now + 5_000
        _ = try harness.db.execute(
            """
            INSERT INTO kv (key, value, time_created, time_updated)
            VALUES ('automation:leader', ?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value, time_updated = excluded.time_updated
            """,
            parameters: [
                .text(#"{"owner":"crashed-server","until":\#(leaseUntil)}"#),
                .integer(now),
                .integer(now),
            ]
        )
        let thirdSvc = try makeNode("server-C")
        let thirdTask = Task { await thirdSvc.run() }
        defer { thirdTask.cancel() }
        try await Task.sleep(for: .milliseconds(80))
        #expect(thirdSvc.activeWatchIDs.isEmpty)
        #expect(producer.openedStreams.count == 2)

        // Advance past the crashed leader's lease expiry -> server-C claims leadership and resumes from cursor "c2".
        clock.set(leaseUntil)
        thirdSvc.wake()
        try await waitUntil { thirdSvc.activeWatchIDs == [auto.id] && producer.openedStreams.count == 3 }
        #expect(producer.openedStreams[2].cursor == "c2")

        thirdTask.cancel()
        await thirdTask.value
        #expect(thirdSvc.activeWatchIDs.isEmpty)
    }

    // MARK: - 7. Failure & Reconnect Handling (inputSchema check, oversized event, terminated stream, continuous reopen)

    @Test("Watch validates args, drops non-matching events, pauses on oversized/terminated, and reopens continuously across disconnects")
    func watchFailureAndRetrySemantics() async throws {
        let harness = try await SessionDatabaseHelper.makeHarness()
        let clock = ClockBox()
        let dir = "/repo/watch-errors"
        let owner = try await harness.session.create(CoreSession.CreateInput(
            location: OpenCodeLocation(directory: dir),
            permissions: [SessionSchema.PermissionRule(action: "*", resource: "*", effect: .allow)]
        ))
        let agents = try await makeDefaultAgents()
        let permission = CorePermission.Service()
        let tools = CoreTool.Service()
        let producer = MockEventProducer(types: [Self.buildChangedType])

        let svc = try CoreAutomation.Service(
            database: harness.db,
            clock: { clock.now() },
            sleep: { _ in try await Task.sleep(for: .milliseconds(5)) },
            sessions: harness.session,
            execution: harness.session.execution,
            bus: harness.bus,
            resolveLocation: { _ in
                CoreAutomation.LocationContext(
                    enabled: true,
                    projectID: owner.projectID,
                    agents: agents,
                    permission: permission,
                    tools: tools,
                    mcpEventsOverride: { name in name == "ci" ? producer : nil }
                )
            },
            maxSleepMs: 15
        )
        let invocation = CoreAutomation.Author.Invocation(sessionID: owner.id, agent: CoreAgent.Agent.defaultID)

        // Validation rejects wrong inputSchema arg & excess properties before creating (via Event.check -> Events.check).
        await #expect(throws: CoreAutomation.InvalidError.self) {
            _ = try await svc.create(
                AutomationSchema.CreateInput(
                    sessionID: owner.id,
                    name: "Bad args",
                    trigger: .event(.init(server: "ci", event: "build.changed", args: ["build": .string("wrong")])),
                    action: .prompt(.init(prompt: "Check"))
                ),
                projectID: owner.projectID,
                directory: dir,
                invocation: invocation
            )
        }
        await #expect(throws: CoreAutomation.InvalidError.self) {
            _ = try await svc.create(
                AutomationSchema.CreateInput(
                    sessionID: owner.id,
                    name: "Excess args",
                    trigger: .event(.init(server: "ci", event: "build.changed", args: ["build": .int(7), "extra": .bool(true)])),
                    action: .prompt(.init(prompt: "Check"))
                ),
                projectID: owner.projectID,
                directory: dir,
                invocation: invocation
            )
        }

        let runner = Task { await svc.run() }
        defer { runner.cancel() }

        // 1) Non-matching payload is dropped without pausing; oversized event (> 16 KiB) pauses with "Oversized MCP event".
        let oversizedWatch = try await svc.create(
            AutomationSchema.CreateInput(
                sessionID: owner.id,
                name: "Oversized test",
                trigger: .event(.init(server: "ci", event: "build.changed", args: ["build": .int(7)])),
                action: .prompt(.init(prompt: "Check"))
            ),
            projectID: owner.projectID,
            directory: dir,
            invocation: invocation
        )
        try await waitUntil { producer.openedStreams.count == 1 }
        producer.emit(producer.openedStreams[0].id, .event(
            eventId: "bad_1",
            name: "build.changed",
            timestamp: "2026-11-10T00:00:00Z",
            data: ["status": .int(42)],
            cursor: "bad_1"
        ))
        try await Task.sleep(for: .milliseconds(30))
        #expect((try await svc.get(oversizedWatch.id)).status == .active)
        #expect((try await svc.get(oversizedWatch.id)).runCount.rawValue == 0)

        let hugeStatus = String(repeating: "x", count: 17_000)
        producer.emit(producer.openedStreams[0].id, .event(
            eventId: "huge_1",
            name: "build.changed",
            timestamp: "2026-11-10T00:00:00Z",
            data: ["status": .string(hugeStatus)],
            cursor: "huge_1"
        ))
        try await waitUntil { (try await svc.get(oversizedWatch.id)).status == .paused }
        let oversizedInfo = try await svc.get(oversizedWatch.id)
        #expect(oversizedInfo.lastOutcome == .failed)
        #expect(oversizedInfo.lastOutput?.contains("Oversized MCP event") == true)
        #expect(oversizedInfo.runCount.rawValue == 0)

        // 2) Continuous reopen across >3 disconnects from saved cursor, and immediate pause on terminated error.
        let resilient = try await svc.create(
            AutomationSchema.CreateInput(
                sessionID: owner.id,
                name: "Resilient test",
                trigger: .event(.init(server: "ci", event: "build.changed", args: ["build": .int(7)])),
                action: .code(.init(code: "return { state: input.event.id }"))
            ),
            projectID: owner.projectID,
            directory: dir,
            invocation: invocation
        )
        try await waitUntil { producer.openedStreams.count == 2 }
        producer.emit(producer.openedStreams[1].id, .event(
            eventId: "saved",
            name: "build.changed",
            timestamp: "2026-11-10T00:00:00Z",
            data: ["status": .string("pending")],
            cursor: "saved"
        ))
        try await waitUntil { (try await svc.get(resilient.id)).runCount.rawValue == 1 }
        producer.close(producer.openedStreams[1].id)

        // Close 4 consecutive reconnected streams without emitting any confirmed message: watch keeps reopening!
        for attempt in 1...4 {
            let expectedTotal = 2 + attempt
            try await waitUntil { producer.openedStreams.count >= expectedTotal }
            let reconnected = producer.openedStreams[expectedTotal - 1]
            #expect(reconnected.cursor == "saved")
            producer.close(reconnected.id)
        }
        try await waitUntil { producer.openedStreams.count >= 7 }
        #expect((try await svc.get(resilient.id)).status == .active)

        // Terminal server termination pauses the watch immediately without further reconnects.
        let terminatedStreamID = producer.openedStreams[6].id
        producer.close(
            terminatedStreamID,
            throwing: CoreMCP.Client.EventStreamTerminatedError(server: "ci", code: -32024, message: "revoked")
        )
        try await waitUntil { (try await svc.get(resilient.id)).status == .paused }
        let resilientInfo = try await svc.get(resilient.id)
        #expect(resilientInfo.runCount.rawValue == 1)
        #expect(resilientInfo.lastOutcome == .failed)
        #expect(resilientInfo.lastOutput == "revoked")

        runner.cancel()
        await runner.value
    }
}
