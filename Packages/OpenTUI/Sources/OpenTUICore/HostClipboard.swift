import Synchronization

/// Pure-Swift host clipboard service, MIME representation validation, tracked cancellation,
/// composed host+terminal clipboard policies, and injectable native backend registry,
/// matching `packages/core/src/lib/clipboard.ts`, `host-clipboard.internal.ts`, and `host-clipboard.native.ts`.

// MARK: - Constants & Validation Limits

public let defaultClipboardTimeoutMs: UInt32 = 1_000
public let defaultClipboardMaxBytes: UInt32 = 8 * 1024 * 1024
public let defaultClipboardMaxImagePixels: UInt32 = 64 * 1024 * 1024
public let defaultClipboardMaxConversionBytes: UInt32 = 512 * 1024 * 1024
public let defaultClipboardMaxConcurrentOperations: UInt32 = 16
public let defaultClipboardMaxProviderTransfers: UInt32 = 16
private let maxU32Value: Int = Int(UInt32.max)

/// Maximum number of preferred MIME essence entries accepted in a single read request.
// parity: core/src/lib/host-clipboard.internal.ts#HOST_CLIPBOARD_MIME_PREFERENCE_COUNT_MAX [status=implemented hash=f1d51b91ea22]
public let hostClipboardMimePreferenceCountMax: Int = 64

/// Maximum ASCII byte length of a single MIME essence string.
// parity: core/src/lib/host-clipboard.internal.ts#HOST_CLIPBOARD_MIME_ESSENCE_BYTES_MAX [status=implemented hash=25919d3044ef]
public let hostClipboardMimeEssenceBytesMax: Int = 255

private let notAttemptedTerminalResult = TerminalClipboardOperationResult(
    status: .notAttempted,
    capability: .unknown
)

// MARK: - Errors & Failures

/// Structured error raised synchronously or asynchronously by clipboard validation and lifecycle checks.
public enum HostClipboardError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
    case typeError(String)
    case rangeError(String)
    case disposed(String)
    case operationFailed(String, code: Int32? = nil)

    public var description: String {
        switch self {
        case .typeError(let message), .rangeError(let message), .disposed(let message):
            return message
        case .operationFailed(let message, let code):
            if let code {
                return "\(message) (code: \(code))"
            }
            return message
        }
    }
}

/// Value-typed failure payload carried by `ClipboardReadResult`, `HostClipboardWriteResult`, and `HostClipboardClearResult`.
public struct ClipboardFailure: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
    public let message: String
    public let code: Int32?

    public init(message: String, code: Int32? = nil) {
        self.message = message
        self.code = code
    }

    public init(_ error: any Error) {
        if let failure = error as? ClipboardFailure {
            self = failure
        } else if let hostError = error as? HostClipboardError {
            if case .operationFailed(let msg, let code) = hostError {
                self.message = msg
                self.code = code
            } else {
                self.message = hostError.description
                self.code = nil
            }
        } else {
            self.message = String(describing: error)
            self.code = nil
        }
    }

    public var description: String {
        if let code {
            return "\(message) (code: \(code))"
        }
        return message
    }
}

// MARK: - Cooperative Cancellation Signal

/// Opaque token returned by `ClipboardAbortSignal.onAbort(_:)` for removing a listener.
public struct ClipboardAbortListenerToken: Equatable, Hashable, Sendable {
    fileprivate let id: UInt64
}

/// Pure-Swift thread-safe cooperative cancellation signal equivalent to Web `AbortSignal`.
public final class ClipboardAbortSignal: Sendable {
    private struct State: Sendable {
        var aborted: Bool = false
        var reason: String? = nil
        var nextListenerId: UInt64 = 1
        var listeners: [(id: UInt64, handler: @Sendable () -> Void)] = []
    }

    private let state = Mutex(State())

    internal init() {}

    public var isAborted: Bool {
        state.withLock { $0.aborted }
    }

    public var reason: String? {
        state.withLock { $0.reason }
    }

    @discardableResult
    public func onAbort(_ handler: @escaping @Sendable () -> Void) -> ClipboardAbortListenerToken {
        let (alreadyAborted, token) = state.withLock { s -> (Bool, ClipboardAbortListenerToken) in
            if s.aborted {
                return (true, ClipboardAbortListenerToken(id: 0))
            }
            let id = s.nextListenerId
            s.nextListenerId &+= 1
            s.listeners.append((id: id, handler: handler))
            return (false, ClipboardAbortListenerToken(id: id))
        }
        if alreadyAborted {
            handler()
        }
        return token
    }

    public func removeAbortListener(_ token: ClipboardAbortListenerToken) {
        guard token.id != 0 else { return }
        state.withLock { s in
            s.listeners.removeAll { $0.id == token.id }
        }
    }

    internal func triggerAbort(reason: String?) {
        let callbacks: [@Sendable () -> Void] = state.withLock { s in
            guard !s.aborted else { return [] }
            s.aborted = true
            s.reason = reason
            let current = s.listeners.map(\.handler)
            s.listeners.removeAll()
            return current
        }
        for callback in callbacks {
            callback()
        }
    }
}

/// Pure-Swift thread-safe cooperative cancellation controller equivalent to Web `AbortController`.
public final class ClipboardAbortController: Sendable {
    public let signal: ClipboardAbortSignal

    public init() {
        self.signal = ClipboardAbortSignal()
    }

    public func abort(reason: String? = nil) {
        signal.triggerAbort(reason: reason)
    }
}

// MARK: - Operation Lifecycle Tracking

/// Lifecycle state of a tracked clipboard operation.
public enum ClipboardOperationState: String, Equatable, Hashable, Sendable, Codable {
    case pending
    case active
    case cancelled
    case settled
}

/// Tracked in-flight clipboard operation holding an abort controller and settlement awaiters.
// parity: core/src/lib/host-clipboard.internal.ts#ActiveClipboardOperation [status=implemented hash=3795e99844c0]
public final class ActiveClipboardOperation: Sendable, Hashable {
    private struct State: Sendable {
        var lifecycle: ClipboardOperationState = .active
        var settled: Bool = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let id: UInt64
    public let controller: ClipboardAbortController
    private let state = Mutex(State())
    private let callerSignal: ClipboardAbortSignal?
    private let callerToken: ClipboardAbortListenerToken?

    private static let idCounter = Mutex<UInt64>(1)

    public init(callerSignal: ClipboardAbortSignal? = nil) {
        let allocatedId = Self.idCounter.withLock { next -> UInt64 in
            let current = next
            next &+= 1
            return current
        }
        self.id = allocatedId
        let controller = ClipboardAbortController()
        self.controller = controller
        self.callerSignal = callerSignal
        if let callerSignal {
            let reason = callerSignal.reason
            self.callerToken = callerSignal.onAbort { [weak controller] in
                controller?.abort(reason: reason)
            }
        } else {
            self.callerToken = nil
        }
    }

