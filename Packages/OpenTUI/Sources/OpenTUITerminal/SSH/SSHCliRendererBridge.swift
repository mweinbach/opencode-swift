import OpenTUICore
import OpenTUIRenderables
import Synchronization

// MARK: - Terminal Mode Escape Sequences

private func makeTerminalSetupSequence(
    screenMode: ScreenMode,
    useMouse: Bool,
    enableMouseMovement: Bool,
    kittyKeyboardFlags: UInt32 = 0
) -> String {
    var seq = ""
    if screenMode == .alternateScreen {
        seq += ANSI.switchToAlternateScreen
        seq += ANSI.clearScreen
        seq += ANSI.home
    }
    // Enable bracketed paste mode
    seq += "\u{1B}[?2004h"
    if kittyKeyboardFlags != 0 {
        // Push Kitty keyboard protocol progressive enhancement flags
        seq += "\u{1B}[>\(kittyKeyboardFlags)u"
    }
    if useMouse {
        // Enable VT200 mouse, button-event drag tracking, optional any-event motion, and SGR extended coordinates
        seq += "\u{1B}[?1000h\u{1B}[?1002h"
        if enableMouseMovement {
            seq += "\u{1B}[?1003h"
        }
        seq += "\u{1B}[?1006h"
    }
    return seq
}

private func makeTerminalTeardownSequence(
    screenMode: ScreenMode,
    useMouse: Bool,
    enableMouseMovement: Bool,
    kittyKeyboardFlags: UInt32 = 0
) -> String {
    var seq = ""
    if useMouse {
        seq += "\u{1B}[?1006l"
        if enableMouseMovement {
            seq += "\u{1B}[?1003l"
        }
        seq += "\u{1B}[?1002l\u{1B}[?1000l"
    }
    if kittyKeyboardFlags != 0 {
        // Pop Kitty keyboard protocol mode cleanly
        seq += "\u{1B}[<u"
    }
    // Disable bracketed paste mode
    seq += "\u{1B}[?2004l"
    // Reset SGR styling and restore visible cursor
    seq += ANSI.reset
    seq += "\u{1B}[?25h"
    if screenMode == .alternateScreen {
        seq += ANSI.switchToMainScreen
    }
    return seq
}

// MARK: - Serialized FIFO Terminal Output Writer

/// Serializes synchronous `CliRenderer.outputWriter` callbacks into strict FIFO
/// asynchronous `TerminalBackend.write(_:)` calls with bounded backpressure and
/// deterministic drain/teardown synchronization.
internal final class SerialTerminalOutputWriter: @unchecked Sendable {
    private struct State: Sendable {
        var queue: [[UInt8]] = []
        var pendingBytes: Int = 0
        var accepting: Bool = true
        var draining: Bool = false
        var closed: Bool = false
        var pressureEvents: Int = 0
        var droppedChunks: Int = 0
        var lastError: (any Error)? = nil
        var flushWaiters: [CheckedContinuation<Void, Never>] = []
        var closeWaiters: [CheckedContinuation<Void, any Error>] = []
    }

    private let backend: any TerminalBackend
    private let maxPendingBytes: Int
    private let onError: (@Sendable (any Error) -> Void)?
    private let state = Mutex(State())

    init(
        backend: any TerminalBackend,
        maxPendingBytes: Int = sshDefaultMaxOutputBufferBytes,
        onError: (@Sendable (any Error) -> Void)? = nil
    ) {
        self.backend = backend
        self.maxPendingBytes = max(1, maxPendingBytes)
        self.onError = onError
    }

    var pressureEvents: Int {
        state.withLock { $0.pressureEvents }
    }

    var droppedChunks: Int {
        state.withLock { $0.droppedChunks }
    }

    var lastError: (any Error)? {
        state.withLock { $0.lastError }
    }

