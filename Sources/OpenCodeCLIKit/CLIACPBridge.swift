#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Synchronization
import OpenCodeClient
import OpenCodePlatform
import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeTUI
import OpenCodeUtil

extension CLIACP {

    // MARK: - Concurrency Primitives

    /// Thread-safe one-shot async gate (`Deferred` equivalent) with cancellation-safe waiters.
    internal final class AsyncGate: Sendable {
        private enum Outcome: Sendable {
            case pending
            case resolved(Bool) // true = succeeded, false = interrupted
        }

        private struct State: Sendable {
            var outcome: Outcome = .pending
            var nextWaiterID: UInt64 = 1
            var waiters: [UInt64: CheckedContinuation<Bool, Never>] = [:]
        }

        private let state = Mutex(State())

        internal init() {}

        internal var isResolved: Bool {
            state.withLock {
                if case .pending = $0.outcome { return false }
                return true
            }
        }

        internal func resolve(succeeded: Bool = true) {
            let waiters: [CheckedContinuation<Bool, Never>] = state.withLock { s in
                guard case .pending = s.outcome else { return [] }
                s.outcome = .resolved(succeeded)
                let all = Array(s.waiters.values)
                s.waiters.removeAll()
                return all
            }
            for waiter in waiters {
                waiter.resume(returning: succeeded)
            }
        }

