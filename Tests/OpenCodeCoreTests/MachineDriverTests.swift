import Testing
import OpenCodeCore
import OpenCodePlatform

private typealias Worker = MachineTestHelper.FakeWorker

private func started(_ message: MachineWire.ToWorker) -> MachineWire.ProcessID? {
    if case .start(let id, _, _, _, _) = message { return id }
    return nil
}

private func collectStream(_ stream: AsyncThrowingStream<[UInt8], any Error>) async throws -> [UInt8] {
    var result: [UInt8] = []
    for try await chunk in stream {
        result.append(contentsOf: chunk)
    }
    return result
}

@Suite("Machine driver: connections, processes, stdio and files")
struct MachineDriverTests {
    @Test("a machine is offline until a worker connects, and serves its hello and connection info while connected")
    func onlineAndOffline() async throws {
        let (machines, _, _) = try MachineTestHelper.machines()
        _ = try await machines.add("gpu")
        await #expect(throws: MachineDriver.NotSent(machine: "gpu")) { try await machines.home("gpu") }
        let environment = try await machines.get("gpu")
        await #expect(throws: CoreLocation.Environment.Files.Failed.self) { try await environment.files.stat("/x") }
        await #expect(throws: MachineDriver.NotSent(machine: "gpu")) {
            try await environment.spawner.run(ProcessSpec(executable: "ls", workingDirectory: "/"))
        }
        let info = MachineDriver.ConnectionInfo(kind: .iroh, path: .direct, rtt: 12.5)
        let worker = Worker(hello: MachineTestHelper.hello(), describe: { info })
        let serving = Task { try await machines.connect("gpu", worker.connection) }
        #expect(await MachineTestHelper.eventuallyAsync { await machines.list().first?.online == true })
        #expect(try await machines.home("gpu") == "/home/me")
        #expect(await machines.list() == [
            Machines.Info(id: "gpu", online: true, paired: false, os: "linux", arch: "x64", connection: info),
        ])
        worker.drop()
        try await serving.value
        #expect(await machines.list() == [Machines.Info(id: "gpu", online: false, paired: false)])
        await #expect(throws: Machines.NotFound(machine: "cpu")) {
            try await machines.connect("cpu", Worker(hello: MachineTestHelper.hello()).connection)
        }
    }

    @Test("a process runs on the worker: output in order, a gap attaches again, and the exit releases it")
    func runProcess() async throws {
        let machine = MachineDriver.make("gpu")
        let worker = Worker(hello: MachineTestHelper.hello())
        let serving = Task { await machine.connect(worker.connection) }
        #expect(await MachineTestHelper.eventually { machine.hello() != nil })
        let run = Task {
            try await machine.environment.spawner.run(
                ProcessSpec(executable: "echo", arguments: ["hi"], workingDirectory: "/work", environment: ["A": "1"])
            )
        }
        let start = try #require(await worker.next { started($0) != nil })
        guard case .start(let id, let argv, let cwd, let env, let stdin) = start else { return }
        #expect(argv == ["echo", "hi"] && cwd == "/work" && env == ["A": "1"] && stdin == false)
        worker.reply(.started(id: id, pid: 42))
        worker.reply(.output(id: id, offset: 0, stream: .stdout, data: Array("hel".utf8)))
        // A repeat of bytes already delivered is trimmed; a chunk past a gap is dropped.
        worker.reply(.output(id: id, offset: 1, stream: .stdout, data: Array("ello".utf8)))
        worker.reply(.output(id: id, offset: 9, stream: .stdout, data: Array("zz".utf8)))
        worker.reply(.exit(MachineWire.Exit(id: id, bytes: 7, code: 0)))
        _ = try #require(await worker.next { $0 == .attach(id: id, from: 5) })
        worker.reply(.output(id: id, offset: 5, stream: .stdout, data: Array("!\n".utf8)))
        worker.reply(.exit(MachineWire.Exit(id: id, bytes: 7, code: 3)))
        let output = try await run.value
        #expect(output.exitCode == 3)
        #expect(String(decoding: output.stdout, as: UTF8.self) == "hello!\n")
        #expect(output.stderr.isEmpty)
        #expect(await worker.next { $0 == .release(id: id) } != nil)
        worker.drop()
        await serving.value
    }

    @Test("a signal exit, a refused start, and options a machine cannot honour fail the run")
    func failures() async throws {
        let machine = MachineDriver.make("gpu")
        let worker = Worker(hello: MachineTestHelper.hello())
        let serving = Task { await machine.connect(worker.connection) }
        #expect(await MachineTestHelper.eventually { machine.hello() != nil })
        let spawner = machine.environment.spawner
        await #expect(throws: MachineDriver.Unsupported.self) { try await spawner.run(ProcessSpec(executable: "ls")) }
        let inheritErr = await #expect(throws: MachineDriver.Unsupported.self) {
            _ = try await MachineDriver.spawn(
                machine,
                options: .init(command: "cat", cwd: "/work", stdin: .inherit)
            )
        }
        #expect(inheritErr?.description == "stdin is not supported on gpu")

        let killed = Task { try await spawner.run(ProcessSpec(executable: "sleep", workingDirectory: "/")) }
        let first = try #require(await worker.next { started($0) != nil }.flatMap(started))
        worker.reply(.started(id: first, pid: 1))
        worker.reply(.exit(MachineWire.Exit(id: first, bytes: 0, signal: "SIGKILL")))
        await #expect(throws: CrossSpawnSpawner.KilledBySignal(signal: "SIGKILL")) { try await killed.value }

        let refused = Task { try await spawner.run(ProcessSpec(executable: "nope", workingDirectory: "/")) }
        let second = try #require(await worker.next { started($0) != nil && started($0) != first }.flatMap(started))
        worker.reply(.failed(id: second, request: .start, message: "no such file"))
        await #expect(throws: MachineDriver.StartFailed(message: "no such file")) { try await refused.value }
        worker.drop()
        await serving.value
    }

    private func flushWorkerMessages(_ worker: Worker, on machine: any MachineDriver.Interface) async throws {
        let syncPath = "/__sync_\(worker.messages.count)"
        let probe = Task { try? await machine.environment.files.stat(syncPath) }
        let call = try #require(await worker.next { message in
            if case .fs(let req) = message, req.call == .stat(path: syncPath) { return true }
            return false
        })
        if case .fs(let req) = call {
            worker.reply(.fs(MachineWire.FileReply(
                req: req.req,
                outcome: .failure(MachineWire.FileError(kind: .notFound, message: "sync"))
            )))
        }
        _ = await probe.value
    }

    @Test("a reconnect from the same worker resumes a process; unknown running/exited processes are killed and released")
    func reconnect() async throws {
        let machine = MachineDriver.make("gpu")
        let first = Worker(hello: MachineTestHelper.hello(instance: "one"))
        let serving = Task { await machine.connect(first.connection) }
        #expect(await MachineTestHelper.eventually { machine.hello() != nil })
        let run = Task { try await machine.environment.spawner.run(ProcessSpec(executable: "make", workingDirectory: "/")) }
        let id = try #require(await first.next { started($0) != nil }.flatMap(started))
        first.reply(.started(id: id, pid: 7))
        first.reply(.output(id: id, offset: 0, stream: .stdout, data: [65]))
        // Ensure `first`'s stream reader has processed `.started` and `.output` before reconnecting.
        try await flushWorkerMessages(first, on: machine)
        // The same instance lists the process: the home attaches from what it already has.
        let second = Worker(hello: MachineTestHelper.hello(
            instance: "one",
            processes: [MachineWire.HelloProcess(id: id, pid: 7, state: .running, bytes: 1)]
        ))
        let resumed = Task { await machine.connect(second.connection) }
        _ = try #require(await second.next { $0 == .attach(id: id, from: 1) })
        await serving.value
        second.reply(.output(id: id, offset: 1, stream: .stdout, data: [66]))
        second.reply(.exit(MachineWire.Exit(id: id, bytes: 2, code: 0)))
        #expect(try await run.value.stdout == [65, 66])

        let lost = Task { try await machine.environment.spawner.run(ProcessSpec(executable: "train", workingDirectory: "/")) }
        let other = try #require(await second.next { started($0) != nil && started($0) != id }.flatMap(started))
        second.reply(.started(id: other, pid: 8))
        // Ensure `second`'s stream reader has processed `.started` before the worker restarts.
        try await flushWorkerMessages(second, on: machine)
        // Unknown exited processes are released; unknown running processes get SIGKILL then release.
        let orphanRunning = MachineWire.ProcessID("orphan-run")
        let orphanExited = MachineWire.ProcessID("old")
        let third = Worker(hello: MachineTestHelper.hello(
            instance: "two",
            processes: [
                MachineWire.HelloProcess(id: orphanRunning, pid: 2, state: .running, bytes: 0),
                MachineWire.HelloProcess(id: orphanExited, pid: 1, state: .exited, bytes: 0, code: .some(0)),
            ]
        ))
        let restarted = Task { await machine.connect(third.connection) }
        await #expect(throws: MachineDriver.ProcessLost(machine: "gpu", restarted: true)) { try await lost.value }
        _ = try #require(await third.next { $0 == .release(id: orphanExited) })
        #expect(third.messages == [
            .kill(id: orphanRunning, signal: .SIGKILL),
            .release(id: orphanRunning),
            .release(id: orphanExited),
        ])
        await resumed.value
        third.drop()
        await restarted.value
    }

    @Test("separate stdout/stderr and merged all output views preserve stream marks, order, and mutual exclusion")
    func outputViewsAndReconnect() async throws {
        let machine = MachineDriver.make("worker")
        let first = Worker(hello: MachineTestHelper.hello(instance: "inst"))
        let serving1 = Task { await machine.connect(first.connection) }
        #expect(await MachineTestHelper.eventually { machine.hello() != nil })

        // 1) Separate view rejects `all` and preserves stream marks across reconnect from a shared offset.
        let spawn1 = Task {
            try await MachineDriver.spawn(machine, options: .init(command: "cmd", cwd: "/work"))
        }
        let id1 = try #require(await first.next { started($0) != nil }.flatMap(started))
        first.reply(.started(id: id1, pid: 10))
        let handle1 = try await spawn1.value

        let outStream = handle1.stdout()
        let errStream = handle1.stderr()
        let outTask = Task { try await collectStream(outStream) }
        let errTask = Task { try await collectStream(errStream) }
        let allConflict = await #expect(throws: MachineDriver.OutputViewConflict.self) {
            _ = try await collectStream(handle1.all())
        }
        #expect(allConflict?.message == "read either all, or stdout and stderr, not both")

        first.reply(.output(id: id1, offset: 0, stream: .stdout, data: Array("out".utf8)))
        first.reply(.output(id: id1, offset: 3, stream: .stderr, data: Array("err".utf8)))
        try await flushWorkerMessages(first, on: machine)

        let second = Worker(hello: MachineTestHelper.hello(
            instance: "inst",
            processes: [MachineWire.HelloProcess(id: id1, pid: 10, state: .running, bytes: 6)]
        ))
        let serving2 = Task { await machine.connect(second.connection) }
        _ = try #require(await second.next { $0 == .attach(id: id1, from: 6) })
        await serving1.value

        second.reply(.output(id: id1, offset: 6, stream: .stderr, data: Array("offline-error".utf8)))
        second.reply(.output(id: id1, offset: 19, stream: .stdout, data: Array("offline-out".utf8)))
        second.reply(.exit(MachineWire.Exit(id: id1, bytes: 30, code: 0)))
        #expect(MachineTestHelper.utf8(try await outTask.value) == "outoffline-out")
        #expect(MachineTestHelper.utf8(try await errTask.value) == "erroffline-error")
        #expect(try await handle1.exitCode() == 0)

        // 2) Merged `all` view preserves exact arrival order across stdout/stderr and rejects separate streams.
        let spawn2 = Task {
            try await MachineDriver.spawn(machine, options: .init(command: "cmd2", cwd: "/work"))
        }
        let id2 = try #require(await second.next { started($0) != nil }.flatMap(started))
        second.reply(.started(id: id2, pid: 11))
        let handle2 = try await spawn2.value

        let allStream = handle2.all()
        let allTask = Task { try await collectStream(allStream) }
        second.reply(.output(id: id2, offset: 0, stream: .stderr, data: Array("one".utf8)))
        second.reply(.output(id: id2, offset: 3, stream: .stdout, data: Array("two".utf8)))
        second.reply(.output(id: id2, offset: 6, stream: .stderr, data: Array("three".utf8)))
        second.reply(.exit(MachineWire.Exit(id: id2, bytes: 11, code: 0)))
        #expect(MachineTestHelper.utf8(try await allTask.value) == "onetwothree")
        await #expect(throws: MachineDriver.OutputViewConflict.self) {
            _ = try await collectStream(handle2.stdout())
        }
        await #expect(throws: MachineDriver.OutputViewConflict.self) {
            _ = try await collectStream(handle2.stderr())
        }
        #expect(try await handle2.exitCode() == 0)

        second.drop()
        await serving2.value
    }

    @Test("stdin chunks large writes at 64 KiB, awaits acks, closes with null, and rejects concurrent or broken writes")
    func stdinProtocol() async throws {
        let machine = MachineDriver.make("worker")
        let worker = Worker(hello: MachineTestHelper.hello())
        let serving = Task { await machine.connect(worker.connection) }
        #expect(await MachineTestHelper.eventually { machine.hello() != nil })

        let spawn = Task {
            try await MachineDriver.spawn(machine, options: .init(command: "cat", cwd: "/work", stdin: .pipe()))
        }
        let startMsg = try #require(await worker.next { started($0) != nil })
        guard case .start(let id, _, _, _, let hasStdin) = startMsg else { return }
        #expect(hasStdin == true)
        worker.reply(.started(id: id, pid: 21))
        let handle = try await spawn.value

        // Write 65,537 bytes -> splits into [65536, 1].
        let large = [UInt8](repeating: 65, count: 65_537)
        let writeTask = Task {
            try await handle.writeStdin(Array("one".utf8))
            try await handle.writeStdin(large)
            try await handle.closeStdin()
        }

        // Ack 4 stdin messages: "one" (3), 65536, 1, null.
        var receivedLengths: [Int?] = []
        var ackedReqs: Set<Int> = []
        while receivedLengths.count < 4 {
            let seen = ackedReqs
            let msg = try #require(await worker.next { msg in
                if case .stdin(let pid, let req, _) = msg, pid == id, !seen.contains(req) { return true }
                return false
            })
            if case .stdin(_, let req, let data) = msg {
                ackedReqs.insert(req)
                receivedLengths.append(data?.count)
                worker.reply(.stdin(id: id, req: req, outcome: .ok))
            }
        }
        try await writeTask.value
        #expect(receivedLengths == [3, 65_536, 1, nil])

        // Broken pipe error from worker is propagated cleanly.
        let lateWrite = Task { try await handle.writeStdin(Array("late".utf8)) }
        let seenBeforeLate = ackedReqs
        let lateMsg = try #require(await worker.next { msg in
            if case .stdin(let pid, let req, _) = msg, pid == id, !seenBeforeLate.contains(req) { return true }
            return false
        })
        if case .stdin(_, let req, _) = lateMsg {
            ackedReqs.insert(req)
            // While `lateMsg` is still unacknowledged, a concurrent write is refused locally.
            await #expect(throws: MachineDriver.StdinFailed(message: "stdin write already pending")) {
                try await handle.writeStdin([1])
            }
            worker.reply(.stdin(id: id, req: req, outcome: .failed("Broken pipe")))
        }
        await #expect(throws: MachineDriver.StdinFailed(message: "Broken pipe")) {
            try await lateWrite.value
        }

        worker.reply(.exit(MachineWire.Exit(id: id, bytes: 0, code: 0)))
        #expect(try await handle.exitCode() == 0)
        worker.drop()
        await serving.value
    }

    @Test("stdin fails offline and unacknowledged writes without resending, and source stream loss kills process")
    func stdinConnectionLoss() async throws {
        let machine = MachineDriver.make("worker")
        let first = Worker(hello: MachineTestHelper.hello(instance: "a"))
        let serving1 = Task { await machine.connect(first.connection) }
        #expect(await MachineTestHelper.eventually { machine.hello() != nil })

        // 1) Manual pipe write loses connection -> StdinUnknown; offline write -> NotSent; never replayed.
        let spawnPipe = Task {
            try await MachineDriver.spawn(machine, options: .init(command: "cat", cwd: "/work", stdin: .pipe()))
        }
        let pipeID = try #require(await first.next { started($0) != nil }.flatMap(started))
        first.reply(.started(id: pipeID, pid: 31))
        let pipeHandle = try await spawnPipe.value

        let pendingWrite = Task { try await pipeHandle.writeStdin(Array("once".utf8)) }
        _ = try #require(await first.next { msg in
            if case .stdin(let pid, _, _) = msg, pid == pipeID { return true }
            return false
        })
        first.drop()
        await serving1.value

        let unknownErr = await #expect(throws: MachineDriver.StdinUnknown.self) {
            try await pendingWrite.value
        }
        #expect(unknownErr?.message == "Lost connection to worker. The stdin operation's outcome is unknown.")
        await #expect(throws: MachineDriver.NotSent(machine: "worker")) {
            try await pipeHandle.writeStdin(Array("offline".utf8))
        }

        // Reconnect: stdin is never resent.
        let second = Worker(hello: MachineTestHelper.hello(
            instance: "a",
            processes: [MachineWire.HelloProcess(id: pipeID, pid: 31, state: .running, bytes: 0)]
        ))
        let serving2 = Task { await machine.connect(second.connection) }
        _ = try #require(await second.next { $0 == .attach(id: pipeID, from: 0) })
        second.reply(.exit(MachineWire.Exit(id: pipeID, bytes: 0, code: 0)))
        #expect(try await pipeHandle.exitCode() == 0)
        #expect(second.messages.filter { if case .stdin = $0 { return true } else { return false } }.isEmpty)

        // 2) Source stream losing an unacknowledged write stops the process with SIGTERM.
        let source = AsyncThrowingStream<[UInt8], any Error> { cont in
            cont.yield(Array("once".utf8))
            cont.yield(Array("never".utf8))
            cont.finish()
        }
        let spawnStream = Task {
            try await MachineDriver.spawn(machine, options: .init(command: "cat", cwd: "/work", stdin: .stream(source)))
        }
        let streamID = try #require(await second.next { started($0) != nil }.flatMap(started))
        second.reply(.started(id: streamID, pid: 32))
        let streamHandle = try await spawnStream.value
        _ = try #require(await second.next { msg in
            if case .stdin(let pid, _, _) = msg, pid == streamID { return true }
            return false
        })
        second.drop()
        await serving2.value

        let third = Worker(hello: MachineTestHelper.hello(
            instance: "a",
            processes: [MachineWire.HelloProcess(id: streamID, pid: 32, state: .running, bytes: 0)]
        ))
        let serving3 = Task { await machine.connect(third.connection) }
        _ = try #require(await third.next { $0 == .kill(id: streamID, signal: .SIGTERM) })
        third.reply(.exit(MachineWire.Exit(id: streamID, bytes: 0, signal: "SIGTERM")))
        await #expect(throws: CrossSpawnSpawner.KilledBySignal(signal: "SIGTERM")) {
            _ = try await streamHandle.exitCode()
        }
        #expect(streamHandle.isRunning() == false)
        third.drop()
        await serving3.value
    }

    @Test("source stream with endOnDone false does not close stdin, and worker stdin refusal keeps process running")
    func stdinEndOnDoneAndBrokenPipe() async throws {
        let machine = MachineDriver.make("worker")
        let worker = Worker(hello: MachineTestHelper.hello())
        let serving = Task { await machine.connect(worker.connection) }
        #expect(await MachineTestHelper.eventually { machine.hello() != nil })

        // endOnDone: false -> no null stdin frame.
        let s1 = AsyncThrowingStream<[UInt8], any Error> { cont in
            cont.yield(Array("stream".utf8))
            cont.finish()
        }
        let spawn1 = Task {
            try await MachineDriver.spawn(
                machine,
                options: .init(command: "cat", cwd: "/work", stdin: .stream(s1, endOnDone: false))
            )
        }
        let id1 = try #require(await worker.next { started($0) != nil }.flatMap(started))
        worker.reply(.started(id: id1, pid: 41))
        let h1 = try await spawn1.value
        let stdinMsg = try #require(await worker.next { msg in
            if case .stdin(let pid, _, _) = msg, pid == id1 { return true }
            return false
        })
        if case .stdin(_, let req, let data) = stdinMsg {
            #expect(data == Array("stream".utf8))
            worker.reply(.stdin(id: id1, req: req, outcome: .ok))
        }
        try await h1.stdinTask?.value
        // Only the 1 data frame, no close frame (`nil`).
        let sentTo1 = worker.messages.compactMap { msg -> [UInt8]?? in
            if case .stdin(let pid, _, let data) = msg, pid == id1 { return .some(data) }
            return nil
        }
        #expect(sentTo1.count == 1)
        worker.reply(.exit(MachineWire.Exit(id: id1, bytes: 0, code: 0)))
        #expect(try await h1.exitCode() == 0)

        // Worker returns `ok: false` (Broken pipe) -> process keeps running (no kill sent).
        let s2 = AsyncThrowingStream<[UInt8], any Error> { cont in
            cont.yield(Array("input".utf8))
            cont.finish()
        }
        let spawn2 = Task {
            try await MachineDriver.spawn(machine, options: .init(command: "cat", cwd: "/work", stdin: .stream(s2)))
        }
        let id2 = try #require(await worker.next { started($0) != nil && started($0) != id1 }.flatMap(started))
        worker.reply(.started(id: id2, pid: 42))
        let h2 = try await spawn2.value
        let stdinMsg2 = try #require(await worker.next { msg in
            if case .stdin(let pid, _, _) = msg, pid == id2 { return true }
            return false
        })
        if case .stdin(_, let req, _) = stdinMsg2 {
            worker.reply(.stdin(id: id2, req: req, outcome: .failed("Broken pipe")))
        }
        await #expect(throws: MachineDriver.StdinFailed(message: "Broken pipe")) {
            try await h2.stdinTask?.value
        }
        #expect(h2.isRunning() == true)
        #expect(worker.messages.filter { if case .kill = $0 { return true } else { return false } }.isEmpty)
        worker.reply(.output(id: id2, offset: 0, stream: .stdout, data: Array("still running".utf8)))
        worker.reply(.exit(MachineWire.Exit(id: id2, bytes: 13, code: 0)))
        #expect(MachineTestHelper.utf8(try await collectStream(h2.stdout())) == "still running")
        #expect(try await h2.exitCode() == 0)
        worker.drop()
        await serving.value
    }

    @Test("closing a machine fails what still waits on it")
    func close() async throws {
        let machine = MachineDriver.make("gpu")
        let worker = Worker(hello: MachineTestHelper.hello())
        let serving = Task { await machine.connect(worker.connection) }
        #expect(await MachineTestHelper.eventually { machine.hello() != nil })
        let run = Task { try await machine.environment.spawner.run(ProcessSpec(executable: "x", workingDirectory: "/")) }
        _ = try #require(await worker.next { started($0) != nil })
        machine.close(Machines.NotFound(machine: "gpu"))
        await #expect(throws: Machines.NotFound(machine: "gpu")) { try await run.value }
        await serving.value
        #expect(machine.hello() == nil)
        #expect(machine.describe() == nil)
    }

    @Test("file calls go to the worker and come back with the Files contract's errors")
    func files() async throws {
        let machine = MachineDriver.make("gpu")
        let worker = Worker(hello: MachineTestHelper.hello())
        let serving = Task { await machine.connect(worker.connection) }
        #expect(await MachineTestHelper.eventually { machine.hello() != nil })
        let files = machine.environment.files
        typealias Files = CoreLocation.Environment.Files

        let stat = Task { try await files.stat("/a") }
        let call = try #require(await worker.next { if case .fs = $0 { return true } else { return false } })
        guard case .fs(let request) = call else { return }
        #expect(request.call == .stat(path: "/a"))
        worker.reply(.fs(MachineWire.FileReply(req: request.req, outcome: .success(.info(MachineWire.FileInfo(type: .file, size: 3, mtimeMs: 1.5))))))
        #expect(try await stat.value == Files.FileInfo(type: .file, size: 3, mtimeMs: 1))

        let read = Task { try await files.read("/b", range: Files.ReadRange(offset: 1, length: 2)) }
        let readCall = try #require(await worker.next { if case .fs(let c) = $0 { return c.req != request.req } else { return false } })
        guard case .fs(let readRequest) = readCall else { return }
        #expect(readRequest.call == .read(path: "/b", range: MachineWire.Range(offset: 1, length: 2)))
        worker.reply(.fs(MachineWire.FileReply(req: readRequest.req, outcome: .failure(MachineWire.FileError(kind: .wrongKind, message: "dir", actual: .directory)))))
        await #expect(throws: Files.WrongKind(path: "/b", actual: .directory)) { try await read.value }

        let missing = Task { try await files.list("/c") }
        let listCall = try #require(await worker.next { if case .fs(let c) = $0 { return c.call == .list(path: "/c") } else { return false } })
        guard case .fs(let listRequest) = listCall else { return }
        worker.reply(.fs(MachineWire.FileReply(req: listRequest.req, outcome: .failure(MachineWire.FileError(kind: .notFound, message: "gone")))))
        await #expect(throws: Files.NotFound(path: "/c")) { try await missing.value }

        // A call whose connection drops fails as unknown.
        let pending = Task { try await files.mkdir("/d") }
        _ = try #require(await worker.next { if case .fs(let c) = $0 { return c.call == .mkdir(path: "/d") } else { return false } })
        worker.drop()
        await #expect(throws: Files.Failed.self) { try await pending.value }
        await serving.value
    }

    @Test("driver errors read as upstream's")
    func messages() {
        #expect(MachineDriver.NotSent(machine: "gpu").message == "gpu is offline, command not sent")
        #expect(MachineDriver.Unknown(machine: "gpu").message == "Lost connection to gpu. The command may or may not have started.")
        #expect(MachineDriver.ProcessLost(machine: "gpu", restarted: true).message == "gpu's worker restarted, the process was lost")
        #expect(MachineDriver.ProcessLost(machine: "gpu", restarted: false).message == "gpu's worker no longer has the process")
        #expect(MachineDriver.StdinUnknown(machine: "gpu").message == "Lost connection to gpu. The stdin operation's outcome is unknown.")
        #expect(MachineDriver.OutputViewConflict().message == "read either all, or stdout and stderr, not both")
    }
}
