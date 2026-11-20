#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Synchronization
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

// MARK: - Async Keyed Serializer

internal final class CoreAsyncKeyedMutex<Key: Hashable & Sendable>: @unchecked Sendable {
    private actor LockActor {
        private var locked = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func acquire() async {
            if !locked {
                locked = true
                return
            }
            await withCheckedContinuation { cont in
                waiters.append(cont)
            }
        }

        func release() {
            if waiters.isEmpty {
                locked = false
            } else {
                let next = waiters.removeFirst()
                next.resume()
            }
        }
    }

    private let locks = Mutex<[Key: LockActor]>([:])

    private func actor(for key: Key) -> LockActor {
        locks.withLock { map in
            if let existing = map[key] { return existing }
            let created = LockActor()
            map[key] = created
            return created
        }
    }

    func withLock<T: Sendable>(_ key: Key, _ body: @Sendable () async throws -> T) async rethrows -> T {
        let lock = actor(for: key)
        await lock.acquire()
        do {
            let value = try await body()
            await lock.release()
            return value
        } catch {
            await lock.release()
            throw error
        }
    }
}

// MARK: - session/inbox.ts

/// Durable pending-only session inbox admission, idempotency reconciliation, delivery ordering,
/// and transactional projections (`packages/core/src/session/inbox.ts`).
public enum CoreSessionInbox {
    // parity: core/src/session/inbox.ts#Compaction [status=implemented hash=1d5c9b36c232]
    public typealias Compaction = SessionInboxSchema.Compaction
    // parity: core/src/session/inbox.ts#CompactionPayload [status=implemented hash=1d5c9b36c232]
    public typealias CompactionPayload = SessionInboxSchema.CompactionPayload
    // parity: core/src/session/inbox.ts#Delivery [status=implemented hash=1d5c9b36c232]
    public typealias Delivery = SessionInboxSchema.Delivery
    // parity: core/src/session/inbox.ts#Info [status=implemented hash=1d5c9b36c232]
    public typealias Info = SessionInboxSchema.Info
    // parity: core/src/session/inbox.ts#Item [status=implemented hash=1d5c9b36c232]
    public typealias Item = SessionInboxSchema.Item
    // parity: core/src/session/inbox.ts#MediaInfo [status=implemented hash=1d5c9b36c232]
    public typealias MediaInfo = SessionInboxSchema.MediaInfo
    // parity: core/src/session/inbox.ts#MediaUser [status=implemented hash=1d5c9b36c232]
    public typealias MediaUser = SessionInboxSchema.MediaUser
    // parity: core/src/session/inbox.ts#MediaUserPayload [status=implemented hash=1d5c9b36c232]
    public typealias MediaUserPayload = SessionInboxSchema.MediaUserPayload
    // parity: core/src/session/inbox.ts#Move [status=implemented hash=1d5c9b36c232]
    public typealias Move = SessionInboxSchema.Move
    // parity: core/src/session/inbox.ts#MovePayload [status=implemented hash=1d5c9b36c232]
    public typealias MovePayload = SessionInboxSchema.MovePayload
    // parity: core/src/session/inbox.ts#Synthetic [status=implemented hash=1d5c9b36c232]
    public typealias Synthetic = SessionInboxSchema.Synthetic
    // parity: core/src/session/inbox.ts#SyntheticPayload [status=implemented hash=1d5c9b36c232]
    public typealias SyntheticPayload = SessionInboxSchema.SyntheticPayload
    // parity: core/src/session/inbox.ts#User [status=implemented hash=1d5c9b36c232]
    public typealias User = SessionInboxSchema.User
    // parity: core/src/session/inbox.ts#UserPayload [status=implemented hash=1d5c9b36c232]
    public typealias UserPayload = SessionInboxSchema.UserPayload

    /// Which pending input `promote` may consume:
    /// - `.steer`: promotes steers only (step boundary mid-work)
    /// - `.input`: promotes steers first, else one queued item (idle boundary)
    // parity: core/src/session/inbox.ts#Promotable [status=implemented hash=ce2b529d5e61]
    public enum Promotable: String, Equatable, Hashable, Sendable, Codable {
        case input
        case steer
    }

    /// Which pending rows count when probing inbox presence.
    // parity: core/src/session/inbox.ts#Scope [status=implemented hash=d4c939b4cd30]
    public enum Scope: Equatable, Hashable, Sendable {
        case input
        case delivery(SessionInboxSchema.Delivery)

        public static let steer = Scope.delivery(.steer)
        public static let queue = Scope.delivery(.queue)
    }

    // parity: core/src/session/inbox.ts#LifecycleConflict [status=implemented hash=4697596d0b74]
    public struct LifecycleConflict: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public static let tag = "SessionInbox.LifecycleConflict"
        public let id: SessionMessageSchema.ID

        public init(id: SessionMessageSchema.ID) {
            self.id = id
        }

