#if !os(WASI)
import Foundation
#endif
#if os(Windows)
import WinSDK
#endif
import Synchronization
import OpenCodeUtil

// MARK: - Cross-Platform Windows Process Helpers (Pure & Unit-Testable on All Hosts)

/// Pure Windows process spawning, quoting, environment-block, flag, and lifecycle helpers
/// mirroring `upstream/opencode/packages/process-daemon/src/service/pipe/windows.rs` and
/// `src/service/windows.rs`. Kept pure so every algorithm is unit-tested on non-Windows hosts.
public enum WindowsProcessHelpers {
    // MARK: Win32 Constants

    /// `CREATE_NO_WINDOW` (0x08000000)
    public static let createNoWindow: UInt32 = 0x0800_0000
    /// `CREATE_SUSPENDED` (0x00000004)
    public static let createSuspended: UInt32 = 0x0000_0004
    /// `CREATE_UNICODE_ENVIRONMENT` (0x00000400)
    public static let createUnicodeEnvironment: UInt32 = 0x0000_0400
    /// `EXTENDED_STARTUPINFO_PRESENT` (0x00080000)
    public static let extendedStartupInfoPresent: UInt32 = 0x0008_0000
    /// `STARTF_USESTDHANDLES` (0x00000100)
    public static let startfUseStdHandles: UInt32 = 0x0000_0100
    /// `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` (0x00002000)
    public static let jobObjectLimitKillOnJobClose: UInt32 = 0x0000_2000
    /// `PROC_THREAD_ATTRIBUTE_HANDLE_LIST` (`ProcThreadAttributeValue(2, FALSE, TRUE, FALSE)` = 0x00020002).
    /// Complex C macro in `WinBase.h` not imported directly by Swift ClangImporter.
    public static let procThreadAttributeHandleList: UInt64 = 0x0002_0002
    /// `PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE` (`ProcThreadAttributeValue(22, FALSE, TRUE, FALSE)` = 0x00020016).
    public static let procThreadAttributePseudoConsole: UInt64 = 0x0002_0016
    /// `SDDL_REVISION_1` (1)
    public static let sddlRevision1: UInt32 = 1

    /// Named pipe in-buffer size (64 KiB, matching upstream `BUFFER_BYTES`).
    public static let pipeBufferBytes: UInt32 = 64 * 1024
    /// Reader transfer chunk size (8 KiB, matching upstream `READ_BYTES`).
    public static let pipeReadBytes: Int = 8 * 1024
    /// Output drain grace after root process exit (1 second, matching upstream `DRAIN_AFTER_EXIT`).
    public static let drainAfterExitMs: UInt64 = 1_000
    /// ConPTY wait worker poll interval (25 ms, matching upstream `EXIT_POLL_INTERVAL`).
    public static let ptyExitPollIntervalMs: UInt32 = 25

    // Win32 error codes checked in pipe/process teardown paths.
    public static let errorAccessDenied: UInt32 = 5
    public static let errorBrokenPipe: UInt32 = 109
    public static let errorNoData: UInt32 = 232
    public static let errorPipeNotConnected: UInt32 = 233
    public static let errorOperationAborted: UInt32 = 995
    public static let errorIoPending: UInt32 = 997

    // Win32 console control event codes (`wincon.h`).
    public static let ctrlCEvent: UInt32 = 0
    public static let ctrlBreakEvent: UInt32 = 1
    public static let ctrlCloseEvent: UInt32 = 2
    public static let ctrlShutdownEvent: UInt32 = 6

    // MARK: Errors

    public enum EncodingError: Error, Equatable, Sendable, CustomStringConvertible {
        case invalidCommandLine(String)
        case invalidEnvironmentVariable(String)
        case embeddedNul(String)

        public var description: String {
            switch self {
            case .invalidCommandLine(let msg): return msg
            case .invalidEnvironmentVariable(let msg): return msg
            case .embeddedNul(let msg): return msg
            }
        }
    }

    // MARK: Creation & Job Flags

    public enum SpawnKind: Equatable, Hashable, Sendable {
        /// Non-PTY daemon pipe child (`CREATE_NO_WINDOW | CREATE_SUSPENDED | EXTENDED_STARTUPINFO_PRESENT | [CREATE_UNICODE_ENVIRONMENT]`).
        case pipe
        /// `HostProcessSpawner` subprocess (`CREATE_NO_WINDOW | CREATE_SUSPENDED | EXTENDED_STARTUPINFO_PRESENT | [CREATE_UNICODE_ENVIRONMENT]`).
        case spawner
        /// ConPTY terminal child (`CREATE_SUSPENDED | EXTENDED_STARTUPINFO_PRESENT | [CREATE_UNICODE_ENVIRONMENT]`).
        case conpty
    }

    /// Computes exact `CreateProcessW` `dwCreationFlags` matching upstream `service/pipe/windows.rs`.
    public static func creationFlags(for kind: SpawnKind, hasExplicitEnvironment: Bool) -> UInt32 {
        var flags: UInt32 = createSuspended | extendedStartupInfoPresent
        switch kind {
        case .pipe, .spawner:
            flags |= createNoWindow
        case .conpty:
            break
        }
        if hasExplicitEnvironment {
            flags |= createUnicodeEnvironment
        }
        return flags
    }

    /// Computes `JOBOBJECT_BASIC_LIMIT_INFORMATION.LimitFlags` (`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` when armed, `0` when disarmed).
    public static func jobLimitFlags(killOnClose: Bool) -> UInt32 {
        killOnClose ? jobObjectLimitKillOnJobClose : 0
    }

    /// Matches upstream `pipe/windows.rs`: terminate leftover descendants in the job only when the
    /// root exited with a non-zero status on its own (not already terminated via `signal`/`kill`).
    public static func shouldTerminateJobOnExit(exitCode: UInt32, wasKilled: Bool) -> Bool {
        exitCode != 0 && !wasKilled
    }

    /// Matches upstream `pipe/windows.rs#is_end_of_output`.
    public static func isEndOfOutputError(_ win32Error: UInt32) -> Bool {
        win32Error == errorBrokenPipe
            || win32Error == errorPipeNotConnected
            || win32Error == errorNoData
            || win32Error == errorOperationAborted
    }

    /// Matches upstream `pipe/windows.rs#terminate`: `ERROR_ACCESS_DENIED` on an already-exited
    /// process is not treated as an error.
    public static func isAlreadyExitedTerminateError(_ win32Error: UInt32) -> Bool {
        win32Error == errorAccessDenied
    }

    /// Computes remaining wait milliseconds with ceiling rounding so a sub-millisecond remainder
    /// never busy-spins with 0, matching upstream `left.as_nanos().div_ceil(1_000_000).min(u32::MAX)`.
    public static func remainingWaitTimeoutMs(deadlineNs: UInt64, nowNs: UInt64) -> UInt32 {
        guard deadlineNs > nowNs else { return 0 }
        let leftNs = deadlineNs - nowNs
        let ms = (leftNs &- 1) / 1_000_000 &+ 1
        return UInt32(min(ms, UInt64(UInt32.max)))
    }

    /// Formats the private local named pipe path for a Windows pipe child (`\\.\pipe\opencode-pty-<hex>`).
    public static func windowsPipeName(randomHex32: String) -> String {
        #"\\.\pipe\opencode-pty-\#(randomHex32)"#
    }

    /// Formats the protected current-user SDDL descriptor (`O:<sid>D:P(A;;GA;;;<sid>)`),
    /// matching upstream `transport/windows/security.rs#PrivateSecurity::new`.
    public static func privateSecuritySDDL(ownerSID: String) -> String {
        "O:\(ownerSID)D:P(A;;GA;;;\(ownerSID))"
    }

