// MARK: - SessionEvent (`src/session-event.ts`)

/// Durable and ephemeral session event schemas (`packages/schema/src/session-event.ts`).
public enum SessionEventSchema {
    // MARK: Shared Payload Helpers

    /// Base payload carrying only `sessionID`.
    public struct SessionBaseData: Equatable, Hashable, Sendable, Codable {
        public let sessionID: SessionID

        public init(sessionID: SessionID) {
            self.sessionID = sessionID
        }
    }

    /// Base payload referencing a specific inbox item (`sessionID` + `inboxID`).
    public struct InboxRefData: Equatable, Hashable, Sendable, Codable {
        public let sessionID: SessionID
        public let inboxID: SessionMessageSchema.ID

        public init(sessionID: SessionID, inboxID: SessionMessageSchema.ID) {
            self.sessionID = sessionID
            self.inboxID = inboxID
        }
    }

    /// Base payload referencing a specific assistant step (`sessionID` + `assistantMessageID`).
    public struct StepRefData: Equatable, Hashable, Sendable, Codable {
        public let sessionID: SessionID
        public let assistantMessageID: SessionMessageSchema.ID

        public init(sessionID: SessionID, assistantMessageID: SessionMessageSchema.ID) {
            self.sessionID = sessionID
            self.assistantMessageID = assistantMessageID
        }
    }

    /// Source of an internal `session.usage.recorded` accounting event.
    public enum UsageSource: String, Equatable, Hashable, Sendable, Codable {
        case title
        case compaction
        case generate
    }

