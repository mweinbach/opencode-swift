#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Synchronization
import OpenCodeAI
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

// MARK: - session/schema.ts

public enum CoreSessionSchema {
    // parity: core/src/session/schema.ts#ID [status=implemented hash=46a615c5cb10]
    public typealias ID = SessionID

    // parity: core/src/session/schema.ts#Info [status=implemented hash=7edea1644fe2]
    public typealias Info = SessionSchema.Info
}

// MARK: - session/error.ts

/// Complete typed session error hierarchy (`packages/core/src/session/error.ts`).
public enum CoreSessionErrors {
    // parity: core/src/session/error.ts#NotFoundError [status=implemented hash=7da886e8cc82]
    public struct NotFoundError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public static let tag = "Session.NotFoundError"
        public let sessionID: SessionID

        public init(sessionID: SessionID) {
            self.sessionID = sessionID
        }

        public var description: String { "Session not found: \(sessionID.rawValue)" }
    }

    // parity: core/src/session/error.ts#InvalidListCursorError [status=implemented hash=aff85e925c6c]
    public struct InvalidListCursorError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public static let tag = "Session.InvalidListCursorError"
        public init() {}
        // parity: core/src/session/error.ts#InvalidListCursorError.message [status=implemented hash=ec81fbc0e4ae]
        public var message: String { "Invalid cursor" }
        public var description: String { message }
    }

    // parity: core/src/session/error.ts#MessageNotFoundError [status=implemented hash=af311e98ee93]
    public struct MessageNotFoundError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public static let tag = "Session.MessageNotFoundError"
        public let sessionID: SessionID
        public let messageID: SessionMessageSchema.ID

        public init(sessionID: SessionID, messageID: SessionMessageSchema.ID) {
            self.sessionID = sessionID
            self.messageID = messageID
        }

        public var description: String { "Message \(messageID.rawValue) not found in session \(sessionID.rawValue)" }
    }

    // parity: core/src/session/error.ts#ForkEmptyError [status=implemented hash=5043e30af634]
    public struct ForkEmptyError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public static let tag = "Session.ForkEmptyError"
        public let sessionID: SessionID

        public init(sessionID: SessionID) {
            self.sessionID = sessionID
        }

        // parity: core/src/session/error.ts#ForkEmptyError.message [status=implemented hash=a11f2df8db08]
        public var message: String { "Cannot fork empty session: \(sessionID.rawValue)" }
        public var description: String { message }
    }

    // parity: core/src/session/error.ts#MessageDecodeError [status=implemented hash=a1996b518f07]
    public struct MessageDecodeError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public static let tag = "Session.MessageDecodeError"
        public let sessionID: SessionID
        public let messageID: SessionMessageSchema.ID

        public init(sessionID: SessionID, messageID: SessionMessageSchema.ID) {
            self.sessionID = sessionID
            self.messageID = messageID
        }

        // parity: core/src/session/error.ts#MessageDecodeError.message [status=implemented hash=16c47716f660]
        public var message: String { "Failed to decode message \(messageID.rawValue) in session \(sessionID.rawValue)" }
        public var description: String { message }
    }

    // parity: core/src/session/error.ts#AgentNotFoundError [status=implemented hash=7ffd1bde9bd7]
    public struct AgentNotFoundError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public static let tag = "Session.AgentNotFoundError"
        public let sessionID: SessionID
        public let agent: String

        public init(sessionID: SessionID, agent: String) {
            self.sessionID = sessionID
            self.agent = agent
        }

        // parity: core/src/session/error.ts#AgentNotFoundError.message [status=implemented hash=cf3a1725228f]
        public var message: String { "Agent not found: \"\(agent)\"" }
        public var description: String { message }
    }

    // parity: core/src/session/error.ts#StepFailedError [status=implemented hash=8b9510f82a7f]
    public struct StepFailedError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public static let tag = "Session.StepFailedError"
        public let error: SessionErrorSchema.Error

        public init(error: SessionErrorSchema.Error) {
            self.error = error
        }

        // parity: core/src/session/error.ts#StepFailedError.message [status=implemented hash=4f27fe67572e]
        public var message: String { error.message }
        public var description: String { message }
    }

    // parity: core/src/session/error.ts#PromptConflictError [status=implemented hash=253b0716ab09]
    public struct PromptConflictError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public static let tag = "Session.PromptConflictError"
        public let sessionID: SessionID
        public let messageID: SessionMessageSchema.ID

        public init(sessionID: SessionID, messageID: SessionMessageSchema.ID) {
            self.sessionID = sessionID
            self.messageID = messageID
        }

        public var description: String { "Prompt conflict for message \(messageID.rawValue) in session \(sessionID.rawValue)" }
    }

    // parity: core/src/session/error.ts#SyntheticConflictError [status=implemented hash=8467c6cabbac]
    public struct SyntheticConflictError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public static let tag = "Session.SyntheticConflictError"
        public let sessionID: SessionID
        public let inputID: SessionMessageSchema.ID

        public init(sessionID: SessionID, inputID: SessionMessageSchema.ID) {
            self.sessionID = sessionID
            self.inputID = inputID
        }

        public var description: String { "Synthetic conflict for input \(inputID.rawValue) in session \(sessionID.rawValue)" }
    }

    // parity: core/src/session/error.ts#AttachmentError [status=implemented hash=02bd17763829]
    public struct AttachmentError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public static let tag = "Session.AttachmentError"
        public let uri: String
        public let message: String

        public init(uri: String, message: String) {
            self.uri = uri
            self.message = message
        }

        public var description: String { message }
    }

    // parity: core/src/session/error.ts#CompactionConflictError [status=implemented hash=ced3f7791c88]
    public struct CompactionConflictError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public static let tag = "Session.CompactionConflictError"
        public let sessionID: SessionID
        public let inputID: SessionMessageSchema.ID

        public init(sessionID: SessionID, inputID: SessionMessageSchema.ID) {
            self.sessionID = sessionID
            self.inputID = inputID
        }

        public var description: String { "Compaction conflict for input \(inputID.rawValue) in session \(sessionID.rawValue)" }
    }

    // parity: core/src/session/error.ts#BusyError [status=implemented hash=e2b1c1472cd5]
    public struct BusyError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public static let tag = "Session.BusyError"
        public let sessionID: SessionID

        public init(sessionID: SessionID) {
            self.sessionID = sessionID
        }

        public var description: String { "Session \(sessionID.rawValue) is currently busy" }
    }

    // parity: core/src/session/error.ts#InboxConflictError [status=implemented hash=f24c355227b4]
    public struct InboxConflictError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public static let tag = "Session.InboxConflictError"
        public let sessionID: SessionID
        public let inboxID: SessionMessageSchema.ID

        public init(sessionID: SessionID, inboxID: SessionMessageSchema.ID) {
            self.sessionID = sessionID
            self.inboxID = inboxID
        }

        public var description: String { "Inbox conflict for item \(inboxID.rawValue) in session \(sessionID.rawValue)" }
    }

    // parity: core/src/session/error.ts#SkillNotFoundError [status=implemented hash=345739215aa7]
    public struct SkillNotFoundError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public static let tag = "Session.SkillNotFoundError"
        public let skill: String

        public init(skill: String) {
            self.skill = skill
        }

        public var description: String { "Skill not found: \(skill)" }
    }
}

// MARK: - session/info.ts

public enum CoreSessionInfo {
    /// Projects a raw `session_v2` SQLite row into canonical `SessionSchema.Info`.
    // parity: core/src/session/info.ts#fromRow [status=implemented hash=bf3b4f0e2846]
    public static func fromRow(_ row: SQLiteRow) throws -> SessionSchema.Info {
        guard let idStr = row.string("id"),
              let id = SessionID(rawValue: idStr),
              let projectIDStr = row.string("project_id"),
              let directory = row.string("directory"),
              let timeCreated = row.int64("time_created"),
              let timeUpdated = row.int64("time_updated")
        else {
            throw SQLiteError.invalidParameter("Malformed session_v2 row")
        }

        let parentID = row.string("parent_id").flatMap(SessionID.init(rawValue:))
        let fork: SessionSchema.Info.Fork? = {
            guard let forkSessionStr = row.string("fork_session_id"),
                  let forkSessionID = SessionID(rawValue: forkSessionStr),
                  let boundaryRaw = row.string("fork_boundary"),
                  let boundary = try? CoreBusJSON.decodeFromString(boundaryRaw, as: SessionForkSchema.Boundary.self)
            else { return nil }
            return SessionSchema.Info.Fork(sessionID: forkSessionID, boundary: boundary)
        }()

        let model: SessionSchema.ModelRef? = row.string("model").flatMap { raw in
            guard let decoded = try? CoreBusJSON.decodeFromString(raw, as: SessionSchema.ModelRef.self) else {
                return nil
            }
            return SessionSchema.ModelRef(
                id: decoded.id,
                providerID: decoded.providerID,
                variant: decoded.variant ?? "default"
            )
        }

        let metadata: SessionSchema.Metadata? = row.string("metadata").flatMap {
            try? CoreBusJSON.decodeFromString($0, as: [String: JSONValue].self)
        }
        let permissions: SessionSchema.PermissionRuleset? = row.string("permission").flatMap {
            try? CoreBusJSON.decodeFromString($0, as: SessionSchema.PermissionRuleset.self)
        }
        let revert: SessionRevertSchema.Revert? = row.string("revert").flatMap {
            try? CoreBusJSON.decodeFromString($0, as: SessionRevertSchema.PersistedRevert.self).revert
        }
        let outcome = row.string("idle_outcome").flatMap(SessionSchema.Outcome.init(rawValue:))
        let workspaceID = row.string("workspace_id").flatMap(WorkspaceID.init(rawValue:))
        let subpath = row.string("path").flatMap { $0.isEmpty ? nil : $0 }

        return SessionSchema.Info(
            id: id,
            parentID: parentID,
            fork: fork,
            projectID: ProjectID(rawValue: projectIDStr),
            agent: row.string("agent"),
            model: model,
            cost: row.double("cost") ?? 0,
            tokens: SessionSchema.TokenUsage(
                input: Double(row.int64("tokens_input") ?? 0),
                output: Double(row.int64("tokens_output") ?? 0),
                reasoning: Double(row.int64("tokens_reasoning") ?? 0),
                cache: SessionSchema.TokenUsage.Cache(
                    read: Double(row.int64("tokens_cache_read") ?? 0),
                    write: Double(row.int64("tokens_cache_write") ?? 0)
                )
            ),
            outcome: outcome,
            time: SessionSchema.Info.Time(
                created: timeCreated,
                updated: timeUpdated,
                busy: row.int64("time_busy"),
                idle: row.int64("time_idle"),
                viewed: row.int64("time_viewed"),
                archived: row.int64("time_archived")
            ),
            title: row.string("title"),
            location: OpenCodeLocation(directory: directory, workspaceID: workspaceID),
            subpath: subpath,
            metadata: metadata,
            permissions: permissions,
            revert: revert
        )
    }
}

// MARK: - session/stored.ts

/// Storage-level user message & inbox shapes where attachments may be stored as `media:` blob refs.
/// Ports `packages/core/src/session/stored.ts`.
public enum CoreSessionStored {
    // parity: core/src/session/stored.ts#Ref [status=implemented hash=856807ec2989]
    public typealias Ref = PromptSchema.MediaRef

    // parity: core/src/session/stored.ts#refHash [status=implemented hash=9cc3a5e835e0]
    public static func refHash(_ ref: Ref) -> String {
        String(ref.rawValue.dropFirst("media:".count))
    }

    // parity: core/src/session/stored.ts#ref [status=implemented hash=cd11a758d7a7]
    public static func ref(_ hash: String) -> Ref? {
        Ref(rawValue: "media:\(hash)")
    }

    // parity: core/src/session/stored.ts#FileRef [status=implemented hash=f92b1372e62b]
    public struct FileRef: Equatable, Hashable, Sendable, Codable {
        public let mime: String
        public let source: PromptSchema.FileSource
        public let name: String?
        public let description: String?
        public let mention: PromptSchema.PromptMention?
        public let uri: Ref

        public init(
            mime: String,
            source: PromptSchema.FileSource,
            name: String? = nil,
            description: String? = nil,
            mention: PromptSchema.PromptMention? = nil,
            uri: Ref
        ) {
            self.mime = mime
            self.source = source
            self.name = name
            self.description = description
            self.mention = mention
            self.uri = uri
        }
    }

    // parity: core/src/session/stored.ts#File [status=implemented hash=1520a387cf44]
    public enum File: Equatable, Hashable, Sendable, Codable {
        case inline(PromptSchema.FileAttachment)
        case ref(FileRef)

        private enum ProbeKeys: String, CodingKey { case data, uri }

        public init(from decoder: Decoder) throws {
            let probe = try decoder.container(keyedBy: ProbeKeys.self)
            if probe.contains(.data) {
                self = .inline(try PromptSchema.FileAttachment(from: decoder))
            } else {
                self = .ref(try FileRef(from: decoder))
            }
        }

        public func encode(to encoder: Encoder) throws {
            switch self {
            case .inline(let f): try f.encode(to: encoder)
            case .ref(let r): try r.encode(to: encoder)
            }
        }
    }

    // parity: core/src/session/stored.ts#ToolFileRef [status=implemented hash=6630264f531f]
    public struct ToolFileRef: Equatable, Hashable, Sendable, Codable {
        public let uri: Ref
        public let mime: String
        public let name: String?

        public init(uri: Ref, mime: String, name: String? = nil) {
            self.uri = uri
            self.mime = mime
            self.name = name
        }
    }

    // parity: core/src/session/stored.ts#UserPayload [status=implemented hash=1ea4cb6f92a0]
    public struct UserPayload: Equatable, Hashable, Sendable, Codable {
        public let text: String
        public let files: [File]?
        public let agents: [PromptSchema.AgentAttachment]?
        public let skills: [PromptSchema.SkillAttachment]?
        public let metadata: [String: JSONValue]?

        public init(
            text: String,
            files: [File]? = nil,
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

    // parity: core/src/session/stored.ts#User [status=implemented hash=70ba30beba4f]
    public struct User: Equatable, Hashable, Sendable, Codable {
        public let id: SessionMessageSchema.ID
        public let metadata: [String: JSONValue]?
        public let time: SessionMessageSchema.TimeCreated
        public let text: String
        public let files: [File]?
        public let agents: [PromptSchema.AgentAttachment]?
        public let skills: [PromptSchema.SkillAttachment]?

        public init(
            id: SessionMessageSchema.ID,
            metadata: [String: JSONValue]? = nil,
            time: SessionMessageSchema.TimeCreated,
            text: String,
            files: [File]? = nil,
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
    }
}

// MARK: - session/blob.ts

/// Content-addressed deduplicated media blob storage and reference counting (`blob` / `blob_ref`).
/// Ports `packages/core/src/session/blob.ts`.
public enum CoreSessionBlob {
    public struct StoredMessageRow: Equatable, Sendable {
        public let id: SessionMessageSchema.ID
        public let sessionID: SessionID
        public let type: SessionMessageSchema.MessageType
        public let seq: Int64
        public let timeCreated: Int64
        public let timeUpdated: Int64
        public var data: [String: JSONValue]

        public init(
            id: SessionMessageSchema.ID,
            sessionID: SessionID,
            type: SessionMessageSchema.MessageType,
            seq: Int64,
            timeCreated: Int64,
            timeUpdated: Int64,
            data: [String: JSONValue]
        ) {
            self.id = id
            self.sessionID = sessionID
            self.type = type
            self.seq = seq
            self.timeCreated = timeCreated
            self.timeUpdated = timeUpdated
            self.data = data
        }
    }

    public struct StoredInboxRow: Equatable, Sendable {
        public let id: SessionMessageSchema.ID
        public let sessionID: SessionID
        public let type: String
        public var payload: [String: JSONValue]
        public let delivery: SessionInboxSchema.Delivery
        public let enqueuedSeq: Int64
        public let timeCreated: Int64

        public init(
            id: SessionMessageSchema.ID,
            sessionID: SessionID,
            type: String,
            payload: [String: JSONValue],
            delivery: SessionInboxSchema.Delivery,
            enqueuedSeq: Int64,
            timeCreated: Int64
        ) {
            self.id = id
            self.sessionID = sessionID
            self.type = type
            self.payload = payload
            self.delivery = delivery
            self.enqueuedSeq = enqueuedSeq
            self.timeCreated = timeCreated
        }
    }

    public struct BlobInsert: Equatable, Sendable {
        public let hash: String
        public let mime: String
        public let bytes: Int
        public let width: Int?
        public let height: Int?
        public let data: [UInt8]

        public init(hash: String, mime: String, bytes: Int, width: Int? = nil, height: Int? = nil, data: [UInt8]) {
            self.hash = hash
            self.mime = mime
            self.bytes = bytes
            self.width = width
            self.height = height
            self.data = data
        }
    }

    // parity: core/src/session/blob.ts#Meta [status=implemented hash=f2389ad77a1c]
    public struct Meta: Equatable, Hashable, Sendable {
        public let bytes: Int
        public let width: Int?
        public let height: Int?

        public init(bytes: Int, width: Int? = nil, height: Int? = nil) {
            self.bytes = bytes
            self.width = width
            self.height = height
        }
    }

    // parity: core/src/session/blob.ts#Owner [status=implemented hash=c6e56b129fc6]
    public struct Owner: Equatable, Hashable, Sendable {
        public let sessionID: SessionID
        public let messageID: SessionMessageSchema.ID
        public let seq: Int64

        public init(sessionID: SessionID, messageID: SessionMessageSchema.ID, seq: Int64) {
            self.sessionID = sessionID
            self.messageID = messageID
            self.seq = seq
        }
    }

    public struct SplitResult: Equatable, Sendable {
        public let data: [String: JSONValue]
        public let moved: Bool
        public let blobs: [BlobInsert]
        public let hashes: Set<String>
    }

    // parity: core/src/session/blob.ts#enabled [status=adapted hash=5ae23d0edda4]
    public static func enabled(flagEnabled: Bool = false) -> Bool {
        flagEnabled
    }

    // parity: core/src/session/blob.ts#enabledFor [status=adapted hash=60d89ba79d5c]
    public static func enabledFor(
        _ session: SessionSchema.Info,
        resolver: (@Sendable (SessionSchema.Info) async -> Bool)? = nil
    ) async -> Bool {
        guard let resolver else { return false }
        return await resolver(session)
    }

    // parity: core/src/session/blob.ts#ForkMedia [status=adapted hash=cabe166922ca]
    @TaskLocal public static var forkMedia: Bool = false

    // parity: core/src/session/blob.ts#hashBytes [status=implemented hash=1a9272a537a1]
    public static func hashBytes(_ raw: [UInt8]) -> String {
        Hash.sha256(raw)
    }

    private static func isMediaRefURI(_ value: JSONValue?) -> String? {
        guard case .string(let s) = value, PromptSchema.MediaRef.isValid(s) else { return nil }
        return String(s.dropFirst("media:".count))
    }

    private static func unavailableText(mime: String, name: String?) -> String {
        "[media unavailable: \(name.map { "\($0) (\(mime))" } ?? mime)]"
    }

    private static func collectHashes(from data: [String: JSONValue], into hashes: inout Set<String>) {
        if case .array(let files) = data["files"] {
            for item in files {
                if case .object(let obj) = item, let h = isMediaRefURI(obj["uri"]) {
                    hashes.insert(h)
                }
            }
        }
        if case .array(let content) = data["content"] {
            for part in content {
                if case .object(let obj) = part {
                    collectToolHashes(from: obj, into: &hashes)
                }
            }
        }
        if case .string("tool") = data["type"] {
            collectToolHashes(from: data, into: &hashes)
        }
    }

    private static func collectToolHashes(from part: [String: JSONValue], into hashes: inout Set<String>) {
        guard case .string("tool") = part["type"],
              case .object(let state) = part["state"],
              case .string(let status) = state["status"],
              status == "completed" || status == "error",
              case .array(let items) = state["content"]
        else { return }
        for item in items {
            if case .object(let obj) = item,
               case .string("file") = obj["type"],
               let h = isMediaRefURI(obj["uri"])
            {
                hashes.insert(h)
            }
        }
    }

    private static func loadBlobs(_ db: any SQLiteDatabase, hashes: Set<String>) throws -> [String: String] {
        guard !hashes.isEmpty else { return [:] }
        var blobs: [String: String] = [:]
        for batch in CoreDatabaseSchema.batches(Array(hashes), perItem: 1) {
            let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ", ")
            let rows = try db.query(
                "SELECT `hash`, `data` FROM `blob` WHERE `hash` IN (\(placeholders))",
                parameters: batch.map(SQLiteValue.text)
            )
            for row in rows {
                if let h = row.string("hash"), let bytes = row.blob("data") {
                    blobs[h] = bytesToBase64(bytes)
                }
            }
        }
        return blobs
    }

    private static func loadMeta(_ db: any SQLiteDatabase, hashes: Set<String>) throws -> [String: Meta] {
        guard !hashes.isEmpty else { return [:] }
        var meta: [String: Meta] = [:]
        for batch in CoreDatabaseSchema.batches(Array(hashes), perItem: 1) {
            let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ", ")
            let rows = try db.query(
                """
                SELECT `hash`, `bytes`, `width`, `height` FROM `blob`
                WHERE `hash` IN (\(placeholders))
                  AND EXISTS (SELECT 1 FROM `blob_ref` WHERE `blob_ref`.`hash` = `blob`.`hash`)
                """,
                parameters: batch.map(SQLiteValue.text)
            )
            for row in rows {
                if let h = row.string("hash"), let bytes = row.int64("bytes") {
                    meta[h] = Meta(
                        bytes: Int(bytes),
                        width: row.int64("width").map(Int.init),
                        height: row.int64("height").map(Int.init)
                    )
                }
            }
        }
        return meta
    }