    /// Maps `ProcessDaemon.ProcessSignal` to its reported Unix signal name on Windows.
    public static func pipeSignalName(_ signal: ProcessDaemon.ProcessSignal) -> String {
        switch signal {
        case .term: return "SIGTERM"
        case .int: return "SIGINT"
        case .kill: return "SIGKILL"
        }
    }

    /// Maps a Win32 `SetConsoleCtrlHandler` `dwCtrlType` code to a POSIX-compatible signal name.
    public static func consoleCtrlEventToSignalName(_ ctrlType: UInt32) -> String? {
        switch ctrlType {
        case ctrlCEvent:
            return "SIGINT"
        case ctrlBreakEvent, ctrlCloseEvent, ctrlShutdownEvent:
            return "SIGTERM"
        default:
            return nil
        }
    }

    // MARK: UTF-16 Wide String Encoding

    /// Returns a NUL-terminated UTF-16 buffer for `value`, rejecting embedded NULs.
    public static func encodeWideString(_ value: String) throws(EncodingError) -> [UInt16] {
        var units = Array(value.utf16)
        if units.contains(0) {
            throw .embeddedNul("path contains a NUL")
        }
        units.append(0)
        return units
    }

    // MARK: MSVCRT / CommandLineToArgvW Command-Line Quoting (`pipe/windows.rs#command_line`)

    /// Builds the NUL-terminated UTF-16 command line that `CreateProcessW` parses and the child
    /// recovers with `CommandLineToArgvW` / MSVCRT rules (exact port of upstream `pipe/windows.rs`).
    public static func buildCommandLine(program: String, args: [String]) throws(EncodingError) -> [UInt16] {
        // A NUL would truncate the line, and the program is always quoted, so a quote in it cannot be represented.
        if program.utf16.contains(0) || program.utf16.contains(0x0022) {
            throw .invalidCommandLine("command cannot be passed to a child process")
        }
        for arg in args {
            if arg.utf16.contains(0) {
                throw .invalidCommandLine("command cannot be passed to a child process")
            }
        }
        var line: [UInt16] = []
        line.reserveCapacity(program.utf16.count + 3)
        // Always quoted: CreateProcessW finds the executable in the first token,
        // and quoting removes any ambiguity for the child.
        line.append(0x0022) // '"'
        line.append(contentsOf: program.utf16)
        line.append(0x0022) // '"'
        for arg in args {
            line.append(0x0020) // ' '
            appendArg(arg, into: &line)
        }
        // CreateProcessW requires a NUL-terminated mutable buffer.
        line.append(0)
        return line
    }

    /// Quotes one argument only when it needs it (`empty`, contains `' '` or `'\t'`),
    /// doubling backslashes before an internal quote (`2n+1`) and before a closing quote (`2n`).
    public static func appendArg(_ arg: String, into line: inout [UInt16]) {
        let units = Array(arg.utf16)
        let quote = units.isEmpty || units.contains(0x0020) || units.contains(0x0009)
        if quote {
            line.append(0x0022) // '"'
        }
        var backslashes = 0
        for unit in units {
            if unit == 0x005C { // '\\'
                backslashes += 1
            } else {
                if unit == 0x0022 { // '"'
                    // Add n+1 backslashes to total 2n+1 before the internal quote.
                    for _ in 0...backslashes {
                        line.append(0x005C)
                    }
                }
                backslashes = 0
            }
            line.append(unit)
        }
        if quote {
            // Add n backslashes to total 2n before the closing quote.
            for _ in 0..<backslashes {
                line.append(0x005C)
            }
            line.append(0x0022) // '"'
        }
    }

    // MARK: UTF-16 Environment Block Encoding (`pipe/windows.rs#environment_block`)

    /// Builds a Windows `CREATE_UNICODE_ENVIRONMENT` block containing exactly `env`:
    /// validated, deduplicated and sorted case-insensitively ordinally (keeping the ordinal-largest
    /// case variant deterministically), with each `KEY=VALUE\0` entry and a final `\0`.
    /// An empty dictionary encodes as `[0, 0]`.
    public static func buildEnvironmentBlock(_ env: [String: String]) throws(EncodingError) -> [UInt16] {
        var entries: [(key: [UInt16], value: [UInt16])] = []
        entries.reserveCapacity(env.count)

        for (key, value) in env {
            // Windows allows a leading `=` for per-drive current directories (`=C:`),
            // but no other `=` in the name, and a lone `=` is invalid.
            let keyUnits = Array(key.utf16)
            let valueUnits = Array(value.utf16)
            let afterLeadingEq = keyUnits.first == 0x003D ? keyUnits.dropFirst() : keyUnits[...]
            if keyUnits.isEmpty
                || (keyUnits.count == 1 && keyUnits[0] == 0x003D)
                || keyUnits.contains(0)
                || valueUnits.contains(0)
                || afterLeadingEq.contains(0x003D)
            {
                throw .invalidEnvironmentVariable("environment variable cannot be passed to a child process")
            }
            entries.append((key: keyUnits, value: valueUnits))
        }

        // Case-insensitive ordinal order, with the ordinal-largest variant first so that
        // deduplication keeps it: the same request always produces the same block.
        entries.sort { a, b in
            let cmp = compareEnvKeysOrdinalIgnoreCase(a.key, b.key)
            if cmp != 0 { return cmp < 0 }
            let keyCmp = compareUTF16Lexicographical(b.key, a.key)
            if keyCmp != 0 { return keyCmp < 0 }
            return compareUTF16Lexicographical(b.value, a.value) < 0
        }

        // Deduplicate adjacent entries whose keys match case-insensitively.
        var deduped: [(key: [UInt16], value: [UInt16])] = []
        deduped.reserveCapacity(entries.count)
        for entry in entries {
            if let last = deduped.last, compareEnvKeysOrdinalIgnoreCase(last.key, entry.key) == 0 {
                continue
            }
            deduped.append(entry)
        }

        var block: [UInt16] = []
        if deduped.isEmpty {
            // An empty environment is an empty entry before the terminating NUL.
            block.append(0)
        }
        for (key, value) in deduped {
            block.append(contentsOf: key)
            block.append(0x003D) // '='
            block.append(contentsOf: value)
            block.append(0)
        }
        block.append(0)
        return block
    }

    /// Compares two UTF-16 environment variable names case-insensitively ordinally, matching
    /// Windows `CompareStringOrdinal(a, lenA, b, lenB, TRUE)` (used by Rust std `EnvKey` and upstream).
    public static func compareEnvKeysOrdinalIgnoreCase(_ a: [UInt16], _ b: [UInt16]) -> Int {
        #if os(Windows)
        if a.isEmpty || b.isEmpty {
            return a.count == b.count ? 0 : (a.isEmpty ? -1 : 1)
        }
        if a.count <= Int(Int32.max), b.count <= Int(Int32.max) {
            let result: Int32 = a.withUnsafeBufferPointer { aPtr in
                b.withUnsafeBufferPointer { bPtr in
                    CompareStringOrdinal(
                        aPtr.baseAddress,
                        Int32(a.count),
                        bPtr.baseAddress,
                        Int32(b.count),
                        true
                    )
                }
            }
            if result == Int32(CSTR_LESS_THAN) { return -1 }
            if result == Int32(CSTR_GREATER_THAN) { return 1 }
            if result == Int32(CSTR_EQUAL) { return 0 }
        }
        return compareUTF16Lexicographical(a, b)
        #else
        return compareEnvKeysPortableOrdinalIgnoreCase(a, b)
        #endif
    }

