#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import OpenCodeAI
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

// MARK: - Snapshot Bridge (decoupled from sibling Snapshot module)

public protocol CoreSessionSnapshotBridge: Sendable {
    func capture() async throws -> String?
    func restore(files: [String: String]) async throws
    func diff(from: String, to: String, paths: [String]?) async throws -> [SessionSchema.FileDiffInfo]
}

public struct CoreSessionNoopSnapshotBridge: CoreSessionSnapshotBridge, Sendable {
    public init() {}
    public func capture() async throws -> String? { nil }
    public func restore(files: [String: String]) async throws {}
    public func diff(from: String, to: String, paths: [String]?) async throws -> [SessionSchema.FileDiffInfo] { [] }
}

/// Concrete `CoreSessionSnapshotBridge` wired directly to a real `CoreSnapshot.Service` (or any `CoreSnapshot.Interface`).
public struct CoreSessionLiveSnapshotBridge: CoreSessionSnapshotBridge, Sendable {
    public let service: any CoreSnapshot.Interface

    public init(service: any CoreSnapshot.Interface) {
        self.service = service
    }

    public init(
        directory: String,
        fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
        enabled: Bool = true
    ) {
        self.service = CoreSnapshot.Service(directory: directory, fileSystem: fileSystem, enabled: enabled)
    }

    public func capture() async throws -> String? {
        await service.capture()?.rawValue
    }

    public func restore(files: [String: String]) async throws {
        var mapped: [SchemaPrimitive.RelativePath: CoreSnapshot.ID] = [:]
        mapped.reserveCapacity(files.count)
        for (path, snapshotID) in files {
            mapped[SchemaPrimitive.RelativePath(rawValue: path)] = CoreSnapshot.ID(rawValue: snapshotID)
        }
        try await service.restore(CoreSnapshot.RestoreInput(files: mapped))
    }

    public func diff(from: String, to: String, paths: [String]?) async throws -> [SessionSchema.FileDiffInfo] {
        let relPaths = paths?.map { SchemaPrimitive.RelativePath(rawValue: $0) }
        let entries = try await service.diff(CoreSnapshot.DiffInput(
            from: CoreSnapshot.ID(rawValue: from),
            to: CoreSnapshot.ID(rawValue: to),
            paths: relPaths
        ))
        return entries.map { entry in
            let mappedStatus: SessionSchema.FileDiffInfo.Status
            switch entry.status {
            case .added: mappedStatus = .added
            case .deleted: mappedStatus = .deleted
            case .modified: mappedStatus = .modified
            }
            return SessionSchema.FileDiffInfo(
                file: entry.file,
                patch: entry.patch,
                additions: entry.additions.rawValue,
                deletions: entry.deletions.rawValue,
                status: mappedStatus,
                more: entry.more
            )
        }
    }
}

// MARK: - session/revert.ts

/// Stages, clears, and commits session history + workspace reverts (`packages/core/src/session/revert.ts`).
public enum CoreSessionRevert {
    // parity: core/src/session/revert.ts#stage [status=implemented hash=566591ac1964]
    public static func stage(
        db: any SQLiteDatabase,
        bus: CoreBus.Service,
        session: SessionSchema.Info,
        messageID: SessionMessageSchema.ID,
        restoreFiles: Bool = true,
        snapshot: any CoreSessionSnapshotBridge = CoreSessionNoopSnapshotBridge()
    ) async throws -> SessionRevertSchema.Revert {
        let original: String?
        if let existing = session.revert?.snapshot {
            original = existing
        } else {
            original = try await snapshot.capture()
        }
        let nextFiles = try plan(db: db, sessionID: session.id, messageID: messageID)
        var restoreMap: [String: String] = [:]
        if let original {
            for file in session.revert?.files ?? [] {
                restoreMap[file.file] = original
            }
        }
        if restoreFiles {
            for (file, tree) in nextFiles {
                restoreMap[file] = tree
            }
        }
        if !restoreMap.isEmpty {
            try await snapshot.restore(files: restoreMap)
        }
        let paths = restoreFiles ? Array(nextFiles.keys) : []
        let diffFiles: [SessionSchema.FileDiffInfo]
        if let original {
            let after = try await snapshot.capture() ?? original
            diffFiles = try await snapshot.diff(from: original, to: after, paths: paths)
        } else {
            diffFiles = []
        }
        let revert = SessionRevertSchema.Revert(
            messageID: messageID,
            snapshot: original,
            files: diffFiles
        )
        _ = try await bus.publish(
            SessionEventSchema.RevertEvent.Staged,
            data: SessionEventSchema.RevertEvent.StagedData(sessionID: session.id, revert: revert)
        )
        return revert
    }

    // parity: core/src/session/revert.ts#clear [status=implemented hash=0d4220d84a9a]
    public static func clear(
        bus: CoreBus.Service,
        session: SessionSchema.Info,
        snapshot: any CoreSessionSnapshotBridge = CoreSessionNoopSnapshotBridge()
    ) async throws {
        guard let revert = session.revert else { return }
        if let original = revert.snapshot, let files = revert.files, !files.isEmpty {
            var map: [String: String] = [:]
            for f in files { map[f.file] = original }
            try await snapshot.restore(files: map)
        }
        _ = try await bus.publish(
            SessionEventSchema.RevertEvent.Cleared,
            data: SessionEventSchema.SessionBaseData(sessionID: session.id)
        )
    }

    // parity: core/src/session/revert.ts#commit [status=implemented hash=0b0f6b2aa57c]
    public static func commit(bus: CoreBus.Service, session: SessionSchema.Info) async throws {
        guard let revert = session.revert else { return }
        _ = try await bus.publish(
            SessionEventSchema.RevertEvent.Committed,
            data: SessionEventSchema.RevertEvent.CommittedData(
                sessionID: session.id,
                to: revert.messageID
            )
        )
    }

    private static func plan(
        db: any SQLiteDatabase,
        sessionID: SessionID,
        messageID: SessionMessageSchema.ID
    ) throws -> [String: String] {
        guard let boundary = try db.queryOne(
            "SELECT `seq` FROM `session_message` WHERE `session_id` = ? AND `id` = ?",
            parameters: [.text(sessionID.rawValue), .text(messageID.rawValue)]
        ), let boundarySeq = boundary.int64("seq") else {
            throw CoreSessionErrors.MessageNotFoundError(sessionID: sessionID, messageID: messageID)
        }
        let rows = try db.query(
            """
            SELECT * FROM `session_message`
            WHERE `session_id` = ? AND `type` = 'assistant' AND `seq` > ?
            ORDER BY `seq` ASC
            """,
            parameters: [.text(sessionID.rawValue), .integer(boundarySeq)]
        )
        var files: [String: String] = [:]
        for row in rows {
            let parsed = try CoreSessionHistory.parseMessageRow(row)
            guard case .assistant(let a) = try CoreSessionHistory.decodeMessageRowSync(parsed),
                  let start = a.snapshot?.start
            else { continue }
            for file in a.snapshot?.files ?? [] where files[file] == nil {
                files[file] = start
            }
        }
        return files
    }
}

// MARK: - session/move.ts

/// Session directory/project relocation service (`packages/core/src/session/move.ts`).
public enum CoreSessionMove {
    // parity: core/src/session/move.ts#DestinationNotFoundError [status=implemented hash=96f2b32e1a81]
    public struct DestinationNotFoundError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public static let tag = "Session.DestinationNotFoundError"
        public let directory: String