    private static func inlineFileObject(_ obj: [String: JSONValue], blobs: [String: String]) -> [String: JSONValue] {
        guard let h = isMediaRefURI(obj["uri"]) else { return obj }
        var copy = obj
        copy.removeValue(forKey: "uri")
        if let base64 = blobs[h] {
            copy["data"] = .string(base64)
            return copy
        }
        let mime: String = if case .string(let m) = obj["mime"] { m } else { "application/octet-stream" }
        let name: String? = if case .string(let n) = obj["name"] { n } else { nil }
        copy["data"] = .string(bytesToBase64(Array(unavailableText(mime: mime, name: name).utf8)))
        copy["mime"] = .string("text/plain")
        return copy
    }

    private static func inlineToolItem(_ item: JSONValue, blobs: [String: String]) -> JSONValue {
        guard case .object(var obj) = item,
              case .string("file") = obj["type"],
              let h = isMediaRefURI(obj["uri"])
        else { return item }
        let mime: String = if case .string(let m) = obj["mime"] { m } else { "application/octet-stream" }
        let name: String? = if case .string(let n) = obj["name"] { n } else { nil }
        guard let base64 = blobs[h] else {
            return .object(["type": .string("text"), "text": .string(unavailableText(mime: mime, name: name))])
        }
        obj["uri"] = .string("data:\(mime);base64,\(base64)")
        return .object(obj)
    }

    private static func rewriteData(
        _ data: [String: JSONValue],
        rewriteFile: ([String: JSONValue]) -> [String: JSONValue],
        rewriteToolItem: (JSONValue) -> JSONValue
    ) -> [String: JSONValue] {
        var copy = data
        if case .array(let files) = data["files"] {
            copy["files"] = .array(files.map { item in
                guard case .object(let obj) = item else { return item }
                return .object(rewriteFile(obj))
            })
        }
        if case .array(let content) = data["content"] {
            copy["content"] = .array(content.map { part in
                guard case .object(var pObj) = part,
                      case .string("tool") = pObj["type"],
                      case .object(var st) = pObj["state"],
                      case .string(let status) = st["status"],
                      status == "completed" || status == "error",
                      case .array(let items) = st["content"]
                else { return part }
                st["content"] = .array(items.map(rewriteToolItem))
                pObj["state"] = .object(st)
                return .object(pObj)
            })
        }
        return copy
    }

    // parity: core/src/session/blob.ts#hydrate [status=implemented hash=49db7a9ed5c0]
    public static func hydrate(_ db: any SQLiteDatabase, rows: [StoredMessageRow]) throws -> [StoredMessageRow] {
        var hashes = Set<String>()
        for row in rows { collectHashes(from: row.data, into: &hashes) }
        if hashes.isEmpty { return rows }
        let blobs = try loadBlobs(db, hashes: hashes)
        return rows.map { row in
            var copy = row
            copy.data = rewriteData(
                row.data,
                rewriteFile: { inlineFileObject($0, blobs: blobs) },
                rewriteToolItem: { inlineToolItem($0, blobs: blobs) }
            )
            return copy
        }
    }

    // parity: core/src/session/blob.ts#hydrateInbox [status=implemented hash=0a07b5ffbb1c]
    public static func hydrateInbox(_ db: any SQLiteDatabase, rows: [StoredInboxRow]) throws -> [StoredInboxRow] {
        var hashes = Set<String>()
        for row in rows { collectHashes(from: row.payload, into: &hashes) }
        if hashes.isEmpty { return rows }
        let blobs = try loadBlobs(db, hashes: hashes)
        return rows.map { row in
            var copy = row
            copy.payload = rewriteData(
                row.payload,
                rewriteFile: { inlineFileObject($0, blobs: blobs) },
                rewriteToolItem: { $0 }
            )
            return copy
        }
    }

    // parity: core/src/session/blob.ts#keepRefs [status=implemented hash=f89c145f4c83]
    public static func keepRefs(
        _ db: any SQLiteDatabase,
        rows: [StoredMessageRow]
    ) throws -> (rows: [StoredMessageRow], meta: [String: Meta]) {
        var hashes = Set<String>()
        for row in rows { collectHashes(from: row.data, into: &hashes) }
        let meta = try loadMeta(db, hashes: hashes)
        let rewritten = rows.map { row -> StoredMessageRow in
            var copy = row
            copy.data = rewriteData(
                row.data,
                rewriteFile: { obj in
                    guard let h = isMediaRefURI(obj["uri"]), meta[h] == nil else { return obj }
                    return inlineFileObject(obj, blobs: [:])
                },
                rewriteToolItem: { item in
                    guard case .object(let obj) = item,
                          case .string("file") = obj["type"],
                          let h = isMediaRefURI(obj["uri"]),
                          meta[h] == nil
                    else { return item }
                    return inlineToolItem(item, blobs: [:])
                }
            )
            return copy
        }
        return (rewritten, meta)
    }

    // parity: core/src/session/blob.ts#keepInboxRefs [status=implemented hash=108461eaa488]
    public static func keepInboxRefs(
        _ db: any SQLiteDatabase,
        rows: [StoredInboxRow]
    ) throws -> (rows: [StoredInboxRow], meta: [String: Meta]) {
        var hashes = Set<String>()
        for row in rows { collectHashes(from: row.payload, into: &hashes) }
        let meta = try loadMeta(db, hashes: hashes)
        let rewritten = rows.map { row -> StoredInboxRow in
            var copy = row
            copy.payload = rewriteData(
                row.payload,
                rewriteFile: { obj in
                    guard let h = isMediaRefURI(obj["uri"]), meta[h] == nil else { return obj }
                    return inlineFileObject(obj, blobs: [:])
                },
                rewriteToolItem: { $0 }
            )
            return copy
        }
        return (rewritten, meta)
    }

    // parity: core/src/session/blob.ts#describe [status=implemented hash=b50f8651533c]
    public static func describe(_ files: [PromptSchema.Attachment], meta: [String: Meta]) -> [PromptSchema.Attachment] {
        files.map { attachment in
            guard case .media(let media) = attachment else { return attachment }
            let h = CoreSessionStored.refHash(media.uri)
            guard let info = meta[h] else { return attachment }
            return .media(PromptSchema.MediaFileAttachment(
                mime: media.mime,
                source: media.source,
                name: media.name,
                description: media.description,
                mention: media.mention,
                uri: media.uri,
                bytes: info.bytes,
                width: info.width,
                height: info.height
            ))
        }
    }

    // parity: core/src/session/blob.ts#read [status=implemented hash=a76030cd4491]
    public static func read(_ db: any SQLiteDatabase, hash: String) throws -> (mime: String, data: [UInt8])? {
        guard let row = try db.queryOne(
            """
            SELECT `mime`, `data` FROM `blob`
            WHERE `hash` = ?
              AND EXISTS (SELECT 1 FROM `blob_ref` WHERE `blob_ref`.`hash` = `blob`.`hash`)
            """,
            parameters: [.text(hash)]
        ),
              let mime = row.string("mime"),
              let bytes = row.blob("data")
        else { return nil }
        return (mime, bytes)
    }

    // parity: core/src/session/blob.ts#save [status=implemented hash=1479187fad61]
    public static func save(_ db: any SQLiteDatabase, blobs: [BlobInsert]) throws {
        guard !blobs.isEmpty else { return }
        let now = Flock.currentEpochMs()
        for blob in blobs {
            _ = try db.execute(
                """
                INSERT INTO `blob` (`hash`, `mime`, `bytes`, `width`, `height`, `data`, `time_created`)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (`hash`) DO NOTHING
                """,
                parameters: [
                    .text(blob.hash),
                    .text(blob.mime),
                    .integer(Int64(blob.bytes)),
                    blob.width.map { .integer(Int64($0)) } ?? .null,
                    blob.height.map { .integer(Int64($0)) } ?? .null,
                    .blob(blob.data),
                    .integer(now),
                ]
            )
        }
    }

    private static func takeBlob(pending: inout [String: BlobInsert], raw: [UInt8], mime: String) -> String {
        let h = hashBytes(raw)
        if pending[h] == nil {
            pending[h] = BlobInsert(hash: h, mime: mime, bytes: raw.count, data: raw)
        }
        return "media:\(h)"
    }

    private static func extractDataURIBase64(_ uri: String) -> String? {
        guard uri.hasPrefix("data:"), let marker = uri.range(of: ";base64,") else { return nil }
        return String(uri[marker.upperBound...])
    }

    // parity: core/src/session/blob.ts#split [status=implemented hash=46f2d1b24342]
    public static func split(_ data: [String: JSONValue]) -> SplitResult {
        var pending: [String: BlobInsert] = [:]
        var copy = data

        if case .array(let files) = data["files"] {
            copy["files"] = .array(files.map { item in
                guard case .object(var obj) = item,
                      obj["uri"] == nil,
                      case .string(let b64) = obj["data"],
                      case .string(let mime) = obj["mime"],
                      let raw = try? base64ToBytes(b64)
                else { return item }
                obj.removeValue(forKey: "data")
                obj["uri"] = .string(takeBlob(pending: &pending, raw: raw, mime: mime))
                return .object(obj)
            })
        }

        func splitToolPart(_ part: JSONValue) -> JSONValue {
            guard case .object(var pObj) = part,
                  case .string("tool") = pObj["type"],
                  case .object(var st) = pObj["state"],
                  case .string(let status) = st["status"],
                  status == "completed" || status == "error",
                  case .array(let items) = st["content"]
            else { return part }
            st["content"] = .array(items.map { item in
                guard case .object(var fObj) = item,
                      case .string("file") = fObj["type"],
                      case .string(let uri) = fObj["uri"],
                      case .string(let mime) = fObj["mime"],
                      let b64 = extractDataURIBase64(uri),
                      let raw = try? base64ToBytes(b64)
                else { return item }
                fObj["uri"] = .string(takeBlob(pending: &pending, raw: raw, mime: mime))
                return .object(fObj)
            })
            pObj["state"] = .object(st)
            return .object(pObj)
        }

        if case .array(let content) = data["content"] {
            copy["content"] = .array(content.map(splitToolPart))
        } else if case .string("tool") = data["type"] {
            if case .object(let updated) = splitToolPart(.object(data)) {
                copy = updated
            }
        }

        let moved = !pending.isEmpty
        let finalData = moved ? copy : data
        var hashes = Set<String>()
        collectHashes(from: finalData, into: &hashes)
        return SplitResult(data: finalData, moved: moved, blobs: Array(pending.values), hashes: hashes)
    }

    // parity: core/src/session/blob.ts#externalizePayload [status=implemented hash=c423e50b2164]
    public static func externalizePayload(
        _ db: any SQLiteDatabase,
        payload: [String: JSONValue],
        mediaBlobEnabled: Bool = false
    ) throws -> [String: JSONValue] {
        guard mediaBlobEnabled, payload["files"] != nil else { return payload }
        let res = split(payload)
        guard res.moved else { return payload }
        try save(db, blobs: res.blobs)
        return res.data
    }

    // parity: core/src/session/blob.ts#externalize [status=implemented hash=e5044424bc6a]
    public static func externalize(
        _ db: any SQLiteDatabase,
        messageData: [String: JSONValue],
        mediaBlobEnabled: Bool = false
    ) throws -> (data: [String: JSONValue], moved: Bool) {
        guard mediaBlobEnabled else { return (messageData, false) }
        let res = split(messageData)
        guard res.moved else { return (messageData, false) }
        try save(db, blobs: res.blobs)
        return (res.data, true)
    }

    // parity: core/src/session/blob.ts#externalizePart [status=implemented hash=e6ac61c25622]
    public static func externalizePart(
        _ db: any SQLiteDatabase,
        part: SessionMessageSchema.AssistantContent,
        mediaBlobEnabled: Bool = false
    ) throws -> (part: SessionMessageSchema.AssistantContent, moved: Bool) {
        guard mediaBlobEnabled,
              case .object(let raw) = try CoreBusJSON.encodeToJSONValue(part)
        else { return (part, false) }
        let res = split(raw)
        guard res.moved else { return (part, false) }
        try save(db, blobs: res.blobs)
        let decoded = try CoreBusJSON.decodeFromJSONValue(.object(res.data), as: SessionMessageSchema.AssistantContent.self)
        return (decoded, true)
    }

    // parity: core/src/session/blob.ts#externalizeRow [status=implemented hash=a19e8f35750b]
    public static func externalizeRow(_ db: any SQLiteDatabase, data: [String: JSONValue]) throws -> [String: JSONValue] {
        let res = split(data)
        guard res.moved else { return data }
        try save(db, blobs: res.blobs)
        return res.data
    }

    // parity: core/src/session/blob.ts#recordRefs [status=implemented hash=dc8accdc7794]
    public static func recordRefs(_ db: any SQLiteDatabase, owner: Owner, data: [String: JSONValue]) throws {
        var hashes = Set<String>()
        collectHashes(from: data, into: &hashes)
        try recordHashes(db, owner: owner, hashes: hashes)
    }

    // parity: core/src/session/blob.ts#recordHashes [status=implemented hash=e3f981b655cb]
    public static func recordHashes(_ db: any SQLiteDatabase, owner: Owner, hashes: Set<String>) throws {
        guard !hashes.isEmpty else { return }
        var existingHashes: [String] = []
        for batch in CoreDatabaseSchema.batches(Array(hashes), perItem: 1) {
            let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ", ")
            let rows = try db.query(
                "SELECT `hash` FROM `blob` WHERE `hash` IN (\(placeholders))",
                parameters: batch.map(SQLiteValue.text)
            )
            existingHashes.append(contentsOf: rows.compactMap { $0.string("hash") })
        }
        for hash in existingHashes {
            _ = try db.execute(
                """
                INSERT INTO `blob_ref` (`session_id`, `message_id`, `hash`, `seq`)
                VALUES (?, ?, ?, ?)
                ON CONFLICT (`session_id`, `message_id`, `hash`) DO UPDATE SET `seq` = excluded.`seq`
                """,
                parameters: [
                    .text(owner.sessionID.rawValue),
                    .text(owner.messageID.rawValue),
                    .text(hash),
                    .integer(owner.seq),
                ]
            )
        }
    }

