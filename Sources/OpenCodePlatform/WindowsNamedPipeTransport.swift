#if !os(WASI)
import Foundation
#endif
#if os(Windows)
import WinSDK
#endif
import Synchronization
import OpenCodeUtil

// MARK: - Cross-Platform Windows Named Pipe Helpers (Pure & Unit-Testable on All Hosts)

/// Pure Windows named-pipe transport, DACL validation, retry policy, chunked byte-stream I/O,
/// and atomic registration publication helpers mirroring:
/// - `upstream/opencode/packages/process-daemon/src/transport/windows.rs`
/// - `upstream/opencode/packages/process-daemon/src/transport/windows/security.rs`
/// - `upstream/opencode/packages/process-daemon/src/daemon/windows.rs`
///
/// Kept completely OS-independent so every algorithm and policy is unit-tested on non-Windows hosts.
public enum WindowsNamedPipeHelpers {
    // MARK: Upstream Transport & Registration Constants

    /// Required local pipe namespace prefix (`\\.\pipe\opencode-pty-`).
    public static let pipePrefix: String = #"\\.\pipe\opencode-pty-"#

    /// Named pipe in/out kernel buffer size and per-call overlapped I/O bound (64 KiB, matching `BUFFER_BYTES`).
    public static let bufferBytes: UInt32 = 64 * 1024

    /// Maximum time a client retries `ERROR_PIPE_BUSY` before failing (5 seconds, matching `CONNECT_TIMEOUT`).
    public static let connectTimeoutMs: UInt64 = 5_000

    /// Grace period waiting for a client to drain a final response frame and close (2 seconds, matching `COMPLETION_TIMEOUT`).
    public static let completionTimeoutMs: UInt64 = 2_000

    /// Interim listener poll slice on Windows (25 ms, matching `POLL_INTERVAL`).
    public static let pollIntervalMs: UInt64 = 25

    /// Bounded kernel wait slice passed to `WaitNamedPipeW` per busy retry (10 ms).
    public static let waitNamedPipeStepMs: UInt32 = 10

    /// Maximum bytes read from `service.json` on Windows (16 KiB).
    public static let maxRegistrationBytes: Int = 16 * 1024

    // MARK: Win32 Flag & Layout Constants (Verified Against Windows SDK Headers)

    /// `PIPE_ACCESS_DUPLEX` (0x00000003)
    public static let pipeAccessDuplex: UInt32 = 0x0000_0003
    /// `FILE_FLAG_OVERLAPPED` (0x40000000)
    public static let fileFlagOverlapped: UInt32 = 0x4000_0000
    /// `FILE_FLAG_FIRST_PIPE_INSTANCE` (0x00080000)
    public static let fileFlagFirstPipeInstance: UInt32 = 0x0008_0000
    /// `PIPE_TYPE_BYTE` (0x00000000)
    public static let pipeTypeByte: UInt32 = 0x0000_0000
    /// `PIPE_READMODE_BYTE` (0x00000000)
    public static let pipeReadmodeByte: UInt32 = 0x0000_0000
    /// `PIPE_WAIT` (0x00000000)
    public static let pipeWait: UInt32 = 0x0000_0000
    /// `PIPE_REJECT_REMOTE_CLIENTS` (0x00000008)
    public static let pipeRejectRemoteClients: UInt32 = 0x0000_0008
    /// `PIPE_UNLIMITED_INSTANCES` (255)
    public static let pipeUnlimitedInstances: UInt32 = 255
    /// `SECURITY_SQOS_PRESENT` (0x00100000)
    public static let securitySqosPresent: UInt32 = 0x0010_0000
    /// `SECURITY_IDENTIFICATION` (`SecurityIdentification << 16` = 0x00010000)
    public static let securityIdentification: UInt32 = 0x0001_0000
    /// `INFINITE` (0xFFFFFFFF)
    public static let infiniteTimeout: UInt32 = 0xFFFF_FFFF

    /// `FILE_RENAME_FLAG_REPLACE_IF_EXISTS` (0x00000001)
    public static let fileRenameFlagReplaceIfExists: UInt32 = 0x0000_0001
    /// `FILE_RENAME_FLAG_POSIX_SEMANTICS` (0x00000002)
    public static let fileRenameFlagPosixSemantics: UInt32 = 0x0000_0002
    /// `FILE_INFO_BY_HANDLE_CLASS::FileRenameInfoEx` (22)
    public static let fileInfoClassRenameInfoEx: Int32 = 22

    /// `LOCKFILE_FAIL_IMMEDIATELY` (0x00000001)
    public static let lockFileFailImmediately: UInt32 = 0x0000_0001
    /// `LOCKFILE_EXCLUSIVE_LOCK` (0x00000002)
    public static let lockFileExclusiveLock: UInt32 = 0x0000_0002

    /// `FILE_ATTRIBUTE_DIRECTORY` (0x00000010)
    public static let fileAttributeDirectory: UInt32 = 0x0000_0010
    /// `FILE_ATTRIBUTE_REPARSE_POINT` (0x00000400)
    public static let fileAttributeReparsePoint: UInt32 = 0x0000_0400

    /// `SE_FILE_OBJECT` (1)
    public static let seFileObject: UInt32 = 1
    /// `OWNER_SECURITY_INFORMATION` (0x00000001)
    public static let ownerSecurityInformation: UInt32 = 0x0000_0001
    /// `DACL_SECURITY_INFORMATION` (0x00000004)
    public static let daclSecurityInformation: UInt32 = 0x0000_0004
    /// `PROTECTED_DACL_SECURITY_INFORMATION` (0x80000000)
    public static let protectedDaclSecurityInformation: UInt32 = 0x8000_0000
    /// `SE_DACL_PROTECTED` (0x1000)
    public static let seDaclProtected: UInt16 = 0x1000
    /// `ACCESS_ALLOWED_ACE_TYPE` (0)
    public static let accessAllowedAceType: UInt8 = 0

    /// Byte offset of `AceCount: UInt16` within Win32 `struct _ACL`.
    public static let aclAceCountOffset: Int = 4
    /// Byte offset of `AceType: UInt8` within Win32 `struct _ACE_HEADER`.
    public static let aceHeaderTypeOffset: Int = 0
    /// Byte offset of `SidStart: DWORD` within Win32 `struct _ACCESS_ALLOWED_ACE`.
    public static let accessAllowedAceSidOffset: Int = 8