    /// Enqueue bytes for strict FIFO writing. When `force` is `false` and the pending
    /// output budget would be exceeded, backpressure is reported via `onError` with
    /// `OutputPressureError` without growing memory unboundedly.
    func enqueue(_ bytes: [UInt8], force: Bool = false) {
        guard !bytes.isEmpty else { return }

        enum Action {
            case startDrain
            case queued
            case pressure
            case ignored
        }

        let action = state.withLock { s -> Action in
            if s.closed { return .ignored }
            if !s.accepting && !force { return .ignored }
            if !force && (s.pendingBytes + bytes.count > maxPendingBytes) {
                s.pressureEvents += 1
                s.droppedChunks += 1
                return .pressure
            }
            s.queue.append(bytes)
            s.pendingBytes += bytes.count
            if !s.draining {
                s.draining = true
                return .startDrain
            }
            return .queued
        }

        switch action {
        case .startDrain:
            Task { await self.drainLoop() }
        case .pressure:
            onError?(OutputPressureError())
        case .queued, .ignored:
            break
        }
    }

    /// Stop accepting new frame writes, optionally enqueue a final terminal restoration
    /// sequence, and transition to closed once the FIFO queue finishes draining.
    func finish(finalBytes: [UInt8]? = nil) {
        enum FinishAction {
            case alreadyFinished
            case closeNow([CheckedContinuation<Void, Never>], [CheckedContinuation<Void, any Error>])
            case startDrain
            case waitForDrain
        }

        let action = state.withLock { s -> FinishAction in
            if !s.accepting { return .alreadyFinished }
            s.accepting = false
            if let finalBytes, !finalBytes.isEmpty {
                s.queue.append(finalBytes)
                s.pendingBytes += finalBytes.count
            }
            if s.queue.isEmpty && !s.draining {
                s.closed = true
                let flushes = s.flushWaiters
                let closes = s.closeWaiters
                s.flushWaiters.removeAll()
                s.closeWaiters.removeAll()
                return .closeNow(flushes, closes)
            }
            if !s.draining {
                s.draining = true
                return .startDrain
            }
            return .waitForDrain
        }

        switch action {
        case .closeNow(let flushes, let closes):
            for w in flushes { w.resume() }
            for w in closes { w.resume() }
        case .startDrain:
            Task { await self.drainLoop() }
        case .alreadyFinished, .waitForDrain:
            break
        }
    }

    /// Suspends until all currently queued chunks have been handed to `backend.write(_:)`.
    func flush() async {
        let alreadyIdle = state.withLock { $0.queue.isEmpty && !$0.draining }
        if alreadyIdle { return }
        await withCheckedContinuation { continuation in
            let resumeNow = state.withLock { s -> Bool in
                if s.queue.isEmpty && !s.draining {
                    return true
                }
                s.flushWaiters.append(continuation)
                return false
            }
            if resumeNow {
                continuation.resume()
            }
        }
    }

    /// Suspends until `finish(...)` has been called and all pending writes (including
    /// any final terminal restoration sequence) have completed.
    func waitForClose() async throws {
        let alreadyClosed = state.withLock { $0.closed }
        if alreadyClosed { return }
        try await withCheckedThrowingContinuation { continuation in
            let resumeNow = state.withLock { s -> Bool in
                if s.closed { return true }
                s.closeWaiters.append(continuation)
                return false
            }
            if resumeNow {
                continuation.resume()
            }
        }
    }

