#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Synchronization
import OpenCodeUtil

/// Namespace housing the complete cross-platform Swift 6 port of `packages/process-daemon`:
/// persistent PTY/pipe daemon, protocol v9 framing, ownership/handoff state machine,
/// VT100/xterm/Ghostty-compatible screen & scrollback engine, IPC transports, and client.
public enum ProcessDaemon {
    // MARK: - Daemon Errors

    public struct DaemonError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public let message: String

        public init(_ message: String) {
            self.message = message
        }

        public var description: String { message }
    }

    // MARK: - Opaque JSON Value for Pipe Metadata

    /// Sendable, Codable JSON value used for opaque `PipeMetadata` dictionaries.
    public enum JSONValue: Equatable, Hashable, Sendable, Codable {
        case null
        case bool(Bool)
        case integer(Int64)
        case number(Double)
        case string(String)
        case array([JSONValue])
        case object([String: JSONValue])

        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
            } else if let b = try? container.decode(Bool.self) {
                self = .bool(b)
            } else if let i = try? container.decode(Int64.self) {
                self = .integer(i)
            } else if let d = try? container.decode(Double.self) {
                self = .number(d)
            } else if let s = try? container.decode(String.self) {
                self = .string(s)
            } else if let arr = try? container.decode([JSONValue].self) {
                self = .array(arr)
            } else if let obj = try? container.decode([String: JSONValue].self) {
                self = .object(obj)
            } else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .null: try container.encodeNil()
            case .bool(let v): try container.encode(v)
            case .integer(let v): try container.encode(v)
            case .number(let v): try container.encode(v)
            case .string(let v): try container.encode(v)
            case .array(let v): try container.encode(v)
            case .object(let v): try container.encode(v)
            }
        }
    }

    // MARK: - Byte Stream Reader / Writer Abstractions

    /// Synchronous byte-stream reader used by protocol v9 frame decoding.
    public protocol ByteReader: Sendable {
        func readExact(_ count: Int) throws -> [UInt8]
    }

    /// Synchronous byte-stream writer used by protocol v9 frame encoding.
    public protocol ByteWriter: Sendable {
        func writeAll(_ bytes: [UInt8]) throws
        func flush() throws
    }

    /// In-memory byte buffer implementing both `ByteReader` and `ByteWriter` for deterministic framing tests.
    public final class ByteBufferStream: ByteReader, ByteWriter, Sendable {
        private struct State: Sendable {
            var bytes: [UInt8]
            var readOffset: Int = 0
        }

        private let state: Mutex<State>

        public init(_ bytes: [UInt8] = []) {
            self.state = Mutex(State(bytes: bytes))
        }

        public var bytes: [UInt8] {
            state.withLock { $0.bytes }
        }

        public var unreadBytes: [UInt8] {
            state.withLock { Array($0.bytes[$0.readOffset...]) }
        }

        public func writeAll(_ bytes: [UInt8]) throws {
            state.withLock { $0.bytes.append(contentsOf: bytes) }
        }

        public func flush() throws {}

        public func readExact(_ count: Int) throws -> [UInt8] {
            if count == 0 { return [] }
            return try state.withLock { s in
                guard s.readOffset + count <= s.bytes.count else {
                    throw DaemonError("unexpected EOF while reading \(count) byte(s)")
                }
                let slice = Array(s.bytes[s.readOffset..<(s.readOffset + count)])
                s.readOffset += count
                return slice
            }
        }
    }

    // MARK: - Shared Service Data Types (`src/service.rs`)

    // parity: process-daemon/src/service.rs#TerminalId [status=implemented hash=9ef8fcd2b06a]
    public typealias TerminalId = UInt64

    // parity: process-daemon/src/service.rs#ProcessMode [status=implemented hash=89d6cdabdda8]
    public enum ProcessMode: String, Equatable, Hashable, Sendable, Codable {
        case pty
        case pipe

        // parity: process-daemon/src/service.rs#is_pty [status=implemented hash=7a184312aad1]
        public func is_pty() -> Bool {
            self == .pty
        }
    }

    // parity: process-daemon/src/service.rs#PipeMetadata [status=implemented hash=05f65f029881]
    public typealias PipeMetadata = [String: JSONValue]

    // parity: process-daemon/src/service.rs#MAX_METADATA_BYTES [status=implemented hash=e4c53936c377]
    public static let MAX_METADATA_BYTES: Int = 1024 * 1024

    // parity: process-daemon/src/service.rs#ProcessSignal [status=implemented hash=f8835215cc54]
    public enum ProcessSignal: String, Equatable, Hashable, Sendable, Codable {
        case term = "SIGTERM"
        case int = "SIGINT"
        case kill = "SIGKILL"
    }

    // parity: process-daemon/src/service.rs#TerminalLifecycle [status=implemented hash=3bd874e21671]
    public enum TerminalLifecycle: Equatable, Hashable, Sendable, Codable {
        case running
        case exited(exitCode: UInt32?, signal: String? = nil)
        case failed(message: String)

        private enum CodingKeys: String, CodingKey {
            case status
            case exitCode = "exit_code"
            case signal
            case message
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let status = try container.decode(String.self, forKey: .status)
            switch status {
            case "running":
                self = .running
            case "exited":
                let exitCode = try container.decodeIfPresent(UInt32.self, forKey: .exitCode)
                let signal = try container.decodeIfPresent(String.self, forKey: .signal)
                self = .exited(exitCode: exitCode, signal: signal)
            case "failed":
                let message = try container.decode(String.self, forKey: .message)
                self = .failed(message: message)
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .status,
                    in: container,
                    debugDescription: "unknown variant `\(status)`"
                )
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .running:
                try container.encode("running", forKey: .status)
            case let .exited(exitCode, signal):
                try container.encode("exited", forKey: .status)
                try container.encode(exitCode, forKey: .exitCode)
                if let signal {
                    try container.encode(signal, forKey: .signal)
                }
            case .failed(let message):
                try container.encode("failed", forKey: .status)
                try container.encode(message, forKey: .message)
            }
        }
    }

    // parity: process-daemon/src/service.rs#PtyInfo [status=implemented hash=cc55773a887e]
    public struct PtyInfo: Equatable, Hashable, Sendable, Codable {
        public var title: String
        public var userTitle: String?
        public var foregroundProcess: String?
        public var cols: UInt16
        public var rows: UInt16

        private enum CodingKeys: String, CodingKey {
            case title
            case userTitle = "user_title"
            case foregroundProcess = "foreground_process"
            case cols
            case rows
        }

        public init(
            title: String,
            userTitle: String? = nil,
            foregroundProcess: String? = nil,
            cols: UInt16,
            rows: UInt16
        ) {
            self.title = title
            self.userTitle = userTitle
            self.foregroundProcess = foregroundProcess
            self.cols = cols
            self.rows = rows
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(title, forKey: .title)
            try container.encode(userTitle, forKey: .userTitle)
            try container.encode(foregroundProcess, forKey: .foregroundProcess)
            try container.encode(cols, forKey: .cols)
            try container.encode(rows, forKey: .rows)
        }
    }

    // parity: process-daemon/src/service.rs#PipeInfo [status=implemented hash=0712350a7e1a]
    public struct PipeInfo: Equatable, Hashable, Sendable, Codable {
        public var outputPath: String
        public var outputLines: UInt64
        public var outputError: String?
        public var metadata: PipeMetadata

        private enum CodingKeys: String, CodingKey {
            case outputPath = "output_path"
            case outputLines = "output_lines"
            case outputError = "output_error"
            case metadata
        }

        public init(
            outputPath: String,
            outputLines: UInt64 = 0,
            outputError: String? = nil,
            metadata: PipeMetadata = [:]
        ) {
            self.outputPath = outputPath
            self.outputLines = outputLines
            self.outputError = outputError
            self.metadata = metadata
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(outputPath, forKey: .outputPath)
            try container.encode(outputLines, forKey: .outputLines)
            if let outputError {
                try container.encode(outputError, forKey: .outputError)
            }
            try container.encode(metadata, forKey: .metadata)
        }
    }

    // parity: process-daemon/src/service.rs#ProcessInfo [status=implemented hash=906f086ae186]
    public struct ProcessInfo: Equatable, Hashable, Sendable, Codable {
        public var id: TerminalId
        public var mode: ProcessMode
        public var pid: UInt32?
        public var command: [String]
        public var cwd: String
        public var groupId: String
        public var lifecycle: TerminalLifecycle
        public var outputHead: UInt64
        public var outputTail: UInt64
        public var startedAt: UInt64
        public var exitedAt: UInt64?
        public var pty: PtyInfo?
        public var pipe: PipeInfo?

        private enum CodingKeys: String, CodingKey {
            case id
            case mode
            case pid
            case command
            case cwd
            case groupId = "group_id"
            case lifecycle
            case outputHead = "output_head"
            case outputTail = "output_tail"
            case startedAt = "started_at"
            case exitedAt = "exited_at"
            case pty
            case pipe
        }

        public init(
            id: TerminalId,
            mode: ProcessMode,
            pid: UInt32?,
            command: [String],
            cwd: String,
            groupId: String,
            lifecycle: TerminalLifecycle = .running,
            outputHead: UInt64 = 0,
            outputTail: UInt64 = 0,
            startedAt: UInt64,
            exitedAt: UInt64? = nil,
            pty: PtyInfo? = nil,
            pipe: PipeInfo? = nil
        ) {
            self.id = id
            self.mode = mode
            self.pid = pid
            self.command = command
            self.cwd = cwd
            self.groupId = groupId
            self.lifecycle = lifecycle
            self.outputHead = outputHead
            self.outputTail = outputTail
            self.startedAt = startedAt
            self.exitedAt = exitedAt
            self.pty = pty
            self.pipe = pipe
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(mode, forKey: .mode)
            try container.encode(pid, forKey: .pid)
            try container.encode(command, forKey: .command)
            try container.encode(cwd, forKey: .cwd)
            try container.encode(groupId, forKey: .groupId)
            try container.encode(lifecycle, forKey: .lifecycle)
            try container.encode(outputHead, forKey: .outputHead)
            try container.encode(outputTail, forKey: .outputTail)
            try container.encode(startedAt, forKey: .startedAt)
            try container.encode(exitedAt, forKey: .exitedAt)
            if let pty {
                try container.encode(pty, forKey: .pty)
            }
            if let pipe {
                try container.encode(pipe, forKey: .pipe)
            }
        }
    }

    // parity: process-daemon/src/service.rs#ProcessExit [status=implemented hash=414a0c90ccc0]
    public struct ProcessExit: Equatable, Hashable, Sendable, Codable {
        public let exitCode: UInt32?
        public let signal: String?
        public let finalOffset: UInt64
        public let outputLines: UInt64?
        public let outputError: String?
        public let exitedAt: UInt64

        public init(
            exitCode: UInt32?,
            signal: String? = nil,
            finalOffset: UInt64,
            outputLines: UInt64? = nil,
            outputError: String? = nil,
            exitedAt: UInt64
        ) {
            self.exitCode = exitCode
            self.signal = signal
            self.finalOffset = finalOffset
            self.outputLines = outputLines
            self.outputError = outputError
            self.exitedAt = exitedAt
        }
    }

    // MARK: - Protocol v9 Framing (`src/protocol.rs`)

    // parity: process-daemon/src/protocol.rs#PROTOCOL_VERSION [status=implemented hash=b8875e58b5b7]
    public static let PROTOCOL_VERSION: UInt32 = 9

    // parity: process-daemon/src/protocol.rs#FEATURES [status=implemented hash=12a070b12d11]
    public static let FEATURES: [String] = []

    // parity: process-daemon/src/protocol.rs#features [status=implemented hash=90063654d50f]
    public static func features() -> [String] {
        FEATURES
    }

    // parity: process-daemon/src/protocol.rs#MAX_FRAME_BYTES [status=implemented hash=99c31f2866a0]
    public static let MAX_FRAME_BYTES: Int = 8 * 1024 * 1024

    private static let outputFrameTag: UInt8 = 0

    // parity: process-daemon/src/protocol.rs#AttachmentRole [status=implemented hash=05fda28a8fb1]
    public enum AttachmentRole: String, Equatable, Hashable, Sendable, Codable {
        case controller
        case observer
    }

    // parity: process-daemon/src/protocol.rs#Envelope [status=implemented hash=9694ce05671b]
    public struct Envelope: Equatable, Sendable, Codable {
        public let token: String
        public let request: Request

        public init(token: String, request: Request) {
            self.token = token
            self.request = request
        }
    }

    // parity: process-daemon/src/protocol.rs#Request [status=implemented hash=26ae8d687061]
    public enum Request: Equatable, Sendable, Codable {
        case ping
        case own(instanceId: String, ticket: String?)
        case prepareHandoff
        case createPty(
            program: String,
            args: [String],
            cwd: String,
            env: [String: String],
            groupId: String,
            title: String,
            cols: UInt16,
            rows: UInt16
        )
        case createPipe(
            program: String,
            args: [String],
            cwd: String,
            env: [String: String],
            groupId: String,
            outputPath: String,
            metadata: PipeMetadata
        )
        case list(mode: ProcessMode)
        case get(id: TerminalId)
        case wait(id: TerminalId)
        case signal(id: TerminalId, signal: ProcessSignal)
        case setMetadata(id: TerminalId, metadata: PipeMetadata)
        case write(id: TerminalId, attachmentId: String?, dataBase64: String)
        case resize(id: TerminalId, attachmentId: String?, cols: UInt16, rows: UInt16)
        case control(id: TerminalId, attachmentId: String, cols: UInt16, rows: UInt16)
        case input(id: TerminalId, attachmentId: String, cols: UInt16, rows: UInt16, dataBase64: String)
        case snapshot(id: TerminalId)
        case readRows(id: TerminalId, rows: UInt16?)
        case rename(id: TerminalId, title: String?)
        case replay(id: TerminalId, offset: UInt64)
        case subscribe(id: TerminalId, offset: UInt64, attachmentId: String, role: AttachmentRole, takeover: Bool)
        case terminate(id: TerminalId)
        case shutdown

        public static let knownOps: Set<String> = [
            "ping", "own", "prepare_handoff", "create_pty", "create_pipe",
            "list", "get", "wait", "signal", "set_metadata",
            "write", "resize", "control", "input", "snapshot",
            "read_rows", "rename", "replay", "subscribe", "terminate", "shutdown",
        ]

        private enum CodingKeys: String, CodingKey {
            case op
            case instanceId = "instance_id"
            case ticket
            case program
            case args
            case cwd
            case env
            case groupId = "group_id"
            case title
            case cols
            case rows
            case outputPath = "output_path"
            case metadata
            case mode
            case id
            case signal
            case attachmentId = "attachment_id"
            case dataBase64 = "data_base64"
            case offset
            case role
            case takeover
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let op = try container.decode(String.self, forKey: .op)
            switch op {
            case "ping":
                self = .ping
            case "own":
                self = .own(
                    instanceId: try container.decode(String.self, forKey: .instanceId),
                    ticket: try container.decodeIfPresent(String.self, forKey: .ticket)
                )
            case "prepare_handoff":
                self = .prepareHandoff
            case "create_pty":
                self = .createPty(
                    program: try container.decode(String.self, forKey: .program),
                    args: try container.decode([String].self, forKey: .args),
                    cwd: try container.decode(String.self, forKey: .cwd),
                    env: try container.decode([String: String].self, forKey: .env),
                    groupId: try container.decode(String.self, forKey: .groupId),
                    title: try container.decode(String.self, forKey: .title),
                    cols: try container.decode(UInt16.self, forKey: .cols),
                    rows: try container.decode(UInt16.self, forKey: .rows)
                )
            case "create_pipe":
                self = .createPipe(
                    program: try container.decode(String.self, forKey: .program),
                    args: try container.decode([String].self, forKey: .args),
                    cwd: try container.decode(String.self, forKey: .cwd),
                    env: try container.decode([String: String].self, forKey: .env),
                    groupId: try container.decode(String.self, forKey: .groupId),
                    outputPath: try container.decode(String.self, forKey: .outputPath),
                    metadata: try container.decode(PipeMetadata.self, forKey: .metadata)
                )
            case "list":
                self = .list(mode: try container.decode(ProcessMode.self, forKey: .mode))
            case "get":
                self = .get(id: try container.decode(TerminalId.self, forKey: .id))
            case "wait":
                self = .wait(id: try container.decode(TerminalId.self, forKey: .id))
            case "signal":
                let rawSig = try container.decode(String.self, forKey: .signal)
                guard let sig = ProcessSignal(rawValue: rawSig) else {
                    throw DaemonError("unknown variant `\(rawSig)`, expected one of `SIGTERM`, `SIGINT`, `SIGKILL`")
                }
                self = .signal(
                    id: try container.decode(TerminalId.self, forKey: .id),
                    signal: sig
                )
            case "set_metadata":
                self = .setMetadata(
                    id: try container.decode(TerminalId.self, forKey: .id),
                    metadata: try container.decode(PipeMetadata.self, forKey: .metadata)
                )
            case "write":
                self = .write(
                    id: try container.decode(TerminalId.self, forKey: .id),
                    attachmentId: try container.decodeIfPresent(String.self, forKey: .attachmentId),
                    dataBase64: try container.decode(String.self, forKey: .dataBase64)
                )
            case "resize":
                self = .resize(
                    id: try container.decode(TerminalId.self, forKey: .id),
                    attachmentId: try container.decodeIfPresent(String.self, forKey: .attachmentId),
                    cols: try container.decode(UInt16.self, forKey: .cols),
                    rows: try container.decode(UInt16.self, forKey: .rows)
                )
            case "control":
                self = .control(
                    id: try container.decode(TerminalId.self, forKey: .id),
                    attachmentId: try container.decode(String.self, forKey: .attachmentId),
                    cols: try container.decode(UInt16.self, forKey: .cols),
                    rows: try container.decode(UInt16.self, forKey: .rows)
                )
            case "input":
                self = .input(
                    id: try container.decode(TerminalId.self, forKey: .id),
                    attachmentId: try container.decode(String.self, forKey: .attachmentId),
                    cols: try container.decode(UInt16.self, forKey: .cols),
                    rows: try container.decode(UInt16.self, forKey: .rows),
                    dataBase64: try container.decode(String.self, forKey: .dataBase64)
                )
            case "snapshot":
                self = .snapshot(id: try container.decode(TerminalId.self, forKey: .id))
            case "read_rows":
                self = .readRows(
                    id: try container.decode(TerminalId.self, forKey: .id),
                    rows: try container.decodeIfPresent(UInt16.self, forKey: .rows)
                )
            case "rename":
                self = .rename(
                    id: try container.decode(TerminalId.self, forKey: .id),
                    title: try container.decodeIfPresent(String.self, forKey: .title)
                )
            case "replay":
                self = .replay(
                    id: try container.decode(TerminalId.self, forKey: .id),
                    offset: try container.decode(UInt64.self, forKey: .offset)
                )
            case "subscribe":
                self = .subscribe(
                    id: try container.decode(TerminalId.self, forKey: .id),
                    offset: try container.decode(UInt64.self, forKey: .offset),
                    attachmentId: try container.decode(String.self, forKey: .attachmentId),
                    role: try container.decode(AttachmentRole.self, forKey: .role),
                    takeover: try container.decode(Bool.self, forKey: .takeover)
                )
            case "terminate":
                self = .terminate(id: try container.decode(TerminalId.self, forKey: .id))
            case "shutdown":
                self = .shutdown
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .op,
                    in: container,
                    debugDescription: "unknown variant `\(op)`"
                )
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .ping:
                try container.encode("ping", forKey: .op)
            case let .own(instanceId, ticket):
                try container.encode("own", forKey: .op)
                try container.encode(instanceId, forKey: .instanceId)
                try container.encode(ticket, forKey: .ticket)
            case .prepareHandoff:
                try container.encode("prepare_handoff", forKey: .op)
            case let .createPty(program, args, cwd, env, groupId, title, cols, rows):
                try container.encode("create_pty", forKey: .op)
                try container.encode(program, forKey: .program)
                try container.encode(args, forKey: .args)
                try container.encode(cwd, forKey: .cwd)
                try container.encode(env, forKey: .env)
                try container.encode(groupId, forKey: .groupId)
                try container.encode(title, forKey: .title)
                try container.encode(cols, forKey: .cols)
                try container.encode(rows, forKey: .rows)
            case let .createPipe(program, args, cwd, env, groupId, outputPath, metadata):
                try container.encode("create_pipe", forKey: .op)
                try container.encode(program, forKey: .program)
                try container.encode(args, forKey: .args)
                try container.encode(cwd, forKey: .cwd)
                try container.encode(env, forKey: .env)
                try container.encode(groupId, forKey: .groupId)
                try container.encode(outputPath, forKey: .outputPath)
                try container.encode(metadata, forKey: .metadata)
            case .list(let mode):
                try container.encode("list", forKey: .op)
                try container.encode(mode, forKey: .mode)
            case .get(let id):
                try container.encode("get", forKey: .op)
                try container.encode(id, forKey: .id)
            case .wait(let id):
                try container.encode("wait", forKey: .op)
                try container.encode(id, forKey: .id)
            case let .signal(id, signal):
                try container.encode("signal", forKey: .op)
                try container.encode(id, forKey: .id)
                try container.encode(signal, forKey: .signal)
            case let .setMetadata(id, metadata):
                try container.encode("set_metadata", forKey: .op)
                try container.encode(id, forKey: .id)
                try container.encode(metadata, forKey: .metadata)
            case let .write(id, attachmentId, dataBase64):
                try container.encode("write", forKey: .op)
                try container.encode(id, forKey: .id)
                try container.encode(attachmentId, forKey: .attachmentId)
                try container.encode(dataBase64, forKey: .dataBase64)
            case let .resize(id, attachmentId, cols, rows):
                try container.encode("resize", forKey: .op)
                try container.encode(id, forKey: .id)
                try container.encode(attachmentId, forKey: .attachmentId)
                try container.encode(cols, forKey: .cols)
                try container.encode(rows, forKey: .rows)
            case let .control(id, attachmentId, cols, rows):
                try container.encode("control", forKey: .op)
                try container.encode(id, forKey: .id)
                try container.encode(attachmentId, forKey: .attachmentId)
                try container.encode(cols, forKey: .cols)
                try container.encode(rows, forKey: .rows)
            case let .input(id, attachmentId, cols, rows, dataBase64):
                try container.encode("input", forKey: .op)
                try container.encode(id, forKey: .id)
                try container.encode(attachmentId, forKey: .attachmentId)
                try container.encode(cols, forKey: .cols)
                try container.encode(rows, forKey: .rows)
                try container.encode(dataBase64, forKey: .dataBase64)
            case .snapshot(let id):
                try container.encode("snapshot", forKey: .op)
                try container.encode(id, forKey: .id)
            case let .readRows(id, rows):
                try container.encode("read_rows", forKey: .op)
                try container.encode(id, forKey: .id)
                try container.encode(rows, forKey: .rows)
            case let .rename(id, title):
                try container.encode("rename", forKey: .op)
                try container.encode(id, forKey: .id)
                try container.encode(title, forKey: .title)
            case let .replay(id, offset):
                try container.encode("replay", forKey: .op)
                try container.encode(id, forKey: .id)
                try container.encode(offset, forKey: .offset)
            case let .subscribe(id, offset, attachmentId, role, takeover):
                try container.encode("subscribe", forKey: .op)
                try container.encode(id, forKey: .id)
                try container.encode(offset, forKey: .offset)
                try container.encode(attachmentId, forKey: .attachmentId)
                try container.encode(role, forKey: .role)
                try container.encode(takeover, forKey: .takeover)
            case .terminate(let id):
                try container.encode("terminate", forKey: .op)
                try container.encode(id, forKey: .id)
            case .shutdown:
                try container.encode("shutdown", forKey: .op)
            }
        }
    }

    // parity: process-daemon/src/protocol.rs#Response [status=implemented hash=add0bc08aaa1]
    public enum Response: Equatable, Sendable, Codable {
        case owned
        case handoff(ticket: String, expiresAt: UInt64)
        case pong(instanceId: String, pid: UInt32, protocolVersion: UInt32, features: [String])
        case created(process: ProcessInfo)
        case process(process: ProcessInfo)
        case processes(processes: [ProcessInfo])
        case ok
        case snapshot(process: ProcessInfo, text: String, checkpointBase64: String, cursorX: UInt16, cursorY: UInt16)
        case rows(process: ProcessInfo, lines: [String], cursorX: UInt16, cursorY: UInt16)
        case replay(
            requestedOffset: UInt64,
            availableOffset: UInt64,
            endOffset: UInt64,
            truncated: Bool,
            dataBase64: String
        )
        case attached(
            process: ProcessInfo,
            role: AttachmentRole,
            generation: UInt64,
            requestedOffset: UInt64,
            availableOffset: UInt64,
            endOffset: UInt64,
            truncated: Bool,
            replayBase64: String
        )
        case resized(cols: UInt16, rows: UInt16, generation: UInt64, checkpointBase64: String)
        case exited(
            exitCode: UInt32?,
            signal: String?,
            finalOffset: UInt64,
            outputLines: UInt64?,
            outputError: String?,
            exitedAt: UInt64
        )
        case controllerChanged(attachmentId: String?, generation: UInt64)
        case titleChanged(title: String)
        case foregroundProcessChanged(process: String?)
        case error(message: String)

        public static func from(_ exit: ProcessExit) -> Response {
            .exited(
                exitCode: exit.exitCode,
                signal: exit.signal,
                finalOffset: exit.finalOffset,
                outputLines: exit.outputLines,
                outputError: exit.outputError,
                exitedAt: exit.exitedAt
            )
        }

        private enum CodingKeys: String, CodingKey {
            case type
            case ticket
            case expiresAt = "expires_at"
            case instanceId = "instance_id"
            case pid
            case protocolVersion = "protocol"
            case features
            case process
            case processes
            case text
            case checkpointBase64 = "checkpoint_base64"
            case cursorX = "cursor_x"
            case cursorY = "cursor_y"
            case lines
            case requestedOffset = "requested_offset"
            case availableOffset = "available_offset"
            case endOffset = "end_offset"
            case truncated
            case dataBase64 = "data_base64"
            case role
            case generation
            case replayBase64 = "replay_base64"
            case cols
            case rows
            case exitCode = "exit_code"
            case signal
            case finalOffset = "final_offset"
            case outputLines = "output_lines"
            case outputError = "output_error"
            case exitedAt = "exited_at"
            case attachmentId = "attachment_id"
            case title
            case message
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "owned":
                self = .owned
            case "handoff":
                self = .handoff(
                    ticket: try container.decode(String.self, forKey: .ticket),
                    expiresAt: try container.decode(UInt64.self, forKey: .expiresAt)
                )
            case "pong":
                self = .pong(
                    instanceId: try container.decode(String.self, forKey: .instanceId),
                    pid: try container.decode(UInt32.self, forKey: .pid),
                    protocolVersion: try container.decode(UInt32.self, forKey: .protocolVersion),
                    features: try container.decode([String].self, forKey: .features)
                )
            case "created":
                self = .created(process: try container.decode(ProcessInfo.self, forKey: .process))
            case "process":
                self = .process(process: try container.decode(ProcessInfo.self, forKey: .process))
            case "processes":
                self = .processes(processes: try container.decode([ProcessInfo].self, forKey: .processes))
            case "ok":
                self = .ok
            case "snapshot":
                self = .snapshot(
                    process: try container.decode(ProcessInfo.self, forKey: .process),
                    text: try container.decode(String.self, forKey: .text),
                    checkpointBase64: try container.decode(String.self, forKey: .checkpointBase64),
                    cursorX: try container.decode(UInt16.self, forKey: .cursorX),
                    cursorY: try container.decode(UInt16.self, forKey: .cursorY)
                )
            case "rows":
                self = .rows(
                    process: try container.decode(ProcessInfo.self, forKey: .process),
                    lines: try container.decode([String].self, forKey: .lines),
                    cursorX: try container.decode(UInt16.self, forKey: .cursorX),
                    cursorY: try container.decode(UInt16.self, forKey: .cursorY)
                )
            case "replay":
                self = .replay(
                    requestedOffset: try container.decode(UInt64.self, forKey: .requestedOffset),
                    availableOffset: try container.decode(UInt64.self, forKey: .availableOffset),
                    endOffset: try container.decode(UInt64.self, forKey: .endOffset),
                    truncated: try container.decode(Bool.self, forKey: .truncated),
                    dataBase64: try container.decode(String.self, forKey: .dataBase64)
                )
            case "attached":
                self = .attached(
                    process: try container.decode(ProcessInfo.self, forKey: .process),
                    role: try container.decode(AttachmentRole.self, forKey: .role),
                    generation: try container.decode(UInt64.self, forKey: .generation),
                    requestedOffset: try container.decode(UInt64.self, forKey: .requestedOffset),
                    availableOffset: try container.decode(UInt64.self, forKey: .availableOffset),
                    endOffset: try container.decode(UInt64.self, forKey: .endOffset),
                    truncated: try container.decode(Bool.self, forKey: .truncated),
                    replayBase64: try container.decode(String.self, forKey: .replayBase64)
                )
            case "resized":
                self = .resized(
                    cols: try container.decode(UInt16.self, forKey: .cols),
                    rows: try container.decode(UInt16.self, forKey: .rows),
                    generation: try container.decode(UInt64.self, forKey: .generation),
                    checkpointBase64: try container.decode(String.self, forKey: .checkpointBase64)
                )
            case "exited":
                self = .exited(
                    exitCode: try container.decodeIfPresent(UInt32.self, forKey: .exitCode),
                    signal: try container.decodeIfPresent(String.self, forKey: .signal),
                    finalOffset: try container.decode(UInt64.self, forKey: .finalOffset),
                    outputLines: try container.decodeIfPresent(UInt64.self, forKey: .outputLines),
                    outputError: try container.decodeIfPresent(String.self, forKey: .outputError),
                    exitedAt: try container.decode(UInt64.self, forKey: .exitedAt)
                )
            case "controller_changed":
                self = .controllerChanged(
                    attachmentId: try container.decodeIfPresent(String.self, forKey: .attachmentId),
                    generation: try container.decode(UInt64.self, forKey: .generation)
                )
            case "title_changed":
                self = .titleChanged(title: try container.decode(String.self, forKey: .title))
            case "foreground_process_changed":
                self = .foregroundProcessChanged(
                    process: try container.decodeIfPresent(String.self, forKey: .process)
                )
            case "error":
                self = .error(message: try container.decode(String.self, forKey: .message))
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .type,
                    in: container,
                    debugDescription: "unknown variant `\(type)`"
                )
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .owned:
                try container.encode("owned", forKey: .type)
            case let .handoff(ticket, expiresAt):
                try container.encode("handoff", forKey: .type)
                try container.encode(ticket, forKey: .ticket)
                try container.encode(expiresAt, forKey: .expiresAt)
            case let .pong(instanceId, pid, protocolVersion, features):
                try container.encode("pong", forKey: .type)
                try container.encode(instanceId, forKey: .instanceId)
                try container.encode(pid, forKey: .pid)
                try container.encode(protocolVersion, forKey: .protocolVersion)
                try container.encode(features, forKey: .features)
            case .created(let process):
                try container.encode("created", forKey: .type)
                try container.encode(process, forKey: .process)
            case .process(let process):
                try container.encode("process", forKey: .type)
                try container.encode(process, forKey: .process)
            case .processes(let processes):
                try container.encode("processes", forKey: .type)
                try container.encode(processes, forKey: .processes)
            case .ok:
                try container.encode("ok", forKey: .type)
            case let .snapshot(process, text, checkpointBase64, cursorX, cursorY):
                try container.encode("snapshot", forKey: .type)
                try container.encode(process, forKey: .process)
                try container.encode(text, forKey: .text)
                try container.encode(checkpointBase64, forKey: .checkpointBase64)
                try container.encode(cursorX, forKey: .cursorX)
                try container.encode(cursorY, forKey: .cursorY)
            case let .rows(process, lines, cursorX, cursorY):
                try container.encode("rows", forKey: .type)
                try container.encode(process, forKey: .process)
                try container.encode(lines, forKey: .lines)
                try container.encode(cursorX, forKey: .cursorX)
                try container.encode(cursorY, forKey: .cursorY)
            case let .replay(requestedOffset, availableOffset, endOffset, truncated, dataBase64):
                try container.encode("replay", forKey: .type)
                try container.encode(requestedOffset, forKey: .requestedOffset)
                try container.encode(availableOffset, forKey: .availableOffset)
                try container.encode(endOffset, forKey: .endOffset)
                try container.encode(truncated, forKey: .truncated)
                try container.encode(dataBase64, forKey: .dataBase64)
            case let .attached(process, role, generation, requestedOffset, availableOffset, endOffset, truncated, replayBase64):
                try container.encode("attached", forKey: .type)
                try container.encode(process, forKey: .process)
                try container.encode(role, forKey: .role)
                try container.encode(generation, forKey: .generation)
                try container.encode(requestedOffset, forKey: .requestedOffset)
                try container.encode(availableOffset, forKey: .availableOffset)
                try container.encode(endOffset, forKey: .endOffset)
                try container.encode(truncated, forKey: .truncated)
                try container.encode(replayBase64, forKey: .replayBase64)
            case let .resized(cols, rows, generation, checkpointBase64):
                try container.encode("resized", forKey: .type)
                try container.encode(cols, forKey: .cols)
                try container.encode(rows, forKey: .rows)
                try container.encode(generation, forKey: .generation)
                try container.encode(checkpointBase64, forKey: .checkpointBase64)
            case let .exited(exitCode, signal, finalOffset, outputLines, outputError, exitedAt):
                try container.encode("exited", forKey: .type)
                try container.encode(exitCode, forKey: .exitCode)
                if let signal {
                    try container.encode(signal, forKey: .signal)
                }
                try container.encode(finalOffset, forKey: .finalOffset)
                if let outputLines {
                    try container.encode(outputLines, forKey: .outputLines)
                }
                if let outputError {
                    try container.encode(outputError, forKey: .outputError)
                }
                try container.encode(exitedAt, forKey: .exitedAt)
            case let .controllerChanged(attachmentId, generation):
                try container.encode("controller_changed", forKey: .type)
                try container.encode(attachmentId, forKey: .attachmentId)
                try container.encode(generation, forKey: .generation)
            case .titleChanged(let title):
                try container.encode("title_changed", forKey: .type)
                try container.encode(title, forKey: .title)
            case .foregroundProcessChanged(let process):
                try container.encode("foreground_process_changed", forKey: .type)
                try container.encode(process, forKey: .process)
            case .error(let message):
                try container.encode("error", forKey: .type)
                try container.encode(message, forKey: .message)
            }
        }
    }

    // parity: process-daemon/src/protocol.rs#SubscriptionEvent [status=implemented hash=79d64bcdc657]
    public enum SubscriptionEvent: Equatable, Sendable {
        case output(start: UInt64, end: UInt64, bytes: [UInt8])
        case response(Response)
    }

    private struct RawEnvelope: Decodable {
        let token: String
        let request: JSONValue
    }

    /// Reads a framed request envelope. Unknown `op` values or malformed fields return
    /// `.failure(message)` inside the tuple rather than failing the connection, so clients can probe ops.
    // parity: process-daemon/src/protocol.rs#read_envelope [status=implemented hash=46270da63f4c]
    public static func read_envelope(
        _ reader: any ByteReader
    ) throws -> (token: String, request: Result<Request, DaemonError>) {
        let raw: RawEnvelope = try read_frame(reader)
        guard case .object(let map) = raw.request,
              case .string(let op)? = map["op"] else {
            return (raw.token, .failure(DaemonError("invalid request: missing field `op`")))
        }
        guard Request.knownOps.contains(op) else {
            return (raw.token, .failure(DaemonError("unsupported request: \(op)")))
        }
        do {
            let encoded = try JSONEncoder().encode(raw.request)
            let parsed = try JSONDecoder().decode(Request.self, from: encoded)
            return (raw.token, .success(parsed))
        } catch let err as DaemonError {
            return (raw.token, .failure(DaemonError("invalid \(op) request: \(err.message)")))
        } catch {
            return (raw.token, .failure(DaemonError("invalid \(op) request: \(error)")))
        }
    }

    // parity: process-daemon/src/protocol.rs#write_frame [status=implemented hash=306c41db41cf]
    public static func write_frame<T: Encodable>(_ writer: any ByteWriter, value: T) throws {
        let data = try JSONEncoder().encode(value)
        let payload = Array(data)
        if payload.count > MAX_FRAME_BYTES {
            throw DaemonError("frame exceeds \(MAX_FRAME_BYTES) byte limit")
        }
        guard let length = UInt32(exactly: payload.count) else {
            throw DaemonError("frame length exceeds u32")
        }
        try writer.writeAll(encodeBigEndian32(length))
        try writer.writeAll(payload)
        try writer.flush()
    }

    // parity: process-daemon/src/protocol.rs#write_output_frame [status=implemented hash=1eec5f515836]
    public static func write_output_frame(
        _ writer: any ByteWriter,
        start: UInt64,
        end: UInt64,
        bytes: [UInt8]
    ) throws {
        let (payloadLen, overflow) = bytes.count.addingReportingOverflow(17)
        if overflow {
            throw DaemonError("output frame length overflow")
        }
        if payloadLen > MAX_FRAME_BYTES {
            throw DaemonError("frame exceeds \(MAX_FRAME_BYTES) byte limit")
        }
        guard let length = UInt32(exactly: payloadLen) else {
            throw DaemonError("frame length exceeds u32")
        }
        var frame: [UInt8] = []
        frame.reserveCapacity(4 + payloadLen)
        frame.append(contentsOf: encodeBigEndian32(length))
        frame.append(outputFrameTag)
        frame.append(contentsOf: encodeBigEndian64(start))
        frame.append(contentsOf: encodeBigEndian64(end))
        frame.append(contentsOf: bytes)
        try writer.writeAll(frame)
        try writer.flush()
    }

    // parity: process-daemon/src/protocol.rs#read_subscription_event [status=implemented hash=924c332eecd7]
    public static func read_subscription_event(_ reader: any ByteReader) throws -> SubscriptionEvent {
        let payload = try readPayload(reader)
        if payload.first != outputFrameTag {
            do {
                let response = try JSONDecoder().decode(Response.self, from: Data(payload))
                return .response(response)
            } catch {
                throw DaemonError("invalid protocol JSON: \(error)")
            }
        }
        if payload.count < 17 {
            throw DaemonError("invalid output frame")
        }
        let start = decodeBigEndian64(payload, offset: 1)
        let end = decodeBigEndian64(payload, offset: 9)
        let bytes = Array(payload[17...])
        return .output(start: start, end: end, bytes: bytes)
    }

    // parity: process-daemon/src/protocol.rs#read_frame [status=implemented hash=41bcb822e21d]
    public static func read_frame<T: Decodable>(_ reader: any ByteReader) throws -> T {
        let payload = try readPayload(reader)
        do {
            return try JSONDecoder().decode(T.self, from: Data(payload))
        } catch {
            throw DaemonError("invalid protocol JSON: \(error)")
        }
    }

    private static func readPayload(_ reader: any ByteReader) throws -> [UInt8] {
        let header = try reader.readExact(4)
        let length = Int(decodeBigEndian32(header, offset: 0))
        if length > MAX_FRAME_BYTES {
            throw DaemonError("frame claims \(length) bytes, limit is \(MAX_FRAME_BYTES)")
        }
        return try reader.readExact(length)
    }

    internal static func encodeBigEndian32(_ value: UInt32) -> [UInt8] {
        [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ]
    }

    internal static func decodeBigEndian32(_ bytes: [UInt8], offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
    }

    internal static func encodeBigEndian64(_ value: UInt64) -> [UInt8] {
        [
            UInt8((value >> 56) & 0xFF),
            UInt8((value >> 48) & 0xFF),
            UInt8((value >> 40) & 0xFF),
            UInt8((value >> 32) & 0xFF),
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ]
    }

    internal static func decodeBigEndian64(_ bytes: [UInt8], offset: Int) -> UInt64 {
        var result: UInt64 = 0
        for i in 0..<8 {
            result = (result << 8) | UInt64(bytes[offset + i])
        }
        return result
    }

    internal static func randomHex32() -> String {
        let hi = UInt64.random(in: 0...UInt64.max)
        let lo = UInt64.random(in: 0...UInt64.max)
        return hex16(hi) + hex16(lo)
    }

    internal static func hex16(_ value: UInt64) -> String {
        let digits: [UInt8] = Array("0123456789abcdef".utf8)
        var out = [UInt8](repeating: 0, count: 16)
        var v = value
        for i in stride(from: 15, through: 0, by: -1) {
            out[i] = digits[Int(v & 0xF)]
            v >>= 4
        }
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: - Ownership & Handoff State Machine (`src/ownership.rs`)

    public static let defaultAcquireTimeoutMs: UInt64 = 5_000
    public static let defaultHandoffTimeoutMs: UInt64 = 120_000

    // parity: process-daemon/src/ownership.rs#Handoff [status=implemented hash=fe19ccbef19a]
    public struct Handoff: Equatable, Hashable, Sendable {
        public let ticket: String
        public let expiresAt: UInt64
        public let deadlineMs: UInt64

        public init(ticket: String, expiresAt: UInt64, deadlineMs: UInt64) {
            self.ticket = ticket
            self.expiresAt = expiresAt
            self.deadlineMs = deadlineMs
        }
    }

    // parity: process-daemon/src/ownership.rs#Snapshot [status=implemented hash=5c461915d62c]
    public struct OwnershipSnapshot: Equatable, Hashable, Sendable {
        public let phase: UInt8
        public let generation: UInt64
        public let deadlineMs: UInt64?

        public init(phase: UInt8 = 0, generation: UInt64 = 0, deadlineMs: UInt64? = nil) {
            self.phase = phase
            self.generation = generation
            self.deadlineMs = deadlineMs
        }
    }

    // parity: process-daemon/src/ownership.rs#Ownership [status=implemented hash=6a59451a65f3]
    public struct Ownership: Equatable, Sendable {
        private enum State: Equatable, Sendable {
            case starting(UInt64)
            case owned(Handoff?)
            case waiting(Handoff)
            case stopped
        }

        private var state: State
        private var generation: UInt64
        private let handoffTimeoutMs: UInt64

        private init(state: State, generation: UInt64, handoffTimeoutMs: UInt64) {
            self.state = state
            self.generation = generation
            self.handoffTimeoutMs = handoffTimeoutMs
        }

        // parity: process-daemon/src/ownership.rs#new [status=implemented hash=5aecfcd50f5f]
        public static func new(nowMs: UInt64) -> Ownership {
            with_timeouts(
                nowMs: nowMs,
                acquireMs: defaultAcquireTimeoutMs,
                handoffMs: defaultHandoffTimeoutMs
            )
        }

        // parity: process-daemon/src/ownership.rs#with_timeouts [status=implemented hash=87a2e7c6e719]
        public static func with_timeouts(
            nowMs: UInt64,
            acquireMs: UInt64,
            handoffMs: UInt64
        ) -> Ownership {
            Ownership(
                state: .starting(nowMs &+ acquireMs),
                generation: 0,
                handoffTimeoutMs: handoffMs
            )
        }

        // parity: process-daemon/src/ownership.rs#tick [status=implemented hash=e16e23111018]
        @discardableResult
        public mutating func tick(nowMs: UInt64) -> Bool {
            switch state {
            case .starting(let deadline) where nowMs >= deadline:
                state = .stopped
            case .waiting(let handoff) where nowMs >= handoff.deadlineMs:
                state = .stopped
            case .owned(.some(let handoff)) where nowMs >= handoff.deadlineMs:
                state = .owned(nil)
            default:
                break
            }
            if case .stopped = state {
                return true
            }
            return false
        }

        // parity: process-daemon/src/ownership.rs#claim [status=implemented hash=5d11c7ca2390]
        public mutating func claim(ticket: String?, nowMs: UInt64) throws -> UInt64 {
            _ = tick(nowMs: nowMs)
            switch state {
            case .starting where ticket == nil:
                break
            case .owned(.some(let handoff)) where ticket == handoff.ticket:
                break
            case .waiting(let handoff) where ticket == handoff.ticket:
                break
            case .owned:
                throw DaemonError("daemon already has a live owner")
            case .stopped:
                throw DaemonError("daemon ownership deadline expired or daemon is stopping")
            default:
                throw DaemonError("invalid handoff ticket")
            }
            generation &+= 1
            state = .owned(nil)
            return generation
        }

        // parity: process-daemon/src/ownership.rs#is_owner [status=implemented hash=a215569303e6]
        public func is_owner(_ generation: UInt64) -> Bool {
            guard self.generation == generation else { return false }
            if case .owned = state {
                return true
            }
            return false
        }

        // parity: process-daemon/src/ownership.rs#prepare [status=implemented hash=7070682c7936]
        public mutating func prepare(
            generation: UInt64,
            nowMs: UInt64,
            unixMs: UInt64
        ) throws -> Handoff {
            _ = tick(nowMs: nowMs)
            guard self.generation == generation else {
                throw DaemonError("handoff requires the owner connection")
            }
            guard case .owned(let existing) = state else {
                throw DaemonError("handoff requires the owner connection")
            }
            if let existing {
                return existing
            }
            let created = Handoff(
                ticket: randomHex32(),
                expiresAt: unixMs &+ handoffTimeoutMs,
                deadlineMs: nowMs &+ handoffTimeoutMs
            )
            state = .owned(created)
            return created
        }

        // parity: process-daemon/src/ownership.rs#deadline [status=implemented hash=bfc045d3e4de]
        public func deadline() -> UInt64? {
            switch state {
            case .starting(let deadline):
                return deadline
            case .owned(.some(let handoff)), .waiting(let handoff):
                return handoff.deadlineMs
            case .owned(nil), .stopped:
                return nil
            }
        }

        // parity: process-daemon/src/ownership.rs#snapshot [status=implemented hash=b56dd28568ba]
        public func snapshot() -> OwnershipSnapshot {
            let phase: UInt8
            switch state {
            case .starting: phase = 0
            case .owned: phase = 1
            case .waiting: phase = 2
            case .stopped: phase = 3
            }
            return OwnershipSnapshot(
                phase: phase,
                generation: generation,
                deadlineMs: deadline()
            )
        }

        // parity: process-daemon/src/ownership.rs#disconnect [status=implemented hash=b26a0094ce20]
        public mutating func disconnect(generation: UInt64, nowMs: UInt64) {
            if !is_owner(generation) {
                return
            }
            _ = tick(nowMs: nowMs)
            if case .owned(.some(let handoff)) = state {
                state = .waiting(handoff)
            } else {
                state = .stopped
            }
        }
    }
}
