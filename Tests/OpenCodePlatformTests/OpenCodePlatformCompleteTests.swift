import Synchronization
import Testing
import OpenCodePlatform
import OpenCodeUtil

private struct MockProcessSpawner: ProcessSpawner {
    let handler: @Sendable (ProcessSpec) async throws -> ProcessOutput

    func run(_ spec: ProcessSpec) async throws -> ProcessOutput {
        try await handler(spec)
    }
}

private struct MockHTTPTransport: HTTPTransport {
    let handler: @Sendable (HTTPRequest) async throws -> HTTPResponse

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try await handler(request)
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStreamingResponse {
        let resp = try await handler(request)
        let body = resp.body
        let s = AsyncThrowingStream<[UInt8], Error> { cont in
            if !body.isEmpty { cont.yield(body) }
            cont.finish()
        }
        return HTTPStreamingResponse(head: resp.head, chunks: s)
    }
}

private struct AccessDeniedFileSystem: OpenCodeFileSystem {
    let error: PlatformError

    func readFile(at path: String) async throws -> [UInt8] { throw error }
    func writeFile(_ bytes: [UInt8], to path: String, createDirectories: Bool) async throws { throw error }
    func exists(at path: String) async -> Bool { false }
    func remove(at path: String) async throws { throw error }
    func realPath(at path: String) async throws -> String { throw error }
}

@Suite("OpenCodePlatform Complete Unit Tests")
struct OpenCodePlatformCompleteTests {

    // MARK: - BomFileIO

    @Test("BomFileIO readFile and syncFile preserve, add, remove, and collapse UTF-8 BOMs")
    func bomFileIO() async throws {
        let fs = InMemoryFileSystem(initialFiles: [
            "/plain.txt": Array("hello".utf8),
            "/with-bom.txt": [0xEF, 0xBB, 0xBF] + Array("hello".utf8),
            "/double-bom.txt": [0xEF, 0xBB, 0xBF, 0xEF, 0xBB, 0xBF] + Array("hi".utf8),
        ])

        let plain = try await BomFileIO.readFile(fs: fs, filepath: "/plain.txt")
        #expect(plain == BomSplitResult(bom: false, text: "hello"))

        let withBom = try await BomFileIO.readFile(fs: fs, filepath: "/with-bom.txt")
        #expect(withBom == BomSplitResult(bom: true, text: "hello"))

        // Add BOM to plain file
        let added = try await BomFileIO.syncFile(fs: fs, filepath: "/plain.txt", bom: true)
        #expect(added == "hello")
        #expect(Bom.has(try await fs.readFile(at: "/plain.txt")))

        // Strip BOM from file
        let stripped = try await BomFileIO.syncFile(fs: fs, filepath: "/with-bom.txt", bom: false)
        #expect(stripped == "hello")
        #expect(!Bom.has(try await fs.readFile(at: "/with-bom.txt")))

        // Collapse double BOM to single BOM
        let collapsed = try await BomFileIO.syncFile(fs: fs, filepath: "/double-bom.txt", bom: true)
        #expect(collapsed == "hi")
        #expect(try await fs.readFile(at: "/double-bom.txt") == [0xEF, 0xBB, 0xBF] + Array("hi".utf8))
    }

    // MARK: - FSUtil.Service

    @Test("FSUtil.Service handles dirs, files, JSON, safe reads, up/findUp/globUp/scan on InMemoryFileSystem")
    func fsUtilServiceComprehensive() async throws {
        let fs = InMemoryFileSystem(initialFiles: [
            "/repo/.git/HEAD": Array("ref: refs/heads/main\n".utf8),
            "/repo/package.json": Array("{\"name\":\"root\"}".utf8),
            "/repo/packages/app/package.json": Array("{\"name\":\"app\"}".utf8),
            "/repo/packages/app/src/index.ts": Array("export const x = 1\n".utf8),
            "/repo/packages/app/src/util.ts": Array("export const y = 2\n".utf8),
            "/repo/packages/app/src/.env": Array("SECRET=1\n".utf8),
            "/repo/packages/app/bad.json": Array("{broken".utf8),
        ])
        let svc = FSUtil.Service(fileSystem: fs)

        #expect(await svc.isDir("/repo/packages/app"))
        #expect(!(await svc.isDir("/repo/package.json")))
        #expect(await svc.isFile("/repo/package.json"))
        #expect(!(await svc.isFile("/repo/packages")))
        #expect(await svc.existsSafe("/repo/package.json"))
        #expect(!(await svc.existsSafe("/repo/missing")))

        // readFileStringSafe
        #expect(try await svc.readFileStringSafe("/repo/packages/app/src/index.ts") == "export const x = 1\n")
        #expect(try await svc.readFileStringSafe("/repo/does-not-exist.txt") == nil)

        // Access-denied vs fatal I/O errors
        let deniedSvc = FSUtil.Service(fileSystem: AccessDeniedFileSystem(error: .ioFailure("denied", code: "EPERM")))
        #expect(try await deniedSvc.readFileStringSafe("/secret") == nil)
        #expect(FSUtil.isAccessDenied(.permissionDenied("/x")))
        #expect(FSUtil.isAccessDenied(.ioFailure("x", code: "EPERM")))
        #expect(FSUtil.isAccessDenied(.ioFailure("x", code: "EACCES")))
        #expect(!FSUtil.isAccessDenied(.ioFailure("x", code: "EIO")))

        let ioErrSvc = FSUtil.Service(fileSystem: AccessDeniedFileSystem(error: .ioFailure("disk", code: "EIO")))
        await #expect(throws: FSUtil.FSError.self) {
            _ = try await ioErrSvc.readFileStringSafe("/broken")
        }