        public var description: String { "\(Self.tag)(\(id.rawValue))" }
    }

    /// Consumed inbox row returned by `projectDelivered` inside the same event transaction.
    // parity: core/src/session/inbox.ts#Delivered [status=implemented hash=dfb585f3499f]
    public enum Delivered: Equatable, Sendable {
        case user(id: SessionMessageSchema.ID, payload: CoreSessionStored.UserPayload)
        case synthetic(id: SessionMessageSchema.ID, payload: SessionInboxSchema.SyntheticPayload)
        case compaction(id: SessionMessageSchema.ID)
        case move(id: SessionMessageSchema.ID)
    }

    /// Next promotable boundary item returned by `nextPromotable`.
    // parity: core/src/session/inbox.ts#Promotion [status=implemented hash=336a81957693]
    public enum Promotion: Equatable, Hashable, Sendable {
        case user(id: SessionMessageSchema.ID, delivery: SessionInboxSchema.Delivery)
        case synthetic(id: SessionMessageSchema.ID, delivery: SessionInboxSchema.Delivery)
        case compaction(id: SessionMessageSchema.ID, delivery: SessionInboxSchema.Delivery)
        case move(id: SessionMessageSchema.ID, delivery: SessionInboxSchema.Delivery, payload: SessionInboxSchema.MovePayload)

        public var id: SessionMessageSchema.ID {
            switch self {
            case .user(let id, _), .synthetic(let id, _), .compaction(let id, _), .move(let id, _, _):
                return id
            }
        }

        public var delivery: SessionInboxSchema.Delivery {
            switch self {
            case .user(_, let d), .synthetic(_, let d), .compaction(_, let d), .move(_, let d, _):
                return d
            }
        }

        public var isControl: Bool {
            switch self {
            case .compaction, .move: true
            case .user, .synthetic: false
            }
        }
    }

    private static let inboxLocks = CoreAsyncKeyedMutex<SessionID>()

    /// Serializes inbox mutations and promotion per Session ID.
    // parity: core/src/session/inbox.ts#serialized [status=implemented hash=88d20ddce3f7]
    public static func serialized<T: Sendable>(
        _ sessionID: SessionID,
        _ body: @Sendable () async throws -> T
    ) async rethrows -> T {
        try await inboxLocks.withLock(sessionID, body)
    }

    // parity: core/src/session/inbox.ts#Interface [status=implemented hash=370bb244117b]
    public protocol Interface: Sendable {
        func list(_ sessionID: SessionID) throws -> [SessionInboxSchema.Info]
        func reconcile(
            id: SessionMessageSchema.ID,
            sessionID: SessionID,
            type: String,
            delivery: SessionInboxSchema.Delivery
        ) throws -> SessionInboxSchema.Info?
        func admit(
            id: SessionMessageSchema.ID,
            sessionID: SessionID,
            item: SessionInboxSchema.Item
        ) async throws -> SessionInboxSchema.Info
        func admitCompaction(
            id: SessionMessageSchema.ID,
            sessionID: SessionID,
            delivery: SessionInboxSchema.Delivery
        ) async throws -> SessionInboxSchema.Compaction
        func cancel(sessionID: SessionID, id: SessionMessageSchema.ID) async throws
        func steer(sessionID: SessionID, id: SessionMessageSchema.ID) async throws
        func queue(sessionID: SessionID, id: SessionMessageSchema.ID) async throws
    }

    // parity: core/src/session/inbox.ts#Service [status=implemented hash=90cf520fb02a]
    public final class Service: Interface, Sendable {
        public static let serviceKey = "@opencode/SessionInbox"
        public let db: any SQLiteDatabase
        public let bus: CoreBus.Service

        public init(db: any SQLiteDatabase, bus: CoreBus.Service) {
            self.db = db
            self.bus = bus
        }

        public func list(_ sessionID: SessionID) throws -> [SessionInboxSchema.Info] {
            try CoreSessionInbox.list(db: db, sessionID: sessionID)
        }

        public func reconcile(
            id: SessionMessageSchema.ID,
            sessionID: SessionID,
            type: String,
            delivery: SessionInboxSchema.Delivery
        ) throws -> SessionInboxSchema.Info? {
            let existing = try CoreSessionInbox.find(db: db, id: id)
                ?? CoreSessionInbox.promotedFromMessage(db: db, sessionID: sessionID, id: id, delivery: delivery)
            guard let existing else { return nil }
            if case .compaction = existing {
                throw LifecycleConflict(id: id)
            }
            guard CoreSessionInbox.matches(existing, sessionID: sessionID, type: type) else {
                throw LifecycleConflict(id: id)
            }
            return existing
        }

        public func admit(
            id: SessionMessageSchema.ID,
            sessionID: SessionID,
            item: SessionInboxSchema.Item
        ) async throws -> SessionInboxSchema.Info {
            if let existing = try reconcile(id: id, sessionID: sessionID, type: item.typeTag, delivery: item.delivery) {
                return existing
            }
            let admitted: SessionInboxSchema.Info
            do {
                let env = try await bus.publish(
                    SessionEventSchema.InboxEnqueued,
                    data: SessionEventSchema.InboxEnqueuedData(sessionID: sessionID, inboxID: id, item: item)
                )
                let time = SessionMessageSchema.TimeCreated(created: env.created)
                switch item {
                case .user(let payload, let delivery):
                    admitted = .user(SessionInboxSchema.User(id: id, sessionID: sessionID, time: time, payload: payload, delivery: delivery))
                case .synthetic(let payload, let delivery):
                    admitted = .synthetic(SessionInboxSchema.Synthetic(id: id, sessionID: sessionID, time: time, payload: payload, delivery: delivery))
                case .compaction(let payload, let delivery):
                    admitted = .compaction(SessionInboxSchema.Compaction(id: id, sessionID: sessionID, time: time, payload: payload, delivery: delivery))
                case .move(let payload, let delivery):
                    admitted = .move(SessionInboxSchema.Move(id: id, sessionID: sessionID, time: time, payload: payload, delivery: delivery))
                }
            } catch let conflict as LifecycleConflict {
                if let stored = try CoreSessionInbox.find(db: db, id: id) {
                    admitted = stored
                } else if let promoted = try CoreSessionInbox.promotedFromMessage(
                    db: db,
                    sessionID: sessionID,
                    id: id,
                    delivery: item.delivery
                ) {
                    admitted = promoted
                } else {
                    throw conflict
                }
            }
            guard CoreSessionInbox.matches(admitted, sessionID: sessionID, type: item.typeTag) else {
                throw LifecycleConflict(id: id)
            }
            return admitted
        }

        public func admitCompaction(
            id: SessionMessageSchema.ID,
            sessionID: SessionID,
            delivery: SessionInboxSchema.Delivery
        ) async throws -> SessionInboxSchema.Compaction {
            try await CoreSessionInbox.serialized(sessionID) {
                if let exact = try CoreSessionInbox.find(db: self.db, id: id) {
                    if case .compaction(let comp) = exact, comp.sessionID == sessionID {
                        return comp
                    }
                    throw LifecycleConflict(id: id)
                }
                if try CoreSessionInbox.promotedFromMessage(db: self.db, sessionID: sessionID, id: id, delivery: delivery) != nil {
                    throw LifecycleConflict(id: id)
                }
                for item in try CoreSessionInbox.list(db: self.db, sessionID: sessionID) {
                    if case .compaction(let comp) = item {
                        return comp
                    }
                }
                let result = try await self.admit(
                    id: id,
                    sessionID: sessionID,
                    item: .compaction(payload: SessionInboxSchema.CompactionPayload(), delivery: delivery)
                )
                guard case .compaction(let comp) = result else {
                    throw LifecycleConflict(id: id)
                }
                return comp
            }
        }

        public func cancel(sessionID: SessionID, id: SessionMessageSchema.ID) async throws {
            try await CoreSessionInbox.serialized(sessionID) {
                _ = try await self.bus.publish(
                    SessionEventSchema.InboxCancelled,
                    data: SessionEventSchema.InboxRefData(sessionID: sessionID, inboxID: id)
                )
            }
        }

        public func steer(sessionID: SessionID, id: SessionMessageSchema.ID) async throws {
            try await CoreSessionInbox.serialized(sessionID) {
                _ = try await self.bus.publish(
                    SessionEventSchema.InboxDeliveryChanged,
                    data: SessionEventSchema.InboxDeliveryChangedData(sessionID: sessionID, inboxID: id, delivery: .steer)
                )
            }
        }

        public func queue(sessionID: SessionID, id: SessionMessageSchema.ID) async throws {
            try await CoreSessionInbox.serialized(sessionID) {
                _ = try await self.bus.publish(
                    SessionEventSchema.InboxDeliveryChanged,
                    data: SessionEventSchema.InboxDeliveryChangedData(sessionID: sessionID, inboxID: id, delivery: .queue)
                )
            }
        }
    }

    // parity: core/src/session/inbox.ts#make [status=implemented hash=c232b4a4af4a]
    public static func make(db: any SQLiteDatabase, bus: CoreBus.Service) -> Service {
        Service(db: db, bus: bus)
    }

    // parity: core/src/session/inbox.ts#layer [status=adapted hash=7ff2fd2f23bc]
    public static let layer: LayerNode.ExecutableLayer = LayerNode.ExecutableLayer { deps, _ in
        guard let db = deps.get(CoreDatabaseStore.Service.serviceKey, as: CoreDatabaseStore.Service.self)?.db,
              let bus = deps.get(CoreBus.Service.serviceKey, as: CoreBus.Service.self)
        else {
            throw SQLiteError.databaseClosed
        }
        return LayerNode.Output([Service.serviceKey: make(db: db, bus: bus)])
    }

    // parity: core/src/session/inbox.ts#node [status=adapted hash=c6deac2d4727]
    public static let node: LayerNode.Provider = AppNode.makeGlobalNode(
        Service.serviceKey,
        layer,
        [CoreDatabaseStore.node, CoreBus.node]
    )

    // MARK: Row Parsing & Queries

    private static func matches(_ info: SessionInboxSchema.Info, sessionID: SessionID, type: String) -> Bool {
        switch info {
        case .user(let u): u.sessionID == sessionID && type == "user"
        case .synthetic(let s): s.sessionID == sessionID && type == "synthetic"
        case .compaction(let c): c.sessionID == sessionID && type == "compaction"
        case .move(let m): m.sessionID == sessionID && type == "move"
        }
    }

    private static func parseInboxRow(_ row: SQLiteRow) throws -> CoreSessionBlob.StoredInboxRow {
        guard let idStr = row.string("id"),
              let id = SessionMessageSchema.ID(rawValue: idStr),
              let sessionStr = row.string("session_id"),
              let sessionID = SessionID(rawValue: sessionStr),
              let type = row.string("type"),
              let rawPayload = row.string("payload"),
              case .object(let payloadDict) = try CoreBusJSON.decodeJSONValue(rawPayload),
              let deliveryStr = row.string("delivery"),
              let delivery = SessionInboxSchema.Delivery(rawValue: deliveryStr),
              let enqueuedSeq = row.int64("enqueued_seq"),
              let timeCreated = row.int64("time_created")
        else {
            throw SQLiteError.invalidParameter("Malformed session_inbox row")
        }
        return CoreSessionBlob.StoredInboxRow(
            id: id,
            sessionID: sessionID,
            type: type,
            payload: payloadDict,
            delivery: delivery,
            enqueuedSeq: enqueuedSeq,
            timeCreated: timeCreated
        )
    }

    private static func infoFromStoredRow(_ row: CoreSessionBlob.StoredInboxRow) throws -> SessionInboxSchema.Info {
        let time = SessionMessageSchema.TimeCreated(created: row.timeCreated)
        switch row.type {
        case "user":
            let payload = try CoreBusJSON.decodeFromJSONValue(.object(row.payload), as: SessionInboxSchema.UserPayload.self)
            return .user(SessionInboxSchema.User(id: row.id, sessionID: row.sessionID, time: time, payload: payload, delivery: row.delivery))
        case "synthetic":
            let payload = try CoreBusJSON.decodeFromJSONValue(.object(row.payload), as: SessionInboxSchema.SyntheticPayload.self)
            return .synthetic(SessionInboxSchema.Synthetic(id: row.id, sessionID: row.sessionID, time: time, payload: payload, delivery: row.delivery))
        case "compaction":
            return .compaction(SessionInboxSchema.Compaction(id: row.id, sessionID: row.sessionID, time: time, delivery: row.delivery))
        case "move":
            let payload = try CoreBusJSON.decodeFromJSONValue(.object(row.payload), as: SessionInboxSchema.MovePayload.self)
            return .move(SessionInboxSchema.Move(id: row.id, sessionID: row.sessionID, time: time, payload: payload, delivery: row.delivery))
        default:
            throw LifecycleConflict(id: row.id)
        }
    }

    // parity: core/src/session/inbox.ts#find [status=implemented hash=1d4e28329ac8]
    public static func find(db: any SQLiteDatabase, id: SessionMessageSchema.ID) throws -> SessionInboxSchema.Info? {
        guard let raw = try db.queryOne(
            "SELECT * FROM `session_inbox` WHERE `id` = ?",
            parameters: [.text(id.rawValue)]
        ) else { return nil }
        let parsed = try parseInboxRow(raw)
        let hydrated = try CoreSessionBlob.hydrateInbox(db, rows: [parsed])
        guard let first = hydrated.first else { return nil }
        return try infoFromStoredRow(first)
    }

    internal static func promotedFromMessage(
        db: any SQLiteDatabase,
        sessionID: SessionID,
        id: SessionMessageSchema.ID,
        delivery: SessionInboxSchema.Delivery
    ) throws -> SessionInboxSchema.Info? {
        guard let raw = try db.queryOne(
            "SELECT * FROM `session_message` WHERE `id` = ?",
            parameters: [.text(id.rawValue)]
        ) else { return nil }
        let parsed = try CoreSessionHistory.parseMessageRow(raw)
        guard parsed.sessionID == sessionID,
              parsed.type == .user || parsed.type == .synthetic
        else {
            throw LifecycleConflict(id: id)
        }
        guard let decoded = try CoreSessionHistory.decodeMessageRows(db, rows: [parsed]).first else {
            return nil
        }
        switch decoded {
        case .user(let u):
            return .user(SessionInboxSchema.User(
                id: id,
                sessionID: sessionID,
                time: u.time,
                payload: SessionInboxSchema.UserPayload(
                    text: u.text,
                    files: u.files,
                    agents: u.agents,
                    skills: u.skills,
                    metadata: u.metadata
                ),
                delivery: delivery
            ))
        case .synthetic(let s):
            return .synthetic(SessionInboxSchema.Synthetic(
                id: id,
                sessionID: sessionID,
                time: s.time,
                payload: SessionInboxSchema.SyntheticPayload(
                    text: s.text,
                    description: s.description,
                    metadata: s.metadata
                ),
                delivery: delivery
            ))
        default:
            return nil
        }
    }

    // MARK: Projections (Transactional)

    // parity: core/src/session/inbox.ts#projectAdmitted [status=implemented hash=445b5f59d12d]
    public static func projectAdmitted(
        db: any SQLiteDatabase,
        enqueuedSeq: Int64,
        id: SessionMessageSchema.ID,
        sessionID: SessionID,
        item: SessionInboxSchema.Item,
        timeCreated: Int64,
        mediaBlobEnabled: Bool = false
    ) throws {
        let alreadyDelivered = try db.queryOne(
            "SELECT `id` FROM `session_message` WHERE `id` = ?",
            parameters: [.text(id.rawValue)]
        ) != nil
        if alreadyDelivered {
            throw LifecycleConflict(id: id)
        }

        let payloadDict: [String: JSONValue]
        switch item {
        case .user(let payload, _):
            guard case .object(let raw) = try CoreBusJSON.encodeToJSONValue(payload) else {
                throw LifecycleConflict(id: id)
            }
            payloadDict = try CoreSessionBlob.externalizePayload(db, payload: raw, mediaBlobEnabled: mediaBlobEnabled)
        case .synthetic(let payload, _):
            guard case .object(let raw) = try CoreBusJSON.encodeToJSONValue(payload) else {
                throw LifecycleConflict(id: id)
            }
            payloadDict = raw
        case .compaction:
            payloadDict = [:]
        case .move(let payload, _):
            guard case .object(let raw) = try CoreBusJSON.encodeToJSONValue(payload) else {
                throw LifecycleConflict(id: id)
            }
            payloadDict = raw
        }

        let payloadJSON = try CoreBusJSON.encodeJSONValue(.object(payloadDict))
        let stored = try db.queryOne(
            """
            INSERT INTO `session_inbox` (`id`, `session_id`, `type`, `payload`, `delivery`, `enqueued_seq`, `time_created`)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (`id`) DO NOTHING
            RETURNING `id`
            """,
            parameters: [
                .text(id.rawValue),
                .text(sessionID.rawValue),
                .text(item.typeTag),
                .text(payloadJSON),
                .text(item.delivery.rawValue),
                .integer(enqueuedSeq),
                .integer(timeCreated),
            ]
        )
        if stored == nil {
            throw LifecycleConflict(id: id)
        }
        try CoreSessionBlob.recordRefs(
            db,
            owner: CoreSessionBlob.Owner(sessionID: sessionID, messageID: id, seq: enqueuedSeq),
            data: payloadDict
        )
    }

    // parity: core/src/session/inbox.ts#projectDelivered [status=implemented hash=2186f285ed90]
    public static func projectDelivered(
        db: any SQLiteDatabase,
        id: SessionMessageSchema.ID,
        sessionID: SessionID
    ) throws -> Delivered {
        guard let deleted = try db.queryOne(
            "DELETE FROM `session_inbox` WHERE `id` = ? AND `session_id` = ? RETURNING *",
            parameters: [.text(id.rawValue), .text(sessionID.rawValue)]
        ) else {
            throw LifecycleConflict(id: id)
        }
        let parsed = try parseInboxRow(deleted)
        switch parsed.type {
        case "user":
            let payload = try CoreBusJSON.decodeFromJSONValue(.object(parsed.payload), as: CoreSessionStored.UserPayload.self)
            return .user(id: parsed.id, payload: payload)
        case "synthetic":
            let payload = try CoreBusJSON.decodeFromJSONValue(.object(parsed.payload), as: SessionInboxSchema.SyntheticPayload.self)
            return .synthetic(id: parsed.id, payload: payload)
        case "compaction":
            return .compaction(id: parsed.id)
        case "move":
            return .move(id: parsed.id)
        default:
            throw LifecycleConflict(id: id)
        }
    }

    // parity: core/src/session/inbox.ts#projectCancelled [status=implemented hash=68cde135e750]
    public static func projectCancelled(
        db: any SQLiteDatabase,
        id: SessionMessageSchema.ID,
        sessionID: SessionID
    ) throws {
        let deleted = try db.queryOne(
            """
            DELETE FROM `session_inbox`
            WHERE `id` = ? AND `session_id` = ? AND (`delivery` = 'queue' OR `delivery` = 'steer')
            RETURNING `id`
            """,
            parameters: [.text(id.rawValue), .text(sessionID.rawValue)]
        )
        if deleted == nil {
            throw LifecycleConflict(id: id)
        }
        try CoreSessionBlob.releaseMessage(db, sessionID: sessionID, messageID: id)
    }

    // parity: core/src/session/inbox.ts#projectDeliveryChanged [status=implemented hash=f9667cbede02]
    public static func projectDeliveryChanged(
        db: any SQLiteDatabase,
        id: SessionMessageSchema.ID,
        sessionID: SessionID,
        delivery: SessionInboxSchema.Delivery
    ) throws {
        let from: SessionInboxSchema.Delivery = (delivery == .steer) ? .queue : .steer
        let updated = try db.queryOne(
            """
            UPDATE `session_inbox` SET `delivery` = ?
            WHERE `id` = ? AND `session_id` = ? AND `delivery` = ?
            RETURNING `id`
            """,
            parameters: [
                .text(delivery.rawValue),
                .text(id.rawValue),
                .text(sessionID.rawValue),
                .text(from.rawValue),
            ]
        )
        if updated == nil {
            throw LifecycleConflict(id: id)
        }
    }

    // MARK: Queries & Promotion Ordering

    private static func listRows(db: any SQLiteDatabase, sessionID: SessionID) throws -> [CoreSessionBlob.StoredInboxRow] {
        let rows = try db.query(
            "SELECT * FROM `session_inbox` WHERE `session_id` = ? ORDER BY `enqueued_seq` ASC",
            parameters: [.text(sessionID.rawValue)]
        )
        return try rows.map(parseInboxRow)
    }

    // parity: core/src/session/inbox.ts#list [status=implemented hash=c4d819288af0]
    public static func list(db: any SQLiteDatabase, sessionID: SessionID) throws -> [SessionInboxSchema.Info] {
        let hydrated = try CoreSessionBlob.hydrateInbox(db, rows: try listRows(db: db, sessionID: sessionID))
        return try hydrated.map(infoFromStoredRow)
    }

    // parity: core/src/session/inbox.ts#listWithRefs [status=implemented hash=fe05905e0039]
    public static func listWithRefs(db: any SQLiteDatabase, sessionID: SessionID) throws -> [SessionInboxSchema.MediaInfo] {
        let kept = try CoreSessionBlob.keepInboxRefs(db, rows: try listRows(db: db, sessionID: sessionID))
        return try kept.rows.map { row in
            if row.type == "user" {
                let payload = try CoreBusJSON.decodeFromJSONValue(.object(row.payload), as: SessionInboxSchema.MediaUserPayload.self)
                let describedFiles = payload.files.map { CoreSessionBlob.describe($0, meta: kept.meta) }
                return .user(SessionInboxSchema.MediaUser(
                    id: row.id,
                    sessionID: row.sessionID,
                    time: SessionMessageSchema.TimeCreated(created: row.timeCreated),
                    payload: SessionInboxSchema.MediaUserPayload(
                        text: payload.text,
                        files: describedFiles,
                        agents: payload.agents,
                        skills: payload.skills,
                        metadata: payload.metadata
                    ),
                    delivery: row.delivery
                ))
            }
            let info = try infoFromStoredRow(row)
            switch info {
            case .user(let u):
                return .user(SessionInboxSchema.MediaUser(
                    id: u.id, sessionID: u.sessionID, time: u.time,
                    payload: SessionInboxSchema.MediaUserPayload(
                        text: u.payload.text,
                        files: u.payload.files?.map { .file($0) },
                        agents: u.payload.agents,
                        skills: u.payload.skills,
                        metadata: u.payload.metadata
                    ),
                    delivery: u.delivery
                ))
            case .synthetic(let s): return .synthetic(s)
            case .compaction(let c): return .compaction(c)
            case .move(let m): return .move(m)
            }
        }
    }

    // parity: core/src/session/inbox.ts#moveIDs [status=implemented hash=139e5395e559]
    public static func moveIDs(db: any SQLiteDatabase, sessionID: SessionID) throws -> [SessionMessageSchema.ID] {
        let rows = try db.query(
            "SELECT `id` FROM `session_inbox` WHERE `session_id` = ? AND `type` = 'move' ORDER BY `enqueued_seq` ASC",
            parameters: [.text(sessionID.rawValue)]
        )
        return rows.compactMap { $0.string("id").flatMap(SessionMessageSchema.ID.init(rawValue:)) }
    }

    private static func isControl(_ row: CoreSessionBlob.StoredInboxRow) -> Bool {
        row.type == "compaction" || row.type == "move"
    }

    private static func beforeControl(_ rows: [CoreSessionBlob.StoredInboxRow]) -> [CoreSessionBlob.StoredInboxRow] {
        guard let idx = rows.firstIndex(where: isControl) else { return rows }
        return Array(rows[..<idx])
    }

    private static func firstQueued(db: any SQLiteDatabase, sessionID: SessionID) throws -> CoreSessionBlob.StoredInboxRow? {
        guard let raw = try db.queryOne(
            "SELECT * FROM `session_inbox` WHERE `session_id` = ? AND `delivery` = 'queue' ORDER BY `enqueued_seq` ASC LIMIT 1",
            parameters: [.text(sessionID.rawValue)]
        ) else { return nil }
        return try parseInboxRow(raw)
    }

    /// Steered items ordered by `enqueued_seq`, hoisting a steered compaction to index 0
    /// unless a steered `move` control precedes it (never crossing a move boundary).
    private static func pendingSteers(db: any SQLiteDatabase, sessionID: SessionID) throws -> [CoreSessionBlob.StoredInboxRow] {
        var rows = try db.query(
            "SELECT * FROM `session_inbox` WHERE `session_id` = ? AND `delivery` = 'steer' ORDER BY `enqueued_seq` ASC",
            parameters: [.text(sessionID.rawValue)]
        ).map(parseInboxRow)
        if let controlIdx = rows.firstIndex(where: isControl),
           controlIdx > 0,
           rows[controlIdx].type == "compaction"
        {
            let comp = rows.remove(at: controlIdx)
            rows.insert(comp, at: 0)
        }
        return rows
    }

    private static func promotionFromRow(_ row: CoreSessionBlob.StoredInboxRow) throws -> Promotion {
        switch row.type {
        case "user": return .user(id: row.id, delivery: row.delivery)
        case "synthetic": return .synthetic(id: row.id, delivery: row.delivery)
        case "compaction": return .compaction(id: row.id, delivery: row.delivery)
        case "move":
            let payload = try CoreBusJSON.decodeFromJSONValue(.object(row.payload), as: SessionInboxSchema.MovePayload.self)
            return .move(id: row.id, delivery: row.delivery, payload: payload)
        default:
            throw LifecycleConflict(id: row.id)
        }
    }

    // parity: core/src/session/inbox.ts#nextPromotable [status=implemented hash=c8bb921773a8]
    public static func nextPromotable(
        db: any SQLiteDatabase,
        sessionID: SessionID,
        promotable: Promotable
    ) throws -> Promotion? {
        if let steer = try pendingSteers(db: db, sessionID: sessionID).first {
            return try promotionFromRow(steer)
        }
        guard promotable == .input, let queued = try firstQueued(db: db, sessionID: sessionID) else {
            return nil
        }
        return try promotionFromRow(queued)
    }

    // parity: core/src/session/inbox.ts#has [status=implemented hash=ddefa2064b4e]
    public static func has(db: any SQLiteDatabase, sessionID: SessionID, scope: Scope) throws -> Bool {
        let sql: String
        let params: [SQLiteValue]
        switch scope {
        case .input:
            sql = "SELECT `id` FROM `session_inbox` WHERE `session_id` = ? AND (`delivery` = 'steer' OR `delivery` = 'queue') LIMIT 1"
            params = [.text(sessionID.rawValue)]
        case .delivery(let delivery):
            sql = "SELECT `id` FROM `session_inbox` WHERE `session_id` = ? AND `delivery` = ? LIMIT 1"
            params = [.text(sessionID.rawValue), .text(delivery.rawValue)]
        }
        return try db.queryOne(sql, parameters: params) != nil
    }

    private static func publishRows(
        db: any SQLiteDatabase,
        bus: CoreBus.Service,
        sessionID: SessionID,
        rows: [CoreSessionBlob.StoredInboxRow]
    ) async throws -> Int {
        for row in rows {
            guard row.type == "move" || row.type == "user" || row.type == "synthetic" else {
                throw LifecycleConflict(id: row.id)
            }
            do {
                _ = try await bus.publish(
                    SessionEventSchema.InboxDelivered,
                    data: SessionEventSchema.InboxRefData(sessionID: sessionID, inboxID: row.id)
                )
            } catch let conflict as LifecycleConflict {
                let already = try promotedFromMessage(db: db, sessionID: sessionID, id: row.id, delivery: row.delivery)
                if already == nil { throw conflict }
            }
        }
        return rows.count
    }

    /// Promotes pending input into visible messages, returning the promoted count,
    /// or `nil` when a control (`compaction` or `move`) owns the boundary.
    // parity: core/src/session/inbox.ts#promote [status=implemented hash=12a5dbd99b64]
    public static func promote(
        db: any SQLiteDatabase,
        bus: CoreBus.Service,
        sessionID: SessionID,
        scope: Promotable
    ) async throws -> Int? {
        try await serialized(sessionID) {
            let steers = try pendingSteers(db: db, sessionID: sessionID)
            if !steers.isEmpty || scope == .steer {
                if let first = steers.first, isControl(first) { return nil }
                return try await publishRows(db: db, bus: bus, sessionID: sessionID, rows: beforeControl(steers))
            }
            guard let queued = try firstQueued(db: db, sessionID: sessionID) else { return 0 }
            if isControl(queued) { return nil }
            let promoted = try await publishRows(db: db, bus: bus, sessionID: sessionID, rows: [queued])
            let extraSteers = beforeControl(try pendingSteers(db: db, sessionID: sessionID))
            return promoted + (try await publishRows(db: db, bus: bus, sessionID: sessionID, rows: extraSteers))
        }
    }
}