    private func drainLoop() async {
        while true {
            enum Step {
                case write([UInt8])
                case idle(
                    flushWaiters: [CheckedContinuation<Void, Never>],
                    closeWaiters: [CheckedContinuation<Void, any Error>]
                )
            }

            let step = state.withLock { s -> Step in
                if !s.queue.isEmpty {
                    let next = s.queue.removeFirst()
                    s.pendingBytes = max(0, s.pendingBytes - next.count)
                    return .write(next)
                }
                s.draining = false
                let flushes = s.flushWaiters
                s.flushWaiters.removeAll()
                if !s.accepting {
                    s.closed = true
                    let closes = s.closeWaiters
                    s.closeWaiters.removeAll()
                    return .idle(flushWaiters: flushes, closeWaiters: closes)
                }
                return .idle(flushWaiters: flushes, closeWaiters: [])
            }

            switch step {
            case .write(let chunk):
                do {
                    try await backend.write(chunk)
                } catch is OutputPressureError {
                    state.withLock { $0.pressureEvents += 1 }
                    onError?(OutputPressureError())
                } catch {
                    state.withLock { $0.lastError = error }
                    onError?(error)
                }
            case .idle(let flushWaiters, let closeWaiters):
                for waiter in flushWaiters {
                    waiter.resume()
                }
                for waiter in closeWaiters {
                    waiter.resume()
                }
                return
            }
        }
    }
}

// MARK: - Sendable SSH CliRenderer Configuration

/// Sendable configuration used by `createCliRendererSSHFactory(config:)` and
/// `createCliSSHServer(config:rendererConfig:driver:)` to construct a live
/// `CliRenderer` sized to each SSH client's negotiated PTY dimensions.
public struct SSHCliRendererConfig: Sendable {
    public var screenMode: ScreenMode
    public var footerHeight: Int
    public var externalOutputMode: ExternalOutputMode?
    public var consoleMode: ConsoleMode
    /// When `nil`, inherits `SSHRendererCreateOptions.exitOnCtrlC`.
    public var exitOnCtrlC: Bool?
    public var clearOnShutdown: Bool
    /// Resize debounce delay in milliseconds (defaults to `0` so SSH `window-change` applies immediately).
    public var debounceDelay: Double
    /// When `nil`, inherits `SSHRendererCreateOptions.targetFps`.
    public var targetFps: Double?
    public var maxFps: Double
    public var gatherStats: Bool
    public var maxStatSamples: Int
    public var enableMouseMovement: Bool
    public var useMouse: Bool
    public var autoFocus: Bool
    public var useKittyKeyboard: KittyKeyboardOptions?
    public var backgroundColor: RGBA
    public var widthMethod: WidthMethod
    public var rendererCapabilities: RendererCapabilities
    /// When `true`, emits terminal setup/teardown ANSI sequences (alternate screen,
    /// bracketed paste, mouse tracking, cursor visibility) on attach and destroy.
    public var manageTerminalModes: Bool
    /// Bounded pending output buffer size before backpressure triggers.
    public var maxPendingOutputBytes: Int
    /// Optional clock factory for deterministic testing (defaults to `SystemClock()`).
    public var clockFactory: (@Sendable () -> any Clock)?
    /// Optional callback invoked when the SSH output bridge reports backpressure or write errors.
    public var onOutputError: (@Sendable (any Error) -> Void)?

    public init(
        screenMode: ScreenMode = .alternateScreen,
        footerHeight: Int = 12,
        externalOutputMode: ExternalOutputMode? = nil,
        consoleMode: ConsoleMode = .disabled,
        exitOnCtrlC: Bool? = nil,
        clearOnShutdown: Bool = true,
        debounceDelay: Double = 0,
        targetFps: Double? = nil,
        maxFps: Double = 60,
        gatherStats: Bool = false,
        maxStatSamples: Int = 300,
        enableMouseMovement: Bool = true,
        useMouse: Bool = true,
        autoFocus: Bool = true,
        useKittyKeyboard: KittyKeyboardOptions? = KittyKeyboardOptions(),
        backgroundColor: RGBA = RGBA.fromInts(0, 0, 0, 0),
        widthMethod: WidthMethod = .unicode,
        rendererCapabilities: RendererCapabilities = RendererCapabilities(),
        manageTerminalModes: Bool = true,
        maxPendingOutputBytes: Int = sshDefaultMaxOutputBufferBytes,
        clockFactory: (@Sendable () -> any Clock)? = nil,
        onOutputError: (@Sendable (any Error) -> Void)? = nil
    ) {
        self.screenMode = screenMode
        self.footerHeight = footerHeight
        self.externalOutputMode = externalOutputMode
        self.consoleMode = consoleMode
        self.exitOnCtrlC = exitOnCtrlC
        self.clearOnShutdown = clearOnShutdown
        self.debounceDelay = debounceDelay
        self.targetFps = targetFps
        self.maxFps = maxFps
        self.gatherStats = gatherStats
        self.maxStatSamples = maxStatSamples
        self.enableMouseMovement = enableMouseMovement
        self.useMouse = useMouse
        self.autoFocus = autoFocus
        self.useKittyKeyboard = useKittyKeyboard
        self.backgroundColor = backgroundColor
        self.widthMethod = widthMethod
        self.rendererCapabilities = rendererCapabilities
        self.manageTerminalModes = manageTerminalModes
        self.maxPendingOutputBytes = maxPendingOutputBytes
        self.clockFactory = clockFactory
        self.onOutputError = onOutputError
    }

