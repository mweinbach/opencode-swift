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
import OpenCodeSDK
import OpenCodeSchema
import OpenCodeServer
import OpenCodeTUI
import OpenCodeUtil
import OpenTUICore
import OpenTUITerminal

/// Testable library backing the `opencode` executable (`packages/cli`).
public enum OpenCodeCLIKitModule {
    public static let upstreamPackage = "cli"
    public static let serverModulePackage = OpenCodeServerModule.upstreamPackage
    public static let sdkModulePackage = OpenCodeSDKModule.upstreamPackage
}

// MARK: - Shared CLI Runtime Context & Cross-Platform I/O

/// Captured global CLI flags active during a command invocation.
public struct CLIGlobalFlagValues: Equatable, Hashable, Sendable {
    public var printLogs: Bool
    public var standalone: Bool
    public var server: String?

    public init(printLogs: Bool = false, standalone: Bool = false, server: String? = nil) {
        self.printLogs = printLogs
        self.standalone = standalone
        self.server = server
    }
}

/// Thread-safe mutable exit code box matching Node's `process.exitCode`.
public final class CLIExitCode: Sendable {
    private let state = Mutex<Int32>(0)

    public init(_ initial: Int32 = 0) {
        state.withLock { $0 = initial }
    }

    public var value: Int32 {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
}

/// Thread-safe stdout/stderr capture buffer for testing and programmatic CLI invocations.
public final class CLIBufferedOutput: Sendable {
    private struct Storage: Sendable {
        var stdout: String = ""
        var stderr: String = ""
    }

    private let storage = Mutex(Storage())

    public init() {}

    public func appendStdout(_ text: String) {
        storage.withLock { $0.stdout += text }
    }

    public func appendStderr(_ text: String) {
        storage.withLock { $0.stderr += text }
    }

    public var stdout: String {
        storage.withLock { $0.stdout }
    }

    public var stderr: String {
        storage.withLock { $0.stderr }
    }

    public func reset() {
        storage.withLock {
            $0.stdout = ""
            $0.stderr = ""
        }
    }
}

/// Injectable terminal & stream I/O layer for all CLI commands and prompts.
public struct CLIIO: Sendable {
    public let writeStdout: @Sendable (String) -> Void
    public let writeStderr: @Sendable (String) -> Void
    public let readStdinAll: @Sendable () async throws -> String
    public let readStdinLine: @Sendable (String?) async throws -> String?
    public let isStdinTTY: @Sendable () -> Bool
    public let isStdoutTTY: @Sendable () -> Bool
    public let columns: @Sendable () -> Int
    public let rows: @Sendable () -> Int
    public let eol: String

    public init(
        writeStdout: @escaping @Sendable (String) -> Void,
        writeStderr: @escaping @Sendable (String) -> Void,
        readStdinAll: @escaping @Sendable () async throws -> String,
        readStdinLine: @escaping @Sendable (String?) async throws -> String?,
        isStdinTTY: @escaping @Sendable () -> Bool,
        isStdoutTTY: @escaping @Sendable () -> Bool,
        columns: @escaping @Sendable () -> Int = { 80 },
        rows: @escaping @Sendable () -> Int = { 24 },
        eol: String = Platform.current == .windows ? "\r\n" : "\n"
    ) {
        self.writeStdout = writeStdout
        self.writeStderr = writeStderr
        self.readStdinAll = readStdinAll
        self.readStdinLine = readStdinLine
        self.isStdinTTY = isStdinTTY
        self.isStdoutTTY = isStdoutTTY
        self.columns = columns
        self.rows = rows
        self.eol = eol
    }

