#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Synchronization
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

// MARK: - Wildcard Pattern Matcher (internal helper mirroring `core/src/util/wildcard.ts`)

public enum CorePermissionWildcard {
    /// Matches `input` against wildcard `pattern` (`*` matches 0+ chars including newlines,
    /// `?` matches any single char, trailing `" *"` optionally matches with or without arguments,
    /// `\` normalized to `/`).
    public static func match(
        _ input: String,
        pattern: String,
        ignoreCase: Bool = false,
        isWindows: Bool = (Platform.current == .windows)
    ) -> Bool {
        let caseless = isWindows || ignoreCase
        let rawInput = input.replacing("\\", with: "/")
        let rawPattern = pattern.replacing("\\", with: "/")
        let normInput = caseless ? rawInput.lowercased() : rawInput
        let normPattern = caseless ? rawPattern.lowercased() : rawPattern

        let inputChars = Array(normInput)
        if normPattern.hasSuffix(" *") {
            let stem = Array(normPattern.dropLast(2))
            if matchChars(inputChars, pattern: stem) {
                return true
            }
            let withSpaceWildcard = stem + [" ", "*"]
            return matchChars(inputChars, pattern: withSpaceWildcard)
        }
        return matchChars(inputChars, pattern: Array(normPattern))
    }

    private static func matchChars(_ input: [Character], pattern: [Character]) -> Bool {
        var i = 0
        var p = 0
        var starIdx: Int? = nil
        var matchIdx = 0

        while i < input.count {
            if p < pattern.count && pattern[p] == "*" {
                starIdx = p
                matchIdx = i
                p += 1
            } else if p < pattern.count && (pattern[p] == "?" || pattern[p] == input[i]) {
                i += 1
                p += 1
            } else if let s = starIdx {
                p = s + 1
                matchIdx += 1
                i = matchIdx
            } else {
                return false
            }
        }
        while p < pattern.count && pattern[p] == "*" {
            p += 1
        }
        return p == pattern.count
    }
}

// MARK: - Persisted Permission SQL Schema (`core/src/permission/sql.ts`)

public enum CorePermissionSQL {
    public struct TableDefinition: Equatable, Hashable, Sendable {
        public let name: String
        public let columns: [String]
        public let uniqueIndexName: String
        public let uniqueIndexColumns: [String]
        public let createTableSQL: String
        public let createIndexSQL: String

        public init(
            name: String,
            columns: [String],
            uniqueIndexName: String,
            uniqueIndexColumns: [String],
            createTableSQL: String,
            createIndexSQL: String
        ) {
            self.name = name
            self.columns = columns
            self.uniqueIndexName = uniqueIndexName
            self.uniqueIndexColumns = uniqueIndexColumns
            self.createTableSQL = createTableSQL
            self.createIndexSQL = createIndexSQL
        }
    }

    /// SQLite table definition for persisted project permissions (`permission` table).
    // parity: core/src/permission/sql.ts#PermissionTable [status=adapted hash=2485a6cd0af0]
    public static let PermissionTable = TableDefinition(
        name: "permission",
        columns: ["id", "project_id", "action", "resource", "time_created", "time_updated"],
        uniqueIndexName: "permission_project_action_resource_idx",
        uniqueIndexColumns: ["project_id", "action", "resource"],
        createTableSQL: """
        CREATE TABLE IF NOT EXISTS permission (
            id TEXT PRIMARY KEY,
            project_id TEXT NOT NULL,
            action TEXT NOT NULL,
            resource TEXT NOT NULL,
            time_created INTEGER NOT NULL,
            time_updated INTEGER NOT NULL
        )
        """,
        createIndexSQL: """
        CREATE UNIQUE INDEX IF NOT EXISTS permission_project_action_resource_idx
        ON permission (project_id, action, resource)
        """
    )

    public static func ensureSchema(in database: any SQLiteDatabase) throws {
        _ = try database.execute(PermissionTable.createTableSQL)
        _ = try database.execute(PermissionTable.createIndexSQL)
    }
}

// MARK: - Saved Permission Store (`core/src/permission/saved.ts`)

public enum CorePermissionSaved {
    // parity: core/src/permission/saved.ts#ID [status=implemented hash=0951b625c471]
    public typealias ID = PermissionSavedSchema.ID

    // parity: core/src/permission/saved.ts#Info [status=implemented hash=cb3a05896138]
    public typealias Info = PermissionSavedSchema.Info