    /// Creates a concrete `CliRendererConfig` sized to `options.width` x `options.height`.
    /// Note: `exitOnCtrlC` is handled safely by `SSHCliRendererAdapter` asynchronously after
    /// `StdinParser.drain` returns to avoid reentrant exclusivity conflicts on `stdinParser`.
    public func makeCliRendererConfig(for options: SSHRendererCreateOptions) -> CliRendererConfig {
        CliRendererConfig(
            width: options.width,
            height: options.height,
            screenMode: screenMode,
            footerHeight: footerHeight,
            externalOutputMode: externalOutputMode,
            consoleMode: consoleMode,
            exitOnCtrlC: false,
            clearOnShutdown: clearOnShutdown,
            debounceDelay: debounceDelay,
            targetFps: targetFps ?? Double(max(1, options.targetFps)),
            maxFps: maxFps,
            gatherStats: gatherStats,
            maxStatSamples: maxStatSamples,
            enableMouseMovement: enableMouseMovement,
            useMouse: useMouse,
            autoFocus: autoFocus,
            useKittyKeyboard: useKittyKeyboard,
            backgroundColor: backgroundColor,
            widthMethod: widthMethod,
            rendererCapabilities: rendererCapabilities,
            clock: clockFactory?()
        )
    }
}

// MARK: - SSHCliRendererAdapter

/// Adapts a live `CliRenderer` to `SSHAttachableRenderer`, bridging:
/// - SSH client stdin bytes -> `CliRenderer.feedInput(_:)`
/// - `CliRenderer.outputWriter` -> serialized FIFO writes onto `SSHTerminalBackend`
/// - SSH `window-change` -> `CliRenderer.resize(width:height:)`
/// - SSH teardown / `CliRenderer.destroy()` -> terminal cleanup (alternate screen exit,
///   cursor restore, mouse disable) and deterministic flush via `waitForClose()`.
public final class SSHCliRendererAdapter: SSHAttachableRenderer, @unchecked Sendable {
    private struct State: Sendable {
        var width: Int
        var height: Int
        var destroyed: Bool = false
        var nextListenerID: UInt64 = 1
        var resizeListeners: [UInt64: @Sendable (Int, Int) -> Void] = [:]
        var destroyListeners: [UInt64: @Sendable () -> Void] = [:]
    }

    public let renderer: CliRenderer
    public let backend: SSHTerminalBackend
    public let environment: [String: String]
    public let term: String
    public let hasPty: Bool

    private let manageTerminalModes: Bool
    private let screenMode: ScreenMode
    private let initialMouseEnabled: Bool
    private let enableMouseMovement: Bool
    private let kittyKeyboardFlags: UInt32
    private let outputWriter: SerialTerminalOutputWriter
    private let state: Mutex<State>

    private var resizeToken: CliRendererListenerToken?
    private var destroyToken: CliRendererListenerToken?

