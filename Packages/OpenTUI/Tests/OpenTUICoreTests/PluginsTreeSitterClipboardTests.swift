import OpenTUICore
import OpenTUILayout
import OpenTUIRenderables
import Synchronization
import Testing

// MARK: - HostClipboard Tests

@Suite("HostClipboard", .serialized)
struct HostClipboardTests {
    @Test("validateClipboardText rejects empty, NUL, and byte-limit overflow")
    func validateTextRules() throws {
        try validateClipboardText("hello world", maxWriteBytes: 64)
        try validateClipboardText("🚀", maxWriteBytes: 4)

        #expect(throws: HostClipboardError.typeError("writeText requires non-empty text")) {
            try validateClipboardText("", maxWriteBytes: 64)
        }
        #expect(throws: HostClipboardError.typeError("writeText does not support NUL characters")) {
            try validateClipboardText("abc\0def", maxWriteBytes: 64)
        }
        #expect(throws: HostClipboardError.rangeError("writeText exceeds the configured 3 byte limit")) {
            try validateClipboardText("🚀", maxWriteBytes: 3)
        }
        #expect(throws: HostClipboardError.typeError("writeText does not support unpaired UTF-16 surrogates")) {
            try validateClipboardUTF16([0xD83D], maxWriteBytes: 64)
        }
    }

    @Test("HostClipboardService MIME preference order, normalization, validation, and size limits")
    func hostClipboardMimeRepresentations() async throws {
        let backend = InMemoryHostClipboardBackend(
            initialRepresentations: [
                .clipboard: [
                    ClipboardRepresentation(mimeType: "text/plain", bytes: Array("plain".utf8)),
                    ClipboardRepresentation(mimeType: "text/html", bytes: Array("<b>bold</b>".utf8)),
                ]
            ]
        )

        let service = try createHostClipboardWithBackend(
            options: HostClipboardOptions(timeoutMs: 500, maxReadBytes: 8, maxWriteBytes: 16),
            createBackend: { _ in backend }
        )

        // Preference order picks text/plain when listed first (case-insensitive MIME essence)
        let plainRead = try await service.read(
            ClipboardReadOptions(preferredTypes: ["TEXT/PLAIN", "text/html"])
        )
        #expect(plainRead == .read(ClipboardRepresentation(mimeType: "text/plain", bytes: Array("plain".utf8))))

        // text/html is 11 bytes > maxReadBytes (8) -> limit-exceeded
        let tooLargeRead = try await service.read(
            ClipboardReadOptions(preferredTypes: ["text/html"])
        )
        #expect(tooLargeRead == .limitExceeded)

        // Invalid MIME essence (contains parameter) throws typeError
        await #expect(throws: HostClipboardError.typeError("preferredTypes must contain valid MIME essence types without parameters")) {
            _ = try await service.read(ClipboardReadOptions(preferredTypes: ["text/plain; charset=utf-8"]))
        }

        // Empty preferredTypes throws typeError
        await #expect(throws: HostClipboardError.typeError("preferredTypes must contain at least one MIME essence type")) {
            _ = try await service.read(ClipboardReadOptions(preferredTypes: []))
        }

        // Write text and read back
        let writeStatus = try await service.writeText("swift-opentui")
        #expect(writeStatus == .written)

        // Oversized read for 13-byte text with 8-byte maxReadBytes
        let oversizedAfterWrite = try await service.read(ClipboardReadOptions(preferredTypes: ["text/plain"]))
        #expect(oversizedAfterWrite == .limitExceeded)

        // Clear selection -> empty
        let cleared = try await service.clear()
        #expect(cleared == .cleared)
        let afterClear = try await service.read(ClipboardReadOptions(preferredTypes: ["text/plain"]))
        #expect(afterClear == .empty)

        try await service.dispose()
    }

    @Test("HostClipboard tracked cancellation and disposal abort in-flight operations")
    func hostClipboardTrackedCancellation() async throws {
        let controller = ClipboardAbortController()
        controller.abort(reason: "pre-cancelled")

        let backend = InMemoryHostClipboardBackend()
        let service = try createHostClipboardWithBackend(
            options: HostClipboardOptions(timeoutMs: 500),
            createBackend: { _ in backend }
        )

        let preCancelled = try await service.writeText(
            "ignored",
            options: HostClipboardOperationOptions(signal: controller.signal)
        )
        #expect(preCancelled == .cancelled)

        // timeoutMs == 0 immediately reports timed-out
        let zeroTimeoutService = try createHostClipboardWithBackend(
            options: HostClipboardOptions(timeoutMs: 0),
            createBackend: { _ in InMemoryHostClipboardBackend() }
        )
        #expect(try await zeroTimeoutService.clear() == .timedOut)
        try await zeroTimeoutService.dispose()

        // Active operation aborted when service disposes
        let activeOps = ActiveClipboardOperationSet()
        let opController = ClipboardAbortController()
        let observedAborted = Mutex<Bool>(false)

        let result: String = try await runTrackedOperation(active: activeOps, callerSignal: opController.signal) { signal in
            opController.abort(reason: "user-abort")
            observedAborted.withLock { $0 = signal.isAborted }
            return "done"
        }
        #expect(result == "done")
        #expect(observedAborted.withLock { $0 } == true)
        #expect(activeOps.count == 0)

        try await service.dispose()
        #expect(backend.isDisposed)

        await #expect(throws: HostClipboardError.disposed("Host clipboard service is disposed")) {
            _ = try await service.writeText("after-dispose")
        }
    }

    @Test("Composed ClipboardService respects policies, remote fallback, and newest-wins supersession")
    func composedClipboardPoliciesAndSupersession() async throws {
        final class RecordingTerminalAdapter: TerminalClipboardAdapter, Sendable {
            let remote: Bool
            private let writes = Mutex<[(String, ClipboardSelection)]>([])
            private let clears = Mutex<[ClipboardSelection]>([])

            init(remote: Bool = false) {
                self.remote = remote
            }

            var recordedWrites: [(String, ClipboardSelection)] {
                writes.withLock { $0 }
            }

            var recordedClears: [ClipboardSelection] {
                clears.withLock { $0 }
            }

            func writeText(_ text: String, selection: ClipboardSelection) -> TerminalClipboardOperationResult {
                writes.withLock { $0.append((text, selection)) }
                return TerminalClipboardOperationResult(status: .attempted, capability: .supported)
            }

            func clear(selection: ClipboardSelection) -> TerminalClipboardOperationResult {
                clears.withLock { $0.append(selection) }
                return TerminalClipboardOperationResult(status: .attempted, capability: .supported)
            }
        }

        // 1. bestAvailable on local session uses host without hitting terminal when host succeeds
        let localBackend = InMemoryHostClipboardBackend()
        let localHost = try createHostClipboardWithBackend(createBackend: { _ in localBackend })
        let localTerminal = RecordingTerminalAdapter(remote: false)
        let localClipboard = createClipboard(ClipboardOptions(host: localHost, terminal: localTerminal))

        let res1 = try await localClipboard.writeText(
            "local-copy",
            options: ClipboardWriteOptions(destination: .bestAvailable)
        )
        #expect(res1.host == .written)
        #expect(res1.terminal.status == .notAttempted)
        #expect(localTerminal.recordedWrites.isEmpty)

        // 2. bestAvailable falls back to terminal when host returns unsupported
        localBackend.setSupported(false)
        let res2 = try await localClipboard.writeText(
            "fallback-copy",
            options: ClipboardWriteOptions(destination: .bestAvailable)
        )
        #expect(res2.host == .unsupported)
        #expect(res2.terminal.status == .attempted)
        #expect(localTerminal.recordedWrites.map(\.0) == ["fallback-copy"])

        // 3. allAvailable writes both host and terminal
        localBackend.setSupported(true)
        let res3 = try await localClipboard.writeText(
            "both-copy",
            options: ClipboardWriteOptions(destination: .allAvailable)
        )
        #expect(res3.host == .written)
        #expect(res3.terminal.status == .attempted)
        #expect(localTerminal.recordedWrites.last?.0 == "both-copy")

        // 4. Remote session skips host on hostOnly unless allowRemoteHost == true
        let remoteBackend = InMemoryHostClipboardBackend()
        let remoteHost = try createHostClipboardWithBackend(createBackend: { _ in remoteBackend })
        let remoteTerminal = RecordingTerminalAdapter(remote: true)
        let remoteClipboard = createClipboard(ClipboardOptions(host: remoteHost, terminal: remoteTerminal))

        let skipped = try await remoteClipboard.writeText(
            "blocked-remote",
            options: ClipboardWriteOptions(destination: .hostOnly)
        )
        #expect(skipped.host == .notAttempted)
        #expect(skipped.terminal.status == .notAttempted)

        let allowed = try await remoteClipboard.writeText(
            "allowed-remote",
            options: ClipboardWriteOptions(destination: .hostOnly, allowRemoteHost: true)
        )
        #expect(allowed.host == .written)

        // 5. Injectable NativeHostClipboardBackendRegistry
        let customBackend = InMemoryHostClipboardBackend()
        NativeHostClipboardBackendRegistry.register { _ in customBackend }
        defer { NativeHostClipboardBackendRegistry.register(nil) }

        let nativeHost = try createHostClipboard()
        #expect(try await nativeHost.writeText("via-registry") == .written)
        #expect(customBackend.storedRepresentation(mimeType: "text/plain")?.bytes == Array("via-registry".utf8))

        try await localClipboard.dispose()
        try await remoteClipboard.dispose()
        try await nativeHost.dispose()
    }
}