    // parity: core/src/permission/saved.ts#ListInput [status=implemented hash=59f5f1a82468]
    public struct ListInput: Equatable, Hashable, Sendable, Codable {
        public let projectID: ProjectID?

        public init(projectID: ProjectID? = nil) {
            self.projectID = projectID
        }
    }

    // parity: core/src/permission/saved.ts#AddInput [status=implemented hash=fb1de3e23b3d]
    public struct AddInput: Equatable, Hashable, Sendable, Codable {
        public let projectID: ProjectID
        public let action: String
        public let resources: [String]

        public init(projectID: ProjectID, action: String, resources: [String]) {
            self.projectID = projectID
            self.action = action
            self.resources = resources
        }
    }

    // parity: core/src/permission/saved.ts#UpdateInput [status=implemented hash=6aad20707da3]
    public struct UpdateInput: Equatable, Hashable, Sendable, Codable {
        public let id: ID
        public let action: String?
        public let resource: String?

        public init(id: ID, action: String? = nil, resource: String? = nil) {
            self.id = id
            self.action = action
            self.resource = resource
        }
    }

    // parity: core/src/permission/saved.ts#NotFoundError [status=implemented hash=d1260c5aa814]
    public struct NotFoundError: Swift.Error, Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
        public static let tag = "PermissionSaved.NotFoundError"
        public let id: ID

        public init(id: ID) {
            self.id = id
        }