    /// Portable case-insensitive ordinal comparison using uppercase folding (matching Win32
    /// `CompareStringOrdinal(..., TRUE)`, where `'a'` folds to `'A'` = 0x41 < `'B'` = 0x42 < `'_'` = 0x5F).
    public static func compareEnvKeysPortableOrdinalIgnoreCase(_ a: [UInt16], _ b: [UInt16]) -> Int {
        let count = min(a.count, b.count)
        for i in 0..<count {
            let ua = foldOrdinalUppercase(a[i])
            let ub = foldOrdinalUppercase(b[i])
            if ua < ub { return -1 }
            if ua > ub { return 1 }
        }
        if a.count < b.count { return -1 }
        if a.count > b.count { return 1 }
        return 0
    }

    private static func foldOrdinalUppercase(_ unit: UInt16) -> UInt16 {
        if unit >= 0x0061 && unit <= 0x007A {
            return unit &- 0x0020
        }
        // Handle non-ASCII BMP single-unit uppercase mappings (matching Windows' 1-to-1 uppercase table).
        if unit >= 0x0080, let scalar = UnicodeScalar(unit) {
            let upper = String(scalar).uppercased()
            let upperUnits = Array(upper.utf16)
            if upperUnits.count == 1 {
                return upperUnits[0]
            }
        }
        return unit
    }

    private static func compareUTF16Lexicographical(_ a: [UInt16], _ b: [UInt16]) -> Int {
        let count = min(a.count, b.count)
        for i in 0..<count {
            if a[i] < b[i] { return -1 }
            if a[i] > b[i] { return 1 }
        }
        if a.count < b.count { return -1 }
        if a.count > b.count { return 1 }
        return 0
    }

    // MARK: Pure Suspended-Spawn, Job-Assign & Resume Lifecycle State Machine

    public struct SuspendedSpawnResult<ProcessHandle: Sendable, JobHandle: Sendable>: Sendable {
        public let pid: UInt32
        public let process: ProcessHandle
        public let job: JobHandle?
        public let jobFallbackWarning: String?

        public init(pid: UInt32, process: ProcessHandle, job: JobHandle?, jobFallbackWarning: String?) {
            self.pid = pid
            self.process = process
            self.job = job
            self.jobFallbackWarning = jobFallbackWarning
        }
    }

    /// Executes the exact upstream suspended-spawn -> close-child-handles -> assign-job -> resume-thread
    /// protocol with RAII termination of the suspended child if any pre-resume step fails.
    ///
    /// - When `allowJoblessFallback` is `true` (matching `upstream/src/service/pipe/windows.rs`),
    ///   an `assignJob` error records a warning, releases the job handle, and resumes the child joblessly.
    /// - When `allowJoblessFallback` is `false`, an `assignJob` error terminates the suspended child
    ///   and rethrows without resuming.
    /// - In both modes, a `resumeThread` error always terminates the suspended child and releases the job.
    public static func runSuspendedSpawnSequence<ProcessHandle: Sendable, ThreadHandle: Sendable, JobHandle: Sendable>(
        job: JobHandle?,
        allowJoblessFallback: Bool = true,
        createSuspended: () throws -> (pid: UInt32, process: ProcessHandle, thread: ThreadHandle),
        closeParentCopiesOfChildHandles: () -> Void,
        assignJob: (JobHandle, ProcessHandle) throws -> Void,
        releaseJob: (JobHandle) -> Void,
        resumeThread: (ThreadHandle) throws -> Void,
        terminateSuspended: (ProcessHandle) -> Void,
        releaseProcess: (ProcessHandle) -> Void,
        releaseThread: (ThreadHandle) -> Void
    ) throws -> SuspendedSpawnResult<ProcessHandle, JobHandle> {
        let created: (pid: UInt32, process: ProcessHandle, thread: ThreadHandle)
        do {
            created = try createSuspended()
        } catch {
            closeParentCopiesOfChildHandles()
            if let job { releaseJob(job) }
            throw error
        }
        // Drop the daemon's copy of the child's stdio handles immediately after CreateProcessW
        // so the output pipe breaks cleanly when the child exits.
        closeParentCopiesOfChildHandles()

        var processStillSuspended = true
        var activeJob: JobHandle? = job
        var fallbackWarning: String? = nil

        defer {
            releaseThread(created.thread)
            if processStillSuspended {
                terminateSuspended(created.process)
                releaseProcess(created.process)
                if let remainingJob = activeJob {
                    releaseJob(remainingJob)
                }
            }
        }

        if let candidateJob = activeJob {
            do {
                try assignJob(candidateJob, created.process)
            } catch {
                if allowJoblessFallback {
                    fallbackWarning = String(describing: error)
                    activeJob = nil
                    releaseJob(candidateJob)
                } else {
                    throw error
                }
            }
        }

        try resumeThread(created.thread)
        processStillSuspended = false
        let handedOffJob = activeJob
        activeJob = nil

        return SuspendedSpawnResult(
            pid: created.pid,
            process: created.process,
            job: handedOffJob,
            jobFallbackWarning: fallbackWarning
        )
    }

    // MARK: Pure Pipe Process Exit & Kill State Machine (`pipe/windows.rs#Process`)

    public enum PipeExitOutcome: Equatable, Sendable {
        case code(UInt32)
        case signal(String)
    }

    public struct PipeWaitCompletion: Equatable, Sendable {
        public let outcome: PipeExitOutcome
        public let shouldTerminateJob: Bool
        public let hadJob: Bool

        public init(outcome: PipeExitOutcome, shouldTerminateJob: Bool, hadJob: Bool) {
            self.outcome = outcome
            self.shouldTerminateJob = shouldTerminateJob
            self.hadJob = hadJob
        }
    }

    /// Pure state transition mirror of `upstream/src/service/pipe/windows.rs` (`State`, `record_kill`, `wait_exit`, `reap`).
    public struct PipeProcessStateMachine: Equatable, Sendable {
        public private(set) var hasHandles: Bool
        public private(set) var hasJob: Bool
        public private(set) var killedSignal: String?

        public init(hasHandles: Bool = true, hasJob: Bool = true) {
            self.hasHandles = hasHandles
            self.hasJob = hasJob
            self.killedSignal = nil
        }

        /// Mirrors `record_kill`: returns `true` if the caller should terminate the process/job,
        /// recording only the first signal sent and ignoring already-exited or already-reaped processes.
        public mutating func recordKill(signalName: String, processAlreadySignalled: Bool) -> Bool {
            guard hasHandles else { return false }
            if processAlreadySignalled { return false }
            if killedSignal == nil {
                killedSignal = signalName
            }
            return true
        }

        /// Mirrors `wait_exit` post-wait transition: consumes handles, determines whether the job
        /// must be terminated (`code != 0 && killed == nil`) vs disarmed, and produces the reported `Exit`.
        public mutating func completeWait(exitCode: UInt32) -> PipeWaitCompletion {
            let hadJob = hasHandles && hasJob
            hasHandles = false
            hasJob = false
            let wasKilled = killedSignal != nil
            let shouldTerminate = WindowsProcessHelpers.shouldTerminateJobOnExit(
                exitCode: exitCode,
                wasKilled: wasKilled
            )
            let outcome: PipeExitOutcome
            if let sig = killedSignal {
                killedSignal = nil
                outcome = .signal(sig)
            } else {
                outcome = .code(exitCode)
            }
            return PipeWaitCompletion(outcome: outcome, shouldTerminateJob: shouldTerminate, hadJob: hadJob)
        }

        /// Mirrors `reap`: releases handles without signalling.
        public mutating func reap() {
            hasHandles = false
            hasJob = false
        }
    }
}

