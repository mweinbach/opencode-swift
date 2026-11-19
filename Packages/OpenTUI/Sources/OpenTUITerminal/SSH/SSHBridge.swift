import OpenTUICore
import Synchronization

// MARK: - Constants & PTY Helpers

/// Renderer factory; injectable for renderer creation and disconnect-race tests.
// parity: ssh/src/bridge.ts#RendererFactory [status=implemented hash=df9ae970f099]
public typealias SSHRendererFactory = @Sendable (SSHRendererCreateOptions) async throws -> any SSHAttachableRenderer

/// PTY parameters from the client's `pty-req`; the renderer sizes off `cols`/`rows`.
// parity: ssh/src/bridge.ts#PtyInfo [status=implemented hash=8aca5a5ab2ce]
public struct SSHPtyInfo: Equatable, Hashable, Sendable {
    public var term: String
    public var cols: Double
    public var rows: Double
    public var hasPty: Bool

    public init(term: String, cols: Double, rows: Double, hasPty: Bool) {
        self.term = term
        self.cols = cols
        self.rows = rows
        self.hasPty = hasPty
    }

    public init(term: String, cols: Int, rows: Int, hasPty: Bool) {
        self.term = term
        self.cols = Double(cols)
        self.rows = Double(rows)
        self.hasPty = hasPty
    }
}

/// Default PTY parameters used when the client omits a `pty-req` or sends empty `TERM`.
// parity: ssh/src/bridge.ts#DEFAULT_PTY [status=implemented hash=53458a00f89f]
public let sshDefaultPty = SSHPtyInfo(term: "xterm-256color", cols: 80, rows: 24, hasPty: false)

/// Upper bounds for client-requested PTY dimensions.
// parity: ssh/src/bridge.ts#MAX_PTY [status=implemented hash=0a45d26e50a8]
public let sshMaxPty: (cols: Int, rows: Int) = (cols: 500, rows: 200)

/// Bounds `TERM` and each client `env` value in UTF-8 bytes.
// parity: ssh/src/bridge.ts#CLIENT_ENV_VALUE_BYTES_MAX [status=implemented hash=4962889c2ee6]
public let sshClientEnvValueBytesMax: Int = 256

/// Default maximum single-write and bounded output queue capacity in bytes
/// (matches upstream `NativeSession`'s 8,323,072-byte atomic output budget).
public let sshDefaultMaxOutputBufferBytes: Int = 8_323_072

/// Default stdin buffer high-water mark before applying `channel.pause()`.
public let sshDefaultStdinHighWaterMark: Int = 16_384

/// Native rejects a whole environment that holds a NUL or exceeds its UTF-8 byte limit.
// parity: ssh/src/bridge.ts#isClientEnvValue [status=implemented hash=3f5d305c2af2]
public func isClientEnvValue(_ value: String) -> Bool {
    let utf8 = value.utf8
    return utf8.count <= sshClientEnvValueBytesMax && !utf8.contains(0)
}

internal func clampPtyDimension(_ value: Double, fallback: Int, max maxValue: Int) -> Int {
    guard value.isFinite, value > 0 else { return fallback }
    let floored = value.rounded(.towardZero)
    guard floored >= 1 else { return fallback }
    if floored >= Double(maxValue) { return maxValue }
    return Int(floored)
}

private struct NormalizedPtyInfo: Equatable, Sendable {
    let term: String
    let cols: Int
    let rows: Int
    let hasPty: Bool
}

private func normalizePtyInfo(_ pty: SSHPtyInfo) -> NormalizedPtyInfo {
    NormalizedPtyInfo(
        term: pty.term.isEmpty ? sshDefaultPty.term : pty.term,
        cols: clampPtyDimension(pty.cols, fallback: Int(sshDefaultPty.cols), max: sshMaxPty.cols),
        rows: clampPtyDimension(pty.rows, fallback: Int(sshDefaultPty.rows), max: sshMaxPty.rows),
        hasPty: pty.hasPty
    )
}

// MARK: - TerminalBackend Adapter & Default Headless Renderer

