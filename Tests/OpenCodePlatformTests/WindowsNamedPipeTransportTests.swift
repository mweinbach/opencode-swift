import Synchronization
import Testing
import OpenCodePlatform

private struct MockPipeError: Error, Equatable, Sendable {
    let message: String
}

/// Deterministic chunked byte stream exercising `readExactLoop` / `writeAllLoop` with arbitrary
/// maximum read/write chunk sizes (e.g. 1 byte, 3 bytes, or 64 KiB) to verify byte-stream framing.
private final class ChunkedByteStream: ProcessDaemon.ByteReader, ProcessDaemon.ByteWriter, @unchecked Sendable {
    private let state = Mutex<(bytes: [UInt8], offset: Int, writeChunks: [Int], readChunks: [Int])>(
        ([], 0, [], [])
    )
    private let maxReadChunk: Int
    private let maxWriteChunk: Int

    init(maxReadChunk: Int = 7, maxWriteChunk: Int = 13) {
        self.maxReadChunk = maxReadChunk
        self.maxWriteChunk = maxWriteChunk
    }

    var recordedWriteChunks: [Int] { state.withLock { $0.writeChunks } }
    var recordedReadChunks: [Int] { state.withLock { $0.readChunks } }

    func writeAll(_ bytes: [UInt8]) throws {
        try WindowsNamedPipeHelpers.writeAllLoop(bytes: bytes) { offset, step in
            let actual = min(step, maxWriteChunk)
            state.withLock { s in
                s.bytes.append(contentsOf: bytes[offset..<(offset + actual)])
                s.writeChunks.append(actual)
            }
            return actual
        }
    }

    func flush() throws {}

    func readExact(_ count: Int) throws -> [UInt8] {
        try WindowsNamedPipeHelpers.readExactLoop(count: count) { step in
            let want = min(step, maxReadChunk)
            return state.withLock { s in
                let avail = s.bytes.count - s.offset
                if avail <= 0 { return [] }
                let take = min(want, avail)
                let slice = Array(s.bytes[s.offset..<(s.offset + take)])
                s.offset += take
                s.readChunks.append(take)
                return slice
            }
        }
    }
}

private final class StubRuntimeHandle: ProcessDaemon.Daemon.RuntimeHandle, @unchecked Sendable {
    let registration: ProcessDaemon.Registration
    let finished = Mutex<Bool>(false)

    init(registration: ProcessDaemon.Registration) {
        self.registration = registration
    }

    func finish() throws {
        finished.withLock { $0 = true }
    }
}

@Suite("Windows Named-Pipe Transport, Security & Daemon Runtime Helpers")
struct WindowsNamedPipeTransportTests {
    private static func utf16Text(_ units: [UInt16]) -> String {
        String(decoding: units, as: UTF16.self)
    }

    // MARK: - Endpoint Naming, Validation & UTF-16 Encoding

    @Test("validateAndEncodeEndpoint accepts local opencode-pty pipes and rejects remote, nested, empty, and NUL paths")
    func endpointValidationAndWideEncoding() throws {
        let endpoint = WindowsNamedPipeHelpers.makeEndpoint(instanceId: "0123456789abcdef0123456789abcdef")
        #expect(endpoint == #"\\.\pipe\opencode-pty-0123456789abcdef0123456789abcdef"#)
        #expect(WindowsNamedPipeHelpers.hasLocalPipePrefix(endpoint))

        let encoded = try WindowsNamedPipeHelpers.validateAndEncodeEndpoint(endpoint)
        #expect(encoded.last == 0)
        #expect(Self.utf16Text(Array(encoded.dropLast())) == endpoint)

        // Unicode suffix encodes faithfully in UTF-16
        let unicodePipe = #"\\.\pipe\opencode-pty-日本語-🚀"#
        let unicodeEncoded = try WindowsNamedPipeHelpers.validateAndEncodeEndpoint(unicodePipe)
        #expect(unicodeEncoded.last == 0)
        #expect(Self.utf16Text(Array(unicodeEncoded.dropLast())) == unicodePipe)

        // Upstream rejection matrix
        let invalidEndpoints = [
            #"\\remote\pipe\opencode-pty-test"#,
            #"C:\tmp\pipe"#,
            #"\\.\pipe\opencode-pty-test\nested"#,
            #"\\.\pipe\opencode-pty-test/nested"#,
            #"\\.\pipe\opencode-pty-"#,
            #"\\.\pipe\other-daemon-123"#,
            #"\\.\pipe\opencode-pty-bad\#("\u{0}")name"#,
            "/tmp/opencode-pty.sock",
            "memory://opencode-pty-123",
            "",
        ]
        for bad in invalidEndpoints {
            #expect(throws: ProcessDaemon.DaemonError("expected a local opencode-pty named-pipe endpoint")) {
                _ = try WindowsNamedPipeHelpers.validateAndEncodeEndpoint(bad)
            }
        }