// MARK: - Native Windows Win32 Process, Job Object, Pipe & ConPTY Primitives

#if os(Windows)

internal struct WindowsOSFailure: Error, CustomStringConvertible, Sendable {
    let operation: String
    let code: UInt32

    init(_ operation: String, code: DWORD = GetLastError()) {
        self.operation = operation
        self.code = UInt32(code)
    }

    var description: String {
        "\(operation) failed (win32 error \(code))"
    }
}

/// ARC-managed Win32 kernel `HANDLE` equivalent to Rust's `Arc<OwnedHandle>`.
/// Closing happens exactly once in `deinit`, so holding a strong reference guarantees the
/// handle stays open across blocking waits without holding a mutex.
internal final class OwnedWinHandle: @unchecked Sendable {
    let raw: HANDLE

    init(_ raw: HANDLE) {
        self.raw = raw
    }

    deinit {
        _ = CloseHandle(raw)
    }

    static func adopt(_ handle: HANDLE?, operation: String) throws -> OwnedWinHandle {
        guard let handle, handle != INVALID_HANDLE_VALUE else {
            throw WindowsOSFailure(operation)
        }
        return OwnedWinHandle(handle)
    }

    func isSignalled() -> Bool {
        WaitForSingleObject(raw, 0) == WAIT_OBJECT_0
    }

    func setEvent() {
        _ = SetEvent(raw)
    }

    func resetEvent() {
        _ = ResetEvent(raw)
    }

    static func makeManualResetEvent() throws -> OwnedWinHandle {
        try adopt(CreateEventW(nil, true, false, nil), operation: "CreateEventW")
    }
}

/// ARC-managed ConPTY `HPCON` wrapper (`@unchecked Sendable` because `HPCON` is a raw pointer).
/// Ensures `ClosePseudoConsole` runs at most once, even on early spawn failures.
internal final class OwnedPseudoConsole: @unchecked Sendable {
    private struct RawBox: @unchecked Sendable {
        let raw: HPCON
    }

    private let state: Mutex<RawBox?>

    init(_ raw: HPCON) {
        self.state = Mutex(RawBox(raw: raw))
    }

    deinit {
        close()
    }

    func withRawHandle<R>(_ body: (HPCON) throws -> R) throws -> R {
        guard let box = state.withLock({ $0 }) else {
            throw ProcessDaemon.DaemonError("terminal child has exited")
        }
        return try body(box.raw)
    }

    func resize(cols: UInt16, rows: UInt16) throws {
        let box = state.withLock { $0 }
        guard let box else {
            throw ProcessDaemon.DaemonError("terminal child has exited")
        }
        let coord = COORD(X: Int16(clamping: cols), Y: Int16(clamping: rows))
        let rc = ResizePseudoConsole(box.raw, coord)
        if rc < 0 {
            throw ProcessDaemon.DaemonError(
                "ResizePseudoConsole failed with HRESULT 0x\(String(UInt32(bitPattern: rc), radix: 16))"
            )
        }
    }

    func close() {
        let box = state.withLock { cur -> RawBox? in
            let old = cur
            cur = nil
            return old
        }
        if let box {
            ClosePseudoConsole(box.raw)
        }
    }
}

/// Private current-user security descriptor (`O:<sid>D:P(A;;GA;;;<sid>)`),
/// matching `upstream/src/transport/windows/security.rs#PrivateSecurity`.
/// Resolves `sddl.h` entrypoints dynamically from `advapi32.dll` because Swift's `WinSDK`
/// `um.modulemap` does not export `<sddl.h>`.
internal final class WindowsPrivateSecurity: @unchecked Sendable {
    private typealias ConvertSidToStringSidWFn = @convention(c) (
        PSID?,
        UnsafeMutablePointer<LPWSTR?>?
    ) -> WindowsBool

    private typealias ConvertStringSDToSDFn = @convention(c) (
        LPCWSTR?,
        DWORD,
        UnsafeMutablePointer<PSECURITY_DESCRIPTOR?>?,
        UnsafeMutablePointer<ULONG>?
    ) -> WindowsBool

    internal let descriptor: PSECURITY_DESCRIPTOR
    let ownerSID: String

    private init(descriptor: PSECURITY_DESCRIPTOR, ownerSID: String) {
        self.descriptor = descriptor
        self.ownerSID = ownerSID
    }

    deinit {
        _ = LocalFree(descriptor)
    }

    internal static func withAdvapi32<R>(_ body: (HMODULE) throws -> R) throws -> R {
        let wideName = try WindowsProcessHelpers.encodeWideString("advapi32.dll")
        let module: HMODULE? = wideName.withUnsafeBufferPointer { ptr in
            LoadLibraryW(ptr.baseAddress)
        }
        guard let module else {
            throw WindowsOSFailure("LoadLibraryW(advapi32.dll)")
        }
        defer { _ = FreeLibrary(module) }
        return try body(module)
    }

    static func create() throws -> WindowsPrivateSecurity {
        let sid = try currentUserSID()
        let sddl = try WindowsProcessHelpers.encodeWideString(
            WindowsProcessHelpers.privateSecuritySDDL(ownerSID: sid)
        )
        let desc: PSECURITY_DESCRIPTOR = try withAdvapi32 { module in
            guard let rawProc = GetProcAddress(module, "ConvertStringSecurityDescriptorToSecurityDescriptorW") else {
                throw WindowsOSFailure("GetProcAddress(ConvertStringSecurityDescriptorToSecurityDescriptorW)")
            }
            let convertSD = unsafeBitCast(rawProc, to: ConvertStringSDToSDFn.self)
            var rawDescriptor: PSECURITY_DESCRIPTOR? = nil
            let converted: WindowsBool = sddl.withUnsafeBufferPointer { ptr in
                convertSD(
                    ptr.baseAddress,
                    DWORD(WindowsProcessHelpers.sddlRevision1),
                    &rawDescriptor,
                    nil
                )
            }
            guard converted.boolValue, let desc = rawDescriptor else {
                throw WindowsOSFailure("ConvertStringSecurityDescriptorToSecurityDescriptorW")
            }
            return desc
        }
        return WindowsPrivateSecurity(descriptor: desc, ownerSID: sid)
    }

    func securityAttributes(inherit: Bool = false) -> SECURITY_ATTRIBUTES {
        var sa = SECURITY_ATTRIBUTES()
        sa.nLength = DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size)
        sa.lpSecurityDescriptor = descriptor
        sa.bInheritHandle = WindowsBool(inherit)
        return sa
    }

    static func currentUserSID() throws -> String {
        var rawToken: HANDLE? = nil
        guard OpenProcessToken(GetCurrentProcess(), DWORD(TOKEN_QUERY), &rawToken) else {
            throw WindowsOSFailure("OpenProcessToken")
        }
        let token = try OwnedWinHandle.adopt(rawToken, operation: "OpenProcessToken")

        var length: DWORD = 0
        _ = GetTokenInformation(token.raw, TokenUser, nil, 0, &length)
        guard length > 0 else {
            throw WindowsOSFailure("GetTokenInformation(size)")
        }

        let buffer = UnsafeMutableRawBufferPointer.allocate(
            byteCount: Int(length),
            alignment: MemoryLayout<TOKEN_USER>.alignment
        )
        defer { buffer.deallocate() }

        guard GetTokenInformation(token.raw, TokenUser, buffer.baseAddress, length, &length) else {
            throw WindowsOSFailure("GetTokenInformation(TokenUser)")
        }

        let user = buffer.baseAddress!.assumingMemoryBound(to: TOKEN_USER.self).pointee
        return try withAdvapi32 { module in
            guard let rawProc = GetProcAddress(module, "ConvertSidToStringSidW") else {
                throw WindowsOSFailure("GetProcAddress(ConvertSidToStringSidW)")
            }
            let convertSid = unsafeBitCast(rawProc, to: ConvertSidToStringSidWFn.self)
            var sidStringPtr: LPWSTR? = nil
            guard convertSid(user.User.Sid, &sidStringPtr).boolValue, let textPtr = sidStringPtr else {
                throw WindowsOSFailure("ConvertSidToStringSidW")
            }
            defer { _ = LocalFree(UnsafeMutableRawPointer(textPtr)) }

            var count = 0
            while textPtr[count] != 0 {
                count += 1
            }
            let units = UnsafeBufferPointer(start: textPtr, count: count)
            return String(decoding: units, as: UTF16.self)
        }
    }
}