    // Win32 error codes handled by named-pipe and daemon storage paths.
    public static let errorAccessDenied: UInt32 = 5
    public static let errorBrokenPipe: UInt32 = 109
    public static let errorAlreadyExists: UInt32 = 183
    public static let errorPipeBusy: UInt32 = 231
    public static let errorNoData: UInt32 = 232
    public static let errorPipeNotConnected: UInt32 = 233
    public static let errorPipeConnected: UInt32 = 535
    public static let errorOperationAborted: UInt32 = 995
    public static let errorIoIncomplete: UInt32 = 996
    public static let errorIoPending: UInt32 = 997

    // MARK: Flag Builders

    /// Computes `CreateNamedPipeW` `dwOpenMode` matching `transport/windows.rs#PendingConnection::new`.
    /// First instance sets `FILE_FLAG_FIRST_PIPE_INSTANCE` so bind fails closed if another server owns the name.
    public static func serverOpenMode(firstInstance: Bool) -> UInt32 {
        pipeAccessDuplex | fileFlagOverlapped | (firstInstance ? fileFlagFirstPipeInstance : 0)
    }

    /// Computes `CreateNamedPipeW` `dwPipeMode` matching `transport/windows.rs#PendingConnection::new`.
    public static func serverPipeMode() -> UInt32 {
        pipeTypeByte | pipeReadmodeByte | pipeWait | pipeRejectRemoteClients
    }

    /// Computes client `CreateFileW` `dwFlagsAndAttributes` matching `transport/windows.rs#Connection::connect`.
    /// `SECURITY_IDENTIFICATION` prevents a rogue pipe server from impersonating the client.
    public static func clientFlagsAndAttributes() -> UInt32 {
        fileFlagOverlapped | securitySqosPresent | securityIdentification
    }

    /// Computes `FILE_RENAME_INFO.Flags` for atomic POSIX replacement (`daemon/windows.rs#publish`).
    public static func atomicRenameFlags() -> UInt32 {
        fileRenameFlagReplaceIfExists | fileRenameFlagPosixSemantics
    }

    /// Computes `LockFileEx` `dwFlags` for non-blocking exclusive service locking (`daemon/windows.rs#Runtime::bind`).
    public static func lockFileExclusiveFlags() -> UInt32 {
        lockFileExclusiveLock | lockFileFailImmediately
    }

    // MARK: Endpoint Naming & UTF-16 Validation (`transport/windows.rs#endpoint_name`, `#wide`)

    /// Formats the registered named-pipe endpoint for a daemon `instanceId`.
    public static func makeEndpoint(instanceId: String) -> String {
        "\(pipePrefix)\(instanceId)"
    }

    /// Returns `true` if `endpoint` starts with the local `opencode-pty` named-pipe prefix.
    public static func hasLocalPipePrefix(_ endpoint: String) -> Bool {
        endpoint.hasPrefix(pipePrefix)
    }

    /// Validates a local `opencode-pty` named-pipe endpoint and returns its NUL-terminated UTF-16 buffer.
    /// Rejects remote pipes (`\\remote\pipe\...`), filesystem paths, empty suffixes, embedded NULs,
    /// and nested path separators (`\` or `/`), matching `transport/windows.rs#endpoint_name`.
    public static func validateAndEncodeEndpoint(_ endpoint: String) throws -> [UInt16] {
        let value = Array(endpoint.utf16)
        let prefix = Array(pipePrefix.utf16)
        guard value.count > prefix.count, value.starts(with: prefix) else {
            throw ProcessDaemon.DaemonError("expected a local opencode-pty named-pipe endpoint")
        }
        for unit in value[prefix.count...] {
            if unit == 0 || unit == 0x005C || unit == 0x002F {
                throw ProcessDaemon.DaemonError("expected a local opencode-pty named-pipe endpoint")
            }
        }
        var wide = value
        wide.append(0)
        return wide
    }

    /// Encodes `value` as NUL-terminated UTF-16, refusing embedded NULs (`transport/windows.rs#wide`).
    public static func encodeWide(_ value: String) throws -> [UInt16] {
        var units = Array(value.utf16)
        if units.contains(0) {
            throw ProcessDaemon.DaemonError("path contains a NUL")
        }
        units.append(0)
        return units
    }

    // MARK: Error Classifiers & Timeout / Chunking Policies

    /// Returns `true` when `ConnectNamedPipe` failed because a client already connected (and possibly closed)
    /// between `CreateNamedPipeW` and `ConnectNamedPipe` (`ERROR_PIPE_CONNECTED` or `ERROR_NO_DATA`).
    public static func isConnectAlreadyConnectedError(_ win32Error: UInt32) -> Bool {
        win32Error == errorPipeConnected || win32Error == errorNoData
    }

    /// Returns `true` when a named-pipe `ReadFile` error represents clean peer EOF (`transport/windows.rs#read_with_timeout`).
    public static func isPipeEofError(_ win32Error: UInt32) -> Bool {
        win32Error == errorBrokenPipe || win32Error == errorPipeNotConnected || win32Error == errorNoData
    }

    /// Returns `true` for `ERROR_IO_PENDING`.
    public static func isIoPendingError(_ win32Error: UInt32) -> Bool {
        win32Error == errorIoPending
    }

    /// Returns `true` for `ERROR_IO_INCOMPLETE`.
    public static func isIoIncompleteError(_ win32Error: UInt32) -> Bool {
        win32Error == errorIoIncomplete
    }

    /// Returns `true` for `ERROR_PIPE_BUSY`.
    public static func isPipeBusyError(_ win32Error: UInt32) -> Bool {
        win32Error == errorPipeBusy
    }

    /// Clamps an optional millisecond timeout for `WaitForMultipleObjects`:
    /// `nil` maps to `INFINITE`, while any finite duration is clamped to `INFINITE - 1` so it never turns infinite.
    /// Matches `transport/windows.rs#Operation::wait`.
    public static func overlappedWaitTimeoutMs(_ timeoutMs: UInt64?) -> UInt32 {
        guard let timeoutMs else {
            return infiniteTimeout
        }
        return UInt32(min(timeoutMs, UInt64(infiniteTimeout - 1)))
    }

