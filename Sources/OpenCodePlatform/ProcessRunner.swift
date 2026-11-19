#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Synchronization
import OpenCodeUtil

// MARK: - CrossSpawnSpawner (`cross-spawn-spawner.ts`)

public enum CrossSpawnSpawner {
    /// Closing a child's scope escalates to SIGKILL after this duration unless overridden.
    // parity: util/src/cross-spawn-spawner.ts#RELEASE_FORCE_KILL_AFTER [status=implemented hash=eead7c55cc8e]
    public static let RELEASE_FORCE_KILL_AFTER = "3 seconds"

    // parity: util/src/cross-spawn-spawner.ts#KilledBySignal [status=implemented hash=1903b260c62e]
    public struct KilledBySignal: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public let signal: String

        public init(signal: String) {
            self.signal = signal
        }

        public var message: String {
            "Process interrupted due to receipt of signal: '\(signal)'"
        }

        public var description: String { message }
    }

    /// Host process spawner using `Foundation.Process` on desktop OSes (macOS, Linux, Windows).
    public struct HostProcessSpawner: ProcessSpawner, Sendable {
        public static let shared = HostProcessSpawner()

        public init() {}

        public func run(_ spec: ProcessSpec) async throws -> ProcessOutput {
            #if os(macOS) || os(Linux) || os(Windows)
            // Validate no NUL characters in command/args/env matching upstream `findNulCharacter`.
            if spec.executable.contains("\u{0}") {
                throw PlatformError.ioFailure("The command contains a NUL character")
            }
            for (idx, arg) in spec.arguments.enumerated() where arg.contains("\u{0}") {
                throw PlatformError.ioFailure("Argument \(idx + 1) contains a NUL character")
            }
            if let env = spec.environment {
                for (name, value) in env where value.contains("\u{0}") {
                    throw PlatformError.ioFailure("The environment variable \(name) contains a NUL character")
                }
            }

            let process = Process()
            if spec.executable.contains("/") || spec.executable.contains("\\") {
                process.executableURL = URL(fileURLWithPath: spec.executable)
                process.arguments = spec.arguments
            } else {
                #if os(Windows)
                process.executableURL = URL(fileURLWithPath: "C:\\Windows\\System32\\cmd.exe")
                process.arguments = ["/c", spec.executable] + spec.arguments
                #else
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = [spec.executable] + spec.arguments
                #endif
            }
            if let cwd = spec.workingDirectory {
                process.currentDirectoryURL = URL(fileURLWithPath: cwd)
            }
            if let env = spec.environment {
                process.environment = env
            }

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            var stdinPipe: Pipe? = nil
            if spec.stdin != nil {
                let pipe = Pipe()
                process.standardInput = pipe
                stdinPipe = pipe
            }

            let settle = Teardown.track("process \(spec.executable)")
            defer { settle() }

            try process.run()
            if let inputBytes = spec.stdin, let pipe = stdinPipe {
                try pipe.fileHandleForWriting.write(contentsOf: Data(inputBytes))
                try pipe.fileHandleForWriting.close()
            }

            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            return ProcessOutput(
                exitCode: process.terminationStatus,
                stdout: Array(stdoutData),
                stderr: Array(stderrData)
            )
            #else
            throw PlatformError.unsupportedOnPlatform(Platform.current, operation: "ProcessSpawner.run")
            #endif
        }
    }

    public static let spawnerKey = "@opencode/ChildProcessSpawner"

    // parity: util/src/cross-spawn-spawner.ts#node [status=implemented hash=dcfc1a1b751f]
    public static let node: LayerNode.Provider = AppNode.makeGlobalNode(
        spawnerKey,
        LayerNode.ExecutableLayer.succeed(key: spawnerKey, value: HostProcessSpawner.shared as any ProcessSpawner),
        [LayerNodePlatform.filesystem, LayerNodePlatform.path]
    )
}

// MARK: - AppProcess (`process.ts`)

