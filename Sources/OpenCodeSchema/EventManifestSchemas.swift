// MARK: - Event (`src/event.ts`)

/// Core event envelope, durability metadata, definition builders, and registry helpers (`packages/schema/src/event.ts`).
public enum EventSchema {
    public enum ValidationError: Swift.Error, Equatable, Sendable {
        case invalidSeq(Int64)
        case invalidVersion(Int)
    }

    public enum RegistryError: Swift.Error, Equatable, Sendable {
        case duplicateLatestDefinition(type: String)
        case duplicateDurableDefinition(key: String)
    }

    /// Empty data payload for events whose upstream schema is `{}`.
    public struct EmptyData: Equatable, Hashable, Sendable, Codable {
        public init() {}
    }

    /// Durability classification of an event definition.
    public enum Durability: String, Equatable, Hashable, Sendable, Codable {
        case durable
        case ephemeral
    }

    /// Static durability specification attached to a durable event definition.
    public struct DurableSpec: Equatable, Hashable, Sendable, Codable {
        public let aggregate: String
        public let version: Int

        public init(aggregate: String, version: Int) {
            self.aggregate = aggregate
            self.version = version
        }
    }

    /// Common interface shared by typed durable and ephemeral event definitions.
    public protocol EventDefinitionType: Sendable {
        associatedtype DataType: Equatable & Hashable & Sendable & Codable
        var type: String { get }
        var identifier: String { get }
        var durability: Durability { get }
        var descriptor: Definition { get }
    }

    /// Branded event identifier (`evt_<26 ascending chars>`, `Event.ID`).
    // parity: schema/src/event.ts#ID [status=implemented hash=fc1f5f650e9e]
    public struct ID: RawRepresentable, Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
        public let rawValue: String

        public init?(rawValue: String) {
            guard rawValue.hasPrefix("evt_") else { return nil }
            self.rawValue = rawValue
        }

        public init(validating value: String) throws(IdentifierValidationError) {
            guard value.hasPrefix("evt_") else {
                throw .invalidPrefix(expected: "evt_", actual: value)
            }
            self.rawValue = value
        }

        public static func create() -> ID {
            ID(unchecked: "evt_" + Identifier.ascending())
        }

        private init(unchecked value: String) {
            self.rawValue = value
        }

        public var description: String { rawValue }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            self = try ID(validating: value)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    /// Position in an aggregate's durable event log (`Event.Seq`, non-negative integer).
    // parity: schema/src/event.ts#Seq [status=implemented hash=814c2f0f8e1b]
    public struct Seq: RawRepresentable, Equatable, Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
        public let rawValue: Int64

        public init?(rawValue: Int64) {
            guard rawValue >= 0 else { return nil }
            self.rawValue = rawValue
        }

        public init(validating value: Int64) throws(ValidationError) {
            guard value >= 0 else {
                throw .invalidSeq(value)
            }
            self.rawValue = value
        }

        public var description: String { String(rawValue) }