internal func windowsLogStderr(_ message: String) {
    try? FileHandle.standardError.write(contentsOf: Data((message + "\n").utf8))
}

internal func windowsMonotonicNowNs() -> UInt64 {
    var counter = LARGE_INTEGER()
    var frequency = LARGE_INTEGER()
    if QueryPerformanceCounter(&counter),
       QueryPerformanceFrequency(&frequency),
       frequency.QuadPart > 0,
       counter.QuadPart >= 0 {
        let ticks = UInt64(counter.QuadPart)
        let freq = UInt64(frequency.QuadPart)
        let seconds = ticks / freq
        let remainder = ticks % freq
        return seconds &* 1_000_000_000 &+ (remainder &* 1_000_000_000) / freq
    }
    return UInt64(GetTickCount64()) &* 1_000_000
}

/// A Windows Job Object configured with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`.
/// Terminating it kills every descendant; closing an armed handle on crash kills them too.
/// On a successful child exit, `finish(failed: false)` disarms kill-on-close before closing.
internal final class WindowsJobObject: @unchecked Sendable {
    private let handle: OwnedWinHandle

    private init(handle: OwnedWinHandle) {
        self.handle = handle
    }

    /// Creates an unnamed job object armed with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`.
    /// Returns `nil` (after warning to stderr) if creation or limit configuration fails,
    /// matching upstream `pipe/windows.rs#Job::new`.
    static func create(label: String) -> WindowsJobObject? {
        let rawHandle = CreateJobObjectW(nil, nil)
        let owned: OwnedWinHandle
        do {
            owned = try OwnedWinHandle.adopt(rawHandle, operation: "CreateJobObjectW")
        } catch {
            windowsLogStderr("\(label): running without a job object: \(error)")
            return nil
        }
        let job = WindowsJobObject(handle: owned)
        do {
            try job.setLimits(DWORD(WindowsProcessHelpers.jobLimitFlags(killOnClose: true)))
        } catch {
            windowsLogStderr("\(label): running without a job object: \(error)")
            return nil
        }
        return job
    }

    func setLimits(_ flags: DWORD) throws {
        var limits = JOBOBJECT_EXTENDED_LIMIT_INFORMATION()
        limits.BasicLimitInformation.LimitFlags = flags
        let ok = withUnsafeMutablePointer(to: &limits) { ptr in
            SetInformationJobObject(
                handle.raw,
                JobObjectExtendedLimitInformation,
                UnsafeMutableRawPointer(ptr),
                DWORD(MemoryLayout<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>.size)
            )
        }
        guard ok else {
            throw WindowsOSFailure("SetInformationJobObject")
        }
    }

    func assign(process: OwnedWinHandle) throws {
        guard AssignProcessToJobObject(handle.raw, process.raw) else {
            throw WindowsOSFailure("AssignProcessToJobObject")
        }
    }

    func terminate(exitCode: DWORD = 1) throws {
        guard TerminateJobObject(handle.raw, exitCode) else {
            throw WindowsOSFailure("TerminateJobObject")
        }
    }

    /// Mirrors upstream `pipe/windows.rs#Job::finish`.
    /// If `failed` is true, terminates the job tree first (leaving kill-on-close armed if termination
    /// fails so closing the handle acts as fallback). Otherwise disarms kill-on-close before release.
    func finish(failed: Bool) throws {
        if failed {
            try terminate(exitCode: 1)
        }
        try setLimits(DWORD(WindowsProcessHelpers.jobLimitFlags(killOnClose: false)))
    }
}

/// A created, still-suspended Windows process. Dropping it before `resume()` terminates it,
/// matching upstream `pipe/windows.rs#Spawned`.
internal final class WindowsSuspendedProcess {
    let pid: UInt32
    private var processHandle: OwnedWinHandle?
    private let threadHandle: OwnedWinHandle

    init(pid: UInt32, process: OwnedWinHandle, thread: OwnedWinHandle) {
        self.pid = pid
        self.processHandle = process
        self.threadHandle = thread
    }

    deinit {
        if let proc = processHandle {
            _ = TerminateProcess(proc.raw, 1)
        }
    }

    var process: OwnedWinHandle {
        guard let proc = processHandle else {
            preconditionFailure("process handle was already consumed by resume()")
        }
        return proc
    }

    func resume() throws -> (pid: UInt32, process: OwnedWinHandle) {
        guard ResumeThread(threadHandle.raw) != DWORD(bitPattern: -1) else {
            throw WindowsOSFailure("ResumeThread")
        }
        guard let proc = processHandle else {
            preconditionFailure("process handle was already consumed by resume()")
        }
        processHandle = nil
        return (pid: pid, process: proc)
    }
}

