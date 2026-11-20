#if os(macOS) || os(Linux) || os(Windows)
import Foundation
#elseif canImport(FoundationEssentials)
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

#if os(macOS) || os(Linux) || os(Windows)
private final class ActiveProcessController: @unchecked Sendable {
    private struct State: Sendable {
        var exited: Bool = false
        var terminationRequested: Bool = false
    }

    let process: Process
    private let forceKillAfterMs: Int
    private let state = Mutex(State())

    init(process: Process, forceKillAfterMs: Int = 500) {
        self.process = process
        self.forceKillAfterMs = forceKillAfterMs
    }

    func markExited() {
        state.withLock { $0.exited = true }
    }

    var isExited: Bool {
        state.withLock { $0.exited }
    }

    /// Terminates the running child process with SIGTERM -> SIGKILL escalation.
    /// Idempotent and safe to invoke from any thread.
    func terminate() {
        let shouldTerminate = state.withLock { s -> Bool in
            if s.exited || s.terminationRequested { return false }
            s.terminationRequested = true
            return true
        }
        guard shouldTerminate else { return }

        let pid = process.processIdentifier
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        if pid > 0 {
            _ = kill(pid, SIGTERM)
        } else if process.isRunning {
            process.terminate()
        }
        #else
        if process.isRunning {
            process.terminate()
        }
        #endif

        let graceMs = max(50, forceKillAfterMs)
        Thread.detachNewThread { [self] in
            let stepMs = 10
            var elapsed = 0
            while elapsed < graceMs {
                if self.isExited || !self.process.isRunning {
                    return
                }
                Thread.sleep(forTimeInterval: Double(stepMs) / 1000.0)
                elapsed += stepMs
            }
            if !self.isExited && self.process.isRunning {
                #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
                if pid > 0 {
                    _ = kill(pid, SIGKILL)
                }
                #else
                self.process.terminate()
                #endif
            }
        }
    }
}

private final class ConcurrentProcessCollector: @unchecked Sendable {
    private struct State {
        var stdout: [UInt8]? = nil
        var stderr: [UInt8]? = nil
        var exitCode: Int32? = nil
        var terminationError: (any Error)? = nil
        var resumed: Bool = false
        var continuation: CheckedContinuation<ProcessOutput, any Error>? = nil
    }

    private let state = Mutex(State())

    func setStdout(_ bytes: [UInt8]) {
        let completion = state.withLock { s -> (CheckedContinuation<ProcessOutput, any Error>, Result<ProcessOutput, any Error>)? in
            s.stdout = bytes
            return tryTakeCompletion(&s)
        }
        if let (cont, result) = completion {
            cont.resume(with: result)
        }
    }

    func setStderr(_ bytes: [UInt8]) {
        let completion = state.withLock { s -> (CheckedContinuation<ProcessOutput, any Error>, Result<ProcessOutput, any Error>)? in
            s.stderr = bytes
            return tryTakeCompletion(&s)
        }
        if let (cont, result) = completion {
            cont.resume(with: result)
        }
    }

    func setExited(exitCode: Int32) {
        let completion = state.withLock { s -> (CheckedContinuation<ProcessOutput, any Error>, Result<ProcessOutput, any Error>)? in
            s.exitCode = exitCode
            return tryTakeCompletion(&s)
        }
        if let (cont, result) = completion {
            cont.resume(with: result)
        }
    }

    /// Records a timeout / abort / cancellation error if the child has not already exited cleanly.
    func recordTerminationError(_ error: any Error) {
        let completion = state.withLock { s -> (CheckedContinuation<ProcessOutput, any Error>, Result<ProcessOutput, any Error>)? in
            guard !s.resumed, s.exitCode == nil, s.terminationError == nil else { return nil }
            s.terminationError = error
            return tryTakeCompletion(&s)
        }
        if let (cont, result) = completion {
            cont.resume(with: result)
        }
    }

    func install(continuation: CheckedContinuation<ProcessOutput, any Error>) {
        let completion = state.withLock { s -> (CheckedContinuation<ProcessOutput, any Error>, Result<ProcessOutput, any Error>)? in
            s.continuation = continuation
            return tryTakeCompletion(&s)
        }
        if let (cont, result) = completion {
            cont.resume(with: result)
        }
    }

