#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import OpenCodeUtil

// MARK: - SessionMetadata (`src/session-metadata.ts`)

/// Host-supplied session annotations, durable and opaque to core (`packages/schema/src/session-metadata.ts`).
public enum SessionMetadataSchema {
    /// Arbitrary key-value JSON annotations attached to a session.
    // parity: schema/src/session-metadata.ts#SessionMetadata [status=implemented hash=153aada7ecbc]
    public typealias SessionMetadata = [String: JSONValue]
}

// MARK: - SessionError (`src/session-error.ts`)

/// Structured error contract for session, step, tool, and compaction failures (`packages/schema/src/session-error.ts`).
public enum SessionErrorSchema {
    /// Wire error payload matching `Session.StructuredError`.
    // parity: schema/src/session-error.ts#Error [status=implemented hash=a29a8e2cce3e]
    public struct Error: Swift.Error, Equatable, Hashable, Sendable, Codable {
        public struct Response: Equatable, Hashable, Sendable, Codable {
            public let body: String

            public init(body: String) {
                self.body = body
            }
        }

        public let type: String
        public let message: String
        public let status: Int?
        public let response: Response?
        /// How long the provider asked to wait before trying again, counted from when the failure was recorded.
        public let retryAfterMs: Int64?

        public init(
            type: String,
            message: String,
            status: Int? = nil,
            response: Response? = nil,
            retryAfterMs: Int64? = nil
        ) {
            self.type = type
            self.message = message
            self.status = status
            self.response = response
            self.retryAfterMs = retryAfterMs
        }

        private enum CodingKeys: String, CodingKey {
            case type
            case message
            case status
            case response
            case retryAfterMs
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            let message = try container.decode(String.self, forKey: .message)
            let status = try container.decodeIfPresent(Int.self, forKey: .status)
            if let status, !(100...599).contains(status) {
                throw DecodingError.dataCorruptedError(
                    forKey: .status,
                    in: container,
                    debugDescription: "HTTP status \(status) must be between 100 and 599"
                )
            }
            let response = try container.decodeIfPresent(Response.self, forKey: .response)
            let retryAfterMs = try container.decodeIfPresent(Int64.self, forKey: .retryAfterMs)
            if let retryAfterMs, retryAfterMs < 0 {
                throw DecodingError.dataCorruptedError(
                    forKey: .retryAfterMs,
                    in: container,
                    debugDescription: "retryAfterMs \(retryAfterMs) must be non-negative"
                )
            }
            self.type = type
            self.message = message
            self.status = status
            self.response = response
            self.retryAfterMs = retryAfterMs
        }
    }
}

// MARK: - SessionFork (`src/session-fork.ts`)

/// Session fork boundary contracts (`packages/schema/src/session-fork.ts`).
public enum SessionForkSchema {
    /// Message boundary defining where a forked session branches from its parent.
    // parity: schema/src/session-fork.ts#Boundary [status=implemented hash=0268c3b3be39]
    public enum Boundary: Equatable, Hashable, Sendable, Codable {
        case before(messageID: SessionMessageSchema.ID)
        case through(messageID: SessionMessageSchema.ID)

        public var messageID: SessionMessageSchema.ID {
            switch self {
            case .before(let id), .through(let id): id
            }
        }

        public var typeTag: String {
            switch self {
            case .before: "before"
            case .through: "through"
            }
        }

        private enum CodingKeys: String, CodingKey {
            case type
            case messageID
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            let messageID = try container.decode(SessionMessageSchema.ID.self, forKey: .messageID)
            switch type {
            case "before":
                self = .before(messageID: messageID)
            case "through":
                self = .through(messageID: messageID)
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .type,
                    in: container,
                    debugDescription: "Unknown Session.ForkBoundary type '\(type)'"
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .before(let messageID):
                try container.encode("before", forKey: .type)
                try container.encode(messageID, forKey: .messageID)
            case .through(let messageID):
                try container.encode("through", forKey: .type)
                try container.encode(messageID, forKey: .messageID)
            }
        }
    }
}

// MARK: - SessionRevert (`src/session-revert.ts`)

/// Session revert and legacy persisted revert contracts (`packages/schema/src/session-revert.ts`).
public enum SessionRevertSchema {
    /// Canonical staged revert state for a session.
    // parity: schema/src/session-revert.ts#Revert [status=implemented hash=e80df2d84d7d]
    public struct Revert: Equatable, Hashable, Sendable, Codable {
        public let messageID: SessionMessageSchema.ID
        /// Legacy V1 compatibility state.
        public let partID: String?
        public let snapshot: String?
        public let files: [SessionSchema.FileDiffInfo]?

        public init(
            messageID: SessionMessageSchema.ID,
            partID: String? = nil,
            snapshot: String? = nil,
            files: [SessionSchema.FileDiffInfo]? = nil
        ) {
            self.messageID = messageID
            self.partID = partID
            self.snapshot = snapshot
            self.files = files
        }
    }