// MARK: - TreeSitterClient Tests

@Suite("TreeSitterClient", .serialized)
struct TreeSitterClientTests {
    @Test("Default parsers, asset paths, and addDefaultParsers overrides")
    func defaultParsersAndOverrides() async {
        resetDefaultParserOverrides()
        defer { resetDefaultParserOverrides() }

        #expect(defaultParserAssetPaths.count == 13)
        let defaults = await getParsers()
        let filetypes = Set(defaults.map(\.filetype))
        #expect(filetypes.contains("javascript"))
        #expect(filetypes.contains("typescript"))
        #expect(filetypes.contains("typescriptreact"))
        #expect(filetypes.contains("markdown"))
        #expect(filetypes.contains("markdown_inline"))
        #expect(filetypes.contains("zig"))

        addDefaultParsers([
            FiletypeParserOptions(
                filetype: "swift",
                aliases: ["sw"],
                queries: FiletypeParserQueries(highlights: ["assets/swift/highlights.scm"]),
                wasm: "assets/swift/tree-sitter-swift.wasm"
            )
        ])
        let withOverride = getDefaultParsers()
        #expect(withOverride.contains { $0.filetype == "swift" })
    }

    @Test("TreeSitterClient highlightOnce, caching, custom parser registration, and query fetching")
    func highlightOnceCachingAndCustomParsers() async throws {
        let loader = InMemoryTreeSitterAssetLoader(
            remoteURLs: [
                "https://example.invalid/custom.scm": Array("(identifier) @variable\n".utf8),
            ]
        )
        let client = TreeSitterClient(
            options: TreeSitterClientOptions(
                dataPath: "/virtual/cache",
                assetLoader: loader
            )
        )

        #expect(!client.isInitialized())
        try await client.initialize()
        #expect(client.isInitialized())

        // Built-in pure-Swift highlighter works out of the box
        let swiftResult = await client.highlightOnce("let answer = 42", filetype: "swift")
        let highlights = try #require(swiftResult.highlights)
        #expect(highlights.contains { $0.group == "keyword" })
        #expect(highlights.contains { $0.group == "number" })
        #expect(client.cacheCount == 1)

        // Second call serves from cache without adding cache entries
        let cachedResult = await client.highlightOnce("let answer = 42", filetype: "swift")
        #expect(cachedResult == swiftResult)
        #expect(client.cacheCount == 1)

        // Register custom parser + custom highlighter + alias + remote query
        client.addFiletypeParser(
            FiletypeParserOptions(
                filetype: "toy",
                aliases: ["ty", "toy"],
                queries: FiletypeParserQueries(highlights: ["https://example.invalid/custom.scm"]),
                wasm: "/$bunfs/root/nested/tree-sitter-toy.wasm"
            )
        )
        client.registerCustomHighlighter(
            StaticSyntaxHighlighter(highlights: [SimpleHighlight(0, 3, "keyword")]),
            forFiletype: "toy",
            aliases: ["ty"]
        )

        let preloaded = await client.preloadParser("ty")
        #expect(preloaded)
        #expect(client.query(forFiletype: "toy")?.contains("@variable") == true)
        #expect(loader.remoteFetchCount == 1)

        let customOutcome = await client.highlightOnce("foo bar", filetype: "ty")
        #expect(customOutcome.highlights == [SimpleHighlight(0, 3, "keyword")])

        // clearCache empties highlight cache & loaded queries
        try await client.clearCache()
        #expect(client.cacheCount == 0)
        #expect(client.query(forFiletype: "toy") == nil)

        // Streaming append highlight & copy disposal
        let part1 = await client.highlightAppend(copyId: 1, offset: 0, text: "let x = ", filetype: "swift")
        #expect(part1.error == nil)
        let part2 = await client.highlightAppend(copyId: 1, offset: 8, text: "100", filetype: "swift")
        #expect(part2.highlights?.contains { $0.group == "number" } == true)
        let badOffset = await client.highlightAppend(copyId: 1, offset: 99, text: "!", filetype: "swift")
        #expect(badOffset.error != nil)
        await client.removeCopy(1)

        let perf = await client.getPerformance()
        #expect(!perf.parseTimes.isEmpty)
        #expect(perf.averageParseTime >= 0)

        await client.destroy()
        #expect(!client.isInitialized())
    }