    private func tryTakeCompletion(
        _ s: inout State
    ) -> (CheckedContinuation<ProcessOutput, any Error>, Result<ProcessOutput, any Error>)? {
        guard !s.resumed, let cont = s.continuation else { return nil }
        guard let exitCode = s.exitCode else { return nil }
        // If the child was forcibly terminated by timeout/abort/cancel, resume as soon as
        // waitUntilExit() completes so orphaned grandchildren holding pipe FDs cannot hang teardown.
        if let termErr = s.terminationError {
            s.resumed = true
            s.continuation = nil
            return (cont, .failure(termErr))
        }
        guard let stdout = s.stdout, let stderr = s.stderr else { return nil }
        s.resumed = true
        s.continuation = nil
        return (cont, .success(ProcessOutput(exitCode: exitCode, stdout: stdout, stderr: stderr)))
    }
}
#endif

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
            try await run(spec, timeoutMs: nil, signal: nil, forceKillAfterMs: 500)
        }

        /// Runs `spec` draining stdout and stderr concurrently on dedicated threads (preventing pipe deadlocks),
        /// with optional `timeoutMs`, live `AbortSignal`, and Swift Task cancellation triggering
        /// `SIGTERM` -> `SIGKILL` escalation.
        public func run(
            _ spec: ProcessSpec,
            timeoutMs: Int?,
            signal: AbortSignal?,
            forceKillAfterMs: Int = 500
        ) async throws -> ProcessOutput {
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

            if let signal, signal.isAborted {
                throw AppProcess.abortError(signal)
            }
            if let timeoutMs, timeoutMs <= 0 {
                throw PlatformError.ioFailure("Timed out")
            }
            if Task.isCancelled {
                throw CancellationError()
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

            let controller = ActiveProcessController(process: process, forceKillAfterMs: forceKillAfterMs)
            let collector = ConcurrentProcessCollector()

            // Feed stdin on its own background thread so large stdin payloads cannot deadlock with stdout/stderr.
            if let inputBytes = spec.stdin, let pipe = stdinPipe {
                let writeHandle = pipe.fileHandleForWriting
                Thread.detachNewThread {
                    if !inputBytes.isEmpty {
                        try? writeHandle.write(contentsOf: Data(inputBytes))
                    }
                    try? writeHandle.close()
                }
            }

            // Drain stdout and stderr CONCURRENTLY on dedicated threads before waitUntilExit()
            // so heavy output on either stream can never fill an OS pipe buffer and deadlock the child.
            let stdoutReadHandle = stdoutPipe.fileHandleForReading
            let stderrReadHandle = stderrPipe.fileHandleForReading

            Thread.detachNewThread {
                let data = (try? stdoutReadHandle.readToEnd()) ?? Data()
                try? stdoutReadHandle.close()
                collector.setStdout(Array(data))
            }

            Thread.detachNewThread {
                let data = (try? stderrReadHandle.readToEnd()) ?? Data()
                try? stderrReadHandle.close()
                collector.setStderr(Array(data))
            }

            Thread.detachNewThread {
                process.waitUntilExit()
                controller.markExited()
                collector.setExited(exitCode: process.terminationStatus)
            }

            // Wire live AbortSignal termination.
            let removeAbortListener: @Sendable () -> Void
            if let signal {
                removeAbortListener = signal.onAbort {
                    collector.recordTerminationError(AppProcess.abortError(signal))
                    controller.terminate()
                }
                if signal.isAborted {
                    collector.recordTerminationError(AppProcess.abortError(signal))
                    controller.terminate()
                }
            } else {
                removeAbortListener = {}
            }
            defer { removeAbortListener() }

            // Wire timeout termination (SIGTERM -> SIGKILL escalation).
            let timeoutTask: Task<Void, Never>?
            if let timeoutMs {
                timeoutTask = Task {
                    do {
                        try await Task.sleep(for: .milliseconds(timeoutMs))
                    } catch {
                        return
                    }
                    if !controller.isExited {
                        collector.recordTerminationError(PlatformError.ioFailure("Timed out"))
                        controller.terminate()
                    }
                }
            } else {
                timeoutTask = nil
            }
            defer { timeoutTask?.cancel() }

            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    collector.install(continuation: continuation)
                }
            } onCancel: {
                collector.recordTerminationError(CancellationError())
                controller.terminate()
            }
            #else
            _ = (timeoutMs, signal, forceKillAfterMs)
            throw PlatformError.unsupportedOnPlatform(Platform.current, operation: "ProcessSpawner.run")
            #endif
        }
    }

    public static let spawnerKey = "@opencode/ChildProcessSpawner"

    // parity: util/src/cross-spawn-spawner.ts#node [status=implemented hash=b4e8095ce98e]
    public static let node: LayerNode.Provider = AppNode.makeGlobalNode(
        spawnerKey,
        LayerNode.ExecutableLayer.succeed(key: spawnerKey, value: HostProcessSpawner.shared as any ProcessSpawner),
        [LayerNodePlatform.filesystem, LayerNodePlatform.path]
    )
}