    /// Legacy V1 persisted revert shape using `path` instead of canonical `FileDiff.Info.file`.
    // parity: schema/src/session-revert.ts#RevertV1 [status=implemented hash=78c5eae588de]
    public struct RevertV1: Equatable, Hashable, Sendable, Codable {
        public struct FileDiffV1: Equatable, Hashable, Sendable, Codable {
            public let path: String
            public let status: SessionSchema.FileDiffInfo.Status
            public let additions: Int
            public let deletions: Int
            public let patch: String

            public init(
                path: String,
                status: SessionSchema.FileDiffInfo.Status,
                additions: Int,
                deletions: Int,
                patch: String
            ) {
                self.path = path
                self.status = status
                self.additions = additions
                self.deletions = deletions
                self.patch = patch
            }
        }

        public let messageID: SessionMessageSchema.ID
        public let partID: String?
        public let snapshot: String?
        public let diff: String?
        public let files: [FileDiffV1]?

        public init(
            messageID: SessionMessageSchema.ID,
            partID: String? = nil,
            snapshot: String? = nil,
            diff: String? = nil,
            files: [FileDiffV1]? = nil
        ) {
            self.messageID = messageID
            self.partID = partID
            self.snapshot = snapshot
            self.diff = diff
            self.files = files
        }
    }

    /// Storage decoder for revert state written before `FileDiff` became canonical.
    /// Decodes either canonical `Revert` or legacy `RevertV1`, normalizing into `Revert`, and always encodes canonical `Revert`.
    // parity: schema/src/session-revert.ts#PersistedRevert [status=implemented hash=844d87a07112]
    public struct PersistedRevert: Equatable, Hashable, Sendable, Codable {
        public let revert: Revert

        public init(revert: Revert) {
            self.revert = revert
        }

        public init(from decoder: Decoder) throws {
            if let current = try? Revert(from: decoder) {
                self.revert = current
                return
            }
            let legacy = try RevertV1(from: decoder)
            let normalizedSnapshot: String? = {
                guard let snap = legacy.snapshot, !snap.isEmpty else { return nil }
                return snap
            }()
            let normalizedFiles = legacy.files?.map { file in
                SessionSchema.FileDiffInfo(
                    file: file.path,
                    patch: file.patch,
                    additions: file.additions,
                    deletions: file.deletions,
                    status: file.status
                )
            }
            self.revert = Revert(
                messageID: legacy.messageID,
                partID: legacy.partID,
                snapshot: normalizedSnapshot,
                files: normalizedFiles
            )
        }

        public func encode(to encoder: Encoder) throws {
            try revert.encode(to: encoder)
        }
    }
}

// MARK: - Session (`src/session.ts`)

/// Core session read model, list filter, pagination anchor, and cursor schemas (`packages/schema/src/session.ts`).
public enum SessionSchema {
    /// Wire coordinate matching `Location.Ref`.
    public typealias LocationRef = OpenCodeLocation

    /// Wire model reference matching `Model.Ref` (`providerID`, `id`, optional `variant`).
    public struct ModelRef: Equatable, Hashable, Sendable, Codable {
        public let id: String
        public let providerID: String
        public let variant: String?

        public init(id: String, providerID: String, variant: String? = nil) {
            self.id = id
            self.providerID = providerID
            self.variant = variant
        }
    }

    /// Wire token usage summary matching `TokenUsage.Info`.
    public struct TokenUsage: Equatable, Hashable, Sendable, Codable {
        public struct Cache: Equatable, Hashable, Sendable, Codable {
            public let read: Double
            public let write: Double

            public init(read: Double, write: Double) {
                self.read = read
                self.write = write
            }
        }

        public let input: Double
        public let output: Double
        public let reasoning: Double
        public let cache: Cache

        public init(input: Double, output: Double, reasoning: Double, cache: Cache) {
            self.input = input
            self.output = output
            self.reasoning = reasoning
            self.cache = cache
        }

        public static let zero = TokenUsage(
            input: 0,
            output: 0,
            reasoning: 0,
            cache: Cache(read: 0, write: 0)
        )

        public var total: Double {
            input + output + reasoning + cache.read + cache.write
        }
    }

    /// Wire permission effect matching `Permission.Effect`.
    public enum PermissionEffect: String, Equatable, Hashable, Sendable, Codable {
        case allow
        case deny
        case ask
    }

    /// Wire permission rule matching `Permission.Rule`.
    public struct PermissionRule: Equatable, Hashable, Sendable, Codable {
        public let action: String
        public let resource: String
        public let effect: PermissionEffect

        public init(action: String, resource: String, effect: PermissionEffect) {
            self.action = action
            self.resource = resource
            self.effect = effect
        }
    }

    /// Wire permission ruleset matching `Permission.Ruleset`.
    public typealias PermissionRuleset = [PermissionRule]

    /// Wire file diff entry matching `FileDiff.Info`.
    public struct FileDiffInfo: Equatable, Hashable, Sendable, Codable {
        public enum Status: String, Equatable, Hashable, Sendable, Codable {
            case added
            case deleted
            case modified
        }