    @Test("TreeSitterClient buffer lifecycle events and default singleton management")
    func bufferLifecycleAndSingleton() async throws {
        await destroyTreeSitterClient()
        defer { setDefaultTreeSitterClient(nil) }

        let client = TreeSitterClient(options: TreeSitterClientOptions(dataPath: "/tmp/ts-test"))
        let highlightEvents = Mutex<[(Int, Int, [HighlightResponse])]>([])
        let disposedIds = Mutex<[Int]>([])

        _ = client.onHighlightsResponse { id, version, responses in
            highlightEvents.withLock { $0.append((id, version, responses)) }
        }
        _ = client.onBufferDisposed { id in
            disposedIds.withLock { $0.append(id) }
        }

        let created = try await client.createBuffer(id: 7, content: "const x = 1\nconst y = 2", filetype: "typescript", version: 1)
        #expect(created)
        #expect(client.getBuffer(7)?.hasParser == true)
        #expect(client.getAllBuffers().count == 1)

        await client.updateBuffer(id: 7, edits: [], newContent: "const x = 42", version: 2)
        #expect(client.getBuffer(7)?.version == 2)

        await client.resetBuffer(bufferId: 7, version: 3, content: "return true")
        #expect(client.getBuffer(7)?.version == 3)

        let recorded = highlightEvents.withLock { $0 }
        #expect(recorded.count == 3)
        #expect(recorded[0].0 == 7 && recorded[0].1 == 1)
        #expect(recorded[2].1 == 3)

        await client.removeBuffer(7)
        #expect(client.getBuffer(7) == nil)
        #expect(disposedIds.withLock { $0 } == [7])

        // Singleton wiring
        setDefaultTreeSitterClient(client)
        #expect(getTreeSitterClient() === client)
        await destroyTreeSitterClient()
        #expect(!client.isInitialized())
    }
}