    public var operationState: ClipboardOperationState {
        state.withLock { s in
            if s.settled { return .settled }
            if controller.signal.isAborted { return .cancelled }
            return s.lifecycle
        }
    }

    public var isSettled: Bool {
        state.withLock { $0.settled }
    }

    public func abort(reason: String? = nil) {
        state.withLock { s in
            if !s.settled {
                s.lifecycle = .cancelled
            }
        }
        controller.abort(reason: reason)
    }

    public func settle() {
        if let callerSignal, let callerToken {
            callerSignal.removeAbortListener(callerToken)
        }
        let waiters: [CheckedContinuation<Void, Never>] = state.withLock { s in
            guard !s.settled else { return [] }
            s.settled = true
            s.lifecycle = .settled
            let pending = s.waiters
            s.waiters.removeAll()
            return pending
        }
        for continuation in waiters {
            continuation.resume()
        }
    }

    public func waitUntilSettled() async {
        let alreadySettled = state.withLock { $0.settled }
        if alreadySettled { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { s -> Bool in
                if s.settled { return true }
                s.waiters.append(continuation)
                return false
            }
            if resumeNow {
                continuation.resume()
            }
        }
    }

    public static func == (lhs: ActiveClipboardOperation, rhs: ActiveClipboardOperation) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// Thread-safe set of active clipboard operations for disposal coordination.
public final class ActiveClipboardOperationSet: Sendable {
    private let storage = Mutex<Set<ActiveClipboardOperation>>([])

    public init() {}

    public var count: Int {
        storage.withLock { $0.count }
    }

    public func insert(_ op: ActiveClipboardOperation) {
        _ = storage.withLock { $0.insert(op) }
    }

    public func remove(_ op: ActiveClipboardOperation) {
        _ = storage.withLock { $0.remove(op) }
    }

    public func snapshot() -> [ActiveClipboardOperation] {
        storage.withLock { Array($0) }
    }

    public func abortAll(reason: String? = "Clipboard service disposed") {
        let ops = snapshot()
        for op in ops {
            op.abort(reason: reason)
        }
    }

    public func waitAllSettled() async {
        let ops = snapshot()
        for op in ops {
            await op.waitUntilSettled()
        }
    }
}

/// Executes an async clipboard operation while tracking it in `active` and propagating cancellation.
// parity: core/src/lib/host-clipboard.internal.ts#runTrackedOperation [status=implemented hash=180255ddc70f]
public func runTrackedOperation<T: Sendable>(
    active: ActiveClipboardOperationSet,
    callerSignal: ClipboardAbortSignal?,
    operation: @Sendable (ClipboardAbortSignal) async throws -> T
) async throws -> T {
    let op = ActiveClipboardOperation(callerSignal: callerSignal)
    active.insert(op)
    defer {
        active.remove(op)
        op.abort()
        op.settle()
    }
    return try await operation(op.controller.signal)
}

// MARK: - Validation Helpers

@inline(__always)
private func isMimeTokenByte(_ byte: UInt8) -> Bool {
    if (byte >= 0x30 && byte <= 0x39) // 0-9
        || (byte >= 0x41 && byte <= 0x5A) // A-Z
        || (byte >= 0x61 && byte <= 0x7A) // a-z
    {
        return true
    }
    switch byte {
    case UInt8(ascii: "!"), UInt8(ascii: "#"), UInt8(ascii: "$"), UInt8(ascii: "%"),
         UInt8(ascii: "&"), UInt8(ascii: "'"), UInt8(ascii: "*"), UInt8(ascii: "+"),
         UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "^"), UInt8(ascii: "_"),
         UInt8(ascii: "`"), UInt8(ascii: "|"), UInt8(ascii: "~"):
        return true
    default:
        return false
    }
}

private func isValidMimeEssence(_ mimeType: String) -> Bool {
    let bytes = Array(mimeType.utf8)
    guard !bytes.isEmpty else { return false }
    var slashIndex: Int? = nil
    for (idx, b) in bytes.enumerated() {
        if b == UInt8(ascii: "/") {
            if slashIndex != nil { return false }
            slashIndex = idx
        } else if !isMimeTokenByte(b) {
            return false
        }
    }
    guard let slash = slashIndex, slash > 0, slash + 1 < bytes.count else {
        return false
    }
    return true
}

private func validateU32Option(_ name: String, _ value: Int) throws(HostClipboardError) -> UInt32 {
    guard value >= 0 && value <= maxU32Value else {
        throw .rangeError("\(name) must be an integer from 0 through \(maxU32Value)")
    }
    return UInt32(value)
}

private func validatePositiveU32Option(_ name: String, _ value: Int) throws(HostClipboardError) -> UInt32 {
    let validated = try validateU32Option(name, value)
    guard validated > 0 else {
        throw .rangeError("\(name) must be greater than zero")
    }
    return validated
}

private func normalizePreferredTypes(_ preferredTypes: [String]) throws(HostClipboardError) -> [String] {
    guard !preferredTypes.isEmpty else {
        throw .typeError("preferredTypes must contain at least one MIME essence type")
    }
    guard preferredTypes.count <= hostClipboardMimePreferenceCountMax else {
        throw .rangeError("preferredTypes must contain at most \(hostClipboardMimePreferenceCountMax) MIME essence types")
    }
    var normalized: [String] = []
    normalized.reserveCapacity(preferredTypes.count)
    for mimeType in preferredTypes {
        guard mimeType.utf8.count <= hostClipboardMimeEssenceBytesMax else {
            throw .rangeError(
                "preferredTypes MIME essences must be at most \(hostClipboardMimeEssenceBytesMax) ASCII bytes"
            )
        }
        guard isValidMimeEssence(mimeType) else {
            throw .typeError("preferredTypes must contain valid MIME essence types without parameters")
        }
        normalized.append(mimeType.lowercased())
    }
    return normalized
}

/// Validates clipboard text for non-emptiness, absence of NUL bytes, and UTF-8 byte budget.
// parity: core/src/lib/host-clipboard.internal.ts#validateClipboardText [status=implemented hash=73e12bedd22c]
public func validateClipboardText(_ text: String, maxWriteBytes: Int) throws(HostClipboardError) {
    guard !text.isEmpty else {
        throw .typeError("writeText requires non-empty text")
    }
    if text.utf8.contains(0) {
        throw .typeError("writeText does not support NUL characters")
    }
    let byteLimit = min(max(0, maxWriteBytes), maxU32Value)
    var byteLength = 0
    for scalar in text.unicodeScalars {
        let v = scalar.value
        if v <= 0x7F {
            byteLength += 1
        } else if v <= 0x7FF {
            byteLength += 2
        } else if v <= 0xFFFF {
            byteLength += 3
        } else {
            byteLength += 4
        }
        if byteLength > byteLimit {
            throw .rangeError("writeText exceeds the configured \(maxWriteBytes) byte limit")
        }
    }
}

/// Validates raw UTF-16 code units, additionally rejecting unpaired UTF-16 surrogates.
public func validateClipboardUTF16(_ units: [UInt16], maxWriteBytes: Int) throws(HostClipboardError) {
    guard !units.isEmpty else {
        throw .typeError("writeText requires non-empty text")
    }
    let byteLimit = min(max(0, maxWriteBytes), maxU32Value)
    var byteLength = 0
    var i = 0
    while i < units.count {
        let u = units[i]
        if u == 0 {
            throw .typeError("writeText does not support NUL characters")
        }
        if u >= 0xD800 && u <= 0xDBFF {
            guard i + 1 < units.count else {
                throw .typeError("writeText does not support unpaired UTF-16 surrogates")
            }
            let low = units[i + 1]
            guard low >= 0xDC00 && low <= 0xDFFF else {
                throw .typeError("writeText does not support unpaired UTF-16 surrogates")
            }
            byteLength += 4
            i += 2
        } else if u >= 0xDC00 && u <= 0xDFFF {
            throw .typeError("writeText does not support unpaired UTF-16 surrogates")
        } else {
            if u <= 0x7F {
                byteLength += 1
            } else if u <= 0x7FF {
                byteLength += 2
            } else {
                byteLength += 3
            }
            i += 1
        }
        if byteLength > byteLimit {
            throw .rangeError("writeText exceeds the configured \(maxWriteBytes) byte limit")
        }
    }
}

// MARK: - Clipboard Options & Result Types (`core/src/lib/clipboard.ts`)

/// Caller options for reading from the process host clipboard.
// parity: core/src/lib/clipboard.ts#ClipboardReadOptions [status=implemented hash=f001965da630]
public struct ClipboardReadOptions: Sendable {
    public var preferredTypes: [String]
    public var selection: ClipboardSelection?
    public var signal: ClipboardAbortSignal?