/// `TerminalBackend` adapter backed directly by an SSH session channel and its
/// bounded output queue. Allows any SSH session to drive `TerminalBackend`
/// consumers immediately (and allows Wave 3B `CliRenderer` to attach cleanly).
public actor SSHTerminalBackend: TerminalBackend {
    private var currentSize: TerminalSize
    public private(set) var isRawMode: Bool = false
    private let writeHandler: @Sendable ([UInt8]) throws -> Void

    public init(
        size: TerminalSize = TerminalSize(width: 80, height: 24),
        writeHandler: @escaping @Sendable ([UInt8]) throws -> Void
    ) {
        self.currentSize = size
        self.writeHandler = writeHandler
    }

    public var size: TerminalSize {
        currentSize
    }

    public func updateSize(_ newSize: TerminalSize) {
        self.currentSize = newSize
    }

    public func write(_ bytes: [UInt8]) async throws {
        try writeHandler(bytes)
    }

    public func enterRawMode() async throws {
        isRawMode = true
    }

    public func exitRawMode() async throws {
        isRawMode = false
    }
}

/// Default `SSHAttachableRenderer` used when no custom `SSHRendererFactory` is
/// supplied. Bridges SSH stdin through `OpenTUICore.StdinParser`, coalesces
/// resize requests, and writes through `SSHTerminalBackend`.
public final class SSHHeadlessRenderer: SSHAttachableRenderer, @unchecked Sendable {
    private struct State: Sendable {
        var width: Int
        var height: Int
        var destroyed: Bool = false
        var nextListenerID: UInt64 = 1
        var resizeListeners: [UInt64: @Sendable (Int, Int) -> Void] = [:]
        var destroyListeners: [UInt64: @Sendable () -> Void] = [:]
        var keyListeners: [UInt64: @Sendable (StdinEvent) -> Void] = [:]
        var receivedInput: [[UInt8]] = []
        var stdinParser: StdinParser = StdinParser()
        var closeContinuations: [CheckedContinuation<Void, any Error>] = []
    }

    public let backend: SSHTerminalBackend
    public let environment: [String: String]
    private let state: Mutex<State>

    public init(options: SSHRendererCreateOptions) {
        self.backend = options.backend
        self.environment = options.environment
        self.state = Mutex(State(width: options.width, height: options.height))
    }

    public var width: Int {
        state.withLock { $0.width }
    }

    public var height: Int {
        state.withLock { $0.height }
    }

    public var isDestroyed: Bool {
        state.withLock { $0.destroyed }
    }

    public var receivedInputBytes: [UInt8] {
        state.withLock { $0.receivedInput.flatMap { $0 } }
    }

    @discardableResult
    public func onStdinEvent(_ listener: @escaping @Sendable (StdinEvent) -> Void) -> @Sendable () -> Void {
        let id = state.withLock { s -> UInt64 in
            let id = s.nextListenerID
            s.nextListenerID &+= 1
            s.keyListeners[id] = listener
            return id
        }
        return { [weak self] in
            _ = self?.state.withLock { $0.keyListeners.removeValue(forKey: id) }
        }
    }

    public func feedInput(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        let (events, listeners) = state.withLock { s -> ([StdinEvent], [@Sendable (StdinEvent) -> Void]) in
            if s.destroyed { return ([], []) }
            s.receivedInput.append(bytes)
            s.stdinParser.push(bytes)
            var drained: [StdinEvent] = []
            s.stdinParser.drain { drained.append($0) }
            return (drained, Array(s.keyListeners.values))
        }
        for event in events {
            for listener in listeners {
                listener(event)
            }
        }
    }

    public func requestResize(cols: Int, rows: Int) {
        let listeners: [@Sendable (Int, Int) -> Void]? = state.withLock { s in
            if s.destroyed { return nil }
            if s.width == cols && s.height == rows { return nil }
            s.width = cols
            s.height = rows
            return Array(s.resizeListeners.values)
        }
        if let listeners {
            Task { await backend.updateSize(TerminalSize(width: cols, height: rows)) }
            for listener in listeners {
                listener(cols, rows)
            }
        }
    }

    @discardableResult
    public func onResize(_ listener: @escaping @Sendable (Int, Int) -> Void) -> @Sendable () -> Void {
        let id = state.withLock { s -> UInt64? in
            if s.destroyed { return nil }
            let id = s.nextListenerID
            s.nextListenerID &+= 1
            s.resizeListeners[id] = listener
            return id
        }
        guard let id else { return {} }
        return { [weak self] in
            _ = self?.state.withLock { $0.resizeListeners.removeValue(forKey: id) }
        }
    }