        public static func < (lhs: Seq, rhs: Seq) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let value = try container.decode(Int64.self)
            guard value >= 0 else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Event.Seq \(value) must be >= 0"
                )
            }
            self.rawValue = value
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    /// Durable schema version of an event type (`Event.Version`, integer >= 1).
    // parity: schema/src/event.ts#Version [status=implemented hash=bf7ce7cf96ce]
    public struct Version: RawRepresentable, Equatable, Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
        public let rawValue: Int

        public init?(rawValue: Int) {
            guard rawValue >= 1 else { return nil }
            self.rawValue = rawValue
        }

        public init(validating value: Int) throws(ValidationError) {
            guard value >= 1 else {
                throw .invalidVersion(value)
            }
            self.rawValue = value
        }

        public var description: String { String(rawValue) }

        public static func < (lhs: Version, rhs: Version) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let value = try container.decode(Int.self)
            guard value >= 1 else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Event.Version \(value) must be >= 1"
                )
            }
            self.rawValue = value
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    /// Durable log metadata envelope attached to every persisted event (`Event.DurableEnvelope`).
    // parity: schema/src/event.ts#DurableEnvelope [status=implemented hash=b99f0303451f]
    public struct DurableEnvelope: Equatable, Hashable, Sendable, Codable {
        public let aggregateID: String
        public let seq: Seq
        public let version: Version

        public init(aggregateID: String, seq: Seq, version: Version) {
            self.aggregateID = aggregateID
            self.seq = seq
            self.version = version
        }
    }

    /// Concrete wire envelope for a durable event with strongly typed `data`.
    public struct DurableEventEnvelope<EventData: Equatable & Hashable & Sendable & Codable>: Equatable, Hashable, Sendable, Codable {
        public let id: ID
        public let created: Int64
        public let metadata: [String: JSONValue]?
        public let type: String
        public let durable: DurableEnvelope
        public let location: OpenCodeLocation?
        public let data: EventData

        public init(
            id: ID,
            created: Int64,
            metadata: [String: JSONValue]? = nil,
            type: String,
            durable: DurableEnvelope,
            location: OpenCodeLocation? = nil,
            data: EventData
        ) {
            self.id = id
            self.created = created
            self.metadata = metadata
            self.type = type
            self.durable = durable
            self.location = location
            self.data = data
        }
    }

    /// Concrete wire envelope for an ephemeral event with strongly typed `data`.
    public struct EphemeralEventEnvelope<EventData: Equatable & Hashable & Sendable & Codable>: Equatable, Hashable, Sendable, Codable {
        public let id: ID
        public let created: Int64
        public let metadata: [String: JSONValue]?
        public let type: String
        public let location: OpenCodeLocation?
        public let data: EventData

        public init(
            id: ID,
            created: Int64,
            metadata: [String: JSONValue]? = nil,
            type: String,
            location: OpenCodeLocation? = nil,
            data: EventData
        ) {
            self.id = id
            self.created = created
            self.metadata = metadata
            self.type = type
            self.location = location
            self.data = data
        }
    }

    /// Strongly typed durable event definition (`Event.DurableDefinition`).
    // parity: schema/src/event.ts#DurableDefinition [status=implemented hash=6847adee6821]
    public struct DurableDefinition<DataType: Equatable & Hashable & Sendable & Codable>: EventDefinitionType, Equatable, Hashable, Sendable {
        public let type: String
        public let identifier: String
        public let durability: Durability
        public let durable: DurableSpec

        public init(type: String, identifier: String? = nil, aggregate: String, version: Int) {
            self.type = type
            self.identifier = identifier ?? type
            self.durability = .durable
            self.durable = DurableSpec(aggregate: aggregate, version: version)
        }

        public var descriptor: Definition {
            Definition(type: type, identifier: identifier, durability: .durable, durable: durable)
        }

        public func makeEnvelope(
            id: ID = .create(),
            created: Int64,
            aggregateID: String,
            seq: Seq,
            location: OpenCodeLocation? = nil,
            metadata: [String: JSONValue]? = nil,
            data: DataType
        ) -> DurableEventEnvelope<DataType> {
            let version = Version(rawValue: durable.version) ?? Version(rawValue: 1)!
            return DurableEventEnvelope(
                id: id,
                created: created,
                metadata: metadata,
                type: type,
                durable: DurableEnvelope(aggregateID: aggregateID, seq: seq, version: version),
                location: location,
                data: data
            )
        }

        public func decode(from decoder: Decoder) throws -> DurableEventEnvelope<DataType> {
            let envelope = try DurableEventEnvelope<DataType>(from: decoder)
            guard envelope.type == type else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "Expected durable event type '\(type)', got '\(envelope.type)'"
                    )
                )
            }
            guard envelope.durable.version.rawValue == durable.version else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "Expected durable version \(durable.version) for '\(type)', got \(envelope.durable.version.rawValue)"
                    )
                )
            }
            return envelope
        }
    }

    /// Strongly typed ephemeral event definition (`Event.EphemeralDefinition`).
    // parity: schema/src/event.ts#EphemeralDefinition [status=implemented hash=3e5786b74ff4]
    public struct EphemeralDefinition<DataType: Equatable & Hashable & Sendable & Codable>: EventDefinitionType, Equatable, Hashable, Sendable {
        public let type: String
        public let identifier: String
        public let durability: Durability

        public init(type: String, identifier: String? = nil) {
            self.type = type
            self.identifier = identifier ?? type
            self.durability = .ephemeral
        }

        public var descriptor: Definition {
            Definition(type: type, identifier: identifier, durability: .ephemeral, durable: nil)
        }

        public func makeEnvelope(
            id: ID = .create(),
            created: Int64,
            location: OpenCodeLocation? = nil,
            metadata: [String: JSONValue]? = nil,
            data: DataType
        ) -> EphemeralEventEnvelope<DataType> {
            EphemeralEventEnvelope(
                id: id,
                created: created,
                metadata: metadata,
                type: type,
                location: location,
                data: data
            )
        }

        public func decode(from decoder: Decoder) throws -> EphemeralEventEnvelope<DataType> {
            let envelope = try EphemeralEventEnvelope<DataType>(from: decoder)
            guard envelope.type == type else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "Expected ephemeral event type '\(type)', got '\(envelope.type)'"
                    )
                )
            }
            return envelope
        }
    }

    /// Type-erased event definition descriptor stored in inventories and manifests (`Event.Definition`).
    // parity: schema/src/event.ts#Definition [status=implemented hash=6d18d9300c6d]
    public struct Definition: Equatable, Hashable, Sendable, Codable {
        public let type: String
        public let identifier: String
        public let durability: Durability
        public let durable: DurableSpec?

        public init(
            type: String,
            identifier: String? = nil,
            durability: Durability,
            durable: DurableSpec? = nil
        ) {
            self.type = type
            self.identifier = identifier ?? type
            self.durability = durability
            self.durable = durable
        }

        public static func durable(
            type: String,
            identifier: String? = nil,
            aggregate: String,
            version: Int
        ) -> Definition {
            Definition(
                type: type,
                identifier: identifier ?? type,
                durability: .durable,
                durable: DurableSpec(aggregate: aggregate, version: version)
            )
        }

        public static func ephemeral(
            type: String,
            identifier: String? = nil
        ) -> Definition {
            Definition(
                type: type,
                identifier: identifier ?? type,
                durability: .ephemeral,
                durable: nil
            )
        }
    }

    /// Associated payload data type extracted from an event definition (`Event.Data<D>`).
    // parity: schema/src/event.ts#Data [status=implemented hash=137a64992bf6]
    public typealias Data<D: EventDefinitionType> = D.DataType

    /// Generic wire payload union matching either a durable or ephemeral event (`Event.Payload`).
    // parity: schema/src/event.ts#Payload [status=implemented hash=324e1416bb0b]
    public enum Payload<EventData: Equatable & Hashable & Sendable & Codable>: Equatable, Hashable, Sendable, Codable {
        case durable(DurableEventEnvelope<EventData>)
        case ephemeral(EphemeralEventEnvelope<EventData>)

        public var id: ID {
            switch self {
            case .durable(let envelope): envelope.id
            case .ephemeral(let envelope): envelope.id
            }
        }

        public var type: String {
            switch self {
            case .durable(let envelope): envelope.type
            case .ephemeral(let envelope): envelope.type
            }
        }

        public var created: Int64 {
            switch self {
            case .durable(let envelope): envelope.created
            case .ephemeral(let envelope): envelope.created
            }
        }

        public var data: EventData {
            switch self {
            case .durable(let envelope): envelope.data
            case .ephemeral(let envelope): envelope.data
            }
        }

        public var location: OpenCodeLocation? {
            switch self {
            case .durable(let envelope): envelope.location
            case .ephemeral(let envelope): envelope.location
            }
        }

        public var metadata: [String: JSONValue]? {
            switch self {
            case .durable(let envelope): envelope.metadata
            case .ephemeral(let envelope): envelope.metadata
            }
        }

        public var durableEnvelope: DurableEnvelope? {
            switch self {
            case .durable(let envelope): envelope.durable
            case .ephemeral: nil
            }
        }

        private enum ProbeKeys: String, CodingKey {
            case durable
        }

        public init(from decoder: Decoder) throws {
            let probe = try decoder.container(keyedBy: ProbeKeys.self)
            if probe.contains(.durable) {
                self = .durable(try DurableEventEnvelope<EventData>(from: decoder))
            } else {
                self = .ephemeral(try EphemeralEventEnvelope<EventData>(from: decoder))
            }
        }

        public func encode(to encoder: Encoder) throws {
            switch self {
            case .durable(let envelope):
                try envelope.encode(to: encoder)
            case .ephemeral(let envelope):
                try envelope.encode(to: encoder)
            }
        }
    }

    /// Constructs a strongly typed durable event definition (`Event.durable`).
    // parity: schema/src/event.ts#durable [status=implemented hash=0224c012ae8c]
    public static func durable<EventData: Equatable & Hashable & Sendable & Codable>(
        type: String,
        identifier: String? = nil,
        aggregate: String,
        version: Int,
        data: EventData.Type = EventData.self
    ) -> DurableDefinition<EventData> {
        DurableDefinition(type: type, identifier: identifier, aggregate: aggregate, version: version)
    }

    /// Constructs a strongly typed ephemeral event definition (`Event.ephemeral`).
    // parity: schema/src/event.ts#ephemeral [status=implemented hash=cff6d7d31320]
    public static func ephemeral<EventData: Equatable & Hashable & Sendable & Codable>(
        type: String,
        identifier: String? = nil,
        data: EventData.Type = EventData.self
    ) -> EphemeralDefinition<EventData> {
        EphemeralDefinition(type: type, identifier: identifier)
    }

    /// Freezes an ordered event definition list (`Event.inventory`).
    // parity: schema/src/event.ts#inventory [status=implemented hash=8cafc52bfc80]
    public static func inventory(_ definitions: [Definition]) -> [Definition] {
        definitions
    }

    /// Variadic convenience overload for `Event.inventory`.
    public static func inventory(_ definitions: Definition...) -> [Definition] {
        definitions
    }

    /// Indexes definitions by event `type`, resolving multiple durable versions to the highest version (`Event.latest`).
    // parity: schema/src/event.ts#latest [status=implemented hash=fcdb0893801b]
    public static func latest(_ definitions: [Definition]) throws(RegistryError) -> [String: Definition] {
        var result: [String: Definition] = [:]
        for definition in definitions {
            guard let existing = result[definition.type] else {
                result[definition.type] = definition
                continue
            }
            if let defDurable = definition.durable,
               let existingDurable = existing.durable,
               defDurable.version != existingDurable.version
            {
                if defDurable.version > existingDurable.version {
                    result[definition.type] = definition
                }
                continue
            }
            if definition != existing {
                throw .duplicateLatestDefinition(type: definition.type)
            }
        }
        return result
    }

    /// Formats a durable event lookup key as `<type>.<version>` (`Event.versionedType`).
    // parity: schema/src/event.ts#versionedType [status=implemented hash=129fe14e7d49]
    public static func versionedType(_ type: String, version: Int) -> String {
        "\(type).\(version)"
    }

    /// Builds a versioned lookup map containing only durable event definitions (`Event.durableMap`).
    // parity: schema/src/event.ts#durableMap [status=implemented hash=aec72287eb6d]
    public static func durableMap(_ definitions: [Definition]) throws(RegistryError) -> [String: Definition] {
        var result: [String: Definition] = [:]
        for definition in definitions {
            guard definition.durability == .durable, let durable = definition.durable else {
                continue
            }
            let key = versionedType(definition.type, version: durable.version)
            if result[key] != nil {
                throw .duplicateDurableDefinition(key: key)
            }
            result[key] = definition
        }
        return result
    }
}

