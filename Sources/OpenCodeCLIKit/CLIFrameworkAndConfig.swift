import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(WinSDK)
import WinSDK
#endif
import Synchronization
import OpenCodeClient
import OpenCodeCore
import OpenCodePlatform
import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeTUI
import OpenCodeUtil
import OpenTUICore
import OpenTUITerminal

// MARK: - CLI Utilities, Runtime Hooks, Archive & Node Targets (`packages/cli/src/util/*`, `src/*.ts`, `src/node/*`)

public enum CLIUtil {
    // MARK: Version (`packages/cli/src/version.ts`)

    public enum Version {
        public struct ReleaseHighlight: Equatable, Hashable, Sendable, Codable {
            public let title: String
            public let body: String

            public init(title: String, body: String) {
                self.title = title
                self.body = body
            }
        }

        // parity: cli/src/version.ts#OPENCODE_VERSION [status=implemented hash=d10b83002c91]
        public static let OPENCODE_VERSION: String = "local"
        // parity: cli/src/version.ts#OPENCODE_CHANNEL [status=implemented hash=cb038e26553b]
        public static let OPENCODE_CHANNEL: String = {
            #if DEBUG
            return "local"
            #else
            return "latest"
            #endif
        }()
        // parity: cli/src/version.ts#OPENCODE_ARTIFACT [status=implemented hash=a68bef1bc782]
        public static let OPENCODE_ARTIFACT: String = "cli"
        // parity: cli/src/version.ts#OPENCODE_HIGHLIGHTS [status=implemented hash=50532af0ac5a]
        public static let OPENCODE_HIGHLIGHTS: [ReleaseHighlight] = []

        // parity: cli/src/version.ts#OPENCODE_LOCAL [status=implemented hash=f27e42b689b3]
        public static let OPENCODE_LOCAL: Bool = OPENCODE_CHANNEL == "local"

        /// Resolves the active CLI channel, honoring a non-empty `OPENCODE_CHANNEL` environment variable
        /// before falling back to the build-time `OPENCODE_CHANNEL` (`"local"` in debug, `"latest"` in release).
        public static func resolvedChannel(
            environment: any EnvironmentProviding = SystemEnvironment.shared
        ) -> String {
            if let override = environment.variable("OPENCODE_CHANNEL")?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !override.isEmpty
            {
                return override
            }
            return OPENCODE_CHANNEL
        }
    }

    // MARK: Error Formatting (`packages/cli/src/util/error.ts`)

    // parity: cli/src/util/error.ts#errorMessage [status=implemented hash=b90817d70aad]
    public static func errorMessage(_ error: Any) -> String {
        if let cliErr = error as? CLIError {
            return cliErr.message
        }
        if let desc = error as? any CustomStringConvertible {
            return desc.description
        }
        if let localized = error as? any LocalizedError, let text = localized.errorDescription {
            return text
        }
        return String(describing: error)
    }

    // MARK: Environment (`packages/cli/src/env.ts`)

    public enum Env {
        /// Redacted password configuration wrapper matching `Env.password`.
        public struct RedactedPassword: Equatable, Hashable, Sendable, CustomStringConvertible {
            private let rawValue: String

            public init(_ value: String) {
                self.rawValue = value
            }

            public var value: String { rawValue }
            public var description: String { "<redacted>" }
        }

        /// Reads `OPENCODE_PASSWORD` (falling back to legacy `OPENCODE_SERVER_PASSWORD`).
        // parity: cli/src/env.ts#password [status=adapted hash=aba0e394de22]
        public static let password: @Sendable (CLIContext) -> RedactedPassword? = { context in
            if let value = context.envVariable("OPENCODE_PASSWORD") {
                return RedactedPassword(value)
            }
            if let legacy = context.envVariable("OPENCODE_SERVER_PASSWORD") {
                return RedactedPassword(legacy)
            }
            return nil
        }

        /// Convenience overload reading from the task-local `CLIContext.current`.
        public static func readPassword(from context: CLIContext = CLIContext.current) -> RedactedPassword? {
            password(context)
        }

        /// Returns session-safe environment variables with server password secrets stripped.
        // parity: cli/src/env.ts#session [status=implemented hash=15be80a13777]
        public static func session(environment: [String: String]? = nil) -> [String: String] {
            let source: [String: String]
            if let environment {
                source = environment
            } else if let dict = CLIContext.current.environment as? DictionaryEnvironment {
                source = dict.variables
            } else {
                #if os(WASI)
                source = [:]
                #else
                source = ProcessInfo.processInfo.environment
                #endif
            }
            return source.filter { key, _ in
                key != "OPENCODE_PASSWORD" && key != "OPENCODE_SERVER_PASSWORD"
            }
        }
    }

    // MARK: Database Path (`packages/cli/src/database-path.ts`)

    // parity: cli/src/database-path.ts#databasePath [status=implemented hash=38c20bc37675]
    public static func databasePath(
        _ data: String,
        channel: String = CLIContext.current.channel,
        environment: any EnvironmentProviding = CLIContext.current.environment
    ) -> String {
        let filename: String
        if let explicit = environment.variable("OPENCODE_DB") {
            filename = explicit
        } else {
            let standardChannels: Set<String> = ["latest", "dev", "beta", "next", "prod"]
            let disableChannelDB = environment.variable("OPENCODE_DISABLE_CHANNEL_DB")
            if standardChannels.contains(channel) || disableChannelDB == "1" || disableChannelDB == "true" {
                filename = "opencode.db"
            } else {
                let sanitized = sanitizeChannelSegment(channel)
                filename = "opencode-\(sanitized).db"
            }
        }
        if filename == ":memory:" {
            return filename
        }
        return CLIPath.resolve(data, filename)
    }

    internal static func sanitizeChannelSegment(_ channel: String) -> String {
        var out = ""
        out.reserveCapacity(channel.utf16.count)
        for unit in channel.utf16 {
            let allowed = (unit >= 0x30 && unit <= 0x39) // 0-9
                || (unit >= 0x41 && unit <= 0x5A) // A-Z
                || (unit >= 0x61 && unit <= 0x7A) // a-z
                || unit == 0x2E || unit == 0x5F || unit == 0x2D // . _ -
            if allowed, let scalar = UnicodeScalar(unit) {
                out.unicodeScalars.append(scalar)
            } else {
                out.append("-")
            }
        }
        return out
    }

    // MARK: Stdin I/O (`packages/cli/src/util/io.ts`)

    // parity: cli/src/util/io.ts#readStdin [status=implemented hash=6ec94715baec]
    public static func readStdin(context: CLIContext = CLIContext.current) async throws -> String {
        try await context.io.readStdinAll()
    }