    /// Bounds each listener poll sleep to `POLL_INTERVAL` (25 ms), matching `transport/windows.rs#Listener::wait`.
    public static func listenerPollSleepMs(_ timeoutMs: UInt64) -> UInt64 {
        min(timeoutMs, pollIntervalMs)
    }

    /// Bounds each individual overlapped `ReadFile` / `WriteFile` submission to `BUFFER_BYTES` (64 KiB).
    public static func chunkSize(remaining: Int) -> Int {
        guard remaining > 0 else { return 0 }
        return min(remaining, Int(bufferBytes))
    }

    // MARK: Client Busy-Retry & Server PID Verification (`transport/windows.rs#connect`, `#connect_to`)

    public enum ConnectAttemptResult<Handle> {
        case connected(Handle)
        case busy
        case failed(any Error)
    }

    /// Executes the exact upstream `Connection::connect` `ERROR_PIPE_BUSY` retry loop:
    /// opens the pipe, retries via `waitPipe(waitStepMs)` on `ERROR_PIPE_BUSY` until `deadline`,
    /// throws `"named pipe is busy"` once the deadline expires, and propagates any other error immediately.
    public static func connectWithBusyRetry<Handle>(
        timeoutMs: UInt64 = connectTimeoutMs,
        waitStepMs: UInt32 = waitNamedPipeStepMs,
        nowMs: () -> UInt64,
        attemptOpen: () -> ConnectAttemptResult<Handle>,
        waitPipe: (_ stepMs: UInt32) -> Void
    ) throws -> Handle {
        let deadline = nowMs() &+ timeoutMs
        while true {
            switch attemptOpen() {
            case .connected(let handle):
                return handle
            case .busy:
                if nowMs() >= deadline {
                    throw ProcessDaemon.DaemonError("named pipe is busy")
                }
                waitPipe(waitStepMs)
            case .failed(let error):
                throw error
            }
        }
    }

    /// Verifies that the connected named-pipe server PID matches the registered daemon PID
    /// before any secret token or input is sent (`transport/windows.rs#Connection::connect_to`).
    public static func verifyServerPid(actual: UInt32, expected: UInt32) throws {
        if actual != expected {
            throw ProcessDaemon.DaemonError("named pipe server is not the registered opencode-pty daemon")
        }
    }

    // MARK: Byte-Stream Chunked Read/Write Loops

    /// Reads exactly `count` bytes from a chunked byte-stream source (each request bounded to `BUFFER_BYTES`),
    /// throwing on premature EOF (0 bytes) and never silently retrying errors.
    public static func readExactLoop(
        count: Int,
        readChunk: (_ maxBytes: Int) throws -> [UInt8]
    ) throws -> [UInt8] {
        if count <= 0 { return [] }
        var result: [UInt8] = []
        result.reserveCapacity(count)
        while result.count < count {
            let step = chunkSize(remaining: count - result.count)
            let chunk = try readChunk(step)
            if chunk.isEmpty {
                throw ProcessDaemon.DaemonError("unexpected EOF while reading \(count) byte(s)")
            }
            if chunk.count > step {
                result.append(contentsOf: chunk.prefix(step))
            } else {
                result.append(contentsOf: chunk)
            }
        }
        return result
    }

    /// Writes every byte in `bytes` in chunks bounded to `BUFFER_BYTES`, throwing if a write makes no progress.
    public static func writeAllLoop(
        bytes: [UInt8],
        writeChunk: (_ offset: Int, _ count: Int) throws -> Int
    ) throws {
        if bytes.isEmpty { return }
        var offset = 0
        while offset < bytes.count {
            let step = chunkSize(remaining: bytes.count - offset)
            let written = try writeChunk(offset, step)
            if written <= 0 {
                throw ProcessDaemon.DaemonError("named pipe write returned 0 bytes")
            }
            offset += written
        }
    }

    // MARK: Security Descriptor / DACL Inspection (`transport/windows/security.rs#check_private`)

    /// Reads the little-endian `AceCount` (`UInt16`) at byte offset 4 of a raw Win32 `ACL` header.
    public static func parseAclAceCount(_ aclHeaderBytes: [UInt8]) -> UInt16? {
        guard aclHeaderBytes.count >= aclAceCountOffset + 2 else { return nil }
        return UInt16(aclHeaderBytes[aclAceCountOffset])
            | (UInt16(aclHeaderBytes[aclAceCountOffset + 1]) << 8)
    }

    /// Reads `AceType` (`UInt8`) at byte offset 0 of a raw Win32 `ACE_HEADER`.
    public static func parseAceHeaderType(_ aceHeaderBytes: [UInt8]) -> UInt8? {
        guard aceHeaderBytes.count > aceHeaderTypeOffset else { return nil }
        return aceHeaderBytes[aceHeaderTypeOffset]
    }

    /// Validates an inspected DACL against upstream `PrivateSecurity::check_private` invariants:
    /// protected DACL (`SE_DACL_PROTECTED`), non-null present DACL, exactly 1 ACE,
    /// `ACCESS_ALLOWED_ACE_TYPE` (0), and SID equal to the current user.
    public static func validatePrivateDacl(
        present: Bool,
        hasDaclPointer: Bool,
        control: UInt16,
        aceCount: UInt32,
        firstAceType: UInt8?,
        firstAceIsCurrentUser: Bool
    ) throws {
        if !present || !hasDaclPointer || (control & seDaclProtected) == 0 {
            throw ProcessDaemon.DaemonError("unprotected PTY storage DACL")
        }
        guard aceCount == 1, let aceType = firstAceType else {
            throw ProcessDaemon.DaemonError("PTY storage must grant only the current user")
        }
        if aceType != accessAllowedAceType {
            throw ProcessDaemon.DaemonError("unexpected PTY storage ACE")
        }
        if !firstAceIsCurrentUser {
            throw ProcessDaemon.DaemonError("PTY storage grants another principal")
        }
    }

    // MARK: Storage File Kind, Registration, Path & `FILE_RENAME_INFO` Helpers (`daemon/windows.rs`)

