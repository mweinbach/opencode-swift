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

/// Non-Testing test fixture helper (keeps Foundation isolated from `import Testing` on macOS CLT).
enum SessionDatabaseHelper {
    final class SessionIDLog: Sendable {
        private let state = Mutex<[SessionID]>([])

        init() {}

        func append(_ id: SessionID) {
            state.withLock { $0.append(id) }
        }

        func snapshot() -> [SessionID] {
            state.withLock { $0 }
        }
    }

    final class RecordingExecution: CoreSessionExecution.Interface, Sendable {
        let log: SessionIDLog

        init(log: SessionIDLog = SessionIDLog()) {
            self.log = log
        }

        func active() async -> Set<SessionID> { [] }
        func isActive(_ sessionID: SessionID) async -> Bool { false }
        func resume(_ sessionID: SessionID) async throws {}
        func wake(_ sessionID: SessionID) async { log.append(sessionID) }
        func interrupt(_ sessionID: SessionID, resume: Bool) async -> Bool { false }
        func awaitIdle(_ sessionID: SessionID) async {}
    }

    struct TestHarness: Sendable {
        let dbService: CoreDatabaseStore.Service
        let db: any SQLiteDatabase
        let bus: CoreBus.Service
        let store: CoreSessionStore.Service
        let inbox: CoreSessionInbox.Service
        let environment: CoreSessionEnvironment.Service
        let wakeLog: SessionIDLog
        let session: CoreSession.Service
        let dbPath: String
    }

    static func makeTempDBPath(prefix: String = "opencode-core-test") -> String {
        let base = FileManager.default.temporaryDirectory.path
        var trimmed = base
        while trimmed.count > 1 && (trimmed.hasSuffix("/") || trimmed.hasSuffix("\\")) {
            trimmed.removeLast()
        }
        return "\(trimmed)/\(prefix)-\(Identifier.ascending()).sqlite"
    }

    static func cleanupTempDB(at path: String) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
    }

    static func makeHarness(
        inMemory: Bool = true,
        persistEvents: Bool = false,
        projectorOptions: CoreSessionProjector.Options = CoreSessionProjector.Options(),
        execution: (any CoreSessionExecution.Interface)? = nil
    ) async throws -> TestHarness {
        let path = inMemory ? ":memory:" : makeTempDBPath()
        let dbService = try await CoreDatabaseStore.open(
            options: CoreDatabaseStore.Options(path: path),
            legacyCredentials: false
        )
        let db = dbService.db

        let bus = CoreBus.Service(db: db, options: CoreBus.Options(persist: persistEvents))
        CoreSessionProjector.register(bus: bus, db: db, options: projectorOptions)

        let store = CoreSessionStore.Service(db: db)
        let inbox = CoreSessionInbox.Service(db: db, bus: bus)
        let env = CoreSessionEnvironment.Service()
        let wakeLog = SessionIDLog()

        let exec = execution ?? RecordingExecution(log: wakeLog)
        let session = CoreSession.Service(
            db: db,
            bus: bus,
            store: store,
            inbox: inbox,
            execution: exec,
            environment: env
        )

        return TestHarness(
            dbService: dbService,
            db: db,
            bus: bus,
            store: store,
            inbox: inbox,
            environment: env,
            wakeLog: wakeLog,
            session: session,
            dbPath: path
        )
    }

    static func makeMockLanguageModel(
        provider: String = "mock",
        id: String = "mock-model"
    ) -> AISchema.LanguageModel {
        let route = AIRoute.AnyRoute(
            id: "mock-route",
            provider: AISchema.ProviderID.make(provider),
            providerMetadataKey: provider,
            protocolID: "mock-protocol",
            baseURL: "https://mock.local",
            buildBody: { _ in .object([:]) },
            executeStream: { _, _, _ in
                AsyncThrowingStream { $0.finish() }
            }
        )
        return AISchema.LanguageModel.make(AISchema.LanguageModel.Input(
            id: id,
            provider: provider,
            route: route
        ))
    }

    static func makeResolvedModel(
        provider: String = "mock",
        id: String = "mock-model",
        contextLimit: Int = 200_000,
        outputLimit: Int = 32_000,
        costs: [ModelSchema.Cost] = []
    ) -> CoreSessionRunnerModel.Resolved {
        CoreSessionRunnerModel.resolved(
            makeMockLanguageModel(provider: provider, id: id),
            capabilities: ModelSchema.Capabilities(tools: true, input: ["text", "image"], output: ["text"]),
            cost: costs,
            limit: ModelSchema.Info.Limit(context: contextLimit, output: outputLimit)
        )
    }

    final class ScriptedLLMClient: AIRoute.Interface, @unchecked Sendable {
        enum StepScript: Sendable {
            case events([AISchema.LLMEvent])
            case error(any Error & Sendable)
            case delayedEvents(delayMs: Int, events: [AISchema.LLMEvent])
        }

        private let state: Mutex<(scripts: [StepScript], requests: [AISchema.LLMRequest])>

        init(scripts: [StepScript]) {
            self.state = Mutex((scripts, []))
        }

        func capturedRequests() -> [AISchema.LLMRequest] {
            state.withLock { $0.requests }
        }

        func stream(
            _ request: AISchema.LLMRequest,
            options: AIRoute.StreamOptions?
        ) -> AsyncThrowingStream<AISchema.LLMEvent, Error> {
            _ = options
            let script: StepScript = state.withLock { s in
                s.requests.append(request)
                if s.scripts.isEmpty {
                    return .events([
                        .finish(AISchema.Finish(
                            reason: AISchema.FinishReasonDetails(normalized: .stop),
                            usage: AISchema.Usage(outputTokens: 5, nonCachedInputTokens: 10)
                        )),
                    ])
                }
                return s.scripts.removeFirst()
            }

            return AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        switch script {
                        case .events(let list):
                            for ev in list {
                                try Task.checkCancellation()
                                continuation.yield(ev)
                            }
                            continuation.finish()
                        case .error(let err):
                            continuation.finish(throwing: err)
                        case .delayedEvents(let delayMs, let list):
                            try await Task.sleep(for: .milliseconds(delayMs))
                            for ev in list {
                                try Task.checkCancellation()
                                continuation.yield(ev)
                            }
                            continuation.finish()
                        }
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }

        func generate(
            _ request: AISchema.LLMRequest,
            options: AIRoute.StreamOptions?
        ) async throws -> AISchema.LLMResponse {
            try await AIRoute.generateWith { req, opts in
                self.stream(req, options: opts)
            }(request, options)
        }

        func compact(
            _ request: AISchema.LLMRequest,
            options: AIRoute.CompactOptions
        ) async throws -> AIRoute.CompactionResult {
            _ = (request, options)
            return .endpoint(AISchema.CompactionResponse(
                replacement: [AISchema.Message.user("Compacted window")],
                usage: AISchema.Usage(outputTokens: 20, nonCachedInputTokens: 50)
            ))
        }
    }

    static func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    static func decodeJSON<T: Decodable>(_ json: String, as type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    static func makeSamplePNGBytes() -> [UInt8] {
        [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D]
    }

    static func makeSampleDataURL() -> String {
        "data:image/png;base64,\(bytesToBase64(makeSamplePNGBytes()))"
    }
}