    @discardableResult
    public func onDestroy(_ listener: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        let id = state.withLock { s -> UInt64? in
            if s.destroyed { return nil }
            let id = s.nextListenerID
            s.nextListenerID &+= 1
            s.destroyListeners[id] = listener
            return id
        }
        guard let id else { return {} }
        return { [weak self] in
            _ = self?.state.withLock { $0.destroyListeners.removeValue(forKey: id) }
        }
    }

    public func destroy() {
        let (listeners, continuations) = state.withLock {
            s -> ([@Sendable () -> Void], [CheckedContinuation<Void, any Error>]) in
            if s.destroyed { return ([], []) }
            s.destroyed = true
            let destroyCallbacks = Array(s.destroyListeners.values)
            s.destroyListeners.removeAll()
            s.resizeListeners.removeAll()
            s.keyListeners.removeAll()
            let pending = s.closeContinuations
            s.closeContinuations.removeAll()
            return (destroyCallbacks, pending)
        }
        for listener in listeners {
            listener()
        }
        for continuation in continuations {
            continuation.resume()
        }
    }

    public func waitForClose() async throws {
        let alreadyDestroyed = state.withLock { $0.destroyed }
        if alreadyDestroyed { return }
        try await withCheckedThrowingContinuation { continuation in
            let resumeNow = state.withLock { s -> Bool in
                if s.destroyed { return true }
                s.closeContinuations.append(continuation)
                return false
            }
            if resumeNow {
                continuation.resume()
            }
        }
    }
}

// MARK: - Session Bridge Protocol & Options

/// Wired-up OpenTUI session bridge over a single SSH shell channel.
// parity: ssh/src/bridge.ts#SessionBridge [status=implemented hash=d79761590d65]
public protocol SSHSessionBridge: AnyObject, Sendable {
    /// One runtime object exposed through middleware and handler session views.
    var session: any SSHSession & SSHMiddlewareSession { get }
    /// True once the session has closed (disconnect, `end()`, `deny()`, or timeout).
    var closed: Bool { get }
    /// Effective environment forwarded to the renderer (TERM + accepted client env vars when `hasPty`).
    var environment: [String: String] { get }
    /// Attach the renderer after middleware authorizes, run the handler, and
    /// resolve when the session closes.
    func enterApp(_ handler: @escaping SSHSessionHandler) async throws
    /// Forward an SSH `window-change` event (clamped and coalesced).
    func resize(cols: Double, rows: Double)
    /// Convenience integer overload for `resize(cols:rows:)`.
    func resize(cols: Int, rows: Int)
    /// Idempotent graceful teardown: destroys renderer, drains/closes channel, fires `onClose`.
    func destroy() async
    /// Cancel a lost connection without writing to a dead peer channel.
    func disconnect() async
}

public extension SSHSessionBridge {
    func resize(cols: Int, rows: Int) {
        resize(cols: Double(cols), rows: Double(rows))
    }
}

/// Configuration for `createSessionBridge(channel:options:)`.
// parity: ssh/src/bridge.ts#SessionBridgeOptions [status=implemented hash=4669b77ab717]
public struct SSHSessionBridgeOptions: Sendable {
    public var pty: SSHPtyInfo
    /// Accepted client `env` request values; passed to the renderer alongside `TERM` when `hasPty` is true.
    public var env: [String: String]
    public var identity: SSHIdentity
    public var idleTimeoutMs: Int?
    public var maxTimeoutMs: Int?
    public var safe: SSHSafeInvoke
    /// Injectable renderer factory; defaults to `SSHHeadlessRenderer`.
    public var createRenderer: SSHRendererFactory?
    public var remoteAddress: SSHRemoteAddress
    /// Maximum bounded output buffer / atomic write limit in bytes.
    public var maxOutputBufferBytes: Int
    /// Stdin buffer high-water mark before pausing the SSH channel.
    public var stdinHighWaterMark: Int