    public init(
        preferredTypes: [String],
        selection: ClipboardSelection? = nil,
        signal: ClipboardAbortSignal? = nil
    ) {
        self.preferredTypes = preferredTypes
        self.selection = selection
        self.signal = signal
    }
}

/// Outcome of a host clipboard read attempt.
// parity: core/src/lib/clipboard.ts#ClipboardReadResult [status=implemented hash=366dbd69825d]
public enum ClipboardReadResult: Equatable, Hashable, Sendable {
    case read(ClipboardRepresentation)
    case empty
    case unsupported
    case cancelled
    case timedOut
    case limitExceeded
    case failed(ClipboardFailure)

    public var status: String {
        switch self {
        case .read: return "read"
        case .empty: return "empty"
        case .unsupported: return "unsupported"
        case .cancelled: return "cancelled"
        case .timedOut: return "timed-out"
        case .limitExceeded: return "limit-exceeded"
        case .failed: return "failed"
        }
    }

    public var representation: ClipboardRepresentation? {
        if case .read(let rep) = self { return rep }
        return nil
    }
}

/// Normalized read options passed directly to a `HostClipboardBackend`.
// parity: core/src/lib/clipboard.ts#HostClipboardReadOptions [status=implemented hash=f1c8a721462f]
public struct HostClipboardReadOptions: Sendable {
    public let preferredTypes: [String]
    public let selection: ClipboardSelection
    public let maxBytes: Int
    public let timeoutMs: Int
    public let signal: ClipboardAbortSignal

    public init(
        preferredTypes: [String],
        selection: ClipboardSelection,
        maxBytes: Int,
        timeoutMs: Int,
        signal: ClipboardAbortSignal
    ) {
        self.preferredTypes = preferredTypes
        self.selection = selection
        self.maxBytes = maxBytes
        self.timeoutMs = timeoutMs
        self.signal = signal
    }
}

/// Normalized write/clear options passed directly to a `HostClipboardBackend`.
// parity: core/src/lib/clipboard.ts#HostClipboardWriteOptions [status=implemented hash=aa65d9975115]
public struct HostClipboardWriteOptions: Sendable {
    public let selection: ClipboardSelection
    public let timeoutMs: Int
    public let signal: ClipboardAbortSignal

    public init(
        selection: ClipboardSelection,
        timeoutMs: Int,
        signal: ClipboardAbortSignal
    ) {
        self.selection = selection
        self.timeoutMs = timeoutMs
        self.signal = signal
    }
}

/// Outcome of a host clipboard text write attempt.
// parity: core/src/lib/clipboard.ts#HostClipboardWriteResult [status=implemented hash=ccea00bc4afa]
public enum HostClipboardWriteResult: Equatable, Hashable, Sendable {
    case written
    case unsupported
    case cancelled
    case timedOut
    case failed(ClipboardFailure)

    public var status: String {
        switch self {
        case .written: return "written"
        case .unsupported: return "unsupported"
        case .cancelled: return "cancelled"
        case .timedOut: return "timed-out"
        case .failed: return "failed"
        }
    }
}

/// Outcome of a host clipboard clear attempt.
// parity: core/src/lib/clipboard.ts#HostClipboardClearResult [status=implemented hash=6369fe932bca]
public enum HostClipboardClearResult: Equatable, Hashable, Sendable {
    case cleared
    case unsupported
    case cancelled
    case timedOut
    case failed(ClipboardFailure)

    public var status: String {
        switch self {
        case .cleared: return "cleared"
        case .unsupported: return "unsupported"
        case .cancelled: return "cancelled"
        case .timedOut: return "timed-out"
        case .failed: return "failed"
        }
    }
}

/// Injectable backend contract for process-host clipboard reads, writes, and clears.
// parity: core/src/lib/clipboard.ts#HostClipboardBackend [status=implemented hash=c515328b0abe]
public protocol HostClipboardBackend: Sendable {
    func read(_ options: HostClipboardReadOptions) async throws -> ClipboardReadResult
    func writeText(_ text: String, options: HostClipboardWriteOptions) async throws -> HostClipboardWriteResult
    func clear(_ options: HostClipboardWriteOptions) async throws -> HostClipboardClearResult
    func dispose() async throws
}

/// Caller options controlling a composed clipboard write or clear operation.
// parity: core/src/lib/clipboard.ts#ClipboardWriteOptions [status=implemented hash=144e2877f711]
public struct ClipboardWriteOptions: Sendable {
    public var destination: ClipboardWriteDestination
    public var selection: ClipboardSelection?
    public var allowRemoteHost: Bool
    public var signal: ClipboardAbortSignal?