    // parity: core/src/session/blob.ts#syncRefs [status=implemented hash=7a17ba0b05f3]
    public static func syncRefs(_ db: any SQLiteDatabase, owner: Owner, data: [String: JSONValue]) throws {
        try recordRefs(db, owner: owner, data: data)
        var present = Set<String>()
        collectHashes(from: data, into: &present)
        if present.isEmpty {
            try releaseMessage(db, sessionID: owner.sessionID, messageID: owner.messageID)
            return
        }
        let rows = try db.query(
            "SELECT `hash` FROM `blob_ref` WHERE `session_id` = ? AND `message_id` = ?",
            parameters: [.text(owner.sessionID.rawValue), .text(owner.messageID.rawValue)]
        )
        let stale = rows.compactMap { $0.string("hash") }.filter { !present.contains($0) }
        for batch in CoreDatabaseSchema.batches(stale, perItem: 1, fixed: 2) {
            let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ", ")
            try releaseWhere(
                db,
                whereClause: "`session_id` = ? AND `message_id` = ? AND `hash` IN (\(placeholders))",
                parameters: [.text(owner.sessionID.rawValue), .text(owner.messageID.rawValue)] + batch.map(SQLiteValue.text)
            )
        }
    }

    private static func releaseWhere(
        _ db: any SQLiteDatabase,
        whereClause: String,
        parameters: [SQLiteValue]
    ) throws {
        let deleted = try db.query(
            "DELETE FROM `blob_ref` WHERE \(whereClause) RETURNING `hash`",
            parameters: parameters
        )
        let hashes = Array(Set(deleted.compactMap { $0.string("hash") }))
        for batch in CoreDatabaseSchema.batches(hashes, perItem: 1) {
            let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ", ")
            _ = try db.execute(
                """
                DELETE FROM `blob`
                WHERE `hash` IN (\(placeholders))
                  AND NOT EXISTS (SELECT 1 FROM `blob_ref` WHERE `blob_ref`.`hash` = `blob`.`hash`)
                """,
                parameters: batch.map(SQLiteValue.text)
            )
        }
    }

    // parity: core/src/session/blob.ts#releaseMessage [status=implemented hash=a053da261304]
    public static func releaseMessage(
        _ db: any SQLiteDatabase,
        sessionID: SessionID,
        messageID: SessionMessageSchema.ID
    ) throws {
        try releaseWhere(
            db,
            whereClause: "`session_id` = ? AND `message_id` = ?",
            parameters: [.text(sessionID.rawValue), .text(messageID.rawValue)]
        )
    }

    // parity: core/src/session/blob.ts#releaseFrom [status=implemented hash=b7b1ce292246]
    public static func releaseFrom(_ db: any SQLiteDatabase, sessionID: SessionID, seq: Int64) throws {
        try releaseWhere(
            db,
            whereClause: "`session_id` = ? AND `seq` >= ?",
            parameters: [.text(sessionID.rawValue), .integer(seq)]
        )
    }

    // parity: core/src/session/blob.ts#releaseSession [status=implemented hash=fe0d605ee92d]
    public static func releaseSession(_ db: any SQLiteDatabase, sessionID: SessionID) throws {
        try releaseWhere(
            db,
            whereClause: "`session_id` = ?",
            parameters: [.text(sessionID.rawValue)]
        )
    }
}

// MARK: - session/history.ts

/// Compaction-bounded session message loading, part assembly, blob hydration, and legacy upgrade.
/// Ports `packages/core/src/session/history.ts`.
public enum CoreSessionHistory {
    // parity: core/src/session/history.ts#Boundary [status=implemented hash=4685a0c13cf8]
    public enum Boundary: Equatable, Hashable, Sendable {
        case latest
        case local
        case model(SessionSchema.ModelRef)
    }

    // parity: core/src/session/history.ts#NativeWindow [status=implemented hash=47ab0d7ec43d]
    public typealias NativeWindow = [AISchema.Message]

    public struct Entry: Equatable, Sendable {
        public let seq: Int64
        public let message: SessionMessageSchema.Info

        public init(seq: Int64, message: SessionMessageSchema.Info) {
            self.seq = seq
            self.message = message
        }
    }

    public struct RunnerEntries: Equatable, Sendable {
        public let initial: [CoreSessionInstructionState.RenderedInstruction]
        public let entries: [Entry]

        public init(initial: [CoreSessionInstructionState.RenderedInstruction], entries: [Entry]) {
            self.initial = initial
            self.entries = entries
        }
    }

    public struct PreviewResult: Equatable, Sendable {
        public let initial: [CoreSessionInstructionState.RenderedInstruction]
        public let messages: [SessionMessageSchema.Info]
        public let instructionUpdate: String

        public init(
            initial: [CoreSessionInstructionState.RenderedInstruction],
            messages: [SessionMessageSchema.Info],
            instructionUpdate: String
        ) {
            self.initial = initial
            self.messages = messages
            self.instructionUpdate = instructionUpdate
        }
    }

    // parity: core/src/session/history.ts#encodePart [status=implemented hash=448b052a9ff7]
    public static func encodePart(_ part: SessionMessageSchema.AssistantContent) throws -> [String: JSONValue] {
        guard case .object(let dict) = try CoreBusJSON.encodeToJSONValue(part) else {
            return [:]
        }
        return dict
    }

    // parity: core/src/session/history.ts#isNativeCompaction [status=implemented hash=f6ade73739d9]
    public static func isNativeCompaction(_ message: SessionMessageSchema.Info) -> Bool {
        guard case .compaction(.completed(let comp)) = message else { return false }
        return comp.native?["messages"] != nil
    }

    private static func decodesWindow(_ value: JSONValue?) -> Bool {
        guard let value else { return false }
        return (try? CoreBusJSON.decodeFromJSONValue(value, as: NativeWindow.self)) != nil
    }

    private static func isReplayable(_ message: SessionMessageSchema.Info, boundary: Boundary) -> Bool {
        guard isNativeCompaction(message) else { return true }
        switch boundary {
        case .latest:
            return true
        case .local:
            return false
        case .model(let ref):
            guard case .compaction(.completed(let comp)) = message else { return false }
            return comp.model?.providerID == ref.providerID
                && comp.model?.id == ref.id
                && decodesWindow(comp.native?["messages"])
        }
    }

    internal static func parseMessageRow(_ row: SQLiteRow) throws -> CoreSessionBlob.StoredMessageRow {
        guard let idStr = row.string("id"),
              let id = SessionMessageSchema.ID(rawValue: idStr),
              let sessionStr = row.string("session_id"),
              let sessionID = SessionID(rawValue: sessionStr),
              let typeStr = row.string("type"),
              let type = SessionMessageSchema.MessageType(rawValue: typeStr),
              let seq = row.int64("seq"),
              let timeCreated = row.int64("time_created"),
              let timeUpdated = row.int64("time_updated"),
              let rawData = row.string("data"),
              case .object(let dict) = try CoreBusJSON.decodeJSONValue(rawData)
        else {
            throw SQLiteError.invalidParameter("Malformed session_message row")
        }
        return CoreSessionBlob.StoredMessageRow(
            id: id,
            sessionID: sessionID,
            type: type,
            seq: seq,
            timeCreated: timeCreated,
            timeUpdated: timeUpdated,
            data: dict
        )
    }

    // parity: core/src/session/history.ts#withParts [status=implemented hash=cd841830fe74]
    public static func withParts(
        _ db: any SQLiteDatabase,
        rows: [CoreSessionBlob.StoredMessageRow]
    ) throws -> [CoreSessionBlob.StoredMessageRow] {
        let assistantIDs = rows.filter { $0.type == .assistant }.map(\.id.rawValue)
        if assistantIDs.isEmpty { return rows }

        var partsByMessage: [String: [JSONValue]] = [:]
        for batch in CoreDatabaseSchema.batches(assistantIDs, perItem: 1) {
            let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ", ")
            let partRows = try db.query(
                """
                SELECT `message_id`, `data` FROM `session_part`
                WHERE `message_id` IN (\(placeholders))
                ORDER BY `message_id` ASC, `ordinal` ASC
                """,
                parameters: batch.map(SQLiteValue.text)
            )
            for pRow in partRows {
                guard let mid = pRow.string("message_id"),
                      let raw = pRow.string("data"),
                      let decoded = try? CoreBusJSON.decodeJSONValue(raw)
                else { continue }
                partsByMessage[mid, default: []].append(decoded)
            }
        }
        if partsByMessage.isEmpty { return rows }

        return rows.map { row in
            guard let parts = partsByMessage[row.id.rawValue] else { return row }
            var copy = row
            if case .array(let inline) = copy.data["content"] {
                copy.data["content"] = .array(parts + inline)
            } else {
                copy.data["content"] = .array(parts)
            }
            return copy
        }
    }

    private static func rowInput(_ row: CoreSessionBlob.StoredMessageRow) -> [String: JSONValue] {
        var upgraded = SessionLegacySchema.message(type: .string(row.type.rawValue), data: row.data)
        upgraded["id"] = .string(row.id.rawValue)
        upgraded["type"] = .string(row.type.rawValue)
        return upgraded
    }

    // parity: core/src/session/history.ts#decodePartRowSync [status=implemented hash=c074118e0a72]
    public static func decodePartRowSync(_ row: SQLiteRow) throws -> SessionMessageSchema.AssistantContent {
        guard let raw = row.string("data"),
              let type = row.string("type"),
              case .object(var dict) = try CoreBusJSON.decodeJSONValue(raw)
        else {
            throw SQLiteError.invalidParameter("Malformed session_part row")
        }
        dict["type"] = .string(type)
        let upgraded = SessionLegacySchema.part(.object(dict))
        return try CoreBusJSON.decodeFromJSONValue(upgraded, as: SessionMessageSchema.AssistantContent.self)
    }

    // parity: core/src/session/history.ts#decodeMessageRowSync [status=implemented hash=47c9f2928b0c]
    public static func decodeMessageRowSync(_ row: CoreSessionBlob.StoredMessageRow) throws -> SessionMessageSchema.Info {
        try CoreBusJSON.decodeFromJSONValue(.object(rowInput(row)), as: SessionMessageSchema.Info.self)
    }

    // parity: core/src/session/history.ts#decodeMessageRow [status=implemented hash=25da04680806]
    public static func decodeMessageRow(_ row: CoreSessionBlob.StoredMessageRow) throws(CoreSessionErrors.MessageDecodeError) -> SessionMessageSchema.Info {
        do {
            return try decodeMessageRowSync(row)
        } catch {
            throw CoreSessionErrors.MessageDecodeError(sessionID: row.sessionID, messageID: row.id)
        }
    }

    // parity: core/src/session/history.ts#decodeMessageRows [status=implemented hash=ab927143ecf7]
    public static func decodeMessageRows(
        _ db: any SQLiteDatabase,
        rows: [CoreSessionBlob.StoredMessageRow]
    ) throws -> [SessionMessageSchema.Info] {
        let withPartRows = try withParts(db, rows: rows)
        let hydrated = try CoreSessionBlob.hydrate(db, rows: withPartRows)
        return try hydrated.map { try decodeMessageRow($0) }
    }

    // parity: core/src/session/history.ts#loadMessageRow [status=implemented hash=361c85c35f89]
    public static func loadMessageRow(
        _ db: any SQLiteDatabase,
        row: CoreSessionBlob.StoredMessageRow
    ) throws -> SessionMessageSchema.Info {
        let hydrated = try CoreSessionBlob.hydrate(db, rows: try withParts(db, rows: [row]))
        return try decodeMessageRow(hydrated.first ?? row)
    }

    // parity: core/src/session/history.ts#decodeMessageRowsWithRefs [status=implemented hash=00dcfa037851]
    public static func decodeMessageRowsWithRefs(
        _ db: any SQLiteDatabase,
        rows: [CoreSessionBlob.StoredMessageRow]
    ) throws -> [SessionMessageSchema.MediaInfo] {
        let kept = try CoreSessionBlob.keepRefs(db, rows: try withParts(db, rows: rows))
        return try kept.rows.map { row in
            let decoded: SessionMessageSchema.MediaInfo
            do {
                decoded = try CoreBusJSON.decodeFromJSONValue(.object(rowInput(row)), as: SessionMessageSchema.MediaInfo.self)
            } catch {
                throw CoreSessionErrors.MessageDecodeError(sessionID: row.sessionID, messageID: row.id)
            }
            if case .user(let u) = decoded, let files = u.files {
                return .user(SessionMessageSchema.MediaUser(
                    id: u.id,
                    metadata: u.metadata,
                    time: u.time,
                    text: u.text,
                    files: CoreSessionBlob.describe(files, meta: kept.meta),
                    agents: u.agents,
                    skills: u.skills
                ))
            }
            return decoded
        }
    }

    private static func latestCompactionSeq(
        _ db: any SQLiteDatabase,
        sessionID: SessionID,
        boundary: Boundary,
        before: Int64? = nil
    ) throws -> Int64? {
        var clauses = [
            "`session_id` = ?",
            "`type` = 'compaction'",
            "json_extract(`data`, '$.status') = 'completed'",
        ]
        var params: [SQLiteValue] = [.text(sessionID.rawValue)]
        if let before {
            clauses.append("`seq` < ?")
            params.append(.integer(before))
        }
        switch boundary {
        case .latest:
            break
        case .local:
            clauses.append("coalesce(json_extract(`data`, '$.native.messages'), json_extract(`data`, '$.providerContext')) IS NULL")
        case .model(let ref):
            clauses.append(
                "(coalesce(json_extract(`data`, '$.native.messages'), json_extract(`data`, '$.providerContext')) IS NULL OR (json_extract(`data`, '$.model.providerID') = ? AND json_extract(`data`, '$.model.id') = ?))"
            )
            params.append(.text(ref.providerID))
            params.append(.text(ref.id))
        }
        let row = try db.queryOne(
            "SELECT `seq` FROM `session_message` WHERE \(clauses.joined(separator: " AND ")) ORDER BY `seq` DESC LIMIT 1",
            parameters: params
        )
        return row?.int64("seq")
    }

    private static func withRecentText(
        _ db: any SQLiteDatabase,
        sessionID: SessionID,
        entries: [Entry]
    ) throws -> [Entry] {
        guard let first = entries.first,
              case .compaction(.completed(let comp)) = first.message,
              case .string(let keepIDStr) = comp.metadata?["keepID"],
              let keepID = SessionMessageSchema.ID(rawValue: keepIDStr)
        else { return entries }

        guard let startRow = try db.queryOne(
            "SELECT `seq` FROM `session_message` WHERE `session_id` = ? AND `id` = ?",
            parameters: [.text(sessionID.rawValue), .text(keepID.rawValue)]
        ), let startSeq = startRow.int64("seq") else {
            return entries
        }

        let rawRows = try db.query(
            """
            SELECT * FROM `session_message`
            WHERE `session_id` = ? AND `seq` >= ? AND `seq` < ?
            ORDER BY `seq` ASC
            """,
            parameters: [.text(sessionID.rawValue), .integer(startSeq), .integer(first.seq)]
        )
        let parsed = try rawRows.map(parseMessageRow)
        let assembled = try withParts(db, rows: parsed)
        var texts: [String] = []
        for row in assembled {
            if let msg = try? decodeMessageRowSync(row) {
                let t = CoreSessionRecentText.messageToText(msg)
                if !t.isEmpty { texts.append(t) }
            }
        }
        let recent = texts.joined(separator: "\n\n")
        var nextMeta = comp.metadata ?? [:]
        nextMeta["recent"] = .string(recent)
        let updated = SessionMessageSchema.Info.compaction(.completed(SessionMessageSchema.CompactionCompleted(
            id: comp.id,
            metadata: nextMeta,
            time: comp.time,
            reason: comp.reason,
            model: comp.model,
            native: comp.native,
            summary: comp.summary,
            cost: comp.cost,
            tokens: comp.tokens
        )))
        return [Entry(seq: first.seq, message: updated)] + Array(entries.dropFirst())
    }

    private static func messageEntries(
        _ db: any SQLiteDatabase,
        sessionID: SessionID,
        boundary: Boundary,
        before: Int64? = nil
    ) throws -> [Entry] {
        let compactionSeq = try latestCompactionSeq(db, sessionID: sessionID, boundary: boundary, before: before)
        let sql: String
        let params: [SQLiteValue]
        if let compactionSeq {
            sql = "SELECT * FROM `session_message` WHERE `session_id` = ? AND `seq` >= ? ORDER BY `seq` ASC"
            params = [.text(sessionID.rawValue), .integer(compactionSeq)]
        } else {
            sql = "SELECT * FROM `session_message` WHERE `session_id` = ? ORDER BY `seq` ASC"
            params = [.text(sessionID.rawValue)]
        }
        let parsed = try db.query(sql, parameters: params).map(parseMessageRow)
        let hydrated = try CoreSessionBlob.hydrate(db, rows: try withParts(db, rows: parsed))
        let decoded: [Entry] = try hydrated.map { Entry(seq: $0.seq, message: try decodeMessageRow($0)) }

        if let compactionSeq, let start = decoded.first, !isReplayable(start.message, boundary: boundary) {
            return try messageEntries(db, sessionID: sessionID, boundary: boundary, before: compactionSeq)
        }
        let entries = compactionSeq != nil ? try withRecentText(db, sessionID: sessionID, entries: decoded) : decoded
        let nativeSeq = entries.last(where: { isNativeCompaction($0.message) })?.seq
        let epochStart = (try? CoreSessionInstructionState.epochStart(db: db, sessionID: sessionID)) ?? Int64.max

        return entries.filter { entry in
            if case .system(let sys) = entry.message {
                if let nativeSeq, entry.seq < nativeSeq { return false }
                if case .string("instructions") = sys.metadata?["notice"], entry.seq < epochStart { return false }
            }
            return isReplayable(entry.message, boundary: boundary)
        }
    }

    // parity: core/src/session/history.ts#load [status=implemented hash=27834ec6d307]
    public static func load(
        _ db: any SQLiteDatabase,
        sessionID: SessionID,
        boundary: Boundary
    ) throws -> [SessionMessageSchema.Info] {
        try messageEntries(db, sessionID: sessionID, boundary: boundary).map(\.message)
    }

    // parity: core/src/session/history.ts#entriesForRunner [status=implemented hash=e37df446b103]
    public static func entriesForRunner(
        _ db: any SQLiteDatabase,
        sessionID: SessionID,
        instructions: [CoreSessionInstructionState.Source],
        boundary: Boundary
    ) throws -> RunnerEntries {
        try db.transaction {
            let entries = try messageEntries(db, sessionID: sessionID, boundary: boundary)
            let initial = (try? CoreSessionInstructionState.initial(db: db, sessionID: sessionID, sources: instructions)) ?? []
            return RunnerEntries(initial: initial, entries: entries)
        }
    }

    // parity: core/src/session/history.ts#preview [status=implemented hash=7648127d1b56]
    public static func preview(
        _ db: any SQLiteDatabase,
        sessionID: SessionID,
        instructions: [CoreSessionInstructionState.Source],
        boundary: Boundary
    ) throws -> PreviewResult {
        try db.transaction {
            let entries = try messageEntries(db, sessionID: sessionID, boundary: boundary)
            let unsettledIdx = entries.firstIndex { entry in
                if case .assistant(let a) = entry.message {
                    return a.time.completed == nil
                }
                return false
            }
            let settled = unsettledIdx.map { Array(entries[..<$0]) } ?? entries
            let assembled = try CoreSessionInstructionState.preview(db: db, sessionID: sessionID, sources: instructions)
            return PreviewResult(
                initial: assembled.initial,
                messages: settled.map(\.message),
                instructionUpdate: assembled.update
            )
        }
    }

    // parity: core/src/session/history.ts#synthetics [status=implemented hash=4c6327669698]
    public static func synthetics(
        _ db: any SQLiteDatabase,
        sessionID: SessionID
    ) throws -> [SessionMessageSchema.Info] {
        let compactionSeq = try latestCompactionSeq(db, sessionID: sessionID, boundary: .latest)
        let sql: String
        let params: [SQLiteValue]
        if let compactionSeq {
            sql = "SELECT * FROM `session_message` WHERE `session_id` = ? AND `type` = 'synthetic' AND `seq` >= ? ORDER BY `seq` ASC"
            params = [.text(sessionID.rawValue), .integer(compactionSeq)]
        } else {
            sql = "SELECT * FROM `session_message` WHERE `session_id` = ? AND `type` = 'synthetic' ORDER BY `seq` ASC"
            params = [.text(sessionID.rawValue)]
        }
        let parsed = try db.query(sql, parameters: params).map(parseMessageRow)
        return try parsed.map { try decodeMessageRow($0) }
    }

    // parity: core/src/session/history.ts#incompleteAssistants [status=implemented hash=09a1320b239c]
    public static func incompleteAssistants(
        _ db: any SQLiteDatabase,
        sessionID: SessionID
    ) throws -> [SessionMessageSchema.Info] {
        let compactionSeq = try latestCompactionSeq(db, sessionID: sessionID, boundary: .latest)
        let sql: String
        let params: [SQLiteValue]
        if let compactionSeq {
            sql = """
            SELECT * FROM `session_message`
            WHERE `session_id` = ? AND `type` = 'assistant'
              AND json_extract(`data`, '$.time.completed') IS NULL AND `seq` >= ?
            ORDER BY `seq` ASC
            """
            params = [.text(sessionID.rawValue), .integer(compactionSeq)]
        } else {
            sql = """
            SELECT * FROM `session_message`
            WHERE `session_id` = ? AND `type` = 'assistant'
              AND json_extract(`data`, '$.time.completed') IS NULL
            ORDER BY `seq` ASC
            """
            params = [.text(sessionID.rawValue)]
        }
        let parsed = try db.query(sql, parameters: params).map(parseMessageRow)
        return try decodeMessageRows(db, rows: parsed)
    }

    // parity: core/src/session/history.ts#firstUserMessage [status=implemented hash=ac3728094df8]
    public static func firstUserMessage(
        _ db: any SQLiteDatabase,
        sessionID: SessionID
    ) throws -> (id: SessionMessageSchema.ID, text: String)? {
        guard let row = try db.queryOne(
            """
            SELECT `id`, json_extract(`data`, '$.text') AS `text`
            FROM `session_message`
            WHERE `session_id` = ? AND `type` = 'user'
            ORDER BY `seq` ASC LIMIT 1
            """,
            parameters: [.text(sessionID.rawValue)]
        ),
              let idStr = row.string("id"),
              let id = SessionMessageSchema.ID(rawValue: idStr),
              let text = row.string("text")
        else { return nil }
        return (id, text)
    }
}