        public init(directory: String) {
            self.directory = directory
        }

        public var description: String { "Destination directory not found: \(directory)" }
    }

    // parity: core/src/session/move.ts#DestinationNotDirectoryError [status=implemented hash=c2c7a9a079a8]
    public struct DestinationNotDirectoryError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public static let tag = "Session.DestinationNotDirectoryError"
        public let directory: String

        public init(directory: String) {
            self.directory = directory
        }

        public var description: String { "Destination is not a directory: \(directory)" }
    }

    // parity: core/src/session/move.ts#DestinationUnavailableError [status=implemented hash=a3b0a70b785f]
    public struct DestinationUnavailableError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public static let tag = "Session.DestinationUnavailableError"
        public let directory: String

        public init(directory: String) {
            self.directory = directory
        }

        public var description: String { "Destination unavailable: \(directory)" }
    }

    public struct MoveInput: Equatable, Hashable, Sendable {
        public let sessionID: SessionID
        public let directory: String
        public let workspaceID: WorkspaceID?
        public let delivery: SessionInboxSchema.Delivery?

        public init(
            sessionID: SessionID,
            directory: String,
            workspaceID: WorkspaceID? = nil,
            delivery: SessionInboxSchema.Delivery? = nil
        ) {
            self.sessionID = sessionID
            self.directory = directory
            self.workspaceID = workspaceID
            self.delivery = delivery
        }
    }

    // parity: core/src/session/move.ts#Interface [status=implemented hash=5f7e55f01500]
    public protocol Interface: Sendable {
        func move(_ input: MoveInput) async throws
    }

    // parity: core/src/session/move.ts#Service [status=implemented hash=181b33ae7840]
    public final class Service: Interface, Sendable {
        public static let serviceKey = "@opencode/SessionMove"
        public let db: any SQLiteDatabase
        public let bus: CoreBus.Service
        public let store: any CoreSessionStore.Interface
        public let inbox: any CoreSessionInbox.Interface
        public let execution: any CoreSessionExecution.Interface
        public let fileSystem: any OpenCodeFileSystem
        public let resolveProject: @Sendable (String) async throws -> (id: ProjectID, directory: String)

        public init(
            db: any SQLiteDatabase,
            bus: CoreBus.Service,
            store: any CoreSessionStore.Interface,
            inbox: any CoreSessionInbox.Interface,
            execution: any CoreSessionExecution.Interface,
            fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
            resolveProject: @escaping @Sendable (String) async throws -> (id: ProjectID, directory: String) = { dir in
                (ProjectID.global, dir)
            }
        ) {
            self.db = db
            self.bus = bus
            self.store = store
            self.inbox = inbox
            self.execution = execution
            self.fileSystem = fileSystem
            self.resolveProject = resolveProject
        }

        public func move(_ input: MoveInput) async throws {
            guard let session = try store.get(input.sessionID) else {
                throw CoreSessionErrors.NotFoundError(sessionID: input.sessionID)
            }
            let target = input.directory.trimmingCharacters(in: .whitespacesAndNewlines)
            let stat: FileStat
            do {
                stat = try await fileSystem.stat(at: target)
            } catch {
                throw DestinationNotFoundError(directory: target)
            }
            guard stat.type == .directory else {
                throw DestinationNotDirectoryError(directory: target)
            }

            let project = try await resolveProject(target)
            let subpath: String
            if target == project.directory {
                subpath = ""
            } else if target.hasPrefix(project.directory + "/") {
                subpath = String(target.dropFirst(project.directory.count + 1))
            } else {
                subpath = ""
            }
            let location = OpenCodeLocation(directory: target, workspaceID: input.workspaceID)

            let active = await execution.isActive(session.id)
            if !active && input.delivery == nil {
                _ = try await bus.publish(
                    SessionEventSchema.Moved,
                    data: SessionEventSchema.MovedData(
                        sessionID: session.id,
                        location: location,
                        projectID: project.id,
                        subpath: subpath.isEmpty ? nil : subpath
                    ),
                    options: CoreBus.PublishOptions(location: location)
                )
                return
            }

            let id = SessionMessageSchema.ID.create()
            _ = try await inbox.admit(
                id: id,
                sessionID: session.id,
                item: .move(
                    payload: SessionInboxSchema.MovePayload(
                        location: location,
                        projectID: project.id,
                        subpath: subpath
                    ),
                    delivery: input.delivery ?? .steer
                )
            )
            await execution.wake(session.id)
        }
    }

    // parity: core/src/session/move.ts#node [status=adapted hash=1fb9ad70fcac]
    public static let node: LayerNode.Provider = AppNode.makeGlobalNode(
        Service.serviceKey,
        LayerNode.ExecutableLayer { deps, _ in
            guard let db = deps.get(CoreDatabaseStore.Service.serviceKey, as: CoreDatabaseStore.Service.self)?.db,
                  let bus = deps.get(CoreBus.Service.serviceKey, as: CoreBus.Service.self),
                  let store = deps.get(CoreSessionStore.Service.serviceKey, as: CoreSessionStore.Service.self),
                  let inbox = deps.get(CoreSessionInbox.Service.serviceKey, as: CoreSessionInbox.Service.self),
                  let execution = deps.get(CoreSessionExecution.Service.serviceKey, as: (any CoreSessionExecution.Interface).self)
            else {
                throw SQLiteError.databaseClosed
            }
            let fs = deps.get(LayerNodePlatform.fileSystemKey, as: (any OpenCodeFileSystem).self) ?? LocalFileSystem.shared
            return LayerNode.Output([Service.serviceKey: Service(
                db: db,
                bus: bus,
                store: store,
                inbox: inbox,
                execution: execution,
                fileSystem: fs
            )])
        },
        [CoreDatabaseStore.node, CoreBus.node, CoreSessionStore.node, CoreSessionInbox.node, CoreSessionExecution.node]
    )
}

// MARK: - session/diff.ts

/// Computes snapshot diffs across a turn bounded by message IDs (`packages/core/src/session/diff.ts`).
public enum CoreSessionDiff {
    // parity: core/src/session/diff.ts#TurnRangeError [status=implemented hash=6e416d692ab8]
    public struct TurnRangeError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public static let tag = "SessionDiff.TurnRangeError"
        public let sessionID: SessionID
        public let from: SessionMessageSchema.ID
        public let to: SessionMessageSchema.ID

        public init(sessionID: SessionID, from: SessionMessageSchema.ID, to: SessionMessageSchema.ID) {
            self.sessionID = sessionID
            self.from = from
            self.to = to
        }