        public let file: String
        public let patch: String
        public let additions: Int
        public let deletions: Int
        public let status: Status
        /// Marks the entry a folder listing adds for itself when it stopped before showing or checking every entry.
        public let more: Bool?

        public init(
            file: String,
            patch: String,
            additions: Int,
            deletions: Int,
            status: Status,
            more: Bool? = nil
        ) {
            self.file = file
            self.patch = patch
            self.additions = additions
            self.deletions = deletions
            self.status = status
            self.more = more
        }

        private enum CodingKeys: String, CodingKey {
            case file
            case patch
            case additions
            case deletions
            case status
            case more
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let file = try container.decode(String.self, forKey: .file)
            let patch = try container.decode(String.self, forKey: .patch)
            let additions = try container.decode(Int.self, forKey: .additions)
            if additions < 0 {
                throw DecodingError.dataCorruptedError(
                    forKey: .additions,
                    in: container,
                    debugDescription: "additions must be non-negative"
                )
            }
            let deletions = try container.decode(Int.self, forKey: .deletions)
            if deletions < 0 {
                throw DecodingError.dataCorruptedError(
                    forKey: .deletions,
                    in: container,
                    debugDescription: "deletions must be non-negative"
                )
            }
            let status = try container.decode(Status.self, forKey: .status)
            let more = try container.decodeIfPresent(Bool.self, forKey: .more)
            if let more, !more {
                throw DecodingError.dataCorruptedError(
                    forKey: .more,
                    in: container,
                    debugDescription: "more must be true when present"
                )
            }
            self.file = file
            self.patch = patch
            self.additions = additions
            self.deletions = deletions
            self.status = status
            self.more = more
        }
    }

    /// Terminal execution outcome recorded when a session transitions to idle.
    public enum Outcome: String, Equatable, Hashable, Sendable, Codable {
        case succeeded
        case failed
        case interrupted
    }

    /// Sort direction for session listing.
    public enum SortOrder: String, Equatable, Hashable, Sendable, Codable {
        case asc
        case desc
    }