public enum AppProcess {
    // parity: util/src/process.ts#AppProcessError [status=implemented hash=59c5d12b4a1c]
    public struct AppProcessError: Error, Equatable, Sendable, CustomStringConvertible {
        public let command: String
        public let exitCode: Int32?
        public let stderr: String?
        public let causeMessage: String?

        public init(
            command: String,
            exitCode: Int32? = nil,
            stderr: String? = nil,
            causeMessage: String? = nil
        ) {
            self.command = command
            self.exitCode = exitCode
            self.stderr = stderr
            self.causeMessage = causeMessage
        }

        public var message: String {
            let trimmedStderr = stderr?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let detail = !trimmedStderr.isEmpty ? trimmedStderr : (causeMessage ?? "")
            let status = exitCode.map { " (exit \($0))" } ?? ""
            return "Command failed\(status): \(command)\(detail.isEmpty ? "" : ": \(detail)")"
        }

        public var description: String { message }
    }

    // parity: util/src/process.ts#RunOptions [status=implemented hash=29d3ed343c62]
    public struct RunOptions: Sendable {
        public let combineOutput: Bool
        public let maxOutputBytes: Int?
        public let maxErrorBytes: Int?
        public let signal: AbortSignal?
        public let timeoutMs: Int?
        public let stdin: [UInt8]?

        public init(
            combineOutput: Bool = false,
            maxOutputBytes: Int? = nil,
            maxErrorBytes: Int? = nil,
            signal: AbortSignal? = nil,
            timeoutMs: Int? = nil,
            stdin: [UInt8]? = nil
        ) {
            self.combineOutput = combineOutput
            self.maxOutputBytes = maxOutputBytes
            self.maxErrorBytes = maxErrorBytes
            self.signal = signal
            self.timeoutMs = timeoutMs
            self.stdin = stdin
        }
    }

    // parity: util/src/process.ts#RunStreamOptions [status=implemented hash=9a4178d3acfb]
    public struct RunStreamOptions: Sendable {
        public let signal: AbortSignal?
        public let includeStderr: Bool
        public let okExitCodes: [Int32]?
        public let maxErrorBytes: Int?

        public init(
            signal: AbortSignal? = nil,
            includeStderr: Bool = false,
            okExitCodes: [Int32]? = nil,
            maxErrorBytes: Int? = nil
        ) {
            self.signal = signal
            self.includeStderr = includeStderr
            self.okExitCodes = okExitCodes
            self.maxErrorBytes = maxErrorBytes
        }
    }

    // parity: util/src/process.ts#RunResult [status=implemented hash=9dc13df2e011]
    public struct RunResult: Equatable, Sendable {
        public let command: String
        public let exitCode: Int32
        public let output: [UInt8]?
        public let stdout: [UInt8]
        public let stderr: [UInt8]
        public let outputTruncated: Bool?
        public let stdoutTruncated: Bool
        public let stderrTruncated: Bool

        public init(
            command: String,
            exitCode: Int32,
            output: [UInt8]? = nil,
            stdout: [UInt8],
            stderr: [UInt8],
            outputTruncated: Bool? = nil,
            stdoutTruncated: Bool = false,
            stderrTruncated: Bool = false
        ) {
            self.command = command
            self.exitCode = exitCode
            self.output = output
            self.stdout = stdout
            self.stderr = stderr
            self.outputTruncated = outputTruncated
            self.stdoutTruncated = stdoutTruncated
            self.stderrTruncated = stderrTruncated
        }
    }

    // parity: util/src/process.ts#Interface [status=implemented hash=016a061d3ff5]
    public protocol Interface: Sendable {
        func run(_ spec: ProcessSpec, options: RunOptions) async throws -> RunResult
        func runStream(_ spec: ProcessSpec, options: RunStreamOptions) -> AsyncThrowingStream<String, Error>
    }

    // parity: util/src/process.ts#Service [status=implemented hash=b6e2fa738603]
    public final class Service: Interface, Sendable {
        public static let serviceKey = "@opencode/AppProcess"
        private let spawner: any ProcessSpawner

        public init(spawner: any ProcessSpawner = CrossSpawnSpawner.HostProcessSpawner.shared) {
            self.spawner = spawner
        }