    /// Refuses reparse points (symlinks/junctions) and verifies file vs directory type (`daemon/windows.rs#check_kind`).
    public static func validateStorageFileKind(attributes: UInt32, expectDirectory: Bool) throws {
        if (attributes & fileAttributeReparsePoint) != 0 {
            throw ProcessDaemon.DaemonError("PTY storage must not be a reparse point")
        }
        let isDir = (attributes & fileAttributeDirectory) != 0
        if isDir != expectDirectory {
            throw ProcessDaemon.DaemonError("unexpected PTY storage file type")
        }
    }

    /// Rejects oversized registration files above 16 KiB (`daemon/windows.rs#read_registration`).
    public static func validateRegistrationSize(_ byteCount: Int) throws {
        if byteCount > maxRegistrationBytes {
            throw ProcessDaemon.DaemonError("PTY registration is too large")
        }
    }

    /// Formats the temporary registration filename written before atomic rename (`service.<instance_id>.tmp`).
    public static func registrationTempFileName(instanceId: String) -> String {
        "service.\(instanceId).tmp"
    }

    /// Returns `true` only when the current registration still belongs to `expectedInstanceId`.
    public static func shouldRemoveRegistrationOnCleanup(
        currentInstanceId: String?,
        expectedInstanceId: String
    ) -> Bool {
        currentInstanceId == expectedInstanceId
    }

    /// Joins `directory` and `component` using Windows backslash semantics so `\\?\` extended-length
    /// paths returned by `GetFinalPathNameByHandleW` never receive unsupported forward slashes.
    public static func joinWindowsPath(_ directory: String, _ component: String) -> String {
        guard !directory.isEmpty else { return component }
        guard !component.isEmpty else { return directory }
        var base = directory
        while base.count > 1 && (base.hasSuffix("\\") || base.hasSuffix("/")) {
            // Preserve drive root `C:\`
            if base.count == 3, base.dropFirst().hasPrefix(":\\") || base.dropFirst().hasPrefix(":/") {
                break
            }
            base.removeLast()
        }
        var tail = component
        while tail.hasPrefix("\\") || tail.hasPrefix("/") {
            tail.removeFirst()
        }
        if base.hasSuffix("\\") || base.hasSuffix("/") {
            return base + tail
        }
        return "\(base)\\\(tail)"
    }

    /// Extracts the parent directory of a Windows or POSIX path, returning `nil` for roots.
    public static func parentDirectory(of path: String) -> String? {
        var trimmed = path
        while trimmed.count > 1 && (trimmed.hasSuffix("\\") || trimmed.hasSuffix("/")) {
            if trimmed.count == 3, trimmed.dropFirst().hasPrefix(":\\") || trimmed.dropFirst().hasPrefix(":/") {
                return nil
            }
            trimmed.removeLast()
        }
        guard let lastSep = trimmed.lastIndex(where: { $0 == "\\" || $0 == "/" }) else {
            return nil
        }
        let prefix = String(trimmed[..<lastSep])
        if prefix.isEmpty {
            return trimmed.hasPrefix("/") ? "/" : nil
        }
        if prefix.count == 2, prefix.hasSuffix(":") {
            return prefix + "\\"
        }
        if prefix == #"\\?"# || prefix == #"\\."# || prefix == #"\"# {
            return nil
        }
        return prefix
    }

    /// Encodes a zeroed, exact-layout `FILE_RENAME_INFO` byte buffer for `SetFileInformationByHandle(..., FileRenameInfoEx, ...)`,
    /// matching `upstream/src/daemon/windows.rs#publish`.
    ///
    /// Layout:
    /// - offset `0`: `Flags: UInt32` (little-endian)
    /// - `RootDirectory`: zeroed (NULL)
    /// - `fileNameLengthOffset`: `FileNameLength: UInt32` in bytes (excluding trailing NUL)
    /// - `fileNameOffset`: UTF-16LE code units of `destinationPath` followed by at least one NUL WCHAR.
    public static func encodeFileRenameInfoBuffer(
        destinationPath: String,
        flags: UInt32 = atomicRenameFlags(),
        structSize: Int,
        fileNameLengthOffset: Int,
        fileNameOffset: Int
    ) throws -> (bytes: [UInt8], fileNameLengthBytes: UInt32) {
        let utf16Units = Array(destinationPath.utf16)
        if utf16Units.isEmpty || utf16Units.contains(0) {
            throw ProcessDaemon.DaemonError("invalid registration rename destination path")
        }
        let (nameBytesInt, nameMulOverflow) = utf16Units.count.multipliedReportingOverflow(by: 2)
        guard !nameMulOverflow, let nameBytes = UInt32(exactly: nameBytesInt) else {
            throw ProcessDaemon.DaemonError("registration rename buffer overflow")
        }
        let (totalBytes, totalOverflow) = structSize.addingReportingOverflow(nameBytesInt)
        guard !totalOverflow,
              fileNameOffset >= 0,
              fileNameLengthOffset >= 0,
              fileNameLengthOffset + 4 <= structSize,
              fileNameOffset + nameBytesInt + 2 <= totalBytes,
              UInt32(exactly: totalBytes) != nil else {
            throw ProcessDaemon.DaemonError("registration rename buffer overflow")
        }

        var buffer = [UInt8](repeating: 0, count: totalBytes)
        // Store Flags (little-endian UInt32) at offset 0.
        buffer[0] = UInt8(flags & 0xFF)
        buffer[1] = UInt8((flags >> 8) & 0xFF)
        buffer[2] = UInt8((flags >> 16) & 0xFF)
        buffer[3] = UInt8((flags >> 24) & 0xFF)

        // Store FileNameLength (little-endian UInt32) at fileNameLengthOffset.
        buffer[fileNameLengthOffset] = UInt8(nameBytes & 0xFF)
        buffer[fileNameLengthOffset + 1] = UInt8((nameBytes >> 8) & 0xFF)
        buffer[fileNameLengthOffset + 2] = UInt8((nameBytes >> 16) & 0xFF)
        buffer[fileNameLengthOffset + 3] = UInt8((nameBytes >> 24) & 0xFF)

        // Store UTF-16LE code units starting at fileNameOffset (trailing bytes remain zeroed).
        var writePos = fileNameOffset
        for unit in utf16Units {
            buffer[writePos] = UInt8(unit & 0xFF)
            buffer[writePos + 1] = UInt8((unit >> 8) & 0xFF)
            writePos += 2
        }
        return (bytes: buffer, fileNameLengthBytes: nameBytes)
    }
}

