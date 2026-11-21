#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Synchronization
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

/// Durable event-sourced bus with atomic SQLite `event_sequence` + `event` persistence,
/// transactional read-model projections, per-aggregate serialization, location-scoped live routing,
/// and replay-to-live durable log streams.
///
/// Ports `packages/core/src/bus.ts`.
public enum CoreBus {
    /// Any bus event envelope carrying normalized `JSONValue` data.
    public typealias AnyEvent = EventSchema.Payload<JSONValue>

    /// Transactional projector callback executed synchronously inside the SQLite transaction.
    public typealias Projector = @Sendable (AnyEvent) throws -> Void

    /// Live event listener callback invoked after commit.
    // parity: core/src/bus.ts#Subscriber [status=implemented hash=1371810092c4]
    public typealias Subscriber = @Sendable (AnyEvent) async -> Void

    /// Handle releasing a live listener or subscription.
    // parity: core/src/bus.ts#Unsubscribe [status=implemented hash=6745b958e4b7]
    public typealias Unsubscribe = @Sendable () -> Void

    /// Wire/storage representation of a persisted durable event.
    // parity: core/src/bus.ts#SerializedEvent [status=implemented hash=d0b22184a0ab]
    public struct SerializedEvent: Equatable, Hashable, Sendable, Codable {
        public let id: EventSchema.ID
        public let type: String
        public let created: Int64?
        public let seq: Int64
        public let aggregateID: String
        public let data: [String: JSONValue]

        public init(
            id: EventSchema.ID,
            type: String,
            created: Int64? = nil,
            seq: Int64,
            aggregateID: String,
            data: [String: JSONValue]
        ) {
            self.id = id
            self.type = type
            self.created = created
            self.seq = seq
            self.aggregateID = aggregateID
            self.data = data
        }
    }

    /// Fatal validation or replay divergence error on durable event operations.
    // parity: core/src/bus.ts#InvalidDurableEventError [status=implemented hash=dd1aceecf4b5]
    public struct InvalidDurableEventError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public static let tag = "Bus.InvalidDurableEvent"
        public let type: String
        public let message: String

        public init(type: String, message: String) {
            self.type = type
            self.message = message
        }