    /// Wire representation of an `Instruction.Delta` value (`<64-hex hash>` or `"removed"`).
    public enum InstructionDeltaValue: Equatable, Hashable, Sendable, Codable {
        case hash(String)
        case removed

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if raw == "removed" {
                self = .removed
                return
            }
            let bytes = Array(raw.utf8)
            guard bytes.count == 64,
                  bytes.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) })
            else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Instruction.Delta value must be 'removed' or a 64-character lowercase hex hash"
                )
            }
            self = .hash(raw)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .hash(let value):
                try container.encode(value)
            case .removed:
                try container.encode("removed")
            }
        }
    }

    /// Snapshot entry matching `InstructionEntry.Snapshot` element.
    public struct InstructionEntrySnapshotItem: Equatable, Hashable, Sendable, Codable {
        public let key: String
        public let value: JSONValue
        public let removed: Bool

        public init(key: String, value: JSONValue, removed: Bool) {
            self.key = key
            self.value = value
            self.removed = removed
        }
    }

    // MARK: Top-Level Session Event Data Structs

    public struct CreatedData: Equatable, Hashable, Sendable, Codable {
        public let sessionID: SessionID
        public let projectID: ProjectID
        public let location: OpenCodeLocation
        public let subpath: String?
        public let parentID: SessionID?
        public let slug: String
        public let title: String?
        public let agent: String?
        public let model: SessionSchema.ModelRef?
        public let metadata: SessionMetadataSchema.SessionMetadata?
        public let permissions: SessionSchema.PermissionRuleset?
        public let version: String

        public init(
            sessionID: SessionID,
            projectID: ProjectID,
            location: OpenCodeLocation,
            subpath: String? = nil,
            parentID: SessionID? = nil,
            slug: String,
            title: String? = nil,
            agent: String? = nil,
            model: SessionSchema.ModelRef? = nil,
            metadata: SessionMetadataSchema.SessionMetadata? = nil,
            permissions: SessionSchema.PermissionRuleset? = nil,
            version: String
        ) {
            self.sessionID = sessionID
            self.projectID = projectID
            self.location = location
            self.subpath = subpath
            self.parentID = parentID
            self.slug = slug
            self.title = title
            self.agent = agent
            self.model = model
            self.metadata = metadata
            self.permissions = permissions
            self.version = version
        }
    }

    public struct AgentSelectedData: Equatable, Hashable, Sendable, Codable {
        public let sessionID: SessionID
        public let agent: String
        public let previous: String?

        public init(sessionID: SessionID, agent: String, previous: String? = nil) {
            self.sessionID = sessionID
            self.agent = agent
            self.previous = previous
        }
    }

    public struct ModelSelectedData: Equatable, Hashable, Sendable, Codable {
        public let sessionID: SessionID
        public let model: SessionSchema.ModelRef
        public let previous: SessionSchema.ModelRef?

        public init(
            sessionID: SessionID,
            model: SessionSchema.ModelRef,
            previous: SessionSchema.ModelRef? = nil
        ) {
            self.sessionID = sessionID
            self.model = model
            self.previous = previous
        }
    }

    public struct MovedData: Equatable, Hashable, Sendable, Codable {
        public let sessionID: SessionID
        public let location: OpenCodeLocation
        public let projectID: ProjectID
        public let subpath: String?

        public init(
            sessionID: SessionID,
            location: OpenCodeLocation,
            projectID: ProjectID,
            subpath: String? = nil
        ) {
            self.sessionID = sessionID
            self.location = location
            self.projectID = projectID
            self.subpath = subpath
        }
    }

    public struct RenamedData: Equatable, Hashable, Sendable, Codable {
        public let sessionID: SessionID
        public let title: String

        public init(sessionID: SessionID, title: String) {
            self.sessionID = sessionID
            self.title = title
        }
    }

    public struct MetadataUpdatedData: Equatable, Hashable, Sendable, Codable {
        public let sessionID: SessionID
        public let metadata: SessionMetadataSchema.SessionMetadata

        public init(sessionID: SessionID, metadata: SessionMetadataSchema.SessionMetadata) {
            self.sessionID = sessionID
            self.metadata = metadata
        }
    }

    public struct PermissionsData: Equatable, Hashable, Sendable, Codable {
        public let sessionID: SessionID
        public let permissions: SessionSchema.PermissionRuleset

        public init(sessionID: SessionID, permissions: SessionSchema.PermissionRuleset) {
            self.sessionID = sessionID
            self.permissions = permissions
        }
    }

    public struct ViewedData: Equatable, Hashable, Sendable, Codable {
        public let sessionID: SessionID
        /// Epoch-millisecond idle watermark the viewer observed.
        public let idle: Int64

        public init(sessionID: SessionID, idle: Int64) {
            self.sessionID = sessionID
            self.idle = idle
        }
    }

    public struct MessageContentUpdatedData: Equatable, Hashable, Sendable, Codable {
        public let sessionID: SessionID
        public let messageID: SessionMessageSchema.ID
        public let content: [SessionMessageSchema.AssistantContentEncoded]

        public init(
            sessionID: SessionID,
            messageID: SessionMessageSchema.ID,
            content: [SessionMessageSchema.AssistantContentEncoded]
        ) {
            self.sessionID = sessionID
            self.messageID = messageID
            self.content = content
        }
    }

    public struct UsageRecordedData: Equatable, Hashable, Sendable, Codable {
        public let sessionID: SessionID
        public let source: UsageSource
        public let cost: Double
        public let tokens: SessionSchema.TokenUsage

        public init(
            sessionID: SessionID,
            source: UsageSource,
            cost: Double,
            tokens: SessionSchema.TokenUsage
        ) {
            self.sessionID = sessionID
            self.source = source
            self.cost = cost
            self.tokens = tokens
        }
    }

    public struct UsageUpdatedData: Equatable, Hashable, Sendable, Codable {
        public let sessionID: SessionID
        public let cost: Double
        public let tokens: SessionSchema.TokenUsage

        public init(sessionID: SessionID, cost: Double, tokens: SessionSchema.TokenUsage) {
            self.sessionID = sessionID
            self.cost = cost
            self.tokens = tokens
        }
    }

    public struct ForkedData: Equatable, Hashable, Sendable, Codable {
        public let sessionID: SessionID
        public let parentID: SessionID
        public let boundary: SessionForkSchema.Boundary
        public let instructions: [String: String]?
        public let instructionEntries: [InstructionEntrySnapshotItem]?

        public init(
            sessionID: SessionID,
            parentID: SessionID,
            boundary: SessionForkSchema.Boundary,
            instructions: [String: String]? = nil,
            instructionEntries: [InstructionEntrySnapshotItem]? = nil
        ) {
            self.sessionID = sessionID
            self.parentID = parentID
            self.boundary = boundary
            self.instructions = instructions
            self.instructionEntries = instructionEntries
        }
    }

    public struct InboxEnqueuedData: Equatable, Hashable, Sendable, Codable {
        public let sessionID: SessionID
        public let inboxID: SessionMessageSchema.ID
        public let item: SessionInboxSchema.Item

        public init(
            sessionID: SessionID,
            inboxID: SessionMessageSchema.ID,
            item: SessionInboxSchema.Item
        ) {
            self.sessionID = sessionID
            self.inboxID = inboxID
            self.item = item
        }
    }

    public struct InboxDeliveryChangedData: Equatable, Hashable, Sendable, Codable {
        public let sessionID: SessionID
        public let inboxID: SessionMessageSchema.ID
        public let delivery: SessionInboxSchema.Delivery

        public init(
            sessionID: SessionID,
            inboxID: SessionMessageSchema.ID,
            delivery: SessionInboxSchema.Delivery
        ) {
            self.sessionID = sessionID
            self.inboxID = inboxID
            self.delivery = delivery
        }
    }

    public struct InstructionsUpdatedData: Equatable, Hashable, Sendable, Codable {
        public let sessionID: SessionID
        public let delta: [String: InstructionDeltaValue]
        public let text: String?

        public init(
            sessionID: SessionID,
            delta: [String: InstructionDeltaValue],
            text: String? = nil
        ) {
            self.sessionID = sessionID
            self.delta = delta
            self.text = text
        }
    }

    public struct SyntheticData: Equatable, Hashable, Sendable, Codable {
        public let sessionID: SessionID
        public let text: String
        public let description: String?
        public let metadata: [String: JSONValue]?

        public init(
            sessionID: SessionID,
            text: String,
            description: String? = nil,
            metadata: [String: JSONValue]? = nil
        ) {
            self.sessionID = sessionID
            self.text = text
            self.description = description
            self.metadata = metadata
        }
    }

    public struct RetryScheduledData: Equatable, Hashable, Sendable, Codable {
        public let sessionID: SessionID
        public let assistantMessageID: SessionMessageSchema.ID
        public let attempt: Int
        public let at: Int64
        public let error: SessionErrorSchema.Error

        public init(
            sessionID: SessionID,
            assistantMessageID: SessionMessageSchema.ID,
            attempt: Int,
            at: Int64,
            error: SessionErrorSchema.Error
        ) {
            self.sessionID = sessionID
            self.assistantMessageID = assistantMessageID
            self.attempt = attempt
            self.at = at
            self.error = error
        }

        private enum CodingKeys: String, CodingKey {
            case sessionID
            case assistantMessageID
            case attempt
            case at
            case error
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.sessionID = try container.decode(SessionID.self, forKey: .sessionID)
            self.assistantMessageID = try container.decode(SessionMessageSchema.ID.self, forKey: .assistantMessageID)
            let attempt = try container.decode(Int.self, forKey: .attempt)
            guard attempt > 0 else {
                throw DecodingError.dataCorruptedError(forKey: .attempt, in: container, debugDescription: "attempt must be positive")
            }
            let at = try container.decode(Int64.self, forKey: .at)
            guard at >= 0 else {
                throw DecodingError.dataCorruptedError(forKey: .at, in: container, debugDescription: "at must be non-negative")
            }
            self.attempt = attempt
            self.at = at
            self.error = try container.decode(SessionErrorSchema.Error.self, forKey: .error)
        }
    }

    // MARK: Top-Level Event Definitions

    // parity: schema/src/session-event.ts#Created [status=implemented hash=5459599200d8]
    public static let Created = EventSchema.durable(
        type: "session.created",
        aggregate: "sessionID",
        version: 1,
        data: CreatedData.self
    )

    // parity: schema/src/session-event.ts#AgentSelected [status=implemented hash=443a0f7f7a3d]
    public static let AgentSelected = EventSchema.durable(
        type: "session.agent.selected",
        aggregate: "sessionID",
        version: 1,
        data: AgentSelectedData.self
    )

    // parity: schema/src/session-event.ts#ModelSelected [status=implemented hash=db35a0c911ed]
    public static let ModelSelected = EventSchema.durable(
        type: "session.model.selected",
        aggregate: "sessionID",
        version: 1,
        data: ModelSelectedData.self
    )

    // parity: schema/src/session-event.ts#Moved [status=implemented hash=c1dbed02bed9]
    public static let Moved = EventSchema.durable(
        type: "session.moved",
        aggregate: "sessionID",
        version: 1,
        data: MovedData.self
    )

    // parity: schema/src/session-event.ts#Renamed [status=implemented hash=13e8164ba9c7]
    public static let Renamed = EventSchema.durable(
        type: "session.renamed",
        aggregate: "sessionID",
        version: 1,
        data: RenamedData.self
    )

    // parity: schema/src/session-event.ts#MetadataUpdated [status=implemented hash=4527ceda4a29]
    public static let MetadataUpdated = EventSchema.durable(
        type: "session.metadata.updated",
        aggregate: "sessionID",
        version: 1,
        data: MetadataUpdatedData.self
    )

    // parity: schema/src/session-event.ts#Permissions [status=implemented hash=5311d6ce440b]
    public static let Permissions = EventSchema.durable(
        type: "session.permissions",
        aggregate: "sessionID",
        version: 1,
        data: PermissionsData.self
    )

    // parity: schema/src/session-event.ts#Viewed [status=implemented hash=d25c33062869]
    public static let Viewed = EventSchema.durable(
        type: "session.viewed",
        aggregate: "sessionID",
        version: 1,
        data: ViewedData.self
    )

    // parity: schema/src/session-event.ts#Archived [status=implemented hash=d5c36945da36]
    public static let Archived = EventSchema.durable(
        type: "session.archived",
        aggregate: "sessionID",
        version: 1,
        data: SessionBaseData.self
    )

    // parity: schema/src/session-event.ts#Unarchived [status=implemented hash=dba4c4f6111b]
    public static let Unarchived = EventSchema.durable(
        type: "session.unarchived",
        aggregate: "sessionID",
        version: 1,
        data: SessionBaseData.self
    )

    // Replay-only: older releases allowed replacing completed assistant content.
    // parity: schema/src/session-event.ts#MessageContentUpdated [status=implemented hash=536a0ab7c9eb]
    public static let MessageContentUpdated = EventSchema.durable(
        type: "session.message.content.updated",
        aggregate: "sessionID",
        version: 1,
        data: MessageContentUpdatedData.self
    )

    // Internal accounting event (excluded from public `Definitions`, included in `DurableDefinitions`).
    // parity: schema/src/session-event.ts#UsageRecorded [status=implemented hash=d9685fa5303e]
    public static let UsageRecorded = EventSchema.durable(
        type: "session.usage.recorded",
        aggregate: "sessionID",
        version: 1,
        data: UsageRecordedData.self
    )

    // parity: schema/src/session-event.ts#UsageUpdated [status=implemented hash=395be539173e]
    public static let UsageUpdated = EventSchema.ephemeral(
        type: "session.usage.updated",
        data: UsageUpdatedData.self
    )

    // parity: schema/src/session-event.ts#Deleted [status=implemented hash=eb96c00bd804]
    public static let Deleted = EventSchema.durable(
        type: "session.deleted",
        aggregate: "sessionID",
        version: 2,
        data: SessionBaseData.self
    )

    // parity: schema/src/session-event.ts#Forked [status=implemented hash=152f0895e832]
    public static let Forked = EventSchema.durable(
        type: "session.forked",
        aggregate: "sessionID",
        version: 2,
        data: ForkedData.self
    )

    // parity: schema/src/session-event.ts#InboxDelivered [status=implemented hash=7515ddc160fa]
    public static let InboxDelivered = EventSchema.durable(
        type: "session.inbox.delivered",
        aggregate: "sessionID",
        version: 1,
        data: InboxRefData.self
    )

    // parity: schema/src/session-event.ts#InboxEnqueued [status=implemented hash=8cd28ca3ffd4]
    public static let InboxEnqueued = EventSchema.durable(
        type: "session.inbox.enqueued",
        aggregate: "sessionID",
        version: 1,
        data: InboxEnqueuedData.self
    )

    // parity: schema/src/session-event.ts#InboxCancelled [status=implemented hash=bb1052486bea]
    public static let InboxCancelled = EventSchema.durable(
        type: "session.inbox.cancelled",
        aggregate: "sessionID",
        version: 1,
        data: InboxRefData.self
    )

    // parity: schema/src/session-event.ts#InboxDeliveryChanged [status=implemented hash=289b58663b90]
    public static let InboxDeliveryChanged = EventSchema.durable(
        type: "session.inbox.delivery.changed",
        aggregate: "sessionID",
        version: 1,
        data: InboxDeliveryChangedData.self
    )

    // MARK: Execution Namespace

    // parity: schema/src/session-event.ts#Execution [status=implemented hash=02ee9a71db7e]
    public enum Execution {
        public enum InterruptReason: String, Equatable, Hashable, Sendable, Codable {
            case user
            case shutdown
            case superseded
            case inactivity
        }

        public struct FailedData: Equatable, Hashable, Sendable, Codable {
            public let sessionID: SessionID
            public let error: SessionErrorSchema.Error

            public init(sessionID: SessionID, error: SessionErrorSchema.Error) {
                self.sessionID = sessionID
                self.error = error
            }
        }

        public struct InterruptedData: Equatable, Hashable, Sendable, Codable {
            public let sessionID: SessionID
            public let reason: InterruptReason

            public init(sessionID: SessionID, reason: InterruptReason) {
                self.sessionID = sessionID
                self.reason = reason
            }
        }

        // parity: schema/src/session-event.ts#Execution.Started [status=implemented hash=e9ab33770df0]
        public static let Started = EventSchema.durable(
            type: "session.execution.started",
            aggregate: "sessionID",
            version: 1,
            data: SessionBaseData.self
        )

        // parity: schema/src/session-event.ts#Execution.Succeeded [status=implemented hash=fe7dad4ac782]
        public static let Succeeded = EventSchema.durable(
            type: "session.execution.succeeded",
            aggregate: "sessionID",
            version: 1,
            data: SessionBaseData.self
        )

        // parity: schema/src/session-event.ts#Execution.Failed [status=implemented hash=55b176298eef]
        public static let Failed = EventSchema.durable(
            type: "session.execution.failed",
            aggregate: "sessionID",
            version: 1,
            data: FailedData.self
        )

        // parity: schema/src/session-event.ts#Execution.Interrupted [status=implemented hash=db3a055d03ed]
        public static let Interrupted = EventSchema.durable(
            type: "session.execution.interrupted",
            aggregate: "sessionID",
            version: 1,
            data: InterruptedData.self
        )
    }

    // parity: schema/src/session-event.ts#InstructionsUpdated [status=implemented hash=8751bc32d838]
    public static let InstructionsUpdated = EventSchema.durable(
        type: "session.instructions.updated",
        aggregate: "sessionID",
        version: 2,
        data: InstructionsUpdatedData.self
    )

    // parity: schema/src/session-event.ts#Synthetic [status=implemented hash=27ff43a25284]
    public static let Synthetic = EventSchema.durable(
        type: "session.synthetic",
        aggregate: "sessionID",
        version: 1,
        data: SyntheticData.self
    )

    // MARK: Skill Namespace

    // parity: schema/src/session-event.ts#Skill [status=implemented hash=2aea0c4a9dc2]
    public enum Skill {
        public struct ActivatedData: Equatable, Hashable, Sendable, Codable {
            public let sessionID: SessionID
            public let id: String
            public let name: String
            public let text: String

            public init(sessionID: SessionID, id: String, name: String, text: String) {
                self.sessionID = sessionID
                self.id = id
                self.name = name
                self.text = text
            }
        }

        // parity: schema/src/session-event.ts#Skill.Activated [status=implemented hash=f3e46b309fd9]
        public static let Activated = EventSchema.durable(
            type: "session.skill.activated",
            aggregate: "sessionID",
            version: 1,
            data: ActivatedData.self
        )
    }

    // MARK: Shell Namespace

    // parity: schema/src/session-event.ts#Shell [status=implemented hash=5c2643944cb9]
    public enum Shell {
        public struct StartedData: Equatable, Hashable, Sendable, Codable {
            public let sessionID: SessionID
            public let shell: SessionMessageSchema.ShellInfo

            public init(sessionID: SessionID, shell: SessionMessageSchema.ShellInfo) {
                self.sessionID = sessionID
                self.shell = shell
            }
        }

        public struct EndedData: Equatable, Hashable, Sendable, Codable {
            public let sessionID: SessionID
            public let shell: SessionMessageSchema.ShellInfo
            public let output: SessionMessageSchema.ShellOutput

            public init(
                sessionID: SessionID,
                shell: SessionMessageSchema.ShellInfo,
                output: SessionMessageSchema.ShellOutput
            ) {
                self.sessionID = sessionID
                self.shell = shell
                self.output = output
            }
        }

        // parity: schema/src/session-event.ts#Shell.Started [status=implemented hash=38509e7df2f3]
        public static let Started = EventSchema.durable(
            type: "session.shell.started",
            aggregate: "sessionID",
            version: 1,
            data: StartedData.self
        )

        // parity: schema/src/session-event.ts#Shell.Ended [status=implemented hash=90fec1e069f6]
        public static let Ended = EventSchema.durable(
            type: "session.shell.ended",
            aggregate: "sessionID",
            version: 1,
            data: EndedData.self
        )
    }

    // MARK: Step Namespace

    // parity: schema/src/session-event.ts#Step [status=implemented hash=958807cd404a]
    public enum Step {
        public enum FailedFinish: String, Equatable, Hashable, Sendable, Codable {
            case contentFilter = "content-filter"
        }

        public struct StartedData: Equatable, Hashable, Sendable, Codable {
            public let sessionID: SessionID
            public let assistantMessageID: SessionMessageSchema.ID
            public let agent: String
            public let model: SessionSchema.ModelRef
            public let snapshot: String?
            /// Request dispatch time (non-negative epoch millis).
            public let started: Int64

            public init(
                sessionID: SessionID,
                assistantMessageID: SessionMessageSchema.ID,
                agent: String,
                model: SessionSchema.ModelRef,
                snapshot: String? = nil,
                started: Int64
            ) {
                self.sessionID = sessionID
                self.assistantMessageID = assistantMessageID
                self.agent = agent
                self.model = model
                self.snapshot = snapshot
                self.started = started
            }

            private enum CodingKeys: String, CodingKey {
                case sessionID
                case assistantMessageID
                case agent
                case model
                case snapshot
                case started
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.sessionID = try container.decode(SessionID.self, forKey: .sessionID)
                self.assistantMessageID = try container.decode(SessionMessageSchema.ID.self, forKey: .assistantMessageID)
                self.agent = try container.decode(String.self, forKey: .agent)
                self.model = try container.decode(SessionSchema.ModelRef.self, forKey: .model)
                self.snapshot = try container.decodeIfPresent(String.self, forKey: .snapshot)
                let started = try container.decode(Int64.self, forKey: .started)
                guard started >= 0 else {
                    throw DecodingError.dataCorruptedError(forKey: .started, in: container, debugDescription: "started must be non-negative")
                }
                self.started = started
            }
        }

        public struct EndedData: Equatable, Hashable, Sendable, Codable {
            public let sessionID: SessionID
            public let assistantMessageID: SessionMessageSchema.ID
            public let finish: SessionMessageSchema.FinishReason
            public let rawFinish: String?
            public let native: SessionMessageSchema.Native?
            public let cost: Double
            public let tokens: SessionSchema.TokenUsage
            public let snapshot: String?
            public let files: [String]?

            public init(
                sessionID: SessionID,
                assistantMessageID: SessionMessageSchema.ID,
                finish: SessionMessageSchema.FinishReason,
                rawFinish: String? = nil,
                native: SessionMessageSchema.Native? = nil,
                cost: Double,
                tokens: SessionSchema.TokenUsage,
                snapshot: String? = nil,
                files: [String]? = nil
            ) {
                self.sessionID = sessionID
                self.assistantMessageID = assistantMessageID
                self.finish = finish
                self.rawFinish = rawFinish
                self.native = native
                self.cost = cost
                self.tokens = tokens
                self.snapshot = snapshot
                self.files = files
            }
        }

        public struct FailedData: Equatable, Hashable, Sendable, Codable {
            public let sessionID: SessionID
            public let assistantMessageID: SessionMessageSchema.ID
            public let error: SessionErrorSchema.Error
            public let finish: FailedFinish?
            public let rawFinish: String?
            public let native: SessionMessageSchema.Native?
            public let cost: Double?
            public let tokens: SessionSchema.TokenUsage?
            public let snapshot: String?
            public let files: [String]?

            public init(
                sessionID: SessionID,
                assistantMessageID: SessionMessageSchema.ID,
                error: SessionErrorSchema.Error,
                finish: FailedFinish? = nil,
                rawFinish: String? = nil,
                native: SessionMessageSchema.Native? = nil,
                cost: Double? = nil,
                tokens: SessionSchema.TokenUsage? = nil,
                snapshot: String? = nil,
                files: [String]? = nil
            ) {
                self.sessionID = sessionID
                self.assistantMessageID = assistantMessageID
                self.error = error
                self.finish = finish
                self.rawFinish = rawFinish
                self.native = native
                self.cost = cost
                self.tokens = tokens
                self.snapshot = snapshot
                self.files = files
            }
        }

        // parity: schema/src/session-event.ts#Step.Started [status=implemented hash=df6edf6ca6a8]
        public static let Started = EventSchema.durable(
            type: "session.step.started",
            aggregate: "sessionID",
            version: 1,
            data: StartedData.self
        )

        // parity: schema/src/session-event.ts#Step.FirstToken [status=implemented hash=8a3acefa80a2]
        public static let FirstToken = EventSchema.durable(
            type: "session.step.first-token",
            aggregate: "sessionID",
            version: 1,
            data: StepRefData.self
        )

        // parity: schema/src/session-event.ts#Step.Streamed [status=implemented hash=fc8ba6d0b7b5]
        public static let Streamed = EventSchema.durable(
            type: "session.step.streamed",
            aggregate: "sessionID",
            version: 1,
            data: StepRefData.self
        )

        // parity: schema/src/session-event.ts#Step.Ended [status=implemented hash=589ded696cd1]
        public static let Ended = EventSchema.durable(
            type: "session.step.ended",
            aggregate: "sessionID",
            version: 1,
            data: EndedData.self
        )

        // parity: schema/src/session-event.ts#Step.Failed [status=implemented hash=9482d7b17a8b]
        public static let Failed = EventSchema.durable(
            type: "session.step.failed",
            aggregate: "sessionID",
            version: 1,
            data: FailedData.self
        )
    }

    // MARK: Text Namespace

    // parity: schema/src/session-event.ts#Text [status=implemented hash=070ddfb4a812]
    public enum Text {
        public struct StartedData: Equatable, Hashable, Sendable, Codable {
            public let sessionID: SessionID
            public let assistantMessageID: SessionMessageSchema.ID
            public let ordinal: Int

            public init(sessionID: SessionID, assistantMessageID: SessionMessageSchema.ID, ordinal: Int) {
                self.sessionID = sessionID
                self.assistantMessageID = assistantMessageID
                self.ordinal = ordinal
            }

            private enum CodingKeys: String, CodingKey {
                case sessionID
                case assistantMessageID
                case ordinal
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.sessionID = try container.decode(SessionID.self, forKey: .sessionID)
                self.assistantMessageID = try container.decode(SessionMessageSchema.ID.self, forKey: .assistantMessageID)
                let ordinal = try container.decode(Int.self, forKey: .ordinal)
                guard ordinal >= 0 else {
                    throw DecodingError.dataCorruptedError(forKey: .ordinal, in: container, debugDescription: "ordinal must be non-negative")
                }
                self.ordinal = ordinal
            }
        }

        public struct DeltaData: Equatable, Hashable, Sendable, Codable {
            public let sessionID: SessionID
            public let assistantMessageID: SessionMessageSchema.ID
            public let ordinal: Int
            public let delta: String

            public init(
                sessionID: SessionID,
                assistantMessageID: SessionMessageSchema.ID,
                ordinal: Int,
                delta: String
            ) {
                self.sessionID = sessionID
                self.assistantMessageID = assistantMessageID
                self.ordinal = ordinal
                self.delta = delta
            }

            private enum CodingKeys: String, CodingKey {
                case sessionID
                case assistantMessageID
                case ordinal
                case delta
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.sessionID = try container.decode(SessionID.self, forKey: .sessionID)
                self.assistantMessageID = try container.decode(SessionMessageSchema.ID.self, forKey: .assistantMessageID)
                let ordinal = try container.decode(Int.self, forKey: .ordinal)
                guard ordinal >= 0 else {
                    throw DecodingError.dataCorruptedError(forKey: .ordinal, in: container, debugDescription: "ordinal must be non-negative")
                }
                self.ordinal = ordinal
                self.delta = try container.decode(String.self, forKey: .delta)
            }
        }

        public struct EndedData: Equatable, Hashable, Sendable, Codable {
            public let sessionID: SessionID
            public let assistantMessageID: SessionMessageSchema.ID
            public let ordinal: Int
            public let text: String
            public let native: SessionMessageSchema.Native?

            public init(
                sessionID: SessionID,
                assistantMessageID: SessionMessageSchema.ID,
                ordinal: Int,
                text: String,
                native: SessionMessageSchema.Native? = nil
            ) {
                self.sessionID = sessionID
                self.assistantMessageID = assistantMessageID
                self.ordinal = ordinal
                self.text = text
                self.native = native
            }

            private enum CodingKeys: String, CodingKey {
                case sessionID
                case assistantMessageID
                case ordinal
                case text
                case native
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.sessionID = try container.decode(SessionID.self, forKey: .sessionID)
                self.assistantMessageID = try container.decode(SessionMessageSchema.ID.self, forKey: .assistantMessageID)
                let ordinal = try container.decode(Int.self, forKey: .ordinal)
                guard ordinal >= 0 else {
                    throw DecodingError.dataCorruptedError(forKey: .ordinal, in: container, debugDescription: "ordinal must be non-negative")
                }
                self.ordinal = ordinal
                self.text = try container.decode(String.self, forKey: .text)
                self.native = try container.decodeIfPresent(SessionMessageSchema.Native.self, forKey: .native)
            }
        }

        // parity: schema/src/session-event.ts#Text.Started [status=implemented hash=69c87532d25a]
        public static let Started = EventSchema.durable(
            type: "session.text.started",
            aggregate: "sessionID",
            version: 1,
            data: StartedData.self
        )

        // parity: schema/src/session-event.ts#Text.Delta [status=implemented hash=9842018daf41]
        public static let Delta = EventSchema.ephemeral(
            type: "session.text.delta",
            data: DeltaData.self
        )

        // parity: schema/src/session-event.ts#Text.Ended [status=implemented hash=692cb9a9ea58]
        public static let Ended = EventSchema.durable(
            type: "session.text.ended",
            aggregate: "sessionID",
            version: 1,
            data: EndedData.self
        )
    }

    // MARK: Reasoning Namespace

    // parity: schema/src/session-event.ts#Reasoning [status=implemented hash=3686dff21da3]
    public enum Reasoning {
        public struct StartedData: Equatable, Hashable, Sendable, Codable {
            public let sessionID: SessionID
            public let assistantMessageID: SessionMessageSchema.ID
            public let ordinal: Int
            public let native: SessionMessageSchema.Native?

            public init(
                sessionID: SessionID,
                assistantMessageID: SessionMessageSchema.ID,
                ordinal: Int,
                native: SessionMessageSchema.Native? = nil
            ) {
                self.sessionID = sessionID
                self.assistantMessageID = assistantMessageID
                self.ordinal = ordinal
                self.native = native
            }

            private enum CodingKeys: String, CodingKey {
                case sessionID
                case assistantMessageID
                case ordinal
                case native
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.sessionID = try container.decode(SessionID.self, forKey: .sessionID)
                self.assistantMessageID = try container.decode(SessionMessageSchema.ID.self, forKey: .assistantMessageID)
                let ordinal = try container.decode(Int.self, forKey: .ordinal)
                guard ordinal >= 0 else {
                    throw DecodingError.dataCorruptedError(forKey: .ordinal, in: container, debugDescription: "ordinal must be non-negative")
                }
                self.ordinal = ordinal
                self.native = try container.decodeIfPresent(SessionMessageSchema.Native.self, forKey: .native)
            }
        }

        public struct DeltaData: Equatable, Hashable, Sendable, Codable {
            public let sessionID: SessionID
            public let assistantMessageID: SessionMessageSchema.ID
            public let ordinal: Int
            public let delta: String

            public init(
                sessionID: SessionID,
                assistantMessageID: SessionMessageSchema.ID,
                ordinal: Int,
                delta: String
            ) {
                self.sessionID = sessionID
                self.assistantMessageID = assistantMessageID
                self.ordinal = ordinal
                self.delta = delta
            }

            private enum CodingKeys: String, CodingKey {
                case sessionID
                case assistantMessageID
                case ordinal
                case delta
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.sessionID = try container.decode(SessionID.self, forKey: .sessionID)
                self.assistantMessageID = try container.decode(SessionMessageSchema.ID.self, forKey: .assistantMessageID)
                let ordinal = try container.decode(Int.self, forKey: .ordinal)
                guard ordinal >= 0 else {
                    throw DecodingError.dataCorruptedError(forKey: .ordinal, in: container, debugDescription: "ordinal must be non-negative")
                }
                self.ordinal = ordinal
                self.delta = try container.decode(String.self, forKey: .delta)
            }
        }

        public struct EndedData: Equatable, Hashable, Sendable, Codable {
            public let sessionID: SessionID
            public let assistantMessageID: SessionMessageSchema.ID
            public let ordinal: Int
            public let text: String
            public let native: SessionMessageSchema.Native?

            public init(
                sessionID: SessionID,
                assistantMessageID: SessionMessageSchema.ID,
                ordinal: Int,
                text: String,
                native: SessionMessageSchema.Native? = nil
            ) {
                self.sessionID = sessionID
                self.assistantMessageID = assistantMessageID
                self.ordinal = ordinal
                self.text = text
                self.native = native
            }

            private enum CodingKeys: String, CodingKey {
                case sessionID
                case assistantMessageID
                case ordinal
                case text
                case native
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.sessionID = try container.decode(SessionID.self, forKey: .sessionID)
                self.assistantMessageID = try container.decode(SessionMessageSchema.ID.self, forKey: .assistantMessageID)
                let ordinal = try container.decode(Int.self, forKey: .ordinal)
                guard ordinal >= 0 else {
                    throw DecodingError.dataCorruptedError(forKey: .ordinal, in: container, debugDescription: "ordinal must be non-negative")
                }
                self.ordinal = ordinal
                self.text = try container.decode(String.self, forKey: .text)
                self.native = try container.decodeIfPresent(SessionMessageSchema.Native.self, forKey: .native)
            }
        }

        // parity: schema/src/session-event.ts#Reasoning.Started [status=implemented hash=8fc7da3c9e59]
        public static let Started = EventSchema.durable(
            type: "session.reasoning.started",
            aggregate: "sessionID",
            version: 1,
            data: StartedData.self
        )

        // parity: schema/src/session-event.ts#Reasoning.Delta [status=implemented hash=3ee8958767ad]
        public static let Delta = EventSchema.ephemeral(
            type: "session.reasoning.delta",
            data: DeltaData.self
        )

        // parity: schema/src/session-event.ts#Reasoning.Ended [status=implemented hash=2639ace59b82]
        public static let Ended = EventSchema.durable(
            type: "session.reasoning.ended",
            aggregate: "sessionID",
            version: 1,
            data: EndedData.self
        )
    }

    // MARK: Tool Namespace

    // parity: schema/src/session-event.ts#Tool [status=implemented hash=16f59f2f1499]
    public enum Tool {
        // parity: schema/src/session-event.ts#Tool.Input [status=implemented hash=79671cd89e5e]
        public enum Input {
            public struct StartedData: Equatable, Hashable, Sendable, Codable {
                public let sessionID: SessionID
                public let assistantMessageID: SessionMessageSchema.ID
                public let id: String
                public let name: String

                public init(
                    sessionID: SessionID,
                    assistantMessageID: SessionMessageSchema.ID,
                    id: String,
                    name: String
                ) {
                    self.sessionID = sessionID
                    self.assistantMessageID = assistantMessageID
                    self.id = id
                    self.name = name
                }
            }

            public struct DeltaData: Equatable, Hashable, Sendable, Codable {
                public let sessionID: SessionID
                public let assistantMessageID: SessionMessageSchema.ID
                public let id: String
                public let delta: String

                public init(
                    sessionID: SessionID,
                    assistantMessageID: SessionMessageSchema.ID,
                    id: String,
                    delta: String
                ) {
                    self.sessionID = sessionID
                    self.assistantMessageID = assistantMessageID
                    self.id = id
                    self.delta = delta
                }
            }

            public struct EndedData: Equatable, Hashable, Sendable, Codable {
                public let sessionID: SessionID
                public let assistantMessageID: SessionMessageSchema.ID
                public let id: String
                public let text: String

                public init(
                    sessionID: SessionID,
                    assistantMessageID: SessionMessageSchema.ID,
                    id: String,
                    text: String
                ) {
                    self.sessionID = sessionID
                    self.assistantMessageID = assistantMessageID
                    self.id = id
                    self.text = text
                }
            }

            // parity: schema/src/session-event.ts#Tool.Input.Started [status=implemented hash=aaccce5ac51e]
            public static let Started = EventSchema.durable(
                type: "session.tool.input.started",
                aggregate: "sessionID",
                version: 1,
                data: StartedData.self
            )

            // parity: schema/src/session-event.ts#Tool.Input.Delta [status=implemented hash=316510f04fb3]
            public static let Delta = EventSchema.ephemeral(
                type: "session.tool.input.delta",
                data: DeltaData.self
            )

            // parity: schema/src/session-event.ts#Tool.Input.Ended [status=implemented hash=be79c0e3d39b]
            public static let Ended = EventSchema.durable(
                type: "session.tool.input.ended",
                aggregate: "sessionID",
                version: 1,
                data: EndedData.self
            )
        }

        public struct CalledData: Equatable, Hashable, Sendable, Codable {
            public let sessionID: SessionID
            public let assistantMessageID: SessionMessageSchema.ID
            public let id: String
            public let input: [String: JSONValue]
            public let executed: Bool
            public let native: SessionMessageSchema.Native?

            public init(
                sessionID: SessionID,
                assistantMessageID: SessionMessageSchema.ID,
                id: String,
                input: [String: JSONValue],
                executed: Bool,
                native: SessionMessageSchema.Native? = nil
            ) {
                self.sessionID = sessionID
                self.assistantMessageID = assistantMessageID
                self.id = id
                self.input = input
                self.executed = executed
                self.native = native
            }
        }

        public struct ProgressData: Equatable, Hashable, Sendable, Codable {
            public let sessionID: SessionID
            public let assistantMessageID: SessionMessageSchema.ID
            public let id: String
            public let metadata: [String: JSONValue]

            public init(
                sessionID: SessionID,
                assistantMessageID: SessionMessageSchema.ID,
                id: String,
                metadata: [String: JSONValue]
            ) {
                self.sessionID = sessionID
                self.assistantMessageID = assistantMessageID
                self.id = id
                self.metadata = metadata
            }
        }

        public struct SuccessData: Equatable, Hashable, Sendable, Codable {
            public let sessionID: SessionID
            public let assistantMessageID: SessionMessageSchema.ID
            public let id: String
            public let content: [SessionMessageSchema.ToolContent]
            public let metadata: [String: JSONValue]?
            public let executed: Bool
            public let native: SessionMessageSchema.Native?

            public init(
                sessionID: SessionID,
                assistantMessageID: SessionMessageSchema.ID,
                id: String,
                content: [SessionMessageSchema.ToolContent],
                metadata: [String: JSONValue]? = nil,
                executed: Bool,
                native: SessionMessageSchema.Native? = nil
            ) {
                self.sessionID = sessionID
                self.assistantMessageID = assistantMessageID
                self.id = id
                self.content = content
                self.metadata = metadata
                self.executed = executed
                self.native = native
            }

            private enum CodingKeys: String, CodingKey {
                case sessionID
                case assistantMessageID
                case id
                case content
                case metadata
                case executed
                case native
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.sessionID = try container.decode(SessionID.self, forKey: .sessionID)
                self.assistantMessageID = try container.decode(SessionMessageSchema.ID.self, forKey: .assistantMessageID)
                self.id = try container.decode(String.self, forKey: .id)
                let content = try container.decode([SessionMessageSchema.ToolContent].self, forKey: .content)
                guard !content.isEmpty else {
                    throw DecodingError.dataCorruptedError(forKey: .content, in: container, debugDescription: "Tool.Success.content must be non-empty")
                }
                self.content = content
                self.metadata = try container.decodeIfPresent([String: JSONValue].self, forKey: .metadata)
                self.executed = try container.decode(Bool.self, forKey: .executed)
                self.native = try container.decodeIfPresent(SessionMessageSchema.Native.self, forKey: .native)
            }
        }

        public struct FailedData: Equatable, Hashable, Sendable, Codable {
            public let sessionID: SessionID
            public let assistantMessageID: SessionMessageSchema.ID
            public let id: String
            public let error: SessionErrorSchema.Error
            public let content: [SessionMessageSchema.ToolContent]?
            public let metadata: [String: JSONValue]?
            public let executed: Bool
            public let native: SessionMessageSchema.Native?

            public init(
                sessionID: SessionID,
                assistantMessageID: SessionMessageSchema.ID,
                id: String,
                error: SessionErrorSchema.Error,
                content: [SessionMessageSchema.ToolContent]? = nil,
                metadata: [String: JSONValue]? = nil,
                executed: Bool,
                native: SessionMessageSchema.Native? = nil
            ) {
                self.sessionID = sessionID
                self.assistantMessageID = assistantMessageID
                self.id = id
                self.error = error
                self.content = content
                self.metadata = metadata
                self.executed = executed
                self.native = native
            }

            private enum CodingKeys: String, CodingKey {
                case sessionID
                case assistantMessageID
                case id
                case error
                case content
                case metadata
                case executed
                case native
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.sessionID = try container.decode(SessionID.self, forKey: .sessionID)
                self.assistantMessageID = try container.decode(SessionMessageSchema.ID.self, forKey: .assistantMessageID)
                self.id = try container.decode(String.self, forKey: .id)
                self.error = try container.decode(SessionErrorSchema.Error.self, forKey: .error)
                let content = try container.decodeIfPresent([SessionMessageSchema.ToolContent].self, forKey: .content)
                if let content, content.isEmpty {
                    throw DecodingError.dataCorruptedError(forKey: .content, in: container, debugDescription: "Tool.Failed.content must be non-empty when present")
                }
                self.content = content
                self.metadata = try container.decodeIfPresent([String: JSONValue].self, forKey: .metadata)
                self.executed = try container.decode(Bool.self, forKey: .executed)
                self.native = try container.decodeIfPresent(SessionMessageSchema.Native.self, forKey: .native)
            }
        }

        // parity: schema/src/session-event.ts#Tool.Called [status=implemented hash=b530d3ab40e1]
        public static let Called = EventSchema.durable(
            type: "session.tool.called",
            aggregate: "sessionID",
            version: 1,
            data: CalledData.self
        )

        // parity: schema/src/session-event.ts#Tool.Progress [status=implemented hash=4061f2b162fb]
        public static let Progress = EventSchema.ephemeral(
            type: "session.tool.progress",
            data: ProgressData.self
        )

        // parity: schema/src/session-event.ts#Tool.Success [status=implemented hash=b1fa81fbb910]
        public static let Success = EventSchema.durable(
            type: "session.tool.success",
            aggregate: "sessionID",
            version: 2,
            data: SuccessData.self
        )

        // parity: schema/src/session-event.ts#Tool.Failed [status=implemented hash=33d1e0b2b0e7]
        public static let Failed = EventSchema.durable(
            type: "session.tool.failed",
            aggregate: "sessionID",
            version: 2,
            data: FailedData.self
        )
    }

    // parity: schema/src/session-event.ts#RetryScheduled [status=implemented hash=69d2c35dfb93]
    public static let RetryScheduled = EventSchema.durable(
        type: "session.retry.scheduled",
        aggregate: "sessionID",
        version: 1,
        data: RetryScheduledData.self
    )

    // MARK: Compaction Namespace

    // parity: schema/src/session-event.ts#Compaction [status=implemented hash=0613ae237eaa]
    public enum Compaction {
        public struct StartedData: Equatable, Hashable, Sendable, Codable {
            public let sessionID: SessionID
            public let reason: SessionMessageSchema.CompactionReason
            public let inputID: SessionMessageSchema.ID?

            public init(
                sessionID: SessionID,
                reason: SessionMessageSchema.CompactionReason,
                inputID: SessionMessageSchema.ID? = nil
            ) {
                self.sessionID = sessionID
                self.reason = reason
                self.inputID = inputID
            }
        }

        public struct DeltaData: Equatable, Hashable, Sendable, Codable {
            public let sessionID: SessionID
            public let text: String

            public init(sessionID: SessionID, text: String) {
                self.sessionID = sessionID
                self.text = text
            }
        }

        public struct EndedData: Equatable, Hashable, Sendable, Codable {
            public let sessionID: SessionID
            public let reason: SessionMessageSchema.CompactionReason
            public let model: SessionSchema.ModelRef?
            public let native: SessionMessageSchema.Native?
            public let text: String
            public let cost: Double?
            public let tokens: SessionSchema.TokenUsage?

            public init(
                sessionID: SessionID,
                reason: SessionMessageSchema.CompactionReason,
                model: SessionSchema.ModelRef? = nil,
                native: SessionMessageSchema.Native? = nil,
                text: String,
                cost: Double? = nil,
                tokens: SessionSchema.TokenUsage? = nil
            ) {
                self.sessionID = sessionID
                self.reason = reason
                self.model = model
                self.native = native
                self.text = text
                self.cost = cost
                self.tokens = tokens
            }
        }

        public struct FailedData: Equatable, Hashable, Sendable, Codable {
            public let sessionID: SessionID
            public let reason: SessionMessageSchema.CompactionReason
            public let error: SessionErrorSchema.Error
            public let inputID: SessionMessageSchema.ID?
            public let cost: Double?
            public let tokens: SessionSchema.TokenUsage?

            public init(
                sessionID: SessionID,
                reason: SessionMessageSchema.CompactionReason,
                error: SessionErrorSchema.Error,
                inputID: SessionMessageSchema.ID? = nil,
                cost: Double? = nil,
                tokens: SessionSchema.TokenUsage? = nil
            ) {
                self.sessionID = sessionID
                self.reason = reason
                self.error = error
                self.inputID = inputID
                self.cost = cost
                self.tokens = tokens
            }
        }

        // parity: schema/src/session-event.ts#Compaction.Started [status=implemented hash=4f21829cf565]
        public static let Started = EventSchema.durable(
            type: "session.compaction.started",
            aggregate: "sessionID",
            version: 1,
            data: StartedData.self
        )

        // parity: schema/src/session-event.ts#Compaction.Delta [status=implemented hash=03ad4bfe233e]
        public static let Delta = EventSchema.ephemeral(
            type: "session.compaction.delta",
            data: DeltaData.self
        )

        // parity: schema/src/session-event.ts#Compaction.Ended [status=implemented hash=91b2282d02ab]
        public static let Ended = EventSchema.durable(
            type: "session.compaction.ended",
            aggregate: "sessionID",
            version: 1,
            data: EndedData.self
        )

        // parity: schema/src/session-event.ts#Compaction.Failed [status=implemented hash=527a5c5a83da]
        public static let Failed = EventSchema.durable(
            type: "session.compaction.failed",
            aggregate: "sessionID",
            version: 1,
            data: FailedData.self
        )
    }

    // MARK: RevertEvent Namespace

    // parity: schema/src/session-event.ts#RevertEvent [status=implemented hash=af3d8ede9697]
    public enum RevertEvent {
        public struct StagedData: Equatable, Hashable, Sendable, Codable {
            public let sessionID: SessionID
            public let revert: SessionRevertSchema.Revert

            public init(sessionID: SessionID, revert: SessionRevertSchema.Revert) {
                self.sessionID = sessionID
                self.revert = revert
            }
        }

        public struct CommittedData: Equatable, Hashable, Sendable, Codable {
            public let sessionID: SessionID
            public let to: SessionMessageSchema.ID

            public init(sessionID: SessionID, to: SessionMessageSchema.ID) {
                self.sessionID = sessionID
                self.to = to
            }
        }

        // parity: schema/src/session-event.ts#RevertEvent.Staged [status=implemented hash=77e87a1576ad]
        public static let Staged = EventSchema.durable(
            type: "session.revert.staged",
            aggregate: "sessionID",
            version: 1,
            data: StagedData.self
        )

        // parity: schema/src/session-event.ts#RevertEvent.Cleared [status=implemented hash=a3c352c9adf9]
        public static let Cleared = EventSchema.durable(
            type: "session.revert.cleared",
            aggregate: "sessionID",
            version: 1,
            data: SessionBaseData.self
        )

        // parity: schema/src/session-event.ts#RevertEvent.Committed [status=implemented hash=9e231213a012]
        public static let Committed = EventSchema.durable(
            type: "session.revert.committed",
            aggregate: "sessionID",
            version: 1,
            data: CommittedData.self
        )
    }

    // MARK: Inventories & Unions

    /// All 52 public session event definitions (excluding internal `UsageRecorded` and replay-only `MessageContentUpdated`).
    // parity: schema/src/session-event.ts#Definitions [status=implemented hash=92c4700e0adb]
    public static let Definitions: [EventSchema.Definition] = EventSchema.inventory(
        Created.descriptor,
        AgentSelected.descriptor,
        ModelSelected.descriptor,
        Moved.descriptor,
        Renamed.descriptor,
        MetadataUpdated.descriptor,
        Permissions.descriptor,
        Viewed.descriptor,
        Archived.descriptor,
        Unarchived.descriptor,
        UsageUpdated.descriptor,
        Deleted.descriptor,
        Forked.descriptor,
        InboxDelivered.descriptor,
        InboxEnqueued.descriptor,
        InboxCancelled.descriptor,
        InboxDeliveryChanged.descriptor,
        Execution.Started.descriptor,
        Execution.Succeeded.descriptor,
        Execution.Failed.descriptor,
        Execution.Interrupted.descriptor,
        InstructionsUpdated.descriptor,
        Synthetic.descriptor,
        Skill.Activated.descriptor,
        Shell.Started.descriptor,
        Shell.Ended.descriptor,
        Step.Started.descriptor,
        Step.FirstToken.descriptor,
        Step.Streamed.descriptor,
        Step.Ended.descriptor,
        Step.Failed.descriptor,
        Text.Started.descriptor,
        Text.Delta.descriptor,
        Text.Ended.descriptor,
        Reasoning.Started.descriptor,
        Reasoning.Delta.descriptor,
        Reasoning.Ended.descriptor,
        Tool.Input.Started.descriptor,
        Tool.Input.Delta.descriptor,
        Tool.Input.Ended.descriptor,
        Tool.Called.descriptor,
        Tool.Progress.descriptor,
        Tool.Success.descriptor,
        Tool.Failed.descriptor,
        RetryScheduled.descriptor,
        Compaction.Started.descriptor,
        Compaction.Delta.descriptor,
        Compaction.Ended.descriptor,
        Compaction.Failed.descriptor,
        RevertEvent.Staged.descriptor,
        RevertEvent.Cleared.descriptor,
        RevertEvent.Committed.descriptor
    )

    /// All 48 durable session event definitions (46 public durable + `UsageRecorded` + `MessageContentUpdated`).
    // parity: schema/src/session-event.ts#DurableDefinitions [status=implemented hash=e7eb97846594]
    public static let DurableDefinitions: [EventSchema.Definition] = EventSchema.inventory(
        Definitions.filter { $0.durability == .durable }
            + [UsageRecorded.descriptor, MessageContentUpdated.descriptor]
    )

    /// All 6 ephemeral session event definitions.
    // parity: schema/src/session-event.ts#EphemeralDefinitions [status=implemented hash=e514d8b67fdb]
    public static let EphemeralDefinitions: [EventSchema.Definition] = EventSchema.inventory(
        Definitions.filter { $0.durability == .ephemeral }
    )

    /// Schema metadata descriptor for the `Session.Event.Durable` union (48 durable session events).
    // parity: schema/src/session-event.ts#Durable [status=implemented hash=b75ba981b97b]
    public static let Durable: [EventSchema.Definition] = DurableDefinitions

    /// Discriminated union of all 48 durable session events (`SessionEvent.DurableEvent`).
    // parity: schema/src/session-event.ts#DurableEvent [status=implemented hash=cd85e978b78f]
    public enum DurableEvent: Equatable, Hashable, Sendable, Codable {
        case created(EventSchema.DurableEventEnvelope<CreatedData>)
        case agentSelected(EventSchema.DurableEventEnvelope<AgentSelectedData>)
        case modelSelected(EventSchema.DurableEventEnvelope<ModelSelectedData>)
        case moved(EventSchema.DurableEventEnvelope<MovedData>)
        case renamed(EventSchema.DurableEventEnvelope<RenamedData>)
        case metadataUpdated(EventSchema.DurableEventEnvelope<MetadataUpdatedData>)
        case permissions(EventSchema.DurableEventEnvelope<PermissionsData>)
        case viewed(EventSchema.DurableEventEnvelope<ViewedData>)
        case archived(EventSchema.DurableEventEnvelope<SessionBaseData>)
        case unarchived(EventSchema.DurableEventEnvelope<SessionBaseData>)
        case deleted(EventSchema.DurableEventEnvelope<SessionBaseData>)
        case forked(EventSchema.DurableEventEnvelope<ForkedData>)
        case inboxDelivered(EventSchema.DurableEventEnvelope<InboxRefData>)
        case inboxEnqueued(EventSchema.DurableEventEnvelope<InboxEnqueuedData>)
        case inboxCancelled(EventSchema.DurableEventEnvelope<InboxRefData>)
        case inboxDeliveryChanged(EventSchema.DurableEventEnvelope<InboxDeliveryChangedData>)
        case executionStarted(EventSchema.DurableEventEnvelope<SessionBaseData>)
        case executionSucceeded(EventSchema.DurableEventEnvelope<SessionBaseData>)
        case executionFailed(EventSchema.DurableEventEnvelope<Execution.FailedData>)
        case executionInterrupted(EventSchema.DurableEventEnvelope<Execution.InterruptedData>)
        case instructionsUpdated(EventSchema.DurableEventEnvelope<InstructionsUpdatedData>)
        case synthetic(EventSchema.DurableEventEnvelope<SyntheticData>)
        case skillActivated(EventSchema.DurableEventEnvelope<Skill.ActivatedData>)
        case shellStarted(EventSchema.DurableEventEnvelope<Shell.StartedData>)
        case shellEnded(EventSchema.DurableEventEnvelope<Shell.EndedData>)
        case stepStarted(EventSchema.DurableEventEnvelope<Step.StartedData>)
        case stepFirstToken(EventSchema.DurableEventEnvelope<StepRefData>)
        case stepStreamed(EventSchema.DurableEventEnvelope<StepRefData>)
        case stepEnded(EventSchema.DurableEventEnvelope<Step.EndedData>)
        case stepFailed(EventSchema.DurableEventEnvelope<Step.FailedData>)
        case textStarted(EventSchema.DurableEventEnvelope<Text.StartedData>)
        case textEnded(EventSchema.DurableEventEnvelope<Text.EndedData>)
        case reasoningStarted(EventSchema.DurableEventEnvelope<Reasoning.StartedData>)
        case reasoningEnded(EventSchema.DurableEventEnvelope<Reasoning.EndedData>)
        case toolInputStarted(EventSchema.DurableEventEnvelope<Tool.Input.StartedData>)
        case toolInputEnded(EventSchema.DurableEventEnvelope<Tool.Input.EndedData>)
        case toolCalled(EventSchema.DurableEventEnvelope<Tool.CalledData>)
        case toolSuccess(EventSchema.DurableEventEnvelope<Tool.SuccessData>)
        case toolFailed(EventSchema.DurableEventEnvelope<Tool.FailedData>)
        case retryScheduled(EventSchema.DurableEventEnvelope<RetryScheduledData>)
        case compactionStarted(EventSchema.DurableEventEnvelope<Compaction.StartedData>)
        case compactionEnded(EventSchema.DurableEventEnvelope<Compaction.EndedData>)
        case compactionFailed(EventSchema.DurableEventEnvelope<Compaction.FailedData>)
        case revertStaged(EventSchema.DurableEventEnvelope<RevertEvent.StagedData>)
        case revertCleared(EventSchema.DurableEventEnvelope<SessionBaseData>)
        case revertCommitted(EventSchema.DurableEventEnvelope<RevertEvent.CommittedData>)
        case usageRecorded(EventSchema.DurableEventEnvelope<UsageRecordedData>)
        case messageContentUpdated(EventSchema.DurableEventEnvelope<MessageContentUpdatedData>)

        public var eventType: EventType {
            switch self {
            case .created: .created
            case .agentSelected: .agentSelected
            case .modelSelected: .modelSelected
            case .moved: .moved
            case .renamed: .renamed
            case .metadataUpdated: .metadataUpdated
            case .permissions: .permissions
            case .viewed: .viewed
            case .archived: .archived
            case .unarchived: .unarchived
            case .deleted: .deleted
            case .forked: .forked
            case .inboxDelivered: .inboxDelivered
            case .inboxEnqueued: .inboxEnqueued
            case .inboxCancelled: .inboxCancelled
            case .inboxDeliveryChanged: .inboxDeliveryChanged
            case .executionStarted: .executionStarted
            case .executionSucceeded: .executionSucceeded
            case .executionFailed: .executionFailed
            case .executionInterrupted: .executionInterrupted
            case .instructionsUpdated: .instructionsUpdated
            case .synthetic: .synthetic
            case .skillActivated: .skillActivated
            case .shellStarted: .shellStarted
            case .shellEnded: .shellEnded
            case .stepStarted: .stepStarted
            case .stepFirstToken: .stepFirstToken
            case .stepStreamed: .stepStreamed
            case .stepEnded: .stepEnded
            case .stepFailed: .stepFailed
            case .textStarted: .textStarted
            case .textEnded: .textEnded
            case .reasoningStarted: .reasoningStarted
            case .reasoningEnded: .reasoningEnded
            case .toolInputStarted: .toolInputStarted
            case .toolInputEnded: .toolInputEnded
            case .toolCalled: .toolCalled
            case .toolSuccess: .toolSuccess
            case .toolFailed: .toolFailed
            case .retryScheduled: .retryScheduled
            case .compactionStarted: .compactionStarted
            case .compactionEnded: .compactionEnded
            case .compactionFailed: .compactionFailed
            case .revertStaged: .revertStaged
            case .revertCleared: .revertCleared
            case .revertCommitted: .revertCommitted
            case .usageRecorded: .usageRecorded
            case .messageContentUpdated: .messageContentUpdated
            }
        }

        public var id: EventSchema.ID {
            switch self {
            case .created(let e): e.id
            case .agentSelected(let e): e.id
            case .modelSelected(let e): e.id
            case .moved(let e): e.id
            case .renamed(let e): e.id
            case .metadataUpdated(let e): e.id
            case .permissions(let e): e.id
            case .viewed(let e): e.id
            case .archived(let e): e.id
            case .unarchived(let e): e.id
            case .deleted(let e): e.id
            case .forked(let e): e.id
            case .inboxDelivered(let e): e.id
            case .inboxEnqueued(let e): e.id
            case .inboxCancelled(let e): e.id
            case .inboxDeliveryChanged(let e): e.id
            case .executionStarted(let e): e.id
            case .executionSucceeded(let e): e.id
            case .executionFailed(let e): e.id
            case .executionInterrupted(let e): e.id
            case .instructionsUpdated(let e): e.id
            case .synthetic(let e): e.id
            case .skillActivated(let e): e.id
            case .shellStarted(let e): e.id
            case .shellEnded(let e): e.id
            case .stepStarted(let e): e.id
            case .stepFirstToken(let e): e.id
            case .stepStreamed(let e): e.id
            case .stepEnded(let e): e.id
            case .stepFailed(let e): e.id
            case .textStarted(let e): e.id
            case .textEnded(let e): e.id
            case .reasoningStarted(let e): e.id
            case .reasoningEnded(let e): e.id
            case .toolInputStarted(let e): e.id
            case .toolInputEnded(let e): e.id
            case .toolCalled(let e): e.id
            case .toolSuccess(let e): e.id
            case .toolFailed(let e): e.id
            case .retryScheduled(let e): e.id
            case .compactionStarted(let e): e.id
            case .compactionEnded(let e): e.id
            case .compactionFailed(let e): e.id
            case .revertStaged(let e): e.id
            case .revertCleared(let e): e.id
            case .revertCommitted(let e): e.id
            case .usageRecorded(let e): e.id
            case .messageContentUpdated(let e): e.id
            }
        }

        public var durable: EventSchema.DurableEnvelope {
            switch self {
            case .created(let e): e.durable
            case .agentSelected(let e): e.durable
            case .modelSelected(let e): e.durable
            case .moved(let e): e.durable
            case .renamed(let e): e.durable
            case .metadataUpdated(let e): e.durable
            case .permissions(let e): e.durable
            case .viewed(let e): e.durable
            case .archived(let e): e.durable
            case .unarchived(let e): e.durable
            case .deleted(let e): e.durable
            case .forked(let e): e.durable
            case .inboxDelivered(let e): e.durable
            case .inboxEnqueued(let e): e.durable
            case .inboxCancelled(let e): e.durable
            case .inboxDeliveryChanged(let e): e.durable
            case .executionStarted(let e): e.durable
            case .executionSucceeded(let e): e.durable
            case .executionFailed(let e): e.durable
            case .executionInterrupted(let e): e.durable
            case .instructionsUpdated(let e): e.durable
            case .synthetic(let e): e.durable
            case .skillActivated(let e): e.durable
            case .shellStarted(let e): e.durable
            case .shellEnded(let e): e.durable
            case .stepStarted(let e): e.durable
            case .stepFirstToken(let e): e.durable
            case .stepStreamed(let e): e.durable
            case .stepEnded(let e): e.durable
            case .stepFailed(let e): e.durable
            case .textStarted(let e): e.durable
            case .textEnded(let e): e.durable
            case .reasoningStarted(let e): e.durable
            case .reasoningEnded(let e): e.durable
            case .toolInputStarted(let e): e.durable
            case .toolInputEnded(let e): e.durable
            case .toolCalled(let e): e.durable
            case .toolSuccess(let e): e.durable
            case .toolFailed(let e): e.durable
            case .retryScheduled(let e): e.durable
            case .compactionStarted(let e): e.durable
            case .compactionEnded(let e): e.durable
            case .compactionFailed(let e): e.durable
            case .revertStaged(let e): e.durable
            case .revertCleared(let e): e.durable
            case .revertCommitted(let e): e.durable
            case .usageRecorded(let e): e.durable
            case .messageContentUpdated(let e): e.durable
            }
        }

        private enum TagKeys: String, CodingKey {
            case type
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: TagKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case Created.type: self = .created(try Created.decode(from: decoder))
            case AgentSelected.type: self = .agentSelected(try AgentSelected.decode(from: decoder))
            case ModelSelected.type: self = .modelSelected(try ModelSelected.decode(from: decoder))
            case Moved.type: self = .moved(try Moved.decode(from: decoder))
            case Renamed.type: self = .renamed(try Renamed.decode(from: decoder))
            case MetadataUpdated.type: self = .metadataUpdated(try MetadataUpdated.decode(from: decoder))
            case Permissions.type: self = .permissions(try Permissions.decode(from: decoder))
            case Viewed.type: self = .viewed(try Viewed.decode(from: decoder))
            case Archived.type: self = .archived(try Archived.decode(from: decoder))
            case Unarchived.type: self = .unarchived(try Unarchived.decode(from: decoder))
            case Deleted.type: self = .deleted(try Deleted.decode(from: decoder))
            case Forked.type: self = .forked(try Forked.decode(from: decoder))
            case InboxDelivered.type: self = .inboxDelivered(try InboxDelivered.decode(from: decoder))
            case InboxEnqueued.type: self = .inboxEnqueued(try InboxEnqueued.decode(from: decoder))
            case InboxCancelled.type: self = .inboxCancelled(try InboxCancelled.decode(from: decoder))
            case InboxDeliveryChanged.type: self = .inboxDeliveryChanged(try InboxDeliveryChanged.decode(from: decoder))
            case Execution.Started.type: self = .executionStarted(try Execution.Started.decode(from: decoder))
            case Execution.Succeeded.type: self = .executionSucceeded(try Execution.Succeeded.decode(from: decoder))
            case Execution.Failed.type: self = .executionFailed(try Execution.Failed.decode(from: decoder))
            case Execution.Interrupted.type: self = .executionInterrupted(try Execution.Interrupted.decode(from: decoder))
            case InstructionsUpdated.type: self = .instructionsUpdated(try InstructionsUpdated.decode(from: decoder))
            case Synthetic.type: self = .synthetic(try Synthetic.decode(from: decoder))
            case Skill.Activated.type: self = .skillActivated(try Skill.Activated.decode(from: decoder))
            case Shell.Started.type: self = .shellStarted(try Shell.Started.decode(from: decoder))
            case Shell.Ended.type: self = .shellEnded(try Shell.Ended.decode(from: decoder))
            case Step.Started.type: self = .stepStarted(try Step.Started.decode(from: decoder))
            case Step.FirstToken.type: self = .stepFirstToken(try Step.FirstToken.decode(from: decoder))
            case Step.Streamed.type: self = .stepStreamed(try Step.Streamed.decode(from: decoder))
            case Step.Ended.type: self = .stepEnded(try Step.Ended.decode(from: decoder))
            case Step.Failed.type: self = .stepFailed(try Step.Failed.decode(from: decoder))
            case Text.Started.type: self = .textStarted(try Text.Started.decode(from: decoder))
            case Text.Ended.type: self = .textEnded(try Text.Ended.decode(from: decoder))
            case Reasoning.Started.type: self = .reasoningStarted(try Reasoning.Started.decode(from: decoder))
            case Reasoning.Ended.type: self = .reasoningEnded(try Reasoning.Ended.decode(from: decoder))
            case Tool.Input.Started.type: self = .toolInputStarted(try Tool.Input.Started.decode(from: decoder))
            case Tool.Input.Ended.type: self = .toolInputEnded(try Tool.Input.Ended.decode(from: decoder))
            case Tool.Called.type: self = .toolCalled(try Tool.Called.decode(from: decoder))
            case Tool.Success.type: self = .toolSuccess(try Tool.Success.decode(from: decoder))
            case Tool.Failed.type: self = .toolFailed(try Tool.Failed.decode(from: decoder))
            case RetryScheduled.type: self = .retryScheduled(try RetryScheduled.decode(from: decoder))
            case Compaction.Started.type: self = .compactionStarted(try Compaction.Started.decode(from: decoder))
            case Compaction.Ended.type: self = .compactionEnded(try Compaction.Ended.decode(from: decoder))
            case Compaction.Failed.type: self = .compactionFailed(try Compaction.Failed.decode(from: decoder))
            case RevertEvent.Staged.type: self = .revertStaged(try RevertEvent.Staged.decode(from: decoder))
            case RevertEvent.Cleared.type: self = .revertCleared(try RevertEvent.Cleared.decode(from: decoder))
            case RevertEvent.Committed.type: self = .revertCommitted(try RevertEvent.Committed.decode(from: decoder))
            case UsageRecorded.type: self = .usageRecorded(try UsageRecorded.decode(from: decoder))
            case MessageContentUpdated.type: self = .messageContentUpdated(try MessageContentUpdated.decode(from: decoder))
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .type,
                    in: container,
                    debugDescription: "Unknown Session.Event.Durable type '\(type)'"
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            switch self {
            case .created(let e): try e.encode(to: encoder)
            case .agentSelected(let e): try e.encode(to: encoder)
            case .modelSelected(let e): try e.encode(to: encoder)
            case .moved(let e): try e.encode(to: encoder)
            case .renamed(let e): try e.encode(to: encoder)
            case .metadataUpdated(let e): try e.encode(to: encoder)
            case .permissions(let e): try e.encode(to: encoder)
            case .viewed(let e): try e.encode(to: encoder)
            case .archived(let e): try e.encode(to: encoder)
            case .unarchived(let e): try e.encode(to: encoder)
            case .deleted(let e): try e.encode(to: encoder)
            case .forked(let e): try e.encode(to: encoder)
            case .inboxDelivered(let e): try e.encode(to: encoder)
            case .inboxEnqueued(let e): try e.encode(to: encoder)
            case .inboxCancelled(let e): try e.encode(to: encoder)
            case .inboxDeliveryChanged(let e): try e.encode(to: encoder)
            case .executionStarted(let e): try e.encode(to: encoder)
            case .executionSucceeded(let e): try e.encode(to: encoder)
            case .executionFailed(let e): try e.encode(to: encoder)
            case .executionInterrupted(let e): try e.encode(to: encoder)
            case .instructionsUpdated(let e): try e.encode(to: encoder)
            case .synthetic(let e): try e.encode(to: encoder)
            case .skillActivated(let e): try e.encode(to: encoder)
            case .shellStarted(let e): try e.encode(to: encoder)
            case .shellEnded(let e): try e.encode(to: encoder)
            case .stepStarted(let e): try e.encode(to: encoder)
            case .stepFirstToken(let e): try e.encode(to: encoder)
            case .stepStreamed(let e): try e.encode(to: encoder)
            case .stepEnded(let e): try e.encode(to: encoder)
            case .stepFailed(let e): try e.encode(to: encoder)
            case .textStarted(let e): try e.encode(to: encoder)
            case .textEnded(let e): try e.encode(to: encoder)
            case .reasoningStarted(let e): try e.encode(to: encoder)
            case .reasoningEnded(let e): try e.encode(to: encoder)
            case .toolInputStarted(let e): try e.encode(to: encoder)
            case .toolInputEnded(let e): try e.encode(to: encoder)
            case .toolCalled(let e): try e.encode(to: encoder)
            case .toolSuccess(let e): try e.encode(to: encoder)
            case .toolFailed(let e): try e.encode(to: encoder)
            case .retryScheduled(let e): try e.encode(to: encoder)
            case .compactionStarted(let e): try e.encode(to: encoder)
            case .compactionEnded(let e): try e.encode(to: encoder)
            case .compactionFailed(let e): try e.encode(to: encoder)
            case .revertStaged(let e): try e.encode(to: encoder)
            case .revertCleared(let e): try e.encode(to: encoder)
            case .revertCommitted(let e): try e.encode(to: encoder)
            case .usageRecorded(let e): try e.encode(to: encoder)
            case .messageContentUpdated(let e): try e.encode(to: encoder)
            }
        }
    }

    /// Complete inventory of all 54 session event definitions (48 durable + 6 ephemeral).
    // parity: schema/src/session-event.ts#All [status=implemented hash=0378bdb8676f]
    public static let All: [EventSchema.Definition] = DurableDefinitions + EphemeralDefinitions

    /// Discriminated union of all 54 session events (48 durable + 6 ephemeral, `SessionEvent.Event`).
    // parity: schema/src/session-event.ts#Event [status=implemented hash=5a0ea47b4094]
    public enum Event: Equatable, Hashable, Sendable, Codable {
        case durable(DurableEvent)
        case usageUpdated(EventSchema.EphemeralEventEnvelope<UsageUpdatedData>)
        case textDelta(EventSchema.EphemeralEventEnvelope<Text.DeltaData>)
        case reasoningDelta(EventSchema.EphemeralEventEnvelope<Reasoning.DeltaData>)
        case toolInputDelta(EventSchema.EphemeralEventEnvelope<Tool.Input.DeltaData>)
        case toolProgress(EventSchema.EphemeralEventEnvelope<Tool.ProgressData>)
        case compactionDelta(EventSchema.EphemeralEventEnvelope<Compaction.DeltaData>)

        public var eventType: EventType {
            switch self {
            case .durable(let durableEvent): durableEvent.eventType
            case .usageUpdated: .usageUpdated
            case .textDelta: .textDelta
            case .reasoningDelta: .reasoningDelta
            case .toolInputDelta: .toolInputDelta
            case .toolProgress: .toolProgress
            case .compactionDelta: .compactionDelta
            }
        }

        public var isDurable: Bool {
            if case .durable = self { return true }
            return false
        }

        public var id: EventSchema.ID {
            switch self {
            case .durable(let e): e.id
            case .usageUpdated(let e): e.id
            case .textDelta(let e): e.id
            case .reasoningDelta(let e): e.id
            case .toolInputDelta(let e): e.id
            case .toolProgress(let e): e.id
            case .compactionDelta(let e): e.id
            }
        }

        private enum TagKeys: String, CodingKey {
            case type
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: TagKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case UsageUpdated.type:
                self = .usageUpdated(try UsageUpdated.decode(from: decoder))
            case Text.Delta.type:
                self = .textDelta(try Text.Delta.decode(from: decoder))
            case Reasoning.Delta.type:
                self = .reasoningDelta(try Reasoning.Delta.decode(from: decoder))
            case Tool.Input.Delta.type:
                self = .toolInputDelta(try Tool.Input.Delta.decode(from: decoder))
            case Tool.Progress.type:
                self = .toolProgress(try Tool.Progress.decode(from: decoder))
            case Compaction.Delta.type:
                self = .compactionDelta(try Compaction.Delta.decode(from: decoder))
            default:
                self = .durable(try DurableEvent(from: decoder))
            }
        }

        public func encode(to encoder: Encoder) throws {
            switch self {
            case .durable(let e): try e.encode(to: encoder)
            case .usageUpdated(let e): try e.encode(to: encoder)
            case .textDelta(let e): try e.encode(to: encoder)
            case .reasoningDelta(let e): try e.encode(to: encoder)
            case .toolInputDelta(let e): try e.encode(to: encoder)
            case .toolProgress(let e): try e.encode(to: encoder)
            case .compactionDelta(let e): try e.encode(to: encoder)
            }
        }
    }

    /// Exhaustive discriminator tag enumeration across all 54 session event types (`SessionEvent.Type`).
    // parity: schema/src/session-event.ts#Type [status=implemented hash=7a22b6c9e934]
    public enum EventType: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
        case created = "session.created"
        case agentSelected = "session.agent.selected"
        case modelSelected = "session.model.selected"
        case moved = "session.moved"
        case renamed = "session.renamed"
        case metadataUpdated = "session.metadata.updated"
        case permissions = "session.permissions"
        case viewed = "session.viewed"
        case archived = "session.archived"
        case unarchived = "session.unarchived"
        case messageContentUpdated = "session.message.content.updated"
        case usageRecorded = "session.usage.recorded"
        case usageUpdated = "session.usage.updated"
        case deleted = "session.deleted"
        case forked = "session.forked"
        case inboxDelivered = "session.inbox.delivered"
        case inboxEnqueued = "session.inbox.enqueued"
        case inboxCancelled = "session.inbox.cancelled"
        case inboxDeliveryChanged = "session.inbox.delivery.changed"
        case executionStarted = "session.execution.started"
        case executionSucceeded = "session.execution.succeeded"
        case executionFailed = "session.execution.failed"
        case executionInterrupted = "session.execution.interrupted"
        case instructionsUpdated = "session.instructions.updated"
        case synthetic = "session.synthetic"
        case skillActivated = "session.skill.activated"
        case shellStarted = "session.shell.started"
        case shellEnded = "session.shell.ended"
        case stepStarted = "session.step.started"
        case stepFirstToken = "session.step.first-token"
        case stepStreamed = "session.step.streamed"
        case stepEnded = "session.step.ended"
        case stepFailed = "session.step.failed"
        case textStarted = "session.text.started"
        case textDelta = "session.text.delta"
        case textEnded = "session.text.ended"
        case reasoningStarted = "session.reasoning.started"
        case reasoningDelta = "session.reasoning.delta"
        case reasoningEnded = "session.reasoning.ended"
        case toolInputStarted = "session.tool.input.started"
        case toolInputDelta = "session.tool.input.delta"
        case toolInputEnded = "session.tool.input.ended"
        case toolCalled = "session.tool.called"
        case toolProgress = "session.tool.progress"
        case toolSuccess = "session.tool.success"
        case toolFailed = "session.tool.failed"
        case retryScheduled = "session.retry.scheduled"
        case compactionStarted = "session.compaction.started"
        case compactionDelta = "session.compaction.delta"
        case compactionEnded = "session.compaction.ended"
        case compactionFailed = "session.compaction.failed"
        case revertStaged = "session.revert.staged"
        case revertCleared = "session.revert.cleared"
        case revertCommitted = "session.revert.committed"
    }
}

