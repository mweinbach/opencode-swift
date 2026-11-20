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
import OpenCodeUtil

/// Live Server-Sent Events (SSE) fan-out hub mirroring `packages/server/src/event-feed.ts`.
public enum EventFeed {
    /// Maximum buffered frames per subscriber before volatile overflow failure.
    // parity: server/src/event-feed.ts#SubscriberCapacity [status=implemented hash=5356aa059587]
    public static let SubscriberCapacity: Int = 4_096

    /// Raised on a subscriber stream when it falls behind by more than `capacity` frames.
    // parity: server/src/event-feed.ts#SubscriberOverflowError [status=implemented hash=1800cbeccb36]
    public struct SubscriberOverflowError: Swift.Error, Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
        public static let tag = "EventFeed.SubscriberOverflow"
        public let capacity: Int

        public init(capacity: Int) {
            self.capacity = capacity
        }

        public var description: String {
            "EventFeed.SubscriberOverflow(capacity: \(capacity))"
        }
    }

    /// Raised when encoding a public event into an SSE frame throws.
    // parity: server/src/event-feed.ts#EncodingError [status=implemented hash=636b65a98743]
    public struct EncodingError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public static let tag = "EventFeed.EncodingError"
        public let eventID: EventSchema.ID
        public let eventType: String
        public let causeDescription: String

        public init(eventID: EventSchema.ID, eventType: String, causeDescription: String) {
            self.eventID = eventID
            self.eventType = eventType
            self.causeDescription = causeDescription
        }

        public var description: String {
            "EventFeed.EncodingError(eventID: \(eventID.rawValue), eventType: \(eventType), cause: \(causeDescription))"
        }
    }

    /// Union of errors surfaced on `EventFeed` streams.
    // parity: server/src/event-feed.ts#Error [status=implemented hash=7b1e86d16f8d]
    public enum Error: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        case subscriberOverflow(SubscriberOverflowError)
        case encoding(EncodingError)

        public var description: String {
            switch self {
            case .subscriberOverflow(let err): return err.description
            case .encoding(let err): return err.description
            }
        }
    }

    /// Subscription interface for `EventFeed`.
    // parity: server/src/event-feed.ts#Interface [status=implemented hash=cc51a96d85b1]
    public protocol Interface: Sendable {
        func subscribe(types: [String]?) -> AsyncThrowingStream<String, Swift.Error>
    }

    public struct Options: Sendable {
        public let capacity: Int?
        public let encode: (@Sendable (OpenCodeEvent) throws -> String)?

        public init(
            capacity: Int? = nil,
            encode: (@Sendable (OpenCodeEvent) throws -> String)? = nil
        ) {
            self.capacity = capacity
            self.encode = encode
        }
    }

    /// Encodes a public `OpenCodeEvent` as a single SSE `data:` frame.
    // parity: server/src/event-feed.ts#frame [status=implemented hash=633d169518cf]
    public static func frame(_ event: OpenCodeEvent) throws -> String {
        let json = try ServerCodec.encodeString(event)
        return "data: \(json)\n\n"
    }

    /// Non-throwing convenience overload returning a JSON-framed SSE event string.
    public static func frameUnsafe(_ event: OpenCodeEvent) -> String {
        (try? frame(event)) ?? "data: {}\n\n"
    }

    /// Bounded async queue implementing exact volatile dropping-overflow semantics per subscriber.
    private final class SubscriberQueue: Sendable {
        private struct QueueState: Sendable {
            var buffer: [String] = []
            var waiters: [CheckedContinuation<String?, Swift.Error>] = []
            var finished = false
            var failure: EventFeed.Error?
        }

        private let capacity: Int
        private let state = Mutex(QueueState())

        init(capacity: Int) {
            self.capacity = max(1, capacity)
        }

        /// Attempts to enqueue one frame without blocking; returns `false` on overflow.
        func offer(_ value: String) -> Bool {
            enum Action {
                case resumeWaiter(CheckedContinuation<String?, Swift.Error>)
                case buffered
                case overflow
                case closed
            }
            let action = state.withLock { s -> Action in
                if s.finished { return .closed }
                if !s.waiters.isEmpty {
                    let waiter = s.waiters.removeFirst()
                    return .resumeWaiter(waiter)
                }
                if s.buffer.count >= capacity {
                    return .overflow
                }
                s.buffer.append(value)
                return .buffered
            }
            switch action {
            case .resumeWaiter(let cont):
                cont.resume(returning: value)
                return true
            case .buffered:
                return true
            case .overflow:
                return false
            case .closed:
                return true
            }
        }

        func fail(_ error: EventFeed.Error) {
            let waiters = state.withLock { s -> [CheckedContinuation<String?, Swift.Error>] in
                guard !s.finished else { return [] }
                s.finished = true
                s.failure = error
                let w = s.waiters
                s.waiters.removeAll()
                return w
            }
            for waiter in waiters {
                waiter.resume(throwing: error)
            }
        }

        func shutdown() {
            let waiters = state.withLock { s -> [CheckedContinuation<String?, Swift.Error>] in
                guard !s.finished else { return [] }
                s.finished = true
                let w = s.waiters
                s.waiters.removeAll()
                return w
            }
            for waiter in waiters {
                waiter.resume(returning: nil)
            }
        }

        func next() async throws -> String? {
            if let immediate = state.withLock({ s -> Result<String?, Swift.Error>? in
                if !s.buffer.isEmpty {
                    return .success(s.buffer.removeFirst())
                }
                if let err = s.failure {
                    return .failure(err)
                }
                if s.finished {
                    return .success(nil)
                }
                return nil
            }) {
                return try immediate.get()
            }

            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { cont in
                    let immediate = state.withLock { s -> Result<String?, Swift.Error>? in
                        if !s.buffer.isEmpty {
                            return .success(s.buffer.removeFirst())
                        }
                        if let err = s.failure {
                            return .failure(err)
                        }
                        if s.finished {
                            return .success(nil)
                        }
                        s.waiters.append(cont)
                        return nil
                    }
                    if let immediate {
                        switch immediate {
                        case .success(let value): cont.resume(returning: value)
                        case .failure(let error): cont.resume(throwing: error)
                        }
                    }
                }
            } onCancel: { [weak self] in
                self?.shutdown()
            }
        }
    }

    /// Process-global `EventFeed` service bridging `CoreBus` events to volatile SSE subscribers.
    // parity: server/src/event-feed.ts#Service [status=implemented hash=e1ab252ba795]
    public final class Service: Interface, Sendable {
        public static let serviceKey = "@opencode/server/EventFeed"

        private struct Entry: Sendable {
            let id: UInt64
            let queue: SubscriberQueue
            let types: Set<String>?
        }

        private struct State: Sendable {
            var nextID: UInt64 = 1
            var subscribers: [UInt64: Entry] = [:]
            var unsubscribe: CoreBus.Unsubscribe?
            var closed = false
        }

        private let capacity: Int
        private let render: @Sendable (OpenCodeEvent) throws -> String
        private let state = Mutex(State())

        public init(
            observe: (@Sendable (@escaping CoreBus.Subscriber) -> CoreBus.Unsubscribe)? = nil,
            options: Options? = nil
        ) {
            self.capacity = options?.capacity ?? EventFeed.SubscriberCapacity
            let defaultRender: @Sendable (OpenCodeEvent) throws -> String = { event in
                try EventFeed.frame(event)
            }
            self.render = options?.encode ?? defaultRender
            if let observe {
                let unsub = observe { [weak self] event in
                    self?.publish(event)
                }
                self.state.withLock { $0.unsubscribe = unsub }
            }
        }

        public func subscribe(types: [String]? = nil) -> AsyncThrowingStream<String, Swift.Error> {
            let filter: Set<String>? = (types?.isEmpty == false) ? Set(types!) : nil
            let queue = SubscriberQueue(capacity: capacity)
            let subID = state.withLock { s -> UInt64 in
                let id = s.nextID
                s.nextID += 1
                if !s.closed {
                    s.subscribers[id] = Entry(id: id, queue: queue, types: filter)
                } else {
                    queue.shutdown()
                }
                return id
            }

            return AsyncThrowingStream { [weak self] in
                do {
                    let item = try await withTaskCancellationHandler {
                        try await queue.next()
                    } onCancel: { [weak self] in
                        self?.removeSubscriber(subID, queue: queue)
                    }
                    if item == nil {
                        self?.removeSubscriber(subID, queue: queue)
                    }
                    return item
                } catch {
                    self?.removeSubscriber(subID, queue: queue)
                    throw error
                }
            }
        }

        /// Publishes a `CoreBus.AnyEvent` into matching subscribers. Non-public events are ignored.
        public func publish(_ event: CoreBus.AnyEvent) {
            guard isOpenCodeEvent(type: event.type) else { return }
            let wire = OpenCodeEvent(
                id: event.id.rawValue,
                type: event.type,
                created: Double(event.created),
                metadata: event.metadata,
                location: event.location,
                data: event.data
            )
            publish(wire)
        }

        /// Publishes a public `OpenCodeEvent` directly into matching subscribers.
        public func publish(_ event: OpenCodeEvent) {
            guard isOpenCodeEvent(event) else { return }
            let snapshot = state.withLock { Array($0.subscribers.values) }
            var encoded: String?

            for entry in snapshot {
                if let types = entry.types, !types.contains(event.type) {
                    continue
                }
                if encoded == nil {
                    do {
                        encoded = try render(event)
                    } catch {
                        let eventID = EventSchema.ID(rawValue: event.id) ?? EventSchema.ID.create()
                        let encodingError = EventFeed.Error.encoding(
                            EncodingError(
                                eventID: eventID,
                                eventType: event.type,
                                causeDescription: String(describing: error)
                            )
                        )
                        failAll(encodingError)
                        return
                    }
                }
                guard let frameString = encoded else { return }
                if entry.queue.offer(frameString) {
                    continue
                }
                state.withLock { _ = $0.subscribers.removeValue(forKey: entry.id) }
                entry.queue.fail(.subscriberOverflow(SubscriberOverflowError(capacity: capacity)))
            }
        }

        public var subscriberCount: Int {
            state.withLock { $0.subscribers.count }
        }

        public func close() async {
            let (unsub, queues) = state.withLock { s -> (CoreBus.Unsubscribe?, [SubscriberQueue]) in
                s.closed = true
                let u = s.unsubscribe
                s.unsubscribe = nil
                let q = s.subscribers.values.map(\.queue)
                s.subscribers.removeAll()
                return (u, q)
            }
            unsub?()
            for q in queues {
                q.shutdown()
            }
        }

        private func removeSubscriber(_ id: UInt64, queue: SubscriberQueue) {
            state.withLock { s in
                _ = s.subscribers.removeValue(forKey: id)
            }
            queue.shutdown()
        }

        private func failAll(_ error: EventFeed.Error) {
            let queues = state.withLock { s -> [SubscriberQueue] in
                let q = s.subscribers.values.map(\.queue)
                s.subscribers.removeAll()
                return q
            }
            for q in queues {
                q.fail(error)
            }
        }
    }

    /// Constructs a live `EventFeed.Service` wired to an event observation source.
    // parity: server/src/event-feed.ts#make [status=implemented hash=9c2a67ba6793]
    public static func make(
        observe: @escaping @Sendable (@escaping CoreBus.Subscriber) -> CoreBus.Unsubscribe,
        options: Options? = nil
    ) -> Service {
        Service(observe: observe, options: options)
    }

    /// Layer node wiring `EventFeed.Service` to `CoreBus.Service`.
    // parity: server/src/event-feed.ts#layer [status=adapted hash=3911bb7720b2]
    public static let layer: LayerNode.ExecutableLayer = LayerNode.ExecutableLayer { deps, scope in
        guard let bus = deps.get(CoreBus.Service.serviceKey, as: CoreBus.Service.self) else {
            let standalone = Service()
            scope.addFinalizer { await standalone.close() }
            return LayerNode.Output([Service.serviceKey: standalone])
        }
        let service = make(observe: { subscriber in bus.listen(subscriber) })
        scope.addFinalizer {
            await service.close()
        }
        return LayerNode.Output([Service.serviceKey: service])
    }
}