// MARK: - session/store.ts

/// Durable SQLite read/claim store for sessions and messages (`packages/core/src/session/store.ts`).
public enum CoreSessionStore {
    // parity: core/src/session/store.ts#ListInput [status=implemented hash=077ccccf7100]
    public struct ListInput: Equatable, Hashable, Sendable {
        public let directory: String?
        public let workspaceID: WorkspaceID?
        public let project: ProjectID?
        public let subpath: String?
        public let search: String?
        public let limit: Int?
        public let order: SessionSchema.SortOrder?
        public let parentID: SessionSchema.ParentFilter?
        public let archived: Bool?
        public let anchor: SessionSchema.ListAnchor?

        public init(
            directory: String? = nil,
            workspaceID: WorkspaceID? = nil,
            project: ProjectID? = nil,
            subpath: String? = nil,
            search: String? = nil,
            limit: Int? = nil,
            order: SessionSchema.SortOrder? = nil,
            parentID: SessionSchema.ParentFilter? = nil,
            archived: Bool? = nil,
            anchor: SessionSchema.ListAnchor? = nil
        ) {
            self.directory = directory
            self.workspaceID = workspaceID
            self.project = project
            self.subpath = subpath
            self.search = search
            self.limit = limit
            self.order = order
            self.parentID = parentID
            self.archived = archived
            self.anchor = anchor
        }
    }

    // parity: core/src/session/store.ts#MessagesInput [status=implemented hash=b13178c22fb4]
    public struct MessagesInput: Equatable, Hashable, Sendable {
        public struct Cursor: Equatable, Hashable, Sendable {
            public let id: SessionMessageSchema.ID
            public let direction: SessionSchema.ListAnchor.Direction

            public init(id: SessionMessageSchema.ID, direction: SessionSchema.ListAnchor.Direction) {
                self.id = id
                self.direction = direction
            }
        }

        public let sessionID: SessionID
        public let limit: Int?
        public let order: SessionSchema.SortOrder?
        public let type: SessionMessageSchema.MessageType?
        public let cursor: Cursor?

        public init(
            sessionID: SessionID,
            limit: Int? = nil,
            order: SessionSchema.SortOrder? = nil,
            type: SessionMessageSchema.MessageType? = nil,
            cursor: Cursor? = nil
        ) {
            self.sessionID = sessionID
            self.limit = limit
            self.order = order
            self.type = type
            self.cursor = cursor
        }
    }

    // parity: core/src/session/store.ts#Interface [status=implemented hash=d9eb80d50537]
    public protocol Interface: Sendable {
        func get(_ sessionID: SessionID) throws -> SessionSchema.Info?
        func list(_ input: ListInput) throws -> [SessionSchema.Info]
        func messages(_ input: MessagesInput) throws -> [SessionMessageSchema.Info]
        func context(_ sessionID: SessionID) throws -> [SessionMessageSchema.Info]
        func lastAssistantAfter(sessionID: SessionID, afterSeq: Int64?) throws -> SessionMessageSchema.Assistant?
        func message(_ messageID: SessionMessageSchema.ID) throws -> (sessionID: SessionID, message: SessionMessageSchema.Info)?
        func messagesWithRefs(_ input: MessagesInput) throws -> [SessionMessageSchema.MediaInfo]
        func messageWithRefs(_ messageID: SessionMessageSchema.ID) throws -> (sessionID: SessionID, message: SessionMessageSchema.MediaInfo)?
        func listSuspended() throws -> [SessionID]
        func claim(_ sessionID: SessionID) throws
        func release(_ sessionID: SessionID) throws
        func releaseOrphanedChildClaims() throws
        func countResume(_ sessionID: SessionID) throws -> Int?
    }

    // parity: core/src/session/store.ts#Service [status=implemented hash=ceca8a2989d3]
    public final class Service: Interface, Sendable {
        public static let serviceKey = "@opencode/SessionStore"
        public let db: any SQLiteDatabase

        public init(db: any SQLiteDatabase) {
            self.db = db
        }

        public func get(_ sessionID: SessionID) throws -> SessionSchema.Info? {
            guard let row = try db.queryOne(
                "SELECT * FROM `session_v2` WHERE `id` = ?",
                parameters: [.text(sessionID.rawValue)]
            ) else { return nil }
            return try CoreSessionInfo.fromRow(row)
        }

        public func list(_ input: ListInput = ListInput()) throws -> [SessionSchema.Info] {
            let direction = input.anchor?.direction ?? .next
            let requestedOrder = input.order ?? .desc
            let order: SessionSchema.SortOrder = (direction == .previous)
                ? (requestedOrder == .asc ? .desc : .asc)
                : requestedOrder

            var clauses: [String] = []
            var params: [SQLiteValue] = []
            if let directory = input.directory {
                clauses.append("`directory` = ?")
                params.append(.text(directory))
            }
            if let workspaceID = input.workspaceID {
                clauses.append("`workspace_id` = ?")
                params.append(.text(workspaceID.rawValue))
            }
            if let project = input.project {
                clauses.append("`project_id` = ?")
                params.append(.text(project.rawValue))
                if let subpath = input.subpath {
                    clauses.append("`path` = ?")
                    params.append(.text(subpath))
                }
            }
            if let search = input.search, !search.isEmpty {
                clauses.append("`title` GLOB ?")
                params.append(.text(Self.titlePattern(search)))
            }
            if let parentFilter = input.parentID {
                switch parentFilter {
                case .root:
                    clauses.append("`parent_id` IS NULL")
                case .session(let pid):
                    clauses.append("`parent_id` = ?")
                    params.append(.text(pid.rawValue))
                }
            }
            if let archived = input.archived {
                clauses.append(archived ? "`time_archived` IS NOT NULL" : "`time_archived` IS NULL")
            }
            if let anchor = input.anchor {
                if order == .asc {
                    clauses.append("(`time_updated` > ? OR (`time_updated` = ? AND `id` > ?))")
                } else {
                    clauses.append("(`time_updated` < ? OR (`time_updated` = ? AND `id` < ?))")
                }
                params.append(.integer(anchor.time))
                params.append(.integer(anchor.time))
                params.append(.text(anchor.id.rawValue))
            }

            let whereSQL = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
            let dirSQL = order == .asc ? "ASC" : "DESC"
            let limitSQL = input.limit.map { " LIMIT \($0)" } ?? ""
            let rows = try db.query(
                "SELECT * FROM `session_v2`\(whereSQL) ORDER BY `time_updated` \(dirSQL), `id` \(dirSQL)\(limitSQL)",
                parameters: params
            )
            let ordered = (direction == .previous) ? Array(rows.reversed()) : rows
            return try ordered.map(CoreSessionInfo.fromRow)
        }

        private func messageRows(_ input: MessagesInput) throws -> [CoreSessionBlob.StoredMessageRow] {
            let direction = input.cursor?.direction ?? .next
            let requestedOrder = input.order ?? .desc
            let order: SessionSchema.SortOrder = (direction == .previous)
                ? (requestedOrder == .asc ? .desc : .asc)
                : requestedOrder

            var clauses = ["`session_id` = ?"]
            var params: [SQLiteValue] = [.text(input.sessionID.rawValue)]
            if let cursor = input.cursor {
                guard let anchorRow = try db.queryOne(
                    "SELECT `seq` FROM `session_message` WHERE `session_id` = ? AND `id` = ?",
                    parameters: [.text(input.sessionID.rawValue), .text(cursor.id.rawValue)]
                ), let anchorSeq = anchorRow.int64("seq") else {
                    return []
                }
                clauses.append(order == .asc ? "`seq` > ?" : "`seq` < ?")
                params.append(.integer(anchorSeq))
            }
            if let type = input.type {
                clauses.append("`type` = ?")
                params.append(.text(type.rawValue))
            }

            let dirSQL = order == .asc ? "ASC" : "DESC"
            let limitSQL = input.limit.map { " LIMIT \($0)" } ?? ""
            let rows = try db.query(
                "SELECT * FROM `session_message` WHERE \(clauses.joined(separator: " AND ")) ORDER BY `seq` \(dirSQL)\(limitSQL)",
                parameters: params
            )
            let ordered = (direction == .previous) ? Array(rows.reversed()) : rows
            return try ordered.map(CoreSessionHistory.parseMessageRow)
        }

        public func messages(_ input: MessagesInput) throws -> [SessionMessageSchema.Info] {
            try CoreSessionHistory.decodeMessageRows(db, rows: try messageRows(input))
        }

        public func messagesWithRefs(_ input: MessagesInput) throws -> [SessionMessageSchema.MediaInfo] {
            try CoreSessionHistory.decodeMessageRowsWithRefs(db, rows: try messageRows(input))
        }

        public func context(_ sessionID: SessionID) throws -> [SessionMessageSchema.Info] {
            try CoreSessionHistory.load(db, sessionID: sessionID, boundary: .latest)
        }

        public func lastAssistantAfter(sessionID: SessionID, afterSeq: Int64?) throws -> SessionMessageSchema.Assistant? {
            var cursorSeq: Int64?
            while true {
                var clauses = ["`session_id` = ?", "`type` = 'assistant'"]
                var params: [SQLiteValue] = [.text(sessionID.rawValue)]
                if let afterSeq {
                    clauses.append("`seq` > ?")
                    params.append(.integer(afterSeq))
                }
                if let cursorSeq {
                    clauses.append("`seq` < ?")
                    params.append(.integer(cursorSeq))
                }
                let rawRows = try db.query(
                    "SELECT * FROM `session_message` WHERE \(clauses.joined(separator: " AND ")) ORDER BY `seq` DESC LIMIT 20",
                    parameters: params
                )
                let parsed = try rawRows.map(CoreSessionHistory.parseMessageRow)
                let decoded = try CoreSessionHistory.decodeMessageRows(db, rows: parsed)
                for msg in decoded {
                    if case .assistant(let assistant) = msg,
                       assistant.time.completed != nil,
                       assistant.error == nil
                    {
                        return assistant
                    }
                }
                if parsed.count < 20 { return nil }
                cursorSeq = parsed.last?.seq
            }
        }

        public func message(_ messageID: SessionMessageSchema.ID) throws -> (sessionID: SessionID, message: SessionMessageSchema.Info)? {
            guard let raw = try db.queryOne(
                "SELECT * FROM `session_message` WHERE `id` = ?",
                parameters: [.text(messageID.rawValue)]
            ) else { return nil }
            let parsed = try CoreSessionHistory.parseMessageRow(raw)
            guard let msg = try CoreSessionHistory.decodeMessageRows(db, rows: [parsed]).first else { return nil }
            return (parsed.sessionID, msg)
        }

        public func messageWithRefs(_ messageID: SessionMessageSchema.ID) throws -> (sessionID: SessionID, message: SessionMessageSchema.MediaInfo)? {
            guard let raw = try db.queryOne(
                "SELECT * FROM `session_message` WHERE `id` = ?",
                parameters: [.text(messageID.rawValue)]
            ) else { return nil }
            let parsed = try CoreSessionHistory.parseMessageRow(raw)
            guard let msg = try CoreSessionHistory.decodeMessageRowsWithRefs(db, rows: [parsed]).first else { return nil }
            return (parsed.sessionID, msg)
        }

        public func listSuspended() throws -> [SessionID] {
            let rows = try db.query("SELECT `id` FROM `session_v2` WHERE `time_suspended` IS NOT NULL")
            return rows.compactMap { $0.string("id").flatMap(SessionID.init(rawValue:)) }
        }

        public func claim(_ sessionID: SessionID) throws {
            // Null guard makes re-claiming a still-claimed session a zero-row no-op.
            // Pin time_updated so claim bookkeeping never alters user activity ordering.
            _ = try db.execute(
                """
                UPDATE `session_v2`
                SET `time_suspended` = ?, `time_updated` = `time_updated`
                WHERE `id` = ? AND `time_suspended` IS NULL
                """,
                parameters: [.integer(Flock.currentEpochMs()), .text(sessionID.rawValue)]
            )
        }

        public func release(_ sessionID: SessionID) throws {
            _ = try db.execute(
                """
                UPDATE `session_v2`
                SET `time_suspended` = NULL, `resume_attempts` = 0, `time_updated` = `time_updated`
                WHERE `id` = ?
                """,
                parameters: [.text(sessionID.rawValue)]
            )
        }

        public func releaseOrphanedChildClaims() throws {
            _ = try db.execute(
                """
                UPDATE `session_v2`
                SET `time_suspended` = NULL, `resume_attempts` = 0, `time_updated` = `time_updated`
                WHERE `time_suspended` IS NOT NULL
                  AND `parent_id` IS NOT NULL
                  AND `parent_id` NOT IN (SELECT `id` FROM `session_v2`)
                """
            )
        }

        public func countResume(_ sessionID: SessionID) throws -> Int? {
            let row = try db.queryOne(
                """
                UPDATE `session_v2`
                SET `resume_attempts` = `resume_attempts` + 1, `time_updated` = `time_updated`
                WHERE `id` = ?
                RETURNING `resume_attempts`
                """,
                parameters: [.text(sessionID.rawValue)]
            )
            return row?.int64("resume_attempts").map(Int.init)
        }

        /// Builds a Unicode-aware case-insensitive SQLite `GLOB` pattern preserving `%` and `_` wildcards.
        public static func titlePattern(_ search: String) -> String {
            var out = "*"
            for ch in search {
                if ch == "%" {
                    out.append("*")
                } else if ch == "_" {
                    out.append("?")
                } else {
                    let lower = String(ch).lowercased()
                    let upper = String(ch).uppercased()
                    var forms: [String] = []
                    for form in [String(ch), lower, upper] where form.count == 1 && !forms.contains(form) {
                        forms.append(form)
                    }
                    if forms.count > 1 {
                        out.append("[\(forms.joined())]")
                    } else if ch == "*" || ch == "?" || ch == "[" {
                        out.append("[\(ch)]")
                    } else {
                        out.append(ch)
                    }
                }
            }
            out.append("*")
            return out
        }
    }