// MARK: - DataPaths, Singleton & Runtime Helpers Tests

@Suite("DataPaths and Singleton", .serialized)
struct DataPathsAndSingletonTests {
    @Test("DataPathsManager resolves POSIX XDG, Windows AppData, overrides, and emits paths:changed")
    func dataPathsResolutionAndEvents() throws {
        let manager = DataPathsManager(
            environment: [
                "XDG_CONFIG_HOME": "/xdg/cfg",
                "XDG_DATA_HOME": "/xdg/data",
                "XDG_CACHE_HOME": "/xdg/cache",
                "XDG_STATE_HOME": "/xdg/state",
            ],
            homeDirectory: "/Users/tester",
            currentWorkingDirectory: "/work/repo"
        )

        #expect(manager.appName == "opentui")
        #expect(manager.globalConfigPath == "/xdg/cfg/opentui")
        #expect(manager.globalConfigFile == "/xdg/cfg/opentui/init.ts")
        #expect(manager.localConfigFile == "/work/repo/.opentui.ts")
        #expect(manager.globalDataPath == "/xdg/data/opentui")
        #expect(manager.globalCachePath == "/xdg/cache/opentui")
        #expect(manager.globalStatePath == "/xdg/state/opentui")

        let observed = Mutex<[DataPaths]>([])
        let token = manager.onPathsChanged { paths in
            observed.withLock { $0.append(paths) }
        }

        try manager.setAppName("my-cli")
        #expect(manager.globalConfigPath == "/xdg/cfg/my-cli")
        #expect(manager.localConfigFile == "/work/repo/.my-cli.ts")
        #expect(observed.withLock { $0.count } == 1)

        // Invalid app name rejected
        #expect(throws: DataPathsError.invalidAppName("bad/name")) {
            try manager.setAppName("bad/name")
        }