        public var description: String {
            "Invalid turn range [\(from.rawValue), \(to.rawValue)] in session \(sessionID.rawValue)"
        }
    }

    // parity: core/src/session/diff.ts#turn [status=implemented hash=82d5f5003383]
    public static func turn(
        db: any SQLiteDatabase,
        session: SessionSchema.Info,
        from: SessionMessageSchema.ID,
        to: SessionMessageSchema.ID,
        snapshot: any CoreSessionSnapshotBridge = CoreSessionNoopSnapshotBridge()
    ) async throws -> [SessionSchema.FileDiffInfo] {
        guard let fromRow = try db.queryOne(
            "SELECT `seq` FROM `session_message` WHERE `session_id` = ? AND `id` = ?",
            parameters: [.text(session.id.rawValue), .text(from.rawValue)]
        ), let fromSeq = fromRow.int64("seq") else {
            throw CoreSessionErrors.MessageNotFoundError(sessionID: session.id, messageID: from)
        }
        guard let toRow = try db.queryOne(
            "SELECT `seq` FROM `session_message` WHERE `session_id` = ? AND `id` = ?",
            parameters: [.text(session.id.rawValue), .text(to.rawValue)]
        ), let toSeq = toRow.int64("seq") else {
            throw CoreSessionErrors.MessageNotFoundError(sessionID: session.id, messageID: to)
        }
        guard fromSeq <= toSeq else {
            throw TurnRangeError(sessionID: session.id, from: from, to: to)
        }

        let rows = try db.query(
            """
            SELECT * FROM `session_message`
            WHERE `session_id` = ? AND `type` = 'assistant' AND `seq` >= ? AND `seq` <= ?
            ORDER BY `seq` ASC
            """,
            parameters: [.text(session.id.rawValue), .integer(fromSeq), .integer(toSeq)]
        )
        var startSnap: String? = nil
        var endSnap: String? = nil
        var touched: [String] = []
        var seen = Set<String>()

        for row in rows {
            let parsed = try CoreSessionHistory.parseMessageRow(row)
            guard case .assistant(let a) = try CoreSessionHistory.decodeMessageRowSync(parsed),
                  let snap = a.snapshot
            else { continue }
            if startSnap == nil, let s = snap.start { startSnap = s }
            if let e = snap.end { endSnap = e }
            for file in snap.files ?? [] where seen.insert(file).inserted {
                touched.append(file)
            }
        }
        guard let startSnap, let endSnap else { return [] }
        return try await snapshot.diff(from: startSnap, to: endSnap, paths: touched.isEmpty ? nil : touched)
    }
}

// MARK: - session/stats.ts

/// Aggregates session, step, token, cost, activity, model, and tool usage statistics from SQLite
/// (`packages/core/src/session/stats.ts`).
public enum CoreSessionStats {
    // parity: core/src/session/stats.ts#InvalidRangeError [status=implemented hash=8b305be5bf32]
    public struct InvalidRangeError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public static let tag = "SessionStats.InvalidRangeError"
        public let from: Int64
        public let to: Int64

        public init(from: Int64, to: Int64) {
            self.from = from
            self.to = to
        }

        public var description: String { "Invalid stats range: from (\(from)) >= to (\(to))" }
    }

    public struct QueryInput: Equatable, Hashable, Sendable {
        public let from: Int64?
        public let to: Int64?
        public let projectID: ProjectID?
        public let tools: SessionStatsSchema.ToolMode

        public init(
            from: Int64? = nil,
            to: Int64? = nil,
            projectID: ProjectID? = nil,
            tools: SessionStatsSchema.ToolMode = .summary
        ) {
            self.from = from
            self.to = to
            self.projectID = projectID
            self.tools = tools
        }
    }

    private static func utcDateKey(_ epochMs: Int64) -> String {
        let secs = epochMs / 1000
        let days = secs / 86_400
        // Howard Hinnant civil-from-days algorithm (pure arithmetic, zero Foundation Date/Calendar overhead).
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp + (mp < 10 ? 3 : -9)
        let year = y + (m <= 2 ? 1 : 0)
        let ys = String(year)
        let ms = m < 10 ? "0\(m)" : "\(m)"
        let ds = d < 10 ? "0\(d)" : "\(d)"
        return "\(ys)-\(ms)-\(ds)"
    }

    // parity: core/src/session/stats.ts#get [status=implemented hash=ac9e2319e614]
    public static func get(db: any SQLiteDatabase, input: QueryInput = QueryInput()) throws -> SessionStatsSchema.Info {
        let to = input.to ?? Flock.currentEpochMs()
        if let from = input.from, from >= to {
            throw InvalidRangeError(from: from, to: to)
        }

        var minParams: [SQLiteValue] = [.integer(to)]
        let projectClause: String
        if let pid = input.projectID {
            projectClause = "AND s.`project_id` = ?"
            minParams.append(.text(pid.rawValue))
        } else {
            projectClause = ""
        }

        let from: Int64
        if let explicitFrom = input.from {
            from = explicitFrom
        } else {
            let minRow = try db.queryOne(
                """
                SELECT min(m.`time_created`) AS `time`
                FROM `session_message` m
                JOIN `session_v2` s ON s.`id` = m.`session_id`
                WHERE m.`type` IN ('user', 'assistant')
                  AND m.`time_created` < ?
                  AND (s.`fork_session_id` IS NULL OR m.`time_created` >= s.`time_created`)
                  \(projectClause)
                """,
                parameters: minParams
            )
            from = minRow?.int64("time") ?? to
        }

        var queryParams: [SQLiteValue] = [.integer(from), .integer(to)]
        if let pid = input.projectID {
            queryParams.append(.text(pid.rawValue))
        }

        let rows = try db.query(
            """
            SELECT m.`session_id`, s.`parent_id`, m.`type`, m.`time_created`,
                   json_extract(m.`data`, '$.model.providerID') AS `provider_id`,
                   json_extract(m.`data`, '$.model.id') AS `model_id`,
                   json_extract(m.`data`, '$.model.variant') AS `variant`,
                   json_extract(m.`data`, '$.tokens.input') AS `t_in`,
                   json_extract(m.`data`, '$.tokens.output') AS `t_out`,
                   json_extract(m.`data`, '$.tokens.reasoning') AS `t_reason`,
                   json_extract(m.`data`, '$.tokens.cache.read') AS `t_cread`,
                   json_extract(m.`data`, '$.tokens.cache.write') AS `t_cwrite`,
                   json_extract(m.`data`, '$.cost') AS `cost`
            FROM `session_message` m
            JOIN `session_v2` s ON s.`id` = m.`session_id`
            WHERE m.`type` IN ('user', 'assistant')
              AND m.`time_created` >= ? AND m.`time_created` < ?
              AND (s.`fork_session_id` IS NULL OR m.`time_created` >= s.`time_created`)
              \(projectClause)
            """,
            parameters: queryParams
        )

        var sessions = Set<String>()
        var subagents = Set<String>()
        var prompts = 0
        var steps = 0
        var totalIn = 0.0
        var totalOut = 0.0
        var totalReason = 0.0
        var totalCRead = 0.0
        var totalCWrite = 0.0
        var totalCost = 0.0
        var activityByDay: [String: Int] = [:]

        struct ModelAgg {
            var model: SessionSchema.ModelRef
            var steps: Int = 0
            var input: Double = 0
            var output: Double = 0
            var reasoning: Double = 0
            var cacheRead: Double = 0
            var cacheWrite: Double = 0
            var cost: Double = 0
        }
        var modelsByKey: [String: ModelAgg] = [:]

        for row in rows {
            guard let sid = row.string("session_id"),
                  let type = row.string("type"),
                  let created = row.int64("time_created")
            else { continue }
            if row.string("parent_id") != nil {
                subagents.insert(sid)
            } else {
                sessions.insert(sid)
            }
            if type == "user" {
                prompts += 1
            } else if type == "assistant" {
                steps += 1
                let day = utcDateKey(created)
                activityByDay[day, default: 0] += 1
                let tin = row.double("t_in") ?? 0
                let tout = row.double("t_out") ?? 0
                let treas = row.double("t_reason") ?? 0
                let tcr = row.double("t_cread") ?? 0
                let tcw = row.double("t_cwrite") ?? 0
                let cost = row.double("cost") ?? 0
                totalIn += tin
                totalOut += tout
                totalReason += treas
                totalCRead += tcr
                totalCWrite += tcw
                totalCost += cost
                if let pid = row.string("provider_id"), let mid = row.string("model_id") {
                    let variant = row.string("variant")
                    let key = "\(pid)/\(mid)#\(variant ?? "")"
                    var agg = modelsByKey[key] ?? ModelAgg(
                        model: SessionSchema.ModelRef(id: mid, providerID: pid, variant: variant)
                    )
                    agg.steps += 1
                    agg.input += tin
                    agg.output += tout
                    agg.reasoning += treas
                    agg.cacheRead += tcr
                    agg.cacheWrite += tcw
                    agg.cost += cost
                    modelsByKey[key] = agg
                }
            }
        }

        let toolsResult: SessionStatsSchema.Tools
        switch input.tools {
        case .none:
            toolsResult = .none
        case .summary, .detail:
            let totals = SessionStatsSchema.ToolTotals(calls: 0, succeeded: 0, failed: 0, unfinished: 0)
            toolsResult = (input.tools == .summary) ? .summary(totals: totals) : .detail(totals: totals, usage: [])
        }

        let activity = activityByDay.keys.sorted().map { day in
            SessionStatsSchema.Activity(date: day, steps: activityByDay[day] ?? 0)
        }
        let models = modelsByKey.values
            .sorted { $0.steps > $1.steps }
            .map { agg in
                SessionStatsSchema.ModelUsage(
                    model: agg.model,
                    steps: agg.steps,
                    tokens: SessionSchema.TokenUsage(
                        input: agg.input,
                        output: agg.output,
                        reasoning: agg.reasoning,
                        cache: SessionSchema.TokenUsage.Cache(read: agg.cacheRead, write: agg.cacheWrite)
                    ),
                    cost: agg.cost
                )
            }

        return SessionStatsSchema.Info(
            range: SessionStatsSchema.Info.TimeRange(from: from, to: to),
            sessions: sessions.count,
            subagents: subagents.count,
            prompts: prompts,
            steps: steps,
            tokens: SessionSchema.TokenUsage(
                input: totalIn,
                output: totalOut,
                reasoning: totalReason,
                cache: SessionSchema.TokenUsage.Cache(read: totalCRead, write: totalCWrite)
            ),
            cost: totalCost,
            tools: toolsResult,
            activeDays: activity.count,
            streak: activity.isEmpty ? 0 : 1,
            activity: activity,
            models: models
        )
    }
}