    public init(
        pty: SSHPtyInfo = sshDefaultPty,
        env: [String: String] = [:],
        identity: SSHIdentity,
        idleTimeoutMs: Int? = nil,
        maxTimeoutMs: Int? = nil,
        safe: SSHSafeInvoke = createSafeInvoke { _ in },
        createRenderer: SSHRendererFactory? = nil,
        remoteAddress: SSHRemoteAddress = SSHRemoteAddress(address: "unknown"),
        maxOutputBufferBytes: Int = sshDefaultMaxOutputBufferBytes,
        stdinHighWaterMark: Int = sshDefaultStdinHighWaterMark
    ) {
        self.pty = pty
        self.env = env
        self.identity = identity
        self.idleTimeoutMs = idleTimeoutMs
        self.maxTimeoutMs = maxTimeoutMs
        self.safe = safe
        self.createRenderer = createRenderer
        self.remoteAddress = remoteAddress
        self.maxOutputBufferBytes = maxOutputBufferBytes
        self.stdinHighWaterMark = stdinHighWaterMark
    }
}

// MARK: - Default Session Bridge Implementation

private final class DefaultSSHSessionBridge: SSHSessionBridge, SSHSession, SSHMiddlewareSession, @unchecked Sendable {
    private struct OutputQueueState: Sendable {
        var waitingForDrain: Bool = false
        var inFlightBytes: Int = 0
        var queuedChunks: [[UInt8]] = []
        var queuedBytes: Int = 0
        var drainWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private struct BridgeState: Sendable {
        var cols: Int
        var rows: Int
        var closed: Bool = false
        var channelClosed: Bool = false
        var transportClosed: Bool = false
        var renderer: (any SSHAttachableRenderer)? = nil
        var creatingRenderer: Bool = false
        var nextListenerID: UInt64 = 1
        var resizeListeners: [UInt64: @Sendable (Int, Int) -> Void] = [:]
        var closeListeners: [UInt64: @Sendable () -> Void] = [:]
        var transportCloseWaiters: [CheckedContinuation<Void, Never>] = []
        var stdinQueue: [[UInt8]] = []
        var stdinBufferedBytes: Int = 0
        var inputPaused: Bool = false
        var idleTask: Task<Void, Never>? = nil
        var maxTask: Task<Void, Never>? = nil
        var output: OutputQueueState = OutputQueueState()
    }

    private let channel: any SSHChannel
    public let identity: SSHIdentity
    public let term: String
    public let hasPty: Bool
    public let remoteAddress: SSHRemoteAddress
    public let environment: [String: String]
    public let context: SSHContextBag = SSHContextBag()
    private let safe: SSHSafeInvoke
    private let rendererFactory: SSHRendererFactory
    private let idleTimeoutMs: Int?
    private let maxTimeoutMs: Int?
    private let maxOutputBufferBytes: Int
    private let stdinHighWaterMark: Int
    private let state: Mutex<BridgeState>
    private let fallbackBackend: SSHTerminalBackend

    var session: any SSHSession & SSHMiddlewareSession { self }

    var terminalBackend: SSHTerminalBackend { fallbackBackend }

    var closed: Bool {
        state.withLock { $0.closed }
    }

    var cols: Int {
        state.withLock { $0.cols }
    }

    var rows: Int {
        state.withLock { $0.rows }
    }

    var renderer: any SSHAttachableRenderer {
        guard let attached = state.withLock({ $0.renderer }) else {
            preconditionFailure(
                "@opentui/ssh: session.renderer is unavailable until the handler runs — a middleware must call next() before using it"
            )
        }
        return attached
    }

    init(channel: any SSHChannel, options: SSHSessionBridgeOptions) {
        self.channel = channel
        let initialPty = normalizePtyInfo(options.pty)
        self.identity = options.identity
        self.term = initialPty.term
        self.hasPty = initialPty.hasPty
        self.remoteAddress = options.remoteAddress
        if initialPty.hasPty && isClientEnvValue(initialPty.term) {
            var env = options.env
            env["TERM"] = initialPty.term
            self.environment = env
        } else {
            self.environment = [:]
        }
        self.safe = options.safe
        self.rendererFactory = options.createRenderer ?? { opts in
            SSHHeadlessRenderer(options: opts)
        }
        self.idleTimeoutMs = options.idleTimeoutMs
        self.maxTimeoutMs = options.maxTimeoutMs
        self.maxOutputBufferBytes = max(1, options.maxOutputBufferBytes)
        self.stdinHighWaterMark = max(1, options.stdinHighWaterMark)
        self.state = Mutex(BridgeState(cols: initialPty.cols, rows: initialPty.rows))

        // Wire SSHTerminalBackend through a late-bound closure referencing self weakly.
        var bridgeRef: DefaultSSHSessionBridge? = nil
        let box = Mutex<(@Sendable ([UInt8]) throws -> Void)?>(nil)
        self.fallbackBackend = SSHTerminalBackend(
            size: TerminalSize(width: initialPty.cols, height: initialPty.rows)
        ) { bytes in
            if let fn = box.withLock({ $0 }) {
                try fn(bytes)
            }
        }
        bridgeRef = self
        if let strongRef = bridgeRef {
            box.withLock { writer in
                writer = { [weak strongRef] bytes in
                    try strongRef?.write(bytes)
                }
            }
        }

        setupChannelHandlers()
        armTimers()
    }