// MARK: - EventLog (`src/event-log.ts`)

/// Durable event log replay boundary markers (`packages/schema/src/event-log.ts`).
public enum EventLogSchema {
    /// Replay-to-live boundary marker for a durable log read (`EventLog.Synced`, `type: "log.synced"`).
    // parity: schema/src/event-log.ts#Synced [status=implemented hash=501879774c36]
    public struct Synced: Equatable, Hashable, Sendable, Codable {
        public static let typeTag = "log.synced"

        public let aggregateID: String
        public let seq: EventSchema.Seq?

        public init(aggregateID: String, seq: EventSchema.Seq? = nil) {
            self.aggregateID = aggregateID
            self.seq = seq
        }

        private enum CodingKeys: String, CodingKey {
            case type
            case aggregateID
            case seq
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            guard type == Self.typeTag else {
                throw DecodingError.dataCorruptedError(
                    forKey: .type,
                    in: container,
                    debugDescription: "Expected EventLog.Synced type '\(Self.typeTag)', got '\(type)'"
                )
            }
            self.aggregateID = try container.decode(String.self, forKey: .aggregateID)
            self.seq = try container.decodeIfPresent(EventSchema.Seq.self, forKey: .seq)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(Self.typeTag, forKey: .type)
            try container.encode(aggregateID, forKey: .aggregateID)
            try container.encodeIfPresent(seq, forKey: .seq)
        }
    }
}