    public init(
        destination: ClipboardWriteDestination,
        selection: ClipboardSelection? = nil,
        allowRemoteHost: Bool = false,
        signal: ClipboardAbortSignal? = nil
    ) {
        self.destination = destination
        self.selection = selection
        self.allowRemoteHost = allowRemoteHost
        self.signal = signal
    }
}

/// Host half of a composed `ClipboardWriteResult`, distinguishing `"not-attempted"` from backend outcomes.
public enum ClipboardWriteHostOutcome: Equatable, Hashable, Sendable {
    case written
    case unsupported
    case cancelled
    case timedOut
    case failed(ClipboardFailure)
    case notAttempted

    public init(_ result: HostClipboardWriteResult) {
        switch result {
        case .written: self = .written
        case .unsupported: self = .unsupported
        case .cancelled: self = .cancelled
        case .timedOut: self = .timedOut
        case .failed(let error): self = .failed(error)
        }
    }

    public var status: String {
        switch self {
        case .written: return "written"
        case .unsupported: return "unsupported"
        case .cancelled: return "cancelled"
        case .timedOut: return "timed-out"
        case .failed: return "failed"
        case .notAttempted: return "not-attempted"
        }
    }
}

/// Host half of a composed `ClipboardClearResult`, distinguishing `"not-attempted"` from backend outcomes.
public enum ClipboardClearHostOutcome: Equatable, Hashable, Sendable {
    case cleared
    case unsupported
    case cancelled
    case timedOut
    case failed(ClipboardFailure)
    case notAttempted

    public init(_ result: HostClipboardClearResult) {
        switch result {
        case .cleared: self = .cleared
        case .unsupported: self = .unsupported
        case .cancelled: self = .cancelled
        case .timedOut: self = .timedOut
        case .failed(let error): self = .failed(error)
        }
    }

    public var status: String {
        switch self {
        case .cleared: return "cleared"
        case .unsupported: return "unsupported"
        case .cancelled: return "cancelled"
        case .timedOut: return "timed-out"
        case .failed: return "failed"
        case .notAttempted: return "not-attempted"
        }
    }
}

/// Combined host and terminal results of a composed clipboard write.
// parity: core/src/lib/clipboard.ts#ClipboardWriteResult [status=implemented hash=cc00cad80c90]
public struct ClipboardWriteResult: Equatable, Hashable, Sendable {
    public let host: ClipboardWriteHostOutcome
    public let terminal: TerminalClipboardOperationResult

    public init(host: ClipboardWriteHostOutcome, terminal: TerminalClipboardOperationResult) {
        self.host = host
        self.terminal = terminal
    }
}

/// Combined host and terminal results of a composed clipboard clear.
// parity: core/src/lib/clipboard.ts#ClipboardClearResult [status=implemented hash=17b01a9a3c82]
public struct ClipboardClearResult: Equatable, Hashable, Sendable {
    public let host: ClipboardClearHostOutcome
    public let terminal: TerminalClipboardOperationResult

    public init(host: ClipboardClearHostOutcome, terminal: TerminalClipboardOperationResult) {
        self.host = host
        self.terminal = terminal
    }
}

/// High-level composed clipboard service coordinating host and terminal OSC 52 destinations.
// parity: core/src/lib/clipboard.ts#ClipboardService [status=implemented hash=d8e5cb01b4b3]
public protocol ClipboardService: Sendable {
    func read(_ options: ClipboardReadOptions) async throws -> ClipboardReadResult
    func writeText(_ text: String, options: ClipboardWriteOptions) async throws -> ClipboardWriteResult
    func clear(_ options: ClipboardWriteOptions) async throws -> ClipboardClearResult
    func dispose() async throws
}

/// Optional selection and cancellation signal for `HostClipboardService` mutations.
// parity: core/src/lib/clipboard.ts#HostClipboardOperationOptions [status=implemented hash=f558240baa81]
public struct HostClipboardOperationOptions: Sendable {
    public var selection: ClipboardSelection?
    public var signal: ClipboardAbortSignal?

    public init(selection: ClipboardSelection? = nil, signal: ClipboardAbortSignal? = nil) {
        self.selection = selection
        self.signal = signal
    }
}

/// Process-host clipboard service with validated limits, cooperative cancellation, and disposal.
// parity: core/src/lib/clipboard.ts#HostClipboardService [status=implemented hash=b23c43683729]
public protocol HostClipboardService: Sendable {
    var maxWriteBytes: Int { get }
    func read(_ options: ClipboardReadOptions) async throws -> ClipboardReadResult
    func writeText(_ text: String, options: HostClipboardOperationOptions) async throws -> HostClipboardWriteResult
    func clear(_ options: HostClipboardOperationOptions) async throws -> HostClipboardClearResult
    func dispose() async throws
}

public extension HostClipboardService {
    func writeText(_ text: String) async throws -> HostClipboardWriteResult {
        try await writeText(text, options: HostClipboardOperationOptions())
    }

    func clear() async throws -> HostClipboardClearResult {
        try await clear(HostClipboardOperationOptions())
    }
}

/// User-facing configuration options for creating a `HostClipboardService`.
// parity: core/src/lib/clipboard.ts#HostClipboardOptions [status=implemented hash=43a7b92c914c]
public struct HostClipboardOptions: Equatable, Hashable, Sendable {
    public var timeoutMs: Int?
    public var maxReadBytes: Int?
    public var maxWriteBytes: Int?
    public var maxImagePixels: Int?
    public var maxConversionBytes: Int?
    public var maxConcurrentOperations: Int?
    public var maxProviderTransfers: Int?
    public var waylandSeat: String?

    public init(
        timeoutMs: Int? = nil,
        maxReadBytes: Int? = nil,
        maxWriteBytes: Int? = nil,
        maxImagePixels: Int? = nil,
        maxConversionBytes: Int? = nil,
        maxConcurrentOperations: Int? = nil,
        maxProviderTransfers: Int? = nil,
        waylandSeat: String? = nil
    ) {
        self.timeoutMs = timeoutMs
        self.maxReadBytes = maxReadBytes
        self.maxWriteBytes = maxWriteBytes
        self.maxImagePixels = maxImagePixels
        self.maxConversionBytes = maxConversionBytes
        self.maxConcurrentOperations = maxConcurrentOperations
        self.maxProviderTransfers = maxProviderTransfers
        self.waylandSeat = waylandSeat
    }
}

/// Validated, defaulted configuration passed to a `HostClipboardBackendFactory`.
// parity: core/src/lib/host-clipboard.internal.ts#NormalizedHostClipboardOptions [status=implemented hash=45b00d61b7b9]
public struct NormalizedHostClipboardOptions: Equatable, Hashable, Sendable {
    public let timeoutMs: UInt32
    public let maxReadBytes: UInt32
    public let maxWriteBytes: UInt32
    public let maxImagePixels: UInt32
    public let maxConversionBytes: UInt32
    public let maxConcurrentOperations: UInt32
    public let maxProviderTransfers: UInt32
    public let waylandSeat: String?