        public var description: String { "Saved permission not found: \(id.rawValue)" }
    }

    // parity: core/src/permission/saved.ts#ConflictError [status=implemented hash=7242468f5a8e]
    public struct ConflictError: Swift.Error, Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
        public static let tag = "PermissionSaved.ConflictError"
        public let id: ID
        public let action: String
        public let resource: String

        public init(id: ID, action: String, resource: String) {
            self.id = id
            self.action = action
            self.resource = resource
        }

        public var description: String {
            "Saved permission conflict for \(id.rawValue): \(action) on \(resource)"
        }
    }

    // parity: core/src/permission/saved.ts#Interface [status=adapted hash=6280d19a064e]
    public protocol Interface: Sendable {
        func list(_ input: ListInput?) async throws -> [Info]
        func add(_ input: AddInput) async throws
        func update(_ input: UpdateInput) async throws -> Info
        func remove(_ id: ID) async throws
    }

    // parity: core/src/permission/saved.ts#Service [status=adapted hash=578ab9e07860]
    public final class Service: Interface, Sendable {
        public static let serviceKey = "@opencode/PermissionSaved"

        private let database: any SQLiteDatabase
        private let nowMs: @Sendable () -> Int64

        public init(
            database: any SQLiteDatabase,
            nowMs: @escaping @Sendable () -> Int64 = { Flock.currentEpochMs() }
        ) throws {
            self.database = database
            self.nowMs = nowMs
            try CorePermissionSQL.ensureSchema(in: database)
        }

        public func list(_ input: ListInput? = nil) async throws -> [Info] {
            let rows: [SQLiteRow]
            if let projectID = input?.projectID {
                rows = try database.query(
                    "SELECT id, project_id, action, resource, time_created, time_updated FROM permission WHERE project_id = ?",
                    parameters: [.text(projectID.rawValue)]
                )
            } else {
                rows = try database.query(
                    "SELECT id, project_id, action, resource, time_created, time_updated FROM permission"
                )
            }
            return rows.compactMap(Self.decodeRow)
        }

        public func add(_ input: AddInput) async throws {
            guard !input.resources.isEmpty else { return }
            let now = nowMs()
            try database.transaction {
                for resource in input.resources {
                    let existing = try database.queryOne(
                        "SELECT id FROM permission WHERE project_id = ? AND action = ? AND resource = ?",
                        parameters: [
                            .text(input.projectID.rawValue),
                            .text(input.action),
                            .text(resource),
                        ]
                    )
                    if existing != nil { continue }
                    let id = ID.create()
                    _ = try database.execute(
                        "INSERT OR IGNORE INTO permission (id, project_id, action, resource, time_created, time_updated) VALUES (?, ?, ?, ?, ?, ?)",
                        parameters: [
                            .text(id.rawValue),
                            .text(input.projectID.rawValue),
                            .text(input.action),
                            .text(resource),
                            .integer(now),
                            .integer(now),
                        ]
                    )
                }
            }
        }

        public func update(_ input: UpdateInput) async throws -> Info {
            guard let row = try database.queryOne(
                "SELECT id, project_id, action, resource, time_created, time_updated FROM permission WHERE id = ?",
                parameters: [.text(input.id.rawValue)]
            ), let current = Self.decodeRow(row) else {
                throw NotFoundError(id: input.id)
            }
            let nextAction = input.action ?? current.action
            let nextResource = input.resource ?? current.resource
            let now = nowMs()

            // Check unique constraint on (project_id, action, resource) for another row.
            let dupRows = try database.query(
                "SELECT id FROM permission WHERE project_id = ? AND action = ? AND resource = ?",
                parameters: [
                    .text(current.projectID.rawValue),
                    .text(nextAction),
                    .text(nextResource),
                ]
            )
            if dupRows.contains(where: { $0.string("id") != input.id.rawValue }) {
                throw ConflictError(id: input.id, action: nextAction, resource: nextResource)
            }

            do {
                _ = try database.execute(
                    "UPDATE permission SET action = ?, resource = ?, time_updated = ? WHERE id = ?",
                    parameters: [
                        .text(nextAction),
                        .text(nextResource),
                        .integer(now),
                        .text(input.id.rawValue),
                    ]
                )
            } catch let err as SQLiteError {
                if case .constraintViolation = err {
                    throw ConflictError(id: input.id, action: nextAction, resource: nextResource)
                }
                throw err
            }

            guard let updatedRow = try database.queryOne(
                "SELECT id, project_id, action, resource, time_created, time_updated FROM permission WHERE id = ?",
                parameters: [.text(input.id.rawValue)]
            ), let updated = Self.decodeRow(updatedRow) else {
                throw NotFoundError(id: input.id)
            }
            return updated
        }

        public func remove(_ id: ID) async throws {
            _ = try database.execute(
                "DELETE FROM permission WHERE id = ?",
                parameters: [.text(id.rawValue)]
            )
        }

        private static func decodeRow(_ row: SQLiteRow) -> Info? {
            guard let idStr = row.string("id"),
                  let projectStr = row.string("project_id"),
                  let action = row.string("action"),
                  let resource = row.string("resource"),
                  let createdMs = row.int64("time_created"),
                  let updatedMs = row.int64("time_updated"),
                  let created = SchemaPrimitive.DateTimeUtcFromMillis(epochMillis: Double(createdMs)),
                  let updated = SchemaPrimitive.DateTimeUtcFromMillis(epochMillis: Double(updatedMs)) else {
                return nil
            }
            return Info(
                id: ID(rawValue: idStr),
                projectID: ProjectID(rawValue: projectStr),
                action: action,
                resource: resource,
                time: Info.Time(created: created, updated: updated)
            )
        }
    }

    // parity: core/src/permission/saved.ts#node [status=adapted hash=788769187e33]
    public static let node: LayerNode.Provider = AppNode.makeGlobalNode(
        Service.serviceKey,
        LayerNode.ExecutableLayer { deps, _ in
            let db: any SQLiteDatabase
            if let existing = deps.get("@opencode/Database", as: (any SQLiteDatabase).self) {
                db = existing
            } else {
                db = try SQLiteDatabaseFactory.open(path: ":memory:")
            }
            let service = try Service(database: db)
            return LayerNode.Output([Service.serviceKey: service])
        },
        []
    )
}

// MARK: - Permission Engine (`core/src/permission.ts`)

public enum CorePermission {
    // parity: core/src/permission.ts#ID [status=implemented hash=75bfa9fa6b69]
    public typealias ID = PermissionSchema.ID

    // parity: core/src/permission.ts#Source [status=implemented hash=60e83dc26fc4]
    public typealias Source = PermissionSchema.Source

    // parity: core/src/permission.ts#Request [status=implemented hash=013354916288]
    public typealias Request = PermissionSchema.Request

    // parity: core/src/permission.ts#Reply [status=implemented hash=b673796c2734]
    public typealias Reply = PermissionSchema.Reply

    // parity: core/src/permission.ts#Effect [status=implemented hash=9944d7771bf4]
    public typealias Effect = PermissionSchema.Effect
    public typealias Rule = PermissionSchema.Rule
    public typealias Ruleset = PermissionSchema.Ruleset

    public static let missingAgentPermissions: Ruleset = [
        Rule(action: "*", resource: "*", effect: .deny),
    ]