// MARK: - InstallationEvent (`src/installation-event.ts`)

/// Installation lifecycle events (`packages/schema/src/installation-event.ts`).
public enum InstallationEventSchema {
    public struct VersionData: Equatable, Hashable, Sendable, Codable {
        public let version: String

        public init(version: String) {
            self.version = version
        }
    }

    // parity: schema/src/installation-event.ts#Updated [status=implemented hash=3aaffef4f98d]
    public static let Updated = EventSchema.ephemeral(
        type: "installation.updated",
        data: VersionData.self
    )

    // parity: schema/src/installation-event.ts#UpdateAvailable [status=implemented hash=91837522d0d6]
    public static let UpdateAvailable = EventSchema.ephemeral(
        type: "installation.update-available",
        data: VersionData.self
    )

    // parity: schema/src/installation-event.ts#Definitions [status=implemented hash=bec8d550c31a]
    public static let Definitions = EventSchema.inventory(
        Updated.descriptor,
        UpdateAvailable.descriptor
    )
}

// MARK: - LocationEvent (`src/location-event.ts`)

/// Location lifecycle events (`packages/schema/src/location-event.ts`).
public enum LocationEventSchema {
    /// The location's cached services were shut down; clients must revalidate its reads.
    // parity: schema/src/location-event.ts#Shutdown [status=implemented hash=d447cf7d1abc]
    public static let Shutdown = EventSchema.ephemeral(
        type: "location.shutdown",
        data: EventSchema.EmptyData.self
    )

    // parity: schema/src/location-event.ts#Definitions [status=implemented hash=ac25b6d9e50d]
    public static let Definitions = EventSchema.inventory(Shutdown.descriptor)
}

// MARK: - LspEvent (`src/lsp-event.ts`)

/// LSP events (`packages/schema/src/lsp-event.ts`).
public enum LspEventSchema {
    // parity: schema/src/lsp-event.ts#Updated [status=implemented hash=66d6e899016d]
    public static let Updated = EventSchema.ephemeral(
        type: "lsp.updated",
        data: EventSchema.EmptyData.self
    )

    // parity: schema/src/lsp-event.ts#Definitions [status=implemented hash=7404eadce372]
    public static let Definitions = EventSchema.inventory(Updated.descriptor)
}

// MARK: - McpEvent (`src/mcp-event.ts`)

/// MCP server and experimental subscription events (`packages/schema/src/mcp-event.ts`).
public enum McpEventSchema {
    public struct ServerData: Equatable, Hashable, Sendable, Codable {
        public let server: String

        public init(server: String) {
            self.server = server
        }
    }

    public struct ExperimentalEventData: Equatable, Hashable, Sendable, Codable {
        public let id: String
        public let server: String
        public let name: String
        public let eventId: String
        public let timestamp: String
        public let data: JSONValue
        /// Where the subscription resumes from after this event; encoded as explicit `null` when absent.
        public let cursor: String?
        /// The server skipped events before this one, which it could not replay.
        public let truncated: Bool?

        public init(
            id: String,
            server: String,
            name: String,
            eventId: String,
            timestamp: String,
            data: JSONValue,
            cursor: String?,
            truncated: Bool? = nil
        ) {
            self.id = id
            self.server = server
            self.name = name
            self.eventId = eventId
            self.timestamp = timestamp
            self.data = data
            self.cursor = cursor
            self.truncated = truncated
        }