/// Low-level Win32 pipe, file, process, and ConPTY helpers used by `ProcessDaemon`, `ProcessRunner`,
/// and `ProcessDaemonServer` on `#if os(Windows)`.
internal enum WindowsProcessPrimitives {
    static func inheritableSecurityAttributes() -> SECURITY_ATTRIBUTES {
        var sa = SECURITY_ATTRIBUTES()
        sa.nLength = DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size)
        sa.lpSecurityDescriptor = nil
        sa.bInheritHandle = true
        return sa
    }

    static func openNullReadHandle() throws -> OwnedWinHandle {
        let wide = try WindowsProcessHelpers.encodeWideString("NUL")
        var sa = inheritableSecurityAttributes()
        let raw = wide.withUnsafeBufferPointer { ptr in
            CreateFileW(
                ptr.baseAddress,
                DWORD(GENERIC_READ),
                DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE),
                &sa,
                DWORD(OPEN_EXISTING),
                0,
                nil
            )
        }
        return try OwnedWinHandle.adopt(raw, operation: "CreateFileW(NUL)")
    }

    static func duplicateInheritable(_ source: OwnedWinHandle) throws -> OwnedWinHandle {
        var dup: HANDLE? = nil
        guard DuplicateHandle(
            GetCurrentProcess(),
            source.raw,
            GetCurrentProcess(),
            &dup,
            0,
            true,
            DWORD(DUPLICATE_SAME_ACCESS)
        ) else {
            throw WindowsOSFailure("DuplicateHandle")
        }
        return try OwnedWinHandle.adopt(dup, operation: "DuplicateHandle")
    }

    static func createAnonymousPipe(
        inheritRead: Bool,
        inheritWrite: Bool
    ) throws -> (read: OwnedWinHandle, write: OwnedWinHandle) {
        var sa = SECURITY_ATTRIBUTES()
        sa.nLength = DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size)
        sa.lpSecurityDescriptor = nil
        sa.bInheritHandle = false

        var readRaw: HANDLE? = nil
        var writeRaw: HANDLE? = nil
        guard CreatePipe(&readRaw, &writeRaw, &sa, 0) else {
            throw WindowsOSFailure("CreatePipe")
        }
        let readEnd = try OwnedWinHandle.adopt(readRaw, operation: "CreatePipe(read)")
        let writeEnd = try OwnedWinHandle.adopt(writeRaw, operation: "CreatePipe(write)")

        if inheritRead {
            guard SetHandleInformation(readEnd.raw, DWORD(HANDLE_FLAG_INHERIT), DWORD(HANDLE_FLAG_INHERIT)) else {
                throw WindowsOSFailure("SetHandleInformation(read)")
            }
        }
        if inheritWrite {
            guard SetHandleInformation(writeEnd.raw, DWORD(HANDLE_FLAG_INHERIT), DWORD(HANDLE_FLAG_INHERIT)) else {
                throw WindowsOSFailure("SetHandleInformation(write)")
            }
        }
        return (read: readEnd, write: writeEnd)
    }

    /// Creates a private, overlapped inbound byte-mode named pipe server and its inheritable
    /// write client handle (with `FILE_READ_ATTRIBUTES` so Git Bash/Python/Go can fstat stdout),
    /// matching `upstream/src/service/pipe/windows.rs#output_pipe`.
    static func createPipeOutputChannel() throws -> (server: OwnedWinHandle, client: OwnedWinHandle) {
        let security = try WindowsPrivateSecurity.create()
        let pipeName = WindowsProcessHelpers.windowsPipeName(randomHex32: ProcessDaemon.randomHex32())
        let wideName = try WindowsProcessHelpers.encodeWideString(pipeName)

        var serverSA = security.securityAttributes(inherit: false)
        let serverRaw = wideName.withUnsafeBufferPointer { ptr in
            CreateNamedPipeW(
                ptr.baseAddress,
                DWORD(PIPE_ACCESS_INBOUND | FILE_FLAG_OVERLAPPED | FILE_FLAG_FIRST_PIPE_INSTANCE),
                DWORD(PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS),
                1,
                0,
                DWORD(WindowsProcessHelpers.pipeBufferBytes),
                0,
                &serverSA
            )
        }
        let server = try OwnedWinHandle.adopt(serverRaw, operation: "CreateNamedPipeW")

        var clientSA = inheritableSecurityAttributes()
        let clientRaw = wideName.withUnsafeBufferPointer { ptr in
            CreateFileW(
                ptr.baseAddress,
                DWORD(GENERIC_WRITE | FILE_READ_ATTRIBUTES),
                0,
                &clientSA,
                DWORD(OPEN_EXISTING),
                0,
                nil
            )
        }
        let client = try OwnedWinHandle.adopt(clientRaw, operation: "CreateFileW(output pipe client)")
        return (server: server, client: client)
    }

    /// Opens the pipe output file before spawning, refusing reparse points without truncating
    /// any symlink target, sharing read/write/delete access, and truncating to 0 through the handle.
    /// Matches `upstream/src/service/pipe/windows.rs#open_output`.
    static func openPipeOutputFile(at path: String) throws -> OwnedWinHandle {
        let widePath = try WindowsProcessHelpers.encodeWideString(path)
        let raw = widePath.withUnsafeBufferPointer { ptr in
            CreateFileW(
                ptr.baseAddress,
                DWORD(GENERIC_WRITE | FILE_READ_ATTRIBUTES),
                DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE),
                nil,
                DWORD(OPEN_ALWAYS),
                DWORD(FILE_FLAG_OPEN_REPARSE_POINT),
                nil
            )
        }
        let handle = try OwnedWinHandle.adopt(raw, operation: "failed to open output file \(path)")
        var info = BY_HANDLE_FILE_INFORMATION()
        guard GetFileInformationByHandle(handle.raw, &info) else {
            throw WindowsOSFailure("failed to open output file \(path)")
        }
        if (info.dwFileAttributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT)) != 0 {
            throw ProcessDaemon.DaemonError("failed to open output file \(path): output path is a reparse point")
        }
        let zero = LARGE_INTEGER()
        guard SetFilePointerEx(handle.raw, zero, nil, DWORD(FILE_BEGIN)),
              SetEndOfFile(handle.raw) else {
            throw WindowsOSFailure("failed to open output file \(path)")
        }
        return handle
    }

    /// Spawns a suspended Windows child process with an explicit `PROC_THREAD_ATTRIBUTE_HANDLE_LIST`
    /// containing only `[stdin, stdout, stderr]`, optional UTF-16 environment block, and optional cwd.
    static func createSuspendedProcessWithHandleList(
        program: String,
        args: [String],
        cwd: String?,
        env: [String: String]?,
        stdin: OwnedWinHandle,
        stdout: OwnedWinHandle,
        stderr: OwnedWinHandle,
        creationFlags: UInt32
    ) throws -> WindowsSuspendedProcess {
        var commandLine = try WindowsProcessHelpers.buildCommandLine(program: program, args: args)
        let envBlock: [UInt16]? = try env.map { try WindowsProcessHelpers.buildEnvironmentBlock($0) }
        let wideCwd: [UInt16]? = try cwd.map { try WindowsProcessHelpers.encodeWideString($0) }

        var attrBytes = SIZE_T(0)
        _ = InitializeProcThreadAttributeList(nil, 1, 0, &attrBytes)
        guard attrBytes > 0 else {
            throw WindowsOSFailure("InitializeProcThreadAttributeList(size)")
        }
        let attrBuffer = UnsafeMutableRawBufferPointer.allocate(byteCount: Int(attrBytes), alignment: 16)
        defer { attrBuffer.deallocate() }

        let attrList = LPPROC_THREAD_ATTRIBUTE_LIST(attrBuffer.baseAddress!)
        guard InitializeProcThreadAttributeList(attrList, 1, 0, &attrBytes) else {
            throw WindowsOSFailure("InitializeProcThreadAttributeList")
        }
        defer { DeleteProcThreadAttributeList(attrList) }

        // Keep the handle array allocation alive until after DeleteProcThreadAttributeList.
        let handleValues: [HANDLE] = [stdin.raw, stdout.raw, stderr.raw]
        let handlesPtr = UnsafeMutablePointer<HANDLE>.allocate(capacity: handleValues.count)
        handlesPtr.initialize(from: handleValues, count: handleValues.count)
        defer {
            handlesPtr.deinitialize(count: handleValues.count)
            handlesPtr.deallocate()
        }

        guard UpdateProcThreadAttribute(
            attrList,
            0,
            DWORD_PTR(WindowsProcessHelpers.procThreadAttributeHandleList),
            UnsafeMutableRawPointer(handlesPtr),
            SIZE_T(MemoryLayout<HANDLE>.stride * handleValues.count),
            nil,
            nil
        ) else {
            throw WindowsOSFailure("UpdateProcThreadAttribute(HANDLE_LIST)")
        }

        var startup = STARTUPINFOEXW()
        startup.StartupInfo.cb = DWORD(MemoryLayout<STARTUPINFOEXW>.size)
        startup.StartupInfo.dwFlags = DWORD(WindowsProcessHelpers.startfUseStdHandles)
        startup.StartupInfo.hStdInput = stdin.raw
        startup.StartupInfo.hStdOutput = stdout.raw
        startup.StartupInfo.hStdError = stderr.raw
        startup.lpAttributeList = attrList

        var processInfo = PROCESS_INFORMATION()
        let created: Bool = commandLine.withUnsafeMutableBufferPointer { cmdPtr in
            withOptionalUTF16Pointer(envBlock) { envPtr in
                withOptionalUTF16Pointer(wideCwd) { dirPtr in
                    withUnsafeMutablePointer(to: &startup) { startupPtr in
                        CreateProcessW(
                            nil,
                            cmdPtr.baseAddress,
                            nil,
                            nil,
                            true,
                            DWORD(creationFlags),
                            envPtr.map { UnsafeMutableRawPointer(mutating: $0) },
                            dirPtr,
                            startupPtr.pointer(to: \.StartupInfo)!,
                            &processInfo
                        )
                    }
                }
            }
        }
        guard created else {
            throw WindowsOSFailure("CreateProcessW")
        }
        let procHandle = try OwnedWinHandle.adopt(processInfo.hProcess, operation: "CreateProcessW(hProcess)")
        let threadHandle = try OwnedWinHandle.adopt(processInfo.hThread, operation: "CreateProcessW(hThread)")
        return WindowsSuspendedProcess(pid: UInt32(processInfo.dwProcessId), process: procHandle, thread: threadHandle)
    }

    /// Spawns a suspended Windows child process attached to a ConPTY `HPCON`.
    static func createSuspendedProcessWithConPty(
        program: String,
        args: [String],
        cwd: String?,
        env: [String: String],
        pseudoConsole: HPCON
    ) throws -> WindowsSuspendedProcess {
        var commandLine = try WindowsProcessHelpers.buildCommandLine(program: program, args: args)
        let envBlock = try WindowsProcessHelpers.buildEnvironmentBlock(env)
        let wideCwd: [UInt16]? = try cwd.map { try WindowsProcessHelpers.encodeWideString($0) }

        var attrBytes = SIZE_T(0)
        _ = InitializeProcThreadAttributeList(nil, 1, 0, &attrBytes)
        guard attrBytes > 0 else {
            throw WindowsOSFailure("InitializeProcThreadAttributeList(size)")
        }
        let attrBuffer = UnsafeMutableRawBufferPointer.allocate(byteCount: Int(attrBytes), alignment: 16)
        defer { attrBuffer.deallocate() }

        let attrList = LPPROC_THREAD_ATTRIBUTE_LIST(attrBuffer.baseAddress!)
        guard InitializeProcThreadAttributeList(attrList, 1, 0, &attrBytes) else {
            throw WindowsOSFailure("InitializeProcThreadAttributeList")
        }
        defer { DeleteProcThreadAttributeList(attrList) }

        // Per Microsoft ConPTY docs, lpValue receives the HPCON handle directly (not &hPC).
        guard UpdateProcThreadAttribute(
            attrList,
            0,
            DWORD_PTR(WindowsProcessHelpers.procThreadAttributePseudoConsole),
            pseudoConsole,
            SIZE_T(MemoryLayout<HPCON>.size),
            nil,
            nil
        ) else {
            throw WindowsOSFailure("UpdateProcThreadAttribute(PSEUDOCONSOLE)")
        }

        var startup = STARTUPINFOEXW()
        startup.StartupInfo.cb = DWORD(MemoryLayout<STARTUPINFOEXW>.size)
        startup.lpAttributeList = attrList

        let flags = WindowsProcessHelpers.creationFlags(for: .conpty, hasExplicitEnvironment: true)
        var processInfo = PROCESS_INFORMATION()
        let created: Bool = commandLine.withUnsafeMutableBufferPointer { cmdPtr in
            envBlock.withUnsafeBufferPointer { envPtr in
                withOptionalUTF16Pointer(wideCwd) { dirPtr in
                    withUnsafeMutablePointer(to: &startup) { startupPtr in
                        CreateProcessW(
                            nil,
                            cmdPtr.baseAddress,
                            nil,
                            nil,
                            false,
                            DWORD(flags),
                            UnsafeMutableRawPointer(mutating: envPtr.baseAddress),
                            dirPtr,
                            startupPtr.pointer(to: \.StartupInfo)!,
                            &processInfo
                        )
                    }
                }
            }
        }
        guard created else {
            throw WindowsOSFailure("CreateProcessW(ConPTY)")
        }
        let procHandle = try OwnedWinHandle.adopt(processInfo.hProcess, operation: "CreateProcessW(hProcess)")
        let threadHandle = try OwnedWinHandle.adopt(processInfo.hThread, operation: "CreateProcessW(hThread)")
        return WindowsSuspendedProcess(pid: UInt32(processInfo.dwProcessId), process: procHandle, thread: threadHandle)
    }

    /// Terminates either the job tree or the single process handle, suppressing `ERROR_ACCESS_DENIED`
    /// when the target has already exited (matching upstream `pipe/windows.rs#terminate`).
    static func terminateTree(process: OwnedWinHandle, job: WindowsJobObject?) throws {
        do {
            if let job {
                try job.terminate(exitCode: 1)
            } else if !TerminateProcess(process.raw, 1) {
                throw WindowsOSFailure("TerminateProcess")
            }
        } catch let failure as WindowsOSFailure where WindowsProcessHelpers.isAlreadyExitedTerminateError(failure.code) {
            return
        }
    }

    /// Writes all `bytes` to `handle`, incrementing `newlines` for every `\n` byte that reached
    /// the handle (including partial writes before an error), matching upstream `service/pipe.rs#write_counting`.
    static func writeAllCountingNewlines(
        to handle: OwnedWinHandle,
        bytes: [UInt8],
        newlines: inout UInt64
    ) throws {
        guard !bytes.isEmpty else { return }
        try bytes.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                var written: DWORD = 0
                let chunkSize = DWORD(min(bytes.count - offset, Int(DWORD.max)))
                guard WriteFile(handle.raw, base.advanced(by: offset), chunkSize, &written, nil) else {
                    throw WindowsOSFailure("WriteFile")
                }
                if written == 0 {
                    throw WindowsOSFailure("WriteFile(zero bytes)", code: 0)
                }
                let end = offset + Int(written)
                for i in offset..<end where bytes[i] == UInt8(ascii: "\n") {
                    newlines &+= 1
                }
                offset = end
            }
        }
    }

    /// Writes all `bytes` to `handle` synchronously.
    static func writeAll(to handle: OwnedWinHandle, bytes: [UInt8]) throws {
        var ignored: UInt64 = 0
        try writeAllCountingNewlines(to: handle, bytes: bytes, newlines: &ignored)
    }

    /// Reads synchronously from `handle` until EOF or `ERROR_BROKEN_PIPE`.
    static func readAllSync(from handle: OwnedWinHandle) -> [UInt8] {
        var collected: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: WindowsProcessHelpers.pipeReadBytes)
        while true {
            var bytesRead: DWORD = 0
            let ok = chunk.withUnsafeMutableBytes { rawBuf in
                ReadFile(handle.raw, rawBuf.baseAddress, DWORD(rawBuf.count), &bytesRead, nil)
            }
            if ok {
                if bytesRead == 0 { break }
                collected.append(contentsOf: chunk[0..<Int(bytesRead)])
            } else {
                break
            }
        }
        return collected
    }

    /// Matches upstream `daemon/windows.rs#process_exists`: opens `SYNCHRONIZE` and
    /// checks the process object with zero-timeout `WaitForSingleObject`, treating `ERROR_ACCESS_DENIED` as live.
    static func processExists(pid: UInt32) -> Bool {
        guard pid > 0 else { return false }
        guard let raw = OpenProcess(SYNCHRONIZE, false, DWORD(pid)),
              raw != INVALID_HANDLE_VALUE else {
            return UInt32(GetLastError()) == WindowsProcessHelpers.errorAccessDenied
        }
        let handle = OwnedWinHandle(raw)
        return WaitForSingleObject(handle.raw, 0) != WAIT_OBJECT_0
    }

    private static func withOptionalUTF16Pointer<R>(
        _ array: [UInt16]?,
        _ body: (UnsafePointer<UInt16>?) throws -> R
    ) rethrows -> R {
        if let array {
            return try array.withUnsafeBufferPointer { try body($0.baseAddress) }
        }
        return try body(nil)
    }
}