        // wide() helper
        #expect(try WindowsNamedPipeHelpers.encodeWide("abc") == [97, 98, 99, 0])
        #expect(try WindowsNamedPipeHelpers.encodeWide("") == [0])
        #expect(throws: ProcessDaemon.DaemonError("path contains a NUL")) {
            _ = try WindowsNamedPipeHelpers.encodeWide("a\u{0}b")
        }
    }

    // MARK: - Win32 Flags, Constants, Error Classifiers & Timeout / Chunk Policies

    @Test("Win32 named-pipe open/pipe/client/rename/lock flags match upstream bitmasks")
    func win32FlagBuildersAndConstants() {
        // Server CreateNamedPipeW flags
        let firstFlags = WindowsNamedPipeHelpers.serverOpenMode(firstInstance: true)
        #expect(
            firstFlags
                == (WindowsNamedPipeHelpers.pipeAccessDuplex
                    | WindowsNamedPipeHelpers.fileFlagOverlapped
                    | WindowsNamedPipeHelpers.fileFlagFirstPipeInstance)
        )
        #expect(firstFlags == 0x4008_0003)

        let nextFlags = WindowsNamedPipeHelpers.serverOpenMode(firstInstance: false)
        #expect(nextFlags == (WindowsNamedPipeHelpers.pipeAccessDuplex | WindowsNamedPipeHelpers.fileFlagOverlapped))
        #expect(nextFlags == 0x4000_0003)
        #expect((nextFlags & WindowsNamedPipeHelpers.fileFlagFirstPipeInstance) == 0)

        let pipeMode = WindowsNamedPipeHelpers.serverPipeMode()
        #expect(pipeMode == WindowsNamedPipeHelpers.pipeRejectRemoteClients)
        #expect(pipeMode == 0x0000_0008)

        #expect(WindowsNamedPipeHelpers.pipeUnlimitedInstances == 255)
        #expect(WindowsNamedPipeHelpers.bufferBytes == 65_536)
        #expect(WindowsNamedPipeHelpers.connectTimeoutMs == 5_000)
        #expect(WindowsNamedPipeHelpers.completionTimeoutMs == 2_000)
        #expect(WindowsNamedPipeHelpers.pollIntervalMs == 25)
        #expect(WindowsNamedPipeHelpers.waitNamedPipeStepMs == 10)
        #expect(WindowsNamedPipeHelpers.maxRegistrationBytes == 16 * 1024)

        // Client CreateFileW SQOS + overlapped flags
        let clientFlags = WindowsNamedPipeHelpers.clientFlagsAndAttributes()
        #expect(
            clientFlags
                == (WindowsNamedPipeHelpers.fileFlagOverlapped
                    | WindowsNamedPipeHelpers.securitySqosPresent
                    | WindowsNamedPipeHelpers.securityIdentification)
        )
        #expect(clientFlags == 0x4011_0000)

        // Atomic POSIX rename & exclusive lock flags
        #expect(WindowsNamedPipeHelpers.atomicRenameFlags() == 0x0000_0003)
        #expect(WindowsNamedPipeHelpers.lockFileExclusiveFlags() == 0x0000_0003)
        #expect(WindowsNamedPipeHelpers.fileInfoClassRenameInfoEx == 22)
    }

    @Test("Error classifiers, overlapped timeout clamping, poll interval, and 64 KiB chunk sizing match upstream")
    func errorClassifiersAndPolicies() {
        // ConnectNamedPipe already-connected errors
        #expect(WindowsNamedPipeHelpers.isConnectAlreadyConnectedError(WindowsNamedPipeHelpers.errorPipeConnected))
        #expect(WindowsNamedPipeHelpers.isConnectAlreadyConnectedError(WindowsNamedPipeHelpers.errorNoData))
        #expect(!WindowsNamedPipeHelpers.isConnectAlreadyConnectedError(WindowsNamedPipeHelpers.errorIoPending))
        #expect(!WindowsNamedPipeHelpers.isConnectAlreadyConnectedError(WindowsNamedPipeHelpers.errorAccessDenied))

        // Pipe EOF errors on ReadFile
        #expect(WindowsNamedPipeHelpers.isPipeEofError(WindowsNamedPipeHelpers.errorBrokenPipe))
        #expect(WindowsNamedPipeHelpers.isPipeEofError(WindowsNamedPipeHelpers.errorPipeNotConnected))
        #expect(WindowsNamedPipeHelpers.isPipeEofError(WindowsNamedPipeHelpers.errorNoData))
        #expect(!WindowsNamedPipeHelpers.isPipeEofError(WindowsNamedPipeHelpers.errorOperationAborted))
        #expect(!WindowsNamedPipeHelpers.isPipeEofError(WindowsNamedPipeHelpers.errorAccessDenied))

        // Async & busy status codes
        #expect(WindowsNamedPipeHelpers.isIoPendingError(WindowsNamedPipeHelpers.errorIoPending))
        #expect(!WindowsNamedPipeHelpers.isIoPendingError(WindowsNamedPipeHelpers.errorIoIncomplete))
        #expect(WindowsNamedPipeHelpers.isIoIncompleteError(WindowsNamedPipeHelpers.errorIoIncomplete))
        #expect(!WindowsNamedPipeHelpers.isIoIncompleteError(WindowsNamedPipeHelpers.errorIoPending))
        #expect(WindowsNamedPipeHelpers.isPipeBusyError(WindowsNamedPipeHelpers.errorPipeBusy))
        #expect(!WindowsNamedPipeHelpers.isPipeBusyError(WindowsNamedPipeHelpers.errorBrokenPipe))

        // Overlapped wait timeout clamps finite values to INFINITE - 1; nil -> INFINITE
        #expect(WindowsNamedPipeHelpers.overlappedWaitTimeoutMs(nil) == 0xFFFF_FFFF)
        #expect(WindowsNamedPipeHelpers.overlappedWaitTimeoutMs(0) == 0)
        #expect(WindowsNamedPipeHelpers.overlappedWaitTimeoutMs(2_000) == 2_000)
        #expect(WindowsNamedPipeHelpers.overlappedWaitTimeoutMs(UInt64(UInt32.max)) == UInt32.max - 1)
        #expect(WindowsNamedPipeHelpers.overlappedWaitTimeoutMs(UInt64.max) == UInt32.max - 1)

        // Listener poll slice capped at 25 ms
        #expect(WindowsNamedPipeHelpers.listenerPollSleepMs(0) == 0)
        #expect(WindowsNamedPipeHelpers.listenerPollSleepMs(10) == 10)
        #expect(WindowsNamedPipeHelpers.listenerPollSleepMs(25) == 25)
        #expect(WindowsNamedPipeHelpers.listenerPollSleepMs(2_000) == 25)

        // Per-call overlapped chunk size bounded to 64 KiB
        #expect(WindowsNamedPipeHelpers.chunkSize(remaining: -5) == 0)
        #expect(WindowsNamedPipeHelpers.chunkSize(remaining: 0) == 0)
        #expect(WindowsNamedPipeHelpers.chunkSize(remaining: 100) == 100)
        #expect(WindowsNamedPipeHelpers.chunkSize(remaining: 65_536) == 65_536)
        #expect(WindowsNamedPipeHelpers.chunkSize(remaining: 200_000) == 65_536)
    }

    // MARK: - Client Busy Retry & Server PID Verification

    @Test("connectWithBusyRetry handles immediate connect, busy retries, deadline timeout, and non-busy errors")
    func clientConnectBusyRetryPolicy() throws {
        // 1. Immediate success never calls waitPipe
        var waitCalls = 0
        let immediate: String = try WindowsNamedPipeHelpers.connectWithBusyRetry(
            timeoutMs: 5_000,
            waitStepMs: 10,
            nowMs: { 1_000 },
            attemptOpen: { .connected("handle-1") },
            waitPipe: { _ in waitCalls += 1 }
        )
        #expect(immediate == "handle-1")
        #expect(waitCalls == 0)

        // 2. Transient ERROR_PIPE_BUSY retries via WaitNamedPipeW(10ms) and succeeds before deadline
        var clock: UInt64 = 10_000
        var attempts = 0
        var waitSteps: [UInt32] = []
        let retried: String = try WindowsNamedPipeHelpers.connectWithBusyRetry(
            timeoutMs: 5_000,
            waitStepMs: 10,
            nowMs: { clock },
            attemptOpen: {
                attempts += 1
                return attempts < 4 ? .busy : .connected("handle-4")
            },
            waitPipe: { step in
                waitSteps.append(step)
                clock += UInt64(step)
            }
        )
        #expect(retried == "handle-4")
        #expect(attempts == 4)
        #expect(waitSteps == [10, 10, 10])

        // 3. Persistent ERROR_PIPE_BUSY fails with "named pipe is busy" once deadline is reached
        var timeoutClock: UInt64 = 500
        var timeoutWaits = 0
        #expect(throws: ProcessDaemon.DaemonError("named pipe is busy")) {
            let _: String = try WindowsNamedPipeHelpers.connectWithBusyRetry(
                timeoutMs: 30,
                waitStepMs: 10,
                nowMs: { timeoutClock },
                attemptOpen: { .busy },
                waitPipe: { step in
                    timeoutWaits += 1
                    timeoutClock += UInt64(step)
                }
            )
        }
        #expect(timeoutWaits == 3)

        // 4. Non-busy failure propagates immediately without calling WaitNamedPipeW
        var failedWaits = 0
        #expect(throws: MockPipeError(message: "access denied")) {
            let _: String = try WindowsNamedPipeHelpers.connectWithBusyRetry(
                timeoutMs: 5_000,
                waitStepMs: 10,
                nowMs: { 0 },
                attemptOpen: { .failed(MockPipeError(message: "access denied")) },
                waitPipe: { _ in failedWaits += 1 }
            )
        }
        #expect(failedWaits == 0)
    }

    @Test("verifyServerPid accepts matching daemon PID and rejects mismatched server PID")
    func serverPidVerification() throws {
        try WindowsNamedPipeHelpers.verifyServerPid(actual: 4242, expected: 4242)
        #expect(throws: ProcessDaemon.DaemonError("named pipe server is not the registered opencode-pty daemon")) {
            try WindowsNamedPipeHelpers.verifyServerPid(actual: 4246, expected: 4242)
        }
    }

    // MARK: - Chunked Byte-Stream I/O & Protocol v9 Framing Parity

    @Test("readExactLoop and writeAllLoop enforce 64 KiB chunk bounds, reassemble split reads, and preserve v9 framing")
    func chunkedByteStreamAndProtocolFraming() throws {
        // Large payload (> 2 * 64 KiB) is bounded to 64 KiB per writeAllLoop / readExactLoop call
        let largeSize = 2 * Int(WindowsNamedPipeHelpers.bufferBytes) + 123
        let largePayload = (0..<largeSize).map { UInt8($0 & 0xFF) }
        var writeSteps: [Int] = []
        var storage: [UInt8] = []
        storage.reserveCapacity(largeSize)
        try WindowsNamedPipeHelpers.writeAllLoop(bytes: largePayload) { offset, step in
            writeSteps.append(step)
            storage.append(contentsOf: largePayload[offset..<(offset + step)])
            return step
        }
        #expect(writeSteps == [65_536, 65_536, 123])
        #expect(storage == largePayload)

        var readSteps: [Int] = []
        var readOffset = 0
        let readBack = try WindowsNamedPipeHelpers.readExactLoop(count: largeSize) { step in
            readSteps.append(step)
            let slice = Array(storage[readOffset..<(readOffset + step)])
            readOffset += step
            return slice
        }
        #expect(readSteps == [65_536, 65_536, 123])
        #expect(readBack == largePayload)

        // Premature EOF raises error without infinite retry
        var eofCalls = 0
        #expect(throws: ProcessDaemon.DaemonError("unexpected EOF while reading 10 byte(s)")) {
            _ = try WindowsNamedPipeHelpers.readExactLoop(count: 10) { _ in
                eofCalls += 1
                return eofCalls == 1 ? [1, 2, 3] : []
            }
        }
        #expect(eofCalls == 2)

        // Zero-byte write fails cleanly
        #expect(throws: ProcessDaemon.DaemonError("named pipe write returned 0 bytes")) {
            try WindowsNamedPipeHelpers.writeAllLoop(bytes: [1, 2, 3]) { _, _ in 0 }
        }

        // Full protocol v9 Envelope, Response, and binary Output frame round-trip across tiny split chunks
        let chunked = ChunkedByteStream(maxReadChunk: 3, maxWriteChunk: 5)
        try ProcessDaemon.write_frame(
            chunked,
            value: ProcessDaemon.Envelope(token: "win-tok", request: .ping)
        )
        try ProcessDaemon.write_output_frame(chunked, start: 10, end: 18, bytes: Array("pipe-out".utf8))
        try ProcessDaemon.write_frame(
            chunked,
            value: ProcessDaemon.Response.exited(
                exitCode: 0,
                signal: nil,
                finalOffset: 18,
                outputLines: 1,
                outputError: nil,
                exitedAt: 999
            )
        )

        #expect(chunked.recordedWriteChunks.allSatisfy { $0 <= 5 })
        let (tok, reqResult) = try ProcessDaemon.read_envelope(chunked)
        #expect(tok == "win-tok")
        #expect(try reqResult.get() == .ping)

        let ev1 = try ProcessDaemon.read_subscription_event(chunked)
        #expect(ev1 == .output(start: 10, end: 18, bytes: Array("pipe-out".utf8)))

        let ev2 = try ProcessDaemon.read_subscription_event(chunked)
        #expect(
            ev2 == .response(.exited(
                exitCode: 0,
                signal: nil,
                finalOffset: 18,
                outputLines: 1,
                outputError: nil,
                exitedAt: 999
            ))
        )
        #expect(chunked.recordedReadChunks.allSatisfy { $0 <= 3 })
    }

    // MARK: - DACL / ACL Validation, File Kind, Paths & FILE_RENAME_INFO Encoding

    @Test("DACL inspection and ACL/ACE binary parsers match upstream security.rs invariants")
    func privateDaclAndAclParsers() throws {
        // Valid ACL header: AclRevision=2, Sbz1=0, AclSize=48, AceCount=1 (LE: 0x01, 0x00), Sbz2=0
        let aclHeader: [UInt8] = [0x02, 0x00, 0x30, 0x00, 0x01, 0x00, 0x00, 0x00]
        #expect(WindowsNamedPipeHelpers.parseAclAceCount(aclHeader) == 1)
        #expect(WindowsNamedPipeHelpers.parseAclAceCount([0x02, 0x00]) == nil)

        // Valid ACE_HEADER: AceType=0 (ACCESS_ALLOWED_ACE_TYPE), AceFlags=0, AceSize=36
        #expect(WindowsNamedPipeHelpers.parseAceHeaderType([0x00, 0x00, 0x24, 0x00]) == 0)
        #expect(WindowsNamedPipeHelpers.parseAceHeaderType([0x01, 0x00, 0x24, 0x00]) == 1)
        #expect(WindowsNamedPipeHelpers.parseAceHeaderType([]) == nil)

        // Valid protected single-ACE current-user DACL passes
        try WindowsNamedPipeHelpers.validatePrivateDacl(
            present: true,
            hasDaclPointer: true,
            control: WindowsNamedPipeHelpers.seDaclProtected,
            aceCount: 1,
            firstAceType: WindowsNamedPipeHelpers.accessAllowedAceType,
            firstAceIsCurrentUser: true
        )

        // Missing / null / unprotected DACL rejected
        #expect(throws: ProcessDaemon.DaemonError("unprotected PTY storage DACL")) {
            try WindowsNamedPipeHelpers.validatePrivateDacl(
                present: true,
                hasDaclPointer: true,
                control: 0,
                aceCount: 1,
                firstAceType: 0,
                firstAceIsCurrentUser: true
            )
        }
        #expect(throws: ProcessDaemon.DaemonError("unprotected PTY storage DACL")) {
            try WindowsNamedPipeHelpers.validatePrivateDacl(
                present: false,
                hasDaclPointer: true,
                control: WindowsNamedPipeHelpers.seDaclProtected,
                aceCount: 1,
                firstAceType: 0,
                firstAceIsCurrentUser: true
            )
        }
        #expect(throws: ProcessDaemon.DaemonError("unprotected PTY storage DACL")) {
            try WindowsNamedPipeHelpers.validatePrivateDacl(
                present: true,
                hasDaclPointer: false,
                control: WindowsNamedPipeHelpers.seDaclProtected,
                aceCount: 1,
                firstAceType: 0,
                firstAceIsCurrentUser: true
            )
        }

        // Multiple or zero ACEs rejected
        #expect(throws: ProcessDaemon.DaemonError("PTY storage must grant only the current user")) {
            try WindowsNamedPipeHelpers.validatePrivateDacl(
                present: true,
                hasDaclPointer: true,
                control: WindowsNamedPipeHelpers.seDaclProtected,
                aceCount: 2,
                firstAceType: 0,
                firstAceIsCurrentUser: true
            )
        }
        #expect(throws: ProcessDaemon.DaemonError("PTY storage must grant only the current user")) {
            try WindowsNamedPipeHelpers.validatePrivateDacl(
                present: true,
                hasDaclPointer: true,
                control: WindowsNamedPipeHelpers.seDaclProtected,
                aceCount: 0,
                firstAceType: nil,
                firstAceIsCurrentUser: false
            )
        }

        // Non-ACCESS_ALLOWED ACE rejected
        #expect(throws: ProcessDaemon.DaemonError("unexpected PTY storage ACE")) {
            try WindowsNamedPipeHelpers.validatePrivateDacl(
                present: true,
                hasDaclPointer: true,
                control: WindowsNamedPipeHelpers.seDaclProtected,
                aceCount: 1,
                firstAceType: 1,
                firstAceIsCurrentUser: true
            )
        }

        // Foreign SID (e.g. Everyone / WD) rejected
        #expect(throws: ProcessDaemon.DaemonError("PTY storage grants another principal")) {
            try WindowsNamedPipeHelpers.validatePrivateDacl(
                present: true,
                hasDaclPointer: true,
                control: WindowsNamedPipeHelpers.seDaclProtected,
                aceCount: 1,
                firstAceType: 0,
                firstAceIsCurrentUser: false
            )
        }
    }

    @Test("Storage kind validation, registration limits, Windows path joining, and FILE_RENAME_INFO layout match upstream")
    func storageKindPathsAndFileRenameInfo() throws {
        // Storage file kind checks
        try WindowsNamedPipeHelpers.validateStorageFileKind(
            attributes: WindowsNamedPipeHelpers.fileAttributeDirectory,
            expectDirectory: true
        )
        try WindowsNamedPipeHelpers.validateStorageFileKind(attributes: 0x20, expectDirectory: false)
        #expect(throws: ProcessDaemon.DaemonError("PTY storage must not be a reparse point")) {
            try WindowsNamedPipeHelpers.validateStorageFileKind(
                attributes: WindowsNamedPipeHelpers.fileAttributeDirectory
                    | WindowsNamedPipeHelpers.fileAttributeReparsePoint,
                expectDirectory: true
            )
        }
        #expect(throws: ProcessDaemon.DaemonError("unexpected PTY storage file type")) {
            try WindowsNamedPipeHelpers.validateStorageFileKind(
                attributes: WindowsNamedPipeHelpers.fileAttributeDirectory,
                expectDirectory: false
            )
        }
        #expect(throws: ProcessDaemon.DaemonError("unexpected PTY storage file type")) {
            try WindowsNamedPipeHelpers.validateStorageFileKind(attributes: 0x20, expectDirectory: true)
        }

        // Registration limits and cleanup ownership check
        try WindowsNamedPipeHelpers.validateRegistrationSize(16 * 1024)
        #expect(throws: ProcessDaemon.DaemonError("PTY registration is too large")) {
            try WindowsNamedPipeHelpers.validateRegistrationSize(16 * 1024 + 1)
        }
        #expect(WindowsNamedPipeHelpers.registrationTempFileName(instanceId: "abc123") == "service.abc123.tmp")
        #expect(WindowsNamedPipeHelpers.shouldRemoveRegistrationOnCleanup(currentInstanceId: "a", expectedInstanceId: "a"))
        #expect(!WindowsNamedPipeHelpers.shouldRemoveRegistrationOnCleanup(currentInstanceId: "b", expectedInstanceId: "a"))
        #expect(!WindowsNamedPipeHelpers.shouldRemoveRegistrationOnCleanup(currentInstanceId: nil, expectedInstanceId: "a"))

        // Windows path join preserves \\?\ extended-length prefixes with backslashes
        #expect(
            WindowsNamedPipeHelpers.joinWindowsPath(#"\\?\C:\Users\dev\pty"#, "service.json")
                == #"\\?\C:\Users\dev\pty\service.json"#
        )
        #expect(
            WindowsNamedPipeHelpers.joinWindowsPath(#"C:\state\"#, "service.lock")
                == #"C:\state\service.lock"#
        )
        #expect(WindowsNamedPipeHelpers.joinWindowsPath(#"C:\"#, "service.json") == #"C:\service.json"#)

        #expect(WindowsNamedPipeHelpers.parentDirectory(of: #"C:\Users\dev\pty"#) == #"C:\Users\dev"#)
        #expect(WindowsNamedPipeHelpers.parentDirectory(of: #"C:\pty"#) == #"C:\"#)
        #expect(WindowsNamedPipeHelpers.parentDirectory(of: #"C:\"#) == nil)
        #expect(WindowsNamedPipeHelpers.parentDirectory(of: #"\\?\C:\state\run1"#) == #"\\?\C:\state"#)

        // FILE_RENAME_INFO 64-bit layout (sizeof=24, RootDirectory@8, FileNameLength@16, FileName@20)
        let dest = #"\\?\C:\pty\service.json"#
        let encoded = try WindowsNamedPipeHelpers.encodeFileRenameInfoBuffer(
            destinationPath: dest,
            flags: WindowsNamedPipeHelpers.atomicRenameFlags(),
            structSize: 24,
            fileNameLengthOffset: 16,
            fileNameOffset: 20
        )
        let expectedNameBytes = UInt32(dest.utf16.count * 2)
        #expect(encoded.fileNameLengthBytes == expectedNameBytes)
        #expect(encoded.bytes.count == 24 + Int(expectedNameBytes))
        // Offset 0: Flags = 0x0000_0003 (REPLACE_IF_EXISTS | POSIX_SEMANTICS)
        #expect(Array(encoded.bytes[0..<4]) == [0x03, 0x00, 0x00, 0x00])
        // Offset 8..16: RootDirectory = NULL
        #expect(Array(encoded.bytes[8..<16]) == [UInt8](repeating: 0, count: 8))
        // Offset 16..20: FileNameLength LE
        let decodedLen = UInt32(encoded.bytes[16])
            | (UInt32(encoded.bytes[17]) << 8)
            | (UInt32(encoded.bytes[18]) << 16)
            | (UInt32(encoded.bytes[19]) << 24)
        #expect(decodedLen == expectedNameBytes)
        // Offset 20..: UTF-16LE destination followed by zero padding
        var decodedUnits: [UInt16] = []
        for i in stride(from: 20, to: 20 + Int(expectedNameBytes), by: 2) {
            decodedUnits.append(UInt16(encoded.bytes[i]) | (UInt16(encoded.bytes[i + 1]) << 8))
        }
        #expect(Self.utf16Text(decodedUnits) == dest)
        #expect(encoded.bytes[20 + Int(expectedNameBytes)] == 0)
        #expect(encoded.bytes[20 + Int(expectedNameBytes) + 1] == 0)

        // Rejects embedded NUL or empty path
        #expect(throws: ProcessDaemon.DaemonError.self) {
            _ = try WindowsNamedPipeHelpers.encodeFileRenameInfoBuffer(
                destinationPath: "bad\u{0}dest",
                structSize: 24,
                fileNameLengthOffset: 16,
                fileNameOffset: 20
            )
        }
        #expect(throws: ProcessDaemon.DaemonError.self) {
            _ = try WindowsNamedPipeHelpers.encodeFileRenameInfoBuffer(
                destinationPath: "",
                structSize: 24,
                fileNameLengthOffset: 16,
                fileNameOffset: 20
            )
        }
    }

    // MARK: - Shared Transport Contract & Namespace Ownership Tests

    @Test("Transport.Windows enforces exclusive namespace ownership, split byte streams, PID verification, and stop retention")
    func windowsTransportNamespaceAndByteStreamContract() throws {
        let endpoint = WindowsNamedPipeHelpers.makeEndpoint(instanceId: "contract-\(UInt64.random(in: 1...UInt64.max))")

        func acceptWithRetry(_ listener: ProcessDaemon.Transport.Windows.Listener) throws -> ProcessDaemon.Transport.Windows.Connection {
            for _ in 0..<200 {
                if let conn = try listener.accept() {
                    return conn
                }
                PlatformPhase2Helper.sleepMs(5)
            }
            throw ProcessDaemon.DaemonError("timed out waiting for Windows listener accept")
        }

        do {
            let listener = try ProcessDaemon.Transport.Windows.Listener.bind(endpoint)
            #expect(try listener.accept() == nil)
            // Must fail closed if another server tries to bind the same name
            #expect(throws: Error.self) {
                _ = try ProcessDaemon.Transport.Windows.Listener.bind(endpoint)
            }

            let first = try ProcessDaemon.Transport.Windows.Connection.connect(endpoint)
            let firstServer = try acceptWithRetry(listener)
            let second = try ProcessDaemon.Transport.Windows.Connection.connect(endpoint)
            let secondServer = try acceptWithRetry(listener)

            // Byte-stream semantics: split writes concatenate cleanly
            try first.writeAll(Array("ab".utf8))
            try first.writeAll(Array("cd".utf8))
            try second.writeAll(Array("xy".utf8))
            #expect(try firstServer.readExact(4) == Array("abcd".utf8))
            #expect(try secondServer.readExact(2) == Array("xy".utf8))

            // Protocol v9 frame round-trip
            try ProcessDaemon.write_frame(firstServer, value: ProcessDaemon.Response.owned)
            let frame: ProcessDaemon.Response = try ProcessDaemon.read_frame(first)
            #expect(frame == .owned)

            // Mismatched server PID must be rejected before sending credentials
            #expect(throws: ProcessDaemon.DaemonError("named pipe server is not the registered opencode-pty daemon")) {
                _ = try ProcessDaemon.Transport.Windows.Connection.connect_to(endpoint, serverPid: 999_999_991)
            }

            first.closeConnection()
            firstServer.closeConnection()
            second.closeConnection()
            secondServer.closeConnection()

            // stop() prevents new accepts while retaining namespace ownership until listener drops
            listener.stop()
            #expect(try listener.accept() == nil)
            #expect(throws: Error.self) {
                _ = try ProcessDaemon.Transport.Windows.Listener.bind(endpoint)
            }
        }

        // After listener deinit releases the namespace, rebinding succeeds cleanly
        let rebound = try ProcessDaemon.Transport.Windows.Listener.bind(endpoint)
        rebound.stop()
    }

    @Test("Daemon.Server and TerminalClient share identical code paths over Transport.Windows")
    func sharedServerAndClientOverWindowsTransport() throws {
        let instanceId = "win-shared-\(UInt64.random(in: 1...UInt64.max))"
        let pipeEndpoint = WindowsNamedPipeHelpers.makeEndpoint(instanceId: instanceId)
        let listener = try ProcessDaemon.Transport.Windows.Listener.bind(pipeEndpoint)
        let wake = try ProcessDaemon.Transport.Windows.Wake.new()

        // Obtain the current process PID (works identically on macOS, Linux, and Windows).
        let pidProbe = try ProcessDaemon.Daemon.Server.startBackground(useInMemoryEndpoint: true)
        let currentPid = pidProbe.registration.pid
        pidProbe.stopAndWait()

        let registration = ProcessDaemon.Registration(
            instanceId: instanceId,
            pid: currentPid,
            protocolVersion: ProcessDaemon.PROTOCOL_VERSION,
            socket: pipeEndpoint,
            token: "shared-secret-token",
            features: ProcessDaemon.features()
        )
        let runtime = StubRuntimeHandle(registration: registration)
        let service = ProcessDaemon.TerminalService.new(
            backend: .simulated(onWrite: { _, bytes, actor in
                actor.emitOutput(bytes)
            })
        )
        let server = ProcessDaemon.Daemon.Server.startBackgroundWithTransport(
            runtime: runtime,
            listener: listener,
            wake: wake,
            service: service
        )
        defer { server.stopAndWait() }

        let client = ProcessDaemon.TerminalClient(registration: registration)

        // Ping + auth + ownership + handoff + PTY create + subscribe + output + shutdown
        let owner = try client.claimOwnership(ticket: nil)
        let handoff = try owner.prepareHandoff()
        let owner2 = try client.claimOwnership(ticket: handoff.ticket)
        owner.releaseOwnership()

        let pong = try client.ping()
        if case let .pong(id, pid, proto, _) = pong {
            #expect(id == instanceId)
            #expect(pid == currentPid)
            #expect(proto == ProcessDaemon.PROTOCOL_VERSION)
        } else {
            Issue.record("Expected Pong response over Windows transport")
        }

        let created = try client.create_pty(.init(
            program: "sh",
            cwd: "/",
            groupId: "win-ipc",
            title: "win-pty",
            cols: 20,
            rows: 5
        ))
        let sub = try client.subscribe(
            id: created.id,
            offset: 0,
            attachmentId: "win-ctrl",
            role: .controller,
            takeover: false
        )
        _ = try sub.next_event() // controller_changed

        try client.write_for(id: created.id, attachmentId: "win-ctrl", data: Array("hello-pipe".utf8))
        let outEv = try sub.next_event()
        #expect(outEv == .output(start: 0, end: 10, bytes: Array("hello-pipe".utf8)))

        let badClient = ProcessDaemon.TerminalClient(registration: ProcessDaemon.Registration(
            instanceId: instanceId,
            pid: currentPid,
            socket: pipeEndpoint,
            token: "wrong-token"
        ))
        #expect(throws: ProcessDaemon.DaemonError("authentication failed")) {
            _ = try badClient.ping()
        }

        sub.close()
        try client.shutdown()
        #expect(server.waitUntilStopped(timeoutMs: 3_000))
        #expect(runtime.finished.withLock { $0 })
        owner2.releaseOwnership()
    }
}