    // parity: core/src/session/store.ts#node [status=adapted hash=98f3fa69d10f]
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

// MARK: - session/message-updater.ts

/// Pure event-to-projected-message state machine (`packages/core/src/session/message-updater.ts`).
public enum CoreSessionMessageUpdater {
    public struct PartMatch: Equatable, Sendable {
        public let type: String
        public let callID: String?
        public let incompleteReasoning: Bool

        public init(type: String, callID: String? = nil, incompleteReasoning: Bool = false) {
            self.type = type
            self.callID = callID
            self.incompleteReasoning = incompleteReasoning
        }
    }

    // parity: core/src/session/message-updater.ts#Adapter [status=implemented hash=03fb317e5345]
    public protocol Adapter {
        func getAgent() throws -> String?
        func getModel() throws -> SessionSchema.ModelRef?
        func getLocation() throws -> SessionMessageSchema.LocationSwitched.Previous?
        func getCurrentAssistant() throws -> SessionMessageSchema.Assistant?
        func getAssistant(_ messageID: SessionMessageSchema.ID) throws -> SessionMessageSchema.Assistant?
        func getShell(_ shellID: String) throws -> SessionMessageSchema.Shell?
        func getCompaction() throws -> SessionMessageSchema.Compaction?
        func updateAssistant(_ assistant: SessionMessageSchema.Assistant) throws
        func appendAssistantPart(_ messageID: SessionMessageSchema.ID, part: SessionMessageSchema.AssistantContent) throws
        func updateAssistantPart(
            _ messageID: SessionMessageSchema.ID,
            match: PartMatch,
            transform: (SessionMessageSchema.AssistantContent) -> SessionMessageSchema.AssistantContent
        ) throws
        func replaceAssistantParts(
            _ messageID: SessionMessageSchema.ID,
            parts: [SessionMessageSchema.AssistantContent]
        ) throws
        func updateShell(_ shell: SessionMessageSchema.Shell) throws
        func updateCompaction(_ compaction: SessionMessageSchema.Compaction) throws
        func appendMessage(_ message: SessionMessageSchema.Info) throws
    }

    /// Folds one durable session event onto projected messages through `adapter`.
    // parity: core/src/session/message-updater.ts#update [status=implemented hash=a0c5f4ce11bb]
    public static func update(adapter: any Adapter, event: SessionEventSchema.DurableEvent, created: Int64, metadata: [String: JSONValue]?) throws {
        func updateOwnedAssistant(
            _ messageID: SessionMessageSchema.ID,
            _ mutate: (SessionMessageSchema.Assistant) -> SessionMessageSchema.Assistant
        ) throws {
            guard let existing = try adapter.getAssistant(messageID) else { return }
            try adapter.updateAssistant(mutate(existing))
        }

        func clearCurrentRetry() throws {
            guard let assistant = try adapter.getCurrentAssistant(), assistant.retry != nil else { return }
            try adapter.updateAssistant(SessionMessageSchema.Assistant(
                id: assistant.id,
                metadata: assistant.metadata,
                agent: assistant.agent,
                model: assistant.model,
                content: assistant.content,
                snapshot: assistant.snapshot,
                finish: assistant.finish,
                rawFinish: assistant.rawFinish,
                native: assistant.native,
                cost: assistant.cost,
                tokens: assistant.tokens,
                error: assistant.error,
                retry: nil,
                time: assistant.time
            ))
        }

        func appendIdle(outcome: SessionSchema.Outcome, error: SessionErrorSchema.Error? = nil) throws {
            try clearCurrentRetry()
            let msgID = try SessionMessageSchema.ID.fromEvent(event.id.rawValue)
            try adapter.appendMessage(.idle(SessionMessageSchema.Idle(
                id: msgID,
                metadata: metadata,
                time: SessionMessageSchema.TimeCreated(created: created),
                outcome: outcome,
                error: error
            )))
        }

        switch event {
        case .created, .viewed, .archived, .unarchived, .usageRecorded,
             .renamed, .metadataUpdated, .permissions, .deleted, .forked,
             .inboxDelivered, .inboxEnqueued, .inboxCancelled, .inboxDeliveryChanged,
             .executionStarted, .revertStaged, .revertCleared, .revertCommitted:
            return

        case .messageContentUpdated(let env):
            try adapter.replaceAssistantParts(env.data.messageID, parts: env.data.content)

        case .agentSelected(let env):
            let previous = try env.data.previous ?? adapter.getAgent()
            try adapter.appendMessage(.agentSelected(SessionMessageSchema.AgentSelected(
                id: try SessionMessageSchema.ID.fromEvent(env.id.rawValue),
                metadata: env.metadata,
                time: SessionMessageSchema.TimeCreated(created: env.created),
                agent: env.data.agent,
                previous: previous
            )))

        case .modelSelected(let env):
            let previous = try env.data.previous ?? adapter.getModel()
            try adapter.appendMessage(.modelSelected(SessionMessageSchema.ModelSelected(
                id: try SessionMessageSchema.ID.fromEvent(env.id.rawValue),
                metadata: env.metadata,
                time: SessionMessageSchema.TimeCreated(created: env.created),
                model: env.data.model,
                previous: previous
            )))

        case .moved(let env):
            let prev = try adapter.getLocation()
            try adapter.appendMessage(.locationSwitched(SessionMessageSchema.LocationSwitched(
                id: try SessionMessageSchema.ID.fromEvent(env.id.rawValue),
                metadata: env.metadata,
                time: SessionMessageSchema.TimeCreated(created: env.created),
                location: env.data.location,
                projectID: env.data.projectID,
                subpath: env.data.subpath,
                previous: prev
            )))

        case .executionSucceeded:
            try appendIdle(outcome: .succeeded)

        case .executionFailed(let env):
            try appendIdle(outcome: .failed, error: env.data.error)

        case .executionInterrupted(let env):
            if env.data.reason == .shutdown {
                try clearCurrentRetry()
            } else {
                try appendIdle(outcome: .interrupted)
            }

        case .instructionsUpdated(let env):
            guard let text = env.data.text else { return }
            let sources = env.data.delta.keys.sorted()
            var meta = env.metadata ?? [:]
            meta["notice"] = .string("instructions")
            meta["instructionSources"] = .array(sources.map(JSONValue.string))
            try adapter.appendMessage(.system(SessionMessageSchema.System(
                id: try SessionMessageSchema.ID.fromEvent(env.id.rawValue),
                metadata: meta,
                time: SessionMessageSchema.TimeCreated(created: env.created),
                text: text,
                description: "Instructions updated: \(sources.joined(separator: ", "))"
            )))

        case .synthetic(let env):
            try adapter.appendMessage(.synthetic(SessionMessageSchema.Synthetic(
                id: try SessionMessageSchema.ID.fromEvent(env.id.rawValue),
                metadata: env.data.metadata,
                time: SessionMessageSchema.TimeCreated(created: env.created),
                text: env.data.text,
                description: env.data.description
            )))

        case .skillActivated(let env):
            try adapter.appendMessage(.skill(SessionMessageSchema.Skill(
                id: try SessionMessageSchema.ID.fromEvent(env.id.rawValue),
                metadata: env.metadata,
                time: SessionMessageSchema.TimeCreated(created: env.created),
                skill: env.data.id,
                name: env.data.name,
                text: env.data.text
            )))

        case .shellStarted(let env):
            var meta = env.metadata
            if case .bool(true) = env.data.shell.metadata["background"] {
                var m = meta ?? [:]
                m["background"] = .bool(true)
                meta = m
            }
            try adapter.appendMessage(.shell(SessionMessageSchema.Shell(
                id: try SessionMessageSchema.ID.fromEvent(env.id.rawValue),
                metadata: meta,
                shellID: env.data.shell.id,
                command: env.data.shell.command,
                status: env.data.shell.status,
                time: SessionMessageSchema.Shell.Time(created: env.created)
            )))

        case .shellEnded(let env):
            guard let current = try adapter.getShell(env.data.shell.id) else { return }
            try adapter.updateShell(SessionMessageSchema.Shell(
                id: current.id,
                metadata: current.metadata,
                shellID: current.shellID,
                command: current.command,
                status: env.data.shell.status,
                exit: env.data.shell.exit,
                output: env.data.output,
                time: SessionMessageSchema.Shell.Time(created: current.time.created, completed: env.created)
            ))

        case .stepStarted(let env):
            if let existing = try adapter.getAssistant(env.data.assistantMessageID) {
                let nextSnap: SessionMessageSchema.Assistant.Snapshot? = env.data.snapshot.map { startSnap in
                    SessionMessageSchema.Assistant.Snapshot(
                        start: startSnap,
                        end: existing.snapshot?.end,
                        files: existing.snapshot?.files
                    )
                } ?? existing.snapshot
                try adapter.updateAssistant(SessionMessageSchema.Assistant(
                    id: existing.id,
                    metadata: existing.metadata,
                    agent: env.data.agent,
                    model: env.data.model,
                    content: existing.content,
                    snapshot: nextSnap,
                    finish: nil,
                    rawFinish: nil,
                    native: nil,
                    cost: existing.cost,
                    tokens: existing.tokens,
                    error: nil,
                    retry: nil,
                    time: SessionMessageSchema.Assistant.Time(created: env.data.started)
                ))
                return
            }
            if let current = try adapter.getCurrentAssistant() {
                try adapter.updateAssistant(SessionMessageSchema.Assistant(
                    id: current.id,
                    metadata: current.metadata,
                    agent: current.agent,
                    model: current.model,
                    content: current.content,
                    snapshot: current.snapshot,
                    finish: current.finish,
                    rawFinish: current.rawFinish,
                    native: current.native,
                    cost: current.cost,
                    tokens: current.tokens,
                    error: current.error,
                    retry: nil,
                    time: SessionMessageSchema.Assistant.Time(
                        created: current.time.created,
                        firstToken: current.time.firstToken,
                        streamed: current.time.streamed,
                        completed: env.created
                    )
                ))
            }
            try adapter.appendMessage(.assistant(SessionMessageSchema.Assistant(
                id: env.data.assistantMessageID,
                metadata: env.metadata,
                agent: env.data.agent,
                model: env.data.model,
                content: [],
                snapshot: env.data.snapshot.map { SessionMessageSchema.Assistant.Snapshot(start: $0) },
                time: SessionMessageSchema.Assistant.Time(created: env.data.started)
            )))

        case .stepFirstToken(let env):
            try updateOwnedAssistant(env.data.assistantMessageID) { a in
                SessionMessageSchema.Assistant(
                    id: a.id, metadata: a.metadata, agent: a.agent, model: a.model, content: a.content,
                    snapshot: a.snapshot, finish: a.finish, rawFinish: a.rawFinish, native: a.native,
                    cost: a.cost, tokens: a.tokens, error: a.error, retry: a.retry,
                    time: SessionMessageSchema.Assistant.Time(
                        created: a.time.created, firstToken: env.created, streamed: a.time.streamed, completed: a.time.completed
                    )
                )
            }

        case .stepStreamed(let env):
            try updateOwnedAssistant(env.data.assistantMessageID) { a in
                SessionMessageSchema.Assistant(
                    id: a.id, metadata: a.metadata, agent: a.agent, model: a.model, content: a.content,
                    snapshot: a.snapshot, finish: a.finish, rawFinish: a.rawFinish, native: a.native,
                    cost: a.cost, tokens: a.tokens, error: a.error, retry: a.retry,
                    time: SessionMessageSchema.Assistant.Time(
                        created: a.time.created, firstToken: a.time.firstToken, streamed: env.created, completed: a.time.completed
                    )
                )
            }

        case .stepEnded(let env):
            try updateOwnedAssistant(env.data.assistantMessageID) { a in
                let nextSnap: SessionMessageSchema.Assistant.Snapshot? = (env.data.snapshot != nil || env.data.files != nil)
                    ? SessionMessageSchema.Assistant.Snapshot(
                        start: a.snapshot?.start,
                        end: env.data.snapshot,
                        files: env.data.files
                    )
                    : a.snapshot
                return SessionMessageSchema.Assistant(
                    id: a.id, metadata: a.metadata, agent: a.agent, model: a.model, content: a.content,
                    snapshot: nextSnap, finish: env.data.finish, rawFinish: env.data.rawFinish, native: env.data.native,
                    cost: env.data.cost, tokens: env.data.tokens, error: a.error, retry: a.retry,
                    time: SessionMessageSchema.Assistant.Time(
                        created: a.time.created, firstToken: a.time.firstToken, streamed: a.time.streamed, completed: env.created
                    )
                )
            }

        case .stepFailed(let env):
            try updateOwnedAssistant(env.data.assistantMessageID) { a in
                let nextSnap: SessionMessageSchema.Assistant.Snapshot? = (env.data.snapshot != nil || env.data.files != nil)
                    ? SessionMessageSchema.Assistant.Snapshot(
                        start: a.snapshot?.start,
                        end: env.data.snapshot,
                        files: env.data.files
                    )
                    : a.snapshot
                let finishReason: SessionMessageSchema.FinishReason = (env.data.finish == .contentFilter) ? .contentFilter : .error
                return SessionMessageSchema.Assistant(
                    id: a.id, metadata: a.metadata, agent: a.agent, model: a.model, content: a.content,
                    snapshot: nextSnap, finish: finishReason, rawFinish: env.data.rawFinish, native: env.data.native,
                    cost: (env.data.cost != nil && env.data.tokens != nil) ? env.data.cost : a.cost,
                    tokens: (env.data.cost != nil && env.data.tokens != nil) ? env.data.tokens : a.tokens,
                    error: env.data.error, retry: nil,
                    time: SessionMessageSchema.Assistant.Time(
                        created: a.time.created, firstToken: a.time.firstToken, streamed: a.time.streamed, completed: env.created
                    )
                )
            }

        case .textStarted(let env):
            try adapter.appendAssistantPart(
                env.data.assistantMessageID,
                part: .text(SessionMessageSchema.AssistantText(text: ""))
            )

        case .textEnded(let env):
            try adapter.updateAssistantPart(env.data.assistantMessageID, match: PartMatch(type: "text")) { part in
                guard case .text = part else { return part }
                return .text(SessionMessageSchema.AssistantText(text: env.data.text, native: env.data.native))
            }

        case .toolInputStarted(let env):
            try adapter.appendAssistantPart(
                env.data.assistantMessageID,
                part: .tool(SessionMessageSchema.AssistantTool(
                    id: env.data.id,
                    name: env.data.name,
                    state: .streaming(SessionMessageSchema.ToolStateStreaming(input: "")),
                    time: SessionMessageSchema.AssistantTool.Time(created: env.created)
                ))
            )

        case .toolInputEnded(let env):
            try adapter.updateAssistantPart(
                env.data.assistantMessageID,
                match: PartMatch(type: "tool", callID: env.data.id)
            ) { part in
                guard case .tool(let t) = part, case .streaming = t.state else { return part }
                return .tool(SessionMessageSchema.AssistantTool(
                    id: t.id, name: t.name, executed: t.executed, native: t.native,
                    state: .streaming(SessionMessageSchema.ToolStateStreaming(input: env.data.text)),
                    time: t.time
                ))
            }

        case .toolCalled(let env):
            try adapter.updateAssistantPart(
                env.data.assistantMessageID,
                match: PartMatch(type: "tool", callID: env.data.id)
            ) { part in
                guard case .tool(let t) = part else { return part }
                return .tool(SessionMessageSchema.AssistantTool(
                    id: t.id, name: t.name, executed: env.data.executed, native: env.data.native,
                    state: .running(SessionMessageSchema.ToolStateRunning(input: env.data.input, metadata: [:])),
                    time: SessionMessageSchema.AssistantTool.Time(
                        created: t.time.created, ran: env.created, completed: t.time.completed
                    )
                ))
            }

        case .toolSuccess(let env):
            try adapter.updateAssistantPart(
                env.data.assistantMessageID,
                match: PartMatch(type: "tool", callID: env.data.id)
            ) { part in
                guard case .tool(let t) = part, case .running(let running) = t.state else { return part }
                var mergedNative = t.native
                if let evNative = env.data.native {
                    var copy = mergedNative ?? [:]
                    for (k, v) in evNative { copy[k] = v }
                    mergedNative = copy
                }
                return .tool(SessionMessageSchema.AssistantTool(
                    id: t.id, name: t.name, executed: env.data.executed || (t.executed == true), native: mergedNative,
                    state: .completed(SessionMessageSchema.ToolStateCompleted(
                        input: running.input,
                        content: env.data.content,
                        metadata: env.data.metadata
                    )),
                    time: SessionMessageSchema.AssistantTool.Time(
                        created: t.time.created, ran: t.time.ran, completed: env.created
                    )
                ))
            }

        case .toolFailed(let env):
            try adapter.updateAssistantPart(
                env.data.assistantMessageID,
                match: PartMatch(type: "tool", callID: env.data.id)
            ) { part in
                guard case .tool(let t) = part else { return part }
                let toolInput: [String: JSONValue]
                switch t.state {
                case .streaming: toolInput = [:]
                case .running(let r): toolInput = r.input
                case .completed, .error: return part
                }
                var mergedNative = t.native
                if let evNative = env.data.native {
                    var copy = mergedNative ?? [:]
                    for (k, v) in evNative { copy[k] = v }
                    mergedNative = copy
                }
                return .tool(SessionMessageSchema.AssistantTool(
                    id: t.id, name: t.name, executed: env.data.executed || (t.executed == true), native: mergedNative,
                    state: .error(SessionMessageSchema.ToolStateError(
                        input: toolInput,
                        error: env.data.error,
                        content: env.data.content,
                        metadata: env.data.metadata
                    )),
                    time: SessionMessageSchema.AssistantTool.Time(
                        created: t.time.created, ran: t.time.ran, completed: env.created
                    )
                ))
            }

        case .reasoningStarted(let env):
            try adapter.appendAssistantPart(
                env.data.assistantMessageID,
                part: .reasoning(SessionMessageSchema.AssistantReasoning(
                    text: "",
                    native: env.data.native,
                    time: SessionMessageSchema.AssistantReasoning.Time(created: env.created)
                ))
            )

        case .reasoningEnded(let env):
            try adapter.updateAssistantPart(
                env.data.assistantMessageID,
                match: PartMatch(type: "reasoning", incompleteReasoning: true)
            ) { part in
                guard case .reasoning(let r) = part else { return part }
                return .reasoning(SessionMessageSchema.AssistantReasoning(
                    text: env.data.text,
                    native: env.data.native ?? r.native,
                    time: SessionMessageSchema.AssistantReasoning.Time(
                        created: r.time?.created ?? env.created,
                        completed: env.created
                    )
                ))
            }

        case .retryScheduled(let env):
            try updateOwnedAssistant(env.data.assistantMessageID) { a in
                SessionMessageSchema.Assistant(
                    id: a.id, metadata: a.metadata, agent: a.agent, model: a.model, content: a.content,
                    snapshot: a.snapshot, finish: a.finish, rawFinish: a.rawFinish, native: a.native,
                    cost: a.cost, tokens: a.tokens, error: a.error,
                    retry: SessionMessageSchema.AssistantRetry(
                        attempt: env.data.attempt, at: env.data.at, error: env.data.error
                    ),
                    time: a.time
                )
            }

        case .compactionStarted(let env):
            let compID = try env.data.inputID ?? SessionMessageSchema.ID.fromEvent(env.id.rawValue)
            try adapter.appendMessage(.compaction(.running(SessionMessageSchema.CompactionRunning(
                id: compID,
                metadata: env.metadata,
                time: SessionMessageSchema.TimeCreated(created: env.created),
                reason: env.data.reason,
                summary: ""
            ))))

        case .compactionEnded(let env):
            if let current = try adapter.getCompaction(), case .running(let running) = current {
                var mergedMeta = running.metadata
                if let evMeta = env.metadata {
                    var copy = mergedMeta ?? [:]
                    for (k, v) in evMeta { copy[k] = v }
                    mergedMeta = copy
                }
                try adapter.updateCompaction(.completed(SessionMessageSchema.CompactionCompleted(
                    id: running.id,
                    metadata: mergedMeta,
                    time: running.time,
                    reason: env.data.reason,
                    model: env.data.model,
                    native: env.data.native,
                    summary: env.data.text,
                    cost: env.data.cost,
                    tokens: env.data.tokens
                )))
                return
            }
            try adapter.appendMessage(.compaction(.completed(SessionMessageSchema.CompactionCompleted(
                id: try SessionMessageSchema.ID.fromEvent(env.id.rawValue),
                metadata: env.metadata,
                time: SessionMessageSchema.TimeCreated(created: env.created),
                reason: env.data.reason,
                model: env.data.model,
                native: env.data.native,
                summary: env.data.text,
                cost: env.data.cost,
                tokens: env.data.tokens
            ))))

        case .compactionFailed(let env):
            let current = try adapter.getCompaction()
            let existingID: SessionMessageSchema.ID? = current?.id
            let existingMeta: [String: JSONValue]?
            let existingTime: SessionMessageSchema.TimeCreated?
            if case .running(let r) = current {
                existingMeta = r.metadata
                existingTime = r.time
            } else {
                existingMeta = nil
                existingTime = nil
            }
            let compID = try existingID ?? env.data.inputID ?? SessionMessageSchema.ID.fromEvent(env.id.rawValue)
            let failed = SessionMessageSchema.Compaction.failed(SessionMessageSchema.CompactionFailed(
                id: compID,
                metadata: existingMeta ?? env.metadata,
                time: existingTime ?? SessionMessageSchema.TimeCreated(created: env.created),
                reason: env.data.reason,
                error: env.data.error,
                cost: env.data.cost,
                tokens: env.data.tokens
            ))
            if case .running = current {
                try adapter.updateCompaction(failed)
            } else {
                try adapter.appendMessage(.compaction(failed))
            }
        }
    }
}

// MARK: - session/projector.ts

/// Transactional SQLite projector wiring all 48 durable session events + `worktree.resolved`
/// onto `session_v2`, `session_message`, `session_part`, `session_inbox`, `instruction_*`, and `blob*`.
///
/// Ports `packages/core/src/session/projector.ts`.
public enum CoreSessionProjector {
    /// Raised inside a `session.created` / `session.forked` projection when the Session row already exists.
    // parity: core/src/session/projector.ts#SessionAlreadyProjected [status=implemented hash=33b5a109c7d0]
    public struct SessionAlreadyProjected: Swift.Error, Equatable, Hashable, Sendable {
        public init() {}
    }

