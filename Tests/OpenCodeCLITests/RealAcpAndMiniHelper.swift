#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Synchronization
import OpenCodeCLIKit
import OpenCodeClient
import OpenCodePlatform
import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeTUI
import OpenCodeUtil

/// Helpers, mock streaming HTTP/SSE transport, byte pipes, and recording footer for `RealAcpAndMiniTests`.
/// Intentionally does NOT `import Testing` (macOS Command Line Tools cross-import rule).

/// Thread-safe FIFO byte pipe enabling in-memory raw byte streams for `CLIACP.NDJSONStream.fromBytes`.
final class InMemoryBytePipe: Sendable {
    private struct State: Sendable {
        var chunks: [[UInt8]] = []
        var continuation: AsyncThrowingStream<[UInt8], any Error>.Continuation?
        var closed: Bool = false
    }

    private let state = Mutex(State())

    func makeStream() -> AsyncThrowingStream<[UInt8], any Error> {
        AsyncThrowingStream { continuation in
            let initial = self.state.withLock { s -> ([[UInt8]], Bool) in
                s.continuation = continuation
                let pending = s.chunks
                s.chunks.removeAll()
                return (pending, s.closed)
            }
            for chunk in initial.0 {
                continuation.yield(chunk)
            }
            if initial.1 {
                continuation.finish()
            }
        }
    }

    func write(_ bytes: [UInt8]) {
        let cont = state.withLock { s -> AsyncThrowingStream<[UInt8], any Error>.Continuation? in
            if s.closed { return nil }
            if let cont = s.continuation {
                return cont
            }
            s.chunks.append(bytes)
            return nil
        }
        cont?.yield(bytes)
    }

    func close() {
        let cont = state.withLock { s -> AsyncThrowingStream<[UInt8], any Error>.Continuation? in
            if s.closed { return nil }
            s.closed = true
            let c = s.continuation
            s.continuation = nil
            return c
        }
        cont?.finish()
    }
}

/// Pushable SSE byte-stream hub simulating a real `/api/event` OpenCode server SSE endpoint.
final class MockSSEEventHub: Sendable {
    private struct State: Sendable {
        var nextID: UInt64 = 1
        var streams: [UInt64: AsyncThrowingStream<[UInt8], any Error>.Continuation] = [:]
        var closed: Bool = false
    }

    private let state = Mutex(State())

    func openStream() -> HTTPStreamingResponse {
        let id = state.withLock { s -> UInt64 in
            let current = s.nextID
            s.nextID &+= 1
            return current
        }
        let chunks = AsyncThrowingStream<[UInt8], any Error> { continuation in
            let alreadyClosed = self.state.withLock { s -> Bool in
                if s.closed { return true }
                s.streams[id] = continuation
                return false
            }
            if alreadyClosed {
                continuation.finish()
                return
            }
            // Send initial server.connected SSE frame just like OpenCodeServer.
            let connected = Self.encodeSSEFrame(
                OpenCodeEvent(id: "evt_connected_\(id)", type: "server.connected", created: 1_700_000_000_000, data: .object([:]))
            )
            continuation.yield(connected)
            continuation.onTermination = { [weak self] _ in
                _ = self?.state.withLock { $0.streams.removeValue(forKey: id) }
            }
        }
        return HTTPStreamingResponse(
            head: HTTPResponseHead(statusCode: 200, headers: ["content-type": "text/event-stream"]),
            chunks: chunks
        )
    }

    func emit(_ event: OpenCodeEvent) {
        let frame = Self.encodeSSEFrame(event)
        let targets = state.withLock { Array($0.streams.values) }
        for cont in targets {
            cont.yield(frame)
        }
    }

    func closeAll() {
        let targets = state.withLock { s -> [AsyncThrowingStream<[UInt8], any Error>.Continuation] in
            s.closed = true
            let values = Array(s.streams.values)
            s.streams.removeAll()
            return values
        }
        for cont in targets {
            cont.finish()
        }
    }

    static func encodeSSEFrame(_ event: OpenCodeEvent) -> [UInt8] {
        let encoder = JSONEncoder()
        let data = (try? encoder.encode(event)) ?? Data("{}".utf8)
        let json = String(decoding: data, as: UTF8.self)
        return Array("data: \(json)\n\n".utf8)
    }
}

