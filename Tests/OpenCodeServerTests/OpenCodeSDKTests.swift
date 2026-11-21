import Testing
import OpenCodeClient
import OpenCodeCore
import OpenCodePlatform
import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeSDK
import OpenCodeServer
import OpenCodeUtil

@Suite("OpenCodeSDK Lifecycle, Logging, OwnedFetch, Instances, Promise, Effect & Workerd Tests")
struct OpenCodeSDKTests {
    // MARK: - 1. Module, Contract Identity & Tool Re-exports

    @Test("SDK module metadata and canonical schema & driver contract identity")
    func contractIdentityAndReexports() {
        #expect(OpenCodeSDKModule.upstreamPackage == "sdk")
        #expect(OpenCodeSDKModule.serverPackage == "server")

        // Canonical schema re-exports (`packages/sdk/src/contracts.ts`)
        #expect(SDKContracts.Session.Info.self == SessionSchema.Info.self)
        #expect(SDKContracts.Agent.Info.self == AgentSchema.Info.self)
        #expect(SDKContracts.Config.Info.self == ConfigSchema.Info.self)
        #expect(SDKContracts.Event.Definition.self == EventSchema.Definition.self)
        #expect(SDKContracts.Location.Ref.self == LocationSchema.Ref.self)
        #expect(SDKContracts.Model.Ref.self == ModelSchema.Ref.self)
        #expect(SDKContracts.Workspace.DestroyResult.self == WorkspaceSchema.DestroyResult.self)
        #expect(SDKContracts.Worktree.Info.self == WorktreeSchema.Info.self)
        #expect(SDKContracts.WebSearch.Provider.self == WebSearchSchema.Provider.self)
        #expect(SDKContracts.AbsolutePath.self == SchemaPrimitive.AbsolutePath.self)
        #expect(SDKContracts.RelativePath.self == SchemaPrimitive.RelativePath.self)

        // Tool & Effect driver re-exports (`tool.ts`, `effect/tool.ts`, `effect/index.ts`)
        #expect(SDKTool.RegistrationError.self == CoreTool.RegistrationError.self)
        #expect(SDKTool.Error.self == ToolSchema.ToolError.self)
        #expect(SDKTool.Context.self == PluginPromise.ToolContext.self)
        #expect(SDKEffectTool.RegistrationError.self == CoreTool.RegistrationError.self)
        #expect(SDKEffectTool.Context.self == ToolSchema.Context.self)
        #expect(EffectSDK.WorkspaceDriver.self == CoreProject.Workspace.Driver.self)
        #expect(EffectSDK.EnvironmentDriver.self == CoreLocation.Environment.Driver.self)
        #expect(EffectSDK.EnvironmentFiles.self == CoreLocation.Environment.Files.self)
        #expect(EffectSDK.ClientError.self == EffectClient.ClientError.self)
        #expect(EffectSDK.OpenCodeEvent.self == OpenCodeProtocol.OpenCodeEvent.self)
        #expect(SDKClientError.self == ClientError.self)
    }

    // MARK: - 2. Scoped Logging (`packages/sdk/src/logging.ts`)

    @Test("SDKLogging maps all Effect log levels, filters by minimum level, merges attributes/spans/causes, and isolates errors")
    func loggingLevelsFormattingAndErrorContainment() async throws {
        // 1. All 6 levels mapped when minimum level is trace
        let entries = SDKTestHelper.Recorder<SDKLogging.LogEntry>()
        let scope = LayerNode.ResourceScope()
        let output = try await SDKLogging.layer(
            SDKLogging.LogOptions(level: .trace) { entry in
                entries.append(entry)
            }
        ).build(LayerNode.Output(), scope)

        let logger = try #require(output.get(SDKLogging.currentLoggersKey, as: SDKLogging.LoggerService.self))
        for name in ["Trace", "Debug", "Info", "Warn", "Error", "Fatal"] {
            logger.log(effectLevelName: name, message: name.lowercased())
        }
        #expect(entries.snapshot().map(\.level) == [.trace, .debug, .info, .warn, .error, .fatal])
        #expect(entries.snapshot().map(\.message) == ["trace", "debug", "info", "warn", "error", "fatal"])
        #expect(entries.snapshot().allSatisfy { $0.attributes == nil && $0.cause == nil })

        // 2. Default minimum level is .info and structured detail/cause/spans merge properly
        let structured = SDKTestHelper.Recorder<SDKLogging.LogEntry>()
        let defaultOutput = try await SDKLogging.layer(
            SDKLogging.LogOptions { entry in
                structured.append(entry)
            }
        ).build(LayerNode.Output(), scope)
        let defaultLogger = try #require(defaultOutput.get(SDKLogging.currentLoggersKey, as: SDKLogging.LoggerService.self))
        #expect(defaultOutput.get(SDKLogging.minimumLogLevelKey, as: SDKLogging.LogLevel.self) == .info)

        defaultLogger.debug("ignored")
        defaultLogger.log(
            level: .warn,
            values: [
                .string("slow query"),
                .object(["sql": .string("SELECT 1"), "cause": .string("timeout")]),
            ],
            annotations: ["component": .string("db")],
            spans: ["query": 42]
        )
        defaultLogger.log(
            level: .error,
            values: [.int(503), .string("upstream")],
            cause: .string("explicit")
        )

        let captured = structured.snapshot()
        #expect(captured.count == 2)
        #expect(captured[0].level == .warn)
        #expect(captured[0].message == "slow query")
        #expect(captured[0].cause == .string("timeout"))
        #expect(captured[0].attributes?["component"] == .string("db"))
        #expect(captured[0].attributes?["sql"] == .string("SELECT 1"))
        #expect(captured[0].attributes?["spans"] == .object(["query": .int(42)]))
        #expect(captured[0].attributes?["cause"] == nil)

        #expect(captured[1].level == .error)
        #expect(captured[1].message == "503")
        #expect(captured[1].attributes?["data"] == .string("upstream"))
        #expect(captured[1].cause == .string("explicit"))

        // 3. Silent by default when log == nil
        let silentOutput = try await SDKLogging.layer(nil).build(LayerNode.Output(), scope)
        let silentLogger = try #require(silentOutput.get(SDKLogging.currentLoggersKey, as: SDKLogging.LoggerService.self))
        silentLogger.fatal("should stay silent")

        // 4. Context extracts ONLY logger and minimum level
        let enriched = output.merging(LayerNode.Output(["extra": "value"]))
        let extracted = SDKLogging.context(enriched)
        #expect(extracted.get(SDKLogging.currentLoggersKey, as: SDKLogging.LoggerService.self) != nil)
        #expect(extracted.get(SDKLogging.minimumLogLevelKey, as: SDKLogging.LogLevel.self) == .trace)
        #expect(extracted.get("extra", as: String.self) == nil)

        // 5. Throwing writer never breaks OpenCode operations
        let throwingLogger = SDKLogging.LoggerService(
            options: SDKLogging.LogOptions(level: .trace, catchingEmit: { _ in
                throw SDKTestHelper.TestFailure("writer crashed")
            })
        )
        throwingLogger.error("must not crash")
        await scope.close()
    }

    // MARK: - 3. OwnedFetch Transport, Retention, Cancellation & Ordered Shutdown