    public static var system: CLIIO {
        CLIIO(
            writeStdout: { text in
                #if !os(WASI)
                if let data = text.data(using: .utf8) {
                    try? FileHandle.standardOutput.write(contentsOf: data)
                }
                #else
                print(text, terminator: "")
                #endif
            },
            writeStderr: { text in
                #if !os(WASI)
                if let data = text.data(using: .utf8) {
                    try? FileHandle.standardError.write(contentsOf: data)
                }
                #else
                print(text, terminator: "")
                #endif
            },
            readStdinAll: {
                #if !os(WASI)
                let data = FileHandle.standardInput.readDataToEndOfFile()
                return String(decoding: data, as: UTF8.self)
                #else
                return ""
                #endif
            },
            readStdinLine: { promptText in
                #if !os(WASI)
                if let promptText, let data = promptText.data(using: .utf8) {
                    try? FileHandle.standardError.write(contentsOf: data)
                }
                return Swift.readLine(strippingNewline: true)
                #else
                _ = promptText
                return nil
                #endif
            },
            isStdinTTY: {
                #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
                return isatty(STDIN_FILENO) != 0
                #else
                return false
                #endif
            },
            isStdoutTTY: {
                #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
                return isatty(STDOUT_FILENO) != 0
                #else
                return false
                #endif
            },
            columns: {
                #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
                var ws = winsize()
                if ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &ws) == 0, ws.ws_col > 0 {
                    return Int(ws.ws_col)
                }
                #endif
                if let cols = SystemEnvironment.shared.variable("COLUMNS").flatMap(Int.init), cols > 0 {
                    return cols
                }
                return 80
            },
            rows: {
                #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
                var ws = winsize()
                if ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &ws) == 0, ws.ws_row > 0 {
                    return Int(ws.ws_row)
                }
                #endif
                if let rows = SystemEnvironment.shared.variable("LINES").flatMap(Int.init), rows > 0 {
                    return rows
                }
                return 24
            }
        )
    }

    public static func buffered(
        output: CLIBufferedOutput = CLIBufferedOutput(),
        stdinText: String = "",
        stdinLines: [String]? = nil,
        isStdinTTY: Bool = false,
        isStdoutTTY: Bool = false,
        columns: Int = 80,
        rows: Int = 24,
        eol: String = "\n"
    ) -> CLIIO {
        let lineQueue = Mutex<[String]>(stdinLines ?? stdinText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
        return CLIIO(
            writeStdout: { output.appendStdout($0) },
            writeStderr: { output.appendStderr($0) },
            readStdinAll: { stdinText },
            readStdinLine: { _ in
                lineQueue.withLock { queue in
                    guard !queue.isEmpty else { return nil }
                    return queue.removeFirst()
                }
            },
            isStdinTTY: { isStdinTTY },
            isStdoutTTY: { isStdoutTTY },
            columns: { columns },
            rows: { rows },
            eol: eol
        )
    }
}

/// Host process handle conforming to `OpenCodeClient.ServiceChildProcessHandle`.
public final class HostServiceChildProcessHandle: ServiceChildProcessHandle, @unchecked Sendable {
    private struct State: Sendable {
        var pid: Int?
        var exitCode: Int32?
        var signalCode: String?
        var onStderr: (@Sendable ([UInt8]) -> Void)?
        var onError: (@Sendable (any Error & Sendable) -> Void)?
        var onClose: (@Sendable () -> Void)?
        var pendingStderr: [[UInt8]] = []
        var pendingError: (any Error & Sendable)?
        var isClosed: Bool = false
    }

    private let state = Mutex(State())
    #if os(macOS) || os(Linux) || os(Windows)
    private let process: Process?
    private let stderrPipe: Pipe?
    #endif