        private enum CodingKeys: String, CodingKey {
            case id
            case server
            case name
            case eventId
            case timestamp
            case data
            case cursor
            case truncated
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try container.decode(String.self, forKey: .id)
            self.server = try container.decode(String.self, forKey: .server)
            self.name = try container.decode(String.self, forKey: .name)
            self.eventId = try container.decode(String.self, forKey: .eventId)
            self.timestamp = try container.decode(String.self, forKey: .timestamp)
            self.data = try container.decode(JSONValue.self, forKey: .data)
            self.cursor = try container.decode(String?.self, forKey: .cursor)
            self.truncated = try container.decodeIfPresent(Bool.self, forKey: .truncated)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(server, forKey: .server)
            try container.encode(name, forKey: .name)
            try container.encode(eventId, forKey: .eventId)
            try container.encode(timestamp, forKey: .timestamp)
            try container.encode(data, forKey: .data)
            try container.encode(cursor, forKey: .cursor)
            try container.encodeIfPresent(truncated, forKey: .truncated)
        }
    }

    public struct ExperimentalSubscriptionChangedData: Equatable, Hashable, Sendable, Codable {
        public let id: String

        public init(id: String) {
            self.id = id
        }
    }

    // parity: schema/src/mcp-event.ts#ToolsChanged [status=implemented hash=43a16ce448d1]
    public static let ToolsChanged = EventSchema.ephemeral(
        type: "mcp.tools.changed",
        data: ServerData.self
    )

    // parity: schema/src/mcp-event.ts#ResourcesChanged [status=implemented hash=3d85bfaf6dcc]
    public static let ResourcesChanged = EventSchema.ephemeral(
        type: "mcp.resources.changed",
        data: ServerData.self
    )

    // parity: schema/src/mcp-event.ts#StatusChanged [status=implemented hash=6f1e5e4f1e90]
    public static let StatusChanged = EventSchema.ephemeral(
        type: "mcp.status.changed",
        data: ServerData.self
    )

    // parity: schema/src/mcp-event.ts#ExperimentalEvent [status=implemented hash=bb7c74ce10fe]
    public static let ExperimentalEvent = EventSchema.ephemeral(
        type: "experimental.mcp.event",
        data: ExperimentalEventData.self
    )

    // parity: schema/src/mcp-event.ts#ExperimentalSubscriptionChanged [status=implemented hash=9970dcd3e1b7]
    public static let ExperimentalSubscriptionChanged = EventSchema.ephemeral(
        type: "experimental.mcp.subscription.changed",
        data: ExperimentalSubscriptionChangedData.self
    )

    // parity: schema/src/mcp-event.ts#Definitions [status=implemented hash=c95cd960adaf]
    public static let Definitions = EventSchema.inventory(
        ToolsChanged.descriptor,
        ResourcesChanged.descriptor,
        StatusChanged.descriptor,
        ExperimentalEvent.descriptor,
        ExperimentalSubscriptionChanged.descriptor
    )
}

// MARK: - ServerEvent (`src/server-event.ts`)

/// Server transport lifecycle events (`packages/schema/src/server-event.ts`).
public enum ServerEventSchema {
    // parity: schema/src/server-event.ts#Connected [status=implemented hash=c45864272545]
    public static let Connected = EventSchema.ephemeral(
        type: "server.connected",
        data: EventSchema.EmptyData.self
    )

    // parity: schema/src/server-event.ts#Disposed [status=implemented hash=3430a3823728]
    public static let Disposed = EventSchema.ephemeral(
        type: "global.disposed",
        data: EventSchema.EmptyData.self
    )

    // parity: schema/src/server-event.ts#Definitions [status=implemented hash=ce6116b47b2d]
    public static let Definitions = EventSchema.inventory(
        Connected.descriptor,
        Disposed.descriptor
    )
}

// MARK: - TuiEvent (`src/tui-event.ts`)

/// Terminal user interface control events (`packages/schema/src/tui-event.ts`).
public enum TuiEventSchema {
    public static let defaultToastDuration = 5000

    public struct PromptAppendData: Equatable, Hashable, Sendable, Codable {
        public let text: String

        public init(text: String) {
            self.text = text
        }
    }

    public enum Command: Equatable, Hashable, Sendable, Codable, RawRepresentable {
        case sessionList
        case sessionNew
        case sessionInterrupt
        case sessionBackground
        case sessionCompact
        case sessionPageUp
        case sessionPageDown
        case sessionLineUp
        case sessionLineDown
        case sessionHalfPageUp
        case sessionHalfPageDown
        case sessionFirst
        case sessionLast
        case promptClear
        case promptSubmit
        case agentCycle
        case custom(String)

        public var rawValue: String {
            switch self {
            case .sessionList: "session.list"
            case .sessionNew: "session.new"
            case .sessionInterrupt: "session.interrupt"
            case .sessionBackground: "session.background"
            case .sessionCompact: "session.compact"
            case .sessionPageUp: "session.page.up"
            case .sessionPageDown: "session.page.down"
            case .sessionLineUp: "session.line.up"
            case .sessionLineDown: "session.line.down"
            case .sessionHalfPageUp: "session.half.page.up"
            case .sessionHalfPageDown: "session.half.page.down"
            case .sessionFirst: "session.first"
            case .sessionLast: "session.last"
            case .promptClear: "prompt.clear"
            case .promptSubmit: "prompt.submit"
            case .agentCycle: "agent.cycle"
            case .custom(let value): value
            }
        }

