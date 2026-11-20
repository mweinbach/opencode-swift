import Synchronization
import Testing
@testable import OpenCodePlatform

private final class CollectedEvents: Sendable {
    private let events = Mutex<[NativeFileEvent]>([])
    private let streamFinished = Mutex<Bool>(false)

    func append(_ event: NativeFileEvent) {
        events.withLock { $0.append(event) }
    }

    func markFinished() {
        streamFinished.withLock { $0 = true }
    }

    var isFinished: Bool {
        streamFinished.withLock { $0 }
    }

    var all: [NativeFileEvent] {
        events.withLock { $0 }
    }

    func count(matching predicate: (NativeFileEvent) -> Bool) -> Int {
        events.withLock { list in
            list.reduce(into: 0) { count, event in
                if predicate(event) { count += 1 }
            }
        }
    }

    func waitFor(
        timeoutMs: Int = 3_000,
        matching predicate: @Sendable (NativeFileEvent) -> Bool
    ) async -> NativeFileEvent? {
        let stepMs = 15
        let attempts = max(1, timeoutMs / stepMs)
        for _ in 0..<attempts {
            if let match = events.withLock({ $0.first(where: predicate) }) {
                return match
            }
            try? await Task.sleep(for: .milliseconds(stepMs))
        }
        return events.withLock { $0.first(where: predicate) }
    }

    func waitUntilFinished(timeoutMs: Int = 2_000) async -> Bool {
        let stepMs = 10
        let attempts = max(1, timeoutMs / stepMs)
        for _ in 0..<attempts {
            if isFinished { return true }
            try? await Task.sleep(for: .milliseconds(stepMs))
        }
        return isFinished
    }
}

@Suite("NativeFileWatcher Tests")
struct NativeFileWatcherTests {

    @Test("Backend selection and start() validation errors for missing or non-directory paths")
    func backendMetadataAndValidationErrors() throws {
        #if os(macOS)
        #expect(NativeFileWatcher.backend == .fsEvents)
        #expect(NativeFileWatcher.isNativelySupported == true)
        #expect(NativeFileWatcher.isSupported == true)
        #elseif os(Linux) || os(Android)
        #expect(NativeFileWatcher.backend == .inotify)
        #expect(NativeFileWatcher.isNativelySupported == true)
        #expect(NativeFileWatcher.isSupported == true)
        #elseif os(Windows)
        #expect(NativeFileWatcher.backend == .windows)
        #expect(NativeFileWatcher.isNativelySupported == true)
        #expect(NativeFileWatcher.isSupported == true)
        #elseif os(iOS) || os(tvOS) || os(watchOS) || os(visionOS) || os(FreeBSD) || os(OpenBSD)
        #expect(NativeFileWatcher.backend == .kqueue)
        #expect(NativeFileWatcher.isNativelySupported == true)
        #expect(NativeFileWatcher.isSupported == true)
        #elseif os(WASI)
        #if canImport(WASILibc)
        #expect(NativeFileWatcher.backend == .polling)
        #expect(NativeFileWatcher.isNativelySupported == false)
        #expect(NativeFileWatcher.isSupported == true)
        #else
        #expect(NativeFileWatcher.backend == .fallback)
        #expect(NativeFileWatcher.isNativelySupported == false)
        #expect(NativeFileWatcher.isSupported == false)
        #endif
        #else
        #expect(NativeFileWatcher.backend == .polling)
        #expect(NativeFileWatcher.isNativelySupported == false)
        #expect(NativeFileWatcher.isSupported == true)
        #endif

        #if os(macOS) || os(Linux) || os(Windows)
        let dir = try NativeFileWatcherHelper.makeTempDirectory(prefix: "opencode-watcher-err")
        defer { NativeFileWatcherHelper.removeItemIfExists(at: dir) }

        let missingPath = "\(dir)/does-not-exist"
        let missingWatcher = NativeFileWatcher(path: missingPath)
        #expect(throws: NativeFileWatcherError.self) {
            try missingWatcher.start()
        }
        #expect(!missingWatcher.isRunning)

