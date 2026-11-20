// MARK: - Prompt (`src/prompt.ts`)

/// Prompt attachments, mentions, and structured prompt payload schemas (`packages/schema/src/prompt.ts`).
public enum PromptSchema {
    public enum ValidationError: Swift.Error, Equatable, Sendable {
        case invalidBase64(String)
        case invalidMediaRef(String)
    }

    /// Source text range for an inline prompt mention (`Prompt.Mention`).
    // parity: schema/src/prompt.ts#PromptMention [status=implemented hash=24b4321f522b]
    public struct PromptMention: Equatable, Hashable, Sendable, Codable {
        public let start: Int
        public let end: Int
        public let text: String

        public init(start: Int, end: Int, text: String) {
            self.start = start
            self.end = end
            self.text = text
        }
    }

    /// Origin of an attached file (`Prompt.FileSource`).
    // parity: schema/src/prompt.ts#FileSource [status=implemented hash=7018d41c8634]
    public enum FileSource: Equatable, Hashable, Sendable, Codable {
        case inline
        case uri(String)

        public var typeTag: String {
            switch self {
            case .inline: "inline"
            case .uri: "uri"
            }
        }

        private enum CodingKeys: String, CodingKey {
            case type
            case uri
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "inline":
                self = .inline
            case "uri":
                let uri = try container.decode(String.self, forKey: .uri)
                self = .uri(uri)
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .type,
                    in: container,
                    debugDescription: "Unknown Prompt.FileSource type '\(type)'"
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .inline:
                try container.encode("inline", forKey: .type)
            case .uri(let uri):
                try container.encode("uri", forKey: .type)
                try container.encode(uri, forKey: .uri)
            }
        }
    }

    /// Validated standard RFC 4648 base64 string (`Prompt.Base64`).
    // parity: schema/src/prompt.ts#Base64 [status=implemented hash=b505ec0e2e82]
    public struct Base64: RawRepresentable, Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
        public let rawValue: String

        public static func isValid(_ value: String) -> Bool {
            let bytes = Array(value.utf8)
            guard bytes.count % 4 == 0 else { return false }
            var end = bytes.count
            var padding = 0
            while end > 0 && bytes[end - 1] == UInt8(ascii: "=") {
                end -= 1
                padding += 1
                if padding > 2 { return false }
            }
            for index in 0..<end {
                let byte = bytes[index]
                let isAlphaNum =
                    (byte >= 65 && byte <= 90)
                    || (byte >= 97 && byte <= 122)
                    || (byte >= 48 && byte <= 57)
                let isSymbol = byte == UInt8(ascii: "+") || byte == UInt8(ascii: "/")
                if !isAlphaNum && !isSymbol {
                    return false
                }
            }
            return true
        }

        public init?(rawValue: String) {
            guard Self.isValid(rawValue) else { return nil }
            self.rawValue = rawValue
        }

        public init(validating value: String) throws(ValidationError) {
            guard Self.isValid(value) else {
                throw .invalidBase64(value)
            }
            self.rawValue = value
        }

        public var description: String { rawValue }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard Self.isValid(value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid base64 string for Prompt.Base64"
                )
            }
            self.rawValue = value
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    /// Inline base64-encoded file attachment (`Prompt.FileAttachment`).
    // parity: schema/src/prompt.ts#FileAttachment [status=implemented hash=45eae25447bd]
    public struct FileAttachment: Equatable, Hashable, Sendable, Codable {
        public let data: Base64
        public let mime: String
        public let source: FileSource
        public let name: String?
        public let description: String?
        public let mention: PromptMention?

        public init(
            data: Base64,
            mime: String,
            source: FileSource,
            name: String? = nil,
            description: String? = nil,
            mention: PromptMention? = nil
        ) {
            self.data = data
            self.mime = mime
            self.source = source
            self.name = name
            self.description = description
            self.mention = mention
        }

        public static func create(_ input: FileAttachment) -> FileAttachment {
            FileAttachment(
                data: input.data,
                mime: input.mime,
                source: input.source,
                name: input.name,
                description: input.description,
                mention: input.mention
            )
        }
    }

    /// `media:` followed by a 64-character lowercase hex SHA-256 digest (`Prompt.MediaRef`).
    // parity: schema/src/prompt.ts#MediaRef [status=implemented hash=05a4c4addf2b]
    public struct MediaRef: RawRepresentable, Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
        public let rawValue: String

        public static func isValid(_ value: String) -> Bool {
            let bytes = Array(value.utf8)
            guard bytes.count == 70, value.hasPrefix("media:") else { return false }
            for index in 6..<70 {
                let byte = bytes[index]
                let isLowerHex = (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
                if !isLowerHex { return false }
            }
            return true
        }

        public init?(rawValue: String) {
            guard Self.isValid(rawValue) else { return nil }
            self.rawValue = rawValue
        }

        public init(validating value: String) throws(ValidationError) {
            guard Self.isValid(value) else {
                throw .invalidMediaRef(value)
            }
            self.rawValue = value
        }

        public var description: String { rawValue }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard Self.isValid(value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid MediaRef '\(value)' (expected /^media:[0-9a-f]{64}$/)"
                )
            }
            self.rawValue = value
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    /// Attachment whose bytes remain on the server (`Prompt.MediaFileAttachment`).
    // parity: schema/src/prompt.ts#MediaFileAttachment [status=implemented hash=06c55b339b93]
    public struct MediaFileAttachment: Equatable, Hashable, Sendable, Codable {
        public let mime: String
        public let source: FileSource
        public let name: String?
        public let description: String?
        public let mention: PromptMention?
        public let uri: MediaRef
        public let bytes: Int?
        public let width: Int?
        public let height: Int?

        public init(
            mime: String,
            source: FileSource,
            name: String? = nil,
            description: String? = nil,
            mention: PromptMention? = nil,
            uri: MediaRef,
            bytes: Int? = nil,
            width: Int? = nil,
            height: Int? = nil
        ) {
            self.mime = mime
            self.source = source
            self.name = name
            self.description = description
            self.mention = mention
            self.uri = uri
            self.bytes = bytes
            self.width = width
            self.height = height
        }
    }

    /// Union of inline `FileAttachment` and server-stored `MediaFileAttachment` (`Prompt.Attachment`).
    // parity: schema/src/prompt.ts#Attachment [status=implemented hash=992c01539f95]
    public enum Attachment: Equatable, Hashable, Sendable, Codable {
        case file(FileAttachment)
        case media(MediaFileAttachment)

        private enum ProbeKeys: String, CodingKey {
            case data
            case uri
        }

        public init(from decoder: Decoder) throws {
            let probe = try decoder.container(keyedBy: ProbeKeys.self)
            if probe.contains(.data) {
                self = .file(try FileAttachment(from: decoder))
            } else if probe.contains(.uri) {
                self = .media(try MediaFileAttachment(from: decoder))
            } else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "Prompt.Attachment must contain either 'data' or 'uri'"
                    )
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            switch self {
            case .file(let attachment):
                try attachment.encode(to: encoder)
            case .media(let attachment):
                try attachment.encode(to: encoder)
            }
        }
    }

    /// Agent mention attachment (`Prompt.AgentAttachment`).
    // parity: schema/src/prompt.ts#AgentAttachment [status=implemented hash=b1447669cdd2]
    public struct AgentAttachment: Equatable, Hashable, Sendable, Codable {
        public let name: String
        public let mention: PromptMention?

        public init(name: String, mention: PromptMention? = nil) {
            self.name = name
            self.mention = mention
        }
    }

    /// Resolved skill attachment (`Prompt.SkillAttachment`).
    // parity: schema/src/prompt.ts#SkillAttachment [status=implemented hash=7aac0ccb70c4]
    public struct SkillAttachment: Equatable, Hashable, Sendable, Codable {
        public let id: String
        public let name: String
        public let text: String?
        public let mention: PromptMention?

        public init(id: String, name: String, text: String? = nil, mention: PromptMention? = nil) {
            self.id = id
            self.name = name
            self.text = text
            self.mention = mention
        }
    }

    /// Canonical structured prompt payload (`Prompt`).
    // parity: schema/src/prompt.ts#Prompt [status=implemented hash=36414d5a37d1]
    public struct Prompt: Equatable, Hashable, Sendable, Codable {
        public let text: String
        public let files: [FileAttachment]?
        public let agents: [AgentAttachment]?
        public let skills: [SkillAttachment]?

        public init(
            text: String,
            files: [FileAttachment]? = nil,
            agents: [AgentAttachment]? = nil,
            skills: [SkillAttachment]? = nil
        ) {
            self.text = text
            self.files = files
            self.agents = agents
            self.skills = skills
        }

        public static func equivalence(_ lhs: Prompt, _ rhs: Prompt) -> Bool {
            lhs == rhs
        }

        public static func fromUserMessage(_ user: SessionMessageSchema.User) -> Prompt {
            Prompt(
                text: user.text,
                files: user.files,
                agents: user.agents,
                skills: user.skills
            )
        }
    }
}

// MARK: - PromptInput (`src/prompt-input.ts`)

/// Client-submitted prompt input schemas before attachment resolution (`packages/schema/src/prompt-input.ts`).
public enum PromptInputSchema {
    /// URI-referenced file input (`PromptInput.FileAttachment`).
    // parity: schema/src/prompt-input.ts#FileAttachment [status=implemented hash=45eae25447bd]
    public struct FileAttachment: Equatable, Hashable, Sendable, Codable {
        public let uri: String
        public let source: PromptSchema.FileSource?
        public let name: String?
        public let description: String?
        public let mention: PromptSchema.PromptMention?

        public init(
            uri: String,
            source: PromptSchema.FileSource? = nil,
            name: String? = nil,
            description: String? = nil,
            mention: PromptSchema.PromptMention? = nil
        ) {
            self.uri = uri
            self.source = source
            self.name = name
            self.description = description
            self.mention = mention
        }
    }

    /// Skill ID reference input (`PromptInput.SkillAttachment`).
    // parity: schema/src/prompt-input.ts#SkillAttachment [status=implemented hash=7aac0ccb70c4]
    public struct SkillAttachment: Equatable, Hashable, Sendable, Codable {
        public let id: String
        public let mention: PromptSchema.PromptMention?

        public init(id: String, mention: PromptSchema.PromptMention? = nil) {
            self.id = id
            self.mention = mention
        }
    }

    /// Client prompt request payload (`PromptInput`).
    // parity: schema/src/prompt-input.ts#Prompt [status=implemented hash=36414d5a37d1]
    public struct Prompt: Equatable, Hashable, Sendable, Codable {
        public let text: String
        public let files: [FileAttachment]?
        public let agents: [PromptSchema.AgentAttachment]?
        public let skills: [SkillAttachment]?