    public init(
        renderer: CliRenderer,
        options: SSHRendererCreateOptions,
        exitOnCtrlC: Bool? = nil,
        manageTerminalModes: Bool = true,
        enableMouseMovement: Bool = true,
        maxPendingOutputBytes: Int = sshDefaultMaxOutputBufferBytes,
        onOutputError: (@Sendable (any Error) -> Void)? = nil
    ) {
        self.renderer = renderer
        self.backend = options.backend
        self.environment = options.environment
        self.term = options.term
        self.hasPty = options.hasPty
        self.manageTerminalModes = manageTerminalModes
        self.screenMode = renderer.screenMode
        self.initialMouseEnabled = renderer.useMouse
        self.enableMouseMovement = enableMouseMovement
        self.kittyKeyboardFlags = renderer.activeKittyKeyboardFlags
        self.outputWriter = SerialTerminalOutputWriter(
            backend: options.backend,
            maxPendingBytes: maxPendingOutputBytes,
            onError: onOutputError
        )
        self.state = Mutex(State(width: renderer.width, height: renderer.height))

        let writer = self.outputWriter
        renderer.outputWriter = { ansi in
            writer.enqueue(Array(ansi.utf8))
        }

        self.resizeToken = renderer.onResize { [weak self] newWidth, newHeight in
            self?.handleRendererResize(width: newWidth, height: newHeight)
        }
        self.destroyToken = renderer.on(.destroy) { [weak self] in
            self?.handleRendererDestroyedDirectly()
        }

        if exitOnCtrlC ?? options.exitOnCtrlC {
            _ = renderer.keyInput.onKeypress { [weak self] event in
                let isBaseC = event.baseCode == 99 // 'c'
                if event.ctrl && (event.name.lowercased() == "c" || isBaseC) {
                    Task { [weak self] in
                        self?.renderer.destroy()
                    }
                }
            }
        }

        if manageTerminalModes {
            let setup = makeTerminalSetupSequence(
                screenMode: self.screenMode,
                useMouse: self.initialMouseEnabled,
                enableMouseMovement: self.enableMouseMovement,
                kittyKeyboardFlags: self.kittyKeyboardFlags
            )
            if !setup.isEmpty {
                writer.enqueue(Array(setup.utf8), force: true)
            }
        }
    }

    public var width: Int {
        state.withLock { $0.width }
    }

    public var height: Int {
        state.withLock { $0.height }
    }

    public var isDestroyed: Bool {
        state.withLock { $0.destroyed } || renderer.isDestroyed
    }

    /// Number of output backpressure events observed while writing frames to SSH.
    public var outputPressureCount: Int {
        outputWriter.pressureEvents
    }

    /// Most recent non-pressure write error observed on the SSH output backend, if any.
    public var lastOutputError: (any Error)? {
        outputWriter.lastError
    }

    /// Delivers raw incoming SSH channel bytes to `CliRenderer.feedInput(_:)`.
    public func feedInput(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        let destroyed = state.withLock { $0.destroyed }
        guard !destroyed, !renderer.isDestroyed else { return }
        renderer.feedInput(bytes)
    }