    /// Reads a shell pipe or redirected file in full; non-FIFO/non-file descriptors (e.g. spawn sockets)
    /// are read only if readable within `graceMs` milliseconds, otherwise skipped.
    // parity: cli/src/util/io.ts#readStdinIfReady [status=adapted hash=d492d05dc87a]
    public static func readStdinIfReady(
        grace graceMs: Int,
        context: CLIContext = CLIContext.current
    ) async throws -> String? {
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        if !(context.io.isStdinTTY()) {
            // For mock/buffered contexts (non-system), return stdin immediately if non-empty.
            if context.environment is DictionaryEnvironment {
                let text = try await context.io.readStdinAll()
                return text.isEmpty ? nil : text
            }
            var st = stat()
            if fstat(STDIN_FILENO, &st) == 0 {
                let mode = st.st_mode & S_IFMT
                if mode == S_IFIFO || mode == S_IFREG {
                    return try await readStdin(context: context)
                }
            }
            var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, Int32(max(0, graceMs)))
            if ready > 0 {
                return try await readStdin(context: context)
            }
            return nil
        }
        return nil
        #else
        _ = graceMs
        let text = try await context.io.readStdinAll()
        return text.isEmpty ? nil : text
        #endif
    }

    // MARK: Self-Reexec Command (`packages/cli/src/util/process.ts`)

    // parity: cli/src/util/process.ts#selfCommand [status=implemented hash=6a8bb8a2d78b]
    public static func selfCommand(
        execPath: String? = nil,
        entrypoint: String? = nil,
        execArgv: [String] = []
    ) throws -> [String] {
        let resolvedExec = execPath ?? CLIContext.current.executablePath
        let runtime = CLIPath.basename(resolvedExec, dropExtension: true).lowercased()
        if runtime != "bun" && runtime != "node" && runtime != "nodejs" {
            return [resolvedExec]
        }
        guard let entrypoint, !entrypoint.isEmpty else {
            throw CLIError("Failed to resolve CLI entrypoint")
        }
        if runtime == "node" || runtime == "nodejs" {
            return [resolvedExec] + filterNodeFlags(execArgv) + [entrypoint]
        }
        return [resolvedExec, entrypoint]
    }

    private static func filterNodeFlags(_ args: [String]) -> [String] {
        var result: [String] = []
        for (index, arg) in args.enumerated() {
            if index > 0 && args[index - 1] == "--conditions" { continue }
            if arg == "--conditions" {
                if index + 1 < args.count {
                    result.append(arg)
                    result.append(args[index + 1])
                }
                continue
            }
            if arg.hasPrefix("--conditions=") {
                result.append(arg)
                continue
            }
            if arg == "--experimental-ffi"
                || arg == "--use-system-ca"
                || arg == "--enable-source-maps"
                || arg == "--no-addons"
                || arg == "--no-warnings"
                || arg.hasPrefix("--disable-warning=")
            {
                result.append(arg)
            }
        }
        return result
    }

    // MARK: Shutdown Deadline (`packages/cli/src/shutdown-deadline.ts`)

    public enum ShutdownDeadline {
        public struct Guard: Sendable {
            private let teardownFn: @Sendable () -> Void
            private let triggerFn: @Sendable (String) -> String?

            public init(
                teardown: @escaping @Sendable () -> Void,
                trigger: @escaping @Sendable (String) -> String?
            ) {
                self.teardownFn = teardown
                self.triggerFn = trigger
            }

            public func release() { teardownFn() }

            @discardableResult
            public func handleSignal(_ signal: String) -> String? { triggerFn(signal) }
        }

        /// After SIGTERM or SIGINT, teardown gets 10 seconds before reporting stuck tasks and exiting.
        // parity: cli/src/shutdown-deadline.ts#DEADLINE [status=implemented hash=5d58a5e06257]
        public static let DEADLINE: Duration = .seconds(10)

        /// Installs a bounded signal teardown guard matching `ShutdownDeadline.install`.
        // parity: cli/src/shutdown-deadline.ts#install [status=adapted hash=8e000542ea49]
        public static func install(
            _ deadline: Duration = DEADLINE,
            _ context: CLIContext = CLIContext.current,
            _ onExit: (@Sendable (Int32) -> Void)? = nil
        ) -> Guard {
            let state = Mutex(false)
            let exitCallback: @Sendable (Int32) -> Void = onExit ?? { code in
                #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
                _exit(code)
                #else
                _ = code
                #endif
            }
            let formatReport: @Sendable (String, [Teardown.PendingEntry]) -> String = { reason, pending in
                var lines: [String] = ["\(reason); exiting. Still pending:"]
                if pending.isEmpty {
                    lines.append("  nothing tracked; the stuck finalizer is outside any LayerNode layer")
                } else {
                    for item in pending {
                        let secs = String(format: "%.1f", Double(item.ms) / 1_000.0)
                        lines.append("  \(secs)s  \(item.label)")
                    }
                }
                lines.append("")
                return lines.joined(separator: "\n")
            }

            let onSignal: @Sendable (String) -> String? = { signal in
                let alreadyStarted = state.withLock { started -> Bool in
                    if started { return true }
                    started = true
                    return false
                }
                if alreadyStarted {
                    let message = formatReport("received \(signal) again during shutdown", Teardown.pending())
                    context.io.writeStderr(message)
                    exitCallback(1)
                    return message
                }
                Task.detached {
                    try? await Task.sleep(for: deadline)
                    let pending = Teardown.pending()
                    let seconds = deadline.components.seconds
                    let message = formatReport("shutdown did not finish within \(seconds)s", pending)
                    context.io.writeStderr(message)
                    try? await Task.sleep(for: .milliseconds(1_500))
                    exitCallback(1)
                }
                return nil
            }

            let unsubTerm = ProcessSignal.subscribe(signal: "SIGTERM") { _ = onSignal("SIGTERM") }
            let unsubInt = ProcessSignal.subscribe(signal: "SIGINT") { _ = onSignal("SIGINT") }
            let hangup = context.io.isStdinTTY() || context.io.isStdoutTTY()
            let unsubHup: @Sendable () -> Void
            if hangup {
                unsubHup = ProcessSignal.subscribe(signal: "SIGHUP") { _ = onSignal("SIGTERM") }
            } else {
                unsubHup = {}
            }

            return Guard(
                teardown: {
                    let started = state.withLock { $0 }
                    if !started {
                        unsubTerm()
                        unsubInt()
                        unsubHup()
                    }
                },
                trigger: onSignal
            )
        }
    }

    // MARK: Signal-Triggered CPU Profiler (`packages/cli/src/cpu-profile.ts`)

    public enum CpuProfile {
        public struct Listener: Sendable {
            private let stopFn: @Sendable () -> Void
            private let triggerFn: @Sendable () async -> String?

            public init(stop: @escaping @Sendable () -> Void, trigger: @escaping @Sendable () async -> String?) {
                self.stopFn = stop
                self.triggerFn = trigger
            }

            public func stop() { stopFn() }
            public func captureNow() async -> String? { await triggerFn() }
        }

        /// Listens for `SIGPROF` on non-Windows hosts and writes a diagnostic `.cpuprofile` to `global.log`.
        // parity: cli/src/cpu-profile.ts#listen [status=adapted hash=76fa74adaa8a]
        public static let listen: @Sendable (CLIContext) -> Listener = { context in
            if context.platformOS == .windows {
                return Listener(stop: {}, trigger: { nil })
            }
            let active = Mutex(false)
            let capture: @Sendable () async -> String? = {
                let acquired = active.withLock { running -> Bool in
                    if running { return false }
                    running = true
                    return true
                }
                guard acquired else { return nil }
                defer { active.withLock { $0 = false } }
                let logDir = context.globalPaths.log
                let stamp = ISO8601DateFormatter().string(from: Date())
                    .replacing(":", with: "")
                    .replacing(".", with: "")
                let file = CLIPath.join(logDir, "cpu-\(context.currentPID)-\(stamp).cpuprofile")
                let payload = "{\"nodes\":[],\"startTime\":0,\"endTime\":0,\"runtime\":\"swift\"}\n"
                do {
                    try await context.fileSystem.makeDirectory(at: logDir, recursive: true)
                    try await context.fileSystem.writeFile(Array(payload.utf8), to: file, createDirectories: true)
                    return file
                } catch {
                    return nil
                }
            }
            let unsub = ProcessSignal.subscribe(signal: "SIGPROF") {
                Task.detached { _ = await capture() }
            }
            return Listener(stop: unsub, trigger: capture)
        }
    }

    // MARK: Signal-Triggered Heap Snapshot (`packages/cli/src/heap.ts`)

    public enum Heap {
        public struct Listener: Sendable {
            private let stopFn: @Sendable () -> Void
            private let triggerFn: @Sendable () async -> HeapSnapshot.Result?

            public init(stop: @escaping @Sendable () -> Void, trigger: @escaping @Sendable () async -> HeapSnapshot.Result?) {
                self.stopFn = stop
                self.triggerFn = trigger
            }

            public func stop() { stopFn() }
            public func captureNow() async -> HeapSnapshot.Result? { await triggerFn() }
        }

        /// Listens for `SIGUSR1` on non-Windows hosts and writes a heap snapshot to `global.log`.
        // parity: cli/src/heap.ts#listen [status=adapted hash=c3b81f289dbf]
        public static let listen: @Sendable (CLIContext) -> Listener = { context in
            if context.platformOS == .windows {
                return Listener(stop: {}, trigger: { nil })
            }
            let busy = Mutex(false)
            let capture: @Sendable () async -> HeapSnapshot.Result? = {
                let acquired = busy.withLock { state -> Bool in
                    if state { return false }
                    state = true
                    return true
                }
                guard acquired else { return nil }
                defer { busy.withLock { $0 = false } }
                return try? await HeapSnapshot.write(directory: context.globalPaths.log, fileSystem: context.fileSystem)
            }
            let unsub = ProcessSignal.subscribe(signal: "SIGUSR1") {
                Task.detached { _ = await capture() }
            }
            return Listener(stop: unsub, trigger: capture)
        }
    }

    // MARK: SSH Askpass Helper (`packages/cli/src/ssh-askpass.ts`)

    public enum SSHAskpass {
        public struct RequestPayload: Equatable, Hashable, Sendable, Codable {
            public let token: String?
            public let text: String
            public let confirm: Bool

            public init(token: String?, text: String, confirm: Bool) {
                self.token = token
                self.text = text
                self.confirm = confirm
            }
        }

        public struct ResponsePayload: Equatable, Hashable, Sendable, Codable {
            public let value: String?

            public init(value: String?) {
                self.value = value
            }
        }

        public typealias Exchange = @Sendable (_ port: Int, _ payload: String) async throws -> String

        /// OpenSSH askpass IPC protocol over loopback TCP (`127.0.0.1:OPENCODE_SSH_ASKPASS_PORT`).
        // parity: cli/src/ssh-askpass.ts#askpass [status=adapted hash=49cb3ff1263b]
        public static let askpass: @Sendable (CLIContext, Exchange?) async -> Int32 = { context, customExchange in
            guard let portStr = context.envVariable("OPENCODE_SSH_ASKPASS_PORT"),
                  let port = Int(portStr),
                  port > 0, port <= 65_535
            else {
                return 1
            }

            let req = RequestPayload(
                token: context.envVariable("OPENCODE_SSH_ASKPASS_TOKEN"),
                text: context.rawArguments.joined(separator: " "),
                confirm: context.envVariable("SSH_ASKPASS_PROMPT") == "confirm"
            )
            guard let jsonLine = try? CLIPath.encodeCompactJSON(req) else {
                return 1
            }

            let exchange: Exchange = customExchange ?? defaultLoopbackExchange
            do {
                let rawResponse = try await exchange(port, jsonLine + "\n")
                let decoded = try JSONDecoder().decode(ResponsePayload.self, from: Data(rawResponse.utf8))
                guard let value = decoded.value else {
                    return 1
                }
                context.io.writeStdout(value + "\n")
                return 0
            } catch {
                return 1
            }
        }

        private static let defaultLoopbackExchange: Exchange = { port, payload in
            #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
            #if canImport(Darwin)
            let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            #elseif canImport(Glibc)
            let fd = Glibc.socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
            #else
            let fd = Musl.socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
            #endif
            guard fd >= 0 else { throw CLIError("Failed to open askpass socket") }
            defer { close(fd) }

            var addr = sockaddr_in()
            #if canImport(Darwin)
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            #endif
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = UInt16(port).bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")

            let connected = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard connected == 0 else { throw CLIError("Failed to connect to askpass server on port \(port)") }

            let bytes = Array(payload.utf8)
            var sent = 0
            while sent < bytes.count {
                let n = bytes.withUnsafeBytes { buf -> Int in
                    guard let base = buf.baseAddress else { return 0 }
                    return send(fd, base.advanced(by: sent), bytes.count - sent, 0)
                }
                if n <= 0 { throw CLIError("Failed to write askpass request") }
                sent += n
            }

            var received: [UInt8] = []
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = recv(fd, &buffer, buffer.count, 0)
                if n > 0 {
                    received.append(contentsOf: buffer[0..<n])
                } else {
                    break
                }
            }
            return String(decoding: received, as: UTF8.self)
            #else
            _ = (port, payload)
            throw CLIError("SSH askpass sockets are unsupported on \(Platform.current.rawValue)")
            #endif
        }
    }

    // MARK: Embedded Web UI Binary Archive (`packages/cli/src/app-archive.ts`)

    public enum AppArchive {
        /// Encodes `(key, bytes)` entries into `[u32le indexByteLength][UTF-8 JSON index][raw body bytes]`.
        // parity: cli/src/app-archive.ts#encode [status=implemented hash=4b415be858b7]
        public static func encode(_ entries: [(String, [UInt8])]) throws -> [UInt8] {
            var index: [String: [Int]] = [:]
            var offset = 0
            var totalBody = 0
            for (key, body) in entries {
                index[key] = [offset, body.count]
                offset += body.count
                totalBody += body.count
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let indexData = try encoder.encode(index)
            let indexBytes = Array(indexData)
            let len = UInt32(indexBytes.count)
            var result: [UInt8] = []
            result.reserveCapacity(4 + indexBytes.count + totalBody)
            result.append(UInt8(len & 0xFF))
            result.append(UInt8((len >> 8) & 0xFF))
            result.append(UInt8((len >> 16) & 0xFF))
            result.append(UInt8((len >> 24) & 0xFF))
            result.append(contentsOf: indexBytes)
            for (_, body) in entries {
                result.append(contentsOf: body)
            }
            return result
        }

        /// Decodes an archive created by `encode(_:)` back into a dictionary of asset bytes.
        // parity: cli/src/app-archive.ts#decode [status=implemented hash=cf019414d124]
        public static func decode(_ archive: [UInt8]) throws -> [String: [UInt8]] {
            guard archive.count >= 4 else {
                throw CLIError("Invalid app archive: truncated header")
            }
            let length = Int(UInt32(archive[0])
                | (UInt32(archive[1]) << 8)
                | (UInt32(archive[2]) << 16)
                | (UInt32(archive[3]) << 24))
            let bodyStart = 4 + length
            guard bodyStart <= archive.count else {
                throw CLIError("Invalid app archive: index exceeds archive length")
            }
            let indexSlice = Data(archive[4..<bodyStart])
            let index = try JSONDecoder().decode([String: [Int]].self, from: indexSlice)
            var out: [String: [UInt8]] = [:]
            out.reserveCapacity(index.count)
            for (key, pair) in index {
                guard pair.count == 2 else {
                    throw CLIError("Invalid app archive index entry for \(key)")
                }
                let start = bodyStart + pair[0]
                let end = start + pair[1]
                guard pair[0] >= 0, pair[1] >= 0, end <= archive.count else {
                    throw CLIError("Invalid app archive bounds for \(key)")
                }
                out[key] = Array(archive[start..<end])
            }
            return out
        }
    }

    // MARK: Web UI Assets Loader (`packages/cli/src/app-assets.ts`)

    public enum AppAssets {
        public enum AssetContent: Equatable, Sendable {
            case text(String)
            case binary([UInt8])

            public var utf8String: String {
                switch self {
                case .text(let str): return str
                case .binary(let bytes): return String(decoding: bytes, as: UTF8.self)
                }
            }

            public var bytes: [UInt8] {
                switch self {
                case .text(let str): return Array(str.utf8)
                case .binary(let bytes): return bytes
                }
            }
        }

        // parity: cli/src/app-assets.ts#AssetMap [status=implemented hash=b1bd55cce0fd]
        public typealias AssetMap = [String: AssetContent]

        /// Each asset's brotli-compressed bytes, when the build embedded them.
        // parity: cli/src/app-assets.ts#BrotliMap [status=implemented hash=1dfb2477b049]
        public typealias BrotliMap = [String: [UInt8]]

        public struct LoadedAssets: Equatable, Sendable {
            public let files: AssetMap
            public let brotli: BrotliMap?

            public init(files: AssetMap, brotli: BrotliMap? = nil) {
                self.files = files
                self.brotli = brotli
            }
        }

        /// Loads Web UI assets from an embedded archive or local source directory.
        // parity: cli/src/app-assets.ts#load [status=adapted hash=684800d52b7e]
        public static func load(
            embeddedArchive: [UInt8]? = nil,
            decompress: (@Sendable ([UInt8]) throws -> [UInt8])? = nil,
            sourceRoot: String? = nil,
            isLocal: Bool = Version.OPENCODE_LOCAL,
            fileSystem: any OpenCodeFileSystem = CLIContext.current.fileSystem
        ) async throws -> LoadedAssets {
            if let embeddedArchive {
                let decoded = try AppArchive.decode(embeddedArchive)
                if !decoded.isEmpty || !isLocal {
                    var files: AssetMap = [:]
                    for (key, compressed) in decoded {
                        let raw = try decompress?(compressed) ?? compressed
                        files[key] = isTextAsset(key)
                            ? .text(String(decoding: raw, as: UTF8.self))
                            : .binary(raw)
                    }
                    return LoadedAssets(files: files, brotli: decoded)
                }
            }
            if !isLocal {
                throw CLIError("Web UI assets are missing from the CLI build")
            }
            guard let sourceRoot, await fileSystem.exists(at: sourceRoot) else {
                return LoadedAssets(files: [:], brotli: nil)
            }
            var files: AssetMap = [:]
            try await collectSourceAssets(root: sourceRoot, relative: "", fileSystem: fileSystem, into: &files)
            return LoadedAssets(files: files, brotli: nil)
        }

        private static func collectSourceAssets(
            root: String,
            relative: String,
            fileSystem: any OpenCodeFileSystem,
            into out: inout AssetMap
        ) async throws {
            let dir = relative.isEmpty ? root : CLIPath.join(root, relative)
            let entries = try await fileSystem.readDirectory(at: dir)
            for entry in entries {
                let rel = relative.isEmpty ? entry : "\(relative)/\(entry)"
                let full = CLIPath.join(root, rel)
                if let info = try? await fileSystem.stat(at: full), info.type == .directory {
                    try await collectSourceAssets(root: root, relative: rel, fileSystem: fileSystem, into: &out)
                    continue
                }
                if rel.hasSuffix(".map") { continue }
                let bytes = try await fileSystem.readFile(at: full)
                out[rel] = isTextAsset(rel) ? .text(String(decoding: bytes, as: UTF8.self)) : .binary(bytes)
            }
        }

        internal static func isTextAsset(_ file: String) -> Bool {
            if file == "_headers" { return true }
            let lower = file.lowercased()
            let suffixes = [".css", ".html", ".js", ".json", ".svg", ".txt", ".webmanifest", ".xml"]
            return suffixes.contains { lower.hasSuffix($0) }
        }
    }

    // MARK: Node Executable Targets & Packaging Metadata (`packages/cli/src/node/target.ts`)

    public enum Node {
        // parity: cli/src/node/target.ts#NodeTarget [status=implemented hash=07d87e603e68]
        public struct NodeTarget: Equatable, Hashable, Sendable, Codable {
            public let platform: String
            public let arch: String
            public let nodePtyPackage: String
            public let nodePtyEntryAsset: String
            public let parcelWatcherPackage: String
            public let parcelWatcherAsset: String
            public let fffPackage: String
            public let fffAsset: String
            public let fffFfiPackage: String
            public let fffFfiAsset: String
            public let opencodePtyAsset: String

            public init(
                platform: String,
                arch: String,
                nodePtyPackage: String,
                nodePtyEntryAsset: String,
                parcelWatcherPackage: String,
                parcelWatcherAsset: String,
                fffPackage: String,
                fffAsset: String,
                fffFfiPackage: String,
                fffFfiAsset: String,
                opencodePtyAsset: String
            ) {
                self.platform = platform
                self.arch = arch
                self.nodePtyPackage = nodePtyPackage
                self.nodePtyEntryAsset = nodePtyEntryAsset
                self.parcelWatcherPackage = parcelWatcherPackage
                self.parcelWatcherAsset = parcelWatcherAsset
                self.fffPackage = fffPackage
                self.fffAsset = fffAsset
                self.fffFfiPackage = fffFfiPackage
                self.fffFfiAsset = fffFfiAsset
                self.opencodePtyAsset = opencodePtyAsset
            }
        }

        // parity: cli/src/node/target.ts#nodeTarget [status=implemented hash=7386b4c99192]
        public static func nodeTarget(platform: String, arch: String) throws -> NodeTarget {
            let validPlatforms: Set<String> = ["darwin", "linux", "win32"]
            guard validPlatforms.contains(platform), (arch == "arm64" || arch == "x64") else {
                throw CLIError("Unsupported Node executable target: \(platform)-\(arch)")
            }
            let nodePtyPackage = "@lydell/node-pty-\(platform)-\(arch)"
            let parcelWatcherPackage = "@parcel/watcher-\(platform)-\(arch)\(platform == "linux" ? "-glibc" : "")"
            let fffPackage = "@ff-labs/fff-bin-\(platform)-\(arch)\(platform == "linux" ? "-gnu" : "")"
            let fffFfiSuffix = platform == "linux" ? "-gnu" : (platform == "win32" ? "-msvc" : "")
            let fffFfiPackage = "@yuuang/ffi-rs-\(platform)-\(arch)\(fffFfiSuffix)"
            let fffLib = platform == "darwin" ? "libfff_c.dylib" : (platform == "win32" ? "fff_c.dll" : "libfff_c.so")
            let opencodePtyAsset = platform == "win32" ? "opencode-pty/opencode-pty.exe" : "opencode-pty/opencode-pty"

            return NodeTarget(
                platform: platform,
                arch: arch,
                nodePtyPackage: nodePtyPackage,
                nodePtyEntryAsset: "\(nodePtyPackage)/lib/index.js",
                parcelWatcherPackage: parcelWatcherPackage,
                parcelWatcherAsset: "\(parcelWatcherPackage)/watcher.node",
                fffPackage: fffPackage,
                fffAsset: "\(fffPackage)/\(fffLib)",
                fffFfiPackage: fffFfiPackage,
                fffFfiAsset: "\(fffFfiPackage)/ffi-rs.\(platform)-\(arch)\(fffFfiSuffix).node",
                opencodePtyAsset: opencodePtyAsset
            )
        }

        // parity: cli/src/node/target.ts#photonWasmAsset [status=implemented hash=d7f606e8eb21]
        public static let photonWasmAsset = "@silvia-odwyer/photon-node/photon_rs_bg.wasm"

        // parity: cli/src/node/target.ts#nodeExecArgv [status=implemented hash=6f3146ed324b]
        public static let nodeExecArgv: [String] = [
            "--experimental-ffi",
            "--use-system-ca",
            "--disable-warning=ExperimentalWarning",
        ]

        // parity: cli/src/node/target.ts#attentionSoundAssets [status=implemented hash=869eba978538]
        public static let attentionSoundAssets: [String] = [
            "@opencode/ui/audio/bip-bop-01.mp3",
            "@opencode/ui/audio/bip-bop-03.mp3",
            "@opencode/ui/audio/staplebops-06.mp3",
            "@opencode/ui/audio/nope-03.mp3",
            "@opencode/ui/audio/yup-01.mp3",
        ]
    }
}

// MARK: - CLI Command Framework (`packages/cli/src/framework/*`)

public enum CLIFramework {
    // MARK: Flag Specifications (`packages/cli/src/framework/flag.ts`)

    public enum Flag {
        /// Value parsed for an optional-value flag (`--name` or `--name=` -> `.flagOnly`, `--name=value` -> `.value(value)`).
        public enum OptionalValue: Equatable, Hashable, Sendable {
            case flagOnly
            case value(String)

            public var stringValue: String? {
                if case .value(let s) = self { return s }
                return nil
            }
        }

        public enum Kind: Equatable, Hashable, Sendable {
            case boolean(defaultValue: Bool?)
            case string(optional: Bool, literals: [String]?, nonEmpty: Bool)
            case integer(optional: Bool, defaultValue: Int?, min: Int?, max: Int?)
            case repeatedString(maxCount: Int?)
            case keyValuePair
            case optionalValue(metavar: String)
        }

        public struct Definition: Equatable, Hashable, Sendable {
            public let name: String
            public let alias: String?
            public let description: String?
            public let hidden: Bool
            public let kind: Kind

            public init(
                name: String,
                alias: String? = nil,
                description: String? = nil,
                hidden: Bool = false,
                kind: Kind
            ) {
                self.name = name
                self.alias = alias
                self.description = description
                self.hidden = hidden
                self.kind = kind
            }

            public func withAlias(_ alias: String) -> Definition {
                Definition(name: name, alias: alias, description: description, hidden: hidden, kind: kind)
            }

            public func withDescription(_ description: String) -> Definition {
                Definition(name: name, alias: alias, description: description, hidden: hidden, kind: kind)
            }

            public func withHidden(_ hidden: Bool = true) -> Definition {
                Definition(name: name, alias: alias, description: description, hidden: hidden, kind: kind)
            }
        }

        public struct GlobalDefinition: Equatable, Hashable, Sendable {
            public let id: String
            public let flag: Definition

            public init(id: String, flag: Definition) {
                self.id = id
                self.flag = flag
            }
        }

        public struct ArgumentDefinition: Equatable, Hashable, Sendable {
            public let name: String
            public let description: String?
            public let optional: Bool
            public let variadicMin: Int?
            public let variadicMax: Int?
            public let literals: [String]?

            public init(
                name: String,
                description: String? = nil,
                optional: Bool = false,
                variadicMin: Int? = nil,
                variadicMax: Int? = nil,
                literals: [String]? = nil
            ) {
                self.name = name
                self.description = description
                self.optional = optional
                self.variadicMin = variadicMin
                self.variadicMax = variadicMax
                self.literals = literals
            }
        }