// MARK: - SessionStatusEvent (`src/session-status-event.ts`)

/// Live session execution status events (`packages/schema/src/session-status-event.ts`).
public enum SessionStatusEventSchema {
    /// Session runtime status union (`SessionStatus`: `idle`, `retry`, `busy`).
    // parity: schema/src/session-status-event.ts#Info [status=implemented hash=5e97a283d792]
    public enum Info: Equatable, Hashable, Sendable, Codable {
        public struct RetryAction: Equatable, Hashable, Sendable, Codable {
            public let reason: String
            public let provider: String
            public let title: String
            public let message: String
            public let label: String
            public let link: String?

            public init(
                reason: String,
                provider: String,
                title: String,
                message: String,
                label: String,
                link: String? = nil
            ) {
                self.reason = reason
                self.provider = provider
                self.title = title
                self.message = message
                self.label = label
                self.link = link
            }
        }

        case idle
        case retry(attempt: Int, message: String, action: RetryAction? = nil, next: Int64)
        case busy

        public var typeTag: String {
            switch self {
            case .idle: "idle"
            case .retry: "retry"
            case .busy: "busy"
            }
        }

        private enum CodingKeys: String, CodingKey {
            case type
            case attempt
            case message
            case action
            case next
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "idle":
                self = .idle
            case "busy":
                self = .busy
            case "retry":
                let attempt = try container.decode(Int.self, forKey: .attempt)
                guard attempt >= 0 else {
                    throw DecodingError.dataCorruptedError(forKey: .attempt, in: container, debugDescription: "attempt must be non-negative")
                }
                let message = try container.decode(String.self, forKey: .message)
                let action = try container.decodeIfPresent(RetryAction.self, forKey: .action)
                let next = try container.decode(Int64.self, forKey: .next)
                guard next >= 0 else {
                    throw DecodingError.dataCorruptedError(forKey: .next, in: container, debugDescription: "next must be non-negative")
                }
                self = .retry(attempt: attempt, message: message, action: action, next: next)
            default:
                throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown SessionStatus type '\(type)'")
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .idle:
                try container.encode("idle", forKey: .type)
            case .busy:
                try container.encode("busy", forKey: .type)
            case .retry(let attempt, let message, let action, let next):
                try container.encode("retry", forKey: .type)
                try container.encode(attempt, forKey: .attempt)
                try container.encode(message, forKey: .message)
                try container.encodeIfPresent(action, forKey: .action)
                try container.encode(next, forKey: .next)
            }
        }
    }

    public struct StatusData: Equatable, Hashable, Sendable, Codable {
        public let sessionID: SessionID
        public let status: Info

        public init(sessionID: SessionID, status: Info) {
            self.sessionID = sessionID
            self.status = status
        }
    }

    public struct IdleData: Equatable, Hashable, Sendable, Codable {
        public let sessionID: SessionID

        public init(sessionID: SessionID) {
            self.sessionID = sessionID
        }
    }

    /// Ephemeral session status update event (`session.status`, identifier `SessionStatusUpdated`).
    // parity: schema/src/session-status-event.ts#Status [status=implemented hash=2f625d1c373d]
    public static let Status = EventSchema.ephemeral(
        type: "session.status",
        identifier: "SessionStatusUpdated",
        data: StatusData.self
    )

    /// Deprecated ephemeral session idle event (`session.idle`).
    // parity: schema/src/session-status-event.ts#Idle [status=implemented hash=1a1d368e5966]
    public static let Idle = EventSchema.ephemeral(
        type: "session.idle",
        data: IdleData.self
    )

    // parity: schema/src/session-status-event.ts#Definitions [status=implemented hash=d239f0e92881]
    public static let Definitions = EventSchema.inventory(
        Status.descriptor,
        Idle.descriptor
    )
}