    #if os(macOS) || os(Linux) || os(Windows)
    public init(process: Process, stderrPipe: Pipe) {
        self.process = process
        self.stderrPipe = stderrPipe
        self.state.withLock { $0.pid = Int(process.processIdentifier) }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            let bytes = Array(data)
            let cb = self?.state.withLock { s -> (@Sendable ([UInt8]) -> Void)? in
                if let handler = s.onStderr { return handler }
                s.pendingStderr.append(bytes)
                return nil
            }
            cb?(bytes)
        }
        process.terminationHandler = { [weak self] proc in
            let cb = self?.state.withLock { s -> (@Sendable () -> Void)? in
                if proc.terminationReason == .uncaughtSignal {
                    s.signalCode = "SIG\(proc.terminationStatus)"
                } else {
                    s.exitCode = proc.terminationStatus
                }
                s.isClosed = true
                return s.onClose
            }
            cb?()
        }
    }
    #endif

    public init(error: any Error & Sendable) {
        #if os(macOS) || os(Linux) || os(Windows)
        self.process = nil
        self.stderrPipe = nil
        #endif
        self.state.withLock {
            $0.pendingError = error
            $0.isClosed = true
        }
    }

    public var pid: Int? { state.withLock { $0.pid } }
    public var exitCode: Int32? { state.withLock { $0.exitCode } }
    public var signalCode: String? { state.withLock { $0.signalCode } }

    public func setHandlers(
        onStderr: @escaping @Sendable ([UInt8]) -> Void,
        onError: @escaping @Sendable (any Error & Sendable) -> Void,
        onClose: @escaping @Sendable () -> Void
    ) {
        let snapshot = state.withLock { s -> ([[UInt8]], (any Error & Sendable)?, Bool) in
            s.onStderr = onStderr
            s.onError = onError
            s.onClose = onClose
            let chunks = s.pendingStderr
            let err = s.pendingError
            let closed = s.isClosed
            s.pendingStderr.removeAll()
            s.pendingError = nil
            return (chunks, err, closed)
        }
        for chunk in snapshot.0 {
            onStderr(chunk)
        }
        if let err = snapshot.1 {
            onError(err)
        }
        if snapshot.2 {
            onClose()
        }
    }

    public func releaseStderr() {
        #if os(macOS) || os(Linux) || os(Windows)
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        #endif
        state.withLock { $0.onStderr = nil }
    }
}

/// Host `ServiceProcessLauncher` spawning detached background `opencode serve --service` processes.
public struct HostServiceProcessLauncher: ServiceProcessLauncher, Sendable {
    public static let shared = HostServiceProcessLauncher()

    public init() {}

    public func spawn(command: String, args: [String], env: [String: String]) throws -> any ServiceChildProcessHandle {
        #if os(macOS) || os(Linux) || os(Windows)
        let process = Process()
        if command.contains("/") || command.contains("\\") {
            process.executableURL = URL(fileURLWithPath: command)
            process.arguments = args
        } else {
            #if os(Windows)
            process.executableURL = URL(fileURLWithPath: "C:\\Windows\\System32\\cmd.exe")
            process.arguments = ["/c", command] + args
            #else
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [command] + args
            #endif
        }
        var mergedEnv = ProcessInfo.processInfo.environment
        for (k, v) in env {
            mergedEnv[k] = v
        }
        process.environment = mergedEnv
        let stderrPipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe
        try process.run()
        return HostServiceChildProcessHandle(process: process, stderrPipe: stderrPipe)
        #else
        throw PlatformError.unsupportedOnPlatform(Platform.current, operation: "HostServiceProcessLauncher.spawn")
        #endif
    }
}

/// Host `ServiceProcessSignaler` using POSIX `kill` where available.
public struct HostServiceProcessSignaler: ServiceProcessSignaler, Sendable {
    public static let shared = HostServiceProcessSignaler()

    public init() {}

    public func sendSignal(pid: Int, signal: String) {
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        let sig: Int32
        switch signal.uppercased() {
        case "SIGKILL", "KILL": sig = SIGKILL
        case "SIGINT", "INT": sig = SIGINT
        case "SIGHUP", "HUP": sig = SIGHUP
        case "SIGUSR1", "USR1": sig = SIGUSR1
        default: sig = SIGTERM
        }
        _ = kill(pid_t(pid), sig)
        #else
        _ = (pid, signal)
        #endif
    }

    public func isRunning(pid: Int) -> Bool {
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        if pid <= 0 { return false }
        if kill(pid_t(pid), 0) == 0 { return true }
        return errno == EPERM
        #else
        _ = pid
        return false
        #endif
    }
}

/// Unified error type for CLI operations.
public struct CLIError: Error, Equatable, Sendable, CustomStringConvertible {
    public let message: String
    public let exitCode: Int32
    public let code: String?

    public init(_ message: String, exitCode: Int32 = 1, code: String? = nil) {
        self.message = message
        self.exitCode = exitCode
        self.code = code
    }

    public var description: String { message }
}

/// Injectable execution context passed through CLI commands, services, and helpers.
public final class CLIContext: Sendable {
    @TaskLocal public static var current: CLIContext = CLIContext()