        // readJson & writeJson
        let parsed = try await svc.readJson("/repo/package.json")
        #expect(parsed == .object([("name", .string("root"))]))
        await #expect(throws: FSUtil.FSError.self) {
            _ = try await svc.readJson("/repo/packages/app/bad.json")
        }

        // ensureDir & writeJson & writeWithDirs
        try await svc.ensureDir("/repo/out/nested")
        try await svc.ensureDir("/repo/out/nested") // idempotent on existing dir
        #expect(await svc.isDir("/repo/out/nested"))
        try await svc.writeJson("/repo/out/nested/data.json", data: .object([("ok", .bool(true))]), mode: 0o600)
        #expect(try await svc.readJson("/repo/out/nested/data.json") == .object([("ok", .bool(true))]))

        try await svc.writeWithDirs("/repo/deep/a/b/hello.txt", content: Array("world".utf8), mode: 0o644)
        #expect(try await svc.readFileStringSafe("/repo/deep/a/b/hello.txt") == "world")

        // up (mode: all vs first, type: file vs directory, stop inclusive)
        let allPkgs = try await svc.up(FSPathUtil.UpOptions(targets: ["package.json"], start: "/repo/packages/app/src", stop: "/repo"))
        #expect(allPkgs == ["/repo/packages/app/package.json", "/repo/package.json"])

        let firstPkg = try await svc.up(FSPathUtil.UpOptions(targets: ["package.json"], start: "/repo/packages/app/src", stop: "/repo", mode: .first))
        #expect(firstPkg == ["/repo/packages/app/package.json"])

        let gitDirs = try await svc.up(FSPathUtil.UpOptions(targets: [".git"], start: "/repo/packages/app/src", stop: "/repo", type: .directory))
        #expect(gitDirs == ["/repo/.git"])

        let gitAsFile = try await svc.up(FSPathUtil.UpOptions(targets: [".git"], start: "/repo/packages/app/src", stop: "/repo", type: .file))
        #expect(gitAsFile.isEmpty)

        // findUp & globUp & scan
        let foundUp = try await svc.findUp(target: "package.json", start: "/repo/packages/app/src", stop: "/repo")
        #expect(foundUp == ["/repo/packages/app/package.json", "/repo/package.json"])

        let globbedUp = try await svc.globUp(pattern: "*.json", start: "/repo/packages/app", stop: "/repo")
        #expect(globbedUp == ["/repo/packages/app/bad.json", "/repo/packages/app/package.json", "/repo/package.json"])

        let scanned = try await svc.scan(pattern: "**/*.ts", options: Glob.Options(cwd: "/repo/packages/app"))
        #expect(scanned == ["src/index.ts", "src/util.ts"])
        #expect(svc.globMatch(pattern: "**/*.ts", filepath: "src/index.ts"))
    }

    // MARK: - Global & GlobalPaths.workerdRoots

    @Test("GlobalPaths.workerdRoots, Global.make, and Global.layerWith create directories cleanly")
    func globalAndWorkerdRoots() async throws {
        let env = DictionaryEnvironment(
            variables: ["XDG_CONFIG_HOME": "/custom/cfg"],
            homeDirectory: "/Users/dev",
            temporaryDirectory: "/tmp/sandbox/"
        )

        let workerd = GlobalPaths.workerdRoots(app: "opencode", environment: env)
        #expect(workerd == GlobalRoots(
            data: "/tmp/sandbox/opencode/data",
            cache: "/tmp/sandbox/opencode/cache",
            config: "/tmp/sandbox/opencode/config",
            state: "/tmp/sandbox/opencode/state",
            tmp: "/tmp/sandbox/opencode/tmp"
        ))

        let paths = Global.make(Global.Overrides(cache: "/fast/cache"), environment: env, os: .linux)
        #expect(paths.home == "/Users/dev")
        #expect(paths.config == "/custom/cfg/opencode")
        #expect(paths.cache == "/fast/cache")
        #expect(paths.bin == "/fast/cache/bin")
        #expect(paths.log == "/Users/dev/.local/share/opencode/log")
        #expect(paths.repos == "/Users/dev/.local/share/opencode/repos")

        let fs = InMemoryFileSystem()
        let layer = Global.layerWith(
            Global.Overrides(
                data: "/g/data",
                cache: "/g/cache",
                config: "/g/config",
                state: "/g/state",
                tmp: "/g/custom-tmp"
            ),
            fileSystem: fs,
            environment: env
        )
        let out = try await layer.build(LayerNode.Output(), LayerNode.ResourceScope())
        let service = try #require(out.get(Global.Service.serviceKey, as: Global.Service.self))
        #expect(service.paths.tmp == "/g/custom-tmp")
        for dir in ["/g/data", "/g/config", "/g/state", "/g/data/log", "/g/cache/bin", "/g/data/repos", "/g/custom-tmp"] {
            #expect(await fs.exists(at: dir))
        }
    }

    // MARK: - Flock & EffectFlock

    @Test("Flock and EffectFlock handle acquire, contention, timeout, abort, stale recovery, and compromised release")
    func flockAndEffectFlock() async throws {
        let fs = InMemoryFileSystem(initialClockMs: 10_000)
        let clock = Mutex<Int64>(10_000)
        let nowMs: @Sendable () -> Int64 = { clock.withLock { $0 } }

        // Basic acquire & release
        let lease1 = try await Flock.acquire("res-1", options: Flock.Options(dir: "/locks"), fileSystem: fs, nowMs: nowMs)
        let lockDir = "/locks/\(Hash.sha256("res-1")).lock"
        #expect(await fs.exists(at: lockDir))
        try await lease1.release()
        try await lease1.release() // idempotent
        #expect(!(await fs.exists(at: lockDir)))

        // withLock releases on error
        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            _ = try await Flock.withLock("res-err", options: Flock.Options(dir: "/locks"), fileSystem: fs) {
                throw Boom()
            }
        }
        #expect(!(await fs.exists(at: "/locks/\(Hash.sha256("res-err")).lock")))

        // Contention: second acquirer waits until first releases
        let held = try await Flock.acquire("contend", options: Flock.Options(dir: "/locks"), fileSystem: fs, nowMs: nowMs)
        let waitEvents = Mutex<[Flock.WaitEvent]>([])
        let releaser = Task {
            try? await Task.sleep(for: .milliseconds(30))
            try? await held.release()
        }
        let lease2 = try await Flock.acquire(
            "contend",
            options: Flock.Options(
                dir: "/locks",
                staleMs: 60_000,
                timeoutMs: 2_000,
                baseDelayMs: 10,
                maxDelayMs: 50,
                onWait: { ev in waitEvents.withLock { $0.append(ev) } }
            ),
            fileSystem: fs,
            nowMs: nowMs
        )
        await releaser.value
        #expect(!waitEvents.withLock { $0 }.isEmpty)
        try await lease2.release()

        // Timeout when held
        let heldTimeout = try await Flock.acquire("timeout-key", options: Flock.Options(dir: "/locks"), fileSystem: fs, nowMs: nowMs)
        await #expect(throws: EffectFlock.LockTimeoutError(key: "timeout-key")) {
            _ = try await Flock.acquire(
                "timeout-key",
                options: Flock.Options(dir: "/locks", staleMs: 60_000, timeoutMs: 0, baseDelayMs: 5),
                fileSystem: fs,
                nowMs: nowMs
            )
        }
        try await heldTimeout.release()

        // Pre-aborted signal rejects immediately
        let abortedSignal = AbortSignal.aborted()
        await #expect(throws: AbortError.self) {
            _ = try await Flock.acquire("abort-key", options: Flock.Options(dir: "/locks", signal: abortedSignal), fileSystem: fs, nowMs: nowMs)
        }

        // Stale lock recovery when clock advances past staleMs
        let staleLease = try await Flock.acquire("stale-key", options: Flock.Options(dir: "/locks", staleMs: 5_000), fileSystem: fs, nowMs: nowMs)
        clock.withLock { $0 = 20_000 }
        fs.setClockMs(20_000)
        let recovered = try await Flock.acquire("stale-key", options: Flock.Options(dir: "/locks", staleMs: 5_000, timeoutMs: 500, baseDelayMs: 10), fileSystem: fs, nowMs: nowMs)
        // Original holder sees LockCompromisedError on release because token changed
        await #expect(throws: EffectFlock.LockCompromisedError.self) {
            try await staleLease.release()
        }
        try await recovered.release()

        // EffectFlock.Service
        let effectFlock = EffectFlock.Service(lockRoot: "/elocks", fileSystem: fs)
        let computed = try await effectFlock.withLock(key: "svc-key") { 42 }
        #expect(computed == 42)
        #expect(!(await fs.exists(at: "/elocks/\(Hash.sha256("svc-key")).lock")))
    }

    // MARK: - AppProcess & CrossSpawnSpawner

    @Test("AppProcess requireSuccess, requireExitIn, collectStream, waitForAbort, run, and runStream")
    func appProcessComprehensive() async throws {
        // requireSuccess & requireExitIn
        let okRes = AppProcess.RunResult(command: "echo hi", exitCode: 0, stdout: Array("hi\n".utf8), stderr: [])
        let failRes = AppProcess.RunResult(command: "false", exitCode: 2, stdout: [], stderr: Array("  bad input \n".utf8))
        #expect(try AppProcess.requireSuccess(okRes) == okRes)
        do {
            _ = try AppProcess.requireSuccess(failRes)
            Issue.record("Expected AppProcessError")
        } catch let err as AppProcess.AppProcessError {
            #expect(err.exitCode == 2)
            #expect(err.message == "Command failed (exit 2): false: bad input")
        }

        let checkExit = AppProcess.requireExitIn([0, 2])
        #expect(try checkExit(failRes) == failRes)
        #expect(throws: AppProcess.AppProcessError.self) {
            _ = try AppProcess.requireExitIn([0, 1])(failRes)
        }

        // collectStream truncation
        let unlimited = AppProcess.collectStream([Array("abc".utf8), Array("def".utf8)], maxOutputBytes: nil)
        #expect(unlimited.buffer == Array("abcdef".utf8))
        #expect(!unlimited.truncated)

        let exactFit = AppProcess.collectStream([Array("abc".utf8), Array("de".utf8)], maxOutputBytes: 5)
        #expect(exactFit.buffer == Array("abcde".utf8))
        #expect(!exactFit.truncated)

        let truncated = AppProcess.collectStream([Array("abc".utf8), Array("defgh".utf8)], maxOutputBytes: 5)
        #expect(truncated.buffer == Array("abcde".utf8))
        #expect(truncated.truncated)

        let zeroCap = AppProcess.collectStream([Array("x".utf8)], maxOutputBytes: 0)
        #expect(zeroCap.buffer.isEmpty)
        #expect(zeroCap.truncated)

        // waitForAbort (pre-aborted and asynchronous abort)
        await #expect(throws: AbortError.self) {
            _ = try await AppProcess.waitForAbort(AbortSignal.aborted())
        }

        let controller = AbortController()
        let waiter = Task<Bool, Never> {
            do {
                _ = try await AppProcess.waitForAbort(controller.signal)
            } catch {
                return true
            }
        }
        try await Task.sleep(for: .milliseconds(15))
        abort(controller)
        #expect(await waiter.value)

        // AppProcess.Service with mock spawner
        let spawner = MockProcessSpawner { spec in
            ProcessOutput(
                exitCode: spec.arguments.contains("--fail") ? 1 : 0,
                stdout: Array("line1\nline2\n".utf8),
                stderr: Array("warn1\n".utf8)
            )
        }
        let service = AppProcess.Service(spawner: spawner)
        let combined = try await service.run(
            ProcessSpec(executable: "tool", arguments: ["arg"]),
            options: AppProcess.RunOptions(combineOutput: true, maxOutputBytes: 8)
        )
        #expect(combined.command == "tool arg")
        #expect(combined.output == Array("line1\nli".utf8))
        #expect(combined.outputTruncated == true)

        // Pre-aborted run rejects before spawning
        await #expect(throws: AppProcess.AppProcessError.self) {
            _ = try await service.run(
                ProcessSpec(executable: "tool"),
                options: AppProcess.RunOptions(signal: AbortSignal.aborted())
            )
        }

        // runStream yields lines & checks okExitCodes
        var lines: [String] = []
        for try await line in service.runStream(ProcessSpec(executable: "tool"), options: AppProcess.RunStreamOptions(includeStderr: true, okExitCodes: [0])) {
            lines.append(line)
        }
        #expect(lines == ["line1", "line2", "warn1"])

        var threwOnExit = false
        do {
            for try await _ in service.runStream(ProcessSpec(executable: "tool", arguments: ["--fail"]), options: AppProcess.RunStreamOptions(okExitCodes: [0])) {}
        } catch is AppProcess.AppProcessError {
            threwOnExit = true
        }
        #expect(threwOnExit)

        // CrossSpawnSpawner helpers & NUL validation
        #expect(CrossSpawnSpawner.RELEASE_FORCE_KILL_AFTER == "3 seconds")
        #expect(CrossSpawnSpawner.KilledBySignal(signal: "SIGTERM").message == "Process interrupted due to receipt of signal: 'SIGTERM'")
        await #expect(throws: PlatformError.self) {
            _ = try await CrossSpawnSpawner.HostProcessSpawner.shared.run(ProcessSpec(executable: "bad\u{0}cmd"))
        }
        await #expect(throws: PlatformError.self) {
            _ = try await CrossSpawnSpawner.HostProcessSpawner.shared.run(ProcessSpec(executable: "echo", arguments: ["bad\u{0}arg"]))
        }
    }

    // MARK: - OpenExternal

    @Test("OpenExternal validates http/https URLs and rejects unsafe schemes")
    func openExternalValidation() async throws {
        let opened = Mutex<[String]>([])
        let launcher: @Sendable (String) async throws -> Void = { target in
            opened.withLock { $0.append(target) }
        }

        try await OpenExternal.openUrl("https://opencode.ai/docs?x=1", launcher: launcher)
        try await OpenExternal.openUrl("http://localhost:4096/health", launcher: launcher)
        try await OpenExternal.openPath("/tmp/report.pdf", launcher: launcher)
        #expect(opened.withLock { $0 } == [
            "https://opencode.ai/docs?x=1",
            "http://localhost:4096/health",
            "/tmp/report.pdf",
        ])

        for rejected in [
            "",
            "not a url",
            "file:///etc/hosts",
            "javascript:alert(1)",
            "ms-msdt:/id PCWDiagnostic",
            "\\\\server\\share\\file.html",
            "ftp://example.com/file",
        ] {
            await #expect(throws: OpenExternal.InvalidURLError.self) {
                try await OpenExternal.openUrl(rejected, launcher: launcher)
            }
        }
    }

    // MARK: - NpmConfig & NpmPlatform

    @Test("NpmConfig reads .npmrc hierarchy and env registry, and NpmPlatform manages package cache")
    func npmConfigAndPlatform() async throws {
        let fs = InMemoryFileSystem(initialFiles: [
            "/home/alice/.npmrc": Array("# home config\nregistry=https://home.registry.test/\n@home:registry=https://scoped.home/\n".utf8),
            "/proj/.npmrc": Array("; project override\nregistry = https://project.registry.test/\n@acme:registry = https://npm.acme.test/\n".utf8),
        ])
        let env = DictionaryEnvironment(variables: [:], homeDirectory: "/home/alice")

        let cfg = await NpmConfig.load(dir: "/proj", fileSystem: fs, environment: env)
        #expect(cfg["registry"] == "https://project.registry.test/")
        #expect(cfg["@acme:registry"] == "https://npm.acme.test/")
        #expect(cfg["@home:registry"] == "https://scoped.home/")
        #expect(await NpmConfig.registry(dir: "/proj", fileSystem: fs, environment: env) == "https://project.registry.test")

        // Environment variable overrides .npmrc
        let envOverride = DictionaryEnvironment(
            variables: ["NPM_CONFIG_REGISTRY": "https://env.registry.test/"],
            homeDirectory: "/home/alice"
        )
        #expect(await NpmConfig.registry(dir: "/proj", fileSystem: fs, environment: envOverride) == "https://env.registry.test")

        // Fallback default registry when no .npmrc exists
        #expect(await NpmConfig.registry(dir: "/empty", fileSystem: InMemoryFileSystem(), environment: DictionaryEnvironment()) == "https://registry.npmjs.org")

        // NpmPlatform.Service
        let npmFs = InMemoryFileSystem()
        let npm = NpmPlatform.Service(cacheRoot: "/cache", fsUtil: FSUtil.Service(fileSystem: npmFs))
        let installed = try await npm.add("@acme/tool@1.0.0")
        #expect(installed.name == "@acme/tool")
        #expect(try await npm.check("@acme/tool@1.0.0"))

        // Generation directory resolution & which()
        let binPath = "/cache/npm/@acme/tool@1.0.0/2000/node_modules/.bin/tool"
        try await npmFs.writeFile([], to: binPath, createDirectories: true)
        let resolved = await npm.resolve("@acme/tool@1.0.0")
        #expect(resolved.directory == "/cache/npm/@acme/tool@1.0.0/2000")
        #expect(await npm.which("@acme/tool@1.0.0") == binPath)
        #expect(await npm.which("@acme/tool@1.0.0", bin: "missing") == nil)

        await #expect(throws: NpmSpec.InstallFailedError.self) {
            _ = try await npm.add("./local-not-installable")
        }
    }

    // MARK: - Logging, Otlp, Observability & NoTimeoutFetch

    @Test("Logging formats logfmt records, resolves paths, filters levels, and trims in-place at newline boundaries")
    func loggingComprehensive() async throws {
        #expect(Logging.file(local: false, channel: "beta", logDirectory: "/logs") == "/logs/opencode.log")
        #expect(Logging.file(local: true, channel: "feat/my branch", logDirectory: "/logs") == "/logs/opencode-feat-my-branch.log")

        let record = StructuredLogRecord(
            timestamp: "2026-06-15T12:00:00Z",
            level: .warn,
            message: "hello world",
            fields: [("service", "core"), ("note", "a=b"), ("empty", "")],
            cause: "disk full"
        )
        let line = Logging.formatRecord(record, runID: "abcd1234")
        #expect(line == "timestamp=2026-06-15T12:00:00Z level=Warn run=abcd1234 message=\"hello world\" cause=\"disk full\" service=core note=\"a=b\" empty=\"\"")

        // minimumLogLevel
        #expect(Logging.minimumLogLevel(environment: DictionaryEnvironment(variables: [:])) == .info)
        #expect(Logging.minimumLogLevel(environment: DictionaryEnvironment(variables: ["OPENCODE_LOG_LEVEL": "debug"])) == .debug)
        #expect(Logging.minimumLogLevel(environment: DictionaryEnvironment(variables: ["OPENCODE_LOG_LEVEL": "WARN"])) == .warn)
        #expect(Logging.minimumLogLevel(environment: DictionaryEnvironment(variables: ["OPENCODE_LOG_LEVEL": "ERROR"])) == .error)
        #expect(Logging.minimumLogLevel(environment: DictionaryEnvironment(variables: ["OPENCODE_LOG_LEVEL": "bogus"])) == .info)

        // fileLogger appends lines
        let fs = InMemoryFileSystem(initialClockMs: 1_000)
        let sink = Logging.fileLogger(target: "/logs/app.log", id: "run12345", fileSystem: fs)
        await sink.log(StructuredLogRecord(timestamp: "t1", level: .info, message: "first"))
        await sink.log(StructuredLogRecord(timestamp: "t2", level: .error, message: "second"))
        let logged = String(decoding: try await fs.readFile(at: "/logs/app.log"), as: UTF8.self)
        #expect(logged == "timestamp=t1 level=Info run=run12345 message=first\ntimestamp=t2 level=Error run=run12345 message=second\n")

        // trim: no-op under max, compacts in-place aligned to next newline over max
        let content = "line-001\nline-002\nline-003\nline-004\nline-005\n" // 45 bytes
        try await fs.writeFile(Array(content.utf8), to: "/logs/trim.log", createDirectories: true)

        try await Logging.trim(target: "/logs/trim.log", max: 100, keep: 20, fileSystem: fs)
        #expect(String(decoding: try await fs.readFile(at: "/logs/trim.log"), as: UTF8.self) == content)

        // cut = 45 - 20 = 25 (in the middle of "line-003\n"), next '\n' is index 26 -> keeps "line-004\nline-005\n"
        try await Logging.trim(target: "/logs/trim.log", max: 30, keep: 20, fileSystem: fs)
        #expect(String(decoding: try await fs.readFile(at: "/logs/trim.log"), as: UTF8.self) == "line-004\nline-005\n")
        #expect(!(await fs.exists(at: "/logs/trim.log.trim")))

        // Active fresh trim lock skips trimming; stale lock is broken
        try await fs.writeFile(Array(content.utf8), to: "/logs/trim2.log", createDirectories: true)
        try await fs.makeDirectory(at: "/logs/trim2.log.trim", recursive: false)
        try await Logging.trim(target: "/logs/trim2.log", max: 30, keep: 20, fileSystem: fs, nowMs: { 2_000 })
        #expect(String(decoding: try await fs.readFile(at: "/logs/trim2.log"), as: UTF8.self) == content)
        #expect(await fs.exists(at: "/logs/trim2.log.trim"))

        // Advance past LOG_TRIM_LOCK_STALE_MS: breaks stale lock on first pass, trims on next pass
        let futureMs: Int64 = 1_000 + Int64(Logging.LOG_TRIM_LOCK_STALE_MS) + 1
        try await Logging.trim(target: "/logs/trim2.log", max: 30, keep: 20, fileSystem: fs, nowMs: { futureMs })
        #expect(!(await fs.exists(at: "/logs/trim2.log.trim")))
        try await Logging.trim(target: "/logs/trim2.log", max: 30, keep: 20, fileSystem: fs, nowMs: { futureMs })
        #expect(String(decoding: try await fs.readFile(at: "/logs/trim2.log"), as: UTF8.self) == "line-004\nline-005\n")
    }

    @Test("Otlp parseHeaders, resource, loggers, tracingLayer, Observability.layer, and NoTimeoutFetch")
    func otlpObservabilityAndNoTimeoutFetch() async throws {
        // parseHeaders
        #expect(Otlp.parseHeaders(nil) == nil)
        #expect(Otlp.parseHeaders("") == nil)
        #expect(Otlp.parseHeaders("x-api-key=secret,Authorization=Basic abc==") == [
            "x-api-key": "secret",
            "Authorization": "Basic abc==",
        ])

        // resource attributes
        let env = DictionaryEnvironment(variables: [
            "OTEL_RESOURCE_ATTRIBUTES": "env=prod,team=platform%20core",
            "OPENCODE_LOG_LEVEL": "DEBUG",
        ])
        let res = Otlp.resource(
            app: Otlp.App(client: "cli", version: "2.3.0", channel: "stable"),
            environment: env,
            runID: "deadbeef"
        )
        #expect(res.serviceName == "opencode")
        #expect(res.serviceVersion == "2.3.0")
        #expect(res.attributes["env"] == "prod")
        #expect(res.attributes["team"] == "platform core")
        #expect(res.attributes["deployment.environment.name"] == "stable")
        #expect(res.attributes["opencode.client"] == "cli")
        #expect(res.attributes["opencode.run"] == "deadbeef")
        #expect(res.attributes["service.instance.id"] == "deadbeef")

        // Malformed OTEL_RESOURCE_ATTRIBUTES falls back to empty user attributes
        let badEnv = DictionaryEnvironment(variables: ["OTEL_RESOURCE_ATTRIBUTES": "invalid-no-equals"])
        let badRes = Otlp.resource(app: Otlp.App(), environment: badEnv, runID: "11223344")
        #expect(badRes.attributes["invalid-no-equals"] == nil)
        #expect(badRes.attributes["opencode.run"] == "11223344")

        // Otlp.loggers & Otlp.tracingLayer
        #expect(Otlp.loggers(options: nil, app: Otlp.App()).isEmpty)
        #expect(Otlp.loggers(options: Otlp.Options(endpoint: ""), app: Otlp.App()).isEmpty)

        let captured = Mutex<[HTTPRequest]>([])
        let transport = MockHTTPTransport { req in
            captured.withLock { $0.append(req) }
            return HTTPResponse(head: HTTPResponseHead(statusCode: 200), body: [])
        }
        let otlpSinks = Otlp.loggers(
            options: Otlp.Options(endpoint: "https://otel.example.test", headers: "x-token=abc"),
            app: Otlp.App(client: "test", version: "1.0.0", channel: "local"),
            transport: transport
        )
        #expect(otlpSinks.count == 1)
        #expect(otlpSinks[0].url == "https://otel.example.test/v1/logs")
        await otlpSinks[0].log(StructuredLogRecord(timestamp: "t", level: .info, message: "ping"))
        let sent = captured.withLock { $0 }
        #expect(sent.count == 1)
        #expect(sent[0].url == "https://otel.example.test/v1/logs")
        #expect(sent[0].headers["x-token"] == "abc")
        #expect(sent[0].headers["Content-Type"] == "application/json")

        let traceOut = try await Otlp.tracingLayer(
            options: Otlp.Options(endpoint: "https://otel.example.test"),
            app: Otlp.App()
        ).build(LayerNode.Output(), LayerNode.ResourceScope())
        #expect(traceOut.get("@opencode/OtlpTracing", as: String.self) == "https://otel.example.test/v1/traces:opencode")

        // Observability.layer
        let obsOut = try await Observability.layer(
            options: Observability.Options(endpoint: "https://otel.example.test", client: "cli", version: "1.0", channel: "local"),
            environment: env,
            fileSystem: InMemoryFileSystem()
        ).build(LayerNode.Output(), LayerNode.ResourceScope())
        let obsSvc = try #require(obsOut.get(Observability.Service.serviceKey, as: Observability.Service.self))
        #expect(obsSvc.minimumLevel == .debug)
        #expect(obsSvc.sinks.count == 2)

        // NoTimeoutFetch
        let fetchReq = HTTPRequest(method: "GET", url: "https://api.example.test/stream")
        _ = try await NoTimeoutFetch.noTimeoutFetch(fetchReq, transport: transport)
        #expect(captured.withLock { $0.last?.headers["X-OpenCode-No-Timeout"] } == "1")
    }

    // MARK: - RuntimeImport & HeapSnapshot

    @Test("RuntimeImport probes TS/JS extensions, handles node: built-ins, and rejects workerd dynamic loading")
    func runtimeImportAndHeapSnapshot() async throws {
        let fs = InMemoryFileSystem(initialFiles: [
            "/app/plugin.ts": Array("export default 1".utf8),
            "/app/legacy.cjs": Array("module.exports = 2".utf8),
            "/app/exact.mjs": Array("export const x = 3".utf8),
        ])

        #expect(try await RuntimeImport.resolveNodeModule(specifier: "node:fs", directory: "/app", fileSystem: fs) == "node:fs")
        #expect(try await RuntimeImport.resolveNodeModule(specifier: "./plugin", directory: "/app", fileSystem: fs) == "file:///app/plugin.ts")
        #expect(try await RuntimeImport.resolveBunModule(specifier: "legacy", directory: "/app", fileSystem: fs) == "file:///app/legacy.cjs")
        #expect(try await RuntimeImport.resolveNodeModule(specifier: "/app/exact.mjs", directory: "/other", fileSystem: fs) == "file:///app/exact.mjs")

        await #expect(throws: RuntimeImport.Error.self) {
            _ = try await RuntimeImport.resolveNodeModule(specifier: "./missing", directory: "/app", fileSystem: fs)
        }
        await #expect(throws: RuntimeImport.Error.self) {
            _ = try await RuntimeImport.importNodeModule("./plugin")
        }
        await #expect(throws: RuntimeImport.Error.self) {
            _ = try await RuntimeImport.importWorkerdModule("./plugin")
        }
        #expect(throws: RuntimeImport.Error("Dynamic module loading is unavailable on workerd")) {
            _ = try RuntimeImport.resolveWorkerdModule("./plugin", directory: "/app")
        }

        // HeapSnapshot
        let snap = try await HeapSnapshot.write(directory: "/snaps", fileSystem: fs)
        #expect(snap.path.hasPrefix("/snaps/heap-"))
        #expect(snap.path.hasSuffix(".heapsnapshot"))
        #expect(await fs.exists(at: snap.path))
    }
}