// MARK: - Native Windows Win32 Named-Pipe Transport, Security & Daemon Storage Primitives

#if os(Windows)

extension WindowsPrivateSecurity {
    private typealias GetSecurityInfoFn = @convention(c) (
        HANDLE?,
        DWORD,
        DWORD,
        UnsafeMutablePointer<PSID?>?,
        UnsafeMutablePointer<PSID?>?,
        UnsafeMutablePointer<UnsafeMutableRawPointer?>?,
        UnsafeMutablePointer<UnsafeMutableRawPointer?>?,
        UnsafeMutablePointer<PSECURITY_DESCRIPTOR?>?
    ) -> DWORD

    private typealias SetSecurityInfoFn = @convention(c) (
        HANDLE?,
        DWORD,
        DWORD,
        PSID?,
        PSID?,
        UnsafeMutableRawPointer?,
        UnsafeMutableRawPointer?
    ) -> DWORD

    private typealias GetSecurityDescriptorDaclFn = @convention(c) (
        PSECURITY_DESCRIPTOR?,
        UnsafeMutablePointer<WindowsBool>?,
        UnsafeMutablePointer<UnsafeMutableRawPointer?>?,
        UnsafeMutablePointer<WindowsBool>?
    ) -> WindowsBool

    private typealias GetSecurityDescriptorControlFn = @convention(c) (
        PSECURITY_DESCRIPTOR?,
        UnsafeMutablePointer<UInt16>?,
        UnsafeMutablePointer<DWORD>?
    ) -> WindowsBool

    private typealias GetSecurityDescriptorOwnerFn = @convention(c) (
        PSECURITY_DESCRIPTOR?,
        UnsafeMutablePointer<PSID?>?,
        UnsafeMutablePointer<WindowsBool>?
    ) -> WindowsBool

    private typealias GetAceFn = @convention(c) (
        UnsafeMutableRawPointer?,
        DWORD,
        UnsafeMutablePointer<UnsafeMutableRawPointer?>?
    ) -> WindowsBool

    private typealias EqualSidFn = @convention(c) (
        PSID?,
        PSID?
    ) -> WindowsBool

    private static func resolveAdvapi32<Fn>(_ module: HMODULE, _ symbol: String, as type: Fn.Type) throws -> Fn {
        guard let raw = GetProcAddress(module, symbol) else {
            throw WindowsOSFailure("GetProcAddress(\(symbol))")
        }
        return unsafeBitCast(raw, to: type)
    }

    private func isCurrentUser(sid: PSID, module: HMODULE) throws -> Bool {
        let getOwner = try Self.resolveAdvapi32(module, "GetSecurityDescriptorOwner", as: GetSecurityDescriptorOwnerFn.self)
        let equalSid = try Self.resolveAdvapi32(module, "EqualSid", as: EqualSidFn.self)
        var owner: PSID? = nil
        var defaulted: WindowsBool = false
        guard getOwner(descriptor, &owner, &defaulted).boolValue, let owner else {
            throw WindowsOSFailure("GetSecurityDescriptorOwner")
        }
        return equalSid(owner, sid).boolValue
    }

    /// Queries the owner + DACL security descriptor for `handle` and verifies ownership by the current user.
    /// Caller owns the returned `PSECURITY_DESCRIPTOR` and MUST free it via `LocalFree`.
    private func copyAndCheckOwnerDescriptor(handle: HANDLE, module: HMODULE) throws -> PSECURITY_DESCRIPTOR {
        let getSecurityInfo = try Self.resolveAdvapi32(module, "GetSecurityInfo", as: GetSecurityInfoFn.self)
        var owner: PSID? = nil
        var actualDescriptor: PSECURITY_DESCRIPTOR? = nil
        let status = getSecurityInfo(
            handle,
            DWORD(WindowsNamedPipeHelpers.seFileObject),
            DWORD(WindowsNamedPipeHelpers.ownerSecurityInformation | WindowsNamedPipeHelpers.daclSecurityInformation),
            &owner,
            nil,
            nil,
            nil,
            &actualDescriptor
        )
        guard status == 0, let actual = actualDescriptor else {
            throw WindowsOSFailure("GetSecurityInfo", code: status)
        }
        do {
            guard let owner, try isCurrentUser(sid: owner, module: module) else {
                _ = LocalFree(actual)
                throw ProcessDaemon.DaemonError("PTY storage is not owned by the current user")
            }
        } catch {
            _ = LocalFree(actual)
            throw error
        }
        return actual
    }

    /// Verifies `handle` is owned by the current user, then applies our protected current-user DACL.
    /// Matches `upstream/src/transport/windows/security.rs#PrivateSecurity::make_private`.
    func makePrivate(handle: HANDLE) throws {
        try Self.withAdvapi32 { module in
            let actual = try copyAndCheckOwnerDescriptor(handle: handle, module: module)
            defer { _ = LocalFree(actual) }

            let getDacl = try Self.resolveAdvapi32(module, "GetSecurityDescriptorDacl", as: GetSecurityDescriptorDaclFn.self)
            let setSecurityInfo = try Self.resolveAdvapi32(module, "SetSecurityInfo", as: SetSecurityInfoFn.self)

            var present: WindowsBool = false
            var defaulted: WindowsBool = false
            var dacl: UnsafeMutableRawPointer? = nil
            guard getDacl(descriptor, &present, &dacl, &defaulted).boolValue else {
                throw WindowsOSFailure("GetSecurityDescriptorDacl")
            }
            let status = setSecurityInfo(
                handle,
                DWORD(WindowsNamedPipeHelpers.seFileObject),
                DWORD(
                    WindowsNamedPipeHelpers.daclSecurityInformation
                        | WindowsNamedPipeHelpers.protectedDaclSecurityInformation
                ),
                nil,
                nil,
                dacl,
                nil
            )
            if status != 0 {
                throw WindowsOSFailure("SetSecurityInfo", code: status)
            }
        }
    }