        /// Waits until resolved or task cancellation. Returns `true` if resolved normally, `false` if interrupted/cancelled.
        @discardableResult
        internal func wait() async -> Bool {
            if let immediate: Bool = state.withLock({ s in
                if case .resolved(let ok) = s.outcome { return ok }
                return nil
            }) {
                return immediate
            }
            if Task.isCancelled { return false }
            let waiterID = state.withLock { s -> UInt64 in
                let id = s.nextWaiterID
                s.nextWaiterID += 1
                return id
            }
            return await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                    let immediate: Bool? = state.withLock { s in
                        if case .resolved(let ok) = s.outcome {
                            return ok
                        }
                        if Task.isCancelled {
                            return false
                        }
                        s.waiters[waiterID] = continuation
                        return nil
                    }
                    if let immediate {
                        continuation.resume(returning: immediate)
                    }
                }
            } onCancel: {
                let cancelled: CheckedContinuation<Bool, Never>? = state.withLock { s in
                    s.waiters.removeValue(forKey: waiterID)
                }
                cancelled?.resume(returning: false)
            }
        }
    }

    /// Thread-safe unbounded FIFO async channel for serialized queues (asks, selections, NDJSON streams).
    internal final class AsyncFIFO<Element: Sendable>: Sendable {
        private struct State: Sendable {
            var buffer: [Element] = []
            var closed = false
            var failure: (any Swift.Error & Sendable)? = nil
            var nextWaiterID: UInt64 = 1
            var waiters: [(id: UInt64, continuation: CheckedContinuation<Result<Element?, any Swift.Error>, Never>)] = []
        }

        private let state = Mutex(State())

        internal init() {}

        internal func push(_ element: Element) {
            let waiter: CheckedContinuation<Result<Element?, any Swift.Error>, Never>? = state.withLock { s in
                guard !s.closed else { return nil }
                if !s.waiters.isEmpty {
                    return s.waiters.removeFirst().continuation
                }
                s.buffer.append(element)
                return nil
            }
            waiter?.resume(returning: .success(element))
        }

        internal func finish(throwing error: (any Swift.Error & Sendable)? = nil) {
            let waiters: [CheckedContinuation<Result<Element?, any Swift.Error>, Never>] = state.withLock { s in
                guard !s.closed else { return [] }
                s.closed = true
                s.failure = error
                let pending = s.waiters.map(\.continuation)
                s.waiters.removeAll()
                return pending
            }
            let result: Result<Element?, any Swift.Error> = error.map { .failure($0) } ?? .success(nil)
            for waiter in waiters {
                waiter.resume(returning: result)
            }
        }

        internal func next() async throws -> Element? {
            if let immediate: Result<Element?, any Swift.Error> = state.withLock({ s in
                if !s.buffer.isEmpty {
                    return .success(s.buffer.removeFirst())
                }
                if s.closed {
                    return s.failure.map { .failure($0) } ?? .success(nil)
                }
                return nil
            }) {
                return try immediate.get()
            }
            if Task.isCancelled { throw CancellationError() }
            let waiterID = state.withLock { s -> UInt64 in
                let id = s.nextWaiterID
                s.nextWaiterID += 1
                return id
            }
            let result: Result<Element?, any Swift.Error> = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    let immediate: Result<Element?, any Swift.Error>? = state.withLock { s in
                        if !s.buffer.isEmpty {
                            return .success(s.buffer.removeFirst())
                        }
                        if s.closed {
                            return s.failure.map { .failure($0) } ?? .success(nil)
                        }
                        if Task.isCancelled {
                            return .failure(CancellationError())
                        }
                        s.waiters.append((waiterID, continuation))
                        return nil
                    }
                    if let immediate {
                        continuation.resume(returning: immediate)
                    }
                }
            } onCancel: {
                let removed: CheckedContinuation<Result<Element?, any Swift.Error>, Never>? = state.withLock { s in
                    guard let idx = s.waiters.firstIndex(where: { $0.id == waiterID }) else { return nil }
                    return s.waiters.remove(at: idx).continuation
                }
                removed?.resume(returning: .failure(CancellationError()))
            }
            return try result.get()
        }
    }

    /// Thread-safe box holding negotiated `Capabilities.Parsed` for the connection.
    public final class CapabilitiesBox: Sendable {
        private let state: Mutex<Capabilities.Parsed>

        public init(_ initial: Capabilities.Parsed = Capabilities.parse(nil)) {
            self.state = Mutex(initial)
        }

        public func get() -> Capabilities.Parsed {
            state.withLock { $0 }
        }

        public func set(_ next: Capabilities.Parsed) {
            state.withLock { $0 = next }
        }
    }

    internal static func awaitAborted(_ signal: AbortSignal) async {
        if signal.isAborted || Task.isCancelled { return }

        final class AbortWaitBox: Sendable {
            private struct State: Sendable {
                var finished = false
                var continuation: CheckedContinuation<Void, Never>? = nil
                var removeListener: (@Sendable () -> Void)? = nil
            }

            private let state = Mutex(State())

            func finish() {
                let (continuation, remove): (CheckedContinuation<Void, Never>?, (@Sendable () -> Void)?) = state.withLock { s in
                    guard !s.finished else { return (nil, nil) }
                    s.finished = true
                    let c = s.continuation
                    let r = s.removeListener
                    s.continuation = nil
                    s.removeListener = nil
                    return (c, r)
                }
                remove?()
                continuation?.resume()
            }

            func attach(continuation: CheckedContinuation<Void, Never>, signal: AbortSignal) {
                let alreadyFinished: Bool = state.withLock { s in
                    if s.finished || signal.isAborted || Task.isCancelled {
                        s.finished = true
                        return true
                    }
                    s.continuation = continuation
                    return false
                }
                if alreadyFinished {
                    continuation.resume()
                    return
                }
                let remove = signal.onAbort { [weak self] in
                    self?.finish()
                }
                let shouldCleanup: Bool = state.withLock { s in
                    if s.finished { return true }
                    s.removeListener = remove
                    return false
                }
                if shouldCleanup {
                    remove()
                }
            }
        }

        let box = AbortWaitBox()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                box.attach(continuation: continuation, signal: signal)
            }
        } onCancel: {
            box.finish()
        }
    }

    // MARK: - Backend Client Abstraction & EffectClient Adapter

    /// Minimal OpenCode server client surface required by the ACP bridge.
    /// Production callers wrap `EffectClient.OpenCodeClient` via `CLIACP.EffectBackendClient`.
    public protocol BackendClient: Sendable {
        func eventSubscribe() -> AsyncThrowingStream<OpenCodeEvent, any Swift.Error>
        func pluginList(directory: String) async throws -> [PluginSchema.Info]
        func modelList(directory: String) async throws -> [ModelSchema.Info]
        func modelDefault(directory: String) async throws -> ModelSchema.Ref?
        func agentList(directory: String) async throws -> [AgentSchema.Info]
        func commandList(directory: String) async throws -> [CommandSchema.Info]
        func sessionCreate(
            location: LocationSchema.PublicRef,
            permissions: PermissionSchema.Ruleset?,
            metadata: [String: JSONValue]?
        ) async throws -> SessionSchema.Info
        func sessionGet(sessionID: String) async throws -> SessionSchema.Info
        func sessionList(
            directory: String?,
            order: ProtocolSortOrder?,
            limit: Int?,
            cursor: String?
        ) async throws -> SessionsResponse
        func sessionUpdate(
            sessionID: String,
            permissions: PermissionSchema.Ruleset?,
            metadata: [String: JSONValue]?
        ) async throws
        func sessionRemove(sessionID: String) async throws
        func sessionFork(sessionID: String) async throws -> SessionSchema.Info
        func sessionActive() async throws -> [String: SessionActiveInfo]
        func sessionSwitchModel(sessionID: String, model: ModelSchema.Ref) async throws
        func sessionSwitchAgent(sessionID: String, agent: String) async throws
        func sessionPrompt(
            sessionID: String,
            id: String,
            text: String,
            files: [PromptInputSchema.FileAttachment],
            delivery: SessionInboxSchema.Delivery,
            resume: Bool?
        ) async throws
        func sessionCommand(
            sessionID: String,
            name: String,
            text: String,
            files: [PromptInputSchema.FileAttachment],
            delivery: SessionInboxSchema.Delivery
        ) async throws
        func sessionSynthetic(
            sessionID: String,
            text: String,
            description: String?,
            delivery: SessionInboxSchema.Delivery,
            resume: Bool?
        ) async throws
        func sessionCompact(sessionID: String, id: String) async throws
        func sessionInterrupt(sessionID: String) async throws
        func sessionFormReply(sessionID: String, formID: String, answer: FormSchema.Answer) async throws
        func sessionFormCancel(sessionID: String, formID: String, message: String?) async throws
        func messageList(
            sessionID: String,
            limit: Int?,
            order: ProtocolSortOrder?,
            cursor: String?
        ) async throws -> SessionMessagesResponse
        func permissionReply(sessionID: String, requestID: String, decision: PermissionSchema.Reply) async throws
        func experimentalMcpAdd(server: String, directory: String, config: McpSchema.ServerConfig) async throws
    }

    /// Concrete `BackendClient` backed by `EffectClient.OpenCodeClient`.
    public struct EffectBackendClient: BackendClient {
        public let client: EffectClient.OpenCodeClient

        public init(client: EffectClient.OpenCodeClient) {
            self.client = client
        }

        public func eventSubscribe() -> AsyncThrowingStream<OpenCodeEvent, any Swift.Error> {
            client.event.subscribe()
        }

        public func pluginList(directory: String) async throws -> [PluginSchema.Info] {
            try await client.plugin.list(
                PromiseInputTypes.PluginListInput(location: LocationQuery.LocationField(directory: directory))
            ).data
        }

        public func modelList(directory: String) async throws -> [ModelSchema.Info] {
            try await client.model.list(
                PromiseInputTypes.ModelListInput(location: LocationQuery.LocationField(directory: directory))
            ).data
        }

        public func modelDefault(directory: String) async throws -> ModelSchema.Ref? {
            guard let info = try await client.model.default(
                PromiseInputTypes.ModelDefaultInput(location: LocationQuery.LocationField(directory: directory))
            ).data else {
                return nil
            }
            return ModelSchema.Ref(id: info.id, providerID: info.providerID)
        }

        public func agentList(directory: String) async throws -> [AgentSchema.Info] {
            try await client.agent.list(
                PromiseInputTypes.AgentListInput(location: LocationQuery.LocationField(directory: directory))
            ).data
        }

        public func commandList(directory: String) async throws -> [CommandSchema.Info] {
            try await client.command.list(
                PromiseInputTypes.CommandListInput(location: LocationQuery.LocationField(directory: directory))
            ).data
        }

        public func sessionCreate(
            location: LocationSchema.PublicRef,
            permissions: PermissionSchema.Ruleset?,
            metadata: [String: JSONValue]?
        ) async throws -> SessionSchema.Info {
            try await client.session.create(
                PromiseInputTypes.SessionCreateInput(
                    location: location,
                    metadata: metadata,
                    permissions: permissions
                )
            )
        }

        public func sessionGet(sessionID: String) async throws -> SessionSchema.Info {
            try await client.session.get(PromiseInputTypes.SessionGetInput(sessionID: sessionID))
        }

        public func sessionList(
            directory: String?,
            order: ProtocolSortOrder?,
            limit: Int?,
            cursor: String?
        ) async throws -> SessionsResponse {
            try await client.session.list(
                PromiseInputTypes.SessionListInput(
                    limit: limit,
                    order: order,
                    directory: directory,
                    cursor: cursor
                )
            )
        }

        public func sessionUpdate(
            sessionID: String,
            permissions: PermissionSchema.Ruleset?,
            metadata: [String: JSONValue]?
        ) async throws {
            try await client.session.update(
                PromiseInputTypes.SessionUpdateInput(
                    sessionID: sessionID,
                    metadata: metadata,
                    permissions: permissions
                )
            )
        }

        public func sessionRemove(sessionID: String) async throws {
            try await client.session.remove(PromiseInputTypes.SessionRemoveInput(sessionID: sessionID))
        }

        public func sessionFork(sessionID: String) async throws -> SessionSchema.Info {
            try await client.session.fork(PromiseInputTypes.SessionForkInput(sessionID: sessionID))
        }

        public func sessionActive() async throws -> [String: SessionActiveInfo] {
            try await client.session.active()
        }

        public func sessionSwitchModel(sessionID: String, model: ModelSchema.Ref) async throws {
            try await client.session.switchModel(
                PromiseInputTypes.SessionSwitchModelInput(sessionID: sessionID, model: model)
            )
        }

        public func sessionSwitchAgent(sessionID: String, agent: String) async throws {
            try await client.session.switchAgent(
                PromiseInputTypes.SessionSwitchAgentInput(sessionID: sessionID, agent: agent)
            )
        }

        public func sessionPrompt(
            sessionID: String,
            id: String,
            text: String,
            files: [PromptInputSchema.FileAttachment],
            delivery: SessionInboxSchema.Delivery,
            resume: Bool?
        ) async throws {
            _ = try await client.session.prompt(
                PromiseInputTypes.SessionPromptInput(
                    sessionID: sessionID,
                    id: id,
                    text: text,
                    files: files,
                    delivery: delivery,
                    resume: resume
                )
            )
        }

        public func sessionCommand(
            sessionID: String,
            name: String,
            text: String,
            files: [PromptInputSchema.FileAttachment],
            delivery: SessionInboxSchema.Delivery
        ) async throws {
            try await client.session.command(
                PromiseInputTypes.SessionCommandInput(
                    sessionID: sessionID,
                    name: name,
                    text: text,
                    files: files,
                    delivery: delivery
                )
            )
        }

        public func sessionSynthetic(
            sessionID: String,
            text: String,
            description: String?,
            delivery: SessionInboxSchema.Delivery,
            resume: Bool?
        ) async throws {
            _ = try await client.session.synthetic(
                PromiseInputTypes.SessionSyntheticInput(
                    sessionID: sessionID,
                    text: text,
                    description: description,
                    delivery: delivery,
                    resume: resume
                )
            )
        }

        public func sessionCompact(sessionID: String, id: String) async throws {
            _ = try await client.session.compact(
                PromiseInputTypes.SessionCompactInput(sessionID: sessionID, id: id)
            )
        }

        public func sessionInterrupt(sessionID: String) async throws {
            _ = try await client.session.interrupt(
                PromiseInputTypes.SessionInterruptInput(sessionID: sessionID)
            )
        }

        public func sessionFormReply(sessionID: String, formID: String, answer: FormSchema.Answer) async throws {
            try await client.session.form.reply(
                PromiseInputTypes.SessionFormReplyInput(sessionID: sessionID, formID: formID, answer: answer)
            )
        }

        public func sessionFormCancel(sessionID: String, formID: String, message: String?) async throws {
            try await client.session.form.cancel(
                PromiseInputTypes.SessionFormCancelInput(sessionID: sessionID, formID: formID, message: message)
            )
        }

        public func messageList(
            sessionID: String,
            limit: Int?,
            order: ProtocolSortOrder?,
            cursor: String?
        ) async throws -> SessionMessagesResponse {
            try await client.message.list(
                PromiseInputTypes.MessageListInput(
                    sessionID: sessionID,
                    limit: limit,
                    order: order,
                    cursor: cursor
                )
            )
        }

        public func permissionReply(sessionID: String, requestID: String, decision: PermissionSchema.Reply) async throws {
            try await client.permission.reply(
                PromiseInputTypes.PermissionReplyInput(sessionID: sessionID, requestID: requestID, decision: decision)
            )
        }

        public func experimentalMcpAdd(server: String, directory: String, config: McpSchema.ServerConfig) async throws {
            try await client.experimental.mcp.add(
                PromiseInputTypes.ExperimentalMcpAddInput(
                    server: server,
                    location: LocationQuery.LocationField(directory: directory),
                    config: config
                )
            )
        }
    }

    // MARK: - NDJSON Codec, Framing Buffer & Bidirectional Stream

    public enum NDJSONCodec {
        public static func encode(_ message: JSONRPCMessage) throws -> [UInt8] {
            var bytes = try ClientCodec.encode(message)
            bytes.append(0x0A)
            return bytes
        }

        public static func encodeLine(_ message: JSONRPCMessage) throws -> String {
            String(decoding: try encode(message), as: UTF8.self)
        }

        public static func decode(_ line: String) throws -> JSONRPCMessage {
            try ClientCodec.decode(JSONRPCMessage.self, from: line)
        }
    }

    /// Incremental newline-delimited JSON framing splitter handling arbitrary chunk boundaries & CRLF.
    public struct NDJSONLineBuffer: Sendable {
        private var buffer: [UInt8] = []

        public init() {}

        public mutating func push(_ chunk: [UInt8]) -> [String] {
            buffer.append(contentsOf: chunk)
            var lines: [String] = []
            var start = 0
            for idx in 0..<buffer.count where buffer[idx] == 0x0A {
                var end = idx
                if end > start && buffer[end - 1] == 0x0D {
                    end -= 1
                }
                let line = String(decoding: buffer[start..<end], as: UTF8.self)
                if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    lines.append(line)
                }
                start = idx + 1
            }
            if start > 0 {
                buffer.removeFirst(start)
            }
            return lines
        }

        public mutating func flush() -> String? {
            guard !buffer.isEmpty else { return nil }
            let remaining = String(decoding: buffer, as: UTF8.self)
            buffer.removeAll()
            let trimmed = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    /// Full-duplex JSON-RPC NDJSON transport stream (stdio, byte pipes, or in-memory pairs).
    public struct NDJSONStream: Sendable {
        public let readable: AsyncThrowingStream<JSONRPCMessage, any Swift.Error>
        public let write: @Sendable (JSONRPCMessage) async throws -> Void
        public let close: @Sendable () async -> Void

        public init(
            readable: AsyncThrowingStream<JSONRPCMessage, any Swift.Error>,
            write: @escaping @Sendable (JSONRPCMessage) async throws -> Void,
            close: @escaping @Sendable () async -> Void = {}
        ) {
            self.readable = readable
            self.write = write
            self.close = close
        }

        /// Creates a connected in-memory duplex pair of NDJSON streams (`agent` <-> `client`).
        public static func pair() -> (agent: NDJSONStream, client: NDJSONStream) {
            let toAgent = AsyncFIFO<JSONRPCMessage>()
            let toClient = AsyncFIFO<JSONRPCMessage>()

            let agentReadable = AsyncThrowingStream<JSONRPCMessage, any Swift.Error> { continuation in
                let task = Task {
                    do {
                        while let message = try await toAgent.next() {
                            continuation.yield(message)
                        }
                        continuation.finish()
                    } catch is CancellationError {
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }

            let clientReadable = AsyncThrowingStream<JSONRPCMessage, any Swift.Error> { continuation in
                let task = Task {
                    do {
                        while let message = try await toClient.next() {
                            continuation.yield(message)
                        }
                        continuation.finish()
                    } catch is CancellationError {
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }

            let agent = NDJSONStream(
                readable: agentReadable,
                write: { message in toClient.push(message) },
                close: {
                    toClient.finish()
                    toAgent.finish()
                }
            )
            let client = NDJSONStream(
                readable: clientReadable,
                write: { message in toAgent.push(message) },
                close: {
                    toAgent.finish()
                    toClient.finish()
                }
            )
            return (agent, client)
        }

        /// Builds a framed `NDJSONStream` from raw byte input and byte write/close callbacks.
        public static func fromBytes(
            input: AsyncThrowingStream<[UInt8], any Swift.Error>,
            write: @escaping @Sendable ([UInt8]) async throws -> Void,
            close: @escaping @Sendable () async -> Void = {}
        ) -> NDJSONStream {
            let readable = AsyncThrowingStream<JSONRPCMessage, any Swift.Error> { continuation in
                let task = Task {
                    var framer = NDJSONLineBuffer()
                    do {
                        for try await chunk in input {
                            if Task.isCancelled { break }
                            for line in framer.push(chunk) {
                                let msg = try NDJSONCodec.decode(line)
                                continuation.yield(msg)
                            }
                        }
                        if let tail = framer.flush() {
                            let msg = try NDJSONCodec.decode(tail)
                            continuation.yield(msg)
                        }
                        continuation.finish()
                    } catch is CancellationError {
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
            return NDJSONStream(
                readable: readable,
                write: { message in
                    let bytes = try NDJSONCodec.encode(message)
                    try await write(bytes)
                },
                close: close
            )
        }

        /// Builds an NDJSON stream over process `stdin` / `stdout` (POSIX).
        public static func stdio() -> NDJSONStream {
            #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
            let input = AsyncThrowingStream<[UInt8], any Swift.Error> { continuation in
                let task = Task.detached {
                    var buf = [UInt8](repeating: 0, count: 4096)
                    while !Task.isCancelled {
                        let count = buf.withUnsafeMutableBytes { raw -> Int in
                            guard let base = raw.baseAddress else { return 0 }
                            return Int(read(STDIN_FILENO, base, raw.count))
                        }
                        if count > 0 {
                            continuation.yield(Array(buf[0..<count]))
                        } else if count == 0 {
                            break
                        } else if errno == EINTR {
                            continue
                        } else {
                            continuation.finish(throwing: PlatformError.ioFailure("stdin read failed", code: "EIO"))
                            return
                        }
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
            let writeLock = Mutex(())
            return fromBytes(
                input: input,
                write: { bytes in
                    try writeLock.withLock { _ in
                        var written = 0
                        while written < bytes.count {
                            let n = bytes.withUnsafeBytes { raw -> Int in
                                guard let base = raw.baseAddress else { return 0 }
                                #if canImport(Darwin)
                                return Int(Darwin.write(STDOUT_FILENO, base.advanced(by: written), bytes.count - written))
                                #elseif canImport(Glibc)
                                return Int(Glibc.write(STDOUT_FILENO, base.advanced(by: written), bytes.count - written))
                                #elseif canImport(Musl)
                                return Int(Musl.write(STDOUT_FILENO, base.advanced(by: written), bytes.count - written))
                                #endif
                            }
                            if n > 0 {
                                written += n
                            } else if n < 0 && errno == EINTR {
                                continue
                            } else {
                                throw PlatformError.ioFailure("stdout write failed", code: "EIO")
                            }
                        }
                    }
                },
                close: {}
            )
            #else
            return fromBytes(
                input: AsyncThrowingStream { $0.finish() },
                write: { _ in },
                close: {}
            )
            #endif
        }
    }

    // MARK: - JSON-RPC AgentApp & Bidirectional Client Peer

    public struct HandlerContext: Sendable {
        public let requestId: JSONRPCId?
        public let params: JSONValue?
        public let signal: AbortSignal

        public init(requestId: JSONRPCId?, params: JSONValue?, signal: AbortSignal) {
            self.requestId = requestId
            self.params = params
            self.signal = signal
        }
    }

    public typealias RequestHandler = @Sendable (HandlerContext) async throws -> JSONValue
    public typealias NotificationHandler = @Sendable (HandlerContext) async throws -> Void

    /// Lightweight JSON-RPC 2.0 router mirroring `@agentclientprotocol/sdk`'s `agent({ name })`.
    public final class AgentApp: Sendable {
        public let name: String

        private struct Handlers: Sendable {
            var requests: [String: RequestHandler] = [:]
            var notifications: [String: NotificationHandler] = [:]
        }

        private let handlers = Mutex(Handlers())

        public init(name: String = "opencode") {
            self.name = name
        }

        public func onRequest(_ method: String, handler: @escaping RequestHandler) {
            handlers.withLock { $0.requests[method] = handler }
        }

        public func onNotification(_ method: String, handler: @escaping NotificationHandler) {
            handlers.withLock { $0.notifications[method] = handler }
        }

        internal func requestHandler(for method: String) -> RequestHandler? {
            handlers.withLock { $0.requests[method] }
        }

        internal func notificationHandler(for method: String) -> NotificationHandler? {
            handlers.withLock { $0.notifications[method] }
        }

        public func connect(stream: NDJSONStream) -> ConnectedRuntime {
            ConnectedRuntime(app: self, stream: stream)
        }
    }

    /// Running JSON-RPC runtime connecting an `AgentApp` to an `NDJSONStream`, with outgoing client calls & cancellation.
    public final class ConnectedRuntime: Sendable {
        private struct PendingClientCall: Sendable {
            let continuation: CheckedContinuation<Result<JSONValue, any Swift.Error>, Never>
        }

        private struct RuntimeState: Sendable {
            var nextOutboundId: Int64 = 1
            var pendingOutbound: [JSONRPCId: PendingClientCall] = [:]
            var inflightIncoming: [JSONRPCId: AbortController] = [:]
            var closed = false
        }

        private let app: AgentApp
        private let stream: NDJSONStream
        private let state = Mutex(RuntimeState())
        private let loopTask: Mutex<Task<Void, Never>?> = Mutex(nil)
        private let closedGate = AsyncGate()

        public init(app: AgentApp, stream: NDJSONStream) {
            self.app = app
            self.stream = stream
            let task = Task<Void, Never> { [weak self] in
                await self?.runReadLoop()
            }
            self.loopTask.withLock { $0 = task }
        }

        public func waitUntilClosed() async {
            _ = await closedGate.wait()
        }

        public func close() async {
            let task = loopTask.withLock { t -> Task<Void, Never>? in
                let prev = t
                t = nil
                return prev
            }
            task?.cancel()
            await stream.close()
            failAllPending(RequestError.internalError(detail: "ACP connection closed"))
            closedGate.resolve(succeeded: true)
        }

        public func notify(method: String, params: JSONValue?) async throws {
            try await stream.write(.notification(method: method, params: params))
        }

        public func request(method: String, params: JSONValue?) async throws -> JSONValue {
            let reqId = state.withLock { s -> JSONRPCId in
                let id = JSONRPCId.int(s.nextOutboundId)
                s.nextOutboundId += 1
                return id
            }
            let result: Result<JSONValue, any Swift.Error> = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    let alreadyClosed = state.withLock { s -> Bool in
                        if s.closed { return true }
                        s.pendingOutbound[reqId] = PendingClientCall(continuation: continuation)
                        return false
                    }
                    if alreadyClosed {
                        continuation.resume(returning: .failure(RequestError.internalError(detail: "ACP connection closed")))
                        return
                    }
                    Task { [weak self] in
                        guard let self else { return }
                        do {
                            try await self.stream.write(.request(id: reqId, method: method, params: params))
                        } catch {
                            let pending = self.state.withLock { $0.pendingOutbound.removeValue(forKey: reqId) }
                            pending?.continuation.resume(returning: .failure(error))
                        }
                    }
                }
            } onCancel: {
                let pending = state.withLock { $0.pendingOutbound.removeValue(forKey: reqId) }
                pending?.continuation.resume(returning: .failure(CancellationError()))
                Task { [weak self] in
                    guard let self else { return }
                    let cancelParams: JSONValue
                    switch reqId {
                    case .int(let n): cancelParams = .object(["requestId": .int(n)])
                    case .string(let s): cancelParams = .object(["requestId": .string(s)])
                    }
                    try? await self.stream.write(.notification(method: Methods.cancelRequest, params: cancelParams))
                }
            }
            return try result.get()
        }

        private func runReadLoop() async {
            do {
                for try await message in stream.readable {
                    if Task.isCancelled { break }
                    handleIncoming(message)
                }
            } catch {
                // Stream ended or errored
            }
            failAllPending(RequestError.internalError(detail: "ACP stream closed"))
            closedGate.resolve(succeeded: true)
        }

        private func handleIncoming(_ message: JSONRPCMessage) {
            switch message {
            case .request(let id, let method, let params):
                let controller = AbortController()
                state.withLock { $0.inflightIncoming[id] = controller }
                Task { [weak self] in
                    guard let self else { return }
                    defer {
                        self.state.withLock { _ = $0.inflightIncoming.removeValue(forKey: id) }
                    }
                    guard let handler = self.app.requestHandler(for: method) else {
                        try? await self.stream.write(
                            .errorResponse(id: id, error: RequestError.methodNotFound(method).toErrorResponse())
                        )
                        return
                    }
                    let ctx = HandlerContext(requestId: id, params: params, signal: controller.signal)
                    do {
                        let result = try await handler(ctx)
                        try? await self.stream.write(.response(id: id, result: result))
                    } catch let reqErr as RequestError {
                        try? await self.stream.write(.errorResponse(id: id, error: reqErr.toErrorResponse()))
                    } catch {
                        let wrapped = Errors.toRequestError(Errors.ACPError.serviceFailure(Errors.fromUnknown(error)))
                        try? await self.stream.write(.errorResponse(id: id, error: wrapped.toErrorResponse()))
                    }
                }

            case .notification(let method, let params):
                if method == Methods.cancelRequest {
                    if let targetId = extractCancelRequestID(params) {
                        let controller = state.withLock { $0.inflightIncoming[targetId] }
                        controller?.abort()
                    }
                    return
                }
                guard let handler = app.notificationHandler(for: method) else { return }
                let ctx = HandlerContext(requestId: nil, params: params, signal: AbortController().signal)
                Task {
                    try? await handler(ctx)
                }

            case .response(let id, let result):
                let pending = state.withLock { $0.pendingOutbound.removeValue(forKey: id) }
                pending?.continuation.resume(returning: .success(result))

            case .errorResponse(let id, let errorObj):
                guard let id else { return }
                let pending = state.withLock { $0.pendingOutbound.removeValue(forKey: id) }
                let reqErr = RequestError(code: errorObj.code, message: errorObj.message, data: errorObj.data)
                pending?.continuation.resume(returning: .failure(reqErr))
            }
        }

        private func failAllPending(_ error: any Swift.Error & Sendable) {
            let (pending, inflight) = state.withLock { s -> ([PendingClientCall], [AbortController]) in
                s.closed = true
                let p = Array(s.pendingOutbound.values)
                let i = Array(s.inflightIncoming.values)
                s.pendingOutbound.removeAll()
                s.inflightIncoming.removeAll()
                return (p, i)
            }
            for item in pending {
                item.continuation.resume(returning: .failure(error))
            }
            for controller in inflight {
                controller.abort()
            }
        }

        private func extractCancelRequestID(_ params: JSONValue?) -> JSONRPCId? {
            guard case .object(let obj) = params, let raw = obj["requestId"] else { return nil }
            switch raw {
            case .int(let n): return .int(n)
            case .string(let s): return .string(s)
            default: return nil
            }
        }
    }

    /// Typed JSON-RPC ACP client peer for connecting to an ACP agent over `NDJSONStream`.
    public final class PeerClient: Sendable {
        public typealias PermissionHandler = @Sendable (RequestPermissionRequest, AbortSignal) async throws -> RequestPermissionResponse
        public typealias ElicitationHandler = @Sendable (CreateElicitationRequest, AbortSignal) async throws -> CreateElicitationResponse
        public typealias UpdateHandler = @Sendable (SessionNotification) async -> Void
        public typealias ChildUpdateHandler = @Sendable (Child.Update) async -> Void

        private struct State: Sendable {
            var nextId: Int64 = 1
            var pending: [JSONRPCId: CheckedContinuation<Result<JSONValue, any Swift.Error>, Never>] = [:]
            var inflightServerRequests: [JSONRPCId: AbortController] = [:]
            var receivedMessages: [JSONRPCMessage] = []
            var closed = false
        }

        private let stream: NDJSONStream
        private let state = Mutex(State())
        private let onUpdate: UpdateHandler?
        private let onChildUpdate: ChildUpdateHandler?
        private let onPermission: PermissionHandler?
        private let onElicitation: ElicitationHandler?
        private let loopTask: Mutex<Task<Void, Never>?> = Mutex(nil)

        public init(
            stream: NDJSONStream,
            onUpdate: UpdateHandler? = nil,
            onChildUpdate: ChildUpdateHandler? = nil,
            onPermission: PermissionHandler? = nil,
            onElicitation: ElicitationHandler? = nil
        ) {
            self.stream = stream
            self.onUpdate = onUpdate
            self.onChildUpdate = onChildUpdate
            self.onPermission = onPermission
            self.onElicitation = onElicitation
            let task = Task<Void, Never> { [weak self] in
                await self?.readLoop()
            }
            self.loopTask.withLock { $0 = task }
        }

        public var receivedMessages: [JSONRPCMessage] {
            state.withLock { $0.receivedMessages }
        }

        public func close() async {
            let task = loopTask.withLock { t -> Task<Void, Never>? in
                let prev = t
                t = nil
                return prev
            }
            task?.cancel()
            await stream.close()
        }

        public func request<Params: Encodable, ResultType: Decodable>(
            _ method: String,
            params: Params,
            as resultType: ResultType.Type = ResultType.self
        ) async throws -> ResultType {
            let rawParams = try ClientCodec.toJSONValue(params)
            let rawResult = try await requestRaw(method, params: rawParams)
            return try ClientCodec.fromJSONValue(resultType, value: rawResult)
        }

        public func requestRaw(_ method: String, params: JSONValue?) async throws -> JSONValue {
            let id = state.withLock { s -> JSONRPCId in
                let next = JSONRPCId.int(s.nextId)
                s.nextId += 1
                return next
            }
            let result: Result<JSONValue, any Swift.Error> = await withCheckedContinuation { continuation in
                let isClosed = state.withLock { s -> Bool in
                    if s.closed { return true }
                    s.pending[id] = continuation
                    return false
                }
                if isClosed {
                    continuation.resume(returning: .failure(RequestError.internalError(detail: "Client closed")))
                    return
                }
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        try await self.stream.write(.request(id: id, method: method, params: params))
                    } catch {
                        let pending = self.state.withLock { $0.pending.removeValue(forKey: id) }
                        pending?.resume(returning: .failure(error))
                    }
                }
            }
            return try result.get()
        }

        public func notify<Params: Encodable>(_ method: String, params: Params) async throws {
            let raw = try ClientCodec.toJSONValue(params)
            try await stream.write(.notification(method: method, params: raw))
        }

        public func cancelRequest(_ requestId: JSONRPCId) async throws {
            let payload: JSONValue
            switch requestId {
            case .int(let n): payload = .object(["requestId": .int(n)])
            case .string(let s): payload = .object(["requestId": .string(s)])
            }
            try await stream.write(.notification(method: Methods.cancelRequest, params: payload))
        }

        private func readLoop() async {
            do {
                for try await message in stream.readable {
                    if Task.isCancelled { break }
                    state.withLock { $0.receivedMessages.append(message) }
                    await handle(message)
                }
            } catch {
                // stream closed
            }
            let pending = state.withLock { s -> [CheckedContinuation<Result<JSONValue, any Swift.Error>, Never>] in
                s.closed = true
                let list = Array(s.pending.values)
                s.pending.removeAll()
                return list
            }
            for cont in pending {
                cont.resume(returning: .failure(RequestError.internalError(detail: "Stream closed")))
            }
        }

        private func handle(_ message: JSONRPCMessage) async {
            switch message {
            case .response(let id, let result):
                let cont = state.withLock { $0.pending.removeValue(forKey: id) }
                cont?.resume(returning: .success(result))

            case .errorResponse(let id, let err):
                guard let id else { return }
                let cont = state.withLock { $0.pending.removeValue(forKey: id) }
                cont?.resume(returning: .failure(RequestError(code: err.code, message: err.message, data: err.data)))

            case .notification(let method, let params):
                if method == Methods.cancelRequest {
                    if case .object(let obj) = params, let raw = obj["requestId"] {
                        let target: JSONRPCId? = switch raw {
                        case .int(let n): .int(n)
                        case .string(let s): .string(s)
                        default: nil
                        }
                        if let target {
                            let controller = state.withLock { $0.inflightServerRequests[target] }
                            controller?.abort()
                        }
                    }
                    return
                }
                if method == Methods.clientSessionUpdate,
                   let params,
                   let notification = try? ClientCodec.fromJSONValue(SessionNotification.self, value: params)
                {
                    await onUpdate?(notification)
                } else if method == Child.updateMethod,
                          let params,
                          let update = try? ClientCodec.fromJSONValue(Child.Update.self, value: params)
                {
                    await onChildUpdate?(update)
                }

            case .request(let id, let method, let params):
                let controller = AbortController()
                state.withLock { $0.inflightServerRequests[id] = controller }
                Task { [weak self] in
                    guard let self else { return }
                    defer { self.state.withLock { _ = $0.inflightServerRequests.removeValue(forKey: id) } }
                    do {
                        if method == Methods.clientSessionRequestPermission,
                           let params,
                           let handler = self.onPermission
                        {
                            let req = try ClientCodec.fromJSONValue(RequestPermissionRequest.self, value: params)
                            let resp = try await handler(req, controller.signal)
                            try? await self.stream.write(.response(id: id, result: try ClientCodec.toJSONValue(resp)))
                        } else if method == Methods.clientElicitationCreate,
                                  let params,
                                  let handler = self.onElicitation
                        {
                            let req = try ClientCodec.fromJSONValue(CreateElicitationRequest.self, value: params)
                            let resp = try await handler(req, controller.signal)
                            try? await self.stream.write(.response(id: id, result: try ClientCodec.toJSONValue(resp)))
                        } else {
                            try? await self.stream.write(
                                .errorResponse(id: id, error: RequestError.methodNotFound(method).toErrorResponse())
                            )
                        }
                    } catch let reqErr as RequestError {
                        try? await self.stream.write(.errorResponse(id: id, error: reqErr.toErrorResponse()))
                    } catch {
                        try? await self.stream.write(
                            .errorResponse(
                                id: id,
                                error: RequestError.internalError(detail: String(describing: error)).toErrorResponse()
                            )
                        )
                    }
                }
            }
        }
    }

    // MARK: - 11. Client Error Classification (`packages/cli/src/acp/client.ts`)

    public enum ClientHelpers {
        // parity: cli/src/acp/client.ts#classify [status=adapted hash=00e15fdab4c1]
        public static func classify(_ error: any Swift.Error) -> Errors.ACPError? {
            if let acpError = error as? Errors.ACPError {
                return acpError
            }
            if let effectErr = error as? EffectClient.ClientError {
                return classify(effectErr.cause)
            }
            if let clientErr = error as? ClientError {
                if clientErr.reason == .transport
                    || (clientErr.reason == .malformedResponse && clientErr.causeDescription != nil)
                {
                    return .serverUnavailable(Errors.ServerUnavailableError())
                }
                return nil
            }
            if let platformErr = error as? PlatformError {
                if case .ioFailure = platformErr {
                    return .serverUnavailable(Errors.ServerUnavailableError())
                }
            }
            if let notFound = error as? OpenCodeProtocol.SessionNotFoundError {
                return .sessionNotFound(Errors.SessionNotFoundError(sessionId: notFound.sessionID))
            }
            if let invalidReq = error as? OpenCodeProtocol.InvalidRequestError {
                return .invalidRequest(Errors.InvalidRequestError(message: invalidReq.message, field: invalidReq.field))
            }
            if let invalidCursor = error as? OpenCodeProtocol.InvalidCursorError {
                return .invalidRequest(Errors.InvalidRequestError(message: invalidCursor.message, field: "cursor"))
            }
            if let envelope = error as? ProtocolErrorEnvelope {
                switch envelope {
                case .sessionNotFound(let e):
                    return .sessionNotFound(Errors.SessionNotFoundError(sessionId: e.sessionID))
                case .invalidRequest(let e):
                    return .invalidRequest(Errors.InvalidRequestError(message: e.message, field: e.field))
                case .invalidCursor(let e):
                    return .invalidRequest(Errors.InvalidRequestError(message: e.message, field: "cursor"))
                default:
                    return nil
                }
            }
            return nil
        }

        internal static func rethrowClassified(_ error: any Swift.Error) throws -> Never {
            if let classified = classify(error) {
                throw classified
            }
            throw error
        }

        // parity: cli/src/acp/client.ts#decodeSessionID [status=implemented hash=a764dad1360b]
        public static func decodeSessionID(_ value: String) throws(Errors.ACPError) -> SessionID {
            do {
                return try SessionID(validating: value)
            } catch {
                throw .invalidRequest(Errors.InvalidRequestError(message: "Invalid session ID", field: "sessionID"))
            }
        }
    }

    // MARK: - 12. Additional Directories (`packages/cli/src/acp/directories.ts`)

    public enum Directories {
        public static let metadataKey = "opencode.acp.additionalDirectories"

        public struct Grant: Equatable, Hashable, Sendable {
            public let permissions: PermissionSchema.Ruleset?
            public let metadata: [String: JSONValue]?

            public init(permissions: PermissionSchema.Ruleset? = nil, metadata: [String: JSONValue]? = nil) {
                self.permissions = permissions
                self.metadata = metadata
            }
        }

        // parity: cli/src/acp/directories.ts#parse [status=implemented hash=190a38cdc368]
        public static func parse(cwd: String, directories: [String] = []) throws(Errors.ACPError) -> [String] {
            _ = try parseCwd(cwd)
            if let invalid = directories.first(where: { dir in
                !ToolMapper.isAbsolutePath(dir) || dir.contains("*") || dir.contains("?")
            }) {
                throw .invalidAdditionalDirectory(Errors.InvalidAdditionalDirectoryError(directory: invalid))
            }
            let root = FSUtil.resolve(cwd)
            var seen: Set<String> = []
            var out: [String] = []
            for directory in directories {
                let normalized = ToolMapper.normalizePOSIXPath(FSPathUtil.windowsPath(directory))
                if seen.insert(normalized).inserted && FSUtil.resolve(normalized) != root {
                    out.append(normalized)
                }
            }
            return out
        }

        // parity: cli/src/acp/directories.ts#parseCwd [status=implemented hash=1fd46229880c]
        public static func parseCwd(_ cwd: String) throws(Errors.ACPError) -> SchemaPrimitive.AbsolutePath {
            guard ToolMapper.isAbsolutePath(cwd) else {
                throw .invalidRequest(
                    Errors.InvalidRequestError(message: "cwd must be an absolute path: \(cwd)", field: "cwd")
                )
            }
            return SchemaPrimitive.AbsolutePath(rawValue: cwd)
        }

        // parity: cli/src/acp/directories.ts#grant [status=implemented hash=c62696ca1e66]
        public static func grant(_ directories: [String]) -> Grant {
            guard !directories.isEmpty else { return Grant() }
            return Grant(
                permissions: rules(directories),
                metadata: [metadataKey: .array(directories.map { .string($0) })]
            )
        }

        // parity: cli/src/acp/directories.ts#list [status=implemented hash=8b8e3b93bf7a]
        public static func list(metadata: [String: JSONValue]?) -> [String] {
            guard case .array(let items) = metadata?[metadataKey] else { return [] }
            var out: [String] = []
            for item in items {
                guard case .string(let s) = item else { return [] }
                out.append(s)
            }
            return out
        }

        public static func list(_ session: SessionSchema.Info) -> [String] {
            list(metadata: session.metadata)
        }

        // parity: cli/src/acp/directories.ts#activate [status=implemented hash=38d509920097]
        public static func activate(
            client: any BackendClient,
            session: SessionSchema.Info,
            directories: [String]
        ) async throws {
            let previous = list(session)
            let owned = rules(previous)
            let current: PermissionSchema.Ruleset = (session.permissions ?? []).map { rule in
                PermissionSchema.Rule(
                    action: rule.action,
                    resource: rule.resource,
                    effect: PermissionSchema.Effect(rawValue: rule.effect.rawValue) ?? .allow
                )
            }
            let nextPermissions = rules(directories) + current.filter { rule in !owned.contains(rule) }
            var nextMetadata: [String: JSONValue] = [:]
            for (k, v) in session.metadata ?? [:] where k != metadataKey {
                nextMetadata[k] = v
            }
            if !directories.isEmpty {
                nextMetadata[metadataKey] = .array(directories.map { .string($0) })
            }
            let permissionsChanged = nextPermissions != current
            let metadataChanged = previous != directories
            if !permissionsChanged && !metadataChanged { return }
            do {
                try await client.sessionUpdate(
                    sessionID: session.id.rawValue,
                    permissions: permissionsChanged ? nextPermissions : nil,
                    metadata: metadataChanged ? nextMetadata : nil
                )
            } catch {
                try ClientHelpers.rethrowClassified(error)
            }
        }

        private static func rules(_ directories: [String]) -> PermissionSchema.Ruleset {
            var seen: Set<String> = []
            var unique: [String] = []
            for dir in directories {
                for spelling in [dir, FSUtil.resolve(dir)] {
                    if seen.insert(spelling).inserted {
                        unique.append(spelling)
                    }
                }
            }
            return unique.map { dir in
                let resource = dir.hasSuffix("/") ? "\(dir)*" : "\(dir)/*"
                return PermissionSchema.Rule(action: "external_directory", resource: resource, effect: .allow)
            }
        }
    }

    // MARK: - 13. Catalog Service (`packages/cli/src/acp/catalog.ts`)

    // MARK: - 14. Connection Bridge (`packages/cli/src/acp/connection.ts`)

    public enum Connection {
        // parity: cli/src/acp/connection.ts#Responded [status=adapted hash=97c861bd09bf]
        public enum Responded {
            @TaskLocal
            public static var current: @Sendable () async -> Bool = { true }
        }

        // parity: cli/src/acp/connection.ts#Interface [status=implemented hash=286c7203d639]
        public protocol Interface: Sendable {
            func sessionUpdate(_ params: SessionNotification) async throws
            func requestPermission(_ params: RequestPermissionRequest) async throws -> RequestPermissionResponse
            func extNotification(method: String, params: [String: JSONValue]) async throws
            func createElicitation(_ params: CreateElicitationRequest) async throws -> CreateElicitationResponse
            func responded(requestId: JSONRPCId) -> @Sendable () async -> Bool
        }

        public struct Connected: Sendable {
            public let agent: ConnectedRuntime
            public let connection: any Interface

            public init(agent: ConnectedRuntime, connection: any Interface) {
                self.agent = agent
                self.connection = connection
            }
        }

        private final class ResponseWaiterMap: Sendable {
            private let map = Mutex<[JSONRPCId: AsyncGate]>([:])

            func register(id: JSONRPCId) -> AsyncGate {
                let gate = AsyncGate()
                map.withLock { $0[id] = gate }
                return gate
            }

            func resolve(id: JSONRPCId, succeeded: Bool) {
                let gate = map.withLock { $0.removeValue(forKey: id) }
                gate?.resolve(succeeded: succeeded)
            }

            func closeAll() {
                let pending = map.withLock { m -> [AsyncGate] in
                    let all = Array(m.values)
                    m.removeAll()
                    return all
                }
                for gate in pending {
                    gate.resolve(succeeded: false)
                }
            }
        }

        private final class LiveConnection: Interface, Sendable {
            let runtime: ConnectedRuntime
            let responseWaiters: ResponseWaiterMap

            init(runtime: ConnectedRuntime, responseWaiters: ResponseWaiterMap) {
                self.runtime = runtime
                self.responseWaiters = responseWaiters
            }

            func sessionUpdate(_ params: SessionNotification) async throws {
                let raw = try ClientCodec.toJSONValue(params)
                try await runtime.notify(method: Methods.clientSessionUpdate, params: raw)
            }

            func requestPermission(_ params: RequestPermissionRequest) async throws -> RequestPermissionResponse {
                let raw = try ClientCodec.toJSONValue(params)
                let result = try await runtime.request(method: Methods.clientSessionRequestPermission, params: raw)
                return try ClientCodec.fromJSONValue(RequestPermissionResponse.self, value: result)
            }

            func extNotification(method: String, params: [String: JSONValue]) async throws {
                try await runtime.notify(method: method, params: .object(params))
            }

            func createElicitation(_ params: CreateElicitationRequest) async throws -> CreateElicitationResponse {
                let raw = try ClientCodec.toJSONValue(params)
                let result = try await runtime.request(method: Methods.clientElicitationCreate, params: raw)
                return try ClientCodec.fromJSONValue(CreateElicitationResponse.self, value: result)
            }

            func responded(requestId: JSONRPCId) -> @Sendable () async -> Bool {
                let gate = responseWaiters.register(id: requestId)
                return {
                    await gate.wait()
                }
            }
        }

        // parity: cli/src/acp/connection.ts#make [status=adapted hash=d8c004552362]
        public static func make(app: AgentApp, stream: NDJSONStream) -> Connected {
            let waiters = ResponseWaiterMap()
            let wrappedStream = NDJSONStream(
                readable: stream.readable,
                write: { message in
                    try await stream.write(message)
                    switch message {
                    case .response(let id, _):
                        waiters.resolve(id: id, succeeded: true)
                    case .errorResponse(let id, _):
                        if let id {
                            waiters.resolve(id: id, succeeded: false)
                        }
                    case .request, .notification:
                        break
                    }
                },
                close: {
                    waiters.closeAll()
                    await stream.close()
                }
            )
            let runtime = app.connect(stream: wrappedStream)
            let connection = LiveConnection(runtime: runtime, responseWaiters: waiters)
            return Connected(agent: runtime, connection: connection)
        }
    }

    // MARK: - 15. Permission Bridge (`packages/cli/src/acp/permission.ts`)

    public enum PermissionBridge {
        private static let pathActions: Set<String> = ["read", "edit", "external_directory"]

        public static let standardOptions: [PermissionOption] = [
            PermissionOption(optionId: "once", kind: "allow_once", name: "Allow once"),
            PermissionOption(optionId: "always", kind: "allow_always", name: "Always allow"),
            PermissionOption(optionId: "reject", kind: "reject_once", name: "Reject"),
        ]

        public struct ToolRef: Equatable, Hashable, Sendable {
            public let id: String
            public let name: String
            public let input: ToolMapper.ToolInput

            public init(id: String, name: String, input: ToolMapper.ToolInput) {
                self.id = id
                self.name = name
                self.input = input
            }
        }

        public struct Input: Sendable {
            public let client: any BackendClient
            public let connection: any Connection.Interface
            public let event: Translate.PermissionAskEvent
            public let sessionID: String
            public let clientSessionID: String
            public let cwd: String
            public let tool: ToolRef?
            public let child: Child.Session?
            public let fileSystem: any OpenCodeFileSystem

            public init(
                client: any BackendClient,
                connection: any Connection.Interface,
                event: Translate.PermissionAskEvent,
                sessionID: String,
                clientSessionID: String,
                cwd: String,
                tool: ToolRef? = nil,
                child: Child.Session? = nil,
                fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared
            ) {
                self.client = client
                self.connection = connection
                self.event = event
                self.sessionID = sessionID
                self.clientSessionID = clientSessionID
                self.cwd = cwd
                self.tool = tool
                self.child = child
                self.fileSystem = fileSystem
            }
        }

        // parity: cli/src/acp/permission.ts#ask [status=implemented hash=d9f1be4896e1]
        public static func ask(_ input: Input) async throws -> PermissionSchema.Reply {
            let toolName = input.tool?.name ?? input.event.action
            let toolInput = input.tool?.input ?? input.event.metadata ?? [:]
            let previews = await permissionPreviews(
                toolName: toolName,
                input: toolInput,
                metadata: input.event.metadata,
                cwd: input.cwd,
                fileSystem: input.fileSystem
            )
            let title = permissionTitle(toolName: toolName, input: toolInput, previews: previews)
            let prefixedTitle: String? = title.map { Child.prefixTitle(input.child, value: $0) } ?? input.child?.title
            var toolCall = ToolMapper.pendingToolCall(
                toolCallId: Child.toolCallID(input.child, id: input.tool?.id ?? input.event.id),
                toolName: toolName,
                input: toolInput,
                title: prefixedTitle,
                cwd: input.cwd
            )
            toolCall.name = input.tool?.name
            toolCall.rawInput = input.tool != nil ? toolCall.rawInput : nil
            toolCall.locations = permissionLocations(toolName: toolName, input: toolInput, ask: input.event, cwd: input.cwd)
            if !previews.isEmpty {
                toolCall.content = previews.map { .diff($0) }
            }
            if let child = input.child {
                toolCall._meta = Child.meta(child)
            }
            let result = try await input.connection.requestPermission(
                RequestPermissionRequest(
                    sessionId: input.clientSessionID,
                    toolCall: toolCall,
                    options: standardOptions
                )
            )
            if case .selected(let optionId) = result.outcome {
                if optionId == "once" { return .once }
                if optionId == "always" { return .always }
            }
            return .reject
        }

        // parity: cli/src/acp/permission.ts#respond [status=implemented hash=202c37433e3a]
        public static func respond(_ input: Input, decision: PermissionSchema.Reply) async throws {
            do {
                try await input.client.permissionReply(
                    sessionID: input.sessionID,
                    requestID: input.event.id,
                    decision: decision
                )
            } catch is OpenCodeProtocol.PermissionNotFoundError {
                return
            } catch ProtocolErrorEnvelope.permissionNotFound {
                return
            } catch {
                try ClientHelpers.rethrowClassified(error)
            }
        }

        // parity: cli/src/acp/permission.ts#withCompletedDiffs [status=implemented hash=1655faee7d4a]
        public static func withCompletedDiffs(
            _ update: SessionUpdate,
            source: ToolMapper.DiffSource?,
            cwd: String,
            fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared
        ) async -> SessionUpdate {
            guard let source, case .toolCallUpdate(var tu) = update else { return update }
            let files = decodeFileDiffs(source.metadata?["files"])
            guard !files.isEmpty else { return update }
            let hunks = ToolMapper.canonicalName(source.toolName) == "patch" ? ToolMapper.patchHunks(source.input) : []

            var diffs: [ToolCallContent] = []
            for file in files {
                let path = ToolMapper.absolutePath(file.file, cwd: cwd)
                let newText: String
                if file.status == .deleted {
                    newText = ""
                } else {
                    guard let bytes = try? await fileSystem.readFile(at: path) else { continue }
                    newText = String(decoding: bytes, as: UTF8.self)
                }
                if file.status == .added {
                    diffs.append(.diff(DiffContent(path: path, oldText: nil, newText: newText)))
                    continue
                }
                guard let recorded = UnifiedDiff.parsePatch(file.patch).first else { continue }
                if let oldText = UnifiedDiff.applyPatch(newText, UnifiedDiff.reversePatch(recorded)) {
                    diffs.append(.diff(DiffContent(path: path, oldText: oldText, newText: newText)))
                    continue
                }
                // Core trims indentation from patch-tool diffs; rebuild from patch hunks if ranges agree.
                let matchingHunk = hunks.first { item in
                    if case .update(let hPath, let movePath, _) = item {
                        return ToolMapper.absolutePath(movePath ?? hPath, cwd: cwd) == path
                    }
                    return false
                }
                if case .update(let hPath, _, let chunks) = matchingHunk,
                   !chunks.contains(where: { $0.oldLines.isEmpty || $0.newLines.isEmpty })
                {
                    let reversedChunks = chunks.map { chunk in
                        Patch.UpdateFileChunk(
                            oldLines: chunk.newLines,
                            newLines: chunk.oldLines,
                            changeContext: chunk.changeContext,
                            endOfFile: chunk.endOfFile
                        )
                    }
                    if let rebuilt = try? Patch.derive(path: hPath, chunks: reversedChunks, original: newText).content {
                        let computed = UnifiedDiff.structuredPatch(
                            oldFileName: path,
                            newFileName: path,
                            oldStr: rebuilt,
                            newStr: newText
                        )
                        if computed.rangesSignature == recorded.rangesSignature {
                            diffs.append(.diff(DiffContent(path: path, oldText: rebuilt, newText: newText)))
                        }
                    }
                }
            }
            guard !diffs.isEmpty else { return update }
            tu.content = (tu.content ?? []) + diffs
            return .toolCallUpdate(tu)
        }

        private static func permissionPreviews(
            toolName: String,
            input: ToolMapper.ToolInput,
            metadata: ToolMapper.ToolInput?,
            cwd: String,
            fileSystem: any OpenCodeFileSystem
        ) async -> [DiffContent] {
            if ToolMapper.canonicalName(toolName) == "patch" {
                return await patchPreviews(input: input, cwd: cwd, fileSystem: fileSystem)
            }
            let files = decodeFileDiffs(metadata?["files"])
            var previews: [DiffContent] = []
            for file in files {
                let path = ToolMapper.absolutePath(file.file, cwd: cwd)
                let oldText: String?
                if file.status == .added {
                    oldText = nil
                } else {
                    guard let bytes = try? await fileSystem.readFile(at: path) else { continue }
                    oldText = String(decoding: bytes, as: UTF8.self)
                }
                if let newText = UnifiedDiff.applyPatch(oldText ?? "", file.patch) {
                    previews.append(DiffContent(path: path, oldText: oldText, newText: newText))
                }
            }
            return previews
        }

        private static func patchPreviews(
            input: ToolMapper.ToolInput,
            cwd: String,
            fileSystem: any OpenCodeFileSystem
        ) async -> [DiffContent] {
            var previews: [DiffContent] = []
            for hunk in ToolMapper.patchHunks(input) {
                switch hunk {
                case .add(let hPath, let contents):
                    let path = ToolMapper.absolutePath(hPath, cwd: cwd)
                    let newText = (contents.isEmpty || contents.hasSuffix("\n")) ? contents : "\(contents)\n"
                    previews.append(DiffContent(path: path, oldText: nil, newText: newText))
                case .delete(let hPath):
                    let path = ToolMapper.absolutePath(hPath, cwd: cwd)
                    guard let bytes = try? await fileSystem.readFile(at: path) else { continue }
                    let oldText = String(decoding: bytes, as: UTF8.self)
                    previews.append(DiffContent(path: path, oldText: oldText, newText: ""))
                case .update(let hPath, let movePath, let chunks):
                    let path = ToolMapper.absolutePath(hPath, cwd: cwd)
                    guard let bytes = try? await fileSystem.readFile(at: path) else { continue }
                    let oldText = String(decoding: bytes, as: UTF8.self)
                    guard let derived = try? Patch.derive(path: hPath, chunks: chunks, original: oldText) else { continue }
                    let dest = movePath.map { ToolMapper.absolutePath($0, cwd: cwd) } ?? path
                    previews.append(DiffContent(path: dest, oldText: oldText, newText: derived.content))
                }
            }
            return previews
        }

        private static func permissionTitle(
            toolName: String,
            input: ToolMapper.ToolInput,
            previews: [DiffContent]
        ) -> String? {
            if previews.count > 1 { return "\(previews.count) files" }
            switch ToolMapper.canonicalName(toolName) {
            case "external_directory":
                return ToolMapper.stringValue(input["description"])
                    ?? ToolMapper.stringValue(input["command"])
                    ?? ToolMapper.stringValue(input["parentDir"])
            case "webfetch":
                return ToolMapper.stringValue(input["url"])
            case "websearch":
                return ToolMapper.stringValue(input["query"])
            case "grep", "glob":
                return ToolMapper.stringValue(input["pattern"])
            case "read", "edit", "write", "patch":
                return ToolMapper.filePath(input) ?? previews.first?.path
            default:
                return nil
            }
        }

        private static func permissionLocations(
            toolName: String,
            input: ToolMapper.ToolInput,
            ask: Translate.PermissionAskEvent,
            cwd: String
        ) -> [ToolCallLocation] {
            let locations = ToolMapper.toLocations(toolName: toolName, input: input, cwd: cwd)
            if !locations.isEmpty || !pathActions.contains(ask.action) { return locations }
            var seen: Set<String> = []
            var out: [ToolCallLocation] = []
            for resource in ask.resources {
                let cleaned = resource.hasSuffix("/*") ? String(resource.dropLast(2)) : resource
                guard !cleaned.isEmpty, !cleaned.contains("*"), !cleaned.contains("?") else { continue }
                let abs = ToolMapper.absolutePath(cleaned, cwd: cwd)
                if seen.insert(abs).inserted {
                    out.append(ToolCallLocation(path: abs))
                }
            }
            return out
        }

        private static func decodeFileDiffs(_ value: JSONValue?) -> [FileDiffSchema.Info] {
            guard let value else { return [] }
            return (try? ClientCodec.fromJSONValue([FileDiffSchema.Info].self, value: value)) ?? []
        }
    }

    // MARK: - 16. Prompt Preparation (`packages/cli/src/acp/prompt.ts`)

    public enum Prompt {
        public struct SlashCommand: Equatable, Hashable, Sendable {
            public let name: String
            public let args: String

            public init(name: String, args: String) {
                self.name = name
                self.args = args
            }
        }

        // parity: cli/src/acp/prompt.ts#Prepared [status=implemented hash=6d3f973ea40d]
        public struct Prepared: Equatable, Hashable, Sendable {
            public let start: Translate.TurnStart
            public let text: String
            public let files: [PromptInputSchema.FileAttachment]
            public let synthetic: [String]
            public let slash: SlashCommand?
            public let command: CommandSchema.Info?

            public init(
                start: Translate.TurnStart,
                text: String,
                files: [PromptInputSchema.FileAttachment],
                synthetic: [String],
                slash: SlashCommand? = nil,
                command: CommandSchema.Info? = nil
            ) {
                self.start = start
                self.text = text
                self.files = files
                self.synthetic = synthetic
                self.slash = slash
                self.command = command
            }
        }

        // parity: cli/src/acp/prompt.ts#prepare [status=implemented hash=f78ea5acabea]
        public static func prepare(
            catalog: CatalogStore.Catalog,
            content: [ContentBlock],
            fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared
        ) async throws(Errors.ACPError) -> Prepared {
            let hasEmptyImage = content.contains { block in
                if case .image(_, let data, let uri) = block {
                    return (data == nil || data!.isEmpty) && (uri == nil || uri!.isEmpty)
                }
                return false
            }
            if hasEmptyImage {
                throw .invalidRequest(
                    Errors.InvalidRequestError(message: "image content has no data or uri", field: "prompt")
                )
            }
            let rawParts = Content.promptContentToParts(content)
            var parts: [Content.PromptPart] = []
            parts.reserveCapacity(rawParts.count)
            for part in rawParts {
                parts.append(await referenceUnreadableFile(part, fileSystem: fileSystem))
            }
            let visible = parts.filter { part in
                switch part {
                case .text(_, let synthetic, let ignored):
                    return synthetic != true && ignored != true
                case .file:
                    return true
                }
            }
            let text = visible.compactMap { part -> String? in
                if case .text(let t, _, _) = part { return t }
                return nil
            }.joined(separator: "\n")
            let files: [PromptInputSchema.FileAttachment] = visible.compactMap { part in
                if case .file(let url, let filename, _) = part {
                    return PromptInputSchema.FileAttachment(uri: url, name: filename)
                }
                return nil
            }
            let synthetic: [String] = parts.compactMap { part in
                if case .text(let t, let isSynthetic, _) = part, isSynthetic == true { return t }
                return nil
            }
            let slash = detectSlashCommand(text)
            let id = SessionMessageSchema.ID.create()
            let isCompaction = slash.flatMap { CatalogStore.builtinCommands[$0.name]?.start } == .compaction
            let start = Translate.TurnStart(type: isCompaction ? .compaction : .input, id: id)
            let command = slash.flatMap { cmd in catalog.commands.first { $0.name == cmd.name } }
            return Prepared(
                start: start,
                text: text,
                files: files,
                synthetic: synthetic,
                slash: slash,
                command: command
            )
        }

        private static func referenceUnreadableFile(
            _ part: Content.PromptPart,
            fileSystem: any OpenCodeFileSystem
        ) async -> Content.PromptPart {
            guard case .file(let url, let filename, _) = part, url.hasPrefix("file://") else {
                return part
            }
            guard let localPath = Content.fileURLToPath(url) else {
                return Content.linkReference(name: filename, uri: url)
            }
            // Check file exists and is readable (directory or missing/unreadable falls back to link reference).
            if let info = try? await fileSystem.stat(at: localPath),
               info.type == .file || info.type == .symlink
            {
                if (try? await fileSystem.readFile(at: localPath)) != nil {
                    return part
                }
            }
            return Content.linkReference(name: filename, uri: url)
        }

        private static func detectSlashCommand(_ text: String) -> SlashCommand? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("/") else { return nil }
            let body = trimmed.dropFirst()
            let tokens = body.split(whereSeparator: { $0.isWhitespace })
            guard let first = tokens.first, !first.isEmpty else { return nil }
            let args = tokens.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            return SlashCommand(name: String(first), args: args)
        }
    }

    // MARK: - 17. Replay (`packages/cli/src/acp/replay.ts`)

    public enum Replay {
        // parity: cli/src/acp/replay.ts#history [status=implemented hash=f753dc8b2511]
        public static func history(
            client: any BackendClient,
            connection: any Connection.Interface,
            attached: Sessions.Attached,
            capabilities: Capabilities.Parsed,
            fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared
        ) async throws {
            var cursor: String? = nil
            while true {
                let page: SessionMessagesResponse
                do {
                    if let c = cursor {
                        page = try await client.messageList(
                            sessionID: attached.id.rawValue,
                            limit: 200,
                            order: nil,
                            cursor: c
                        )
                    } else {
                        page = try await client.messageList(
                            sessionID: attached.id.rawValue,
                            limit: 200,
                            order: .asc,
                            cursor: nil
                        )
                    }
                } catch {
                    try ClientHelpers.rethrowClassified(error)
                }

                for message in page.data {
                    for update in updates(message: message, cwd: attached.cwd, capabilities: capabilities) {
                        let enriched = await PermissionBridge.withCompletedDiffs(
                            update,
                            source: completedSource(message: message, update: update),
                            cwd: attached.cwd,
                            fileSystem: fileSystem
                        )
                        try await connection.sessionUpdate(
                            SessionNotification(sessionId: attached.id.rawValue, update: enriched)
                        )
                    }
                }

                guard let next = page.cursor.next, !next.isEmpty else { break }
                cursor = next
            }
        }

        // parity: cli/src/acp/replay.ts#updates [status=implemented hash=1c26e95fd641]
        public static func updates(
            message: SessionMessageSchema.Info,
            cwd: String,
            capabilities: Capabilities.Parsed
        ) -> [SessionUpdate] {
            switch message {
            case .user(let user):
                var out: [SessionUpdate] = [
                    .userMessageChunk(messageId: user.id.rawValue, content: .text(text: user.text)),
                ]
                let fileParts: [Content.ReplayPart] = (user.files ?? []).map { file in
                    let url: String
                    switch file.source {
                    case .uri(let uri): url = uri
                    case .inline: url = "data:\(file.mime);base64,\(file.data.rawValue)"
                    }
                    return .file(url: url, filename: file.name, mime: file.mime)
                }
                for chunk in Content.partsToContentChunks(fileParts) {
                    out.append(.userMessageChunk(messageId: user.id.rawValue, content: chunk.content))
                }
                return out

            case .compaction(let compaction):
                if let update = Compaction.replay(message: compaction, standardUpdates: capabilities.compaction) {
                    return [update]
                }
                return []

            case .assistant(let assistant):
                var reasoningOrdinal = 0
                var out: [SessionUpdate] = []
                for part in assistant.content {
                    switch part {
                    case .text(let textPart):
                        out.append(
                            .agentMessageChunk(messageId: assistant.id.rawValue, content: .text(text: textPart.text))
                        )
                    case .reasoning(let reasoningPart):
                        out.append(
                            .agentThoughtChunk(
                                messageId: Translate.reasoningMessageID(assistant.id.rawValue, ordinal: reasoningOrdinal),
                                content: .text(text: reasoningPart.text)
                            )
                        )
                        reasoningOrdinal += 1
                    case .tool(let toolPart):
                        let pendingInput: ToolMapper.ToolInput = {
                            switch toolPart.state {
                            case .streaming: return [:]
                            case .running(let s): return s.input
                            case .completed(let s): return s.input
                            case .error(let s): return s.input
                            }
                        }()
                        let call = SessionUpdate.toolCall(
                            ToolMapper.pendingToolCall(
                                toolCallId: toolPart.id,
                                toolName: toolPart.name,
                                input: pendingInput,
                                cwd: cwd
                            )
                        )
                        out.append(call)
                        switch toolPart.state {
                        case .completed(let s):
                            out.append(
                                .toolCallUpdate(
                                    ToolMapper.completedToolUpdate(
                                        toolCallId: toolPart.id,
                                        toolName: toolPart.name,
                                        input: s.input,
                                        content: s.content,
                                        metadata: s.metadata,
                                        cwd: cwd
                                    )
                                )
                            )
                        case .running(let s):
                            out.append(
                                .toolCallUpdate(
                                    ToolMapper.runningToolUpdate(
                                        toolCallId: toolPart.id,
                                        toolName: toolPart.name,
                                        input: s.input,
                                        cwd: cwd
                                    )
                                )
                            )
                        case .error(let s):
                            out.append(
                                .toolCallUpdate(
                                    ToolMapper.errorToolUpdate(
                                        toolCallId: toolPart.id,
                                        toolName: toolPart.name,
                                        input: s.input,
                                        content: s.content,
                                        metadata: s.metadata,
                                        error: s.error.message,
                                        cwd: cwd
                                    )
                                )
                            )
                        case .streaming:
                            break
                        }
                    }
                }
                return out

            default:
                return []
            }
        }

        private static func completedSource(
            message: SessionMessageSchema.Info,
            update: SessionUpdate
        ) -> ToolMapper.DiffSource? {
            guard case .assistant(let assistant) = message,
                  case .toolCallUpdate(let tu) = update
            else {
                return nil
            }
            for part in assistant.content {
                if case .tool(let tool) = part, tool.id == tu.toolCallId {
                    if case .completed(let s) = tool.state {
                        return ToolMapper.DiffSource(toolName: tool.name, input: s.input, metadata: s.metadata)
                    }
                    return nil
                }
            }
            return nil
        }
    }

    // MARK: - 18. Sessions Registry (`packages/cli/src/acp/sessions.ts`)

    public enum Sessions {
        // parity: cli/src/acp/sessions.ts#SupportedMcpServer [status=implemented hash=f26bdbc43d40]
        public enum SupportedMcpServer: Equatable, Hashable, Sendable, Codable {
            case stdio(McpServerStdio)
            case http(McpServerHttp)

            public var name: String {
                switch self {
                case .stdio(let s): s.name
                case .http(let h): h.name
                }
            }
        }

        // parity: cli/src/acp/sessions.ts#Attached [status=implemented hash=540bbeee8afe]
        public final class Attached: Sendable {
            public let id: SessionID
            public let cwd: String
            private let selectionState: Mutex<ConfigOption.Selection>

            public init(id: SessionID, cwd: String, selection: ConfigOption.Selection) {
                self.id = id
                self.cwd = cwd
                self.selectionState = Mutex(selection)
            }

            public func getSelection() -> ConfigOption.Selection {
                selectionState.withLock { $0 }
            }

            public func updateSelection(_ transform: (ConfigOption.Selection) -> ConfigOption.Selection) -> ConfigOption.Selection {
                selectionState.withLock { current in
                    let previous = current
                    current = transform(current)
                    return previous
                }
            }
        }

        public struct AttachmentResult: Sendable {
            public let attached: Attached
            public let configOptions: [SessionConfigOption]

            public init(attached: Attached, configOptions: [SessionConfigOption]) {
                self.attached = attached
                self.configOptions = configOptions
            }
        }

        // parity: cli/src/acp/sessions.ts#Interface [status=implemented hash=90d364b8a952]
        public protocol Interface: Sendable {
            func attach(
                session: SessionSchema.Info,
                cwd: String,
                mcpServers: [SupportedMcpServer]
            ) async throws -> AttachmentResult
            func detach(sessionID: String) async
            func release(attached: Attached) async
            func require(sessionID: String) throws(Errors.ACPError) -> Attached
            func fork(attached: Attached, operation: @escaping @Sendable () async -> Void) throws(Errors.ACPError)
            func select(attached: Attached, change: ConfigOption.Change) async throws
            func shutdown() async
        }

        private final class Entry: Sendable {
            let attached: Attached
            let selected = AsyncFIFO<ConfigOption.Change>()
            let tasks = Mutex<[Task<Void, Never>]>([])

            init(attached: Attached) {
                self.attached = attached
            }

            func addTask(_ task: Task<Void, Never>) {
                tasks.withLock { $0.append(task) }
            }

            func close() {
                selected.finish()
                let list = tasks.withLock { arr -> [Task<Void, Never>] in
                    let copy = arr
                    arr.removeAll()
                    return copy
                }
                for task in list {
                    task.cancel()
                }
            }
        }

        private final class Store: Interface, Sendable {
            private struct State: Sendable {
                var sessions: [String: Entry] = [:]
                var registeredMcpBySession: [String: [String: McpSchema.ServerConfig]] = [:]
            }

            let client: any BackendClient
            let connection: any Connection.Interface
            let catalog: any CatalogStore.Interface
            private let state = Mutex(State())
            let connected = AsyncGate()
            let eventTask: Mutex<Task<Void, Never>?> = Mutex(nil)

            init(
                client: any BackendClient,
                connection: any Connection.Interface,
                catalog: any CatalogStore.Interface
            ) {
                self.client = client
                self.connection = connection
                self.catalog = catalog
                let task = Task<Void, Never> { [weak self] in
                    await self?.listenSelectionEvents()
                }
                self.eventTask.withLock { $0 = task }
            }

            private func listenSelectionEvents() async {
                defer { connected.resolve(succeeded: true) }
                do {
                    for try await event in client.eventSubscribe() {
                        if Task.isCancelled { break }
                        if event.type == "server.connected" {
                            connected.resolve(succeeded: true)
                            continue
                        }
                        guard event.type == "session.model.selected" || event.type == "session.agent.selected",
                              case .object(let obj) = event.data,
                              let sid = ToolMapper.stringValue(obj["sessionID"])
                        else {
                            continue
                        }
                        guard let entry = state.withLock({ $0.sessions[sid] }) else { continue }
                        if event.type == "session.model.selected",
                           let modelVal = obj["model"],
                           let model = try? ClientCodec.fromJSONValue(ModelSchema.Ref.self, value: modelVal)
                        {
                            entry.selected.push(.model(model))
                        } else if event.type == "session.agent.selected",
                                  let agent = ToolMapper.stringValue(obj["agent"])
                        {
                            entry.selected.push(.modeID(AgentSchema.ID(rawValue: agent)))
                        }
                    }
                } catch {
                    // Selection event stream failed; resolve connected so attaches don't hang.
                }
            }

            func attach(
                session: SessionSchema.Info,
                cwd: String,
                mcpServers: [SupportedMcpServer]
            ) async throws -> AttachmentResult {
                _ = await connected.wait()
                let current = try await catalog.get(cwd: cwd)
                let initialSelection = ConfigOption.Selection(
                    model: session.model.map {
                        ModelSchema.Ref(
                            id: ModelSchema.ID(rawValue: $0.id),
                            providerID: ProviderSchema.ID(rawValue: $0.providerID),
                            variant: $0.variant.map(ModelSchema.VariantID.init(rawValue:))
                        )
                    },
                    modeID: session.agent.map(AgentSchema.ID.init(rawValue:))
                )
                let attached = Attached(id: session.id, cwd: cwd, selection: initialSelection)
                let entry = Entry(attached: attached)

                let replaced: Entry? = state.withLock { s in
                    let prev = s.sessions[session.id.rawValue]
                    s.sessions[session.id.rawValue] = entry
                    return prev
                }
                replaced?.close()

                do {
                    try await registerMcp(attached: attached, servers: mcpServers)
                } catch {
                    remove(sessionID: session.id.rawValue, entry: entry)
                    throw error
                }

                let responded = Connection.Responded.current
                let watcherTask = Task { [weak self] in
                    guard let self else { return }
                    let ok = await responded()
                    guard ok && !Task.isCancelled else { return }
                    try? await self.sendCommands(sessionID: session.id.rawValue, catalog: current)
                    await self.watchUpdates(entry: entry, initialCatalog: current)
                }
                entry.addTask(watcherTask)

                return AttachmentResult(
                    attached: attached,
                    configOptions: ConfigOption.configOptions(current, selection: attached.getSelection())
                )
            }

            func detach(sessionID: String) async {
                let entry = state.withLock { $0.sessions[sessionID] }
                if let entry {
                    remove(sessionID: sessionID, entry: entry)
                }
            }

            func release(attached: Attached) async {
                let entry = state.withLock { $0.sessions[attached.id.rawValue] }
                if let entry, entry.attached === attached {
                    remove(sessionID: attached.id.rawValue, entry: entry)
                }
            }

            func require(sessionID: String) throws(Errors.ACPError) -> Attached {
                guard let entry = state.withLock({ $0.sessions[sessionID] }) else {
                    throw .sessionNotFound(Errors.SessionNotFoundError(sessionId: sessionID))
                }
                return entry.attached
            }

            func fork(attached: Attached, operation: @escaping @Sendable () async -> Void) throws(Errors.ACPError) {
                guard let entry = state.withLock({ $0.sessions[attached.id.rawValue] }),
                      entry.attached === attached
                else {
                    throw .sessionNotFound(Errors.SessionNotFoundError(sessionId: attached.id.rawValue))
                }
                let task = Task {
                    await operation()
                }
                entry.addTask(task)
            }

            func select(attached: Attached, change: ConfigOption.Change) async throws {
                _ = attached.updateSelection { $0.applying(change) }
                do {
                    switch change {
                    case .model(let ref):
                        try await client.sessionSwitchModel(sessionID: attached.id.rawValue, model: ref)
                    case .modeID(let modeID):
                        try await client.sessionSwitchAgent(sessionID: attached.id.rawValue, agent: modeID.rawValue)
                    }
                } catch {
                    try ClientHelpers.rethrowClassified(error)
                }
            }

            func shutdown() async {
                eventTask.withLock { t in
                    t?.cancel()
                    t = nil
                }
                let all = state.withLock { s -> [Entry] in
                    let values = Array(s.sessions.values)
                    s.sessions.removeAll()
                    s.registeredMcpBySession.removeAll()
                    return values
                }
                for entry in all {
                    entry.close()
                }
            }

            private func remove(sessionID: String, entry: Entry) {
                state.withLock { s in
                    if s.sessions[sessionID] === entry {
                        s.sessions.removeValue(forKey: sessionID)
                        s.registeredMcpBySession.removeValue(forKey: sessionID)
                    }
                }
                entry.close()
            }

            private func registerMcp(attached: Attached, servers: [SupportedMcpServer]) async throws {
                guard !servers.isEmpty else { return }
                let sid = attached.id.rawValue
                for server in servers {
                    let config = mcpConfig(server)
                    let alreadySame: Bool = state.withLock { s in
                        var map = s.registeredMcpBySession[sid] ?? [:]
                        if map[server.name] == config { return true }
                        map[server.name] = config
                        s.registeredMcpBySession[sid] = map
                        return false
                    }
                    if alreadySame { continue }
                    do {
                        try await client.experimentalMcpAdd(
                            server: server.name,
                            directory: attached.cwd,
                            config: config
                        )
                    } catch {
                        state.withLock { s in
                            _ = s.registeredMcpBySession[sid]?.removeValue(forKey: server.name)
                        }
                        try ClientHelpers.rethrowClassified(error)
                    }
                }
            }

            private func sendCommands(sessionID: String, catalog: CatalogStore.Catalog) async throws {
                try await connection.sessionUpdate(
                    SessionNotification(
                        sessionId: sessionID,
                        update: .availableCommandsUpdate(availableCommands: ConfigOption.availableCommands(catalog))
                    )
                )
            }

            private enum MergedStep: Sendable {
                case catalog(CatalogStore.Catalog)
                case selection(ConfigOption.Change)
            }

            private func watchUpdates(entry: Entry, initialCatalog: CatalogStore.Catalog) async {
                let merged = AsyncFIFO<MergedStep>()
                let catalogStream = catalog.changes(cwd: entry.attached.cwd)
                let catTask = Task {
                    do {
                        for try await cat in catalogStream {
                            if Task.isCancelled { break }
                            merged.push(.catalog(cat))
                        }
                    } catch {
                        // ignore
                    }
                }
                let selTask = Task {
                    do {
                        while let change = try await entry.selected.next() {
                            if Task.isCancelled { break }
                            merged.push(.selection(change))
                        }
                    } catch {
                        // ignore
                    }
                }
                defer {
                    catTask.cancel()
                    selTask.cancel()
                    merged.finish()
                }
                var previous = initialCatalog
                while !Task.isCancelled {
                    guard let step = try? await merged.next() else { break }
                    let nextCatalog: CatalogStore.Catalog
                    let patch: ConfigOption.Selection
                    switch step {
                    case .catalog(let cat):
                        nextCatalog = cat
                        patch = ConfigOption.Selection()
                    case .selection(let change):
                        nextCatalog = previous
                        patch = ConfigOption.Selection().applying(change)
                    }
                    let oldSelection = entry.attached.updateSelection { $0.merging(patch) }
                    let newSelection = oldSelection.merging(patch)
                    let newOptions = ConfigOption.configOptions(nextCatalog, selection: newSelection)
                    let oldOptions = ConfigOption.configOptions(previous, selection: oldSelection)
                    if newOptions != oldOptions {
                        try? await connection.sessionUpdate(
                            SessionNotification(
                                sessionId: entry.attached.id.rawValue,
                                update: .configOptionUpdate(configOptions: newOptions)
                            )
                        )
                    }
                    if nextCatalog.commands != previous.commands {
                        try? await sendCommands(sessionID: entry.attached.id.rawValue, catalog: nextCatalog)
                    }
                    previous = nextCatalog
                }
            }
        }

        // parity: cli/src/acp/sessions.ts#make [status=adapted hash=9035a1f62c5a]
        public static func make(
            client: any BackendClient,
            connection: any Connection.Interface,
            catalog: any CatalogStore.Interface
        ) -> any Interface {
            Store(client: client, connection: connection, catalog: catalog)
        }

        internal static func mcpConfig(_ server: SupportedMcpServer) -> McpSchema.ServerConfig {
            switch server {
            case .http(let http):
                var headers: [String: String] = [:]
                for h in http.headers { headers[h.name] = h.value }
                return .remote(McpSchema.RemoteConfig(url: http.url, headers: headers, oauth: .disabled))
            case .stdio(let stdio):
                var env: [String: String] = [:]
                for e in stdio.env { env[e.name] = e.value }
                return .local(McpSchema.LocalConfig(command: [stdio.command] + stdio.args, environment: env))
            }
        }
    }

    // MARK: - 19. Turn Runner (`packages/cli/src/acp/turn.ts`)

    public enum Turn {
        // parity: cli/src/acp/turn.ts#SteeringRequest [status=implemented hash=6dd1208fc4a1]
        public struct SteeringRequest: Equatable, Hashable, Sendable, Codable {
            public let sessionId: String
            public let prompt: [ContentBlock]

            public init(sessionId: String, prompt: [ContentBlock]) {
                self.sessionId = sessionId
                self.prompt = prompt
            }
        }

        // parity: cli/src/acp/turn.ts#SteeringResponse [status=implemented hash=90561f0bea04]
        public enum SteeringResponse: Equatable, Hashable, Sendable, Codable {
            case injected
            case promptRequired(reason: String)

            private enum CodingKeys: String, CodingKey {
                case outcome
                case reason
            }

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                let outcome = try c.decode(String.self, forKey: .outcome)
                switch outcome {
                case "injected":
                    self = .injected
                case "promptRequired":
                    self = .promptRequired(reason: try c.decode(String.self, forKey: .reason))
                default:
                    throw DecodingError.dataCorruptedError(
                        forKey: .outcome,
                        in: c,
                        debugDescription: "Unknown steering outcome '\(outcome)'"
                    )
                }
            }

            public func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                switch self {
                case .injected:
                    try c.encode("injected", forKey: .outcome)
                case .promptRequired(let reason):
                    try c.encode("promptRequired", forKey: .outcome)
                    try c.encode(reason, forKey: .reason)
                }
            }
        }

        // parity: cli/src/acp/turn.ts#Interface [status=implemented hash=91aff97a9d0e]
        public protocol Interface: Sendable {
            func prompt(_ input: PromptRequest, signal: AbortSignal) async throws -> PromptResponse
            func steer(_ input: SteeringRequest) async throws -> SteeringResponse
            func cancel(_ input: CancelNotification) async
            func close(sessionID: String) async throws
        }

        /// Core acknowledges an interrupt before its cleanup settles, and its shell tool waits 3s before SIGKILL.
        // parity: cli/src/acp/turn.ts#CancelDrainTimeout [status=adapted hash=1ef3760fa741]
        public enum CancelDrainTimeout {
            public static let defaultNanoseconds: UInt64 = 5_000_000_000

            @TaskLocal
            public static var nanoseconds: UInt64 = 5_000_000_000
        }

        private final class Subscription: Sendable {
            let events = AsyncFIFO<OpenCodeEvent>()
            let askQueue = AsyncFIFO<@Sendable () async -> Void>()
            let settled = Mutex<[String: AsyncGate]>([:])
            let tasks = Mutex<[Task<Void, Never>]>([])

            func addTask(_ task: Task<Void, Never>) {
                tasks.withLock { $0.append(task) }
            }

            func close() {
                events.finish()
                askQueue.finish()
                let list = tasks.withLock { arr -> [Task<Void, Never>] in
                    let copy = arr
                    arr.removeAll()
                    return copy
                }
                for task in list {
                    task.cancel()
                }
                let gates = settled.withLock { map -> [AsyncGate] in
                    let values = Array(map.values)
                    map.removeAll()
                    return values
                }
                for gate in gates {
                    gate.resolve(succeeded: false)
                }
            }
        }

        private final class TurnStateBox: Sendable {
            private let mutex: Mutex<Translate.TurnState>

            init(_ initial: Translate.TurnState) {
                self.mutex = Mutex(initial)
            }

            func withLock<R: Sendable>(_ body: (inout Translate.TurnState) throws -> R) rethrows -> R {
                try mutex.withLock { current in
                    try body(&current)
                }
            }
        }

        private final class ActiveTurn: Sendable {
            let ctx: Translate.TurnContext
            let state: TurnStateBox
            let subscription: Subscription
            let cancelled = AsyncGate()

            init(ctx: Translate.TurnContext, state: Translate.TurnState, subscription: Subscription) {
                self.ctx = ctx
                self.state = TurnStateBox(state)
                self.subscription = subscription
            }
        }

        private final class BackgroundHolder: Sendable {
            let state: TurnStateBox
            let cancel: (@Sendable () -> Void)?

            init(state: TurnStateBox, cancel: (@Sendable () -> Void)? = nil) {
                self.state = state
                self.cancel = cancel
            }
        }

        private struct RunningTurnEntry: Sendable {
            let task: Task<Result<PromptResponse, any Swift.Error>, Never>
            let cancel: @Sendable () -> Void
        }

        private enum AskRaceOutcome<A: Sendable>: Sendable {
            case cancelled
            case settled
            case answered(A)
        }

        private final class Runner: Interface, Sendable {
            let client: any BackendClient
            let connection: any Connection.Interface
            let sessions: any Sessions.Interface
            let catalog: any CatalogStore.Interface
            let capabilities: CapabilitiesBox
            let fileSystem: any OpenCodeFileSystem
            let drainTimeoutNanoseconds: UInt64

            private struct State: Sendable {
                var turns: [String: RunningTurnEntry] = [:]
                var backgrounds: [ObjectIdentifier: BackgroundHolder] = [:]
            }

            private let state = Mutex(State())

            init(
                client: any BackendClient,
                connection: any Connection.Interface,
                sessions: any Sessions.Interface,
                catalog: any CatalogStore.Interface,
                capabilities: CapabilitiesBox,
                fileSystem: any OpenCodeFileSystem,
                drainTimeoutNanoseconds: UInt64
            ) {
                self.client = client
                self.connection = connection
                self.sessions = sessions
                self.catalog = catalog
                self.capabilities = capabilities
                self.fileSystem = fileSystem
                self.drainTimeoutNanoseconds = drainTimeoutNanoseconds
            }

            func prompt(_ input: PromptRequest, signal: AbortSignal) async throws -> PromptResponse {
                let sessionId = input.sessionId
                let turnCancel = AbortController()

                // Register synchronously before setup so concurrent prompts collide deterministically.
                let registered: RunningTurnEntry = try state.withLock { s in
                    if s.turns[sessionId] != nil {
                        throw Errors.ACPError.serviceFailure(
                            Errors.ServiceFailureError(
                                safeMessage: "Session already has an active ACP prompt: \(sessionId)",
                                service: "session"
                            )
                        )
                    }
                    let responded = Connection.Responded.current
                    let task = Task<Result<PromptResponse, any Swift.Error>, Never> { [weak self] in
                        guard let self else {
                            return .failure(Errors.ACPError.serverUnavailable(Errors.ServerUnavailableError()))
                        }
                        defer {
                            self.state.withLock { _ = $0.turns.removeValue(forKey: sessionId) }
                        }
                        return await Connection.Responded.$current.withValue(responded) {
                            do {
                                return .success(try await self.runTurn(params: input, cancelSignal: turnCancel.signal))
                            } catch {
                                return .failure(error)
                            }
                        }
                    }
                    let entry = RunningTurnEntry(task: task, cancel: { turnCancel.abort() })
                    s.turns[sessionId] = entry
                    return entry
                }

                let abortWatch = Task {
                    await awaitAborted(signal)
                    if !Task.isCancelled {
                        registered.cancel()
                    }
                }
                defer { abortWatch.cancel() }

                let result = await registered.task.value
                return try result.get()
            }

            func steer(_ input: SteeringRequest) async throws -> SteeringResponse {
                let attached = try sessions.require(sessionID: input.sessionId)
                let active: [String: SessionActiveInfo]
                do {
                    active = try await client.sessionActive()
                } catch {
                    try ClientHelpers.rethrowClassified(error)
                }
                if active[attached.id.rawValue] == nil {
                    return .promptRequired(reason: "noRunningTurn")
                }
                let cat = try await catalog.get(cwd: attached.cwd)
                let prepared = try await Prompt.prepare(catalog: cat, content: input.prompt, fileSystem: fileSystem)
                try await submitSynthetic(attached: attached, prompt: prepared)
                do {
                    try await client.sessionPrompt(
                        sessionID: attached.id.rawValue,
                        id: prepared.start.id.rawValue,
                        text: prepared.text,
                        files: prepared.files,
                        delivery: .steer,
                        resume: false
                    )
                } catch {
                    try ClientHelpers.rethrowClassified(error)
                }
                return .injected
            }

            func cancel(_ input: CancelNotification) async {
                let entry = state.withLock { $0.turns[input.sessionId] }
                entry?.cancel()
            }

            func close(sessionID: String) async throws {
                if let entry = state.withLock({ $0.turns[sessionID] }) {
                    entry.cancel()
                    _ = await entry.task.value
                    return
                }
                let id: SessionID
                do {
                    id = try ClientHelpers.decodeSessionID(sessionID)
                } catch {
                    return
                }
                do {
                    try await client.sessionInterrupt(sessionID: id.rawValue)
                } catch is OpenCodeProtocol.SessionNotFoundError {
                    return
                } catch ProtocolErrorEnvelope.sessionNotFound {
                    return
                } catch {
                    try ClientHelpers.rethrowClassified(error)
                }
            }

            private func runTurn(params: PromptRequest, cancelSignal: AbortSignal) async throws -> PromptResponse {
                let attached = try sessions.require(sessionID: params.sessionId)
                let cat = try await catalog.get(cwd: attached.cwd)
                let prepared = try await Prompt.prepare(catalog: cat, content: params.prompt, fileSystem: fileSystem)
                let caps = capabilities.get()

                let ctx = Translate.TurnContext(
                    sessionID: attached.id,
                    cwd: attached.cwd,
                    start: prepared.start,
                    childUpdates: caps.childSessionUpdates,
                    compaction: caps.compaction
                )
                let turn = open(attached: attached, ctx: ctx)

                let exit: ExecutionExit
                do {
                    let result = try await execute(attached: attached, prompt: prepared, turn: turn, cancelSignal: cancelSignal)
                    exit = result
                } catch {
                    exit = .failed(error)
                }

                let handoffFailed: Bool = {
                    if case .failed = exit { return true }
                    return false
                }()
                handoff(attached: attached, turn: turn, failedNonInterrupt: handoffFailed)

                if case .failed(let err) = exit {
                    throw err
                }

                let currentState = turn.state.withLock { $0 }
                let terminal: Translate.Terminal = switch exit {
                case .terminal(let t): t
                case .interrupted: .interrupted
                case .failed: .failed
                }
                if terminal != .interrupted, let failure = Translate.failure(currentState) {
                    throw failure
                }
                await sendUsageUpdate(attached: attached, state: currentState)
                let finalTerminal: Translate.Terminal = cancelSignal.isAborted ? .interrupted : terminal
                return Translate.response(currentState, sessionID: attached.id.rawValue, terminal: finalTerminal)
            }

            private func open(attached: Sessions.Attached, ctx: Translate.TurnContext) -> ActiveTurn {
                let key = ObjectIdentifier(attached)
                let previous = state.withLock { $0.backgrounds.removeValue(forKey: key) }
                var initialState = Translate.initial
                if let previous {
                    previous.cancel?()
                    let inherited = previous.state.withLock { $0 }
                    initialState.children = inherited.children
                    initialState.openChildren = inherited.openChildren
                    initialState.shells = inherited.shells
                }

                let sub = Subscription()
                let eventStream = client.eventSubscribe()
                let pumpTask = Task {
                    do {
                        for try await event in eventStream {
                            if Task.isCancelled { break }
                            sub.events.push(event)
                        }
                        sub.events.finish()
                    } catch {
                        sub.events.finish(throwing: error)
                    }
                }
                let askTask = Task {
                    while !Task.isCancelled {
                        guard let work = try? await sub.askQueue.next() else { break }
                        await work()
                    }
                }
                sub.addTask(pumpTask)
                sub.addTask(askTask)
                return ActiveTurn(ctx: ctx, state: initialState, subscription: sub)
            }

            private func takeEvent(from subscription: Subscription) async throws -> OpenCodeEvent {
                do {
                    guard let event = try await subscription.events.next() else {
                        throw Errors.ACPError.serverUnavailable(Errors.ServerUnavailableError())
                    }
                    return event
                } catch is CancellationError {
                    throw CancellationError()
                } catch let err as Errors.ACPError {
                    throw err
                } catch {
                    try ClientHelpers.rethrowClassified(error)
                }
            }

            private func asksSettled(_ subscription: Subscription) async {
                let gate = AsyncGate()
                subscription.askQueue.push {
                    gate.resolve(succeeded: true)
                }
                _ = await gate.wait()
            }

            private func queueAsk<A: Sendable>(
                turn: ActiveTurn,
                id: String,
                ask: @escaping @Sendable () async throws -> A,
                fallback: A,
                respond: @escaping @Sendable (A) async throws -> Void
            ) {
                let settled = AsyncGate()
                turn.subscription.settled.withLock { $0[id] = settled }
                turn.subscription.askQueue.push {
                    if turn.cancelled.isResolved {
                        try? await respond(fallback)
                        return
                    }
                    if settled.isResolved {
                        return
                    }
                    let outcome: AskRaceOutcome<A> = await withTaskGroup(of: AskRaceOutcome<A>.self) { group in
                        group.addTask {
                            _ = await turn.cancelled.wait()
                            return .cancelled
                        }
                        group.addTask {
                            _ = await settled.wait()
                            return .settled
                        }
                        group.addTask {
                            do {
                                return .answered(try await ask())
                            } catch {
                                return .answered(fallback)
                            }
                        }
                        let first = await group.next() ?? .cancelled
                        group.cancelAll()
                        return first
                    }
                    switch outcome {
                    case .settled:
                        return
                    case .cancelled:
                        try? await respond(fallback)
                    case .answered(let value):
                        try? await respond(value)
                    }
                }
            }

            private func interpret(turn: ActiveTurn, output: Translate.Output) async throws {
                switch output {
                case .sessionUpdate(let update, let diff):
                    let enriched = await PermissionBridge.withCompletedDiffs(
                        update,
                        source: diff,
                        cwd: turn.ctx.cwd,
                        fileSystem: fileSystem
                    )
                    try await connection.sessionUpdate(
                        SessionNotification(sessionId: turn.ctx.sessionID.rawValue, update: enriched)
                    )

                case .childUpdate(let update, let diff):
                    do {
                        let finalUpdate: Child.Update
                        if case .update(let inner) = update.event {
                            let enriched = await PermissionBridge.withCompletedDiffs(
                                inner,
                                source: diff,
                                cwd: turn.ctx.cwd,
                                fileSystem: fileSystem
                            )
                            finalUpdate = Child.Update(
                                rootSessionId: update.rootSessionId,
                                childSessionId: update.childSessionId,
                                parentSessionId: update.parentSessionId,
                                depth: update.depth,
                                title: update.title,
                                event: .update(enriched)
                            )
                        } else {
                            finalUpdate = update
                        }
                        let raw = try ClientCodec.toJSONValue(finalUpdate)
                        if case .object(let dict) = raw {
                            try await connection.extNotification(method: Child.updateMethod, params: dict)
                        }
                    } catch {
                        // Best-effort child updates (matches upstream catchCause warning).
                    }

                case .permissionAsk(let event, let tool, let child):
                    let permInput = PermissionBridge.Input(
                        client: client,
                        connection: connection,
                        event: event,
                        sessionID: event.sessionID,
                        clientSessionID: turn.ctx.sessionID.rawValue,
                        cwd: turn.ctx.cwd,
                        tool: tool.map { PermissionBridge.ToolRef(id: $0.id, name: $0.name, input: $0.input) },
                        child: child?.session,
                        fileSystem: fileSystem
                    )
                    queueAsk(
                        turn: turn,
                        id: event.id,
                        ask: { try await PermissionBridge.ask(permInput) },
                        fallback: .reject,
                        respond: { decision in try await PermissionBridge.respond(permInput, decision: decision) }
                    )

                case .formAsk(let form, let child):
                    let caps = capabilities.get()
                    guard let schema = Elicitation.requestedSchema(form: form, capabilities: caps) else {
                        await Elicitation.cancelUnshown(client: client, form: form)
                        return
                    }
                    let toolCallSent = child == nil || Translate.projectChild(ctx: turn.ctx, child: child!)
                    let elicitationInput = Elicitation.Input(
                        client: client,
                        connection: connection,
                        form: form,
                        requestedSchema: schema,
                        clientSessionID: turn.ctx.sessionID.rawValue,
                        child: child?.session,
                        toolCallSent: toolCallSent
                    )
                    queueAsk(
                        turn: turn,
                        id: form.id,
                        ask: { try await Elicitation.ask(elicitationInput) },
                        fallback: .cancel,
                        respond: { outcome in await Elicitation.respond(elicitationInput, outcome: outcome) }
                    )

                case .askSettled(let id):
                    let gate = turn.subscription.settled.withLock { $0.removeValue(forKey: id) }
                    gate?.resolve(succeeded: true)
                }
            }

            private func advance(turn: ActiveTurn) async throws -> Translate.Folded {
                let event = try await takeEvent(from: turn.subscription)
                let folded = turn.state.withLock { current -> Translate.Folded in
                    let next = Translate.fold(current, event: event, ctx: turn.ctx)
                    current = next.state
                    return next
                }
                for output in folded.outputs {
                    try await interpret(turn: turn, output: output)
                }
                return folded
            }

            private func consume(turn: ActiveTurn) async throws -> Translate.Terminal {
                while true {
                    let folded = try await advance(turn: turn)
                    if let terminal = folded.terminal {
                        await asksSettled(turn.subscription)
                        return terminal
                    }
                }
            }

            private func followBackground(turn: ActiveTurn) async {
                do {
                    while !Task.isCancelled {
                        let folded = try await advance(turn: turn)
                        if folded.terminal != nil && !Translate.pending(folded.state) {
                            await asksSettled(turn.subscription)
                            return
                        }
                    }
                } catch {
                    // Background consumer exits quietly on stream closure or cancellation.
                }
            }

            private func submitSynthetic(attached: Sessions.Attached, prompt: Prompt.Prepared) async throws {
                guard !prompt.synthetic.isEmpty else { return }
                do {
                    try await client.sessionSynthetic(
                        sessionID: attached.id.rawValue,
                        text: prompt.synthetic.joined(separator: "\n\n"),
                        description: "ACP embedded context",
                        delivery: .steer,
                        resume: false
                    )
                } catch {
                    try ClientHelpers.rethrowClassified(error)
                }
            }

            private func submit(attached: Sessions.Attached, prompt: Prompt.Prepared) async throws {
                try await submitSynthetic(attached: attached, prompt: prompt)
                if prompt.start.type == .compaction {
                    do {
                        try await client.sessionCompact(
                            sessionID: attached.id.rawValue,
                            id: prompt.start.id.rawValue
                        )
                    } catch {
                        try ClientHelpers.rethrowClassified(error)
                    }
                    return
                }
                if let command = prompt.command {
                    do {
                        try await client.sessionCommand(
                            sessionID: attached.id.rawValue,
                            name: command.name,
                            text: prompt.slash?.args ?? "",
                            files: prompt.files,
                            delivery: .steer
                        )
                    } catch {
                        try ClientHelpers.rethrowClassified(error)
                    }
                    return
                }
                do {
                    try await client.sessionPrompt(
                        sessionID: attached.id.rawValue,
                        id: prompt.start.id.rawValue,
                        text: prompt.text,
                        files: prompt.files,
                        delivery: .steer,
                        resume: nil
                    )
                } catch {
                    try ClientHelpers.rethrowClassified(error)
                }
            }

            private final class EventsHandle: Sendable {
                private final class ResultBox: Sendable {
                    private let storage = Mutex<Result<Translate.Terminal, any Swift.Error>?>(nil)
                    func set(_ value: Result<Translate.Terminal, any Swift.Error>) { storage.withLock { $0 = value } }
                    func get() -> Result<Translate.Terminal, any Swift.Error>? { storage.withLock { $0 } }
                }

                let task: Task<Void, Never>
                let done = AsyncGate()
                private let resultBox = ResultBox()

                init(operation: @escaping @Sendable () async -> Result<Translate.Terminal, any Swift.Error>) {
                    let gate = done
                    let box = resultBox
                    self.task = Task<Void, Never> {
                        let res = await operation()
                        box.set(res)
                        gate.resolve(succeeded: true)
                    }
                }

                func awaitCancellable() async -> Result<Translate.Terminal, any Swift.Error>? {
                    let ok = await done.wait()
                    guard ok else { return nil }
                    return resultBox.get()
                }

                func cancel() {
                    task.cancel()
                }
            }

            private func windDown(
                turn: ActiveTurn,
                events: EventsHandle
            ) async {
                turn.cancelled.resolve(succeeded: true)
                try? await client.sessionInterrupt(sessionID: turn.ctx.sessionID.rawValue)
                let started = turn.state.withLock { $0.started }
                if !started {
                    events.cancel()
                    return
                }
                let drained: Bool = await withTaskGroup(of: Bool.self) { group in
                    group.addTask {
                        if let res = await events.awaitCancellable(), case .success = res {
                            return true
                        }
                        return false
                    }
                    group.addTask { [drainTimeoutNanoseconds] in
                        try? await Task.sleep(nanoseconds: drainTimeoutNanoseconds)
                        return false
                    }
                    let first = await group.next() ?? false
                    group.cancelAll()
                    return first
                }
                if drained { return }
                events.cancel()
                let abandoned = turn.state.withLock { current -> Translate.Folded in
                    let folded = Translate.abandon(current, ctx: turn.ctx)
                    current = folded.state
                    return folded
                }
                for output in abandoned.outputs {
                    try? await interpret(turn: turn, output: output)
                }
            }

            private enum ExecutionExit {
                case terminal(Translate.Terminal)
                case interrupted
                case failed(any Swift.Error)
            }

            private func execute(
                attached: Sessions.Attached,
                prompt: Prompt.Prepared,
                turn: ActiveTurn,
                cancelSignal: AbortSignal
            ) async throws -> ExecutionExit {
                // First event on the feed is `server.connected`.
                let connected = try await takeEvent(from: turn.subscription)
                guard connected.type == "server.connected" else {
                    throw Errors.ACPError.serviceFailure(
                        Errors.ServiceFailureError(
                            safeMessage: "expected server.connected, got \(connected.type)",
                            service: "session"
                        )
                    )
                }

                let events = EventsHandle {
                    do {
                        return .success(try await self.consume(turn: turn))
                    } catch {
                        return .failure(error)
                    }
                }

                if cancelSignal.isAborted {
                    await windDown(turn: turn, events: events)
                    return .interrupted
                }

                enum RaceResult {
                    case cancelled
                    case finished(Result<Translate.Terminal, any Swift.Error>)
                }

                let race: RaceResult = await withTaskGroup(of: RaceResult.self) { group in
                    group.addTask {
                        await awaitAborted(cancelSignal)
                        return .cancelled
                    }
                    group.addTask {
                        do {
                            try await self.submit(attached: attached, prompt: prompt)
                            if prompt.command != nil {
                                events.cancel()
                                return .finished(.success(.succeeded))
                            }
                            guard let res = await events.awaitCancellable() else {
                                return .cancelled
                            }
                            return .finished(res)
                        } catch {
                            events.cancel()
                            return .finished(.failure(error))
                        }
                    }
                    let first = await group.next() ?? .cancelled
                    group.cancelAll()
                    return first
                }

                switch race {
                case .cancelled:
                    await windDown(turn: turn, events: events)
                    return .interrupted
                case .finished(.success(let terminal)):
                    return .terminal(terminal)
                case .finished(.failure(let error)):
                    events.cancel()
                    return .failed(error)
                }
            }

            private func handoff(attached: Sessions.Attached, turn: ActiveTurn, failedNonInterrupt: Bool) {
                if failedNonInterrupt {
                    turn.subscription.close()
                    return
                }
                let current = turn.state.withLock { $0 }
                let key = ObjectIdentifier(attached)
                if !Translate.pending(current) {
                    if !current.children.isEmpty {
                        state.withLock { $0.backgrounds[key] = BackgroundHolder(state: turn.state, cancel: nil) }
                    }
                    turn.subscription.close()
                    return
                }

                let responded = Connection.Responded.current
                var nextState = current
                nextState.started = false
                let bgCtx = Translate.TurnContext(
                    sessionID: turn.ctx.sessionID,
                    cwd: turn.ctx.cwd,
                    start: nil,
                    childUpdates: turn.ctx.childUpdates,
                    compaction: turn.ctx.compaction
                )
                let bgTurn = ActiveTurn(ctx: bgCtx, state: nextState, subscription: turn.subscription)
                let bgTaskBox = Mutex<Task<Void, Never>?>(nil)
                do {
                    try sessions.fork(attached: attached) { [weak self] in
                        let inner = Task<Void, Never> {
                            defer { turn.subscription.close() }
                            _ = await responded()
                            guard let self, !Task.isCancelled else { return }
                            await self.followBackground(turn: bgTurn)
                        }
                        bgTaskBox.withLock { $0 = inner }
                        await inner.value
                    }
                    state.withLock {
                        $0.backgrounds[key] = BackgroundHolder(
                            state: bgTurn.state,
                            cancel: {
                                bgTurn.cancelled.resolve(succeeded: true)
                                bgTaskBox.withLock { $0?.cancel() }
                                turn.subscription.close()
                            }
                        )
                    }
                } catch {
                    turn.subscription.close()
                }
            }

            private func sendUsageUpdate(attached: Sessions.Attached, state: Translate.TurnState) async {
                let used = state.usage?.last.total ?? 0
                guard used > 0 else { return }
                guard let cat = try? await catalog.get(cwd: attached.cwd) else { return }
                let selected = ConfigOption.currentModel(cat, selection: attached.getSelection())
                guard let model = CatalogStore.findModel(cat.models, ref: selected), model.limit.context > 0 else {
                    return
                }
                guard let info = try? await client.sessionGet(sessionID: attached.id.rawValue) else { return }
                try? await connection.sessionUpdate(
                    SessionNotification(
                        sessionId: attached.id.rawValue,
                        update: .usageUpdate(
                            used: used,
                            size: model.limit.context,
                            cost: UsageCost(amount: info.cost, currency: "USD")
                        )
                    )
                )
            }
        }

        // parity: cli/src/acp/turn.ts#make [status=adapted hash=89f26159020a]
        public static func make(
            client: any BackendClient,
            connection: any Connection.Interface,
            sessions: any Sessions.Interface,
            catalog: any CatalogStore.Interface,
            capabilities: CapabilitiesBox,
            fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
            drainTimeoutNanoseconds: UInt64? = nil
        ) -> any Interface {
            Runner(
                client: client,
                connection: connection,
                sessions: sessions,
                catalog: catalog,
                capabilities: capabilities,
                fileSystem: fileSystem,
                drainTimeoutNanoseconds: drainTimeoutNanoseconds ?? CancelDrainTimeout.nanoseconds
            )
        }
    }

    // MARK: - 20. Service Facade (`packages/cli/src/acp/service.ts`)

    public enum Service {
        public static let authMethodID = "opencode-login"

        // parity: cli/src/acp/service.ts#Interface [status=implemented hash=e0b88f10f15d]
        public protocol Interface: Sendable {
            func initialize(_ input: InitializeRequest) async -> InitializeResponse
            func authenticate(_ input: AuthenticateRequest) async throws -> AuthenticateResponse
            func newSession(_ input: NewSessionRequest) async throws -> NewSessionResponse
            func loadSession(_ input: LoadSessionRequest) async throws -> LoadSessionResponse
            func listSessions(_ input: ListSessionsRequest) async throws -> ListSessionsResponse
            func deleteSession(_ input: DeleteSessionRequest) async throws -> DeleteSessionResponse
            func resumeSession(_ input: ResumeSessionRequest) async throws -> ResumeSessionResponse
            func closeSession(_ input: CloseSessionRequest) async throws -> CloseSessionResponse
            func forkSession(_ input: ForkSessionRequest) async throws -> ForkSessionResponse
            func setSessionConfigOption(_ input: SetSessionConfigOptionRequest) async throws -> SetSessionConfigOptionResponse
            func setSessionMode(_ input: SetSessionModeRequest) async throws -> SetSessionModeResponse
            func prompt(_ input: PromptRequest, signal: AbortSignal) async throws -> PromptResponse
            func steer(_ input: Turn.SteeringRequest) async throws -> Turn.SteeringResponse
            func cancel(_ input: CancelNotification) async
        }

        private final class Impl: Interface, Sendable {
            let client: any BackendClient
            let connection: any Connection.Interface
            let catalog: any CatalogStore.Interface
            let sessions: any Sessions.Interface
            let capabilities: CapabilitiesBox
            let turn: any Turn.Interface
            let fileSystem: any OpenCodeFileSystem
            let version: String
            let unprompted = Mutex<Set<String>>([])

            init(
                client: any BackendClient,
                connection: any Connection.Interface,
                catalog: any CatalogStore.Interface,
                sessions: any Sessions.Interface,
                capabilities: CapabilitiesBox,
                turn: any Turn.Interface,
                fileSystem: any OpenCodeFileSystem,
                version: String
            ) {
                self.client = client
                self.connection = connection
                self.catalog = catalog
                self.sessions = sessions
                self.capabilities = capabilities
                self.turn = turn
                self.fileSystem = fileSystem
                self.version = version
            }

            func initialize(_ params: InitializeRequest) async -> InitializeResponse {
                capabilities.set(Capabilities.parse(params.clientCapabilities))
                let isTerminal = params.clientCapabilities?.auth?.terminal == true
                var authMethod = AuthMethod(
                    id: Service.authMethodID,
                    name: "Login with opencode",
                    description: "Run `opencode auth login` in the terminal",
                    type: isTerminal ? "terminal" : nil,
                    args: isTerminal ? ["--login"] : nil
                )
                if params.clientCapabilities?._meta?["terminal-auth"] == .bool(true) {
                    authMethod._meta = [
                        "terminal-auth": .object([
                            "command": .string("opencode"),
                            "args": .array([.string("auth"), .string("login")]),
                            "label": .string("OpenCode Login"),
                        ]),
                    ]
                }
                return InitializeResponse(
                    protocolVersion: 1,
                    agentCapabilities: AgentCapabilities(
                        loadSession: true,
                        mcpCapabilities: McpCapabilities(http: true, sse: false),
                        promptCapabilities: PromptCapabilities(embeddedContext: true, image: true),
                        sessionCapabilities: AgentSessionCapabilities(),
                        _meta: [Capabilities.childSessionUpdatesKey: .bool(true)]
                    ),
                    authMethods: [authMethod],
                    _meta: ["steering": .object(["supported": .bool(true)])],
                    agentInfo: AgentInfo(name: "OpenCode", version: version)
                )
            }

            func authenticate(_ params: AuthenticateRequest) async throws -> AuthenticateResponse {
                guard params.methodId == Service.authMethodID else {
                    throw Errors.ACPError.unknownAuthMethod(Errors.UnknownAuthMethodError(methodId: params.methodId))
                }
                return EmptyObject()
            }

            func newSession(_ params: NewSessionRequest) async throws -> NewSessionResponse {
                let directories = try Directories.parse(cwd: params.cwd, directories: params.additionalDirectories ?? [])
                let mcpServers = try supportedMcpServers(params.mcpServers ?? [])
                // Load catalog first so a catalog failure leaves no empty session on the server.
                _ = try await catalog.get(cwd: params.cwd)
                let grant = Directories.grant(directories)
                let created: SessionSchema.Info
                do {
                    created = try await client.sessionCreate(
                        location: LocationSchema.PublicRef(directory: SchemaPrimitive.AbsolutePath(rawValue: params.cwd)),
                        permissions: grant.permissions,
                        metadata: grant.metadata
                    )
                } catch {
                    try ClientHelpers.rethrowClassified(error)
                }
                let attachment = try await sessions.attach(session: created, cwd: params.cwd, mcpServers: mcpServers)
                unprompted.withLock { _ = $0.insert(attachment.attached.id.rawValue) }
                return NewSessionResponse(
                    sessionId: attachment.attached.id.rawValue,
                    configOptions: attachment.configOptions
                )
            }

            func loadSession(_ params: LoadSessionRequest) async throws -> LoadSessionResponse {
                let directories = try Directories.parse(cwd: params.cwd, directories: params.additionalDirectories ?? [])
                let mcpServers = try supportedMcpServers(params.mcpServers ?? [])
                let session = try await getSession(sessionId: params.sessionId, cwd: params.cwd)
                try await Directories.activate(client: client, session: session, directories: directories)
                let attachment = try await sessions.attach(
                    session: session,
                    cwd: session.location.directory,
                    mcpServers: mcpServers
                )
                do {
                    try await Replay.history(
                        client: client,
                        connection: connection,
                        attached: attachment.attached,
                        capabilities: capabilities.get(),
                        fileSystem: fileSystem
                    )
                    let options = try await currentOptions(attached: attachment.attached)
                    return LoadSessionResponse(configOptions: options)
                } catch {
                    await sessions.release(attached: attachment.attached)
                    throw error
                }
            }

            func listSessions(_ params: ListSessionsRequest) async throws -> ListSessionsResponse {
                let directory: String? = try params.cwd.map { try Directories.parseCwd($0).rawValue }
                let page: SessionsResponse
                do {
                    page = try await client.sessionList(
                        directory: directory,
                        order: .desc,
                        limit: 100,
                        cursor: params.cursor
                    )
                } catch {
                    try ClientHelpers.rethrowClassified(error)
                }
                let entries = page.data.map { session -> SessionListEntry in
                    let additional = Directories.list(session)
                    let title = SessionTitleFallback.withTimestampedFallback(
                        SessionTitleFallback.Info(
                            title: session.title,
                            parentID: session.parentID?.rawValue,
                            time: SessionTitleFallback.Time(created: session.time.created)
                        )
                    )
                    return SessionListEntry(
                        sessionId: session.id.rawValue,
                        cwd: session.location.directory,
                        additionalDirectories: additional.isEmpty ? nil : additional,
                        title: title,
                        updatedAt: Translate.formatISO8601UTC(epochMillis: session.time.updated)
                    )
                }
                return ListSessionsResponse(sessions: entries, nextCursor: page.cursor.next?.rawValue)
            }

            func deleteSession(_ params: DeleteSessionRequest) async throws -> DeleteSessionResponse {
                unprompted.withLock { _ = $0.remove(params.sessionId) }
                await turn.cancel(CancelNotification(sessionId: params.sessionId))
                if let sessionID = try? ClientHelpers.decodeSessionID(params.sessionId) {
                    do {
                        try await client.sessionRemove(sessionID: sessionID.rawValue)
                    } catch is OpenCodeProtocol.SessionNotFoundError {
                        // already deleted
                    } catch ProtocolErrorEnvelope.sessionNotFound {
                        // already deleted
                    } catch {
                        try ClientHelpers.rethrowClassified(error)
                    }
                }
                await sessions.detach(sessionID: params.sessionId)
                return EmptyObject()
            }

            func resumeSession(_ params: ResumeSessionRequest) async throws -> ResumeSessionResponse {
                let directories = try Directories.parse(cwd: params.cwd, directories: params.additionalDirectories ?? [])
                let mcpServers = try supportedMcpServers(params.mcpServers ?? [])
                let session = try await getSession(sessionId: params.sessionId, cwd: params.cwd)
                try await Directories.activate(client: client, session: session, directories: directories)
                let attachment = try await sessions.attach(
                    session: session,
                    cwd: session.location.directory,
                    mcpServers: mcpServers
                )
                return ResumeSessionResponse(configOptions: attachment.configOptions)
            }

            func closeSession(_ params: CloseSessionRequest) async throws -> CloseSessionResponse {
                try await turn.close(sessionID: params.sessionId)
                await sessions.detach(sessionID: params.sessionId)
                await discardUnprompted(sessionId: params.sessionId)
                return EmptyObject()
            }

            func forkSession(_ params: ForkSessionRequest) async throws -> ForkSessionResponse {
                let directories = try Directories.parse(cwd: params.cwd, directories: params.additionalDirectories ?? [])
                let mcpServers = try supportedMcpServers(params.mcpServers ?? [])
                let session = try await getSession(sessionId: params.sessionId, cwd: params.cwd)
                let forked: SessionSchema.Info
                do {
                    forked = try await client.sessionFork(sessionID: session.id.rawValue)
                } catch {
                    try ClientHelpers.rethrowClassified(error)
                }
                try await Directories.activate(client: client, session: forked, directories: directories)
                let attachment = try await sessions.attach(
                    session: forked,
                    cwd: forked.location.directory,
                    mcpServers: mcpServers
                )
                return ForkSessionResponse(
                    sessionId: attachment.attached.id.rawValue,
                    configOptions: attachment.configOptions
                )
            }

            func setSessionConfigOption(_ params: SetSessionConfigOptionRequest) async throws -> SetSessionConfigOptionResponse {
                let attached = try sessions.require(sessionID: params.sessionId)
                guard case .string(let value) = params.value else {
                    throw Errors.ACPError.invalidConfigOption(
                        Errors.InvalidConfigOptionError(configId: params.configId)
                    )
                }
                try await withReload(attached: attached) {
                    try await self.select(attached: attached, configId: params.configId, value: value)
                }
                return SetSessionConfigOptionResponse(configOptions: try await currentOptions(attached: attached))
            }

            func setSessionMode(_ params: SetSessionModeRequest) async throws -> SetSessionModeResponse {
                let attached = try sessions.require(sessionID: params.sessionId)
                try await withReload(attached: attached) {
                    try await self.select(attached: attached, configId: "mode", value: params.modeId)
                }
                return EmptyObject()
            }

            func prompt(_ params: PromptRequest, signal: AbortSignal) async throws -> PromptResponse {
                unprompted.withLock { _ = $0.remove(params.sessionId) }
                return try await turn.prompt(params, signal: signal)
            }

            func steer(_ params: Turn.SteeringRequest) async throws -> Turn.SteeringResponse {
                try await turn.steer(params)
            }

            func cancel(_ params: CancelNotification) async {
                await turn.cancel(params)
            }

            private func currentOptions(attached: Sessions.Attached) async throws -> [SessionConfigOption] {
                let cat = try await catalog.get(cwd: attached.cwd)
                return ConfigOption.configOptions(cat, selection: attached.getSelection())
            }

            private func withReload<A>(attached: Sessions.Attached, attempt: () async throws -> A) async throws -> A {
                do {
                    return try await attempt()
                } catch let error as Errors.ACPError {
                    switch error {
                    case .invalidModel, .invalidMode, .invalidEffort:
                        try await catalog.reload(cwd: attached.cwd)
                        return try await attempt()
                    default:
                        throw error
                    }
                }
            }

            private func select(attached: Sessions.Attached, configId: String, value: String) async throws {
                let cat = try await catalog.get(cwd: attached.cwd)
                let change = try ConfigOption.resolveChange(
                    cat,
                    selection: attached.getSelection(),
                    configId: configId,
                    value: value
                )
                try await sessions.select(attached: attached, change: change)
            }

            private func getSession(sessionId: String, cwd: String) async throws -> SessionSchema.Info {
                let id = try ClientHelpers.decodeSessionID(sessionId)
                let session: SessionSchema.Info
                do {
                    session = try await client.sessionGet(sessionID: id.rawValue)
                } catch {
                    try ClientHelpers.rethrowClassified(error)
                }
                if FSUtil.resolve(cwd) != FSUtil.resolve(session.location.directory) {
                    throw Errors.ACPError.sessionDirectoryMismatch(
                        Errors.SessionDirectoryMismatchError(sessionId: sessionId, cwd: cwd)
                    )
                }
                return session
            }

            private func discardUnprompted(sessionId: String) async {
                let removed = unprompted.withLock { $0.remove(sessionId) != nil }
                guard removed else { return }
                guard let id = try? ClientHelpers.decodeSessionID(sessionId) else { return }
                do {
                    let messages = try await client.messageList(
                        sessionID: id.rawValue,
                        limit: 1,
                        order: nil,
                        cursor: nil
                    )
                    if messages.data.isEmpty {
                        try await client.sessionRemove(sessionID: id.rawValue)
                    }
                } catch {
                    // Best-effort cleanup of unused sessions.
                }
            }

            private func supportedMcpServers(_ servers: [McpServer]) throws(Errors.ACPError) -> [Sessions.SupportedMcpServer] {
                var out: [Sessions.SupportedMcpServer] = []
                out.reserveCapacity(servers.count)
                for server in servers {
                    switch server {
                    case .stdio(let s): out.append(.stdio(s))
                    case .http(let h): out.append(.http(h))
                    case .sse, .acp:
                        throw .invalidRequest(
                            Errors.InvalidRequestError(
                                message: "Only stdio and HTTP MCP servers are supported",
                                field: "mcpServers"
                            )
                        )
                    }
                }
                return out
            }
        }

        // parity: cli/src/acp/service.ts#make [status=adapted hash=2f91943c5caf]
        public static func make(
            client: any BackendClient,
            connection: any Connection.Interface,
            catalog: any CatalogStore.Interface,
            sessions: any Sessions.Interface,
            capabilities: CapabilitiesBox,
            turn: any Turn.Interface,
            fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
            version: String = "local"
        ) -> any Interface {
            Impl(
                client: client,
                connection: connection,
                catalog: catalog,
                sessions: sessions,
                capabilities: capabilities,
                turn: turn,
                fileSystem: fileSystem,
                version: version
            )
        }
    }

    // MARK: - 21. Agent Entrypoint (`packages/cli/src/acp/agent.ts`)

    public enum Agent {
        public final class ConnectedAgent: Sendable {
            public let runtime: ConnectedRuntime
            public let service: any Service.Interface
            public let connection: any Connection.Interface
            private let onClose: @Sendable () async -> Void

            public init(
                runtime: ConnectedRuntime,
                service: any Service.Interface,
                connection: any Connection.Interface,
                onClose: @escaping @Sendable () async -> Void
            ) {
                self.runtime = runtime
                self.service = service
                self.connection = connection
                self.onClose = onClose
            }

            public func waitUntilClosed() async {
                await runtime.waitUntilClosed()
            }

            public func close() async {
                await onClose()
                await runtime.close()
            }
        }

        /// Connects an ACP JSON-RPC agent to an `NDJSONStream` using any `BackendClient`.
        // parity: cli/src/acp/agent.ts#connect [status=adapted hash=df3d8ef5ff88]
        public static func connect(
            client: any BackendClient,
            stream: NDJSONStream,
            fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
            version: String = "local",
            pollIntervalNanoseconds: UInt64 = 25_000_000,
            pollTimeoutNanoseconds: UInt64 = 5_000_000_000,
            drainTimeoutNanoseconds: UInt64? = nil
        ) -> ConnectedAgent {
            let catalog = CatalogStore.make(
                client: client,
                pollIntervalNanoseconds: pollIntervalNanoseconds,
                pollTimeoutNanoseconds: pollTimeoutNanoseconds
            )

            struct ReadyBundle: Sendable {
                let service: any Service.Interface
                let connection: any Connection.Interface
            }

            let readyGate = AsyncGate()
            let readyBox = Mutex<ReadyBundle?>(nil)

            let awaitReady: @Sendable () async -> ReadyBundle? = {
                _ = await readyGate.wait()
                return readyBox.withLock { $0 }
            }

            let mapFailure: @Sendable (any Swift.Error) -> RequestError = { error in
                if let req = error as? RequestError {
                    return req
                }
                if let acpErr = error as? Errors.ACPError {
                    return Errors.toRequestError(acpErr)
                }
                if let failure = error as? Errors.Failure {
                    switch failure {
                    case .error(let e): return Errors.toRequestError(e)
                    case .request(let r): return r
                    case .catalog(let c):
                        switch c {
                        case .load(let load):
                            if let classified = ClientHelpers.classify(load.cause) {
                                return Errors.toRequestError(classified)
                            }
                            return Errors.toRequestError(.serviceFailure(Errors.fromUnknown(load.cause)))
                        case .notReady(let nr):
                            return Errors.toRequestError(
                                .serviceFailure(
                                    Errors.ServiceFailureError(safeMessage: nr.message, errorName: "CatalogNotReady")
                                )
                            )
                        }
                    }
                }
                if let catErr = error as? Errors.CatalogError {
                    switch catErr {
                    case .load(let load):
                        if let classified = ClientHelpers.classify(load.cause) {
                            return Errors.toRequestError(classified)
                        }
                        return Errors.toRequestError(.serviceFailure(Errors.fromUnknown(load.cause)))
                    case .notReady(let nr):
                        return Errors.toRequestError(
                            .serviceFailure(
                                Errors.ServiceFailureError(safeMessage: nr.message, errorName: "CatalogNotReady")
                            )
                        )
                    }
                }
                if let loadErr = error as? Errors.CatalogLoadError {
                    if let classified = ClientHelpers.classify(loadErr.cause) {
                        return Errors.toRequestError(classified)
                    }
                    return Errors.toRequestError(.serviceFailure(Errors.fromUnknown(loadErr.cause)))
                }
                if let nr = error as? Errors.CatalogNotReadyError {
                    return Errors.toRequestError(
                        .serviceFailure(
                            Errors.ServiceFailureError(safeMessage: nr.message, errorName: "CatalogNotReady")
                        )
                    )
                }
                return Errors.toRequestError(.serviceFailure(Errors.fromUnknown(error)))
            }

            func registerRequest<Params: Decodable & Sendable, ResultType: Encodable & Sendable>(
                on app: AgentApp,
                method: String,
                paramsType: Params.Type = Params.self,
                call: @escaping @Sendable (any Service.Interface, Params, AbortSignal) async throws -> ResultType
            ) {
                app.onRequest(method) { ctx in
                    guard let bundle = await awaitReady() else {
                        throw RequestError.internalError(detail: "ACP agent not ready")
                    }
                    let decoded: Params
                    do {
                        let raw = ctx.params ?? .object([:])
                        decoded = try ClientCodec.fromJSONValue(paramsType, value: raw)
                    } catch {
                        throw RequestError.invalidParams(
                            data: ["details": .string(String(describing: error))],
                            detail: "Invalid parameters for \(method)"
                        )
                    }
                    let runCall: @Sendable () async throws -> JSONValue = {
                        do {
                            let result = try await call(bundle.service, decoded, ctx.signal)
                            return try ClientCodec.toJSONValue(result)
                        } catch {
                            throw mapFailure(error)
                        }
                    }
                    if let requestId = ctx.requestId {
                        let responded = bundle.connection.responded(requestId: requestId)
                        return try await Connection.Responded.$current.withValue(responded) {
                            try await runCall()
                        }
                    }
                    return try await runCall()
                }
            }

            let app = AgentApp(name: "opencode")

            registerRequest(on: app, method: Methods.initialize, paramsType: InitializeRequest.self) { service, params, _ in
                await service.initialize(params)
            }
            registerRequest(on: app, method: Methods.authenticate, paramsType: AuthenticateRequest.self) { service, params, _ in
                try await service.authenticate(params)
            }
            registerRequest(on: app, method: Methods.sessionNew, paramsType: NewSessionRequest.self) { service, params, _ in
                try await service.newSession(params)
            }
            registerRequest(on: app, method: Methods.sessionLoad, paramsType: LoadSessionRequest.self) { service, params, _ in
                try await service.loadSession(params)
            }
            registerRequest(on: app, method: Methods.sessionList, paramsType: ListSessionsRequest.self) { service, params, _ in
                try await service.listSessions(params)
            }
            registerRequest(on: app, method: Methods.sessionDelete, paramsType: DeleteSessionRequest.self) { service, params, _ in
                try await service.deleteSession(params)
            }
            registerRequest(on: app, method: Methods.sessionResume, paramsType: ResumeSessionRequest.self) { service, params, _ in
                try await service.resumeSession(params)
            }
            registerRequest(on: app, method: Methods.sessionClose, paramsType: CloseSessionRequest.self) { service, params, _ in
                try await service.closeSession(params)
            }
            registerRequest(on: app, method: Methods.sessionFork, paramsType: ForkSessionRequest.self) { service, params, _ in
                try await service.forkSession(params)
            }
            registerRequest(on: app, method: Methods.sessionSetConfigOption, paramsType: SetSessionConfigOptionRequest.self) { service, params, _ in
                try await service.setSessionConfigOption(params)
            }
            registerRequest(on: app, method: Methods.sessionSetMode, paramsType: SetSessionModeRequest.self) { service, params, _ in
                try await service.setSessionMode(params)
            }
            registerRequest(on: app, method: Methods.sessionPrompt, paramsType: PromptRequest.self) { service, params, signal in
                try await service.prompt(params, signal: signal)
            }
            // Interim extension until ACP has native mid-turn steering.
            registerRequest(on: app, method: Methods.sessionSteering, paramsType: Turn.SteeringRequest.self) { service, params, _ in
                try await service.steer(params)
            }
            app.onNotification(Methods.sessionCancel) { ctx in
                guard let bundle = await awaitReady() else { return }
                let raw = ctx.params ?? .object([:])
                guard let decoded = try? ClientCodec.fromJSONValue(CancelNotification.self, value: raw) else { return }
                await bundle.service.cancel(decoded)
            }

            let acp = Connection.make(app: app, stream: stream)
            let sessions = Sessions.make(client: client, connection: acp.connection, catalog: catalog)
            let capabilities = CapabilitiesBox(Capabilities.parse(nil))
            let turn = Turn.make(
                client: client,
                connection: acp.connection,
                sessions: sessions,
                catalog: catalog,
                capabilities: capabilities,
                fileSystem: fileSystem,
                drainTimeoutNanoseconds: drainTimeoutNanoseconds
            )
            let service = Service.make(
                client: client,
                connection: acp.connection,
                catalog: catalog,
                sessions: sessions,
                capabilities: capabilities,
                turn: turn,
                fileSystem: fileSystem,
                version: version
            )
            readyBox.withLock { $0 = ReadyBundle(service: service, connection: acp.connection) }
            readyGate.resolve(succeeded: true)

            return ConnectedAgent(
                runtime: acp.agent,
                service: service,
                connection: acp.connection,
                onClose: {
                    await sessions.shutdown()
                    if let shutdownable = catalog as? CatalogStore.LiveCatalogStore {
                        await shutdownable.shutdown()
                    }
                }
            )
        }

        /// Convenience overload connecting an ACP agent directly to an `EffectClient.OpenCodeClient`.
        public static func connect(
            client: EffectClient.OpenCodeClient,
            stream: NDJSONStream,
            fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
            version: String = "local"
        ) -> ConnectedAgent {
            connect(
                client: EffectBackendClient(client: client),
                stream: stream,
                fileSystem: fileSystem,
                version: version
            )
        }
    }
}

// MARK: - CatalogStore.make (`packages/cli/src/acp/catalog.ts`)

extension CLIACP.CatalogStore {
    internal final class LiveCatalogStore: Interface, Sendable {
        private static let reloadOn: Set<String> = ["model.updated", "agent.updated", "command.updated"]

        private final class Entry: Sendable {
            private struct State: Sendable {
                var catalog: Catalog
                var requestedGeneration: Int = 0
                var loadedGeneration: Int = 0
                var reloading = false
                var nextSubscriberID: UInt64 = 1
                var subscribers: [UInt64: AsyncThrowingStream<Catalog, any Swift.Error>.Continuation] = [:]
            }

            let cwd: String
            private let state: Mutex<State>
            let reloadWaiters = Mutex<[CheckedContinuation<Void, Never>]>([])

            init(cwd: String, initial: Catalog) {
                self.cwd = cwd
                self.state = Mutex(State(catalog: initial))
            }

            func get() -> Catalog {
                state.withLock { $0.catalog }
            }

            func set(_ next: Catalog) {
                let subs = state.withLock { s -> [AsyncThrowingStream<Catalog, any Swift.Error>.Continuation] in
                    s.catalog = next
                    return Array(s.subscribers.values)
                }
                for sub in subs {
                    sub.yield(next)
                }
            }

            func subscribe() -> AsyncThrowingStream<Catalog, any Swift.Error> {
                AsyncThrowingStream { continuation in
                    let (current, id) = state.withLock { s -> (Catalog, UInt64) in
                        let id = s.nextSubscriberID
                        s.nextSubscriberID += 1
                        s.subscribers[id] = continuation
                        return (s.catalog, id)
                    }
                    continuation.yield(current)
                    continuation.onTermination = { [weak self] _ in
                        self?.state.withLock { _ = $0.subscribers.removeValue(forKey: id) }
                    }
                }
            }

            func close() {
                let subs = state.withLock { s -> [AsyncThrowingStream<Catalog, any Swift.Error>.Continuation] in
                    let values = Array(s.subscribers.values)
                    s.subscribers.removeAll()
                    return values
                }
                for sub in subs {
                    sub.finish()
                }
            }

            func reload(using loader: @Sendable (String) async throws -> Catalog) async {
                let target = state.withLock { s -> Int in
                    s.requestedGeneration += 1
                    return s.requestedGeneration
                }
                while true {
                    let action: (shouldRun: Bool, done: Bool, generation: Int) = state.withLock { s in
                        if s.loadedGeneration >= target { return (false, true, s.loadedGeneration) }
                        if s.reloading { return (false, false, s.requestedGeneration) }
                        s.reloading = true
                        return (true, false, s.requestedGeneration)
                    }
                    if action.done { return }
                    if !action.shouldRun {
                        await withCheckedContinuation { continuation in
                            let alreadyIdle = state.withLock { !$0.reloading }
                            if alreadyIdle {
                                continuation.resume()
                            } else {
                                reloadWaiters.withLock { $0.append(continuation) }
                            }
                        }
                        continue
                    }
                    if let next = try? await loader(cwd) {
                        set(next)
                    }
                    state.withLock { s in
                        s.loadedGeneration = action.generation
                        s.reloading = false
                    }
                    let waiters = reloadWaiters.withLock { list -> [CheckedContinuation<Void, Never>] in
                        let copy = list
                        list.removeAll()
                        return copy
                    }
                    for waiter in waiters {
                        waiter.resume()
                    }
                    return
                }
            }
        }

        private enum CachedSlot: Sendable {
            case loading(Task<Result<Entry, any Swift.Error>, Never>)
            case loaded(Entry)
        }

        private let client: any CLIACP.BackendClient
        private let pollIntervalNanoseconds: UInt64
        private let pollTimeoutNanoseconds: UInt64
        private let entries = Mutex<[String: CachedSlot]>([:])
        private let connected = CLIACP.AsyncGate()
        private let eventTask = Mutex<Task<Void, Never>?>(nil)

        init(
            client: any CLIACP.BackendClient,
            pollIntervalNanoseconds: UInt64,
            pollTimeoutNanoseconds: UInt64
        ) {
            self.client = client
            self.pollIntervalNanoseconds = pollIntervalNanoseconds
            self.pollTimeoutNanoseconds = pollTimeoutNanoseconds
            let task = Task<Void, Never> { [weak self] in
                await self?.listenEvents()
            }
            self.eventTask.withLock { $0 = task }
        }

        func shutdown() async {
            eventTask.withLock { t in
                t?.cancel()
                t = nil
            }
            let slots = entries.withLock { map -> [CachedSlot] in
                let values = Array(map.values)
                map.removeAll()
                return values
            }
            for slot in slots {
                switch slot {
                case .loading(let t): t.cancel()
                case .loaded(let e): e.close()
                }
            }
        }

        func get(cwd: String) async throws -> Catalog {
            try await entry(for: cwd).get()
        }

        func reload(cwd: String) async throws {
            let loaded = try await entry(for: cwd)
            await loaded.reload { dir in
                try await self.load(cwd: dir)
            }
        }

        func changes(cwd: String) -> AsyncThrowingStream<Catalog, any Swift.Error> {
            AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        let loaded = try await self.entry(for: cwd)
                        for try await item in loaded.subscribe() {
                            if Task.isCancelled { break }
                            continuation.yield(item)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }

        private func listenEvents() async {
            defer { connected.resolve(succeeded: true) }
            do {
                for try await event in client.eventSubscribe() {
                    if Task.isCancelled { break }
                    if event.type == "server.connected" {
                        connected.resolve(succeeded: true)
                        continue
                    }
                    guard Self.reloadOn.contains(event.type) else { continue }
                    let targets: [CachedSlot]
                    if let dir = event.location?.directory {
                        let key = FSUtil.resolve(dir)
                        targets = entries.withLock { map in
                            map[key].map { [$0] } ?? []
                        }
                    } else {
                        targets = entries.withLock { Array($0.values) }
                    }
                    for slot in targets {
                        Task { [weak self] in
                            guard let self else { return }
                            let resolved: Entry?
                            switch slot {
                            case .loaded(let e): resolved = e
                            case .loading(let t): resolved = try? await t.value.get()
                            }
                            if let resolved {
                                await resolved.reload { dir in
                                    try await self.load(cwd: dir)
                                }
                            }
                        }
                    }
                }
            } catch {
                // Catalog event stream failed
            }
        }

        private func entry(for cwd: String) async throws -> Entry {
            let key = FSUtil.resolve(cwd)
            let slot: CachedSlot = entries.withLock { map in
                if let existing = map[key] { return existing }
                let task = Task<Result<Entry, any Swift.Error>, Never> { [weak self] in
                    guard let self else {
                        return .failure(CLIACP.Errors.CatalogError.notReady(.init(reason: .models)))
                    }
                    _ = await self.connected.wait()
                    do {
                        let loaded = try await self.load(cwd: cwd)
                        let entry = Entry(cwd: cwd, initial: loaded)
                        self.entries.withLock { $0[key] = .loaded(entry) }
                        return .success(entry)
                    } catch {
                        self.entries.withLock { _ = $0.removeValue(forKey: key) }
                        return .failure(error)
                    }
                }
                map[key] = .loading(task)
                return .loading(task)
            }
            switch slot {
            case .loaded(let e):
                return e
            case .loading(let t):
                return try await t.value.get()
            }
        }

        private func load(cwd: String) async throws -> Catalog {
            let deadline = ContinuousClock.now + .nanoseconds(Int64(pollTimeoutNanoseconds))
            // Poll plugins until at least one is listed (or timeout).
            while true {
                if let plugins = try? await client.pluginList(directory: cwd), !plugins.isEmpty {
                    break
                }
                if ContinuousClock.now >= deadline || Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
            }
            while true {
                do {
                    return try await read(cwd: cwd)
                } catch CLIACP.Errors.CatalogError.notReady(let notReady) {
                    if ContinuousClock.now >= deadline || Task.isCancelled {
                        throw CLIACP.Errors.CatalogError.notReady(notReady)
                    }
                    try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
                }
            }
        }

        private func read(cwd: String) async throws -> Catalog {
            let modelsRaw: [ModelSchema.Info]
            let defaultRef: ModelSchema.Ref?
            let agentsRaw: [AgentSchema.Info]
            let commandsRaw: [CommandSchema.Info]
            do {
                async let m = client.modelList(directory: cwd)
                async let d = client.modelDefault(directory: cwd)
                async let a = client.agentList(directory: cwd)
                async let c = client.commandList(directory: cwd)
                (modelsRaw, defaultRef, agentsRaw, commandsRaw) = try await (m, d, a, c)
            } catch {
                throw CLIACP.Errors.CatalogError.load(CLIACP.Errors.CatalogLoadError(cause: error))
            }

            let models = modelsRaw.filter(\.enabled)
            let defaultModelInfo: ModelSchema.Info? = {
                if let preferred = defaultRef {
                    return CLIACP.CatalogStore.findModel(models, ref: preferred)
                }
                return models.first
            }()
            guard let defaultModelInfo else {
                throw CLIACP.Errors.CatalogError.notReady(CLIACP.Errors.CatalogNotReadyError(reason: .models))
            }
            let agents = agentsRaw.filter { $0.mode != .subagent && !$0.hidden }
            guard let defaultAgent = agents.first else {
                throw CLIACP.Errors.CatalogError.notReady(CLIACP.Errors.CatalogNotReadyError(reason: .agents))
            }
            let defaultVariant = defaultModelInfo.variants.first(where: { $0.id.rawValue == "default" })?.id
            return Catalog(
                models: models,
                defaultModel: ModelSchema.Ref(
                    id: defaultModelInfo.id,
                    providerID: defaultModelInfo.providerID,
                    variant: defaultVariant
                ),
                modes: agents.map { Mode(id: $0.id, name: $0.name.rawValue, description: $0.description) },
                defaultModeID: defaultAgent.id,
                commands: commandsRaw.filter { CLIACP.CatalogStore.builtinCommands[$0.name] == nil }
            )
        }
    }

    // parity: cli/src/acp/catalog.ts#make [status=adapted hash=464ed6d8341c]
    public static func make(
        client: any CLIACP.BackendClient,
        pollIntervalNanoseconds: UInt64 = 25_000_000,
        pollTimeoutNanoseconds: UInt64 = 5_000_000_000
    ) -> any Interface {
        LiveCatalogStore(
            client: client,
            pollIntervalNanoseconds: pollIntervalNanoseconds,
            pollTimeoutNanoseconds: pollTimeoutNanoseconds
        )
    }
}

// MARK: - Elicitation Operations (`packages/cli/src/acp/elicitation.ts`)

extension CLIACP.Elicitation {
    private static let questionKind = "question"
    private static let elicitedKinds: Set<String> = ["question", "websearch.provider"]

    public struct Input: Sendable {
        public let client: any CLIACP.BackendClient
        public let connection: any CLIACP.Connection.Interface
        public let form: AskedForm
        public let requestedSchema: CLIACP.ElicitationSchema
        public let clientSessionID: String
        public let child: CLIACP.Child.Session?
        public let toolCallSent: Bool

        public init(
            client: any CLIACP.BackendClient,
            connection: any CLIACP.Connection.Interface,
            form: AskedForm,
            requestedSchema: CLIACP.ElicitationSchema,
            clientSessionID: String,
            child: CLIACP.Child.Session? = nil,
            toolCallSent: Bool = false
        ) {
            self.client = client
            self.connection = connection
            self.form = form
            self.requestedSchema = requestedSchema
            self.clientSessionID = clientSessionID
            self.child = child
            self.toolCallSent = toolCallSent
        }
    }

    // parity: cli/src/acp/elicitation.ts#requestedSchema [status=implemented hash=bb8c6cc1bd18]
    public static func requestedSchema(
        form: AskedForm,
        capabilities: CLIACP.Capabilities.Parsed
    ) -> CLIACP.ElicitationSchema? {
        guard capabilities.formElicitation else { return nil }
        guard let kind = CLIACP.ToolMapper.stringValue(form.metadata?["kind"]),
              elicitedKinds.contains(kind)
        else {
            return nil
        }
        if form.fields.contains(where: credentialLike) { return nil }
        for field in form.fields {
            if case .external = field { return nil }
            if hasNonEmptyWhen(field) { return nil }
            if isHiddenRequiredWithoutDefault(field) { return nil }
        }
        let keys = Set(form.fields.map(fieldKey))
        let visible = form.fields.filter { !isHidden($0) }
        guard visible.allSatisfy({ representable($0, keys: keys) }) else { return nil }

        var properties: [String: CLIACP.ElicitationPropertySchema] = [:]
        var required: [String] = []
        for field in visible {
            for (k, prop) in fieldProperties(field) {
                properties[k] = prop
            }
            if isRequired(field) {
                required.append(fieldKey(field))
            }
        }
        return CLIACP.ElicitationSchema(type: "object", properties: properties, required: required)
    }

    // parity: cli/src/acp/elicitation.ts#cancelUnshown [status=implemented hash=c773c122674d]
    public static func cancelUnshown(client: any CLIACP.BackendClient, form: AskedForm) async {
        let isQuestion = CLIACP.ToolMapper.stringValue(form.metadata?["kind"]) == questionKind
        await cancel(client: client, form: form, message: isQuestion ? unshownQuestionMessage : nil)
    }

    // parity: cli/src/acp/elicitation.ts#ask [status=implemented hash=6e707d645375]
    public static func ask(_ input: Input) async throws -> Outcome {
        let toolCallID: String? = {
            guard input.toolCallSent,
                  case .object(let toolObj) = input.form.metadata?["tool"],
                  let id = CLIACP.ToolMapper.stringValue(toolObj["id"])
            else {
                return nil
            }
            return CLIACP.Child.toolCallID(input.child, id: id)
        }()
        let response = try await input.connection.createElicitation(
            CLIACP.CreateElicitationRequest(
                mode: "form",
                sessionId: input.clientSessionID,
                toolCallId: toolCallID,
                message: CLIACP.Child.prefixTitle(input.child, value: input.form.title),
                requestedSchema: input.requestedSchema
            )
        )
        return parseAnswer(form: input.form, response: response) ?? .cancel
    }

    // parity: cli/src/acp/elicitation.ts#respond [status=implemented hash=a16366b3449c]
    public static func respond(_ input: Input, outcome: Outcome) async {
        switch outcome {
        case .cancel:
            await cancel(client: input.client, form: input.form, message: nil)
        case .answer(let answer):
            do {
                try await input.client.sessionFormReply(
                    sessionID: input.form.sessionID,
                    formID: input.form.id,
                    answer: answer
                )
            } catch is OpenCodeProtocol.FormAlreadySettledError {
                return
            } catch is OpenCodeProtocol.FormNotFoundError {
                return
            } catch ProtocolErrorEnvelope.formAlreadySettled, ProtocolErrorEnvelope.formNotFound {
                return
            } catch {
                await cancel(client: input.client, form: input.form, message: nil)
            }
        }
    }

    private static func cancel(client: any CLIACP.BackendClient, form: AskedForm, message: String?) async {
        do {
            try await client.sessionFormCancel(
                sessionID: form.sessionID,
                formID: form.id,
                message: message
            )
        } catch is OpenCodeProtocol.FormAlreadySettledError {
            return
        } catch is OpenCodeProtocol.FormNotFoundError {
            return
        } catch ProtocolErrorEnvelope.formAlreadySettled, ProtocolErrorEnvelope.formNotFound {
            return
        } catch {
            if let sessionID = try? CLIACP.ClientHelpers.decodeSessionID(form.sessionID) {
                try? await client.sessionInterrupt(sessionID: sessionID.rawValue)
            }
        }
    }

    private static func parseAnswer(form: AskedForm, response: CLIACP.CreateElicitationResponse) -> Outcome? {
        guard response.action == "accept" else { return nil }
        let rawContent = response.content ?? [:]
        var decoded: FormSchema.Answer = [:]
        for (k, v) in rawContent {
            guard let formVal = jsonToFormValue(v) else { return nil }
            decoded[k] = formVal
        }
        var result: FormSchema.Answer = [:]
        for field in form.fields {
            if let value = fieldAnswer(field: field, content: decoded) {
                result[fieldKey(field)] = value
            }
        }
        return .answer(result)
    }

    private static func jsonToFormValue(_ value: JSONValue) -> FormSchema.Value? {
        switch value {
        case .string(let s): return .string(s)
        case .int(let i): return .number(Double(i))
        case .double(let d): return .number(d)
        case .bool(let b): return .bool(b)
        case .array(let arr):
            var strings: [String] = []
            for item in arr {
                guard case .string(let s) = item else { return nil }
                strings.append(s)
            }
            return .strings(strings)
        case .null, .object:
            return nil
        }
    }

    private static func fieldAnswer(field: FormSchema.Field, content: FormSchema.Answer) -> FormSchema.Value? {
        if isHidden(field) {
            return defaultFormValue(field)
        }
        let key = fieldKey(field)
        let value = content[key]
        switch field {
        case .string(let f):
            guard f.custom == true, f.options != nil else { return value }
            if case .string(let custom) = content["\(key)_custom"],
               !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return .string(custom)
            }
            return value
        case .multiselect(let f):
            guard f.custom == true else { return value }
            if case .string(let custom) = content["\(key)_custom"],
               !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                if case .strings(let existing) = value {
                    return .strings(existing + [custom])
                }
                return .strings([custom])
            }
            return value
        default:
            return value
        }
    }

    private static func credentialLike(_ field: FormSchema.Field) -> Bool {
        var texts: [String] = []
        switch field {
        case .string(let f):
            texts.append(f.key)
            if let t = f.title { texts.append(t) }
            if let d = f.description { texts.append(d) }
            if let opts = f.options { texts.append(contentsOf: opts.map(\.label)) }
        case .multiselect(let f):
            texts.append(f.key)
            if let t = f.title { texts.append(t) }
            if let d = f.description { texts.append(d) }
            texts.append(contentsOf: f.options.map(\.label))
        case .number(let f):
            texts.append(f.key)
            if let t = f.title { texts.append(t) }
            if let d = f.description { texts.append(d) }
        case .integer(let f):
            texts.append(f.key)
            if let t = f.title { texts.append(t) }
            if let d = f.description { texts.append(d) }
        case .boolean(let f):
            texts.append(f.key)
            if let t = f.title { texts.append(t) }
            if let d = f.description { texts.append(d) }
        case .external(let f):
            texts.append(f.key)
            if let t = f.title { texts.append(t) }
            if let d = f.description { texts.append(d) }
        }
        return texts.contains(where: matchesCredentialPattern)
    }

    /// Matches `/password|passphrase|secret|token|api[_ -]?key|credential|private[_ -]?key/i`.
    private static func matchesCredentialPattern(_ text: String) -> Bool {
        let lower = text.lowercased()
        let fixed = ["password", "passphrase", "secret", "token", "credential"]
        for needle in fixed where lower.contains(needle) {
            return true
        }
        let compound = ["apikey", "api_key", "api-key", "api key", "privatekey", "private_key", "private-key", "private key"]
        for needle in compound where lower.contains(needle) {
            return true
        }
        return false
    }

    private static func representable(_ field: FormSchema.Field, keys: Set<String>) -> Bool {
        switch field {
        case .string(let f):
            guard let options = f.options else { return true }
            let values = Set(options.map(\.value))
            if let def = f.defaultValue, !values.contains(def) { return false }
            if f.custom != true { return true }
            if f.required == true || keys.contains("\(f.key)_custom") { return false }
            return true
        case .multiselect(let f):
            let values = Set(f.options.map(\.value))
            if let defs = f.defaultValue, defs.contains(where: { !values.contains($0) }) { return false }
            if f.custom != true { return true }
            if f.required == true || keys.contains("\(f.key)_custom") { return false }
            return f.minItems == nil && f.maxItems == nil
        case .number, .integer, .boolean:
            return true
        case .external:
            return false
        }
    }

    private static func fieldProperties(_ field: FormSchema.Field) -> [(String, CLIACP.ElicitationPropertySchema)] {
        switch field {
        case .string(let f):
            if let opts = f.options {
                let select = CLIACP.ElicitationPropertySchema(
                    type: "string",
                    title: f.title,
                    description: f.description,
                    oneOf: mapOptions(opts),
                    defaultValue: f.defaultValue.map { .string($0) }
                )
                if f.custom == true {
                    return [
                        (f.key, select),
                        otherField(
                            key: f.key,
                            title: f.title,
                            description: "Type your own answer",
                            stringField: f
                        ),
                    ]
                }
                return [(f.key, select)]
            }
            let minLen = f.required == true ? max(f.minLength?.rawValue ?? 0, 1) : f.minLength?.rawValue
            return [
                (
                    f.key,
                    CLIACP.ElicitationPropertySchema(
                        type: "string",
                        title: f.title,
                        description: f.description,
                        format: f.format?.rawValue,
                        minLength: minLen,
                        maxLength: f.maxLength?.rawValue,
                        pattern: f.pattern,
                        defaultValue: f.defaultValue.map { .string($0) }
                    )
                ),
            ]

        case .multiselect(let f):
            let minItems = f.required == true ? max(f.minItems?.rawValue ?? 0, 1) : f.minItems?.rawValue
            let select = CLIACP.ElicitationPropertySchema(
                type: "array",
                title: f.title,
                description: f.description,
                items: CLIACP.ElicitationArrayItems(anyOf: mapOptions(f.options)),
                minItems: minItems,
                maxItems: f.maxItems?.rawValue,
                defaultValue: f.defaultValue.map { .array($0.map { .string($0) }) }
            )
            if f.custom == true {
                return [
                    (f.key, select),
                    otherField(
                        key: f.key,
                        title: f.title,
                        description: "Add your own answer",
                        stringField: nil
                    ),
                ]
            }
            return [(f.key, select)]

        case .number(let f):
            return [
                (
                    f.key,
                    CLIACP.ElicitationPropertySchema(
                        type: "number",
                        title: f.title,
                        description: f.description,
                        minimum: f.minimum,
                        maximum: f.maximum,
                        defaultValue: f.defaultValue.map { .double($0) }
                    )
                ),
            ]

        case .integer(let f):
            return [
                (
                    f.key,
                    CLIACP.ElicitationPropertySchema(
                        type: "integer",
                        title: f.title,
                        description: f.description,
                        minimum: f.minimum,
                        maximum: f.maximum,
                        defaultValue: f.defaultValue.map { .double($0) }
                    )
                ),
            ]

        case .boolean(let f):
            return [
                (
                    f.key,
                    CLIACP.ElicitationPropertySchema(
                        type: "boolean",
                        title: f.title,
                        description: f.description,
                        defaultValue: f.defaultValue.map { .bool($0) }
                    )
                ),
            ]

        case .external:
            return []
        }
    }

    private static func otherField(
        key: String,
        title: String?,
        description: String,
        stringField: FormSchema.StringField?
    ) -> (String, CLIACP.ElicitationPropertySchema) {
        let minLen: Int?
        if let f = stringField {
            minLen = f.required == true ? max(f.minLength?.rawValue ?? 0, 1) : f.minLength?.rawValue
        } else {
            minLen = nil
        }
        return (
            "\(key)_custom",
            CLIACP.ElicitationPropertySchema(
                type: "string",
                title: "\(title ?? key) (other)",
                description: description,
                format: stringField?.format?.rawValue,
                minLength: minLen,
                maxLength: stringField?.maxLength?.rawValue,
                pattern: stringField?.pattern
            )
        )
    }

    private static func mapOptions(_ opts: [FormSchema.Option]) -> [CLIACP.EnumOption] {
        opts.map { CLIACP.EnumOption(const: $0.value, title: $0.label, description: $0.description) }
    }

    private static func fieldKey(_ field: FormSchema.Field) -> String {
        switch field {
        case .string(let f): f.key
        case .number(let f): f.key
        case .integer(let f): f.key
        case .boolean(let f): f.key
        case .multiselect(let f): f.key
        case .external(let f): f.key
        }
    }

    private static func isHidden(_ field: FormSchema.Field) -> Bool {
        switch field {
        case .string(let f): f.hidden == true
        case .number(let f): f.hidden == true
        case .integer(let f): f.hidden == true
        case .boolean(let f): f.hidden == true
        case .multiselect(let f): f.hidden == true
        case .external: false
        }
    }

    private static func isRequired(_ field: FormSchema.Field) -> Bool {
        switch field {
        case .string(let f): f.required == true
        case .number(let f): f.required == true
        case .integer(let f): f.required == true
        case .boolean(let f): f.required == true
        case .multiselect(let f): f.required == true
        case .external: false
        }
    }

    private static func hasNonEmptyWhen(_ field: FormSchema.Field) -> Bool {
        switch field {
        case .string(let f): !(f.when ?? []).isEmpty
        case .number(let f): !(f.when ?? []).isEmpty
        case .integer(let f): !(f.when ?? []).isEmpty
        case .boolean(let f): !(f.when ?? []).isEmpty
        case .multiselect(let f): !(f.when ?? []).isEmpty
        case .external: false
        }
    }

    private static func isHiddenRequiredWithoutDefault(_ field: FormSchema.Field) -> Bool {
        switch field {
        case .string(let f): f.hidden == true && f.required == true && f.defaultValue == nil
        case .number(let f): f.hidden == true && f.required == true && f.defaultValue == nil
        case .integer(let f): f.hidden == true && f.required == true && f.defaultValue == nil
        case .boolean(let f): f.hidden == true && f.required == true && f.defaultValue == nil
        case .multiselect(let f): f.hidden == true && f.required == true && f.defaultValue == nil
        case .external: false
        }
    }

    private static func defaultFormValue(_ field: FormSchema.Field) -> FormSchema.Value? {
        switch field {
        case .string(let f): f.defaultValue.map { .string($0) }
        case .number(let f): f.defaultValue.map { .number($0) }
        case .integer(let f): f.defaultValue.map { .number($0) }
        case .boolean(let f): f.defaultValue.map { .bool($0) }
        case .multiselect(let f): f.defaultValue.map { .strings($0) }
        case .external: nil
        }
    }
}
