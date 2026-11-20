import Synchronization
import Testing
import OpenCodeCore
import OpenCodePlatform
import OpenCodeSchema

/// Core-tier unit tests matching upstream `watcher.test.ts`, `file-watch.test.ts`, and `instruction-discovery.test.ts`.
@Suite("Core watcher, FileWatch, and Instruction.Loader parity")
struct InstructionWatcherTests {

    private final class CountingNative: CoreFilesystem.Watcher.NativeInterface, Sendable {
        struct Counts: Sendable {
            var subscribes: Int = 0
            var unsubscribes: Int = 0
            var publishCallbacks: [@Sendable (CoreFilesystem.Watcher.Update) -> Void] = []
        }

        let counts = Mutex(Counts())
        let unavailable: Bool

        init(unavailable: Bool = false) {
            self.unavailable = unavailable
        }

        func subscribe(
            _ input: CoreFilesystem.Watcher.WatchInput,
            publish: @escaping @Sendable (CoreFilesystem.Watcher.Update) -> Void
        ) async -> CoreFilesystem.Watcher.NativeSubscription? {
            _ = input
            counts.withLock {
                $0.subscribes += 1
                if !unavailable { $0.publishCallbacks.append(publish) }
            }
            if unavailable { return nil }
            return CoreFilesystem.Watcher.NativeSubscription(backend: "counting") { [self] in
                self.counts.withLock { $0.unsubscribes += 1 }
            }
        }
    }

    private final class ConcurrencyTrackingHTTP: HTTPTransport, Sendable {
        struct State: Sendable {
            var active: Int = 0
            var maxActive: Int = 0
            var requests: [String] = []
        }

        let state = Mutex(State())
        let delay: Duration
        let handler: @Sendable (String) async throws -> HTTPResponse

        init(
            delay: Duration = .milliseconds(30),
            handler: @escaping @Sendable (String) async throws -> HTTPResponse = { url in
                HTTPResponse(head: HTTPResponseHead(statusCode: 200), body: Array("body:\(url)".utf8))
            }
        ) {
            self.delay = delay
            self.handler = handler
        }

        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            state.withLock { s in
                s.requests.append(request.url)
                s.active += 1
                if s.active > s.maxActive { s.maxActive = s.active }
            }
            defer {
                state.withLock { $0.active -= 1 }
            }
            try await Task.sleep(for: delay)
            return try await handler(request.url)
        }

