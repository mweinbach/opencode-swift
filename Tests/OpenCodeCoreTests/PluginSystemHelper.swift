#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Synchronization
import OpenCodeAI
import OpenCodeCore
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

/// Helper utilities and mock transports for `PluginSystemTests`.
/// Intentionally does NOT `import Testing` (macOS CLT cross-import overlay rule).
enum PluginSystemHelper {
    static func encodeJSON<T: Encodable>(_ value: T) throws -> [UInt8] {
        Array(try JSONEncoder().encode(value))
    }

    static func decodeJSON<T: Decodable>(_ type: T.Type, from bytes: [UInt8]) throws -> T {
        try JSONDecoder().decode(type, from: Data(bytes))
    }

    static func utf8Bytes(_ text: String) -> [UInt8] {
        Array(text.utf8)
    }

    static func makeInMemorySQLiteKVStore() throws -> CorePlugin.SQLiteKVStore {
        let db = try SQLiteDatabaseFactory.open()
        return try CorePlugin.SQLiteKVStore(database: db)
    }

    /// Deterministic async gate used to pause a slow plugin during activation tests without sleep polling.
    final class AsyncGate: Sendable {
        private struct State: Sendable {
            var opened: Bool = false
            var entered: Bool = false
            var enterWaiters: [CheckedContinuation<Void, Never>] = []
            var openWaiters: [CheckedContinuation<Void, Never>] = []
        }

        private let state = Mutex(State())

        func markEnteredAndWait() async {
            let enterResumes: [CheckedContinuation<Void, Never>] = state.withLock { s in
                s.entered = true
                let list = s.enterWaiters
                s.enterWaiters.removeAll()
                return list
            }
            for c in enterResumes { c.resume() }

            let alreadyOpen = state.withLock { $0.opened }
            if alreadyOpen { return }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = state.withLock { s -> Bool in
                    if s.opened { return true }
                    s.openWaiters.append(continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }

        func waitUntilEntered() async {
            let already = state.withLock { $0.entered }
            if already { return }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = state.withLock { s -> Bool in
                    if s.entered { return true }
                    s.enterWaiters.append(continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }

        func open() {
            let waiters: [CheckedContinuation<Void, Never>] = state.withLock { s in
                s.opened = true
                let list = s.openWaiters
                s.openWaiters.removeAll()
                return list
            }
            for c in waiters { c.resume() }
        }
    }

    /// Thread-safe event log recorder for verifying lifecycle ordering.
    final class TraceRecorder: Sendable {
        private let items = Mutex<[String]>([])

        func record(_ event: String) {
            items.withLock { $0.append(event) }
        }

        func snapshot() -> [String] {
            items.withLock { $0 }
        }
    }

    /// Mock JSON-RPC 2.0 transport simulating an out-of-process JS/TS plugin host.
    final class MockRPCTransport: CorePlugin.RPCBridge.Transport, Sendable {
        private struct State: Sendable {
            var requests: [CorePlugin.RPCBridge.Request] = []
            var closed: Bool = false
        }

        private let state = Mutex(State())
        private let handshake: CorePlugin.RPCBridge.Handshake

        init(handshake: CorePlugin.RPCBridge.Handshake) {
            self.handshake = handshake
        }

        func recordedMethods() -> [String] {
            state.withLock { $0.requests.map(\.method) }
        }

        func isClosed() -> Bool {
            state.withLock { $0.closed }
        }

        func send(_ request: CorePlugin.RPCBridge.Request) async throws -> CorePlugin.RPCBridge.Response {
            state.withLock { $0.requests.append(request) }
            switch request.method {
            case "plugin.initialize":
                let data = try JSONEncoder().encode(handshake)
                let json = try JSONDecoder().decode(JSONValue.self, from: data)
                return CorePlugin.RPCBridge.Response(id: request.id, result: json)

            case "plugin.tool.execute":
                if case .object(let params) = request.params,
                   case .string(let name) = params["name"]
                {
                    return CorePlugin.RPCBridge.Response(
                        id: request.id,
                        result: .object([
                            "executedBy": .string("remote-rpc"),
                            "tool": .string(name),
                            "echo": params["input"] ?? .null,
                        ])
                    )
                }
                return CorePlugin.RPCBridge.Response(
                    id: request.id,
                    error: CorePlugin.RPCBridge.ErrorObject(code: -32_602, message: "Invalid tool params")
                )

            case "plugin.hook.trigger":
                if case .object(let params) = request.params,
                   case .string(let domain) = params["domain"],
                   case .string(let name) = params["name"],
                   case .object(var payload) = params["payload"]
                {
                    if domain == "shell" && name == "create.before",
                       case .string(let cmd) = payload["command"]
                    {
                        payload["command"] = .string("rpc-wrapped: \(cmd)")
                        return CorePlugin.RPCBridge.Response(id: request.id, result: .object(payload))
                    }
                    if domain == "permission" && name == "evaluate" {
                        payload["effect"] = .string("deny")
                        payload["message"] = .string("Denied by remote JSON-RPC plugin")
                        return CorePlugin.RPCBridge.Response(id: request.id, result: .object(payload))
                    }
                }
                return CorePlugin.RPCBridge.Response(id: request.id, result: .null)

            case "plugin.shutdown":
                return CorePlugin.RPCBridge.Response(id: request.id, result: .bool(true))

            default:
                return CorePlugin.RPCBridge.Response(
                    id: request.id,
                    error: CorePlugin.RPCBridge.ErrorObject(code: -32_601, message: "Method not found: \(request.method)")
                )
            }
        }

        func close() async {
            state.withLock { $0.closed = true }
        }
    }

    /// Sample native Swift plugin conforming directly to `PluginSDK.NativePlugin`.
    struct SampleNativePlugin: PluginSDK.NativePlugin {
        let id: String
        let recorder: TraceRecorder

        func activate(in context: PluginEffect.Context) async throws -> (@Sendable () async -> Void)? {
            recorder.record("native:\(id):activate")
            _ = await context.tool.transform { editor in
                editor.add(
                    PluginEffect.DynamicToolInfo(
                        name: "native_echo",
                        input: .jsonSchema(["type": .string("object")]),
                        description: "Echoes input from native Swift plugin",
                        execute: { input, _ throws(ToolSchema.ToolError) in
                            ToolSchema.Result(output: input)
                        }
                    )
                )
            }
            let rec = recorder
            let pluginID = id
            return {
                rec.record("native:\(pluginID):cleanup")
            }
        }
    }

    struct FailingTestError: Error, Sendable, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    static func makeCoreService(
        environment: CorePlugin.Host.Environment,
        fileSystem: any OpenCodeFileSystem = InMemoryFileSystem(),
        onInventoryChanged: (@Sendable ([PluginSchema.Info]) -> Void)? = nil
    ) -> CorePlugin.Service {
        CorePlugin.Service(
            fileSystem: fileSystem,
            onInventoryChanged: onInventoryChanged
        ) { pluginID, listInventory, addFinalizer in
            CorePlugin.Host.make(
                environment: environment,
                pluginID: pluginID,
                listPlugins: listInventory,
                addFinalizer: addFinalizer
            )
        }
    }

    static func makeSampleHTTPRequest(url: String = "https://api.example.com/v1/chat") -> HTTPRequest {
        HTTPRequest(method: "POST", url: url, headers: ["X-Initial": "1"])
    }

    static func makeSampleSessionID(_ suffix: String = "0001") -> SessionID {
        SessionID(rawValue: "ses_\(suffix)")!
    }
}