    /// Verifies `handle` is owned by the current user and has a protected DACL with a single
    /// `ACCESS_ALLOWED_ACE` granting access only to the current user.
    /// Matches `upstream/src/transport/windows/security.rs#PrivateSecurity::check_private`.
    func checkPrivate(handle: HANDLE) throws {
        try Self.withAdvapi32 { module in
            let actual = try copyAndCheckOwnerDescriptor(handle: handle, module: module)
            defer { _ = LocalFree(actual) }

            let getDacl = try Self.resolveAdvapi32(module, "GetSecurityDescriptorDacl", as: GetSecurityDescriptorDaclFn.self)
            let getControl = try Self.resolveAdvapi32(module, "GetSecurityDescriptorControl", as: GetSecurityDescriptorControlFn.self)
            let getAce = try Self.resolveAdvapi32(module, "GetAce", as: GetAceFn.self)

            var present: WindowsBool = false
            var defaulted: WindowsBool = false
            var dacl: UnsafeMutableRawPointer? = nil
            var control: UInt16 = 0
            var revision: DWORD = 0
            guard getDacl(actual, &present, &dacl, &defaulted).boolValue,
                  getControl(actual, &control, &revision).boolValue else {
                throw WindowsOSFailure("GetSecurityDescriptorDacl/Control")
            }

            var aceCount: UInt32 = 0
            var firstAceType: UInt8? = nil
            var firstAceIsCurrentUser = false

            if present.boolValue, let daclPtr = dacl {
                let rawCount = daclPtr.loadUnaligned(
                    fromByteOffset: WindowsNamedPipeHelpers.aclAceCountOffset,
                    as: UInt16.self
                )
                aceCount = UInt32(rawCount)
                if aceCount == 1 {
                    var acePtr: UnsafeMutableRawPointer? = nil
                    if getAce(daclPtr, 0, &acePtr).boolValue, let ace = acePtr {
                        let aceType = ace.load(
                            fromByteOffset: WindowsNamedPipeHelpers.aceHeaderTypeOffset,
                            as: UInt8.self
                        )
                        firstAceType = aceType
                        if aceType == WindowsNamedPipeHelpers.accessAllowedAceType {
                            let sidPtr = ace.advanced(by: WindowsNamedPipeHelpers.accessAllowedAceSidOffset)
                            firstAceIsCurrentUser = try isCurrentUser(sid: sidPtr, module: module)
                        }
                    }
                }
            }

            try WindowsNamedPipeHelpers.validatePrivateDacl(
                present: present.boolValue,
                hasDaclPointer: dacl != nil,
                control: control,
                aceCount: aceCount,
                firstAceType: firstAceType,
                firstAceIsCurrentUser: firstAceIsCurrentUser
            )
        }
    }
}

/// Shared named-pipe handle + manual-reset cancellation event, equivalent to Rust `Arc<Pipe>`.
internal final class WindowsPipe: @unchecked Sendable {
    let handle: OwnedWinHandle
    let cancelled: OwnedWinHandle

    init(handle: OwnedWinHandle) throws {
        self.handle = handle
        self.cancelled = try OwnedWinHandle.makeManualResetEvent()
    }

    func cancel() {
        cancelled.setEvent()
    }
}

/// Owns one overlapped named-pipe I/O operation (`OVERLAPPED` + manual-reset completion event).
/// Cancels (`CancelIoEx`) and reaps (`GetOverlappedResult(..., true)`) before releasing its
/// `OVERLAPPED`, event, or returning control past a borrowed I/O buffer.
/// Mirrors `upstream/src/transport/windows.rs#Operation`.
internal final class WindowsPipeOperation: @unchecked Sendable {
    let pipe: WindowsPipe
    private let overlapped: ProcessDaemon.Transport.Retained<OVERLAPPED>
    private let event: OwnedWinHandle
    private var pending: Bool = false

    init(pipe: WindowsPipe) throws {
        if pipe.cancelled.isSignalled() {
            throw ProcessDaemon.DaemonError("named pipe operation cancelled")
        }
        let event = try OwnedWinHandle.makeManualResetEvent()
        var ov = OVERLAPPED()
        ov.hEvent = event.raw
        self.pipe = pipe
        self.overlapped = ProcessDaemon.Transport.Retained.new(ov)
        self.event = event
        self.pending = false
    }

    deinit {
        reapIfPending()
    }

    /// Cancels and synchronously reaps any in-flight overlapped operation so the kernel is guaranteed
    /// to stop referencing `overlapped` and any borrowed I/O buffer.
    func reapIfPending() {
        if pending {
            _ = CancelIoEx(pipe.handle.raw, overlapped.as_ptr())
            var count: DWORD = 0
            _ = GetOverlappedResult(pipe.handle.raw, overlapped.as_ptr(), &count, true)
            pending = false
        }
    }

    func begin(_ submit: (HANDLE, UnsafeMutablePointer<OVERLAPPED>) -> Bool) throws -> UInt32? {
        pending = true
        if submit(pipe.handle.raw, overlapped.as_ptr()) {
            return try poll()
        }
        let err = GetLastError()
        if WindowsNamedPipeHelpers.isIoPendingError(UInt32(err)) {
            return nil
        }
        pending = false
        throw WindowsOSFailure("overlapped named pipe operation", code: err)
    }

    func poll() throws -> UInt32? {
        var count: DWORD = 0
        if GetOverlappedResult(pipe.handle.raw, overlapped.as_ptr(), &count, false) {
            pending = false
            return UInt32(count)
        }
        let err = GetLastError()
        if WindowsNamedPipeHelpers.isIoIncompleteError(UInt32(err)) {
            return nil
        }
        pending = false
        throw WindowsOSFailure("GetOverlappedResult", code: err)
    }

    func wait(timeoutMs: UInt64?) throws -> UInt32 {
        // Cancellation is index 0 so WaitForMultipleObjects prioritizes it if both are signalled.
        let handles: [HANDLE?] = [pipe.cancelled.raw, event.raw]
        let milliseconds = DWORD(WindowsNamedPipeHelpers.overlappedWaitTimeoutMs(timeoutMs))
        let result = handles.withUnsafeBufferPointer { ptr in
            WaitForMultipleObjects(2, ptr.baseAddress, false, milliseconds)
        }
        if result == WAIT_OBJECT_0 {
            throw ProcessDaemon.DaemonError("named pipe operation cancelled")
        }
        if result == DWORD(WAIT_TIMEOUT) {
            throw ProcessDaemon.DaemonError("named pipe completion timed out")
        }
        if result != WAIT_OBJECT_0 + 1 {
            throw WindowsOSFailure("WaitForMultipleObjects")
        }
        guard let count = try poll() else {
            throw ProcessDaemon.DaemonError("named pipe signalled before I/O completion")
        }
        return count
    }
}