    public init(
        timeoutMs: UInt32 = defaultClipboardTimeoutMs,
        maxReadBytes: UInt32 = defaultClipboardMaxBytes,
        maxWriteBytes: UInt32 = defaultClipboardMaxBytes,
        maxImagePixels: UInt32 = defaultClipboardMaxImagePixels,
        maxConversionBytes: UInt32 = defaultClipboardMaxConversionBytes,
        maxConcurrentOperations: UInt32 = defaultClipboardMaxConcurrentOperations,
        maxProviderTransfers: UInt32 = defaultClipboardMaxProviderTransfers,
        waylandSeat: String? = nil
    ) {
        self.timeoutMs = timeoutMs
        self.maxReadBytes = maxReadBytes
        self.maxWriteBytes = maxWriteBytes
        self.maxImagePixels = maxImagePixels
        self.maxConversionBytes = maxConversionBytes
        self.maxConcurrentOperations = maxConcurrentOperations
        self.maxProviderTransfers = maxProviderTransfers
        self.waylandSeat = waylandSeat
    }
}

/// Factory closure creating a `HostClipboardBackend` from normalized options.
// parity: core/src/lib/host-clipboard.internal.ts#HostClipboardBackendFactory [status=implemented hash=a7433931248d]
public typealias HostClipboardBackendFactory =
    @Sendable (NormalizedHostClipboardOptions) throws -> any HostClipboardBackend

/// Dependencies required to construct a composed `ClipboardService`.
// parity: core/src/lib/clipboard.ts#ClipboardOptions [status=implemented hash=6aae4777d9d3]
public struct ClipboardOptions: Sendable {
    public let host: any HostClipboardService
    public let terminal: any TerminalClipboardAdapter

    public init(host: any HostClipboardService, terminal: any TerminalClipboardAdapter) {
        self.host = host
        self.terminal = terminal
    }
}

// MARK: - Option Normalization

private func normalizeHostClipboardOptions(_ options: HostClipboardOptions) throws(HostClipboardError) -> NormalizedHostClipboardOptions {
    if let seat = options.waylandSeat {
        if seat.isEmpty || seat.utf8.contains(0) {
            throw .typeError("waylandSeat must be a non-empty string without NUL characters")
        }
    }
    return NormalizedHostClipboardOptions(
        timeoutMs: try validateU32Option("timeoutMs", options.timeoutMs ?? Int(defaultClipboardTimeoutMs)),
        maxReadBytes: try validateU32Option("maxReadBytes", options.maxReadBytes ?? Int(defaultClipboardMaxBytes)),
        maxWriteBytes: try validateU32Option("maxWriteBytes", options.maxWriteBytes ?? Int(defaultClipboardMaxBytes)),
        maxImagePixels: try validateU32Option("maxImagePixels", options.maxImagePixels ?? Int(defaultClipboardMaxImagePixels)),
        maxConversionBytes: try validateU32Option(
            "maxConversionBytes",
            options.maxConversionBytes ?? Int(defaultClipboardMaxConversionBytes)
        ),
        maxConcurrentOperations: try validatePositiveU32Option(
            "maxConcurrentOperations",
            options.maxConcurrentOperations ?? Int(defaultClipboardMaxConcurrentOperations)
        ),
        maxProviderTransfers: try validatePositiveU32Option(
            "maxProviderTransfers",
            options.maxProviderTransfers ?? Int(defaultClipboardMaxProviderTransfers)
        ),
        waylandSeat: options.waylandSeat
    )
}

// MARK: - HostClipboardService Implementation

private final class DefaultHostClipboardService: HostClipboardService, Sendable {
    private struct LifecycleState: Sendable {
        var disposed: Bool = false
        var disposeTask: Task<Void, Error>? = nil
    }

    private let config: NormalizedHostClipboardOptions
    private let backend: any HostClipboardBackend
    private let active = ActiveClipboardOperationSet()
    private let lifecycle = Mutex(LifecycleState())

    init(config: NormalizedHostClipboardOptions, backend: any HostClipboardBackend) {
        self.config = config
        self.backend = backend
    }

    var maxWriteBytes: Int {
        Int(config.maxWriteBytes)
    }

    private func assertUsable() throws(HostClipboardError) {
        let isDisposed = lifecycle.withLock { $0.disposed }
        if isDisposed {
            throw .disposed("Host clipboard service is disposed")
        }
    }

    func read(_ options: ClipboardReadOptions) async throws -> ClipboardReadResult {
        try assertUsable()
        let preferredTypes = try normalizePreferredTypes(options.preferredTypes)
        let selection = options.selection ?? .clipboard
        if options.signal?.isAborted == true {
            return .cancelled
        }
        if config.timeoutMs == 0 {
            return .timedOut
        }
        let maxRead = Int(config.maxReadBytes)
        let timeout = Int(config.timeoutMs)
        let backendRef = self.backend
        return try await runTrackedOperation(active: active, callerSignal: options.signal) { signal in
            let result = try await backendRef.read(
                HostClipboardReadOptions(
                    preferredTypes: preferredTypes,
                    selection: selection,
                    maxBytes: maxRead,
                    timeoutMs: timeout,
                    signal: signal
                )
            )
            if case .read(let representation) = result {
                if representation.bytes.count > maxRead {
                    return .limitExceeded
                }
                return .read(representation)
            }
            return result
        }
    }

    func writeText(_ text: String, options: HostClipboardOperationOptions) async throws -> HostClipboardWriteResult {
        try assertUsable()
        try validateClipboardText(text, maxWriteBytes: Int(config.maxWriteBytes))
        let selection = options.selection ?? .clipboard
        if options.signal?.isAborted == true {
            return .cancelled
        }
        if config.timeoutMs == 0 {
            return .timedOut
        }
        let timeout = Int(config.timeoutMs)
        let backendRef = self.backend
        return try await runTrackedOperation(active: active, callerSignal: options.signal) { signal in
            try await backendRef.writeText(
                text,
                options: HostClipboardWriteOptions(selection: selection, timeoutMs: timeout, signal: signal)
            )
        }
    }