    public struct InvocationContext: Equatable, Hashable, Sendable, Codable {
        public let sessionID: SessionID
        public let agent: AgentSchema.ID
        public let source: Source

        public init(sessionID: SessionID, agent: AgentSchema.ID, source: Source) {
            self.sessionID = sessionID
            self.agent = agent
            self.source = source
        }
    }

    // parity: core/src/permission.ts#AssertInput [status=implemented hash=cbbd0a7e5421]
    public struct AssertInput: Equatable, Hashable, Sendable, Codable {
        public let id: ID?
        public let sessionID: SessionID
        public let agent: AgentSchema.ID?
        public let action: String
        public let resources: [String]
        public let save: [String]?
        public let metadata: [String: JSONValue]?
        public let source: Source?

        public init(
            id: ID? = nil,
            sessionID: SessionID,
            agent: AgentSchema.ID? = nil,
            action: String,
            resources: [String],
            save: [String]? = nil,
            metadata: [String: JSONValue]? = nil,
            source: Source? = nil
        ) {
            self.id = id
            self.sessionID = sessionID
            self.agent = agent
            self.action = action
            self.resources = resources
            self.save = save
            self.metadata = metadata
            self.source = source
        }
    }

    /// The requester fields of a permission request made by a tool call.
    // parity: core/src/permission.ts#invocation [status=implemented hash=cd0f9c0f1165]
    public static func invocation(_ context: ToolSchema.Context) -> InvocationContext {
        InvocationContext(
            sessionID: context.sessionID,
            agent: context.agent,
            source: .tool(messageID: context.messageID, id: context.id.rawValue)
        )
    }

    // parity: core/src/permission.ts#ReplyInput [status=implemented hash=cff780a8dc34]
    public struct ReplyInput: Equatable, Hashable, Sendable, Codable {
        public let requestID: ID
        public let reply: Reply
        public let message: String?

        public init(requestID: ID, reply: Reply, message: String? = nil) {
            self.requestID = requestID
            self.reply = reply
            self.message = message
        }
    }

    // parity: core/src/permission.ts#AskResult [status=implemented hash=d1f9ecd90760]
    public struct AskResult: Equatable, Hashable, Sendable, Codable {
        public let id: ID
        public let effect: Effect

        public init(id: ID, effect: Effect) {
            self.id = id
            self.effect = effect
        }
    }

    /// Context reference key for unattended execution rulesets (settled without user interaction).
    // parity: core/src/permission.ts#Unattended [status=adapted hash=c269d6b55e79]
    public enum Unattended {
        public static let key = "@opencode/Permission/Unattended"
        @TaskLocal public static var current: Ruleset? = nil
    }

    // parity: core/src/permission.ts#DeclinedError [status=implemented hash=82977a9efb76]
    public struct DeclinedError: Swift.Error, Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
        public static let tag = "Permission.DeclinedError"

        public init() {}