        public var description: String { "\(Self.tag)(\(type)): \(message)" }
    }

    /// Formats a durable event versioned key `<type>.<version>`.
    // parity: core/src/bus.ts#versionedType [status=implemented hash=8c6cac5db549]
    public static func versionedType(_ type: String, version: Int) -> String {
        EventSchema.versionedType(type, version: version)
    }

    /// Constructs a strongly typed durable event definition (`Bus.durable`).
    // parity: core/src/bus.ts#durable [status=implemented hash=4914b8fea9b4]
    public static func durable<EventData: Equatable & Hashable & Sendable & Codable>(
        type: String,
        identifier: String? = nil,
        aggregate: String,
        version: Int,
        data: EventData.Type = EventData.self
    ) -> EventSchema.DurableDefinition<EventData> {
        EventSchema.durable(type: type, identifier: identifier, aggregate: aggregate, version: version, data: data)
    }

    /// Constructs a strongly typed ephemeral event definition (`Bus.ephemeral`).
    // parity: core/src/bus.ts#ephemeral [status=implemented hash=c636776cc98b]
    public static func ephemeral<EventData: Equatable & Hashable & Sendable & Codable>(
        type: String,
        identifier: String? = nil,
        data: EventData.Type = EventData.self
    ) -> EventSchema.EphemeralDefinition<EventData> {
        EventSchema.ephemeral(type: type, identifier: identifier, data: data)
    }

    /// Options controlling event publication, metadata, location routing, and transactional commit hooks.
    // parity: core/src/bus.ts#PublishOptions [status=implemented hash=4402c4c79377]
    public struct PublishOptions: Sendable {
        public let id: EventSchema.ID?
        public let metadata: [String: JSONValue]?
        public let location: OpenCodeLocation?
        public let global: Bool
        /// Local operational projection committed atomically with a new durable event. Not replayed or serialized.
        public let commit: (@Sendable (Int64) throws -> Void)?

        public init(
            id: EventSchema.ID? = nil,
            metadata: [String: JSONValue]? = nil,
            location: OpenCodeLocation? = nil,
            global: Bool = false,
            commit: (@Sendable (Int64) throws -> Void)? = nil
        ) {
            self.id = id
            self.metadata = metadata
            self.location = location
            self.global = global
            self.commit = commit
        }
    }

    /// Single durable event input for atomic batch publication via `publishAll`.
    // parity: core/src/bus.ts#PublishInput [status=implemented hash=e818663b9ca8]
    public struct PublishInput: Sendable {
        public let definition: EventSchema.Definition
        public let data: JSONValue
        public let options: PublishOptions?

        public init(definition: EventSchema.Definition, data: JSONValue, options: PublishOptions? = nil) {
            self.definition = definition
            self.data = data
            self.options = options
        }

        public static func make<EventData: Equatable & Hashable & Sendable & Codable>(
            _ definition: EventSchema.DurableDefinition<EventData>,
            data: EventData,
            options: PublishOptions? = nil
        ) throws -> PublishInput {
            let encoded = try CoreBusJSON.encodeToJSONValue(data)
            return PublishInput(definition: definition.descriptor, data: encoded, options: options)
        }
    }

    /// Batch publication result array.
    // parity: core/src/bus.ts#PublishResult [status=implemented hash=58c8717f90b9]
    public typealias PublishResult = [AnyEvent]

    /// Replay / live log stream item union (`Event.Payload | EventLog.Synced`).
    // parity: core/src/bus.ts#LogItem [status=implemented hash=4a1978d0a41d]
    public enum LogItem: Equatable, Hashable, Sendable {
        case event(AnyEvent)
        case synced(EventLogSchema.Synced)
    }

    /// Type predicate testing whether a `LogItem` is the replay-to-live `log.synced` boundary marker.
    // parity: core/src/bus.ts#isSynced [status=implemented hash=48c4e36edee7]
    public static func isSynced(_ item: LogItem) -> Bool {
        if case .synced = item { return true }
        return false
    }

    /// Payload type emitted by a live subscription.
    // parity: core/src/bus.ts#SubscribePayload [status=implemented hash=f93deaf043b3]
    public typealias SubscribePayload = AnyEvent

    /// Subscription factory interface (`Bus.Subscribe`).
    // parity: core/src/bus.ts#Subscribe [status=implemented hash=3782d35d4192]
    public protocol Subscribe: Sendable {
        func subscribe(location: OpenCodeLocation?) -> AsyncStream<SubscribePayload>
        func subscribe(types: Set<String>, location: OpenCodeLocation?) -> AsyncStream<SubscribePayload>
    }

    public struct ReplayOptions: Equatable, Sendable {
        public let publish: Bool
        public let ownerID: String?
        public let strictOwner: Bool

        public init(publish: Bool = false, ownerID: String? = nil, strictOwner: Bool = false) {
            self.publish = publish
            self.ownerID = ownerID
            self.strictOwner = strictOwner
        }
    }

    public struct LogInput: Equatable, Sendable {
        public let aggregateID: String
        public let after: Int64?
        public let follow: Bool

        public init(aggregateID: String, after: Int64? = nil, follow: Bool = false) {
            self.aggregateID = aggregateID
            self.after = after
            self.follow = follow
        }
    }

    public struct Options: Sendable {
        public let beforeAggregateRead: (@Sendable (String) async -> Void)?
        public let logReadPageSize: Int
        public let persist: Bool

        public init(
            beforeAggregateRead: (@Sendable (String) async -> Void)? = nil,
            logReadPageSize: Int = 512,
            persist: Bool = false
        ) {
            self.beforeAggregateRead = beforeAggregateRead
            self.logReadPageSize = max(1, logReadPageSize)
            self.persist = persist
        }
    }

    /// Reads the latest durable sequence for `aggregateID` (or `-1` if no sequence row exists).
    // parity: core/src/bus.ts#latestSequence [status=implemented hash=3d1293366748]
    public static func latestSequence(db: any SQLiteDatabase, aggregateID: String) throws -> Int64 {
        let row = try db.queryOne(
            "SELECT `seq` FROM `event_sequence` WHERE `aggregate_id` = ?",
            parameters: [.text(aggregateID)]
        )
        return row?.int64("seq") ?? -1
    }

    /// Reserves an inherited sequence watermark on `event_sequence` (`seq = max(seq, reserved)`).
    // parity: core/src/bus.ts#reserveSequence [status=implemented hash=f357a239d837]
    public static func reserveSequence(db: any SQLiteDatabase, aggregateID: String, seq: Int64) throws {
        _ = try db.execute(
            """
            INSERT INTO `event_sequence` (`aggregate_id`, `seq`)
            VALUES (?, ?)
            ON CONFLICT (`aggregate_id`) DO UPDATE SET `seq` = max(`event_sequence`.`seq`, excluded.`seq`)
            """,
            parameters: [.text(aggregateID), .integer(seq)]
        )
    }

    /// Canonical event bus service contract (`Bus.Interface`).
    // parity: core/src/bus.ts#Interface [status=implemented hash=879f0f61dc45]
    public protocol Interface: Subscribe, Sendable {
        func publishRaw(
            definition: EventSchema.Definition,
            data: JSONValue,
            options: PublishOptions?
        ) async throws -> AnyEvent
        func publishAll(_ events: [PublishInput]) async throws -> PublishResult
        func log(_ input: LogInput) -> AsyncStream<LogItem>
        func listen(_ listener: @escaping Subscriber) -> Unsubscribe
        func project(definition: EventSchema.Definition, projector: @escaping Projector)
        func replay(_ event: SerializedEvent, options: ReplayOptions) async throws
        func remove(aggregateID: String) async throws
        func claim(aggregateID: String, ownerID: String) throws
    }

    /// Concrete process-global Event Bus implementation backed by `SQLiteDatabase`.
    // parity: core/src/bus.ts#Service [status=implemented hash=66207d5f6956]
    public final class Service: Interface, @unchecked Sendable {
        public static let serviceKey = "@opencode/Bus"

        private struct LiveSub: Sendable {
            let id: UInt64
            let types: Set<String>?
            let location: OpenCodeLocation?
            let continuation: AsyncStream<SubscribePayload>.Continuation
        }

        private struct ListenerEntry: Sendable {
            let id: UInt64
            let callback: Subscriber
        }

        private struct DurableWake: Sendable {
            let id: UInt64
            let continuation: AsyncStream<Void>.Continuation
        }

        private struct MutableState: Sendable {
            var nextID: UInt64 = 1
            var projectors: [String: [Projector]] = [:]
            var listeners: [ListenerEntry] = []
            var liveSubs: [LiveSub] = []
            var durableWakes: [String: [DurableWake]] = [:]
            var sessionRoutes: [String: OpenCodeLocation] = [:]
        }

        public let db: any SQLiteDatabase
        public let options: Options

        private final class LockBox: Sendable {
            let mutex = Mutex(())
        }

        private let state = Mutex(MutableState())
        private let aggregateLocks = Mutex<[String: LockBox]>([:])

        private static let sessionEventTypes: Set<String> = Set(SessionEventSchema.All.map(\.type))

        public init(db: any SQLiteDatabase, options: Options = Options()) {
            self.db = db
            self.options = options
        }

        // MARK: Typed Conveniences

        @discardableResult
        public func publish<EventData: Equatable & Hashable & Sendable & Codable>(
            _ definition: EventSchema.DurableDefinition<EventData>,
            data: EventData,
            options: PublishOptions? = nil
        ) async throws -> EventSchema.DurableEventEnvelope<EventData> {
            let encoded = try CoreBusJSON.encodeToJSONValue(data)
            let raw = try await publishRaw(definition: definition.descriptor, data: encoded, options: options)
            guard case .durable(let env) = raw else {
                throw InvalidDurableEventError(type: definition.type, message: "Durable publish returned ephemeral payload")
            }
            return EventSchema.DurableEventEnvelope(
                id: env.id,
                created: env.created,
                metadata: env.metadata,
                type: env.type,
                durable: env.durable,
                location: env.location,
                data: data
            )
        }

        @discardableResult
        public func publish<EventData: Equatable & Hashable & Sendable & Codable>(
            _ definition: EventSchema.EphemeralDefinition<EventData>,
            data: EventData,
            options: PublishOptions? = nil
        ) async throws -> EventSchema.EphemeralEventEnvelope<EventData> {
            let encoded = try CoreBusJSON.encodeToJSONValue(data)
            let raw = try await publishRaw(definition: definition.descriptor, data: encoded, options: options)
            guard case .ephemeral(let env) = raw else {
                throw InvalidDurableEventError(type: definition.type, message: "Ephemeral publish returned durable payload")
            }
            return EventSchema.EphemeralEventEnvelope(
                id: env.id,
                created: env.created,
                metadata: env.metadata,
                type: env.type,
                location: env.location,
                data: data
            )
        }

        public func emit<EventData: Equatable & Hashable & Sendable & Codable>(
            _ definition: EventSchema.EphemeralDefinition<EventData>,
            data: EventData,
            options: PublishOptions? = nil
        ) async {
            _ = try? await publish(definition, data: data, options: options)
        }

        public func project<EventData: Equatable & Hashable & Sendable & Codable>(
            _ definition: EventSchema.DurableDefinition<EventData>,
            projector: @escaping @Sendable (EventSchema.DurableEventEnvelope<EventData>) throws -> Void
        ) {
            project(definition: definition.descriptor) { payload in
                guard case .durable(let env) = payload else { return }
                let decoded: EventData = try CoreBusJSON.decodeFromJSONValue(env.data, as: EventData.self)
                try projector(EventSchema.DurableEventEnvelope(
                    id: env.id,
                    created: env.created,
                    metadata: env.metadata,
                    type: env.type,
                    durable: env.durable,
                    location: env.location,
                    data: decoded
                ))
            }
        }

        public func project(definition: EventSchema.Definition, projector: @escaping Projector) {
            let key = definition.durable.map { CoreBus.versionedType(definition.type, version: $0.version) }
                ?? definition.type
            state.withLock { s in
                s.projectors[key, default: []].append(projector)
            }
        }

        // MARK: Publish

        public func publishRaw(
            definition: EventSchema.Definition,
            data: JSONValue,
            options: PublishOptions? = nil
        ) async throws -> AnyEvent {
            if definition.durability == .ephemeral && options?.commit != nil {
                throw InvalidDurableEventError(
                    type: definition.type,
                    message: "Local commit hooks require a durable event"
                )
            }

            let eventID = options?.id ?? EventSchema.ID.create()
            let created = Flock.currentEpochMs()
            let location: OpenCodeLocation? = (options?.global == true) ? nil : options?.location

            if let durableSpec = definition.durable {
                let aggregateID = try requireAggregateID(
                    type: definition.type,
                    aggregateField: durableSpec.aggregate,
                    data: data
                )
                let (committed, routes) = try withAggregateLock(aggregateID) {
                    try commitDurableSync(
                        definition: definition,
                        durableSpec: durableSpec,
                        eventID: eventID,
                        created: created,
                        metadata: options?.metadata,
                        location: location,
                        data: data,
                        replayInput: nil,
                        commitHook: options?.commit
                    )
                }
                guard let committed else {
                    throw InvalidDurableEventError(type: definition.type, message: "Durable commit produced no event")
                }
                wakeDurableSubscribers(for: aggregateID)
                await notify(event: committed, routes: routes, isolateListeners: true)
                return committed
            }

            let ephemeralEnvelope = EventSchema.EphemeralEventEnvelope(
                id: eventID,
                created: created,
                metadata: options?.metadata,
                type: definition.type,
                location: location,
                data: data
            )
            let payload: AnyEvent = .ephemeral(ephemeralEnvelope)
            let (routeUpdate, resolvedRoutes) = try prepareRoutes(for: [payload])
            applyRouteUpdates(routeUpdate)
            await notify(event: payload, routes: resolvedRoutes[eventID], isolateListeners: false)
            return payload
        }

        public func publishAll(_ events: [PublishInput]) async throws -> PublishResult {
            guard !events.isEmpty else { return [] }

            struct PreparedItem {
                let definition: EventSchema.Definition
                let durableSpec: EventSchema.DurableSpec
                let aggregateID: String
                let eventID: EventSchema.ID
                let created: Int64
                let metadata: [String: JSONValue]?
                let location: OpenCodeLocation?
                let data: JSONValue
                let commit: (@Sendable (Int64) throws -> Void)?
            }

            var prepared: [PreparedItem] = []
            prepared.reserveCapacity(events.count)
            for item in events {
                guard let spec = item.definition.durable else {
                    throw InvalidDurableEventError(
                        type: item.definition.type,
                        message: "publishAll requires durable events"
                    )
                }
                let aggID = try requireAggregateID(
                    type: item.definition.type,
                    aggregateField: spec.aggregate,
                    data: item.data
                )
                let opts = item.options
                prepared.append(PreparedItem(
                    definition: item.definition,
                    durableSpec: spec,
                    aggregateID: aggID,
                    eventID: opts?.id ?? EventSchema.ID.create(),
                    created: Flock.currentEpochMs(),
                    metadata: opts?.metadata,
                    location: (opts?.global == true) ? nil : opts?.location,
                    data: item.data,
                    commit: opts?.commit
                ))
            }

            let aggregateID = prepared[0].aggregateID
            if prepared.contains(where: { $0.aggregateID != aggregateID }) {
                throw InvalidDurableEventError(
                    type: prepared[0].definition.type,
                    message: "Published events must belong to the same aggregate"
                )
            }

            let (committedEvents, routeMap) = try withAggregateLock(aggregateID) { () -> ([AnyEvent], [EventSchema.ID: [OpenCodeLocation]]) in
                var routeUpdates: [String: OpenCodeLocation?] = [:]
                var resolvedRoutes: [EventSchema.ID: [OpenCodeLocation]] = [:]

                let committed: [AnyEvent] = try db.transaction {
                    let latest = try CoreBus.latestSequence(db: db, aggregateID: aggregateID)
                    let firstSeq = latest + 1
                    let finalSeq = firstSeq + Int64(prepared.count) - 1

                    var queued: [AnyEvent] = []
                    queued.reserveCapacity(prepared.count)
                    for (idx, item) in prepared.enumerated() {
                        let seq = EventSchema.Seq(rawValue: firstSeq + Int64(idx))!
                        let version = EventSchema.Version(rawValue: item.durableSpec.version) ?? EventSchema.Version(rawValue: 1)!
                        let env = EventSchema.DurableEventEnvelope(
                            id: item.eventID,
                            created: item.created,
                            metadata: item.metadata,
                            type: item.definition.type,
                            durable: EventSchema.DurableEnvelope(
                                aggregateID: aggregateID,
                                seq: seq,
                                version: version
                            ),
                            location: item.location,
                            data: item.data
                        )
                        queued.append(.durable(env))
                    }

                    let (updates, routes) = try prepareRoutes(for: queued)
                    routeUpdates = updates
                    resolvedRoutes = routes

                    var seenIDs = Set<EventSchema.ID>()
                    var persistRows: [(id: String, seq: Int64, created: Int64, type: String, dataJSON: String)] = []

                    for (idx, item) in prepared.enumerated() {
                        let seq = firstSeq + Int64(idx)
                        if options.persist {
                            if !seenIDs.insert(item.eventID).inserted {
                                throw InvalidDurableEventError(
                                    type: item.definition.type,
                                    message: "Event \(item.eventID.rawValue) appears more than once in the batch"
                                )
                            }
                            if let existing = try db.queryOne(
                                "SELECT `aggregate_id`, `seq` FROM `event` WHERE `id` = ?",
                                parameters: [.text(item.eventID.rawValue)]
                            ) {
                                let existingAgg = existing.string("aggregate_id") ?? ""
                                let existingSeq = existing.int64("seq") ?? 0
                                throw InvalidDurableEventError(
                                    type: item.definition.type,
                                    message: "Event \(item.eventID.rawValue) already exists at aggregate \(existingAgg) sequence \(existingSeq)"
                                )
                            }
                        }

                        let eventPayload = queued[idx]
                        let vType = CoreBus.versionedType(item.definition.type, version: item.durableSpec.version)
                        let projs = state.withLock { $0.projectors[vType] ?? [] }
                        for projector in projs {
                            try projector(eventPayload)
                        }
                        if let commitHook = item.commit {
                            try commitHook(seq)
                        }
                        if options.persist {
                            let jsonStr = try CoreBusJSON.encodeJSONValue(item.data)
                            persistRows.append((item.eventID.rawValue, seq, item.created, vType, jsonStr))
                        }
                    }

                    _ = try db.execute(
                        """
                        INSERT INTO `event_sequence` (`aggregate_id`, `seq`)
                        VALUES (?, ?)
                        ON CONFLICT (`aggregate_id`) DO UPDATE SET `seq` = excluded.`seq`
                        """,
                        parameters: [.text(aggregateID), .integer(finalSeq)]
                    )
                    if options.persist {
                        for row in persistRows {
                            _ = try db.execute(
                                """
                                INSERT INTO `event` (`id`, `aggregate_id`, `seq`, `created`, `type`, `data`)
                                VALUES (?, ?, ?, ?, ?, ?)
                                """,
                                parameters: [
                                    .text(row.id),
                                    .text(aggregateID),
                                    .integer(row.seq),
                                    .integer(row.created),
                                    .text(row.type),
                                    .text(row.dataJSON),
                                ]
                            )
                        }
                    }
                    return queued
                }

                applyRouteUpdates(routeUpdates)
                return (committed, resolvedRoutes)
            }

            wakeDurableSubscribers(for: aggregateID)
            for event in committedEvents {
                await notify(event: event, routes: routeMap[event.id], isolateListeners: true)
            }
            return committedEvents
        }

        // MARK: Replay / Remove / Claim

        public func replay(_ event: SerializedEvent, options replayOptions: ReplayOptions = ReplayOptions()) async throws {
            guard let definition = DurableEventManifestSchema.Durable[event.type],
                  let durableSpec = definition.durable
            else {
                throw InvalidDurableEventError(
                    type: event.type,
                    message: "Unknown durable event type \(event.type)"
                )
            }

            let upgraded = SessionLegacySchema.event(type: definition.type, data: .object(event.data))
            let (committed, routes) = try withAggregateLock(event.aggregateID) {
                try commitDurableSync(
                    definition: definition,
                    durableSpec: durableSpec,
                    eventID: event.id,
                    created: event.created ?? 0,
                    metadata: nil,
                    location: nil,
                    data: upgraded,
                    replayInput: ReplayCommitInput(
                        seq: event.seq,
                        aggregateID: event.aggregateID,
                        ownerID: replayOptions.ownerID,
                        strictOwner: replayOptions.strictOwner
                    ),
                    commitHook: nil
                )
            }

            if let committed {
                wakeDurableSubscribers(for: event.aggregateID)
                if replayOptions.publish {
                    await notify(event: committed, routes: routes, isolateListeners: true)
                }
            }
        }

        public func remove(aggregateID: String) async throws {
            try withAggregateLock(aggregateID) {
                try db.transaction {
                    _ = try db.execute(
                        "DELETE FROM `event_sequence` WHERE `aggregate_id` = ?",
                        parameters: [.text(aggregateID)]
                    )
                    _ = try db.execute(
                        "DELETE FROM `event` WHERE `aggregate_id` = ?",
                        parameters: [.text(aggregateID)]
                    )
                }
                state.withLock { s in
                    _ = s.sessionRoutes.removeValue(forKey: aggregateID)
                }
            }
        }

        public func claim(aggregateID: String, ownerID: String) throws {
            _ = try db.execute(
                "UPDATE `event_sequence` SET `owner_id` = ? WHERE `aggregate_id` = ?",
                parameters: [.text(ownerID), .text(aggregateID)]
            )
        }

        // MARK: Subscriptions & Durable Log

        public func subscribe(location: OpenCodeLocation? = nil) -> AsyncStream<SubscribePayload> {
            makeSubscription(types: nil, location: location)
        }

        public func subscribe(types: Set<String>, location: OpenCodeLocation? = nil) -> AsyncStream<SubscribePayload> {
            makeSubscription(types: types, location: location)
        }

        public func listen(_ listener: @escaping Subscriber) -> Unsubscribe {
            let id = state.withLock { s -> UInt64 in
                let next = s.nextID
                s.nextID += 1
                s.listeners.append(ListenerEntry(id: next, callback: listener))
                return next
            }
            return { [weak self] in
                self?.state.withLock { s in
                    s.listeners.removeAll { $0.id == id }
                }
            }
        }

        public func log(_ input: LogInput) -> AsyncStream<LogItem> {
            AsyncStream { continuation in
                let task = Task {
                    var wakeStream: AsyncStream<Void>?
                    var wakeSubID: UInt64?
                    if input.follow {
                        let (stream, subID) = registerDurableWake(for: input.aggregateID)
                        wakeStream = stream
                        wakeSubID = subID
                    }
                    defer {
                        if let wakeSubID {
                            unregisterDurableWake(for: input.aggregateID, id: wakeSubID)
                        }
                    }

                    var cursor = input.after ?? -1
                    let readThrough: (Int64) async -> Void = { through in
                        while cursor < through && !Task.isCancelled {
                            if let before = self.options.beforeAggregateRead {
                                await before(input.aggregateID)
                            }
                            guard let rows = try? self.db.query(
                                """
                                SELECT `id`, `aggregate_id`, `seq`, `created`, `type`, `data`
                                FROM `event`
                                WHERE `aggregate_id` = ? AND `seq` > ? AND `seq` <= ?
                                ORDER BY `seq` ASC
                                LIMIT ?
                                """,
                                parameters: [
                                    .text(input.aggregateID),
                                    .integer(cursor),
                                    .integer(through),
                                    .integer(Int64(self.options.logReadPageSize)),
                                ]
                            ) else { break }

                            if rows.isEmpty { break }
                            for row in rows {
                                guard let seq = row.int64("seq") else { continue }
                                cursor = seq
                                guard let eventType = row.string("type"),
                                      let definition = DurableEventManifestSchema.Durable[eventType],
                                      let durableSpec = definition.durable,
                                      let idStr = row.string("id"),
                                      let eventID = EventSchema.ID(rawValue: idStr),
                                      let aggID = row.string("aggregate_id"),
                                      let rawJSON = row.string("data"),
                                      let decodedJSON = try? CoreBusJSON.decodeJSONValue(rawJSON)
                                else { continue }

                                let created = row.int64("created") ?? 0
                                let upgraded = SessionLegacySchema.event(type: definition.type, data: decodedJSON)
                                let seqVal = EventSchema.Seq(rawValue: seq) ?? EventSchema.Seq(rawValue: 0)!
                                let verVal = EventSchema.Version(rawValue: durableSpec.version) ?? EventSchema.Version(rawValue: 1)!
                                let env = EventSchema.DurableEventEnvelope(
                                    id: eventID,
                                    created: created,
                                    metadata: nil,
                                    type: definition.type,
                                    durable: EventSchema.DurableEnvelope(
                                        aggregateID: aggID,
                                        seq: seqVal,
                                        version: verVal
                                    ),
                                    location: nil,
                                    data: upgraded
                                )
                                continuation.yield(.event(.durable(env)))
                            }
                            if rows.count < self.options.logReadPageSize { break }
                        }
                    }

                    let target = (try? CoreBus.latestSequence(db: self.db, aggregateID: input.aggregateID)) ?? -1
                    await readThrough(target)
                    let markerSeq = target >= 0 ? EventSchema.Seq(rawValue: target) : nil
                    continuation.yield(.synced(EventLogSchema.Synced(aggregateID: input.aggregateID, seq: markerSeq)))

                    if let wakeStream {
                        for await _ in wakeStream {
                            if Task.isCancelled { break }
                            let nextTarget = (try? CoreBus.latestSequence(db: self.db, aggregateID: input.aggregateID)) ?? -1
                            if nextTarget > cursor {
                                await readThrough(nextTarget)
                            }
                        }
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in
                    task.cancel()
                }
            }
        }

        // MARK: Internal Commit & Routing

        private struct ReplayCommitInput {
            let seq: Int64
            let aggregateID: String
            let ownerID: String?
            let strictOwner: Bool
        }

        private func commitDurableSync(
            definition: EventSchema.Definition,
            durableSpec: EventSchema.DurableSpec,
            eventID: EventSchema.ID,
            created: Int64,
            metadata: [String: JSONValue]?,
            location: OpenCodeLocation?,
            data: JSONValue,
            replayInput: ReplayCommitInput?,
            commitHook: (@Sendable (Int64) throws -> Void)?
        ) throws -> (AnyEvent?, [OpenCodeLocation]?) {
            let aggregateID = try requireAggregateID(
                type: definition.type,
                aggregateField: durableSpec.aggregate,
                data: data
            )
            if let replayInput, replayInput.aggregateID != aggregateID {
                throw InvalidDurableEventError(
                    type: definition.type,
                    message: "Aggregate mismatch: expected \(replayInput.aggregateID), got \(aggregateID)"
                )
            }

            let vType = CoreBus.versionedType(definition.type, version: durableSpec.version)
            let projs = state.withLock { $0.projectors[vType] ?? [] }
            var routeUpdates: [String: OpenCodeLocation?] = [:]
            var resolvedRoutes: [OpenCodeLocation]? = nil

            let committed: AnyEvent? = try db.transaction {
                let seqRow = try db.queryOne(
                    "SELECT `seq`, `owner_id` FROM `event_sequence` WHERE `aggregate_id` = ?",
                    parameters: [.text(aggregateID)]
                )
                let latest = seqRow?.int64("seq") ?? -1
                let existingOwner = seqRow?.string("owner_id")

                if let replayInput, replayInput.strictOwner,
                   let existingOwner, existingOwner != replayInput.ownerID
                {
                    throw InvalidDurableEventError(
                        type: definition.type,
                        message: "Replay owner mismatch for aggregate \(aggregateID): expected \(existingOwner), got \(replayInput.ownerID ?? "none")"
                    )
                }

                if let replayInput, replayInput.seq <= latest {
                    if !options.persist { return nil }
                    let stored = try db.queryOne(
                        "SELECT `id`, `type`, `created`, `data` FROM `event` WHERE `aggregate_id` = ? AND `seq` = ?",
                        parameters: [.text(aggregateID), .integer(replayInput.seq)]
                    )
                    if let stored,
                       stored.string("id") == eventID.rawValue,
                       stored.string("type") == vType,
                       stored.int64("created") == created,
                       let storedRaw = stored.string("data"),
                       let storedJSON = try? CoreBusJSON.decodeJSONValue(storedRaw),
                       SessionLegacySchema.event(type: definition.type, data: storedJSON) == data
                    {
                        if let newOwner = replayInput.ownerID, existingOwner == nil {
                            _ = try db.execute(
                                "UPDATE `event_sequence` SET `owner_id` = ? WHERE `aggregate_id` = ?",
                                parameters: [.text(newOwner), .text(aggregateID)]
                            )
                        }
                        return nil
                    }
                    throw InvalidDurableEventError(
                        type: definition.type,
                        message: "Replay diverged at aggregate \(aggregateID) sequence \(replayInput.seq)"
                    )
                }

                if let replayInput, let existingOwner, existingOwner != replayInput.ownerID {
                    return nil
                }

                let seq = replayInput?.seq ?? (latest + 1)
                if replayInput != nil && seq != latest + 1 {
                    throw InvalidDurableEventError(
                        type: definition.type,
                        message: "Sequence mismatch for aggregate \(aggregateID): expected \(latest + 1), got \(seq)"
                    )
                }

                if options.persist {
                    if let dup = try db.queryOne(
                        "SELECT `aggregate_id`, `seq` FROM `event` WHERE `id` = ?",
                        parameters: [.text(eventID.rawValue)]
                    ) {
                        let dupAgg = dup.string("aggregate_id") ?? ""
                        let dupSeq = dup.int64("seq") ?? 0
                        throw InvalidDurableEventError(
                            type: definition.type,
                            message: "Event \(eventID.rawValue) already exists at aggregate \(dupAgg) sequence \(dupSeq)"
                        )
                    }
                }

                let seqObj = EventSchema.Seq(rawValue: seq) ?? EventSchema.Seq(rawValue: 0)!
                let verObj = EventSchema.Version(rawValue: durableSpec.version) ?? EventSchema.Version(rawValue: 1)!
                let committedEnvelope = EventSchema.DurableEventEnvelope(
                    id: eventID,
                    created: created,
                    metadata: metadata,
                    type: definition.type,
                    durable: EventSchema.DurableEnvelope(
                        aggregateID: aggregateID,
                        seq: seqObj,
                        version: verObj
                    ),
                    location: location,
                    data: data
                )
                let committedPayload: AnyEvent = .durable(committedEnvelope)

                let (updates, routes) = try prepareRoutes(for: [committedPayload])
                routeUpdates = updates
                resolvedRoutes = routes[eventID]

                for projector in projs {
                    try projector(committedPayload)
                }
                if let commitHook {
                    try commitHook(seq)
                }

                let ownerParam: SQLiteValue = replayInput?.ownerID.map(SQLiteValue.text) ?? .null
                if let newOwner = replayInput?.ownerID, existingOwner == nil {
                    _ = try db.execute(
                        """
                        INSERT INTO `event_sequence` (`aggregate_id`, `seq`, `owner_id`)
                        VALUES (?, ?, ?)
                        ON CONFLICT (`aggregate_id`) DO UPDATE SET
                          `seq` = max(`event_sequence`.`seq`, excluded.`seq`),
                          `owner_id` = ?
                        """,
                        parameters: [.text(aggregateID), .integer(seq), ownerParam, .text(newOwner)]
                    )
                } else {
                    _ = try db.execute(
                        """
                        INSERT INTO `event_sequence` (`aggregate_id`, `seq`, `owner_id`)
                        VALUES (?, ?, ?)
                        ON CONFLICT (`aggregate_id`) DO UPDATE SET
                          `seq` = max(`event_sequence`.`seq`, excluded.`seq`)
                        """,
                        parameters: [.text(aggregateID), .integer(seq), ownerParam]
                    )
                }

                if options.persist {
                    let dataJSON = try CoreBusJSON.encodeJSONValue(data)
                    _ = try db.execute(
                        """
                        INSERT INTO `event` (`id`, `aggregate_id`, `seq`, `created`, `type`, `data`)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """,
                        parameters: [
                            .text(eventID.rawValue),
                            .text(aggregateID),
                            .integer(seq),
                            .integer(created),
                            .text(vType),
                            .text(dataJSON),
                        ]
                    )
                }
                return committedPayload
            }

            if committed != nil {
                applyRouteUpdates(routeUpdates)
            }
            return (committed, resolvedRoutes)
        }

        private func requireAggregateID(type: String, aggregateField: String, data: JSONValue) throws -> String {
            guard case .object(let dict) = data,
                  case .string(let aggregateID) = dict[aggregateField]
            else {
                throw InvalidDurableEventError(
                    type: type,
                    message: "Expected string aggregate field \(aggregateField)"
                )
            }
            return aggregateID
        }

        private func withAggregateLock<T>(_ aggregateID: String, _ body: () throws -> T) rethrows -> T {
            let lock = aggregateLocks.withLock { map -> LockBox in
                if let existing = map[aggregateID] { return existing }
                let created = LockBox()
                map[aggregateID] = created
                return created
            }
            return try lock.mutex.withLock { _ in try body() }
        }

        private func prepareRoutes(
            for events: [AnyEvent]
        ) throws -> ([String: OpenCodeLocation?], [EventSchema.ID: [OpenCodeLocation]]) {
            var updates: [String: OpenCodeLocation?] = [:]
            var resolved: [EventSchema.ID: [OpenCodeLocation]] = [:]
            let cachedRoutes = state.withLock { $0.sessionRoutes }

            for event in events {
                guard Self.sessionEventTypes.contains(event.type),
                      case .object(let dict) = event.data,
                      case .string(let sessionID) = dict["sessionID"]
                else { continue }

                if event.type == SessionEventSchema.Created.type {
                    if let loc = decodeLocation(dict["location"]) {
                        updates[sessionID] = loc
                        resolved[event.id] = [event.location ?? loc]
                    }
                    continue
                }
                if event.location != nil
                    && event.type != SessionEventSchema.Forked.type
                    && event.type != SessionEventSchema.Moved.type
                {
                    if event.type == SessionEventSchema.Deleted.type {
                        updates[sessionID] = .some(nil)
                    }
                    continue
                }

                let ownerID: String = {
                    if event.type == SessionEventSchema.Forked.type,
                       case .string(let parentID) = dict["parentID"]
                    {
                        return parentID
                    }
                    return sessionID
                }()

                var ownerLocation: OpenCodeLocation?
                if let updated = updates[ownerID] {
                    ownerLocation = updated
                } else if let cached = cachedRoutes[ownerID] {
                    ownerLocation = cached
                } else if let row = try db.queryOne(
                    "SELECT `directory`, `workspace_id` FROM `session_v2` WHERE `id` = ?",
                    parameters: [.text(ownerID)]
                ), let dir = row.string("directory") {
                    let ws = row.string("workspace_id").flatMap(WorkspaceID.init(rawValue:))
                    let loc = OpenCodeLocation(directory: dir, workspaceID: ws)
                    ownerLocation = loc
                    updates[ownerID] = loc
                } else {
                    updates[ownerID] = .some(nil)
                }

                if event.type == SessionEventSchema.Moved.type, let dest = decodeLocation(dict["location"]) {
                    // Both old and new locations receive session.moved.
                    updates[sessionID] = dest
                    resolved[event.id] = ownerLocation.map { [$0, dest] } ?? [dest]
                    continue
                }
                if event.type == SessionEventSchema.Forked.type {
                    updates[sessionID] = ownerLocation
                }
                if let explicit = event.location {
                    resolved[event.id] = [explicit]
                } else if let ownerLocation {
                    resolved[event.id] = [ownerLocation]
                } else {
                    resolved[event.id] = []
                }
                if event.type == SessionEventSchema.Deleted.type {
                    updates[sessionID] = .some(nil)
                }
            }
            return (updates, resolved)
        }

        private func applyRouteUpdates(_ updates: [String: OpenCodeLocation?]) {
            guard !updates.isEmpty else { return }
            state.withLock { s in
                for (sessionID, loc) in updates {
                    if let loc {
                        s.sessionRoutes[sessionID] = loc
                    } else {
                        s.sessionRoutes.removeValue(forKey: sessionID)
                    }
                }
            }
        }

        private func decodeLocation(_ value: JSONValue?) -> OpenCodeLocation? {
            guard case .object(let obj) = value,
                  case .string(let dir) = obj["directory"]
            else { return nil }
            let ws: WorkspaceID? = if case .string(let w) = obj["workspaceID"] {
                WorkspaceID(rawValue: w)
            } else {
                nil
            }
            return OpenCodeLocation(directory: dir, workspaceID: ws)
        }

        private func makeSubscription(
            types: Set<String>?,
            location: OpenCodeLocation?
        ) -> AsyncStream<SubscribePayload> {
            AsyncStream { continuation in
                let subID = state.withLock { s -> UInt64 in
                    let id = s.nextID
                    s.nextID += 1
                    s.liveSubs.append(LiveSub(id: id, types: types, location: location, continuation: continuation))
                    return id
                }
                continuation.onTermination = { [weak self] _ in
                    self?.state.withLock { s in
                        s.liveSubs.removeAll { $0.id == subID }
                    }
                }
            }
        }

        private func registerDurableWake(for aggregateID: String) -> (AsyncStream<Void>, UInt64) {
            var subID: UInt64 = 0
            let stream = AsyncStream<Void>(bufferingPolicy: .bufferingNewest(1)) { continuation in
                subID = state.withLock { s in
                    let id = s.nextID
                    s.nextID += 1
                    s.durableWakes[aggregateID, default: []].append(DurableWake(id: id, continuation: continuation))
                    return id
                }
            }
            return (stream, subID)
        }

        private func unregisterDurableWake(for aggregateID: String, id: UInt64) {
            state.withLock { s in
                s.durableWakes[aggregateID]?.removeAll { $0.id == id }
                if s.durableWakes[aggregateID]?.isEmpty == true {
                    s.durableWakes.removeValue(forKey: aggregateID)
                }
            }
        }

        private func wakeDurableSubscribers(for aggregateID: String) {
            let wakes = state.withLock { $0.durableWakes[aggregateID] ?? [] }
            for wake in wakes {
                wake.continuation.yield(())
            }
        }

        private func notify(
            event: AnyEvent,
            routes: [OpenCodeLocation]?,
            isolateListeners: Bool
        ) async {
            let (listeners, subs) = state.withLock { ($0.listeners, $0.liveSubs) }
            for listener in listeners {
                _ = isolateListeners
                await listener.callback(event)
            }
            for sub in subs {
                if let filterTypes = sub.types, !filterTypes.contains(event.type) {
                    continue
                }
                if let targetLoc = sub.location {
                    let canonTarget = CoreLocation.ServiceMap.canonical(LocationSchema.Ref(
                        directory: SchemaPrimitive.AbsolutePath(rawValue: targetLoc.directory),
                        workspaceID: targetLoc.workspaceID
                    ))
                    let matches: (OpenCodeLocation) -> Bool = { ref in
                        if ref.directory == targetLoc.directory && ref.workspaceID == targetLoc.workspaceID {
                            return true
                        }
                        guard ref.workspaceID == targetLoc.workspaceID else { return false }
                        let canonRef = CoreLocation.ServiceMap.canonical(LocationSchema.Ref(
                            directory: SchemaPrimitive.AbsolutePath(rawValue: ref.directory),
                            workspaceID: ref.workspaceID
                        ))
                        return canonRef.directory == canonTarget.directory
                    }
                    if let routes {
                        if !routes.contains(where: matches) { continue }
                    } else if let eventLoc = event.location, !matches(eventLoc) {
                        continue
                    }
                }
                sub.continuation.yield(event)
            }
        }
    }

    // parity: core/src/bus.ts#configured [status=adapted hash=e7fe36aa0956]
    public static func configured(options: Options = Options()) -> LayerNode.Provider {
        let impl = LayerNode.ExecutableLayer { deps, _ in
            let dbService = deps.get(CoreDatabaseStore.Service.serviceKey, as: CoreDatabaseStore.Service.self)
            let db: any SQLiteDatabase
            if let dbService {
                db = dbService.db
            } else {
                db = try await CoreDatabaseStore.open().db
            }
            let bus = Service(db: db, options: options)
            return LayerNode.Output([Service.serviceKey: bus])
        }
        return AppNode.makeGlobalNode(Service.serviceKey, impl, [CoreDatabaseStore.node])
    }

    // parity: core/src/bus.ts#node [status=adapted hash=aea3814ebc3b]
    public static let node: LayerNode.Provider = configured()
}