        // Override hooks take precedence
        manager.setOverrides(DataPathsOverrides(configDir: "/override/cfg", dataDir: "/override/data"))
        #expect(manager.globalConfigPath == "/override/cfg")
        #expect(manager.globalDataPath == "/override/data")
        #expect(observed.withLock { $0.count } == 2)

        manager.offPathsChanged(token)

        // Windows AppData style
        let winManager = DataPathsManager(
            environment: [
                "APPDATA": "C:\\Users\\Dev\\AppData\\Roaming",
                "LOCALAPPDATA": "C:\\Users\\Dev\\AppData\\Local",
            ],
            homeDirectory: "C:\\Users\\Dev",
            currentWorkingDirectory: "C:\\src",
            platformStyle: .windows
        )
        #expect(winManager.globalConfigPath == "C:\\Users\\Dev\\AppData\\Roaming\\opentui")
        #expect(winManager.globalDataPath == "C:\\Users\\Dev\\AppData\\Local\\opentui")
    }

    @Test("Singleton store creates once, queries, destroys, and clears safely")
    func singletonStoreLifecycle() {
        let key = "test.workstream3.singleton"
        destroySingleton(key)
        #expect(!hasSingleton(key))
        #expect(getSingleton(key, as: Int.self) == nil)

        var invocations = 0
        let first = singleton(key) {
            invocations += 1
            return 42
        }
        let second = singleton(key) {
            invocations += 1
            return 99
        }

        #expect(first == 42)
        #expect(second == 42)
        #expect(invocations == 1)
        #expect(hasSingleton(key))
        #expect(getSingleton(key, as: Int.self) == 42)

        destroySingleton(key)
        #expect(!hasSingleton(key))
    }

    @Test("SessionBuffer leasing, withBufferAccess scope enforcement, BunFS & asset descriptors")
    func bufferAccessAndRuntimeAssets() throws {
        let session = SessionBuffer(width: 4, height: 2)
        session.current.drawText("Hi", x: 0, y: 0, fg: RGBA.fromInts(255, 255, 255, 255))

        let lease = acquireSessionBufferLease(session: session, which: .current, frameId: 1)
        #expect(session.activeLeaseCount == 1)

        var leakedView: BufferAccessView? = nil
        let firstChar: UInt32 = try withBufferAccess(session: session, lease: lease) { view in
            leakedView = view
            let chars = try view.chars()
            return chars[0]
        }
        #expect(firstChar == UInt32(UInt8(ascii: "H")))
        #expect(session.activeLeaseCount == 0)

        // Accessing leaked view outside scope throws scopeEnded
        let view = try #require(leakedView)
        #expect(throws: BufferAccessError.scopeEnded) {
            _ = try view.chars()
        }

        // BunFS & asset target validation
        #expect(isBunfsPath("/$bunfs/root/file.wasm"))
        #expect(isBunfsPath("B:\\~BUN\\root\\file.wasm"))
        #expect(!isBunfsPath("/usr/local/lib/file.wasm"))
        #expect(normalizeBunfsPath("/foo/bar/tree-sitter.wasm") == "/$bunfs/root/tree-sitter.wasm")

        let darwinArm = try getNativeAssetDescriptor(NodeAssetTarget(platform: "darwin", arch: "arm64"))
        #expect(darwinArm.packageName == "@opentui/core-darwin-arm64")
        #expect(darwinArm.fileName == "libopentui.dylib")

        let linuxMusl = try getNativeAssetDescriptor(NodeAssetTarget(platform: "linux", arch: "x64", libc: "musl"))
        #expect(linuxMusl.packageName == "@opentui/core-linux-x64-musl")

        #expect(throws: RuntimeAssetError.invalidAssetKey("../escape")) {
            try validateAssetKey("../escape")
        }
    }
}

// MARK: - PluginRegistry & CoreSlotRenderable Tests

@Suite("PluginRegistry and CoreSlotRenderable", .serialized)
struct PluginSystemTests {
    private final class AppPluginContext {
        let appTitle: String
        var events: [String] = []

        init(appTitle: String) {
            self.appTitle = appTitle
        }
    }

    private struct SlotData {
        var label: String
    }