    /// Applies an SSH `window-change` resize directly to `CliRenderer.resize(width:height:)`.
    public func requestResize(cols: Int, rows: Int) {
        let destroyed = state.withLock { $0.destroyed }
        guard !destroyed, !renderer.isDestroyed else { return }
        renderer.resize(width: cols, height: rows)
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

    /// Suspends until all currently queued ANSI frames have been written to `backend`.
    public func flushOutput() async {
        await outputWriter.flush()
    }

    /// Idempotently destroys the wrapped `CliRenderer`, emits terminal restoration
    /// sequences (leaving alternate screen, disabling mouse, showing cursor), and
    /// notifies `onDestroy` subscribers.
    public func destroy() {
        let listeners = state.withLock { s -> [@Sendable () -> Void]? in
            if s.destroyed { return nil }
            s.destroyed = true
            let destroyCallbacks = Array(s.destroyListeners.values)
            s.destroyListeners.removeAll()
            s.resizeListeners.removeAll()
            return destroyCallbacks
        }
        guard let listeners else { return }

        finishOutputWithTeardown()
        renderer.outputWriter = nil
        if !renderer.isDestroyed {
            renderer.destroy()
        }
        for listener in listeners {
            listener()
        }
    }

    /// Awaits full drain of queued frames and terminal restoration output after `destroy()`.
    public func waitForClose() async throws {
        try await outputWriter.waitForClose()
    }

    // MARK: - Internal Bridges

    private func handleRendererResize(width newWidth: Int, height newHeight: Int) {
        let listeners = state.withLock { s -> [@Sendable (Int, Int) -> Void] in
            if s.destroyed { return [] }
            s.width = newWidth
            s.height = newHeight
            return Array(s.resizeListeners.values)
        }
        Task { await backend.updateSize(TerminalSize(width: newWidth, height: newHeight)) }
        for listener in listeners {
            listener(newWidth, newHeight)
        }
    }

    private func handleRendererDestroyedDirectly() {
        let listeners = state.withLock { s -> [@Sendable () -> Void]? in
            if s.destroyed { return nil }
            s.destroyed = true
            let destroyCallbacks = Array(s.destroyListeners.values)
            s.destroyListeners.removeAll()
            s.resizeListeners.removeAll()
            return destroyCallbacks
        }
        guard let listeners else { return }

        finishOutputWithTeardown()
        renderer.outputWriter = nil

        // Drain restoration output while the SSH session bridge is still open,
        // then notify bridge/listeners so channel close follows restoration cleanly.
        let writer = self.outputWriter
        Task {
            try? await writer.waitForClose()
            for listener in listeners {
                listener()
            }
        }
    }

    private func finishOutputWithTeardown() {
        let teardownBytes: [UInt8]?
        if manageTerminalModes {
            let teardown = makeTerminalTeardownSequence(
                screenMode: screenMode,
                useMouse: initialMouseEnabled,
                enableMouseMovement: enableMouseMovement,
                kittyKeyboardFlags: kittyKeyboardFlags
            )
            teardownBytes = teardown.isEmpty ? nil : Array(teardown.utf8)
        } else {
            teardownBytes = nil
        }
        outputWriter.finish(finalBytes: teardownBytes)
    }
}

public extension SSHSession {
    /// Returns the live `CliRenderer` attached to this session when constructed with
    /// `createCliRendererSSHFactory(config:)` or `createCliSSHServer(...)`.
    var cliRenderer: CliRenderer? {
        (renderer as? SSHCliRendererAdapter)?.renderer
    }

    /// Returns the `SSHCliRendererAdapter` wrapping `cliRenderer`, if attached.
    var cliRendererAdapter: SSHCliRendererAdapter? {
        renderer as? SSHCliRendererAdapter
    }
}

// MARK: - SSH Factory & Server Convenience Constructors

/// Builds an `SSHRendererFactory` that constructs a live `CliRenderer` sized to each
/// client's negotiated PTY dimensions (`cols`, `rows`) and wraps it in `SSHCliRendererAdapter`.
public func createCliRendererSSHFactory(
    config: SSHCliRendererConfig = SSHCliRendererConfig()
) -> SSHRendererFactory {
    { options in
        let cliConfig = config.makeCliRendererConfig(for: options)
        let renderer = CliRenderer(config: cliConfig)
        return SSHCliRendererAdapter(
            renderer: renderer,
            options: options,
            exitOnCtrlC: config.exitOnCtrlC,
            manageTerminalModes: config.manageTerminalModes,
            enableMouseMovement: config.enableMouseMovement,
            maxPendingOutputBytes: config.maxPendingOutputBytes,
            onOutputError: config.onOutputError
        )
    }
}

/// Convenience builder creating an `SSHServerBuilder` pre-wired with
/// `createCliRendererSSHFactory(config: rendererConfig)`.
public func createCliSSHServer(
    config: SSHServerConfig = SSHServerConfig(),
    rendererConfig: SSHCliRendererConfig = SSHCliRendererConfig(),
    driver: any SSHTransportDriver = InMemorySSHTransportDriver()
) -> SSHServerBuilder {
    var serverConfig = config
    if serverConfig.createRenderer == nil {
        serverConfig.createRenderer = createCliRendererSSHFactory(config: rendererConfig)
    }
    return createSSHServer(config: serverConfig, driver: driver)
}

// MARK: - Generic TerminalBackend <-> CliRenderer Runner

/// Options configuring `runWithTerminalBackend(renderer:backend:options:...)`.
public struct TerminalBackendRunOptions: Sendable {
    public var enterRawMode: Bool
    public var manageTerminalModes: Bool
    public var initialRender: Bool
    public var destroyOnExit: Bool
    public var enableMouseMovement: Bool
    public var maxPendingOutputBytes: Int
    public var onOutputError: (@Sendable (any Error) -> Void)?

