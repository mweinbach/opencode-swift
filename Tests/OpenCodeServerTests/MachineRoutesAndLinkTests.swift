import Synchronization
import Testing
import OpenCodeClient
import OpenCodeCore
import OpenCodePlatform
import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeServer
import OpenCodeUtil

private typealias Helper = MachineIntegrationHelper

@Suite("Server Machine Routes, Link Guards, and Config.automations Tests")
struct MachineRoutesAndLinkTests {
    private static func makeHarness(
        flags: String?,
        configJSON: String? = nil
    ) async throws -> (runtime: ServerAppRuntime, router: ServerRouter, client: OpenCodeClient) {
        var files: [String: [UInt8]] = ["/workspace/README.md": Helper.utf8Bytes("ok\n")]
        if let configJSON {
            files["/workspace/opencode.json"] = Helper.utf8Bytes(configJSON)
        }
        let fs = InMemoryFileSystem(initialFiles: files)
        let env = DictionaryEnvironment(variables: flags.map { ["OPENCODE_FLAGS": $0] } ?? [:])
        let runtime = try await ServerAppRuntime.make(
            options: ServerOptions(password: "pw"),
            fileSystem: fs,
            environment: env,
            defaultDirectory: "/workspace"
        )
        let router = ServerRouter(runtime: runtime)
        let transport = ServerInProcessTransport(handler: { await router.handle($0) })
        let client = OpenCodeClient(
            options: ClientOptions(
                baseUrl: "http://127.0.0.1:4096",
                transport: transport,
                headers: ["authorization": ClientHTTPHeaders.basicAuthorization(username: "opencode", password: "pw")]
            )
        )
        return (runtime, router, client)
    }

    @Test("machine.* HTTP routes return 403 when machines flag is off, and work end-to-end when enabled")
    func machineRoutesFlagAndCRUD() async throws {
        // 1. Flag disabled -> 403 ForbiddenError
        let disabled = try await Self.makeHarness(flags: "-machines")
        defer { Task { await disabled.runtime.close() } }

        do {
            _ = try await disabled.client.experimental.machine.list()
            Issue.record("Expected ForbiddenError when machines flag is off")
        } catch {
            #expect(isForbiddenError(error))
        }

        // Link upgrade returns 404 when machines flag is off
        let (_, serverWS) = InMemoryServerWebSocket.makePair()
        let disabledUpgrade = await disabled.router.handle(ServerHTTPRequest(
            method: "GET",
            url: MACHINE_LINK_PATH,
            headers: ["upgrade": "websocket", "connection": "Upgrade"],
            upgradeWebSocket: { serverWS }
        ))
        #expect(disabledUpgrade.statusCode == 404)

        // 2. Flag enabled -> full CRUD + error codes
        let enabled = try await Self.makeHarness(flags: "machines")
        defer { Task { await enabled.runtime.close() } }

        #expect(try await enabled.client.experimental.machine.list().isEmpty)

        // Invalid name -> 400 InvalidRequestError(kind: "invalid_name")
        do {
            _ = try await enabled.client.experimental.machine.add(ExperimentalMachineAddInput(
                name: "Bad_Name",
                reach: [MachineReach(url: "ws://127.0.0.1:4096/api/experimental/machine/link")]
            ))
            Issue.record("Expected InvalidRequestError for invalid machine name")
        } catch {
            #expect(isInvalidRequestError(error))
        }

        // Add machine returns invite
        let invite = try await enabled.client.experimental.machine.add(ExperimentalMachineAddInput(
            name: "gpu",
            reach: [MachineReach(url: "ws://127.0.0.1:4096/api/experimental/machine/link")]
        ))
        #expect(invite.name == "gpu")
        #expect(invite.join.hasPrefix("ocjoin_"))
        #expect(invite.reach == [.url("ws://127.0.0.1:4096/api/experimental/machine/link")])

        // Re-adding unpaired machine reissues invite rather than failing
        let reinvite = try await enabled.client.experimental.machine.add(ExperimentalMachineAddInput(
            name: "gpu",
            reach: [MachineReach(url: "wss://example.com/api/experimental/machine/link")]
        ))
        #expect(reinvite.name == "gpu")
        #expect(reinvite.join != invite.join)

        // Pair the machine via join secret, then verify add without replace returns 409 ConflictError
        let decoded = try #require(MachineJoin.decode(reinvite.join))
        let workerKey = MachineIdentity.fromSeed([UInt8](repeating: 42, count: 32))
        _ = try await enabled.runtime.machines.join(secret: decoded.secret, key: workerKey.publicKey)

        do {
            _ = try await enabled.client.experimental.machine.add(ExperimentalMachineAddInput(
                name: "gpu",
                reach: [MachineReach(url: "wss://example.com/api/experimental/machine/link")]
            ))
            Issue.record("Expected ConflictError for already-paired machine without replace")
        } catch {
            #expect(isConflictError(error))
        }

        // With replace: true, invite succeeds
        let replaced = try await enabled.client.experimental.machine.add(ExperimentalMachineAddInput(
            name: "gpu",
            reach: [MachineReach(url: "wss://example.com/api/experimental/machine/link")],
            replace: true
        ))
        #expect(replaced.name == "gpu")

        let list = try await enabled.client.experimental.machine.list()
        #expect(list.count == 1)
        #expect(list[0].id == "gpu")
        #expect(list[0].paired == true)
        #expect(list[0].online == false)

        // Remove missing machine -> 404 MachineNotFoundError
        do {
            try await enabled.client.experimental.machine.remove(ExperimentalMachineRemoveInput(name: "missing"))
            Issue.record("Expected MachineNotFoundError")
        } catch {
            #expect(isMachineNotFoundError(error))
        }

        // Remove existing machine -> 204
        try await enabled.client.experimental.machine.remove(ExperimentalMachineRemoveInput(name: "gpu"))
        #expect(try await enabled.client.experimental.machine.list().isEmpty)
    }

