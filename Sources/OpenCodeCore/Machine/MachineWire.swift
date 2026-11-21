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

    /// Output stream tag carried on every `output` message.
    public enum OutputStream: String, Equatable, Hashable, Sendable, Codable {
        case stdout
        case stderr
    }

    /// Outcome of a worker `stdin` acknowledgment.
    public enum StdinOutcome: Equatable, Hashable, Sendable {
        case ok
        case failed(String)
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
        case type, id, pid, request, message, offset, stream, data, bytes, code, signal, req, ok, result, error
        case `protocol`, os, arch, home, instance, processes, state
        case argv, cwd, env, stdin, from, to, call, path, range
        case kind, actual, info, length, name
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

    /// The first message of every connection, reconnects included. It names no machine: which machine sent it is the
    /// link's to prove, never the worker's to say.
    // parity: core/src/machine/wire.ts#Hello [status=implemented hash=e449e5cd967f]
    public struct Hello: Equatable, Hashable, Sendable, Codable {
        /// The version of the messages after the handshake: a home that does not know a worker's version ends the
        /// connection.
        public static let protocolVersion = 2

        public let `protocol`: Int
        public let os: String
        public let arch: String
        /// The worker's home directory, an absolute POSIX path: where `~` in a path on this machine starts.
        public let home: String
        /// Made once per worker process start: a new value means every process the worker held is gone.
        public let instance: Instance
        public let processes: [HelloProcess]

        public init(
            protocol version: Int = MachineWire.Hello.protocolVersion,
            os: String,
            arch: String,
            home: String,
            instance: Instance,
            processes: [HelloProcess] = []
        ) {
            self.`protocol` = version
            self.os = os
            self.arch = arch
            self.home = home
            self.instance = instance
            self.processes = processes
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            try MachineWire.literal(c, .type, "hello")
            let version = try c.decode(Int.self, forKey: .protocol)
            guard version == Self.protocolVersion else {
                throw DecodingError.dataCorruptedError(
                    forKey: .protocol,
                    in: c,
                    debugDescription: "Expected protocol \(Self.protocolVersion)"
                )
            }
            self.`protocol` = version
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
            try c.encode(self.`protocol`, forKey: .protocol)
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

    // parity: core/src/machine/wire.ts#FromWorker [status=implemented hash=553787302ba0]
    public enum FromWorker: Equatable, Hashable, Sendable, Codable {
        case hello(Hello)
        case started(id: ProcessID, pid: Int)
        /// A start, attach or kill that could not be done.
        case failed(id: ProcessID, request: FailedRequest, message: String)
        /// `offset` is the position of the first byte of `data` in the process's merged stdout and stderr.
        case output(id: ProcessID, offset: Int, stream: OutputStream, data: [UInt8])
        case stdin(id: ProcessID, req: Int, outcome: StdinOutcome)
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
                    stream: try c.decode(OutputStream.self, forKey: .stream),
                    data: try c.decode(Bytes.self, forKey: .data).value
                )
            case "stdin":
                let id = try c.decode(ProcessID.self, forKey: .id)
                let req = try c.decode(Int.self, forKey: .req)
                if try c.decode(Bool.self, forKey: .ok) {
                    self = .stdin(id: id, req: req, outcome: .ok)
                } else {
                    self = .stdin(id: id, req: req, outcome: .failed(try c.decode(String.self, forKey: .message)))
                }
            case "exit":
                let id = try c.decode(ProcessID.self, forKey: .id)
                let bytes = try c.decode(Int.self, forKey: .bytes)
                guard c.contains(.code) else {
                    throw DecodingError.keyNotFound(Keys.code, .init(codingPath: c.codingPath, debugDescription: "Missing code"))
                }
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
            guard c.contains(.result) else {
                throw DecodingError.keyNotFound(Keys.result, .init(codingPath: c.codingPath, debugDescription: "Missing result"))
            }
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
            case .output(let id, let offset, let stream, let data):
                try c.encode("output", forKey: .type)
                try c.encode(id, forKey: .id)
                try c.encode(offset, forKey: .offset)
                try c.encode(stream, forKey: .stream)
                try c.encode(Bytes(data), forKey: .data)
            case .stdin(let id, let req, let outcome):
                try c.encode("stdin", forKey: .type)
                try c.encode(id, forKey: .id)
                try c.encode(req, forKey: .req)
                switch outcome {
                case .ok:
                    try c.encode(true, forKey: .ok)
                case .failed(let message):
                    try c.encode(false, forKey: .ok)
                    try c.encode(message, forKey: .message)
                }
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
    // parity: core/src/machine/wire.ts#FileCall [status=implemented hash=fa8f2d531e1d]
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

    // parity: core/src/machine/wire.ts#ToWorker [status=implemented hash=e4949c6b69c5]
    public enum ToWorker: Equatable, Hashable, Sendable, Codable {
        /// Starts the process and attaches to its output from byte 0. `env` is set over the worker's own environment.
        case start(id: ProcessID, argv: [String], cwd: String, env: [String: String], stdin: Bool)
        /// Acknowledged after writing to the OS pipe. `nil` closes it; never replayed.
        case stdin(id: ProcessID, req: Int, data: [UInt8]?)
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
                    env: try c.decode([String: String].self, forKey: .env),
                    stdin: try c.decode(Bool.self, forKey: .stdin)
                )
            case "stdin":
                let id = try c.decode(ProcessID.self, forKey: .id)
                let req = try c.decode(Int.self, forKey: .req)
                guard c.contains(.data) else {
                    throw DecodingError.keyNotFound(Keys.data, .init(codingPath: c.codingPath, debugDescription: "Missing data"))
                }
                let data: [UInt8]? = try c.decodeNil(forKey: .data)
                    ? nil
                    : try c.decode(Bytes.self, forKey: .data).value
                self = .stdin(id: id, req: req, data: data)
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
            case .start(let id, let argv, let cwd, let env, let stdin):
                try c.encode("start", forKey: .type)
                try c.encode(id, forKey: .id)
                try c.encode(argv, forKey: .argv)
                try c.encode(cwd, forKey: .cwd)
                try c.encode(env, forKey: .env)
                try c.encode(stdin, forKey: .stdin)
            case .stdin(let id, let req, let data):
                try c.encode("stdin", forKey: .type)
                try c.encode(id, forKey: .id)
                try c.encode(req, forKey: .req)
                if let data {
                    try c.encode(Bytes(data), forKey: .data)
                } else {
                    try c.encodeNil(forKey: .data)
                }
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

    // MARK: - Canonical Wire JSON Encoding (matches upstream Schema.encodeSync field order without escaping slashes)

    private static func jsonNumber(_ value: Double) -> String {
        if value.isFinite, value.rounded() == value, abs(value) <= 9_007_199_254_740_991 {
            return String(Int64(value))
        }
        return String(value)
    }

    private static func jsonFileInfo(_ info: FileInfo) -> String {
        "{\"type\":\(MachineJoin.jsonString(info.type.rawValue)),\"size\":\(jsonNumber(info.size)),\"mtimeMs\":\(jsonNumber(info.mtimeMs))}"
    }

    private static func jsonHelloProcess(_ proc: HelloProcess) -> String {
        var fields = [
            "\"id\":\(MachineJoin.jsonString(proc.id.rawValue))",
            "\"pid\":\(proc.pid)",
            "\"state\":\(MachineJoin.jsonString(proc.state.rawValue))",
            "\"bytes\":\(proc.bytes)",
        ]
        if case .some(let inner) = proc.code {
            fields.append("\"code\":\(inner.map(String.init) ?? "null")")
        }
        if let signal = proc.signal {
            fields.append("\"signal\":\(MachineJoin.jsonString(signal))")
        }
        return "{" + fields.joined(separator: ",") + "}"
    }

    public static func encodeJSONString(_ hello: Hello) -> String {
        let procs = hello.processes.map(jsonHelloProcess).joined(separator: ",")
        return "{\"type\":\"hello\",\"protocol\":\(hello.`protocol`),\"os\":\(MachineJoin.jsonString(hello.os)),\"arch\":\(MachineJoin.jsonString(hello.arch)),\"home\":\(MachineJoin.jsonString(hello.home)),\"instance\":\(MachineJoin.jsonString(hello.instance.rawValue)),\"processes\":[\(procs)]}"
    }

    public static func encodeJSONString(_ message: FromWorker) -> String {
        switch message {
        case .hello(let hello):
            return encodeJSONString(hello)
        case .started(let id, let pid):
            return "{\"type\":\"started\",\"id\":\(MachineJoin.jsonString(id.rawValue)),\"pid\":\(pid)}"
        case .failed(let id, let request, let text):
            return "{\"type\":\"failed\",\"id\":\(MachineJoin.jsonString(id.rawValue)),\"request\":\(MachineJoin.jsonString(request.rawValue)),\"message\":\(MachineJoin.jsonString(text))}"
        case .output(let id, let offset, let stream, let data):
            return "{\"type\":\"output\",\"id\":\(MachineJoin.jsonString(id.rawValue)),\"offset\":\(offset),\"stream\":\(MachineJoin.jsonString(stream.rawValue)),\"data\":\(MachineJoin.jsonString(MachineCrypto.base64Encode(data)))}"
        case .stdin(let id, let req, let outcome):
            switch outcome {
            case .ok:
                return "{\"type\":\"stdin\",\"id\":\(MachineJoin.jsonString(id.rawValue)),\"req\":\(req),\"ok\":true}"
            case .failed(let text):
                return "{\"type\":\"stdin\",\"id\":\(MachineJoin.jsonString(id.rawValue)),\"req\":\(req),\"ok\":false,\"message\":\(MachineJoin.jsonString(text))}"
            }
        case .exit(let exit):
            if let code = exit.code {
                return "{\"type\":\"exit\",\"id\":\(MachineJoin.jsonString(exit.id.rawValue)),\"bytes\":\(exit.bytes),\"code\":\(code)}"
            }
            return "{\"type\":\"exit\",\"id\":\(MachineJoin.jsonString(exit.id.rawValue)),\"bytes\":\(exit.bytes),\"code\":null,\"signal\":\(MachineJoin.jsonString(exit.signal ?? ""))}"
        case .fs(let reply):
            switch reply.outcome {
            case .success(let result):
                let encodedResult: String
                switch result {
                case .none:
                    encodedResult = "null"
                case .info(let info):
                    encodedResult = jsonFileInfo(info)
                case .list(let entries):
                    encodedResult = "[" + entries.map {
                        "{\"name\":\(MachineJoin.jsonString($0.name)),\"type\":\(MachineJoin.jsonString($0.type.rawValue))}"
                    }.joined(separator: ",") + "]"
                case .read(let read):
                    encodedResult = "{\"info\":\(jsonFileInfo(read.info)),\"bytes\":\(MachineJoin.jsonString(MachineCrypto.base64Encode(read.bytes)))}"
                }
                return "{\"type\":\"fs\",\"req\":\(reply.req),\"ok\":true,\"result\":\(encodedResult)}"
            case .failure(let error):
                var fields = [
                    "\"kind\":\(MachineJoin.jsonString(error.kind.rawValue))",
                    "\"message\":\(MachineJoin.jsonString(error.message))",
                ]
                if let actual = error.actual {
                    fields.append("\"actual\":\(MachineJoin.jsonString(actual.rawValue))")
                }
                return "{\"type\":\"fs\",\"req\":\(reply.req),\"ok\":false,\"error\":{\(fields.joined(separator: ","))}}"
            }
        }
    }

    public static func encodeJSONString(_ message: ToWorker) -> String {
        switch message {
        case .start(let id, let argv, let cwd, let env, let stdin):
            let argvJSON = "[" + argv.map(MachineJoin.jsonString).joined(separator: ",") + "]"
            let envJSON = "{" + env.keys.sorted().map { key in
                "\(MachineJoin.jsonString(key)):\(MachineJoin.jsonString(env[key] ?? ""))"
            }.joined(separator: ",") + "}"
            return "{\"type\":\"start\",\"id\":\(MachineJoin.jsonString(id.rawValue)),\"argv\":\(argvJSON),\"cwd\":\(MachineJoin.jsonString(cwd)),\"env\":\(envJSON),\"stdin\":\(stdin ? "true" : "false")}"
        case .stdin(let id, let req, let data):
            let dataJSON = data.map { MachineJoin.jsonString(MachineCrypto.base64Encode($0)) } ?? "null"
            return "{\"type\":\"stdin\",\"id\":\(MachineJoin.jsonString(id.rawValue)),\"req\":\(req),\"data\":\(dataJSON)}"
        case .attach(let id, let from):
            return "{\"type\":\"attach\",\"id\":\(MachineJoin.jsonString(id.rawValue)),\"from\":\(from)}"
        case .kill(let id, let signal):
            return "{\"type\":\"kill\",\"id\":\(MachineJoin.jsonString(id.rawValue)),\"signal\":\(MachineJoin.jsonString(signal.rawValue))}"
        case .release(let id):
            return "{\"type\":\"release\",\"id\":\(MachineJoin.jsonString(id.rawValue))}"
        case .fs(let fileCall):
            switch fileCall.call {
            case .stat(let path):
                return "{\"type\":\"fs\",\"req\":\(fileCall.req),\"call\":\"stat\",\"path\":\(MachineJoin.jsonString(path))}"
            case .list(let path):
                return "{\"type\":\"fs\",\"req\":\(fileCall.req),\"call\":\"list\",\"path\":\(MachineJoin.jsonString(path))}"
            case .remove(let path):
                return "{\"type\":\"fs\",\"req\":\(fileCall.req),\"call\":\"remove\",\"path\":\(MachineJoin.jsonString(path))}"
            case .mkdir(let path):
                return "{\"type\":\"fs\",\"req\":\(fileCall.req),\"call\":\"mkdir\",\"path\":\(MachineJoin.jsonString(path))}"
            case .read(let path, let range):
                var fields = [
                    "\"type\":\"fs\"",
                    "\"req\":\(fileCall.req)",
                    "\"call\":\"read\"",
                    "\"path\":\(MachineJoin.jsonString(path))",
                ]
                if let range {
                    fields.append("\"range\":{\"offset\":\(range.offset),\"length\":\(range.length)}")
                }
                return "{" + fields.joined(separator: ",") + "}"
            case .write(let path, let bytes):
                return "{\"type\":\"fs\",\"req\":\(fileCall.req),\"call\":\"write\",\"path\":\(MachineJoin.jsonString(path)),\"bytes\":\(MachineJoin.jsonString(MachineCrypto.base64Encode(bytes)))}"
            case .append(let path, let bytes):
                return "{\"type\":\"fs\",\"req\":\(fileCall.req),\"call\":\"append\",\"path\":\(MachineJoin.jsonString(path)),\"bytes\":\(MachineJoin.jsonString(MachineCrypto.base64Encode(bytes)))}"
            case .move(let from, let to):
                return "{\"type\":\"fs\",\"req\":\(fileCall.req),\"call\":\"move\",\"from\":\(MachineJoin.jsonString(from)),\"to\":\(MachineJoin.jsonString(to))}"
            }
        }
    }

    public static func encodeJSON(_ message: FromWorker) -> [UInt8] {
        Array(encodeJSONString(message).utf8)
    }

    public static func encodeJSON(_ message: ToWorker) -> [UInt8] {
        Array(encodeJSONString(message).utf8)
    }
}