        public var description: String { "Permission declined by user" }
    }

    // parity: core/src/permission.ts#CorrectedError [status=implemented hash=05bf83e8e723]
    public struct CorrectedError: Swift.Error, Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
        public static let tag = "Permission.CorrectedError"
        public let feedback: String

        public init(feedback: String) {
            self.feedback = feedback
        }

        // parity: core/src/permission.ts#CorrectedError.message [status=implemented hash=f702bc1c76ae]
        public var message: String { feedback }
        public var description: String { feedback }
    }

    // parity: core/src/permission.ts#BlockedError [status=implemented hash=182fcc2289f7]
    public struct BlockedError: Swift.Error, Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
        public static let tag = "Permission.BlockedError"
        public let rules: Ruleset
        public let permission: String
        public let resources: [String]
        public let reason: String?

        public init(rules: Ruleset, permission: String, resources: [String], reason: String? = nil) {
            self.rules = rules
            self.permission = permission
            self.resources = resources
            self.reason = reason
        }

        // parity: core/src/permission.ts#BlockedError.message [status=implemented hash=d5dfbdf0eb22]
        public var message: String { reason ?? "Permission denied: \(permission)" }
        public var description: String { message }
    }

    // parity: core/src/permission.ts#NotFoundError [status=implemented hash=7e7b1d3be76a]
    public struct NotFoundError: Swift.Error, Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
        public static let tag = "Permission.NotFoundError"
        public let requestID: ID

        public init(requestID: ID) {
            self.requestID = requestID
        }

        public var description: String { "Permission request not found: \(requestID.rawValue)" }
    }

    // parity: core/src/permission.ts#Error [status=implemented hash=eb7aeea8b6a1]
    public enum PermissionError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        case blocked(BlockedError)
        case corrected(CorrectedError)

        public var description: String {
            switch self {
            case .blocked(let e): return e.description
            case .corrected(let e): return e.description
            }
        }
    }

    /// Actions whose resources are file paths.
    // parity: core/src/permission.ts#pathActions [status=implemented hash=a69a5617aa95]
    public static let pathActions: [String] = ["external_directory", "read", "edit"]

    /// macOS volumes ignore case by default, so `.OPENCODE/x` opens `.opencode/x`; rules for file paths must match it too.
    // parity: core/src/permission.ts#ignoresCase [status=implemented hash=297b82dfc641]
    public static func ignoresCase(_ action: String, platform: PlatformOS = Platform.current) -> Bool {
        platform == .macOS && pathActions.contains(action)
    }

    /// Evaluates the effective permission rule for `(action, resource)` across ordered rulesets (last match wins; defaults to `.ask`).
    // parity: core/src/permission.ts#evaluate [status=implemented hash=238eb43c9a17]
    public static func evaluate(
        action: String,
        resource: String,
        rulesets: [Ruleset],
        platform: PlatformOS = Platform.current
    ) -> Rule {
        let ignoreCase = ignoresCase(action, platform: platform)
        let isWindows = platform == .windows
        let flat = rulesets.flatMap { $0 }
        for rule in flat.reversed() {
            if CorePermissionWildcard.match(action, pattern: rule.action, ignoreCase: false, isWindows: isWindows) &&
                CorePermissionWildcard.match(resource, pattern: rule.resource, ignoreCase: ignoreCase, isWindows: isWindows)
            {
                return rule
            }
        }
        return Rule(action: action, resource: "*", effect: .ask)
    }

    public static func evaluate(
        action: String,
        resource: String,
        _ rulesets: Ruleset...,
        platform: PlatformOS = Platform.current
    ) -> Rule {
        evaluate(action: action, resource: resource, rulesets: rulesets, platform: platform)
    }

    /// Flattens multiple permission rulesets into a single ordered ruleset.
    // parity: core/src/permission.ts#merge [status=implemented hash=2812ed22d999]
    public static func merge(_ rulesets: Ruleset...) -> Ruleset {
        rulesets.flatMap { $0 }
    }

    public static func merge(_ rulesets: [Ruleset]) -> Ruleset {
        rulesets.flatMap { $0 }
    }

    public struct EvaluateHookEvent: Equatable, Sendable {
        public let sessionID: SessionID
        public let agent: AgentSchema.ID?
        public let action: String
        public let resources: [String]
        public let metadata: [String: JSONValue]?
        public let source: Source?
        public var effect: Effect
        public var message: String?

        public init(
            sessionID: SessionID,
            agent: AgentSchema.ID?,
            action: String,
            resources: [String],
            metadata: [String: JSONValue]?,
            source: Source?,
            effect: Effect,
            message: String? = nil
        ) {
            self.sessionID = sessionID
            self.agent = agent
            self.action = action
            self.resources = resources
            self.metadata = metadata
            self.source = source
            self.effect = effect
            self.message = message
        }
    }

    public struct NestedLease: Sendable {
        private let releaseImpl: @Sendable () -> Void

        public init(release: @escaping @Sendable () -> Void) {
            self.releaseImpl = release
        }

        public func release() {
            releaseImpl()
        }
    }

    // parity: core/src/permission.ts#Interface [status=adapted hash=6531e7a1e7f6]
    public protocol Interface: Sendable {
        func close() async
        func ask(_ input: AssertInput) async throws -> AskResult
        func assert(_ input: AssertInput) async throws
        func assertNotDenied(_ input: AssertInput) async throws
        func allows(_ input: AssertInput) async throws -> Bool
        func reply(_ input: ReplyInput) async throws
        func get(_ id: ID) async -> Request?
        func forSession(_ sessionID: SessionID) async -> [Request]
        func list() async -> [Request]
        func nested(call: ToolSchema.CallID, parent: ToolSchema.CallID) -> NestedLease
    }

    // parity: core/src/permission.ts#Service [status=adapted hash=00e0c6724f9e]
    public final class Service: Interface, Sendable {
        public static let serviceKey = "@opencode/Permission"

        private final class DeferredOutcome: @unchecked Sendable {
            private enum Resolution: Sendable {
                case pending([CheckedContinuation<Void, any Swift.Error>])
                case succeeded
                case failed(any Swift.Error)
            }

            private let lock = Mutex<Resolution>(.pending([]))

            func succeed() {
                let waiters: [CheckedContinuation<Void, any Swift.Error>] = lock.withLock { state in
                    guard case .pending(let list) = state else { return [] }
                    state = .succeeded
                    return list
                }
                for w in waiters { w.resume() }
            }

            func fail(_ error: any Swift.Error) {
                let waiters: [CheckedContinuation<Void, any Swift.Error>] = lock.withLock { state in
                    guard case .pending(let list) = state else { return [] }
                    state = .failed(error)
                    return list
                }
                for w in waiters { w.resume(throwing: error) }
            }

            func await() async throws {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Swift.Error>) in
                    let immediate: Swift.Result<Void, any Swift.Error>? = lock.withLock { state in
                        switch state {
                        case .pending(var list):
                            list.append(cont)
                            state = .pending(list)
                            return nil
                        case .succeeded:
                            return .success(())
                        case .failed(let err):
                            return .failure(err)
                        }
                    }
                    if let immediate {
                        cont.resume(with: immediate)
                    }
                }
            }
        }

        private struct Pending: Sendable {
            let request: Request
            let agent: AgentSchema.ID?
            let deferred: DeferredOutcome
        }

        private struct State: Sendable {
            var pending: [ID: Pending] = [:]
            var order: [ID] = []
            var parents: [String: ToolSchema.CallID] = [:]
            var closed = false
        }

        public let projectID: ProjectID
        private let saved: (any CorePermissionSaved.Interface)?
        private let configuredRules: @Sendable (SessionID, AgentSchema.ID?) async throws -> Ruleset
        private let evaluateHook: (@Sendable (EvaluateHookEvent) async -> EvaluateHookEvent)?
        private let onAsked: (@Sendable (Request) async -> Void)?
        private let onReplied: (@Sendable (PermissionSchema.Event.RepliedPayload) async -> Void)?
        private let state = Mutex(State())

        public init(
            projectID: ProjectID = .global,
            saved: (any CorePermissionSaved.Interface)? = nil,
            configuredRules: @escaping @Sendable (SessionID, AgentSchema.ID?) async throws -> Ruleset = { _, _ in
                [Rule(action: "*", resource: "*", effect: .allow)]
            },
            evaluateHook: (@Sendable (EvaluateHookEvent) async -> EvaluateHookEvent)? = nil,
            onAsked: (@Sendable (Request) async -> Void)? = nil,
            onReplied: (@Sendable (PermissionSchema.Event.RepliedPayload) async -> Void)? = nil
        ) {
            self.projectID = projectID
            self.saved = saved
            self.configuredRules = configuredRules
            self.evaluateHook = evaluateHook
            self.onAsked = onAsked
            self.onReplied = onReplied
        }

        public func close() async {
            let items: [Pending] = state.withLock { s in
                s.closed = true
                let list = s.order.compactMap { s.pending[$0] }
                s.pending.removeAll()
                s.order.removeAll()
                return list
            }
            for item in items {
                await onReplied?(PermissionSchema.Event.RepliedPayload(
                    sessionID: item.request.sessionID,
                    requestID: item.request.id,
                    reply: .reject
                ))
                item.deferred.fail(DeclinedError())
            }
        }

        public func ask(_ input: AssertInput) async throws -> AskResult {
            let isClosed = state.withLock { $0.closed }
            if isClosed {
                return AskResult(id: input.id ?? ID.create(), effect: .deny)
            }
            let eval = try await evaluateInput(input)
            let req = makeRequest(input, message: eval.message)
            if eval.effect == .ask {
                _ = try await createPending(req, agent: input.agent)
            }
            return AskResult(id: req.id, effect: eval.effect)
        }

        public func assert(_ input: AssertInput) async throws {
            let isClosed = state.withLock { $0.closed }
            if isClosed { throw DeclinedError() }
            let eval = try await evaluateInput(input)
            if eval.effect == .deny {
                throw BlockedError(
                    rules: relevantRules(for: input, in: eval.rules),
                    permission: input.action,
                    resources: input.resources,
                    reason: eval.message
                )
            }
            if eval.effect == .allow { return }
            let req = makeRequest(input, message: eval.message)
            let item = try await createPending(req, agent: input.agent)
            defer {
                state.withLock { s in
                    s.pending.removeValue(forKey: item.request.id)
                    s.order.removeAll { $0 == item.request.id }
                }
            }
            try await item.deferred.await()
        }

        public func assertNotDenied(_ input: AssertInput) async throws {
            let eval = try await evaluateInput(input)
            if eval.effect != .deny { return }
            throw BlockedError(
                rules: relevantRules(for: input, in: eval.rules),
                permission: input.action,
                resources: input.resources,
                reason: eval.message
            )
        }

        public func allows(_ input: AssertInput) async throws -> Bool {
            let isClosed = state.withLock { $0.closed }
            if isClosed { return false }
            return try await evaluateInput(input).effect == .allow
        }

        public func reply(_ input: ReplyInput) async throws {
            let existing: Pending? = state.withLock { $0.pending[input.requestID] }
            guard let existing else {
                throw NotFoundError(requestID: input.requestID)
            }
            await onReplied?(PermissionSchema.Event.RepliedPayload(
                sessionID: existing.request.sessionID,
                requestID: existing.request.id,
                reply: input.reply
            ))

            if input.reply == .reject {
                let error: any Swift.Error = input.message.map { CorrectedError(feedback: $0) } ?? DeclinedError()
                let siblings: [Pending] = state.withLock { s in
                    s.pending.removeValue(forKey: input.requestID)
                    s.order.removeAll { $0 == input.requestID }
                    let existingMsgID = Self.sourceMessageID(existing.request.source)
                    var matched: [Pending] = []
                    var remainingOrder: [ID] = []
                    for id in s.order {
                        guard let item = s.pending[id] else { continue }
                        if item.request.sessionID == existing.request.sessionID &&
                            Self.sourceMessageID(item.request.source) == existingMsgID
                        {
                            matched.append(item)
                            s.pending.removeValue(forKey: id)
                        } else {
                            remainingOrder.append(id)
                        }
                    }
                    s.order = remainingOrder
                    return matched
                }
                existing.deferred.fail(error)
                for sib in siblings {
                    await onReplied?(PermissionSchema.Event.RepliedPayload(
                        sessionID: sib.request.sessionID,
                        requestID: sib.request.id,
                        reply: .reject
                    ))
                    sib.deferred.fail(error)
                }
                return
            }

            if input.reply == .always, let saveList = existing.request.save, !saveList.isEmpty, let saved {
                try await saved.add(CorePermissionSaved.AddInput(
                    projectID: projectID,
                    action: existing.request.action,
                    resources: saveList
                ))
            }

            state.withLock { s in
                s.pending.removeValue(forKey: input.requestID)
                s.order.removeAll { $0 == input.requestID }
            }
            existing.deferred.succeed()

            guard input.reply == .always, let saveList = existing.request.save, !saveList.isEmpty else {
                return
            }

            let candidates: [Pending] = state.withLock { s in
                s.order.compactMap { s.pending[$0] }
            }
            for item in candidates {
                let recheck = AssertInput(
                    id: item.request.id,
                    sessionID: item.request.sessionID,
                    agent: item.agent,
                    action: item.request.action,
                    resources: item.request.resources,
                    save: item.request.save,
                    metadata: item.request.metadata,
                    source: item.request.source
                )
                guard let evaluated = try? await evaluateInput(recheck), evaluated.effect == .allow else {
                    continue
                }
                let removed = state.withLock { s -> Bool in
                    guard s.pending.removeValue(forKey: item.request.id) != nil else { return false }
                    s.order.removeAll { $0 == item.request.id }
                    return true
                }
                if removed {
                    await onReplied?(PermissionSchema.Event.RepliedPayload(
                        sessionID: item.request.sessionID,
                        requestID: item.request.id,
                        reply: .always
                    ))
                    item.deferred.succeed()
                }
            }
        }

        public func get(_ id: ID) async -> Request? {
            state.withLock { $0.pending[id]?.request }
        }

        public func forSession(_ sessionID: SessionID) async -> [Request] {
            state.withLock { s in
                s.order.compactMap { s.pending[$0]?.request }.filter { $0.sessionID == sessionID }
            }
        }

        public func list() async -> [Request] {
            state.withLock { s in
                s.order.compactMap { s.pending[$0]?.request }
            }
        }

        public func nested(call: ToolSchema.CallID, parent: ToolSchema.CallID) -> NestedLease {
            state.withLock { s in
                s.parents[call.rawValue] = parent
            }
            return NestedLease { [weak self] in
                self?.state.withLock { s in
                    _ = s.parents.removeValue(forKey: call.rawValue)
                }
            }
        }

        private func remapSource(_ source: Source?) -> Source? {
            guard case .tool(let messageID, let id) = source else { return source }
            let parent = state.withLock { $0.parents[id] }
            if let parent {
                return .tool(messageID: messageID, id: parent.rawValue)
            }
            return source
        }

        private static func sourceMessageID(_ source: Source?) -> String? {
            guard case .tool(let messageID, _) = source else { return nil }
            return messageID
        }

        private func evaluateInput(_ input: AssertInput) async throws -> (effect: Effect, message: String?, rules: Ruleset) {
            let rules = try await configuredRules(input.sessionID, input.agent)
            if input.resources.contains(where: { CorePermission.evaluate(action: input.action, resource: $0, rules).effect == .deny }) {
                return (.deny, nil, rules)
            }
            let persisted: Ruleset
            if let saved {
                let items = try await saved.list(CorePermissionSaved.ListInput(projectID: projectID))
                persisted = items.map { Rule(action: $0.action, resource: $0.resource, effect: .allow) }
            } else {
                persisted = []
            }
            let all = CorePermission.merge(rules, persisted)
            let effects = input.resources.map { CorePermission.evaluate(action: input.action, resource: $0, all).effect }
            let initialEffect: Effect = effects.contains(.ask) ? .ask : .allow

            var hookEvent = EvaluateHookEvent(
                sessionID: input.sessionID,
                agent: input.agent,
                action: input.action,
                resources: input.resources,
                metadata: input.metadata,
                source: remapSource(input.source),
                effect: initialEffect,
                message: nil
            )
            if let evaluateHook {
                hookEvent = await evaluateHook(hookEvent)
            }

            if hookEvent.effect != .ask || Unattended.current == nil {
                return (hookEvent.effect, hookEvent.message, all)
            }
            let settled = CorePermission.merge(all, Unattended.current ?? [])
            let allowed = input.resources.allSatisfy {
                CorePermission.evaluate(action: input.action, resource: $0, settled).effect == .allow
            }
            if allowed {
                return (.allow, nil, all)
            }
            return (
                .deny,
                "Permission \(input.action) needs approval, and nobody is present to give it",
                all
            )
        }

        private func relevantRules(for input: AssertInput, in rules: Ruleset) -> Ruleset {
            rules.filter { CorePermissionWildcard.match(input.action, pattern: $0.action) }
        }

        private func makeRequest(_ input: AssertInput, message: String?) -> Request {
            Request(
                id: input.id ?? ID.create(),
                sessionID: input.sessionID,
                action: input.action,
                resources: input.resources,
                save: input.save,
                metadata: input.metadata,
                source: remapSource(input.source),
                message: message
            )
        }

        private func createPending(_ request: Request, agent: AgentSchema.ID?) async throws -> Pending {
            let deferred = DeferredOutcome()
            let item = Pending(request: request, agent: agent, deferred: deferred)
            let inserted: Bool = try state.withLock { s in
                if s.closed {
                    return false
                }
                if s.pending[request.id] != nil {
                    throw BlockedError(
                        rules: [],
                        permission: request.action,
                        resources: request.resources,
                        reason: "Duplicate pending permission ID: \(request.id.rawValue)"
                    )
                }
                s.pending[request.id] = item
                s.order.append(request.id)
                return true
            }
            if !inserted {
                deferred.fail(DeclinedError())
                return item
            }
            await onAsked?(request)
            return item
        }
    }

    // parity: core/src/permission.ts#node [status=adapted hash=c6ce0e94f9a4]
    public static let node: LayerNode.Provider = AppNode.makeLocationNode(
        Service.serviceKey,
        LayerNode.ExecutableLayer { deps, _ in
            let saved = deps.get(CorePermissionSaved.Service.serviceKey, as: (any CorePermissionSaved.Interface).self)
            let service = Service(saved: saved)
            return LayerNode.Output([Service.serviceKey: service])
        },
        [CorePermissionSaved.node]
    )
}