        public func run(_ spec: ProcessSpec, options: RunOptions = RunOptions()) async throws -> RunResult {
            let description = spec.arguments.isEmpty
                ? spec.executable
                : "\(spec.executable) \(spec.arguments.joined(separator: " "))"
            if let signal = options.signal, signal.isAborted {
                let err = AppProcess.abortError(signal)
                throw AppProcessError(command: description, causeMessage: String(describing: err))
            }
            let effectiveSpec = options.stdin != nil
                ? ProcessSpec(
                    executable: spec.executable,
                    arguments: spec.arguments,
                    workingDirectory: spec.workingDirectory,
                    environment: spec.environment,
                    stdin: options.stdin
                )
                : spec
            do {
                let raw = try await spawner.run(effectiveSpec)
                if options.combineOutput {
                    let combined = AppProcess.collectStream([raw.stdout, raw.stderr], maxOutputBytes: options.maxOutputBytes)
                    return RunResult(
                        command: description,
                        exitCode: raw.exitCode,
                        output: combined.buffer,
                        stdout: [],
                        stderr: [],
                        outputTruncated: combined.truncated,
                        stdoutTruncated: false,
                        stderrTruncated: false
                    )
                }
                let out = AppProcess.collectStream([raw.stdout], maxOutputBytes: options.maxOutputBytes)
                let err = AppProcess.collectStream([raw.stderr], maxOutputBytes: options.maxErrorBytes)
                return RunResult(
                    command: description,
                    exitCode: raw.exitCode,
                    stdout: out.buffer,
                    stderr: err.buffer,
                    stdoutTruncated: out.truncated,
                    stderrTruncated: err.truncated
                )
            } catch let e as AppProcessError {
                throw e
            } catch {
                throw AppProcessError(command: description, causeMessage: String(describing: error))
            }
        }

