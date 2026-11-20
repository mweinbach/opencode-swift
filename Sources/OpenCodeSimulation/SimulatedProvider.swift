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

/// Driver-controlled LLM and simulated-tool provider (`packages/simulation/src/backend/simulated-provider.ts`).
public enum SimulatedProvider {
    /// Intercepted provider HTTP request passed to `SimulatedProvider.Interface.stream`.
    // parity: simulation/src/backend/simulated-provider.ts#ProviderRequest [status=implemented hash=f07c86710c14]
    public struct ProviderRequest: Equatable, Hashable, Sendable, Codable {
        public let url: String
        public let body: JSONValue

        public init(url: String, body: JSONValue) {
            self.url = url
            self.body = body
        }
    }

    /// Event emitted by a simulated model provider stream (`Backend.Item | finish`).
    // parity: simulation/src/backend/simulated-provider.ts#ProviderResponseEvent [status=implemented hash=963ecc553325]
    public enum ProviderResponseEvent: Equatable, Hashable, Sendable, Codable {
        case item(OpenCodeProtocol.Backend.Item)
        case finish(reason: OpenCodeProtocol.Backend.FinishReason)

        public static func textDelta(_ text: String) -> ProviderResponseEvent {
            .item(.textDelta(text: text))
        }

        public static func reasoningDelta(_ text: String) -> ProviderResponseEvent {
            .item(.reasoningDelta(text: text))
        }

        public static func toolInputStart(index: Double, id: String, name: String) -> ProviderResponseEvent {
            .item(.toolInputStart(index: index, id: id, name: name))
        }

        public static func toolInputDelta(index: Double, text: String) -> ProviderResponseEvent {
            .item(.toolInputDelta(index: index, text: text))
        }

        public static func toolCall(index: Double, id: String, name: String, input: JSONValue) -> ProviderResponseEvent {
            .item(.toolCall(index: index, id: id, name: name, input: input))
        }

        public static func raw(_ chunk: JSONValue) -> ProviderResponseEvent {
            .item(.raw(chunk: chunk))
        }

        private enum CodingKeys: String, CodingKey {
            case type, reason
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let kind = try c.decode(String.self, forKey: .type)
            if kind == "finish" {
                self = .finish(reason: try c.decode(OpenCodeProtocol.Backend.FinishReason.self, forKey: .reason))
            } else {
                self = .item(try OpenCodeProtocol.Backend.Item(from: decoder))
            }
        }

        public func encode(to encoder: Encoder) throws {
            switch self {
            case .item(let item):
                try item.encode(to: encoder)
            case .finish(let reason):
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode("finish", forKey: .type)
                try c.encode(reason, forKey: .reason)
            }
        }
    }

    /// Error raised when Drive disconnects an in-flight model provider invocation.
    // parity: simulation/src/backend/simulated-provider.ts#ProviderDisconnectedError [status=implemented hash=72d7825e1317]
    public struct ProviderDisconnectedError: Error, Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
        public static let tag = "SimulatedProvider.ProviderDisconnectedError"

        public let message: String

        public init(message: String) {
            self.message = message
        }

        public var description: String { message }