/// Recorded HTTP request snapshot for assertions without Foundation imports in `@Test` files.
struct RecordedMockHTTPRequest: Sendable {
    let method: String
    let url: String
    let headers: [String: String]
    let bodyUTF8: String
}

/// Mock `HTTPTransport` implementing full OpenCode REST + SSE `/api/event` endpoints for real ACP and Mini tests.
final class MockOpenCodeServerTransport: HTTPTransport, Sendable {
    typealias PromptReplyGenerator = @Sendable (_ sessionID: String, _ messageID: String, _ text: String, _ hub: MockSSEEventHub) -> Void

    private struct State: Sendable {
        var requests: [RecordedMockHTTPRequest] = []
        var sessions: [String: SessionSchema.Info] = [:]
        var nextSessionSeq: Int = 1
        var promptTexts: [String] = []
    }

    let sseHub = MockSSEEventHub()
    private let sessionPrefix: String
    private let onPrompt: PromptReplyGenerator
    private let state = Mutex(State())

    init(
        sessionPrefix: String = "ses_real_",
        onPrompt: @escaping PromptReplyGenerator
    ) {
        self.sessionPrefix = sessionPrefix
        self.onPrompt = onPrompt
    }

    var requests: [RecordedMockHTTPRequest] {
        state.withLock { $0.requests }
    }