        /// `--name` and `--name=` parse as `true`, `--name=value` as the value; never consumes the next positional argument.
        // parity: cli/src/framework/flag.ts#optionalValue [status=implemented hash=5a496378eec2]
        public static func optionalValue(_ name: String, metavar: String) -> Definition {
            Definition(name: name, kind: .optionalValue(metavar: metavar))
        }

        public static func boolean(_ name: String, default defaultValue: Bool? = false, alias: String? = nil, description: String? = nil, hidden: Bool = false) -> Definition {
            Definition(name: name, alias: alias, description: description, hidden: hidden, kind: .boolean(defaultValue: defaultValue))
        }

        public static func string(_ name: String, optional: Bool = true, alias: String? = nil, description: String? = nil, nonEmpty: Bool = false) -> Definition {
            Definition(name: name, alias: alias, description: description, kind: .string(optional: optional, literals: nil, nonEmpty: nonEmpty))
        }

        public static func literals(_ name: String, _ values: [String], optional: Bool = true, alias: String? = nil, description: String? = nil) -> Definition {
            Definition(name: name, alias: alias, description: description, kind: .string(optional: optional, literals: values, nonEmpty: true))
        }

        public static func integer(_ name: String, optional: Bool = true, default defaultValue: Int? = nil, min: Int? = nil, max: Int? = nil, alias: String? = nil, description: String? = nil) -> Definition {
            Definition(name: name, alias: alias, description: description, kind: .integer(optional: optional, defaultValue: defaultValue, min: min, max: max))
        }

        public static func repeatedString(_ name: String, maxCount: Int? = nil, alias: String? = nil, description: String? = nil) -> Definition {
            Definition(name: name, alias: alias, description: description, kind: .repeatedString(maxCount: maxCount))
        }

        public static func keyValuePair(_ name: String, alias: String? = nil, description: String? = nil) -> Definition {
            Definition(name: name, alias: alias, description: description, kind: .keyValuePair)
        }
    }

    // MARK: Command Specification Tree (`packages/cli/src/framework/spec.ts`)

    public enum Spec {
        public struct Options: Sendable {
            public let description: String?
            public let aliases: [String]
            /// Hidden commands still parse, but stay out of parent help, completions and typo suggestions.
            public let hidden: Bool
            public let flags: [Flag.Definition]
            public let arguments: [Flag.ArgumentDefinition]
            public let globalFlags: [Flag.GlobalDefinition]
            public let commands: [CommandNode]

            public init(
                description: String? = nil,
                aliases: [String] = [],
                hidden: Bool = false,
                flags: [Flag.Definition] = [],
                arguments: [Flag.ArgumentDefinition] = [],
                globalFlags: [Flag.GlobalDefinition] = [],
                commands: [CommandNode] = []
            ) {
                self.description = description
                self.aliases = aliases
                self.hidden = hidden
                self.flags = flags
                self.arguments = arguments
                self.globalFlags = globalFlags
                self.commands = commands
            }
        }

        // parity: cli/src/framework/spec.ts#Node [status=implemented hash=d8d508df50a9]
        public protocol Node: Sendable {
            var name: String { get }
            var description: String? { get }
            var primaryAlias: String? { get }
            var hidden: Bool { get }
            var flags: [Flag.Definition] { get }
            var arguments: [Flag.ArgumentDefinition] { get }
            var globalFlags: [Flag.GlobalDefinition] { get }
            var commands: Children { get }
            var orderedCommands: [CommandNode] { get }
            var aliases: [CommandNode] { get }
        }

        // parity: cli/src/framework/spec.ts#Any [status=implemented hash=e5558186f67b]
        public typealias AnyNode = CommandNode

        // parity: cli/src/framework/spec.ts#Children [status=implemented hash=c0fbb5bf762e]
        public typealias Children = [String: CommandNode]

        public struct CommandNode: Node, Equatable, Sendable {
            public let name: String
            public let description: String?
            public let primaryAlias: String?
            public let hidden: Bool
            public let flags: [Flag.Definition]
            public let arguments: [Flag.ArgumentDefinition]
            public let globalFlags: [Flag.GlobalDefinition]
            public let commands: Children
            public let orderedCommands: [CommandNode]
            public let aliases: [CommandNode]

            public init(
                name: String,
                description: String? = nil,
                primaryAlias: String? = nil,
                hidden: Bool = false,
                flags: [Flag.Definition] = [],
                arguments: [Flag.ArgumentDefinition] = [],
                globalFlags: [Flag.GlobalDefinition] = [],
                orderedCommands: [CommandNode] = [],
                aliases: [CommandNode] = []
            ) {
                self.name = name
                self.description = description
                self.primaryAlias = primaryAlias
                self.hidden = hidden
                self.flags = flags
                self.arguments = arguments
                self.globalFlags = globalFlags
                self.orderedCommands = orderedCommands
                var map: Children = [:]
                for child in orderedCommands {
                    map[child.name] = child
                }
                self.commands = map
                self.aliases = aliases
            }
        }

        // parity: cli/src/framework/spec.ts#make [status=implemented hash=0bab1b86ba8d]
        public static func make(_ name: String, options: Options = Options()) -> CommandNode {
            let primary = options.aliases.first
            let extraAliases: [CommandNode] = options.aliases.dropFirst().map { alias in
                CommandNode(
                    name: alias,
                    description: options.description,
                    primaryAlias: nil,
                    hidden: options.hidden,
                    flags: options.flags,
                    arguments: options.arguments,
                    globalFlags: options.globalFlags,
                    orderedCommands: options.commands,
                    aliases: []
                )
            }
            return CommandNode(
                name: name,
                description: options.description,
                primaryAlias: primary,
                hidden: options.hidden,
                flags: options.flags,
                arguments: options.arguments,
                globalFlags: options.globalFlags,
                orderedCommands: options.commands,
                aliases: extraAliases
            )
        }
    }

    // MARK: Parsed Input, Handler Registry & Execution Runtime (`packages/cli/src/framework/runtime.ts`)

    public enum Runtime {
        /// Mirrors Effect CLI's `CliError.ShowHelp`: prints command help and optional validation errors with exit code 1.
        public struct ShowHelpError: Error, Equatable, Sendable {
            public let commandPath: [String]
            public let errors: [String]

            public init(commandPath: [String] = [], errors: [String] = []) {
                self.commandPath = commandPath
                self.errors = errors
            }
        }

        /// Parsed invocation payload handed to command handlers.
        // parity: cli/src/framework/runtime.ts#Input [status=adapted hash=89f37cb5e32d]
        public struct Input: Equatable, Sendable {
            public let commandPath: [String]
            public let booleans: [String: Bool]
            public let strings: [String: String]
            public let integers: [String: Int]
            public let repeatedStrings: [String: [String]]
            public let keyValues: [String: [String: String]]
            public let optionalValues: [String: Flag.OptionalValue]
            public let positionals: [String]
            public let namedArguments: [String: [String]]
            public let passthrough: [String]
            public let globalFlags: CLIGlobalFlagValues

            public init(
                commandPath: [String] = [],
                booleans: [String: Bool] = [:],
                strings: [String: String] = [:],
                integers: [String: Int] = [:],
                repeatedStrings: [String: [String]] = [:],
                keyValues: [String: [String: String]] = [:],
                optionalValues: [String: Flag.OptionalValue] = [:],
                positionals: [String] = [],
                namedArguments: [String: [String]] = [:],
                passthrough: [String] = [],
                globalFlags: CLIGlobalFlagValues = CLIGlobalFlagValues()
            ) {
                self.commandPath = commandPath
                self.booleans = booleans
                self.strings = strings
                self.integers = integers
                self.repeatedStrings = repeatedStrings
                self.keyValues = keyValues
                self.optionalValues = optionalValues
                self.positionals = positionals
                self.namedArguments = namedArguments
                self.passthrough = passthrough
                self.globalFlags = globalFlags
            }

            public func bool(_ name: String, default fallback: Bool = false) -> Bool {
                booleans[name] ?? fallback
            }

            public func optionalBool(_ name: String) -> Bool? {
                booleans[name]
            }

            public func string(_ name: String) -> String? {
                strings[name]
            }

            public func integer(_ name: String) -> Int? {
                integers[name]
            }

            public func stringsList(_ name: String) -> [String] {
                repeatedStrings[name] ?? []
            }

            public func keyValueMap(_ name: String) -> [String: String]? {
                keyValues[name]
            }

            public func optionalFlag(_ name: String) -> Flag.OptionalValue? {
                optionalValues[name]
            }

            public func arg(_ name: String) -> String? {
                namedArguments[name]?.first
            }

            public func args(_ name: String) -> [String] {
                namedArguments[name] ?? []
            }
        }

        public typealias HandlerFn = @Sendable (Input, CLIContext) async throws -> Void
        public typealias LazyLoader = @Sendable () async -> HandlerFn

        /// Hierarchical command handler registration map mirroring `Runtime.Handlers<Node>`.
        // parity: cli/src/framework/runtime.ts#Handlers [status=adapted hash=070ea0bfed78]
        public indirect enum Handlers: Sendable {
            case leaf(LazyLoader)
            case branch(selfHandler: LazyLoader?, children: [String: Handlers])

            public static func sync(_ fn: @escaping HandlerFn) -> Handlers {
                .leaf { fn }
            }
        }

        public struct BoundHandler: Sendable {
            public let path: [String]
            public let load: LazyLoader

            public init(path: [String], load: @escaping LazyLoader) {
                self.path = path
                self.load = load
            }
        }

        public struct RunOptions: Equatable, Sendable {
            public let version: String
            public let globalFlags: [Flag.GlobalDefinition]

            public init(version: String, globalFlags: [Flag.GlobalDefinition] = []) {
                self.version = version
                self.globalFlags = globalFlags
            }
        }

        // parity: cli/src/framework/runtime.ts#handler [status=adapted hash=e4a9d64b68ed]
        public static func handler(
            _ node: Spec.CommandNode,
            _ execute: @escaping HandlerFn
        ) -> HandlerFn {
            _ = node
            return execute
        }

        // parity: cli/src/framework/runtime.ts#handlers [status=adapted hash=c7b27375c656]
        public static func handlers(
            _ root: Spec.CommandNode,
            _ tree: Handlers
        ) -> [BoundHandler] {
            var result: [BoundHandler] = []
            func bind(node: Spec.CommandNode, path: [String], entry: Handlers) {
                switch entry {
                case .leaf(let loader):
                    result.append(BoundHandler(path: path, load: loader))
                    if let primary = node.primaryAlias, !path.isEmpty {
                        var aliasPath = path
                        aliasPath[aliasPath.count - 1] = primary
                        result.append(BoundHandler(path: aliasPath, load: loader))
                    }
                    for alias in node.aliases where !path.isEmpty {
                        var aliasPath = path
                        aliasPath[aliasPath.count - 1] = alias.name
                        result.append(BoundHandler(path: aliasPath, load: loader))
                    }
                case .branch(let selfLoader, let children):
                    if let selfLoader {
                        result.append(BoundHandler(path: path, load: selfLoader))
                        if let primary = node.primaryAlias, !path.isEmpty {
                            var aliasPath = path
                            aliasPath[aliasPath.count - 1] = primary
                            result.append(BoundHandler(path: aliasPath, load: selfLoader))
                        }
                        for alias in node.aliases where !path.isEmpty {
                            var aliasPath = path
                            aliasPath[aliasPath.count - 1] = alias.name
                            result.append(BoundHandler(path: aliasPath, load: selfLoader))
                        }
                    }
                    for child in node.orderedCommands {
                        if let childEntry = children[child.name] {
                            bind(node: child, path: path + [child.name], entry: childEntry)
                        }
                    }
                }
            }
            bind(node: root, path: [], entry: tree)
            return result
        }

        /// Parses `arguments` against `commands`, handles `--help` and `--version`, sets global flags,
        /// and dispatches the matched command handler.
        // parity: cli/src/framework/runtime.ts#run [status=adapted hash=8189683f2327]
        public static func run(
            _ commands: Spec.CommandNode,
            handlers boundHandlers: [BoundHandler],
            options: RunOptions,
            arguments: [String],
            context: CLIContext = CLIContext.current
        ) async throws {
            let rootGlobals = options.globalFlags + commands.globalFlags
            var currentNode = commands
            var commandPath: [String] = []
            var accumulatedGlobals: [Flag.GlobalDefinition] = rootGlobals
            var cursor = 0

            // Walk down subcommand tree while skipping leading global flags if present.
            var preGlobalTokens: [String] = []
            while cursor < arguments.count {
                let token = arguments[cursor]
                if token == "--" { break }
                if token == "-h" || token == "--help" {
                    context.io.writeStdout(renderHelp(rootName: commands.name, path: commandPath, node: currentNode, globals: accumulatedGlobals) + context.io.eol)
                    return
                }
                if commandPath.isEmpty && (token == "-v" || token == "--version") {
                    context.io.writeStdout(options.version + context.io.eol)
                    return
                }
                if token.hasPrefix("-") {
                    // Check if this is a global flag that takes a value so we don't confuse its value with a subcommand.
                    let allFlags = deduplicatedFlags(currentNode.flags + accumulatedGlobals.map(\.flag))
                    if let matched = matchFlagToken(token, in: allFlags) {
                        preGlobalTokens.append(token)
                        cursor += 1
                        if matched.needsNextArg && cursor < arguments.count {
                            preGlobalTokens.append(arguments[cursor])
                            cursor += 1
                        }
                        continue
                    }
                    break
                }
                if let child = findSubcommand(named: token, in: currentNode) {
                    currentNode = child
                    commandPath.append(child.name)
                    accumulatedGlobals.append(contentsOf: child.globalFlags)
                    cursor += 1
                    continue
                }
                break
            }

            let remainingTokens = preGlobalTokens + Array(arguments[cursor...])

            // Check if --help / -h appears anywhere before `--`.
            for tok in remainingTokens {
                if tok == "--" { break }
                if tok == "-h" || tok == "--help" {
                    context.io.writeStdout(renderHelp(rootName: commands.name, path: commandPath, node: currentNode, globals: accumulatedGlobals) + context.io.eol)
                    return
                }
            }

            // If a branch command has no self handler and no further subcommand was supplied, show help.
            let matchedHandler = boundHandlers.first { $0.path == commandPath }
            if matchedHandler == nil {
                if !currentNode.orderedCommands.isEmpty {
                    let unknown = remainingTokens.first { !$0.hasPrefix("-") && $0 != "--" }
                    if let unknown {
                        throw CLIError("Unknown command: \(unknown)")
                    }
                    context.io.writeStdout(renderHelp(rootName: commands.name, path: commandPath, node: currentNode, globals: accumulatedGlobals) + context.io.eol)
                    return
                }
                throw CLIError("No handler registered for command: \(commandPath.joined(separator: " "))")
            }

            let parsed = try parseCommandInput(
                node: currentNode,
                commandPath: commandPath,
                globalDefinitions: accumulatedGlobals,
                tokens: remainingTokens
            )

            context.globalFlags = parsed.globalFlags
            if parsed.globalFlags.printLogs {
                context.setEnvOverride("OPENCODE_PRINT_LOGS", value: "1")
            }

            let handlerFn = await matchedHandler!.load()
            do {
                try await CLIContext.$current.withValue(context) {
                    try await handlerFn(parsed, context)
                }
            } catch let helpError as ShowHelpError {
                var targetNode = commands
                var targetGlobals = rootGlobals
                var resolvedPath: [String] = []
                for segment in helpError.commandPath {
                    if segment == commands.name && resolvedPath.isEmpty { continue }
                    if let next = findSubcommand(named: segment, in: targetNode) {
                        targetNode = next
                        resolvedPath.append(next.name)
                        targetGlobals.append(contentsOf: next.globalFlags)
                    }
                }
                context.io.writeStdout(
                    renderHelp(rootName: commands.name, path: resolvedPath, node: targetNode, globals: targetGlobals)
                        + context.io.eol
                )
                for msg in helpError.errors {
                    context.io.writeStderr(msg + context.io.eol)
                }
                context.exitCode.value = 1
            }
        }

        private static func findSubcommand(named token: String, in node: Spec.CommandNode) -> Spec.CommandNode? {
            if let exact = node.commands[token] { return exact }
            for child in node.orderedCommands {
                if child.primaryAlias == token { return child }
                if child.aliases.contains(where: { $0.name == token }) { return child }
            }
            return nil
        }

        private static func deduplicatedFlags(_ flags: [Flag.Definition]) -> [Flag.Definition] {
            var seen: Set<String> = []
            var out: [Flag.Definition] = []
            for f in flags where seen.insert(f.name).inserted {
                out.append(f)
            }
            return out
        }