    func clear(_ options: HostClipboardOperationOptions) async throws -> HostClipboardClearResult {
        try assertUsable()
        let selection = options.selection ?? .clipboard
        if options.signal?.isAborted == true {
            return .cancelled
        }
        if config.timeoutMs == 0 {
            return .timedOut
        }
        let timeout = Int(config.timeoutMs)
        let backendRef = self.backend
        return try await runTrackedOperation(active: active, callerSignal: options.signal) { signal in
            try await backendRef.clear(
                HostClipboardWriteOptions(selection: selection, timeoutMs: timeout, signal: signal)
            )
        }
    }

    func dispose() async throws {
        let task: Task<Void, Error> = lifecycle.withLock { state in
            if let existing = state.disposeTask {
                return existing
            }
            state.disposed = true
            let activeOps = self.active
            let backendRef = self.backend
            let created = Task {
                activeOps.abortAll(reason: "Host clipboard service is disposed")
                await activeOps.waitAllSettled()
                try await backendRef.dispose()
            }
            state.disposeTask = created
            return created
        }
        try await task.value
    }
}

/// Creates a `HostClipboardService` backed by a custom `HostClipboardBackendFactory`.
// parity: core/src/lib/host-clipboard.internal.ts#createHostClipboardWithBackend [status=implemented hash=064f32418599]
public func createHostClipboardWithBackend(
    options: HostClipboardOptions = HostClipboardOptions(),
    createBackend: HostClipboardBackendFactory
) throws -> any HostClipboardService {
    let normalized = try normalizeHostClipboardOptions(options)
    let backend = try createBackend(normalized)
    return DefaultHostClipboardService(config: normalized, backend: backend)
}

// MARK: - In-Memory & Injectable Native Host Clipboard Backend

/// Pure-Swift in-memory `HostClipboardBackend` supporting arbitrary MIME representations per selection,
/// preference-order matching, byte limits, cooperative cancellation, and optional fault/delay hooks.
public final class InMemoryHostClipboardBackend: HostClipboardBackend, Sendable {
    private struct State: Sendable {
        var representations: [ClipboardSelection: [String: [UInt8]]] = [:]
        var disposed: Bool = false
        var supported: Bool = true
        var failWith: ClipboardFailure? = nil
    }

    private let state: Mutex<State>
    private let operationHook: (@Sendable (String, ClipboardSelection, ClipboardAbortSignal) async -> Void)?

    public init(
        supported: Bool = true,
        initialRepresentations: [ClipboardSelection: [ClipboardRepresentation]] = [:],
        operationHook: (@Sendable (String, ClipboardSelection, ClipboardAbortSignal) async -> Void)? = nil
    ) {
        var initial = State()
        initial.supported = supported
        for (selection, reps) in initialRepresentations {
            var map: [String: [UInt8]] = [:]
            for rep in reps {
                map[rep.mimeType.lowercased()] = rep.bytes
            }
            initial.representations[selection] = map
        }
        self.state = Mutex(initial)
        self.operationHook = operationHook
    }

    public var isDisposed: Bool {
        state.withLock { $0.disposed }
    }

    public func setSupported(_ supported: Bool) {
        state.withLock { $0.supported = supported }
    }

    public func setFailure(_ failure: ClipboardFailure?) {
        state.withLock { $0.failWith = failure }
    }

    /// Seeds or replaces a MIME representation directly in the in-memory store.
    public func setRepresentation(_ representation: ClipboardRepresentation, selection: ClipboardSelection = .clipboard) {
        state.withLock { s in
            s.representations[selection, default: [:]][representation.mimeType.lowercased()] = representation.bytes
        }
    }

    /// Reads the raw stored bytes for a MIME type without invoking clipboard policy checks.
    public func storedRepresentation(
        mimeType: String,
        selection: ClipboardSelection = .clipboard
    ) -> ClipboardRepresentation? {
        let lower = mimeType.lowercased()
        return state.withLock { s in
            guard let bytes = s.representations[selection]?[lower] else { return nil }
            return ClipboardRepresentation(mimeType: lower, bytes: bytes)
        }
    }

    public func read(_ options: HostClipboardReadOptions) async throws -> ClipboardReadResult {
        if let hook = operationHook {
            await hook("read", options.selection, options.signal)
        }
        if options.signal.isAborted {
            return .cancelled
        }
        return try state.withLock { s throws -> ClipboardReadResult in
            if s.disposed {
                throw HostClipboardError.disposed("InMemoryHostClipboardBackend is disposed")
            }
            if let failure = s.failWith {
                return .failed(failure)
            }
            if !s.supported {
                return .unsupported
            }
            guard let selectionMap = s.representations[options.selection], !selectionMap.isEmpty else {
                return .empty
            }
            for preferred in options.preferredTypes {
                let canonical = preferred.lowercased()
                if let bytes = selectionMap[canonical] {
                    if bytes.count > options.maxBytes {
                        return .limitExceeded
                    }
                    return .read(ClipboardRepresentation(mimeType: canonical, bytes: bytes))
                }
            }
            return .empty
        }
    }

    public func writeText(_ text: String, options: HostClipboardWriteOptions) async throws -> HostClipboardWriteResult {
        if let hook = operationHook {
            await hook("write", options.selection, options.signal)
        }
        if options.signal.isAborted {
            return .cancelled
        }
        return try state.withLock { s throws -> HostClipboardWriteResult in
            if s.disposed {
                throw HostClipboardError.disposed("InMemoryHostClipboardBackend is disposed")
            }
            if let failure = s.failWith {
                return .failed(failure)
            }
            if !s.supported {
                return .unsupported
            }
            s.representations[options.selection] = ["text/plain": Array(text.utf8)]
            return .written
        }
    }

    public func clear(_ options: HostClipboardWriteOptions) async throws -> HostClipboardClearResult {
        if let hook = operationHook {
            await hook("clear", options.selection, options.signal)
        }
        if options.signal.isAborted {
            return .cancelled
        }
        return try state.withLock { s throws -> HostClipboardClearResult in
            if s.disposed {
                throw HostClipboardError.disposed("InMemoryHostClipboardBackend is disposed")
            }
            if let failure = s.failWith {
                return .failed(failure)
            }
            if !s.supported {
                return .unsupported
            }
            s.representations.removeValue(forKey: options.selection)
            return .cleared
        }
    }

    public func dispose() async throws {
        state.withLock { s in
            s.disposed = true
            s.representations.removeAll()
        }
    }
}

/// Process-wide injectable registry allowing platform targets (e.g. `OpenTUITerminal`) to supply
/// a native OS clipboard backend while keeping `OpenTUICore` 100% pure Swift.
public enum NativeHostClipboardBackendRegistry {
    private static let registeredFactory = Mutex<HostClipboardBackendFactory?>(nil)