        public init(rawValue: String) {
            switch rawValue {
            case "session.list": self = .sessionList
            case "session.new": self = .sessionNew
            case "session.interrupt": self = .sessionInterrupt
            case "session.background": self = .sessionBackground
            case "session.compact": self = .sessionCompact
            case "session.page.up": self = .sessionPageUp
            case "session.page.down": self = .sessionPageDown
            case "session.line.up": self = .sessionLineUp
            case "session.line.down": self = .sessionLineDown
            case "session.half.page.up": self = .sessionHalfPageUp
            case "session.half.page.down": self = .sessionHalfPageDown
            case "session.first": self = .sessionFirst
            case "session.last": self = .sessionLast
            case "prompt.clear": self = .promptClear
            case "prompt.submit": self = .promptSubmit
            case "agent.cycle": self = .agentCycle
            default: self = .custom(rawValue)
            }
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            self = Command(rawValue: raw)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    public struct CommandExecuteData: Equatable, Hashable, Sendable, Codable {
        public let command: Command

        public init(command: Command) {
            self.command = command
        }
    }

    public struct ToastShowData: Equatable, Hashable, Sendable, Codable {
        public enum Variant: String, Equatable, Hashable, Sendable, Codable {
            case info
            case success
            case warning
            case error
        }

        public let title: String?
        public let message: String
        public let variant: Variant
        /// Duration in milliseconds (defaults to 5000 on decode if omitted).
        public let duration: Int

        public init(
            title: String? = nil,
            message: String,
            variant: Variant,
            duration: Int = TuiEventSchema.defaultToastDuration
        ) {
            self.title = title
            self.message = message
            self.variant = variant
            self.duration = duration
        }

        private enum CodingKeys: String, CodingKey {
            case title
            case message
            case variant
            case duration
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.title = try container.decodeIfPresent(String.self, forKey: .title)
            self.message = try container.decode(String.self, forKey: .message)
            self.variant = try container.decode(Variant.self, forKey: .variant)
            let duration = try container.decodeIfPresent(Int.self, forKey: .duration) ?? TuiEventSchema.defaultToastDuration
            guard duration > 0 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .duration,
                    in: container,
                    debugDescription: "Toast duration \(duration) must be a positive integer"
                )
            }
            self.duration = duration
        }
    }

    public struct SessionSelectData: Equatable, Hashable, Sendable, Codable {
        public let sessionID: SessionID

        public init(sessionID: SessionID) {
            self.sessionID = sessionID
        }
    }

    // parity: schema/src/tui-event.ts#PromptAppend [status=implemented hash=311ba4e983ec]
    public static let PromptAppend = EventSchema.ephemeral(
        type: "tui.prompt.append",
        data: PromptAppendData.self
    )

    // parity: schema/src/tui-event.ts#CommandExecute [status=implemented hash=f86f361d2a7b]
    public static let CommandExecute = EventSchema.ephemeral(
        type: "tui.command.execute",
        data: CommandExecuteData.self
    )

    // parity: schema/src/tui-event.ts#ToastShow [status=implemented hash=f954d1426a2e]
    public static let ToastShow = EventSchema.ephemeral(
        type: "tui.toast.show",
        data: ToastShowData.self
    )

    // parity: schema/src/tui-event.ts#SessionSelect [status=implemented hash=4ee2f80533d8]
    public static let SessionSelect = EventSchema.ephemeral(
        type: "tui.session.select",
        data: SessionSelectData.self
    )

    // parity: schema/src/tui-event.ts#Definitions [status=implemented hash=68e1954d739f]
    public static let Definitions = EventSchema.inventory(
        PromptAppend.descriptor,
        CommandExecute.descriptor,
        ToastShow.descriptor,
        SessionSelect.descriptor
    )
}

// MARK: - VcsEvent (`src/vcs-event.ts`)

/// Version control events (`packages/schema/src/vcs-event.ts`).
public enum VcsEventSchema {
    public struct BranchUpdatedData: Equatable, Hashable, Sendable, Codable {
        public let branch: String?

        public init(branch: String? = nil) {
            self.branch = branch
        }
    }

    // parity: schema/src/vcs-event.ts#BranchUpdated [status=implemented hash=bb2722f03345]
    public static let BranchUpdated = EventSchema.ephemeral(
        type: "vcs.branch.updated",
        data: BranchUpdatedData.self
    )

    // parity: schema/src/vcs-event.ts#Definitions [status=implemented hash=73b428111cd1]
    public static let Definitions = EventSchema.inventory(BranchUpdated.descriptor)
}

// MARK: - WorkspaceEvent (`src/workspace-event.ts`)

/// Remote workspace connection and lifecycle events (`packages/schema/src/workspace-event.ts`).
public enum WorkspaceEventSchema {
    /// Workspace connection status payload (`WorkspaceEvent.ConnectionStatus`).
    // parity: schema/src/workspace-event.ts#ConnectionStatus [status=implemented hash=9c2d2f07cef1]
    public struct ConnectionStatus: Equatable, Hashable, Sendable, Codable {
        public enum State: String, Equatable, Hashable, Sendable, Codable {
            case connected
            case connecting
            case disconnected
            case error
        }