    @Test("OwnedFetch releases completed and failed requests immediately without retaining caller signals")
    func ownedFetchReleasesCompletedAndFailedRequests() async throws {
        let caller = AbortController()
        let transport = OwnedFetch.make(
            bufferedHandler: { request, _ in
                if request.url.contains("/fail") {
                    throw SDKTestHelper.TestFailure("handler failed")
                }
                return HTTPResponse(head: HTTPResponseHead(statusCode: 200), body: Array("ok".utf8))
            },
            dispose: {}
        )

        for i in 0..<50 {
            let res = try await transport.fetch(
                HTTPRequest(method: "GET", url: "http://opencode.local/ok/\(i)"),
                signal: caller.signal
            )
            #expect(res.head.statusCode == 200)
        }
        #expect(transport.activeRequestCount == 0)

        for i in 0..<50 {
            do {
                _ = try await transport.fetch(
                    HTTPRequest(method: "GET", url: "http://opencode.local/fail/\(i)"),
                    signal: caller.signal
                )
                Issue.record("Expected failure")
            } catch let err as SDKTestHelper.TestFailure {
                #expect(err.message == "handler failed")
            }
        }

        let drained = await SDKTestHelper.waitUntil { transport.activeRequestCount == 0 }
        #expect(drained)
        #expect(!caller.signal.isAborted)
        await transport.close()
    }

    @Test("OwnedFetch wires caller abort and host close to in-flight requests and drains before dispose")
    func ownedFetchAbortAndShutdownOrder() async throws {
        let seen = SDKTestHelper.Recorder<String>()
        let disposed = SDKTestHelper.Recorder<Bool>()
        let firstStarted = SDKTestHelper.AsyncGate<Void>()
        let secondStarted = SDKTestHelper.AsyncGate<Void>()

        let transport = OwnedFetch.make(
            bufferedHandler: { request, signal in
                let gate = SDKTestHelper.AsyncGate<Void>()
                _ = signal.onAbort {
                    seen.append(signal.reason.map { String(describing: $0) } ?? "none")
                    gate.resolve(())
                }
                if request.url.hasSuffix("/first") {
                    firstStarted.resolve(())
                } else {
                    secondStarted.resolve(())
                }
                await gate.wait()
                return HTTPResponse(head: HTTPResponseHead(statusCode: 200), body: Array("aborted".utf8))
            },
            dispose: {
                disposed.append(true)
            }
        )

        // 1. Caller abort
        let caller = AbortController()
        let firstTask = Task<HTTPResponse, any Error> {
            try await transport.fetch(HTTPRequest(method: "GET", url: "http://opencode.local/first"), signal: caller.signal)
        }
        await firstStarted.wait()
        caller.abort(reason: SDKTestHelper.TestFailure("caller"))
        do {
            _ = try await firstTask.value
            Issue.record("Expected caller abort")
        } catch let err as SDKTestHelper.TestFailure {
            #expect(err.message == "caller")
        }

        // 2. Host close aborts in-flight request and waits for handler to finish BEFORE dispose
        let secondTask = Task<HTTPResponse, any Error> {
            try await transport.fetch(HTTPRequest(method: "GET", url: "http://opencode.local/second"))
        }
        await secondStarted.wait()
        let closeTask = Task { await transport.close() }
        do {
            _ = try await secondTask.value
            Issue.record("Expected ClosedError")
        } catch let err as OwnedFetch.ClosedError {
            #expect(err.message == "OpenCode host is closed")
        }
        await closeTask.value
        // Idempotent close never invokes dispose twice
        await transport.close()

        #expect(disposed.snapshot() == [true])
        #expect(seen.snapshot() == ["caller", "OpenCode host is closed"])

        // 3. Subsequent requests reject immediately
        do {
            _ = try await transport.fetch(HTTPRequest(method: "GET", url: "http://opencode.local/after"))
            Issue.record("Expected ClosedError after close")
        } catch let err as OwnedFetch.ClosedError {
            #expect(err.message == "OpenCode host is closed")
        }
    }

    @Test("OwnedFetch cancels open streaming response body on host shutdown before calling dispose")
    func ownedFetchCancelsOpenStreamBeforeDispose() async throws {
        let events = SDKTestHelper.Recorder<String>()
        let transport = OwnedFetch.make(
            handler: { _, _ in
                let stream = AsyncThrowingStream<[UInt8], Error> { continuation in
                    continuation.onTermination = { _ in
                        events.append("stream-cancelled")
                    }
                }
                return .streaming(
                    HTTPStreamingResponse(
                        head: HTTPResponseHead(statusCode: 200, headers: ["content-type": "text/event-stream"]),
                        chunks: stream
                    )
                )
            },
            dispose: {
                events.append("disposed")
            }
        )

        let response = try await transport.fetchStream(HTTPRequest(method: "GET", url: "http://opencode.local/stream"))
        #expect(transport.activeRequestCount == 1)

        let readTask = Task<[UInt8]?, any Error> {
            var iterator = response.chunks.makeAsyncIterator()
            return try await iterator.next()
        }
        try? await Task.sleep(nanoseconds: 20_000_000)

        await transport.close()
        do {
            _ = try await readTask.value
            Issue.record("Expected ClosedError from open stream read")
        } catch let err as OwnedFetch.ClosedError {
            #expect(err.message == "OpenCode host is closed")
        }

        #expect(transport.activeRequestCount == 0)
        #expect(events.snapshot() == ["stream-cancelled", "disposed"])
    }

    // MARK: - 4. Promise SDK End-to-End Router, Streams & Isolation (`promise.test.ts`, `embedded.test.ts`)

    @Test("Promise SDK (OpenCode.create & createOpencode) runs full session flow over embedded router")
    func promiseHostEmbeddedRouter() async throws {
        let dir = try SDKTestHelper.makeTempDirectory(prefix: "opencode-promise-sdk")
        defer { SDKTestHelper.removeDirectory(dir) }

        let opencode = try await createOpencode(
            OpenCode.CreateOptions(
                app: .init(version: "promise-test-1.0"),
                events: .init(persist: true),
                config: .init(directory: dir, project: false, content: "{}")
            )
        )

        do {
            let info = try await opencode.server.info()
            #expect(info.version == "promise-test-1.0")
            #expect(info.urls.isEmpty)

            let created = try await opencode.sessions.create(
                SessionCreateInput(
                    location: LocationSchema.PublicRef(directory: SchemaPrimitive.AbsolutePath(rawValue: dir))
                )
            )
            let selected = try await opencode.sessions.get(SessionGetInput(sessionID: created.id.rawValue))
            let page = try await opencode.sessions.list(SessionListInput(directory: dir))
            #expect(selected.id == created.id)
            #expect(page.data.contains { $0.id == created.id })

            try await opencode.sessions.switchModel(
                SessionSwitchModelInput(
                    sessionID: created.id.rawValue,
                    model: ModelSchema.Ref(
                        id: ModelSchema.ID(rawValue: "embedded"),
                        providerID: ProviderSchema.ID(rawValue: "test")
                    )
                )
            )
            let updated = try await opencode.sessions.get(SessionGetInput(sessionID: created.id.rawValue))
            #expect(updated.model?.id == "embedded")
            #expect(updated.model?.providerID == "test")

            let admitted = try await opencode.sessions.prompt(
                SessionPromptInput(sessionID: created.id.rawValue, text: "Do not run", resume: false)
            )
            #expect(admitted.sessionID == created.id)
            #expect(admitted.payload.text == "Do not run")

            let pending = try await opencode.sessions.inbox.list(SessionInboxListInput(sessionID: created.id.rawValue))
            #expect(pending.count == 1)

            try await opencode.experimental.session.instructions.entry.put(
                ExperimentalSessionInstructionsEntryPutInput(
                    sessionID: created.id.rawValue,
                    key: "deploy-target",
                    value: .string("production")
                )
            )
            let entries = try await opencode.experimental.session.instructions.entry.list(
                ExperimentalSessionInstructionsEntryListInput(sessionID: created.id.rawValue)
            )
            let expectedKey = try #require(InstructionEntrySchema.Key(rawValue: "deploy-target"))
            #expect(entries == [InstructionEntrySchema.Info(key: expectedKey, value: .string("production"))])
            try await opencode.experimental.session.instructions.entry.remove(
                ExperimentalSessionInstructionsEntryRemoveInput(sessionID: created.id.rawValue, key: "deploy-target")
            )
            let remaining = try await opencode.experimental.session.instructions.entry.list(
                ExperimentalSessionInstructionsEntryListInput(sessionID: created.id.rawValue)
            )
            #expect(remaining.isEmpty)

            // Durable session log contains session.created & session.model.selected
            var logTypes: [String] = []
            for try await item in opencode.experimental.session.log(
                ExperimentalSessionLogInput(sessionID: created.id.rawValue)
            ) {
                if case .event(let event) = item {
                    logTypes.append(event.type)
                }
            }
            #expect(logTypes.contains("session.created"))
            #expect(logTypes.contains("session.model.selected"))

            // Missing session decodes SessionNotFoundError
            let missingID = SessionID.create()
            do {
                _ = try await opencode.sessions.get(SessionGetInput(sessionID: missingID.rawValue))
                Issue.record("Expected SessionNotFoundError")
            } catch {
                #expect(isSessionNotFoundError(error))
            }
        } catch {
            await opencode.close()
            throw error
        }

        // Idempotent close & asyncDispose
        await opencode.close()
        await opencode.asyncDispose()
    }