        public init(
            text: String,
            files: [FileAttachment]? = nil,
            agents: [PromptSchema.AgentAttachment]? = nil,
            skills: [SkillAttachment]? = nil
        ) {
            self.text = text
            self.files = files
            self.agents = agents
            self.skills = skills
        }
    }
}

// MARK: - SessionMessage (`src/session-message.ts`)

/// Projected session message and assistant content part schemas (`packages/schema/src/session-message.ts`).
public enum SessionMessageSchema {
    /// Timestamp container with a single `created` epoch-millisecond field.
    public struct TimeCreated: Equatable, Hashable, Sendable, Codable {
        public let created: Int64

        public init(created: Int64) {
            self.created = created
        }
    }

    /// Wire shell execution status matching `Shell.Status`.
    public enum ShellStatus: String, Equatable, Hashable, Sendable, Codable {
        case running
        case exited
        case timeout
        case killed
    }

    /// Wire shell output page matching `Shell.Output`.
    public struct ShellOutput: Equatable, Hashable, Sendable, Codable {
        public let output: String
        public let cursor: Int
        public let size: Int
        public let truncated: Bool

        public init(output: String, cursor: Int, size: Int, truncated: Bool) {
            self.output = output
            self.cursor = cursor
            self.size = size
            self.truncated = truncated
        }
    }

    /// Wire shell timing matching `Shell.Time`.
    public struct ShellTime: Equatable, Hashable, Sendable, Codable {
        public let started: Int64
        public let completed: Int64?

        public init(started: Int64, completed: Int64? = nil) {
            self.started = started
            self.completed = completed
        }
    }

    /// Wire shell info matching `Shell.Info`.
    public struct ShellInfo: Equatable, Hashable, Sendable, Codable {
        public let id: String
        public let status: ShellStatus
        public let command: String
        public let cwd: String
        public let shell: String
        public let file: String
        public let pid: Int?
        public let exit: Double?
        public let signal: String?
        public let metadata: [String: JSONValue]
        public let time: ShellTime

        public init(
            id: String,
            status: ShellStatus,
            command: String,
            cwd: String,
            shell: String,
            file: String,
            pid: Int? = nil,
            exit: Double? = nil,
            signal: String? = nil,
            metadata: [String: JSONValue] = [:],
            time: ShellTime
        ) {
            self.id = id
            self.status = status
            self.command = command
            self.cwd = cwd
            self.shell = shell
            self.file = file
            self.pid = pid
            self.exit = exit
            self.signal = signal
            self.metadata = metadata
            self.time = time
        }
    }

    /// Wire tool content part matching `Tool.Content` (`text` or `file`).
    public enum ToolContent: Equatable, Hashable, Sendable, Codable {
        case text(String)
        case file(uri: String, mime: String, name: String? = nil)

        public var typeTag: String {
            switch self {
            case .text: "text"
            case .file: "file"
            }
        }