    private struct SimulatedPluginError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    @Test("PluginRegistry ordering, duplicate detection, batching, error containment, and renderer teardown")
    func pluginRegistryOrderingAndContainment() throws {
        let testRenderer = createTestRenderer(width: 40, height: 10)
        let ctx = AppPluginContext(appTitle: "Demo")

        let registry: CoreSlotRegistry<String, AppPluginContext, SlotData> = try createCoreSlotRegistry(
            renderer: testRenderer.renderer,
            context: ctx,
            options: SlotRegistryOptions(maxPluginErrors: 2)
        )

        // Calling createCoreSlotRegistry with a different context object throws
        #expect(throws: PluginRegistryError.mismatchedContext(key: "core:slot-registry")) {
            let _: CoreSlotRegistry<String, AppPluginContext, SlotData> = try createCoreSlotRegistry(
                renderer: testRenderer.renderer,
                context: AppPluginContext(appTitle: "Other")
            )
        }

        var notifications = 0
        _ = registry.subscribe { notifications += 1 }

        // Batch registration emits a single notification
        try registry.batch {
            _ = try registerCorePlugin(
                in: registry,
                plugin: CorePlugin(
                    id: "second",
                    order: 20,
                    dispose: { ctx.events.append("dispose:second") },
                    slots: ["header": .renderer { _, data in
                        TextRenderable(ctx: testRenderer.renderer, options: TextOptions(content: .string("B:\(data.label)")))
                    }]
                )
            )
            _ = try registerCorePlugin(
                in: registry,
                plugin: CorePlugin(
                    id: "first",
                    order: 10,
                    dispose: { ctx.events.append("dispose:first") },
                    slots: ["header": .renderer { _, data in
                        TextRenderable(ctx: testRenderer.renderer, options: TextOptions(content: .string("A:\(data.label)")))
                    }]
                )
            )
        }

        #expect(notifications == 1)
        #expect(resolveCoreSlot(in: registry, slot: "header").map(\.id) == ["first", "second"])