// MARK: - session/transfer.ts

/// Portable session export & import with optional sensitive-data sanitization
/// (`packages/core/src/session/transfer.ts`).
public enum CoreSessionTransfer {
    // parity: core/src/session/transfer.ts#Data [status=implemented hash=d2d2803eb35b]
    public typealias Data = SessionTransferSchema.Data

    // parity: core/src/session/transfer.ts#ImportConflictError [status=implemented hash=97f8584160f0]
    public struct ImportConflictError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public static let tag = "SessionTransfer.ImportConflictError"
        public let sessionID: SessionID

        public init(sessionID: SessionID) {
            self.sessionID = sessionID
        }

        public var description: String { "Session already exists: \(sessionID.rawValue)" }
    }

    // parity: core/src/session/transfer.ts#Interface [status=implemented hash=3b362b9ee997]
    public protocol Interface: Sendable {
        func export(sessionID: SessionID, sanitize: Bool) throws -> Data
        func `import`(data: Data, location: OpenCodeLocation) async throws -> SessionSchema.Info
    }

    private static func isSettled(_ message: SessionMessageSchema.Info) -> Bool {
        switch message {
        case .assistant(let a):
            return a.time.completed != nil
        case .shell(let s):
            return s.status != .running
        case .compaction(let c):
            if case .running = c { return false }
            return true
        default:
            return true
        }
    }

    // parity: core/src/session/transfer.ts#Service [status=implemented hash=f8b3757a1103]
    public final class Service: Interface, Sendable {
        public static let serviceKey = "@opencode/SessionTransfer"
        public let db: any SQLiteDatabase
        public let bus: CoreBus.Service
        public let store: any CoreSessionStore.Interface
        public let version: String

        public init(
            db: any SQLiteDatabase,
            bus: CoreBus.Service,
            store: any CoreSessionStore.Interface,
            version: String = "0.0.0"
        ) {
            self.db = db
            self.bus = bus
            self.store = store
            self.version = version
        }

        public func export(sessionID: SessionID, sanitize: Bool = false) throws -> Data {
            guard let info = try store.get(sessionID) else {
                throw CoreSessionErrors.NotFoundError(sessionID: sessionID)
            }
            let messages = try store.messages(CoreSessionStore.MessagesInput(sessionID: sessionID, order: .asc))
                .filter(CoreSessionTransfer.isSettled)
            if !sanitize {
                return Data(info: info, messages: messages)
            }
            let sanitizedInfo = SessionSchema.Info(
                id: info.id,
                parentID: info.parentID,
                fork: info.fork,
                projectID: ProjectID.global,
                agent: info.agent,
                model: info.model,
                cost: info.cost,
                tokens: info.tokens,
                outcome: info.outcome,
                time: info.time,
                title: info.title,
                location: OpenCodeLocation(directory: "/sanitized"),
                subpath: nil,
                metadata: nil,
                permissions: nil,
                revert: nil
            )
            return Data(info: sanitizedInfo, messages: messages)
        }

        public func `import`(data: Data, location: OpenCodeLocation) async throws -> SessionSchema.Info {
            let sessionID = data.info.id
            if try db.queryOne("SELECT `id` FROM `session_v2` WHERE `id` = ?", parameters: [.text(sessionID.rawValue)]) != nil {
                throw ImportConflictError(sessionID: sessionID)
            }
            if let parentID = data.info.parentID, try store.get(parentID) == nil {
                throw CoreSessionErrors.NotFoundError(sessionID: parentID)
            }
            let projectID = ProjectID.global
            try ensureProjectRow(db: db, id: projectID, worktree: location.directory)

            let settled = data.messages.filter(CoreSessionTransfer.isSettled)
            let info = data.info
            _ = try await bus.publish(
                SessionEventSchema.Created,
                data: SessionEventSchema.CreatedData(
                    sessionID: sessionID,
                    projectID: projectID,
                    location: location,
                    subpath: nil,
                    parentID: info.parentID,
                    slug: "import-\(Identifier.ascending().prefix(8))",
                    title: info.title,
                    agent: info.agent,
                    model: info.model,
                    metadata: info.metadata,
                    permissions: info.permissions,
                    version: version
                ),
                options: CoreBus.PublishOptions(
                    location: location,
                    commit: { [db] seq in
                        for (idx, msg) in settled.enumerated() {
                            let msgSeq = Int64(idx + 1)
                            guard case .object(var dict) = try CoreBusJSON.encodeToJSONValue(msg) else { continue }
                            dict.removeValue(forKey: "id")
                            dict.removeValue(forKey: "type")
                            let jsonStr = try CoreBusJSON.encodeJSONValue(.object(dict))
                            _ = try db.execute(
                                """
                                INSERT INTO `session_message` (`id`, `session_id`, `type`, `seq`, `time_created`, `time_updated`, `data`)
                                VALUES (?, ?, ?, ?, ?, ?, ?)
                                """,
                                parameters: [
                                    .text(msg.id.rawValue),
                                    .text(sessionID.rawValue),
                                    .text(msg.messageType.rawValue),
                                    .integer(msgSeq),
                                    .integer(info.time.created),
                                    .integer(info.time.updated),
                                    .text(jsonStr),
                                ]
                            )
                        }
                        if !settled.isEmpty {
                            try CoreBus.reserveSequence(db: db, aggregateID: sessionID.rawValue, seq: seq + Int64(settled.count))
                        }
                        _ = try db.execute(
                            """
                            UPDATE `session_v2`
                            SET `cost` = ?, `tokens_input` = ?, `tokens_output` = ?, `tokens_reasoning` = ?,
                                `tokens_cache_read` = ?, `tokens_cache_write` = ?,
                                `time_created` = ?, `time_updated` = ?
                            WHERE `id` = ?
                            """,
                            parameters: [
                                .real(info.cost),
                                .integer(Int64(info.tokens.input)),
                                .integer(Int64(info.tokens.output)),
                                .integer(Int64(info.tokens.reasoning)),
                                .integer(Int64(info.tokens.cache.read)),
                                .integer(Int64(info.tokens.cache.write)),
                                .integer(info.time.created),
                                .integer(info.time.updated),
                                .text(sessionID.rawValue),
                            ]
                        )
                    }
                )
            )
            guard let imported = try store.get(sessionID) else {
                throw CoreSessionErrors.NotFoundError(sessionID: sessionID)
            }
            return imported
        }
    }

    // parity: core/src/session/transfer.ts#node [status=adapted hash=f955b4aa8e07]
    public static let node: LayerNode.Provider = AppNode.makeGlobalNode(
        Service.serviceKey,
        LayerNode.ExecutableLayer { deps, _ in
            guard let db = deps.get(CoreDatabaseStore.Service.serviceKey, as: CoreDatabaseStore.Service.self)?.db,
                  let bus = deps.get(CoreBus.Service.serviceKey, as: CoreBus.Service.self),
                  let store = deps.get(CoreSessionStore.Service.serviceKey, as: CoreSessionStore.Service.self)
            else {
                throw SQLiteError.databaseClosed
            }
            return LayerNode.Output([Service.serviceKey: Service(db: db, bus: bus, store: store)])
        },
        [CoreDatabaseStore.node, CoreBus.node, CoreSessionStore.node]
    )
}