        public func runStream(_ spec: ProcessSpec, options: RunStreamOptions = RunStreamOptions()) -> AsyncThrowingStream<String, Error> {
            let service = self
            return AsyncThrowingStream { continuation in
                Task {
                    do {
                        let result = try await service.run(
                            spec,
                            options: RunOptions(
                                combineOutput: options.includeStderr,
                                maxErrorBytes: options.maxErrorBytes,
                                signal: options.signal
                            )
                        )
                        let bytes = options.includeStderr ? (result.output ?? []) : result.stdout
                        let text = String(decoding: bytes, as: UTF8.self)
                        for line in text.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                            continuation.yield(String(line))
                        }
                        if let okCodes = options.okExitCodes, !okCodes.isEmpty, !okCodes.contains(result.exitCode) {
                            continuation.finish(throwing: AppProcessError(
                                command: result.command,
                                exitCode: result.exitCode,
                                stderr: String(decoding: result.stderr, as: UTF8.self)
                            ))
                            return
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
        }
    }

    // parity: util/src/process.ts#requireSuccess [status=implemented hash=4b5f58493165]
    public static func requireSuccess(_ result: RunResult) throws -> RunResult {
        if result.exitCode == 0 { return result }
        throw AppProcessError(
            command: result.command,
            exitCode: result.exitCode,
            stderr: String(decoding: result.stderr, as: UTF8.self)
        )
    }

    // parity: util/src/process.ts#requireExitIn [status=implemented hash=07ddd077561e]
    public static func requireExitIn(_ codes: [Int32]) -> @Sendable (RunResult) throws -> RunResult {
        { result in
            if codes.contains(result.exitCode) { return result }
            throw AppProcessError(
                command: result.command,
                exitCode: result.exitCode,
                stderr: String(decoding: result.stderr, as: UTF8.self)
            )
        }
    }

    // parity: util/src/process.ts#abortError [status=implemented hash=5bdccdadee1f]
    public static func abortError(_ signal: AbortSignal) -> any Error {
        if let reason = signal.reason { return reason }
        return AbortError(message: "Aborted", name: "AbortError")
    }

    // parity: util/src/process.ts#waitForAbort [status=implemented hash=1f3e77df358a]
    public static func waitForAbort(_ signal: AbortSignal) async throws -> Never {
        if signal.isAborted {
            throw abortError(signal)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let resumed = Mutex(false)
            _ = signal.onAbort {
                let shouldResume = resumed.withLock { done -> Bool in
                    if done { return false }
                    done = true
                    return true
                }
                if shouldResume {
                    continuation.resume(throwing: abortError(signal))
                }
            }
        }
        throw abortError(signal)
    }

    // parity: util/src/process.ts#collectStream [status=implemented hash=50d0a7cff772]
    public static func collectStream(
        _ chunks: [[UInt8]],
        maxOutputBytes: Int?
    ) -> (buffer: [UInt8], truncated: Bool) {
        var collected: [UInt8] = []
        var totalBytes = 0
        var truncated = false
        for chunk in chunks {
            if let maxOutputBytes {
                let remaining = maxOutputBytes - totalBytes
                if remaining > 0 {
                    if remaining >= chunk.count {
                        collected.append(contentsOf: chunk)
                    } else {
                        collected.append(contentsOf: chunk.prefix(remaining))
                    }
                }
                totalBytes += chunk.count
                if totalBytes > maxOutputBytes { truncated = true }
            } else {
                collected.append(contentsOf: chunk)
                totalBytes += chunk.count
            }
        }
        return (buffer: collected, truncated: truncated)
    }

    // parity: util/src/process.ts#node [status=implemented hash=c10cdaefc7ab]
    public static let node: LayerNode.Provider = AppNode.makeGlobalNode(
        Service.serviceKey,
        LayerNode.ExecutableLayer { deps, _ in
            let spawner = deps.get(CrossSpawnSpawner.spawnerKey, as: (any ProcessSpawner).self)
                ?? CrossSpawnSpawner.HostProcessSpawner.shared
            return LayerNode.Output([Service.serviceKey: Service(spawner: spawner)])
        },
        [CrossSpawnSpawner.node]
    )
}

// MARK: - ProcessSignal (`process-signal.ts`)

public enum ProcessSignal {
    private struct Registry: Sendable {
        var nextID: UInt64 = 1
        var unavailable: [String: @Sendable () -> Void] = [:]
        var listeners: [String: [UInt64: @Sendable () -> Void]] = [:]
    }

    private static let registry = Mutex(Registry())

    // parity: util/src/process-signal.ts#install [status=implemented hash=ec1d26a15ffe]
    public static func install(signal: String, unavailable: @escaping @Sendable () -> Void) {
        registry.withLock { reg in
            if reg.listeners[signal] != nil { return }
            reg.listeners[signal] = [:]
            reg.unavailable[signal] = unavailable
        }
    }

    // parity: util/src/process-signal.ts#subscribe [status=implemented hash=d466134be985]
    @discardableResult
    public static func subscribe(signal: String, listener: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        let token = registry.withLock { reg -> UInt64? in
            guard reg.listeners[signal] != nil else { return nil }
            let id = reg.nextID
            reg.nextID += 1
            reg.listeners[signal]?[id] = listener
            return id
        }
        guard let token else { return {} }
        return {
            registry.withLock { reg in
                _ = reg.listeners[signal]?.removeValue(forKey: token)
            }
        }
    }

    /// Dispatches a received process signal to all active subscribers (or the installed `unavailable` callback).
    public static func dispatch(signal: String) {
        let (handlers, fallback): ([@Sendable () -> Void], (@Sendable () -> Void)?) = registry.withLock { reg in
            guard let map = reg.listeners[signal] else { return ([], nil) }
            if map.isEmpty {
                return ([], reg.unavailable[signal])
            }
            return (map.sorted { $0.key < $1.key }.map(\.value), nil)
        }
        if let fallback {
            fallback()
        } else {
            for handler in handlers {
                handler()
            }
        }
    }

    /// Clears signal registrations (for test isolation).
    public static func reset() {
        registry.withLock { $0 = Registry() }
    }
}

// MARK: - OpenExternal (`open.ts`)

public enum OpenExternal {
    public struct InvalidURLError: Error, Equatable, Sendable, CustomStringConvertible {
        public let input: String

        public init(_ input: String) {
            self.input = input
        }

        public var description: String {
            "Only http and https links can be opened in the browser: \(input)"
        }
    }

    // parity: util/src/open.ts#openUrl [status=implemented hash=6ccbdc56b1e0]
    public static func openUrl(
        _ input: String,
        launcher: (@Sendable (String) async throws -> Void)? = nil
    ) async throws {
        guard let url = URL(string: input),
              let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              url.host != nil else {
            throw InvalidURLError(input)
        }
        try await openPath(url.absoluteString, launcher: launcher)
    }

    // parity: util/src/open.ts#openPath [status=implemented hash=30ca773450c9]
    public static func openPath(
        _ path: String,
        launcher: (@Sendable (String) async throws -> Void)? = nil
    ) async throws {
        if let launcher {
            try await launcher(path)
            return
        }
        #if os(macOS)
        _ = try await CrossSpawnSpawner.HostProcessSpawner.shared.run(
            ProcessSpec(executable: "/usr/bin/open", arguments: [path])
        )
        #elseif os(Linux)
        _ = try await CrossSpawnSpawner.HostProcessSpawner.shared.run(
            ProcessSpec(executable: "xdg-open", arguments: [path])
        )
        #elseif os(Windows)
        _ = try await CrossSpawnSpawner.HostProcessSpawner.shared.run(
            ProcessSpec(executable: "cmd", arguments: ["/c", "start", "", path])
        )
        #else
        throw PlatformError.unsupportedOnPlatform(Platform.current, operation: "OpenExternal.openPath")
        #endif
    }
}

// MARK: - HeapSnapshot (`heap-snapshot.ts`)

public enum HeapSnapshot {
    public struct MemorySummary: Equatable, Hashable, Sendable, Codable {
        public let rss: Int64
        public let heapTotal: Int64
        public let heapUsed: Int64
        public let external: Int64
        public let arrayBuffers: Int64

        public init(rss: Int64, heapTotal: Int64, heapUsed: Int64, external: Int64, arrayBuffers: Int64) {
            self.rss = rss
            self.heapTotal = heapTotal
            self.heapUsed = heapUsed
            self.external = external
            self.arrayBuffers = arrayBuffers
        }
    }

    public struct Result: Equatable, Hashable, Sendable, Codable {
        public let path: String
        public let pid: Int32
        public let memory: MemorySummary

        public init(path: String, pid: Int32, memory: MemorySummary) {
            self.path = path
            self.pid = pid
            self.memory = memory
        }
    }

    private static let serializeGate = Mutex(false)

    /// Writes a diagnostic memory snapshot file into `directory` (native Swift adaptation of V8 heap snapshot).
    // parity: util/src/heap-snapshot.ts#write [status=adapted hash=721d3e0e7a6c]
    public static func write(
        directory: String,
        fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared
    ) async throws -> Result {
        // Simple single-permit gate matching upstream `Semaphore.makeUnsafe(1)`.
        while true {
            let acquired = serializeGate.withLock { busy -> Bool in
                if busy { return false }
                busy = true
                return true
            }
            if acquired { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        defer { serializeGate.withLock { $0 = false } }

        let pid: Int32
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        pid = getpid()
        #else
        pid = 0
        #endif

        let nowMs = Flock.currentEpochMs()
        let file = "\(directory)/heap-\(pid)-\(nowMs).heapsnapshot"
        try await fileSystem.makeDirectory(at: directory, recursive: true)
        let memory = MemorySummary(rss: 0, heapTotal: 0, heapUsed: 0, external: 0, arrayBuffers: 0)
        let payload = "{\"runtime\":\"swift\",\"pid\":\(pid),\"timestampMs\":\(nowMs)}"
        try await fileSystem.writeFileExclusive(Array(payload.utf8), to: file)
        return Result(path: file, pid: pid, memory: memory)
    }
}