    /// Filter value for `parentID`: either a specific parent session ID or `null` (root sessions only).
    /// Encodes `.root` as the literal string `"null"` to match upstream query/cursor encoding.
    public enum ParentFilter: Equatable, Hashable, Sendable, Codable {
        case session(SessionID)
        case root

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .root
                return
            }
            let raw = try container.decode(String.self)
            if raw == "null" {
                self = .root
                return
            }
            self = .session(try SessionID(validating: raw))
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .session(let id):
                try container.encode(id)
            case .root:
                try container.encode("null")
            }
        }
    }

    /// Branded session identifier alias.
    // parity: schema/src/session.ts#ID [status=implemented hash=abd6f39b6f39]
    public typealias ID = SessionID

    /// Session metadata map alias.
    // parity: schema/src/session.ts#Metadata [status=implemented hash=25270102f6b8]
    public typealias Metadata = SessionMetadataSchema.SessionMetadata

    /// Session event namespace alias.
    // parity: schema/src/session.ts#Event [status=implemented hash=88a0baca52c2]
    public typealias Event = SessionEventSchema

    /// Session revert record alias.
    // parity: schema/src/session.ts#Revert [status=implemented hash=8a9ab5ac8611]
    public typealias Revert = SessionRevertSchema.Revert

    /// Session fork boundary alias.
    // parity: schema/src/session.ts#ForkBoundary [status=implemented hash=362d7e4f44e8]
    public typealias ForkBoundary = SessionForkSchema.Boundary

    /// Canonical projected session record (`Session.Info`).
    // parity: schema/src/session.ts#Info [status=implemented hash=1821aa3b7f74]
    public struct Info: Equatable, Hashable, Sendable, Codable {
        public struct Fork: Equatable, Hashable, Sendable, Codable {
            public let sessionID: ID
            public let boundary: ForkBoundary

            public init(sessionID: ID, boundary: ForkBoundary) {
                self.sessionID = sessionID
                self.boundary = boundary
            }
        }

        public struct Time: Equatable, Hashable, Sendable, Codable {
            public let created: Int64
            public let updated: Int64
            public let busy: Int64?
            public let idle: Int64?
            public let viewed: Int64?
            public let archived: Int64?

            public init(
                created: Int64,
                updated: Int64,
                busy: Int64? = nil,
                idle: Int64? = nil,
                viewed: Int64? = nil,
                archived: Int64? = nil
            ) {
                self.created = created
                self.updated = updated
                self.busy = busy
                self.idle = idle
                self.viewed = viewed
                self.archived = archived
            }
        }

        public let id: ID
        public let parentID: ID?
        public let fork: Fork?
        public let projectID: ProjectID
        public let agent: String?
        public let model: ModelRef?
        public let cost: Double
        public let tokens: TokenUsage
        public let outcome: Outcome?
        public let time: Time
        public let title: String?
        public let location: LocationRef
        public let subpath: String?
        public let metadata: Metadata?
        public let permissions: PermissionRuleset?
        public let revert: SessionRevertSchema.Revert?

        public init(
            id: ID,
            parentID: ID? = nil,
            fork: Fork? = nil,
            projectID: ProjectID,
            agent: String? = nil,
            model: ModelRef? = nil,
            cost: Double,
            tokens: TokenUsage,
            outcome: Outcome? = nil,
            time: Time,
            title: String? = nil,
            location: LocationRef,
            subpath: String? = nil,
            metadata: Metadata? = nil,
            permissions: PermissionRuleset? = nil,
            revert: SessionRevertSchema.Revert? = nil
        ) {
            self.id = id
            self.parentID = parentID
            self.fork = fork
            self.projectID = projectID
            self.agent = agent
            self.model = model
            self.cost = cost
            self.tokens = tokens
            self.outcome = outcome
            self.time = time
            self.title = title
            self.location = location
            self.subpath = subpath
            self.metadata = metadata
            self.permissions = permissions
            self.revert = revert
        }
    }

    /// Keyset pagination anchor (`Session.ListAnchor`).
    // parity: schema/src/session.ts#ListAnchor [status=implemented hash=8c1f28b6017a]
    public struct ListAnchor: Equatable, Hashable, Sendable, Codable {
        public enum Direction: String, Equatable, Hashable, Sendable, Codable {
            case previous
            case next
        }

        public let id: ID
        public let time: Int64
        public let direction: Direction

        public init(id: ID, time: Int64, direction: Direction) {
            self.id = id
            self.time = time
            self.direction = direction
        }
    }

    /// Query filter for listing sessions (`Session.ListFilter`).
    /// Encodes `archived` as `"true"` / `"false"` and `parentID: .root` as `"null"` to match upstream wire format.
    // parity: schema/src/session.ts#ListFilter [status=implemented hash=f67cb9d7178f]
    public struct ListFilter: Equatable, Hashable, Sendable, Codable {
        public let order: SortOrder?
        public let search: String?
        public let parentID: ParentFilter?
        public let archived: Bool?
        public let directory: String?
        public let project: ProjectID?
        public let subpath: String?

        public init(
            order: SortOrder? = nil,
            search: String? = nil,
            parentID: ParentFilter? = nil,
            archived: Bool? = nil,
            directory: String? = nil,
            project: ProjectID? = nil,
            subpath: String? = nil
        ) {
            self.order = order
            self.search = search
            self.parentID = parentID
            self.archived = archived
            self.directory = directory
            self.project = project
            self.subpath = subpath
        }

        private enum CodingKeys: String, CodingKey {
            case order
            case search
            case parentID
            case archived
            case directory
            case project
            case subpath
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.order = try container.decodeIfPresent(SortOrder.self, forKey: .order)
            self.search = try container.decodeIfPresent(String.self, forKey: .search)
            self.parentID = try container.decodeIfPresent(ParentFilter.self, forKey: .parentID)
            if container.contains(.archived) {
                if let str = try? container.decode(String.self, forKey: .archived) {
                    switch str {
                    case "true": self.archived = true
                    case "false": self.archived = false
                    default:
                        throw DecodingError.dataCorruptedError(
                            forKey: .archived,
                            in: container,
                            debugDescription: "archived must be 'true' or 'false'"
                        )
                    }
                } else {
                    self.archived = try container.decode(Bool.self, forKey: .archived)
                }
            } else {
                self.archived = nil
            }
            self.directory = try container.decodeIfPresent(String.self, forKey: .directory)
            self.project = try container.decodeIfPresent(ProjectID.self, forKey: .project)
            self.subpath = try container.decodeIfPresent(String.self, forKey: .subpath)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(order, forKey: .order)
            try container.encodeIfPresent(search, forKey: .search)
            try container.encodeIfPresent(parentID, forKey: .parentID)
            if let archived {
                try container.encode(archived ? "true" : "false", forKey: .archived)
            }
            try container.encodeIfPresent(directory, forKey: .directory)
            try container.encodeIfPresent(project, forKey: .project)
            try container.encodeIfPresent(subpath, forKey: .subpath)
        }
    }

    /// Opaque URL-safe Base64 pagination cursor (`SessionsCursor`).
    // parity: schema/src/session.ts#ListCursor [status=implemented hash=b3a3de08234f]
    public struct ListCursor: RawRepresentable, Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
        public enum CursorError: Swift.Error, Equatable, Sendable {
            case invalidCursor
        }

        public enum Scope: Equatable, Hashable, Sendable {
            case directory(String)
            case project(ProjectID, subpath: String? = nil)
            case all
        }

        public struct Payload: Equatable, Hashable, Sendable, Codable {
            public let order: SortOrder?
            public let search: String?
            public let parentID: ParentFilter?
            public let archived: Bool?
            public let scope: Scope
            public let anchor: ListAnchor

            public init(
                order: SortOrder? = nil,
                search: String? = nil,
                parentID: ParentFilter? = nil,
                archived: Bool? = nil,
                scope: Scope = .all,
                anchor: ListAnchor
            ) {
                self.order = order
                self.search = search
                self.parentID = parentID
                self.archived = archived
                self.scope = scope
                self.anchor = anchor
            }

            private enum CodingKeys: String, CodingKey {
                case order
                case search
                case parentID
                case archived
                case directory
                case project
                case subpath
                case anchor
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.order = try container.decodeIfPresent(SortOrder.self, forKey: .order)
                self.search = try container.decodeIfPresent(String.self, forKey: .search)
                self.parentID = try container.decodeIfPresent(ParentFilter.self, forKey: .parentID)
                if container.contains(.archived) {
                    if let str = try? container.decode(String.self, forKey: .archived) {
                        switch str {
                        case "true": self.archived = true
                        case "false": self.archived = false
                        default:
                            throw DecodingError.dataCorruptedError(
                                forKey: .archived,
                                in: container,
                                debugDescription: "archived must be 'true' or 'false'"
                            )
                        }
                    } else {
                        self.archived = try container.decode(Bool.self, forKey: .archived)
                    }
                } else {
                    self.archived = nil
                }
                if let directory = try container.decodeIfPresent(String.self, forKey: .directory) {
                    self.scope = .directory(directory)
                } else if let project = try container.decodeIfPresent(ProjectID.self, forKey: .project) {
                    let subpath = try container.decodeIfPresent(String.self, forKey: .subpath)
                    self.scope = .project(project, subpath: subpath)
                } else {
                    self.scope = .all
                }
                self.anchor = try container.decode(ListAnchor.self, forKey: .anchor)
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encodeIfPresent(order, forKey: .order)
                try container.encodeIfPresent(search, forKey: .search)
                try container.encodeIfPresent(parentID, forKey: .parentID)
                if let archived {
                    try container.encode(archived ? "true" : "false", forKey: .archived)
                }
                switch scope {
                case .directory(let directory):
                    try container.encode(directory, forKey: .directory)
                case .project(let project, let subpath):
                    try container.encode(project, forKey: .project)
                    try container.encodeIfPresent(subpath, forKey: .subpath)
                case .all:
                    break
                }
                try container.encode(anchor, forKey: .anchor)
            }
        }

        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public var description: String { rawValue }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            self.rawValue = try container.decode(String.self)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }

        public static func make(_ payload: Payload) throws(CursorError) -> ListCursor {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            guard let data = try? encoder.encode(payload),
                  let json = String(data: data, encoding: .utf8)
            else {
                throw .invalidCursor
            }
            return ListCursor(rawValue: base64Encode(json))
        }

        public static func parse(_ input: String) throws(CursorError) -> Payload {
            guard !input.isEmpty,
                  let json = try? base64Decode(input),
                  let data = json.data(using: .utf8),
                  let payload = try? JSONDecoder().decode(Payload.self, from: data)
            else {
                throw .invalidCursor
            }
            return payload
        }

        public func parse() throws(CursorError) -> Payload {
            try Self.parse(rawValue)
        }
    }
}