        func stream(_ request: HTTPRequest) async throws -> HTTPStreamingResponse {
            throw HTTPTransportError.noStubbedResponse(method: request.method, url: request.url)
        }
    }

    private final class SandboxedFileSystem: OpenCodeFileSystem, Sendable {
        let inner: InMemoryFileSystem
        let deniedPaths: Set<String>
        let vanishPaths: Set<String>

        init(inner: InMemoryFileSystem, deniedPaths: Set<String> = [], vanishPaths: Set<String> = []) {
            self.inner = inner
            self.deniedPaths = deniedPaths
            self.vanishPaths = vanishPaths
        }

        func readFile(at path: String) async throws -> [UInt8] {
            if deniedPaths.contains(path) {
                throw PlatformError.permissionDenied(path, code: "EPERM")
            }
            if vanishPaths.contains(path) {
                throw PlatformError.notFound(path)
            }
            return try await inner.readFile(at: path)
        }

        func writeFile(_ bytes: [UInt8], to path: String, createDirectories: Bool) async throws {
            try await inner.writeFile(bytes, to: path, createDirectories: createDirectories)
        }

        func exists(at path: String) async -> Bool { await inner.exists(at: path) }
        func stat(at path: String) async throws -> FileStat { try await inner.stat(at: path) }
        func makeDirectory(at path: String, recursive: Bool) async throws { try await inner.makeDirectory(at: path, recursive: recursive) }
        func readDirectory(at path: String) async throws -> [String] { try await inner.readDirectory(at: path) }
        func remove(at path: String) async throws { try await inner.remove(at: path) }
        func rename(from source: String, to destination: String) async throws { try await inner.rename(from: source, to: destination) }
        func realPath(at path: String) async throws -> String { try await inner.realPath(at: path) }
        func setModificationTime(at path: String, epochMs: Int64) async throws { try await inner.setModificationTime(at: path, epochMs: epochMs) }
        func chmod(at path: String, mode: UInt16) async throws { try await inner.chmod(at: path, mode: mode) }
    }

    @Test("Watcher.Service shares equivalent subscriptions, buffers onReady events, and releases exactly once")
    func watcherServiceSharedLifecycle() async {
        // 1. Equivalent entry sets share ONE native subscription and release once after final consumer ends.
        let native = CountingNative()
        let watcher = CoreFilesystem.Watcher.Service(enabled: true, native: native)

        let stream1 = await watcher.subscribe(.entries(path: "/shared", names: ["opencode.json", ".opencode", "opencode.json"]), onReady: nil)
        let stream2 = await watcher.subscribe(.entries(path: "/shared", names: [".opencode", "opencode.json"]), onReady: nil)
        let task1 = Task { for await _ in stream1 {} }
        let task2 = Task { for await _ in stream2 {} }

        #expect(native.counts.withLock { $0.subscribes } == 1)
        #expect(native.counts.withLock { $0.unsubscribes } == 0)

        task1.cancel()
        await task1.value
        try? await Task.sleep(for: .milliseconds(25))
        #expect(native.counts.withLock { $0.unsubscribes } == 0)

        task2.cancel()
        await task2.value
        for _ in 0..<40 where native.counts.withLock({ $0.unsubscribes }) == 0 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(native.counts.withLock { $0.subscribes } == 1)
        #expect(native.counts.withLock { $0.unsubscribes } == 1)

        // 2. onReady runs after acquisition and buffers events published inside onReady.
        let readyCount = Mutex(0)
        let stream3 = await watcher.subscribe(
            .entries(path: "/ready", names: ["opencode.json"]),
            onReady: {
                readyCount.withLock { $0 += 1 }
                let cb = native.counts.withLock { $0.publishCallbacks.last }
                cb?(CoreFilesystem.Watcher.Update(path: "/ready/opencode.json", type: .create))
            }
        )
        #expect(readyCount.withLock { $0 } == 1)
        var firstEvent: CoreFilesystem.Watcher.Update?
        for await ev in stream3 {
            firstEvent = ev
            break
        }
        #expect(firstEvent == CoreFilesystem.Watcher.Update(path: "/ready/opencode.json", type: .create))

        // 3. close() releases an active subscription exactly once even while a consumer holds a reference.
        let closeNative = CountingNative()
        let closeWatcher = CoreFilesystem.Watcher.Service(enabled: true, native: closeNative)
        let activeStream = await closeWatcher.subscribe(.directory(path: "/active", ignore: []), onReady: nil)
        let activeConsumer = Task { for await _ in activeStream {} }
        #expect(closeNative.counts.withLock { $0.subscribes } == 1)
        #expect(closeNative.counts.withLock { $0.unsubscribes } == 0)
        await closeWatcher.close()
        await activeConsumer.value
        try? await Task.sleep(for: .milliseconds(25))
        #expect(closeNative.counts.withLock { $0.unsubscribes } == 1)
        await watcher.close()

        // 4. Unavailable native watch does not invoke onReady.
        let unavailNative = CountingNative(unavailable: true)
        let unavailWatcher = CoreFilesystem.Watcher.Service(enabled: true, native: unavailNative)
        let unavailReady = Mutex(0)
        let unavailStream = await unavailWatcher.subscribe(.directory(path: "/missing", ignore: [])) {
            unavailReady.withLock { $0 += 1 }
        }
        var count = 0
        for await _ in unavailStream { count += 1 }
        #expect(count == 0)
        #expect(unavailReady.withLock { $0 } == 0)
    }

    @Test("FileWatch recovers after a dead native watch and evicts the soonest-expiring watch at MAX_PER_LOCATION")
    func fileWatchDeadRecoveryAndEviction() async throws {
        // 1. Dead watch (native returns nil -> stream ends immediately) is forgotten so next watch() resubscribes.
        let failingNative = CountingNative(unavailable: true)
        let failingWatcher = CoreFilesystem.Watcher.Service(enabled: true, native: failingNative)
        let fwDead = CoreFilesystem.FileWatch.Service(
            enabled: true,
            watcher: failingWatcher,
            fileSystem: InMemoryFileSystem(),
            sweepIntervalMs: 0
        )
        let loc = LocationSchema.Ref(directory: SchemaPrimitive.AbsolutePath(rawValue: "/project"))
        try await fwDead.watch(CoreFilesystem.FileWatch.Input(location: loc, file: "/project/a.ts"))
        for _ in 0..<40 where failingNative.counts.withLock({ $0.subscribes }) < 1 {
            try? await Task.sleep(for: .milliseconds(5))
        }
        try? await Task.sleep(for: .milliseconds(25))
        try await fwDead.watch(CoreFilesystem.FileWatch.Input(location: loc, file: "/project/a.ts"))
        #expect(failingNative.counts.withLock { $0.subscribes } == 2)
        await fwDead.close()

        // 2. MAX_PER_LOCATION evicts the oldest/soonest-expiring watch and cancels its subscription.
        let clockMs = Mutex<Int64>(1_000_000)
        let testWatcher = CoreFilesystem.Watcher.Test()
        let fw = CoreFilesystem.FileWatch.Service(
            enabled: true,
            watcher: testWatcher,
            fileSystem: InMemoryFileSystem(),
            nowMs: { clockMs.withLock { $0 } },
            sweepIntervalMs: 0
        )
        try await fw.watch(CoreFilesystem.FileWatch.Input(location: loc, file: "/project/oldest.ts"))
        clockMs.withLock { $0 += 60_000 }
        for idx in 0..<(CoreFilesystem.FileWatch.MAX_PER_LOCATION - 1) {
            try await fw.watch(CoreFilesystem.FileWatch.Input(location: loc, file: "/project/\(idx).ts"))
        }
        let otherLoc = LocationSchema.Ref(directory: SchemaPrimitive.AbsolutePath(rawValue: "/other"))
        try await fw.watch(CoreFilesystem.FileWatch.Input(location: otherLoc, file: "/other/a.ts"))
        #expect(await testWatcher.subscriptions().count == CoreFilesystem.FileWatch.MAX_PER_LOCATION + 1)

        // Adding newest.ts evicts oldest.ts; re-watching 0.ts reuses its slot, re-watching oldest.ts creates a new watch.
        try await fw.watch(CoreFilesystem.FileWatch.Input(location: loc, file: "/project/newest.ts"))
        try await fw.watch(CoreFilesystem.FileWatch.Input(location: loc, file: "/project/0.ts"))
        #expect(await testWatcher.subscriptions().count == CoreFilesystem.FileWatch.MAX_PER_LOCATION + 2)
        try await fw.watch(CoreFilesystem.FileWatch.Input(location: loc, file: "/project/oldest.ts"))
        #expect(await testWatcher.subscriptions().count == CoreFilesystem.FileWatch.MAX_PER_LOCATION + 3)
        await fw.close()
    }

    @Test("Instruction.Loader matches upstream CLAUDE.md fallback, candidate boundaries, EPERM/NotFound isolation, and URL concurrency 4")
    func instructionLoaderUpstreamInvariants() async throws {
        // 1. Candidate subscriptions stop at project root outside home, and CLAUDE.md stands in when AGENTS.md is absent.
        let fs = InMemoryFileSystem(initialFiles: [
            "/home/.claude/CLAUDE.md": Array("claude global".utf8),
            "/scratch/repo/AGENTS.md": Array("project agents".utf8),
            "/scratch/repo/CLAUDE.md": Array("project claude".utf8),
            "/scratch/repo/packages/core/CLAUDE.md": Array("package claude".utf8),
            "/scratch/AGENTS.md": Array("outside".utf8),
        ])
        let testWatcher = CoreFilesystem.Watcher.Test()
        let discovery = CoreInstruction.Discovery.Service(options: CoreInstruction.Discovery.Options(project: true, global: true, claude: true))
        let loader = CoreConfigPlugin.Instruction.Loader(
            discovery: discovery,
            paths: CoreConfigPlugin.Instruction.Loader.Paths(
                directory: "/scratch/repo/packages/core",
                projectDirectory: "/scratch/repo",
                home: "/home",
                globalConfig: "/global"
            ),
            fileSystem: fs,
            watcher: testWatcher,
            entries: { [] },
            debounce: .milliseconds(20)
        )
        await loader.start()
        defer { Task { await loader.close() } }

        let subs = await testWatcher.subscriptions()
        #expect(subs == [
            .file(path: "/global/AGENTS.md"),
            .file(path: "/home/.claude/CLAUDE.md"),
            .file(path: "/scratch/repo/packages/core/AGENTS.md"),
            .file(path: "/scratch/repo/packages/core/CLAUDE.md"),
            .file(path: "/scratch/repo/packages/AGENTS.md"),
            .file(path: "/scratch/repo/packages/CLAUDE.md"),
            .file(path: "/scratch/repo/AGENTS.md"),
            .file(path: "/scratch/repo/CLAUDE.md"),
        ])
        let listed = await discovery.list()
        #expect(listed == .files([
            CoreInstruction.Discovery.File(path: "/home/.claude/CLAUDE.md", content: "claude global"),
            CoreInstruction.Discovery.File(path: "/scratch/repo/packages/core/CLAUDE.md", content: "package claude"),
            CoreInstruction.Discovery.File(path: "/scratch/repo/AGENTS.md", content: "project agents"),
        ]))

        // 2. EPERM skips denied file while keeping readable files; racing NotFound marks discovery unavailable.
        let sandboxFS = SandboxedFileSystem(
            inner: InMemoryFileSystem(initialFiles: [
                "/repo/AGENTS.md": Array("root".utf8),
                "/repo/packages/AGENTS.md": Array("package".utf8),
            ]),
            deniedPaths: ["/repo/AGENTS.md"]
        )
        let sandboxDiscovery = CoreInstruction.Discovery.Service(options: CoreInstruction.Discovery.Options(project: true, global: false, claude: false))
        let sandboxLoader = CoreConfigPlugin.Instruction.Loader(
            discovery: sandboxDiscovery,
            paths: CoreConfigPlugin.Instruction.Loader.Paths(
                directory: "/repo/packages",
                projectDirectory: "/repo",
                home: "/home",
                globalConfig: "/global"
            ),
            fileSystem: sandboxFS,
            entries: { [] }
        )
        await sandboxLoader.start()
        #expect(await sandboxDiscovery.list() == .files([
            CoreInstruction.Discovery.File(path: "/repo/packages/AGENTS.md", content: "package"),
        ]))
        await sandboxLoader.close()

        let racingFS = SandboxedFileSystem(
            inner: InMemoryFileSystem(initialFiles: [
                "/repo/AGENTS.md": Array("vanished".utf8),
            ]),
            vanishPaths: ["/repo/AGENTS.md"]
        )
        let racingDiscovery = CoreInstruction.Discovery.Service(options: CoreInstruction.Discovery.Options(project: true, global: false, claude: false))
        let racingLoader = CoreConfigPlugin.Instruction.Loader(
            discovery: racingDiscovery,
            paths: CoreConfigPlugin.Instruction.Loader.Paths(
                directory: "/repo",
                projectDirectory: "/repo",
                home: "/home",
                globalConfig: "/global"
            ),
            fileSystem: racingFS,
            entries: { [] }
        )
        await racingLoader.start()
        #expect(await racingDiscovery.list() == .unavailable)
        await racingLoader.close()

        // 3. Configured URL fetches cap concurrency at 4 (upstream `{ concurrency: 4 }`).
        let urls = (1...6).map { "https://example.test/doc-\($0).md" }
        let http = ConcurrencyTrackingHTTP(delay: .milliseconds(40))
        let urlDiscovery = CoreInstruction.Discovery.Service(options: CoreInstruction.Discovery.Options(project: false, global: false, claude: false))
        let urlLoader = CoreConfigPlugin.Instruction.Loader(
            discovery: urlDiscovery,
            paths: CoreConfigPlugin.Instruction.Loader.Paths(
                directory: "/repo",
                projectDirectory: "/repo",
                home: "/home",
                globalConfig: "/global"
            ),
            fileSystem: InMemoryFileSystem(),
            http: http,
            entries: {
                [.document(ConfigSchema.Document(path: nil, info: ConfigSchema.Info(instructions: urls)))]
            }
        )
        await urlLoader.start()
        defer { Task { await urlLoader.close() } }
        let httpState = http.state.withLock { $0 }
        #expect(httpState.requests.count == 6)
        #expect(httpState.maxActive <= 4)
        #expect(httpState.maxActive >= 2)
        if case .files(let files) = await urlDiscovery.list() {
            #expect(files.map(\.path) == urls)
        } else {
            Issue.record("Expected 6 remote instruction files")
        }
    }
}