    public struct Options: Sendable {
        public let partRowsEnabled: Bool
        public let mediaBlobEnabled: Bool

        public init(partRowsEnabled: Bool = false, mediaBlobEnabled: Bool = false) {
            self.partRowsEnabled = partRowsEnabled
            self.mediaBlobEnabled = mediaBlobEnabled
        }
    }

    /// Registers all durable session projectors onto `bus` backed by `db`.
    public static func register(
        bus: CoreBus.Service,
        db: any SQLiteDatabase,
        options: Options = Options()
    ) {
        // session.created
        bus.project(SessionEventSchema.Created) { env in
            let modelJSON: SQLiteValue = try env.data.model.map { .text(try CoreBusJSON.encodeToString($0)) } ?? .null
            let metaJSON: SQLiteValue = try env.data.metadata.map { .text(try CoreBusJSON.encodeToString($0)) } ?? .null
            let permJSON: SQLiteValue = try env.data.permissions.map { .text(try CoreBusJSON.encodeToString($0)) } ?? .null
            let stored = try db.queryOne(
                """
                INSERT INTO `session_v2` (
                  `id`, `project_id`, `workspace_id`, `parent_id`, `slug`, `directory`, `path`,
                  `title`, `agent`, `model`, `metadata`, `permission`, `version`,
                  `time_created`, `time_updated`
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (`id`) DO NOTHING
                RETURNING `id`
                """,
                parameters: [
                    .text(env.data.sessionID.rawValue),
                    .text(env.data.projectID.rawValue),
                    env.data.location.workspaceID.map { .text($0.rawValue) } ?? .null,
                    env.data.parentID.map { .text($0.rawValue) } ?? .null,
                    .text(env.data.slug),
                    .text(env.data.location.directory),
                    env.data.subpath.map(SQLiteValue.text) ?? .null,
                    env.data.title.map(SQLiteValue.text) ?? .null,
                    env.data.agent.map(SQLiteValue.text) ?? .null,
                    modelJSON,
                    metaJSON,
                    permJSON,
                    .text(env.data.version),
                    .integer(env.created),
                    .integer(env.created),
                ]
            )
            if stored == nil {
                throw SessionAlreadyProjected()
            }
        }

        // session.moved
        bus.project(SessionEventSchema.Moved) { env in
            try projectMessageEvent(db: db, event: .moved(env), seq: env.durable.seq.rawValue, created: env.created, metadata: env.metadata, options: options)
            _ = try db.execute(
                """
                UPDATE `session_v2`
                SET `directory` = ?, `path` = ?, `project_id` = ?, `workspace_id` = ?, `time_updated` = ?
                WHERE `id` = ?
                """,
                parameters: [
                    .text(env.data.location.directory),
                    env.data.subpath.map(SQLiteValue.text) ?? .null,
                    .text(env.data.projectID.rawValue),
                    env.data.location.workspaceID.map { .text($0.rawValue) } ?? .null,
                    .integer(env.created),
                    .text(env.data.sessionID.rawValue),
                ]
            )
        }

        // worktree.resolved
        bus.project(definition: EventSchema.Definition.durable(
            type: "worktree.resolved",
            aggregate: "projectID",
            version: 1
        )) { payload in
            guard case .durable(let env) = payload else { return }
            let resolved = try CoreBusJSON.decodeFromJSONValue(env.data, as: WorktreeSchema.Event.ResolvedPayload.self)
            var candidates: [String] = []
            for id in [resolved.previous.rawValue, ProjectID.global.rawValue] + (resolved.adopted?.map(\.rawValue) ?? []) {
                if id != resolved.projectID.rawValue && !candidates.contains(id) {
                    candidates.append(id)
                }
            }
            if candidates.isEmpty { return }
            let placeholders = Array(repeating: "?", count: candidates.count).joined(separator: ", ")
            let rows = try db.query(
                """
                SELECT s.`id`, s.`directory`, s.`project_id`, p.`worktree`
                FROM `session_v2` s
                INNER JOIN `project` p ON s.`project_id` = p.`id`
                WHERE s.`project_id` IN (\(placeholders)) AND s.`workspace_id` IS NULL
                """,
                parameters: candidates.map(SQLiteValue.text)
            )
            let adoptEvent = WorktreeSchema.AdoptEvent(
                projectID: resolved.projectID.rawValue,
                directory: resolved.directory.rawValue,
                previous: resolved.previous.rawValue,
                adopted: resolved.adopted?.map(\.rawValue)
            )
            for row in rows {
                guard let id = row.string("id"),
                      let dir = row.string("directory"),
                      let pid = row.string("project_id")
                else { continue }
                let adopted = WorktreeSchema.adopt(
                    WorktreeSchema.AdoptSession(projectID: pid, directory: dir, workspaceID: nil),
                    adoptEvent
                )
                guard let adoption = adopted else { continue }
                _ = try db.execute(
                    "UPDATE `session_v2` SET `project_id` = ?, `path` = ?, `time_updated` = `time_updated` WHERE `id` = ?",
                    parameters: [
                        .text(adoption.projectID),
                        .text(adoption.subpath ?? ""),
                        .text(id),
                    ]
                )
            }
        }

        // session.deleted
        bus.project(SessionEventSchema.Deleted) { env in
            try CoreSessionBlob.releaseSession(db, sessionID: env.data.sessionID)
            _ = try db.execute(
                "DELETE FROM `session_v2` WHERE `id` = ?",
                parameters: [.text(env.data.sessionID.rawValue)]
            )
        }

        // session.agent.selected
        bus.project(SessionEventSchema.AgentSelected) { env in
            try projectMessageEvent(db: db, event: .agentSelected(env), seq: env.durable.seq.rawValue, created: env.created, metadata: env.metadata, options: options)
            _ = try db.execute(
                "UPDATE `session_v2` SET `agent` = ?, `time_updated` = ? WHERE `id` = ?",
                parameters: [.text(env.data.agent), .integer(env.created), .text(env.data.sessionID.rawValue)]
            )
        }

        // session.model.selected
        bus.project(SessionEventSchema.ModelSelected) { env in
            try projectMessageEvent(db: db, event: .modelSelected(env), seq: env.durable.seq.rawValue, created: env.created, metadata: env.metadata, options: options)
            let modelJSON = try CoreBusJSON.encodeToString(env.data.model)
            _ = try db.execute(
                "UPDATE `session_v2` SET `model` = ?, `time_updated` = ? WHERE `id` = ?",
                parameters: [.text(modelJSON), .integer(env.created), .text(env.data.sessionID.rawValue)]
            )
        }

        // session.renamed / metadata / permissions / viewed / archived / unarchived
        bus.project(SessionEventSchema.Renamed) { env in
            _ = try db.execute(
                "UPDATE `session_v2` SET `title` = ?, `time_updated` = ? WHERE `id` = ?",
                parameters: [.text(env.data.title), .integer(env.created), .text(env.data.sessionID.rawValue)]
            )
        }
        bus.project(SessionEventSchema.MetadataUpdated) { env in
            let json = try CoreBusJSON.encodeToString(env.data.metadata)
            _ = try db.execute(
                "UPDATE `session_v2` SET `metadata` = ?, `time_updated` = ? WHERE `id` = ?",
                parameters: [.text(json), .integer(env.created), .text(env.data.sessionID.rawValue)]
            )
        }
        bus.project(SessionEventSchema.Permissions) { env in
            let json = try CoreBusJSON.encodeToString(env.data.permissions)
            _ = try db.execute(
                "UPDATE `session_v2` SET `permission` = ?, `time_updated` = ? WHERE `id` = ?",
                parameters: [.text(json), .integer(env.created), .text(env.data.sessionID.rawValue)]
            )
        }
        bus.project(SessionEventSchema.Viewed) { env in
            _ = try db.execute(
                """
                UPDATE `session_v2`
                SET `time_viewed` = max(?, coalesce(`time_viewed`, ?)), `time_updated` = `time_updated`
                WHERE `id` = ?
                """,
                parameters: [.integer(env.data.idle), .integer(env.data.idle), .text(env.data.sessionID.rawValue)]
            )
        }
        bus.project(SessionEventSchema.Archived) { env in
            _ = try db.execute(
                "UPDATE `session_v2` SET `time_archived` = ?, `time_updated` = ? WHERE `id` = ?",
                parameters: [.integer(env.created), .integer(env.created), .text(env.data.sessionID.rawValue)]
            )
        }
        bus.project(SessionEventSchema.Unarchived) { env in
            _ = try db.execute(
                "UPDATE `session_v2` SET `time_archived` = NULL, `time_updated` = ? WHERE `id` = ?",
                parameters: [.integer(env.created), .text(env.data.sessionID.rawValue)]
            )
        }

        // session.message.content.updated / usage.recorded / forked
        bus.project(SessionEventSchema.MessageContentUpdated) { env in
            try projectMessageEvent(db: db, event: .messageContentUpdated(env), seq: env.durable.seq.rawValue, created: env.created, metadata: env.metadata, options: options)
        }
        bus.project(SessionEventSchema.UsageRecorded) { env in
            try applyUsage(db: db, sessionID: env.data.sessionID, cost: env.data.cost, tokens: env.data.tokens, timeUpdated: nil)
        }
        bus.project(SessionEventSchema.Forked) { env in
            try projectFork(db: db, event: env)
        }

        // session.inbox.*
        bus.project(SessionEventSchema.InboxEnqueued) { env in
            try CoreSessionInbox.projectAdmitted(
                db: db,
                enqueuedSeq: env.durable.seq.rawValue,
                id: env.data.inboxID,
                sessionID: env.data.sessionID,
                item: env.data.item,
                timeCreated: env.created,
                mediaBlobEnabled: options.mediaBlobEnabled
            )
            _ = try db.execute(
                "UPDATE `session_v2` SET `time_updated` = ? WHERE `id` = ?",
                parameters: [.integer(env.created), .text(env.data.sessionID.rawValue)]
            )
        }
        bus.project(SessionEventSchema.InboxDelivered) { env in
            let delivered = try CoreSessionInbox.projectDelivered(
                db: db,
                id: env.data.inboxID,
                sessionID: env.data.sessionID
            )
            let time = SessionMessageSchema.TimeCreated(created: env.created)
            switch delivered {
            case .user(let id, let storedPayload):
                var dict: [String: JSONValue] = [
                    "text": .string(storedPayload.text),
                    "time": .object(["created": .int(time.created)]),
                ]
                if let files = storedPayload.files {
                    dict["files"] = try CoreBusJSON.encodeToJSONValue(files)
                }
                if let agents = storedPayload.agents {
                    dict["agents"] = try CoreBusJSON.encodeToJSONValue(agents)
                }
                if let skills = storedPayload.skills {
                    dict["skills"] = try CoreBusJSON.encodeToJSONValue(skills)
                }
                if let meta = storedPayload.metadata {
                    dict["metadata"] = .object(meta)
                }
                try insertRawMessage(
                    db: db,
                    sessionID: env.data.sessionID,
                    messageID: id,
                    type: .user,
                    seq: env.durable.seq.rawValue,
                    timeCreated: env.created,
                    data: dict,
                    mediaBlobEnabled: options.mediaBlobEnabled
                )
            case .synthetic(let id, let payload):
                try insertMessage(
                    db: db,
                    sessionID: env.data.sessionID,
                    seq: env.durable.seq.rawValue,
                    eventCreated: env.created,
                    message: .synthetic(SessionMessageSchema.Synthetic(
                        id: id,
                        metadata: payload.metadata,
                        time: time,
                        text: payload.text,
                        description: payload.description
                    )),
                    mediaBlobEnabled: options.mediaBlobEnabled
                )
            case .compaction, .move:
                break
            }
        }
        bus.project(SessionEventSchema.InboxCancelled) { env in
            try CoreSessionInbox.projectCancelled(db: db, id: env.data.inboxID, sessionID: env.data.sessionID)
        }
        bus.project(SessionEventSchema.InboxDeliveryChanged) { env in
            try CoreSessionInbox.projectDeliveryChanged(
                db: db,
                id: env.data.inboxID,
                sessionID: env.data.sessionID,
                delivery: env.data.delivery
            )
        }

        // session.execution.*
        bus.project(SessionEventSchema.Execution.Started) { env in
            _ = try db.execute(
                "UPDATE `session_v2` SET `time_busy` = ?, `time_updated` = `time_updated` WHERE `id` = ?",
                parameters: [.integer(env.created), .text(env.data.sessionID.rawValue)]
            )
        }
        bus.project(SessionEventSchema.Execution.Succeeded) { env in
            try projectIdle(db: db, event: .executionSucceeded(env), sessionID: env.data.sessionID, seq: env.durable.seq.rawValue, created: env.created, metadata: env.metadata, outcome: .succeeded, isShutdown: false, options: options)
        }
        bus.project(SessionEventSchema.Execution.Failed) { env in
            try projectIdle(db: db, event: .executionFailed(env), sessionID: env.data.sessionID, seq: env.durable.seq.rawValue, created: env.created, metadata: env.metadata, outcome: .failed, isShutdown: false, options: options)
        }
        bus.project(SessionEventSchema.Execution.Interrupted) { env in
            try projectIdle(db: db, event: .executionInterrupted(env), sessionID: env.data.sessionID, seq: env.durable.seq.rawValue, created: env.created, metadata: env.metadata, outcome: .interrupted, isShutdown: env.data.reason == .shutdown, options: options)
        }

        // instructions / synthetic / skill / shell
        bus.project(SessionEventSchema.InstructionsUpdated) { env in
            try projectMessageEvent(db: db, event: .instructionsUpdated(env), seq: env.durable.seq.rawValue, created: env.created, metadata: env.metadata, options: options)
            try CoreSessionInstructionState.apply(
                db: db,
                sessionID: env.data.sessionID,
                seq: env.durable.seq.rawValue,
                delta: env.data.delta
            )
        }
        bus.project(SessionEventSchema.Synthetic) { env in
            try projectMessageEvent(db: db, event: .synthetic(env), seq: env.durable.seq.rawValue, created: env.created, metadata: env.metadata, options: options)
        }
        bus.project(SessionEventSchema.Skill.Activated) { env in
            try projectMessageEvent(db: db, event: .skillActivated(env), seq: env.durable.seq.rawValue, created: env.created, metadata: env.metadata, options: options)
        }
        bus.project(SessionEventSchema.Shell.Started) { env in
            try projectMessageEvent(db: db, event: .shellStarted(env), seq: env.durable.seq.rawValue, created: env.created, metadata: env.metadata, options: options)
        }
        bus.project(SessionEventSchema.Shell.Ended) { env in
            try projectMessageEvent(db: db, event: .shellEnded(env), seq: env.durable.seq.rawValue, created: env.created, metadata: env.metadata, options: options)
        }

        // step / text / reasoning / tool / retry
        bus.project(SessionEventSchema.Step.Started) { env in
            try projectMessageEvent(db: db, event: .stepStarted(env), seq: env.durable.seq.rawValue, created: env.created, metadata: env.metadata, options: options)
            _ = try db.execute(
                "UPDATE `session_v2` SET `time_updated` = ? WHERE `id` = ?",
                parameters: [.integer(env.created), .text(env.data.sessionID.rawValue)]
            )
        }
        bus.project(SessionEventSchema.Step.FirstToken) { env in
            try projectMessageEvent(db: db, event: .stepFirstToken(env), seq: env.durable.seq.rawValue, created: env.created, metadata: env.metadata, options: options)
        }
        bus.project(SessionEventSchema.Step.Streamed) { env in
            try projectMessageEvent(db: db, event: .stepStreamed(env), seq: env.durable.seq.rawValue, created: env.created, metadata: env.metadata, options: options)
        }
        bus.project(SessionEventSchema.Step.Ended) { env in
            try projectMessageEvent(db: db, event: .stepEnded(env), seq: env.durable.seq.rawValue, created: env.created, metadata: env.metadata, options: options)
            try applyUsage(db: db, sessionID: env.data.sessionID, cost: env.data.cost, tokens: env.data.tokens, timeUpdated: env.created)
        }
        bus.project(SessionEventSchema.Step.Failed) { env in
            try projectMessageEvent(db: db, event: .stepFailed(env), seq: env.durable.seq.rawValue, created: env.created, metadata: env.metadata, options: options)
            if let cost = env.data.cost, let tokens = env.data.tokens {
                try applyUsage(db: db, sessionID: env.data.sessionID, cost: cost, tokens: tokens, timeUpdated: env.created)
            } else {
                _ = try db.execute(
                    "UPDATE `session_v2` SET `time_updated` = ? WHERE `id` = ?",
                    parameters: [.integer(env.created), .text(env.data.sessionID.rawValue)]
                )
            }
        }
        bus.project(SessionEventSchema.Text.Started) { env in
            try projectMessageEvent(db: db, event: .textStarted(env), seq: env.durable.seq.rawValue, created: env.created, metadata: env.metadata, options: options)
        }
        bus.project(SessionEventSchema.Text.Ended) { env in
            try projectMessageEvent(db: db, event: .textEnded(env), seq: env.durable.seq.rawValue, created: env.created, metadata: env.metadata, options: options)
        }
        bus.project(SessionEventSchema.Tool.Input.Started) { env in
            try projectMessageEvent(db: db, event: .toolInputStarted(env), seq: env.durable.seq.rawValue, created: env.created, metadata: env.metadata, options: options)
        }
        bus.project(SessionEventSchema.Tool.Input.Ended) { env in
            try projectMessageEvent(db: db, event: .toolInputEnded(env), seq: env.durable.seq.rawValue, created: env.created, metadata: env.metadata, options: options)
        }
        bus.project(SessionEventSchema.Tool.Called) { env in
            try projectMessageEvent(db: db, event: .toolCalled(env), seq: env.durable.seq.rawValue, created: env.created, metadata: env.metadata, options: options)
        }
        bus.project(SessionEventSchema.Tool.Success) { env in
            try projectMessageEvent(db: db, event: .toolSuccess(env), seq: env.durable.seq.rawValue, created: env.created, metadata: env.metadata, options: options)
        }
        bus.project(SessionEventSchema.Tool.Failed) { env in
            try projectMessageEvent(db: db, event: .toolFailed(env), seq: env.durable.seq.rawValue, created: env.created, metadata: env.metadata, options: options)
        }
        bus.project(SessionEventSchema.Reasoning.Started) { env in
            try projectMessageEvent(db: db, event: .reasoningStarted(env), seq: env.durable.seq.rawValue, created: env.created, metadata: env.metadata, options: options)
        }
        bus.project(SessionEventSchema.Reasoning.Ended) { env in
            try projectMessageEvent(db: db, event: .reasoningEnded(env), seq: env.durable.seq.rawValue, created: env.created, metadata: env.metadata, options: options)
        }
        bus.project(SessionEventSchema.RetryScheduled) { env in
            try projectMessageEvent(db: db, event: .retryScheduled(env), seq: env.durable.seq.rawValue, created: env.created, metadata: env.metadata, options: options)
        }

        // compaction
        bus.project(SessionEventSchema.Compaction.Started) { env in
            try projectMessageEvent(db: db, event: .compactionStarted(env), seq: env.durable.seq.rawValue, created: env.created, metadata: env.metadata, options: options)
        }
        bus.project(SessionEventSchema.Compaction.Ended) { env in
            try projectMessageEvent(db: db, event: .compactionEnded(env), seq: env.durable.seq.rawValue, created: env.created, metadata: env.metadata, options: options)
            try CoreSessionInstructionState.advanceEpoch(
                db: db,
                sessionID: env.data.sessionID,
                epochStart: env.durable.seq.rawValue
            )
        }
        bus.project(SessionEventSchema.Compaction.Failed) { env in
            try projectMessageEvent(db: db, event: .compactionFailed(env), seq: env.durable.seq.rawValue, created: env.created, metadata: env.metadata, options: options)
        }

        // revert
        bus.project(SessionEventSchema.RevertEvent.Staged) { env in
            let json = try CoreBusJSON.encodeToString(env.data.revert)
            _ = try db.execute(
                "UPDATE `session_v2` SET `revert` = ?, `time_updated` = ? WHERE `id` = ?",
                parameters: [.text(json), .integer(env.created), .text(env.data.sessionID.rawValue)]
            )
        }
        bus.project(SessionEventSchema.RevertEvent.Cleared) { env in
            _ = try db.execute(
                "UPDATE `session_v2` SET `revert` = NULL, `time_updated` = ? WHERE `id` = ?",
                parameters: [.integer(env.created), .text(env.data.sessionID.rawValue)]
            )
        }
        bus.project(SessionEventSchema.RevertEvent.Committed) { env in
            guard let boundary = try db.queryOne(
                "SELECT `seq` FROM `session_message` WHERE `session_id` = ? AND `id` = ?",
                parameters: [.text(env.data.sessionID.rawValue), .text(env.data.to.rawValue)]
            ), let boundarySeq = boundary.int64("seq") else {
                throw CoreSessionErrors.MessageNotFoundError(sessionID: env.data.sessionID, messageID: env.data.to)
            }
            _ = try db.execute(
                "DELETE FROM `session_message` WHERE `session_id` = ? AND `seq` >= ?",
                parameters: [.text(env.data.sessionID.rawValue), .integer(boundarySeq)]
            )
            _ = try db.execute(
                "DELETE FROM `session_inbox` WHERE `session_id` = ? AND `enqueued_seq` >= ?",
                parameters: [.text(env.data.sessionID.rawValue), .integer(boundarySeq)]
            )
            _ = try db.execute(
                "UPDATE `session_v2` SET `revert` = NULL, `time_updated` = ? WHERE `id` = ?",
                parameters: [.integer(env.created), .text(env.data.sessionID.rawValue)]
            )
            try CoreSessionInstructionState.rewind(db: db, sessionID: env.data.sessionID, boundary: boundarySeq)
            try CoreSessionBlob.releaseFrom(db, sessionID: env.data.sessionID, seq: boundarySeq)
        }
    }