// MARK: - SessionStats (`src/session-stats.ts`)

/// Session usage statistics schemas (`packages/schema/src/session-stats.ts`).
public enum SessionStatsSchema {
    /// Daily step activity entry (`SessionStats.Activity`).
    // parity: schema/src/session-stats.ts#Activity [status=implemented hash=840a5a747482]
    public struct Activity: Equatable, Hashable, Sendable, Codable {
        public let date: String
        public let steps: Int

        public init(date: String, steps: Int) {
            self.date = date
            self.steps = steps
        }

        private enum CodingKeys: String, CodingKey {
            case date
            case steps
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let date = try container.decode(String.self, forKey: .date)
            let steps = try container.decode(Int.self, forKey: .steps)
            guard steps >= 0 else {
                throw DecodingError.dataCorruptedError(forKey: .steps, in: container, debugDescription: "steps must be non-negative")
            }
            self.date = date
            self.steps = steps
        }
    }

    /// Aggregated model usage entry (`SessionStats.ModelUsage`).
    // parity: schema/src/session-stats.ts#ModelUsage [status=implemented hash=5694003e6ee6]
    public struct ModelUsage: Equatable, Hashable, Sendable, Codable {
        public let model: SessionSchema.ModelRef
        public let steps: Int
        public let tokens: SessionSchema.TokenUsage
        public let cost: Double

        public init(model: SessionSchema.ModelRef, steps: Int, tokens: SessionSchema.TokenUsage, cost: Double) {
            self.model = model
            self.steps = steps
            self.tokens = tokens
            self.cost = cost
        }