internal func ensureProjectRow(db: any SQLiteDatabase, id: ProjectID, worktree: String) throws {
    let now = Flock.currentEpochMs()
    _ = try db.execute(
        """
        INSERT INTO `project` (`id`, `worktree`, `time_created`, `time_updated`, `sandboxes`)
        VALUES (?, ?, ?, ?, '[]')
        ON CONFLICT (`id`) DO NOTHING
        """,
        parameters: [.text(id.rawValue), .text(worktree), .integer(now), .integer(now)]
    )
}

// MARK: - session/command.ts, session/shell.ts, session/skill.ts

/// Slash-command template expansion into a session prompt (`packages/core/src/session/command.ts`).
public enum CoreSessionCommand {
    public struct CommandTemplate: Equatable, Hashable, Sendable {
        public let name: String
        public let template: String
        public let agent: String?
        public let model: SessionSchema.ModelRef?

        public init(name: String, template: String, agent: String? = nil, model: SessionSchema.ModelRef? = nil) {
            self.name = name
            self.template = template
            self.agent = agent
            self.model = model
        }
    }

    // parity: core/src/session/command.ts#execute [status=implemented hash=482aa7ee2b1f]
    public static func execute(
        session: CoreSession.Service,
        sessionID: SessionID,
        command: CommandTemplate,
        arguments: String = "",
        delivery: SessionInboxSchema.Delivery? = nil,
        resume: Bool? = nil
    ) async throws -> SessionInboxSchema.Info {
        var expanded = command.template.replacingOccurrences(of: "$ARGUMENTS", with: arguments)
        let args = arguments.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        for (idx, arg) in args.enumerated() {
            expanded = expanded.replacingOccurrences(of: "$\(idx + 1)", with: arg)
        }
        if let agent = command.agent {
            try await session.selectAgent(sessionID: sessionID, agent: agent)
        }
        if let model = command.model {
            try await session.selectModel(sessionID: sessionID, model: model)
        }
        return try await session.prompt(CoreSession.PromptRequest(
            sessionID: sessionID,
            input: CoreSessionPrompt.Input(text: expanded, delivery: delivery),
            resume: resume
        ))
    }
}

/// Interactive user shell execution recording (`packages/core/src/session/shell.ts`).
public enum CoreSessionShell {
    // parity: core/src/session/shell.ts#start [status=implemented hash=b59b36999087]
    public static func start(
        bus: CoreBus.Service,
        session: SessionSchema.Info,
        command: String,
        processSpawner: any ProcessSpawner = CrossSpawnSpawner.HostProcessSpawner.shared,
        background: Bool = false
    ) async throws -> SessionMessageSchema.ShellInfo {
        let shellID = ShellSchema.ID.create().rawValue
        let startedAt = Flock.currentEpochMs()
        let started = SessionMessageSchema.ShellInfo(
            id: shellID,
            status: .running,
            command: command,
            cwd: session.location.directory,
            shell: "/bin/sh",
            file: "",
            metadata: background ? ["background": .bool(true)] : [:],
            time: SessionMessageSchema.ShellTime(started: startedAt)
        )
        _ = try await bus.publish(
            SessionEventSchema.Shell.Started,
            data: SessionEventSchema.Shell.StartedData(sessionID: session.id, shell: started)
        )
        let output = try await processSpawner.run(ProcessSpec(
            executable: "/bin/sh",
            arguments: ["-c", command],
            workingDirectory: session.location.directory
        ))
        let combined = String(decoding: output.stdout + output.stderr, as: UTF8.self)
        let completedAt = Flock.currentEpochMs()
        let ended = SessionMessageSchema.ShellInfo(
            id: shellID,
            status: .exited,
            command: command,
            cwd: session.location.directory,
            shell: "/bin/sh",
            file: "",
            exit: Double(output.exitCode),
            metadata: started.metadata,
            time: SessionMessageSchema.ShellTime(started: startedAt, completed: completedAt)
        )
        _ = try await bus.publish(
            SessionEventSchema.Shell.Ended,
            data: SessionEventSchema.Shell.EndedData(
                sessionID: session.id,
                shell: ended,
                output: SessionMessageSchema.ShellOutput(
                    output: combined,
                    cursor: combined.utf8.count,
                    size: combined.utf8.count,
                    truncated: false
                )
            )
        )
        return ended
    }
}

/// Skill activation helper (`packages/core/src/session/skill.ts`).
public enum CoreSessionSkill {
    // parity: core/src/session/skill.ts#get [status=implemented hash=c30f7b26d3f3]
    public static func get(
        bus: CoreBus.Service,
        sessionID: SessionID,
        id: String,
        name: String,
        text: String
    ) async throws {
        _ = try await bus.publish(
            SessionEventSchema.Skill.Activated,
            data: SessionEventSchema.Skill.ActivatedData(
                sessionID: sessionID,
                id: id,
                name: name,
                text: text
            )
        )
    }
}

// MARK: - session/session.ts & session.ts