    public let io: CLIIO
    public let environment: any EnvironmentProviding
    public let fileSystem: any OpenCodeFileSystem
    public let transport: any HTTPTransport
    public let spawner: any ProcessSpawner
    public let launcher: any ServiceProcessLauncher
    public let signaler: any ServiceProcessSignaler
    public let executablePath: String
    public let rawArguments: [String]
    public let exitCode: CLIExitCode
    public let globalOverrides: Global.Overrides
    public let version: String
    public let channel: String
    public let artifact: String
    public let platformOS: PlatformOS
    public let configServiceOverride: (any CLIConfig.Interface)?
    public let updaterServiceOverride: (any CLIServices.Updater.Interface)?
    public let npmServiceOverride: (any NpmPlatform.Interface)?
    public let serverStarter: CLIServices.ServerProcess.Starter?
    public let remoteTunnelBackend: (any CLIServices.RemoteTunnel.Backend)?
    public let promptBackend: (any CLIUI.Prompt.Backend)?
    public let acpRunner: (@Sendable (CLIContext, Bool) async throws -> Int32)?
    public let tuiRunner: (@Sendable (TUIApp.TuiInput) async throws -> TUIApp.RunResult)?
    public let miniRunner: (@Sendable (CLIRun.Mini.MiniCommandInput) async throws -> Void)?

    private let mutableCwd: Mutex<String>
    private let mutableGlobalFlags: Mutex<CLIGlobalFlagValues>
    private let mutableEnvOverrides: Mutex<[String: String]>

    public init(
        io: CLIIO = .system,
        environment: any EnvironmentProviding = SystemEnvironment.shared,
        fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
        transport: any HTTPTransport = URLSessionHTTPTransport.shared,
        spawner: any ProcessSpawner = CrossSpawnSpawner.HostProcessSpawner.shared,
        launcher: any ServiceProcessLauncher = HostServiceProcessLauncher.shared,
        signaler: any ServiceProcessSignaler = HostServiceProcessSignaler.shared,
        cwd: String? = nil,
        executablePath: String? = nil,
        rawArguments: [String] = Array(CommandLine.arguments.dropFirst()),
        exitCode: CLIExitCode = CLIExitCode(),
        globalOverrides: Global.Overrides = Global.Overrides(),
        version: String = CLIUtil.Version.OPENCODE_VERSION,
        channel: String = CLIUtil.Version.OPENCODE_CHANNEL,
        artifact: String = CLIUtil.Version.OPENCODE_ARTIFACT,
        platformOS: PlatformOS = Platform.current,
        globalFlags: CLIGlobalFlagValues = CLIGlobalFlagValues(),
        configService: (any CLIConfig.Interface)? = nil,
        updaterService: (any CLIServices.Updater.Interface)? = nil,
        npmService: (any NpmPlatform.Interface)? = nil,
        serverStarter: CLIServices.ServerProcess.Starter? = nil,
        remoteTunnelBackend: (any CLIServices.RemoteTunnel.Backend)? = nil,
        promptBackend: (any CLIUI.Prompt.Backend)? = nil,
        acpRunner: (@Sendable (CLIContext, Bool) async throws -> Int32)? = nil,
        tuiRunner: (@Sendable (TUIApp.TuiInput) async throws -> TUIApp.RunResult)? = nil,
        miniRunner: (@Sendable (CLIRun.Mini.MiniCommandInput) async throws -> Void)? = nil
    ) {
        self.io = io
        self.environment = environment
        self.fileSystem = fileSystem
        self.transport = transport
        self.spawner = spawner
        self.launcher = launcher
        self.signaler = signaler
        #if os(WASI)
        let defaultCwd = "/"
        #else
        let defaultCwd = FileManager.default.currentDirectoryPath
        #endif
        self.mutableCwd = Mutex(cwd ?? defaultCwd)
        self.executablePath = executablePath ?? CommandLine.arguments.first ?? "opencode"
        self.rawArguments = rawArguments
        self.exitCode = exitCode
        self.globalOverrides = globalOverrides
        self.version = version
        self.channel = channel
        self.artifact = artifact
        self.platformOS = platformOS
        self.mutableGlobalFlags = Mutex(globalFlags)
        self.mutableEnvOverrides = Mutex([:])
        self.configServiceOverride = configService
        self.updaterServiceOverride = updaterService
        self.npmServiceOverride = npmService
        self.serverStarter = serverStarter
        self.remoteTunnelBackend = remoteTunnelBackend
        self.promptBackend = promptBackend
        self.acpRunner = acpRunner
        self.tuiRunner = tuiRunner
        self.miniRunner = miniRunner
    }

