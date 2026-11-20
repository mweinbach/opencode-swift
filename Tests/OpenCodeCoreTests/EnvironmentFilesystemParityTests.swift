import Testing
import OpenCodeCore
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

private typealias Environment = CoreLocation.Environment
private typealias FileAccess = CoreFilesystem.FileAccess
private typealias FileMutation = CoreFilesystem.FileMutation
private typealias Helper = EnvironmentFilesystemHelper

@Suite("Environment & filesystem parity (envfs)")
struct EnvironmentFilesystemParityTests {
    // MARK: - environment/environment.ts

    @Test("Environment IDs: local, make, service defaults and plain-string coding")
    func environmentIDs() async throws {
        #expect(Environment.localID.rawValue == "local")
        #expect(Environment.ID.make("gpu") == "gpu")
        let driver = Environment.makeMemoryDriver()
        let made = Environment.make("wrk_123", Environment.Driver(spawner: Environment.unavailableSpawner, overrides: driver))
        #expect(made.id == "wrk_123")
        #expect(Environment.Service(driver: Environment.makeLocalDriver()).id == Environment.localID)
        #expect(Environment.host.id == Environment.localID)
        #expect(try Helper.encodeID("gpu") == "\"gpu\"")
        #expect(try Helper.decodeID("\"local\"") == Environment.localID)
    }

    // MARK: - file-access.ts

    @Test("FileAccess.key: length-prefixed by UTF-16 units, distinct per environment, sorted per environment")
    func fileAccessKey() {
        #expect(FileAccess.key(absolute: "/a/b", environment: "local") == "5:local:/a/b")
        #expect(FileAccess.key(absolute: "/a/b", environment: "gpu") != FileAccess.key(absolute: "/a/b", environment: "local"))
        // "😀" is two UTF-16 code units, as JavaScript's `length` counts it.
        #expect(FileAccess.key(absolute: "/x", environment: "a😀") == "3:a😀:/x")
        let a = FileAccess.key(absolute: "/a", environment: "gpu")
        let b = FileAccess.key(absolute: "/b", environment: "gpu")
        #expect(a < b)
    }

    @Test("Machine paths parse only with a valid machine name")
    func machinePathParse() {
        let parsed = FileAccess.parseMachinePath("gpu:/work/train.py")
        #expect(parsed?.machine == "gpu")
        #expect(parsed?.path == "/work/train.py")
        #expect(FileAccess.parseMachinePath("gpu:~/a")?.path == "~/a")
        #expect(FileAccess.parseMachinePath("C:/Windows") == nil)
        #expect(FileAccess.parseMachinePath("local:/x") == nil)
        #expect(FileAccess.parseMachinePath("https://example.com") == nil)
        #expect(FileAccess.parseMachinePath("gpu:relative") == nil)
        #expect(FileAccess.parseMachinePath("Gpu:/x") == nil)
        #expect(FileAccess.isMachineName("gpu-2"))
        #expect(!FileAccess.isMachineName("g"))
    }

    @Test("Local targets carry the Location's environment; locate resolves text without touching disk")
    func localTargetsCarryEnvironment() async throws {
        let fs = InMemoryFileSystem()
        let access = FileAccess.Service(directory: "/repo", fileSystem: fs, home: "/home/me")
        let internalTarget = try await access.resolve(FileAccess.ResolveInput(path: "src/a.ts"))
        #expect(internalTarget.resource == "src/a.ts")
        #expect(internalTarget.environment.id == Environment.localID)
        let external = try await access.resolve(FileAccess.ResolveInput(path: "/tmp/x.txt", kind: .file))
        #expect(external.externalDirectory?.resource == "/tmp/*")
        #expect(external.environment.id == Environment.localID)
        let place = try await access.locate("~/notes.md", base: nil)
        #expect(place == FileAccess.Place(absolute: "/home/me/notes.md", environment: Environment.localID))
        // With the machines flag off, a machine-looking path is a local relative path.
        let plain = try await access.locate("gpu:/work", base: nil)
        #expect(plain.environment.id == Environment.localID)
    }