    public init(
        enterRawMode: Bool = true,
        manageTerminalModes: Bool = true,
        initialRender: Bool = true,
        destroyOnExit: Bool = true,
        enableMouseMovement: Bool = true,
        maxPendingOutputBytes: Int = sshDefaultMaxOutputBufferBytes,
        onOutputError: (@Sendable (any Error) -> Void)? = nil
    ) {
        self.enterRawMode = enterRawMode
        self.manageTerminalModes = manageTerminalModes
        self.initialRender = initialRender
        self.destroyOnExit = destroyOnExit
        self.enableMouseMovement = enableMouseMovement
        self.maxPendingOutputBytes = maxPendingOutputBytes
        self.onOutputError = onOutputError
    }
}

/// Active session handle exposed to `runWithTerminalBackend` closures for syncing
/// terminal dimensions, feeding input, rendering, and flushing ANSI output.
public final class TerminalBackendSession: @unchecked Sendable {
    public let renderer: CliRenderer
    public let backend: any TerminalBackend
    private let writer: SerialTerminalOutputWriter

    internal init(
        renderer: CliRenderer,
        backend: any TerminalBackend,
        writer: SerialTerminalOutputWriter
    ) {
        self.renderer = renderer
        self.backend = backend
        self.writer = writer
    }

    /// Reads the current `backend.size` and resizes `renderer` if dimensions changed.
    @discardableResult
    public func syncSize() async -> TerminalSize {
        let currentSize = await backend.size
        if currentSize.width > 0 && currentSize.height > 0,
           (renderer.terminalWidth != currentSize.width || renderer.terminalHeight != currentSize.height)
        {
            renderer.resize(width: currentSize.width, height: currentSize.height)
        }
        return currentSize
    }

    /// Feeds raw input bytes into the attached `CliRenderer`.
    public func feedInput(_ bytes: [UInt8]) {
        renderer.feedInput(bytes)
    }

    /// Feeds a UTF-8 input string into the attached `CliRenderer`.
    public func feedInput(_ text: String) {
        renderer.feedInput(text)
    }

    /// Executes one render pass and flushes all emitted ANSI bytes to `backend`.
    public func renderNow(force: Bool = false) async {
        renderer.renderOnce(force: force)
        await writer.flush()
    }

    /// Suspends until all pending ANSI bytes have been written to `backend`.
    public func flush() async {
        await writer.flush()
    }

