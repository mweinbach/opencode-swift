/// Pure Swift 6.2 V1 compatibility schemas.
/// Ports all 4 files in `packages/schema/src/v1/{filesystem,legacy-event,permission,session}.ts`.
/// 100% pure Swift standard library (zero OS imports, zero Foundation imports).

public enum V1Schema {
    // MARK: - src/v1/filesystem.ts

    public enum FileSystem {
        // parity: schema/src/v1/filesystem.ts#Event [status=implemented hash=315302f600c4]
        public enum Event {
            public struct EditedPayload: Equatable, Hashable, Sendable, Codable {
                public let file: String

                public init(file: String) {
                    self.file = file
                }
            }

            public static let edited = SchemaPrimitive.EventDescriptor.ephemeral(type: "file.edited")
            public static let definitions: [SchemaPrimitive.EventDescriptor] = [edited]
        }
    }

    // MARK: - src/v1/legacy-event.ts

    public enum LegacyEvent {
        public struct CommandExecutedPayload: Equatable, Hashable, Sendable, Codable {
            public let name: String
            public let sessionID: SessionID
            public let arguments: String
            public let messageID: Session.MessageID

            public init(name: String, sessionID: SessionID, arguments: String, messageID: Session.MessageID) {
                self.name = name
                self.sessionID = sessionID
                self.arguments = arguments
                self.messageID = messageID
            }
        }

        // parity: schema/src/v1/legacy-event.ts#CommandExecuted [status=implemented hash=9e01c82b64cd]
        public static let commandExecuted = SchemaPrimitive.EventDescriptor.ephemeral(type: "command.executed")

        // parity: schema/src/v1/legacy-event.ts#Definitions [status=implemented hash=762e070744c7]
        public static let definitions: [SchemaPrimitive.EventDescriptor] = [commandExecuted]
    }

    // MARK: - src/v1/permission.ts

    public enum Permission {
        // parity: schema/src/v1/permission.ts#ID [status=implemented hash=1216900a24e9]
        public struct ID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
            public let rawValue: String

            public init?(rawValue: String) {
                guard rawValue.hasPrefix("per") else { return nil }
                self.rawValue = rawValue
            }

            public init(validating value: String) throws(IdentifierValidationError) {
                guard value.hasPrefix("per") else {
                    throw .invalidPrefix(expected: "per", actual: value)
                }
                self.rawValue = value
            }

            private init(unchecked value: String) {
                self.rawValue = value
            }

            public static func ascending(_ id: String? = nil) throws(IdentifierValidationError) -> ID {
                guard let id else { return ID(unchecked: "per_" + Identifier.ascending()) }
                return try ID(validating: id)
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

        // parity: schema/src/v1/permission.ts#Action [status=implemented hash=21e5583186f8]
        public enum Action: String, Equatable, Hashable, Sendable, Codable {
            case allow
            case deny
            case ask
        }

        // parity: schema/src/v1/permission.ts#Rule [status=implemented hash=835f1cf2afe5]
        public struct Rule: Equatable, Hashable, Sendable, Codable {
            public let permission: String
            public let pattern: String
            public let action: Action

            public init(permission: String, pattern: String, action: Action) {
                self.permission = permission
                self.pattern = pattern
                self.action = action
            }
        }

        // parity: schema/src/v1/permission.ts#Ruleset [status=implemented hash=1d739c5fbbf1]
        public typealias Ruleset = [Rule]

        public struct ToolRef: Equatable, Hashable, Sendable, Codable {
            public let messageID: String
            public let callID: String

            public init(messageID: String, callID: String) {
                self.messageID = messageID
                self.callID = callID
            }
        }

        // parity: schema/src/v1/permission.ts#Request [status=implemented hash=5c4702d96a5d]
        public struct Request: Equatable, Hashable, Sendable, Codable {
            public let id: ID
            public let sessionID: SessionID
            public let permission: String
            public let patterns: [String]
            public let metadata: [String: JSONValue]
            public let always: [String]
            public let tool: ToolRef?

            public init(
                id: ID,
                sessionID: SessionID,
                permission: String,
                patterns: [String],
                metadata: [String: JSONValue] = [:],
                always: [String],
                tool: ToolRef? = nil
            ) {
                self.id = id
                self.sessionID = sessionID
                self.permission = permission
                self.patterns = patterns
                self.metadata = metadata
                self.always = always
                self.tool = tool
            }
        }

        // parity: schema/src/v1/permission.ts#Reply [status=implemented hash=264a472d3e09]
        public enum Reply: String, Equatable, Hashable, Sendable, Codable {
            case once
            case always
            case reject
        }

        // parity: schema/src/v1/permission.ts#ReplyBody [status=implemented hash=f7458d5419ac]
        public struct ReplyBody: Equatable, Hashable, Sendable, Codable {
            public let reply: Reply
            public let message: String?

            public init(reply: Reply, message: String? = nil) {
                self.reply = reply
                self.message = message
            }
        }

        // parity: schema/src/v1/permission.ts#Approval [status=implemented hash=ae336dcecf04]
        public struct Approval: Equatable, Hashable, Sendable, Codable {
            public let projectID: ProjectID
            public let patterns: [String]

            public init(projectID: ProjectID, patterns: [String]) {
                self.projectID = projectID
                self.patterns = patterns
            }
        }

        // parity: schema/src/v1/permission.ts#AskInput [status=implemented hash=2dca631c20d9]
        public struct AskInput: Equatable, Hashable, Sendable, Codable {
            public let id: ID?
            public let sessionID: SessionID
            public let permission: String
            public let patterns: [String]
            public let metadata: [String: JSONValue]
            public let always: [String]
            public let tool: ToolRef?
            public let ruleset: Ruleset

            public init(
                id: ID? = nil,
                sessionID: SessionID,
                permission: String,
                patterns: [String],
                metadata: [String: JSONValue] = [:],
                always: [String],
                tool: ToolRef? = nil,
                ruleset: Ruleset
            ) {
                self.id = id
                self.sessionID = sessionID
                self.permission = permission
                self.patterns = patterns
                self.metadata = metadata
                self.always = always
                self.tool = tool
                self.ruleset = ruleset
            }
        }

        // parity: schema/src/v1/permission.ts#ReplyInput [status=implemented hash=1ccedf7bcbe7]
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

        // parity: schema/src/v1/permission.ts#Event [status=implemented hash=18473cd164e0]
        public enum Event {
            public struct RepliedPayload: Equatable, Hashable, Sendable, Codable {
                public let sessionID: SessionID
                public let requestID: ID
                public let reply: Reply

                public init(sessionID: SessionID, requestID: ID, reply: Reply) {
                    self.sessionID = sessionID
                    self.requestID = requestID
                    self.reply = reply
                }
            }

            public static let asked = SchemaPrimitive.EventDescriptor.ephemeral(type: "permission.asked")
            public static let replied = SchemaPrimitive.EventDescriptor.ephemeral(type: "permission.replied")
            public static let definitions: [SchemaPrimitive.EventDescriptor] = [asked, replied]
        }
    }

    // MARK: - src/v1/session.ts

    public enum Session {
        // parity: schema/src/v1/session.ts#MessageID [status=implemented hash=76271f0ed95b]
        public struct MessageID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
            public let rawValue: String

            public init?(rawValue: String) {
                guard rawValue.hasPrefix("msg") else { return nil }
                self.rawValue = rawValue
            }

            public init(validating value: String) throws(IdentifierValidationError) {
                guard value.hasPrefix("msg") else {
                    throw .invalidPrefix(expected: "msg", actual: value)
                }
                self.rawValue = value
            }

            private init(unchecked value: String) {
                self.rawValue = value
            }

            public static func ascending(_ id: String? = nil) throws(IdentifierValidationError) -> MessageID {
                guard let id else { return MessageID(unchecked: "msg_" + Identifier.ascending()) }
                return try MessageID(validating: id)
            }

            public var description: String { rawValue }

            public init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                let value = try container.decode(String.self)
                self = try MessageID(validating: value)
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.singleValueContainer()
                try container.encode(rawValue)
            }
        }

        // parity: schema/src/v1/session.ts#PartID [status=implemented hash=f57e78fade78]
        public struct PartID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
            public let rawValue: String

            public init?(rawValue: String) {
                guard rawValue.hasPrefix("prt") else { return nil }
                self.rawValue = rawValue
            }

            public init(validating value: String) throws(IdentifierValidationError) {
                guard value.hasPrefix("prt") else {
                    throw .invalidPrefix(expected: "prt", actual: value)
                }
                self.rawValue = value
            }

            private init(unchecked value: String) {
                self.rawValue = value
            }

            public static func ascending(_ id: String? = nil) throws(IdentifierValidationError) -> PartID {
                guard let id else { return PartID(unchecked: "prt_" + Identifier.ascending()) }
                return try PartID(validating: id)
            }

            public var description: String { rawValue }