        private static func matchFlagToken(_ token: String, in flags: [Flag.Definition]) -> (flag: Flag.Definition, needsNextArg: Bool)? {
            if token.hasPrefix("--no-") {
                let name = String(token.dropFirst(5))
                if let def = flags.first(where: { $0.name == name }), case .boolean = def.kind {
                    return (def, false)
                }
                return nil
            }
            if token.hasPrefix("--") {
                let raw = String(token.dropFirst(2))
                let parts = raw.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let name = String(parts[0])
                let hasInline = parts.count == 2
                guard let def = flags.first(where: { $0.name == name }) else { return nil }
                switch def.kind {
                case .boolean, .optionalValue:
                    return (def, false)
                default:
                    return (def, !hasInline)
                }
            }
            if token.hasPrefix("-"), token.count >= 2 {
                let raw = String(token.dropFirst(1))
                let parts = raw.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let alias = String(parts[0])
                let hasInline = parts.count == 2
                guard let def = flags.first(where: { $0.alias == alias }) else { return nil }
                switch def.kind {
                case .boolean, .optionalValue:
                    return (def, false)
                default:
                    return (def, !hasInline)
                }
            }
            return nil
        }

        public static func parseCommandInput(
            node: Spec.CommandNode,
            commandPath: [String],
            globalDefinitions: [Flag.GlobalDefinition],
            tokens: [String]
        ) throws -> Input {
            let allFlags = deduplicatedFlags(node.flags + globalDefinitions.map(\.flag))
            var booleans: [String: Bool] = [:]
            var strings: [String: String] = [:]
            var integers: [String: Int] = [:]
            var repeatedStrings: [String: [String]] = [:]
            var keyValues: [String: [String: String]] = [:]
            var optionalValues: [String: Flag.OptionalValue] = [:]
            var positionals: [String] = []
            var passthrough: [String] = []

            // Seed defaults
            for def in allFlags {
                switch def.kind {
                case .boolean(let defaultValue):
                    if let defaultValue { booleans[def.name] = defaultValue }
                case .integer(_, let defaultValue, _, _):
                    if let defaultValue { integers[def.name] = defaultValue }
                case .repeatedString:
                    repeatedStrings[def.name] = []
                default:
                    break
                }
            }

            var i = 0
            while i < tokens.count {
                let tok = tokens[i]
                if tok == "--" {
                    passthrough = Array(tokens[(i + 1)...])
                    break
                }
                if tok.hasPrefix("--no-") {
                    let name = String(tok.dropFirst(5))
                    if let def = allFlags.first(where: { $0.name == name }), case .boolean = def.kind {
                        booleans[def.name] = false
                        i += 1
                        continue
                    }
                    throw CLIError("Unknown flag: \(tok)")
                }
                if tok.hasPrefix("--") || (tok.hasPrefix("-") && tok.count >= 2) {
                    let isLong = tok.hasPrefix("--")
                    let raw = String(tok.dropFirst(isLong ? 2 : 1))
                    let eqSplit = raw.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    let flagKey = String(eqSplit[0])
                    let inlineValue: String? = eqSplit.count == 2 ? String(eqSplit[1]) : nil

                    guard let def = allFlags.first(where: { isLong ? $0.name == flagKey : $0.alias == flagKey }) else {
                        throw CLIError("Unknown flag: \(tok)")
                    }
                    i += 1

                    func requireValue() throws -> String {
                        if let inlineValue { return inlineValue }
                        guard i < tokens.count else {
                            throw CLIError("Missing value for flag --\(def.name)")
                        }
                        let v = tokens[i]
                        i += 1
                        return v
                    }

                    switch def.kind {
                    case .boolean:
                        if let inlineValue {
                            let lower = inlineValue.lowercased()
                            if lower == "true" || lower == "1" {
                                booleans[def.name] = true
                            } else if lower == "false" || lower == "0" {
                                booleans[def.name] = false
                            } else {
                                throw CLIError("Invalid boolean value for --\(def.name): \(inlineValue)")
                            }
                        } else {
                            booleans[def.name] = true
                        }

                    case .optionalValue:
                        if let inlineValue, !inlineValue.isEmpty {
                            optionalValues[def.name] = .value(inlineValue)
                        } else {
                            optionalValues[def.name] = .flagOnly
                        }

                    case .string(_, let literals, let nonEmpty):
                        let v = try requireValue()
                        if nonEmpty && v.isEmpty {
                            throw CLIError("Flag --\(def.name) must not be empty")
                        }
                        if let literals, !literals.contains(v) {
                            throw CLIError("Invalid value for --\(def.name): \(v). Expected one of: \(literals.joined(separator: ", "))")
                        }
                        strings[def.name] = v

                    case .integer(_, _, let minVal, let maxVal):
                        let rawInt = try requireValue()
                        guard let parsedInt = Int(rawInt) else {
                            throw CLIError("Invalid integer for --\(def.name): \(rawInt)")
                        }
                        if let minVal, parsedInt < minVal {
                            throw CLIError("Value for --\(def.name) must be at least \(minVal)")
                        }
                        if let maxVal, parsedInt > maxVal {
                            throw CLIError("Value for --\(def.name) must be at most \(maxVal)")
                        }
                        integers[def.name] = parsedInt

                    case .repeatedString(let maxCount):
                        let v = try requireValue()
                        var list = repeatedStrings[def.name] ?? []
                        list.append(v)
                        if let maxCount, list.count > maxCount {
                            throw CLIError("Flag --\(def.name) may be specified at most \(maxCount) times")
                        }
                        repeatedStrings[def.name] = list

                    case .keyValuePair:
                        let rawPair = try requireValue()
                        guard let eq = rawPair.firstIndex(of: "="), eq != rawPair.startIndex else {
                            throw CLIError("Invalid key=value pair for --\(def.name): \(rawPair)")
                        }
                        let k = String(rawPair[..<eq])
                        let v = String(rawPair[rawPair.index(after: eq)...])
                        var dict = keyValues[def.name] ?? [:]
                        dict[k] = v
                        keyValues[def.name] = dict
                    }
                    continue
                }

                positionals.append(tok)
                i += 1
            }

            // Bind positional arguments to argument definitions
            var namedArguments: [String: [String]] = [:]
            var posIdx = 0
            for argDef in node.arguments {
                if let varMin = argDef.variadicMin {
                    var collected: [String] = []
                    let limit = argDef.variadicMax ?? Int.max
                    while posIdx < positionals.count && collected.count < limit {
                        collected.append(positionals[posIdx])
                        posIdx += 1
                    }
                    if collected.count < varMin {
                        throw CLIError("Missing required argument: \(argDef.name)")
                    }
                    namedArguments[argDef.name] = collected
                } else if posIdx < positionals.count {
                    let val = positionals[posIdx]
                    posIdx += 1
                    if let literals = argDef.literals, !literals.contains(val) {
                        throw CLIError("Invalid value for \(argDef.name): \(val). Expected one of: \(literals.joined(separator: ", "))")
                    }
                    namedArguments[argDef.name] = [val]
                } else if !argDef.optional {
                    throw CLIError("Missing required argument: \(argDef.name)")
                }
            }
            if posIdx < positionals.count {
                throw CLIError("Unexpected argument: \(positionals[posIdx])")
            }

            let globalValues = CLIGlobalFlagValues(
                printLogs: booleans["print-logs"] ?? false,
                standalone: booleans["standalone"] ?? false,
                server: strings["server"]
            )

            return Input(
                commandPath: commandPath,
                booleans: booleans,
                strings: strings,
                integers: integers,
                repeatedStrings: repeatedStrings,
                keyValues: keyValues,
                optionalValues: optionalValues,
                positionals: positionals,
                namedArguments: namedArguments,
                passthrough: passthrough,
                globalFlags: globalValues
            )
        }

        public static func renderHelp(
            rootName: String,
            path: [String],
            node: Spec.CommandNode,
            globals: [Flag.GlobalDefinition]
        ) -> String {
            let fullCommand = ([rootName] + path).joined(separator: " ")
            let visibleCommands = node.orderedCommands.filter { !$0.hidden }
            var usageParts: [String] = [fullCommand]
            if !visibleCommands.isEmpty {
                usageParts.append("<command>")
            }
            let allFlags = deduplicatedFlags(node.flags + globals.map(\.flag)).filter { !$0.hidden }
            if !allFlags.isEmpty {
                usageParts.append("[options]")
            }
            for arg in node.arguments {
                if let varMin = arg.variadicMin {
                    usageParts.append(varMin == 0 ? "[\(arg.name)...]" : "<\(arg.name)...>")
                } else if arg.optional {
                    usageParts.append("[\(arg.name)]")
                } else {
                    usageParts.append("<\(arg.name)>")
                }
            }

            var lines: [String] = []
            if let description = node.description {
                lines.append("\(fullCommand) - \(description)")
                lines.append("")
            }
            lines.append("USAGE")
            lines.append("  \(usageParts.joined(separator: " "))")

            if !node.arguments.isEmpty {
                lines.append("")
                lines.append("ARGUMENTS")
                let argWidth = max(12, (node.arguments.map(\.name.count).max() ?? 0) + 2)
                for arg in node.arguments {
                    let padded = arg.name.padding(toLength: argWidth, withPad: " ", startingAt: 0)
                    lines.append("  \(padded)\(arg.description ?? "")")
                }
            }

            if !visibleCommands.isEmpty {
                lines.append("")
                lines.append("COMMANDS")
                let cmdLabels = visibleCommands.map { child -> (String, String) in
                    let label = child.primaryAlias.map { "\(child.name), \($0)" } ?? child.name
                    return (label, child.description ?? "")
                }
                let width = max(14, (cmdLabels.map(\.0.count).max() ?? 0) + 2)
                for (label, desc) in cmdLabels {
                    let padded = label.padding(toLength: width, withPad: " ", startingAt: 0)
                    lines.append("  \(padded)\(desc)")
                }
            }

            lines.append("")
            lines.append("OPTIONS")
            var flagRows: [(String, String)] = allFlags.map { def in
                let shortPart = def.alias.map { "-\($0), " } ?? "    "
                let suffix: String
                switch def.kind {
                case .boolean: suffix = ""
                case .string(_, let literals, _):
                    suffix = literals.map { " <\($0.joined(separator: "|"))>" } ?? " <value>"
                case .integer: suffix = " <int>"
                case .repeatedString: suffix = " <value>"
                case .keyValuePair: suffix = " <key=value>"
                case .optionalValue(let metavar): suffix = "[=\(metavar)]"
                }
                return ("\(shortPart)--\(def.name)\(suffix)", def.description ?? "")
            }
            flagRows.append(("-h, --help", "Show help information"))
            if path.isEmpty {
                flagRows.append(("-v, --version", "Show version information"))
            }
            let optWidth = max(18, (flagRows.map(\.0.count).max() ?? 0) + 2)
            for (label, desc) in flagRows {
                let padded = label.padding(toLength: optWidth, withPad: " ", startingAt: 0)
                lines.append("  \(padded)\(desc)")
            }
            return lines.joined(separator: "\n")
        }
    }
}

// MARK: - CLI Configuration & V1 Migration (`packages/cli/src/config/*`)

public enum CLIConfig {
    // parity: cli/src/config/schema.ts#SchemaURL [status=implemented hash=933ce59eeeaa]
    public static let SchemaURL = "https://opencode.ai/v2/cli.json"

    /// CLI configuration document (`$schema` + all `TUIConfig.Info` settings).
    // parity: cli/src/config/schema.ts#Info [status=implemented hash=8bb587c8f3bb]
    public struct Info: Equatable, Sendable, Codable {
        public var schema: String?
        public var tui: TUIConfig.Info

        public init(schema: String? = nil, tui: TUIConfig.Info = TUIConfig.Info()) {
            self.schema = schema
            self.tui = tui
        }

        public var theme: TUIConfig.ThemeConfig? {
            get { tui.theme }
            set { tui.theme = newValue }
        }
        public var keybinds: TUIConfig.Keybind.KeybindOverrides? {
            get { tui.keybinds }
            set { tui.keybinds = newValue }
        }
        public var plugins: [TUIConfig.Plugin]? {
            get { tui.plugins }
            set { tui.plugins = newValue }
        }
        public var leader: TUIConfig.LeaderConfig? {
            get { tui.leader }
            set { tui.leader = newValue }
        }
        public var scroll: TUIConfig.ScrollConfig? {
            get { tui.scroll }
            set { tui.scroll = newValue }
        }
        public var attention: TUIConfig.AttentionConfig? {
            get { tui.attention }
            set { tui.attention = newValue }
        }
        public var diffs: TUIConfig.DiffsConfig? {
            get { tui.diffs }
            set { tui.diffs = newValue }
        }
        public var terminal: TUIConfig.TerminalConfig? {
            get { tui.terminal }
            set { tui.terminal = newValue }
        }
        public var prompt: TUIConfig.PromptConfig? {
            get { tui.prompt }
            set { tui.prompt = newValue }
        }
        public var session: TUIConfig.SessionConfig? {
            get { tui.session }
            set { tui.session = newValue }
        }
        public var tabs: TUIConfig.TabsConfig? {
            get { tui.tabs }
            set { tui.tabs = newValue }
        }
        public var mini: TUIConfig.MiniConfig? {
            get { tui.mini }
            set { tui.mini = newValue }
        }
        public var debug: TUIConfig.DebugConfig? {
            get { tui.debug }
            set { tui.debug = newValue }
        }
        public var experimental: [String: Bool]? {
            get { tui.experimental }
            set { tui.experimental = newValue }
        }
        public var animations: Bool? {
            get { tui.animations }
            set { tui.animations = newValue }
        }
        public var highlights: Bool? {
            get { tui.highlights }
            set { tui.highlights = newValue }
        }
        public var mouse: Bool? {
            get { tui.mouse }
            set { tui.mouse = newValue }
        }
        public var cursor: TUIConfig.Cursor? {
            get { tui.cursor }
            set { tui.cursor = newValue }
        }

        private enum SchemaKey: String, CodingKey {
            case schema = "$schema"
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: SchemaKey.self)
            self.schema = try container.decodeIfPresent(String.self, forKey: .schema)
            self.tui = try TUIConfig.Info(from: decoder)
        }