    /// Number of backpressure events observed while writing to `backend`.
    public var outputPressureCount: Int {
        writer.pressureEvents
    }
}

private final class DestroySignal: @unchecked Sendable {
    private struct State: Sendable {
        var signaled: Bool = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    func signal() {
        let waiters = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            if s.signaled { return [] }
            s.signaled = true
            let list = s.waiters
            s.waiters.removeAll()
            return list
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    func wait() async {
        let already = state.withLock { $0.signaled }
        if already { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let resumeNow = state.withLock { s -> Bool in
                    if s.signaled { return true }
                    s.waiters.append(continuation)
                    return false
                }
                if resumeNow {
                    continuation.resume()
                }
            }
        } onCancel: {
            self.signal()
        }
    }
}

/// Wires any `TerminalBackend` (`PlatformTerminalBackend`, `MemoryTerminalBackend`,
/// `SSHTerminalBackend`, etc.) to a live `CliRenderer` for the duration of `body`:
/// enters raw mode, syncs renderer size to `backend.size`, routes `CliRenderer.outputWriter`
/// into `backend.write(_:)` in strict FIFO order, renders the initial frame, and on exit
/// restores terminal modes, flushes output, destroys the renderer (unless disabled), and
/// exits raw mode.
@discardableResult
public func runWithTerminalBackend<Result: Sendable>(
    renderer: CliRenderer,
    backend: any TerminalBackend,
    options: TerminalBackendRunOptions = TerminalBackendRunOptions(),
    body: @Sendable (CliRenderer, TerminalBackendSession) async throws -> Result
) async throws -> Result {
    let screenMode = renderer.screenMode
    let useMouse = renderer.useMouse
    let kittyKeyboardFlags = renderer.activeKittyKeyboardFlags
    var enteredRawMode = false

    if options.enterRawMode {
        try await backend.enterRawMode()
        enteredRawMode = true
    }
    let didEnterRawMode = enteredRawMode

    let writer = SerialTerminalOutputWriter(
        backend: backend,
        maxPendingBytes: options.maxPendingOutputBytes,
        onError: options.onOutputError
    )
    let session = TerminalBackendSession(renderer: renderer, backend: backend, writer: writer)

    renderer.outputWriter = { ansi in
        writer.enqueue(Array(ansi.utf8))
    }

    let teardown: @Sendable () async -> Void = {
        let finalBytes: [UInt8]?
        if options.manageTerminalModes {
            let seq = makeTerminalTeardownSequence(
                screenMode: screenMode,
                useMouse: useMouse,
                enableMouseMovement: options.enableMouseMovement,
                kittyKeyboardFlags: kittyKeyboardFlags
            )
            finalBytes = seq.isEmpty ? nil : Array(seq.utf8)
        } else {
            finalBytes = nil
        }
        writer.finish(finalBytes: finalBytes)
        try? await writer.waitForClose()
        renderer.outputWriter = nil
        if options.destroyOnExit && !renderer.isDestroyed {
            renderer.destroy()
        }
        if didEnterRawMode {
            try? await backend.exitRawMode()
        }
    }

    do {
        _ = await session.syncSize()
        if options.manageTerminalModes {
            let setup = makeTerminalSetupSequence(
                screenMode: screenMode,
                useMouse: useMouse,
                enableMouseMovement: options.enableMouseMovement,
                kittyKeyboardFlags: kittyKeyboardFlags
            )
            if !setup.isEmpty {
                writer.enqueue(Array(setup.utf8), force: true)
            }
        }
        if options.initialRender {
            await session.renderNow(force: true)
        } else {
            await session.flush()
        }

        let result = try await body(renderer, session)
        await teardown()
        return result
    } catch {
        await teardown()
        throw error
    }
}

/// Wires any `TerminalBackend` to a live `CliRenderer` and runs until `renderer.destroy()`
/// is called or the calling `Task` is cancelled, handling raw mode, initial size sync,
/// FIFO ANSI output, and clean terminal restoration automatically.
public func runWithTerminalBackend(
    renderer: CliRenderer,
    backend: any TerminalBackend,
    options: TerminalBackendRunOptions = TerminalBackendRunOptions()
) async throws {
    let signal = DestroySignal()
    let token = renderer.on(.destroy) {
        signal.signal()
    }
    defer {
        renderer.off(token)
    }

    try await runWithTerminalBackend(
        renderer: renderer,
        backend: backend,
        options: options
    ) { liveRenderer, _ in
        if !liveRenderer.isDestroyed {
            await signal.wait()
        }
    }
}