// MARK: - session/prompt.ts

/// Prompt attachment materialization and skill expansion (`packages/core/src/session/prompt.ts`).
public enum CoreSessionPrompt {
    public static let maxAttachmentBytes: Int = 20 * 1024 * 1024

    // parity: core/src/session/prompt.ts#Input [status=implemented hash=9e7e7173c87e]
    public struct Input: Equatable, Hashable, Sendable, Codable {
        public let text: String
        public let files: [PromptInputSchema.FileAttachment]?
        public let agents: [PromptSchema.AgentAttachment]?
        public let skills: [PromptInputSchema.SkillAttachment]?
        public let metadata: [String: JSONValue]?
        public let delivery: SessionInboxSchema.Delivery?

        public init(
            text: String,
            files: [PromptInputSchema.FileAttachment]? = nil,
            agents: [PromptSchema.AgentAttachment]? = nil,
            skills: [PromptInputSchema.SkillAttachment]? = nil,
            metadata: [String: JSONValue]? = nil,
            delivery: SessionInboxSchema.Delivery? = nil
        ) {
            self.text = text
            self.files = files
            self.agents = agents
            self.skills = skills
            self.metadata = metadata
            self.delivery = delivery
        }
    }

    public struct SkillResolution: Equatable, Sendable {
        public let id: String
        public let name: String
        public let text: String