    private func setupChannelHandlers() {
        channel.setDataHandler { [weak self] chunk in
            self?.handleIncomingData(chunk)
        }
        channel.setDrainHandler { [weak self] in
            self?.handleChannelDrain()
        }
        channel.setCloseHandler { [weak self] in
            self?.handleChannelClose()
        }
        channel.setErrorHandler { [weak self] error in
            self?.handleChannelError(error)
        }
    }

    private func armTimers() {
        if let idleTimeoutMs, idleTimeoutMs > 0 {
            resetIdleTimer()
        }
        if let maxTimeoutMs, maxTimeoutMs > 0 {
            let task = Task { [weak self] in
                do {
                    try await Task.sleep(for: .milliseconds(maxTimeoutMs))
                } catch {
                    return
                }
                await self?.destroy()
            }
            state.withLock { $0.maxTask = task }
        }
    }

    private func resetIdleTimer() {
        guard let idleTimeoutMs, idleTimeoutMs > 0 else { return }
        let oldTask = state.withLock { s -> Task<Void, Never>? in
            if s.closed { return nil }
            let previous = s.idleTask
            s.idleTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: .milliseconds(idleTimeoutMs))
                } catch {
                    return
                }
                await self?.destroy()
            }
            return previous
        }
        oldTask?.cancel()
    }

    private func handleIncomingData(_ chunk: [UInt8]) {
        guard !chunk.isEmpty else { return }
        resetIdleTimer()
        let (attachedRenderer, shouldPause) = state.withLock {
            s -> ((any SSHAttachableRenderer)?, Bool) in
            if s.closed { return (nil, false) }
            if let renderer = s.renderer {
                return (renderer, false)
            }
            s.stdinQueue.append(chunk)
            s.stdinBufferedBytes += chunk.count
            if s.stdinBufferedBytes >= stdinHighWaterMark && !s.inputPaused {
                s.inputPaused = true
                return (nil, true)
            }
            return (nil, false)
        }
        if let attachedRenderer {
            attachedRenderer.feedInput(chunk)
        } else if shouldPause {
            channel.pause()
        }
    }

    private func flushBufferedStdin(to renderer: any SSHAttachableRenderer) {
        let (chunks, shouldResume) = state.withLock { s -> ([[UInt8]], Bool) in
            let buffered = s.stdinQueue
            s.stdinQueue.removeAll()
            s.stdinBufferedBytes = 0
            let wasPaused = s.inputPaused
            s.inputPaused = false
            return (buffered, wasPaused)
        }
        for chunk in chunks {
            renderer.feedInput(chunk)
        }
        if shouldResume {
            channel.resume()
        }
    }

    private func handleChannelDrain() {
        while true {
            enum DrainStep {
                case writeChunk([UInt8])
                case drained([CheckedContinuation<Void, Never>])
            }
            let step = state.withLock { s -> DrainStep in
                s.output.inFlightBytes = 0
                if s.output.queuedChunks.isEmpty {
                    s.output.waitingForDrain = false
                    let waiters = s.output.drainWaiters
                    s.output.drainWaiters.removeAll()
                    return .drained(waiters)
                }
                let next = s.output.queuedChunks.removeFirst()
                s.output.queuedBytes -= next.count
                s.output.inFlightBytes = next.count
                return .writeChunk(next)
            }
            switch step {
            case .drained(let waiters):
                for waiter in waiters {
                    waiter.resume()
                }
                return
            case .writeChunk(let chunk):
                let ready = channel.write(chunk)
                if !ready {
                    // Still backpressured; wait for the next drain notification.
                    return
                }
            }
        }
    }

    private func waitForOutputDrain() async {
        let needsWait = state.withLock { s -> Bool in
            !s.channelClosed && (s.output.waitingForDrain || !s.output.queuedChunks.isEmpty)
        }
        guard needsWait else { return }
        await withCheckedContinuation { continuation in
            let resumeImmediately = state.withLock { s -> Bool in
                if s.channelClosed || (!s.output.waitingForDrain && s.output.queuedChunks.isEmpty) {
                    return true
                }
                s.output.drainWaiters.append(continuation)
                return false
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
    }

    private func handleChannelClose() {
        state.withLock { $0.channelClosed = true }
        channel.setCloseHandler(nil)
        channel.setErrorHandler(nil)
        Task { await self.destroy() }
    }

    private func handleChannelError(_ error: any Error) {
        state.withLock { $0.channelClosed = true }
        safe.report(error)
        Task { await self.destroy() }
    }

    // MARK: - SSHSessionCommon

    @discardableResult
    func onResize(_ callback: @escaping @Sendable (Int, Int) -> Void) -> @Sendable () -> Void {
        let id = state.withLock { s -> UInt64? in
            if s.closed { return nil }
            let id = s.nextListenerID
            s.nextListenerID &+= 1
            s.resizeListeners[id] = callback
            return id
        }
        guard let id else { return {} }
        return { [weak self] in
            _ = self?.state.withLock { $0.resizeListeners.removeValue(forKey: id) }
        }
    }

    @discardableResult
    func onClose(_ callback: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        let registration = state.withLock { s -> UInt64? in
            if s.closed { return nil }
            let id = s.nextListenerID
            s.nextListenerID &+= 1
            s.closeListeners[id] = callback
            return id
        }
        guard let id = registration else {
            // Late subscribers still get the close callback once.
            safe(callback)
            return {}
        }
        return { [weak self] in
            _ = self?.state.withLock { $0.closeListeners.removeValue(forKey: id) }
        }
    }

    func write(_ bytes: [UInt8]) throws {
        if state.withLock({ $0.closed }) { return }
        if bytes.count > maxOutputBufferBytes {
            throw SSHOutputCapacityError("raw write exceeds the native session output limit")
        }
        if bytes.isEmpty { return }

        enum Admission {
            case closed
            case pressure
            case queued
            case writeNow
        }

        let admission = state.withLock { s -> Admission in
            if s.closed { return .closed }
            let totalPending = s.output.inFlightBytes + s.output.queuedBytes
            if totalPending + bytes.count > maxOutputBufferBytes {
                return .pressure
            }
            if s.output.waitingForDrain || !s.output.queuedChunks.isEmpty {
                s.output.queuedChunks.append(bytes)
                s.output.queuedBytes += bytes.count
                return .queued
            }
            s.output.waitingForDrain = true
            s.output.inFlightBytes = bytes.count
            return .writeNow
        }

        switch admission {
        case .closed, .queued:
            return
        case .pressure:
            throw OutputPressureError()
        case .writeNow:
            let ready = channel.write(bytes)
            if ready {
                // Channel accepted immediately; drain any chunks queued concurrently while writing.
                handleChannelDrain()
            }
        }
    }

    func write(_ string: String) throws {
        if state.withLock({ $0.closed }) { return }
        // Bound UTF-8 check before allocating byte array.
        if string.utf8.count > maxOutputBufferBytes {
            throw SSHOutputCapacityError("raw write exceeds the native session output limit")
        }
        try write(Array(string.utf8))
    }

    func end() {
        Task { await self.destroy() }
    }

    func deny(_ reason: String?) throws -> Never {
        do {
            if let reason, !reason.isEmpty, !closed {
                if reason.utf8.count > maxOutputBufferBytes {
                    throw SSHOutputCapacityError("deny reason exceeds the native session output limit")
                }
                let formatted = reason.hasSuffix("\n") ? reason : "\(reason)\r\n"
                try write(formatted)
            }
        } catch {
            safe.report(error)
        }
        end()
        throw DenyError(reason)
    }

    // MARK: - Resize

    func resize(cols requestedCols: Double, rows requestedRows: Double) {
        let (targetCols, targetRows, attachedRenderer) = state.withLock {
            s -> (Int, Int, (any SSHAttachableRenderer)?) in
            if s.closed { return (s.cols, s.rows, nil) }
            let nextCols = clampPtyDimension(requestedCols, fallback: s.cols, max: sshMaxPty.cols)
            let nextRows = clampPtyDimension(requestedRows, fallback: s.rows, max: sshMaxPty.rows)
            if let renderer = s.renderer {
                return (nextCols, nextRows, renderer)
            }
            s.cols = nextCols
            s.rows = nextRows
            return (nextCols, nextRows, nil)
        }
        if let attachedRenderer {
            attachedRenderer.requestResize(cols: targetCols, rows: targetRows)
        } else {
            Task { await fallbackBackend.updateSize(TerminalSize(width: targetCols, height: targetRows)) }
        }
    }

    // MARK: - Renderer Attachment & App Execution

    private func attachRenderer() async throws -> (any SSHAttachableRenderer)? {
        let precheck = state.withLock {
            s -> (existing: (any SSHAttachableRenderer)?, closed: Bool, cols: Int, rows: Int) in
            if let existing = s.renderer { return (existing, s.closed, s.cols, s.rows) }
            if s.closed { return (nil, true, s.cols, s.rows) }
            s.creatingRenderer = true
            return (nil, false, s.cols, s.rows)
        }
        if let existing = precheck.existing { return existing }
        if precheck.closed { return nil }

        let options = SSHRendererCreateOptions(
            width: precheck.cols,
            height: precheck.rows,
            term: term,
            hasPty: hasPty,
            environment: environment,
            backend: fallbackBackend
        )
        let created: any SSHAttachableRenderer
        do {
            created = try await rendererFactory(options)
        } catch {
            state.withLock { $0.creatingRenderer = false }
            throw error
        }

        let attachResult = state.withLock { s -> (closed: Bool, requestedCols: Int, requestedRows: Int) in
            s.creatingRenderer = false
            if s.closed {
                return (true, s.cols, s.rows)
            }
            let reqCols = s.cols
            let reqRows = s.rows
            s.cols = created.width
            s.rows = created.height
            s.renderer = created
            return (false, reqCols, reqRows)
        }

        if attachResult.closed {
            ignoreErrors { created.destroy() }
            return nil
        }

        created.onResize { [weak self] width, height in
            guard let self else { return }
            let listeners = self.state.withLock { s -> [@Sendable (Int, Int) -> Void] in
                if s.closed { return [] }
                s.cols = width
                s.rows = height
                return Array(s.resizeListeners.values)
            }
            for listener in listeners {
                self.safe { listener(width, height) }
            }
        }
        created.onDestroy { [weak self] in
            Task { await self?.destroy() }
        }

        flushBufferedStdin(to: created)
        created.requestResize(cols: attachResult.requestedCols, rows: attachResult.requestedRows)
        return created
    }

    private final class CloseSignal: Sendable {
        private struct State: Sendable {
            var signaled: Bool = false
            var continuations: [CheckedContinuation<Void, Never>] = []
        }

        private let state = Mutex(State())

        func signal() {
            let pending = state.withLock { s -> [CheckedContinuation<Void, Never>] in
                if s.signaled { return [] }
                s.signaled = true
                let list = s.continuations
                s.continuations.removeAll()
                return list
            }
            for cont in pending {
                cont.resume()
            }
        }

        func wait() async {
            let already = state.withLock { $0.signaled }
            if already { return }
            await withCheckedContinuation { continuation in
                let resumeNow = state.withLock { s -> Bool in
                    if s.signaled { return true }
                    s.continuations.append(continuation)
                    return false
                }
                if resumeNow {
                    continuation.resume()
                }
            }
        }
    }

    func enterApp(_ handler: @escaping SSHSessionHandler) async throws {
        // Register close signal before renderer setup so an early close cannot be missed.
        let closeSignal = CloseSignal()
        let _ = onClose {
            closeSignal.signal()
        }

        if closed {
            await closeSignal.wait()
            return
        }

        let attached: (any SSHAttachableRenderer)?
        do {
            attached = try await attachRenderer()
        } catch {
            await destroy()
            throw error
        }
        guard attached != nil else {
            await closeSignal.wait()
            return
        }

        enum RaceOutcome: Sendable {
            case handlerFinished
            case handlerFailed(any Error)
            case sessionEnded
        }

        let handlerTask = Task<Result<Void, any Error>, Never> {
            do {
                try await handler(self)
                return .success(())
            } catch {
                return .failure(error)
            }
        }

        let outcome = await withTaskGroup(of: RaceOutcome.self) { group -> RaceOutcome in
            group.addTask {
                switch await handlerTask.value {
                case .success:
                    return .handlerFinished
                case .failure(let error):
                    return .handlerFailed(error)
                }
            }
            group.addTask {
                await closeSignal.wait()
                return .sessionEnded
            }
            let first = await group.next() ?? .sessionEnded
            group.cancelAll()
            return first
        }

        switch outcome {
        case .handlerFailed(let error):
            throw error
        case .handlerFinished:
            await closeSignal.wait()
        case .sessionEnded:
            // Report late handler failures after disconnect rather than silently dropping them.
            Task { [safe] in
                if case .failure(let lateError) = await handlerTask.value {
                    safe.report(lateError)
                }
            }
        }
    }

    // MARK: - Teardown

    func destroy() async {
        let transition = state.withLock {
            s -> (
                shouldRun: Bool,
                renderer: (any SSHAttachableRenderer)?,
                closeListeners: [@Sendable () -> Void],
                idleTask: Task<Void, Never>?,
                maxTask: Task<Void, Never>?,
                wasPaused: Bool
            ) in
            if s.closed {
                return (false, nil, [], nil, nil, false)
            }
            s.closed = true
            let r = s.renderer
            let listeners = Array(s.closeListeners.values)
            s.closeListeners.removeAll()
            s.resizeListeners.removeAll()
            s.stdinQueue.removeAll()
            s.stdinBufferedBytes = 0
            let paused = s.inputPaused
            s.inputPaused = false
            let idle = s.idleTask
            let maxT = s.maxTask
            s.idleTask = nil
            s.maxTask = nil
            return (true, r, listeners, idle, maxT, paused)
        }

        if !transition.shouldRun {
            await waitForTransportClosed()
            return
        }

        transition.idleTask?.cancel()
        transition.maxTask?.cancel()
        channel.setDataHandler(nil)
        if transition.wasPaused {
            ignoreErrors { channel.resume() }
        }

        if let renderer = transition.renderer {
            ignoreErrors { renderer.destroy() }
        }

        for listener in transition.closeListeners {
            safe(listener)
        }

        var restored = true
        if let renderer = transition.renderer {
            do {
                try await renderer.waitForClose()
            } catch {
                restored = false
                safe.report(error)
            }
        }

        await waitForOutputDrain()
        finishTransportClose(restored: restored)
    }

    func disconnect() async {
        let drainWaiters = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            s.channelClosed = true
            s.output.queuedChunks.removeAll()
            s.output.queuedBytes = 0
            s.output.inFlightBytes = 0
            s.output.waitingForDrain = false
            let waiters = s.output.drainWaiters
            s.output.drainWaiters.removeAll()
            return waiters
        }
        for waiter in drainWaiters {
            waiter.resume()
        }
        await destroy()
    }

    private func finishTransportClose(restored: Bool) {
        let (shouldCloseChannel, waiters) = state.withLock {
            s -> (Bool, [CheckedContinuation<Void, Never>]) in
            if s.transportClosed { return (false, []) }
            s.transportClosed = true
            let pending = s.transportCloseWaiters
            s.transportCloseWaiters.removeAll()
            return (!s.channelClosed, pending)
        }
        if shouldCloseChannel {
            ignoreErrors { channel.exit(code: restored ? 0 : 1) }
            ignoreErrors { channel.close() }
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func waitForTransportClosed() async {
        let done = state.withLock { $0.transportClosed }
        if done { return }
        await withCheckedContinuation { continuation in
            let resumeNow = state.withLock { s -> Bool in
                if s.transportClosed { return true }
                s.transportCloseWaiters.append(continuation)
                return false
            }
            if resumeNow {
                continuation.resume()
            }
        }
    }
}

/// Turn an SSH shell channel into a wired-up OpenTUI session bridge.
/// The session starts without a renderer; `enterApp()` attaches it only after
/// the middleware chain authorizes and reaches the handler.
// parity: ssh/src/bridge.ts#createSessionBridge [status=implemented hash=152e4cb3388b]
public func createSessionBridge(
    channel: any SSHChannel,
    options: SSHSessionBridgeOptions
) -> any SSHSessionBridge {
    DefaultSSHSessionBridge(channel: channel, options: options)
}
