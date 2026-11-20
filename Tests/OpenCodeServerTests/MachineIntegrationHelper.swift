#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Synchronization
import OpenCodeCore
import OpenCodePlatform
import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeServer
import OpenCodeUtil

/// Non-Testing helpers for `MachineIntegrationTests` (keeps Foundation out of files that `import Testing`).
enum MachineIntegrationHelper {
    /// Records every process start sent to the in-process worker.
    struct RecordedRun: Equatable, Sendable {
        let id: MachineWire.ProcessID
        let argv: [String]
        let cwd: String
        let env: [String: String]
    }

    /// In-process machine worker backed by `CoreLocation.Environment.MemoryDriver` and a programmable command handler.
    /// Speaks the real `MachineLink.dial` Noise XX handshake and encrypted JSON `MachineWire` framing over any
    /// `ServerWebSocketConnection`.
    final class InProcessWorker: Sendable {
        let name: String
        let home: String
        let os: String
        let arch: String
        let instance: MachineWire.Instance
        let identity: MachineIdentity.Key
        let files: CoreLocation.Environment.MemoryDriver
        private let onRun: @Sendable (RecordedRun) async -> (output: [UInt8], exitCode: Int)
        private let runsBox = Mutex<[RecordedRun]>([])
        private let nextPID = Mutex(1000)
        private let clientSocketBox = Mutex<(any ServerWebSocketConnection)?>(nil)
        private let workerTaskBox = Mutex<Task<Void, Never>?>(nil)
        private let serverTaskBox = Mutex<Task<ServerHTTPResponse, Never>?>(nil)
        private let directConnectTaskBox = Mutex<Task<Void, Never>?>(nil)
        private let directFinishBox = Mutex<(@Sendable () -> Void)?>(nil)

        init(
            name: String = "gpu",
            home: String = "/home/gpu",
            os: String = "linux",
            arch: String = "arm64",
            instance: String = "inst-1",
            seed: [UInt8] = [UInt8](repeating: 7, count: 32),
            initialFiles: [String: String] = [:],
            onRun: @escaping @Sendable (RecordedRun) async -> (output: [UInt8], exitCode: Int) = { run in
                (Array("ran \(run.argv.joined(separator: " ")) in \(run.cwd)\n".utf8), 0)
            }
        ) async throws {
            self.name = name
            self.home = home
            self.os = os
            self.arch = arch
            self.instance = MachineWire.Instance(instance)
            self.identity = MachineIdentity.fromSeed(seed)
            let driver = CoreLocation.Environment.makeMemoryDriver()
            try await driver.mkdir(home)
            for (path, text) in initialFiles {
                if let slash = path.lastIndex(of: "/"), slash != path.startIndex {
                    try await driver.mkdir(String(path[..<slash]))
                }
                try await driver.write(path, bytes: Array(text.utf8))
            }
            self.files = driver
            self.onRun = onRun
        }

        var recordedRuns: [RecordedRun] {
            runsBox.withLock { $0 }
        }

        /// Dials the server's `/api/machine/link` WebSocket route through `router`, completing the Noise XX
        /// handshake and serving encrypted `MachineWire` frames in the background until `disconnect()` is called.
        @discardableResult
        func dial(
            router: ServerRouter,
            homeKey: [UInt8],
            secret: [UInt8]? = nil
        ) async throws -> String {
            let (clientWS, serverWS) = InMemoryServerWebSocket.makePair()
            let request = ServerHTTPRequest(
                method: "GET",
                url: MACHINE_LINK_PATH,
                headers: ["upgrade": "websocket"],
                upgradeWebSocket: { serverWS }
            )
            let serverTask = Task { await router.handle(request) }
            serverTaskBox.withLock { $0 = serverTask }
            clientSocketBox.withLock { $0 = clientWS }

            let carrier = ServerWebSocketCarrier(socket: clientWS)
            let established: MachineLink.Established
            do {
                established = try await MachineLink.dial(
                    carrier,
                    options: MachineLink.DialOptions(home: homeKey, identity: identity, secret: secret)
                )
            } catch {
                carrier.stop()
                await clientWS.close(code: 1000, reason: "")
                _ = await serverTask.value
                throw error
            }

            let hello = MachineWire.Hello(
                name: established.machine,
                os: os,
                arch: arch,
                home: home,
                instance: instance,
                processes: []
            )
            // Send the encrypted Hello before returning so the server serves it immediately.
            let helloPlain = try JSONEncoder().encode(MachineWire.FromWorker.hello(hello))
            let helloCipher = try established.send.encrypt(Array(helloPlain))
            try await clientWS.send(.binary(helloCipher))

            let (outbox, outboxCont) = AsyncStream<MachineWire.FromWorker>.makeStream()

            let workerTask = Task { [self] in
                defer { carrier.stop() }
                let writer = Task {
                    let encoder = JSONEncoder()
                    for await msg in outbox {
                        if Task.isCancelled { break }
                        guard let plain = try? encoder.encode(msg),
                              let cipher = try? established.send.encrypt(Array(plain))
                        else { break }
                        do {
                            try await clientWS.send(.binary(cipher))
                        } catch {
                            break
                        }
                    }
                }
                let decoder = JSONDecoder()
                while !Task.isCancelled {
                    guard let frame = try? await carrier.receive(),
                          let plain = try? established.receive.decrypt(frame),
                          let msg = try? decoder.decode(MachineWire.ToWorker.self, from: Data(plain))
                    else {
                        break
                    }
                    await self.handle(msg, reply: { outboxCont.yield($0) })
                }
                outboxCont.finish()
                writer.cancel()
            }
            workerTaskBox.withLock { $0 = workerTask }
            return established.machine
        }