/// Pending server-side named-pipe instance waiting on overlapped `ConnectNamedPipe`.
/// Mirrors `upstream/src/transport/windows.rs#PendingConnection`.
internal final class WindowsPendingConnection: @unchecked Sendable {
    let operation: WindowsPipeOperation
    var connected: Bool

    init(endpointWide: [UInt16], security: WindowsPrivateSecurity, first: Bool) throws {
        let openMode = DWORD(WindowsNamedPipeHelpers.serverOpenMode(firstInstance: first))
        let pipeMode = DWORD(WindowsNamedPipeHelpers.serverPipeMode())
        var sa = security.securityAttributes(inherit: false)
        let rawHandle: HANDLE? = endpointWide.withUnsafeBufferPointer { ptr in
            CreateNamedPipeW(
                ptr.baseAddress,
                openMode,
                pipeMode,
                DWORD(WindowsNamedPipeHelpers.pipeUnlimitedInstances),
                DWORD(WindowsNamedPipeHelpers.bufferBytes),
                DWORD(WindowsNamedPipeHelpers.bufferBytes),
                0,
                &sa
            )
        }
        let owned = try OwnedWinHandle.adopt(rawHandle, operation: "CreateNamedPipeW")
        let pipe = try WindowsPipe(handle: owned)
        let operation = try WindowsPipeOperation(pipe: pipe)
        let connected: Bool
        do {
            let ready = try operation.begin { handle, overlapped in
                ConnectNamedPipe(handle, overlapped)
            }
            connected = ready != nil
        } catch let failure as WindowsOSFailure where WindowsNamedPipeHelpers.isConnectAlreadyConnectedError(failure.code) {
            // A client can connect (and even close) between CreateNamedPipeW and ConnectNamedPipe.
            // Hand off that connection; its reader sees EOF.
            connected = true
        }
        self.operation = operation
        self.connected = connected
    }

    func ready() throws -> Bool {
        if !connected {
            connected = try operation.poll() != nil
        }
        return connected
    }

    func cancel() {
        operation.pipe.cancel()
    }
}

/// Win32 storage, locking, and atomic POSIX-rename primitives for `Daemon.WindowsRuntime` & `Daemon.Sweep`.
/// Mirrors `upstream/src/daemon/windows.rs`.
internal enum WindowsRuntimePrimitives {
    static func openStorageHandle(
        path: String,
        access: DWORD,
        creation: DWORD,
        sharing: DWORD,
        security: WindowsPrivateSecurity
    ) throws -> OwnedWinHandle {
        let widePath = try WindowsNamedPipeHelpers.encodeWide(path)
        var sa = security.securityAttributes(inherit: false)
        let raw: HANDLE? = widePath.withUnsafeBufferPointer { ptr in
            CreateFileW(
                ptr.baseAddress,
                access,
                sharing,
                &sa,
                creation,
                DWORD(FILE_FLAG_OPEN_REPARSE_POINT) | DWORD(FILE_FLAG_BACKUP_SEMANTICS),
                nil
            )
        }
        return try OwnedWinHandle.adopt(raw, operation: "CreateFileW(\(path))")
    }

    static func checkStorageKind(_ handle: OwnedWinHandle, expectDirectory: Bool) throws {
        var info = BY_HANDLE_FILE_INFORMATION()
        guard GetFileInformationByHandle(handle.raw, &info) else {
            throw WindowsOSFailure("GetFileInformationByHandle")
        }
        try WindowsNamedPipeHelpers.validateStorageFileKind(
            attributes: UInt32(info.dwFileAttributes),
            expectDirectory: expectDirectory
        )
    }

    static func createPrivateDirectory(path: String, security: WindowsPrivateSecurity) throws {
        let wideDir = try WindowsNamedPipeHelpers.encodeWide(path)
        var sa = security.securityAttributes(inherit: false)
        let created = wideDir.withUnsafeBufferPointer { ptr in
            CreateDirectoryW(ptr.baseAddress, &sa)
        }
        if !created {
            let err = GetLastError()
            if UInt32(err) != WindowsNamedPipeHelpers.errorAlreadyExists {
                throw WindowsOSFailure("CreateDirectoryW(\(path))", code: err)
            }
        }
    }

    /// Resolves the normalized final path for a held directory handle (`daemon/windows.rs#held_directory_path`).
    static func heldDirectoryPath(_ directory: OwnedWinHandle) throws -> String {
        let length = GetFinalPathNameByHandleW(directory.raw, nil, 0, 0)
        guard length > 0 else {
            throw WindowsOSFailure("GetFinalPathNameByHandleW(size)")
        }
        var buffer = [UInt16](repeating: 0, count: Int(length))
        let written: DWORD = buffer.withUnsafeMutableBufferPointer { ptr in
            GetFinalPathNameByHandleW(directory.raw, ptr.baseAddress, length, 0)
        }
        guard written > 0 else {
            throw WindowsOSFailure("GetFinalPathNameByHandleW")
        }
        guard written < length else {
            throw ProcessDaemon.DaemonError("PTY runtime directory path changed during publication")
        }
        return String(decoding: buffer[0..<Int(written)], as: UTF16.self)
    }

    /// Acquires a non-blocking exclusive byte-range lock on `handle` matching `fs2::FileExt::try_lock_exclusive`.
    static func tryLockFileExclusive(_ handle: OwnedWinHandle) -> Bool {
        var ov = OVERLAPPED()
        return LockFileEx(
            handle.raw,
            DWORD(WindowsNamedPipeHelpers.lockFileExclusiveFlags()),
            0,
            1,
            0,
            &ov
        )
    }

    /// Reads at most `maxBytes + 1` bytes synchronously from `handle`.
    static func readFileBounded(_ handle: OwnedWinHandle, maxBytes: Int) throws -> [UInt8] {
        let limit = maxBytes + 1
        var collected: [UInt8] = []
        collected.reserveCapacity(min(limit, 4096))
        var chunk = [UInt8](repeating: 0, count: min(limit, 4096))
        while collected.count < limit {
            let remaining = limit - collected.count
            let toRead = min(chunk.count, remaining)
            var bytesRead: DWORD = 0
            let ok = chunk.withUnsafeMutableBytes { rawBuf in
                ReadFile(handle.raw, rawBuf.baseAddress, DWORD(toRead), &bytesRead, nil)
            }
            guard ok else {
                throw WindowsOSFailure("ReadFile")
            }
            if bytesRead == 0 {
                break
            }
            collected.append(contentsOf: chunk[0..<Int(bytesRead)])
        }
        return collected
    }

