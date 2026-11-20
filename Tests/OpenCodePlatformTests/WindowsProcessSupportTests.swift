import Synchronization
import Testing
import OpenCodePlatform

private struct MockSpawnError: Error, Equatable, Sendable {
    let reason: String
}

@Suite("Windows Process Spawn, Job Object, Quoting, Environment & Lifecycle Helpers")
struct WindowsProcessSupportTests {

    private static func utf16Text(_ units: [UInt16]) -> String {
        String(decoding: units, as: UTF16.self)
    }

    // MARK: - Command-Line Quoting (MSVCRT / CommandLineToArgvW parity with `pipe/windows.rs`)

    @Test("buildCommandLine terminates with NUL and quotes per MSVCRT rules matching upstream")
    func commandLinesAreTerminatedAndQuotedForMsvcrt() throws {
        // Upstream pipe/windows.rs test cases
        let cmd1 = try WindowsProcessHelpers.buildCommandLine(
            program: "cmd.exe",
            args: ["/d", "/c", "echo hi"]
        )
        #expect(cmd1.last == 0)
        #expect(Self.utf16Text(Array(cmd1.dropLast())) == #""cmd.exe" /d /c "echo hi""#)

        let cmd2 = try WindowsProcessHelpers.buildCommandLine(
            program: "a b.exe",
            args: ["", #"echo "hi""#]
        )
        #expect(cmd2.last == 0)
        #expect(Self.utf16Text(Array(cmd2.dropLast())) == #""a b.exe" "" "echo \"hi\"""#)

        // Quoted argument with trailing backslash doubles trailing backslashes before closing quote
        let cmd3 = try WindowsProcessHelpers.buildCommandLine(
            program: "x.exe",
            args: [#"C:\a b\"#]
        )
        #expect(Self.utf16Text(Array(cmd3.dropLast())) == #""x.exe" "C:\a b\\""#)

        // Unquoted argument with trailing backslash does NOT double trailing backslashes (no closing quote)
        let cmd4 = try WindowsProcessHelpers.buildCommandLine(
            program: "x.exe",
            args: [#"C:\plain\"#, "plain", "has\ttab", #"a\\b\"c"#]
        )
        #expect(
            Self.utf16Text(Array(cmd4.dropLast()))
                == "\"x.exe\" C:\\plain\\ plain \"has\ttab\" a\\\\b\\\\\\\"c"
        )

        // Upstream pipe_windows.rs round-trip argument set
        let cmd5 = try WindowsProcessHelpers.buildCommandLine(
            program: "powershell.exe",
            args: ["plain", "with space", #"say "hi""#, #"C:\with space\"#]
        )
        #expect(
            Self.utf16Text(Array(cmd5.dropLast()))
                == #""powershell.exe" plain "with space" "say \"hi\"" "C:\with space\\""#
        )

        // Multiple trailing backslashes inside quoted arg (n -> 2n) and before internal quote (n -> 2n+1)
        let cmd6 = try WindowsProcessHelpers.buildCommandLine(
            program: "app.exe",
            args: [#"two\\ "quoted"\\"#]
        )
        #expect(
            Self.utf16Text(Array(cmd6.dropLast()))
                == #""app.exe" "two\\ \"quoted\"\\\\""#
        )

        // Non-ASCII & surrogate pairs (emoji / CJK) round-trip cleanly in UTF-16
        let cmdUnicode = try WindowsProcessHelpers.buildCommandLine(
            program: #"C:\ツール\app.exe"#,
            args: ["hello 🚀 world", "日本語"]
        )
        #expect(cmdUnicode.last == 0)
        #expect(
            Self.utf16Text(Array(cmdUnicode.dropLast()))
                == #""C:\ツール\app.exe" "hello 🚀 world" 日本語"#
        )
    }

    @Test("buildCommandLine rejects NULs in program/args and quotes in program")
    func commandLinesRejectUnrepresentableInputs() {
        #expect(throws: WindowsProcessHelpers.EncodingError.self) {
            _ = try WindowsProcessHelpers.buildCommandLine(program: "a\u{0}b", args: [])
        }
        #expect(throws: WindowsProcessHelpers.EncodingError.self) {
            _ = try WindowsProcessHelpers.buildCommandLine(program: #"a"b"#, args: [])
        }
        #expect(throws: WindowsProcessHelpers.EncodingError.self) {
            _ = try WindowsProcessHelpers.buildCommandLine(program: "x.exe", args: ["ok", "a\u{0}b"])
        }
    }

    // MARK: - Environment Block Encoding (`pipe/windows.rs#environment_block`)

    @Test("buildEnvironmentBlock sorts case-insensitively ordinally and double-NUL-terminates")
    func environmentBlocksSortedAndDoubleTerminated() throws {
        let block = try WindowsProcessHelpers.buildEnvironmentBlock(["B": "2", "A": "1"])
        #expect(block == Array("A=1\u{0}B=2\u{0}\u{0}".utf16))

        let empty = try WindowsProcessHelpers.buildEnvironmentBlock([:])
        #expect(empty == [0, 0])

        // Case-insensitive ordinal puts `a` before `B`, matching CompareStringOrdinal(..., TRUE)
        let caseOrder = try WindowsProcessHelpers.buildEnvironmentBlock(["a": "1", "B": "2"])
        #expect(Self.utf16Text(caseOrder) == "a=1\u{0}B=2\u{0}\u{0}")

        // Uppercase folding puts `z` ('Z' = 0x5A) before `_` (0x5F), matching Windows CompareStringOrdinal
        let underscoreOrder = try WindowsProcessHelpers.buildEnvironmentBlock(["_": "under", "z": "zee"])
        #expect(Self.utf16Text(underscoreOrder) == "z=zee\u{0}_=under\u{0}\u{0}")
    }

    @Test("buildEnvironmentBlock accepts drive-directory keys, collapses case variants deterministically, and rejects invalid keys/values")
    func environmentBlocksDriveDirsDeduplicationAndValidation() throws {
        let block = try WindowsProcessHelpers.buildEnvironmentBlock([
            "=C:": #"C:\work"#,
            "PATH": "upper",
            "Path": "lower",
        ])
        // Ordinal-largest case variant (`Path` > `PATH`) wins deterministically, matching upstream.
        #expect(Self.utf16Text(block) == "=C:=C:\\work\u{0}Path=lower\u{0}\u{0}")

        let invalidPairs: [(String, String)] = [
            ("", "x"),
            ("=", "x"),
            ("A=B", "x"),
            ("=C:=D", "x"),
            ("A\u{0}B", "x"),
            ("KEY", "val\u{0}ue"),
        ]
        for (k, v) in invalidPairs {
            #expect(throws: WindowsProcessHelpers.EncodingError.self) {
                _ = try WindowsProcessHelpers.buildEnvironmentBlock([k: v])
            }
        }
    }

    @Test("encodeWideString encodes UTF-16 NUL-terminated strings and rejects embedded NUL")
    func encodeWideStringBehavior() throws {
        #expect(try WindowsProcessHelpers.encodeWideString("NUL") == [78, 85, 76, 0])
        #expect(try WindowsProcessHelpers.encodeWideString("") == [0])
        let emoji = try WindowsProcessHelpers.encodeWideString("🚀")
        #expect(emoji == [0xD83D, 0xDE80, 0])
        #expect(throws: WindowsProcessHelpers.EncodingError.self) {
            _ = try WindowsProcessHelpers.encodeWideString("bad\u{0}path")
        }
    }

    // MARK: - Creation Flags, Job Limits, Error Classification, Timeouts & Naming

    @Test("creationFlags and jobLimitFlags match upstream Win32 bitmasks")
    func creationAndJobLimitFlags() {
        let pipeFlags = WindowsProcessHelpers.creationFlags(for: .pipe, hasExplicitEnvironment: true)
        #expect(
            pipeFlags
                == (WindowsProcessHelpers.createNoWindow
                    | WindowsProcessHelpers.createSuspended
                    | WindowsProcessHelpers.createUnicodeEnvironment
                    | WindowsProcessHelpers.extendedStartupInfoPresent)
        )
        #expect(pipeFlags == 0x0808_0404)

        let spawnerInheritedEnvFlags = WindowsProcessHelpers.creationFlags(for: .spawner, hasExplicitEnvironment: false)
        #expect((spawnerInheritedEnvFlags & WindowsProcessHelpers.createSuspended) != 0)
        #expect((spawnerInheritedEnvFlags & WindowsProcessHelpers.createNoWindow) != 0)
        #expect((spawnerInheritedEnvFlags & WindowsProcessHelpers.extendedStartupInfoPresent) != 0)
        #expect((spawnerInheritedEnvFlags & WindowsProcessHelpers.createUnicodeEnvironment) == 0)

        let conptyFlags = WindowsProcessHelpers.creationFlags(for: .conpty, hasExplicitEnvironment: true)
        #expect((conptyFlags & WindowsProcessHelpers.createSuspended) != 0)
        #expect((conptyFlags & WindowsProcessHelpers.extendedStartupInfoPresent) != 0)
        #expect((conptyFlags & WindowsProcessHelpers.createUnicodeEnvironment) != 0)
        #expect((conptyFlags & WindowsProcessHelpers.createNoWindow) == 0)

        #expect(WindowsProcessHelpers.jobLimitFlags(killOnClose: true) == 0x0000_2000)
        #expect(WindowsProcessHelpers.jobLimitFlags(killOnClose: false) == 0)
        #expect(WindowsProcessHelpers.procThreadAttributeHandleList == 0x0002_0002)
        #expect(WindowsProcessHelpers.procThreadAttributePseudoConsole == 0x0002_0016)
    }

    @Test("error classifiers, wait timeout ceiling rounding, SDDL, pipe name, and signal mappings match upstream")
    func errorClassifiersTimeoutsAndMappings() {
        #expect(WindowsProcessHelpers.shouldTerminateJobOnExit(exitCode: 0, wasKilled: false) == false)
        #expect(WindowsProcessHelpers.shouldTerminateJobOnExit(exitCode: 3, wasKilled: false) == true)
        #expect(WindowsProcessHelpers.shouldTerminateJobOnExit(exitCode: 1, wasKilled: true) == false)

        #expect(WindowsProcessHelpers.isEndOfOutputError(WindowsProcessHelpers.errorBrokenPipe))
        #expect(WindowsProcessHelpers.isEndOfOutputError(WindowsProcessHelpers.errorPipeNotConnected))
        #expect(WindowsProcessHelpers.isEndOfOutputError(WindowsProcessHelpers.errorNoData))
        #expect(WindowsProcessHelpers.isEndOfOutputError(WindowsProcessHelpers.errorOperationAborted))
        #expect(!WindowsProcessHelpers.isEndOfOutputError(WindowsProcessHelpers.errorAccessDenied))
        #expect(!WindowsProcessHelpers.isEndOfOutputError(WindowsProcessHelpers.errorIoPending))

        #expect(WindowsProcessHelpers.isAlreadyExitedTerminateError(WindowsProcessHelpers.errorAccessDenied))
        #expect(!WindowsProcessHelpers.isAlreadyExitedTerminateError(WindowsProcessHelpers.errorBrokenPipe))

        // Sub-millisecond remainder rounds UP to 1 ms so WaitForMultipleObjects never busy-spins with 0.
        #expect(WindowsProcessHelpers.remainingWaitTimeoutMs(deadlineNs: 1_000, nowNs: 1_000) == 0)
        #expect(WindowsProcessHelpers.remainingWaitTimeoutMs(deadlineNs: 900, nowNs: 1_000) == 0)
        #expect(WindowsProcessHelpers.remainingWaitTimeoutMs(deadlineNs: 1_001, nowNs: 1_000) == 1)
        #expect(WindowsProcessHelpers.remainingWaitTimeoutMs(deadlineNs: 2_000_000, nowNs: 1_000_000) == 1)
        #expect(WindowsProcessHelpers.remainingWaitTimeoutMs(deadlineNs: 2_000_001, nowNs: 1_000_000) == 2)

        #expect(WindowsProcessHelpers.windowsPipeName(randomHex32: "0123456789abcdef0123456789abcdef") == #"\\.\pipe\opencode-pty-0123456789abcdef0123456789abcdef"#)
        #expect(WindowsProcessHelpers.privateSecuritySDDL(ownerSID: "S-1-5-21-1000") == "O:S-1-5-21-1000D:P(A;;GA;;;S-1-5-21-1000)")

        #expect(WindowsProcessHelpers.pipeSignalName(.term) == "SIGTERM")
        #expect(WindowsProcessHelpers.pipeSignalName(.int) == "SIGINT")
        #expect(WindowsProcessHelpers.pipeSignalName(.kill) == "SIGKILL")

        #expect(WindowsProcessHelpers.consoleCtrlEventToSignalName(WindowsProcessHelpers.ctrlCEvent) == "SIGINT")
        #expect(WindowsProcessHelpers.consoleCtrlEventToSignalName(WindowsProcessHelpers.ctrlBreakEvent) == "SIGTERM")
        #expect(WindowsProcessHelpers.consoleCtrlEventToSignalName(WindowsProcessHelpers.ctrlCloseEvent) == "SIGTERM")
        #expect(WindowsProcessHelpers.consoleCtrlEventToSignalName(WindowsProcessHelpers.ctrlShutdownEvent) == "SIGTERM")
        #expect(WindowsProcessHelpers.consoleCtrlEventToSignalName(99) == nil)
    }

    // MARK: - Suspended Spawn -> Job Assign -> Resume Sequence & Failure Rollback

    @Test("runSuspendedSpawnSequence orders create -> close child handles -> assign job -> resume and rolls back on failure")
    func suspendedSpawnSequenceAndRollback() throws {
        // 1. Happy path verifies exact ordering: create -> closeChildHandles -> assignJob -> resume -> releaseThread
        var trace: [String] = []
        let ok = try WindowsProcessHelpers.runSuspendedSpawnSequence(
            job: "job-1",
            allowJoblessFallback: true,
            createSuspended: {
                trace.append("createSuspended")
                return (pid: 4242, process: "proc-1", thread: "thread-1")
            },
            closeParentCopiesOfChildHandles: { trace.append("closeChildHandles") },
            assignJob: { job, proc in trace.append("assign(\(job),\(proc))") },
            releaseJob: { trace.append("releaseJob(\($0))") },
            resumeThread: { trace.append("resume(\($0))") },
            terminateSuspended: { trace.append("terminateSuspended(\($0))") },
            releaseProcess: { trace.append("releaseProc(\($0))") },
            releaseThread: { trace.append("releaseThread(\($0))") }
        )
        #expect(ok.pid == 4242)
        #expect(ok.process == "proc-1")
        #expect(ok.job == "job-1")
        #expect(ok.jobFallbackWarning == nil)
        #expect(trace == [
            "createSuspended",
            "closeChildHandles",
            "assign(job-1,proc-1)",
            "resume(thread-1)",
            "releaseThread(thread-1)",
        ])

        // 2. Assign failure with allowJoblessFallback=true (upstream pipe/windows.rs fallback)
        trace.removeAll()
        let fallback = try WindowsProcessHelpers.runSuspendedSpawnSequence(
            job: "job-restricted",
            allowJoblessFallback: true,
            createSuspended: {
                trace.append("createSuspended")
                return (pid: 77, process: "proc-77", thread: "thread-77")
            },
            closeParentCopiesOfChildHandles: { trace.append("closeChildHandles") },
            assignJob: { _, _ in
                trace.append("assignFailed")
                throw MockSpawnError(reason: "access denied")
            },
            releaseJob: { trace.append("releaseJob(\($0))") },
            resumeThread: { trace.append("resume(\($0))") },
            terminateSuspended: { trace.append("terminateSuspended(\($0))") },
            releaseProcess: { trace.append("releaseProc(\($0))") },
            releaseThread: { trace.append("releaseThread(\($0))") }
        )
        #expect(fallback.pid == 77)
        #expect(fallback.job == nil)
        #expect(fallback.jobFallbackWarning != nil)
        #expect(trace == [
            "createSuspended",
            "closeChildHandles",
            "assignFailed",
            "releaseJob(job-restricted)",
            "resume(thread-77)",
            "releaseThread(thread-77)",
        ])

        // 3. Assign failure with allowJoblessFallback=false terminates suspended child and never resumes
        trace.removeAll()
        #expect(throws: MockSpawnError(reason: "nested job refused")) {
            _ = try WindowsProcessHelpers.runSuspendedSpawnSequence(
                job: "job-strict",
                allowJoblessFallback: false,
                createSuspended: {
                    trace.append("createSuspended")
                    return (pid: 88, process: "proc-88", thread: "thread-88")
                },
                closeParentCopiesOfChildHandles: { trace.append("closeChildHandles") },
                assignJob: { _, _ in
                    trace.append("assignFailed")
                    throw MockSpawnError(reason: "nested job refused")
                },
                releaseJob: { trace.append("releaseJob(\($0))") },
                resumeThread: { trace.append("resume(\($0))") },
                terminateSuspended: { trace.append("terminateSuspended(\($0))") },
                releaseProcess: { trace.append("releaseProc(\($0))") },
                releaseThread: { trace.append("releaseThread(\($0))") }
            )
        }
        #expect(trace == [
            "createSuspended",
            "closeChildHandles",
            "assignFailed",
            "releaseThread(thread-88)",
            "terminateSuspended(proc-88)",
            "releaseProc(proc-88)",
            "releaseJob(job-strict)",
        ])

        // 4. ResumeThread failure terminates the suspended child and cleans up job + handles
        trace.removeAll()
        #expect(throws: MockSpawnError(reason: "ResumeThread failed")) {
            _ = try WindowsProcessHelpers.runSuspendedSpawnSequence(
                job: "job-99",
                allowJoblessFallback: true,
                createSuspended: {
                    trace.append("createSuspended")
                    return (pid: 99, process: "proc-99", thread: "thread-99")
                },
                closeParentCopiesOfChildHandles: { trace.append("closeChildHandles") },
                assignJob: { job, proc in trace.append("assign(\(job),\(proc))") },
                releaseJob: { trace.append("releaseJob(\($0))") },
                resumeThread: { _ in
                    trace.append("resumeFailed")
                    throw MockSpawnError(reason: "ResumeThread failed")
                },
                terminateSuspended: { trace.append("terminateSuspended(\($0))") },
                releaseProcess: { trace.append("releaseProc(\($0))") },
                releaseThread: { trace.append("releaseThread(\($0))") }
            )
        }
        #expect(trace == [
            "createSuspended",
            "closeChildHandles",
            "assign(job-99,proc-99)",
            "resumeFailed",
            "releaseThread(thread-99)",
            "terminateSuspended(proc-99)",
            "releaseProc(proc-99)",
            "releaseJob(job-99)",
        ])
    }

    // MARK: - Pipe Process State Machine & ConPTY Wait-and-Close Worker

    @Test("PipeProcessStateMachine enforces first-signal-wins, natural-exit race immunity, and job finish policy")
    func pipeProcessStateMachine() {
        // Exit 0 -> disarm job, preserve exit code
        var normal = WindowsProcessHelpers.PipeProcessStateMachine(hasHandles: true, hasJob: true)
        let normalDone = normal.completeWait(exitCode: 0)
        #expect(normalDone == .init(outcome: .code(0), shouldTerminateJob: false, hadJob: true))
        #expect(!normal.hasHandles)
        let killAfterNormal = normal.recordKill(signalName: "SIGKILL", processAlreadySignalled: false)
        #expect(!killAfterNormal)

        // Non-zero exit without signal -> terminate job tree
        var failed = WindowsProcessHelpers.PipeProcessStateMachine(hasHandles: true, hasJob: true)
        let failedDone = failed.completeWait(exitCode: 3)
        #expect(failedDone == .init(outcome: .code(3), shouldTerminateJob: true, hadJob: true))

        // Signal racing an already-exited process is ignored; exit code & job policy are preserved
        var raced = WindowsProcessHelpers.PipeProcessStateMachine(hasHandles: true, hasJob: true)
        let racedKill = raced.recordKill(signalName: "SIGTERM", processAlreadySignalled: true)
        #expect(racedKill == false)
        #expect(raced.killedSignal == nil)
        let racedDone = raced.completeWait(exitCode: 0)
        #expect(racedDone == .init(outcome: .code(0), shouldTerminateJob: false, hadJob: true))

        // First signal wins when multiple signals arrive before exit
        var killed = WindowsProcessHelpers.PipeProcessStateMachine(hasHandles: true, hasJob: true)
        let firstKill = killed.recordKill(signalName: "SIGTERM", processAlreadySignalled: false)
        let secondKill = killed.recordKill(signalName: "SIGKILL", processAlreadySignalled: false)
        #expect(firstKill == true)
        #expect(secondKill == true)
        #expect(killed.killedSignal == "SIGTERM")
        let killedDone = killed.completeWait(exitCode: 1)
        #expect(killedDone == .init(outcome: .signal("SIGTERM"), shouldTerminateJob: false, hadJob: true))

        // Reaped process ignores subsequent signals
        var reaped = WindowsProcessHelpers.PipeProcessStateMachine(hasHandles: true, hasJob: true)
        reaped.reap()
        let reapedKill = reaped.recordKill(signalName: "SIGKILL", processAlreadySignalled: false)
        #expect(reapedKill == false)
    }

    @Test("WindowsPty.wait_and_close handles natural exit and early teardown faithfully")
    func windowsPtyWaitAndCloseWorker() {
        // 1. Natural exit before close: reports exit, waits for close, closes master without killing
        let log1 = Mutex<[String]>([])
        let polls = Mutex<Int>(0)
        ProcessDaemon.WindowsPty.wait_and_close(
            pollExited: {
                let n = polls.withLock { c -> Int in
                    c += 1
                    return c
                }
                return n >= 2
            },
            waitUntilExit: {
                log1.withLock { $0.append("waitExit") }
                return .success(23)
            },
            killChild: { log1.withLock { $0.append("kill") } },
            waitForClose: { blocking in
                log1.withLock { $0.append("waitClose(\(blocking))") }
                return blocking ? .closeRequested : .timeout
            },
            onExit: { result in
                if case .success(let code) = result {
                    log1.withLock { $0.append("onExit(\(code ?? 999))") }
                }
            },
            onCloseMaster: { log1.withLock { $0.append("closeMaster") } }
        )
        #expect(log1.withLock { $0 } == [
            "waitClose(false)",
            "waitExit",
            "onExit(23)",
            "waitClose(true)",
            "closeMaster",
        ])

        // 2. Early teardown before child exits: kills child, closes master, then waits & reports exit
        let log2 = Mutex<[String]>([])
        ProcessDaemon.WindowsPty.wait_and_close(
            pollExited: { false },
            waitUntilExit: {
                log2.withLock { $0.append("waitExit") }
                return .success(1)
            },
            killChild: { log2.withLock { $0.append("kill") } },
            waitForClose: { _ in .closeRequested },
            onExit: { result in
                if case .success(let code) = result {
                    log2.withLock { $0.append("onExit(\(code ?? 999))") }
                }
            },
            onCloseMaster: { log2.withLock { $0.append("closeMaster") } }
        )
        #expect(log2.withLock { $0 } == [
            "kill",
            "closeMaster",
            "waitExit",
            "onExit(1)",
        ])
    }
}