        private enum CodingKeys: String, CodingKey {
            case type
            case text
            case uri
            case mime
            case name
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "text":
                let text = try container.decode(String.self, forKey: .text)
                self = .text(text)
            case "file":
                let uri = try container.decode(String.self, forKey: .uri)
                let mime = try container.decode(String.self, forKey: .mime)
                let name = try container.decodeIfPresent(String.self, forKey: .name)
                self = .file(uri: uri, mime: mime, name: name)
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .type,
                    in: container,
                    debugDescription: "Unknown Tool.Content type '\(type)'"
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let text):
                try container.encode("text", forKey: .type)
                try container.encode(text, forKey: .text)
            case .file(let uri, let mime, let name):
                try container.encode("file", forKey: .type)
                try container.encode(uri, forKey: .uri)
                try container.encode(mime, forKey: .mime)
                try container.encodeIfPresent(name, forKey: .name)
            }
        }
    }

    /// Wire LLM finish reason matching `LLM.FinishReason`.
    public enum FinishReason: String, Equatable, Hashable, Sendable, Codable {
        case stop
        case length
        case toolCalls = "tool-calls"
        case contentFilter = "content-filter"
        case error
        case unknown
    }

    /// Reason a compaction was triggered (`auto` or `manual`).
    public enum CompactionReason: String, Equatable, Hashable, Sendable, Codable {
        case auto
        case manual
    }

    /// Branded message identifier (`msg_<26 ascending chars>`, `Session.Message.ID`).
    // parity: schema/src/session-message.ts#ID [status=implemented hash=82dde93f309d]
    public struct ID: RawRepresentable, Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
        public let rawValue: String

        public init?(rawValue: String) {
            guard rawValue.hasPrefix("msg_") else { return nil }
            self.rawValue = rawValue
        }

        public init(validating value: String) throws(IdentifierValidationError) {
            guard value.hasPrefix("msg_") else {
                throw .invalidPrefix(expected: "msg_", actual: value)
            }
            self.rawValue = value
        }

        public static func create() -> ID {
            ID(unchecked: "msg_" + Identifier.ascending())
        }

        public static func fromEvent(_ eventID: String) throws(IdentifierValidationError) -> ID {
            let converted: String
            if eventID.hasPrefix("evt_") {
                converted = "msg_" + eventID.dropFirst(4)
            } else {
                converted = eventID
            }
            return try ID(validating: converted)
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

    /// Provider-owned replay data echoed back verbatim (`Session.Message.Native`).
    // parity: schema/src/session-message.ts#Native [status=implemented hash=98a48f4889fe]
    public typealias Native = [String: JSONValue]

    /// Agent switch message (`type: "agent-switched"`).
    // parity: schema/src/session-message.ts#AgentSelected [status=implemented hash=185b061017a8]
    public struct AgentSelected: Equatable, Hashable, Sendable, Codable {
        public static let typeTag = "agent-switched"

        public let id: ID
        public let metadata: [String: JSONValue]?
        public let time: TimeCreated
        public let agent: String
        public let previous: String?

        public init(
            id: ID,
            metadata: [String: JSONValue]? = nil,
            time: TimeCreated,
            agent: String,
            previous: String? = nil
        ) {
            self.id = id
            self.metadata = metadata
            self.time = time
            self.agent = agent
            self.previous = previous
        }

        private enum CodingKeys: String, CodingKey {
            case type
            case id
            case metadata
            case time
            case agent
            case previous
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let tag = try container.decode(String.self, forKey: .type)
            guard tag == Self.typeTag else {
                throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Expected type '\(Self.typeTag)', got '\(tag)'")
            }
            self.id = try container.decode(ID.self, forKey: .id)
            self.metadata = try container.decodeIfPresent([String: JSONValue].self, forKey: .metadata)
            self.time = try container.decode(TimeCreated.self, forKey: .time)
            self.agent = try container.decode(String.self, forKey: .agent)
            self.previous = try container.decodeIfPresent(String.self, forKey: .previous)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(Self.typeTag, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encodeIfPresent(metadata, forKey: .metadata)
            try container.encode(time, forKey: .time)
            try container.encode(agent, forKey: .agent)
            try container.encodeIfPresent(previous, forKey: .previous)
        }
    }

    /// Model switch message (`type: "model-switched"`).
    // parity: schema/src/session-message.ts#ModelSelected [status=implemented hash=9487efb901e6]
    public struct ModelSelected: Equatable, Hashable, Sendable, Codable {
        public static let typeTag = "model-switched"

        public let id: ID
        public let metadata: [String: JSONValue]?
        public let time: TimeCreated
        public let model: SessionSchema.ModelRef
        public let previous: SessionSchema.ModelRef?

        public init(
            id: ID,
            metadata: [String: JSONValue]? = nil,
            time: TimeCreated,
            model: SessionSchema.ModelRef,
            previous: SessionSchema.ModelRef? = nil
        ) {
            self.id = id
            self.metadata = metadata
            self.time = time
            self.model = model
            self.previous = previous
        }

        private enum CodingKeys: String, CodingKey {
            case type
            case id
            case metadata
            case time
            case model
            case previous
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let tag = try container.decode(String.self, forKey: .type)
            guard tag == Self.typeTag else {
                throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Expected type '\(Self.typeTag)', got '\(tag)'")
            }
            self.id = try container.decode(ID.self, forKey: .id)
            self.metadata = try container.decodeIfPresent([String: JSONValue].self, forKey: .metadata)
            self.time = try container.decode(TimeCreated.self, forKey: .time)
            self.model = try container.decode(SessionSchema.ModelRef.self, forKey: .model)
            self.previous = try container.decodeIfPresent(SessionSchema.ModelRef.self, forKey: .previous)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(Self.typeTag, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encodeIfPresent(metadata, forKey: .metadata)
            try container.encode(time, forKey: .time)
            try container.encode(model, forKey: .model)
            try container.encodeIfPresent(previous, forKey: .previous)
        }
    }

    /// Location switch message (`type: "location-switched"`).
    // parity: schema/src/session-message.ts#LocationSwitched [status=implemented hash=64fdac97f7f4]
    public struct LocationSwitched: Equatable, Hashable, Sendable, Codable {
        public static let typeTag = "location-switched"

        public struct Previous: Equatable, Hashable, Sendable, Codable {
            public let location: OpenCodeLocation
            public let projectID: ProjectID?
            public let subpath: String?

            public init(location: OpenCodeLocation, projectID: ProjectID? = nil, subpath: String? = nil) {
                self.location = location
                self.projectID = projectID
                self.subpath = subpath
            }
        }

        public let id: ID
        public let metadata: [String: JSONValue]?
        public let time: TimeCreated
        public let location: OpenCodeLocation
        public let projectID: ProjectID?
        public let subpath: String?
        public let previous: Previous?

        public init(
            id: ID,
            metadata: [String: JSONValue]? = nil,
            time: TimeCreated,
            location: OpenCodeLocation,
            projectID: ProjectID? = nil,
            subpath: String? = nil,
            previous: Previous? = nil
        ) {
            self.id = id
            self.metadata = metadata
            self.time = time
            self.location = location
            self.projectID = projectID
            self.subpath = subpath
            self.previous = previous
        }

        private enum CodingKeys: String, CodingKey {
            case type
            case id
            case metadata
            case time
            case location
            case projectID
            case subpath
            case previous
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let tag = try container.decode(String.self, forKey: .type)
            guard tag == Self.typeTag else {
                throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Expected type '\(Self.typeTag)', got '\(tag)'")
            }
            self.id = try container.decode(ID.self, forKey: .id)
            self.metadata = try container.decodeIfPresent([String: JSONValue].self, forKey: .metadata)
            self.time = try container.decode(TimeCreated.self, forKey: .time)
            self.location = try container.decode(OpenCodeLocation.self, forKey: .location)
            self.projectID = try container.decodeIfPresent(ProjectID.self, forKey: .projectID)
            self.subpath = try container.decodeIfPresent(String.self, forKey: .subpath)
            self.previous = try container.decodeIfPresent(Previous.self, forKey: .previous)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(Self.typeTag, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encodeIfPresent(metadata, forKey: .metadata)
            try container.encode(time, forKey: .time)
            try container.encode(location, forKey: .location)
            try container.encodeIfPresent(projectID, forKey: .projectID)
            try container.encodeIfPresent(subpath, forKey: .subpath)
            try container.encodeIfPresent(previous, forKey: .previous)
        }
    }

    /// User message (`type: "user"`).
    // parity: schema/src/session-message.ts#User [status=implemented hash=70ba30beba4f]
    public struct User: Equatable, Hashable, Sendable, Codable {
        public static let typeTag = "user"

        public let id: ID
        public let metadata: [String: JSONValue]?
        public let time: TimeCreated
        public let text: String
        public let files: [PromptSchema.FileAttachment]?
        public let agents: [PromptSchema.AgentAttachment]?
        public let skills: [PromptSchema.SkillAttachment]?

        public init(
            id: ID,
            metadata: [String: JSONValue]? = nil,
            time: TimeCreated,
            text: String,
            files: [PromptSchema.FileAttachment]? = nil,
            agents: [PromptSchema.AgentAttachment]? = nil,
            skills: [PromptSchema.SkillAttachment]? = nil
        ) {
            self.id = id
            self.metadata = metadata
            self.time = time
            self.text = text
            self.files = files
            self.agents = agents
            self.skills = skills
        }

        private enum CodingKeys: String, CodingKey {
            case type
            case id
            case metadata
            case time
            case text
            case files
            case agents
            case skills
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let tag = try container.decode(String.self, forKey: .type)
            guard tag == Self.typeTag else {
                throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Expected type '\(Self.typeTag)', got '\(tag)'")
            }
            self.id = try container.decode(ID.self, forKey: .id)
            self.metadata = try container.decodeIfPresent([String: JSONValue].self, forKey: .metadata)
            self.time = try container.decode(TimeCreated.self, forKey: .time)
            self.text = try container.decode(String.self, forKey: .text)
            self.files = try container.decodeIfPresent([PromptSchema.FileAttachment].self, forKey: .files)
            self.agents = try container.decodeIfPresent([PromptSchema.AgentAttachment].self, forKey: .agents)
            self.skills = try container.decodeIfPresent([PromptSchema.SkillAttachment].self, forKey: .skills)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(Self.typeTag, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encodeIfPresent(metadata, forKey: .metadata)
            try container.encode(time, forKey: .time)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(files, forKey: .files)
            try container.encodeIfPresent(agents, forKey: .agents)
            try container.encodeIfPresent(skills, forKey: .skills)
        }
    }

    /// User message whose attachments may stay on the server (`experimental-media-uri`).
    // parity: schema/src/session-message.ts#MediaUser [status=implemented hash=936b29ad025d]
    public struct MediaUser: Equatable, Hashable, Sendable, Codable {
        public static let typeTag = "user"

        public let id: ID
        public let metadata: [String: JSONValue]?
        public let time: TimeCreated
        public let text: String
        public let files: [PromptSchema.Attachment]?
        public let agents: [PromptSchema.AgentAttachment]?
        public let skills: [PromptSchema.SkillAttachment]?

        public init(
            id: ID,
            metadata: [String: JSONValue]? = nil,
            time: TimeCreated,
            text: String,
            files: [PromptSchema.Attachment]? = nil,
            agents: [PromptSchema.AgentAttachment]? = nil,
            skills: [PromptSchema.SkillAttachment]? = nil
        ) {
            self.id = id
            self.metadata = metadata
            self.time = time
            self.text = text
            self.files = files
            self.agents = agents
            self.skills = skills
        }

        private enum CodingKeys: String, CodingKey {
            case type
            case id
            case metadata
            case time
            case text
            case files
            case agents
            case skills
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let tag = try container.decode(String.self, forKey: .type)
            guard tag == Self.typeTag else {
                throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Expected type '\(Self.typeTag)', got '\(tag)'")
            }
            self.id = try container.decode(ID.self, forKey: .id)
            self.metadata = try container.decodeIfPresent([String: JSONValue].self, forKey: .metadata)
            self.time = try container.decode(TimeCreated.self, forKey: .time)
            self.text = try container.decode(String.self, forKey: .text)
            self.files = try container.decodeIfPresent([PromptSchema.Attachment].self, forKey: .files)
            self.agents = try container.decodeIfPresent([PromptSchema.AgentAttachment].self, forKey: .agents)
            self.skills = try container.decodeIfPresent([PromptSchema.SkillAttachment].self, forKey: .skills)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(Self.typeTag, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encodeIfPresent(metadata, forKey: .metadata)
            try container.encode(time, forKey: .time)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(files, forKey: .files)
            try container.encodeIfPresent(agents, forKey: .agents)
            try container.encodeIfPresent(skills, forKey: .skills)
        }
    }

    /// Synthetic message (`type: "synthetic"`).
    // parity: schema/src/session-message.ts#Synthetic [status=implemented hash=c27fd85e4a79]
    public struct Synthetic: Equatable, Hashable, Sendable, Codable {
        public static let typeTag = "synthetic"

        public let id: ID
        public let metadata: [String: JSONValue]?
        public let time: TimeCreated
        public let text: String
        public let description: String?

        public init(
            id: ID,
            metadata: [String: JSONValue]? = nil,
            time: TimeCreated,
            text: String,
            description: String? = nil
        ) {
            self.id = id
            self.metadata = metadata
            self.time = time
            self.text = text
            self.description = description
        }

        private enum CodingKeys: String, CodingKey {
            case type
            case id
            case metadata
            case time
            case text
            case description
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let tag = try container.decode(String.self, forKey: .type)
            guard tag == Self.typeTag else {
                throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Expected type '\(Self.typeTag)', got '\(tag)'")
            }
            self.id = try container.decode(ID.self, forKey: .id)
            self.metadata = try container.decodeIfPresent([String: JSONValue].self, forKey: .metadata)
            self.time = try container.decode(TimeCreated.self, forKey: .time)
            self.text = try container.decode(String.self, forKey: .text)
            self.description = try container.decodeIfPresent(String.self, forKey: .description)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(Self.typeTag, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encodeIfPresent(metadata, forKey: .metadata)
            try container.encode(time, forKey: .time)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(description, forKey: .description)
        }
    }

    /// System update message (`type: "system"`).
    // parity: schema/src/session-message.ts#System [status=implemented hash=8699ecb4ebb0]
    public struct System: Equatable, Hashable, Sendable, Codable {
        public static let typeTag = "system"

        public let id: ID
        public let metadata: [String: JSONValue]?
        public let time: TimeCreated
        public let text: String
        public let description: String?

        public init(
            id: ID,
            metadata: [String: JSONValue]? = nil,
            time: TimeCreated,
            text: String,
            description: String? = nil
        ) {
            self.id = id
            self.metadata = metadata
            self.time = time
            self.text = text
            self.description = description
        }

        private enum CodingKeys: String, CodingKey {
            case type
            case id
            case metadata
            case time
            case text
            case description
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let tag = try container.decode(String.self, forKey: .type)
            guard tag == Self.typeTag else {
                throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Expected type '\(Self.typeTag)', got '\(tag)'")
            }
            self.id = try container.decode(ID.self, forKey: .id)
            self.metadata = try container.decodeIfPresent([String: JSONValue].self, forKey: .metadata)
            self.time = try container.decode(TimeCreated.self, forKey: .time)
            self.text = try container.decode(String.self, forKey: .text)
            self.description = try container.decodeIfPresent(String.self, forKey: .description)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(Self.typeTag, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encodeIfPresent(metadata, forKey: .metadata)
            try container.encode(time, forKey: .time)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(description, forKey: .description)
        }
    }

    /// Skill activation message (`type: "skill"`).
    // parity: schema/src/session-message.ts#Skill [status=implemented hash=44382e1e0611]
    public struct Skill: Equatable, Hashable, Sendable, Codable {
        public static let typeTag = "skill"

        public let id: ID
        public let metadata: [String: JSONValue]?
        public let time: TimeCreated
        public let skill: String
        public let name: String
        public let text: String

        public init(
            id: ID,
            metadata: [String: JSONValue]? = nil,
            time: TimeCreated,
            skill: String,
            name: String,
            text: String
        ) {
            self.id = id
            self.metadata = metadata
            self.time = time
            self.skill = skill
            self.name = name
            self.text = text
        }

        private enum CodingKeys: String, CodingKey {
            case type
            case id
            case metadata
            case time
            case skill
            case name
            case text
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let tag = try container.decode(String.self, forKey: .type)
            guard tag == Self.typeTag else {
                throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Expected type '\(Self.typeTag)', got '\(tag)'")
            }
            self.id = try container.decode(ID.self, forKey: .id)
            self.metadata = try container.decodeIfPresent([String: JSONValue].self, forKey: .metadata)
            self.time = try container.decode(TimeCreated.self, forKey: .time)
            self.skill = try container.decode(String.self, forKey: .skill)
            self.name = try container.decode(String.self, forKey: .name)
            self.text = try container.decode(String.self, forKey: .text)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(Self.typeTag, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encodeIfPresent(metadata, forKey: .metadata)
            try container.encode(time, forKey: .time)
            try container.encode(skill, forKey: .skill)
            try container.encode(name, forKey: .name)
            try container.encode(text, forKey: .text)
        }
    }

    /// Shell execution message (`type: "shell"`).
    // parity: schema/src/session-message.ts#Shell [status=implemented hash=9b7d5f0065c4]
    public struct Shell: Equatable, Hashable, Sendable, Codable {
        public static let typeTag = "shell"

        public struct Time: Equatable, Hashable, Sendable, Codable {
            public let created: Int64
            public let completed: Int64?

            public init(created: Int64, completed: Int64? = nil) {
                self.created = created
                self.completed = completed
            }
        }

        public let id: ID
        public let metadata: [String: JSONValue]?
        public let shellID: String
        public let command: String
        public let status: ShellStatus
        public let exit: Double?
        public let output: ShellOutput?
        public let time: Time

        public init(
            id: ID,
            metadata: [String: JSONValue]? = nil,
            shellID: String,
            command: String,
            status: ShellStatus,
            exit: Double? = nil,
            output: ShellOutput? = nil,
            time: Time
        ) {
            self.id = id
            self.metadata = metadata
            self.shellID = shellID
            self.command = command
            self.status = status
            self.exit = exit
            self.output = output
            self.time = time
        }

        private enum CodingKeys: String, CodingKey {
            case type
            case id
            case metadata
            case shellID
            case command
            case status
            case exit
            case output
            case time
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let tag = try container.decode(String.self, forKey: .type)
            guard tag == Self.typeTag else {
                throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Expected type '\(Self.typeTag)', got '\(tag)'")
            }
            self.id = try container.decode(ID.self, forKey: .id)
            self.metadata = try container.decodeIfPresent([String: JSONValue].self, forKey: .metadata)
            self.shellID = try container.decode(String.self, forKey: .shellID)
            self.command = try container.decode(String.self, forKey: .command)
            self.status = try container.decode(ShellStatus.self, forKey: .status)
            self.exit = try container.decodeIfPresent(Double.self, forKey: .exit)
            self.output = try container.decodeIfPresent(ShellOutput.self, forKey: .output)
            self.time = try container.decode(Time.self, forKey: .time)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(Self.typeTag, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encodeIfPresent(metadata, forKey: .metadata)
            try container.encode(shellID, forKey: .shellID)
            try container.encode(command, forKey: .command)
            try container.encode(status, forKey: .status)
            try container.encodeIfPresent(exit, forKey: .exit)
            try container.encodeIfPresent(output, forKey: .output)
            try container.encode(time, forKey: .time)
        }
    }

    /// Tool state while raw JSON input is still streaming (`status: "streaming"`).
    // parity: schema/src/session-message.ts#ToolStateStreaming [status=implemented hash=6c7fcf1a1f07]
    public struct ToolStateStreaming: Equatable, Hashable, Sendable, Codable {
        public static let statusTag = "streaming"

        public let input: String

        public init(input: String) {
            self.input = input
        }

        private enum CodingKeys: String, CodingKey {
            case status
            case input
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let tag = try container.decode(String.self, forKey: .status)
            guard tag == Self.statusTag else {
                throw DecodingError.dataCorruptedError(forKey: .status, in: container, debugDescription: "Expected status '\(Self.statusTag)', got '\(tag)'")
            }
            self.input = try container.decode(String.self, forKey: .input)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(Self.statusTag, forKey: .status)
            try container.encode(input, forKey: .input)
        }
    }

    /// Tool state while executing (`status: "running"`).
    // parity: schema/src/session-message.ts#ToolStateRunning [status=implemented hash=736e7841a8c2]
    public struct ToolStateRunning: Equatable, Hashable, Sendable, Codable {
        public static let statusTag = "running"

        public let input: [String: JSONValue]
        public let metadata: [String: JSONValue]

        public init(input: [String: JSONValue], metadata: [String: JSONValue] = [:]) {
            self.input = input
            self.metadata = metadata
        }

        private enum CodingKeys: String, CodingKey {
            case status
            case input
            case metadata
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let tag = try container.decode(String.self, forKey: .status)
            guard tag == Self.statusTag else {
                throw DecodingError.dataCorruptedError(forKey: .status, in: container, debugDescription: "Expected status '\(Self.statusTag)', got '\(tag)'")
            }
            self.input = try container.decode([String: JSONValue].self, forKey: .input)
            self.metadata = try container.decode([String: JSONValue].self, forKey: .metadata)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(Self.statusTag, forKey: .status)
            try container.encode(input, forKey: .input)
            try container.encode(metadata, forKey: .metadata)
        }
    }

    /// Tool state after terminal success (`status: "completed"`).
    // parity: schema/src/session-message.ts#ToolStateCompleted [status=implemented hash=1215741113a5]
    public struct ToolStateCompleted: Equatable, Hashable, Sendable, Codable {
        public static let statusTag = "completed"

        public let input: [String: JSONValue]
        public let content: [ToolContent]
        public let metadata: [String: JSONValue]?

        public init(
            input: [String: JSONValue],
            content: [ToolContent],
            metadata: [String: JSONValue]? = nil
        ) {
            self.input = input
            self.content = content
            self.metadata = metadata
        }

        private enum CodingKeys: String, CodingKey {
            case status
            case input
            case content
            case metadata
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let tag = try container.decode(String.self, forKey: .status)
            guard tag == Self.statusTag else {
                throw DecodingError.dataCorruptedError(forKey: .status, in: container, debugDescription: "Expected status '\(Self.statusTag)', got '\(tag)'")
            }
            self.input = try container.decode([String: JSONValue].self, forKey: .input)
            let content = try container.decode([ToolContent].self, forKey: .content)
            guard !content.isEmpty else {
                throw DecodingError.dataCorruptedError(forKey: .content, in: container, debugDescription: "ToolStateCompleted.content must be non-empty")
            }
            self.content = content
            self.metadata = try container.decodeIfPresent([String: JSONValue].self, forKey: .metadata)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(Self.statusTag, forKey: .status)
            try container.encode(input, forKey: .input)
            try container.encode(content, forKey: .content)
            try container.encodeIfPresent(metadata, forKey: .metadata)
        }
    }

    /// Tool state after terminal failure (`status: "error"`).
    // parity: schema/src/session-message.ts#ToolStateError [status=implemented hash=67da4201a970]
    public struct ToolStateError: Equatable, Hashable, Sendable, Codable {
        public static let statusTag = "error"

        public let input: [String: JSONValue]
        public let error: SessionErrorSchema.Error
        public let content: [ToolContent]?
        public let metadata: [String: JSONValue]?

        public init(
            input: [String: JSONValue],
            error: SessionErrorSchema.Error,
            content: [ToolContent]? = nil,
            metadata: [String: JSONValue]? = nil
        ) {
            self.input = input
            self.error = error
            self.content = content
            self.metadata = metadata
        }

        private enum CodingKeys: String, CodingKey {
            case status
            case input
            case error
            case content
            case metadata
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let tag = try container.decode(String.self, forKey: .status)
            guard tag == Self.statusTag else {
                throw DecodingError.dataCorruptedError(forKey: .status, in: container, debugDescription: "Expected status '\(Self.statusTag)', got '\(tag)'")
            }
            self.input = try container.decode([String: JSONValue].self, forKey: .input)
            self.error = try container.decode(SessionErrorSchema.Error.self, forKey: .error)
            let content = try container.decodeIfPresent([ToolContent].self, forKey: .content)
            if let content, content.isEmpty {
                throw DecodingError.dataCorruptedError(forKey: .content, in: container, debugDescription: "ToolStateError.content must be non-empty when present")
            }
            self.content = content
            self.metadata = try container.decodeIfPresent([String: JSONValue].self, forKey: .metadata)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(Self.statusTag, forKey: .status)
            try container.encode(input, forKey: .input)
            try container.encode(error, forKey: .error)
            try container.encodeIfPresent(content, forKey: .content)
            try container.encodeIfPresent(metadata, forKey: .metadata)
        }
    }

    /// Discriminated union of tool lifecycle states (`status`).
    // parity: schema/src/session-message.ts#ToolState [status=implemented hash=1f2b963b54a1]
    public enum ToolState: Equatable, Hashable, Sendable, Codable {
        case streaming(ToolStateStreaming)
        case running(ToolStateRunning)
        case completed(ToolStateCompleted)
        case error(ToolStateError)

        public var statusTag: String {
            switch self {
            case .streaming: ToolStateStreaming.statusTag
            case .running: ToolStateRunning.statusTag
            case .completed: ToolStateCompleted.statusTag
            case .error: ToolStateError.statusTag
            }
        }

        private enum TagKeys: String, CodingKey {
            case status
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: TagKeys.self)
            let status = try container.decode(String.self, forKey: .status)
            switch status {
            case ToolStateStreaming.statusTag:
                self = .streaming(try ToolStateStreaming(from: decoder))
            case ToolStateRunning.statusTag:
                self = .running(try ToolStateRunning(from: decoder))
            case ToolStateCompleted.statusTag:
                self = .completed(try ToolStateCompleted(from: decoder))
            case ToolStateError.statusTag:
                self = .error(try ToolStateError(from: decoder))
            default:
                throw DecodingError.dataCorruptedError(forKey: .status, in: container, debugDescription: "Unknown ToolState status '\(status)'")
            }
        }

        public func encode(to encoder: Encoder) throws {
            switch self {
            case .streaming(let value): try value.encode(to: encoder)
            case .running(let value): try value.encode(to: encoder)
            case .completed(let value): try value.encode(to: encoder)
            case .error(let value): try value.encode(to: encoder)
            }
        }
    }

    /// Assistant tool call part (`type: "tool"`).
    // parity: schema/src/session-message.ts#AssistantTool [status=implemented hash=eb33ca04e146]
    public struct AssistantTool: Equatable, Hashable, Sendable, Codable {
        public static let typeTag = "tool"

        public struct Time: Equatable, Hashable, Sendable, Codable {
            public let created: Int64
            public let ran: Int64?
            public let completed: Int64?

            public init(created: Int64, ran: Int64? = nil, completed: Int64? = nil) {
                self.created = created
                self.ran = ran
                self.completed = completed
            }
        }

        public let id: String
        public let name: String
        public let executed: Bool?
        public let native: Native?
        public let state: ToolState
        public let time: Time

        public init(
            id: String,
            name: String,
            executed: Bool? = nil,
            native: Native? = nil,
            state: ToolState,
            time: Time
        ) {
            self.id = id
            self.name = name
            self.executed = executed
            self.native = native
            self.state = state
            self.time = time
        }

        private enum CodingKeys: String, CodingKey {
            case type
            case id
            case name
            case executed
            case native
            case state
            case time
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let tag = try container.decode(String.self, forKey: .type)
            guard tag == Self.typeTag else {
                throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Expected type '\(Self.typeTag)', got '\(tag)'")
            }
            self.id = try container.decode(String.self, forKey: .id)
            self.name = try container.decode(String.self, forKey: .name)
            self.executed = try container.decodeIfPresent(Bool.self, forKey: .executed)
            self.native = try container.decodeIfPresent(Native.self, forKey: .native)
            self.state = try container.decode(ToolState.self, forKey: .state)
            self.time = try container.decode(Time.self, forKey: .time)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(Self.typeTag, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            try container.encodeIfPresent(executed, forKey: .executed)
            try container.encodeIfPresent(native, forKey: .native)
            try container.encode(state, forKey: .state)
            try container.encode(time, forKey: .time)
        }
    }

    /// Assistant text content part (`type: "text"`).
    // parity: schema/src/session-message.ts#AssistantText [status=implemented hash=bf6e6a500950]
    public struct AssistantText: Equatable, Hashable, Sendable, Codable {
        public static let typeTag = "text"

        public let text: String
        public let native: Native?

        public init(text: String, native: Native? = nil) {
            self.text = text
            self.native = native
        }

        private enum CodingKeys: String, CodingKey {
            case type
            case text
            case native
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let tag = try container.decode(String.self, forKey: .type)
            guard tag == Self.typeTag else {
                throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Expected type '\(Self.typeTag)', got '\(tag)'")
            }
            self.text = try container.decode(String.self, forKey: .text)
            self.native = try container.decodeIfPresent(Native.self, forKey: .native)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(Self.typeTag, forKey: .type)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(native, forKey: .native)
        }
    }

    /// Assistant reasoning content part (`type: "reasoning"`).
    // parity: schema/src/session-message.ts#AssistantReasoning [status=implemented hash=48f1b2bb8f88]
    public struct AssistantReasoning: Equatable, Hashable, Sendable, Codable {
        public static let typeTag = "reasoning"

        public struct Time: Equatable, Hashable, Sendable, Codable {
            public let created: Int64
            public let completed: Int64?

            public init(created: Int64, completed: Int64? = nil) {
                self.created = created
                self.completed = completed
            }
        }

        public let text: String
        public let native: Native?
        public let time: Time?

        public init(text: String, native: Native? = nil, time: Time? = nil) {
            self.text = text
            self.native = native
            self.time = time
        }

        private enum CodingKeys: String, CodingKey {
            case type
            case text
            case native
            case time
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let tag = try container.decode(String.self, forKey: .type)
            guard tag == Self.typeTag else {
                throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Expected type '\(Self.typeTag)', got '\(tag)'")
            }
            self.text = try container.decode(String.self, forKey: .text)
            self.native = try container.decodeIfPresent(Native.self, forKey: .native)
            self.time = try container.decodeIfPresent(Time.self, forKey: .time)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(Self.typeTag, forKey: .type)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(native, forKey: .native)
            try container.encodeIfPresent(time, forKey: .time)
        }
    }

    /// Discriminated union of assistant content parts (`text`, `reasoning`, `tool`).
    // parity: schema/src/session-message.ts#AssistantContent [status=implemented hash=c68042393ff4]
    public enum AssistantContent: Equatable, Hashable, Sendable, Codable {
        case text(AssistantText)
        case reasoning(AssistantReasoning)
        case tool(AssistantTool)

        public var typeTag: String {
            switch self {
            case .text: AssistantText.typeTag
            case .reasoning: AssistantReasoning.typeTag
            case .tool: AssistantTool.typeTag
            }
        }

        private enum TagKeys: String, CodingKey {
            case type
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: TagKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case AssistantText.typeTag:
                self = .text(try AssistantText(from: decoder))
            case AssistantReasoning.typeTag:
                self = .reasoning(try AssistantReasoning(from: decoder))
            case AssistantTool.typeTag:
                self = .tool(try AssistantTool(from: decoder))
            default:
                throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown AssistantContent type '\(type)'")
            }
        }

        public func encode(to encoder: Encoder) throws {
            switch self {
            case .text(let value): try value.encode(to: encoder)
            case .reasoning(let value): try value.encode(to: encoder)
            case .tool(let value): try value.encode(to: encoder)
            }
        }
    }

    /// Wire-encoded form of `AssistantContent` (timestamps encoded as epoch milliseconds).
    // parity: schema/src/session-message.ts#AssistantContentEncoded [status=implemented hash=74ce41f814d8]
    public typealias AssistantContentEncoded = AssistantContent

    /// Scheduled retry information attached to an assistant step (`Session.Message.Assistant.Retry`).
    // parity: schema/src/session-message.ts#AssistantRetry [status=implemented hash=687e1a80df21]
    public struct AssistantRetry: Equatable, Hashable, Sendable, Codable {
        public let attempt: Int
        public let at: Int64
        public let error: SessionErrorSchema.Error

        public init(attempt: Int, at: Int64, error: SessionErrorSchema.Error) {
            self.attempt = attempt
            self.at = at
            self.error = error
        }

        private enum CodingKeys: String, CodingKey {
            case attempt
            case at
            case error
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let attempt = try container.decode(Int.self, forKey: .attempt)
            guard attempt > 0 else {
                throw DecodingError.dataCorruptedError(forKey: .attempt, in: container, debugDescription: "attempt must be positive")
            }
            self.attempt = attempt
            self.at = try container.decode(Int64.self, forKey: .at)
            self.error = try container.decode(SessionErrorSchema.Error.self, forKey: .error)
        }
    }

    /// Assistant step message (`type: "assistant"`).
    // parity: schema/src/session-message.ts#Assistant [status=implemented hash=affa4149c2a1]
    public struct Assistant: Equatable, Hashable, Sendable, Codable {
        public static let typeTag = "assistant"

        public struct Snapshot: Equatable, Hashable, Sendable, Codable {
            public let start: String?
            public let end: String?
            public let files: [String]?

            public init(start: String? = nil, end: String? = nil, files: [String]? = nil) {
                self.start = start
                self.end = end
                self.files = files
            }
        }

        public struct Time: Equatable, Hashable, Sendable, Codable {
            public let created: Int64
            public let firstToken: Int64?
            public let streamed: Int64?
            public let completed: Int64?

            public init(
                created: Int64,
                firstToken: Int64? = nil,
                streamed: Int64? = nil,
                completed: Int64? = nil
            ) {
                self.created = created
                self.firstToken = firstToken
                self.streamed = streamed
                self.completed = completed
            }
        }

        public let id: ID
        public let metadata: [String: JSONValue]?
        public let agent: String
        public let model: SessionSchema.ModelRef
        public let content: [AssistantContent]
        public let snapshot: Snapshot?
        public let finish: FinishReason?
        public let rawFinish: String?
        public let native: Native?
        public let cost: Double?
        public let tokens: SessionSchema.TokenUsage?
        public let error: SessionErrorSchema.Error?
        public let retry: AssistantRetry?
        public let time: Time

        public init(
            id: ID,
            metadata: [String: JSONValue]? = nil,
            agent: String,
            model: SessionSchema.ModelRef,
            content: [AssistantContent],
            snapshot: Snapshot? = nil,
            finish: FinishReason? = nil,
            rawFinish: String? = nil,
            native: Native? = nil,
            cost: Double? = nil,
            tokens: SessionSchema.TokenUsage? = nil,
            error: SessionErrorSchema.Error? = nil,
            retry: AssistantRetry? = nil,
            time: Time
        ) {
            self.id = id
            self.metadata = metadata
            self.agent = agent
            self.model = model
            self.content = content
            self.snapshot = snapshot
            self.finish = finish
            self.rawFinish = rawFinish
            self.native = native
            self.cost = cost
            self.tokens = tokens
            self.error = error
            self.retry = retry
            self.time = time
        }

        private enum CodingKeys: String, CodingKey {
            case type
            case id
            case metadata
            case agent
            case model
            case content
            case snapshot
            case finish
            case rawFinish
            case native
            case cost
            case tokens
            case error
            case retry
            case time
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let tag = try container.decode(String.self, forKey: .type)
            guard tag == Self.typeTag else {
                throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Expected type '\(Self.typeTag)', got '\(tag)'")
            }
            self.id = try container.decode(ID.self, forKey: .id)
            self.metadata = try container.decodeIfPresent([String: JSONValue].self, forKey: .metadata)
            self.agent = try container.decode(String.self, forKey: .agent)
            self.model = try container.decode(SessionSchema.ModelRef.self, forKey: .model)
            self.content = try container.decode([AssistantContent].self, forKey: .content)
            self.snapshot = try container.decodeIfPresent(Snapshot.self, forKey: .snapshot)
            self.finish = try container.decodeIfPresent(FinishReason.self, forKey: .finish)
            self.rawFinish = try container.decodeIfPresent(String.self, forKey: .rawFinish)
            self.native = try container.decodeIfPresent(Native.self, forKey: .native)
            self.cost = try container.decodeIfPresent(Double.self, forKey: .cost)
            self.tokens = try container.decodeIfPresent(SessionSchema.TokenUsage.self, forKey: .tokens)
            self.error = try container.decodeIfPresent(SessionErrorSchema.Error.self, forKey: .error)
            self.retry = try container.decodeIfPresent(AssistantRetry.self, forKey: .retry)
            self.time = try container.decode(Time.self, forKey: .time)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(Self.typeTag, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encodeIfPresent(metadata, forKey: .metadata)
            try container.encode(agent, forKey: .agent)
            try container.encode(model, forKey: .model)
            try container.encode(content, forKey: .content)
            try container.encodeIfPresent(snapshot, forKey: .snapshot)
            try container.encodeIfPresent(finish, forKey: .finish)
            try container.encodeIfPresent(rawFinish, forKey: .rawFinish)
            try container.encodeIfPresent(native, forKey: .native)
            try container.encodeIfPresent(cost, forKey: .cost)
            try container.encodeIfPresent(tokens, forKey: .tokens)
            try container.encodeIfPresent(error, forKey: .error)
            try container.encodeIfPresent(retry, forKey: .retry)
            try container.encode(time, forKey: .time)
        }
    }

    /// Running compaction message (`type: "compaction"`, `status: "running"`).
    // parity: schema/src/session-message.ts#CompactionRunning [status=implemented hash=e4813da9a24a]
    public struct CompactionRunning: Equatable, Hashable, Sendable, Codable {
        public static let typeTag = "compaction"
        public static let statusTag = "running"

        public let id: ID
        public let metadata: [String: JSONValue]?
        public let time: TimeCreated
        public let reason: CompactionReason
        public let summary: String

        public init(
            id: ID,
            metadata: [String: JSONValue]? = nil,
            time: TimeCreated,
            reason: CompactionReason,
            summary: String
        ) {
            self.id = id
            self.metadata = metadata
            self.time = time
            self.reason = reason
            self.summary = summary
        }

        private enum CodingKeys: String, CodingKey {
            case type
            case id
            case metadata
            case time
            case status
            case reason
            case summary
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            guard type == Self.typeTag else {
                throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Expected type '\(Self.typeTag)', got '\(type)'")
            }
            let status = try container.decode(String.self, forKey: .status)
            guard status == Self.statusTag else {
                throw DecodingError.dataCorruptedError(forKey: .status, in: container, debugDescription: "Expected status '\(Self.statusTag)', got '\(status)'")
            }
            self.id = try container.decode(ID.self, forKey: .id)
            self.metadata = try container.decodeIfPresent([String: JSONValue].self, forKey: .metadata)
            self.time = try container.decode(TimeCreated.self, forKey: .time)
            self.reason = try container.decode(CompactionReason.self, forKey: .reason)
            self.summary = try container.decode(String.self, forKey: .summary)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(Self.typeTag, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encodeIfPresent(metadata, forKey: .metadata)
            try container.encode(time, forKey: .time)
            try container.encode(Self.statusTag, forKey: .status)
            try container.encode(reason, forKey: .reason)
            try container.encode(summary, forKey: .summary)
        }
    }

    /// Completed compaction message (`type: "compaction"`, `status: "completed"`).
    // parity: schema/src/session-message.ts#CompactionCompleted [status=implemented hash=b062060a79cf]
    public struct CompactionCompleted: Equatable, Hashable, Sendable, Codable {
        public static let typeTag = "compaction"
        public static let statusTag = "completed"

        public let id: ID
        public let metadata: [String: JSONValue]?
        public let time: TimeCreated
        public let reason: CompactionReason
        public let model: SessionSchema.ModelRef?
        public let native: Native?
        public let summary: String
        public let cost: Double?
        public let tokens: SessionSchema.TokenUsage?

        public init(
            id: ID,
            metadata: [String: JSONValue]? = nil,
            time: TimeCreated,
            reason: CompactionReason,
            model: SessionSchema.ModelRef? = nil,
            native: Native? = nil,
            summary: String,
            cost: Double? = nil,
            tokens: SessionSchema.TokenUsage? = nil
        ) {
            self.id = id
            self.metadata = metadata
            self.time = time
            self.reason = reason
            self.model = model
            self.native = native
            self.summary = summary
            self.cost = cost
            self.tokens = tokens
        }

        private enum CodingKeys: String, CodingKey {
            case type
            case id
            case metadata
            case time
            case status
            case reason
            case model
            case native
            case summary
            case cost
            case tokens
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            guard type == Self.typeTag else {
                throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Expected type '\(Self.typeTag)', got '\(type)'")
            }
            let status = try container.decode(String.self, forKey: .status)
            guard status == Self.statusTag else {
                throw DecodingError.dataCorruptedError(forKey: .status, in: container, debugDescription: "Expected status '\(Self.statusTag)', got '\(status)'")
            }
            self.id = try container.decode(ID.self, forKey: .id)
            self.metadata = try container.decodeIfPresent([String: JSONValue].self, forKey: .metadata)
            self.time = try container.decode(TimeCreated.self, forKey: .time)
            self.reason = try container.decode(CompactionReason.self, forKey: .reason)
            self.model = try container.decodeIfPresent(SessionSchema.ModelRef.self, forKey: .model)
            self.native = try container.decodeIfPresent(Native.self, forKey: .native)
            self.summary = try container.decode(String.self, forKey: .summary)
            self.cost = try container.decodeIfPresent(Double.self, forKey: .cost)
            self.tokens = try container.decodeIfPresent(SessionSchema.TokenUsage.self, forKey: .tokens)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(Self.typeTag, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encodeIfPresent(metadata, forKey: .metadata)
            try container.encode(time, forKey: .time)
            try container.encode(Self.statusTag, forKey: .status)
            try container.encode(reason, forKey: .reason)
            try container.encodeIfPresent(model, forKey: .model)
            try container.encodeIfPresent(native, forKey: .native)
            try container.encode(summary, forKey: .summary)
            try container.encodeIfPresent(cost, forKey: .cost)
            try container.encodeIfPresent(tokens, forKey: .tokens)
        }
    }

    /// Failed compaction message (`type: "compaction"`, `status: "failed"`).
    // parity: schema/src/session-message.ts#CompactionFailed [status=implemented hash=b0d575a512d2]
    public struct CompactionFailed: Equatable, Hashable, Sendable, Codable {
        public static let typeTag = "compaction"
        public static let statusTag = "failed"

        public let id: ID
        public let metadata: [String: JSONValue]?
        public let time: TimeCreated
        public let reason: CompactionReason
        public let error: SessionErrorSchema.Error
        public let cost: Double?
        public let tokens: SessionSchema.TokenUsage?

        public init(
            id: ID,
            metadata: [String: JSONValue]? = nil,
            time: TimeCreated,
            reason: CompactionReason,
            error: SessionErrorSchema.Error,
            cost: Double? = nil,
            tokens: SessionSchema.TokenUsage? = nil
        ) {
            self.id = id
            self.metadata = metadata
            self.time = time
            self.reason = reason
            self.error = error
            self.cost = cost
            self.tokens = tokens
        }

        private enum CodingKeys: String, CodingKey {
            case type
            case id
            case metadata
            case time
            case status
            case reason
            case error
            case cost
            case tokens
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            guard type == Self.typeTag else {
                throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Expected type '\(Self.typeTag)', got '\(type)'")
            }
            let status = try container.decode(String.self, forKey: .status)
            guard status == Self.statusTag else {
                throw DecodingError.dataCorruptedError(forKey: .status, in: container, debugDescription: "Expected status '\(Self.statusTag)', got '\(status)'")
            }
            self.id = try container.decode(ID.self, forKey: .id)
            self.metadata = try container.decodeIfPresent([String: JSONValue].self, forKey: .metadata)
            self.time = try container.decode(TimeCreated.self, forKey: .time)
            self.reason = try container.decode(CompactionReason.self, forKey: .reason)
            self.error = try container.decode(SessionErrorSchema.Error.self, forKey: .error)
            self.cost = try container.decodeIfPresent(Double.self, forKey: .cost)
            self.tokens = try container.decodeIfPresent(SessionSchema.TokenUsage.self, forKey: .tokens)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(Self.typeTag, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encodeIfPresent(metadata, forKey: .metadata)
            try container.encode(time, forKey: .time)
            try container.encode(Self.statusTag, forKey: .status)
            try container.encode(reason, forKey: .reason)
            try container.encode(error, forKey: .error)
            try container.encodeIfPresent(cost, forKey: .cost)
            try container.encodeIfPresent(tokens, forKey: .tokens)
        }
    }

    /// Discriminated union of compaction messages (`status`: `running`, `completed`, `failed`).
    // parity: schema/src/session-message.ts#Compaction [status=implemented hash=c8d646c01e3c]
    public enum Compaction: Equatable, Hashable, Sendable, Codable {
        case running(CompactionRunning)
        case completed(CompactionCompleted)
        case failed(CompactionFailed)

        public var id: ID {
            switch self {
            case .running(let value): value.id
            case .completed(let value): value.id
            case .failed(let value): value.id
            }
        }

        public var statusTag: String {
            switch self {
            case .running: CompactionRunning.statusTag
            case .completed: CompactionCompleted.statusTag
            case .failed: CompactionFailed.statusTag
            }
        }

        private enum TagKeys: String, CodingKey {
            case status
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: TagKeys.self)
            let status = try container.decode(String.self, forKey: .status)
            switch status {
            case CompactionRunning.statusTag:
                self = .running(try CompactionRunning(from: decoder))
            case CompactionCompleted.statusTag:
                self = .completed(try CompactionCompleted(from: decoder))
            case CompactionFailed.statusTag:
                self = .failed(try CompactionFailed(from: decoder))
            default:
                throw DecodingError.dataCorruptedError(forKey: .status, in: container, debugDescription: "Unknown Compaction status '\(status)'")
            }
        }

        public func encode(to encoder: Encoder) throws {
            switch self {
            case .running(let value): try value.encode(to: encoder)
            case .completed(let value): try value.encode(to: encoder)
            case .failed(let value): try value.encode(to: encoder)
            }
        }
    }

    /// Turn completion marker (`type: "idle"`).
    // parity: schema/src/session-message.ts#Idle [status=implemented hash=5e81fd4ed1b1]
    public struct Idle: Equatable, Hashable, Sendable, Codable {
        public static let typeTag = "idle"

        public let id: ID
        public let metadata: [String: JSONValue]?
        public let time: TimeCreated
        public let outcome: SessionSchema.Outcome
        public let error: SessionErrorSchema.Error?

        public init(
            id: ID,
            metadata: [String: JSONValue]? = nil,
            time: TimeCreated,
            outcome: SessionSchema.Outcome,
            error: SessionErrorSchema.Error? = nil
        ) {
            self.id = id
            self.metadata = metadata
            self.time = time
            self.outcome = outcome
            self.error = error
        }

        private enum CodingKeys: String, CodingKey {
            case type
            case id
            case metadata
            case time
            case outcome
            case error
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let tag = try container.decode(String.self, forKey: .type)
            guard tag == Self.typeTag else {
                throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Expected type '\(Self.typeTag)', got '\(tag)'")
            }
            self.id = try container.decode(ID.self, forKey: .id)
            self.metadata = try container.decodeIfPresent([String: JSONValue].self, forKey: .metadata)
            self.time = try container.decode(TimeCreated.self, forKey: .time)
            self.outcome = try container.decode(SessionSchema.Outcome.self, forKey: .outcome)
            self.error = try container.decodeIfPresent(SessionErrorSchema.Error.self, forKey: .error)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(Self.typeTag, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encodeIfPresent(metadata, forKey: .metadata)
            try container.encode(time, forKey: .time)
            try container.encode(outcome, forKey: .outcome)
            try container.encodeIfPresent(error, forKey: .error)
        }
    }

    /// Discriminator tag union for `SessionMessage.Info` (`SessionMessage.Type`).
    // parity: schema/src/session-message.ts#Type [status=implemented hash=4023b9fc7aeb]
    public enum MessageType: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
        case agentSelected = "agent-switched"
        case modelSelected = "model-switched"
        case locationSwitched = "location-switched"
        case user
        case synthetic
        case system
        case skill
        case shell
        case assistant
        case compaction
        case idle
    }

    /// Canonical projected session message union (`Session.Message.Info`).
    // parity: schema/src/session-message.ts#Info [status=implemented hash=b4d8cc5306e4]
    public enum Info: Equatable, Hashable, Sendable, Codable {
        case agentSelected(AgentSelected)
        case modelSelected(ModelSelected)
        case locationSwitched(LocationSwitched)
        case user(User)
        case synthetic(Synthetic)
        case system(System)
        case skill(Skill)
        case shell(Shell)
        case assistant(Assistant)
        case compaction(Compaction)
        case idle(Idle)

        public var messageType: MessageType {
            switch self {
            case .agentSelected: .agentSelected
            case .modelSelected: .modelSelected
            case .locationSwitched: .locationSwitched
            case .user: .user
            case .synthetic: .synthetic
            case .system: .system
            case .skill: .skill
            case .shell: .shell
            case .assistant: .assistant
            case .compaction: .compaction
            case .idle: .idle
            }
        }

        public var id: ID {
            switch self {
            case .agentSelected(let value): value.id
            case .modelSelected(let value): value.id
            case .locationSwitched(let value): value.id
            case .user(let value): value.id
            case .synthetic(let value): value.id
            case .system(let value): value.id
            case .skill(let value): value.id
            case .shell(let value): value.id
            case .assistant(let value): value.id
            case .compaction(let value): value.id
            case .idle(let value): value.id
            }
        }

        private enum TagKeys: String, CodingKey {
            case type
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: TagKeys.self)
            let type = try container.decode(MessageType.self, forKey: .type)
            switch type {
            case .agentSelected: self = .agentSelected(try AgentSelected(from: decoder))
            case .modelSelected: self = .modelSelected(try ModelSelected(from: decoder))
            case .locationSwitched: self = .locationSwitched(try LocationSwitched(from: decoder))
            case .user: self = .user(try User(from: decoder))
            case .synthetic: self = .synthetic(try Synthetic(from: decoder))
            case .system: self = .system(try System(from: decoder))
            case .skill: self = .skill(try Skill(from: decoder))
            case .shell: self = .shell(try Shell(from: decoder))
            case .assistant: self = .assistant(try Assistant(from: decoder))
            case .compaction: self = .compaction(try Compaction(from: decoder))
            case .idle: self = .idle(try Idle(from: decoder))
            }
        }

        public func encode(to encoder: Encoder) throws {
            switch self {
            case .agentSelected(let value): try value.encode(to: encoder)
            case .modelSelected(let value): try value.encode(to: encoder)
            case .locationSwitched(let value): try value.encode(to: encoder)
            case .user(let value): try value.encode(to: encoder)
            case .synthetic(let value): try value.encode(to: encoder)
            case .system(let value): try value.encode(to: encoder)
            case .skill(let value): try value.encode(to: encoder)
            case .shell(let value): try value.encode(to: encoder)
            case .assistant(let value): try value.encode(to: encoder)
            case .compaction(let value): try value.encode(to: encoder)
            case .idle(let value): try value.encode(to: encoder)
            }
        }
    }

    /// Projected session message union supporting `experimental-media-uri` user attachments (`Session.Message.MediaInfo`).
    // parity: schema/src/session-message.ts#MediaInfo [status=implemented hash=e043655f5b0a]
    public enum MediaInfo: Equatable, Hashable, Sendable, Codable {
        case agentSelected(AgentSelected)
        case modelSelected(ModelSelected)
        case locationSwitched(LocationSwitched)
        case user(MediaUser)
        case synthetic(Synthetic)
        case system(System)
        case skill(Skill)
        case shell(Shell)
        case assistant(Assistant)
        case compaction(Compaction)
        case idle(Idle)

        public var messageType: MessageType {
            switch self {
            case .agentSelected: .agentSelected
            case .modelSelected: .modelSelected
            case .locationSwitched: .locationSwitched
            case .user: .user
            case .synthetic: .synthetic
            case .system: .system
            case .skill: .skill
            case .shell: .shell
            case .assistant: .assistant
            case .compaction: .compaction
            case .idle: .idle
            }
        }

        public var id: ID {
            switch self {
            case .agentSelected(let value): value.id
            case .modelSelected(let value): value.id
            case .locationSwitched(let value): value.id
            case .user(let value): value.id
            case .synthetic(let value): value.id
            case .system(let value): value.id
            case .skill(let value): value.id
            case .shell(let value): value.id
            case .assistant(let value): value.id
            case .compaction(let value): value.id
            case .idle(let value): value.id
            }
        }

        private enum TagKeys: String, CodingKey {
            case type
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: TagKeys.self)
            let type = try container.decode(MessageType.self, forKey: .type)
            switch type {
            case .agentSelected: self = .agentSelected(try AgentSelected(from: decoder))
            case .modelSelected: self = .modelSelected(try ModelSelected(from: decoder))
            case .locationSwitched: self = .locationSwitched(try LocationSwitched(from: decoder))
            case .user: self = .user(try MediaUser(from: decoder))
            case .synthetic: self = .synthetic(try Synthetic(from: decoder))
            case .system: self = .system(try System(from: decoder))
            case .skill: self = .skill(try Skill(from: decoder))
            case .shell: self = .shell(try Shell(from: decoder))
            case .assistant: self = .assistant(try Assistant(from: decoder))
            case .compaction: self = .compaction(try Compaction(from: decoder))
            case .idle: self = .idle(try Idle(from: decoder))
            }
        }

        public func encode(to encoder: Encoder) throws {
            switch self {
            case .agentSelected(let value): try value.encode(to: encoder)
            case .modelSelected(let value): try value.encode(to: encoder)
            case .locationSwitched(let value): try value.encode(to: encoder)
            case .user(let value): try value.encode(to: encoder)
            case .synthetic(let value): try value.encode(to: encoder)
            case .system(let value): try value.encode(to: encoder)
            case .skill(let value): try value.encode(to: encoder)
            case .shell(let value): try value.encode(to: encoder)
            case .assistant(let value): try value.encode(to: encoder)
            case .compaction(let value): try value.encode(to: encoder)
            case .idle(let value): try value.encode(to: encoder)
            }
        }
    }
}

// MARK: - SessionInbox (`src/session-inbox.ts`)

/// Durable session inbox items, payloads, and delivery modes (`packages/schema/src/session-inbox.ts`).
public enum SessionInboxSchema {
    /// Inbox item delivery scheduling mode (`Session.Inbox.Delivery`).
    // parity: schema/src/session-inbox.ts#Delivery [status=implemented hash=4583be2de0b9]
    public enum Delivery: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
        case steer
        case queue
    }

    /// User prompt inbox payload (`Session.Inbox.UserPayload`).
    // parity: schema/src/session-inbox.ts#UserPayload [status=implemented hash=1ea4cb6f92a0]
    public struct UserPayload: Equatable, Hashable, Sendable, Codable {
        public let text: String
        public let files: [PromptSchema.FileAttachment]?
        public let agents: [PromptSchema.AgentAttachment]?
        public let skills: [PromptSchema.SkillAttachment]?
        public let metadata: [String: JSONValue]?

        public init(
            text: String,
            files: [PromptSchema.FileAttachment]? = nil,
            agents: [PromptSchema.AgentAttachment]? = nil,
            skills: [PromptSchema.SkillAttachment]? = nil,
            metadata: [String: JSONValue]? = nil
        ) {
            self.text = text
            self.files = files
            self.agents = agents
            self.skills = skills
            self.metadata = metadata
        }
    }

    /// User prompt inbox payload with optional server-stored media attachments (`Session.Inbox.MediaUserPayload`).
    // parity: schema/src/session-inbox.ts#MediaUserPayload [status=implemented hash=89c025578441]
    public struct MediaUserPayload: Equatable, Hashable, Sendable, Codable {
        public let text: String
        public let files: [PromptSchema.Attachment]?
        public let agents: [PromptSchema.AgentAttachment]?
        public let skills: [PromptSchema.SkillAttachment]?
        public let metadata: [String: JSONValue]?

        public init(
            text: String,
            files: [PromptSchema.Attachment]? = nil,
            agents: [PromptSchema.AgentAttachment]? = nil,
            skills: [PromptSchema.SkillAttachment]? = nil,
            metadata: [String: JSONValue]? = nil
        ) {
            self.text = text
            self.files = files
            self.agents = agents
            self.skills = skills
            self.metadata = metadata
        }
    }

    /// Synthetic message inbox payload (`Session.Inbox.SyntheticPayload`).
    // parity: schema/src/session-inbox.ts#SyntheticPayload [status=implemented hash=2cb66ccba0a2]
    public struct SyntheticPayload: Equatable, Hashable, Sendable, Codable {
        public let text: String
        public let description: String?
        public let metadata: [String: JSONValue]?

        public init(text: String, description: String? = nil, metadata: [String: JSONValue]? = nil) {
            self.text = text
            self.description = description
            self.metadata = metadata
        }
    }

    /// Compaction control inbox payload (`Session.Inbox.CompactionPayload`).
    // parity: schema/src/session-inbox.ts#CompactionPayload [status=implemented hash=3b420902b52f]
    public struct CompactionPayload: Equatable, Hashable, Sendable, Codable {
        public init() {}
    }

    /// Session location move control payload (`Session.Inbox.MovePayload`).
    // parity: schema/src/session-inbox.ts#MovePayload [status=implemented hash=f548be4b7fcb]
    public struct MovePayload: Equatable, Hashable, Sendable, Codable {
        public let location: OpenCodeLocation
        public let projectID: ProjectID
        public let subpath: String?

        public init(location: OpenCodeLocation, projectID: ProjectID, subpath: String? = nil) {
            self.location = location
            self.projectID = projectID
            self.subpath = subpath
        }
    }

    /// Unenqueued inbox item union (`Session.Inbox.Item`).
    // parity: schema/src/session-inbox.ts#Item [status=implemented hash=46637bf404e8]
    public enum Item: Equatable, Hashable, Sendable, Codable {
        case user(payload: UserPayload, delivery: Delivery)
        case synthetic(payload: SyntheticPayload, delivery: Delivery)
        case compaction(payload: CompactionPayload, delivery: Delivery)
        case move(payload: MovePayload, delivery: Delivery)

        public var typeTag: String {
            switch self {
            case .user: "user"
            case .synthetic: "synthetic"
            case .compaction: "compaction"
            case .move: "move"
            }
        }

        public var delivery: Delivery {
            switch self {
            case .user(_, let delivery),
                 .synthetic(_, let delivery),
                 .compaction(_, let delivery),
                 .move(_, let delivery):
                delivery
            }
        }

        private enum CodingKeys: String, CodingKey {
            case type
            case payload
            case delivery
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            let delivery = try container.decode(Delivery.self, forKey: .delivery)
            switch type {
            case "user":
                self = .user(payload: try container.decode(UserPayload.self, forKey: .payload), delivery: delivery)
            case "synthetic":
                self = .synthetic(payload: try container.decode(SyntheticPayload.self, forKey: .payload), delivery: delivery)
            case "compaction":
                self = .compaction(payload: try container.decode(CompactionPayload.self, forKey: .payload), delivery: delivery)
            case "move":
                self = .move(payload: try container.decode(MovePayload.self, forKey: .payload), delivery: delivery)
            default:
                throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown Session.Inbox.Item type '\(type)'")
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .user(let payload, let delivery):
                try container.encode("user", forKey: .type)
                try container.encode(payload, forKey: .payload)
                try container.encode(delivery, forKey: .delivery)
            case .synthetic(let payload, let delivery):
                try container.encode("synthetic", forKey: .type)
                try container.encode(payload, forKey: .payload)
                try container.encode(delivery, forKey: .delivery)
            case .compaction(let payload, let delivery):
                try container.encode("compaction", forKey: .type)
                try container.encode(payload, forKey: .payload)
                try container.encode(delivery, forKey: .delivery)
            case .move(let payload, let delivery):
                try container.encode("move", forKey: .type)
                try container.encode(payload, forKey: .payload)
                try container.encode(delivery, forKey: .delivery)
            }
        }
    }

    /// Enqueued user inbox record (`Session.Inbox.User`).
    // parity: schema/src/session-inbox.ts#User [status=implemented hash=70ba30beba4f]
    public struct User: Equatable, Hashable, Sendable, Codable {
        public static let typeTag = "user"

        public let id: SessionMessageSchema.ID
        public let sessionID: SessionID
        public let time: SessionMessageSchema.TimeCreated
        public let payload: UserPayload
        public let delivery: Delivery

        public init(
            id: SessionMessageSchema.ID,
            sessionID: SessionID,
            time: SessionMessageSchema.TimeCreated,
            payload: UserPayload,
            delivery: Delivery
        ) {
            self.id = id
            self.sessionID = sessionID
            self.time = time
            self.payload = payload
            self.delivery = delivery
        }

        private enum CodingKeys: String, CodingKey {
            case id
            case sessionID
            case time
            case type
            case payload
            case delivery
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            guard type == Self.typeTag else {
                throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Expected type '\(Self.typeTag)', got '\(type)'")
            }
            self.id = try container.decode(SessionMessageSchema.ID.self, forKey: .id)
            self.sessionID = try container.decode(SessionID.self, forKey: .sessionID)
            self.time = try container.decode(SessionMessageSchema.TimeCreated.self, forKey: .time)
            self.payload = try container.decode(UserPayload.self, forKey: .payload)
            self.delivery = try container.decode(Delivery.self, forKey: .delivery)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(sessionID, forKey: .sessionID)
            try container.encode(time, forKey: .time)
            try container.encode(Self.typeTag, forKey: .type)
            try container.encode(payload, forKey: .payload)
            try container.encode(delivery, forKey: .delivery)
        }
    }

    /// Enqueued user inbox record supporting `experimental-media-uri` (`Session.Inbox.MediaUser`).
    // parity: schema/src/session-inbox.ts#MediaUser [status=implemented hash=936b29ad025d]
    public struct MediaUser: Equatable, Hashable, Sendable, Codable {
        public static let typeTag = "user"

        public let id: SessionMessageSchema.ID
        public let sessionID: SessionID
        public let time: SessionMessageSchema.TimeCreated
        public let payload: MediaUserPayload
        public let delivery: Delivery

        public init(
            id: SessionMessageSchema.ID,
            sessionID: SessionID,
            time: SessionMessageSchema.TimeCreated,
            payload: MediaUserPayload,
            delivery: Delivery
        ) {
            self.id = id
            self.sessionID = sessionID
            self.time = time
            self.payload = payload
            self.delivery = delivery
        }

        private enum CodingKeys: String, CodingKey {
            case id
            case sessionID
            case time
            case type
            case payload
            case delivery
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            guard type == Self.typeTag else {
                throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Expected type '\(Self.typeTag)', got '\(type)'")
            }
            self.id = try container.decode(SessionMessageSchema.ID.self, forKey: .id)
            self.sessionID = try container.decode(SessionID.self, forKey: .sessionID)
            self.time = try container.decode(SessionMessageSchema.TimeCreated.self, forKey: .time)
            self.payload = try container.decode(MediaUserPayload.self, forKey: .payload)
            self.delivery = try container.decode(Delivery.self, forKey: .delivery)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(sessionID, forKey: .sessionID)
            try container.encode(time, forKey: .time)
            try container.encode(Self.typeTag, forKey: .type)
            try container.encode(payload, forKey: .payload)
            try container.encode(delivery, forKey: .delivery)
        }
    }

    /// Enqueued synthetic inbox record (`Session.Inbox.Synthetic`).
    // parity: schema/src/session-inbox.ts#Synthetic [status=implemented hash=c27fd85e4a79]
    public struct Synthetic: Equatable, Hashable, Sendable, Codable {
        public static let typeTag = "synthetic"

        public let id: SessionMessageSchema.ID
        public let sessionID: SessionID
        public let time: SessionMessageSchema.TimeCreated
        public let payload: SyntheticPayload
        public let delivery: Delivery

        public init(
            id: SessionMessageSchema.ID,
            sessionID: SessionID,
            time: SessionMessageSchema.TimeCreated,
            payload: SyntheticPayload,
            delivery: Delivery
        ) {
            self.id = id
            self.sessionID = sessionID
            self.time = time
            self.payload = payload
            self.delivery = delivery
        }

        private enum CodingKeys: String, CodingKey {
            case id
            case sessionID
            case time
            case type
            case payload
            case delivery
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            guard type == Self.typeTag else {
                throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Expected type '\(Self.typeTag)', got '\(type)'")
            }
            self.id = try container.decode(SessionMessageSchema.ID.self, forKey: .id)
            self.sessionID = try container.decode(SessionID.self, forKey: .sessionID)
            self.time = try container.decode(SessionMessageSchema.TimeCreated.self, forKey: .time)
            self.payload = try container.decode(SyntheticPayload.self, forKey: .payload)
            self.delivery = try container.decode(Delivery.self, forKey: .delivery)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(sessionID, forKey: .sessionID)
            try container.encode(time, forKey: .time)
            try container.encode(Self.typeTag, forKey: .type)
            try container.encode(payload, forKey: .payload)
            try container.encode(delivery, forKey: .delivery)
        }
    }

    /// Enqueued compaction control inbox record (`Session.Inbox.Compaction`).
    // parity: schema/src/session-inbox.ts#Compaction [status=implemented hash=0b5cdb34b0b3]
    public struct Compaction: Equatable, Hashable, Sendable, Codable {
        public static let typeTag = "compaction"

        public let id: SessionMessageSchema.ID
        public let sessionID: SessionID
        public let time: SessionMessageSchema.TimeCreated
        public let payload: CompactionPayload
        public let delivery: Delivery

        public init(
            id: SessionMessageSchema.ID,
            sessionID: SessionID,
            time: SessionMessageSchema.TimeCreated,
            payload: CompactionPayload = CompactionPayload(),
            delivery: Delivery
        ) {
            self.id = id
            self.sessionID = sessionID
            self.time = time
            self.payload = payload
            self.delivery = delivery
        }

        private enum CodingKeys: String, CodingKey {
            case id
            case sessionID
            case time
            case type
            case payload
            case delivery
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            guard type == Self.typeTag else {
                throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Expected type '\(Self.typeTag)', got '\(type)'")
            }
            self.id = try container.decode(SessionMessageSchema.ID.self, forKey: .id)
            self.sessionID = try container.decode(SessionID.self, forKey: .sessionID)
            self.time = try container.decode(SessionMessageSchema.TimeCreated.self, forKey: .time)
            self.payload = try container.decode(CompactionPayload.self, forKey: .payload)
            self.delivery = try container.decode(Delivery.self, forKey: .delivery)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(sessionID, forKey: .sessionID)
            try container.encode(time, forKey: .time)
            try container.encode(Self.typeTag, forKey: .type)
            try container.encode(payload, forKey: .payload)
            try container.encode(delivery, forKey: .delivery)
        }
    }

    /// Enqueued move control inbox record (`Session.Inbox.Move`).
    // parity: schema/src/session-inbox.ts#Move [status=implemented hash=e8ea58a842d1]
    public struct Move: Equatable, Hashable, Sendable, Codable {
        public static let typeTag = "move"

        public let id: SessionMessageSchema.ID
        public let sessionID: SessionID
        public let time: SessionMessageSchema.TimeCreated
        public let payload: MovePayload
        public let delivery: Delivery

        public init(
            id: SessionMessageSchema.ID,
            sessionID: SessionID,
            time: SessionMessageSchema.TimeCreated,
            payload: MovePayload,
            delivery: Delivery
        ) {
            self.id = id
            self.sessionID = sessionID
            self.time = time
            self.payload = payload
            self.delivery = delivery
        }

        private enum CodingKeys: String, CodingKey {
            case id
            case sessionID
            case time
            case type
            case payload
            case delivery
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            guard type == Self.typeTag else {
                throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Expected type '\(Self.typeTag)', got '\(type)'")
            }
            self.id = try container.decode(SessionMessageSchema.ID.self, forKey: .id)
            self.sessionID = try container.decode(SessionID.self, forKey: .sessionID)
            self.time = try container.decode(SessionMessageSchema.TimeCreated.self, forKey: .time)
            self.payload = try container.decode(MovePayload.self, forKey: .payload)
            self.delivery = try container.decode(Delivery.self, forKey: .delivery)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(sessionID, forKey: .sessionID)
            try container.encode(time, forKey: .time)
            try container.encode(Self.typeTag, forKey: .type)
            try container.encode(payload, forKey: .payload)
            try container.encode(delivery, forKey: .delivery)
        }
    }

    /// Discriminated union of enqueued inbox records (`Session.Inbox.Info`).
    // parity: schema/src/session-inbox.ts#Info [status=implemented hash=e971c7c3ff62]
    public enum Info: Equatable, Hashable, Sendable, Codable {
        case user(User)
        case synthetic(Synthetic)
        case compaction(Compaction)
        case move(Move)

        public var id: SessionMessageSchema.ID {
            switch self {
            case .user(let value): value.id
            case .synthetic(let value): value.id
            case .compaction(let value): value.id
            case .move(let value): value.id
            }
        }

        public var delivery: Delivery {
            switch self {
            case .user(let value): value.delivery
            case .synthetic(let value): value.delivery
            case .compaction(let value): value.delivery
            case .move(let value): value.delivery
            }
        }

        private enum TagKeys: String, CodingKey {
            case type
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: TagKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case User.typeTag: self = .user(try User(from: decoder))
            case Synthetic.typeTag: self = .synthetic(try Synthetic(from: decoder))
            case Compaction.typeTag: self = .compaction(try Compaction(from: decoder))
            case Move.typeTag: self = .move(try Move(from: decoder))
            default:
                throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown Session.Inbox.Info type '\(type)'")
            }
        }

        public func encode(to encoder: Encoder) throws {
            switch self {
            case .user(let value): try value.encode(to: encoder)
            case .synthetic(let value): try value.encode(to: encoder)
            case .compaction(let value): try value.encode(to: encoder)
            case .move(let value): try value.encode(to: encoder)
            }
        }
    }

    /// Discriminated union of enqueued inbox records supporting `experimental-media-uri` (`Session.Inbox.MediaInfo`).
    // parity: schema/src/session-inbox.ts#MediaInfo [status=implemented hash=71df6abbe038]
    public enum MediaInfo: Equatable, Hashable, Sendable, Codable {
        case user(MediaUser)
        case synthetic(Synthetic)
        case compaction(Compaction)
        case move(Move)

        public var id: SessionMessageSchema.ID {
            switch self {
            case .user(let value): value.id
            case .synthetic(let value): value.id
            case .compaction(let value): value.id
            case .move(let value): value.id
            }
        }

        public var delivery: Delivery {
            switch self {
            case .user(let value): value.delivery
            case .synthetic(let value): value.delivery
            case .compaction(let value): value.delivery
            case .move(let value): value.delivery
            }
        }

        private enum TagKeys: String, CodingKey {
            case type
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: TagKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case MediaUser.typeTag: self = .user(try MediaUser(from: decoder))
            case Synthetic.typeTag: self = .synthetic(try Synthetic(from: decoder))
            case Compaction.typeTag: self = .compaction(try Compaction(from: decoder))
            case Move.typeTag: self = .move(try Move(from: decoder))
            default:
                throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown Session.Inbox.MediaInfo type '\(type)'")
            }
        }

        public func encode(to encoder: Encoder) throws {
            switch self {
            case .user(let value): try value.encode(to: encoder)
            case .synthetic(let value): try value.encode(to: encoder)
            case .compaction(let value): try value.encode(to: encoder)
            case .move(let value): try value.encode(to: encoder)
            }
        }
    }
}