        public func encode(to encoder: Encoder) throws {
            try tui.encode(to: encoder)
            var container = encoder.container(keyedBy: SchemaKey.self)
            try container.encodeIfPresent(schema, forKey: .schema)
        }
    }

    // parity: cli/src/config/schema.ts#normalizeLegacyTabs [status=implemented hash=dbc66cc4e6e6]
    public static func normalizeLegacyTabs(_ info: Info?) -> Info? {
        guard var info, let enabled = info.tabs?.enabled else { return info }
        var tabs = info.tabs ?? TUIConfig.TabsConfig()
        if tabs.mode == nil {
            tabs.mode = enabled ? .on : .off
        }
        tabs.enabled = nil
        info.tabs = tabs
        return info
    }

    // MARK: Config Service (`packages/cli/src/config/config.ts`)

    // parity: cli/src/config/config.ts#Interface [status=implemented hash=4d7d8b1f5ec6]
    public protocol Interface: Sendable {
        var path: String { get }
        func get() async throws -> Info
        func update(_ mutate: @escaping @Sendable (inout Info) -> Void) async throws -> Info
    }

    /// Adapter bridging `CLIConfig.Interface` to `TUIConfig.Interface`.
    public struct TUIConfigAdapter: TUIConfig.Interface, Sendable {
        private let service: any CLIConfig.Interface

        public init(_ service: any CLIConfig.Interface) {
            self.service = service
        }

        public var path: String? { service.path }

        public func get() async throws -> TUIConfig.Info {
            try await service.get().tui
        }

        public func update(_ mutate: @escaping @Sendable (inout TUIConfig.Info) -> Void) async throws -> TUIConfig.Info {
            try await service.update { draft in
                mutate(&draft.tui)
            }.tui
        }
    }

    // parity: cli/src/config/config.ts#Service [status=implemented hash=ae55b421fe6d]
    public final class Service: Interface, Sendable {
        public static let serviceKey = "@opencode/cli/config/Config"

        public let path: String
        private let configDir: String
        private let stateDir: String
        private let fileSystem: any OpenCodeFileSystem
        private let envOverrideContent: String?

        public init(
            configDir: String,
            stateDir: String,
            fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
            envOverrideContent: String? = nil
        ) {
            self.configDir = configDir
            self.stateDir = stateDir
            self.path = CLIPath.join(configDir, "cli.json")
            self.fileSystem = fileSystem
            self.envOverrideContent = envOverrideContent
        }

        public convenience init(context: CLIContext = CLIContext.current) {
            let paths = context.globalPaths
            self.init(
                configDir: paths.config,
                stateDir: paths.state,
                fileSystem: context.fileSystem,
                envOverrideContent: context.envVariable("OPENCODE_CLI_CONFIG_CONTENT")
            )
        }

        private func withFileLock<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
            let lockDir = CLIPath.join(stateDir, "locks")
            let lock = try await Flock.acquire(
                path,
                options: Flock.Options(dir: lockDir),
                fileSystem: fileSystem
            )
            // Release before returning, as upstream's scoped lock does: a detached release would let the next locked
            // operation take the directory while this holder's heartbeat and meta files are still being removed.
            let result: T
            do {
                result = try await operation()
            } catch {
                try? await lock.release()
                throw error
            }
            try? await lock.release()
            return result
        }

        private func readInfoFromDisk() async -> Info? {
            guard let bytes = try? await fileSystem.readFile(at: path) else { return nil }
            let text = String(decoding: bytes, as: UTF8.self)
            return Self.decodeJSONC(text)
        }

        private func envOverlayInfo() -> Info? {
            guard let envOverrideContent, !envOverrideContent.isEmpty else { return nil }
            return Self.decodeJSONC(envOverrideContent)
        }

        public func get() async throws -> Info {
            try await withFileLock {
                let migrated = try? await Migration.run(
                    Migration.Input(file: self.path, config: self.configDir, state: self.stateDir),
                    fileSystem: self.fileSystem
                )
                let base: Info?
                if let info = migrated?.info {
                    base = info
                } else {
                    base = await self.readInfoFromDisk()
                }
                return Self.merge(base, self.envOverlayInfo())
            }
        }

        public func update(_ mutate: @escaping @Sendable (inout Info) -> Void) async throws -> Info {
            try await withFileLock {
                let migrated = try await Migration.run(
                    Migration.Input(file: self.path, config: self.configDir, state: self.stateDir),
                    fileSystem: self.fileSystem
                )
                if let cause = migrated?.error {
                    throw CLIError("Failed to update CLI config: \(cause)")
                }
                let base: Info?
                if let info = migrated?.info {
                    base = info
                } else {
                    base = await self.readInfoFromDisk()
                }
                let current = Self.merge(base, self.envOverlayInfo())
                var next = current
                mutate(&next)
                let edits = Self.diffChanges(
                    try Self.encodeInfoToWirePureJSON(current),
                    try Self.encodeInfoToWirePureJSON(next)
                )
                if edits.isEmpty {
                    return current
                }
                let defaultText = PureJSON.stringifyPretty(.object([("$schema", .string(SchemaURL))]), indent: 2)
                let text: String
                if let bytes = try? await self.fileSystem.readFile(at: self.path) {
                    text = String(decoding: bytes, as: UTF8.self)
                } else {
                    text = defaultText
                }
                var updated = text
                let modOpts = JSONC.ModificationOptions(
                    formattingOptions: JSONC.FormattingOptions(tabSize: 2, insertSpaces: true)
                )
                for (editPath, editValue) in edits {
                    let jsoncEdits = try JSONC.modify(updated, path: editPath, value: editValue, options: modOpts)
                    updated = try JSONC.applyEdits(updated, edits: jsoncEdits)
                }
                var parseErrors: [JSONC.ParseError] = []
                _ = JSONC.parse(updated, errors: &parseErrors, options: JSONC.ParseOptions(allowTrailingComma: true))
                guard parseErrors.isEmpty, let config = Self.decodeJSONC(updated) else {
                    throw CLIError("Invalid CLI config update")
                }
                let finalText = updated.utf8.last == 0x0A ? updated : updated + "\n"
                let temp = self.path + ".tmp"
                try await self.fileSystem.makeDirectory(at: CLIPath.dirname(self.path), recursive: true)
                try await self.fileSystem.writeFile(Array(finalText.utf8), to: temp, createDirectories: true)
                try? await self.fileSystem.chmod(at: temp, mode: 0o600)
                try await self.fileSystem.rename(from: temp, to: self.path)
                return Self.merge(config, self.envOverlayInfo())
            }
        }

        internal static func encodeInfoToWirePureJSON(_ info: Info) throws -> PureJSONValue {
            let data = try JSONEncoder().encode(info)
            var raw = try JSONDecoder().decode(JSONValue.self, from: data)
            if case .object(var dict) = raw {
                if case .object(let rawKeybinds) = dict["keybinds"] {
                    var wireKeybinds: [String: JSONValue] = [:]
                    for (name, val) in rawKeybinds {
                        wireKeybinds[name] = denormalizeBindingValueJSON(val)
                    }
                    dict["keybinds"] = .object(wireKeybinds)
                }
                if case .array(let rawPlugins) = dict["plugins"] {
                    dict["plugins"] = .array(rawPlugins.map(denormalizePluginJSON))
                }
                raw = .object(dict)
            }
            return CoreConfigJSONC.toPureJSON(raw)
        }

        private static func denormalizeBindingItemJSON(_ value: JSONValue) -> JSONValue {
            guard case .object(let obj) = value else { return value }
            if case .object(let seq) = obj["sequence"], let s = seq["_0"] {
                return s
            }
            if case .object(let objWrap) = obj["object"], let inner = objWrap["_0"] {
                return inner
            }
            if case .object(let strokeWrap) = obj["stroke"], let inner = strokeWrap["_0"] {
                return inner
            }
            return value
        }

        private static func denormalizeBindingValueJSON(_ value: JSONValue) -> JSONValue {
            guard case .object(let obj) = value else { return value }
            if obj["disabled"] != nil {
                return .bool(false)
            }
            if case .object(let itemWrap) = obj["item"], let inner = itemWrap["_0"] {
                return denormalizeBindingItemJSON(inner)
            }
            if case .object(let itemsWrap) = obj["items"], case .array(let arr) = itemsWrap["_0"] {
                return .array(arr.map(denormalizeBindingItemJSON))
            }
            return value
        }

        private static func denormalizePluginJSON(_ value: JSONValue) -> JSONValue {
            guard case .object(let obj) = value else { return value }
            if case .object(let spec) = obj["specifier"], let s = spec["_0"] {
                return s
            }
            if case .object(let cfg) = obj["configured"] {
                var out: [String: JSONValue] = [:]
                if let pkg = cfg["package"] { out["package"] = pkg }
                if let opts = cfg["options"], opts != .null { out["options"] = opts }
                return .object(out)
            }
            return value
        }

        internal static func diffChanges(
            _ before: PureJSONValue,
            _ after: PureJSONValue,
            path: [JSONC.PathSegment] = []
        ) -> [([JSONC.PathSegment], PureJSONValue?)] {
            if before == after { return [] }
            if case .object(let bEntries) = before, case .object(let aEntries) = after {
                var bMap: [String: PureJSONValue] = [:]
                var aMap: [String: PureJSONValue] = [:]
                var keys: [String] = []
                for (k, v) in bEntries {
                    if bMap[k] == nil { keys.append(k) }
                    bMap[k] = v
                }
                for (k, v) in aEntries {
                    if bMap[k] == nil && aMap[k] == nil { keys.append(k) }
                    aMap[k] = v
                }
                var out: [([JSONC.PathSegment], PureJSONValue?)] = []
                for key in keys {
                    let nextPath = path + [.key(key)]
                    guard let afterVal = aMap[key] else {
                        out.append((nextPath, nil))
                        continue
                    }
                    guard let beforeVal = bMap[key] else {
                        out.append((nextPath, afterVal))
                        continue
                    }
                    out.append(contentsOf: diffChanges(beforeVal, afterVal, path: nextPath))
                }
                return out
            }
            return [(path, after)]
        }

        internal static func decodeJSONC(_ text: String) -> Info? {
            guard let parsed = try? CoreConfigJSONC.parse(text),
                  case .object(var dict) = parsed
            else {
                return nil
            }
            if case .object(let rawKeybinds) = dict["keybinds"] {
                var normalizedKeybinds: [String: JSONValue] = [:]
                for (name, val) in rawKeybinds {
                    normalizedKeybinds[name] = normalizeBindingValueJSON(val)
                }
                dict["keybinds"] = .object(normalizedKeybinds)
            }
            if case .array(let rawPlugins) = dict["plugins"] {
                dict["plugins"] = .array(rawPlugins.map(normalizePluginJSON))
            }
            guard let data = try? JSONEncoder().encode(JSONValue.object(dict)),
                  let decoded = try? JSONDecoder().decode(Info.self, from: data)
            else {
                return nil
            }
            return normalizeLegacyTabs(decoded)
        }

        private static func normalizeBindingItemJSON(_ value: JSONValue) -> JSONValue {
            switch value {
            case .string(let s):
                return .object(["sequence": .object(["_0": .string(s)])])
            case .object(let obj):
                if obj["sequence"] != nil || obj["stroke"] != nil || obj["object"] != nil {
                    return value
                }
                if obj["key"] != nil {
                    return .object(["object": .object(["_0": value])])
                }
                return value
            default:
                return value
            }
        }

        private static func normalizeBindingValueJSON(_ value: JSONValue) -> JSONValue {
            switch value {
            case .bool(false):
                return .object(["disabled": .object([:])])
            case .bool(true):
                return .object(["items": .object(["_0": .array([])])])
            case .string(let s):
                if s == "none" {
                    return .object(["disabled": .object([:])])
                }
                return .object(["item": .object(["_0": .object(["sequence": .object(["_0": .string(s)])])])])
            case .array(let arr):
                return .object(["items": .object(["_0": .array(arr.map(normalizeBindingItemJSON))])])
            case .object(let obj):
                if obj["disabled"] != nil || obj["item"] != nil || obj["items"] != nil {
                    return value
                }
                if obj["key"] != nil {
                    return .object(["item": .object(["_0": .object(["object": .object(["_0": value])])])])
                }
                return value
            default:
                return value
            }
        }

        private static func normalizePluginJSON(_ value: JSONValue) -> JSONValue {
            switch value {
            case .string(let s):
                return .object(["specifier": .object(["_0": .string(s)])])
            case .object(let obj):
                if obj["specifier"] != nil || obj["configured"] != nil {
                    return value
                }
                if let pkg = obj["package"] {
                    var cfg: [String: JSONValue] = ["package": pkg]
                    if let opts = obj["options"] { cfg["options"] = opts }
                    return .object(["configured": .object(cfg)])
                }
                return value
            default:
                return value
            }
        }

        internal static func merge(_ values: Info?...) -> Info {
            var mergedObj: [String: JSONValue] = [:]
            let encoder = JSONEncoder()
            let decoder = JSONDecoder()
            for raw in values {
                guard let normalized = normalizeLegacyTabs(raw),
                      let data = try? encoder.encode(normalized),
                      let json = try? decoder.decode(JSONValue.self, from: data),
                      case .object(let dict) = json
                else {
                    continue
                }
                mergedObj = deepMergeObjects(mergedObj, dict)
            }
            guard let outData = try? encoder.encode(JSONValue.object(mergedObj)),
                  let decoded = try? decoder.decode(Info.self, from: outData)
            else {
                return Info()
            }
            return decoded
        }

        private static func deepMergeObjects(_ base: [String: JSONValue], _ overlay: [String: JSONValue]) -> [String: JSONValue] {
            var result = base
            for (key, value) in overlay {
                if case .object(let lhs) = result[key], case .object(let rhs) = value {
                    result[key] = .object(deepMergeObjects(lhs, rhs))
                } else {
                    result[key] = value
                }
            }
            return result
        }
    }

    // parity: cli/src/config/config.ts#layer [status=adapted hash=eba11449aae9]
    public static let layer: LayerNode.ExecutableLayer = LayerNode.ExecutableLayer { _, _ in
        let service = Service(context: CLIContext.current)
        return LayerNode.Output([Service.serviceKey: service])
    }

    // MARK: Config Migration (`packages/cli/src/config/migrate.ts`)

    public enum Migration {
        public struct Input: Equatable, Hashable, Sendable {
            public let file: String
            public let config: String
            public let state: String

            public init(file: String, config: String, state: String) {
                self.file = file
                self.config = config
                self.state = state
            }
        }

        public struct Result: Equatable, Sendable {
            public let info: Info
            public let error: String?

            public init(info: Info, error: String? = nil) {
                self.info = info
                self.error = error
            }
        }

        private static let legacyKeybindTargets = Set(TUIConfig.V1.Keybind.CommandMap.values)

        /// Migrates existing `cli.json` (legacy `terminal.copy_on_select` and V1 keybind names)
        /// or creates `cli.json` from V1 `tui.json` + `kv.json`.
        // parity: cli/src/config/migrate.ts#run [status=implemented hash=6335646cc5f8]
        public static func run(
            _ input: Input,
            fileSystem: any OpenCodeFileSystem = CLIContext.current.fileSystem
        ) async throws -> Result? {
            func persist(_ text: String, info: Info) async -> Result {
                let temp = "\(input.file).\(CLIContext.current.currentPID).\(uuid()).tmp"
                do {
                    try await fileSystem.makeDirectory(at: CLIPath.dirname(input.file), recursive: true)
                    try await fileSystem.writeFile(Array(text.utf8), to: temp, createDirectories: true)
                    try? await fileSystem.chmod(at: temp, mode: 0o600)
                    try await fileSystem.rename(from: temp, to: input.file)
                    return Result(info: info, error: nil)
                } catch {
                    try? await fileSystem.remove(at: temp)
                    return Result(info: info, error: CLIUtil.errorMessage(error))
                }
            }

            if await fileSystem.exists(at: input.file) {
                let bytes = try await fileSystem.readFile(at: input.file)
                let text = String(decoding: bytes, as: UTF8.self)
                var parseErrors: [JSONC.ParseError] = []
                let parsed = JSONC.parse(text, errors: &parseErrors, options: JSONC.ParseOptions(allowTrailingComma: true))
                guard parseErrors.isEmpty, case .object(let rootEntries)? = parsed else {
                    return nil
                }
                var rootMap: [String: PureJSONValue] = [:]
                for (k, v) in rootEntries { rootMap[k] = v }

                let modOpts = JSONC.ModificationOptions(
                    formattingOptions: JSONC.FormattingOptions(tabSize: 2, insertSpaces: true)
                )

                // 1. Surgically migrate `terminal.copy_on_select` -> `terminal.copy`
                var renamed = text
                if case .object(let terminalEntries)? = rootMap["terminal"] {
                    var terminalMap: [String: PureJSONValue] = [:]
                    for (k, v) in terminalEntries { terminalMap[k] = v }
                    if case .bool(let legacyCopy)? = terminalMap["copy_on_select"] {
                        var termEdits: [([JSONC.PathSegment], PureJSONValue?)] = []
                        if terminalMap["copy"] == nil {
                            termEdits.append(([.key("terminal"), .key("copy")], .string(legacyCopy ? "select" : "manual")))
                        }
                        termEdits.append(([.key("terminal"), .key("copy_on_select")], nil))
                        for (editPath, editValue) in termEdits {
                            let edits = try JSONC.modify(renamed, path: editPath, value: editValue, options: modOpts)
                            renamed = try JSONC.applyEdits(renamed, edits: edits)
                        }
                    }
                }

                // 2. Surgically migrate legacy V1 keybind names in `keybinds` while preserving all comments
                var updated = renamed
                if case .object(let keybindEntries)? = rootMap["keybinds"] {
                    var keybindMap: [String: PureJSONValue] = [:]
                    var keybindKeys: [String] = []
                    for (k, v) in keybindEntries {
                        if keybindMap[k] == nil { keybindKeys.append(k) }
                        keybindMap[k] = v
                    }
                    let duplicateKeybindObjects = findKeybindObjects(updated).matches
                    if duplicateKeybindObjects.count > 1 {
                        for _ in 0..<(duplicateKeybindObjects.count - 1) {
                            let found = findKeybindObjects(updated)
                            if let property = found.matches.first {
                                updated = withExtendedLifetime(found.tree) {
                                    removeProperty(updated, property: property)
                                }
                            }
                        }
                    }
                    for name in keybindKeys {
                        let target: String?
                        if let mapped = TUIConfig.V1.Keybind.CommandMap[name] {
                            target = mapped
                        } else if TUIConfig.Keybind.Definitions[name] != nil || legacyKeybindTargets.contains(name) {
                            target = name
                        } else {
                            target = nil
                        }
                        guard let target else { continue }
                        let properties = findKeybindProperties(updated, name: name).matches
                        if properties.isEmpty { continue }
                        let shouldRemove = TUIConfig.Keybind.Definitions[target] == nil
                            || (target != name && keybindMap[target] != nil)
                        // The parser gives the final duplicate precedence, so remove earlier properties before renaming it.
                        let removeCount = shouldRemove ? properties.count : (properties.count - 1)
                        if removeCount > 0 {
                            for _ in 0..<removeCount {
                                let found = findKeybindProperties(updated, name: name)
                                if let property = found.matches.first {
                                    updated = withExtendedLifetime(found.tree) {
                                        removeProperty(updated, property: property)
                                    }
                                }
                            }
                        }
                        if shouldRemove || target == name { continue }
                        let renameFound = findKeybindProperties(updated, name: name)
                        if let keyNode = renameFound.matches.first?.children?.first {
                            updated = withExtendedLifetime(renameFound.tree) {
                                JSONC.applyEdit(
                                    updated,
                                    edit: JSONC.Edit(
                                        offset: keyNode.offset,
                                        length: keyNode.length,
                                        content: PureJSON.stringifyCompact(.string(target))
                                    )
                                )
                            }
                        }
                    }
                }

                if updated == text { return nil }
                var updatedErrors: [JSONC.ParseError] = []
                _ = JSONC.parse(updated, errors: &updatedErrors, options: JSONC.ParseOptions(allowTrailingComma: true))
                guard updatedErrors.isEmpty, let info = Service.decodeJSONC(updated) else { return nil }
                return await persist(updated, info: info)
            }

            // No cli.json yet: check legacy tui.json + kv.json
            let legacyTuiPath = CLIPath.join(input.config, "tui.json")
            let kvPath = CLIPath.join(input.state, "kv.json")
            let legacyV1: TUIConfig.V1.Info? = await {
                guard let bytes = try? await fileSystem.readFile(at: legacyTuiPath),
                      let stripped = try? CoreConfigJSONC.stripCommentsAndTrailingCommas(String(decoding: bytes, as: UTF8.self)),
                      let data = stripped.data(using: .utf8)
                else { return nil }
                return try? JSONDecoder().decode(TUIConfig.V1.Info.self, from: data)
            }()
            let kvDict: [String: JSONValue] = await {
                guard let bytes = try? await fileSystem.readFile(at: kvPath),
                      let parsed = try? CoreConfigJSONC.parse(String(decoding: bytes, as: UTF8.self)),
                      case .object(let dict) = parsed
                else { return [:] }
                return dict
            }()

            let migrated = migrateV1(legacyV1, kv: kvDict)
            if migrated == Info() { return nil }
            var withSchema = migrated
            withSchema.schema = SchemaURL
            let wirePure = try Service.encodeInfoToWirePureJSON(withSchema)
            let encoded = PureJSON.stringifyPretty(wirePure, indent: 2) + "\n"
            return await persist(encoded, info: withSchema)
        }

        private static func findKeybindObjects(_ text: String) -> (tree: JSONC.Node?, matches: [JSONC.Node]) {
            var errors: [JSONC.ParseError] = []
            guard let tree = JSONC.parseTree(text, errors: &errors),
                  let children = tree.children
            else {
                return (nil, [])
            }
            return (tree, children.filter { $0.children?.first?.stringValue == "keybinds" })
        }

        private static func findKeybindProperties(_ text: String, name: String) -> (tree: JSONC.Node?, matches: [JSONC.Node]) {
            let found = findKeybindObjects(text)
            guard let keybindObj = found.matches.last?.children?.dropFirst().first,
                  let children = keybindObj.children
            else {
                return (found.tree, [])
            }
            return (found.tree, children.filter { $0.children?.first?.stringValue == name })
        }

        private static func removeProperty(_ text: String, property: JSONC.Node) -> String {
            let properties = property.parent?.children ?? []
            guard let index = properties.firstIndex(where: { $0 === property }) else { return text }
            let end = property.offset + property.length
            if index + 1 < properties.count {
                let next = properties[index + 1]
                if let comma = findComma(text, start: end, end: next.offset) {
                    return spliceUTF16(text, [(property.offset, end), (comma, comma + 1)])
                }
            }
            if index > 0 {
                let previous = properties[index - 1]
                if let comma = findComma(text, start: previous.offset + previous.length, end: property.offset) {
                    return spliceUTF16(text, [(comma, comma + 1), (property.offset, end)])
                }
            }
            let parentEnd = (property.parent?.offset ?? 0) + (property.parent?.length ?? 0)
            if let comma = findComma(text, start: end, end: parentEnd) {
                return spliceUTF16(text, [(property.offset, end), (comma, comma + 1)])
            }
            return spliceUTF16(text, [(property.offset, end)])
        }

        private static func findComma(_ text: String, start: Int, end: Int) -> Int? {
            let units = Array(text.utf16)
            let scanner = JSONC.createScanner(text, ignoreTrivia: false)
            scanner.setPosition(start)
            while true {
                scanner.scan()
                let offset = scanner.getTokenOffset()
                if scanner.getTokenLength() == 0 || offset >= end { return nil }
                if offset >= 0 && offset < units.count && units[offset] == 44 { // ','
                    return offset
                }
            }
        }

        private static func spliceUTF16(_ text: String, _ removals: [(Int, Int)]) -> String {
            let units = Array(text.utf16)
            let sorted = removals.sorted { $0.0 < $1.0 }
            var out: [UInt16] = []
            out.reserveCapacity(units.count)
            var cursor = 0
            for (start, end) in sorted {
                let s = min(max(cursor, start), units.count)
                let e = min(max(s, end), units.count)
                if cursor < s {
                    out.append(contentsOf: units[cursor..<s])
                }
                cursor = e
            }
            if cursor < units.count {
                out.append(contentsOf: units[cursor..<units.count])
            }
            return String(decoding: out, as: UTF16.self)
        }

        // parity: cli/src/config/migrate.ts#migrateV1 [status=implemented hash=17139b449864]
        public static func migrateV1(_ legacy: TUIConfig.V1.Info?, kv: [String: JSONValue]) -> Info {
            var info = Info()

            // Plugins
            var plugins: [TUIConfig.Plugin] = []
            if let legacyPlugins = legacy?.plugin {
                for spec in legacyPlugins {
                    switch spec {
                    case .name(let name):
                        plugins.append(.specifier(name))
                    case .tuple(let name, let opts):
                        plugins.append(.configured(package: name, options: opts))
                    }
                }
            }
            if let enabledMap = legacy?.pluginEnabled {
                for (id, enabled) in enabledMap.sorted(by: { $0.key < $1.key }) {
                    plugins.append(.specifier(enabled ? id : "-\(id)"))
                }
            }
            if !plugins.isEmpty { info.plugins = plugins }

            // Theme
            let themeName = legacy?.theme ?? kv["theme"]?.stringValue
            let themeMode = kv["theme_mode_lock"]?.stringValue.flatMap(TUIConfig.ThemeConfig.ModePreference.init(rawValue:))
            if themeName != nil || themeMode != nil {
                info.theme = TUIConfig.ThemeConfig(name: themeName, mode: themeMode)
            }

            // Keybinds
            if let legacyKeybinds = legacy?.keybinds {
                var mapped: TUIConfig.Keybind.KeybindOverrides = [:]
                for (name, value) in legacyKeybinds {
                    let target = TUIConfig.V1.Keybind.CommandMap[name] ?? name
                    if TUIConfig.Keybind.Definitions[target] != nil {
                        mapped[target] = value
                    }
                }
                info.keybinds = mapped
            }

            // Leader timeout
            if let timeout = legacy?.leaderTimeout {
                info.leader = TUIConfig.LeaderConfig(timeout: timeout)
            }

            // Scroll
            if legacy?.scrollSpeed != nil || legacy?.scrollAcceleration?.enabled != nil {
                info.scroll = TUIConfig.ScrollConfig(
                    speed: legacy?.scrollSpeed,
                    acceleration: legacy?.scrollAcceleration?.enabled
                )
            }

            // Attention
            let attentionSoundPack = kv["attention_sound_pack"]?.stringValue
            if legacy?.attention != nil || attentionSoundPack != nil {
                info.attention = TUIConfig.AttentionConfig(
                    notifications: legacy?.attention?.notifications,
                    sound: legacy?.attention?.sound,
                    volume: legacy?.attention?.volume,
                    soundPack: attentionSoundPack ?? legacy?.attention?.soundPack,
                    sounds: legacy?.attention?.sounds
                )
            }

            // Diffs
            let diffView = kv["diff_viewer_view"]?.stringValue ?? (legacy?.diffStyle == .stacked ? "unified" : nil)
            let diffWrap = kv["diff_wrap_mode"]?.stringValue
            let diffTree = kv["diff_viewer_show_file_tree"]?.boolValue
            let diffSingle = kv["diff_viewer_single_patch"]?.boolValue
            if legacy?.diffStyle != nil || diffWrap != nil || diffTree != nil || diffSingle != nil || diffView != nil {
                info.diffs = TUIConfig.DiffsConfig(
                    wrap: diffWrap,
                    tree: diffTree,
                    single: diffSingle,
                    view: diffView
                )
            }

            // Terminal
            if let title = kv["terminal_title_enabled"]?.boolValue {
                info.terminal = TUIConfig.TerminalConfig(title: title)
            }

            // Prompt
            let fileContext = kv["file_context_enabled"]?.boolValue
            let pasteSummary = kv["paste_summary_enabled"]?.boolValue
            if fileContext != nil || pasteSummary != nil {
                info.prompt = TUIConfig.PromptConfig(
                    editor: fileContext,
                    paste: pasteSummary.map { $0 ? "compact" : "full" }
                )
            }

            // Session
            let sidebar = kv["sidebar"]?.stringValue
            let scrollbar = kv["scrollbar_visible"]?.boolValue
            let thinkingMode: TUIContext.ThinkingMode? = {
                if let raw = kv["thinking_mode"]?.stringValue {
                    return TUIContext.ThinkingMode(rawValue: raw)
                }
                if let vis = kv["thinking_visibility"]?.boolValue {
                    return vis ? .show : .hide
                }
                return nil
            }()
            let explorationGrouping = kv["exploration_grouping"]?.boolValue
            if sidebar != nil || scrollbar != nil || thinkingMode != nil || explorationGrouping != nil {
                info.session = TUIConfig.SessionConfig(
                    sidebar: sidebar,
                    scrollbar: scrollbar,
                    thinking: thinkingMode,
                    grouping: explorationGrouping.map { $0 ? "auto" : "none" }
                )
            }

            // Misc
            if let animations = kv["animations_enabled"]?.boolValue {
                info.animations = animations
            }
            if let mouse = legacy?.mouse {
                info.mouse = mouse
            }
            if let cursor = legacy?.cursor {
                info.cursor = cursor
            }

            return info
        }
    }
}