    @Test("A base on another machine resolves POSIX paths there, with machine-prefixed resources")
    func machineTargetFromBase() async throws {
        let gpu = try await Helper.memoryEnvironment("gpu", files: ["/work/data/a.txt": "hello"])
        let access = FileAccess.Service(
            directory: "/repo",
            fileSystem: InMemoryFileSystem(),
            machines: Helper.StubMachines(environments: ["gpu": gpu], homes: ["gpu": "/home/gpu"])
        )
        let base = FileAccess.Place(absolute: "/work", environment: "gpu")
        let target = try await access.resolve(FileAccess.ResolveInput(path: "data/a.txt", base: base))
        #expect(target.absolute.rawValue == "/work/data/a.txt")
        #expect(target.resource == "gpu:/work/data/a.txt")
        #expect(target.externalDirectory?.resource == "gpu:/work/data/*")
        #expect(target.externalDirectory?.save == "gpu:/work/data/*")
        #expect(target.environment.id == "gpu")
        let directory = try await access.resolve(FileAccess.ResolveInput(path: "../work/data", base: base))
        #expect(directory.externalDirectory?.directory.rawValue == "/work/data")
        // With the flag off no home is asked for, so a base on another machine refuses every `~`.
        await #expect(throws: Environment.Files.Failed.self) {
            _ = try await access.locate("~/x", base: base)
        }
        // An unknown machine fails as an environment failure.
        await #expect(throws: Environment.Files.Failed.self) {
            _ = try await access.resolve(FileAccess.ResolveInput(path: "a", base: FileAccess.Place(absolute: "/w", environment: "tpu")))
        }
    }

    @Test("Targets compare, hash and code their environment by id")
    func targetCoding() throws {
        let target = FileAccess.Target(absolute: SchemaPrimitive.AbsolutePath(rawValue: "/a"), resource: "a")
        let (json, decoded) = try Helper.roundTripTarget(target)
        #expect(json.contains("\"environment\":{\"id\":\"local\"}"))
        #expect(decoded == target)
        #expect(decoded.environment.id == Environment.localID)
        let remote = FileAccess.Target(
            absolute: SchemaPrimitive.AbsolutePath(rawValue: "/a"),
            resource: "a",
            environment: Environment.Service(id: "gpu", driver: Environment.Driver(spawner: Environment.unavailableSpawner))
        )
        #expect(remote != target)
        #expect(Set<FileAccess.Target>([remote, target, decoded]).count == 2)
    }

    // MARK: - file-mutation.ts

    @Test("readEditableText refuses non-UTF-8 files and keeps BOM text")
    func readEditableTextRefusesInvalidUtf8() async throws {
        let fs = InMemoryFileSystem(initialFiles: [
            "/repo/latin1.txt": [0x63, 0x61, 0x66, 0xE9],
            "/repo/bom.txt": [0xEF, 0xBB, 0xBF, 0x68, 0x69],
            "/repo/overlong.txt": [0xC0, 0x80],
        ])
        let error = await #expect(throws: FileMutation.InvalidUtf8Error.self) {
            _ = try await FileMutation.readEditableText(fileSystem: fs, target: "/repo/latin1.txt")
        }
        #expect(error?.path == "/repo/latin1.txt")
        #expect(error?.message.hasPrefix("file is not valid UTF-8.") == true)
        await #expect(throws: FileMutation.InvalidUtf8Error.self) {
            _ = try await FileMutation.readEditableText(fileSystem: fs, target: "/repo/overlong.txt")
        }
        let bom = try await FileMutation.readEditableText(fileSystem: fs, target: "/repo/bom.txt")
        #expect(bom.text == "hi")
        #expect(bom.bom)
        // The lenient reader still decodes with replacement characters.
        let lenient = try await FileMutation.readText(fileSystem: fs, target: "/repo/latin1.txt")
        #expect(lenient.text.hasPrefix("caf"))
        #expect(FileMutation.isUtf8(Array("héllo 😀".utf8)))
        #expect(!FileMutation.isUtf8([0xED, 0xA0, 0x80]))
    }

    @Test("Mutations act on the target's environment; locks key by environment and path")
    func mutationsUseTargetEnvironment() async throws {
        let local = InMemoryFileSystem()
        let gpu = try await Helper.memoryEnvironment("gpu", files: ["/work/keep.txt": "x"])
        let mutation = FileMutation.Service(fileSystem: local)
        let remoteTarget = FileMutation.Target(absolute: SchemaPrimitive.AbsolutePath(rawValue: "/work/out.txt"), resource: "gpu:/work/out.txt", environment: gpu)
        let written = try await mutation.writeTextPreservingBom(FileMutation.TextWriteInput(target: remoteTarget, content: "remote"))
        #expect(!written.existed)
        #expect(String(decoding: try await gpu.files.read("/work/out.txt", range: nil).bytes, as: UTF8.self) == "remote")
        #expect(!(await local.exists(at: "/work/out.txt")))
        _ = try await mutation.append(FileMutation.WriteInput(target: remoteTarget, text: "+more"))
        #expect(String(decoding: try await gpu.files.read("/work/out.txt", range: nil).bytes, as: UTF8.self) == "remote+more")

        let localTarget = FileMutation.Target(absolute: SchemaPrimitive.AbsolutePath(rawValue: "/work/out.txt"), resource: "/work/out.txt")
        _ = try await mutation.write(FileMutation.WriteInput(target: localTarget, text: "local"))
        #expect(String(decoding: try await local.readFile(at: "/work/out.txt"), as: UTF8.self) == "local")

        // The same path in two environments is two files: nested locks do not wait on each other.
        let nested = try await mutation.withLock(places: [FileAccess.Place(absolute: "/work/out.txt", environment: "gpu")]) {
            try await mutation.withLock(places: [FileAccess.Place(absolute: "/work/out.txt", environment: Environment.localID)]) {
                "ok"
            }
        }
        #expect(nested == "ok")
    }

    // MARK: - formatter.ts

    @Test("The formatter only formats files on the server's own machine")
    func formatterSkipsRemoteTargets() async throws {
        let formatter = CoreFormatter.Service(directory: "/repo")
        _ = await formatter.transform { editor in
            editor.set(CoreFormatter.Info(name: "fake", extensions: [".ts"], enabled: { ["true"] }))
        }
        let gpu = try await Helper.memoryEnvironment("gpu")
        let remote = FileAccess.Target(absolute: SchemaPrimitive.AbsolutePath(rawValue: "/work/a.ts"), resource: "gpu:/work/a.ts", environment: gpu)
        #expect(await formatter.file(remote) == false)
    }

    // MARK: - ripgrep.ts / filesystem/search.ts

    @Test("Ripgrep searches run over the input environment's files")
    func ripgrepUsesInputEnvironment() async throws {
        let gpu = try await Helper.memoryEnvironment("gpu", files: [
            "/work/src/a.swift": "let needle = 1\n",
            "/work/src/b.txt": "nothing here\n",
        ])
        let ripgrep = CoreRipgrep.Service(fileSystem: InMemoryFileSystem())
        let found = try await ripgrep.find(CoreRipgrep.FindInput(environment: gpu, cwd: "/work", pattern: "*", limit: 10))
        #expect(found.map(\.path.rawValue) == ["src/a.swift", "src/b.txt"])
        let globbed = try await ripgrep.glob(CoreRipgrep.GlobInput(environment: gpu, cwd: "/work", pattern: "*.swift", limit: 10))
        #expect(globbed.map(\.path.rawValue) == ["src/a.swift"])
        let matches = try await ripgrep.grep(CoreRipgrep.GrepInput(environment: gpu, cwd: "/work", pattern: "needle", literal: true, limit: 10))
        #expect(matches.map(\.entry.path.rawValue) == ["src/a.swift"])
        // The local environment still searches the service's own file system.
        let localFound = try await ripgrep.find(CoreRipgrep.FindInput(cwd: "/work", pattern: "*", limit: 10))
        #expect(localFound.isEmpty)
    }

    // MARK: - shell/parse.ts

    @Test("Shell scan leaves a machine's ~ as written when no home is known")
    func shellScanHome() throws {
        let server = try CoreShell.Parse.scan(command: "cd ~/proj", shell: "/bin/bash", cwd: "/repo", home: .path("/home/me"))
        #expect(server.directories == ["/home/me/proj"])
        let machine = try CoreShell.Parse.scan(command: "cd ~/proj", shell: "sh", cwd: "/work", home: .unknown)
        #expect(machine.directories == ["~/proj"])
        let quoted = try CoreShell.Parse.scan(command: "cd '~'", shell: "sh", cwd: "/work", home: .unknown)
        #expect(quoted.directories == ["/work/~"])
        let relative = try CoreShell.Parse.scan(command: "cd sub", shell: "sh", cwd: "/work", home: .unknown)
        #expect(relative.directories == ["/work/sub"])
    }

    // MARK: - shell.ts

    @Test("A command whose working directory is in another environment runs there through sh")
    func shellRunsInTargetEnvironment() async throws {
        let spawner = Helper.RecordingSpawner()
        let gpu = try await Helper.memoryEnvironment("gpu", spawner: spawner)
        let shell = CoreShell.Service(directory: "/repo", fileSystem: InMemoryFileSystem())
        let started = try await shell.create(
            CoreShell.CreateRequest(command: "nvidia-smi", cwd: "/work", shell: "/bin/zsh", environment: gpu),
            before: nil
        )
        #expect(started.shell == "sh")
        #expect(started.cwd == "/work")
        let result = await shell.result(started, waitMs: nil)
        #expect(result.info.exit == 0)
        #expect(result.capture?.output == "remote\n")
        #expect(spawner.recorded.count == 1)
        #expect(spawner.recorded.first?.executable == "sh")
        #expect(spawner.recorded.first?.workingDirectory == "/work")
    }

    @Test("A remote command whose exit cannot be read reports the driver's sentence")
    func shellReportsRemoteKill() async throws {
        let spawner = Helper.RecordingSpawner(failure: "worker restarted")
        let gpu = try await Helper.memoryEnvironment("gpu", spawner: spawner)
        let shell = CoreShell.Service(directory: "/repo", fileSystem: InMemoryFileSystem())
        let started = try await shell.create(CoreShell.CreateRequest(command: "train", cwd: "/work", environment: gpu), before: nil)
        let result = await shell.result(started, waitMs: nil)
        #expect(result.info.exit == nil)
        #expect(result.capture?.killed == "worker restarted")
    }

    // MARK: - session/search-index.ts & search-build.ts

    @Test("Session search index builds over existing history and answers FTS queries")
    func sessionSearchBuildAndQuery() async throws {
        let db = try await Helper.openDatabase()
        try Helper.insertSession(db, id: "ses_b", title: "Refactor the parser")
        try Helper.insertSession(db, id: "ses_a", title: "Hóa đơn export")
        try Helper.insertMessage(db, id: "msg_001", session: "ses_b", type: "user", data: ["text": "Please fix the tokenizer bug"])
        try Helper.insertMessage(db, id: "msg_002", session: "ses_b", type: "assistant", data: [
            "time": ["created": 1, "completed": 2],
            "content": [["type": "text", "text": "The lexer now handles quotes"]],
        ])
        try Helper.insertMessage(db, id: "msg_003", session: "ses_b", type: "assistant", data: [
            "time": ["created": 3],
            "content": [["type": "text", "text": "streaming draft"]],
        ])
        try Helper.insertMessage(db, id: "msg_004", session: "ses_b", type: "compaction", data: [
            "status": "completed",
            "summary": "Summary about migrations",
        ])
        try Helper.insertMessage(db, id: "msg_005", session: "ses_b", type: "shell", data: ["text": "tokenizer shell"])

        let ensured = try SessionSearchIndex.ensure(db)
        guard case .ready(let state) = ensured else {
            Issue.record("expected a ready index, got \(ensured)")
            return
        }
        #expect(state.status == .building)
        #expect(state.phase == .titles)
        #expect(state.total == 7)

        var chunks = 0
        while try !SessionSearchIndex.buildChunk(db).done { chunks += 1 }
        #expect(chunks == 1)
        guard case .state(let done) = try SessionSearchIndex.state(db) else {
            Issue.record("missing state")
            return
        }
        #expect(done.status == .done)
        #expect(done.processed == 7)

        #expect(try Helper.search(db, "parser") == ["ses_b"])
        #expect(try Helper.search(db, "tokenizer") == ["msg_001"])
        #expect(try Helper.search(db, "lexer") == ["msg_002"])
        #expect(try Helper.search(db, "migrations") == ["msg_004"])
        // Folded letters match their ASCII forms; porter stemming matches word variants.
        #expect(try Helper.search(db, "hoa don") == ["ses_a"])
        #expect(try Helper.search(db, "quote") == ["msg_002"])
        // A streaming assistant is not indexed until it finishes; unindexed types never are.
        #expect(try Helper.search(db, "streaming").isEmpty)
        #expect(try Helper.search(db, "shell").isEmpty)

        // Triggers keep the index current after the build.
        try Helper.updateMessage(db, id: "msg_003", data: [
            "time": ["created": 3, "completed": 4],
            "content": [["type": "text", "text": "finished streaming answer"]],
        ])
        #expect(try Helper.search(db, "streaming") == ["msg_003"])
        try Helper.insertMessage(db, id: "msg_006", session: "ses_a", type: "user", data: ["text": "invoice totals"])
        #expect(try Helper.search(db, "invoice") == ["msg_006"])
        _ = try db.execute("DELETE FROM session_message WHERE id = 'msg_006'", parameters: [])
        #expect(try Helper.search(db, "invoice").isEmpty)
        _ = try db.execute("UPDATE session_v2 SET title = 'Rewrite the scanner' WHERE id = 'ses_b'", parameters: [])
        #expect(try Helper.search(db, "parser").isEmpty)
        #expect(try Helper.search(db, "scanner") == ["ses_b"])

        // A second ensure keeps the finished index.
        guard case .ready(let again) = try SessionSearchIndex.ensure(db) else {
            Issue.record("expected ready")
            return
        }
        #expect(again.status == .done)
    }

    @Test("Session search state: newer versions are left alone; fail and retry restart the build")
    func sessionSearchStateTransitions() async throws {
        let db = try await Helper.openDatabase()
        try Helper.writeRawState(db, json: "{\"version\":99,\"future\":true}")
        #expect(try SessionSearchIndex.ensure(db) == .newer)
        #expect(try SessionSearchIndex.state(db) == .versionOnly(99))
        #expect(SessionSearchIndex.current(try SessionSearchIndex.state(db)) == nil)

        let fresh = try await Helper.openDatabase()
        guard case .ready = try SessionSearchIndex.ensure(fresh) else {
            Issue.record("expected ready")
            return
        }
        try SessionSearchIndex.fail(fresh, error: "disk full")
        guard case .state(let failed) = try SessionSearchIndex.state(fresh) else { return }
        #expect(failed.status == .failed)
        #expect(failed.error == "disk full")
        try SessionSearchIndex.retry(fresh)
        guard case .state(let retried) = try SessionSearchIndex.state(fresh) else { return }
        #expect(retried.status == .building)
        #expect(retried.phase == .titles)
        #expect(retried.error == nil)
        #expect(SessionSearchIndex.isBusy(SQLiteError.stepFailed(sql: "x", code: 5, message: "busy")))
        #expect(SessionSearchIndex.isBusy(SQLiteError.stepFailed(sql: "x", code: 262, message: "locked")))
        #expect(!SessionSearchIndex.isBusy(SQLiteError.stepFailed(sql: "x", code: 1, message: "error")))
        #expect(SessionSearchIndex.indexes(.user))
        #expect(!SessionSearchIndex.indexes(.shell))
    }

    @Test("SessionSearchBuild waits for start, then runs the build to done")
    func sessionSearchBuildService() async throws {
        let db = try await Helper.openDatabase()
        try Helper.insertSession(db, id: "ses_x", title: "Background build")
        let build = SessionSearchBuild.Service(db: db)
        let runner = Task { await build.run() }
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(try SessionSearchIndex.state(db) == nil)
        await build.start()
        await runner.value
        guard case .state(let state) = try SessionSearchIndex.state(db) else {
            Issue.record("missing state")
            return
        }
        #expect(state.status == .done)
        #expect(try Helper.search(db, "background") == ["ses_x"])

        // A run cancelled before start returns without building.
        let idle = SessionSearchBuild.Service(db: try await Helper.openDatabase())
        let cancelled = Task { await idle.run() }
        cancelled.cancel()
        await cancelled.value
    }
}