    public var cwd: String {
        get { mutableCwd.withLock { $0 } }
        set { mutableCwd.withLock { $0 = newValue } }
    }

    public var globalFlags: CLIGlobalFlagValues {
        get { mutableGlobalFlags.withLock { $0 } }
        set { mutableGlobalFlags.withLock { $0 = newValue } }
    }

    public func envVariable(_ key: String) -> String? {
        if let override = mutableEnvOverrides.withLock({ $0[key] }) {
            return override
        }
        return environment.variable(key)
    }

    public func setEnvOverride(_ key: String, value: String?) {
        mutableEnvOverrides.withLock { dict in
            if let value {
                dict[key] = value
            } else {
                dict.removeValue(forKey: key)
            }
        }
    }

    public var globalPaths: Global.Interface {
        var overrides = globalOverrides
        if overrides.config == nil, let envConfig = envVariable("OPENCODE_CONFIG_DIR"), !envConfig.isEmpty {
            overrides.config = envConfig
        }
        return Global.make(overrides, environment: environment, os: platformOS)
    }

    public var appProcess: AppProcess.Service {
        AppProcess.Service(spawner: spawner)
    }

    public var npmService: any NpmPlatform.Interface {
        if let override = npmServiceOverride { return override }
        let paths = globalPaths
        return NpmPlatform.Service(
            cacheRoot: paths.cache,
            fsUtil: FSUtil.Service(fileSystem: fileSystem),
            flock: EffectFlock.Service(lockRoot: CLIPath.join(paths.state, "locks"), fileSystem: fileSystem)
        )
    }

    public var configService: any CLIConfig.Interface {
        if let override = configServiceOverride { return override }
        return CLIConfig.Service(context: self)
    }

    public var updaterService: any CLIServices.Updater.Interface {
        if let override = updaterServiceOverride { return override }
        return CLIServices.Updater.Service(context: self)
    }

    public func makeClient(endpoint: ServiceEndpoint) -> OpenCodeClient {
        OpenCode.make(
            ClientOptions(
                baseUrl: endpoint.url,
                transport: transport,
                headers: OpenCodeClient.headers(for: endpoint) ?? [:]
            )
        )
    }

    public var currentPID: Int32 {
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        return getpid()
        #else
        return 1
        #endif
    }
}

extension OpenCodeClient {
    /// Convenience forwarding to `OpenCodeClient.headers(for:)` so callers inside `OpenCodeCLIKit` don't collide on `headers`.
    internal static func headers(for endpoint: ServiceEndpoint) -> [String: String]? {
        OpenCodeClient.serviceHeaders(for: endpoint)
    }

    internal static func serviceHeaders(for endpoint: ServiceEndpoint) -> [String: String]? {
        guard let auth = endpoint.auth else { return nil }
        return [
            "authorization": ClientHTTPHeaders.basicAuthorization(username: auth.username, password: auth.password),
        ]
    }
}

// MARK: - Internal Cross-Platform Path & Random Helpers

internal enum CLIPath {
    static func join(_ parts: String...) -> String {
        join(parts)
    }

    static func join(_ parts: [String]) -> String {
        var cleaned: [String] = []
        for (idx, part) in parts.enumerated() where !part.isEmpty {
            var s = part
            if idx > 0 {
                while s.hasPrefix("/") { s.removeFirst() }
            }
            while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
            cleaned.append(s)
        }
        return cleaned.joined(separator: "/")
    }