// MARK: - CLI Interactive UI, Prompts & Timeline (`packages/cli/src/ui/*`)

public enum CLIUI {
    // MARK: Integration Picker (`packages/cli/src/ui/integration-picker.ts`)

    public enum IntegrationCategory: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
        case mcp = "MCP"
        case popular = "Popular"
        case services = "Services"
    }

    // parity: cli/src/ui/integration-picker.ts#IntegrationChoice [status=implemented hash=a5e8a744e0b2]
    public struct IntegrationChoice: Equatable, Hashable, Sendable, Codable {
        public let value: String
        public let label: String
        public let category: IntegrationCategory
        public let connected: Bool
        public let hint: String?

        public init(
            value: String,
            label: String,
            category: IntegrationCategory,
            connected: Bool,
            hint: String? = nil
        ) {
            self.value = value
            self.label = label
            self.category = category
            self.connected = connected
            self.hint = hint
        }
    }

    public static func filterIntegrationChoices(_ choices: [IntegrationChoice], search: String) -> [IntegrationChoice] {
        guard !search.isEmpty else { return choices }
        let q = search.lowercased()
        return choices.filter { choice in
            choice.label.lowercased().contains(q)
                || choice.value.lowercased().contains(q)
                || choice.category.rawValue.lowercased().contains(q)
        }
    }

    public static func renderIntegrationPickerFrame(
        choices: [IntegrationChoice],
        search: String = "",
        cursor: Int = 0,
        kind: String = "integration",
        columns: Int = 80,
        rows: Int = 24
    ) -> String {
        let filtered = filterIntegrationChoices(choices, search: search)
        let maxItems = min(8, max(2, rows - 14))
        let compact = rows < 18
        let safeCursor = filtered.isEmpty ? 0 : min(max(0, cursor), filtered.count - 1)
        let start = min(max(0, safeCursor - min(2, maxItems - 1)), max(0, filtered.count - maxItems))
        let visible = Array(filtered.dropFirst(start).prefix(maxItems))

        var lines: [String] = [
            "│",
            "◆  Select \(kind)",
            "│  Search: \(search)",
        ]
        if visible.isEmpty && !search.isEmpty {
            lines.append("│  No \(kind)s found")
        }
        if start > 0 {
            lines.append("│  …")
        }
        for (idx, choice) in visible.enumerated() {
            if idx == 0 || visible[idx - 1].category != choice.category {
                if !compact { lines.append("│  ") }
                lines.append("│  \(choice.category.rawValue)")
            }
            let marker = (start + idx == safeCursor) ? "●" : "○"
            let check = choice.connected ? " ✓" : ""
            let hintText = choice.hint.map { " (\($0))" } ?? ""
            lines.append("│  \(marker) \(choice.label)\(check)\(hintText)")
        }
        if start + maxItems < filtered.count {
            lines.append("│  …")
        }
        let footer = columns < 50
            ? "↑/↓ navigate • Enter select"
            : "↑/↓ to select • Enter: confirm • Type: to search"
        lines.append("│  \(footer)")
        lines.append("└")
        return lines.joined(separator: "\n")
    }

    // parity: cli/src/ui/integration-picker.ts#selectIntegration [status=adapted hash=792a71aa6bde]
    public static func selectIntegration(
        _ choices: [IntegrationChoice],
        kind: String = "integration",
        context: CLIContext = CLIContext.current
    ) async throws -> String {
        if let backend = context.promptBackend {
            let options = choices.map { choice in
                Prompt.SelectOption(
                    value: choice.value,
                    label: choice.label,
                    hint: choice.hint ?? (choice.connected ? "connected" : nil)
                )
            }
            return try await backend.select(message: "Select \(kind)", options: options, initialValue: choices.first?.value)
        }
        guard !choices.isEmpty else {
            throw CLIError("No \(kind) selected")
        }
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        if context.io.isStdinTTY() && context.io.isStdoutTTY(),
           isatty(STDIN_FILENO) != 0,
           isatty(STDOUT_FILENO) != 0
        {
            return try Prompt.DefaultTerminalBackend.withNoEchoRawMode(fd: STDIN_FILENO) {
                try runInteractiveIntegrationPicker(
                    choices: choices,
                    kind: kind,
                    columns: context.io.columns(),
                    rows: context.io.rows(),
                    eol: context.io.eol,
                    nextKey: {
                        Prompt.DefaultTerminalBackend.decodeTerminalKey { timeoutMs in
                            Prompt.DefaultTerminalBackend.readPOSIXByte(fd: STDIN_FILENO, timeoutMs: timeoutMs)
                        }
                    },
                    writeStderr: context.io.writeStderr
                )
            }
        }
        #endif
        context.io.writeStderr(
            renderIntegrationPickerFrame(
                choices: choices,
                kind: kind,
                columns: context.io.columns(),
                rows: context.io.rows()
            ) + "\n"
        )
        let answer = try await context.io.readStdinLine("Enter \(kind) ID or number [1-\(choices.count)]: ")
        guard let raw = answer?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            throw Prompt.CancelledError()
        }
        if let idx = Int(raw), idx >= 1, idx <= choices.count {
            return choices[idx - 1].value
        }
        if let match = choices.first(where: { $0.value.lowercased() == raw.lowercased() || $0.label.lowercased() == raw.lowercased() }) {
            return match.value
        }
        throw CLIError("No \(kind) selected")
    }

    public static func runInteractiveIntegrationPicker(
        choices: [IntegrationChoice],
        kind: String = "integration",
        columns: Int = 80,
        rows: Int = 24,
        eol: String = "\n",
        nextKey: () -> Prompt.TerminalKey?,
        writeStderr: (String) -> Void
    ) throws -> String {
        guard !choices.isEmpty else {
            throw CLIError("No \(kind) selected")
        }
        var search = ""
        var cursor = 0
        var renderedLines = 0

        writeStderr("\u{1B}[?25l")
        defer { writeStderr("\u{1B}[?25h") }

        while true {
            let filtered = filterIntegrationChoices(choices, search: search)
            if filtered.isEmpty {
                cursor = 0
            } else if cursor >= filtered.count {
                cursor = filtered.count - 1
            } else if cursor < 0 {
                cursor = 0
            }

            let frame = renderIntegrationPickerFrame(
                choices: choices,
                search: search,
                cursor: cursor,
                kind: kind,
                columns: columns,
                rows: rows
            )
            let frameLines = frame.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            Prompt.DefaultTerminalBackend.redrawTerminalFrame(
                lines: frameLines,
                columns: columns,
                previousLineCount: &renderedLines,
                writeStderr: writeStderr
            )

            guard let key = nextKey() else {
                Prompt.DefaultTerminalBackend.clearTerminalFrame(previousLineCount: &renderedLines, writeStderr: writeStderr)
                writeStderr("■  Select \(kind)\(eol)")
                throw Prompt.CancelledError()
            }

            switch key {
            case .up:
                if !filtered.isEmpty {
                    cursor = (cursor - 1 + filtered.count) % filtered.count
                }
            case .down:
                if !filtered.isEmpty {
                    cursor = (cursor + 1) % filtered.count
                }
            case .enter:
                if !filtered.isEmpty {
                    let chosen = filtered[cursor]
                    Prompt.DefaultTerminalBackend.clearTerminalFrame(previousLineCount: &renderedLines, writeStderr: writeStderr)
                    writeStderr("◇  Select \(kind)\(eol)│  \(chosen.label)\(eol)")
                    return chosen.value
                }
            case .escape, .ctrlC, .ctrlD:
                Prompt.DefaultTerminalBackend.clearTerminalFrame(previousLineCount: &renderedLines, writeStderr: writeStderr)
                writeStderr("■  Select \(kind)\(eol)")
                throw Prompt.CancelledError()
            case .backspace:
                if !search.isEmpty {
                    search.removeLast()
                    cursor = 0
                }
            case .ctrlU:
                if !search.isEmpty {
                    search.removeAll()
                    cursor = 0
                }
            case .space:
                search.append(" ")
                cursor = 0
            case .character(let ch):
                search.append(ch)
                cursor = 0
            case .left, .right, .tab:
                break
            }
        }
    }

    // MARK: Prompts (`packages/cli/src/ui/prompt.ts`)

    public enum Prompt {
        public struct CancelledError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
            public init() {}
            public var description: String { "Cancelled" }
        }

        public struct SelectOption: Equatable, Hashable, Sendable {
            public let value: String
            public let label: String
            public let hint: String?

            public init(value: String, label: String, hint: String? = nil) {
                self.value = value
                self.label = label
                self.hint = hint
            }
        }

        public enum TerminalKey: Equatable, Hashable, Sendable {
            case up
            case down
            case left
            case right
            case enter
            case space
            case escape
            case ctrlC
            case ctrlD
            case ctrlU
            case backspace
            case tab
            case character(Character)
        }

        public protocol Backend: Sendable {
            func confirm(message: String, initialValue: Bool) async throws -> Bool
            func text(message: String, placeholder: String?, initialValue: String?, validate: (@Sendable (String) -> String?)?) async throws -> String
            func password(message: String, validate: (@Sendable (String) -> String?)?) async throws -> String
            func select(message: String, options: [SelectOption], initialValue: String?) async throws -> String
            func multiselect(message: String, options: [SelectOption], initialValues: [String]?, required: Bool) async throws -> [String]
        }

        public struct DefaultTerminalBackend: Backend, Sendable {
            private let io: CLIIO

            public init(io: CLIIO) {
                self.io = io
            }

            public func confirm(message: String, initialValue: Bool) async throws -> Bool {
                let hint = initialValue ? "[Y/n]" : "[y/N]"
                guard let line = try await io.readStdinLine("\(message) \(hint): ") else {
                    throw CancelledError()
                }
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if trimmed.isEmpty { return initialValue }
                if trimmed == "y" || trimmed == "yes" { return true }
                if trimmed == "n" || trimmed == "no" { return false }
                return initialValue
            }

            public func text(
                message: String,
                placeholder: String?,
                initialValue: String?,
                validate: (@Sendable (String) -> String?)?
            ) async throws -> String {
                let suffix = initialValue.map { " [\($0)]" } ?? (placeholder.map { " (\($0))" } ?? "")
                guard let line = try await io.readStdinLine("\(message)\(suffix): ") else {
                    throw CancelledError()
                }
                let value = line.isEmpty ? (initialValue ?? "") : line
                if let err = validate?(value) {
                    throw CLIError(err)
                }
                return value
            }

            public func password(message: String, validate: (@Sendable (String) -> String?)?) async throws -> String {
                let line: String
                #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
                if io.isStdinTTY(), isatty(STDIN_FILENO) != 0 {
                    line = try Self.readPOSIXPassword(
                        prompt: "\(message): ",
                        fd: STDIN_FILENO,
                        writeStderr: io.writeStderr,
                        eol: io.eol
                    )
                } else {
                    guard let fallback = try await io.readStdinLine("\(message): ") else {
                        throw CancelledError()
                    }
                    line = fallback
                }
                #else
                guard let fallback = try await io.readStdinLine("\(message): ") else {
                    throw CancelledError()
                }
                line = fallback
                #endif
                if let err = validate?(line) {
                    throw CLIError(err)
                }
                return line
            }

            public func select(message: String, options: [SelectOption], initialValue: String?) async throws -> String {
                guard !options.isEmpty else {
                    throw CancelledError()
                }
                #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
                if io.isStdinTTY() && io.isStdoutTTY(),
                   isatty(STDIN_FILENO) != 0,
                   isatty(STDOUT_FILENO) != 0
                {
                    return try Self.withNoEchoRawMode(fd: STDIN_FILENO) {
                        try Self.runInteractiveSelect(
                            message: message,
                            options: options,
                            initialValue: initialValue,
                            columns: io.columns(),
                            rows: io.rows(),
                            eol: io.eol,
                            nextKey: {
                                Self.decodeTerminalKey { timeoutMs in
                                    Self.readPOSIXByte(fd: STDIN_FILENO, timeoutMs: timeoutMs)
                                }
                            },
                            writeStderr: io.writeStderr
                        )
                    }
                }
                #endif
                io.writeStderr("\(message)\n")
                for (idx, opt) in options.enumerated() {
                    let hint = opt.hint.map { " (\($0))" } ?? ""
                    io.writeStderr("  \(idx + 1). \(opt.label)\(hint)\n")
                }
                guard let line = try await io.readStdinLine("Select [1-\(options.count)]: ") else {
                    throw CancelledError()
                }
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty, let initialValue { return initialValue }
                if let idx = Int(trimmed), idx >= 1, idx <= options.count {
                    return options[idx - 1].value
                }
                if let match = options.first(where: { $0.value == trimmed || $0.label.lowercased() == trimmed.lowercased() }) {
                    return match.value
                }
                throw CancelledError()
            }

            public func multiselect(
                message: String,
                options: [SelectOption],
                initialValues: [String]?,
                required: Bool
            ) async throws -> [String] {
                if options.isEmpty {
                    if required { throw CLIError("At least one selection is required") }
                    return []
                }
                #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
                if io.isStdinTTY() && io.isStdoutTTY(),
                   isatty(STDIN_FILENO) != 0,
                   isatty(STDOUT_FILENO) != 0
                {
                    return try Self.withNoEchoRawMode(fd: STDIN_FILENO) {
                        try Self.runInteractiveMultiselect(
                            message: message,
                            options: options,
                            initialValues: initialValues,
                            required: required,
                            columns: io.columns(),
                            rows: io.rows(),
                            eol: io.eol,
                            nextKey: {
                                Self.decodeTerminalKey { timeoutMs in
                                    Self.readPOSIXByte(fd: STDIN_FILENO, timeoutMs: timeoutMs)
                                }
                            },
                            writeStderr: io.writeStderr
                        )
                    }
                }
                #endif
                io.writeStderr("\(message) (comma-separated numbers)\n")
                for (idx, opt) in options.enumerated() {
                    let hint = opt.hint.map { " (\($0))" } ?? ""
                    io.writeStderr("  \(idx + 1). \(opt.label)\(hint)\n")
                }
                guard let line = try await io.readStdinLine("Select: ") else {
                    throw CancelledError()
                }
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    if let initialValues, !initialValues.isEmpty { return initialValues }
                    if required { throw CLIError("At least one selection is required") }
                    return []
                }
                var seen: Set<String> = []
                var out: [String] = []
                for token in trimmed.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                    if let idx = Int(token), idx >= 1, idx <= options.count {
                        let val = options[idx - 1].value
                        if seen.insert(val).inserted { out.append(val) }
                    } else if let match = options.first(where: { $0.value == token || $0.label.lowercased() == token.lowercased() }) {
                        if seen.insert(match.value).inserted { out.append(match.value) }
                    }
                }
                if out.isEmpty && required {
                    throw CLIError("At least one selection is required")
                }
                return out
            }

            // MARK: POSIX termios & Interactive TTY Helpers

            #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
            /// Disables `ECHO`, `ECHONL`, `ICANON`, and `ISIG` on a copy of `original`
            /// and configures single-byte blocking reads (`VMIN = 1, VTIME = 0`).
            public static func makeNoEchoRawTermios(from original: termios) -> termios {
                var raw = original
                let mask = tcflag_t(ECHO) | tcflag_t(ECHONL) | tcflag_t(ICANON) | tcflag_t(ISIG)
                raw.c_lflag &= ~mask
                withUnsafeMutableBytes(of: &raw.c_cc) { ccBuffer in
                    let vminIndex = Int(VMIN)
                    let vtimeIndex = Int(VTIME)
                    if vminIndex < ccBuffer.count { ccBuffer[vminIndex] = 1 }
                    if vtimeIndex < ccBuffer.count { ccBuffer[vtimeIndex] = 0 }
                }
                return raw
            }

            /// Applies no-echo raw `termios` to `fd` for the duration of `body` and
            /// unconditionally restores the original `termios` in `defer`.
            public static func withNoEchoRawMode<T>(
                fd: Int32 = STDIN_FILENO,
                _ body: () throws -> T
            ) throws -> T {
                var oldTerm = termios()
                guard tcgetattr(fd, &oldTerm) == 0 else {
                    throw CLIError("Failed to read terminal attributes (errno \(errno))")
                }
                var rawTerm = makeNoEchoRawTermios(from: oldTerm)
                guard tcsetattr(fd, TCSANOW, &rawTerm) == 0 else {
                    throw CLIError("Failed to configure terminal mode (errno \(errno))")
                }
                defer {
                    _ = tcsetattr(fd, TCSANOW, &oldTerm)
                }
                return try body()
            }

            /// Reads a masked password from POSIX TTY descriptor `fd`, restoring `termios` in `defer`.
            public static func readPOSIXPassword(
                prompt: String,
                fd: Int32 = STDIN_FILENO,
                writeStderr: (String) -> Void,
                eol: String = "\n"
            ) throws -> String {
                try withNoEchoRawMode(fd: fd) {
                    try readMaskedPassword(
                        prompt: prompt,
                        readByte: { timeoutMs in readPOSIXByte(fd: fd, timeoutMs: timeoutMs) },
                        writeStderr: writeStderr,
                        eol: eol
                    )
                }
            }

            internal static func readPOSIXByte(fd: Int32, timeoutMs: Int32? = nil) -> UInt8? {
                while true {
                    if let timeoutMs {
                        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                        let ready = poll(&pfd, 1, max(0, timeoutMs))
                        if ready < 0 {
                            if errno == EINTR { continue }
                            return nil
                        }
                        if ready == 0 || (pfd.revents & Int16(POLLIN)) == 0 {
                            return nil
                        }
                    }
                    var byte: UInt8 = 0
                    #if canImport(Darwin)
                    let n = Darwin.read(fd, &byte, 1)
                    #elseif canImport(Glibc)
                    let n = Glibc.read(fd, &byte, 1)
                    #elseif canImport(Musl)
                    let n = Musl.read(fd, &byte, 1)
                    #endif
                    if n == 1 { return byte }
                    if n < 0 && errno == EINTR { continue }
                    return nil
                }
            }
            #endif

            /// Decodes a single terminal keypress (including CSI/SS3 arrow sequences and UTF-8 bytes)
            /// from a byte reader closure.
            public static func decodeTerminalKey(
                readByte: (_ timeoutMs: Int32?) -> UInt8?
            ) -> TerminalKey? {
                while true {
                    guard let byte = readByte(nil) else { return nil }
                    switch byte {
                    case 0x03: return .ctrlC
                    case 0x04: return .ctrlD
                    case 0x09: return .tab
                    case 0x0A, 0x0D: return .enter
                    case 0x0E: return .down
                    case 0x10: return .up
                    case 0x15: return .ctrlU
                    case 0x20: return .space
                    case 0x08, 0x7F: return .backspace
                    case 0x1B:
                        guard let next = readByte(25) else {
                            return .escape
                        }
                        if next == 0x5B { // CSI: ESC [
                            var finalByte: UInt8? = nil
                            for _ in 0..<16 {
                                guard let b = readByte(25) else { break }
                                if b >= 0x40 && b <= 0x7E {
                                    finalByte = b
                                    break
                                }
                            }
                            switch finalByte {
                            case 0x41: return .up
                            case 0x42: return .down
                            case 0x43: return .right
                            case 0x44: return .left
                            default: continue
                            }
                        } else if next == 0x4F { // SS3: ESC O
                            guard let b = readByte(25) else { return .escape }
                            switch b {
                            case 0x41: return .up
                            case 0x42: return .down
                            case 0x43: return .right
                            case 0x44: return .left
                            default: continue
                            }
                        } else {
                            return .escape
                        }
                    case 0x21...0x7E:
                        return .character(Character(UnicodeScalar(byte)))
                    case 0xC0...0xFF:
                        let expectedLen: Int
                        if (byte & 0xE0) == 0xC0 {
                            expectedLen = 2
                        } else if (byte & 0xF0) == 0xE0 {
                            expectedLen = 3
                        } else if (byte & 0xF8) == 0xF0 {
                            expectedLen = 4
                        } else {
                            continue
                        }
                        var utf8Bytes: [UInt8] = [byte]
                        utf8Bytes.reserveCapacity(expectedLen)
                        for _ in 1..<expectedLen {
                            guard let cont = readByte(25) else { break }
                            utf8Bytes.append(cont)
                        }
                        if let text = String(bytes: utf8Bytes, encoding: .utf8), let first = text.first {
                            return .character(first)
                        }
                    default:
                        continue
                    }
                }
            }

            /// Interactive char-by-char masked password loop (`*` echo, backspace, Ctrl+U, Ctrl+C/Esc cancel).
            public static func readMaskedPassword(
                prompt: String,
                readByte: (_ timeoutMs: Int32?) -> UInt8?,
                writeStderr: (String) -> Void,
                eol: String = "\n"
            ) throws -> String {
                writeStderr(prompt)
                var chars: [Character] = []
                while true {
                    guard let key = decodeTerminalKey(readByte: readByte) else {
                        writeStderr(eol)
                        throw CancelledError()
                    }
                    switch key {
                    case .enter:
                        writeStderr(eol)
                        return String(chars)
                    case .ctrlC, .escape:
                        writeStderr(eol)
                        throw CancelledError()
                    case .ctrlD:
                        writeStderr(eol)
                        if chars.isEmpty {
                            throw CancelledError()
                        }
                        return String(chars)
                    case .backspace:
                        if !chars.isEmpty {
                            chars.removeLast()
                            writeStderr("\u{08} \u{08}")
                        }
                    case .ctrlU:
                        if !chars.isEmpty {
                            let count = chars.count
                            chars.removeAll()
                            writeStderr(String(repeating: "\u{08} \u{08}", count: count))
                        }
                    case .space:
                        chars.append(" ")
                        writeStderr("*")
                    case .character(let ch):
                        chars.append(ch)
                        writeStderr("*")
                    case .up, .down, .left, .right, .tab:
                        break
                    }
                }
            }

            public static func filterSelectOptions(
                _ options: [SelectOption],
                search: String
            ) -> [SelectOption] {
                guard !search.isEmpty else { return options }
                let q = search.lowercased()
                return options.filter { opt in
                    opt.label.lowercased().contains(q)
                        || opt.value.lowercased().contains(q)
                        || (opt.hint?.lowercased().contains(q) == true)
                }
            }

            public static func renderSelectFrame(
                message: String,
                options: [SelectOption],
                cursor: Int,
                search: String = "",
                searchable: Bool = false,
                rows: Int = 24,
                errorMessage: String? = nil
            ) -> [String] {
                let maxItems = max(3, min(10, rows - (searchable ? 8 : 6)))
                let safeCursor = options.isEmpty ? 0 : min(max(0, cursor), options.count - 1)
                let start = min(max(0, safeCursor - min(2, maxItems - 1)), max(0, options.count - maxItems))
                let visible = Array(options.dropFirst(start).prefix(maxItems))

                var lines: [String] = [
                    "◆  \(message)",
                ]
                if searchable {
                    lines.append("│  Search: \(search)")
                }
                if visible.isEmpty {
                    lines.append("│  No matches found")
                } else {
                    if start > 0 {
                        lines.append("│  …")
                    }
                    for (idx, opt) in visible.enumerated() {
                        let isActive = (start + idx) == safeCursor
                        let marker = isActive ? "●" : "○"
                        let hintText = opt.hint.map { " (\($0))" } ?? ""
                        lines.append("│  \(marker) \(opt.label)\(hintText)")
                    }
                    if start + maxItems < options.count {
                        lines.append("│  …")
                    }
                }
                if let errorMessage {
                    lines.append("│  ⚠ \(errorMessage)")
                }
                let footer = searchable
                    ? "↑/↓ navigate • Type to filter • Enter confirm • Esc cancel"
                    : "↑/↓ navigate • Enter confirm • Esc cancel"
                lines.append("│  \(footer)")
                lines.append("└")
                return lines
            }

            public static func renderMultiselectFrame(
                message: String,
                options: [SelectOption],
                cursor: Int,
                selectedValues: Set<String>,
                search: String = "",
                searchable: Bool = false,
                rows: Int = 24,
                errorMessage: String? = nil
            ) -> [String] {
                let maxItems = max(3, min(10, rows - (searchable ? 8 : 6)))
                let safeCursor = options.isEmpty ? 0 : min(max(0, cursor), options.count - 1)
                let start = min(max(0, safeCursor - min(2, maxItems - 1)), max(0, options.count - maxItems))
                let visible = Array(options.dropFirst(start).prefix(maxItems))

                var lines: [String] = [
                    "◆  \(message)",
                ]
                if searchable {
                    lines.append("│  Search: \(search)")
                }
                if visible.isEmpty {
                    lines.append("│  No matches found")
                } else {
                    if start > 0 {
                        lines.append("│  …")
                    }
                    for (idx, opt) in visible.enumerated() {
                        let isActive = (start + idx) == safeCursor
                        let pointer = isActive ? "❯" : " "
                        let box = selectedValues.contains(opt.value) ? "[✓]" : "[ ]"
                        let hintText = opt.hint.map { " (\($0))" } ?? ""
                        lines.append("│ \(pointer) \(box) \(opt.label)\(hintText)")
                    }
                    if start + maxItems < options.count {
                        lines.append("│  …")
                    }
                }
                if let errorMessage {
                    lines.append("│  ⚠ \(errorMessage)")
                }
                let footer = searchable
                    ? "↑/↓ navigate • Space toggle • Type to filter • Enter confirm • Esc cancel"
                    : "↑/↓ navigate • Space toggle • Enter confirm • Esc cancel"
                lines.append("│  \(footer)")
                lines.append("└")
                return lines
            }

            /// Runs the interactive arrow-key + live-filter single-select picker loop.
            public static func runInteractiveSelect(
                message: String,
                options: [SelectOption],
                initialValue: String? = nil,
                columns: Int = 80,
                rows: Int = 24,
                eol: String = "\n",
                nextKey: () -> TerminalKey?,
                writeStderr: (String) -> Void
            ) throws -> String {
                guard !options.isEmpty else {
                    throw CancelledError()
                }
                let searchable = options.count > 5
                var search = ""
                var cursor = initialValue.flatMap { target in
                    options.firstIndex(where: { $0.value == target })
                } ?? 0
                var errorMessage: String? = nil
                var renderedLines = 0

                writeStderr("\u{1B}[?25l")
                defer { writeStderr("\u{1B}[?25h") }

                while true {
                    let filtered = filterSelectOptions(options, search: search)
                    if filtered.isEmpty {
                        cursor = 0
                    } else if cursor >= filtered.count {
                        cursor = filtered.count - 1
                    } else if cursor < 0 {
                        cursor = 0
                    }

                    let frame = renderSelectFrame(
                        message: message,
                        options: filtered,
                        cursor: cursor,
                        search: search,
                        searchable: searchable,
                        rows: rows,
                        errorMessage: errorMessage
                    )
                    redrawTerminalFrame(
                        lines: frame,
                        columns: columns,
                        previousLineCount: &renderedLines,
                        writeStderr: writeStderr
                    )

                    guard let key = nextKey() else {
                        clearTerminalFrame(previousLineCount: &renderedLines, writeStderr: writeStderr)
                        writeStderr("■  \(message)\(eol)")
                        throw CancelledError()
                    }
                    errorMessage = nil

                    switch key {
                    case .up:
                        if !filtered.isEmpty {
                            cursor = (cursor - 1 + filtered.count) % filtered.count
                        }
                    case .down:
                        if !filtered.isEmpty {
                            cursor = (cursor + 1) % filtered.count
                        }
                    case .enter:
                        if filtered.isEmpty {
                            errorMessage = "No matching options"
                        } else {
                            let chosen = filtered[cursor]
                            clearTerminalFrame(previousLineCount: &renderedLines, writeStderr: writeStderr)
                            writeStderr("◇  \(message)\(eol)│  \(chosen.label)\(eol)")
                            return chosen.value
                        }
                    case .escape, .ctrlC, .ctrlD:
                        clearTerminalFrame(previousLineCount: &renderedLines, writeStderr: writeStderr)
                        writeStderr("■  \(message)\(eol)")
                        throw CancelledError()
                    case .backspace:
                        if searchable && !search.isEmpty {
                            search.removeLast()
                            cursor = 0
                        }
                    case .ctrlU:
                        if searchable && !search.isEmpty {
                            search.removeAll()
                            cursor = 0
                        }
                    case .space:
                        if searchable {
                            search.append(" ")
                            cursor = 0
                        }
                    case .character(let ch):
                        if searchable {
                            search.append(ch)
                            cursor = 0
                        } else if ch == "j", !filtered.isEmpty {
                            cursor = (cursor + 1) % filtered.count
                        } else if ch == "k", !filtered.isEmpty {
                            cursor = (cursor - 1 + filtered.count) % filtered.count
                        }
                    case .left, .right, .tab:
                        break
                    }
                }
            }

            /// Runs the interactive arrow-key + Space-toggle + live-filter multiselect picker loop.
            public static func runInteractiveMultiselect(
                message: String,
                options: [SelectOption],
                initialValues: [String]? = nil,
                required: Bool = false,
                columns: Int = 80,
                rows: Int = 24,
                eol: String = "\n",
                nextKey: () -> TerminalKey?,
                writeStderr: (String) -> Void
            ) throws -> [String] {
                if options.isEmpty {
                    if required { throw CLIError("At least one selection is required") }
                    return []
                }
                let searchable = options.count > 5
                var search = ""
                var selected = Set(initialValues ?? [])
                var cursor = 0
                var errorMessage: String? = nil
                var renderedLines = 0

                writeStderr("\u{1B}[?25l")
                defer { writeStderr("\u{1B}[?25h") }

                while true {
                    let filtered = filterSelectOptions(options, search: search)
                    if filtered.isEmpty {
                        cursor = 0
                    } else if cursor >= filtered.count {
                        cursor = filtered.count - 1
                    } else if cursor < 0 {
                        cursor = 0
                    }

                    let frame = renderMultiselectFrame(
                        message: message,
                        options: filtered,
                        cursor: cursor,
                        selectedValues: selected,
                        search: search,
                        searchable: searchable,
                        rows: rows,
                        errorMessage: errorMessage
                    )
                    redrawTerminalFrame(
                        lines: frame,
                        columns: columns,
                        previousLineCount: &renderedLines,
                        writeStderr: writeStderr
                    )

                    guard let key = nextKey() else {
                        clearTerminalFrame(previousLineCount: &renderedLines, writeStderr: writeStderr)
                        writeStderr("■  \(message)\(eol)")
                        throw CancelledError()
                    }
                    errorMessage = nil

                    switch key {
                    case .up:
                        if !filtered.isEmpty {
                            cursor = (cursor - 1 + filtered.count) % filtered.count
                        }
                    case .down:
                        if !filtered.isEmpty {
                            cursor = (cursor + 1) % filtered.count
                        }
                    case .space:
                        if !filtered.isEmpty {
                            let val = filtered[cursor].value
                            if selected.contains(val) {
                                selected.remove(val)
                            } else {
                                selected.insert(val)
                            }
                        }
                    case .enter:
                        let chosen = options.filter { selected.contains($0.value) }
                        if required && chosen.isEmpty {
                            errorMessage = "At least one selection is required"
                        } else {
                            let summary = chosen.isEmpty ? "none" : chosen.map(\.label).joined(separator: ", ")
                            clearTerminalFrame(previousLineCount: &renderedLines, writeStderr: writeStderr)
                            writeStderr("◇  \(message)\(eol)│  \(summary)\(eol)")
                            return chosen.map(\.value)
                        }
                    case .escape, .ctrlC, .ctrlD:
                        clearTerminalFrame(previousLineCount: &renderedLines, writeStderr: writeStderr)
                        writeStderr("■  \(message)\(eol)")
                        throw CancelledError()
                    case .backspace:
                        if searchable && !search.isEmpty {
                            search.removeLast()
                            cursor = 0
                        }
                    case .ctrlU:
                        if searchable && !search.isEmpty {
                            search.removeAll()
                            cursor = 0
                        }
                    case .character(let ch):
                        if searchable {
                            search.append(ch)
                            cursor = 0
                        } else if ch == "j", !filtered.isEmpty {
                            cursor = (cursor + 1) % filtered.count
                        } else if ch == "k", !filtered.isEmpty {
                            cursor = (cursor - 1 + filtered.count) % filtered.count
                        }
                    case .left, .right, .tab:
                        break
                    }
                }
            }

            internal static func redrawTerminalFrame(
                lines: [String],
                columns: Int,
                previousLineCount: inout Int,
                writeStderr: (String) -> Void
            ) {
                let maxWidth = max(20, columns - 1)
                let clipped = lines.map { line -> String in
                    if line.count <= maxWidth { return line }
                    return String(line.prefix(maxWidth - 1)) + "…"
                }
                var seq = ""
                if previousLineCount > 0 {
                    if previousLineCount > 1 {
                        seq += "\u{1B}[\(previousLineCount - 1)A"
                    }
                    seq += "\r\u{1B}[J"
                }
                seq += clipped.joined(separator: "\n")
                writeStderr(seq)
                previousLineCount = clipped.count
            }

            internal static func clearTerminalFrame(
                previousLineCount: inout Int,
                writeStderr: (String) -> Void
            ) {
                guard previousLineCount > 0 else { return }
                var seq = ""
                if previousLineCount > 1 {
                    seq += "\u{1B}[\(previousLineCount - 1)A"
                }
                seq += "\r\u{1B}[J"
                writeStderr(seq)
                previousLineCount = 0
            }
        }

        public static func backend(for context: CLIContext = CLIContext.current) -> any Backend {
            context.promptBackend ?? DefaultTerminalBackend(io: context.io)
        }

        // parity: cli/src/ui/prompt.ts#prompt [status=adapted hash=8f167b7ae8d3]
        public static func prompt<A: Sendable>(
            signal: AbortSignal = AbortController().signal,
            _ run: @Sendable (AbortSignal) async throws -> A?
        ) async throws -> A {
            guard let value = try await run(signal) else {
                throw CancelledError()
            }
            return value
        }

        // parity: cli/src/ui/prompt.ts#requireInteractive [status=implemented hash=0a6c2d35dc0b]
        public static func requireInteractive(
            _ message: String,
            context: CLIContext = CLIContext.current
        ) throws {
            guard context.io.isStdinTTY() && context.io.isStdoutTTY() else {
                throw CLIError(message)
            }
        }

        // parity: cli/src/ui/prompt.ts#openUrl [status=implemented hash=79c3c58af983]
        public static func openUrl(
            _ url: String,
            launcher: (@Sendable (String) async throws -> Void)? = nil
        ) async {
            // Best effort: headless environments may lack a browser opener, and the caller already printed the URL.
            try? await OpenExternal.openUrl(url, launcher: launcher)
        }

        // parity: cli/src/ui/prompt.ts#handlePromptErrors [status=implemented hash=7cf4b426bae5]
        public static func handlePromptErrors<A: Sendable>(
            context: CLIContext = CLIContext.current,
            _ operation: @Sendable () async throws -> A
        ) async -> A? {
            do {
                return try await operation()
            } catch is CancelledError {
                context.io.writeStderr("■ Cancelled\(context.io.eol)")
                context.exitCode.value = 130
                return nil
            } catch is CancellationError {
                context.io.writeStderr("■ Cancelled\(context.io.eol)")
                context.exitCode.value = 130
                return nil
            } catch {
                context.io.writeStderr("■ \(CLIUtil.errorMessage(error))\(context.io.eol)")
                context.io.writeStderr("└ Failed\(context.io.eol)")
                context.exitCode.value = 1
                return nil
            }
        }
    }

    // MARK: Timeline Host (`packages/cli/src/ui/timeline.tsx`)

    // parity: cli/src/ui/timeline.tsx#TimelineHost [status=implemented hash=dc9cbd9cab5b]
    public protocol TimelineHost: Sendable {
        var signal: AbortSignal { get }
        func intro(_ text: String) async throws
        func item(_ text: String) async throws
        func pending(_ text: String) async throws
        func success(_ text: String) async throws
        func failure(_ text: String) async throws
        func outro(_ text: String) async throws
        func close() async
    }

    public final class DefaultTimelineHost: TimelineHost, Sendable {
        private enum RowKind: String, Sendable {
            case intro, item, pending, success, failure, outro

            var marker: String {
                switch self {
                case .intro: return "┌"
                case .item: return "●"
                case .pending: return "."
                case .success: return "◇"
                case .failure: return "■"
                case .outro: return "└"
                }
            }

            var hasConnector: Bool {
                switch self {
                case .intro, .item, .success: return true
                case .pending, .failure, .outro: return false
                }
            }
        }

        private struct State: Sendable {
            var closed = false
            var writing = false
            var pendingText: String? = nil
        }

        private let controller = AbortController()
        private let state = Mutex(State())
        private let io: CLIIO
        private let isInteractive: Bool
        private let unsubscribeSignals: [@Sendable () -> Void]

        public var signal: AbortSignal { controller.signal }

        public init(context: CLIContext = CLIContext.current) {
            self.io = context.io
            self.isInteractive = context.io.isStdoutTTY() && context.io.isStdinTTY()
            let ctrl = self.controller
            let cancel: @Sendable () -> Void = {
                if !ctrl.signal.isAborted {
                    ctrl.abort()
                }
            }
            self.unsubscribeSignals = ["SIGINT", "SIGHUP", "SIGQUIT"].map { sig in
                ProcessSignal.subscribe(signal: sig, listener: cancel)
            }
            if isInteractive {
                io.writeStdout("\n")
            }
        }

        private func writeRow(_ kind: RowKind, _ text: String) async throws {
            try state.withLock { s in
                if s.closed { throw CLIError("timeline closed") }
                if s.writing { throw CLIError("timeline write already in progress") }
                s.writing = true
                if kind == .pending {
                    s.pendingText = text
                } else if kind == .success || kind == .failure || kind == .outro {
                    s.pendingText = nil
                }
            }
            defer { state.withLock { $0.writing = false } }
            let connector = kind.hasConnector ? "│\n" : ""
            io.writeStdout("\(kind.marker) \(text)\n\(connector)")
        }

        public func intro(_ text: String) async throws { try await writeRow(.intro, text) }
        public func item(_ text: String) async throws { try await writeRow(.item, text) }
        public func pending(_ text: String) async throws { try await writeRow(.pending, text) }
        public func success(_ text: String) async throws { try await writeRow(.success, text) }
        public func failure(_ text: String) async throws { try await writeRow(.failure, text) }
        public func outro(_ text: String) async throws { try await writeRow(.outro, text) }

        public func close() async {
            let shouldUnsub = state.withLock { s -> Bool in
                if s.closed { return false }
                s.closed = true
                return true
            }
            if shouldUnsub {
                for unsub in unsubscribeSignals { unsub() }
            }
        }
    }

    // parity: cli/src/ui/timeline.tsx#createTimelineHost [status=adapted hash=92ee791e1842]
    public static func createTimelineHost(context: CLIContext = CLIContext.current) async -> any TimelineHost {
        DefaultTimelineHost(context: context)
    }
}

extension CLIContext {
    /// Creates a default host `CLIContext` that honors `OPENCODE_CHANNEL` from `environment` when set
    /// (allowing debug builds to run with `OPENCODE_CHANNEL=latest swift run opencode`), falling back to
    /// `CLIUtil.Version.OPENCODE_CHANNEL` (`"local"` in debug builds, `"latest"` in release builds).
    public static func makeDefault(
        io: CLIIO = .system,
        environment: any EnvironmentProviding = SystemEnvironment.shared,
        fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
        transport: any HTTPTransport = URLSessionHTTPTransport.shared,
        rawArguments: [String] = Array(CommandLine.arguments.dropFirst())
    ) -> CLIContext {
        CLIContext(
            io: io,
            environment: environment,
            fileSystem: fileSystem,
            transport: transport,
            rawArguments: rawArguments,
            channel: CLIUtil.Version.resolvedChannel(environment: environment)
        )
    }
}

private extension JSONValue {
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }
}