        public init(id: String, name: String, text: String) {
            self.id = id
            self.name = name
            self.text = text
        }
    }

    /// Materializes prompt attachments (`data:`, `media:`, `file:`) and resolves attached skills
    /// into a durable `SessionInboxSchema.Item`.
    // parity: core/src/session/prompt.ts#prepare [status=implemented hash=7d88f5df016c]
    public static func prepare(
        session: SessionSchema.Info,
        messageID: SessionMessageSchema.ID,
        input: Input,
        db: (any SQLiteDatabase)? = nil,
        fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
        resolveSkill: (@Sendable (String) async throws -> SkillResolution?)? = nil
    ) async throws -> SessionInboxSchema.Item {
        _ = (session, messageID)
        let delivery = input.delivery ?? .steer

        var resolvedFiles: [PromptSchema.FileAttachment]? = nil
        if let inputFiles = input.files, !inputFiles.isEmpty {
            var materialized: [PromptSchema.FileAttachment] = []
            materialized.reserveCapacity(inputFiles.count)
            for file in inputFiles {
                materialized.append(try await materializeAttachment(file, db: db, fileSystem: fileSystem))
            }
            resolvedFiles = materialized
        }

        var resolvedSkills: [PromptSchema.SkillAttachment]? = nil
        if let inputSkills = input.skills, !inputSkills.isEmpty {
            var seen: [String: String] = [:]
            var list: [PromptSchema.SkillAttachment] = []
            for attachment in inputSkills {
                if let existingName = seen[attachment.id] {
                    list.append(PromptSchema.SkillAttachment(
                        id: attachment.id,
                        name: existingName,
                        text: nil,
                        mention: attachment.mention
                    ))
                    continue
                }
                guard let resolved = try await resolveSkill?(attachment.id) else {
                    throw CoreSessionErrors.SkillNotFoundError(skill: attachment.id)
                }
                seen[resolved.id] = resolved.name
                list.append(PromptSchema.SkillAttachment(
                    id: resolved.id,
                    name: resolved.name,
                    text: resolved.text,
                    mention: attachment.mention
                ))
            }
            resolvedSkills = list
        }

        return .user(
            payload: SessionInboxSchema.UserPayload(
                text: input.text,
                files: resolvedFiles,
                agents: input.agents,
                skills: resolvedSkills,
                metadata: input.metadata
            ),
            delivery: delivery
        )
    }