        /// Connects the in-process worker directly to `machines.connect` (for fast driver/tool tests without
        /// repeating the Noise handshake).
        func connectDirectly(to machines: any Machines.Interface) {
            let hello = MachineWire.Hello(
                name: name,
                os: os,
                arch: arch,
                home: home,
                instance: instance,
                processes: []
            )
            let (fromWorker, fromWorkerCont) = AsyncStream<MachineWire.FromWorker>.makeStream()
            let (toWorker, toWorkerCont) = AsyncStream<MachineWire.ToWorker>.makeStream()

            let pumpTask = Task { [self] in
                for await msg in toWorker {
                    if Task.isCancelled { break }
                    await self.handle(msg, reply: { fromWorkerCont.yield($0) })
                }
            }
            workerTaskBox.withLock { $0 = pumpTask }
            directFinishBox.withLock {
                $0 = {
                    toWorkerCont.finish()
                    fromWorkerCont.finish()
                }
            }

            let connection = MachineDriver.Connection(
                hello: hello,
                send: { toWorkerCont.yield($0) },
                messages: fromWorker
            )
            let connectTask = Task {
                _ = try? await machines.connect(connection)
            }
            directConnectTaskBox.withLock { $0 = connectTask }
        }

        func disconnect() async {
            let finishDirect = directFinishBox.withLock { current -> (@Sendable () -> Void)? in
                let old = current
                current = nil
                return old
            }
            finishDirect?()
            let ws = clientSocketBox.withLock { current -> (any ServerWebSocketConnection)? in
                let old = current
                current = nil
                return old
            }
            await ws?.close(code: 1000, reason: "")
            let workerTask = workerTaskBox.withLock { current -> Task<Void, Never>? in
                let old = current
                current = nil
                return old
            }
            workerTask?.cancel()
            await workerTask?.value
            let serverTask = serverTaskBox.withLock { current -> Task<ServerHTTPResponse, Never>? in
                let old = current
                current = nil
                return old
            }
            _ = await serverTask?.value
            let directTask = directConnectTaskBox.withLock { current -> Task<Void, Never>? in
                let old = current
                current = nil
                return old
            }
            await directTask?.value
        }

        private func handle(
            _ message: MachineWire.ToWorker,
            reply: @escaping @Sendable (MachineWire.FromWorker) -> Void
        ) async {
            switch message {
            case .fs(let call):
                let outcome = await handleFS(call.call)
                reply(.fs(MachineWire.FileReply(req: call.req, outcome: outcome)))
            case .start(let id, let argv, let cwd, let env):
                let run = RecordedRun(id: id, argv: argv, cwd: cwd, env: env)
                runsBox.withLock { $0.append(run) }
                let pid = nextPID.withLock { n -> Int in
                    n += 1
                    return n
                }
                reply(.started(id: id, pid: pid))
                let result = await onRun(run)
                if !result.output.isEmpty {
                    reply(.output(id: id, offset: 0, data: result.output))
                }
                reply(.exit(MachineWire.Exit(id: id, bytes: result.output.count, code: result.exitCode)))
            case .attach, .kill, .release:
                break
            }
        }