/// High-level Session facade (`packages/core/src/session.ts` and `packages/core/src/session/session.ts`).
///
/// Enforces all Session Core invariants:
/// - Reusing a Session ID in `create` adopts the existing Session.
/// - Reusing a user or synthetic inbox item ID is idempotent when Session and type match
///   (pending or already delivered), and rejects cross-Session / cross-type reuse.
/// - Durable prompt admission (`session.inbox.enqueued` -> `session_inbox`) stays separate
///   from `CoreSessionExecution.wake` (skipped when `resume: false`).
/// - Interruption of a known idle Session is a no-op; unknown Sessions throw `NotFoundError`.
public enum CoreSession {
    // parity: core/src/session.ts#ListAnchor [status=implemented hash=05707e21b66c]
    public typealias ListAnchor = SessionSchema.ListAnchor
    // parity: core/src/session.ts#ListCursor [status=implemented hash=05707e21b66c]
    public typealias ListCursor = SessionSchema.ListCursor
    // parity: core/src/session.ts#AttachmentError [status=implemented hash=49705c12715d]
    public typealias AttachmentError = CoreSessionErrors.AttachmentError
    // parity: core/src/session.ts#BusyError [status=implemented hash=49705c12715d]
    public typealias BusyError = CoreSessionErrors.BusyError
    // parity: core/src/session.ts#CompactionConflictError [status=implemented hash=49705c12715d]
    public typealias CompactionConflictError = CoreSessionErrors.CompactionConflictError
    // parity: core/src/session.ts#ForkEmptyError [status=implemented hash=49705c12715d]
    public typealias ForkEmptyError = CoreSessionErrors.ForkEmptyError
    // parity: core/src/session.ts#InboxConflictError [status=implemented hash=49705c12715d]
    public typealias InboxConflictError = CoreSessionErrors.InboxConflictError
    // parity: core/src/session.ts#InvalidListCursorError [status=implemented hash=49705c12715d]
    public typealias InvalidListCursorError = CoreSessionErrors.InvalidListCursorError
    // parity: core/src/session.ts#MessageDecodeError [status=implemented hash=49705c12715d]
    public typealias MessageDecodeError = CoreSessionErrors.MessageDecodeError
    // parity: core/src/session.ts#MessageNotFoundError [status=implemented hash=49705c12715d]
    public typealias MessageNotFoundError = CoreSessionErrors.MessageNotFoundError
    // parity: core/src/session.ts#NotFoundError [status=implemented hash=49705c12715d]
    public typealias NotFoundError = CoreSessionErrors.NotFoundError
    // parity: core/src/session.ts#PromptConflictError [status=implemented hash=49705c12715d]
    public typealias PromptConflictError = CoreSessionErrors.PromptConflictError
    // parity: core/src/session.ts#SkillNotFoundError [status=implemented hash=49705c12715d]
    public typealias SkillNotFoundError = CoreSessionErrors.SkillNotFoundError
    // parity: core/src/session.ts#SyntheticConflictError [status=implemented hash=49705c12715d]
    public typealias SyntheticConflictError = CoreSessionErrors.SyntheticConflictError
    // parity: core/src/session.ts#DestinationNotFoundError [status=implemented hash=a26d3f866573]
    public typealias DestinationNotFoundError = CoreSessionMove.DestinationNotFoundError
    // parity: core/src/session.ts#DestinationNotDirectoryError [status=implemented hash=a26d3f866573]
    public typealias DestinationNotDirectoryError = CoreSessionMove.DestinationNotDirectoryError
    // parity: core/src/session.ts#DestinationUnavailableError [status=implemented hash=a26d3f866573]
    public typealias DestinationUnavailableError = CoreSessionMove.DestinationUnavailableError
    // parity: core/src/session.ts#TurnRangeError [status=implemented hash=3bf5f23b1fad]
    public typealias TurnRangeError = CoreSessionDiff.TurnRangeError

    // parity: core/src/session.ts#ListInput [status=implemented hash=ddbc8f6acca9]
    public typealias ListInput = CoreSessionStore.ListInput

    public struct ListPage: Equatable, Sendable {
        public let data: [SessionSchema.Info]
        public let previous: SessionSchema.ListCursor?
        public let next: SessionSchema.ListCursor?

        public init(data: [SessionSchema.Info], previous: SessionSchema.ListCursor? = nil, next: SessionSchema.ListCursor? = nil) {
            self.data = data
            self.previous = previous
            self.next = next
        }
    }

    public struct CreateInput: Equatable, Hashable, Sendable {
        public let id: SessionID?
        public let location: OpenCodeLocation?
        public let parentID: SessionID?
        public let projectID: ProjectID?
        public let subpath: String?
        public let title: String?
        public let agent: String?
        public let model: SessionSchema.ModelRef?
        public let metadata: SessionSchema.Metadata?
        public let permissions: SessionSchema.PermissionRuleset?

        public init(
            id: SessionID? = nil,
            location: OpenCodeLocation? = nil,
            parentID: SessionID? = nil,
            projectID: ProjectID? = nil,
            subpath: String? = nil,
            title: String? = nil,
            agent: String? = nil,
            model: SessionSchema.ModelRef? = nil,
            metadata: SessionSchema.Metadata? = nil,
            permissions: SessionSchema.PermissionRuleset? = nil
        ) {
            self.id = id
            self.location = location
            self.parentID = parentID
            self.projectID = projectID
            self.subpath = subpath
            self.title = title
            self.agent = agent
            self.model = model
            self.metadata = metadata
            self.permissions = permissions
        }
    }

    public struct PromptRequest: Equatable, Hashable, Sendable {
        public let sessionID: SessionID
        public let id: SessionMessageSchema.ID?
        public let input: CoreSessionPrompt.Input
        public let resume: Bool?

        public init(
            sessionID: SessionID,
            id: SessionMessageSchema.ID? = nil,
            input: CoreSessionPrompt.Input,
            resume: Bool? = nil
        ) {
            self.sessionID = sessionID
            self.id = id
            self.input = input
            self.resume = resume
        }
    }

    public struct CompactRequest: Equatable, Hashable, Sendable {
        public let sessionID: SessionID
        public let id: SessionMessageSchema.ID?
        public let delivery: SessionInboxSchema.Delivery?
        public let resume: Bool?

        public init(
            sessionID: SessionID,
            id: SessionMessageSchema.ID? = nil,
            delivery: SessionInboxSchema.Delivery? = nil,
            resume: Bool? = nil
        ) {
            self.sessionID = sessionID
            self.id = id
            self.delivery = delivery
            self.resume = resume
        }
    }

    // parity: core/src/session/session.ts#Handle [status=implemented hash=bd9994046615]
    public struct Handle: Sendable {
        public let id: SessionID
        private let service: Service

        fileprivate init(id: SessionID, service: Service) {
            self.id = id
            self.service = service
        }

        public func info() throws -> SessionSchema.Info {
            try service.get(id)
        }

        public func messages(_ limit: Int? = nil, order: SessionSchema.SortOrder? = nil) throws -> [SessionMessageSchema.Info] {
            try service.messages(CoreSessionStore.MessagesInput(sessionID: id, limit: limit, order: order))
        }

        public func prompt(
            id messageID: SessionMessageSchema.ID? = nil,
            _ input: CoreSessionPrompt.Input,
            resume: Bool? = nil
        ) async throws -> SessionInboxSchema.Info {
            try await service.prompt(PromptRequest(sessionID: id, id: messageID, input: input, resume: resume))
        }