// MARK: - event-logger.ts

/// Logs key catalog/config update events from the process-global event bus.
/// Ports `packages/core/src/event-logger.ts`.
public enum CoreEventLogger {
    public static let loggedEventTypes: Set<String> = [
        "agent.updated",
        "provider.updated",
        "model.updated",
        "command.updated",
        "config.updated",
    ]

    // parity: core/src/event-logger.ts#layer [status=implemented hash=e1f73c01aa2e]
    public static let layer: LayerNode.ExecutableLayer = LayerNode.ExecutableLayer { deps, scope in
        guard let bus = deps.get(CoreBus.Service.serviceKey, as: CoreBus.Service.self) else {
            return LayerNode.Output()
        }
        let sink = deps.get("@opencode/LogSink", as: (any LogSink).self)
        let unsub = bus.listen { event in
            guard loggedEventTypes.contains(event.type) else { return }
            await sink?.log(StructuredLogRecord(
                timestamp: String(event.created),
                level: .info,
                message: "event",
                fields: [("eventType", event.type), ("eventID", event.id.rawValue)]
            ))
        }
        scope.addFinalizer {
            unsub()
        }
        return LayerNode.Output()
    }

    // parity: core/src/event-logger.ts#node [status=implemented hash=0b47235bd880]
    public static let node: LayerNode.Provider = AppNode.makeGlobalNode(
        "event-logger",
        layer,
        [CoreBus.node]
    )
}

// MARK: - Shared Internal JSON Helpers for OpenCodeCore

internal enum CoreBusJSON {
    static func encodeJSONValue(_ value: JSONValue) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    static func decodeJSONValue(_ raw: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8))
    }

    static func encodeToJSONValue<T: Encodable>(_ value: T) throws -> JSONValue {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    static func encodeToString<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    static func decodeFromJSONValue<T: Decodable>(_ value: JSONValue, as type: T.Type = T.self) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    static func decodeFromString<T: Decodable>(_ raw: String, as type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(raw.utf8))
    }
}