    /// Atomically publishes an open temporary registration file onto `service.json` using
    /// `SetFileInformationByHandle(..., FileRenameInfoEx, ...)` with POSIX replace semantics.
    /// Mirrors `upstream/src/daemon/windows.rs#publish`.
    static func publishRegistrationAtomically(
        file: OwnedWinHandle,
        directoryHandle: OwnedWinHandle
    ) throws {
        let destination = WindowsNamedPipeHelpers.joinWindowsPath(
            try heldDirectoryPath(directoryHandle),
            ProcessDaemon.REGISTRATION_FILE
        )
        let structSize = MemoryLayout<FILE_RENAME_INFO>.size
        let structAlignment = MemoryLayout<FILE_RENAME_INFO>.alignment
        guard let fileNameLengthOffset = MemoryLayout<FILE_RENAME_INFO>.offset(of: \.FileNameLength),
              let fileNameOffset = MemoryLayout<FILE_RENAME_INFO>.offset(of: \.FileName) else {
            throw ProcessDaemon.DaemonError("FILE_RENAME_INFO layout unavailable")
        }
        let encoded = try WindowsNamedPipeHelpers.encodeFileRenameInfoBuffer(
            destinationPath: destination,
            flags: WindowsNamedPipeHelpers.atomicRenameFlags(),
            structSize: structSize,
            fileNameLengthOffset: fileNameLengthOffset,
            fileNameOffset: fileNameOffset
        )

        let alignedBuffer = UnsafeMutableRawBufferPointer.allocate(
            byteCount: encoded.bytes.count,
            alignment: max(structAlignment, MemoryLayout<UInt64>.alignment)
        )
        defer { alignedBuffer.deallocate() }
        encoded.bytes.withUnsafeBytes { src in
            if let dstBase = alignedBuffer.baseAddress, let srcBase = src.baseAddress {
                dstBase.copyMemory(from: srcBase, byteCount: encoded.bytes.count)
            }
        }

        let ok = SetFileInformationByHandle(
            file.raw,
            FileRenameInfoEx,
            alignedBuffer.baseAddress,
            DWORD(encoded.bytes.count)
        )
        guard ok else {
            throw ProcessDaemon.DaemonError(
                "failed to atomically publish PTY registration: \(WindowsOSFailure("SetFileInformationByHandle"))"
            )
        }
    }

    /// Writes `registration` to a brand-new private temporary file, flushes it to disk, and
    /// atomically publishes it as `service.json` via POSIX rename semantics.
    /// Mirrors `upstream/src/daemon/windows.rs#write_registration`.
    static func writeRegistrationAtomically(
        directory: String,
        directoryHandle: OwnedWinHandle,
        registration: ProcessDaemon.Registration,
        security: WindowsPrivateSecurity
    ) throws {
        let tempName = WindowsNamedPipeHelpers.registrationTempFileName(instanceId: registration.instanceId)
        let tempPath = WindowsNamedPipeHelpers.joinWindowsPath(directory, tempName)
        do {
            let tempFile = try openStorageHandle(
                path: tempPath,
                access: DWORD(GENERIC_WRITE) | DWORD(READ_CONTROL) | DWORD(DELETE),
                creation: DWORD(CREATE_NEW),
                sharing: 0,
                security: security
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(registration)
            try WindowsProcessPrimitives.writeAll(to: tempFile, bytes: Array(data))
            // Regular disk file sync (matches Rust `file.sync_all()` — never used on named pipes).
            guard FlushFileBuffers(tempFile.raw) else {
                throw WindowsOSFailure("FlushFileBuffers(registration)")
            }
            try publishRegistrationAtomically(file: tempFile, directoryHandle: directoryHandle)
        } catch {
            try? FileManager.default.removeItem(atPath: tempPath)
            throw error
        }
    }

    /// Returns `true` if `path` has `FILE_ATTRIBUTE_REPARSE_POINT` set.
    static func isReparsePoint(path: String) -> Bool {
        guard let wide = try? WindowsNamedPipeHelpers.encodeWide(path) else { return false }
        let attrs = wide.withUnsafeBufferPointer { ptr in
            GetFileAttributesW(ptr.baseAddress)
        }
        guard attrs != INVALID_FILE_ATTRIBUTES else { return false }
        return (UInt32(attrs) & WindowsNamedPipeHelpers.fileAttributeReparsePoint) != 0
    }

    /// Opens an existing `service.lock` for the stale-runtime sweeper and tries an exclusive lock.
    /// Returns `.some(handle)` if acquired, `nil` if the file does not exist, or throws `.busy` if locked by a live daemon.
    enum SweepLockResult {
        case acquired(OwnedWinHandle)
        case missing
        case lockedByLiveDaemon
    }

    static func tryAcquireSweepLock(lockPath: String) -> SweepLockResult {
        guard let wide = try? WindowsNamedPipeHelpers.encodeWide(lockPath) else {
            return .lockedByLiveDaemon
        }
        let raw: HANDLE? = wide.withUnsafeBufferPointer { ptr in
            CreateFileW(
                ptr.baseAddress,
                DWORD(GENERIC_READ) | DWORD(GENERIC_WRITE),
                DWORD(FILE_SHARE_READ) | DWORD(FILE_SHARE_WRITE) | DWORD(FILE_SHARE_DELETE),
                nil,
                DWORD(OPEN_EXISTING),
                DWORD(FILE_FLAG_OPEN_REPARSE_POINT),
                nil
            )
        }
        guard let raw, raw != INVALID_HANDLE_VALUE else {
            let err = GetLastError()
            if err == DWORD(ERROR_FILE_NOT_FOUND) || err == DWORD(ERROR_PATH_NOT_FOUND) {
                return .missing
            }
            return .lockedByLiveDaemon
        }
        let handle = OwnedWinHandle(raw)
        if tryLockFileExclusive(handle) {
            return .acquired(handle)
        }
        return .lockedByLiveDaemon
    }
}

#endif