        private enum CodingKeys: String, CodingKey {
            case model
            case steps
            case tokens
            case cost
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let model = try container.decode(SessionSchema.ModelRef.self, forKey: .model)
            let steps = try container.decode(Int.self, forKey: .steps)
            guard steps >= 0 else {
                throw DecodingError.dataCorruptedError(forKey: .steps, in: container, debugDescription: "steps must be non-negative")
            }
            let tokens = try container.decode(SessionSchema.TokenUsage.self, forKey: .tokens)
            let cost = try container.decode(Double.self, forKey: .cost)
            self.model = model
            self.steps = steps
            self.tokens = tokens
            self.cost = cost
        }
    }

    /// Per-tool call statistics (`SessionStats.ToolUsage`).
    // parity: schema/src/session-stats.ts#ToolUsage [status=implemented hash=bd3f43e7dafd]
    public struct ToolUsage: Equatable, Hashable, Sendable, Codable {
        public let name: String
        public let calls: Int
        public let succeeded: Int
        public let failed: Int
        public let unfinished: Int
        public let durationP50: Double?

        public init(
            name: String,
            calls: Int,
            succeeded: Int,
            failed: Int,
            unfinished: Int,
            durationP50: Double? = nil
        ) {
            self.name = name
            self.calls = calls
            self.succeeded = succeeded
            self.failed = failed
            self.unfinished = unfinished
            self.durationP50 = durationP50
        }

        private enum CodingKeys: String, CodingKey {
            case name
            case calls
            case succeeded
            case failed
            case unfinished
            case durationP50
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.name = try container.decode(String.self, forKey: .name)
            self.calls = try Self.decodeNonNegative(container, forKey: .calls)
            self.succeeded = try Self.decodeNonNegative(container, forKey: .succeeded)
            self.failed = try Self.decodeNonNegative(container, forKey: .failed)
            self.unfinished = try Self.decodeNonNegative(container, forKey: .unfinished)
            self.durationP50 = try container.decodeIfPresent(Double.self, forKey: .durationP50)
        }

        private static func decodeNonNegative(
            _ container: KeyedDecodingContainer<CodingKeys>,
            forKey key: CodingKeys
        ) throws -> Int {
            let value = try container.decode(Int.self, forKey: key)
            guard value >= 0 else {
                throw DecodingError.dataCorruptedError(
                    forKey: key,
                    in: container,
                    debugDescription: "\(key.stringValue) must be non-negative"
                )
            }
            return value
        }
    }

    /// Requested level of tool statistics detail (`SessionStats.ToolMode`).
    // parity: schema/src/session-stats.ts#ToolMode [status=implemented hash=9841731f7826]
    public enum ToolMode: String, Equatable, Hashable, Sendable, Codable {
        case none
        case summary
        case detail
    }

    /// Aggregate tool invocation totals (`SessionStats.ToolTotals`).
    // parity: schema/src/session-stats.ts#ToolTotals [status=implemented hash=34b551ecaf48]
    public struct ToolTotals: Equatable, Hashable, Sendable, Codable {
        public let calls: Int
        public let succeeded: Int
        public let failed: Int
        public let unfinished: Int

        public init(calls: Int, succeeded: Int, failed: Int, unfinished: Int) {
            self.calls = calls
            self.succeeded = succeeded
            self.failed = failed
            self.unfinished = unfinished
        }