    private static func materializeAttachment(
        _ input: PromptInputSchema.FileAttachment,
        db: (any SQLiteDatabase)?,
        fileSystem: any OpenCodeFileSystem
    ) async throws -> PromptSchema.FileAttachment {
        if let mediaRef = PromptSchema.MediaRef(rawValue: input.uri) {
            guard let db, let blob = try CoreSessionBlob.read(db, hash: CoreSessionStored.refHash(mediaRef)) else {
                throw CoreSessionErrors.AttachmentError(
                    uri: input.uri,
                    message: "Attachment is no longer stored: \(input.uri)"
                )
            }
            let b64 = PromptSchema.Base64(rawValue: bytesToBase64(blob.data))!
            return PromptSchema.FileAttachment(
                data: b64,
                mime: blob.mime,
                source: input.source ?? .inline,
                name: input.name,
                description: input.description,
                mention: input.mention
            )
        }

        let label = input.name ?? (input.uri.hasPrefix("data:") ? "inline attachment" : input.uri)
        if input.uri.hasPrefix("data:") {
            guard let comma = input.uri.firstIndex(of: ",") else {
                throw CoreSessionErrors.AttachmentError(uri: label, message: "Invalid attachment data URL: \(label)")
            }
            let header = String(input.uri[input.uri.index(input.uri.startIndex, offsetBy: 5)..<comma])
            let payload = String(input.uri[input.uri.index(after: comma)...])
            let parts = header.split(separator: ";").map(String.init)
            let isBase64 = parts.contains { $0.lowercased() == "base64" }
            let rawBytes: [UInt8]
            if isBase64 {
                guard let decoded = try? base64ToBytes(payload), bytesToBase64(decoded) == payload else {
                    throw CoreSessionErrors.AttachmentError(uri: label, message: "Invalid attachment data URL: \(label)")
                }
                rawBytes = decoded
            } else {
                rawBytes = Array((payload.removingPercentEncoding ?? payload).utf8)
            }
            if rawBytes.count > maxAttachmentBytes {
                throw CoreSessionErrors.AttachmentError(
                    uri: label,
                    message: "Attachment exceeds the \(maxAttachmentBytes) byte limit: \(label)"
                )
            }
            let mime = parts.first.flatMap { $0.isEmpty ? nil : $0 } ?? sniffMime(rawBytes)
            let b64 = PromptSchema.Base64(rawValue: bytesToBase64(rawBytes))!
            return PromptSchema.FileAttachment(
                data: b64,
                mime: mime,
                source: input.source ?? .inline,
                name: input.name,
                description: input.description,
                mention: input.mention
            )
        }

        guard let url = URL(string: input.uri), url.scheme == "file" else {
            throw CoreSessionErrors.AttachmentError(uri: input.uri, message: "Unsupported attachment URI: \(input.uri)")
        }
        let target = url.path
        let stat: FileStat
        do {
            stat = try await fileSystem.stat(at: target)
        } catch {
            throw CoreSessionErrors.AttachmentError(uri: input.uri, message: "Unable to read attachment: \(input.uri)")
        }
        let basename = target.split(separator: "/").last.map(String.init) ?? target
        if stat.type == .directory {
            let entries = (try? await fileSystem.readDirectory(at: target)) ?? []
            let bytes = Array(entries.sorted().joined(separator: "\n").utf8)
            let b64 = PromptSchema.Base64(rawValue: bytesToBase64(bytes))!
            return PromptSchema.FileAttachment(
                data: b64,
                mime: "application/x-directory",
                source: .uri(input.uri),
                name: input.name ?? basename,
                description: input.description,
                mention: input.mention
            )
        }
        guard stat.type == .file else {
            throw CoreSessionErrors.AttachmentError(uri: input.uri, message: "Attachment is not a file: \(input.uri)")
        }
        if Int(stat.size) > maxAttachmentBytes {
            throw CoreSessionErrors.AttachmentError(
                uri: input.uri,
                message: "Attachment exceeds the \(maxAttachmentBytes) byte limit: \(input.uri)"
            )
        }
        let bytes = try await fileSystem.readFile(at: target)
        let mime = sniffMime(bytes)
        let b64 = PromptSchema.Base64(rawValue: bytesToBase64(bytes))!
        return PromptSchema.FileAttachment(
            data: b64,
            mime: mime,
            source: .uri(input.uri),
            name: input.name ?? basename,
            description: input.description,
            mention: input.mention
        )
    }

    private static func sniffMime(_ bytes: [UInt8]) -> String {
        if bytes.count >= 8 && Array(bytes[0..<8]) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] {
            return "image/png"
        }
        if bytes.count >= 3 && Array(bytes[0..<3]) == [0xFF, 0xD8, 0xFF] { return "image/jpeg" }
        if bytes.count >= 4 && Array(bytes[0..<4]) == [0x47, 0x49, 0x46, 0x38] { return "image/gif" }
        if bytes.count >= 4 && Array(bytes[0..<4]) == [0x25, 0x50, 0x44, 0x46] { return "application/pdf" }
        return "text/plain"
    }
}

// MARK: - session/synthetic.ts

/// Admits durable synthetic inbox items and conditionally schedules wakeups (`packages/core/src/session/synthetic.ts`).
public enum CoreSessionSynthetic {
    public struct Request: Equatable, Hashable, Sendable {
        public let sessionID: SessionID
        public let id: SessionMessageSchema.ID?
        public let text: String
        public let description: String?
        public let metadata: [String: JSONValue]?
        public let delivery: SessionInboxSchema.Delivery?
        public let resume: Bool?

        public init(
            sessionID: SessionID,
            id: SessionMessageSchema.ID? = nil,
            text: String,
            description: String? = nil,
            metadata: [String: JSONValue]? = nil,
            delivery: SessionInboxSchema.Delivery? = nil,
            resume: Bool? = nil
        ) {
            self.sessionID = sessionID
            self.id = id
            self.text = text
            self.description = description
            self.metadata = metadata
            self.delivery = delivery
            self.resume = resume
        }
    }

    // parity: core/src/session/synthetic.ts#make [status=implemented hash=d8072ded9246]
    public static func make(
        store: any CoreSessionStore.Interface,
        inbox: any CoreSessionInbox.Interface,
        wake: @escaping @Sendable (SessionID) async -> Void
    ) -> @Sendable (Request) async throws -> SessionInboxSchema.Info {
        { input in
            guard try store.get(input.sessionID) != nil else {
                throw CoreSessionErrors.NotFoundError(sessionID: input.sessionID)
            }
            let id = input.id ?? SessionMessageSchema.ID.create()
            let admitted: SessionInboxSchema.Info
            do {
                admitted = try await inbox.admit(
                    id: id,
                    sessionID: input.sessionID,
                    item: .synthetic(
                        payload: SessionInboxSchema.SyntheticPayload(
                            text: input.text,
                            description: input.description,
                            metadata: input.metadata
                        ),
                        delivery: input.delivery ?? .steer
                    )
                )
            } catch is CoreSessionInbox.LifecycleConflict {
                throw CoreSessionErrors.SyntheticConflictError(sessionID: input.sessionID, inputID: id)
            }
            if input.resume != false, let latest = try store.get(input.sessionID), latest.revert == nil {
                await wake(input.sessionID)
            }
            return admitted
        }
    }
}

// MARK: - session/environment.ts

/// Process-local per-session environment variable overrides (`packages/core/src/session/environment.ts`).
public enum CoreSessionEnvironment {
    // parity: core/src/session/environment.ts#Variables [status=implemented hash=8610cbffeffc]
    public typealias Variables = [String: String]

    // parity: core/src/session/environment.ts#Interface [status=implemented hash=909283dd4c4c]
    public protocol Interface: Sendable {
        func get(_ sessionID: SessionID) -> Variables?
        func set(_ sessionID: SessionID, variables: Variables)
        func clear(_ sessionID: SessionID)
    }

    // parity: core/src/session/environment.ts#Service [status=implemented hash=1a96b7a43c9e]
    public final class Service: Interface, Sendable {
        public static let serviceKey = "@opencode/SessionEnvironment"
        private let state = Mutex<[SessionID: Variables]>([:])

        public init() {}

        public func get(_ sessionID: SessionID) -> Variables? {
            state.withLock { $0[sessionID] }
        }

        public func set(_ sessionID: SessionID, variables: Variables) {
            state.withLock { $0[sessionID] = variables }
        }

        public func clear(_ sessionID: SessionID) {
            state.withLock { _ = $0.removeValue(forKey: sessionID) }
        }
    }

    // parity: core/src/session/environment.ts#node [status=implemented hash=f295b9fcbf23]
    public static let node: LayerNode.Provider = AppNode.makeGlobalNode(
        Service.serviceKey,
        LayerNode.ExecutableLayer { _, _ in LayerNode.Output([Service.serviceKey: Service()]) },
        []
    )
}

// MARK: - session/affinity.ts

/// Computes provider prompt-cache routing affinity for a Session (`packages/core/src/session/affinity.ts`).
public enum CoreSessionAffinity {
    // parity: core/src/session/affinity.ts#get [status=implemented hash=24e44b4a3024]
    public static func get(_ session: SessionSchema.Info) -> SessionID {
        session.parentID ?? session.fork?.sessionID ?? session.id
    }
}

// MARK: - session/instruction-entry.ts

/// Session-scoped custom instruction entries persisted in `instruction_entry` (`packages/core/src/session/instruction-entry.ts`).
public enum CoreSessionInstructionEntry {
    // parity: core/src/session/instruction-entry.ts#Key [status=implemented hash=642d31e7e025]
    public typealias Key = String

    // parity: core/src/session/instruction-entry.ts#Info [status=implemented hash=cfc96f92d67c]
    public struct Info: Equatable, Hashable, Sendable, Codable {
        public let key: Key
        public let value: JSONValue

        public init(key: Key, value: JSONValue) {
            self.key = key
            self.value = value
        }
    }

    // parity: core/src/session/instruction-entry.ts#Snapshot [status=implemented hash=db9d4eef4884]
    public typealias Snapshot = [SessionEventSchema.InstructionEntrySnapshotItem]

    // parity: core/src/session/instruction-entry.ts#MaxValueBytes [status=implemented hash=dcc2866bf5a2]
    public static let maxValueBytes: Int = 64 * 1024