    @Test("Promise event streams emit server.connected, support caller abort, and fail with Transport error on host close")
    func promiseEventStreamsCancellationAndClose() async throws {
        // 1. Caller cancellation ends stream cleanly
        let first = try await OpenCode.create()
        try await first.withClose { opencode in
            let controller = AbortController()
            let stream = opencode.events.subscribe(SubscribeOptions(signal: controller.signal))
            var iterator = stream.makeAsyncIterator()
            let connected = try await iterator.next()
            #expect(connected?.type == "server.connected")

            let pending = Task<OpenCodeEvent?, any Error> {
                try await iterator.next()
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
            controller.abort()
            let ended = try await pending.value
            #expect(ended == nil)
        }

        // 2. Host close terminates active subscribers with ClientError(reason: .transport)
        let second = try await OpenCode.create()
        let stream = second.events.subscribe()
        var iterator = stream.makeAsyncIterator()
        let connected = try await iterator.next()
        #expect(connected?.type == "server.connected")

        let pending = Task<OpenCodeEvent?, any Error> {
            try await iterator.next()
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        await second.close()

        do {
            _ = try await pending.value
            Issue.record("Expected ClientError(reason: .transport) on host close")
        } catch let err as ClientError {
            #expect(err.reason == .transport)
        }
    }

    @Test("Independent embedded hosts isolate live event streams from one another")
    func independentHostsIsolateLiveEvents() async throws {
        let first = try await OpenCode.create()
        let second = try await OpenCode.create()
        defer {
            Task {
                await first.close()
                await second.close()
            }
        }

        let firstReady = SDKTestHelper.AsyncGate<Void>()
        let secondReady = SDKTestHelper.AsyncGate<Void>()
        let firstEvents = SDKTestHelper.Recorder<String>()
        let secondEvents = SDKTestHelper.Recorder<String>()

        let sessionID = SessionID.create()
        let sub1 = Task {
            for try await event in first.events.subscribe() {
                if event.type == "server.connected" {
                    firstReady.resolve(())
                } else if event.type == "session.agent.selected" {
                    firstEvents.append(event.type)
                    break
                }
            }
        }
        let sub2 = Task {
            for try await event in second.events.subscribe() {
                if event.type == "server.connected" {
                    secondReady.resolve(())
                } else if event.type == "session.agent.selected" {
                    secondEvents.append(event.type)
                    break
                }
            }
        }

        await firstReady.wait()
        await secondReady.wait()

        _ = try await first.sessions.create(SessionCreateInput(id: sessionID.rawValue))
        try await first.sessions.switchAgent(SessionSwitchAgentInput(sessionID: sessionID.rawValue, agent: "plan"))

        let sawFirst = await SDKTestHelper.waitUntil { !firstEvents.snapshot().isEmpty }
        #expect(sawFirst)
        try? await Task.sleep(nanoseconds: 60_000_000)
        #expect(secondEvents.snapshot().isEmpty)

        sub1.cancel()
        sub2.cancel()
        await first.close()
        await second.close()
    }

    // MARK: - 5. Non-Blocking Plugin Loading & Cleanup Invariant

    @Test("Slow host plugin activation never blocks HTTP handlers, activates asynchronously, and cleans up on close")
    func nonBlockingPluginLoadingAndCleanup() async throws {
        let releasePlugin = SDKTestHelper.AsyncGate<Void>()
        let startedPlugin = SDKTestHelper.AsyncGate<Void>()
        let cleanups = SDKTestHelper.Recorder<String>()

        let slowPlugin = PluginPromise.define(
            PluginPromise.Plugin(id: "slow-host-plugin") { _ in
                startedPlugin.resolve(())
                await releasePlugin.wait()
                return {
                    cleanups.append("slow-host-plugin")
                }
            }
        )

        let opencode = try await OpenCode.create(
            OpenCode.CreateOptions(
                app: .init(version: "plugin-nonblock"),
                plugins: [slowPlugin]
            )
        )

        await startedPlugin.wait()

        // CRITICAL INVARIANT: server/plugin handlers MUST NOT block waiting for slow plugin activation!
        let info = try await opencode.server.info()
        #expect(info.version == "plugin-nonblock")
        let coldList = try await opencode.plugin.list()
        #expect(coldList.data.isEmpty)

        // Allow plugin activation to complete and verify inventory updates
        releasePlugin.resolve(())
        await opencode.host.defaultPluginService.awaitActivation()

        let warmList = try await opencode.plugin.list()
        #expect(warmList.data.contains { $0.id?.rawValue == "slow-host-plugin" && $0.state == .active })

        // Dynamic registration via callable `opencode.plugin(...)`
        let dynamicCleanups = SDKTestHelper.Recorder<String>()
        await opencode.plugin(
            PluginPromise.Plugin(id: "dynamic-plugin") { _ in
                return { dynamicCleanups.append("dynamic-plugin") }
            }
        )
        await opencode.host.defaultPluginService.awaitActivation()
        let afterDynamic = try await opencode.plugin.list()
        #expect(afterDynamic.data.contains { $0.id?.rawValue == "dynamic-plugin" && $0.state == .active })

        // Closing tears down both plugins cleanly
        await opencode.close()
        #expect(cleanups.snapshot() == ["slow-host-plugin"])
        #expect(dynamicCleanups.snapshot() == ["dynamic-plugin"])
    }

    @Test("A throwing fork hook still returns the saved fork")
    func throwingForkHookStillReturnsFork() async throws {
        let seen = SDKTestHelper.Recorder<String>()
        let opencode = try await OpenCode.create(
            OpenCode.CreateOptions(
                plugins: [
                    PluginPromise.Plugin(id: "broken-fork-hook") { ctx in
                        _ = await ctx.session.hook("fork", { event in
                            if case .fork(let sid) = event {
                                seen.append(sid.rawValue)
                            }
                            throw SDKTestHelper.TestFailure("fork hook failed")
                        }, nil)
                        return nil
                    },
                ]
            )
        )
        await opencode.host.defaultPluginService.awaitActivation()

        let parent = try await opencode.sessions.create()
        try await opencode.sessions.switchAgent(SessionSwitchAgentInput(sessionID: parent.id.rawValue, agent: "plan"))
        let fork = try await opencode.sessions.fork(SessionForkInput(sessionID: parent.id.rawValue))
        #expect(seen.snapshot() == [fork.id.rawValue])
        let fetched = try await opencode.sessions.get(SessionGetInput(sessionID: fork.id.rawValue))
        #expect(fetched.id == fork.id)
        #expect(fetched.fork?.sessionID == parent.id)
        await opencode.close()
    }

    // MARK: - 6. Session-Selected Instances (`instances.test.ts`, `instances-lifecycle.test.ts`)

    @Test("Promise instances are lazy, share by key and canonical Location, isolate across hosts, and clean up on close")
    func promiseInstancesLazySharingAndIsolation() async throws {
        let dir = try SDKTestHelper.makeTempDirectory(prefix: "opencode-instances")
        let otherDir = try SDKTestHelper.makeSubdirectory(dir, name: "other")
        defer { SDKTestHelper.removeDirectory(dir) }

        let configured = SDKTestHelper.Recorder<String>()
        let setups = SDKTestHelper.Recorder<String>()
        let cleanups = SDKTestHelper.Recorder<String>()

        func makeHost(_ name: String) async throws -> OpenCode.Interface {
            try await OpenCode.create(
                OpenCode.CreateOptions(
                    database: .init(path: SDKTestHelper.joinPath(dir, "\(name).sqlite")),
                    models: .init(fetch: false),
                    config: .init(directory: dir, project: false, content: "{}"),
                    fs: .init(filewatcher: false),
                    instances: OpenCode.InstanceOptions(
                        key: { session in
                            guard case .string(let account) = session.metadata?["account"] else {
                                throw SDKTestHelper.TestFailure("Missing account metadata")
                            }
                            return account
                        },
                        configure: { key in
                            configured.append("\(name):\(key)")
                            return OpenCode.InstanceConfiguration(
                                plugins: [
                                    PluginPromise.Plugin(id: "account-prompts") { ctx in
                                        let activation = "\(name):\(key)@\(ctx.location.directory.rawValue)"
                                        setups.append(activation)
                                        _ = await ctx.session.hook("prompt", { event in
                                            guard case .prompt(var p) = event else { return event }
                                            p.prompt = PromptInputSchema.Prompt(
                                                text: "\(activation): \(p.prompt.text)",
                                                files: p.prompt.files,
                                                agents: p.prompt.agents,
                                                skills: p.prompt.skills
                                            )
                                            return .prompt(p)
                                        }, nil)
                                        return {
                                            cleanups.append(activation)
                                        }
                                    },
                                ]
                            )
                        }
                    )
                )
            )
        }

        let first = try await makeHost("first")
        let second = try await makeHost("second")

        let sharedID = SessionID.create()
        let original = try await first.sessions.create(
            SessionCreateInput(
                id: sharedID.rawValue,
                location: LocationSchema.PublicRef(directory: SchemaPrimitive.AbsolutePath(rawValue: dir)),
                metadata: ["account": .string("alpha")]
            )
        )
        let sameKey = try await first.sessions.create(
            SessionCreateInput(
                location: LocationSchema.PublicRef(directory: SchemaPrimitive.AbsolutePath(rawValue: dir)),
                metadata: ["account": .string("alpha")]
            )
        )
        let separateKey = try await first.sessions.create(
            SessionCreateInput(
                location: LocationSchema.PublicRef(directory: SchemaPrimitive.AbsolutePath(rawValue: dir)),
                metadata: ["account": .string("beta")]
            )
        )
        let separateLoc = try await first.sessions.create(
            SessionCreateInput(
                location: LocationSchema.PublicRef(directory: SchemaPrimitive.AbsolutePath(rawValue: otherDir)),
                metadata: ["account": .string("alpha")]
            )
        )
        let separateHost = try await second.sessions.create(
            SessionCreateInput(
                id: sharedID.rawValue,
                location: LocationSchema.PublicRef(directory: SchemaPrimitive.AbsolutePath(rawValue: dir)),
                metadata: ["account": .string("alpha")]
            )
        )

        // Reads do NOT initialize instances
        #expect(try await first.sessions.get(SessionGetInput(sessionID: sharedID.rawValue)) == original)
        #expect(try await first.sessions.list().data.count == 4)
        #expect(try await first.message.list(MessageListInput(sessionID: sharedID.rawValue)).data.isEmpty)
        #expect(try await first.sessions.context(SessionContextInput(sessionID: sharedID.rawValue)).isEmpty)
        #expect(try await first.sessions.inbox.list(SessionInboxListInput(sessionID: sharedID.rawValue)).isEmpty)
        #expect(try await second.sessions.get(SessionGetInput(sessionID: sharedID.rawValue)) == separateHost)
        #expect(configured.snapshot().isEmpty)
        #expect(setups.snapshot().isEmpty)

        // Permission and form lists DO acquire the session's instance
        #expect(try await first.permission.list(PermissionListInput(sessionID: sharedID.rawValue)).isEmpty)
        #expect(try await first.session.form.list(SessionFormListInput(sessionID: sharedID.rawValue)).isEmpty)
        #expect(configured.snapshot() == ["first:alpha"])

        // Prompts route through the matching shared/isolated instances
        let p1 = try await first.sessions.prompt(SessionPromptInput(sessionID: original.id.rawValue, text: "Review", resume: false))
        let p2 = try await first.sessions.prompt(SessionPromptInput(sessionID: sameKey.id.rawValue, text: "Review", resume: false))
        let p3 = try await first.sessions.prompt(SessionPromptInput(sessionID: separateKey.id.rawValue, text: "Review", resume: false))
        let p4 = try await first.sessions.prompt(SessionPromptInput(sessionID: separateLoc.id.rawValue, text: "Review", resume: false))
        let p5 = try await second.sessions.prompt(SessionPromptInput(sessionID: separateHost.id.rawValue, text: "Review", resume: false))

        #expect(p1.payload.text == "first:alpha@\(dir): Review")
        #expect(p2.payload.text == "first:alpha@\(dir): Review")
        #expect(p3.payload.text == "first:beta@\(dir): Review")
        #expect(p4.payload.text == "first:alpha@\(otherDir): Review")
        #expect(p5.payload.text == "second:alpha@\(dir): Review")

        #expect(configured.snapshot().sorted() == ["first:alpha", "first:alpha", "first:beta", "second:alpha"])
        #expect(cleanups.snapshot().isEmpty)

        await first.close()
        let firstCleanups = cleanups.snapshot().sorted()
        #expect(firstCleanups == setups.snapshot().filter { $0.hasPrefix("first:") }.sorted())

        // Second host remains unaffected
        let p6 = try await second.sessions.prompt(SessionPromptInput(sessionID: sharedID.rawValue, text: "Keep going", resume: false))
        #expect(p6.payload.text == "second:alpha@\(dir): Keep going")
        await second.close()
        #expect(cleanups.snapshot().sorted() == setups.snapshot().sorted())
    }

    @Test("Instance configuration failure, plugin setup failure, and host plugin ID collision reject admission and retry cleanly")
    func instanceFailuresCollisionsAndRetry() async throws {
        // Case A: configuration & plugin setup failures
        for mode in ["configuration", "plugin-setup"] {
            let configured = SDKTestHelper.Recorder<String>()
            let setups = SDKTestHelper.Recorder<String>()
            let cleanups = SDKTestHelper.Recorder<String>()

            let opencode = try await OpenCode.create(
                OpenCode.CreateOptions(
                    instances: OpenCode.InstanceOptions(
                        key: { session in
                            guard case .string(let account) = session.metadata?["account"] else {
                                throw SDKTestHelper.TestFailure("missing account")
                            }
                            return account
                        },
                        configure: { key in
                            configured.append(key)
                            let countForKey = configured.snapshot().filter { $0 == key }.count
                            if key == "retry", mode == "configuration", countForKey == 1 {
                                throw SDKTestHelper.TestFailure("Account configuration unavailable")
                            }
                            return OpenCode.InstanceConfiguration(
                                plugins: [
                                    PluginPromise.Plugin(id: "account-prompts") { ctx in
                                        setups.append(key)
                                        let setupCount = setups.snapshot().filter { $0 == key }.count
                                        _ = await ctx.session.hook("prompt", { event in
                                            guard case .prompt(var p) = event else { return event }
                                            p.prompt = PromptInputSchema.Prompt(text: "\(key): \(p.prompt.text)")
                                            return .prompt(p)
                                        }, nil)
                                        if key == "retry", mode == "plugin-setup", setupCount == 1 {
                                            throw SDKTestHelper.TestFailure("Account plugin unavailable")
                                        }
                                        return { cleanups.append(key) }
                                    },
                                ]
                            )
                        }
                    )
                )
            )

            let healthy = try await opencode.sessions.create(SessionCreateInput(metadata: ["account": .string("healthy")]))
            let retry = try await opencode.sessions.create(SessionCreateInput(metadata: ["account": .string("retry")]))

            let before = try await opencode.sessions.prompt(SessionPromptInput(sessionID: healthy.id.rawValue, text: "Before", resume: false))
            #expect(before.payload.text == "healthy: Before")

            let retryMsgID = SessionMessageSchema.ID.create().rawValue
            do {
                _ = try await opencode.sessions.prompt(
                    SessionPromptInput(sessionID: retry.id.rawValue, id: retryMsgID, text: "Try once", resume: false)
                )
                Issue.record("Expected failure for mode \(mode)")
            } catch let err as ClientError {
                #expect(err.reason == .unexpectedStatus)
            }
            #expect(try await opencode.sessions.inbox.list(SessionInboxListInput(sessionID: retry.id.rawValue)).isEmpty)

            // Healthy instance unaffected; retry succeeds on next attempt
            let after = try await opencode.sessions.prompt(SessionPromptInput(sessionID: healthy.id.rawValue, text: "After", resume: false))
            #expect(after.payload.text == "healthy: After")

            let admitted = try await opencode.sessions.prompt(
                SessionPromptInput(sessionID: retry.id.rawValue, id: retryMsgID, text: "Try once", resume: false)
            )
            #expect(admitted.id.rawValue == retryMsgID)
            #expect(admitted.payload.text == "retry: Try once")

            await opencode.close()
            #expect(cleanups.snapshot().sorted() == ["healthy", "retry"])
        }

        // Case B: host plugin ID collision tears down failed generation (including host plugin cleanup) and retries cleanly
        let collisionConfigured = SDKTestHelper.Recorder<String>()
        let collisionSetups = SDKTestHelper.Recorder<String>()
        let collisionCleanups = SDKTestHelper.Recorder<String>()

        let collisionHost = try await OpenCode.create(
            OpenCode.CreateOptions(
                plugins: [
                    PluginPromise.Plugin(id: "account-prompts") { _ in
                        collisionSetups.append("host")
                        return { collisionCleanups.append("host") }
                    },
                ],
                instances: OpenCode.InstanceOptions(
                    key: { session in
                        guard case .string(let account) = session.metadata?["account"] else { return "default" }
                        return account
                    },
                    configure: { key in
                        let attempt = collisionConfigured.appendAndCount(key)
                        return OpenCode.InstanceConfiguration(
                            plugins: [
                                PluginPromise.Plugin(id: attempt == 1 ? "account-prompts" : "instance-prompts") { ctx in
                                    collisionSetups.append(key)
                                    _ = await ctx.session.hook("prompt", { event in
                                        guard case .prompt(var p) = event else { return event }
                                        p.prompt = PromptInputSchema.Prompt(text: "\(key): \(p.prompt.text)")
                                        return .prompt(p)
                                    }, nil)
                                    return nil
                                },
                            ]
                        )
                    }
                )
            )
        )
        // Wait for default host plugin activation so only instance-level assertions are tracked separately
        await collisionHost.host.defaultPluginService.awaitActivation()
        let baselineHostSetups = collisionSetups.count

        let session = try await collisionHost.sessions.create(SessionCreateInput(metadata: ["account": .string("alpha")]))
        let msgID = SessionMessageSchema.ID.create().rawValue
        do {
            _ = try await collisionHost.sessions.prompt(
                SessionPromptInput(sessionID: session.id.rawValue, id: msgID, text: "Collision test", resume: false)
            )
            Issue.record("Expected collision failure")
        } catch let err as ClientError {
            #expect(err.reason == .unexpectedStatus)
        }
        #expect(collisionConfigured.snapshot() == ["alpha"])
        // Host plugin activated inside failed instance generation and then cleaned up when rejected
        #expect(collisionSetups.count == baselineHostSetups + 1)
        #expect(collisionCleanups.snapshot() == ["host"])

        let recovered = try await collisionHost.sessions.prompt(
            SessionPromptInput(sessionID: session.id.rawValue, id: msgID, text: "Collision test", resume: false)
        )
        #expect(recovered.payload.text == "alpha: Collision test")
        #expect(collisionConfigured.snapshot() == ["alpha", "alpha"])
        await collisionHost.close()
    }

    @Test("Persisted SQLite sessions reconstruct instances lazily across host restarts")
    func persistedInstancesRestartReconstruction() async throws {
        let dir = try SDKTestHelper.makeTempDirectory(prefix: "opencode-instance-restart")
        defer { SDKTestHelper.removeDirectory(dir) }

        let dbPath = SDKTestHelper.joinPath(dir, "sessions.sqlite")
        let configured = SDKTestHelper.Recorder<String>()
        let cleanups = SDKTestHelper.Recorder<Int>()

        let options = OpenCode.CreateOptions(
            database: .init(path: dbPath),
            config: .init(directory: dir, project: false, content: "{}"),
            instances: OpenCode.InstanceOptions(
                key: { session in
                    guard case .string(let account) = session.metadata?["account"] else { return "none" }
                    return account
                },
                configure: { key in
                    let generation = configured.appendAndCount(key)
                    return OpenCode.InstanceConfiguration(
                        plugins: [
                            PluginPromise.Plugin(id: "account-prompts") { ctx in
                                _ = await ctx.session.hook("prompt", { event in
                                    guard case .prompt(var p) = event else { return event }
                                    p.prompt = PromptInputSchema.Prompt(text: "\(key)/\(generation): \(p.prompt.text)")
                                    return .prompt(p)
                                }, nil)
                                return { cleanups.append(generation) }
                            },
                        ]
                    )
                }
            )
        )

        let sessionID = SessionID.create()
        let first = try await OpenCode.create(options)
        _ = try await first.sessions.create(
            SessionCreateInput(
                id: sessionID.rawValue,
                location: LocationSchema.PublicRef(directory: SchemaPrimitive.AbsolutePath(rawValue: dir)),
                metadata: ["account": .string("alpha")]
            )
        )
        let before = try await first.sessions.prompt(
            SessionPromptInput(sessionID: sessionID.rawValue, text: "Before restart", resume: false)
        )
        #expect(before.payload.text == "alpha/1: Before restart")
        await first.close()
        #expect(cleanups.snapshot() == [1])

        // Restart host against same SQLite DB
        let second = try await OpenCode.create(options)
        #expect(try await second.sessions.get(SessionGetInput(sessionID: sessionID.rawValue)).id == sessionID)
        #expect(try await second.sessions.inbox.list(SessionInboxListInput(sessionID: sessionID.rawValue)).count == 1)
        #expect(configured.snapshot() == ["alpha"]) // Reads did NOT trigger generation 2

        // Idempotent retry acquires generation 2 but returns original admission unchanged
        let retried = try await second.sessions.prompt(
            SessionPromptInput(sessionID: sessionID.rawValue, id: before.id.rawValue, text: "Already admitted", resume: false)
        )
        #expect(retried == before)
        #expect(configured.snapshot() == ["alpha", "alpha"])

        // New prompt executes generation 2 hook
        let after = try await second.sessions.prompt(
            SessionPromptInput(sessionID: sessionID.rawValue, text: "After restart", resume: false)
        )
        #expect(after.payload.text == "alpha/2: After restart")
        await second.close()
        #expect(cleanups.snapshot() == [1, 2])
    }

    @Test("Cancelled borrower cannot strand a later failed instance construction (instances-lifecycle.test.ts)")
    func cancelledBorrowerDoesNotStrandFailedConstruction() async throws {
        let started = SDKTestHelper.AsyncGate<Void>()
        let release = SDKTestHelper.AsyncGate<Void>()
        let acquired = SDKTestHelper.Recorder<Int>()
        let released = SDKTestHelper.Recorder<Int>()

        let host = try await EmbeddedHost.create(
            EmbeddedHost.CreateOptions(
                instances: SdkInstances.Options(
                    key: { _ in "shared" },
                    configure: { _, scope in
                        let attempt = acquired.appendAndCount(acquired.count + 1)
                        scope.addFinalizer {
                            released.append(attempt)
                        }
                        if attempt != 1 {
                            return SdkInstances.Configuration(plugins: [])
                        }
                        started.resolve(())
                        await release.wait()
                        throw SDKTestHelper.TestFailure("Configuration unavailable")
                    }
                )
            )
        )
        let selector = try #require(host.instances)
        let session = try await host.sessions.create(
            CoreSession.CreateInput(location: OpenCodeLocation(directory: "/workspace"))
        )
        #expect(acquired.snapshot().isEmpty)

        // Start borrower and cancel it while configure attempt 1 is suspended
        let borrower = Task {
            try await selector.provide(session: session) { _ in () }
        }
        await started.wait()
        borrower.cancel()
        do {
            try await borrower.value
            Issue.record("Expected borrower to exit with CancellationError")
        } catch is CancellationError {
            // Expected
        }
        #expect(released.snapshot().isEmpty)

        // Release attempt 1 so it fails, cleans up scope, and evicts itself
        release.resolve(())
        let cleanedUpFirst = await SDKTestHelper.waitUntil { released.snapshot() == [1] }
        #expect(cleanedUpFirst)

        // Subsequent borrower succeeds with attempt 2
        try await selector.provide(session: session) { _ in () }
        #expect(acquired.snapshot() == [1, 2])
        #expect(released.snapshot() == [1])

        await host.close()
        #expect(released.snapshot() == [1, 2])
    }

    // MARK: - 7. Effect SDK, Layer Composition, Services & Workspace Facade

    @Test("OpenCodeEffect.create and OpenCodeEffect.layer provide isolated transport, core session/workspace APIs, and service-configured instances")
    func effectSdkCreateLayerServicesAndWorkspace() async throws {
        let dir = try SDKTestHelper.makeTempDirectory(prefix: "opencode-effect-sdk")
        defer { SDKTestHelper.removeDirectory(dir) }

        let driver = SDKTestHelper.RecordingWorkspaceDriver()
        let attempts = SDKTestHelper.Recorder<String>()
        let released = SDKTestHelper.Recorder<String>()

        let personaKey = "@test/Personas"
        let personas: @Sendable (String) -> String = { threadID in "persona-for-\(threadID)" }
        let deps = LayerNode.Output([personaKey: personas])

        let layer = OpenCodeEffect.layer(
            OpenCodeEffect.CreateOptions(
                app: .init(version: "effect-test-2.0"),
                events: .init(persist: true),
                config: .init(directory: dir, project: false, content: "{}"),
                workspaceProviders: ["fake": driver],
                instances: SdkInstances.Options(
                    key: { session in
                        guard case .string(let threadID) = session.metadata?["threadID"] else { return "default" }
                        return threadID
                    },
                    configure: { key, scope, services in
                        let lookup = services.get(personaKey, as: (@Sendable (String) -> String).self)
                        let persona = lookup?(key) ?? "missing"
                        let attempt = attempts.appendAndCount(key)
                        scope.addFinalizer {
                            released.append("\(key):\(attempt)")
                        }
                        if attempt == 1 {
                            throw SDKTestHelper.TestFailure("Persona store cold")
                        }
                        return SdkInstances.Configuration(
                            plugins: [
                                PluginEffect.Plugin(id: "persona") { ctx in
                                    _ = await ctx.session.hook("prompt", { event in
                                        guard case .prompt(var p) = event else { return event }
                                        p.prompt = PromptInputSchema.Prompt(text: "\(p.prompt.text):\(persona)")
                                        return .prompt(p)
                                    }, nil)
                                },
                            ]
                        )
                    }
                )
            )
        )

        let hostScope = LayerNode.ResourceScope()
        let built = try await layer.build(deps, hostScope)
        let opencode = try #require(built.get(OpenCodeEffect.Service.serviceKey, as: OpenCodeEffect.Interface.self))

        #expect(try await opencode.server.info().version == "effect-test-2.0")

        // Workspace facade: create -> provision -> destroy (idempotent) + ProviderNotFound
        let requestedWorkspaceID = WorkspaceID.create()
        let wid = try await opencode.workspace.create(id: requestedWorkspaceID, provider: "fake")
        #expect(wid == requestedWorkspaceID)
        #expect(try await opencode.workspace.create(id: requestedWorkspaceID, provider: "fake") == requestedWorkspaceID)
        #expect(driver.calls.snapshot().isEmpty)

        let provisioned = try await opencode.workspace.provision(workspaceID: wid)
        #expect(provisioned.provider == "fake")
        #expect(provisioned.binding == ["externalID": JSONValue.string(wid.rawValue)])

        let destroyedFirst = try await opencode.workspace.destroy(workspaceID: wid)
        #expect(destroyedFirst.destroyed == true)
        let destroyedSecond = try await opencode.workspace.destroy(workspaceID: wid)
        #expect(destroyedSecond.destroyed == false)

        do {
            _ = try await opencode.workspace.create(provider: "missing")
            Issue.record("Expected ProviderNotFound")
        } catch let err as CoreProject.Workspace.Driver.ProviderNotFound {
            #expect(err.provider == "missing")
        }

        // Core session direct APIs: missing session throws CoreSessionErrors.NotFoundError directly (no HTTP)
        // while HTTP export throws protocol SessionNotFoundError!
        let missing = SessionID.create()
        do {
            _ = try opencode.sessions.get(sessionID: missing)
            Issue.record("Expected CoreSessionErrors.NotFoundError")
        } catch let err as CoreSessionErrors.NotFoundError {
            #expect(err.sessionID == missing)
            #expect(CoreSessionErrors.NotFoundError.tag == "Session.NotFoundError")
        }
        do {
            _ = try await opencode.experimental.session.export(
                ExperimentalSessionExportInput(sessionID: missing.rawValue)
            )
            Issue.record("Expected HTTP SessionNotFoundError")
        } catch {
            #expect(isSessionNotFoundError(error))
        }

        // Service-configured instance: attempt 1 fails and releases its scope IMMEDIATELY (not held until hostScope closes!)
        let session = try await opencode.sessions.create(
            CoreSession.CreateInput(
                location: OpenCodeLocation(directory: dir),
                title: "Service-configured",
                metadata: ["threadID": .string("thread-7")]
            )
        )
        do {
            _ = try await opencode.sessions.prompt(
                SessionPromptInput(sessionID: session.id.rawValue, text: "Hello", resume: false)
            )
            Issue.record("Expected attempt 1 failure")
        } catch is ClientError {
            // Expected 500
        }
        #expect(released.snapshot() == ["thread-7:1"])

        let admitted = try await opencode.sessions.prompt(
            SessionPromptInput(sessionID: session.id.rawValue, text: "Hello", resume: false)
        )
        #expect(admitted.payload.text == "Hello:persona-for-thread-7")
        #expect(attempts.snapshot() == ["thread-7", "thread-7"])
        #expect(released.snapshot() == ["thread-7:1"])

        // Closing hostScope releases instance 2 AND rejects subsequent HTTP requests
        await hostScope.close()
        #expect(released.snapshot() == ["thread-7:1", "thread-7:2"])

        do {
            _ = try await opencode.server.info()
            Issue.record("Expected transport error after scope close")
        } catch let err as ClientError {
            #expect(err.reason == .transport)
        }
    }

    // MARK: - 8. Workerd Profile (Promise & Effect) & Custom Server Router Hook

    @Test("WorkerdProfile, OpenCodeWorkerd, and OpenCodeEffectWorkerd boot over DurableObjectStorage with persistence and clean teardown")
    func workerdPromiseAndEffectSurfaces() async throws {
        let storage = try SDKTestHelper.InMemoryDurableObjectStorage()
        defer { storage.close() }

        // 1. Verify WorkerdProfile.make options & replacements
        let profile = try WorkerdProfile.make(
            WorkerdProfile.Options(
                storage: storage,
                app: .init(version: "workerd-1.0"),
                config: WorkerdProfile.Configuration(defaultAgent: "build")
            )
        )
        #expect(profile.options.events?.persist == true)
        #expect(profile.options.fs?.filewatcher == false)
        #expect(profile.options.fs?.fff == false)
        #expect(profile.options.config?.content?.contains("\"default_agent\":\"build\"") == true)
        #expect(profile.replacements.count == 6)

        // 2. Promise OpenCodeWorkerd boots over DO storage and persists a session
        let persistedID = SessionID.create()
        let promiseHost = try await OpenCodeWorkerd.create(
            OpenCodeWorkerd.CreateOptions(
                storage: storage,
                app: .init(version: "workerd-promise"),
                config: WorkerdProfile.Configuration(defaultAgent: "build")
            )
        )
        let info = try await promiseHost.server.info()
        #expect(info.version == "workerd-promise")
        #expect(info.pid == 0)
        #expect(info.hostname == nil)

        _ = try await promiseHost.sessions.create(
            SessionCreateInput(
                id: persistedID.rawValue,
                title: "Durable Session",
                location: LocationSchema.PublicRef(directory: SchemaPrimitive.AbsolutePath(rawValue: "/workspace"))
            )
        )
        await promiseHost.close()

        // 3. Effect OpenCodeEffectWorkerd.layer reboots against same DO storage and recovers persisted session!
        let scope = LayerNode.ResourceScope()
        let workerdLayer = OpenCodeEffectWorkerd.layer(
            OpenCodeEffectWorkerd.CreateOptions(
                storage: storage,
                app: .init(version: "workerd-effect"),
                config: WorkerdProfile.Configuration(defaultAgent: "build")
            )
        )
        let built = try await workerdLayer.build(LayerNode.Output(), scope)
        let effectHost = try #require(built.get(OpenCodeEffect.Service.serviceKey, as: OpenCodeEffect.Interface.self))

        let recovered = try effectHost.sessions.get(sessionID: persistedID)
        #expect(recovered.id == persistedID)
        #expect(recovered.title == "Durable Session")

        // Verify direct Effect Workerd `create` also works cleanly
        let secondScope = LayerNode.ResourceScope()
        let directHost = try await OpenCodeEffectWorkerd.create(
            OpenCodeEffectWorkerd.CreateOptions(
                storage: storage,
                app: .init(version: "workerd-direct")
            ),
            scope: secondScope
        )
        #expect(try await directHost.server.info().version == "workerd-direct")
        await secondScope.close()
        await scope.close()
    }

    @Test("Injectable EmbedOptions.routerFactory routes OpenCodeClient traffic cleanly through custom server handlers")
    func injectableCustomServerRouterHook() async throws {
        let seenPaths = SDKTestHelper.Recorder<String>()
        let opencode = try await OpenCode.create(
            OpenCode.CreateOptions(app: .init(version: "custom-router")),
            embed: EmbeddedHost.EmbedOptions(
                routerFactory: { ctx in
                    { request, _ in
                        seenPaths.append("\(request.method) \(request.url)")
                        let payload = OpenCodeProtocol.ServerInfo(
                            version: "\(ctx.appInfo.version)-injected",
                            pid: 1234,
                            hostname: "injected.local",
                            urls: [],
                            paths: .init(tmp: "/injected-tmp")
                        )
                        let bytes = try ClientCodec.encode(payload)
                        return .buffered(
                            HTTPResponse(
                                head: HTTPResponseHead(statusCode: 200, headers: ["content-type": "application/json"]),
                                body: bytes
                            )
                        )
                    }
                }
            )
        )

        let info = try await opencode.server.info()
        #expect(info.version == "custom-router-injected")
        #expect(info.pid == 1234)
        #expect(info.hostname == "injected.local")
        #expect(seenPaths.snapshot() == ["GET http://opencode.local/api/info"])

        await opencode.close()
    }

    @Test("Instances qualify keys by workspaceID and reselect a moved Session without reconfiguring")
    func workspaceQualifiedInstancesAndMoveReselection() async throws {
        let dir = try SDKTestHelper.makeTempDirectory(prefix: "opencode-workspace-move")
        defer { SDKTestHelper.removeDirectory(dir) }

        let driver = SDKTestHelper.RecordingWorkspaceDriver()
        let configured = SDKTestHelper.Recorder<String>()
        let placements = SDKTestHelper.Recorder<WorkspaceID?>()

        let scope = LayerNode.ResourceScope()
        let opencode = try await OpenCodeEffect.create(
            OpenCodeEffect.CreateOptions(
                config: .init(directory: dir, project: false, content: "{}"),
                workspaceProviders: ["memory": driver],
                instances: SdkInstances.Options(
                    key: { session in
                        guard case .string(let threadID) = session.metadata?["threadID"] else { return "default" }
                        return threadID
                    },
                    configure: { key in
                        configured.append(key)
                        return SdkInstances.Configuration(
                            plugins: [
                                PluginEffect.Plugin(id: "placement-hook") { ctx in
                                    placements.append(ctx.location.workspaceID)
                                    _ = await ctx.session.hook("prompt", { event in
                                        guard case .prompt(var p) = event else { return event }
                                        let suffix = ctx.location.workspaceID?.rawValue ?? "local"
                                        p.prompt = PromptInputSchema.Prompt(text: "\(p.prompt.text):\(suffix)")
                                        return .prompt(p)
                                    }, nil)
                                },
                            ]
                        )
                    }
                )
            ),
            scope: scope
        )

        let firstWorkspace = try await opencode.workspace.create(provider: "memory")
        let secondWorkspace = try await opencode.workspace.create(provider: "memory")

        let first = try await opencode.sessions.create(
            CoreSession.CreateInput(
                location: OpenCodeLocation(directory: dir, workspaceID: firstWorkspace),
                title: "First placement",
                metadata: ["threadID": .string("same-thread")]
            )
        )
        let second = try await opencode.sessions.create(
            CoreSession.CreateInput(
                location: OpenCodeLocation(directory: dir, workspaceID: secondWorkspace),
                title: "Second placement",
                metadata: ["threadID": .string("same-thread")]
            )
        )

        let p1 = try await opencode.sessions.prompt(SessionPromptInput(sessionID: first.id.rawValue, text: "Hello", resume: false))
        let p2 = try await opencode.sessions.prompt(SessionPromptInput(sessionID: second.id.rawValue, text: "Hello", resume: false))
        #expect(p1.payload.text == "Hello:\(firstWorkspace.rawValue)")
        #expect(p2.payload.text == "Hello:\(secondWorkspace.rawValue)")
        #expect(configured.snapshot() == ["same-thread", "same-thread"])
        #expect(placements.snapshot() == [firstWorkspace, secondWorkspace])

        // Move session 1 to secondWorkspace: must reselect existing secondWorkspace instance with no 3rd configure
        try await opencode.sessions.move(
            CoreSessionMove.MoveInput(sessionID: first.id, directory: dir, workspaceID: secondWorkspace)
        )
        let moved = try opencode.sessions.get(sessionID: first.id)
        #expect(moved.location.workspaceID == secondWorkspace)

        let p3 = try await opencode.sessions.prompt(SessionPromptInput(sessionID: first.id.rawValue, text: "Moved", resume: false))
        #expect(p3.payload.text == "Moved:\(secondWorkspace.rawValue)")
        #expect(configured.snapshot() == ["same-thread", "same-thread"])

        await scope.close()
    }

    @Test("SdkInstances.node, SdkInstances.layer, and SdkInstances.provide compose directly with LayerNode")
    func sdkInstancesLayerNodeAndProvideAmbientPrecedence() async throws {
        let keyA = "@test/serviceA"
        let keyB = "@test/serviceB"
        let captured = SDKTestHelper.Recorder<String>()

        let raw = SdkInstances.Options(
            key: { _ in "k1" },
            configure: { key, _, services in
                let a = services.get(keyA, as: String.self) ?? "nil"
                let b = services.get(keyB, as: String.self) ?? "nil"
                captured.append("\(key):\(a):\(b)")
                return SdkInstances.Configuration(plugins: [])
            }
        )
        let provided = SdkInstances.provide(raw, context: LayerNode.Output([keyA: "from-build", keyB: "from-build"]))
        let checkScope = LayerNode.ResourceScope()
        _ = try await provided.configure("k1", checkScope, LayerNode.Output([keyB: "from-ambient"]))
        #expect(captured.snapshot() == ["k1:from-build:from-ambient"])

        let providerNode = SdkInstances.node(provided, replacements: { [] })
        let compiled = try LayerNode.compile(
            providerNode,
            options: LayerNode.CompileOptions(
                replacements: [
                    try CoreLocation.ServiceMap.node.replace(
                        with: CoreLocation.Services.buildLocationServiceMap()
                    ),
                ]
            )
        )
        let graphScope = LayerNode.ResourceScope()
        let built = try await compiled.build(scope: graphScope)
        let selector = try #require(
            built.get(CoreLocation.Instance.Service.serviceKey, as: SdkInstances.SelectorService.self)
        )
        let session = SessionSchema.Info(
            id: SessionID.create(),
            projectID: ProjectID.global,
            cost: 0,
            tokens: .zero,
            time: .init(created: 1, updated: 1),
            title: "Test",
            location: OpenCodeLocation(directory: "/tmp/a/./b/../b")
        )
        #expect(selector.live(session: session) == false)
        let container = try await selector.acquire(session: session)
        #expect(container.instanceKey.location.directory.rawValue == "/tmp/a/b")
        #expect(selector.live(session: session) == true)

        await graphScope.close()
        await checkScope.close()
    }

    @Test("OpenCode.make and OpenCode.create coexist without ambiguity and OpenCodeEffect.withScoped closes on thrown error")
    func clientAndSdkCoexistenceAndScopedErrorCleanup() async throws {
        // 1. OwnedFetch already-aborted signal rejects without invoking handler
        let handlerInvoked = SDKTestHelper.Recorder<Bool>()
        let transport = OwnedFetch.make(
            bufferedHandler: { _, _ in
                handlerInvoked.append(true)
                return HTTPResponse(head: HTTPResponseHead(statusCode: 200), body: [])
            },
            dispose: {}
        )
        let preAborted = AbortSignal.aborted(reason: SDKTestHelper.TestFailure("pre-aborted"))
        do {
            _ = try await transport.fetch(HTTPRequest(method: "GET", url: "http://opencode.local/"), signal: preAborted)
            Issue.record("Expected pre-aborted error")
        } catch let err as SDKTestHelper.TestFailure {
            #expect(err.message == "pre-aborted")
        }
        #expect(handlerInvoked.snapshot().isEmpty)

        // 2. OpenCode.make (Client) works alongside OpenCode.create (SDK) with zero ambiguity
        let standaloneClient = OpenCode.make(ClientOptions(baseUrl: "http://opencode.local", transport: transport))
        await transport.close()
        do {
            _ = try await standaloneClient.server.info()
            Issue.record("Expected transport error on closed OwnedFetch")
        } catch let err as ClientError {
            #expect(err.reason == .transport)
        }

        // 3. OpenCodeEffect.withScoped closes host even when body throws
        let cleanedUp = SDKTestHelper.Recorder<Bool>()
        var leakedHost: EmbeddedHost.Interface? = nil
        do {
            try await OpenCodeEffect.withScoped(
                OpenCodeEffect.CreateOptions(
                    plugins: [
                        PluginEffect.Plugin(id: "cleanup-on-throw") { ctx in
                            ctx.addFinalizer {
                                cleanedUp.append(true)
                            }
                        },
                    ]
                )
            ) { sdk in
                leakedHost = sdk.host
                await sdk.host.defaultPluginService.awaitActivation()
                throw SDKTestHelper.TestFailure("body exploded")
            }
            Issue.record("Expected body error")
        } catch let err as SDKTestHelper.TestFailure {
            #expect(err.message == "body exploded")
        }
        #expect(cleanedUp.snapshot() == [true])
        #expect(leakedHost?.fetch.isClosed == true)
    }
}