        public func compact(
            id inputID: SessionMessageSchema.ID? = nil,
            delivery: SessionInboxSchema.Delivery? = nil,
            resume: Bool? = nil
        ) async throws -> SessionInboxSchema.Compaction {
            try await service.compact(CompactRequest(sessionID: id, id: inputID, delivery: delivery, resume: resume))
        }

        public func interrupt(resume: Bool = false) async throws -> Bool {
            try await service.interrupt(id, resume: resume)
        }

        public func awaitIdle() async throws {
            try await service.awaitIdle(id)
        }
    }

    // parity: core/src/session/session.ts#make [status=implemented hash=9ee40a846d72]
    public static func make(id: SessionID, service: Service) -> Handle {
        Handle(id: id, service: service)
    }

    // parity: core/src/session.ts#Interface [status=implemented hash=27e1b2a02d7a]
    public protocol Interface: Sendable {
        func list(_ input: ListInput) throws -> ListPage
        func create(_ input: CreateInput) async throws -> SessionSchema.Info
        func fork(sessionID: SessionID, before: SessionMessageSchema.ID?) async throws -> SessionSchema.Info
        func get(_ sessionID: SessionID) throws -> SessionSchema.Info
        func remove(_ sessionID: SessionID) async throws
        func messages(_ input: CoreSessionStore.MessagesInput) throws -> [SessionMessageSchema.Info]
        func prompt(_ request: PromptRequest) async throws -> SessionInboxSchema.Info
        func synthetic(_ request: CoreSessionSynthetic.Request) async throws -> SessionInboxSchema.Info
        func compact(_ request: CompactRequest) async throws -> SessionInboxSchema.Compaction
        func selectAgent(sessionID: SessionID, agent: String) async throws
        func selectModel(sessionID: SessionID, model: SessionSchema.ModelRef) async throws
        func rename(sessionID: SessionID, title: String) async throws
        func archive(_ sessionID: SessionID) async throws
        func unarchive(_ sessionID: SessionID) async throws
        func interrupt(_ sessionID: SessionID, resume: Bool) async throws -> Bool
        func awaitIdle(_ sessionID: SessionID) async throws
        func resume(_ sessionID: SessionID) async throws
        func handle(_ sessionID: SessionID) -> Handle
    }

    // parity: core/src/session.ts#Service [status=implemented hash=75e7d2b0d29c]
    public final class Service: Interface, Sendable {
        public static let serviceKey = "@opencode/Session"
        public static let defaultListLimit = 50

        public let db: any SQLiteDatabase
        public let bus: CoreBus.Service
        public let store: any CoreSessionStore.Interface
        public let inbox: any CoreSessionInbox.Interface
        public let execution: any CoreSessionExecution.Interface
        public let environment: CoreSessionEnvironment.Service
        public let fileSystem: any OpenCodeFileSystem
        public let version: String
        private let syntheticAdmission: @Sendable (CoreSessionSynthetic.Request) async throws -> SessionInboxSchema.Info

        public init(
            db: any SQLiteDatabase,
            bus: CoreBus.Service,
            store: any CoreSessionStore.Interface,
            inbox: any CoreSessionInbox.Interface,
            execution: any CoreSessionExecution.Interface = CoreSessionExecution.NoopService(),
            environment: CoreSessionEnvironment.Service = CoreSessionEnvironment.Service(),
            fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
            version: String = "0.0.0"
        ) {
            self.db = db
            self.bus = bus
            self.store = store
            self.inbox = inbox
            self.execution = execution
            self.environment = environment
            self.fileSystem = fileSystem
            self.version = version
            self.syntheticAdmission = CoreSessionSynthetic.make(
                store: store,
                inbox: inbox,
                wake: { [execution] sid in await execution.wake(sid) }
            )
        }

        public func handle(_ sessionID: SessionID) -> Handle {
            CoreSession.make(id: sessionID, service: self)
        }

        public func get(_ sessionID: SessionID) throws -> SessionSchema.Info {
            guard let info = try store.get(sessionID) else {
                throw CoreSessionErrors.NotFoundError(sessionID: sessionID)
            }
            return info
        }

        public func list(_ input: ListInput = ListInput()) throws -> ListPage {
            let limit = input.limit ?? Self.defaultListLimit
            let rows = try store.list(ListInput(
                directory: input.directory,
                workspaceID: input.workspaceID,
                project: input.project,
                subpath: input.subpath,
                search: input.search,
                limit: limit + 1,
                order: input.order,
                parentID: input.parentID,
                archived: input.archived,
                anchor: input.anchor
            ))
            let hasMore = rows.count > limit
            let page = hasMore ? Array(rows.prefix(limit)) : rows
            return ListPage(data: page)
        }

        public func create(_ input: CreateInput) async throws -> SessionSchema.Info {
            let sessionID = input.id ?? SessionID.create()
            // Invariant: Reusing an existing Session ID adopts the existing Session.
            if let existing = try store.get(sessionID) {
                return existing
            }

            let location: OpenCodeLocation
            let projectID: ProjectID
            let subpath: String?
            if let parentID = input.parentID {
                let parent = try get(parentID)
                location = parent.location
                projectID = parent.projectID
                subpath = parent.subpath
            } else {
                location = input.location ?? OpenCodeLocation(directory: "/")
                projectID = input.projectID ?? ProjectID.global
                subpath = input.subpath
            }

            try ensureProjectRow(db: db, id: projectID, worktree: location.directory)

            do {
                _ = try await bus.publish(
                    SessionEventSchema.Created,
                    data: SessionEventSchema.CreatedData(
                        sessionID: sessionID,
                        projectID: projectID,
                        location: location,
                        subpath: subpath,
                        parentID: input.parentID,
                        slug: "ses-\(Identifier.ascending().prefix(8))",
                        title: input.title,
                        agent: input.agent,
                        model: input.model,
                        metadata: input.metadata,
                        permissions: input.permissions,
                        version: version
                    ),
                    options: CoreBus.PublishOptions(location: location)
                )
            } catch is CoreSessionProjector.SessionAlreadyProjected {
                // Concurrent create with same ID adopts the projected row.
            }
            return try get(sessionID)
        }

        public func fork(sessionID: SessionID, before: SessionMessageSchema.ID? = nil) async throws -> SessionSchema.Info {
            let parent = try get(sessionID)
            let boundary: SessionForkSchema.Boundary
            if let before {
                guard try db.queryOne(
                    "SELECT `id` FROM `session_message` WHERE `session_id` = ? AND `id` = ?",
                    parameters: [.text(sessionID.rawValue), .text(before.rawValue)]
                ) != nil else {
                    throw CoreSessionErrors.MessageNotFoundError(sessionID: sessionID, messageID: before)
                }
                boundary = .before(messageID: before)
            } else {
                guard let latestRow = try db.queryOne(
                    "SELECT `id` FROM `session_message` WHERE `session_id` = ? ORDER BY `seq` DESC LIMIT 1",
                    parameters: [.text(sessionID.rawValue)]
                ), let latestIDStr = latestRow.string("id"), let latestID = SessionMessageSchema.ID(rawValue: latestIDStr) else {
                    throw CoreSessionErrors.ForkEmptyError(sessionID: sessionID)
                }
                boundary = .through(messageID: latestID)
            }

            let newID = SessionID.create()
            let instructions = try CoreSessionInstructionState.current(db: db, sessionID: sessionID)
            let instructionEntries = try CoreSessionInstructionEntry.snapshot(db: db, sessionID: sessionID)
            _ = try await bus.publish(
                SessionEventSchema.Forked,
                data: SessionEventSchema.ForkedData(
                    sessionID: newID,
                    parentID: sessionID,
                    boundary: boundary,
                    instructions: instructions,
                    instructionEntries: instructionEntries.isEmpty ? nil : instructionEntries
                ),
                options: CoreBus.PublishOptions(location: parent.location)
            )
            return try get(newID)
        }

