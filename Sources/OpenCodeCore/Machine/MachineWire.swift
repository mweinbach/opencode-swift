// Messages between the home and a machine's worker (`core/src/machine/wire.ts`). Bytes are `[UInt8]` in memory and
// standard base64 in JSON, so `JSONEncoder().encode(message)` is the JSON form of a `ToWorker` and
// `JSONDecoder().decode(FromWorker.self, from:)` reads a worker's message.

/// Port of `core/src/machine/wire.ts`.
public enum MachineWire {
    public typealias FileType = CoreLocation.Environment.Files.FileType

    /// Names a process between the home and the worker. The home makes it when it starts the process.
    // parity: core/src/machine/wire.ts#ProcessID [status=implemented hash=d9ab6f077858]
    public struct ProcessID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(_ rawValue: String) { self.rawValue = rawValue }
        public init(from decoder: any Decoder) throws {
            rawValue = try decoder.singleValueContainer().decode(String.self)
        }
        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
        public var description: String { rawValue }
    }

    /// One run of the worker program.
    // parity: core/src/machine/wire.ts#Instance [status=implemented hash=a07363f16c8f]
    public struct Instance: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(_ rawValue: String) { self.rawValue = rawValue }
        public init(from decoder: any Decoder) throws {
            rawValue = try decoder.singleValueContainer().decode(String.self)
        }
        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
        public var description: String { rawValue }
    }

    /// The signals a worker can send to a process.
    // parity: core/src/machine/wire.ts#Signal [status=implemented hash=5f8ec949ddbf]
    public enum Signal: String, Hashable, Sendable, Codable, CaseIterable {
        case SIGTERM, SIGKILL, SIGINT
    }

    public struct FileInfo: Equatable, Hashable, Sendable, Codable {
        public let type: FileType
        public let size: Double
        public let mtimeMs: Double

        public init(type: FileType, size: Double, mtimeMs: Double) {
            self.type = type
            self.size = size
            self.mtimeMs = mtimeMs
        }
    }

    public struct DirEntry: Equatable, Hashable, Sendable, Codable {
        public let name: String
        public let type: FileType

        public init(name: String, type: FileType) {
            self.name = name
            self.type = type
        }
    }

    /// Bytes as standard base64 in JSON.
    struct Bytes: Codable, Equatable {
        let value: [UInt8]
        init(_ value: [UInt8]) { self.value = value }
        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let bytes = MachineCrypto.base64Decode(text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected base64")
            }
            value = bytes
        }
        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(MachineCrypto.base64Encode(value))
        }
    }

    enum Keys: String, CodingKey {
        case type, id, pid, request, message, offset, data, bytes, code, signal, req, ok, result, error
        case name, os, arch, home, instance, processes, state
        case argv, cwd, env, from, to, call, path, range
        case kind, actual, info, length
    }

    static func literal(_ container: KeyedDecodingContainer<Keys>, _ key: Keys, _ expected: String) throws {
        let value = try container.decode(String.self, forKey: key)
        guard value == expected else {
            throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "Expected \(expected)")
        }
    }

    // MARK: - Hello

    public struct HelloProcess: Equatable, Hashable, Sendable, Codable {
        public enum State: String, Hashable, Sendable, Codable { case running, exited }

        public let id: ProcessID
        public let pid: Int
        public let state: State
        public let bytes: Int
        /// Absent, `null`, or the exit code.
        public let code: Int??
        public let signal: String?

        public init(id: ProcessID, pid: Int, state: State, bytes: Int, code: Int?? = nil, signal: String? = nil) {
            self.id = id
            self.pid = pid
            self.state = state
            self.bytes = bytes
            self.code = code
            self.signal = signal
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            id = try c.decode(ProcessID.self, forKey: .id)
            pid = try c.decode(Int.self, forKey: .pid)
            state = try c.decode(State.self, forKey: .state)
            bytes = try c.decode(Int.self, forKey: .bytes)
            if c.contains(.code) {
                code = .some(try c.decodeNil(forKey: .code) ? nil : try c.decode(Int.self, forKey: .code))
            } else {
                code = nil
            }
            signal = try c.decodeIfPresent(String.self, forKey: .signal)
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(id, forKey: .id)
            try c.encode(pid, forKey: .pid)
            try c.encode(state, forKey: .state)
            try c.encode(bytes, forKey: .bytes)
            if case .some(let inner) = code {
                if let inner { try c.encode(inner, forKey: .code) } else { try c.encodeNil(forKey: .code) }
            }
            try c.encodeIfPresent(signal, forKey: .signal)
        }
    }

    /// The first message of every connection, reconnects included.
    // parity: core/src/machine/wire.ts#Hello [status=implemented hash=50d89f499e13]
    public struct Hello: Equatable, Hashable, Sendable, Codable {
        public let name: String
        public let os: String
        public let arch: String
        /// The worker's home directory, an absolute POSIX path: where `~` in a path on this machine starts.
        public let home: String
        /// Made once per worker process start: a new value means every process the worker held is gone.
        public let instance: Instance
        public let processes: [HelloProcess]

        public init(name: String, os: String, arch: String, home: String, instance: Instance, processes: [HelloProcess] = []) {
            self.name = name
            self.os = os
            self.arch = arch
            self.home = home
            self.instance = instance
            self.processes = processes
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            try MachineWire.literal(c, .type, "hello")
            name = try c.decode(String.self, forKey: .name)
            os = try c.decode(String.self, forKey: .os)
            arch = try c.decode(String.self, forKey: .arch)
            home = try c.decode(String.self, forKey: .home)
            guard home.hasPrefix("/") else {
                throw DecodingError.dataCorruptedError(forKey: .home, in: c, debugDescription: "Expected an absolute POSIX path")
            }
            instance = try c.decode(Instance.self, forKey: .instance)
            processes = try c.decode([HelloProcess].self, forKey: .processes)
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode("hello", forKey: .type)
            try c.encode(name, forKey: .name)
            try c.encode(os, forKey: .os)
            try c.encode(arch, forKey: .arch)
            try c.encode(home, forKey: .home)
            try c.encode(instance, forKey: .instance)
            try c.encode(processes, forKey: .processes)
        }
    }

    // MARK: - FromWorker

    public enum FailedRequest: String, Hashable, Sendable, Codable { case start, attach, kill }

    public enum FileErrorKind: String, Hashable, Sendable, Codable {
        case notFound = "not_found"
        case wrongKind = "wrong_kind"
        case failed
    }

    public struct FileError: Error, Equatable, Hashable, Sendable, Codable {
        public let kind: FileErrorKind
        public let message: String
        public let actual: FileType?

        public init(kind: FileErrorKind, message: String, actual: FileType? = nil) {
            self.kind = kind
            self.message = message
            self.actual = actual
        }
    }

    public struct ReadResult: Equatable, Hashable, Sendable {
        public let info: FileInfo
        public let bytes: [UInt8]

        public init(info: FileInfo, bytes: [UInt8]) {
            self.info = info
            self.bytes = bytes
        }
    }

    /// What a successful file call returns: nothing, a stat, a listing, or a read.
    public enum FileResult: Equatable, Hashable, Sendable {
        case none
        case info(FileInfo)
        case list([DirEntry])
        case read(ReadResult)
    }

    /// A file call's reply. It carries the call's `req`.
    public struct FileReply: Equatable, Hashable, Sendable {
        public let req: Int
        public let outcome: Result<FileResult, FileError>

        public init(req: Int, outcome: Result<FileResult, FileError>) {
            self.req = req
            self.outcome = outcome
        }
    }

    public struct Exit: Equatable, Hashable, Sendable {
        public let id: ProcessID
        public let bytes: Int
        /// The exit code, or `nil` when a signal ended the process.
        public let code: Int?
        public let signal: String?

        public init(id: ProcessID, bytes: Int, code: Int) {
            self.id = id
            self.bytes = bytes
            self.code = code
            self.signal = nil
        }

        public init(id: ProcessID, bytes: Int, signal: String) {
            self.id = id
            self.bytes = bytes
            self.code = nil
            self.signal = signal
        }
    }

    // parity: core/src/machine/wire.ts#FromWorker [status=implemented hash=3c59175cb333]
    public enum FromWorker: Equatable, Hashable, Sendable, Codable {
        case hello(Hello)
        case started(id: ProcessID, pid: Int)
        /// A start, attach or kill that could not be done.
        case failed(id: ProcessID, request: FailedRequest, message: String)
        /// `offset` is the position of the first byte of `data` in the process's merged stdout and stderr.
        case output(id: ProcessID, offset: Int, data: [UInt8])
        case exit(Exit)
        case fs(FileReply)

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            let type = try c.decode(String.self, forKey: .type)
            switch type {
            case "hello":
                self = .hello(try Hello(from: decoder))
            case "started":
                self = .started(id: try c.decode(ProcessID.self, forKey: .id), pid: try c.decode(Int.self, forKey: .pid))
            case "failed":
                self = .failed(
                    id: try c.decode(ProcessID.self, forKey: .id),
                    request: try c.decode(FailedRequest.self, forKey: .request),
                    message: try c.decode(String.self, forKey: .message)
                )
            case "output":
                self = .output(
                    id: try c.decode(ProcessID.self, forKey: .id),
                    offset: try c.decode(Int.self, forKey: .offset),
                    data: try c.decode(Bytes.self, forKey: .data).value
                )
            case "exit":
                let id = try c.decode(ProcessID.self, forKey: .id)
                let bytes = try c.decode(Int.self, forKey: .bytes)
                if try c.decodeNil(forKey: .code) {
                    self = .exit(Exit(id: id, bytes: bytes, signal: try c.decode(String.self, forKey: .signal)))
                } else {
                    self = .exit(Exit(id: id, bytes: bytes, code: try c.decode(Int.self, forKey: .code)))
                }
            case "fs":
                let req = try c.decode(Int.self, forKey: .req)
                if try c.decode(Bool.self, forKey: .ok) {
                    self = .fs(FileReply(req: req, outcome: .success(try Self.decodeResult(c))))
                } else {
                    self = .fs(FileReply(req: req, outcome: .failure(try c.decode(FileError.self, forKey: .error))))
                }
            default:
                throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown message \(type)")
            }
        }

        /// The members of the result union, tried in upstream's order.
        private static func decodeResult(_ c: KeyedDecodingContainer<Keys>) throws -> FileResult {
            if try c.decodeNil(forKey: .result) { return .none }
            if let info = try? c.decode(FileInfo.self, forKey: .result) { return .info(info) }
            if let entries = try? c.decode([DirEntry].self, forKey: .result) { return .list(entries) }
            let read = try c.nestedContainer(keyedBy: Keys.self, forKey: .result)
            return .read(ReadResult(
                info: try read.decode(FileInfo.self, forKey: .info),
                bytes: try read.decode(Bytes.self, forKey: .bytes).value
            ))
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            switch self {
            case .hello(let hello):
                try hello.encode(to: encoder)
            case .started(let id, let pid):
                try c.encode("started", forKey: .type)
                try c.encode(id, forKey: .id)
                try c.encode(pid, forKey: .pid)
            case .failed(let id, let request, let message):
                try c.encode("failed", forKey: .type)
                try c.encode(id, forKey: .id)
                try c.encode(request, forKey: .request)
                try c.encode(message, forKey: .message)
            case .output(let id, let offset, let data):
                try c.encode("output", forKey: .type)
                try c.encode(id, forKey: .id)
                try c.encode(offset, forKey: .offset)
                try c.encode(Bytes(data), forKey: .data)
            case .exit(let exit):
                try c.encode("exit", forKey: .type)
                try c.encode(exit.id, forKey: .id)
                try c.encode(exit.bytes, forKey: .bytes)
                if let code = exit.code {
                    try c.encode(code, forKey: .code)
                } else {
                    try c.encodeNil(forKey: .code)
                    try c.encode(exit.signal ?? "", forKey: .signal)
                }
            case .fs(let reply):
                try c.encode("fs", forKey: .type)
                try c.encode(reply.req, forKey: .req)
                switch reply.outcome {
                case .success(let result):
                    try c.encode(true, forKey: .ok)
                    switch result {
                    case .none: try c.encodeNil(forKey: .result)
                    case .info(let info): try c.encode(info, forKey: .result)
                    case .list(let entries): try c.encode(entries, forKey: .result)
                    case .read(let read):
                        var nested = c.nestedContainer(keyedBy: Keys.self, forKey: .result)
                        try nested.encode(read.info, forKey: .info)
                        try nested.encode(Bytes(read.bytes), forKey: .bytes)
                    }
                case .failure(let error):
                    try c.encode(false, forKey: .ok)
                    try c.encode(error, forKey: .error)
                }
            }
        }
    }

    // MARK: - FileCall

    public struct Range: Equatable, Hashable, Sendable, Codable {
        public let offset: Int
        public let length: Int

        public init(offset: Int, length: Int) {
            self.offset = offset
            self.length = length
        }
    }

    /// A file call as the files ask for it, before it is given a `req`.
    public enum Call: Equatable, Hashable, Sendable {
        case stat(path: String)
        case list(path: String)
        case remove(path: String)
        case mkdir(path: String)
        case read(path: String, range: Range?)
        case write(path: String, bytes: [UInt8])
        case append(path: String, bytes: [UInt8])
        case move(from: String, to: String)
    }

    /// File calls, with the semantics of the environment's `Files`.
    // parity: core/src/machine/wire.ts#FileCall [status=implemented hash=08fa728738d7]
    public struct FileCall: Equatable, Hashable, Sendable, Codable {
        /// A file call and its reply carry the same `req`.
        public let req: Int
        public let call: Call

        public init(req: Int, call: Call) {
            self.req = req
            self.call = call
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            try MachineWire.literal(c, .type, "fs")
            req = try c.decode(Int.self, forKey: .req)
            let name = try c.decode(String.self, forKey: .call)
            switch name {
            case "stat": call = .stat(path: try c.decode(String.self, forKey: .path))
            case "list": call = .list(path: try c.decode(String.self, forKey: .path))
            case "remove": call = .remove(path: try c.decode(String.self, forKey: .path))
            case "mkdir": call = .mkdir(path: try c.decode(String.self, forKey: .path))
            case "read":
                call = .read(path: try c.decode(String.self, forKey: .path), range: try c.decodeIfPresent(Range.self, forKey: .range))
            case "write":
                call = .write(path: try c.decode(String.self, forKey: .path), bytes: try c.decode(Bytes.self, forKey: .bytes).value)
            case "append":
                call = .append(path: try c.decode(String.self, forKey: .path), bytes: try c.decode(Bytes.self, forKey: .bytes).value)
            case "move":
                call = .move(from: try c.decode(String.self, forKey: .from), to: try c.decode(String.self, forKey: .to))
            default:
                throw DecodingError.dataCorruptedError(forKey: .call, in: c, debugDescription: "Unknown file call \(name)")
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode("fs", forKey: .type)
            try c.encode(req, forKey: .req)
            switch call {
            case .stat(let path), .list(let path), .remove(let path), .mkdir(let path):
                let name: String
                switch call {
                case .stat: name = "stat"
                case .list: name = "list"
                case .remove: name = "remove"
                default: name = "mkdir"
                }
                try c.encode(name, forKey: .call)
                try c.encode(path, forKey: .path)
            case .read(let path, let range):
                try c.encode("read", forKey: .call)
                try c.encode(path, forKey: .path)
                try c.encodeIfPresent(range, forKey: .range)
            case .write(let path, let bytes):
                try c.encode("write", forKey: .call)
                try c.encode(path, forKey: .path)
                try c.encode(Bytes(bytes), forKey: .bytes)
            case .append(let path, let bytes):
                try c.encode("append", forKey: .call)
                try c.encode(path, forKey: .path)
                try c.encode(Bytes(bytes), forKey: .bytes)
            case .move(let from, let to):
                try c.encode("move", forKey: .call)
                try c.encode(from, forKey: .from)
                try c.encode(to, forKey: .to)
            }
        }
    }

    // MARK: - ToWorker

    // parity: core/src/machine/wire.ts#ToWorker [status=implemented hash=c080c8433591]
    public enum ToWorker: Equatable, Hashable, Sendable, Codable {
        /// Starts the process and attaches to its output from byte 0. `env` is set over the worker's own environment.
        case start(id: ProcessID, argv: [String], cwd: String, env: [String: String])
        /// Sends output from byte `from` on, then the exit once every byte is sent. Replaces an earlier attach.
        case attach(id: ProcessID, from: Int)
        case kill(id: ProcessID, signal: Signal)
        /// Sent once the home has the process's exit: the worker may forget the process and its output.
        case release(id: ProcessID)
        case fs(FileCall)

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            let type = try c.decode(String.self, forKey: .type)
            switch type {
            case "start":
                self = .start(
                    id: try c.decode(ProcessID.self, forKey: .id),
                    argv: try c.decode([String].self, forKey: .argv),
                    cwd: try c.decode(String.self, forKey: .cwd),
                    env: try c.decode([String: String].self, forKey: .env)
                )
            case "attach":
                self = .attach(id: try c.decode(ProcessID.self, forKey: .id), from: try c.decode(Int.self, forKey: .from))
            case "kill":
                self = .kill(id: try c.decode(ProcessID.self, forKey: .id), signal: try c.decode(Signal.self, forKey: .signal))
            case "release":
                self = .release(id: try c.decode(ProcessID.self, forKey: .id))
            case "fs":
                self = .fs(try FileCall(from: decoder))
            default:
                throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown message \(type)")
            }
        }

        public func encode(to encoder: any Encoder) throws {
            if case .fs(let call) = self {
                try call.encode(to: encoder)
                return
            }
            var c = encoder.container(keyedBy: Keys.self)
            switch self {
            case .start(let id, let argv, let cwd, let env):
                try c.encode("start", forKey: .type)
                try c.encode(id, forKey: .id)
                try c.encode(argv, forKey: .argv)
                try c.encode(cwd, forKey: .cwd)
                try c.encode(env, forKey: .env)
            case .attach(let id, let from):
                try c.encode("attach", forKey: .type)
                try c.encode(id, forKey: .id)
                try c.encode(from, forKey: .from)
            case .kill(let id, let signal):
                try c.encode("kill", forKey: .type)
                try c.encode(id, forKey: .id)
                try c.encode(signal, forKey: .signal)
            case .release(let id):
                try c.encode("release", forKey: .type)
                try c.encode(id, forKey: .id)
            case .fs:
                break
            }
        }
    }
}