        // Duplicate plugin ID throws
        #expect(throws: PluginRegistryError.duplicatePlugin(id: "first")) {
            try registerCorePlugin(in: registry, plugin: CorePlugin(id: "first", slots: [:]))
        }

        // Dynamic priority reorder
        #expect(registry.updateOrder("second", order: 1))
        #expect(resolveCoreSlot(in: registry, slot: "header").map(\.id) == ["second", "first"])

        // Setup failure is contained and recorded without registering plugin
        _ = try registerCorePlugin(
            in: registry,
            plugin: CorePlugin(
                id: "broken-setup",
                setup: { _, _ in throw SimulatedPluginError(message: "boom-setup") },
                slots: [:]
            )
        )
        #expect(!registry.registeredPluginIds.contains("broken-setup"))
        #expect(registry.getPluginErrors().last?.phase == .setup)

        // Renderer destroy automatically clears the registry and runs dispose hooks
        testRenderer.destroy()
        #expect(ctx.events.contains("dispose:first"))
        #expect(ctx.events.contains("dispose:second"))
    }

    @Test("CoreSlotRenderable mounts append/replace/single modes, managed hooks, and error placeholders in TestRenderer")
    func coreSlotRenderableInTestRenderer() throws {
        let testRenderer = createTestRenderer(width: 40, height: 10)
        defer { testRenderer.destroy() }

        let ctx = AppPluginContext(appTitle: "Host")
        let registry: CoreSlotRegistry<String, AppPluginContext, SlotData> = try createCoreSlotRegistry(
            renderer: testRenderer.renderer,
            context: ctx
        )

        let slot = try CoreSlotRenderable<String, AppPluginContext, SlotData>(
            ctx: testRenderer.renderer,
            options: SlotRenderableOptions(
                renderable: RenderableOptions(flexDirection: .column),
                registry: registry,
                name: "banner",
                data: SlotData(label: "v1"),
                mode: .append,
                fallback: {
                    [TextRenderable(ctx: testRenderer.renderer, options: TextOptions(content: .string("FALLBACK")))]
                },
                pluginFailurePlaceholder: { failure, _ in
                    [TextRenderable(ctx: testRenderer.renderer, options: TextOptions(content: .string("ERR:\(failure.pluginId)")))]
                }
            )
        )
        testRenderer.root.add(slot)
        testRenderer.renderOnce()

        // No plugins yet -> fallback visible
        #expect(testRenderer.captureCharFrame().contains("FALLBACK"))

        // Register plugin in .append mode -> both FALLBACK and plugin render
        let unregisterP1 = try registerCorePlugin(
            in: registry,
            plugin: CorePlugin(
                id: "p1",
                order: 10,
                slots: [
                    "banner": .managed(
                        CoreManagedSlot(
                            render: { _, data in
                                TextRenderable(ctx: testRenderer.renderer, options: TextOptions(content: .string("P1-\(data.label)")))
                            },
                            onActivate: { $0.events.append("activate:p1") },
                            onDeactivate: { $0.events.append("deactivate:p1") },
                            onDispose: { $0.events.append("dispose:p1") }
                        )
                    )
                ]
            )
        )
        testRenderer.renderOnce()
        let appendFrame = testRenderer.captureCharFrame()
        #expect(appendFrame.contains("FALLBACK"))
        #expect(appendFrame.contains("P1-v1"))
        #expect(ctx.events == ["activate:p1"])

        // Updating slot.data re-renders plugin output
        slot.data = SlotData(label: "v2")
        testRenderer.renderOnce()
        #expect(testRenderer.captureCharFrame().contains("P1-v2"))

        // Switch to .replace mode -> FALLBACK hidden, plugin shown
        slot.mode = .replace
        testRenderer.renderOnce()
        let replaceFrame = testRenderer.captureCharFrame()
        #expect(!replaceFrame.contains("FALLBACK"))
        #expect(replaceFrame.contains("P1-v2"))

        // Register higher-priority plugin p0 and switch to .single (.singleWinner)
        _ = try registerCorePlugin(
            in: registry,
            plugin: CorePlugin(
                id: "p0",
                order: 1,
                slots: [
                    "banner": .renderer { _, data in
                        TextRenderable(ctx: testRenderer.renderer, options: TextOptions(content: .string("P0-\(data.label)")))
                    }
                ]
            )
        )
        slot.mode = .single
        testRenderer.renderOnce()
        let singleFrame = testRenderer.captureCharFrame()
        #expect(singleFrame.contains("P0-v2"))
        #expect(!singleFrame.contains("P1-v2"))
        #expect(ctx.events.contains("deactivate:p1"))

        // Error boundary renders failure placeholder when a plugin throws during render
        _ = try registerCorePlugin(
            in: registry,
            plugin: CorePlugin(
                id: "failing",
                order: 0,
                slots: [
                    "banner": .renderer { _, _ in
                        throw SimulatedPluginError(message: "render-crash")
                    }
                ]
            )
        )
        testRenderer.renderOnce()
        #expect(testRenderer.captureCharFrame().contains("ERR:failing"))
        #expect(registry.getPluginErrors().contains { $0.pluginId == "failing" && $0.phase == .render && $0.source == .core })

        // Unregistering p1 fires its onDispose managed hook
        unregisterP1()
        #expect(ctx.events.contains("dispose:p1"))
    }

    @Test("Runtime plugin specifier encoding and RuntimePluginSupport compatibility checks")
    func runtimePluginSupportConfiguration() throws {
        RuntimePluginSupport.reset()
        defer { RuntimePluginSupport.reset() }

        #expect(isCoreRuntimeModuleSpecifier("@opentui/core"))
        #expect(isCoreRuntimeModuleSpecifier("@opentui/core/testing"))
        #expect(!isCoreRuntimeModuleSpecifier("solid-js"))

        #expect(runtimeModuleIdForSpecifier("@opentui/core") == "opentui:runtime-module:%40opentui%2Fcore")

        let firstInstall = try configureRuntimePluginSupport(
            CreateRuntimePluginOptions(
                additional: ["custom-mod": .exports(["version": AnySendablePayload("1.0")])],
                preserve: .list(["preserved-pkg"])
            )
        )
        #expect(firstInstall == true)
        #expect(RuntimePluginSupport.isInstalled)
        #expect(RuntimePluginSupport.current?.isPreserved("preserved-pkg") == true)

        // Compatible repeat call returns false
        let secondInstall = try ensureRuntimePluginSupport(
            CreateRuntimePluginOptions(additional: ["custom-mod": .exports([:])])
        )
        #expect(secondInstall == false)

        // Incompatible additional specifier throws
        #expect(throws: PluginRegistryError.self) {
            try ensureRuntimePluginSupport(
                CreateRuntimePluginOptions(additional: ["missing-mod": .exports([:])])
            )
        }
    }
}