        private enum CodingKeys: String, CodingKey {
            case calls
            case succeeded
            case failed
            case unfinished
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let calls = try container.decode(Int.self, forKey: .calls)
            let succeeded = try container.decode(Int.self, forKey: .succeeded)
            let failed = try container.decode(Int.self, forKey: .failed)
            let unfinished = try container.decode(Int.self, forKey: .unfinished)
            guard calls >= 0, succeeded >= 0, failed >= 0, unfinished >= 0 else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: container.codingPath,
                        debugDescription: "ToolTotals counts must be non-negative"
                    )
                )
            }
            self.calls = calls
            self.succeeded = succeeded
            self.failed = failed
            self.unfinished = unfinished
        }
    }

    /// Discriminated union of tool statistics payload shapes (`SessionStats.Tools`).
    // parity: schema/src/session-stats.ts#Tools [status=implemented hash=f0717c1b9c4f]
    public enum Tools: Equatable, Hashable, Sendable, Codable {
        case none
        case summary(totals: ToolTotals)
        case detail(totals: ToolTotals, usage: [ToolUsage])

        public var mode: ToolMode {
            switch self {
            case .none: .none
            case .summary: .summary
            case .detail: .detail
            }
        }

        private enum CodingKeys: String, CodingKey {
            case mode
            case totals
            case usage
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let mode = try container.decode(ToolMode.self, forKey: .mode)
            switch mode {
            case .none:
                self = .none
            case .summary:
                let totals = try container.decode(ToolTotals.self, forKey: .totals)
                self = .summary(totals: totals)
            case .detail:
                let totals = try container.decode(ToolTotals.self, forKey: .totals)
                let usage = try container.decode([ToolUsage].self, forKey: .usage)
                self = .detail(totals: totals, usage: usage)
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .none:
                try container.encode(ToolMode.none, forKey: .mode)
            case .summary(let totals):
                try container.encode(ToolMode.summary, forKey: .mode)
                try container.encode(totals, forKey: .totals)
            case .detail(let totals, let usage):
                try container.encode(ToolMode.detail, forKey: .mode)
                try container.encode(totals, forKey: .totals)
                try container.encode(usage, forKey: .usage)
            }
        }
    }

    /// Full session statistics response (`SessionStats.Info`).
    // parity: schema/src/session-stats.ts#Info [status=implemented hash=04103a4605c5]
    public struct Info: Equatable, Hashable, Sendable, Codable {
        public struct TimeRange: Equatable, Hashable, Sendable, Codable {
            public let from: Int64
            public let to: Int64

            public init(from: Int64, to: Int64) {
                self.from = from
                self.to = to
            }
        }

        public let range: TimeRange
        public let sessions: Int
        public let subagents: Int
        public let prompts: Int
        public let steps: Int
        public let tokens: SessionSchema.TokenUsage
        public let cost: Double
        public let tools: Tools
        public let activeDays: Int
        public let streak: Int
        public let activity: [Activity]
        public let models: [ModelUsage]

        public init(
            range: TimeRange,
            sessions: Int,
            subagents: Int,
            prompts: Int,
            steps: Int,
            tokens: SessionSchema.TokenUsage,
            cost: Double,
            tools: Tools,
            activeDays: Int,
            streak: Int,
            activity: [Activity],
            models: [ModelUsage]
        ) {
            self.range = range
            self.sessions = sessions
            self.subagents = subagents
            self.prompts = prompts
            self.steps = steps
            self.tokens = tokens
            self.cost = cost
            self.tools = tools
            self.activeDays = activeDays
            self.streak = streak
            self.activity = activity
            self.models = models
        }

        private enum CodingKeys: String, CodingKey {
            case range
            case sessions
            case subagents
            case prompts
            case steps
            case tokens
            case cost
            case tools
            case activeDays
            case streak
            case activity
            case models
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.range = try container.decode(TimeRange.self, forKey: .range)
            self.sessions = try Self.decodeNonNegative(container, forKey: .sessions)
            self.subagents = try Self.decodeNonNegative(container, forKey: .subagents)
            self.prompts = try Self.decodeNonNegative(container, forKey: .prompts)
            self.steps = try Self.decodeNonNegative(container, forKey: .steps)
            self.tokens = try container.decode(SessionSchema.TokenUsage.self, forKey: .tokens)
            self.cost = try container.decode(Double.self, forKey: .cost)
            self.tools = try container.decode(Tools.self, forKey: .tools)
            self.activeDays = try Self.decodeNonNegative(container, forKey: .activeDays)
            self.streak = try Self.decodeNonNegative(container, forKey: .streak)
            self.activity = try container.decode([Activity].self, forKey: .activity)
            self.models = try container.decode([ModelUsage].self, forKey: .models)
        }

        private static func decodeNonNegative(
            _ container: KeyedDecodingContainer<CodingKeys>,
            forKey key: CodingKeys
        ) throws -> Int {
            let value = try container.decode(Int.self, forKey: key)
            guard value >= 0 else {
                throw DecodingError.dataCorruptedError(
                    forKey: key,
                    in: container,
                    debugDescription: "\(key.stringValue) must be non-negative"
                )
            }
            return value
        }
    }
}

// MARK: - SessionTransfer (`src/session-transfer.ts`)

/// Session import/export payload (`packages/schema/src/session-transfer.ts`).
public enum SessionTransferSchema {
    /// Complete portable session bundle (`SessionTransfer.Data`).
    // parity: schema/src/session-transfer.ts#Data [status=implemented hash=04d541ba4aca]
    public struct Data: Equatable, Hashable, Sendable, Codable {
        public let info: SessionSchema.Info
        public let messages: [SessionMessageSchema.Info]

        public init(info: SessionSchema.Info, messages: [SessionMessageSchema.Info]) {
            self.info = info
            self.messages = messages
        }
    }
}

// MARK: - SessionLegacy (`src/session-legacy.ts`)

/// Storage and wire compatibility upgrades for pre-v2.1 session events, messages, and parts (`packages/schema/src/session-legacy.ts`).
public enum SessionLegacySchema {
    private static let renames: [String: (String, String)] = [
        "session.text.ended": ("state", "native"),
        "session.reasoning.started": ("state", "native"),
        "session.reasoning.ended": ("state", "native"),
        "session.tool.called": ("state", "native"),
        "session.step.ended": ("providerState", "native"),
        "session.step.failed": ("providerState", "native"),
        "session.tool.success": ("resultState", "native"),
        "session.tool.failed": ("resultState", "native"),
    ]

    /// Upgrades a durable event payload by event type.
    // parity: schema/src/session-legacy.ts#event [status=implemented hash=e2b57173f36e]
    public static func event(type: String, data: JSONValue) -> JSONValue {
        guard case .object(let dict) = data else { return data }
        if type == "session.message.content.updated" {
            return .object(content(dict))
        }
        if type == "session.compaction.started" {
            return .object(omit(dict, "recent"))
        }
        if type == "session.compaction.ended" {
            return .object(providerContext(omit(rename(dict, from: "providerState", to: "native"), "recent")))
        }
        if let entry = renames[type] {
            return .object(rename(dict, from: entry.0, to: entry.1))
        }
        return data
    }