    /// Registers a platform-provided backend factory used by `createNativeHostClipboardBackend`.
    public static func register(_ factory: HostClipboardBackendFactory?) {
        registeredFactory.withLock { $0 = factory }
    }

    /// Returns the currently registered factory, if any.
    public static func currentFactory() -> HostClipboardBackendFactory? {
        registeredFactory.withLock { $0 }
    }
}

/// Creates the native host clipboard backend by delegating to `NativeHostClipboardBackendRegistry`
/// when a platform backend is registered, or falling back to a pure-Swift `InMemoryHostClipboardBackend`.
// parity: core/src/lib/host-clipboard.native.ts#createNativeHostClipboardBackend [status=adapted hash=3a8aa58aa98b]
public func createNativeHostClipboardBackend(_ options: NormalizedHostClipboardOptions) throws -> any HostClipboardBackend {
    if let factory = NativeHostClipboardBackendRegistry.currentFactory() {
        return try factory(options)
    }
    return InMemoryHostClipboardBackend()
}

/// Creates a `HostClipboardService` using the registered native host clipboard backend factory.
// parity: core/src/lib/clipboard.ts#createHostClipboard [status=implemented hash=856d9d79d743]
public func createHostClipboard(_ options: HostClipboardOptions = HostClipboardOptions()) throws -> any HostClipboardService {
    try createHostClipboardWithBackend(options: options, createBackend: createNativeHostClipboardBackend)
}

// MARK: - Composed ClipboardService (`core/src/lib/clipboard.ts#createClipboard`)

private final class ComposedClipboardService: ClipboardService, Sendable {
    private enum TerminalDecision: Sendable {
        case pending
        case none
        case write(@Sendable () -> TerminalClipboardOperationResult)
    }

    private final class NewestOperation: @unchecked Sendable {
        var decision: TerminalDecision

        init(_ decision: TerminalDecision) {
            self.decision = decision
        }
    }

    private final class PendingSelection: @unchecked Sendable {
        var count: Int = 0
        var newest: NewestOperation
        var sent: TerminalClipboardOperationResult? = nil

        init(newest: NewestOperation) {
            self.newest = newest
        }
    }

    private struct State: @unchecked Sendable {
        var disposed: Bool = false
        var disposeTask: Task<Void, Error>? = nil
        var inFlight: [ClipboardSelection: PendingSelection] = [:]
    }

    private let host: any HostClipboardService
    private let terminal: any TerminalClipboardAdapter
    private let active = ActiveClipboardOperationSet()
    private let state = Mutex(State())

    init(host: any HostClipboardService, terminal: any TerminalClipboardAdapter) {
        self.host = host
        self.terminal = terminal
    }

    private func assertUsable() throws(HostClipboardError) {
        let isDisposed = state.withLock { $0.disposed }
        if isDisposed {
            throw .disposed("Clipboard service is disposed")
        }
    }

    private func canUseRemoteHost(_ options: ClipboardWriteOptions) -> Bool {
        !terminal.remote || options.allowRemoteHost
    }

    private func replaceInFlight(selection: ClipboardSelection, newest: NewestOperation) -> PendingSelection? {
        state.withLock { s in
            if let pending = s.inFlight[selection] {
                pending.newest = newest
                pending.sent = nil
                return pending
            }
            return nil
        }
    }

    private func sendNewest(_ pending: PendingSelection) -> TerminalClipboardOperationResult {
        enum Action {
            case returnResult(TerminalClipboardOperationResult)
            case invoke(NewestOperation, @Sendable () -> TerminalClipboardOperationResult)
        }

        let action: Action = state.withLock { _ in
            let newest = pending.newest
            switch newest.decision {
            case .pending, .none:
                return .returnResult(notAttemptedTerminalResult)
            case .write(let fn):
                if let alreadySent = pending.sent {
                    return .returnResult(alreadySent)
                }
                return .invoke(newest, fn)
            }
        }

        switch action {
        case .returnResult(let result):
            return result
        case .invoke(let newest, let fn):
            let result = fn()
            state.withLock { _ in
                if pending.newest === newest && result.status == .attempted {
                    pending.sent = result
                }
            }
            return result
        }
    }

    private func composeWrite(
        options: ClipboardWriteOptions,
        signal: ClipboardAbortSignal,
        selection: ClipboardSelection,
        hostOperation: @escaping @Sendable () async throws -> HostClipboardWriteResult,
        terminalOperation: @escaping @Sendable () -> TerminalClipboardOperationResult
    ) async throws -> ClipboardWriteResult {
        let runTerminalNow: () -> ClipboardWriteResult = {
            let pending = self.replaceInFlight(selection: selection, newest: NewestOperation(.write(terminalOperation)))
            let terminalResult = pending.map { self.sendNewest($0) } ?? terminalOperation()
            return ClipboardWriteResult(host: .notAttempted, terminal: terminalResult)
        }

        switch options.destination {
        case .terminalOnly:
            return runTerminalNow()
        case .hostOnly:
            guard canUseRemoteHost(options) else {
                return ClipboardWriteResult(host: .notAttempted, terminal: notAttemptedTerminalResult)
            }
            _ = replaceInFlight(selection: selection, newest: NewestOperation(.none))
            let hostRes = try await hostOperation()
            return ClipboardWriteResult(host: ClipboardWriteHostOutcome(hostRes), terminal: notAttemptedTerminalResult)
        case .bestAvailable, .allAvailable:
            let bestAvailable = options.destination == .bestAvailable
            if bestAvailable ? terminal.remote : !canUseRemoteHost(options) {
                return runTerminalNow()
            }

            let newest = NewestOperation(bestAvailable ? .pending : .write(terminalOperation))
            let pending: PendingSelection = state.withLock { s in
                let p: PendingSelection
                if let existing = s.inFlight[selection] {
                    existing.newest = newest
                    existing.sent = nil
                    p = existing
                } else {
                    p = PendingSelection(newest: newest)
                    s.inFlight[selection] = p
                }
                p.count += 1
                return p
            }

            var hostResult: HostClipboardWriteResult? = nil
            do {
                hostResult = try await hostOperation()
            } catch {
                finishInFlight(
                    selection: selection,
                    pending: pending,
                    newest: newest,
                    succeeded: false,
                    fallbackToTerminal: !signal.isAborted,
                    terminalOperation: terminalOperation
                )
                throw error
            }

            let succeeded = hostResult == .written
            let shouldFallback: Bool
            if let hostResult {
                switch hostResult {
                case .unsupported, .failed:
                    shouldFallback = !signal.isAborted
                case .written, .cancelled, .timedOut:
                    shouldFallback = false
                }
            } else {
                shouldFallback = false
            }

            let terminalResult = finishInFlight(
                selection: selection,
                pending: pending,
                newest: newest,
                succeeded: succeeded,
                fallbackToTerminal: shouldFallback,
                terminalOperation: terminalOperation
            )
            return ClipboardWriteResult(
                host: hostResult.map(ClipboardWriteHostOutcome.init) ?? .notAttempted,
                terminal: terminalResult
            )
        }
    }