    @Test("ServerMachine.keepalive terminates silent transport and preserves active or paused transport")
    func keepaliveBehavior() async {
        final class FakeTransport: ServerMachine.Transport, Sendable {
            struct State {
                var pings = 0
                var terminated = false
                var isPaused = false
                var nextToken: UInt64 = 0
                var listeners: [ServerMachine.TransportEvent: [UInt64: @Sendable () -> Void]] = [:]
            }
            let state = Mutex(State())
            var bufferedAmount: Int { 0 }
            var isPaused: Bool { state.withLock { $0.isPaused } }
            func send(_ message: [UInt8], taken: @escaping @Sendable () -> Void) { taken() }
            func ping() { state.withLock { $0.pings += 1 } }
            func on(_ event: ServerMachine.TransportEvent, _ listener: @escaping @Sendable () -> Void) -> ServerMachine.TransportListenerToken {
                state.withLock { s in
                    s.nextToken += 1
                    s.listeners[event, default: [:]][s.nextToken] = listener
                    return ServerMachine.TransportListenerToken(rawValue: s.nextToken)
                }
            }
            func off(_ event: ServerMachine.TransportEvent, _ token: ServerMachine.TransportListenerToken) {
                state.withLock { _ = $0.listeners[event]?.removeValue(forKey: token.rawValue) }
            }
            func terminate() { state.withLock { $0.terminated = true } }
        }

        let silent = FakeTransport()
        await ServerMachine.keepalive(silent, interval: .milliseconds(25))
        let snap = silent.state.withLock { ($0.pings, $0.terminated) }
        #expect(snap.0 >= 1)
        #expect(snap.1 == true)
    }

    @Test("Automations default enabled from top-level config.automations and disable when false")
    func automationsTopLevelConfig() async throws {
        // Default (unset) -> enabled!
        let defaultHarness = try await Self.makeHarness(flags: nil)
        defer { Task { await defaultHarness.runtime.close() } }
        let listDefault = try await defaultHarness.client.experimental.automation.list(
            ExperimentalAutomationListInput(directory: "/workspace")
        )
        #expect(listDefault.isEmpty)

        // Explicitly disabled via top-level `automations: false` -> 403 ForbiddenError
        let disabledHarness = try await Self.makeHarness(flags: nil, configJSON: #"{"automations":false}"#)
        defer { Task { await disabledHarness.runtime.close() } }
        do {
            _ = try await disabledHarness.client.experimental.automation.list(
                ExperimentalAutomationListInput(directory: "/workspace")
            )
            Issue.record("Expected ForbiddenError when automations is false in config")
        } catch {
            #expect(isForbiddenError(error))
        }
    }
}