    var promptTexts: [String] {
        state.withLock { $0.promptTexts }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let bodyString = request.body.map { String(decoding: $0, as: UTF8.self) } ?? ""
        state.withLock {
            $0.requests.append(RecordedMockHTTPRequest(
                method: request.method,
                url: request.url,
                headers: request.headers,
                bodyUTF8: bodyString
            ))
        }
        let path = Self.extractPath(from: request.url)

        let defaultLocation = LocationSchema.PublicRef(directory: SchemaPrimitive.AbsolutePath(rawValue: "/workspace"))

        if request.method == "GET" && path == "/api/plugin" {
            let plugin = PluginSchema.Info(
                id: PluginSchema.ID(rawValue: "builtin"),
                source: .builtin,
                features: PluginSchema.Features(server: true),
                state: .active
            )
            return Self.encodedResponse(LocationSchema.ResponseEnvelope(location: defaultLocation, data: [plugin]))
        }

        if request.method == "GET" && path == "/api/model" {
            let model = ModelSchema.Info(
                id: ModelSchema.ID(rawValue: "claude-sonnet-4"),
                modelID: ModelSchema.ID(rawValue: "claude-sonnet-4"),
                providerID: ProviderSchema.ID(rawValue: "anthropic"),
                name: "Claude Sonnet 4",
                capabilities: ModelSchema.Capabilities.default(),
                variants: [ModelSchema.Variant(id: ModelSchema.VariantID(rawValue: "default"))],
                time: ModelSchema.Info.Time(released: 0),
                cost: [],
                status: .active,
                enabled: true,
                limit: ModelSchema.Info.Limit(context: 200_000, output: 16_000)
            )
            return Self.encodedResponse(LocationSchema.ResponseEnvelope(location: defaultLocation, data: [model]))
        }

        if request.method == "GET" && path == "/api/model/default" {
            let model = ModelSchema.Info(
                id: ModelSchema.ID(rawValue: "claude-sonnet-4"),
                modelID: ModelSchema.ID(rawValue: "claude-sonnet-4"),
                providerID: ProviderSchema.ID(rawValue: "anthropic"),
                name: "Claude Sonnet 4",
                capabilities: ModelSchema.Capabilities.default(),
                variants: [ModelSchema.Variant(id: ModelSchema.VariantID(rawValue: "default"))],
                time: ModelSchema.Info.Time(released: 0),
                cost: [],
                status: .active,
                enabled: true,
                limit: ModelSchema.Info.Limit(context: 200_000, output: 16_000)
            )
            return Self.encodedResponse(LocationSchema.ResponseEnvelope<ModelSchema.Info?>(location: defaultLocation, data: model))
        }

        if request.method == "GET" && path == "/api/agent" {
            let agent = AgentSchema.Info(
                id: AgentSchema.ID(rawValue: "build"),
                name: AgentSchema.Name(rawValue: "Build"),
                request: ProviderSchema.Request(),
                description: "Build agent",
                mode: .primary,
                hidden: false,
                permissions: []
            )
            return Self.encodedResponse(LocationSchema.ResponseEnvelope(location: defaultLocation, data: [agent]))
        }

        if request.method == "GET" && path == "/api/command" {
            let command = CommandSchema.Info(name: "review", description: "Review code")
            return Self.encodedResponse(LocationSchema.ResponseEnvelope(location: defaultLocation, data: [command]))
        }

        if request.method == "GET" && path == "/api/session/active" {
            let empty: [String: SessionActiveInfo] = [:]
            return Self.encodedDataResponse(empty)
        }

        if request.method == "POST" && path == "/api/session" {
            let bodyObj = Self.decodeJSONObject(bodyString)
            let cwd: String
            if case .object(let loc) = bodyObj["location"], case .string(let dir) = loc["directory"] {
                cwd = dir
            } else {
                cwd = "/workspace"
            }
            let session = state.withLock { s -> SessionSchema.Info in
                let seq = s.nextSessionSeq
                s.nextSessionSeq += 1
                let sid = "\(sessionPrefix)\(seq)"
                let info = SessionSchema.Info(
                    id: SessionID(rawValue: sid)!,
                    projectID: ProjectID(rawValue: "prj_real_test"),
                    agent: "build",
                    model: SessionSchema.ModelRef(id: "claude-sonnet-4", providerID: "anthropic"),
                    cost: 0,
                    tokens: .zero,
                    time: SessionSchema.Info.Time(created: 1_700_000_000_000, updated: 1_700_000_000_000),
                    title: "Real Session \(seq)",
                    location: OpenCodeLocation(directory: cwd)
                )
                s.sessions[sid] = info
                return info
            }
            return Self.encodedDataResponse(session)
        }

        if request.method == "POST" && path.hasPrefix("/api/session/") && path.hasSuffix("/prompt") {
            let parts = path.split(separator: "/")
            let sid = parts.count >= 3 ? String(parts[2]) : "\(sessionPrefix)1"
            let bodyObj = Self.decodeJSONObject(bodyString)
            let messageID: String
            if case .string(let rawID) = bodyObj["id"], !rawID.isEmpty {
                messageID = rawID
            } else {
                messageID = SessionMessageSchema.ID.create().rawValue
            }
            let text: String
            if case .string(let t) = bodyObj["text"] {
                text = t
            } else {
                text = ""
            }
            state.withLock { $0.promptTexts.append(text) }

            let inboxItem = SessionInboxSchema.Info.user(
                SessionInboxSchema.User(
                    id: SessionMessageSchema.ID(rawValue: messageID) ?? SessionMessageSchema.ID.create(),
                    sessionID: SessionID(rawValue: sid) ?? SessionID(rawValue: "ses_fallback")!,
                    time: SessionMessageSchema.TimeCreated(created: 1_700_000_000_100),
                    payload: SessionInboxSchema.UserPayload(text: text),
                    delivery: .steer
                )
            )
            let generator = self.onPrompt
            let hub = self.sseHub
            Task {
                try? await Task.sleep(for: .milliseconds(15))
                generator(sid, messageID, text, hub)
            }
            return Self.encodedDataResponse(inboxItem)
        }

        if request.method == "POST" && path.hasPrefix("/api/session/") && (path.hasSuffix("/agent") || path.hasSuffix("/model")) {
            return HTTPResponse(head: HTTPResponseHead(statusCode: 204), body: [])
        }

        if request.method == "PATCH" && path.hasPrefix("/api/session/") {
            return HTTPResponse(head: HTTPResponseHead(statusCode: 204), body: [])
        }

        if request.method == "DELETE" && path.hasPrefix("/api/session/") {
            let parts = path.split(separator: "/")
            if parts.count >= 3 {
                let sid = String(parts[2])
                _ = state.withLock { $0.sessions.removeValue(forKey: sid) }
            }
            return HTTPResponse(head: HTTPResponseHead(statusCode: 204), body: [])
        }

        if request.method == "GET" && path.hasPrefix("/api/session/") && !path.hasSuffix("/message") {
            let parts = path.split(separator: "/")
            if parts.count == 3 {
                let sid = String(parts[2])
                if let session = state.withLock({ $0.sessions[sid] }) {
                    return Self.encodedDataResponse(session)
                }
            }
        }

        if request.method == "GET" && path.hasPrefix("/api/session/") && path.hasSuffix("/message") {
            let json = "{\"data\":[],\"cursor\":{\"next\":null,\"prev\":null}}"
            return HTTPResponse(
                head: HTTPResponseHead(statusCode: 200, headers: ["content-type": "application/json"]),
                body: Array(json.utf8)
            )
        }

        if request.method == "POST" && path.hasPrefix("/api/session/") && path.hasSuffix("/interrupt") {
            let json = "{\"data\":{\"interrupted\":true}}"
            return HTTPResponse(
                head: HTTPResponseHead(statusCode: 200, headers: ["content-type": "application/json"]),
                body: Array(json.utf8)
            )
        }

        return HTTPResponse(
            head: HTTPResponseHead(statusCode: 404, headers: ["content-type": "application/json"]),
            body: Array("{\"error\":\"not found: \(request.method) \(path)\"}".utf8)
        )
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStreamingResponse {
        state.withLock {
            $0.requests.append(RecordedMockHTTPRequest(
                method: request.method,
                url: request.url,
                headers: request.headers,
                bodyUTF8: ""
            ))
        }
        return sseHub.openStream()
    }

    private static func extractPath(from url: String) -> String {
        if let components = URLComponents(string: url) {
            return components.path
        }
        if let q = url.firstIndex(of: "?") {
            return String(url[..<q])
        }
        return url
    }

    private static func decodeJSONObject(_ raw: String) -> [String: JSONValue] {
        guard !raw.isEmpty,
              let decoded = try? JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8)),
              case .object(let dict) = decoded
        else {
            return [:]
        }
        return dict
    }

    private struct DataEnvelope<T: Encodable>: Encodable {
        let data: T
    }

    private static func encodedDataResponse<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        let bytes = (try? JSONEncoder().encode(DataEnvelope(data: value))) ?? Data("{}".utf8)
        return HTTPResponse(
            head: HTTPResponseHead(statusCode: status, headers: ["content-type": "application/json"]),
            body: Array(bytes)
        )
    }

    private static func encodedResponse<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        let bytes = (try? JSONEncoder().encode(value)) ?? Data("{}".utf8)
        return HTTPResponse(
            head: HTTPResponseHead(statusCode: status, headers: ["content-type": "application/json"]),
            body: Array(bytes)
        )
    }
}