    /// Upgrades a projected message's data by message type.
    // parity: schema/src/session-legacy.ts#message [status=implemented hash=1981a650c072]
    public static func message(type: JSONValue?, data: [String: JSONValue]) -> [String: JSONValue] {
        if type == .string("assistant") {
            return content(rename(data, from: "providerState", to: "native"))
        }
        if type == .string("compaction") {
            return providerContext(recent(rename(data, from: "providerState", to: "native")))
        }
        return data
    }

    /// Upgrades complete messages, such as those in an exported session, before decoding.
    // parity: schema/src/session-legacy.ts#messages [status=implemented hash=a44b12663660]
    public static func messages(_ values: [JSONValue]) -> [JSONValue] {
        values.map { value in
            guard case .object(let dict) = value else { return value }
            return .object(message(type: dict["type"], data: dict))
        }
    }

    /// Upgrades an assistant content part written before v2.1.
    // parity: schema/src/session-legacy.ts#part [status=implemented hash=aff8e6d63667]
    public static func part(_ value: JSONValue) -> JSONValue {
        guard case .object(let dict) = value else { return value }
        if dict["type"] == .string("text") || dict["type"] == .string("reasoning") {
            return .object(rename(dict, from: "state", to: "native"))
        }
        // A tool part's own `state` is its lifecycle status, not native data.
        if dict["type"] == .string("tool") {
            return .object(toolResult(rename(dict, from: "providerState", to: "native")))
        }
        return value
    }

    private static func content(_ data: [String: JSONValue]) -> [String: JSONValue] {
        guard case .array(let items) = data["content"] else { return data }
        var copy = data
        copy["content"] = .array(items.map(part))
        return copy
    }

    private static func recent(_ data: [String: JSONValue]) -> [String: JSONValue] {
        let text = data["recent"]
        let rest = omit(data, "recent")
        guard case .string(let recentText) = text, !recentText.isEmpty else { return rest }
        var metadata: [String: JSONValue] = ["recent": .string(recentText)]
        if case .object(let existing) = rest["metadata"] {
            for (key, value) in existing {
                metadata[key] = value
            }
        }
        var copy = rest
        copy["metadata"] = .object(metadata)
        return copy
    }

    private static func providerContext(_ data: [String: JSONValue]) -> [String: JSONValue] {
        let context = data["providerContext"]
        let rest = omit(data, "providerContext")
        guard case .object(let contextDict) = context else { return rest }
        var native: [String: JSONValue] = [:]
        if let messagesValue = contextDict["messages"] {
            if case .array(let messagesArray) = messagesValue {
                native["messages"] = .array(messagesArray.map(media))
            } else {
                native["messages"] = messagesValue
            }
        }
        var copy = rest
        copy["native"] = .object(native)
        return copy
    }

    private static func media(_ message: JSONValue) -> JSONValue {
        guard case .object(let messageDict) = message,
              case .array(let contentArray) = messageDict["content"]
        else {
            return message
        }
        let upgraded = contentArray.map { item -> JSONValue in
            guard case .object(let partDict) = item,
                  partDict["type"] == .string("media"),
                  partDict["media"] == nil,
                  case .string(let dataString) = partDict["data"]
            else {
                return item
            }
            var source: [String: JSONValue] = [
                "type": .string("base64"),
                "data": .string(dataString),
            ]
            if let mediaType = partDict["mediaType"] {
                source["mediaType"] = mediaType
            }
            var rest = omit(omit(partDict, "mediaType"), "data")
            rest["media"] = .object(["source": .object(source)])
            return .object(rest)
        }
        var copy = messageDict
        copy["content"] = .array(upgraded)
        return .object(copy)
    }

    private static func omit(_ value: [String: JSONValue], _ key: String) -> [String: JSONValue] {
        guard value[key] != nil else { return value }
        var copy = value
        copy.removeValue(forKey: key)
        return copy
    }

    private static func toolResult(_ value: [String: JSONValue]) -> [String: JSONValue] {
        guard let providerResultState = value["providerResultState"] else { return value }
        var rest = omit(value, "providerResultState")
        guard case .object(let resultDict) = providerResultState else { return rest }
        var merged: [String: JSONValue] = [:]
        if case .object(let existingNative) = rest["native"] {
            merged = existingNative
        }
        for (key, val) in resultDict {
            merged[key] = val
        }
        rest["native"] = .object(merged)
        return rest
    }

    private static func rename(
        _ value: [String: JSONValue],
        from: String,
        to: String
    ) -> [String: JSONValue] {
        guard let moved = value[from] else { return value }
        var rest = omit(value, from)
        if rest[to] != nil {
            return rest
        }
        rest[to] = moved
        return rest
    }
}