    static func isAbsolute(_ path: String) -> Bool {
        if path.hasPrefix("/") || path.hasPrefix("\\\\") { return true }
        let chars = Array(path)
        if chars.count >= 3, chars[0].isLetter, chars[1] == ":", (chars[2] == "/" || chars[2] == "\\") {
            return true
        }
        return false
    }

    static func resolve(_ base: String, _ target: String) -> String {
        let combined = isAbsolute(target) ? target : join(base, target)
        return normalize(combined)
    }

    static func normalize(_ raw: String) -> String {
        let isAbs = raw.hasPrefix("/")
        let replaced = raw.replacing("\\", with: "/")
        var parts: [String] = []
        for seg in replaced.split(separator: "/") {
            if seg.isEmpty || seg == "." { continue }
            if seg == ".." {
                if let last = parts.last, last != ".." {
                    parts.removeLast()
                } else if !isAbs {
                    parts.append("..")
                }
            } else {
                parts.append(String(seg))
            }
        }
        let body = parts.joined(separator: "/")
        if isAbs { return "/" + body }
        return body.isEmpty ? "." : body
    }

    static func dirname(_ raw: String) -> String {
        let norm = raw.replacing("\\", with: "/")
        let trimmed = norm.count > 1 && norm.hasSuffix("/") ? String(norm.dropLast()) : norm
        guard let slash = trimmed.lastIndex(of: "/") else { return "." }
        if slash == trimmed.startIndex { return "/" }
        return String(trimmed[..<slash])
    }

    static func basename(_ raw: String, dropExtension: Bool = false) -> String {
        let norm = raw.replacing("\\", with: "/")
        let trimmed = norm.count > 1 && norm.hasSuffix("/") ? String(norm.dropLast()) : norm
        let base: String
        if let slash = trimmed.lastIndex(of: "/") {
            base = String(trimmed[trimmed.index(after: slash)...])
        } else {
            base = trimmed
        }
        if dropExtension, let dot = base.lastIndex(of: "."), dot != base.startIndex {
            return String(base[..<dot])
        }
        return base
    }

    static func relative(from base: String, to target: String) -> String {
        let fromParts = normalize(base).split(separator: "/").map(String.init)
        let toParts = normalize(target).split(separator: "/").map(String.init)
        var common = 0
        while common < fromParts.count && common < toParts.count && fromParts[common] == toParts[common] {
            common += 1
        }
        let ups = Array(repeating: "..", count: fromParts.count - common)
        let rest = Array(toParts.dropFirst(common))
        return (ups + rest).joined(separator: "/")
    }

    static func randomBytes(_ count: Int) -> [UInt8] {
        var rng = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: 0...255, using: &rng) }
    }

    static func randomHex(bytes count: Int) -> String {
        let digits = Array("0123456789abcdef".utf8)
        let raw = randomBytes(count)
        var out: [UInt8] = []
        out.reserveCapacity(count * 2)
        for b in raw {
            out.append(digits[Int(b >> 4)])
            out.append(digits[Int(b & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    static func randomBase64URL(bytes count: Int) -> String {
        bytesToBase64(randomBytes(count))
            .replacing("+", with: "-")
            .replacing("/", with: "_")
            .replacing("=", with: "")
    }

    static func stripANSI(_ input: String) -> String {
        var result = ""
        result.reserveCapacity(input.count)
        let scalars = Array(input.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let s = scalars[i]
            if s.value == 0x1B, i + 1 < scalars.count {
                let next = scalars[i + 1]
                if next == "[" {
                    i += 2
                    while i < scalars.count {
                        let c = scalars[i].value
                        i += 1
                        if c >= 0x40 && c <= 0x7E { break }
                    }
                    continue
                } else if next == "]" {
                    i += 2
                    while i < scalars.count {
                        let c = scalars[i].value
                        if c == 0x07 {
                            i += 1
                            break
                        }
                        if c == 0x1B, i + 1 < scalars.count, scalars[i + 1] == "\\" {
                            i += 2
                            break
                        }
                        i += 1
                    }
                    continue
                }
            }
            result.unicodeScalars.append(s)
            i += 1
        }
        return result
    }

    static func encodePrettyJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    static func encodeCompactJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    static func currentEpochMs() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1_000.0).rounded())
    }
}