        private func handleFS(_ call: MachineWire.Call) async -> Result<MachineWire.FileResult, MachineWire.FileError> {
            do {
                switch call {
                case .stat(let path):
                    let info = try await files.stat(path)
                    return .success(.info(MachineWire.FileInfo(type: info.type, size: Double(info.size), mtimeMs: Double(info.mtimeMs))))
                case .list(let path):
                    let entries = try await files.list(path)
                    return .success(.list(entries.map { MachineWire.DirEntry(name: $0.name, type: $0.type) }))
                case .read(let path, let range):
                    let envRange = range.map { CoreLocation.Environment.Files.ReadRange(offset: $0.offset, length: $0.length) }
                    let res = try await files.read(path, range: envRange)
                    let info = MachineWire.FileInfo(type: res.info.type, size: Double(res.info.size), mtimeMs: Double(res.info.mtimeMs))
                    return .success(.read(MachineWire.ReadResult(info: info, bytes: res.bytes)))
                case .write(let path, let bytes):
                    try await files.write(path, bytes: bytes)
                    return .success(.none)
                case .append(let path, let bytes):
                    try await files.append(path, bytes: bytes)
                    return .success(.none)
                case .remove(let path):
                    try await files.remove(path)
                    return .success(.none)
                case .mkdir(let path):
                    try await files.mkdir(path)
                    return .success(.none)
                case .move(let from, let to):
                    try await files.move(from: from, to: to)
                    return .success(.none)
                }
            } catch is CoreLocation.Environment.Files.NotFound {
                return .failure(MachineWire.FileError(kind: .notFound, message: "Not found"))
            } catch let wrong as CoreLocation.Environment.Files.WrongKind {
                return .failure(MachineWire.FileError(kind: .wrongKind, message: wrong.description, actual: wrong.actual))
            } catch {
                return .failure(MachineWire.FileError(kind: .failed, message: String(describing: error)))
            }
        }
    }

    static func eventually(
        timeoutMs: Int = 10_000,
        _ condition: @Sendable () async -> Bool
    ) async -> Bool {
        let attempts = max(1, timeoutMs / 10)
        for _ in 0..<attempts {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    static func executeTool(
        snapshot: CoreTool.Snapshot,
        name: String,
        args: [String: JSONValue],
        sessionID: String = "ses_machine_int"
    ) async throws -> CoreTool.NormalizedResult {
        try await snapshot.execute(CoreTool.ExecuteCallInput(
            sessionID: SessionID(rawValue: sessionID)!,
            agent: AgentSchema.ID(rawValue: "build"),
            messageID: "msg_machine_int",
            callID: ToolSchema.CallID(rawValue: "c_\(name)"),
            name: name,
            input: .object(args)
        ))
    }

    static func allowAllRules() -> PermissionSchema.Ruleset {
        [PermissionSchema.Rule(action: "*", resource: "*", effect: .allow)]
    }

    static func utf8String(_ bytes: [UInt8]) -> String {
        String(decoding: bytes, as: UTF8.self)
    }

    static func utf8Bytes(_ text: String) -> [UInt8] {
        Array(text.utf8)
    }

    static func firstText(from result: CoreTool.NormalizedResult) -> String {
        for item in result.content {
            if case .text(let tc) = item { return tc.text }
        }
        return ""
    }

    static func insertDueAutomation(
        db: any SQLiteDatabase,
        id: String,
        directory: String,
        name: String,
        nowMs: Int64
    ) throws {
        let pastDue = nowMs - 5_000
        let trigger = #"{"type":"at","at":"2020-01-01T00:00:00Z"}"#
        let action = #"{"type":"prompt","prompt":"ping","to":{"session":"ses_auto_int"}}"#
        _ = try db.execute(
            """
            INSERT INTO automation (
                id, project_id, session_id, directory, name, trigger, tz, action,
                status, next_due_at, expires_at, run_count, failures, time_created, time_updated
            ) VALUES (?, 'global', 'ses_auto_int', ?, ?, ?, 'UTC', ?, 'active', ?, NULL, 0, 0, ?, ?)
            """,
            parameters: [
                .text(id),
                .text(directory),
                .text(name),
                .text(trigger),
                .text(action),
                .integer(pastDue),
                .integer(pastDue),
                .integer(pastDue),
            ]
        )
    }

    static func automationLeaderRowExists(db: any SQLiteDatabase) -> Bool {
        (try? db.queryOne("SELECT value FROM kv WHERE key = 'automation:leader'", parameters: [])) != nil
    }

    static func decodeJSON(_ bytes: [UInt8]) throws -> [String: JSONValue] {
        let val = try JSONDecoder().decode(JSONValue.self, from: Data(bytes))
        guard case .object(let obj) = val else { return [:] }
        return obj
    }

    static func flattenStrings(_ value: JSONValue?) -> [String] {
        switch value {
        case .string(let s): return [s]
        case .array(let items): return items.flatMap { flattenStrings($0) }
        case .object(let obj): return obj.keys.sorted().flatMap { flattenStrings(obj[$0]) }
        default: return []
        }
    }
}
