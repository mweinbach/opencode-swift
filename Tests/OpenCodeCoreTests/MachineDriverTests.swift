import Testing
import OpenCodeCore
import OpenCodePlatform

private typealias Worker = MachineTestHelper.FakeWorker

private func started(_ message: MachineWire.ToWorker) -> MachineWire.ProcessID? {
    if case .start(let id, _, _, _) = message { return id }
    return nil
}

@Suite("Machine driver: connections, processes and files")
struct MachineDriverTests {
    @Test("a machine is offline until a worker connects, and serves its hello while connected")
    func onlineAndOffline() async throws {
        let (machines, _, _) = try MachineTestHelper.machines()
        _ = try await machines.add("gpu")
        await #expect(throws: MachineDriver.NotSent(machine: "gpu")) { try await machines.home("gpu") }
        let environment = try await machines.get("gpu")
        await #expect(throws: CoreLocation.Environment.Files.Failed.self) { try await environment.files.stat("/x") }
        await #expect(throws: MachineDriver.NotSent(machine: "gpu")) {
            try await environment.spawner.run(ProcessSpec(executable: "ls", workingDirectory: "/"))
        }
        let worker = Worker(hello: MachineTestHelper.hello())
        let serving = Task { try await machines.connect(worker.connection) }
        #expect(await MachineTestHelper.eventuallyAsync { await machines.list().first?.online == true })
        #expect(try await machines.home("gpu") == "/home/me")
        #expect(await machines.list() == [Machines.Info(id: "gpu", online: true, paired: false, os: "linux", arch: "x64")])
        worker.drop()
        try await serving.value
        #expect(await machines.list() == [Machines.Info(id: "gpu", online: false, paired: false)])
        await #expect(throws: Machines.NotFound(machine: "cpu")) {
            try await machines.connect(Worker(hello: MachineTestHelper.hello(name: "cpu")).connection)
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
        guard case .start(let id, let argv, let cwd, let env) = start else { return }
        #expect(argv == ["echo", "hi"] && cwd == "/work" && env == ["A": "1"])
        worker.reply(.started(id: id, pid: 42))
        worker.reply(.output(id: id, offset: 0, data: Array("hel".utf8)))
        // A repeat of bytes already delivered is trimmed; a chunk past a gap is dropped.
        worker.reply(.output(id: id, offset: 1, data: Array("ello".utf8)))
        worker.reply(.output(id: id, offset: 9, data: Array("zz".utf8)))
        worker.reply(.exit(MachineWire.Exit(id: id, bytes: 7, code: 0)))
        _ = try #require(await worker.next { $0 == .attach(id: id, from: 5) })
        worker.reply(.output(id: id, offset: 5, data: Array("!\n".utf8)))
        worker.reply(.exit(MachineWire.Exit(id: id, bytes: 7, code: 3)))
        let output = try await run.value
        #expect(output.exitCode == 3)
        #expect(String(decoding: output.stdout, as: UTF8.self) == "hello!\n")
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
        await #expect(throws: MachineDriver.Unsupported.self) {
            try await spawner.run(ProcessSpec(executable: "cat", workingDirectory: "/", stdin: [1]))
        }

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

    @Test("a reconnect from the same worker resumes a process; a restarted worker loses it")
    func reconnect() async throws {
        let machine = MachineDriver.make("gpu")
        let first = Worker(hello: MachineTestHelper.hello(instance: "one"))
        let serving = Task { await machine.connect(first.connection) }
        #expect(await MachineTestHelper.eventually { machine.hello() != nil })
        let run = Task { try await machine.environment.spawner.run(ProcessSpec(executable: "make", workingDirectory: "/")) }
        let id = try #require(await first.next { started($0) != nil }.flatMap(started))
        first.reply(.started(id: id, pid: 7))
        first.reply(.output(id: id, offset: 0, data: [65]))
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
        second.reply(.output(id: id, offset: 1, data: [66]))
        second.reply(.exit(MachineWire.Exit(id: id, bytes: 2, code: 0)))
        #expect(try await run.value.stdout == [65, 66])

        let lost = Task { try await machine.environment.spawner.run(ProcessSpec(executable: "train", workingDirectory: "/")) }
        let other = try #require(await second.next { started($0) != nil && started($0) != id }.flatMap(started))
        second.reply(.started(id: other, pid: 8))
        // Ensure `second`'s stream reader has processed `.started` before the worker restarts.
        try await flushWorkerMessages(second, on: machine)
        // An exited process the home no longer tracks is released again.
        let third = Worker(hello: MachineTestHelper.hello(
            instance: "two",
            processes: [MachineWire.HelloProcess(id: MachineWire.ProcessID("old"), pid: 1, state: .exited, bytes: 0, code: .some(0))]
        ))
        let restarted = Task { await machine.connect(third.connection) }
        await #expect(throws: MachineDriver.ProcessLost(machine: "gpu", restarted: true)) { try await lost.value }
        _ = try #require(await third.next { $0 == .release(id: MachineWire.ProcessID("old")) })
        await resumed.value
        third.drop()
        await restarted.value
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
    }
}