// MARK: - Serialized Suite for Process-Global Signal Registry

@Suite("OpenCodePlatform ProcessSignal Tests", .serialized)
struct ProcessSignalTests {
    @Test("ProcessSignal install, subscribe, dispatch, unsubscribe, and unavailable fallback")
    func processSignalLifecycle() {
        ProcessSignal.reset()
        defer { ProcessSignal.reset() }

        let events = Mutex<[String]>([])
        ProcessSignal.install(signal: "SIGUSR2") {
            events.withLock { $0.append("unavailable") }
        }
        // Duplicate install is a no-op (does not replace callback)
        ProcessSignal.install(signal: "SIGUSR2") {
            events.withLock { $0.append("replaced-should-not-run") }
        }

        // Dispatch without subscribers triggers unavailable
        ProcessSignal.dispatch(signal: "SIGUSR2")
        #expect(events.withLock { $0 } == ["unavailable"])

        // Subscribers receive signal in registration order
        let unsub1 = ProcessSignal.subscribe(signal: "SIGUSR2") { events.withLock { $0.append("sub1") } }
        let unsub2 = ProcessSignal.subscribe(signal: "SIGUSR2") { events.withLock { $0.append("sub2") } }
        ProcessSignal.dispatch(signal: "SIGUSR2")
        #expect(events.withLock { $0 } == ["unavailable", "sub1", "sub2"])

        // Unsubscribing all restores unavailable fallback
        unsub1()
        unsub2()
        ProcessSignal.dispatch(signal: "SIGUSR2")
        #expect(events.withLock { $0 } == ["unavailable", "sub1", "sub2", "unavailable"])

        // Uninstalled signal is a safe no-op
        _ = ProcessSignal.subscribe(signal: "SIGUNKNOWN") { events.withLock { $0.append("nope") } }
        ProcessSignal.dispatch(signal: "SIGUNKNOWN")
        #expect(events.withLock { $0 } == ["unavailable", "sub1", "sub2", "unavailable"])
    }
}