        let regularFile = "\(dir)/plain.txt"
        try NativeFileWatcherHelper.writeFileInPlace("content", to: regularFile)
        let fileWatcher = NativeFileWatcher(path: regularFile)
        #expect(throws: NativeFileWatcherError.self) {
            try fileWatcher.start()
        }
        #expect(!fileWatcher.isRunning)
        #endif
    }

    @Test("Built-in ignore filter skips .git, node_modules, .build, .swiftpm and caller globs/subpaths")
    func ignoreFilterRules() throws {
        let dir = try NativeFileWatcherHelper.makeTempDirectory(prefix: "opencode-watcher-ignore")
        defer { NativeFileWatcherHelper.removeItemIfExists(at: dir) }

        let watcher = NativeFileWatcher(
            path: dir,
            ignore: ["dist", "sub/secret", "**/*.log", "*.tmp"]
        )

        // Built-in defaults at top level and nested depths
        #expect(watcher.isIgnored(".git/HEAD"))
        #expect(watcher.isIgnored("sub/.git/objects/ab"))
        #expect(watcher.isIgnored("node_modules/pkg/index.js"))
        #expect(watcher.isIgnored("packages/web/node_modules/react/index.js"))
        #expect(watcher.isIgnored(".build/debug/opencode"))
        #expect(watcher.isIgnored("Packages/OpenTUI/.build/release/lib.a"))
        #expect(watcher.isIgnored(".swiftpm/xcode/package.xcworkspace"))
        #expect(watcher.isIgnored("\(dir)/.git/config"))
        #expect(watcher.isIgnored("\(dir)/node_modules/foo/bar.js"))

        // Caller literal subpaths and globs
        #expect(watcher.isIgnored("dist"))
        #expect(watcher.isIgnored("dist/app.js"))
        #expect(watcher.isIgnored("sub/secret/key.pem"))
        #expect(watcher.isIgnored("logs/debug.log"))
        #expect(watcher.isIgnored("scratch.tmp"))

        // Allowed normal paths
        #expect(!watcher.isIgnored("Sources/App.swift"))
        #expect(!watcher.isIgnored("README.md"))
        #expect(!watcher.isIgnored("git_notes.txt"))
        #expect(!watcher.isIgnored("sub/public/info.txt"))
        #expect(!watcher.isIgnored("\(dir)/Sources/App.swift"))

        // Opting out of default ignores permits direct .git watching (e.g. .git/HEAD)
        let noDefaults = NativeFileWatcher(path: dir, includeDefaultIgnores: false)
        #expect(!noDefaults.isIgnored(".git/HEAD"))
        #expect(!noDefaults.isIgnored("node_modules/a.js"))
    }

    @Test("Event coalescer merges rapid bursts cleanly while preserving deterministic order")
    func eventCoalescerTransitions() {
        var coalescer = NativeFileEventCoalescer()

        // created + modified -> created
        coalescer.push(NativeFileEvent(path: "/w/a.txt", kind: .created))
        coalescer.push(NativeFileEvent(path: "/w/a.txt", kind: .modified))

        // modified + modified -> modified
        coalescer.push(NativeFileEvent(path: "/w/b.txt", kind: .modified))
        coalescer.push(NativeFileEvent(path: "/w/b.txt", kind: .modified))

        // created + deleted -> transient cancel out (dropped)
        coalescer.push(NativeFileEvent(path: "/w/temp.txt", kind: .created))
        coalescer.push(NativeFileEvent(path: "/w/temp.txt", kind: .deleted))

        // modified + deleted -> deleted
        coalescer.push(NativeFileEvent(path: "/w/c.txt", kind: .modified))
        coalescer.push(NativeFileEvent(path: "/w/c.txt", kind: .deleted))

        // deleted + created -> modified
        coalescer.push(NativeFileEvent(path: "/w/d.txt", kind: .deleted))
        coalescer.push(NativeFileEvent(path: "/w/d.txt", kind: .created))

        // renamed + modified -> renamed
        coalescer.push(NativeFileEvent(path: "/w/e.txt", kind: .renamed))
        coalescer.push(NativeFileEvent(path: "/w/e.txt", kind: .modified))

        let drained = coalescer.drain()
        #expect(drained == [
            NativeFileEvent(path: "/w/a.txt", kind: .created),
            NativeFileEvent(path: "/w/b.txt", kind: .modified),
            NativeFileEvent(path: "/w/c.txt", kind: .deleted),
            NativeFileEvent(path: "/w/d.txt", kind: .modified),
            NativeFileEvent(path: "/w/e.txt", kind: .renamed),
        ])
        #expect(coalescer.isEmpty)
        #expect(coalescer.drain().isEmpty)
    }

    @Test("End-to-end live OS watch delivers created, modified, renamed, and deleted events")
    func liveCreateModifyRenameDelete() async throws {
        #if os(macOS) || os(Linux) || os(Windows)
        let dir = try NativeFileWatcherHelper.makeTempDirectory(prefix: "opencode-watcher-crud")
        defer { NativeFileWatcherHelper.removeItemIfExists(at: dir) }

        let watcher = NativeFileWatcher(path: dir, coalesceIntervalMs: 15)
        let collector = CollectedEvents()
        let stream = watcher.events

        let consumer = Task {
            for await event in stream {
                collector.append(event)
            }
            collector.markFinished()
        }

        try watcher.start()
        defer {
            watcher.stop()
            consumer.cancel()
        }
        #expect(watcher.isRunning)

        let fileA = "\(watcher.path)/alpha.txt"
        let fileB = "\(watcher.path)/beta.txt"

        // 1. Create
        try NativeFileWatcherHelper.writeFileInPlace("hello v1", to: fileA)
        let created = await collector.waitFor { $0.path == fileA && $0.kind == .created }
        #expect(created == NativeFileEvent(path: fileA, kind: .created, isDirectory: false))

        // 2. Modify in place
        try NativeFileWatcherHelper.writeFileInPlace("hello v2 updated content", to: fileA)
        let modified = await collector.waitFor { $0.path == fileA && $0.kind == .modified }
        #expect(modified == NativeFileEvent(path: fileA, kind: .modified, isDirectory: false))

        // 3. Rename alpha.txt -> beta.txt
        try NativeFileWatcherHelper.renameItem(from: fileA, to: fileB)
        let renamed = await collector.waitFor { $0.path == fileB && $0.kind == .renamed }
        #expect(renamed == NativeFileEvent(path: fileB, kind: .renamed, isDirectory: false))
        let movedAway = await collector.waitFor { $0.path == fileA && $0.kind == .deleted }
        #expect(movedAway == NativeFileEvent(path: fileA, kind: .deleted, isDirectory: false))

        // 4. Delete beta.txt
        try NativeFileWatcherHelper.deleteFile(at: fileB)
        let deleted = await collector.waitFor { $0.path == fileB && $0.kind == .deleted }
        #expect(deleted == NativeFileEvent(path: fileB, kind: .deleted, isDirectory: false))

        // 5. Clean teardown finishes stream
        watcher.stop()
        #expect(!watcher.isRunning)
        #expect(await collector.waitUntilFinished())
        await consumer.value
        #endif
    }

    @Test("End-to-end live OS watch monitors nested subdirectories recursively and respects recursive=false")
    func liveNestedSubdirectoriesAndNonRecursiveMode() async throws {
        #if os(macOS) || os(Linux) || os(Windows)
        let dir = try NativeFileWatcherHelper.makeTempDirectory(prefix: "opencode-watcher-nested")
        defer { NativeFileWatcherHelper.removeItemIfExists(at: dir) }

        // Recursive watcher catches newly created nested directories and files inside them
        let recursiveWatcher = NativeFileWatcher(path: dir, recursive: true, coalesceIntervalMs: 15)
        let recursiveCollector = CollectedEvents()
        let recursiveStream = recursiveWatcher.events
        let recursiveTask = Task {
            for await event in recursiveStream {
                recursiveCollector.append(event)
            }
            recursiveCollector.markFinished()
        }

        try recursiveWatcher.start()
        defer {
            recursiveWatcher.stop()
            recursiveTask.cancel()
        }

        let nestedDir = "\(recursiveWatcher.path)/level1/level2"
        let leafFile = "\(nestedDir)/leaf.swift"
        try NativeFileWatcherHelper.createDirectory(at: nestedDir)
        try NativeFileWatcherHelper.writeFileInPlace("let x = 1\n", to: leafFile)

        let leafCreated = await recursiveCollector.waitFor {
            $0.path == leafFile && ($0.kind == .created || $0.kind == .modified)
        }
        #expect(leafCreated != nil)

        try NativeFileWatcherHelper.writeFileInPlace("let x = 2\n", to: leafFile)
        let leafModified = await recursiveCollector.waitFor {
            $0.path == leafFile && $0.kind == .modified
        }
        #expect(leafModified != nil)

        try NativeFileWatcherHelper.deleteFile(at: leafFile)
        let leafDeleted = await recursiveCollector.waitFor {
            $0.path == leafFile && $0.kind == .deleted
        }
        #expect(leafDeleted != nil)

        recursiveWatcher.stop()
        #expect(await recursiveCollector.waitUntilFinished())
        await recursiveTask.value

        // Non-recursive watcher reports direct children but ignores deeper nested paths
        let shallowWatcher = NativeFileWatcher(path: dir, recursive: false, coalesceIntervalMs: 15)
        let shallowCollector = CollectedEvents()
        let shallowStream = shallowWatcher.events
        let shallowTask = Task {
            for await event in shallowStream {
                shallowCollector.append(event)
            }
            shallowCollector.markFinished()
        }

        try shallowWatcher.start()
        defer {
            shallowWatcher.stop()
            shallowTask.cancel()
        }

        let deepFile = "\(nestedDir)/deep-only.txt"
        let topFile = "\(shallowWatcher.path)/top-level.txt"
        try NativeFileWatcherHelper.writeFileInPlace("deep", to: deepFile)
        try NativeFileWatcherHelper.writeFileInPlace("top", to: topFile)

        let topEvent = await shallowCollector.waitFor { $0.path == topFile }
        #expect(topEvent != nil)
        try? await Task.sleep(for: .milliseconds(80))
        #expect(shallowCollector.count { $0.path == deepFile } == 0)

        shallowWatcher.stop()
        #expect(await shallowCollector.waitUntilFinished())
        await shallowTask.value
        #endif
    }

    @Test("End-to-end live OS watch filters ignored .git, node_modules, .build, .swiftpm, and custom globs")
    func liveIgnoredPathsNeverEmitEvents() async throws {
        #if os(macOS) || os(Linux) || os(Windows)
        let dir = try NativeFileWatcherHelper.makeTempDirectory(prefix: "opencode-watcher-filter")
        defer { NativeFileWatcherHelper.removeItemIfExists(at: dir) }

        try NativeFileWatcherHelper.createDirectory(at: "\(dir)/.git")
        try NativeFileWatcherHelper.createDirectory(at: "\(dir)/node_modules/pkg")
        try NativeFileWatcherHelper.createDirectory(at: "\(dir)/.build/debug")
        try NativeFileWatcherHelper.createDirectory(at: "\(dir)/.swiftpm")
        try NativeFileWatcherHelper.createDirectory(at: "\(dir)/dist")
        try NativeFileWatcherHelper.createDirectory(at: "\(dir)/src")

        let watcher = NativeFileWatcher(
            path: dir,
            ignore: ["dist", "**/*.tmp"],
            coalesceIntervalMs: 15
        )
        let collector = CollectedEvents()
        let stream = watcher.events
        let consumer = Task {
            for await event in stream {
                collector.append(event)
            }
            collector.markFinished()
        }

        try watcher.start()
        defer {
            watcher.stop()
            consumer.cancel()
        }

        // Trigger mutations across all ignored locations
        try NativeFileWatcherHelper.writeFileInPlace("ref: refs/heads/main\n", to: "\(watcher.path)/.git/HEAD")
        try NativeFileWatcherHelper.writeFileInPlace("module.exports = {}\n", to: "\(watcher.path)/node_modules/pkg/index.js")
        try NativeFileWatcherHelper.writeFileInPlace("obj", to: "\(watcher.path)/.build/debug/main.o")
        try NativeFileWatcherHelper.writeFileInPlace("{}", to: "\(watcher.path)/.swiftpm/config.json")
        try NativeFileWatcherHelper.writeFileInPlace("bundle", to: "\(watcher.path)/dist/out.js")
        try NativeFileWatcherHelper.writeFileInPlace("temp", to: "\(watcher.path)/src/scratch.tmp")

        // Trigger a visible non-ignored file mutation as our synchronization sentinel
        let visibleFile = "\(watcher.path)/src/visible.swift"
        try NativeFileWatcherHelper.writeFileInPlace("public struct Visible {}\n", to: visibleFile)

        let visibleEvent = await collector.waitFor { $0.path == visibleFile }
        #expect(visibleEvent != nil)

        // Allow any straggler ignored events a chance to arrive if filtering were broken
        try? await Task.sleep(for: .milliseconds(80))

        let received = collector.all
        #expect(!received.isEmpty)
        for event in received {
            #expect(!event.path.contains("/.git/"))
            #expect(!event.path.contains("/node_modules/"))
            #expect(!event.path.contains("/.build/"))
            #expect(!event.path.contains("/.swiftpm/"))
            #expect(!event.path.contains("/dist/"))
            #expect(!event.path.hasSuffix(".tmp"))
        }

        watcher.stop()
        #expect(await collector.waitUntilFinished())
        await consumer.value
        #endif
    }

    @Test("End-to-end live OS watch coalesces rapid write bursts into minimal events")
    func liveRapidBurstCoalescing() async throws {
        #if os(macOS) || os(Linux) || os(Windows)
        let dir = try NativeFileWatcherHelper.makeTempDirectory(prefix: "opencode-watcher-burst")
        defer { NativeFileWatcherHelper.removeItemIfExists(at: dir) }

        let targetFile = "\(dir)/burst.txt"
        try NativeFileWatcherHelper.writeFileInPlace("seed", to: targetFile)

        let watcher = NativeFileWatcher(path: dir, coalesceIntervalMs: 60)
        let resolvedFile = "\(watcher.path)/burst.txt"
        let collector = CollectedEvents()
        let stream = watcher.events
        let consumer = Task {
            for await event in stream {
                collector.append(event)
            }
            collector.markFinished()
        }

        try watcher.start()
        defer {
            watcher.stop()
            consumer.cancel()
        }

        // Perform 25 rapid in-place writes in a tight burst
        for i in 1...25 {
            try NativeFileWatcherHelper.writeFileInPlace("burst-write-\(i)", to: resolvedFile)
        }

        let first = await collector.waitFor { $0.path == resolvedFile && $0.kind == .modified }
        #expect(first != nil)

        // Wait past coalesce window to confirm burst was compressed
        try? await Task.sleep(for: .milliseconds(120))
        let totalForFile = collector.count { $0.path == resolvedFile }
        #expect(totalForFile >= 1)
        #expect(totalForFile <= 5)

        watcher.stop()
        #expect(await collector.waitUntilFinished())
        await consumer.value
        #endif
    }

    @Test("Clean stop() teardown is idempotent, suppresses post-stop events, and handles re-entrant callback stop")
    func cleanStopTeardownAndReentrantSafety() async throws {
        #if os(macOS) || os(Linux) || os(Windows)
        let dir = try NativeFileWatcherHelper.makeTempDirectory(prefix: "opencode-watcher-stop")
        defer { NativeFileWatcherHelper.removeItemIfExists(at: dir) }

        // 1. Standard stop() teardown + post-stop silence + idempotent stop()
        let watcher = NativeFileWatcher(path: dir, coalesceIntervalMs: 15)
        let collector = CollectedEvents()
        let stream = watcher.events
        let consumer = Task {
            for await event in stream {
                collector.append(event)
            }
            collector.markFinished()
        }

        try watcher.start()
        #expect(watcher.isRunning)

        let beforeStopFile = "\(watcher.path)/before.txt"
        try NativeFileWatcherHelper.writeFileInPlace("before", to: beforeStopFile)
        #expect(await collector.waitFor { $0.path == beforeStopFile } != nil)

        watcher.stop()
        watcher.stop() // Idempotent second stop
        #expect(!watcher.isRunning)
        #expect(await collector.waitUntilFinished())
        await consumer.value

        let countAfterStop = collector.all.count
        try NativeFileWatcherHelper.writeFileInPlace("after", to: "\(watcher.path)/after.txt")
        try? await Task.sleep(for: .milliseconds(80))
        #expect(collector.all.count == countAfterStop)

        // Accessing events after stop() returns an immediately-finished stream
        var postStopEvents: [NativeFileEvent] = []
        for await ev in watcher.events {
            postStopEvents.append(ev)
        }
        #expect(postStopEvents.isEmpty)

        // 2. Re-entrant stop() called synchronously from inside onEvent must not deadlock
        let reentrantWatcher = NativeFileWatcher(path: dir, coalesceIntervalMs: 15)
        let callbackFired = Mutex<Bool>(false)
        let triggerFile = "\(reentrantWatcher.path)/trigger-reentrant.txt"
        try reentrantWatcher.start { event in
            if event.path == triggerFile {
                callbackFired.withLock { $0 = true }
                reentrantWatcher.stop()
            }
        }
        try NativeFileWatcherHelper.writeFileInPlace("go", to: triggerFile)

        var fired = false
        for _ in 0..<200 {
            if callbackFired.withLock({ $0 }) && !reentrantWatcher.isRunning {
                fired = true
                break
            }
            try? await Task.sleep(for: .milliseconds(15))
        }
        #expect(fired)
        #expect(!reentrantWatcher.isRunning)

        // 3. Repeated start/stop cycles leak zero resources
        for cycle in 0..<5 {
            let cycleWatcher = NativeFileWatcher(path: dir, coalesceIntervalMs: 10)
            let s = cycleWatcher.events
            let t = Task {
                for await _ in s {}
            }
            try cycleWatcher.start()
            try NativeFileWatcherHelper.writeFileInPlace("c-\(cycle)", to: "\(dir)/cycle-\(cycle).txt")
            cycleWatcher.stop()
            await t.value
            #expect(!cycleWatcher.isRunning)
        }
        #endif
    }

    @Test("kqueue driver delivers create, modify, rename, delete events and cleans up on stop")
    func kqueueDriverLiveLifecycle() async throws {
        #if canImport(Darwin) || os(FreeBSD) || os(OpenBSD)
        let dir = try NativeFileWatcherHelper.makeTempDirectory(prefix: "opencode-watcher-kqueue")
        defer { NativeFileWatcherHelper.removeItemIfExists(at: dir) }

        let watcher = NativeFileWatcher(
            configuration: NativeFileWatcher.Configuration(path: dir, recursive: true, coalesceIntervalMs: 15),
            driverOverride: .kqueue
        )
        let collector = CollectedEvents()
        let stream = watcher.events
        let consumer = Task {
            for await event in stream {
                collector.append(event)
            }
            collector.markFinished()
        }

        try watcher.start()
        defer {
            watcher.stop()
            consumer.cancel()
        }
        #expect(watcher.isRunning)

        let fileA = "\(watcher.path)/AGENTS.md"
        try NativeFileWatcherHelper.writeFileInPlace("v1", to: fileA)
        let created = await collector.waitFor { $0.path == fileA && $0.kind == .created }
        #expect(created != nil)

        try NativeFileWatcherHelper.writeFileInPlace("v2 updated content", to: fileA)
        let modified = await collector.waitFor { $0.path == fileA && $0.kind == .modified }
        #expect(modified != nil)

        let tmpFile = "\(watcher.path)/.AGENTS.tmp"
        try NativeFileWatcherHelper.writeFileInPlace("v3 atomic", to: tmpFile)
        try NativeFileWatcherHelper.renameItem(from: tmpFile, to: fileA)
        let replaced = await collector.waitFor { $0.path == fileA && ($0.kind == .renamed || $0.kind == .modified) }
        #expect(replaced != nil)

        try NativeFileWatcherHelper.deleteFile(at: fileA)
        let deleted = await collector.waitFor { $0.path == fileA && $0.kind == .deleted }
        #expect(deleted != nil)

        watcher.stop()
        #expect(!watcher.isRunning)
        #expect(await collector.waitUntilFinished())
        await consumer.value
        #endif
    }

    @Test("Polling fallback driver delivers create, modify, delete events, respects ignores, and stops cleanly")
    func pollingFallbackDriverLiveLifecycle() async throws {
        #if !os(WASI)
        let dir = try NativeFileWatcherHelper.makeTempDirectory(prefix: "opencode-watcher-poll")
        defer { NativeFileWatcherHelper.removeItemIfExists(at: dir) }

        let watcher = NativeFileWatcher(
            configuration: NativeFileWatcher.Configuration(
                path: dir,
                recursive: true,
                ignore: ["**/*.tmp"],
                coalesceIntervalMs: 0
            ),
            driverOverride: .polling(intervalMs: 25)
        )
        let collector = CollectedEvents()
        let stream = watcher.events
        let consumer = Task {
            for await event in stream {
                collector.append(event)
            }
            collector.markFinished()
        }

        try watcher.start()
        defer {
            watcher.stop()
            consumer.cancel()
        }
        #expect(watcher.isRunning)

        let fileA = "\(watcher.path)/AGENTS.md"
        let ignoredFile = "\(watcher.path)/scratch.tmp"
        try NativeFileWatcherHelper.writeFileInPlace("ignored", to: ignoredFile)
        try NativeFileWatcherHelper.writeFileInPlace("v1", to: fileA)
        let created = await collector.waitFor { $0.path == fileA && $0.kind == .created }
        #expect(created != nil)
        #expect(collector.count { $0.path == ignoredFile } == 0)

        try NativeFileWatcherHelper.writeFileInPlace("v2 longer content", to: fileA)
        let modified = await collector.waitFor { $0.path == fileA && $0.kind == .modified }
        #expect(modified != nil)

        try NativeFileWatcherHelper.deleteFile(at: fileA)
        let deleted = await collector.waitFor { $0.path == fileA && $0.kind == .deleted }
        #expect(deleted != nil)

        watcher.stop()
        #expect(!watcher.isRunning)
        #expect(await collector.waitUntilFinished())
        await consumer.value
        #endif
    }
}