    // parity: core/src/session/instruction-entry.ts#ValueTooLargeError [status=implemented hash=081263642677]
    public struct ValueTooLargeError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public let actualBytes: Int
        public let maxBytes: Int
        public let message: String

        public init(actualBytes: Int, maxBytes: Int = CoreSessionInstructionEntry.maxValueBytes) {
            self.actualBytes = actualBytes
            self.maxBytes = maxBytes
            self.message = "Instruction entry value is \(actualBytes) bytes; the limit is \(maxBytes) bytes"
        }

        public var description: String { message }
    }

    // parity: core/src/session/instruction-entry.ts#snapshot [status=implemented hash=45682931b0be]
    public static func snapshot(db: any SQLiteDatabase, sessionID: SessionID) throws -> Snapshot {
        try fetchRows(db: db, sessionID: sessionID, includeRemoved: true)
    }

    private static func fetchRows(
        db: any SQLiteDatabase,
        sessionID: SessionID,
        includeRemoved: Bool
    ) throws -> Snapshot {
        let sql = includeRemoved
            ? "SELECT `key`, `value`, `removed` FROM `instruction_entry` WHERE `session_id` = ? ORDER BY `key` ASC"
            : "SELECT `key`, `value`, `removed` FROM `instruction_entry` WHERE `session_id` = ? AND `removed` = 0 ORDER BY `key` ASC"
        let rows = try db.query(sql, parameters: [.text(sessionID.rawValue)])
        return rows.compactMap { row in
            guard let key = row.string("key") else { return nil }
            let val: JSONValue = row.string("value").flatMap { try? CoreBusJSON.decodeJSONValue($0) } ?? .null
            let removed = (row.int64("removed") ?? 0) != 0
            return SessionEventSchema.InstructionEntrySnapshotItem(key: key, value: val, removed: removed)
        }
    }

    // parity: core/src/session/instruction-entry.ts#initialize [status=implemented hash=d199b9cdee11]
    public static func initialize(
        db: any SQLiteDatabase,
        sessionID: SessionID,
        entries: Snapshot,
        created: Int64
    ) throws {
        for entry in entries {
            let valJSON = try CoreBusJSON.encodeJSONValue(entry.value)
            _ = try db.execute(
                """
                INSERT INTO `instruction_entry` (`session_id`, `key`, `value`, `removed`, `time_created`, `time_updated`)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                parameters: [
                    .text(sessionID.rawValue),
                    .text(entry.key),
                    .text(valJSON),
                    .integer(entry.removed ? 1 : 0),
                    .integer(created),
                    .integer(created),
                ]
            )
        }
    }

    // parity: core/src/session/instruction-entry.ts#Interface [status=implemented hash=bbd9f9d2cee2]
    public protocol Interface: Sendable {
        func list(_ sessionID: SessionID) throws -> [Info]
        func put(sessionID: SessionID, key: Key, value: JSONValue) throws
        func remove(sessionID: SessionID, key: Key) throws
        func load(_ sessionID: SessionID) throws -> CoreInstruction.Instructions.List
    }

    // parity: core/src/session/instruction-entry.ts#Service [status=implemented hash=fca79d25d218]
    public final class Service: Interface, Sendable {
        public static let serviceKey = "@opencode/InstructionEntry"
        public let db: any SQLiteDatabase

        public init(db: any SQLiteDatabase) {
            self.db = db
        }

        public func list(_ sessionID: SessionID) throws -> [Info] {
            try fetchRows(db: db, sessionID: sessionID, includeRemoved: false)
                .map { Info(key: $0.key, value: $0.value) }
        }

        public func put(sessionID: SessionID, key: Key, value: JSONValue) throws {
            let encoded = try CoreBusJSON.encodeJSONValue(value)
            let byteCount = encoded.utf8.count
            if byteCount > CoreSessionInstructionEntry.maxValueBytes {
                throw ValueTooLargeError(actualBytes: byteCount)
            }
            let now = Flock.currentEpochMs()
            _ = try db.execute(
                """
                INSERT INTO `instruction_entry` (`session_id`, `key`, `value`, `removed`, `time_created`, `time_updated`)
                VALUES (?, ?, ?, 0, ?, ?)
                ON CONFLICT (`session_id`, `key`) DO UPDATE SET
                  `value` = excluded.`value`,
                  `removed` = 0,
                  `time_updated` = excluded.`time_updated`
                WHERE `instruction_entry`.`removed` = 1
                   OR `instruction_entry`.`value` IS NOT excluded.`value`
                """,
                parameters: [
                    .text(sessionID.rawValue),
                    .text(key),
                    .text(encoded),
                    .integer(now),
                    .integer(now),
                ]
            )
        }

        public func remove(sessionID: SessionID, key: Key) throws {
            _ = try db.execute(
                """
                UPDATE `instruction_entry`
                SET `value` = NULL, `removed` = 1, `time_updated` = ?
                WHERE `session_id` = ? AND `key` = ? AND `removed` = 0
                """,
                parameters: [.integer(Flock.currentEpochMs()), .text(sessionID.rawValue), .text(key)]
            )
        }

        /// One `api/<key>` instruction source per entry row; a removed row reads as `Instructions.removed`.
        public func load(_ sessionID: SessionID) throws -> CoreInstruction.Instructions.List {
            typealias Instructions = CoreInstruction.Instructions
            let sources: [Instructions.List] = try fetchRows(db: db, sessionID: sessionID, includeRemoved: true).compactMap { entry in
                guard let sourceKey = Instructions.Key(rawValue: "api/\(entry.key)") else { return nil }
                let key = entry.key
                let observed: Instructions.Observation<JSONValue> = entry.removed ? .removed : .value(entry.value)
                return [Instructions.Source(
                    key: sourceKey,
                    read: { observed },
                    initial: { val in Self.renderBlock(key: key, value: val) },
                    changed: { _, val in
                        "The context under \"\(key)\" changed and supersedes the previous value:\n\(Self.renderBlock(key: key, value: val))"
                    },
                    removed: { _ in "The context under \"\(key)\" no longer applies. Disregard it." }
                )]
            }
            return (try? Instructions.combine(sources)) ?? sources.flatMap { $0 }
        }

        private static func renderBlock(key: String, value: JSONValue) -> String {
            let rendered: String
            if case .string(let s) = value {
                rendered = s
            } else {
                rendered = (try? CoreBusJSON.encodeJSONValue(value)) ?? ""
            }
            return "<context key=\"\(key)\">\n\(rendered)\n</context>"
        }
    }

    // parity: core/src/session/instruction-entry.ts#node [status=adapted hash=788769187e33]
    public static let node: LayerNode.Provider = AppNode.makeGlobalNode(
        Service.serviceKey,
        LayerNode.ExecutableLayer { deps, _ in
            guard let db = deps.get(CoreDatabaseStore.Service.serviceKey, as: CoreDatabaseStore.Service.self)?.db else {
                throw SQLiteError.databaseClosed
            }
            return LayerNode.Output([Service.serviceKey: Service(db: db)])
        },
        [CoreDatabaseStore.node]
    )
}

// MARK: - session/instruction-state.ts

/// Epoch-based instruction baseline, hash-blob deduplication, delta observation, and rewind
/// (`packages/core/src/session/instruction-state.ts`).
public enum CoreSessionInstructionState {
    /// One observed instruction source: an `Instructions.Source` after `read`, with its renderers. An empty
    /// rendering means the source contributes no text (upstream's `undefined`).
    public struct Source: Sendable {
        public let key: String
        /// The observed value; nil when the source reads as removed or is unavailable.
        public let value: JSONValue?
        /// The source could not be read (`Instructions.unavailable`): its previous value stands, and a Session's
        /// first baseline waits for it (`Instructions.InitializationBlocked`).
        public let unavailable: Bool
        public let renderInitial: @Sendable (JSONValue) -> String
        /// Renders a replacement; when there is no previous value the update restates the source with `renderInitial`.
        public let renderChanged: @Sendable (JSONValue?, JSONValue) -> String
        public let renderRemoved: @Sendable () -> String
        private let renderRemovedFrom: @Sendable (JSONValue) -> String

        public static func defaultRender(_ val: JSONValue) -> String {
            if case .string(let s) = val { return s }
            return (try? CoreBusJSON.encodeJSONValue(val)) ?? ""
        }

        public init(
            key: String,
            value: JSONValue?,
            renderInitial: @escaping @Sendable (JSONValue) -> String = { CoreSessionInstructionState.Source.defaultRender($0) },
            renderChanged: @escaping @Sendable (JSONValue?, JSONValue) -> String = { _, val in CoreSessionInstructionState.Source.defaultRender(val) },
            renderRemoved: @escaping @Sendable () -> String = { "" },
            unavailable: Bool = false
        ) {
            self.key = key
            self.value = value
            self.unavailable = unavailable
            self.renderInitial = renderInitial
            self.renderChanged = renderChanged
            self.renderRemoved = renderRemoved
            self.renderRemovedFrom = { _ in renderRemoved() }
        }

        private init(observing source: CoreInstruction.Instructions.Source, observed: CoreInstruction.Instructions.Observation<JSONValue>) {
            self.key = source.key.rawValue
            switch observed {
            case .value(let value):
                self.value = value
                self.unavailable = false
            case .removed:
                self.value = nil
                self.unavailable = false
            case .unavailable:
                self.value = nil
                self.unavailable = true
            }
            self.renderInitial = { source.initial($0) ?? "" }
            self.renderChanged = { previous, next in
                guard let previous else { return source.initial(next) ?? "" }
                return source.changed(previous, next) ?? ""
            }
            self.renderRemoved = { "" }
            self.renderRemovedFrom = { source.removed($0) ?? "" }
        }

        /// Reads one `Instructions.Source` (`Instructions.read`) into an observed source.
        public static func read(_ source: CoreInstruction.Instructions.Source) async -> Source {
            Source(observing: source, observed: await source.read())
        }

        /// The text that retires this source, given the value the model last saw.
        public func renderRemoved(previous: JSONValue) -> String {
            renderRemovedFrom(previous)
        }
    }

    /// Reads every source of an `Instructions.List` concurrently, keeping list order (`Instructions.read`).
    public static func read(_ list: CoreInstruction.Instructions.List) async -> [Source] {
        await withTaskGroup(of: (Int, Source).self) { group in
            for (index, source) in list.enumerated() {
                group.addTask { (index, await Source.read(source)) }
            }
            var observed: [(Int, Source)] = []
            observed.reserveCapacity(list.count)
            for await item in group { observed.append(item) }
            return observed.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    public struct RenderedInstruction: Equatable, Hashable, Sendable {
        public let key: String
        public let text: String

        public init(key: String, text: String) {
            self.key = key
            self.text = text
        }
    }

    // parity: core/src/session/instruction-state.ts#Observation [status=implemented hash=329a5b04780b]
    public struct Observation: Equatable, Sendable {
        public let sessionID: SessionID
        public let initial: Bool
        public let previous: [String: String]
        public let current: [String: String]
        public let delta: [String: SessionEventSchema.InstructionDeltaValue]
        public let blobs: [String: JSONValue]

        public init(
            sessionID: SessionID,
            initial: Bool,
            previous: [String: String],
            current: [String: String],
            delta: [String: SessionEventSchema.InstructionDeltaValue],
            blobs: [String: JSONValue]
        ) {
            self.sessionID = sessionID
            self.initial = initial
            self.previous = previous
            self.current = current
            self.delta = delta
            self.blobs = blobs
        }
    }

    private struct StoredState {
        let epochStart: Int64
        let throughSeq: Int64
        let initialValues: [String: String]
        let currentValues: [String: String]
    }

    private static func findState(db: any SQLiteDatabase, sessionID: SessionID) throws -> StoredState? {
        guard let row = try db.queryOne(
            "SELECT `epoch_start`, `through_seq`, `initial_values`, `current_values` FROM `instruction_state` WHERE `session_id` = ?",
            parameters: [.text(sessionID.rawValue)]
        ),
              let epochStart = row.int64("epoch_start"),
              let throughSeq = row.int64("through_seq"),
              let initRaw = row.string("initial_values"),
              let currRaw = row.string("current_values")
        else { return nil }
        let initialValues = (try? CoreBusJSON.decodeFromString(initRaw, as: [String: String].self)) ?? [:]
        let currentValues = (try? CoreBusJSON.decodeFromString(currRaw, as: [String: String].self)) ?? [:]
        return StoredState(
            epochStart: epochStart,
            throughSeq: throughSeq,
            initialValues: initialValues,
            currentValues: currentValues
        )
    }

    private static func hashJSONValue(_ value: JSONValue) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        return Hash.sha256(Array(data))
    }

    private static func applyHashDelta(
        _ base: [String: String],
        delta: [String: SessionEventSchema.InstructionDeltaValue]
    ) -> [String: String] {
        var next = base
        for (key, value) in delta {
            switch value {
            case .removed:
                next.removeValue(forKey: key)
            case .hash(let hash):
                next[key] = hash
            }
        }
        return next
    }

    private static func diffSources(
        _ sources: [Source],
        previous: [String: String]
    ) throws -> (current: [String: String], delta: [String: SessionEventSchema.InstructionDeltaValue], blobs: [String: JSONValue]) {
        // `Instructions.diff`: an unavailable source keeps its previous value, a removed one retires a value the
        // model saw, and only changed values are admitted as blobs. Keys no source reports are left as they are.
        var delta: [String: SessionEventSchema.InstructionDeltaValue] = [:]
        var blobs: [String: JSONValue] = [:]

        for source in sources where !source.unavailable {
            if let val = source.value {
                let h = try hashJSONValue(val)
                if previous[source.key] != h {
                    delta[source.key] = .hash(h)
                    blobs[h] = val
                }
            } else if previous[source.key] != nil {
                delta[source.key] = .removed
            }
        }
        let current = applyHashDelta(previous, delta: delta)
        return (current, delta, blobs)
    }

    private static func insertBlobs(db: any SQLiteDatabase, blobs: [String: JSONValue]) throws {
        for (hash, value) in blobs {
            let json = try CoreBusJSON.encodeJSONValue(value)
            _ = try db.execute(
                "INSERT INTO `instruction_blob` (`hash`, `value`) VALUES (?, ?) ON CONFLICT (`hash`) DO NOTHING",
                parameters: [.text(hash), .text(json)]
            )
        }
    }

    private static func loadBlobs(db: any SQLiteDatabase, hashes: [String]) throws -> [String: JSONValue] {
        let unique = Array(Set(hashes))
        guard !unique.isEmpty else { return [:] }
        var map: [String: JSONValue] = [:]
        for batch in CoreDatabaseSchema.batches(unique, perItem: 1) {
            let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ", ")
            let rows = try db.query(
                "SELECT `hash`, `value` FROM `instruction_blob` WHERE `hash` IN (\(placeholders))",
                parameters: batch.map(SQLiteValue.text)
            )
            for row in rows {
                if let h = row.string("hash"), let raw = row.string("value"), let val = try? CoreBusJSON.decodeJSONValue(raw) {
                    map[h] = val
                }
            }
        }
        return map
    }

    private static func renderInitial(
        sources: [Source],
        values: [String: String],
        blobs: [String: JSONValue]
    ) -> [RenderedInstruction] {
        sources.compactMap { source in
            guard let hash = values[source.key], let val = blobs[hash] else { return nil }
            let rendered = source.renderInitial(val)
            return rendered.isEmpty ? nil : RenderedInstruction(key: source.key, text: rendered)
        }
    }

    /// `Instructions.diff` without a stored baseline: an unavailable source blocks the first baseline.
    private static func assertInitializable(_ sources: [Source]) throws(CoreInstruction.Instructions.InitializationBlocked) {
        let blocked = sources.filter(\.unavailable).compactMap { CoreInstruction.Instructions.Key(rawValue: $0.key) }
        if !blocked.isEmpty { throw CoreInstruction.Instructions.InitializationBlocked(keys: blocked) }
    }

    /// `Instructions.renderUpdate`: changed sources in list order; a source new to the Session restates its
    /// initial text, and a removed one renders against the value the model last saw.
    private static func renderUpdate(
        sources: [Source],
        previous: [String: JSONValue],
        delta: [String: SessionEventSchema.InstructionDeltaValue],
        blobs: [String: JSONValue]
    ) -> String {
        var chunks: [String] = []
        for source in sources {
            guard let change = delta[source.key] else { continue }
            let rendered: String
            switch change {
            case .removed:
                guard let before = previous[source.key] else { continue }
                rendered = source.renderRemoved(previous: before)
            case .hash(let h):
                guard let nextVal = blobs[h] else { continue }
                if let before = previous[source.key] {
                    rendered = source.renderChanged(before, nextVal)
                } else {
                    rendered = source.renderInitial(nextVal)
                }
            }
            if !rendered.isEmpty { chunks.append(rendered) }
        }
        return chunks.joined(separator: "\n\n")
    }

    // parity: core/src/session/instruction-state.ts#observe [status=implemented hash=9886361554b4]
    public static func observe(
        db: any SQLiteDatabase,
        sources: [Source],
        sessionID: SessionID
    ) throws -> Observation {
        let stored = try findState(db: db, sessionID: sessionID)
        if stored == nil { try assertInitializable(sources) }
        let prev = stored?.currentValues ?? [:]
        let diff = try diffSources(sources, previous: prev)
        return Observation(
            sessionID: sessionID,
            initial: stored == nil,
            previous: prev,
            current: diff.current,
            delta: diff.delta,
            blobs: diff.blobs
        )
    }

    // parity: core/src/session/instruction-state.ts#commit [status=implemented hash=34498b241ce2]
    public static func commit(
        db: any SQLiteDatabase,
        bus: CoreBus.Service,
        sources: [Source],
        observation: Observation
    ) async throws {
        if !observation.initial && observation.delta.isEmpty { return }
        let text: String
        if observation.initial {
            text = ""
        } else {
            let prevHashes = observation.previous.filter { observation.delta[$0.key] != nil }.values
            let loadedPrev = try loadBlobs(db: db, hashes: Array(prevHashes))
            var prevValues: [String: JSONValue] = [:]
            for (k, h) in observation.previous where observation.delta[k] != nil {
                if let v = loadedPrev[h] { prevValues[k] = v }
            }
            text = renderUpdate(sources: sources, previous: prevValues, delta: observation.delta, blobs: observation.blobs)
        }
        let blobsToInsert = observation.blobs
        _ = try await bus.publish(
            SessionEventSchema.InstructionsUpdated,
            data: SessionEventSchema.InstructionsUpdatedData(
                sessionID: observation.sessionID,
                delta: observation.delta,
                text: text.isEmpty ? nil : text
            ),
            options: CoreBus.PublishOptions(
                metadata: observation.initial ? ["instructions": .object(["initial": .bool(true)])] : nil,
                commit: { _ in
                    try insertBlobs(db: db, blobs: blobsToInsert)
                }
            )
        )
    }

    // parity: core/src/session/instruction-state.ts#prepare [status=implemented hash=b4ef72814850]
    public static func prepare(
        db: any SQLiteDatabase,
        bus: CoreBus.Service,
        sources: [Source],
        sessionID: SessionID
    ) async throws {
        let obs = try observe(db: db, sources: sources, sessionID: sessionID)
        try await commit(db: db, bus: bus, sources: sources, observation: obs)
    }

    // parity: core/src/session/instruction-state.ts#apply [status=implemented hash=00f335f35766]
    public static func apply(
        db: any SQLiteDatabase,
        sessionID: SessionID,
        seq: Int64,
        delta: [String: SessionEventSchema.InstructionDeltaValue]
    ) throws {
        let stored = try findState(db: db, sessionID: sessionID)
        let current = applyHashDelta(stored?.currentValues ?? [:], delta: delta)
        if stored == nil {
            try initialize(db: db, sessionID: sessionID, seq: seq, values: current)
            return
        }
        let currentJSON = try CoreBusJSON.encodeToString(current)
        _ = try db.execute(
            "UPDATE `instruction_state` SET `through_seq` = ?, `current_values` = ? WHERE `session_id` = ?",
            parameters: [.integer(seq), .text(currentJSON), .text(sessionID.rawValue)]
        )
    }

    // parity: core/src/session/instruction-state.ts#initialize [status=implemented hash=ead958b40557]
    public static func initialize(
        db: any SQLiteDatabase,
        sessionID: SessionID,
        seq: Int64,
        values: [String: String]
    ) throws {
        let json = try CoreBusJSON.encodeToString(values)
        _ = try db.execute(
            """
            INSERT INTO `instruction_state` (`session_id`, `epoch_start`, `through_seq`, `initial_values`, `current_values`)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT (`session_id`) DO NOTHING
            """,
            parameters: [
                .text(sessionID.rawValue),
                .integer(seq),
                .integer(seq),
                .text(json),
                .text(json),
            ]
        )
    }

    // parity: core/src/session/instruction-state.ts#advanceEpoch [status=implemented hash=183f9c92f63c]
    public static func advanceEpoch(db: any SQLiteDatabase, sessionID: SessionID, epochStart: Int64) throws {
        _ = try db.execute(
            """
            UPDATE `instruction_state`
            SET `epoch_start` = ?, `through_seq` = ?, `initial_values` = `current_values`
            WHERE `session_id` = ?
            """,
            parameters: [.integer(epochStart), .integer(epochStart), .text(sessionID.rawValue)]
        )
    }

    // parity: core/src/session/instruction-state.ts#rewind [status=implemented hash=dfb959c8b1e4]
    public static func rewind(db: any SQLiteDatabase, sessionID: SessionID, boundary: Int64) throws {
        _ = try db.execute(
            "DELETE FROM `instruction_state` WHERE `session_id` = ? AND `through_seq` >= ?",
            parameters: [.text(sessionID.rawValue), .integer(boundary)]
        )
    }

    // parity: core/src/session/instruction-state.ts#initial [status=implemented hash=40903e9ccd94]
    public static func initial(
        db: any SQLiteDatabase,
        sessionID: SessionID,
        sources: [Source]
    ) throws -> [RenderedInstruction] {
        guard let stored = try findState(db: db, sessionID: sessionID) else {
            return []
        }
        let blobs = try loadBlobs(db: db, hashes: Array(stored.initialValues.values))
        return renderInitial(sources: sources, values: stored.initialValues, blobs: blobs)
    }

    // parity: core/src/session/instruction-state.ts#current [status=implemented hash=9123e960937d]
    public static func current(db: any SQLiteDatabase, sessionID: SessionID) throws -> [String: String]? {
        try findState(db: db, sessionID: sessionID)?.currentValues
    }

    // parity: core/src/session/instruction-state.ts#epochStart [status=implemented hash=eb9579c2e9d1]
    public static func epochStart(db: any SQLiteDatabase, sessionID: SessionID) throws -> Int64? {
        try findState(db: db, sessionID: sessionID)?.epochStart
    }

    // parity: core/src/session/instruction-state.ts#preview [status=implemented hash=9e85a9f4c0f8]
    public static func preview(
        db: any SQLiteDatabase,
        sessionID: SessionID,
        sources: [Source]
    ) throws -> (initial: [RenderedInstruction], update: String) {
        let stored = try findState(db: db, sessionID: sessionID)
        if stored == nil { try assertInitializable(sources) }
        let diff = try diffSources(sources, previous: stored?.currentValues ?? [:])
        guard let stored else {
            return (renderInitial(sources: sources, values: diff.current, blobs: diff.blobs), "")
        }
        let storedBlobs = try loadBlobs(
            db: db,
            hashes: Array(stored.initialValues.values) + Array(stored.currentValues.values)
        )
        var prevValues: [String: JSONValue] = [:]
        for (k, h) in stored.currentValues {
            if let v = storedBlobs[h] { prevValues[k] = v }
        }
        let initial = renderInitial(sources: sources, values: stored.initialValues, blobs: storedBlobs)
        let update = renderUpdate(sources: sources, previous: prevValues, delta: diff.delta, blobs: diff.blobs)
        return (initial, update)
    }
}

// MARK: - session/instructions.ts

/// Deduplicated on-demand AGENTS.md / instruction-file injection into session synthetic history
/// (`packages/core/src/session/instructions.ts`).
public enum CoreSessionInstructions {
    // parity: core/src/session/instructions.ts#Interface [status=implemented hash=af7171ae8d45]
    public protocol Interface: Sendable {
        func load(sessionID: SessionID, paths: [String]) async throws
    }

    // parity: core/src/session/instructions.ts#Service [status=implemented hash=3a66f86e06e1]
    public final class Service: Interface, Sendable {
        public static let serviceKey = "@opencode/SessionInstructions"
        public let bus: CoreBus.Service
        public let db: any SQLiteDatabase
        public let fileSystem: any OpenCodeFileSystem
        public let projectRoot: String

        private let inFlight = Mutex<[SessionID: Set<String>]>([:])

        public init(
            bus: CoreBus.Service,
            db: any SQLiteDatabase,
            fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
            projectRoot: String
        ) {
            self.bus = bus
            self.db = db
            self.fileSystem = fileSystem
            self.projectRoot = projectRoot
        }

        public func load(sessionID: SessionID, paths: [String]) async throws {
            let claimed: [String] = inFlight.withLock { map in
                let existing = map[sessionID] ?? []
                let newlyClaimed = paths.filter { !existing.contains($0) }
                if newlyClaimed.isEmpty { return [] }
                map[sessionID] = existing.union(newlyClaimed)
                return newlyClaimed
            }
            if claimed.isEmpty { return }

            defer {
                inFlight.withLock { map in
                    guard var existing = map[sessionID] else { return }
                    existing.subtract(claimed)
                    if existing.isEmpty {
                        map.removeValue(forKey: sessionID)
                    } else {
                        map[sessionID] = existing
                    }
                }
            }

            let already = try previouslyInjected(sessionID: sessionID)
            let toInject = claimed.filter { !already.contains($0) }
            if toInject.isEmpty { return }

            var readable: [(path: String, content: String)] = []
            for path in toInject {
                if let bytes = try? await fileSystem.readFile(at: path) {
                    readable.append((path, String(decoding: bytes, as: UTF8.self)))
                }
            }
            if readable.isEmpty { return }

            let text = readable.map { "Instructions from: \($0.path)\n\($0.content)" }.joined(separator: "\n\n")
            let desc = "Loaded \(readable.map { describePath($0.path) }.joined(separator: ", "))"
            _ = try await bus.publish(
                SessionEventSchema.Synthetic,
                data: SessionEventSchema.SyntheticData(
                    sessionID: sessionID,
                    text: text,
                    description: desc,
                    metadata: ["instruction": .object(["paths": .array(readable.map { .string($0.path) })])]
                )
            )
        }

        private func previouslyInjected(sessionID: SessionID) throws -> Set<String> {
            let messages = try CoreSessionHistory.synthetics(db, sessionID: sessionID)
            var seen = Set<String>()
            for msg in messages {
                guard case .synthetic(let s) = msg,
                      case .object(let instr) = s.metadata?["instruction"],
                      case .array(let paths) = instr["paths"]
                else { continue }
                for p in paths {
                    if case .string(let path) = p { seen.insert(path) }
                }
            }
            return seen
        }

        private func describePath(_ path: String) -> String {
            let prefix = projectRoot.hasSuffix("/") ? projectRoot : projectRoot + "/"
            if path.hasPrefix(prefix) {
                return String(path.dropFirst(prefix.count))
            }
            return path
        }
    }

    // parity: core/src/session/instructions.ts#node [status=adapted hash=11fa6213d177]
    public static let node: LayerNode.Provider = AppNode.makeLocationNode(
        Service.serviceKey,
        LayerNode.ExecutableLayer { deps, _ in
            guard let bus = deps.get(CoreBus.Service.serviceKey, as: CoreBus.Service.self),
                  let db = deps.get(CoreDatabaseStore.Service.serviceKey, as: CoreDatabaseStore.Service.self)?.db
            else {
                throw SQLiteError.databaseClosed
            }
            let fs = deps.get(LayerNodePlatform.fileSystemKey, as: (any OpenCodeFileSystem).self) ?? LocalFileSystem.shared
            let root = deps.get("@opencode/LocationDirectory", as: String.self) ?? "/"
            return LayerNode.Output([Service.serviceKey: Service(bus: bus, db: db, fileSystem: fs, projectRoot: root)])
        },
        [CoreBus.node, CoreDatabaseStore.node]
    )
}