        public let workspaceID: WorkspaceID
        public let status: State

        public init(workspaceID: WorkspaceID, status: State) {
            self.workspaceID = workspaceID
            self.status = status
        }
    }

    public struct ReadyData: Equatable, Hashable, Sendable, Codable {
        public let name: String

        public init(name: String) {
            self.name = name
        }
    }

    public struct FailedData: Equatable, Hashable, Sendable, Codable {
        public let message: String

        public init(message: String) {
            self.message = message
        }
    }

    // parity: schema/src/workspace-event.ts#Ready [status=implemented hash=c32b5f891ee3]
    public static let Ready = EventSchema.ephemeral(
        type: "workspace.ready",
        data: ReadyData.self
    )

    // parity: schema/src/workspace-event.ts#Failed [status=implemented hash=823ec819173e]
    public static let Failed = EventSchema.ephemeral(
        type: "workspace.failed",
        data: FailedData.self
    )

    // parity: schema/src/workspace-event.ts#Status [status=implemented hash=6a661d00905d]
    public static let Status = EventSchema.ephemeral(
        type: "workspace.status",
        data: ConnectionStatus.self
    )

    // parity: schema/src/workspace-event.ts#Definitions [status=implemented hash=ae31928e09f0]
    public static let Definitions = EventSchema.inventory(
        Ready.descriptor,
        Failed.descriptor,
        Status.descriptor
    )
}

// MARK: - WorktreeEvent (`src/worktree-event.ts`)

/// Git worktree lifecycle events (`packages/schema/src/worktree-event.ts`).
public enum WorktreeEventSchema {
    public struct ReadyData: Equatable, Hashable, Sendable, Codable {
        public let name: String
        public let branch: String?

        public init(name: String, branch: String? = nil) {
            self.name = name
            self.branch = branch
        }
    }

    public struct FailedData: Equatable, Hashable, Sendable, Codable {
        public let message: String

        public init(message: String) {
            self.message = message
        }
    }

    // parity: schema/src/worktree-event.ts#Ready [status=implemented hash=7a2d7d5a96dc]
    public static let Ready = EventSchema.ephemeral(
        type: "worktree.ready",
        data: ReadyData.self
    )

    // parity: schema/src/worktree-event.ts#Failed [status=implemented hash=55b012b731b0]
    public static let Failed = EventSchema.ephemeral(
        type: "worktree.failed",
        data: FailedData.self
    )

    // parity: schema/src/worktree-event.ts#Definitions [status=implemented hash=5777bec924a5]
    public static let Definitions = EventSchema.inventory(
        Ready.descriptor,
        Failed.descriptor
    )
}

// MARK: - DurableEventManifest (`src/durable-event-manifest.ts`)

/// Registry of all versioned durable event definitions (`packages/schema/src/durable-event-manifest.ts`).
public enum DurableEventManifestSchema {
    /// Descriptor for `worktree.resolved` (durable v1, aggregate `projectID`).
    internal static let worktreeResolvedDefinition = EventSchema.Definition.durable(
        type: "worktree.resolved",
        aggregate: "projectID",
        version: 1
    )

    /// Versioned map (`<type>.<version>`) of all 49 durable event definitions.
    // parity: schema/src/durable-event-manifest.ts#Durable [status=implemented hash=0d560ca25e2b]
    public static let Durable: [String: EventSchema.Definition] = {
        let all = SessionEventSchema.DurableDefinitions + [worktreeResolvedDefinition]
        return try! EventSchema.durableMap(all)
    }()
}

// MARK: - EventManifest (`src/event-manifest.ts`)

/// Canonical server and complete event manifest registries (`packages/schema/src/event-manifest.ts`).
public enum EventManifestSchema {
    private static let foundationDefinitions: [EventSchema.Definition] = EventSchema.inventory(
        LocationEventSchema.Definitions
            + [
                .ephemeral(type: "models-dev.refreshed"),
                .ephemeral(type: "credential.updated"),
                .ephemeral(type: "credential.switched"),
                .ephemeral(type: "integration.updated"),
                .ephemeral(type: "provider.updated"),
                .ephemeral(type: "model.updated"),
                .ephemeral(type: "agent.updated"),
            ]
            + SessionEventSchema.Definitions
    )

    private static let featureDefinitions: [EventSchema.Definition] = EventSchema.inventory([
        .ephemeral(type: "filesystem.changed"),
        .ephemeral(type: "reference.updated"),
        .ephemeral(type: "permission.asked"),
        .ephemeral(type: "permission.replied"),
        .ephemeral(type: "plugin.updated"),
        .ephemeral(type: "project.updated"),
        .ephemeral(type: "worktree.updated"),
        DurableEventManifestSchema.worktreeResolvedDefinition,
        .ephemeral(type: "command.updated"),
        .ephemeral(type: "config.updated"),
        .ephemeral(type: "skill.updated"),
        .ephemeral(type: "pty.created"),
        .ephemeral(type: "pty.updated"),
        .ephemeral(type: "pty.exited"),
        .ephemeral(type: "pty.deleted"),
        .ephemeral(type: "persistent-pty.added"),
        .ephemeral(type: "persistent-pty.removed"),
        .ephemeral(type: "persistent-pty.updated"),
        .ephemeral(type: "shell.created"),
        .ephemeral(type: "shell.exited"),
        .ephemeral(type: "shell.deleted"),
        .ephemeral(type: "experimental.job.updated"),
        .ephemeral(type: "form.created"),
        .ephemeral(type: "form.replied"),
        .ephemeral(type: "form.cancelled"),
        .ephemeral(type: "websearch.updated"),
        .ephemeral(type: "artifact.updated"),
    ])