            public init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                let value = try container.decode(String.self)
                self = try PartID(validating: value)
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.singleValueContainer()
                try container.encode(rawValue)
            }
        }

        // MARK: Named Errors

        public struct EmptyData: Equatable, Hashable, Sendable, Codable {
            public init() {}
        }

        // parity: schema/src/v1/session.ts#OutputLengthError [status=implemented hash=4a7394a09a19]
        public struct OutputLengthError: Equatable, Hashable, Sendable, Codable {
            public static let errorName = "MessageOutputLengthError"
            public let data: EmptyData

            public init(data: EmptyData = EmptyData()) {
                self.data = data
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                try SchemaPrimitive.decodeRequiredLiteral(Self.errorName, from: container, forKey: .name)
                self.data = try container.decode(EmptyData.self, forKey: .data)
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(Self.errorName, forKey: .name)
                try container.encode(data, forKey: .data)
            }

            enum CodingKeys: String, CodingKey {
                case name
                case data
            }
        }

        // parity: schema/src/v1/session.ts#AuthError [status=implemented hash=afeca41354a0]
        public struct AuthError: Equatable, Hashable, Sendable, Codable {
            public static let errorName = "ProviderAuthError"

            public struct Data: Equatable, Hashable, Sendable, Codable {
                public let providerID: String
                public let message: String

                public init(providerID: String, message: String) {
                    self.providerID = providerID
                    self.message = message
                }
            }

            public let data: Data

            public init(data: Data) {
                self.data = data
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                try SchemaPrimitive.decodeRequiredLiteral(Self.errorName, from: container, forKey: .name)
                self.data = try container.decode(Data.self, forKey: .data)
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(Self.errorName, forKey: .name)
                try container.encode(data, forKey: .data)
            }

            enum CodingKeys: String, CodingKey {
                case name
                case data
            }
        }

        // parity: schema/src/v1/session.ts#AbortedError [status=implemented hash=a06b3016f8ea]
        public struct AbortedError: Equatable, Hashable, Sendable, Codable {
            public static let errorName = "MessageAbortedError"

            public struct Data: Equatable, Hashable, Sendable, Codable {
                public let message: String

                public init(message: String) {
                    self.message = message
                }
            }

            public let data: Data

            public init(data: Data) {
                self.data = data
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                try SchemaPrimitive.decodeRequiredLiteral(Self.errorName, from: container, forKey: .name)
                self.data = try container.decode(Data.self, forKey: .data)
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(Self.errorName, forKey: .name)
                try container.encode(data, forKey: .data)
            }

            enum CodingKeys: String, CodingKey {
                case name
                case data
            }
        }

        // parity: schema/src/v1/session.ts#StructuredOutputError [status=implemented hash=397c2c579c31]
        public struct StructuredOutputError: Equatable, Hashable, Sendable, Codable {
            public static let errorName = "StructuredOutputError"

            public struct Data: Equatable, Hashable, Sendable, Codable {
                public let message: String
                public let retries: SchemaPrimitive.NonNegativeInt

                public init(message: String, retries: SchemaPrimitive.NonNegativeInt) {
                    self.message = message
                    self.retries = retries
                }
            }

            public let data: Data

            public init(data: Data) {
                self.data = data
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                try SchemaPrimitive.decodeRequiredLiteral(Self.errorName, from: container, forKey: .name)
                self.data = try container.decode(Data.self, forKey: .data)
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(Self.errorName, forKey: .name)
                try container.encode(data, forKey: .data)
            }

            enum CodingKeys: String, CodingKey {
                case name
                case data
            }
        }

        // parity: schema/src/v1/session.ts#APIError [status=implemented hash=d2e314f17ac7]
        public struct APIError: Equatable, Hashable, Sendable, Codable {
            public static let errorName = "APIError"

            public struct Data: Equatable, Hashable, Sendable, Codable {
                public let message: String
                public let statusCode: SchemaPrimitive.NonNegativeInt?
                public let isRetryable: Bool
                public let responseHeaders: [String: String]?
                public let responseBody: String?
                public let metadata: [String: String]?

                public init(
                    message: String,
                    statusCode: SchemaPrimitive.NonNegativeInt? = nil,
                    isRetryable: Bool,
                    responseHeaders: [String: String]? = nil,
                    responseBody: String? = nil,
                    metadata: [String: String]? = nil
                ) {
                    self.message = message
                    self.statusCode = statusCode
                    self.isRetryable = isRetryable
                    self.responseHeaders = responseHeaders
                    self.responseBody = responseBody
                    self.metadata = metadata
                }
            }

            public let data: Data

            public init(data: Data) {
                self.data = data
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                try SchemaPrimitive.decodeRequiredLiteral(Self.errorName, from: container, forKey: .name)
                self.data = try container.decode(Data.self, forKey: .data)
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(Self.errorName, forKey: .name)
                try container.encode(data, forKey: .data)
            }

            enum CodingKeys: String, CodingKey {
                case name
                case data
            }
        }

        // parity: schema/src/v1/session.ts#ContextOverflowError [status=implemented hash=8790d4bf62e0]
        public struct ContextOverflowError: Equatable, Hashable, Sendable, Codable {
            public static let errorName = "ContextOverflowError"

            public struct Data: Equatable, Hashable, Sendable, Codable {
                public let message: String
                public let responseBody: String?

                public init(message: String, responseBody: String? = nil) {
                    self.message = message
                    self.responseBody = responseBody
                }
            }

            public let data: Data

            public init(data: Data) {
                self.data = data
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                try SchemaPrimitive.decodeRequiredLiteral(Self.errorName, from: container, forKey: .name)
                self.data = try container.decode(Data.self, forKey: .data)
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(Self.errorName, forKey: .name)
                try container.encode(data, forKey: .data)
            }

            enum CodingKeys: String, CodingKey {
                case name
                case data
            }
        }

        // parity: schema/src/v1/session.ts#ContentFilterError [status=implemented hash=73920e8373a4]
        public struct ContentFilterError: Equatable, Hashable, Sendable, Codable {
            public static let errorName = "ContentFilterError"

            public struct Data: Equatable, Hashable, Sendable, Codable {
                public let message: String

                public init(message: String) {
                    self.message = message
                }
            }

            public let data: Data

            public init(data: Data) {
                self.data = data
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                try SchemaPrimitive.decodeRequiredLiteral(Self.errorName, from: container, forKey: .name)
                self.data = try container.decode(Data.self, forKey: .data)
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(Self.errorName, forKey: .name)
                try container.encode(data, forKey: .data)
            }

            enum CodingKeys: String, CodingKey {
                case name
                case data
            }
        }

        public struct UnknownError: Equatable, Hashable, Sendable, Codable {
            public static let errorName = "UnknownError"

            public struct Data: Equatable, Hashable, Sendable, Codable {
                public let message: String
                public let ref: String?

                public init(message: String, ref: String? = nil) {
                    self.message = message
                    self.ref = ref
                }
            }

            public let data: Data

            public init(data: Data) {
                self.data = data
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                try SchemaPrimitive.decodeRequiredLiteral(Self.errorName, from: container, forKey: .name)
                self.data = try container.decode(Data.self, forKey: .data)
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(Self.errorName, forKey: .name)
                try container.encode(data, forKey: .data)
            }

            enum CodingKeys: String, CodingKey {
                case name
                case data
            }
        }

        public enum AssistantError: Equatable, Hashable, Sendable, Codable {
            case auth(AuthError)
            case unknown(UnknownError)
            case outputLength(OutputLengthError)
            case aborted(AbortedError)
            case structuredOutput(StructuredOutputError)
            case contextOverflow(ContextOverflowError)
            case contentFilter(ContentFilterError)
            case api(APIError)

            enum TagKeys: String, CodingKey {
                case name
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: TagKeys.self)
                let name = try container.decode(String.self, forKey: .name)
                switch name {
                case AuthError.errorName: self = .auth(try AuthError(from: decoder))
                case UnknownError.errorName: self = .unknown(try UnknownError(from: decoder))
                case OutputLengthError.errorName: self = .outputLength(try OutputLengthError(from: decoder))
                case AbortedError.errorName: self = .aborted(try AbortedError(from: decoder))
                case StructuredOutputError.errorName: self = .structuredOutput(try StructuredOutputError(from: decoder))
                case ContextOverflowError.errorName: self = .contextOverflow(try ContextOverflowError(from: decoder))
                case ContentFilterError.errorName: self = .contentFilter(try ContentFilterError(from: decoder))
                case APIError.errorName: self = .api(try APIError(from: decoder))
                default:
                    throw DecodingError.dataCorruptedError(
                        forKey: .name,
                        in: container,
                        debugDescription: "Unknown SessionV1 AssistantError name '\(name)'"
                    )
                }
            }

            public func encode(to encoder: Encoder) throws {
                switch self {
                case .auth(let e): try e.encode(to: encoder)
                case .unknown(let e): try e.encode(to: encoder)
                case .outputLength(let e): try e.encode(to: encoder)
                case .aborted(let e): try e.encode(to: encoder)
                case .structuredOutput(let e): try e.encode(to: encoder)
                case .contextOverflow(let e): try e.encode(to: encoder)
                case .contentFilter(let e): try e.encode(to: encoder)
                case .api(let e): try e.encode(to: encoder)
                }
            }
        }

        // MARK: Output Formats

        // parity: schema/src/v1/session.ts#OutputFormatText [status=implemented hash=52fba1dd7c21]
        public struct OutputFormatText: Equatable, Hashable, Sendable, Codable {
            public init() {}

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                try SchemaPrimitive.decodeRequiredLiteral("text", from: container, forKey: .type)
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode("text", forKey: .type)
            }

            enum CodingKeys: String, CodingKey {
                case type
            }
        }

        // parity: schema/src/v1/session.ts#OutputFormatJsonSchema [status=implemented hash=67cff0ba96eb]
        public struct OutputFormatJsonSchema: Equatable, Hashable, Sendable, Codable {
            public let schema: [String: JSONValue]
            public let retryCount: SchemaPrimitive.NonNegativeInt

            public init(
                schema: [String: JSONValue],
                retryCount: SchemaPrimitive.NonNegativeInt = SchemaPrimitive.NonNegativeInt(rawValue: 2)!
            ) {
                self.schema = schema
                self.retryCount = retryCount
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                try SchemaPrimitive.decodeRequiredLiteral("json_schema", from: container, forKey: .type)
                self.schema = try container.decode([String: JSONValue].self, forKey: .schema)
                self.retryCount = try container.decodeIfPresent(
                    SchemaPrimitive.NonNegativeInt.self,
                    forKey: .retryCount
                ) ?? SchemaPrimitive.NonNegativeInt(rawValue: 2)!
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode("json_schema", forKey: .type)
                try container.encode(schema, forKey: .schema)
                try container.encode(retryCount, forKey: .retryCount)
            }

            enum CodingKeys: String, CodingKey {
                case type
                case schema
                case retryCount
            }
        }

        // parity: schema/src/v1/session.ts#Format [status=implemented hash=417812b027db]
        public enum Format: Equatable, Hashable, Sendable, Codable {
            case text(OutputFormatText)
            case jsonSchema(OutputFormatJsonSchema)

            enum TagKeys: String, CodingKey {
                case type
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: TagKeys.self)
                let type = try container.decode(String.self, forKey: .type)
                switch type {
                case "text":
                    self = .text(try OutputFormatText(from: decoder))
                case "json_schema":
                    self = .jsonSchema(try OutputFormatJsonSchema(from: decoder))
                default:
                    throw DecodingError.dataCorruptedError(
                        forKey: .type,
                        in: container,
                        debugDescription: "Unknown SessionV1.OutputFormat type '\(type)'"
                    )
                }
            }

            public func encode(to encoder: Encoder) throws {
                switch self {
                case .text(let v): try v.encode(to: encoder)
                case .jsonSchema(let v): try v.encode(to: encoder)
                }
            }
        }

        // parity: schema/src/v1/session.ts#OutputFormat [status=implemented hash=616c41ccb50f]
        public typealias OutputFormat = Format

        // MARK: Parts & Supporting Structs

        public struct TimeSpan: Equatable, Hashable, Sendable, Codable {
            public let start: SchemaPrimitive.NonNegativeInt
            public let end: SchemaPrimitive.NonNegativeInt?

            public init(start: SchemaPrimitive.NonNegativeInt, end: SchemaPrimitive.NonNegativeInt? = nil) {
                self.start = start
                self.end = end
            }
        }

        public struct FilePartSourceText: Equatable, Hashable, Sendable, Codable {
            public let value: String
            public let start: Double
            public let end: Double

            public init(value: String, start: Double, end: Double) {
                self.value = value
                self.start = start
                self.end = end
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.value = try container.decode(String.self, forKey: .value)
                self.start = try SchemaPrimitive.decodeFinite(from: container, forKey: .start)
                self.end = try SchemaPrimitive.decodeFinite(from: container, forKey: .end)
            }

            enum CodingKeys: String, CodingKey {
                case value
                case start
                case end
            }
        }

        public struct Position: Equatable, Hashable, Sendable, Codable {
            public let line: SchemaPrimitive.NonNegativeInt
            public let character: SchemaPrimitive.NonNegativeInt

            public init(line: SchemaPrimitive.NonNegativeInt, character: SchemaPrimitive.NonNegativeInt) {
                self.line = line
                self.character = character
            }
        }

        // parity: schema/src/v1/session.ts#Range [status=implemented hash=3bcad5336e13]
        public struct Range: Equatable, Hashable, Sendable, Codable {
            public let start: Position
            public let end: Position

            public init(start: Position, end: Position) {
                self.start = start
                self.end = end
            }
        }

        // parity: schema/src/v1/session.ts#FileSource [status=implemented hash=5db0adfdee15]
        public struct FileSource: Equatable, Hashable, Sendable, Codable {
            public let text: FilePartSourceText
            public let path: String

            public init(text: FilePartSourceText, path: String) {
                self.text = text
                self.path = path
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                try SchemaPrimitive.decodeRequiredLiteral("file", from: container, forKey: .type)
                self.text = try container.decode(FilePartSourceText.self, forKey: .text)
                self.path = try container.decode(String.self, forKey: .path)
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode("file", forKey: .type)
                try container.encode(text, forKey: .text)
                try container.encode(path, forKey: .path)
            }

            enum CodingKeys: String, CodingKey {
                case type
                case text
                case path
            }
        }

        // parity: schema/src/v1/session.ts#SymbolSource [status=implemented hash=f5517226ff3c]
        public struct SymbolSource: Equatable, Hashable, Sendable, Codable {
            public let text: FilePartSourceText
            public let path: String
            public let range: Range
            public let name: String
            public let kind: SchemaPrimitive.NonNegativeInt

            public init(
                text: FilePartSourceText,
                path: String,
                range: Range,
                name: String,
                kind: SchemaPrimitive.NonNegativeInt
            ) {
                self.text = text
                self.path = path
                self.range = range
                self.name = name
                self.kind = kind
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                try SchemaPrimitive.decodeRequiredLiteral("symbol", from: container, forKey: .type)
                self.text = try container.decode(FilePartSourceText.self, forKey: .text)
                self.path = try container.decode(String.self, forKey: .path)
                self.range = try container.decode(Range.self, forKey: .range)
                self.name = try container.decode(String.self, forKey: .name)
                self.kind = try container.decode(SchemaPrimitive.NonNegativeInt.self, forKey: .kind)
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode("symbol", forKey: .type)
                try container.encode(text, forKey: .text)
                try container.encode(path, forKey: .path)
                try container.encode(range, forKey: .range)
                try container.encode(name, forKey: .name)
                try container.encode(kind, forKey: .kind)
            }

            enum CodingKeys: String, CodingKey {
                case type
                case text
                case path
                case range
                case name
                case kind
            }
        }

        // parity: schema/src/v1/session.ts#ResourceSource [status=implemented hash=8f810669aa75]
        public struct ResourceSource: Equatable, Hashable, Sendable, Codable {
            public let text: FilePartSourceText
            public let clientName: String
            public let uri: String

            public init(text: FilePartSourceText, clientName: String, uri: String) {
                self.text = text
                self.clientName = clientName
                self.uri = uri
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                try SchemaPrimitive.decodeRequiredLiteral("resource", from: container, forKey: .type)
                self.text = try container.decode(FilePartSourceText.self, forKey: .text)
                self.clientName = try container.decode(String.self, forKey: .clientName)
                self.uri = try container.decode(String.self, forKey: .uri)
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode("resource", forKey: .type)
                try container.encode(text, forKey: .text)
                try container.encode(clientName, forKey: .clientName)
                try container.encode(uri, forKey: .uri)
            }

            enum CodingKeys: String, CodingKey {
                case type
                case text
                case clientName
                case uri
            }
        }

        // parity: schema/src/v1/session.ts#FilePartSource [status=implemented hash=05312b45ec2f]
        public enum FilePartSource: Equatable, Hashable, Sendable, Codable {
            case file(FileSource)
            case symbol(SymbolSource)
            case resource(ResourceSource)

            enum TagKeys: String, CodingKey {
                case type
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: TagKeys.self)
                let type = try container.decode(String.self, forKey: .type)
                switch type {
                case "file": self = .file(try FileSource(from: decoder))
                case "symbol": self = .symbol(try SymbolSource(from: decoder))
                case "resource": self = .resource(try ResourceSource(from: decoder))
                default:
                    throw DecodingError.dataCorruptedError(
                        forKey: .type,
                        in: container,
                        debugDescription: "Unknown SessionV1.FilePartSource type '\(type)'"
                    )
                }
            }

            public func encode(to encoder: Encoder) throws {
                switch self {
                case .file(let v): try v.encode(to: encoder)
                case .symbol(let v): try v.encode(to: encoder)
                case .resource(let v): try v.encode(to: encoder)
                }
            }
        }

        // parity: schema/src/v1/session.ts#SnapshotPart [status=implemented hash=2e32fe065458]
        public struct SnapshotPart: Equatable, Hashable, Sendable, Codable {
            public let id: PartID
            public let sessionID: SessionID
            public let messageID: MessageID
            public let snapshot: String

            public init(id: PartID, sessionID: SessionID, messageID: MessageID, snapshot: String) {
                self.id = id
                self.sessionID = sessionID
                self.messageID = messageID
                self.snapshot = snapshot
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                try SchemaPrimitive.decodeRequiredLiteral("snapshot", from: container, forKey: .type)
                self.id = try container.decode(PartID.self, forKey: .id)
                self.sessionID = try container.decode(SessionID.self, forKey: .sessionID)
                self.messageID = try container.decode(MessageID.self, forKey: .messageID)
                self.snapshot = try container.decode(String.self, forKey: .snapshot)
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode("snapshot", forKey: .type)
                try container.encode(id, forKey: .id)
                try container.encode(sessionID, forKey: .sessionID)
                try container.encode(messageID, forKey: .messageID)
                try container.encode(snapshot, forKey: .snapshot)
            }

            enum CodingKeys: String, CodingKey {
                case type
                case id
                case sessionID
                case messageID
                case snapshot
            }
        }

        // parity: schema/src/v1/session.ts#PatchPart [status=implemented hash=c4a0eaf20745]
        public struct PatchPart: Equatable, Hashable, Sendable, Codable {
            public let id: PartID
            public let sessionID: SessionID
            public let messageID: MessageID
            public let hash: String
            public let files: [String]

            public init(id: PartID, sessionID: SessionID, messageID: MessageID, hash: String, files: [String]) {
                self.id = id
                self.sessionID = sessionID
                self.messageID = messageID
                self.hash = hash
                self.files = files
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                try SchemaPrimitive.decodeRequiredLiteral("patch", from: container, forKey: .type)
                self.id = try container.decode(PartID.self, forKey: .id)
                self.sessionID = try container.decode(SessionID.self, forKey: .sessionID)
                self.messageID = try container.decode(MessageID.self, forKey: .messageID)
                self.hash = try container.decode(String.self, forKey: .hash)
                self.files = try container.decode([String].self, forKey: .files)
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode("patch", forKey: .type)
                try container.encode(id, forKey: .id)
                try container.encode(sessionID, forKey: .sessionID)
                try container.encode(messageID, forKey: .messageID)
                try container.encode(hash, forKey: .hash)
                try container.encode(files, forKey: .files)
            }

            enum CodingKeys: String, CodingKey {
                case type
                case id
                case sessionID
                case messageID
                case hash
                case files
            }
        }

        // parity: schema/src/v1/session.ts#TextPart [status=implemented hash=068a7245d976]
        public struct TextPart: Equatable, Hashable, Sendable, Codable {
            public let id: PartID
            public let sessionID: SessionID
            public let messageID: MessageID
            public let text: String
            public let synthetic: Bool?
            public let ignored: Bool?
            public let time: TimeSpan?
            public let metadata: [String: JSONValue]?

            public init(
                id: PartID,
                sessionID: SessionID,
                messageID: MessageID,
                text: String,
                synthetic: Bool? = nil,
                ignored: Bool? = nil,
                time: TimeSpan? = nil,
                metadata: [String: JSONValue]? = nil
            ) {
                self.id = id
                self.sessionID = sessionID
                self.messageID = messageID
                self.text = text
                self.synthetic = synthetic
                self.ignored = ignored
                self.time = time
                self.metadata = metadata
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                try SchemaPrimitive.decodeRequiredLiteral("text", from: container, forKey: .type)
                self.id = try container.decode(PartID.self, forKey: .id)
                self.sessionID = try container.decode(SessionID.self, forKey: .sessionID)
                self.messageID = try container.decode(MessageID.self, forKey: .messageID)
                self.text = try container.decode(String.self, forKey: .text)
                self.synthetic = try container.decodeIfPresent(Bool.self, forKey: .synthetic)
                self.ignored = try container.decodeIfPresent(Bool.self, forKey: .ignored)
                self.time = try container.decodeIfPresent(TimeSpan.self, forKey: .time)
                self.metadata = try container.decodeIfPresent([String: JSONValue].self, forKey: .metadata)
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode("text", forKey: .type)
                try container.encode(id, forKey: .id)
                try container.encode(sessionID, forKey: .sessionID)
                try container.encode(messageID, forKey: .messageID)
                try container.encode(text, forKey: .text)
                try container.encodeIfPresent(synthetic, forKey: .synthetic)
                try container.encodeIfPresent(ignored, forKey: .ignored)
                try container.encodeIfPresent(time, forKey: .time)
                try container.encodeIfPresent(metadata, forKey: .metadata)
            }

            enum CodingKeys: String, CodingKey {
                case type
                case id
                case sessionID
                case messageID
                case text
                case synthetic
                case ignored
                case time
                case metadata
            }
        }

        // parity: schema/src/v1/session.ts#ReasoningPart [status=implemented hash=ade23ddae96f]
        public struct ReasoningPart: Equatable, Hashable, Sendable, Codable {
            public let id: PartID
            public let sessionID: SessionID
            public let messageID: MessageID
            public let text: String
            public let metadata: [String: JSONValue]?
            public let time: TimeSpan

            public init(
                id: PartID,
                sessionID: SessionID,
                messageID: MessageID,
                text: String,
                metadata: [String: JSONValue]? = nil,
                time: TimeSpan
            ) {
                self.id = id
                self.sessionID = sessionID
                self.messageID = messageID
                self.text = text
                self.metadata = metadata
                self.time = time
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                try SchemaPrimitive.decodeRequiredLiteral("reasoning", from: container, forKey: .type)
                self.id = try container.decode(PartID.self, forKey: .id)
                self.sessionID = try container.decode(SessionID.self, forKey: .sessionID)
                self.messageID = try container.decode(MessageID.self, forKey: .messageID)
                self.text = try container.decode(String.self, forKey: .text)
                self.metadata = try container.decodeIfPresent([String: JSONValue].self, forKey: .metadata)
                self.time = try container.decode(TimeSpan.self, forKey: .time)
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode("reasoning", forKey: .type)
                try container.encode(id, forKey: .id)
                try container.encode(sessionID, forKey: .sessionID)
                try container.encode(messageID, forKey: .messageID)
                try container.encode(text, forKey: .text)
                try container.encodeIfPresent(metadata, forKey: .metadata)
                try container.encode(time, forKey: .time)
            }

            enum CodingKeys: String, CodingKey {
                case type
                case id
                case sessionID
                case messageID
                case text
                case metadata
                case time
            }
        }

        // parity: schema/src/v1/session.ts#FilePart [status=implemented hash=7e1079402b7e]
        public struct FilePart: Equatable, Hashable, Sendable, Codable {
            public let id: PartID
            public let sessionID: SessionID
            public let messageID: MessageID
            public let mime: String
            public let filename: String?
            public let url: String
            public let source: FilePartSource?

            public init(
                id: PartID,
                sessionID: SessionID,
                messageID: MessageID,
                mime: String,
                filename: String? = nil,
                url: String,
                source: FilePartSource? = nil
            ) {
                self.id = id
                self.sessionID = sessionID
                self.messageID = messageID
                self.mime = mime
                self.filename = filename
                self.url = url
                self.source = source
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                try SchemaPrimitive.decodeRequiredLiteral("file", from: container, forKey: .type)
                self.id = try container.decode(PartID.self, forKey: .id)
                self.sessionID = try container.decode(SessionID.self, forKey: .sessionID)
                self.messageID = try container.decode(MessageID.self, forKey: .messageID)
                self.mime = try container.decode(String.self, forKey: .mime)
                self.filename = try container.decodeIfPresent(String.self, forKey: .filename)
                self.url = try container.decode(String.self, forKey: .url)
                self.source = try container.decodeIfPresent(FilePartSource.self, forKey: .source)
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode("file", forKey: .type)
                try container.encode(id, forKey: .id)
                try container.encode(sessionID, forKey: .sessionID)
                try container.encode(messageID, forKey: .messageID)
                try container.encode(mime, forKey: .mime)
                try container.encodeIfPresent(filename, forKey: .filename)
                try container.encode(url, forKey: .url)
                try container.encodeIfPresent(source, forKey: .source)
            }

            enum CodingKeys: String, CodingKey {
                case type
                case id
                case sessionID
                case messageID
                case mime
                case filename
                case url
                case source
            }
        }

        public struct AgentSourceSpan: Equatable, Hashable, Sendable, Codable {
            public let value: String
            public let start: SchemaPrimitive.NonNegativeInt
            public let end: SchemaPrimitive.NonNegativeInt

            public init(
                value: String,
                start: SchemaPrimitive.NonNegativeInt,
                end: SchemaPrimitive.NonNegativeInt
            ) {
                self.value = value
                self.start = start
                self.end = end
            }
        }

        // parity: schema/src/v1/session.ts#AgentPart [status=implemented hash=5daf33d40b29]
        public struct AgentPart: Equatable, Hashable, Sendable, Codable {
            public let id: PartID
            public let sessionID: SessionID
            public let messageID: MessageID
            public let name: String
            public let source: AgentSourceSpan?

            public init(
                id: PartID,
                sessionID: SessionID,
                messageID: MessageID,
                name: String,
                source: AgentSourceSpan? = nil
            ) {
                self.id = id
                self.sessionID = sessionID
                self.messageID = messageID
                self.name = name
                self.source = source
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                try SchemaPrimitive.decodeRequiredLiteral("agent", from: container, forKey: .type)
                self.id = try container.decode(PartID.self, forKey: .id)
                self.sessionID = try container.decode(SessionID.self, forKey: .sessionID)
                self.messageID = try container.decode(MessageID.self, forKey: .messageID)
                self.name = try container.decode(String.self, forKey: .name)
                self.source = try container.decodeIfPresent(AgentSourceSpan.self, forKey: .source)
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode("agent", forKey: .type)
                try container.encode(id, forKey: .id)
                try container.encode(sessionID, forKey: .sessionID)
                try container.encode(messageID, forKey: .messageID)
                try container.encode(name, forKey: .name)
                try container.encodeIfPresent(source, forKey: .source)
            }

            enum CodingKeys: String, CodingKey {
                case type
                case id
                case sessionID
                case messageID
                case name
                case source
            }
        }

        // parity: schema/src/v1/session.ts#CompactionPart [status=implemented hash=0f401c023a94]
        public struct CompactionPart: Equatable, Hashable, Sendable, Codable {
            public let id: PartID
            public let sessionID: SessionID
            public let messageID: MessageID
            public let auto: Bool
            public let overflow: Bool?
            public let tailStartID: MessageID?

            public init(
                id: PartID,
                sessionID: SessionID,
                messageID: MessageID,
                auto: Bool,
                overflow: Bool? = nil,
                tailStartID: MessageID? = nil
            ) {
                self.id = id
                self.sessionID = sessionID
                self.messageID = messageID
                self.auto = auto
                self.overflow = overflow
                self.tailStartID = tailStartID
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                try SchemaPrimitive.decodeRequiredLiteral("compaction", from: container, forKey: .type)
                self.id = try container.decode(PartID.self, forKey: .id)
                self.sessionID = try container.decode(SessionID.self, forKey: .sessionID)
                self.messageID = try container.decode(MessageID.self, forKey: .messageID)
                self.auto = try container.decode(Bool.self, forKey: .auto)
                self.overflow = try container.decodeIfPresent(Bool.self, forKey: .overflow)
                self.tailStartID = try container.decodeIfPresent(MessageID.self, forKey: .tailStartID)
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode("compaction", forKey: .type)
                try container.encode(id, forKey: .id)
                try container.encode(sessionID, forKey: .sessionID)
                try container.encode(messageID, forKey: .messageID)
                try container.encode(auto, forKey: .auto)
                try container.encodeIfPresent(overflow, forKey: .overflow)
                try container.encodeIfPresent(tailStartID, forKey: .tailStartID)
            }

            enum CodingKeys: String, CodingKey {
                case type
                case id
                case sessionID
                case messageID
                case auto
                case overflow
                case tailStartID = "tail_start_id"
            }
        }

        public struct ModelSelectionRef: Equatable, Hashable, Sendable, Codable {
            public let providerID: ProviderSchema.ID
            public let modelID: ModelSchema.ID

            public init(providerID: ProviderSchema.ID, modelID: ModelSchema.ID) {
                self.providerID = providerID
                self.modelID = modelID
            }
        }

        // parity: schema/src/v1/session.ts#SubtaskPart [status=implemented hash=4158b99d7d65]
        public struct SubtaskPart: Equatable, Hashable, Sendable, Codable {
            public let id: PartID
            public let sessionID: SessionID
            public let messageID: MessageID
            public let prompt: String
            public let description: String
            public let agent: String
            public let model: ModelSelectionRef?
            public let command: String?

            public init(
                id: PartID,
                sessionID: SessionID,
                messageID: MessageID,
                prompt: String,
                description: String,
                agent: String,
                model: ModelSelectionRef? = nil,
                command: String? = nil
            ) {
                self.id = id
                self.sessionID = sessionID
                self.messageID = messageID
                self.prompt = prompt
                self.description = description
                self.agent = agent
                self.model = model
                self.command = command
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                try SchemaPrimitive.decodeRequiredLiteral("subtask", from: container, forKey: .type)
                self.id = try container.decode(PartID.self, forKey: .id)
                self.sessionID = try container.decode(SessionID.self, forKey: .sessionID)
                self.messageID = try container.decode(MessageID.self, forKey: .messageID)
                self.prompt = try container.decode(String.self, forKey: .prompt)
                self.description = try container.decode(String.self, forKey: .description)
                self.agent = try container.decode(String.self, forKey: .agent)
                self.model = try container.decodeIfPresent(ModelSelectionRef.self, forKey: .model)
                self.command = try container.decodeIfPresent(String.self, forKey: .command)
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode("subtask", forKey: .type)
                try container.encode(id, forKey: .id)
                try container.encode(sessionID, forKey: .sessionID)
                try container.encode(messageID, forKey: .messageID)
                try container.encode(prompt, forKey: .prompt)
                try container.encode(description, forKey: .description)
                try container.encode(agent, forKey: .agent)
                try container.encodeIfPresent(model, forKey: .model)
                try container.encodeIfPresent(command, forKey: .command)
            }

            enum CodingKeys: String, CodingKey {
                case type
                case id
                case sessionID
                case messageID
                case prompt
                case description
                case agent
                case model
                case command
            }
        }

        public struct CreatedTime: Equatable, Hashable, Sendable, Codable {
            public let created: SchemaPrimitive.NonNegativeInt

            public init(created: SchemaPrimitive.NonNegativeInt) {
                self.created = created
            }
        }

        // parity: schema/src/v1/session.ts#RetryPart [status=implemented hash=4efe44fba330]
        public struct RetryPart: Equatable, Hashable, Sendable, Codable {
            public let id: PartID
            public let sessionID: SessionID
            public let messageID: MessageID
            public let attempt: SchemaPrimitive.NonNegativeInt
            public let error: APIError
            public let time: CreatedTime

            public init(
                id: PartID,
                sessionID: SessionID,
                messageID: MessageID,
                attempt: SchemaPrimitive.NonNegativeInt,
                error: APIError,
                time: CreatedTime
            ) {
                self.id = id
                self.sessionID = sessionID
                self.messageID = messageID
                self.attempt = attempt
                self.error = error
                self.time = time
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                try SchemaPrimitive.decodeRequiredLiteral("retry", from: container, forKey: .type)
                self.id = try container.decode(PartID.self, forKey: .id)
                self.sessionID = try container.decode(SessionID.self, forKey: .sessionID)
                self.messageID = try container.decode(MessageID.self, forKey: .messageID)
                self.attempt = try container.decode(SchemaPrimitive.NonNegativeInt.self, forKey: .attempt)
                self.error = try container.decode(APIError.self, forKey: .error)
                self.time = try container.decode(CreatedTime.self, forKey: .time)
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode("retry", forKey: .type)
                try container.encode(id, forKey: .id)
                try container.encode(sessionID, forKey: .sessionID)
                try container.encode(messageID, forKey: .messageID)
                try container.encode(attempt, forKey: .attempt)
                try container.encode(error, forKey: .error)
                try container.encode(time, forKey: .time)
            }

            enum CodingKeys: String, CodingKey {
                case type
                case id
                case sessionID
                case messageID
                case attempt
                case error
                case time
            }
        }

        // parity: schema/src/v1/session.ts#StepStartPart [status=implemented hash=ef76fc1cafc0]
        public struct StepStartPart: Equatable, Hashable, Sendable, Codable {
            public let id: PartID
            public let sessionID: SessionID
            public let messageID: MessageID
            public let snapshot: String?

            public init(id: PartID, sessionID: SessionID, messageID: MessageID, snapshot: String? = nil) {
                self.id = id
                self.sessionID = sessionID
                self.messageID = messageID
                self.snapshot = snapshot
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                try SchemaPrimitive.decodeRequiredLiteral("step-start", from: container, forKey: .type)
                self.id = try container.decode(PartID.self, forKey: .id)
                self.sessionID = try container.decode(SessionID.self, forKey: .sessionID)
                self.messageID = try container.decode(MessageID.self, forKey: .messageID)
                self.snapshot = try container.decodeIfPresent(String.self, forKey: .snapshot)
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode("step-start", forKey: .type)
                try container.encode(id, forKey: .id)
                try container.encode(sessionID, forKey: .sessionID)
                try container.encode(messageID, forKey: .messageID)
                try container.encodeIfPresent(snapshot, forKey: .snapshot)
            }

            enum CodingKeys: String, CodingKey {
                case type
                case id
                case sessionID
                case messageID
                case snapshot
            }
        }

        public struct StepTokens: Equatable, Hashable, Sendable, Codable {
            public let total: Double?
            public let input: Double
            public let output: Double
            public let reasoning: Double
            public let cache: TokenUsageSchema.Cache

            public init(
                total: Double? = nil,
                input: Double,
                output: Double,
                reasoning: Double,
                cache: TokenUsageSchema.Cache
            ) {
                self.total = total
                self.input = input
                self.output = output
                self.reasoning = reasoning
                self.cache = cache
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.total = try SchemaPrimitive.decodeFiniteIfPresent(from: container, forKey: .total)
                self.input = try SchemaPrimitive.decodeFinite(from: container, forKey: .input)
                self.output = try SchemaPrimitive.decodeFinite(from: container, forKey: .output)
                self.reasoning = try SchemaPrimitive.decodeFinite(from: container, forKey: .reasoning)
                self.cache = try container.decode(TokenUsageSchema.Cache.self, forKey: .cache)
            }

            enum CodingKeys: String, CodingKey {
                case total
                case input
                case output
                case reasoning
                case cache
            }
        }

        // parity: schema/src/v1/session.ts#StepFinishPart [status=implemented hash=3a08a3773941]
        public struct StepFinishPart: Equatable, Hashable, Sendable, Codable {
            public let id: PartID
            public let sessionID: SessionID
            public let messageID: MessageID
            public let reason: String
            public let snapshot: String?
            public let cost: Double
            public let tokens: StepTokens

            public init(
                id: PartID,
                sessionID: SessionID,
                messageID: MessageID,
                reason: String,
                snapshot: String? = nil,
                cost: Double,
                tokens: StepTokens
            ) {
                self.id = id
                self.sessionID = sessionID
                self.messageID = messageID
                self.reason = reason
                self.snapshot = snapshot
                self.cost = cost
                self.tokens = tokens
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                try SchemaPrimitive.decodeRequiredLiteral("step-finish", from: container, forKey: .type)
                self.id = try container.decode(PartID.self, forKey: .id)
                self.sessionID = try container.decode(SessionID.self, forKey: .sessionID)
                self.messageID = try container.decode(MessageID.self, forKey: .messageID)
                self.reason = try container.decode(String.self, forKey: .reason)
                self.snapshot = try container.decodeIfPresent(String.self, forKey: .snapshot)
                self.cost = try SchemaPrimitive.decodeFinite(from: container, forKey: .cost)
                self.tokens = try container.decode(StepTokens.self, forKey: .tokens)
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode("step-finish", forKey: .type)
                try container.encode(id, forKey: .id)
                try container.encode(sessionID, forKey: .sessionID)
                try container.encode(messageID, forKey: .messageID)
                try container.encode(reason, forKey: .reason)
                try container.encodeIfPresent(snapshot, forKey: .snapshot)
                try container.encode(cost, forKey: .cost)
                try container.encode(tokens, forKey: .tokens)
            }

            enum CodingKeys: String, CodingKey {
                case type
                case id
                case sessionID
                case messageID
                case reason
                case snapshot
                case cost
                case tokens
            }
        }

        // MARK: Tool States & Tool Part

        // parity: schema/src/v1/session.ts#ToolStatePending [status=implemented hash=0821dddde336]
        public struct ToolStatePending: Equatable, Hashable, Sendable, Codable {
            public let input: [String: JSONValue]
            public let raw: String

            public init(input: [String: JSONValue], raw: String) {
                self.input = input
                self.raw = raw
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                try SchemaPrimitive.decodeRequiredLiteral("pending", from: container, forKey: .status)
                self.input = try container.decode([String: JSONValue].self, forKey: .input)
                self.raw = try container.decode(String.self, forKey: .raw)
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode("pending", forKey: .status)
                try container.encode(input, forKey: .input)
                try container.encode(raw, forKey: .raw)
            }

            enum CodingKeys: String, CodingKey {
                case status
                case input
                case raw
            }
        }

        // parity: schema/src/v1/session.ts#ToolStateRunning [status=implemented hash=e9d779c695c4]
        public struct ToolStateRunning: Equatable, Hashable, Sendable, Codable {
            public struct Time: Equatable, Hashable, Sendable, Codable {
                public let start: SchemaPrimitive.NonNegativeInt

                public init(start: SchemaPrimitive.NonNegativeInt) {
                    self.start = start
                }
            }

            public let input: [String: JSONValue]
            public let title: String?
            public let metadata: [String: JSONValue]?
            public let time: Time

            public init(
                input: [String: JSONValue],
                title: String? = nil,
                metadata: [String: JSONValue]? = nil,
                time: Time
            ) {
                self.input = input
                self.title = title
                self.metadata = metadata
                self.time = time
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                try SchemaPrimitive.decodeRequiredLiteral("running", from: container, forKey: .status)
                self.input = try container.decode([String: JSONValue].self, forKey: .input)
                self.title = try container.decodeIfPresent(String.self, forKey: .title)
                self.metadata = try container.decodeIfPresent([String: JSONValue].self, forKey: .metadata)
                self.time = try container.decode(Time.self, forKey: .time)
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode("running", forKey: .status)
                try container.encode(input, forKey: .input)
                try container.encodeIfPresent(title, forKey: .title)
                try container.encodeIfPresent(metadata, forKey: .metadata)
                try container.encode(time, forKey: .time)
            }

            enum CodingKeys: String, CodingKey {
                case status
                case input
                case title
                case metadata
                case time
            }
        }

        // parity: schema/src/v1/session.ts#ToolStateCompleted [status=implemented hash=23216be88829]
        public struct ToolStateCompleted: Equatable, Hashable, Sendable, Codable {
            public struct Time: Equatable, Hashable, Sendable, Codable {
                public let start: SchemaPrimitive.NonNegativeInt
                public let end: SchemaPrimitive.NonNegativeInt
                public let compacted: SchemaPrimitive.NonNegativeInt?

                public init(
                    start: SchemaPrimitive.NonNegativeInt,
                    end: SchemaPrimitive.NonNegativeInt,
                    compacted: SchemaPrimitive.NonNegativeInt? = nil
                ) {
                    self.start = start
                    self.end = end
                    self.compacted = compacted
                }
            }

            public let input: [String: JSONValue]
            public let output: String
            public let title: String
            public let metadata: [String: JSONValue]
            public let time: Time
            public let attachments: [FilePart]?

            public init(
                input: [String: JSONValue],
                output: String,
                title: String,
                metadata: [String: JSONValue] = [:],
                time: Time,
                attachments: [FilePart]? = nil
            ) {
                self.input = input
                self.output = output
                self.title = title
                self.metadata = metadata
                self.time = time
                self.attachments = attachments
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                try SchemaPrimitive.decodeRequiredLiteral("completed", from: container, forKey: .status)
                self.input = try container.decode([String: JSONValue].self, forKey: .input)
                self.output = try container.decode(String.self, forKey: .output)
                self.title = try container.decode(String.self, forKey: .title)
                self.metadata = try container.decode([String: JSONValue].self, forKey: .metadata)
                self.time = try container.decode(Time.self, forKey: .time)
                self.attachments = try container.decodeIfPresent([FilePart].self, forKey: .attachments)
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode("completed", forKey: .status)
                try container.encode(input, forKey: .input)
                try container.encode(output, forKey: .output)
                try container.encode(title, forKey: .title)
                try container.encode(metadata, forKey: .metadata)
                try container.encode(time, forKey: .time)
                try container.encodeIfPresent(attachments, forKey: .attachments)
            }

            enum CodingKeys: String, CodingKey {
                case status
                case input
                case output
                case title
                case metadata
                case time
                case attachments
            }
        }

        // parity: schema/src/v1/session.ts#ToolStateError [status=implemented hash=687fde688150]
        public struct ToolStateError: Equatable, Hashable, Sendable, Codable {
            public struct Time: Equatable, Hashable, Sendable, Codable {
                public let start: SchemaPrimitive.NonNegativeInt
                public let end: SchemaPrimitive.NonNegativeInt

                public init(start: SchemaPrimitive.NonNegativeInt, end: SchemaPrimitive.NonNegativeInt) {
                    self.start = start
                    self.end = end
                }
            }

            public let input: [String: JSONValue]
            public let error: String
            public let metadata: [String: JSONValue]?
            public let time: Time

            public init(
                input: [String: JSONValue],
                error: String,
                metadata: [String: JSONValue]? = nil,
                time: Time
            ) {
                self.input = input
                self.error = error
                self.metadata = metadata
                self.time = time
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                try SchemaPrimitive.decodeRequiredLiteral("error", from: container, forKey: .status)
                self.input = try container.decode([String: JSONValue].self, forKey: .input)
                self.error = try container.decode(String.self, forKey: .error)
                self.metadata = try container.decodeIfPresent([String: JSONValue].self, forKey: .metadata)
                self.time = try container.decode(Time.self, forKey: .time)
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode("error", forKey: .status)
                try container.encode(input, forKey: .input)
                try container.encode(error, forKey: .error)
                try container.encodeIfPresent(metadata, forKey: .metadata)
                try container.encode(time, forKey: .time)
            }

            enum CodingKeys: String, CodingKey {
                case status
                case input
                case error
                case metadata
                case time
            }
        }

        // parity: schema/src/v1/session.ts#ToolState [status=implemented hash=f50c53184ad9]
        public enum ToolState: Equatable, Hashable, Sendable, Codable {
            case pending(ToolStatePending)
            case running(ToolStateRunning)
            case completed(ToolStateCompleted)
            case error(ToolStateError)

            enum TagKeys: String, CodingKey {
                case status
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: TagKeys.self)
                let status = try container.decode(String.self, forKey: .status)
                switch status {
                case "pending": self = .pending(try ToolStatePending(from: decoder))
                case "running": self = .running(try ToolStateRunning(from: decoder))
                case "completed": self = .completed(try ToolStateCompleted(from: decoder))
                case "error": self = .error(try ToolStateError(from: decoder))
                default:
                    throw DecodingError.dataCorruptedError(
                        forKey: .status,
                        in: container,
                        debugDescription: "Unknown SessionV1.ToolState status '\(status)'"
                    )
                }
            }

            public func encode(to encoder: Encoder) throws {
                switch self {
                case .pending(let v): try v.encode(to: encoder)
                case .running(let v): try v.encode(to: encoder)
                case .completed(let v): try v.encode(to: encoder)
                case .error(let v): try v.encode(to: encoder)
                }
            }
        }

        // parity: schema/src/v1/session.ts#ToolPart [status=implemented hash=c51892c5b762]
        public struct ToolPart: Equatable, Hashable, Sendable, Codable {
            public let id: PartID
            public let sessionID: SessionID
            public let messageID: MessageID
            public let callID: String
            public let tool: String
            public let state: ToolState
            public let metadata: [String: JSONValue]?

            public init(
                id: PartID,
                sessionID: SessionID,
                messageID: MessageID,
                callID: String,
                tool: String,
                state: ToolState,
                metadata: [String: JSONValue]? = nil
            ) {
                self.id = id
                self.sessionID = sessionID
                self.messageID = messageID
                self.callID = callID
                self.tool = tool
                self.state = state
                self.metadata = metadata
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                try SchemaPrimitive.decodeRequiredLiteral("tool", from: container, forKey: .type)
                self.id = try container.decode(PartID.self, forKey: .id)
                self.sessionID = try container.decode(SessionID.self, forKey: .sessionID)
                self.messageID = try container.decode(MessageID.self, forKey: .messageID)
                self.callID = try container.decode(String.self, forKey: .callID)
                self.tool = try container.decode(String.self, forKey: .tool)
                self.state = try container.decode(ToolState.self, forKey: .state)
                self.metadata = try container.decodeIfPresent([String: JSONValue].self, forKey: .metadata)
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode("tool", forKey: .type)
                try container.encode(id, forKey: .id)
                try container.encode(sessionID, forKey: .sessionID)
                try container.encode(messageID, forKey: .messageID)
                try container.encode(callID, forKey: .callID)
                try container.encode(tool, forKey: .tool)
                try container.encode(state, forKey: .state)
                try container.encodeIfPresent(metadata, forKey: .metadata)
            }

            enum CodingKeys: String, CodingKey {
                case type
                case id
                case sessionID
                case messageID
                case callID
                case tool
                case state
                case metadata
            }
        }

        // parity: schema/src/v1/session.ts#Part [status=implemented hash=8a845926b1eb]
        public enum Part: Equatable, Hashable, Sendable, Codable {
            case text(TextPart)
            case subtask(SubtaskPart)
            case reasoning(ReasoningPart)
            case file(FilePart)
            case tool(ToolPart)
            case stepStart(StepStartPart)
            case stepFinish(StepFinishPart)
            case snapshot(SnapshotPart)
            case patch(PatchPart)
            case agent(AgentPart)
            case retry(RetryPart)
            case compaction(CompactionPart)

            enum TagKeys: String, CodingKey {
                case type
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: TagKeys.self)
                let type = try container.decode(String.self, forKey: .type)
                switch type {
                case "text": self = .text(try TextPart(from: decoder))
                case "subtask": self = .subtask(try SubtaskPart(from: decoder))
                case "reasoning": self = .reasoning(try ReasoningPart(from: decoder))
                case "file": self = .file(try FilePart(from: decoder))
                case "tool": self = .tool(try ToolPart(from: decoder))
                case "step-start": self = .stepStart(try StepStartPart(from: decoder))
                case "step-finish": self = .stepFinish(try StepFinishPart(from: decoder))
                case "snapshot": self = .snapshot(try SnapshotPart(from: decoder))
                case "patch": self = .patch(try PatchPart(from: decoder))
                case "agent": self = .agent(try AgentPart(from: decoder))
                case "retry": self = .retry(try RetryPart(from: decoder))
                case "compaction": self = .compaction(try CompactionPart(from: decoder))
                default:
                    throw DecodingError.dataCorruptedError(
                        forKey: .type,
                        in: container,
                        debugDescription: "Unknown SessionV1.Part type '\(type)'"
                    )
                }
            }

            public func encode(to encoder: Encoder) throws {
                switch self {
                case .text(let v): try v.encode(to: encoder)
                case .subtask(let v): try v.encode(to: encoder)
                case .reasoning(let v): try v.encode(to: encoder)
                case .file(let v): try v.encode(to: encoder)
                case .tool(let v): try v.encode(to: encoder)
                case .stepStart(let v): try v.encode(to: encoder)
                case .stepFinish(let v): try v.encode(to: encoder)
                case .snapshot(let v): try v.encode(to: encoder)
                case .patch(let v): try v.encode(to: encoder)
                case .agent(let v): try v.encode(to: encoder)
                case .retry(let v): try v.encode(to: encoder)
                case .compaction(let v): try v.encode(to: encoder)
                }
            }
        }

        // MARK: Part Inputs

        // parity: schema/src/v1/session.ts#TextPartInput [status=implemented hash=044f6ab3b6a2]
        public struct TextPartInput: Equatable, Hashable, Sendable, Codable {
            public let id: PartID?
            public let text: String
            public let synthetic: Bool?
            public let ignored: Bool?
            public let time: TimeSpan?
            public let metadata: [String: JSONValue]?

            public init(
                id: PartID? = nil,
                text: String,
                synthetic: Bool? = nil,
                ignored: Bool? = nil,
                time: TimeSpan? = nil,
                metadata: [String: JSONValue]? = nil
            ) {
                self.id = id
                self.text = text
                self.synthetic = synthetic
                self.ignored = ignored
                self.time = time
                self.metadata = metadata
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                try SchemaPrimitive.decodeRequiredLiteral("text", from: container, forKey: .type)
                self.id = try container.decodeIfPresent(PartID.self, forKey: .id)
                self.text = try container.decode(String.self, forKey: .text)
                self.synthetic = try container.decodeIfPresent(Bool.self, forKey: .synthetic)
                self.ignored = try container.decodeIfPresent(Bool.self, forKey: .ignored)
                self.time = try container.decodeIfPresent(TimeSpan.self, forKey: .time)
                self.metadata = try container.decodeIfPresent([String: JSONValue].self, forKey: .metadata)
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode("text", forKey: .type)
                try container.encodeIfPresent(id, forKey: .id)
                try container.encode(text, forKey: .text)
                try container.encodeIfPresent(synthetic, forKey: .synthetic)
                try container.encodeIfPresent(ignored, forKey: .ignored)
                try container.encodeIfPresent(time, forKey: .time)
                try container.encodeIfPresent(metadata, forKey: .metadata)
            }

            enum CodingKeys: String, CodingKey {
                case type
                case id
                case text
                case synthetic
                case ignored
                case time
                case metadata
            }
        }

        // parity: schema/src/v1/session.ts#FilePartInput [status=implemented hash=0c3e26ea3b0e]
        public struct FilePartInput: Equatable, Hashable, Sendable, Codable {
            public let id: PartID?
            public let mime: String
            public let filename: String?
            public let url: String
            public let source: FilePartSource?

            public init(
                id: PartID? = nil,
                mime: String,
                filename: String? = nil,
                url: String,
                source: FilePartSource? = nil
            ) {
                self.id = id
                self.mime = mime
                self.filename = filename
                self.url = url
                self.source = source
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                try SchemaPrimitive.decodeRequiredLiteral("file", from: container, forKey: .type)
                self.id = try container.decodeIfPresent(PartID.self, forKey: .id)
                self.mime = try container.decode(String.self, forKey: .mime)
                self.filename = try container.decodeIfPresent(String.self, forKey: .filename)
                self.url = try container.decode(String.self, forKey: .url)
                self.source = try container.decodeIfPresent(FilePartSource.self, forKey: .source)
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode("file", forKey: .type)
                try container.encodeIfPresent(id, forKey: .id)
                try container.encode(mime, forKey: .mime)
                try container.encodeIfPresent(filename, forKey: .filename)
                try container.encode(url, forKey: .url)
                try container.encodeIfPresent(source, forKey: .source)
            }

            enum CodingKeys: String, CodingKey {
                case type
                case id
                case mime
                case filename
                case url
                case source
            }
        }

        // parity: schema/src/v1/session.ts#AgentPartInput [status=implemented hash=c00ba41b5eee]
        public struct AgentPartInput: Equatable, Hashable, Sendable, Codable {
            public let id: PartID?
            public let name: String
            public let source: AgentSourceSpan?

            public init(id: PartID? = nil, name: String, source: AgentSourceSpan? = nil) {
                self.id = id
                self.name = name
                self.source = source
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                try SchemaPrimitive.decodeRequiredLiteral("agent", from: container, forKey: .type)
                self.id = try container.decodeIfPresent(PartID.self, forKey: .id)
                self.name = try container.decode(String.self, forKey: .name)
                self.source = try container.decodeIfPresent(AgentSourceSpan.self, forKey: .source)
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode("agent", forKey: .type)
                try container.encodeIfPresent(id, forKey: .id)
                try container.encode(name, forKey: .name)
                try container.encodeIfPresent(source, forKey: .source)
            }

            enum CodingKeys: String, CodingKey {
                case type
                case id
                case name
                case source
            }
        }

        // parity: schema/src/v1/session.ts#SubtaskPartInput [status=implemented hash=cce0f1ea15b9]
        public struct SubtaskPartInput: Equatable, Hashable, Sendable, Codable {
            public let id: PartID?
            public let prompt: String
            public let description: String
            public let agent: String
            public let model: ModelSelectionRef?
            public let command: String?

            public init(
                id: PartID? = nil,
                prompt: String,
                description: String,
                agent: String,
                model: ModelSelectionRef? = nil,
                command: String? = nil
            ) {
                self.id = id
                self.prompt = prompt
                self.description = description
                self.agent = agent
                self.model = model
                self.command = command
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                try SchemaPrimitive.decodeRequiredLiteral("subtask", from: container, forKey: .type)
                self.id = try container.decodeIfPresent(PartID.self, forKey: .id)
                self.prompt = try container.decode(String.self, forKey: .prompt)
                self.description = try container.decode(String.self, forKey: .description)
                self.agent = try container.decode(String.self, forKey: .agent)
                self.model = try container.decodeIfPresent(ModelSelectionRef.self, forKey: .model)
                self.command = try container.decodeIfPresent(String.self, forKey: .command)
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode("subtask", forKey: .type)
                try container.encodeIfPresent(id, forKey: .id)
                try container.encode(prompt, forKey: .prompt)
                try container.encode(description, forKey: .description)
                try container.encode(agent, forKey: .agent)
                try container.encodeIfPresent(model, forKey: .model)
                try container.encodeIfPresent(command, forKey: .command)
            }

            enum CodingKeys: String, CodingKey {
                case type
                case id
                case prompt
                case description
                case agent
                case model
                case command
            }
        }

        // MARK: Messages

        // parity: schema/src/v1/session.ts#User [status=implemented hash=58a25252ad1d]
        public struct User: Equatable, Hashable, Sendable, Codable {
            public struct Time: Equatable, Hashable, Sendable, Codable {
                public let created: Double

                public init(created: Double) {
                    self.created = created
                }

                public init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    let value = try SchemaPrimitive.decodeFinite(from: container, forKey: .created)
                    guard value >= 0 else {
                        throw DecodingError.dataCorruptedError(
                            forKey: .created,
                            in: container,
                            debugDescription: "Expected non-negative timestamp, got \(value)"
                        )
                    }
                    self.created = value
                }

                enum CodingKeys: String, CodingKey {
                    case created
                }
            }

            public struct Summary: Equatable, Hashable, Sendable, Codable {
                public let title: String?
                public let body: String?
                public let diffs: [FileDiffSchema.LegacyInfo]

                public init(title: String? = nil, body: String? = nil, diffs: [FileDiffSchema.LegacyInfo]) {
                    self.title = title
                    self.body = body
                    self.diffs = diffs
                }
            }

            public struct ModelRef: Equatable, Hashable, Sendable, Codable {
                public let providerID: ProviderSchema.ID
                public let modelID: ModelSchema.ID
                public let variant: String?

                public init(providerID: ProviderSchema.ID, modelID: ModelSchema.ID, variant: String? = nil) {
                    self.providerID = providerID
                    self.modelID = modelID
                    self.variant = variant
                }
            }

            public let id: MessageID
            public let sessionID: SessionID
            public let time: Time
            public let format: Format?
            public let summary: Summary?
            public let agent: String
            public let model: ModelRef
            public let system: String?
            public let tools: [String: Bool]?

            public init(
                id: MessageID,
                sessionID: SessionID,
                time: Time,
                format: Format? = nil,
                summary: Summary? = nil,
                agent: String,
                model: ModelRef,
                system: String? = nil,
                tools: [String: Bool]? = nil
            ) {
                self.id = id
                self.sessionID = sessionID
                self.time = time
                self.format = format
                self.summary = summary
                self.agent = agent
                self.model = model
                self.system = system
                self.tools = tools
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                try SchemaPrimitive.decodeRequiredLiteral("user", from: container, forKey: .role)
                self.id = try container.decode(MessageID.self, forKey: .id)
                self.sessionID = try container.decode(SessionID.self, forKey: .sessionID)
                self.time = try container.decode(Time.self, forKey: .time)
                self.format = try container.decodeIfPresent(Format.self, forKey: .format)
                self.summary = try container.decodeIfPresent(Summary.self, forKey: .summary)
                self.agent = try container.decode(String.self, forKey: .agent)
                self.model = try container.decode(ModelRef.self, forKey: .model)
                self.system = try container.decodeIfPresent(String.self, forKey: .system)
                self.tools = try container.decodeIfPresent([String: Bool].self, forKey: .tools)
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode("user", forKey: .role)
                try container.encode(id, forKey: .id)
                try container.encode(sessionID, forKey: .sessionID)
                try container.encode(time, forKey: .time)
                try container.encodeIfPresent(format, forKey: .format)
                try container.encodeIfPresent(summary, forKey: .summary)
                try container.encode(agent, forKey: .agent)
                try container.encode(model, forKey: .model)
                try container.encodeIfPresent(system, forKey: .system)
                try container.encodeIfPresent(tools, forKey: .tools)
            }

            enum CodingKeys: String, CodingKey {
                case role
                case id
                case sessionID
                case time
                case format
                case summary
                case agent
                case model
                case system
                case tools
            }
        }

        // parity: schema/src/v1/session.ts#Assistant [status=implemented hash=40b553b76810]
        public struct Assistant: Equatable, Hashable, Sendable, Codable {
            public struct Time: Equatable, Hashable, Sendable, Codable {
                public let created: SchemaPrimitive.NonNegativeInt
                public let completed: SchemaPrimitive.NonNegativeInt?

                public init(
                    created: SchemaPrimitive.NonNegativeInt,
                    completed: SchemaPrimitive.NonNegativeInt? = nil
                ) {
                    self.created = created
                    self.completed = completed
                }
            }

            public struct PathInfo: Equatable, Hashable, Sendable, Codable {
                public let cwd: String
                public let root: String

                public init(cwd: String, root: String) {
                    self.cwd = cwd
                    self.root = root
                }
            }

            public let id: MessageID
            public let sessionID: SessionID
            public let time: Time
            public let error: AssistantError?
            public let parentID: MessageID
            public let modelID: ModelSchema.ID
            public let providerID: ProviderSchema.ID
            public let mode: String
            public let agent: String
            public let path: PathInfo
            public let summary: Bool?
            public let cost: Double
            public let tokens: StepTokens
            public let structured: JSONValue?
            public let variant: String?
            public let finish: String?

            public init(
                id: MessageID,
                sessionID: SessionID,
                time: Time,
                error: AssistantError? = nil,
                parentID: MessageID,
                modelID: ModelSchema.ID,
                providerID: ProviderSchema.ID,
                mode: String,
                agent: String,
                path: PathInfo,
                summary: Bool? = nil,
                cost: Double,
                tokens: StepTokens,
                structured: JSONValue? = nil,
                variant: String? = nil,
                finish: String? = nil
            ) {
                self.id = id
                self.sessionID = sessionID
                self.time = time
                self.error = error
                self.parentID = parentID
                self.modelID = modelID
                self.providerID = providerID
                self.mode = mode
                self.agent = agent
                self.path = path
                self.summary = summary
                self.cost = cost
                self.tokens = tokens
                self.structured = structured
                self.variant = variant
                self.finish = finish
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                try SchemaPrimitive.decodeRequiredLiteral("assistant", from: container, forKey: .role)
                self.id = try container.decode(MessageID.self, forKey: .id)
                self.sessionID = try container.decode(SessionID.self, forKey: .sessionID)
                self.time = try container.decode(Time.self, forKey: .time)
                self.error = try container.decodeIfPresent(AssistantError.self, forKey: .error)
                self.parentID = try container.decode(MessageID.self, forKey: .parentID)
                self.modelID = try container.decode(ModelSchema.ID.self, forKey: .modelID)
                self.providerID = try container.decode(ProviderSchema.ID.self, forKey: .providerID)
                self.mode = try container.decode(String.self, forKey: .mode)
                self.agent = try container.decode(String.self, forKey: .agent)
                self.path = try container.decode(PathInfo.self, forKey: .path)
                self.summary = try container.decodeIfPresent(Bool.self, forKey: .summary)
                self.cost = try SchemaPrimitive.decodeFinite(from: container, forKey: .cost)
                self.tokens = try container.decode(StepTokens.self, forKey: .tokens)
                self.structured = try container.decodeIfPresent(JSONValue.self, forKey: .structured)
                self.variant = try container.decodeIfPresent(String.self, forKey: .variant)
                self.finish = try container.decodeIfPresent(String.self, forKey: .finish)
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode("assistant", forKey: .role)
                try container.encode(id, forKey: .id)
                try container.encode(sessionID, forKey: .sessionID)
                try container.encode(time, forKey: .time)
                try container.encodeIfPresent(error, forKey: .error)
                try container.encode(parentID, forKey: .parentID)
                try container.encode(modelID, forKey: .modelID)
                try container.encode(providerID, forKey: .providerID)
                try container.encode(mode, forKey: .mode)
                try container.encode(agent, forKey: .agent)
                try container.encode(path, forKey: .path)
                try container.encodeIfPresent(summary, forKey: .summary)
                try container.encode(cost, forKey: .cost)
                try container.encode(tokens, forKey: .tokens)
                try container.encodeIfPresent(structured, forKey: .structured)
                try container.encodeIfPresent(variant, forKey: .variant)
                try container.encodeIfPresent(finish, forKey: .finish)
            }

            enum CodingKeys: String, CodingKey {
                case role
                case id
                case sessionID
                case time
                case error
                case parentID
                case modelID
                case providerID
                case mode
                case agent
                case path
                case summary
                case cost
                case tokens
                case structured
                case variant
                case finish
            }
        }

        // parity: schema/src/v1/session.ts#Info [status=implemented hash=edd914a128c2]
        public enum Info: Equatable, Hashable, Sendable, Codable {
            case user(User)
            case assistant(Assistant)

            enum TagKeys: String, CodingKey {
                case role
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: TagKeys.self)
                let role = try container.decode(String.self, forKey: .role)
                switch role {
                case "user": self = .user(try User(from: decoder))
                case "assistant": self = .assistant(try Assistant(from: decoder))
                default:
                    throw DecodingError.dataCorruptedError(
                        forKey: .role,
                        in: container,
                        debugDescription: "Unknown SessionV1.Message role '\(role)'"
                    )
                }
            }

            public func encode(to encoder: Encoder) throws {
                switch self {
                case .user(let u): try u.encode(to: encoder)
                case .assistant(let a): try a.encode(to: encoder)
                }
            }
        }

        // MARK: SessionInfo

        public struct SessionSummary: Equatable, Hashable, Sendable, Codable {
            public let additions: Double
            public let deletions: Double
            public let files: Double
            public let diffs: [FileDiffSchema.LegacyInfo]?

            public init(
                additions: Double,
                deletions: Double,
                files: Double,
                diffs: [FileDiffSchema.LegacyInfo]? = nil
            ) {
                self.additions = additions
                self.deletions = deletions
                self.files = files
                self.diffs = diffs
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.additions = try SchemaPrimitive.decodeFinite(from: container, forKey: .additions)
                self.deletions = try SchemaPrimitive.decodeFinite(from: container, forKey: .deletions)
                self.files = try SchemaPrimitive.decodeFinite(from: container, forKey: .files)
                self.diffs = try container.decodeIfPresent([FileDiffSchema.LegacyInfo].self, forKey: .diffs)
            }

            enum CodingKeys: String, CodingKey {
                case additions
                case deletions
                case files
                case diffs
            }
        }

        public struct SessionShare: Equatable, Hashable, Sendable, Codable {
            public let url: String

            public init(url: String) {
                self.url = url
            }
        }

        public struct SessionRevert: Equatable, Hashable, Sendable, Codable {
            public let messageID: MessageID
            public let partID: PartID?
            public let snapshot: String?
            public let diff: String?

            public init(
                messageID: MessageID,
                partID: PartID? = nil,
                snapshot: String? = nil,
                diff: String? = nil
            ) {
                self.messageID = messageID
                self.partID = partID
                self.snapshot = snapshot
                self.diff = diff
            }
        }

        public struct SessionModel: Equatable, Hashable, Sendable, Codable {
            public let id: ModelSchema.ID
            public let providerID: ProviderSchema.ID
            public let variant: String?

            public init(id: ModelSchema.ID, providerID: ProviderSchema.ID, variant: String? = nil) {
                self.id = id
                self.providerID = providerID
                self.variant = variant
            }
        }

        public struct SessionTime: Equatable, Hashable, Sendable, Codable {
            public let created: SchemaPrimitive.NonNegativeInt
            public let updated: SchemaPrimitive.NonNegativeInt
            public let compacting: SchemaPrimitive.NonNegativeInt?
            public let archived: Double?

            public init(
                created: SchemaPrimitive.NonNegativeInt,
                updated: SchemaPrimitive.NonNegativeInt,
                compacting: SchemaPrimitive.NonNegativeInt? = nil,
                archived: Double? = nil
            ) {
                self.created = created
                self.updated = updated
                self.compacting = compacting
                self.archived = archived
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.created = try container.decode(SchemaPrimitive.NonNegativeInt.self, forKey: .created)
                self.updated = try container.decode(SchemaPrimitive.NonNegativeInt.self, forKey: .updated)
                self.compacting = try container.decodeIfPresent(
                    SchemaPrimitive.NonNegativeInt.self,
                    forKey: .compacting
                )
                self.archived = try SchemaPrimitive.decodeFiniteIfPresent(from: container, forKey: .archived)
            }

            enum CodingKeys: String, CodingKey {
                case created
                case updated
                case compacting
                case archived
            }
        }

        // parity: schema/src/v1/session.ts#SessionInfo [status=implemented hash=24559797caab]
        public struct SessionInfo: Equatable, Hashable, Sendable, Codable {
            public let id: SessionID
            public let slug: String
            public let projectID: ProjectID
            public let workspaceID: WorkspaceID?
            public let directory: String
            public let path: String?
            public let parentID: SessionID?
            public let summary: SessionSummary?
            public let cost: Double?
            public let tokens: TokenUsageSchema.Info?
            public let share: SessionShare?
            public let title: String?
            public let agent: String?
            public let model: SessionModel?
            public let version: String
            public let metadata: [String: JSONValue]?
            public let time: SessionTime
            public let permission: Permission.Ruleset?
            public let revert: SessionRevert?

            public init(
                id: SessionID,
                slug: String,
                projectID: ProjectID,
                workspaceID: WorkspaceID? = nil,
                directory: String,
                path: String? = nil,
                parentID: SessionID? = nil,
                summary: SessionSummary? = nil,
                cost: Double? = nil,
                tokens: TokenUsageSchema.Info? = nil,
                share: SessionShare? = nil,
                title: String? = nil,
                agent: String? = nil,
                model: SessionModel? = nil,
                version: String,
                metadata: [String: JSONValue]? = nil,
                time: SessionTime,
                permission: Permission.Ruleset? = nil,
                revert: SessionRevert? = nil
            ) {
                self.id = id
                self.slug = slug
                self.projectID = projectID
                self.workspaceID = workspaceID
                self.directory = directory
                self.path = path
                self.parentID = parentID
                self.summary = summary
                self.cost = cost
                self.tokens = tokens
                self.share = share
                self.title = title
                self.agent = agent
                self.model = model
                self.version = version
                self.metadata = metadata
                self.time = time
                self.permission = permission
                self.revert = revert
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.id = try container.decode(SessionID.self, forKey: .id)
                self.slug = try container.decode(String.self, forKey: .slug)
                self.projectID = try container.decode(ProjectID.self, forKey: .projectID)
                self.workspaceID = try container.decodeIfPresent(WorkspaceID.self, forKey: .workspaceID)
                self.directory = try container.decode(String.self, forKey: .directory)
                self.path = try container.decodeIfPresent(String.self, forKey: .path)
                self.parentID = try container.decodeIfPresent(SessionID.self, forKey: .parentID)
                self.summary = try container.decodeIfPresent(SessionSummary.self, forKey: .summary)
                self.cost = try SchemaPrimitive.decodeFiniteIfPresent(from: container, forKey: .cost)
                self.tokens = try container.decodeIfPresent(TokenUsageSchema.Info.self, forKey: .tokens)
                self.share = try container.decodeIfPresent(SessionShare.self, forKey: .share)
                self.title = try container.decodeIfPresent(String.self, forKey: .title)
                self.agent = try container.decodeIfPresent(String.self, forKey: .agent)
                self.model = try container.decodeIfPresent(SessionModel.self, forKey: .model)
                self.version = try container.decode(String.self, forKey: .version)
                self.metadata = try container.decodeIfPresent([String: JSONValue].self, forKey: .metadata)
                self.time = try container.decode(SessionTime.self, forKey: .time)
                self.permission = try container.decodeIfPresent(Permission.Ruleset.self, forKey: .permission)
                self.revert = try container.decodeIfPresent(SessionRevert.self, forKey: .revert)
            }

            enum CodingKeys: String, CodingKey {
                case id
                case slug
                case projectID
                case workspaceID
                case directory
                case path
                case parentID
                case summary
                case cost
                case tokens
                case share
                case title
                case agent
                case model
                case version
                case metadata
                case time
                case permission
                case revert
            }
        }

        // MARK: Events

        public struct PartDeltaPayload: Equatable, Hashable, Sendable, Codable {
            public let sessionID: SessionID
            public let messageID: MessageID
            public let partID: PartID
            public let field: String
            public let delta: String

            public init(sessionID: SessionID, messageID: MessageID, partID: PartID, field: String, delta: String) {
                self.sessionID = sessionID
                self.messageID = messageID
                self.partID = partID
                self.field = field
                self.delta = delta
            }
        }

        public struct DiffPayload: Equatable, Hashable, Sendable, Codable {
            public let sessionID: SessionID
            public let diff: [FileDiffSchema.LegacyInfo]

            public init(sessionID: SessionID, diff: [FileDiffSchema.LegacyInfo]) {
                self.sessionID = sessionID
                self.diff = diff
            }
        }

        public struct ErrorPayload: Equatable, Hashable, Sendable, Codable {
            public let sessionID: SessionID?
            public let error: AssistantError?

            public init(sessionID: SessionID? = nil, error: AssistantError? = nil) {
                self.sessionID = sessionID
                self.error = error
            }
        }

        // parity: schema/src/v1/session.ts#PartDelta [status=implemented hash=ac719986e832]
        public static let partDelta = SchemaPrimitive.EventDescriptor.ephemeral(type: "message.part.delta")

        // parity: schema/src/v1/session.ts#Diff [status=implemented hash=998162ce69a4]
        public static let diff = SchemaPrimitive.EventDescriptor.ephemeral(type: "session.diff")

        // parity: schema/src/v1/session.ts#Error [status=implemented hash=7d8bf038a888]
        public static let sessionError = SchemaPrimitive.EventDescriptor.ephemeral(type: "session.error")

        // parity: schema/src/v1/session.ts#Event [status=implemented hash=5a0a4867f73e]
        public enum Event {
            public static let created = SchemaPrimitive.EventDescriptor.durable(
                type: "session.created",
                aggregate: "sessionID",
                version: 1
            )
            public static let updated = SchemaPrimitive.EventDescriptor.durable(
                type: "session.updated",
                aggregate: "sessionID",
                version: 1
            )
            public static let deleted = SchemaPrimitive.EventDescriptor.durable(
                type: "session.deleted",
                aggregate: "sessionID",
                version: 1
            )
            public static let messageUpdated = SchemaPrimitive.EventDescriptor.durable(
                type: "message.updated",
                aggregate: "sessionID",
                version: 1
            )
            public static let messageRemoved = SchemaPrimitive.EventDescriptor.durable(
                type: "message.removed",
                aggregate: "sessionID",
                version: 1
            )
            public static let partUpdated = SchemaPrimitive.EventDescriptor.durable(
                type: "message.part.updated",
                aggregate: "sessionID",
                version: 1
            )
            public static let partRemoved = SchemaPrimitive.EventDescriptor.durable(
                type: "message.part.removed",
                aggregate: "sessionID",
                version: 1
            )
            public static let partDelta = Session.partDelta
            public static let diff = Session.diff
            public static let error = Session.sessionError

            public static let definitions: [SchemaPrimitive.EventDescriptor] = [
                created,
                updated,
                deleted,
                messageUpdated,
                messageRemoved,
                partUpdated,
                partRemoved,
                partDelta,
                diff,
                error,
            ]
        }
    }
}