        public func remove(_ sessionID: SessionID) async throws {
            _ = try get(sessionID)
            _ = await execution.interrupt(sessionID, resume: false)
            await execution.awaitIdle(sessionID)
            environment.clear(sessionID)
            _ = try await bus.publish(
                SessionEventSchema.Deleted,
                data: SessionEventSchema.SessionBaseData(sessionID: sessionID)
            )
        }

        public func messages(_ input: CoreSessionStore.MessagesInput) throws -> [SessionMessageSchema.Info] {
            _ = try get(input.sessionID)
            return try store.messages(input)
        }

        public func prompt(_ request: PromptRequest) async throws -> SessionInboxSchema.Info {
            let session = try get(request.sessionID)
            let messageID = request.id ?? SessionMessageSchema.ID.create()
            let delivery = request.input.delivery ?? .steer

            // Reconcile idempotency BEFORE materializing attachments or publishing.
            do {
                if let existing = try inbox.reconcile(
                    id: messageID,
                    sessionID: session.id,
                    type: "user",
                    delivery: delivery
                ) {
                    if request.resume != false, session.revert == nil {
                        await execution.wake(session.id)
                    }
                    return existing
                }
            } catch is CoreSessionInbox.LifecycleConflict {
                throw CoreSessionErrors.PromptConflictError(sessionID: session.id, messageID: messageID)
            }

            if session.revert != nil {
                try await CoreSessionRevert.commit(bus: bus, session: session)
            }

            let item = try await CoreSessionPrompt.prepare(
                session: session,
                messageID: messageID,
                input: request.input,
                db: db,
                fileSystem: fileSystem
            )

            let admitted: SessionInboxSchema.Info
            do {
                admitted = try await inbox.admit(id: messageID, sessionID: session.id, item: item)
            } catch is CoreSessionInbox.LifecycleConflict {
                throw CoreSessionErrors.PromptConflictError(sessionID: session.id, messageID: messageID)
            }

            if request.resume != false {
                await execution.wake(session.id)
            }
            return admitted
        }

        public func synthetic(_ request: CoreSessionSynthetic.Request) async throws -> SessionInboxSchema.Info {
            try await syntheticAdmission(request)
        }

        public func compact(_ request: CompactRequest) async throws -> SessionInboxSchema.Compaction {
            let session = try get(request.sessionID)
            let inputID = request.id ?? SessionMessageSchema.ID.create()
            let delivery = request.delivery ?? .steer
            let admitted: SessionInboxSchema.Compaction
            do {
                admitted = try await inbox.admitCompaction(id: inputID, sessionID: session.id, delivery: delivery)
            } catch is CoreSessionInbox.LifecycleConflict {
                throw CoreSessionErrors.CompactionConflictError(sessionID: session.id, inputID: inputID)
            }
            if request.resume != false {
                await execution.wake(session.id)
            }
            return admitted
        }

        public func selectAgent(sessionID: SessionID, agent: String) async throws {
            let session = try get(sessionID)
            // Without a stored agent the Session runs as its Location's default, which its last step records.
            let current = session.agent ?? (try? store.lastAssistantAfter(sessionID: sessionID, afterSeq: nil))?.agent
            if current == agent { return }
            _ = try await bus.publish(
                SessionEventSchema.AgentSelected,
                data: SessionEventSchema.AgentSelectedData(sessionID: sessionID, agent: agent, previous: session.agent)
            )
        }

        public func selectModel(sessionID: SessionID, model: SessionSchema.ModelRef) async throws {
            let session = try get(sessionID)
            if session.model == model { return }
            _ = try await bus.publish(
                SessionEventSchema.ModelSelected,
                data: SessionEventSchema.ModelSelectedData(sessionID: sessionID, model: model, previous: session.model)
            )
        }

        public func rename(sessionID: SessionID, title: String) async throws {
            _ = try get(sessionID)
            _ = try await bus.publish(
                SessionEventSchema.Renamed,
                data: SessionEventSchema.RenamedData(sessionID: sessionID, title: title)
            )
        }

        public func archive(_ sessionID: SessionID) async throws {
            _ = try get(sessionID)
            _ = try await bus.publish(
                SessionEventSchema.Archived,
                data: SessionEventSchema.SessionBaseData(sessionID: sessionID)
            )
        }

        public func unarchive(_ sessionID: SessionID) async throws {
            _ = try get(sessionID)
            _ = try await bus.publish(
                SessionEventSchema.Unarchived,
                data: SessionEventSchema.SessionBaseData(sessionID: sessionID)
            )
        }

        public func interrupt(_ sessionID: SessionID, resume: Bool = false) async throws -> Bool {
            // Public API rejects unknown Session IDs; idle known Sessions are a no-op returning false.
            _ = try get(sessionID)
            return await execution.interrupt(sessionID, resume: resume)
        }

        public func awaitIdle(_ sessionID: SessionID) async throws {
            _ = try get(sessionID)
            await execution.awaitIdle(sessionID)
        }

        public func resume(_ sessionID: SessionID) async throws {
            _ = try get(sessionID)
            try await execution.resume(sessionID)
        }
    }

    // parity: core/src/session.ts#node [status=adapted hash=9c5a4b3c1db0]
    public static let node: LayerNode.Provider = AppNode.makeGlobalNode(
        Service.serviceKey,
        LayerNode.ExecutableLayer { deps, _ in
            guard let db = deps.get(CoreDatabaseStore.Service.serviceKey, as: CoreDatabaseStore.Service.self)?.db,
                  let bus = deps.get(CoreBus.Service.serviceKey, as: CoreBus.Service.self),
                  let store = deps.get(CoreSessionStore.Service.serviceKey, as: CoreSessionStore.Service.self),
                  let inbox = deps.get(CoreSessionInbox.Service.serviceKey, as: CoreSessionInbox.Service.self)
            else {
                throw SQLiteError.databaseClosed
            }
            let execution = deps.get(CoreSessionExecution.Service.serviceKey, as: (any CoreSessionExecution.Interface).self)
                ?? CoreSessionExecution.NoopService()
            let env = deps.get(CoreSessionEnvironment.Service.serviceKey, as: CoreSessionEnvironment.Service.self)
                ?? CoreSessionEnvironment.Service()
            let fs = deps.get(LayerNodePlatform.fileSystemKey, as: (any OpenCodeFileSystem).self) ?? LocalFileSystem.shared
            return LayerNode.Output([Service.serviceKey: Service(
                db: db,
                bus: bus,
                store: store,
                inbox: inbox,
                execution: execution,
                environment: env,
                fileSystem: fs
            )])
        },
        [
            CoreDatabaseStore.node,
            CoreBus.node,
            CoreSessionStore.node,
            CoreSessionInbox.node,
            CoreSessionExecution.node,
            CoreSessionEnvironment.node,
            CoreSessionProjector.node,
        ]
    )
}