// MARK: - AppProcess (`process.ts`)

public enum AppProcess {
    // parity: util/src/process.ts#AppProcessError [status=implemented hash=e70de0434e35]
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

        // parity: util/src/process.ts#AppProcessError.message [status=implemented hash=e05a55cbbc95]
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
            if let timeoutMs = options.timeoutMs, timeoutMs <= 0 {
                throw AppProcessError(command: description, causeMessage: "Timed out")
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
                let raw: ProcessOutput
                if let hostSpawner = spawner as? CrossSpawnSpawner.HostProcessSpawner {
                    raw = try await hostSpawner.run(
                        effectiveSpec,
                        timeoutMs: options.timeoutMs,
                        signal: options.signal
                    )
                } else if options.timeoutMs != nil || options.signal != nil {
                    raw = try await runWithCustomSpawnerControls(
                        effectiveSpec,
                        description: description,
                        timeoutMs: options.timeoutMs,
                        signal: options.signal
                    )
                } else {
                    raw = try await spawner.run(effectiveSpec)
                }
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
                let message: String
                if case PlatformError.ioFailure(let detail, _) = error {
                    message = detail
                } else {
                    message = String(describing: error)
                }
                throw AppProcessError(command: description, causeMessage: message)
            }
        }

        private func runWithCustomSpawnerControls(
            _ spec: ProcessSpec,
            description: String,
            timeoutMs: Int?,
            signal: AbortSignal?
        ) async throws -> ProcessOutput {
            let spawner = self.spawner
            let worker = Task<ProcessOutput, any Error> {
                try await spawner.run(spec)
            }
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessOutput, any Error>) in
                    let gate = Mutex(false)
                    let resumeOnce: @Sendable (Result<ProcessOutput, any Error>) -> Void = { result in
                        let shouldResume = gate.withLock { done -> Bool in
                            if done { return false }
                            done = true
                            return true
                        }
                        if shouldResume {
                            continuation.resume(with: result)
                        }
                    }

                    let removeAbort: @Sendable () -> Void
                    if let signal {
                        removeAbort = signal.onAbort {
                            worker.cancel()
                            let err = AppProcess.abortError(signal)
                            resumeOnce(.failure(AppProcessError(command: description, causeMessage: String(describing: err))))
                        }
                        if signal.isAborted {
                            worker.cancel()
                            let err = AppProcess.abortError(signal)
                            resumeOnce(.failure(AppProcessError(command: description, causeMessage: String(describing: err))))
                        }
                    } else {
                        removeAbort = {}
                    }

                    let timerTask: Task<Void, Never>?
                    if let timeoutMs {
                        timerTask = Task {
                            do {
                                try await Task.sleep(for: .milliseconds(timeoutMs))
                            } catch {
                                return
                            }
                            worker.cancel()
                            resumeOnce(.failure(AppProcessError(command: description, causeMessage: "Timed out")))
                        }
                    } else {
                        timerTask = nil
                    }

                    Task {
                        let result = await worker.result
                        timerTask?.cancel()
                        removeAbort()
                        resumeOnce(result)
                    }
                }
            } onCancel: {
                worker.cancel()
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

    // parity: util/src/process.ts#requireSuccess [status=implemented hash=26c6b4d0267d]
    public static func requireSuccess(_ result: RunResult) throws -> RunResult {
        if result.exitCode == 0 { return result }
        throw AppProcessError(
            command: result.command,
            exitCode: result.exitCode,
            stderr: String(decoding: result.stderr, as: UTF8.self)
        )
    }

    // parity: util/src/process.ts#requireExitIn [status=implemented hash=d6e1a7b78208]
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

    // parity: util/src/process.ts#waitForAbort [status=implemented hash=e4a4b8146b7d]
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

    // parity: util/src/process.ts#collectStream [status=implemented hash=03ae5dda1c63]
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

    // parity: util/src/process.ts#node [status=implemented hash=3cbb186d2a50]
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

#if os(macOS) || os(Linux)
/// Async-signal-safe write end of the process-wide self-pipe used to forward POSIX signals
/// out of C signal context into a dedicated Swift dispatcher thread without touching GCD or locks.
private nonisolated(unsafe) var posixSignalPipeWriteFD: Int32 = -1

private func posixSignalTrampoline(_ sig: Int32) {
    let fd = posixSignalPipeWriteFD
    guard fd >= 0 else { return }
    var byte = UInt8(truncatingIfNeeded: sig)
    #if canImport(Darwin)
    _ = Darwin.write(fd, &byte, 1)
    #elseif canImport(Glibc)
    _ = Glibc.write(fd, &byte, 1)
    #elseif canImport(Musl)
    _ = Musl.write(fd, &byte, 1)
    #endif
}
#endif

public enum ProcessSignal {
    private struct Registry: Sendable {
        var nextID: UInt64 = 1
        var unavailable: [String: @Sendable () -> Void] = [:]
        var listeners: [String: [UInt64: @Sendable () -> Void]] = [:]
    }

    private struct PosixState: Sendable {
        var pumpStarted: Bool = false
        var installedSignals: Set<Int32> = []
    }

    private static let registry = Mutex(Registry())
    private static let posixState = Mutex(PosixState())

    #if os(macOS) || os(Linux)
    private static func posixSignalNumber(for name: String) -> Int32? {
        switch name.uppercased() {
        case "SIGHUP": return SIGHUP
        case "SIGINT": return SIGINT
        case "SIGQUIT": return SIGQUIT
        case "SIGUSR1": return SIGUSR1
        case "SIGUSR2": return SIGUSR2
        case "SIGPIPE": return SIGPIPE
        case "SIGALRM": return SIGALRM
        case "SIGTERM": return SIGTERM
        case "SIGCHLD": return SIGCHLD
        case "SIGCONT": return SIGCONT
        case "SIGTSTP": return SIGTSTP
        case "SIGTTIN": return SIGTTIN
        case "SIGTTOU": return SIGTTOU
        case "SIGWINCH": return SIGWINCH
        #if canImport(Darwin)
        case "SIGINFO": return SIGINFO
        #endif
        default: return nil
        }
    }

    private static func posixSignalName(for number: Int32) -> String? {
        switch number {
        case SIGHUP: return "SIGHUP"
        case SIGINT: return "SIGINT"
        case SIGQUIT: return "SIGQUIT"
        case SIGUSR1: return "SIGUSR1"
        case SIGUSR2: return "SIGUSR2"
        case SIGPIPE: return "SIGPIPE"
        case SIGALRM: return "SIGALRM"
        case SIGTERM: return "SIGTERM"
        case SIGCHLD: return "SIGCHLD"
        case SIGCONT: return "SIGCONT"
        case SIGTSTP: return "SIGTSTP"
        case SIGTTIN: return "SIGTTIN"
        case SIGTTOU: return "SIGTTOU"
        case SIGWINCH: return "SIGWINCH"
        #if canImport(Darwin)
        case SIGINFO: return "SIGINFO"
        #endif
        default: return nil
        }
    }

    private static func installPosixHandlerIfSupported(for signalName: String) {
        guard let sigNum = posixSignalNumber(for: signalName) else { return }

        let (needsPump, needsSigaction): (Bool, Bool) = posixState.withLock { s in
            let startPump = !s.pumpStarted
            if startPump {
                s.pumpStarted = true
            }
            let installHandler = s.installedSignals.insert(sigNum).inserted
            return (startPump, installHandler)
        }

        if needsPump {
            var fds: [Int32] = [-1, -1]
            #if canImport(Darwin)
            let pipeRC = Darwin.pipe(&fds)
            #elseif canImport(Glibc)
            let pipeRC = Glibc.pipe(&fds)
            #elseif canImport(Musl)
            let pipeRC = Musl.pipe(&fds)
            #else
            let pipeRC: Int32 = -1
            #endif
            if pipeRC == 0 {
                let readFD = fds[0]
                let writeFD = fds[1]
                _ = fcntl(readFD, F_SETFD, FD_CLOEXEC)
                _ = fcntl(writeFD, F_SETFD, FD_CLOEXEC)
                let writeFlags = fcntl(writeFD, F_GETFL)
                if writeFlags >= 0 {
                    _ = fcntl(writeFD, F_SETFL, writeFlags | O_NONBLOCK)
                }
                posixSignalPipeWriteFD = writeFD

                Thread.detachNewThread {
                    var buffer = [UInt8](repeating: 0, count: 64)
                    while true {
                        let n: Int = buffer.withUnsafeMutableBytes { rawBuf in
                            guard let base = rawBuf.baseAddress else { return -1 }
                            #if canImport(Darwin)
                            return Darwin.read(readFD, base, rawBuf.count)
                            #elseif canImport(Glibc)
                            return Glibc.read(readFD, base, rawBuf.count)
                            #elseif canImport(Musl)
                            return Musl.read(readFD, base, rawBuf.count)
                            #else
                            return -1
                            #endif
                        }
                        if n < 0 {
                            if errno == EINTR { continue }
                            break
                        }
                        if n == 0 { break }
                        for i in 0..<n {
                            let sigNumber = Int32(buffer[i])
                            if let name = ProcessSignal.posixSignalName(for: sigNumber) {
                                ProcessSignal.dispatch(signal: name)
                            }
                        }
                    }
                }
            }
        }

        if needsSigaction {
            #if canImport(Darwin)
            var act = sigaction()
            act.__sigaction_u.__sa_handler = posixSignalTrampoline
            sigemptyset(&act.sa_mask)
            act.sa_flags = SA_RESTART
            _ = sigaction(sigNum, &act, nil)
            #elseif canImport(Glibc)
            _ = Glibc.signal(sigNum, posixSignalTrampoline)
            #elseif canImport(Musl)
            _ = Musl.signal(sigNum, posixSignalTrampoline)
            #endif
        }
    }
    #endif

    // parity: util/src/process-signal.ts#install [status=implemented hash=ec1d26a15ffe]
    public static func install(signal: String, unavailable: @escaping @Sendable () -> Void) {
        let inserted = registry.withLock { reg -> Bool in
            if reg.listeners[signal] != nil { return false }
            reg.listeners[signal] = [:]
            reg.unavailable[signal] = unavailable
            return true
        }
        #if os(macOS) || os(Linux)
        if inserted {
            installPosixHandlerIfSupported(for: signal)
        }
        #else
        _ = inserted
        #endif
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

    /// Reads current process memory statistics (RSS and native heap where available) using OS APIs.
    public static func currentMemorySummary() -> MemorySummary {
        var rss: Int64 = 0
        var heapTotal: Int64 = 0
        var heapUsed: Int64 = 0

        #if canImport(Darwin)
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) { infoPtr in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(task_self_trap(), task_flavor_t(MACH_TASK_BASIC_INFO), intPtr, &count)
            }
        }
        if kerr == KERN_SUCCESS {
            rss = Int64(info.resident_size)
        } else {
            var usage = rusage()
            if getrusage(RUSAGE_SELF, &usage) == 0 {
                rss = Int64(usage.ru_maxrss) // macOS ru_maxrss is in bytes
            }
        }
        var mallocStats = malloc_statistics_t()
        malloc_zone_statistics(nil, &mallocStats)
        heapTotal = Int64(mallocStats.size_allocated)
        heapUsed = Int64(mallocStats.size_in_use)
        #elseif os(Linux)
        if let statm = try? String(contentsOfFile: "/proc/self/statm", encoding: .utf8) {
            let fields = statm.split(whereSeparator: \.isWhitespace)
            if fields.count >= 2, let residentPages = Int64(fields[1]), residentPages > 0 {
                #if canImport(Glibc) || canImport(Musl)
                let pageSize = Int64(sysconf(Int32(_SC_PAGESIZE)))
                if pageSize > 0 {
                    rss = residentPages * pageSize
                }
                #endif
            }
        }
        if rss == 0 {
            #if canImport(Glibc) || canImport(Musl)
            var usage = rusage()
            if getrusage(Int32(RUSAGE_SELF.rawValue), &usage) == 0 {
                rss = Int64(usage.ru_maxrss) * 1024 // Linux ru_maxrss is in KiB
            }
            #endif
        }
        #endif

        return MemorySummary(
            rss: rss,
            heapTotal: heapTotal,
            heapUsed: heapUsed,
            external: 0,
            arrayBuffers: 0
        )
    }

    /// Writes a diagnostic memory snapshot file into `directory` (native Swift adaptation of V8 heap snapshot).
    // parity: util/src/heap-snapshot.ts#write [status=adapted hash=381d411801d0]
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
        let memory = currentMemorySummary()
        let payload = "{\"runtime\":\"swift\",\"pid\":\(pid),\"timestampMs\":\(nowMs),\"memory\":{\"rss\":\(memory.rss),\"heapTotal\":\(memory.heapTotal),\"heapUsed\":\(memory.heapUsed),\"external\":\(memory.external),\"arrayBuffers\":\(memory.arrayBuffers)}}"
        try await fileSystem.writeFileExclusive(Array(payload.utf8), to: file)
        return Result(path: file, pid: pid, memory: memory)
    }
}