/// Recording `TUIMini.FooterApi` capturing all commits and footer events for assertions.
final class RecordingMiniFooter: TUIMini.FooterApi, @unchecked Sendable {
    private struct State: Sendable {
        var commits: [TUIMini.StreamCommit] = []
        var events: [TUIMini.FooterEvent] = []
        var closed: Bool = false
        var promptListeners: [UInt64: @Sendable (TUIMini.RunPrompt) -> Void] = [:]
        var closeListeners: [UInt64: @Sendable () -> Void] = [:]
        var nextID: UInt64 = 1
    }

    private let state = Mutex(State())

    var isClosed: Bool { state.withLock { $0.closed } }
    var commits: [TUIMini.StreamCommit] { state.withLock { $0.commits } }
    var events: [TUIMini.FooterEvent] { state.withLock { $0.events } }

    func onPrompt(_ fn: @escaping @Sendable (TUIMini.RunPrompt) -> Void) -> @Sendable () -> Void {
        let id = state.withLock { s -> UInt64 in
            let current = s.nextID
            s.nextID &+= 1
            s.promptListeners[current] = fn
            return current
        }
        return { [weak self] in
            _ = self?.state.withLock { $0.promptListeners.removeValue(forKey: id) }
        }
    }

    func onClose(_ fn: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        let id = state.withLock { s -> UInt64 in
            let current = s.nextID
            s.nextID &+= 1
            s.closeListeners[current] = fn
            return current
        }
        return { [weak self] in
            _ = self?.state.withLock { $0.closeListeners.removeValue(forKey: id) }
        }
    }

    func event(_ next: TUIMini.FooterEvent) {
        state.withLock { $0.events.append(next) }
    }

    func submitPrompt(_ prompt: TUIMini.RunPrompt) {
        let listeners = state.withLock { Array($0.promptListeners.values) }
        for fn in listeners { fn(prompt) }
    }

    func append(_ commit: TUIMini.StreamCommit) {
        state.withLock { $0.commits.append(commit) }
    }

    func idle() async {}

    func close() {
        let listeners = state.withLock { s -> [@Sendable () -> Void] in
            if s.closed { return [] }
            s.closed = true
            return Array(s.closeListeners.values)
        }
        for fn in listeners { fn() }
    }

    func destroy() {
        close()
    }
}