    /// Ordered inventory of all 99 public server event definitions.
    // parity: schema/src/event-manifest.ts#ServerDefinitions [status=implemented hash=36396993e596]
    public static let ServerDefinitions: [EventSchema.Definition] = EventSchema.inventory(
        foundationDefinitions
            + featureDefinitions
            + SessionStatusEventSchema.Definitions
            + TuiEventSchema.Definitions
            + InstallationEventSchema.Definitions
            + VcsEventSchema.Definitions
            + [
                McpEventSchema.StatusChanged.descriptor,
                McpEventSchema.ResourcesChanged.descriptor,
                McpEventSchema.ExperimentalEvent.descriptor,
            ]
    )

    /// Lookup map of latest public server event definitions keyed by event `type`.
    // parity: schema/src/event-manifest.ts#Server [status=implemented hash=4c0fdb5d415d]
    public static let Server: [String: EventSchema.Definition] = try! EventSchema.latest(ServerDefinitions)

    /// Validated public server event wire envelope whose `type` is guaranteed to belong to `Server`.
    // parity: schema/src/event-manifest.ts#ServerEvent [status=implemented hash=ddce2b2e0fa5]
    public struct ServerEvent: Equatable, Hashable, Sendable, Codable {
        public let payload: EventSchema.Payload<JSONValue>

        public var id: EventSchema.ID { payload.id }
        public var type: String { payload.type }
        public var created: Int64 { payload.created }
        public var data: JSONValue { payload.data }
        public var location: OpenCodeLocation? { payload.location }
        public var metadata: [String: JSONValue]? { payload.metadata }
        public var durable: EventSchema.DurableEnvelope? { payload.durableEnvelope }

        public init(payload: EventSchema.Payload<JSONValue>) {
            self.payload = payload
        }

        public init(from decoder: Decoder) throws {
            let payload = try EventSchema.Payload<JSONValue>(from: decoder)
            guard let definition = EventManifestSchema.Server[payload.type] else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "Event type '\(payload.type)' is not in EventManifest.Server"
                    )
                )
            }
            switch (definition.durability, payload) {
            case (.durable, .durable(let env)):
                if let spec = definition.durable, env.durable.version.rawValue != spec.version {
                    throw DecodingError.dataCorrupted(
                        DecodingError.Context(
                            codingPath: decoder.codingPath,
                            debugDescription: "Expected durable version \(spec.version) for '\(payload.type)', got \(env.durable.version.rawValue)"
                        )
                    )
                }
            case (.ephemeral, .ephemeral):
                break
            case (.durable, .ephemeral):
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "Event '\(payload.type)' requires a durable envelope"
                    )
                )
            case (.ephemeral, .durable):
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "Ephemeral event '\(payload.type)' must not include a durable envelope"
                    )
                )
            }
            self.payload = payload
        }

        public func encode(to encoder: Encoder) throws {
            try payload.encode(to: encoder)
        }
    }

    /// Type predicate testing whether an event type belongs to the public `Server` manifest.
    // parity: schema/src/event-manifest.ts#isServer [status=implemented hash=5bf8ffc9e86a]
    public static func isServer(type: String) -> Bool {
        Server[type] != nil
    }

    /// Convenience overload checking an event payload directly.
    public static func isServer<EventData: Equatable & Hashable & Sendable & Codable>(
        _ event: EventSchema.Payload<EventData>
    ) -> Bool {
        isServer(type: event.type)
    }

    /// Complete ordered inventory of all 110 public and compatibility event definitions.
    // parity: schema/src/event-manifest.ts#Definitions [status=implemented hash=a72bca3b5293]
    public static let Definitions: [EventSchema.Definition] = EventSchema.inventory(
        foundationDefinitions
            + InstallationEventSchema.Definitions
            + featureDefinitions
            + LspEventSchema.Definitions
            + TuiEventSchema.Definitions
            + McpEventSchema.Definitions
            + [
                .ephemeral(type: "command.executed"),
                .ephemeral(type: "file.edited"),
            ]
            + SessionStatusEventSchema.Definitions
            + VcsEventSchema.Definitions
            + WorkspaceEventSchema.Definitions
            + WorktreeEventSchema.Definitions
            + ServerEventSchema.Definitions
    )

    /// Lookup map of all 110 latest event definitions keyed by event `type`.
    // parity: schema/src/event-manifest.ts#Latest [status=implemented hash=6a977567c1f3]
    public static let Latest: [String: EventSchema.Definition] = try! EventSchema.latest(Definitions)

    /// Re-export of the durable event registry (`DurableEventManifestSchema.Durable`).
    // parity: schema/src/event-manifest.ts#Durable [status=implemented hash=b9ce60f52c19]
    public static let Durable: [String: EventSchema.Definition] = DurableEventManifestSchema.Durable
}