    private func composeClear(
        options: ClipboardWriteOptions,
        signal: ClipboardAbortSignal,
        selection: ClipboardSelection,
        hostOperation: @escaping @Sendable () async throws -> HostClipboardClearResult,
        terminalOperation: @escaping @Sendable () -> TerminalClipboardOperationResult
    ) async throws -> ClipboardClearResult {
        let runTerminalNow: () -> ClipboardClearResult = {
            let pending = self.replaceInFlight(selection: selection, newest: NewestOperation(.write(terminalOperation)))
            let terminalResult = pending.map { self.sendNewest($0) } ?? terminalOperation()
            return ClipboardClearResult(host: .notAttempted, terminal: terminalResult)
        }

        switch options.destination {
        case .terminalOnly:
            return runTerminalNow()
        case .hostOnly:
            guard canUseRemoteHost(options) else {
                return ClipboardClearResult(host: .notAttempted, terminal: notAttemptedTerminalResult)
            }
            _ = replaceInFlight(selection: selection, newest: NewestOperation(.none))
            let hostRes = try await hostOperation()
            return ClipboardClearResult(host: ClipboardClearHostOutcome(hostRes), terminal: notAttemptedTerminalResult)
        case .bestAvailable, .allAvailable:
            let bestAvailable = options.destination == .bestAvailable
            if bestAvailable ? terminal.remote : !canUseRemoteHost(options) {
                return runTerminalNow()
            }

            let newest = NewestOperation(bestAvailable ? .pending : .write(terminalOperation))
            let pending: PendingSelection = state.withLock { s in
                let p: PendingSelection
                if let existing = s.inFlight[selection] {
                    existing.newest = newest
                    existing.sent = nil
                    p = existing
                } else {
                    p = PendingSelection(newest: newest)
                    s.inFlight[selection] = p
                }
                p.count += 1
                return p
            }

            var hostResult: HostClipboardClearResult? = nil
            do {
                hostResult = try await hostOperation()
            } catch {
                finishInFlight(
                    selection: selection,
                    pending: pending,
                    newest: newest,
                    succeeded: false,
                    fallbackToTerminal: !signal.isAborted,
                    terminalOperation: terminalOperation
                )
                throw error
            }

            let succeeded = hostResult == .cleared
            let shouldFallback: Bool
            if let hostResult {
                switch hostResult {
                case .unsupported, .failed:
                    shouldFallback = !signal.isAborted
                case .cleared, .cancelled, .timedOut:
                    shouldFallback = false
                }
            } else {
                shouldFallback = false
            }

            let terminalResult = finishInFlight(
                selection: selection,
                pending: pending,
                newest: newest,
                succeeded: succeeded,
                fallbackToTerminal: shouldFallback,
                terminalOperation: terminalOperation
            )
            return ClipboardClearResult(
                host: hostResult.map(ClipboardClearHostOutcome.init) ?? .notAttempted,
                terminal: terminalResult
            )
        }
    }

    @discardableResult
    private func finishInFlight(
        selection: ClipboardSelection,
        pending: PendingSelection,
        newest: NewestOperation,
        succeeded: Bool,
        fallbackToTerminal: Bool,
        terminalOperation: @escaping @Sendable () -> TerminalClipboardOperationResult
    ) -> TerminalClipboardOperationResult {
        state.withLock { s in
            pending.count -= 1
            if pending.count <= 0 {
                s.inFlight.removeValue(forKey: selection)
            }
            if succeeded {
                pending.sent = nil
            }
            if case .pending = newest.decision {
                newest.decision = fallbackToTerminal ? .write(terminalOperation) : .none
            }
        }
        return sendNewest(pending)
    }

    func read(_ options: ClipboardReadOptions) async throws -> ClipboardReadResult {
        try assertUsable()
        return try await host.read(options)
    }

    func writeText(_ text: String, options: ClipboardWriteOptions) async throws -> ClipboardWriteResult {
        try assertUsable()
        try validateClipboardText(text, maxWriteBytes: host.maxWriteBytes)
        let selection = options.selection ?? .clipboard
        if options.signal?.isAborted == true {
            return ClipboardWriteResult(host: .notAttempted, terminal: notAttemptedTerminalResult)
        }
        let hostRef = self.host
        let terminalRef = self.terminal
        return try await runTrackedOperation(active: active, callerSignal: options.signal) { signal in
            try await self.composeWrite(
                options: options,
                signal: signal,
                selection: selection,
                hostOperation: {
                    try await hostRef.writeText(
                        text,
                        options: HostClipboardOperationOptions(selection: selection, signal: signal)
                    )
                },
                terminalOperation: {
                    terminalRef.writeText(text, selection: selection)
                }
            )
        }
    }

    func clear(_ options: ClipboardWriteOptions) async throws -> ClipboardClearResult {
        try assertUsable()
        let selection = options.selection ?? .clipboard
        if options.signal?.isAborted == true {
            return ClipboardClearResult(host: .notAttempted, terminal: notAttemptedTerminalResult)
        }
        let hostRef = self.host
        let terminalRef = self.terminal
        return try await runTrackedOperation(active: active, callerSignal: options.signal) { signal in
            try await self.composeClear(
                options: options,
                signal: signal,
                selection: selection,
                hostOperation: {
                    try await hostRef.clear(
                        HostClipboardOperationOptions(selection: selection, signal: signal)
                    )
                },
                terminalOperation: {
                    terminalRef.clear(selection: selection)
                }
            )
        }
    }

    func dispose() async throws {
        let task: Task<Void, Error> = state.withLock { s in
            if let existing = s.disposeTask {
                return existing
            }
            s.disposed = true
            let activeOps = self.active
            let hostRef = self.host
            let created = Task {
                activeOps.abortAll(reason: "Clipboard service is disposed")
                await activeOps.waitAllSettled()
                try await hostRef.dispose()
            }
            s.disposeTask = created
            return created
        }
        try await task.value
    }
}

/// Creates a composed `ClipboardService` uniting a `HostClipboardService` and a `TerminalClipboardAdapter`.
// parity: core/src/lib/clipboard.ts#createClipboard [status=implemented hash=a75318d30634]
public func createClipboard(_ options: ClipboardOptions) -> any ClipboardService {
    ComposedClipboardService(host: options.host, terminal: options.terminal)
}