    // MARK: Projection Helpers

    private static func applyUsage(
        db: any SQLiteDatabase,
        sessionID: SessionID,
        cost: Double,
        tokens: SessionSchema.TokenUsage,
        timeUpdated: Int64?
    ) throws {
        if let timeUpdated {
            _ = try db.execute(
                """
                UPDATE `session_v2`
                SET `cost` = `cost` + ?,
                    `tokens_input` = `tokens_input` + ?,
                    `tokens_output` = `tokens_output` + ?,
                    `tokens_reasoning` = `tokens_reasoning` + ?,
                    `tokens_cache_read` = `tokens_cache_read` + ?,
                    `tokens_cache_write` = `tokens_cache_write` + ?,
                    `time_updated` = ?
                WHERE `id` = ?
                """,
                parameters: [
                    .real(cost),
                    .integer(Int64(tokens.input)),
                    .integer(Int64(tokens.output)),
                    .integer(Int64(tokens.reasoning)),
                    .integer(Int64(tokens.cache.read)),
                    .integer(Int64(tokens.cache.write)),
                    .integer(timeUpdated),
                    .text(sessionID.rawValue),
                ]
            )
        } else {
            _ = try db.execute(
                """
                UPDATE `session_v2`
                SET `cost` = `cost` + ?,
                    `tokens_input` = `tokens_input` + ?,
                    `tokens_output` = `tokens_output` + ?,
                    `tokens_reasoning` = `tokens_reasoning` + ?,
                    `tokens_cache_read` = `tokens_cache_read` + ?,
                    `tokens_cache_write` = `tokens_cache_write` + ?,
                    `time_updated` = `time_updated`
                WHERE `id` = ?
                """,
                parameters: [
                    .real(cost),
                    .integer(Int64(tokens.input)),
                    .integer(Int64(tokens.output)),
                    .integer(Int64(tokens.reasoning)),
                    .integer(Int64(tokens.cache.read)),
                    .integer(Int64(tokens.cache.write)),
                    .text(sessionID.rawValue),
                ]
            )
        }
    }

    private static func projectIdle(
        db: any SQLiteDatabase,
        event: SessionEventSchema.DurableEvent,
        sessionID: SessionID,
        seq: Int64,
        created: Int64,
        metadata: [String: JSONValue]?,
        outcome: SessionSchema.Outcome,
        isShutdown: Bool,
        options: Options
    ) throws {
        try projectMessageEvent(db: db, event: event, seq: seq, created: created, metadata: metadata, options: options)
        if isShutdown { return }
        _ = try db.execute(
            """
            UPDATE `session_v2`
            SET `time_idle` = max(?, coalesce(`time_idle` + 1, ?)),
                `idle_outcome` = ?,
                `time_updated` = `time_updated`
            WHERE `id` = ?
            """,
            parameters: [
                .integer(created),
                .integer(created),
                .text(outcome.rawValue),
                .text(sessionID.rawValue),
            ]
        )
    }

    private static func forkTitle(_ value: String?) -> String? {
        guard let value else { return nil }
        if let regex = try? Regex("^(.+) \\(fork #(\\d+)\\)$"),
           let match = value.firstMatch(of: regex),
           match.output.count >= 3,
           let base = match.output[1].substring,
           let numStr = match.output[2].substring,
           let num = Int(numStr)
        {
            return "\(base) (fork #\(num + 1))"
        }
        return "\(value) (fork #1)"
    }