        private enum CodingKeys: String, CodingKey {
            case _tag, message
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let tag = try c.decodeIfPresent(String.self, forKey: ._tag), tag != Self.tag {
                throw DecodingError.dataCorruptedError(forKey: ._tag, in: c, debugDescription: "Expected tag '\(Self.tag)'")
            }
            self.message = try c.decode(String.self, forKey: .message)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(Self.tag, forKey: ._tag)
            try c.encode(message, forKey: .message)
        }
    }

    /// Tagged error raised when an LLM invocation ID does not match any pending invocation.
    public struct InvocationNotFoundError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public static let tag = "SimulatedProvider.InvocationNotFoundError"
        public let id: String
        public let message: String

        public init(id: String, message: String) {
            self.id = id
            self.message = message
        }

        public var description: String { message }
    }

    /// Tagged error raised when a Drive LLM controller disconnects before or during attachment.
    public struct ControllerDisconnectedError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public static let tag = "SimulatedProvider.ControllerDisconnectedError"
        public let message: String

        public init(message: String) {
            self.message = message
        }

        public var description: String { message }
    }

    /// Tagged error raised when a tool invocation ID is unknown or already settled.
    public struct ToolInvocationNotFoundError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public static let tag = "SimulatedProvider.ToolInvocationNotFoundError"
        public let id: String
        public let message: String

        public init(id: String, message: String) {
            self.id = id
            self.message = message
        }

        public var description: String { message }
    }

    /// Tagged error raised when tool controller attachment, sequencing, or reconciliation fails.
    public struct ToolControllerError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public static let tag = "SimulatedProvider.ToolControllerError"
        public let message: String

        public init(message: String) {
            self.message = message
        }

        public var description: String { message }
    }

    /// Core contract for streaming simulated model responses for intercepted requests.
    // parity: simulation/src/backend/simulated-provider.ts#Interface [status=implemented hash=4859ef408819]
    public protocol Interface: Sendable {
        func stream(_ request: ProviderRequest) -> AsyncThrowingStream<ProviderResponseEvent, Error>
    }

    /// Service container for `SimulatedProvider` matching Effect's `Context.Service`.
    // parity: simulation/src/backend/simulated-provider.ts#Service [status=implemented hash=e4df795012da]
    public final class Service: Interface, Sendable {
        public static let serviceKey = "@opencode/simulation/SimulatedProvider"

        private let implementation: any Interface

        public init(_ implementation: any Interface) {
            self.implementation = implementation
        }

        public static func of(_ implementation: any Interface) -> Service {
            Service(implementation)
        }

        public static func of(
            stream: @escaping @Sendable (ProviderRequest) -> AsyncThrowingStream<ProviderResponseEvent, Error>
        ) -> Service {
            Service(ClosureProvider(streamFn: stream))
        }

        /// Creates a deterministic scripted provider that replies to sequential requests using `turns`.
        public static func scripted(_ turns: [[ProviderResponseEvent]]) -> Service {
            let state = Mutex<(index: Int, requests: [ProviderRequest])>((0, []))
            return Service.of { request in
                let turn: [ProviderResponseEvent]? = state.withLock { s in
                    s.requests.append(request)
                    guard s.index < turns.count else { return nil }
                    let current = turns[s.index]
                    s.index += 1
                    return current
                }
                return AsyncThrowingStream { continuation in
                    guard let turn else {
                        continuation.finish(
                            throwing: ProviderDisconnectedError(message: "Scripted provider exhausted all configured turns")
                        )
                        return
                    }
                    for event in turn {
                        continuation.yield(event)
                        if case .finish = event {
                            break
                        }
                    }
                    continuation.finish()
                }
            }
        }

        public func stream(_ request: ProviderRequest) -> AsyncThrowingStream<ProviderResponseEvent, Error> {
            implementation.stream(request)
        }
    }

    private struct ClosureProvider: Interface, Sendable {
        let streamFn: @Sendable (ProviderRequest) -> AsyncThrowingStream<ProviderResponseEvent, Error>

        func stream(_ request: ProviderRequest) -> AsyncThrowingStream<ProviderResponseEvent, Error> {
            streamFn(request)
        }
    }

    /// Options for constructing a Drive-controlled `SimulatedProvider` backend server layer.
    public struct DriveOptions: Equatable, Hashable, Sendable {
        public let endpoint: String
        public let version: String
        public let bindNetwork: Bool

        public init(endpoint: String, version: String, bindNetwork: Bool = true) {
            self.endpoint = endpoint
            self.version = version
            self.bindNetwork = bindNetwork
        }
    }

    /// Live Drive backend handle exposing both the `SimulatedProvider.Service` and its control server.
    public struct DriveHandle: Sendable {
        public let service: Service
        public let server: SimulationControlServer.Server
        public let shutdown: @Sendable () async -> Void
    }

    /// Starts the Drive-controlled `SimulatedProvider` + simulated tool driver directly (for host wiring or tests).
    public static func startDrive(
        _ options: DriveOptions,
        sdkPlugins: CorePlugin.SdkPlugins.Service? = nil,
        scope: LayerNode.ResourceScope? = nil
    ) async throws -> DriveHandle {
        let llmDriver = LLMInvocationDriver()
        let toolDriver = ToolInvocationDriver(sdkPlugins: sdkPlugins)
        let controllerActor = LLMControllerCoordinator()
        let version = options.version

        let server = try await SimulationControlServer.start(
            options: SimulationControlServer.StartOptions<OpenCodeProtocol.Backend.Request>(
                endpoint: options.endpoint,
                label: "opencode drive backend websocket",
                data: { SimulationControlServer.SocketData() },
                decode: { try OpenCodeProtocol.Backend.decodeRequestEffect($0) },
                requestID: { requestID(of: $0) },
                handle: { socket, request in
                    try await handleRequest(
                        llmDriver: llmDriver,
                        toolDriver: toolDriver,
                        controllerActor: controllerActor,
                        socket: socket,
                        request: request,
                        version: version
                    )
                },
                close: { socket in
                    await controllerActor.release(socket: socket)
                    await toolDriver.release(socket: socket)
                },
                bindNetwork: options.bindNetwork
            )
        )

        let shutdownFn: @Sendable () async -> Void = {
            await server.close()
            await controllerActor.shutdown()
            await llmDriver.shutdown()
            await toolDriver.shutdown()
        }

        if let scope {
            scope.addFinalizer(shutdownFn)
        }

        let service = Service.of { request in
            llmDriver.stream(request)
        }
        return DriveHandle(service: service, server: server, shutdown: shutdownFn)
    }

    /// Builds a `LayerNode.ExecutableLayer` acquiring the Drive WebSocket backend provider and tool driver.
    // parity: simulation/src/backend/simulated-provider.ts#layerDrive [status=implemented hash=b5713d02cb4b]
    public static func layerDrive(_ options: DriveOptions) -> LayerNode.ExecutableLayer {
        LayerNode.ExecutableLayer { deps, scope in
            let sdkPlugins = deps.get(CorePlugin.SdkPlugins.Service.serviceKey, as: CorePlugin.SdkPlugins.Service.self)
            let handle = try await startDrive(options, sdkPlugins: sdkPlugins, scope: scope)
            return LayerNode.Output([
                Service.serviceKey: handle.service,
                driveServerKey: handle.server,
            ])
        }
    }

    /// Output key under which `layerDrive` also exposes its started `SimulationControlServer.Server`.
    public static let driveServerKey = "@opencode/simulation/SimulatedProviderServer"

    // MARK: - Request Dispatch

    private static func requestID(of request: OpenCodeProtocol.Backend.Request) -> OpenCodeProtocol.JsonRpc.ID? {
        switch request {
        case .handshake(let req): return req.id
        case .llmChunk(let id, _): return id
        case .llmFinish(let id, _): return id
        case .llmDisconnect(let id, _): return id
        case .toolAttach(let id, _): return id
        case .toolUpdate(let id, _): return id
        case .toolFinish(let id, _): return id
        case .toolFail(let id, _): return id
        case .llmAttach(let id): return id
        case .llmPending(let id): return id
        }
    }

    private static func handleRequest(
        llmDriver: LLMInvocationDriver,
        toolDriver: ToolInvocationDriver,
        controllerActor: LLMControllerCoordinator,
        socket: SimulationControlServer.Socket,
        request: OpenCodeProtocol.Backend.Request,
        version: String
    ) async throws -> JSONValue {
        switch request {
        case .handshake(let req):
            let response = try OpenCodeProtocol.Handshake.dispatch(
                action: OpenCodeProtocol.Handshake.DispatchAction(
                    role: .backend,
                    server: OpenCodeProtocol.Handshake.Identity(name: "opencode", version: version),
                    capabilities: OpenCodeProtocol.Backend.Capabilities
                ),
                params: req.params
            )
            return try ServerCodec.toJSONValue(response)

        case .llmAttach:
            let attached = try await controllerActor.attach(socket: socket, driver: llmDriver)
            return try ServerCodec.toJSONValue(attached)

        case .llmChunk(_, let params):
            try await llmDriver.push(id: params.id, items: params.items)
            return try ServerCodec.toJSONValue(OpenCodeProtocol.Backend.Ok())

        case .llmFinish(_, let params):
            try await llmDriver.finish(id: params.id, reason: params.reason)
            return try ServerCodec.toJSONValue(OpenCodeProtocol.Backend.Ok())

        case .llmDisconnect(_, let params):
            try await llmDriver.disconnect(id: params.id)
            return try ServerCodec.toJSONValue(OpenCodeProtocol.Backend.Ok())

        case .llmPending:
            let pending = await llmDriver.pending()
            return try ServerCodec.toJSONValue(OpenCodeProtocol.Backend.Pending(invocations: pending))

        case .toolAttach(_, let params):
            let attached = try await toolDriver.attach(socket: socket, registrations: params.tools)
            return try ServerCodec.toJSONValue(attached)

        case .toolUpdate(_, let params):
            try await toolDriver.update(socket: socket, params: params)
            return try ServerCodec.toJSONValue(OpenCodeProtocol.Backend.Ok())

        case .toolFinish(_, let params):
            try await toolDriver.finish(socket: socket, params: params)
            return try ServerCodec.toJSONValue(OpenCodeProtocol.Backend.Ok())

        case .toolFail(_, let params):
            try await toolDriver.fail(socket: socket, params: params)
            return try ServerCodec.toJSONValue(OpenCodeProtocol.Backend.Ok())
        }
    }

    // MARK: - Bounded Backpressured Async Queue for LLM Responses

    private actor BoundedEventQueue {
        enum Terminal: Sendable {
            case ended
            case failed(ProviderDisconnectedError)
            case shutdown
        }

        private let capacity: Int
        private var buffer: [ProviderResponseEvent] = []
        private var terminal: Terminal? = nil
        private var consumerWaiter: CheckedContinuation<Result<ProviderResponseEvent?, Error>, Never>? = nil
        private var producerWaiters: [(event: ProviderResponseEvent, cont: CheckedContinuation<Bool, Never>)] = []

        init(capacity: Int = 256) {
            self.capacity = capacity
        }

        /// Enqueues an item, suspending under backpressure when full and returning `false` if closed/shut down.
        func offer(_ event: ProviderResponseEvent) async -> Bool {
            if terminal != nil { return false }
            if let consumer = consumerWaiter {
                consumerWaiter = nil
                consumer.resume(returning: .success(event))
                return true
            }
            if buffer.count < capacity {
                buffer.append(event)
                return true
            }
            return await withCheckedContinuation { cont in
                if terminal != nil {
                    cont.resume(returning: false)
                    return
                }
                if let consumer = consumerWaiter {
                    consumerWaiter = nil
                    consumer.resume(returning: .success(event))
                    cont.resume(returning: true)
                    return
                }
                if buffer.count < capacity {
                    buffer.append(event)
                    cont.resume(returning: true)
                    return
                }
                producerWaiters.append((event: event, cont: cont))
            }
        }

        func offerAll(_ events: [ProviderResponseEvent]) async {
            for event in events {
                let accepted = await offer(event)
                if !accepted { break }
            }
        }

        func take() async throws -> ProviderResponseEvent? {
            if !buffer.isEmpty {
                let item = buffer.removeFirst()
                promoteProducerIfRoom()
                return item
            }
            if !producerWaiters.isEmpty {
                let first = producerWaiters.removeFirst()
                first.cont.resume(returning: true)
                return first.event
            }
            if let terminal {
                return try resolveTerminal(terminal)
            }
            let result = await withCheckedContinuation { (cont: CheckedContinuation<Result<ProviderResponseEvent?, Error>, Never>) in
                if !buffer.isEmpty {
                    let item = buffer.removeFirst()
                    promoteProducerIfRoom()
                    cont.resume(returning: .success(item))
                    return
                }
                if !producerWaiters.isEmpty {
                    let first = producerWaiters.removeFirst()
                    first.cont.resume(returning: true)
                    cont.resume(returning: .success(first.event))
                    return
                }
                if let terminal {
                    do {
                        cont.resume(returning: .success(try resolveTerminal(terminal)))
                    } catch {
                        cont.resume(returning: .failure(error))
                    }
                    return
                }
                consumerWaiter = cont
            }
            return try result.get()
        }

        func end() {
            guard terminal == nil else { return }
            terminal = .ended
            if buffer.isEmpty && producerWaiters.isEmpty, let consumer = consumerWaiter {
                consumerWaiter = nil
                consumer.resume(returning: .success(nil))
            }
        }

        func fail(_ error: ProviderDisconnectedError) {
            guard terminal == nil else { return }
            terminal = .failed(error)
            let waiters = producerWaiters
            producerWaiters.removeAll()
            for waiter in waiters {
                waiter.cont.resume(returning: false)
            }
            if let consumer = consumerWaiter {
                consumerWaiter = nil
                consumer.resume(returning: .failure(error))
            }
        }

        func shutdown() {
            if terminal == nil {
                terminal = .shutdown
            }
            buffer.removeAll()
            let waiters = producerWaiters
            producerWaiters.removeAll()
            for waiter in waiters {
                waiter.cont.resume(returning: false)
            }
            if let consumer = consumerWaiter {
                consumerWaiter = nil
                consumer.resume(returning: .success(nil))
            }
        }

        private func promoteProducerIfRoom() {
            while buffer.count < capacity && !producerWaiters.isEmpty {
                let waiter = producerWaiters.removeFirst()
                buffer.append(waiter.event)
                waiter.cont.resume(returning: true)
            }
        }

        private func resolveTerminal(_ terminal: Terminal) throws -> ProviderResponseEvent? {
            switch terminal {
            case .ended, .shutdown:
                return nil
            case .failed(let error):
                throw error
            }
        }
    }

    // MARK: - LLM Invocation Driver

    private actor LLMInvocationDriver {
        private struct PendingInvocation {
            let invocation: OpenCodeProtocol.Backend.ProviderInvocation
            let responses: BoundedEventQueue
        }

        private var counter: Int = 0
        private var order: [String] = []
        private var pendingMap: [String: PendingInvocation] = [:]
        private var subscribers: [UUID: AsyncStream<OpenCodeProtocol.Backend.ProviderInvocation>.Continuation] = [:]

        nonisolated func stream(_ request: ProviderRequest) -> AsyncThrowingStream<ProviderResponseEvent, Error> {
            final class PullState: Sendable {
                struct Inner: Sendable {
                    var pending: PendingInvocation? = nil
                    var finished: Bool = false
                    var cancelled: Bool = false
                }
                let driver: LLMInvocationDriver
                let inner = Mutex(Inner())

                init(driver: LLMInvocationDriver) {
                    self.driver = driver
                }

                func cancelAndClose() {
                    let pending = inner.withLock { s -> PendingInvocation? in
                        s.cancelled = true
                        let p = s.pending
                        s.pending = nil
                        return p
                    }
                    if let pending {
                        let drv = driver
                        Task {
                            await drv.close(pending)
                        }
                    }
                }

                deinit {
                    cancelAndClose()
                }
            }
            let state = PullState(driver: self)
            return AsyncThrowingStream { [self, state] in
                if state.inner.withLock({ $0.finished || $0.cancelled }) {
                    return nil
                }
                let pending: PendingInvocation
                if let existing = state.inner.withLock({ $0.pending }) {
                    pending = existing
                } else {
                    let opened = await self.open(request)
                    let shouldClose = state.inner.withLock { s -> Bool in
                        if s.cancelled { return true }
                        s.pending = opened
                        return false
                    }
                    if shouldClose || Task.isCancelled {
                        await self.close(opened)
                        return nil
                    }
                    pending = opened
                }
                do {
                    let event = try await withTaskCancellationHandler {
                        try await pending.responses.take()
                    } onCancel: {
                        state.cancelAndClose()
                    }
                    guard let event else {
                        state.inner.withLock { s in
                            s.finished = true
                            s.pending = nil
                        }
                        await self.close(pending)
                        return nil
                    }
                    if case .finish = event {
                        state.inner.withLock { s in
                            s.finished = true
                            s.pending = nil
                        }
                        await self.close(pending)
                    }
                    return event
                } catch {
                    state.inner.withLock { s in
                        s.finished = true
                        s.pending = nil
                    }
                    await self.close(pending)
                    throw error
                }
            }
        }

        private func open(_ request: ProviderRequest) -> PendingInvocation {
            counter += 1
            let id = "inv_\(counter)"
            let invocation = OpenCodeProtocol.Backend.ProviderInvocation(id: id, url: request.url, body: request.body)
            let responses = BoundedEventQueue(capacity: 256)
            let entry = PendingInvocation(invocation: invocation, responses: responses)
            order.append(id)
            pendingMap[id] = entry
            for cont in subscribers.values {
                cont.yield(invocation)
            }
            return entry
        }

        private func close(_ entry: PendingInvocation) async {
            await entry.responses.shutdown()
            if pendingMap[entry.invocation.id]?.responses === entry.responses {
                pendingMap.removeValue(forKey: entry.invocation.id)
                order.removeAll { $0 == entry.invocation.id }
            }
        }

        func subscribeRequests() -> AsyncStream<OpenCodeProtocol.Backend.ProviderInvocation> {
            let subID = UUID()
            let snapshot = order.compactMap { pendingMap[$0]?.invocation }
            return AsyncStream { continuation in
                for item in snapshot {
                    continuation.yield(item)
                }
                subscribers[subID] = continuation
                continuation.onTermination = { [self] _ in
                    Task {
                        await self.unsubscribe(subID)
                    }
                }
            }
        }

        private func unsubscribe(_ id: UUID) {
            subscribers.removeValue(forKey: id)
        }

        func push(id: String, items: [OpenCodeProtocol.Backend.Item]) async throws {
            guard let entry = pendingMap[id] else {
                throw InvocationNotFoundError(
                    id: id,
                    message: "Simulated provider invocation not found or already finished: \(id)"
                )
            }
            await entry.responses.offerAll(items.map(ProviderResponseEvent.item))
        }

        func finish(id: String, reason: OpenCodeProtocol.Backend.FinishReason) async throws {
            guard let entry = pendingMap.removeValue(forKey: id) else {
                throw InvocationNotFoundError(
                    id: id,
                    message: "Simulated provider invocation not found or already finished: \(id)"
                )
            }
            order.removeAll { $0 == id }
            _ = await entry.responses.offer(.finish(reason: reason))
            await entry.responses.end()
        }

        func disconnect(id: String) async throws {
            guard let entry = pendingMap.removeValue(forKey: id) else {
                throw InvocationNotFoundError(
                    id: id,
                    message: "Simulated provider invocation not found or already finished: \(id)"
                )
            }
            order.removeAll { $0 == id }
            await entry.responses.fail(ProviderDisconnectedError(message: "Simulated model provider disconnected"))
        }

        func pending() -> [OpenCodeProtocol.Backend.ProviderInvocation] {
            order.compactMap { pendingMap[$0]?.invocation }
        }

        func shutdown() async {
            let all = Array(pendingMap.values)
            pendingMap.removeAll()
            order.removeAll()
            for entry in all {
                await entry.responses.shutdown()
            }
            let subs = Array(subscribers.values)
            subscribers.removeAll()
            for cont in subs {
                cont.finish()
            }
        }
    }

    private actor LLMControllerCoordinator {
        private var activeAttachment: Task<Void, Never>? = nil

        func attach(
            socket: SimulationControlServer.Socket,
            driver: LLMInvocationDriver
        ) async throws -> OpenCodeProtocol.Backend.Attached {
            if socket.data.closed {
                throw ControllerDisconnectedError(message: "Drive controller disconnected before attachment")
            }
            if let previous = activeAttachment {
                previous.cancel()
                activeAttachment = nil
            }
            let stream = await driver.subscribeRequests()
            let task = Task {
                for await invocation in stream {
                    if Task.isCancelled || socket.data.closed { break }
                    let notification = OpenCodeProtocol.Backend.Notification.llmRequest(invocation)
                    if let encoded = try? ServerCodec.encodeString(notification) {
                        do {
                            try await socket.send(encoded)
                        } catch {
                            break
                        }
                    }
                }
            }
            if socket.data.closed {
                task.cancel()
                throw ControllerDisconnectedError(message: "Drive controller disconnected during attachment")
            }
            socket.data.attachment = task
            activeAttachment = task
            return OpenCodeProtocol.Backend.Attached()
        }

        func release(socket: SimulationControlServer.Socket) {
            guard let attachment = socket.data.attachment else { return }
            attachment.cancel()
            if activeAttachment == attachment {
                activeAttachment = nil
            }
        }

        func shutdown() {
            activeAttachment?.cancel()
            activeAttachment = nil
        }
    }

    // MARK: - Simulated Tool Driver

    private actor ToolInvocationDriver {
        private static let completedRetention = 256

        private enum ToolCompletion: Sendable {
            case success(OpenCodeProtocol.Backend.ToolOutput)
            case failure(String)

            var jsonValue: JSONValue {
                switch self {
                case .success(let output):
                    let encoded = (try? ServerCodec.toJSONValue(output)) ?? .null
                    return .object(["type": .string("success"), "output": encoded])
                case .failure(let message):
                    return .object(["type": .string("failure"), "message": .string(message)])
                }
            }
        }

        private final class PendingToolInvocation: Sendable {
            let id: String
            let notification: OpenCodeProtocol.Backend.ToolInvocation
            let progress: @Sendable (ToolSchema.Metadata) async -> Void

            private struct MutableState: Sendable {
                var lastUpdate: (sequence: Int, fingerprint: String)? = nil
                var completion: ToolCompletion? = nil
                var waiter: CheckedContinuation<ToolCompletion, Never>? = nil
            }

            private let state = Mutex(MutableState())

            init(
                id: String,
                notification: OpenCodeProtocol.Backend.ToolInvocation,
                progress: @escaping @Sendable (ToolSchema.Metadata) async -> Void
            ) {
                self.id = id
                self.notification = notification
                self.progress = progress
            }

            var lastUpdate: (sequence: Int, fingerprint: String)? {
                get { state.withLock { $0.lastUpdate } }
                set { state.withLock { $0.lastUpdate = newValue } }
            }

            func awaitCompletion() async -> ToolCompletion {
                let immediate = state.withLock { $0.completion }
                if let immediate { return immediate }
                return await withCheckedContinuation { cont in
                    let resolved: ToolCompletion? = state.withLock { s in
                        if let done = s.completion { return done }
                        s.waiter = cont
                        return nil
                    }
                    if let resolved {
                        cont.resume(returning: resolved)
                    }
                }
            }

            func resolve(_ completion: ToolCompletion) {
                let waiter: CheckedContinuation<ToolCompletion, Never>? = state.withLock { s in
                    guard s.completion == nil else { return nil }
                    s.completion = completion
                    let w = s.waiter
                    s.waiter = nil
                    return w
                }
                waiter?.resume(returning: completion)
            }
        }

        private final class OverlayHandle: Sendable {
            let id = UUID()
            let apply: @Sendable (Int, [OpenCodeProtocol.Backend.ToolRegistration]) async throws -> Void
            let dispose: @Sendable () async -> Void

            init(
                apply: @escaping @Sendable (Int, [OpenCodeProtocol.Backend.ToolRegistration]) async throws -> Void,
                dispose: @escaping @Sendable () async -> Void
            ) {
                self.apply = apply
                self.dispose = dispose
            }
        }

        private var counter: Int = 0
        private var generation: Int = 0
        private var appliedGeneration: Int = 0
        private var controller: SimulationControlServer.Socket? = nil
        private var registrations: [OpenCodeProtocol.Backend.ToolRegistration] = []
        private var pendingOrder: [String] = []
        private var pending: [String: PendingToolInvocation] = [:]
        private var completedOrder: [String] = []
        private var completed: [String: String] = [:]
        private var overlays: [UUID: OverlayHandle] = [:]

        init(sdkPlugins: CorePlugin.SdkPlugins.Service?) {
            if let sdkPlugins {
                let driver = self
                sdkPlugins.register(
                    PluginEffect.define(
                        PluginEffect.Plugin(id: "opencode.simulation.tools") { ctx in
                            await driver.registerOverlay(ctx: ctx)
                        }
                    )
                )
            }
        }

        private func registerOverlay(ctx: PluginEffect.Context) async {
            let overlayState = Mutex<(registration: PluginEffect.Registration?, installedIDs: [String])>((nil, []))
            let driver = self
            let overlay = OverlayHandle(
                apply: { generation, nextRegistrations in
                    let (previous, previousIDs) = overlayState.withLock { s -> (PluginEffect.Registration?, [String]) in
                        let prev = (s.registration, s.installedIDs)
                        s.registration = nil
                        return prev
                    }
                    if let previous {
                        await previous.dispose()
                    }
                    let nextIDs = nextRegistrations.map(OpenCodeProtocol.Backend.exposedToolName)
                    let reg = await ctx.tool.transform { editor in
                        for oldID in previousIDs {
                            editor.remove(oldID)
                        }
                        for item in nextRegistrations {
                            let exposed = OpenCodeProtocol.Backend.exposedToolName(item)
                            let toolOpts = ToolSchema.Options(
                                namespace: item.options?.namespace,
                                permission: item.permission,
                                codemode: item.options?.codemode
                            )
                            let dynamic = PluginEffect.DynamicToolInfo(
                                id: exposed,
                                name: item.name,
                                input: .jsonSchema(item.inputSchema),
                                description: item.description,
                                execute: { input, toolCtx async throws(ToolSchema.ToolError) -> ToolSchema.Result<JSONValue> in
                                    try await driver.invoke(
                                        registrationGeneration: generation,
                                        name: exposed,
                                        input: input,
                                        context: toolCtx
                                    )
                                },
                                output: .jsonSchema(item.outputSchema ?? [:]),
                                options: toolOpts
                            )
                            editor.add(dynamic)
                        }
                    }
                    overlayState.withLock { s in
                        s.registration = reg
                        s.installedIDs = nextIDs
                    }
                },
                dispose: {
                    let (existing, installedIDs) = overlayState.withLock { s -> (PluginEffect.Registration?, [String]) in
                        let prev = (s.registration, s.installedIDs)
                        s.registration = nil
                        s.installedIDs = []
                        return prev
                    }
                    if let existing {
                        await existing.dispose()
                    }
                    if !installedIDs.isEmpty {
                        let cleanup = await ctx.tool.transform { editor in
                            for oldID in installedIDs {
                                editor.remove(oldID)
                            }
                        }
                        await cleanup.dispose()
                    }
                }
            )
            overlays[overlay.id] = overlay
            let initialGen = generation
            let initialRegs = registrations
            ctx.addFinalizer { [driver, overlayID = overlay.id] in
                await driver.unregisterOverlay(id: overlayID)
            }
            try? await overlay.apply(initialGen, initialRegs)
        }

        private func unregisterOverlay(id: UUID) async {
            if let overlay = overlays.removeValue(forKey: id) {
                await overlay.dispose()
            }
        }

        func attach(
            socket: SimulationControlServer.Socket,
            registrations nextRegistrations: [OpenCodeProtocol.Backend.ToolRegistration]
        ) async throws -> OpenCodeProtocol.Backend.Attached {
            if socket.data.closed {
                throw ToolControllerError(message: "Drive tool controller disconnected before attachment")
            }
            if let existing = controller, existing !== socket, !existing.data.closed {
                throw ToolControllerError(message: "Another Drive tool controller is already attached")
            }
            let replay = controller !== socket
            let sameRegistrations =
                appliedGeneration == generation &&
                fingerprintEncodable(registrations) == fingerprintEncodable(nextRegistrations)
            if replay && !pending.isEmpty && !sameRegistrations {
                throw ToolControllerError(
                    message: "A reconnecting Drive tool controller must settle pending invocations before replacing tools"
                )
            }
            if sameRegistrations {
                controller = socket
                if replay {
                    await replayPending(to: socket)
                }
                return OpenCodeProtocol.Backend.Attached()
            }

            let previousController = controller
            let previousRegistrations = registrations
            let previousGeneration = generation
            let nextGeneration = generation + 1
            controller = socket
            registrations = nextRegistrations
            generation = nextGeneration

            do {
                try await reconcileOverlays(generation: nextGeneration, registrations: nextRegistrations)
                appliedGeneration = nextGeneration
            } catch {
                controller = previousController
                registrations = previousRegistrations
                generation = previousGeneration
                do {
                    try await reconcileOverlays(generation: previousGeneration, registrations: previousRegistrations)
                } catch let rollbackError {
                    throw ToolControllerError(
                        message: "Failed to apply and restore simulated tools: \(error); \(rollbackError)"
                    )
                }
                throw ToolControllerError(message: "Failed to apply simulated tools: \(error)")
            }

            if replay && controller === socket {
                await replayPending(to: socket)
            }
            return OpenCodeProtocol.Backend.Attached()
        }

        func update(
            socket: SimulationControlServer.Socket,
            params: OpenCodeProtocol.Backend.ToolUpdateParams
        ) async throws {
            try requireController(socket)
            guard let invocation = pending[params.id] else {
                throw ToolInvocationNotFoundError(
                    id: params.id,
                    message: "Simulated tool invocation not found or already finished: \(params.id)"
                )
            }
            let fp = fingerprintJSON(.object(params.update))
            if let applied = invocation.lastUpdate {
                if applied.sequence == params.sequence && applied.fingerprint == fp {
                    return
                }
                if applied.sequence == params.sequence {
                    throw ToolControllerError(
                        message: "Simulated tool update sequence \(params.sequence) was reused with different progress"
                    )
                }
                let expected = applied.sequence + 1
                if params.sequence != expected {
                    throw ToolControllerError(
                        message: "Expected simulated tool update sequence \(expected), received \(params.sequence)"
                    )
                }
            } else if params.sequence != 0 {
                throw ToolControllerError(
                    message: "Expected simulated tool update sequence 0, received \(params.sequence)"
                )
            }
            await invocation.progress(params.update)
            invocation.lastUpdate = (sequence: params.sequence, fingerprint: fp)
        }

        func finish(
            socket: SimulationControlServer.Socket,
            params: OpenCodeProtocol.Backend.ToolFinishParams
        ) async throws {
            try await settle(socket: socket, id: params.id, completion: .success(params.output))
        }

        func fail(
            socket: SimulationControlServer.Socket,
            params: OpenCodeProtocol.Backend.ToolFailParams
        ) async throws {
            try await settle(socket: socket, id: params.id, completion: .failure(params.message))
        }

        func release(socket: SimulationControlServer.Socket) {
            if controller === socket {
                controller = nil
            }
        }

        func shutdown() async {
            controller = nil
            registrations = []
            try? await reconcileOverlays(generation: generation + 1, registrations: [])
            let active = Array(pending.values)
            pending.removeAll()
            pendingOrder.removeAll()
            overlays.removeAll()
            for item in active {
                item.resolve(.failure("Simulated tool controller shut down"))
            }
        }

        private func invoke(
            registrationGeneration: Int,
            name: String,
            input: JSONValue,
            context: ToolSchema.Context
        ) async throws(ToolSchema.ToolError) -> ToolSchema.Result<JSONValue> {
            guard generation == registrationGeneration else {
                throw ToolSchema.ToolError(message: "Simulated tool registration is no longer active: \(name)")
            }
            counter += 1
            let id = "tool_\(counter)"
            let notification = OpenCodeProtocol.Backend.ToolInvocation(
                id: id,
                name: name,
                input: input,
                context: OpenCodeProtocol.Backend.ToolInvocation.Context(
                    sessionID: context.sessionID.rawValue,
                    agent: context.agent.rawValue,
                    messageID: context.messageID,
                    id: context.id.rawValue
                )
            )
            let pendingInvocation = PendingToolInvocation(
                id: id,
                notification: notification,
                progress: context.progress
            )
            pendingOrder.append(id)
            pending[id] = pendingInvocation
            if let controller, !controller.data.closed {
                await sendNotification(controller, .toolInvocation(notification))
            }

            let driver = self
            let completion = await withTaskCancellationHandler {
                await pendingInvocation.awaitCompletion()
            } onCancel: {
                Task {
                    await driver.cancel(id: id, expected: pendingInvocation)
                }
            }

            if pending[id] === pendingInvocation {
                pending.removeValue(forKey: id)
                pendingOrder.removeAll { $0 == id }
            }

            switch completion {
            case .success(let output):
                let content: ToolSchema.ResultContent?
                if output.content.isEmpty {
                    content = nil
                } else {
                    content = .parts(output.content.map { part in
                        switch part {
                        case .text(let text):
                            return .text(ToolSchema.TextContent(text: text))
                        case .file(let data, let mime, let fileName):
                            return .file(
                                ToolSchema.FileContent(
                                    uri: "data:\(mime);base64,\(data)",
                                    mime: mime,
                                    name: fileName
                                )
                            )
                        }
                    })
                }
                return ToolSchema.Result(output: output.structured, content: content)
            case .failure(let message):
                throw ToolSchema.ToolError(message: message)
            }
        }

        private func cancel(id: String, expected: PendingToolInvocation) async {
            guard pending[id] === expected else { return }
            pending.removeValue(forKey: id)
            pendingOrder.removeAll { $0 == id }
            expected.resolve(.failure("Simulated tool invocation interrupted"))
            if let controller, !controller.data.closed {
                await sendNotification(controller, .toolCancel(OpenCodeProtocol.Backend.ToolCancellation(id: id)))
            }
        }

        private func settle(
            socket: SimulationControlServer.Socket,
            id: String,
            completion: ToolCompletion
        ) async throws {
            try requireController(socket)
            let fp = fingerprintJSON(completion.jsonValue)
            guard let invocation = pending.removeValue(forKey: id) else {
                if completed[id] == fp {
                    return
                }
                throw ToolInvocationNotFoundError(
                    id: id,
                    message: "Simulated tool invocation not found or already finished: \(id)"
                )
            }
            pendingOrder.removeAll { $0 == id }
            recordCompleted(id: id, fingerprint: fp)
            invocation.resolve(completion)
        }

        private func recordCompleted(id: String, fingerprint: String) {
            if completed[id] == nil {
                completedOrder.append(id)
            }
            completed[id] = fingerprint
            if completedOrder.count > Self.completedRetention {
                let oldest = completedOrder.removeFirst()
                completed.removeValue(forKey: oldest)
            }
        }

        private func requireController(_ socket: SimulationControlServer.Socket) throws {
            guard controller === socket else {
                throw ToolControllerError(message: "Drive tool controller is not attached")
            }
        }

        private func reconcileOverlays(
            generation: Int,
            registrations: [OpenCodeProtocol.Backend.ToolRegistration]
        ) async throws {
            let currentOverlays = Array(overlays.values)
            for overlay in currentOverlays {
                try await overlay.apply(generation, registrations)
            }
        }

        private func replayPending(to socket: SimulationControlServer.Socket) async {
            for id in pendingOrder {
                if let item = pending[id], !socket.data.closed {
                    await sendNotification(socket, .toolInvocation(item.notification))
                }
            }
        }

        private func sendNotification(
            _ socket: SimulationControlServer.Socket,
            _ notification: OpenCodeProtocol.Backend.Notification
        ) async {
            if let encoded = try? ServerCodec.encodeString(notification) {
                try? await socket.send(encoded)
            }
        }
    }

    // MARK: - Canonical JSON Fingerprinting

    internal static func canonicalJSON(_ value: JSONValue) -> String {
        switch value {
        case .null:
            return "null"
        case .bool(let b):
            return b ? "true" : "false"
        case .int(let i):
            return String(i)
        case .double(let d):
            if d.isFinite, d.rounded() == d, d >= Double(Int64.min), d <= Double(Int64.max) {
                return String(Int64(d))
            }
            return String(d)
        case .string(let s):
            return encodeJSONStringLiteral(s)
        case .array(let items):
            return "[" + items.map(canonicalJSON).joined(separator: ",") + "]"
        case .object(let dict):
            let pairs = dict.keys.sorted().map { key in
                "\(encodeJSONStringLiteral(key)):\(canonicalJSON(dict[key]!))"
            }
            return "{" + pairs.joined(separator: ",") + "}"
        }
    }

    private static func encodeJSONStringLiteral(_ value: String) -> String {
        if let bytes = try? ServerCodec.encode(value) {
            return String(decoding: bytes, as: UTF8.self)
        }
        return "\"\(value)\""
    }

    private static func fingerprintJSON(_ value: JSONValue) -> String {
        let canonical = canonicalJSON(value)
        return ServerCrypto.base64URLEncode(ServerCrypto.sha256Bytes(Array(canonical.utf8)))
    }

    private static func fingerprintEncodable<T: Encodable>(_ value: T) -> String {
        let jsonValue = (try? ServerCodec.toJSONValue(value)) ?? .null
        return fingerprintJSON(jsonValue)
    }
}