// MARK: - SSE Stream Builder (Initial server.connected Frame + Live Feed + 15s Heartbeat)

public enum ServerSSEStream {
    public static let defaultHeartbeatInterval: Swift.Duration = .seconds(15)
    public static let heartbeatFrame = ": heartbeat\n\n"

    public static let sseHeaders: [String: String] = [
        "content-type": "text/event-stream",
        "cache-control": "no-cache, no-transform",
        "x-accel-buffering": "no",
        "x-content-type-options": "nosniff",
    ]

    /// Builds an HTTP SSE streaming response that emits `server.connected` immediately,
    /// forwards filtered `EventFeed` frames, and interleaves `: heartbeat\n\n` frames while open.
    public static func makeResponse(
        feed: any EventFeed.Interface,
        types: [String]? = nil,
        heartbeatInterval: Swift.Duration = defaultHeartbeatInterval
    ) -> ServerHTTPResponse {
        let connected = OpenCodeEvent(
            id: EventSchema.ID.create().rawValue,
            type: "server.connected",
            data: .object([:])
        )
        let connectedBytes = Array(EventFeed.frameUnsafe(connected).utf8)
        let liveStream = feed.subscribe(types: types)

        let byteStream = AsyncThrowingStream<[UInt8], Swift.Error> { continuation in
            continuation.yield(connectedBytes)

            let heartbeatTask = Task {
                let hbBytes = Array(heartbeatFrame.utf8)
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: heartbeatInterval)
                    } catch {
                        break
                    }
                    if Task.isCancelled { break }
                    continuation.yield(hbBytes)
                }
            }

            let feedTask = Task {
                do {
                    for try await frameText in liveStream {
                        if Task.isCancelled { break }
                        continuation.yield(Array(frameText.utf8))
                    }
                    heartbeatTask.cancel()
                    continuation.finish()
                } catch {
                    heartbeatTask.cancel()
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                feedTask.cancel()
                heartbeatTask.cancel()
            }
        }

        return ServerHTTPResponse.stream(
            byteStream,
            statusCode: 200,
            contentType: "text/event-stream",
            headers: sseHeaders
        )
    }
}