    private static func projectFork(
        db: any SQLiteDatabase,
        event: EventSchema.DurableEventEnvelope<SessionEventSchema.ForkedData>
    ) throws {
        guard let parent = try db.queryOne(
            "SELECT * FROM `session_v2` WHERE `id` = ?",
            parameters: [.text(event.data.parentID.rawValue)]
        ) else {
            throw CoreSessionErrors.NotFoundError(sessionID: event.data.parentID)
        }
        guard let boundaryRow = try db.queryOne(
            "SELECT `seq` FROM `session_message` WHERE `session_id` = ? AND `id` = ?",
            parameters: [.text(event.data.parentID.rawValue), .text(event.data.boundary.messageID.rawValue)]
        ), let boundarySeq = boundaryRow.int64("seq") else {
            throw CoreSessionErrors.MessageNotFoundError(
                sessionID: event.data.parentID,
                messageID: event.data.boundary.messageID
            )
        }

        let op = event.data.boundary.typeTag == "before" ? "<" : "<="
        let copiedSeq = try db.queryOne(
            "SELECT `seq` FROM `session_message` WHERE `session_id` = ? AND `seq` \(op) ? ORDER BY `seq` DESC LIMIT 1",
            parameters: [.text(event.data.parentID.rawValue), .integer(boundarySeq)]
        )?.int64("seq")

        let boundaryJSON = try CoreBusJSON.encodeToString(event.data.boundary)
        let nextTitle = forkTitle(parent.string("title"))
        let stored = try db.queryOne(
            """
            INSERT INTO `session_v2` (
              `id`, `parent_id`, `fork_session_id`, `fork_boundary`, `project_id`, `workspace_id`,
              `slug`, `directory`, `path`, `title`, `agent`, `model`, `metadata`, `permission`, `version`,
              `cost`, `tokens_input`, `tokens_output`, `tokens_reasoning`, `tokens_cache_read`, `tokens_cache_write`,
              `time_created`, `time_updated`
            ) VALUES (?, NULL, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, 0, 0, 0, 0, 0, ?, ?)
            ON CONFLICT (`id`) DO NOTHING
            RETURNING `id`
            """,
            parameters: [
                .text(event.data.sessionID.rawValue),
                .text(event.data.parentID.rawValue),
                .text(boundaryJSON),
                parent["project_id"] ?? .null,
                parent["workspace_id"] ?? .null,
                .text("fork-\(Identifier.ascending().prefix(8))"),
                parent["directory"] ?? .text(""),
                parent["path"] ?? .null,
                nextTitle.map(SQLiteValue.text) ?? .null,
                parent["agent"] ?? .null,
                parent["model"] ?? .null,
                parent["metadata"] ?? .null,
                parent["permission"] ?? .null,
                parent["version"] ?? .text("0.0.0"),
                .integer(event.created),
                .integer(event.created),
            ]
        )
        if stored == nil {
            throw SessionAlreadyProjected()
        }

        if let entries = event.data.instructionEntries {
            try CoreSessionInstructionEntry.initialize(
                db: db,
                sessionID: event.data.sessionID,
                entries: entries,
                created: event.created
            )
        }

        let baseMsgID = try SessionMessageSchema.ID.fromEvent(event.id.rawValue).rawValue
        let forkedID: (Int64) -> SessionMessageSchema.ID = { seq in
            SessionMessageSchema.ID(rawValue: "\(baseMsgID)_\(seq)")!
        }

        if let copiedSeq {
            let rows = try db.query(
                """
                SELECT * FROM `session_message`
                WHERE `session_id` = ? AND `seq` <= ?
                  AND (`type` != 'assistant' OR json_extract(`data`, '$.time.completed') IS NOT NULL)
                  AND (`type` != 'shell' OR json_extract(`data`, '$.status') != 'running')
                  AND (`type` != 'compaction' OR json_extract(`data`, '$.status') != 'running')
                ORDER BY `seq` ASC
                """,
                parameters: [.text(event.data.parentID.rawValue), .integer(copiedSeq)]
            )
            let media = CoreSessionBlob.forkMedia
            for row in rows {
                let parsed = try CoreSessionHistory.parseMessageRow(row)
                let newID = forkedID(parsed.seq)
                var copiedData = media ? try CoreSessionBlob.externalizeRow(db, data: parsed.data) : parsed.data
                if parsed.type == .compaction,
                   case .object(var meta) = copiedData["metadata"],
                   case .string(let keepStr) = meta["keepID"],
                   let keptSeq = try db.queryOne(
                       "SELECT `seq` FROM `session_message` WHERE `session_id` = ? AND `id` = ?",
                       parameters: [.text(event.data.parentID.rawValue), .text(keepStr)]
                   )?.int64("seq")
                {
                    meta["keepID"] = .string(forkedID(keptSeq).rawValue)
                    copiedData["metadata"] = .object(meta)
                }
                let jsonStr = try CoreBusJSON.encodeJSONValue(.object(copiedData))
                _ = try db.execute(
                    """
                    INSERT INTO `session_message` (`id`, `session_id`, `type`, `seq`, `time_created`, `time_updated`, `data`)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    parameters: [
                        .text(newID.rawValue),
                        .text(event.data.sessionID.rawValue),
                        .text(parsed.type.rawValue),
                        .integer(parsed.seq),
                        .integer(parsed.timeCreated),
                        .integer(parsed.timeUpdated),
                        .text(jsonStr),
                    ]
                )
                try CoreSessionBlob.recordRefs(
                    db,
                    owner: CoreSessionBlob.Owner(sessionID: event.data.sessionID, messageID: newID, seq: parsed.seq),
                    data: copiedData
                )

                if parsed.type == .assistant {
                    let parts = try db.query(
                        "SELECT * FROM `session_part` WHERE `session_id` = ? AND `message_id` = ? ORDER BY `ordinal` ASC",
                        parameters: [.text(event.data.parentID.rawValue), .text(parsed.id.rawValue)]
                    )
                    for part in parts {
                        guard let ord = part.int64("ordinal"),
                              let pType = part.string("type"),
                              let pCreated = part.int64("time_created"),
                              let pUpdated = part.int64("time_updated"),
                              let rawPart = part.string("data")
                        else { continue }
                        let partJSON: String
                        if media, case .object(let pDict) = try CoreBusJSON.decodeJSONValue(rawPart) {
                            let split = CoreSessionBlob.split(pDict)
                            if split.moved { try CoreSessionBlob.save(db, blobs: split.blobs) }
                            partJSON = try CoreBusJSON.encodeJSONValue(.object(split.data))
                            try CoreSessionBlob.recordRefs(
                                db,
                                owner: CoreSessionBlob.Owner(sessionID: event.data.sessionID, messageID: newID, seq: parsed.seq),
                                data: split.data
                            )
                        } else {
                            partJSON = rawPart
                        }
                        _ = try db.execute(
                            """
                            INSERT INTO `session_part` (`message_id`, `session_id`, `ordinal`, `type`, `call_id`, `time_created`, `time_updated`, `data`)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                            """,
                            parameters: [
                                .text(newID.rawValue),
                                .text(event.data.sessionID.rawValue),
                                .integer(ord),
                                .text(pType),
                                part["call_id"] ?? .null,
                                .integer(pCreated),
                                .integer(pUpdated),
                                .text(partJSON),
                            ]
                        )
                    }
                }
            }
            try CoreBus.reserveSequence(db: db, aggregateID: event.data.sessionID.rawValue, seq: copiedSeq)
        }

        if let instructions = event.data.instructions {
            try CoreSessionInstructionState.initialize(
                db: db,
                sessionID: event.data.sessionID,
                seq: event.durable.seq.rawValue,
                values: instructions
            )
        }
    }

    private static func insertRawMessage(
        db: any SQLiteDatabase,
        sessionID: SessionID,
        messageID: SessionMessageSchema.ID,
        type: SessionMessageSchema.MessageType,
        seq: Int64,
        timeCreated: Int64,
        data: [String: JSONValue],
        mediaBlobEnabled: Bool
    ) throws {
        let ext = try CoreSessionBlob.externalize(db, messageData: data, mediaBlobEnabled: mediaBlobEnabled)
        let jsonStr = try CoreBusJSON.encodeJSONValue(.object(ext.data))
        _ = try db.execute(
            """
            INSERT INTO `session_message` (`id`, `session_id`, `type`, `seq`, `time_created`, `time_updated`, `data`)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            parameters: [
                .text(messageID.rawValue),
                .text(sessionID.rawValue),
                .text(type.rawValue),
                .integer(seq),
                .integer(timeCreated),
                .integer(timeCreated),
                .text(jsonStr),
            ]
        )
        try CoreSessionBlob.recordRefs(
            db,
            owner: CoreSessionBlob.Owner(sessionID: sessionID, messageID: messageID, seq: seq),
            data: ext.data
        )
    }

    private static func insertMessage(
        db: any SQLiteDatabase,
        sessionID: SessionID,
        seq: Int64,
        eventCreated: Int64,
        message: SessionMessageSchema.Info,
        mediaBlobEnabled: Bool
    ) throws {
        guard case .object(var dict) = try CoreBusJSON.encodeToJSONValue(message) else { return }
        dict.removeValue(forKey: "id")
        dict.removeValue(forKey: "type")
        let timeCreated: Int64 = if case .object(let t) = dict["time"], case .int(let c) = t["created"] {
            c
        } else {
            eventCreated
        }
        let ext = try CoreSessionBlob.externalize(db, messageData: dict, mediaBlobEnabled: mediaBlobEnabled)
        var envelopeData = ext.data

        var parts: [SessionMessageSchema.AssistantContent] = []
        if case .assistant(let a) = message, !a.content.isEmpty {
            parts = a.content
            envelopeData["content"] = .array([])
        }

        let jsonStr = try CoreBusJSON.encodeJSONValue(.object(envelopeData))
        _ = try db.execute(
            """
            INSERT INTO `session_message` (`id`, `session_id`, `type`, `seq`, `time_created`, `time_updated`, `data`)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            parameters: [
                .text(message.id.rawValue),
                .text(sessionID.rawValue),
                .text(message.messageType.rawValue),
                .integer(seq),
                .integer(timeCreated),
                .integer(eventCreated),
                .text(jsonStr),
            ]
        )
        for (ordinal, part) in parts.enumerated() {
            let pDict = try CoreSessionHistory.encodePart(part)
            let pJSON = try CoreBusJSON.encodeJSONValue(.object(pDict))
            let callID: SQLiteValue = if case .tool(let t) = part { .text(t.id) } else { .null }
            _ = try db.execute(
                """
                INSERT INTO `session_part` (`message_id`, `session_id`, `ordinal`, `type`, `call_id`, `time_created`, `time_updated`, `data`)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                parameters: [
                    .text(message.id.rawValue),
                    .text(sessionID.rawValue),
                    .integer(Int64(ordinal)),
                    .text(part.typeTag),
                    callID,
                    .integer(timeCreated),
                    .integer(eventCreated),
                    .text(pJSON),
                ]
            )
        }
        try CoreSessionBlob.recordRefs(
            db,
            owner: CoreSessionBlob.Owner(sessionID: sessionID, messageID: message.id, seq: seq),
            data: ext.data
        )
    }

    private struct SQLiteAdapter: CoreSessionMessageUpdater.Adapter {
        let db: any SQLiteDatabase
        let sessionID: SessionID
        let seq: Int64
        let created: Int64
        let eventType: SessionEventSchema.EventType
        let options: Options

        func getAgent() throws -> String? {
            try db.queryOne(
                "SELECT `agent` FROM `session_v2` WHERE `id` = ?",
                parameters: [.text(sessionID.rawValue)]
            )?.string("agent")
        }

        func getModel() throws -> SessionSchema.ModelRef? {
            guard let raw = try db.queryOne(
                "SELECT `model` FROM `session_v2` WHERE `id` = ?",
                parameters: [.text(sessionID.rawValue)]
            )?.string("model") else { return nil }
            return try? CoreBusJSON.decodeFromString(raw, as: SessionSchema.ModelRef.self)
        }

        func getLocation() throws -> SessionMessageSchema.LocationSwitched.Previous? {
            guard let row = try db.queryOne(
                "SELECT `directory`, `workspace_id`, `project_id`, `path` FROM `session_v2` WHERE `id` = ?",
                parameters: [.text(sessionID.rawValue)]
            ), let dir = row.string("directory") else { return nil }
            return SessionMessageSchema.LocationSwitched.Previous(
                location: OpenCodeLocation(
                    directory: dir,
                    workspaceID: row.string("workspace_id").flatMap(WorkspaceID.init(rawValue:))
                ),
                projectID: row.string("project_id").map(ProjectID.init(rawValue:)),
                subpath: row.string("path")
            )
        }

        func getCurrentAssistant() throws -> SessionMessageSchema.Assistant? {
            guard let raw = try db.queryOne(
                "SELECT * FROM `session_message` WHERE `session_id` = ? AND `type` = 'assistant' ORDER BY `seq` DESC LIMIT 1",
                parameters: [.text(sessionID.rawValue)]
            ) else { return nil }
            let parsed = try CoreSessionHistory.parseMessageRow(raw)
            let assembled = try CoreSessionHistory.withParts(db, rows: [parsed]).first ?? parsed
            let decoded = try CoreSessionHistory.decodeMessageRowSync(assembled)
            if case .assistant(let a) = decoded, a.time.completed == nil {
                return a
            }
            return nil
        }

        func getAssistant(_ messageID: SessionMessageSchema.ID) throws -> SessionMessageSchema.Assistant? {
            guard let raw = try db.queryOne(
                "SELECT * FROM `session_message` WHERE `id` = ? AND `session_id` = ? AND `type` = 'assistant'",
                parameters: [.text(messageID.rawValue), .text(sessionID.rawValue)]
            ) else { return nil }
            let parsed = try CoreSessionHistory.parseMessageRow(raw)
            let assembled = try CoreSessionHistory.withParts(db, rows: [parsed]).first ?? parsed
            let decoded = try CoreSessionHistory.decodeMessageRowSync(assembled)
            if case .assistant(let a) = decoded { return a }
            return nil
        }

        func getShell(_ shellID: String) throws -> SessionMessageSchema.Shell? {
            guard let raw = try db.queryOne(
                """
                SELECT * FROM `session_message`
                WHERE `session_id` = ? AND `type` = 'shell' AND json_extract(`data`, '$.shellID') = ?
                ORDER BY `seq` DESC LIMIT 1
                """,
                parameters: [.text(sessionID.rawValue), .text(shellID)]
            ) else { return nil }
            let parsed = try CoreSessionHistory.parseMessageRow(raw)
            if case .shell(let s) = try CoreSessionHistory.decodeMessageRowSync(parsed) { return s }
            return nil
        }

        func getCompaction() throws -> SessionMessageSchema.Compaction? {
            guard let raw = try db.queryOne(
                """
                SELECT * FROM `session_message`
                WHERE `session_id` = ? AND `type` = 'compaction' AND json_extract(`data`, '$.status') = 'running'
                ORDER BY `seq` DESC LIMIT 1
                """,
                parameters: [.text(sessionID.rawValue)]
            ) else { return nil }
            let parsed = try CoreSessionHistory.parseMessageRow(raw)
            if case .compaction(let c) = try CoreSessionHistory.decodeMessageRowSync(parsed) { return c }
            return nil
        }

        private func updateMessage(_ message: SessionMessageSchema.Info) throws {
            guard case .object(var dict) = try CoreBusJSON.encodeToJSONValue(message) else { return }
            dict.removeValue(forKey: "id")
            dict.removeValue(forKey: "type")
            let timeCreated: Int64 = if case .object(let t) = dict["time"], case .int(let c) = t["created"] {
                c
            } else {
                created
            }
            let ext = try CoreSessionBlob.externalize(db, messageData: dict, mediaBlobEnabled: options.mediaBlobEnabled)
            let existingParts = (message.messageType == .assistant)
                ? try db.query(
                    "SELECT `ordinal`, `data` FROM `session_part` WHERE `message_id` = ? ORDER BY `ordinal` ASC",
                    parameters: [.text(message.id.rawValue)]
                )
                : []
            var envelopeData = ext.data
            if !existingParts.isEmpty && envelopeData["content"] != nil {
                envelopeData["content"] = .array([])
            }
            let jsonStr = try CoreBusJSON.encodeJSONValue(.object(envelopeData))
            guard let updatedRow = try db.queryOne(
                """
                UPDATE `session_message`
                SET `type` = ?, `time_created` = ?, `time_updated` = ?, `data` = ?
                WHERE `id` = ? AND `session_id` = ?
                RETURNING `seq`
                """,
                parameters: [
                    .text(message.messageType.rawValue),
                    .integer(timeCreated),
                    .integer(created),
                    .text(jsonStr),
                    .text(message.id.rawValue),
                    .text(sessionID.rawValue),
                ]
            ), let msgSeq = updatedRow.int64("seq") else { return }

            if !existingParts.isEmpty, case .assistant(let a) = message {
                try rewriteParts(messageID: message.id, existing: existingParts, content: a.content)
            }
            let owner = CoreSessionBlob.Owner(sessionID: sessionID, messageID: message.id, seq: msgSeq)
            if eventType == .messageContentUpdated {
                try CoreSessionBlob.syncRefs(db, owner: owner, data: ext.data)
            } else if ext.moved {
                try CoreSessionBlob.recordRefs(db, owner: owner, data: ext.data)
            }
        }

        private func rewriteParts(
            messageID: SessionMessageSchema.ID,
            existing: [SQLiteRow],
            content: [SessionMessageSchema.AssistantContent]
        ) throws {
            var nextOrd = (existing.last?.int64("ordinal") ?? -1) + 1
            for (index, part) in content.enumerated() {
                let pDict = try CoreSessionHistory.encodePart(part)
                let pJSON = try CoreBusJSON.encodeJSONValue(.object(pDict))
                let callID: SQLiteValue = if case .tool(let t) = part { .text(t.id) } else { .null }
                if index >= existing.count {
                    _ = try db.execute(
                        """
                        INSERT INTO `session_part` (`message_id`, `session_id`, `ordinal`, `type`, `call_id`, `time_created`, `time_updated`, `data`)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        parameters: [
                            .text(messageID.rawValue),
                            .text(sessionID.rawValue),
                            .integer(nextOrd),
                            .text(part.typeTag),
                            callID,
                            .integer(created),
                            .integer(created),
                            .text(pJSON),
                        ]
                    )
                    nextOrd += 1
                } else if existing[index].string("data") != pJSON, let ord = existing[index].int64("ordinal") {
                    _ = try db.execute(
                        """
                        UPDATE `session_part` SET `type` = ?, `call_id` = ?, `time_updated` = ?, `data` = ?
                        WHERE `message_id` = ? AND `ordinal` = ?
                        """,
                        parameters: [
                            .text(part.typeTag),
                            callID,
                            .integer(created),
                            .text(pJSON),
                            .text(messageID.rawValue),
                            .integer(ord),
                        ]
                    )
                }
            }
            if existing.count > content.count {
                let stale = existing[content.count...].compactMap { $0.int64("ordinal") }
                for ord in stale {
                    _ = try db.execute(
                        "DELETE FROM `session_part` WHERE `message_id` = ? AND `ordinal` = ?",
                        parameters: [.text(messageID.rawValue), .integer(ord)]
                    )
                }
            }
        }

        func updateAssistant(_ assistant: SessionMessageSchema.Assistant) throws {
            try updateMessage(.assistant(assistant))
        }

        func updateShell(_ shell: SessionMessageSchema.Shell) throws {
            try updateMessage(.shell(shell))
        }

        func updateCompaction(_ compaction: SessionMessageSchema.Compaction) throws {
            try updateMessage(.compaction(compaction))
        }

        func appendAssistantPart(_ messageID: SessionMessageSchema.ID, part: SessionMessageSchema.AssistantContent) throws {
            if options.partRowsEnabled {
                let nextOrd = (try db.queryScalar(
                    "SELECT coalesce(max(`ordinal`) + 1, 0) FROM `session_part` WHERE `message_id` = ?",
                    parameters: [.text(messageID.rawValue)]
                )?.int64Value) ?? 0
                let ext = try CoreSessionBlob.externalizePart(db, part: part, mediaBlobEnabled: options.mediaBlobEnabled)
                let pDict = try CoreSessionHistory.encodePart(ext.part)
                let pJSON = try CoreBusJSON.encodeJSONValue(.object(pDict))
                let callID: SQLiteValue = if case .tool(let t) = ext.part { .text(t.id) } else { .null }
                _ = try db.execute(
                    """
                    INSERT INTO `session_part` (`message_id`, `session_id`, `ordinal`, `type`, `call_id`, `time_created`, `time_updated`, `data`)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    parameters: [
                        .text(messageID.rawValue),
                        .text(sessionID.rawValue),
                        .integer(nextOrd),
                        .text(ext.part.typeTag),
                        callID,
                        .integer(created),
                        .integer(created),
                        .text(pJSON),
                    ]
                )
                return
            }
            guard let a = try getAssistant(messageID) else { return }
            try updateAssistant(SessionMessageSchema.Assistant(
                id: a.id, metadata: a.metadata, agent: a.agent, model: a.model,
                content: a.content + [part],
                snapshot: a.snapshot, finish: a.finish, rawFinish: a.rawFinish, native: a.native,
                cost: a.cost, tokens: a.tokens, error: a.error, retry: a.retry, time: a.time
            ))
        }

        func updateAssistantPart(
            _ messageID: SessionMessageSchema.ID,
            match: CoreSessionMessageUpdater.PartMatch,
            transform: (SessionMessageSchema.AssistantContent) -> SessionMessageSchema.AssistantContent
        ) throws {
            guard let a = try getAssistant(messageID) else { return }
            guard let idx = a.content.lastIndex(where: { item in
                guard item.typeTag == match.type else { return false }
                if let callID = match.callID {
                    guard case .tool(let t) = item, t.id == callID else { return false }
                }
                if match.incompleteReasoning {
                    guard case .reasoning(let r) = item, r.time?.completed == nil else { return false }
                }
                return true
            }) else { return }
            var next = a.content
            next[idx] = transform(next[idx])
            try updateAssistant(SessionMessageSchema.Assistant(
                id: a.id, metadata: a.metadata, agent: a.agent, model: a.model, content: next,
                snapshot: a.snapshot, finish: a.finish, rawFinish: a.rawFinish, native: a.native,
                cost: a.cost, tokens: a.tokens, error: a.error, retry: a.retry, time: a.time
            ))
        }

        func replaceAssistantParts(
            _ messageID: SessionMessageSchema.ID,
            parts: [SessionMessageSchema.AssistantContent]
        ) throws {
            guard let a = try getAssistant(messageID) else { return }
            try updateAssistant(SessionMessageSchema.Assistant(
                id: a.id, metadata: a.metadata, agent: a.agent, model: a.model, content: parts,
                snapshot: a.snapshot, finish: a.finish, rawFinish: a.rawFinish, native: a.native,
                cost: a.cost, tokens: a.tokens, error: a.error, retry: a.retry, time: a.time
            ))
        }

        func appendMessage(_ message: SessionMessageSchema.Info) throws {
            try CoreSessionProjector.insertMessage(
                db: db,
                sessionID: sessionID,
                seq: seq,
                eventCreated: created,
                message: message,
                mediaBlobEnabled: options.mediaBlobEnabled
            )
        }
    }

    private static func projectMessageEvent(
        db: any SQLiteDatabase,
        event: SessionEventSchema.DurableEvent,
        seq: Int64,
        created: Int64,
        metadata: [String: JSONValue]?,
        options: Options
    ) throws {
        guard let sessionID = SessionID(rawValue: event.durable.aggregateID) else { return }
        let adapter = SQLiteAdapter(
            db: db,
            sessionID: sessionID,
            seq: seq,
            created: created,
            eventType: event.eventType,
            options: options
        )
        try CoreSessionMessageUpdater.update(adapter: adapter, event: event, created: created, metadata: metadata)
    }

    // parity: core/src/session/projector.ts#node [status=adapted hash=29bb5a42a2a5]
    public static let node: LayerNode.Provider = AppNode.makeGlobalNode(
        "session-projector",
        LayerNode.ExecutableLayer { deps, _ in
            guard let bus = deps.get(CoreBus.Service.serviceKey, as: CoreBus.Service.self),
                  let db = deps.get(CoreDatabaseStore.Service.serviceKey, as: CoreDatabaseStore.Service.self)?.db
            else {
                return LayerNode.Output()
            }
            register(bus: bus, db: db)
            return LayerNode.Output()
        },
        [CoreBus.node, CoreDatabaseStore.node]
    )
}