/// Stable heap-allocated overlapped pipe reader matching upstream `pipe/windows.rs#Read`.
/// Cancels and reaps any pending overlapped I/O before releasing `OVERLAPPED`, buffer, or handles.
/// Created on the spawn thread and exclusively owned by the single output reader thread.
internal final class WindowsOverlappedRead: @unchecked Sendable {
    private let pipe: OwnedWinHandle
    private let readEvent: OwnedWinHandle
    private let overlappedPtr: UnsafeMutablePointer<OVERLAPPED>
    private let bufferPtr: UnsafeMutablePointer<UInt8>
    private var pending: Bool = false
    private var closed: Bool = false

    init(pipe: OwnedWinHandle) throws {
        self.pipe = pipe
        self.readEvent = try OwnedWinHandle.makeManualResetEvent()
        let ov = UnsafeMutablePointer<OVERLAPPED>.allocate(capacity: 1)
        ov.initialize(to: OVERLAPPED())
        ov.pointee.hEvent = readEvent.raw
        self.overlappedPtr = ov
        self.bufferPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: WindowsProcessHelpers.pipeReadBytes)
    }

    deinit {
        cancelAndClose()
        overlappedPtr.deinitialize(count: 1)
        overlappedPtr.deallocate()
        bufferPtr.deallocate()
    }

    var isPending: Bool { pending }
    var eventHandle: HANDLE { readEvent.raw }

    func cancelAndClose() {
        guard !closed else { return }
        closed = true
        if pending {
            var count: DWORD = 0
            _ = CancelIoEx(pipe.raw, overlappedPtr)
            _ = GetOverlappedResult(pipe.raw, overlappedPtr, &count, true)
            pending = false
        }
    }

    /// Submits one overlapped read. Returns `.some(count)` if it completed synchronously,
    /// `nil` if `ERROR_IO_PENDING` (now pending), or throws the Win32 failure.
    func submit() throws -> Int? {
        readEvent.resetEvent()
        let ok = ReadFile(
            pipe.raw,
            UnsafeMutableRawPointer(bufferPtr),
            DWORD(WindowsProcessHelpers.pipeReadBytes),
            nil,
            overlappedPtr
        )
        if ok {
            pending = true
            return try complete()
        }
        let err = GetLastError()
        if UInt32(err) != WindowsProcessHelpers.errorIoPending {
            throw WindowsOSFailure("ReadFile", code: err)
        }
        pending = true
        return nil
    }

    /// Reaps a submitted overlapped read. Waiting guarantees the kernel has stopped touching our buffers.
    func complete() throws -> Int {
        var count: DWORD = 0
        let ok = GetOverlappedResult(pipe.raw, overlappedPtr, &count, true)
        pending = false
        if !ok {
            throw WindowsOSFailure("GetOverlappedResult")
        }
        return Int(count)
    }

    func copyBytes(length: Int) -> [UInt8] {
        guard length > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: bufferPtr, count: length))
    }
}