/// Thread-safe boolean flag helper for tests without Foundation imports.
final class AtomicFlag: Sendable {
    private let value: Mutex<Bool>

    init(_ initial: Bool = false) {
        self.value = Mutex(initial)
    }

    func set(_ next: Bool = true) {
        value.withLock { $0 = next }
    }

    var isSet: Bool {
        value.withLock { $0 }
    }
}

/// Thread-safe array collector for notifications/events in tests.
final class SyncCollector<T: Sendable>: Sendable {
    private let items = Mutex<[T]>([])

    func append(_ item: T) {
        items.withLock { $0.append(item) }
    }

    var values: [T] {
        items.withLock { $0 }
    }
}

/// Helper constructors for `OpenCodeEvent` SSE payloads used by `RealAcpAndMiniTests`.
enum RealTestSSEEvents {
    static func inboxDelivered(sessionID: String, inboxID: String) -> OpenCodeEvent {
        OpenCodeEvent(
            id: "evt_delivered_\(inboxID)",
            type: "session.inbox.delivered",
            created: 1_700_000_000_110,
            data: .object([
                "sessionID": .string(sessionID),
                "inboxID": .string(inboxID),
            ])
        )
    }

    static func executionStarted(sessionID: String) -> OpenCodeEvent {
        OpenCodeEvent(
            id: "evt_exec_start",
            type: "session.execution.started",
            created: 1_700_000_000_120,
            data: .object(["sessionID": .string(sessionID)])
        )
    }

    static func stepStarted(sessionID: String, assistantMessageID: String) -> OpenCodeEvent {
        OpenCodeEvent(
            id: "evt_step_start",
            type: "session.step.started",
            created: 1_700_000_000_125,
            data: .object([
                "sessionID": .string(sessionID),
                "assistantMessageID": .string(assistantMessageID),
                "model": .object([
                    "id": .string("claude-sonnet-4"),
                    "providerID": .string("anthropic"),
                ]),
            ])
        )
    }

    static func reasoningDelta(sessionID: String, assistantMessageID: String, ordinal: Int = 0, delta: String) -> OpenCodeEvent {
        OpenCodeEvent(
            id: "evt_rdelta_\(ordinal)",
            type: "session.reasoning.delta",
            created: 1_700_000_000_130,
            data: .object([
                "sessionID": .string(sessionID),
                "assistantMessageID": .string(assistantMessageID),
                "ordinal": .int(Int64(ordinal)),
                "delta": .string(delta),
            ])
        )
    }

    static func textDelta(sessionID: String, assistantMessageID: String, ordinal: Int = 0, delta: String) -> OpenCodeEvent {
        OpenCodeEvent(
            id: "evt_tdelta_\(ordinal)",
            type: "session.text.delta",
            created: 1_700_000_000_140,
            data: .object([
                "sessionID": .string(sessionID),
                "assistantMessageID": .string(assistantMessageID),
                "ordinal": .int(Int64(ordinal)),
                "delta": .string(delta),
            ])
        )
    }

    static func toolCalled(sessionID: String, assistantMessageID: String, id: String, name: String, input: [String: JSONValue]) -> OpenCodeEvent {
        OpenCodeEvent(
            id: "evt_tool_call_\(id)",
            type: "session.tool.called",
            created: 1_700_000_000_150,
            data: .object([
                "sessionID": .string(sessionID),
                "assistantMessageID": .string(assistantMessageID),
                "id": .string(id),
                "name": .string(name),
                "input": .object(input),
                "executed": .bool(true),
            ])
        )
    }

    static func toolSuccess(sessionID: String, assistantMessageID: String, id: String, name: String, outputText: String) -> OpenCodeEvent {
        OpenCodeEvent(
            id: "evt_tool_ok_\(id)",
            type: "session.tool.success",
            created: 1_700_000_000_160,
            data: .object([
                "sessionID": .string(sessionID),
                "assistantMessageID": .string(assistantMessageID),
                "id": .string(id),
                "name": .string(name),
                "executed": .bool(true),
                "content": .array([
                    .object(["type": .string("text"), "text": .string(outputText)]),
                ]),
                "metadata": .object([:]),
            ])
        )
    }

    static func executionSucceeded(sessionID: String) -> OpenCodeEvent {
        OpenCodeEvent(
            id: "evt_exec_done",
            type: "session.execution.succeeded",
            created: 1_700_000_000_200,
            data: .object(["sessionID": .string(sessionID)])
        )
    }
}