/// Runs the overlapped pipe output reader loop matching `upstream/src/service/pipe/windows.rs#read_output`.
/// Writes every chunk to `outputFile` BEFORE forwarding to `actor`, closes the file and pipe BEFORE
/// emitting EOF or failure, and enforces `DRAIN_AFTER_EXIT` (1 second) once `exitEvent` fires.
internal func runWindowsPipeOutputReader(
    reader initialReader: WindowsOverlappedRead?,
    initError: String?,
    outputFile: OwnedWinHandle,
    actor: ProcessDaemon.SessionActor,
    cancelEvent: OwnedWinHandle,
    exitEvent: OwnedWinHandle
) {
    var reader: WindowsOverlappedRead? = initialReader
    var sinkFile: OwnedWinHandle? = outputFile

    func closeAllAndEmitEof() {
        reader?.cancelAndClose()
        reader = nil
        sinkFile = nil
        actor.emitReaderEof()
    }

    func closeAllAndEmitFailed(_ message: String) {
        reader?.cancelAndClose()
        reader = nil
        sinkFile = nil
        actor.emitReaderFailed(message)
    }

    if let initError {
        closeAllAndEmitFailed(initError)
        return
    }
    guard reader != nil else {
        closeAllAndEmitFailed("missing overlapped reader")
        return
    }

    let drainNs: UInt64 = WindowsProcessHelpers.drainAfterExitMs * 1_000_000
    var exited = exitEvent.isSignalled()
    var deadlineNs: UInt64? = exited ? (windowsMonotonicNowNs() &+ drainNs) : nil

    while true {
        // Cancellation and exit win over output so a noisy descendant cannot starve them.
        if cancelEvent.isSignalled() {
            reader?.cancelAndClose()
            reader = nil
            sinkFile = nil
            return
        }
        if !exited && exitEvent.isSignalled() {
            exited = true
            deadlineNs = windowsMonotonicNowNs() &+ drainNs
        }
        if let deadline = deadlineNs, windowsMonotonicNowNs() >= deadline {
            closeAllAndEmitEof()
            return
        }

        guard let activeReader = reader else { return }
        let completed: Result<Int, Error>?
        if activeReader.isPending {
            let timeout: DWORD
            if let deadline = deadlineNs {
                let now = windowsMonotonicNowNs()
                timeout = DWORD(WindowsProcessHelpers.remainingWaitTimeoutMs(deadlineNs: deadline, nowNs: now))
            } else {
                timeout = INFINITE
            }
            // Cancel is index 0 so WaitForMultipleObjects prioritizes it over an always-readable pipe.
            let handles: [HANDLE?] = [cancelEvent.raw, activeReader.eventHandle, exitEvent.raw]
            let count: DWORD = exited ? 2 : 3
            let waitResult = handles.withUnsafeBufferPointer { ptr in
                WaitForMultipleObjects(count, ptr.baseAddress, false, timeout)
            }
            switch waitResult {
            case WAIT_OBJECT_0:
                reader?.cancelAndClose()
                reader = nil
                sinkFile = nil
                return
            case WAIT_OBJECT_0 + 1:
                completed = Result { try activeReader.complete() }
            case WAIT_OBJECT_0 + 2:
                exited = true
                deadlineNs = windowsMonotonicNowNs() &+ drainNs
                completed = nil
            case DWORD(WAIT_TIMEOUT):
                closeAllAndEmitEof()
                return
            default:
                let err = WindowsOSFailure("WaitForMultipleObjects")
                closeAllAndEmitFailed(err.description)
                return
            }
        } else {
            do {
                if let length = try activeReader.submit() {
                    completed = .success(length)
                } else {
                    completed = nil
                }
            } catch {
                completed = .failure(error)
            }
        }

        guard let result = completed else { continue }
        switch result {
        case .success(0):
            closeAllAndEmitEof()
            return
        case .success(let length):
            let bytes = activeReader.copyBytes(length: length)
            var newlines: UInt64 = 0
            if let file = sinkFile {
                do {
                    try WindowsProcessPrimitives.writeAllCountingNewlines(
                        to: file,
                        bytes: bytes,
                        newlines: &newlines
                    )
                } catch {
                    sinkFile = nil
                    actor.emitOutputFileError("failed to write output file: \(error)")
                }
            }
            actor.emitPipeOutput(bytes, newlines: newlines)
        case .failure(let error):
            if let osErr = error as? WindowsOSFailure,
               WindowsProcessHelpers.isEndOfOutputError(osErr.code) {
                closeAllAndEmitEof()
            } else {
                closeAllAndEmitFailed(String(describing: error))
            }
            return
        }
    }
}

#endif
