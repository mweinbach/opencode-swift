// Pure-Swift terminal session coordinator (`core/src/NativeSession.ts`).
// Zero OS / Foundation imports (Pure Tier).

import OpenTUICore
import OpenTUIKeymap
import OpenTUILayout
import Synchronization

// MARK: - Handles, Context & Frame Ticket Primitives

/// Context handle identifying a pure-Swift `NativeResourceContext`.
public struct NativeContextHandle: Equatable, Hashable, Sendable, Codable {
    public let contextId: UInt64

    public init(contextId: UInt64) {
        self.contextId = contextId
    }
}

/// Checked handle for a `NativeSession` belonging to a `NativeResourceContext`.
public struct SessionHandle: Equatable, Hashable, Sendable, Codable {
    public let contextId: UInt64
    public let slot: UInt32
    public let generation: UInt32

    public init(contextId: UInt64, slot: UInt32, generation: UInt32) {
        self.contextId = contextId
        self.slot = slot
        self.generation = generation
    }
}

/// Checked handle for a retained scene node belonging to a `NativeResourceContext`.
public struct SceneNodeHandle: Equatable, Hashable, Sendable, Codable {
    public let contextId: UInt64
    public let slot: UInt32
    public let generation: UInt32

    public init(contextId: UInt64, slot: UInt32, generation: UInt32) {
        self.contextId = contextId
        self.slot = slot
        self.generation = generation
    }
}

/// Configuration for a `NativeResourceContext`.
public struct NativeContextOptions: Equatable, Hashable, Sendable, Codable {
    public var objectCapacity: Int
    public var renderCellsMax: Int

    public init(objectCapacity: Int = 65_536, renderCellsMax: Int = 1_000_000) {
        self.objectCapacity = max(1, objectCapacity)
        self.renderCellsMax = max(1, renderCellsMax)
    }
}

/// Pure-Swift resource context owning shared pools and session/node slot allocation.
public final class NativeResourceContext: @unchecked Sendable {
    private static let nextContextIdLock = Mutex<UInt64>(1)

    public let context: NativeContextHandle
    public let options: NativeContextOptions
    public let graphemePool: GraphemePool
    public let linkPool: LinkPool
    public private(set) var disposed: Bool = false

    private var nextSessionSlot: UInt32 = 1
    private var nextNodeSlot: UInt32 = 1
    private var generation: UInt32 = 1

    public init(
        options: NativeContextOptions = NativeContextOptions(),
        graphemePool: GraphemePool = GraphemePool(),
        linkPool: LinkPool = LinkPool()
    ) {
        let cid: UInt64 = Self.nextContextIdLock.withLock { current in
            let allocated = current
            current &+= 1
            if current == 0 { current = 1 }
            return allocated
        }
        self.context = NativeContextHandle(contextId: cid)
        self.options = options
        self.graphemePool = graphemePool
        self.linkPool = linkPool
    }

    internal func allocateSessionHandle() -> SessionHandle {
        let slot = nextSessionSlot
        nextSessionSlot &+= 1
        if nextSessionSlot == 0 { nextSessionSlot = 1 }
        return SessionHandle(contextId: context.contextId, slot: slot, generation: generation)
    }

    internal func allocateNodeHandle() -> SceneNodeHandle {
        let slot = nextNodeSlot
        nextNodeSlot &+= 1
        if nextNodeSlot == 0 { nextNodeSlot = 1 }
        return SceneNodeHandle(contextId: context.contextId, slot: slot, generation: generation)
    }

    public func destroy() {
        if disposed { return }
        disposed = true
        generation &+= 1
    }
}

/// Pure-Swift runtime facade providing a per-session `YogaHost`.
public final class NativeSessionRuntime: @unchecked Sendable {
    public let yogaHost: YogaHost

    public init(yogaHost: YogaHost = YogaHost()) {
        self.yogaHost = yogaHost
    }

    public func getYogaHost() -> YogaHost {
        yogaHost
    }
}

// MARK: - Scene Frame Ticket & Split Snapshot

/// Frame state machine kind matching `zig.ts#NativeSceneFrame`.
public enum NativeSceneFrame: Int32, Equatable, Hashable, Sendable, Codable {
    case done = 0
    case update = 1
    case resize = 2
    case layoutChanged = 3
    case record = 4
    case scroll = 5
}

/// Paint layout geometry for a scene node matching `zig.ts#NativeSceneLayout`.
public struct NativeSceneLayout: Equatable, Hashable, Sendable, Codable {
    public var left: Float
    public var top: Float
    public var right: Float
    public var bottom: Float
    public var width: Float
    public var height: Float
    public var screenX: Int
    public var screenY: Int

    public static let zero = NativeSceneLayout(
        left: 0,
        top: 0,
        right: 0,
        bottom: 0,
        width: 0,
        height: 0,
        screenX: 0,
        screenY: 0
    )

    public init(
        left: Float = 0,
        top: Float = 0,
        right: Float = 0,
        bottom: Float = 0,
        width: Float = 0,
        height: Float = 0,
        screenX: Int = 0,
        screenY: Int = 0
    ) {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
        self.width = width
        self.height = height
        self.screenX = screenX
        self.screenY = screenY
    }
}

/// Issued frame ticket passed between `NativeScene.paint` and `NativeSession.render`.
public struct NativeSceneFrameRequest: Equatable, Sendable {
    public let session: SessionHandle
    public let root: SceneNodeHandle
    public let node: SceneNodeHandle
    public let frameId: UInt64
    public let requestId: UInt64
    public let layoutEpoch: UInt64
    public let hookGeneration: UInt64
    public let kind: NativeSceneFrame
    public let num: UInt32
    public let width: Int
    public let height: Int
    public var paintLayout: NativeSceneLayout?
    public var publicLayout: NativeSceneLayout?

    public init(
        session: SessionHandle,
        root: SceneNodeHandle,
        node: SceneNodeHandle,
        frameId: UInt64,
        requestId: UInt64,
        layoutEpoch: UInt64,
        hookGeneration: UInt64 = 0,
        kind: NativeSceneFrame = .done,
        num: UInt32 = 0,
        width: Int = 0,
        height: Int = 0,
        paintLayout: NativeSceneLayout? = nil,
        publicLayout: NativeSceneLayout? = nil
    ) {
        self.session = session
        self.root = root
        self.node = node
        self.frameId = frameId
        self.requestId = requestId
        self.layoutEpoch = layoutEpoch
        self.hookGeneration = hookGeneration
        self.kind = kind
        self.num = num
        self.width = width
        self.height = height
        self.paintLayout = paintLayout
        self.publicLayout = publicLayout
    }
}

/// Snapshot committed into scrollback during split rendering.
public struct NativeSplitSnapshot: Sendable {
    public var buffer: OptimizedBuffer
    public var rowColumns: Int
    public var startOnNewLine: Bool
    public var trailingNewline: Bool

    public init(
        buffer: OptimizedBuffer,
        rowColumns: Int,
        startOnNewLine: Bool = false,
        trailingNewline: Bool = true
    ) {
        self.buffer = buffer
        self.rowColumns = rowColumns
        self.startOnNewLine = startOnNewLine
        self.trailingNewline = trailingNewline
    }
}

// MARK: - Scheduler & Output Sink Protocols

/// Monotonic nanosecond scheduler matching `core/src/NativeSession.ts#NativeSessionScheduler`.
// parity: core/src/NativeSession.ts#NativeSessionScheduler [status=implemented hash=549947da6e98]
public protocol NativeSessionScheduler: AnyObject {
    /// Monotonic nanoseconds.
    func now() -> UInt64
    /// Schedule a later turn; returns a cancellation closure.
    @discardableResult
    func schedule(_ callback: @escaping () -> Void, delayMs: Double?) -> () -> Void
}

/// `NativeSessionScheduler` adapter backed by any `OpenTUICore.Clock`.
public final class ClockNativeSessionScheduler: NativeSessionScheduler {
    private let clock: any Clock

    public init(clock: any Clock = SystemClock()) {
        self.clock = clock
    }

    public func now() -> UInt64 {
        let ms = max(0, clock.now())
        return UInt64(ms * 1_000_000.0)
    }

    @discardableResult
    public func schedule(_ callback: @escaping () -> Void, delayMs: Double?) -> () -> Void {
        let handle = clock.setTimeout(callback, delayMs: delayMs ?? 0)
        return { [weak clock] in
            clock?.clearTimeout(handle)
        }
    }
}

/// Deterministic manual scheduler for unit testing `NativeSession` turn ordering and timeouts.
public final class ManualNativeSessionScheduler: NativeSessionScheduler {
    private struct TaskEntry {
        let id: UInt64
        let dueNs: UInt64
        let callback: () -> Void
        var cancelled: Bool = false
    }

    private var currentNs: UInt64
    private var nextId: UInt64 = 1
    private var queue: [TaskEntry] = []

    public init(initialNs: UInt64 = 0) {
        self.currentNs = initialNs
    }

    public func now() -> UInt64 {
        currentNs
    }

    public func advance(byMs ms: Double) {
        currentNs &+= UInt64(max(0, ms) * 1_000_000.0)
    }

    public func advance(byNs ns: UInt64) {
        currentNs &+= ns
    }

    @discardableResult
    public func schedule(_ callback: @escaping () -> Void, delayMs: Double?) -> () -> Void {
        let id = nextId
        nextId &+= 1
        let delayNs = delayMs.map { UInt64(max(0, $0) * 1_000_000.0) } ?? 0
        queue.append(TaskEntry(id: id, dueNs: currentNs &+ delayNs, callback: callback))
        return { [weak self] in
            guard let self else { return }
            for i in 0..<self.queue.count where self.queue[i].id == id {
                self.queue[i].cancelled = true
            }
        }
    }

    /// Runs all due non-cancelled tasks up to `currentNs`.
    @discardableResult
    public func runDue() -> Int {
        var executed = 0
        while let idx = queue.firstIndex(where: { !$0.cancelled && $0.dueNs <= currentNs }) {
            let task = queue.remove(at: idx)
            task.callback()
            executed += 1
        }
        queue.removeAll { $0.cancelled }
        return executed
    }
}

/// Injectable output destination borrowed by `NativeSession` (pure-Swift equivalent of Node `Writable`).
public protocol NativeSessionOutputSink: AnyObject {
    var isWritable: Bool { get }
    var isDestroyed: Bool { get }
    var isEnded: Bool { get }
    var needsDrain: Bool { get }
    var onDrain: (() -> Void)? { get set }
    var onError: ((NativeSessionError) -> Void)? { get set }
    var onClose: (() -> Void)? { get set }

    /// Writes `bytes` to the destination. Returns `false` if downstream backpressure requires waiting for `onDrain`.
    @discardableResult
    func write(_ bytes: [UInt8]) -> Bool
}

/// Pure-Swift in-memory output sink capturing emitted terminal byte streams with simulated backpressure.
public final class MemorySessionOutputSink: NativeSessionOutputSink, @unchecked Sendable {
    public var isWritable: Bool = true
    public var isDestroyed: Bool = false
    public var isEnded: Bool = false
    public var needsDrain: Bool = false
    public var simulateBackpressure: Bool = false

    public var onDrain: (() -> Void)?
    public var onError: ((NativeSessionError) -> Void)?
    public var onClose: (() -> Void)?

    public private(set) var chunks: [[UInt8]] = []
    public private(set) var allBytes: [UInt8] = []

    public init(simulateBackpressure: Bool = false) {
        self.simulateBackpressure = simulateBackpressure
    }

    public var outputText: String {
        String(decoding: allBytes, as: UTF8.self)
    }

    @discardableResult
    public func write(_ bytes: [UInt8]) -> Bool {
        guard isWritable && !isDestroyed && !isEnded else { return false }
        chunks.append(bytes)
        allBytes.append(contentsOf: bytes)
        if simulateBackpressure {
            needsDrain = true
            return false
        }
        return true
    }

    public func drain() {
        needsDrain = false
        onDrain?()
    }

    public func clear() {
        chunks.removeAll()
        allBytes.removeAll()
    }

    public func close() {
        isWritable = false
        isEnded = true
        isDestroyed = true
        onClose?()
    }
}

// MARK: - Session Enums, Options, Control Commands & Metrics

public enum SynchronizedOutputMode: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case auto
    case always
    case never
}

public enum NativeSessionState: Int32, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case open = 0
    case closing = 1
    case closed = 2
    case failed = 3
    case cancelled = 4
}

public enum NativeSessionTerminalPhase: Int32, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case uninitialized = 0
    case settingUp = 1
    case active = 2
    case suspending = 3
    case suspended = 4
    case resuming = 5
    case closing = 6
    case restored = 7
    case failed = 8
    case cancelled = 9
}

public enum NativeSessionRenderStatus: Int32, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case presented = 0
    case pending = 1
    case skipped = 2
    case failed = 3
}

public enum NativeSessionPumpStatus: Int32, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case idle = 0
    case again = 1
    case outputPending = 2
    case waitUntil = 3
    case closed = 4
}

/// Output queue capacity options matching `zig.ts#NativeSessionOptions`.
public struct NativeSessionOutputOptions: Equatable, Hashable, Sendable, Codable {
    public var chunkSize: Int
    public var spanCapacity: Int
    public var maxBytes: UInt64
    public var controlCapacity: Int

    public init(
        chunkSize: Int = 65_536,
        spanCapacity: Int = 128,
        maxBytes: UInt64 = 8_388_608,
        controlCapacity: Int = 4096
    ) {
        self.chunkSize = max(1, chunkSize)
        self.spanCapacity = max(1, spanCapacity)
        self.maxBytes = maxBytes
        self.controlCapacity = max(0, controlCapacity)
    }
}

/// Driver configuration options matching `core/src/NativeSession.ts#NativeSessionDriverOptions`.
// parity: core/src/NativeSession.ts#NativeSessionDriverOptions [status=adapted hash=8660ec3fbcb5]
public struct NativeSessionDriverOptions {
    public var context: NativeContextOptions
    public var output: NativeSessionOutputOptions
    public var outputBufferSize: Int
    public var closeTimeoutMs: Int
    public var scheduler: (any NativeSessionScheduler)?
    public var width: Int?
    public var height: Int?
    public var widthMethod: WidthMethod
    public var capabilities: TerminalCapabilities
    public var themeMode: ThemeMode?
    public var palette: NormalizedTerminalPalette?

    public init(
        context: NativeContextOptions = NativeContextOptions(),
        output: NativeSessionOutputOptions = NativeSessionOutputOptions(),
        outputBufferSize: Int = 65_536,
        closeTimeoutMs: Int = 1000,
        scheduler: (any NativeSessionScheduler)? = nil,
        width: Int? = nil,
        height: Int? = nil,
        widthMethod: WidthMethod = .unicode,
        capabilities: TerminalCapabilities = TerminalCapabilities(),
        themeMode: ThemeMode? = nil,
        palette: NormalizedTerminalPalette? = nil
    ) {
        self.context = context
        self.output = output
        self.outputBufferSize = outputBufferSize
        self.closeTimeoutMs = closeTimeoutMs
        self.scheduler = scheduler
        self.width = width
        self.height = height
        self.widthMethod = widthMethod
        self.capabilities = capabilities
        self.themeMode = themeMode
        self.palette = palette
    }
}

/// Ergonomic alias for `NativeSessionDriverOptions`.
public typealias NativeSessionOptions = NativeSessionDriverOptions

public struct NativeSessionRendererOptions: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var remote: Bool?
    public var environment: [String: String]?
    public var widthMethod: WidthMethod
    public var backgroundColor: RGBA

    public init(
        width: Int,
        height: Int,
        remote: Bool? = nil,
        environment: [String: String]? = nil,
        widthMethod: WidthMethod = .unicode,
        backgroundColor: RGBA = RGBA.fromInts(0, 0, 0, 0)
    ) {
        self.width = width
        self.height = height
        self.remote = remote
        self.environment = environment
        self.widthMethod = widthMethod
        self.backgroundColor = backgroundColor
    }
}

public struct NativeSessionRendererState: Equatable, Hashable, Sendable, Codable {
    public var width: Int
    public var height: Int
    public var frameCount: UInt64
    public var framePending: Bool
    public var imageUploadsPending: Int
    public var droppedFrames: Int
    public var droppedFrameBytes: Int

    public init(
        width: Int = 0,
        height: Int = 0,
        frameCount: UInt64 = 0,
        framePending: Bool = false,
        imageUploadsPending: Int = 0,
        droppedFrames: Int = 0,
        droppedFrameBytes: Int = 0
    ) {
        self.width = width
        self.height = height
        self.frameCount = frameCount
        self.framePending = framePending
        self.imageUploadsPending = imageUploadsPending
        self.droppedFrames = droppedFrames
        self.droppedFrameBytes = droppedFrameBytes
    }
}

public struct NativeSessionTerminalOptions: Equatable, Hashable, Sendable, Codable {
    public var useAlternateScreen: Bool
    public var mouse: Bool
    public var mouseMovement: Bool
    public var kittyKeyboardFlags: UInt32
    public var clearOnClose: Bool
    public var replySentinel: Bool
    public var synchronizedOutput: SynchronizedOutputMode
    public var hostMultiplexer: Bool

    public init(
        useAlternateScreen: Bool = true,
        mouse: Bool = false,
        mouseMovement: Bool = false,
        kittyKeyboardFlags: UInt32 = 0,
        clearOnClose: Bool = false,
        replySentinel: Bool = false,
        synchronizedOutput: SynchronizedOutputMode = .auto,
        hostMultiplexer: Bool = false
    ) {
        self.useAlternateScreen = useAlternateScreen
        self.mouse = mouse
        self.mouseMovement = mouseMovement
        self.kittyKeyboardFlags = kittyKeyboardFlags
        self.clearOnClose = clearOnClose
        self.replySentinel = replySentinel
        self.synchronizedOutput = synchronizedOutput
        self.hostMultiplexer = hostMultiplexer
    }
}

public struct NativeSessionKittyImageTransportStatus: Equatable, Hashable, Sendable, Codable {
    public var requested: Int
    public var effective: Int
    public var fileState: Int
    public var fallback: Int
    public var pendingFiles: Int
    public var pendingBytes: Int

    public init(
        requested: Int = 0,
        effective: Int = 0,
        fileState: Int = 0,
        fallback: Int = 0,
        pendingFiles: Int = 0,
        pendingBytes: Int = 0
    ) {
        self.requested = requested
        self.effective = effective
        self.fileState = fileState
        self.fallback = fallback
        self.pendingFiles = pendingFiles
        self.pendingBytes = pendingBytes
    }
}

public enum ProgramStatusKind: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case permission
    case question
    case auth
}

public enum ProgramStatusState: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case idle
    case working
    case blocked
    case done
    case error
    case clear
}

/// OSC 7501 Program Status Protocol report matching `core/src/types.ts#ProgramStatus`.
public struct ProgramStatus: Equatable, Hashable, Sendable, Codable {
    public var state: ProgramStatusState
    public var id: String?
    public var app: String?
    public var title: String?
    public var message: String?
    public var kind: ProgramStatusKind?
    public var progress: Double?

    public init(
        state: ProgramStatusState,
        id: String? = nil,
        app: String? = nil,
        title: String? = nil,
        message: String? = nil,
        kind: ProgramStatusKind? = nil,
        progress: Double? = nil
    ) {
        self.state = state
        self.id = id
        self.app = app
        self.title = title
        self.message = message
        self.kind = kind
        self.progress = progress
    }
}

public enum NativeSessionMouseMode: String, Equatable, Hashable, Sendable, Codable {
    case disabled
    case drag
    case motion
}

/// Terminal control command submitted through `NativeSession.control(_:)`.
public enum NativeSessionControl: Equatable, Sendable {
    case capabilityResponse([UInt8])
    case paletteQuery(bytes: [UInt8], sentinel: Bool = false)
    case title(String)
    case mouse(NativeSessionMouseMode)
    case kittyKeyboardFlags(UInt32)
    case programStatus(ProgramStatus)
    case queryPixelResolution(sentinel: Bool = false)
    case queryThemeColors(sentinel: Bool = false)
    case restoreModes
    case resetBackground
    case endReplySentinel
}

/// Terminal capabilities plus active Kitty keyboard flags matching `zig.ts#NativeSessionCapabilities`.
public struct NativeSessionCapabilities: Equatable, Hashable, Sendable, Codable {
    public var capabilities: TerminalCapabilities
    public var kittyKeyboardFlags: UInt32

    public init(capabilities: TerminalCapabilities = TerminalCapabilities(), kittyKeyboardFlags: UInt32 = 0) {
        self.capabilities = capabilities
        self.kittyKeyboardFlags = kittyKeyboardFlags
    }
}

/// Session output & frame delivery telemetry.
public struct NativeSessionMetrics: Equatable, Hashable, Sendable {
    public var framesSubmitted: UInt64
    public var framesPresented: UInt64
    public var framesSkipped: UInt64
    public var framesDropped: UInt64
    public var bytesWritten: UInt64
    public var bytesQueued: UInt64
    public var backpressureEvents: UInt64
    public var lastRenderStats: AnsiDiffRenderStats

    public init(
        framesSubmitted: UInt64 = 0,
        framesPresented: UInt64 = 0,
        framesSkipped: UInt64 = 0,
        framesDropped: UInt64 = 0,
        bytesWritten: UInt64 = 0,
        bytesQueued: UInt64 = 0,
        backpressureEvents: UInt64 = 0,
        lastRenderStats: AnsiDiffRenderStats = AnsiDiffRenderStats()
    ) {
        self.framesSubmitted = framesSubmitted
        self.framesPresented = framesPresented
        self.framesSkipped = framesSkipped
        self.framesDropped = framesDropped
        self.bytesWritten = bytesWritten
        self.bytesQueued = bytesQueued
        self.backpressureEvents = backpressureEvents
        self.lastRenderStats = lastRenderStats
    }
}

/// Errors raised by `NativeSession`.
public enum NativeSessionError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
    case invalidOption(String)
    case sinkNotWritable
    case closingOrDisposed
    case writeExceedsLimit(requested: Int, limit: UInt64)
    case transitionPending
    case closeInterrupted
    case closeLate
    case closeTimedOut
    case disposedWithoutClose
    case rendererNotAttached
    case invalidDimensions(width: Int, height: Int)
    case sinkClosed
    case custom(String)

    public var description: String {
        switch self {
        case .invalidOption(let msg): return msg
        case .sinkNotWritable: return "NativeSession sink is not writable"
        case .closingOrDisposed: return "NativeSession is closing or disposed"
        case .writeExceedsLimit(let req, let limit):
            return "NativeSession write of \(req) bytes exceeds max atomic write limit \(limit)"
        case .transitionPending: return "NativeSession terminal transition is pending"
        case .closeInterrupted: return "NativeSession terminal transition interrupted by close"
        case .closeLate: return "NativeSession graceful close ran late; queued output was dropped"
        case .closeTimedOut: return "NativeSession graceful close timed out; output cancelled without restoration"
        case .disposedWithoutClose: return "NativeSession disposed without graceful close"
        case .rendererNotAttached: return "NativeSession has no attached renderer"
        case .invalidDimensions(let w, let h): return "Invalid session dimensions: \(w)x\(h)"
        case .sinkClosed: return "NativeSession sink closed before graceful close"
        case .custom(let msg): return msg
        }
    }
}

// MARK: - NativeSession

/// Pure-Swift terminal session coordinator matching `core/src/NativeSession.ts`.
// parity: core/src/NativeSession.ts#NativeSession [status=adapted hash=f20328928d0c]
public final class NativeSession: @unchecked Sendable {
    public let resourceContext: NativeResourceContext
    public let scheduler: any NativeSessionScheduler
    public let maxWriteBytes: UInt64
    public let maxAtomicWriteBytes: UInt64
    public var imageUploadsPending: Int = 0

    private let sink: any NativeSessionOutputSink
    private let runtime: NativeSessionRuntime
    private let nativeSession: SessionHandle
    private weak var owner: NativeSession?
    private var detachedSessions: [ObjectIdentifier: NativeSession] = [:]

    private let outputBufferSize: Int
    private let closeTimeoutNs: UInt64
    private var attachmentCleanup: (() -> Void)?

    public private(set) var diffRenderer: AnsiDiffRenderer?
    public private(set) var rendererState: NativeSessionRendererState = NativeSessionRendererState()
    public private(set) var state: NativeSessionState = .open
    public private(set) var terminalPhase: NativeSessionTerminalPhase = .uninitialized
    public private(set) var terminalOptions: NativeSessionTerminalOptions = NativeSessionTerminalOptions()
    public private(set) var capabilities: NativeSessionCapabilities
    public private(set) var palette: NormalizedTerminalPalette?
    public private(set) var themeMode: ThemeMode?
    public private(set) var metrics: NativeSessionMetrics = NativeSessionMetrics()

    private var kittyTransport = NativeSessionKittyImageTransportStatus()
    private var kittyRepliesReceived: Int = 0
    private var kittyFileProbeStarted: Bool = false

    // Bounded output queue for backpressure simulation & ordered presentation
    private var queuedOutput: [[UInt8]] = []
    private var queuedByteCount: UInt64 = 0
    private var blocked: Bool = false
    private var closeDeadlineNs: UInt64?
    private var closeCapNs: UInt64?
    private var closeLate: NativeSessionError?
    private var closeInterruption: NativeSessionError?
    private var closeRequested: Bool = false
    private var stopped: Bool = false
    private var exiting: Bool = false
    private var finishing: Bool = false
    private var _disposed: Bool = false
    private var _error: NativeSessionError?

    // Input stream attachment
    private var inputParser: StdinParser?
    private var inputEventListeners: [(StdinEvent) -> Void] = []

    // Async waiters
    private var idleContinuations: [CheckedContinuation<Void, any Error>] = []
    private var presentationContinuations: [CheckedContinuation<Void, any Error>] = []

    public init(
        sink: any NativeSessionOutputSink = MemorySessionOutputSink(),
        options: NativeSessionDriverOptions = NativeSessionDriverOptions(),
        owner: NativeSession? = nil,
        runtime: NativeSessionRuntime? = nil
    ) throws {
        let rt = runtime ?? owner?.runtime ?? NativeSessionRuntime()
        try rt.getYogaHost().assertMutable()
        guard options.outputBufferSize > 0 else {
            throw NativeSessionError.invalidOption("NativeSession outputBufferSize must be positive")
        }
        guard options.closeTimeoutMs >= 0 else {
            throw NativeSessionError.invalidOption("NativeSession closeTimeoutMs must be non-negative")
        }
        guard sink.isWritable && !sink.isDestroyed && !sink.isEnded else {
            throw NativeSessionError.sinkNotWritable
        }
        if let owner {
            try owner.checkOpen()
        }

        self.sink = sink
        self.runtime = rt
        self.owner = owner
        self.outputBufferSize = options.outputBufferSize
        self.closeTimeoutNs = UInt64(options.closeTimeoutMs) * 1_000_000
        self.scheduler = options.scheduler ?? ClockNativeSessionScheduler()
        self.maxWriteBytes = options.output.maxBytes
        let reservedControl = UInt64(min(options.output.controlCapacity, Int(options.output.maxBytes)))
        self.maxAtomicWriteBytes = options.output.maxBytes > reservedControl
            ? (options.output.maxBytes - reservedControl)
            : options.output.maxBytes
        self.resourceContext = owner?.resourceContext ?? NativeResourceContext(options: options.context)
        self.nativeSession = self.resourceContext.allocateSessionHandle()
        self.capabilities = NativeSessionCapabilities(capabilities: options.capabilities, kittyKeyboardFlags: 0)
        self.palette = options.palette
        self.themeMode = options.themeMode
        self.blocked = sink.needsDrain

        sink.onDrain = { [weak self] in
            guard let self, !self.stopped else { return }
            self.blocked = false
            self.flushOutput()
        }
        sink.onError = { [weak self] err in
            guard let self else { return }
            if !self.stopped && self._error == nil {
                self._error = err
                self.finish(error: err)
            }
        }
        sink.onClose = { [weak self] in
            guard let self else { return }
            if !self.stopped && !self.closeRequested {
                let err = NativeSessionError.sinkClosed
                self._error = self._error ?? err
                self.finish(error: err)
            }
        }

        owner?.detachedSessions[ObjectIdentifier(self)] = self

        if let w = options.width, let h = options.height, w > 0, h > 0 {
            try attachRenderer(NativeSessionRendererOptions(width: w, height: h, widthMethod: options.widthMethod))
        }
    }

    // MARK: Core Identity & State Getters

    // parity: core/src/NativeSession.ts#NativeSession.context [status=implemented hash=4c68aa71b1ff]
    public var context: NativeContextHandle {
        resourceContext.context
    }

    // parity: core/src/NativeSession.ts#NativeSession.renderLib [status=adapted hash=8073c4aead48]
    public var renderLib: NativeSessionRuntime {
        runtime
    }

    // parity: core/src/NativeSession.ts#NativeSession.session [status=implemented hash=5c488d86774e]
    public var session: SessionHandle {
        nativeSession
    }

    // parity: core/src/NativeSession.ts#NativeSession.disposed [status=implemented hash=8bcd778b3586]
    public var disposed: Bool {
        _disposed
    }

    // parity: core/src/NativeSession.ts#NativeSession.contextDisposed [status=implemented hash=377264186362]
    public var contextDisposed: Bool {
        resourceContext.disposed
    }

    // parity: core/src/NativeSession.ts#NativeSession.error [status=implemented hash=e8e553fa3c2a]
    public var error: NativeSessionError? {
        _error
    }

    // parity: core/src/NativeSession.ts#NativeSession.open [status=implemented hash=0d7a6bcb7ae1]
    public var open: Bool {
        _error == nil && !closeRequested && !exiting && !_disposed && !stopped
    }

    // parity: core/src/NativeSession.ts#NativeSession.usesOutput [status=implemented hash=0d6c2f64ffb0]
    public func usesOutput(_ candidate: any NativeSessionOutputSink) -> Bool {
        sink === candidate
    }

    // MARK: Renderer Attachment & Detached Sub-Sessions

    // parity: core/src/NativeSession.ts#NativeSession.attachRenderer [status=implemented hash=6072a67a9da0]
    public func attachRenderer(
        _ options: NativeSessionRendererOptions,
        beforeDispose: (() -> Void)? = nil
    ) throws {
        try checkOpen()
        guard options.width > 0 && options.height > 0 else {
            throw NativeSessionError.invalidDimensions(width: options.width, height: options.height)
        }
        let rendererCaps = RendererCapabilities(
            rgb: capabilities.capabilities.rgb,
            ansi256: capabilities.capabilities.ansi256,
            hyperlinks: capabilities.capabilities.hyperlinks,
            synchronizedOutput: capabilities.capabilities.sync,
            explicitWidth: capabilities.capabilities.explicitWidth,
            explicitCursorPositioning: capabilities.capabilities.explicitCursorPositioning
        )
        let renderer = AnsiDiffRenderer(
            width: options.width,
            height: options.height,
            widthMethod: options.widthMethod,
            backgroundColor: options.backgroundColor,
            capabilities: rendererCaps,
            graphemePool: resourceContext.graphemePool,
            linkPool: resourceContext.linkPool
        )
        if let palette {
            renderer.setPalette(palette.palette)
        }
        self.diffRenderer = renderer
        self.rendererState = NativeSessionRendererState(
            width: options.width,
            height: options.height,
            frameCount: 0,
            framePending: false,
            imageUploadsPending: 0,
            droppedFrames: 0,
            droppedFrameBytes: 0
        )
        self.attachmentCleanup = beforeDispose
    }

    // parity: core/src/NativeSession.ts#NativeSession.createDetached [status=implemented hash=b5d7375383a4]
    public func createDetached(
        _ options: NativeSessionRendererOptions,
        beforeDispose: @escaping () -> Void
    ) throws -> NativeSession {
        try checkOpen()
        let detached = try NativeSession(
            sink: MemorySessionOutputSink(),
            options: NativeSessionDriverOptions(
                output: NativeSessionOutputOptions(chunkSize: 4096, spanCapacity: 2, maxBytes: 8192, controlCapacity: 0),
                outputBufferSize: 4096,
                scheduler: scheduler
            ),
            owner: self,
            runtime: runtime
        )
        do {
            try detached.attachRenderer(options, beforeDispose: beforeDispose)
            return detached
        } catch {
            detached.dispose()
            throw error
        }
    }

    // MARK: Terminal Lifecycle (start / setupTerminal / suspend / resume)

    /// Convenience lifecycle starter matching `setupTerminal`.
    public func start(_ options: NativeSessionTerminalOptions = NativeSessionTerminalOptions()) throws {
        try setupTerminal(options)
    }

    // parity: core/src/NativeSession.ts#NativeSession.setupTerminal [status=adapted hash=4e2c1c880445]
    public func setupTerminal(_ options: NativeSessionTerminalOptions = NativeSessionTerminalOptions()) throws {
        try checkOpen()
        if terminalPhase == .active { return }
        self.terminalOptions = options
        self.terminalPhase = .settingUp

        var seq = ""
        if options.useAlternateScreen {
            seq.append(ANSI.switchToAlternateScreen)
        }
        if options.mouse {
            seq.append("\u{1B}[?1000h\u{1B}[?1006h")
            if options.mouseMovement {
                seq.append("\u{1B}[?1003h")
            } else {
                seq.append("\u{1B}[?1002h")
            }
        }
        if options.kittyKeyboardFlags != 0 {
            seq.append("\u{1B}[>\(options.kittyKeyboardFlags)u")
            capabilities.kittyKeyboardFlags = options.kittyKeyboardFlags
        }
        if options.replySentinel {
            seq.append("\u{1B}[c")
        }
        if let renderer = diffRenderer {
            switch options.synchronizedOutput {
            case .always:
                renderer.capabilities.synchronizedOutput = true
            case .never:
                renderer.capabilities.synchronizedOutput = false
            case .auto:
                renderer.capabilities.synchronizedOutput = capabilities.capabilities.sync && !options.hostMultiplexer
            }
        }

        if !seq.isEmpty {
            _ = try enqueueAndFlush(Array(seq.utf8))
        }
        self.terminalPhase = .active
    }

    // parity: core/src/NativeSession.ts#NativeSession.suspend [status=adapted hash=34a6a924e63b]
    public func suspend() throws {
        try checkOpen()
        if terminalPhase == .suspended { return }
        terminalPhase = .suspending
        inputParser?.suspend()
        let restoreSeq = buildRestoreSequence(clearScreen: false)
        if !restoreSeq.isEmpty {
            _ = try enqueueAndFlush(Array(restoreSeq.utf8))
        }
        terminalPhase = .suspended
    }

    // parity: core/src/NativeSession.ts#NativeSession.resume [status=adapted hash=cc9c365e1001]
    public func resume() throws {
        try checkOpen()
        if terminalPhase == .active { return }
        terminalPhase = .resuming
        inputParser?.resume()
        let setupOpts = terminalOptions
        var seq = ""
        if setupOpts.useAlternateScreen {
            seq.append(ANSI.switchToAlternateScreen)
        }
        if setupOpts.mouse {
            seq.append("\u{1B}[?1000h\u{1B}[?1006h")
            seq.append(setupOpts.mouseMovement ? "\u{1B}[?1003h" : "\u{1B}[?1002h")
        }
        if setupOpts.kittyKeyboardFlags != 0 {
            seq.append("\u{1B}[>\(setupOpts.kittyKeyboardFlags)u")
        }
        if !seq.isEmpty {
            _ = try enqueueAndFlush(Array(seq.utf8))
        }
        diffRenderer?.invalidate()
        terminalPhase = .active
    }

    // MARK: Frame Submission, Split Render, Screen & Resize

    // parity: core/src/NativeSession.ts#NativeSession.render [status=adapted hash=cc31c57cb3ac]
    @discardableResult
    public func render(
        force: Bool = false,
        frame: NativeSceneFrameRequest? = nil
    ) throws -> NativeSessionRenderStatus {
        try checkOpen()
        guard let renderer = diffRenderer else {
            throw NativeSessionError.rendererNotAttached
        }
        _ = frame
        metrics.framesSubmitted &+= 1

        let ansi = renderer.render(force: force, clearNextAfterRender: false)
        metrics.lastRenderStats = renderer.stats
        rendererState.frameCount &+= 1

        if ansi.isEmpty {
            metrics.framesSkipped &+= 1
            rendererState.framePending = false
            completePresentationWaiters()
            return .skipped
        }

        let bytes = Array(ansi.utf8)
        if UInt64(bytes.count) > maxAtomicWriteBytes {
            metrics.framesDropped &+= 1
            rendererState.droppedFrames += 1
            rendererState.droppedFrameBytes = bytes.count
            return .failed
        }

        if queuedByteCount + UInt64(bytes.count) > maxWriteBytes {
            metrics.backpressureEvents &+= 1
            metrics.framesSkipped &+= 1
            return .skipped
        }

        let flushedImmediately = enqueueBytes(bytes)
        if flushedImmediately {
            metrics.framesPresented &+= 1
            rendererState.framePending = false
            completePresentationWaiters()
            return .presented
        } else {
            rendererState.framePending = true
            return .pending
        }
    }

    // parity: core/src/NativeSession.ts#NativeSession.renderSplit [status=adapted hash=f11c46f2bb9b]
    @discardableResult
    public func renderSplit(
        frame: NativeSceneFrameRequest?,
        commits: [NativeSplitSnapshot],
        pinnedRenderOffset: Int,
        force: Bool
    ) throws -> (status: NativeSessionRenderStatus, bytesEmitted: Int) {
        try checkOpen()
        var totalBytes = 0
        for snap in commits {
            var out = ""
            if snap.startOnNewLine { out.append("\r\n") }
            out.append(snap.buffer.getPlainText(trimTrailingSpaces: true))
            if snap.trailingNewline { out.append("\r\n") }
            let raw = Array(out.utf8)
            totalBytes += raw.count
            if !raw.isEmpty {
                _ = try enqueueAndFlush(raw)
            }
        }
        if let renderer = diffRenderer {
            renderer.renderOffset = max(0, pinnedRenderOffset)
            let status = try render(force: force, frame: frame)
            totalBytes += renderer.stats.bytesEmitted
            return (status, totalBytes)
        }
        return (.presented, totalBytes)
    }

    // parity: core/src/NativeSession.ts#NativeSession.setScreen [status=adapted hash=24d7f991a2b2]
    public func setScreen(
        alternate: Bool,
        width: Int,
        height: Int,
        trailingOutput: [UInt8]? = nil
    ) throws {
        try checkOpen()
        terminalOptions.useAlternateScreen = alternate
        var bytes = Array((alternate ? ANSI.switchToAlternateScreen : ANSI.switchToMainScreen).utf8)
        if let trailingOutput, !trailingOutput.isEmpty {
            bytes.append(contentsOf: trailingOutput)
        }
        _ = try enqueueAndFlush(bytes)
        if diffRenderer != nil && width > 0 && height > 0 {
            try resize(width: width, height: height)
        }
    }

    // parity: core/src/NativeSession.ts#NativeSession.whenPresented [status=adapted hash=9d6fc0cce5f2]
    public func whenPresented() async throws {
        try checkOpen()
        if !rendererState.framePending {
            imageUploadsPending = rendererState.imageUploadsPending
            return
        }
        try await withCheckedThrowingContinuation { continuation in
            if !rendererState.framePending {
                continuation.resume()
            } else {
                presentationContinuations.append(continuation)
            }
        }
    }

    // parity: core/src/NativeSession.ts#NativeSession.resize [status=implemented hash=c276693c9ba8]
    public func resize(width: Int, height: Int) throws {
        try checkOpen()
        guard width > 0 && height > 0 else {
            throw NativeSessionError.invalidDimensions(width: width, height: height)
        }
        if let renderer = diffRenderer {
            try renderer.resize(width: width, height: height)
        }
        rendererState.width = width
        rendererState.height = height
    }

    // MARK: Controls, Clipboard, Notifications & Program Status

    // parity: core/src/NativeSession.ts#NativeSession.control [status=adapted hash=7435bf00dbf8]
    public func control(_ command: NativeSessionControl) throws {
        try checkOpen()
        switch command {
        case .capabilityResponse(let bytes):
            applyCapabilityResponse(bytes)
        case .paletteQuery(let bytes, let sentinel):
            var payload = bytes
            if sentinel { payload.append(contentsOf: "\u{1B}[c".utf8) }
            _ = try enqueueAndFlush(payload)
        case .title(let title):
            let seq = "\u{1B}]0;\(title)\u{07}"
            _ = try enqueueAndFlush(Array(seq.utf8))
        case .mouse(let mode):
            let seq: String
            switch mode {
            case .disabled:
                seq = "\u{1B}[?1003l\u{1B}[?1002l\u{1B}[?1000l\u{1B}[?1006l"
            case .drag:
                seq = "\u{1B}[?1000h\u{1B}[?1002h\u{1B}[?1006h"
            case .motion:
                seq = "\u{1B}[?1000h\u{1B}[?1003h\u{1B}[?1006h"
            }
            _ = try enqueueAndFlush(Array(seq.utf8))
        case .kittyKeyboardFlags(let flags):
            capabilities.kittyKeyboardFlags = flags
            let seq = flags == 0 ? "\u{1B}[<u" : "\u{1B}[>\(flags)u"
            _ = try enqueueAndFlush(Array(seq.utf8))
        case .programStatus(let status):
            _ = try setProgramStatus(status)
        case .queryPixelResolution(let sentinel):
            var seq = "\u{1B}[14t"
            if sentinel { seq.append("\u{1B}[c") }
            _ = try enqueueAndFlush(Array(seq.utf8))
        case .queryThemeColors(let sentinel):
            var seq = "\u{1B}]10;?\u{07}\u{1B}]11;?\u{07}"
            if sentinel { seq.append("\u{1B}[c") }
            _ = try enqueueAndFlush(Array(seq.utf8))
        case .restoreModes:
            let seq = buildRestoreSequence(clearScreen: false)
            if !seq.isEmpty { _ = try enqueueAndFlush(Array(seq.utf8)) }
        case .resetBackground:
            _ = try enqueueAndFlush(Array(ANSI.resetBackground.utf8))
        case .endReplySentinel:
            _ = try enqueueAndFlush(Array("\u{1B}[c".utf8))
        }
    }

    // parity: core/src/NativeSession.ts#NativeSession.writeClipboard [status=implemented hash=5f8b3bb325cb]
    @discardableResult
    public func writeClipboard(target: ClipboardTarget = .clipboard, bytes: [UInt8]) throws -> Bool {
        try checkOpen()
        let text = String(decoding: bytes, as: UTF8.self)
        let seq = Osc52Clipboard.encodeCopy(text, target: target)
        let raw = Array(seq.utf8)
        guard queuedByteCount + UInt64(raw.count) <= maxWriteBytes else {
            metrics.backpressureEvents &+= 1
            return false
        }
        _ = enqueueBytes(raw)
        return true
    }

    // parity: core/src/NativeSession.ts#NativeSession.triggerNotification [status=implemented hash=17f2aa92e781]
    @discardableResult
    public func triggerNotification(message: String, title: String? = nil) throws -> Bool {
        try checkOpen()
        let seq: String
        if let title, !title.isEmpty {
            seq = "\u{1B}]777;notify;\(title);\(message)\u{07}"
        } else {
            seq = "\u{1B}]9;\(message)\u{07}"
        }
        let raw = Array(seq.utf8)
        guard queuedByteCount + UInt64(raw.count) <= maxWriteBytes else {
            metrics.backpressureEvents &+= 1
            return false
        }
        _ = enqueueBytes(raw)
        return true
    }

    // parity: core/src/NativeSession.ts#NativeSession.setProgramStatus [status=implemented hash=f7f341d3f62b]
    @discardableResult
    public func setProgramStatus(_ status: ProgramStatus) throws -> Bool {
        try checkOpen()
        guard terminalPhase == .active || terminalPhase == .uninitialized else {
            return false
        }
        var fields: [String] = ["state=\(status.state.rawValue)"]
        if let id = status.id { fields.append("id=\(id)") }
        if let app = status.app { fields.append("app=\(app)") }
        if let title = status.title { fields.append("title=\(title)") }
        if let message = status.message { fields.append("message=\(message)") }
        if let kind = status.kind { fields.append("kind=\(kind.rawValue)") }
        if let progress = status.progress, progress.isFinite {
            fields.append("progress=\(progress)")
        }
        let seq = "\u{1B}]7501;\(fields.joined(separator: ";"))\u{1B}\\"
        let raw = Array(seq.utf8)
        guard queuedByteCount + UInt64(raw.count) <= maxWriteBytes else {
            metrics.backpressureEvents &+= 1
            return false
        }
        _ = enqueueBytes(raw)
        return true
    }

    // MARK: Kitty Image Transport

    // parity: core/src/NativeSession.ts#NativeSession.setKittyImageTransport [status=implemented hash=f418693cd432]
    public func setKittyImageTransport(mode: Int) throws {
        try checkOpen()
        kittyTransport.requested = mode
        kittyTransport.effective = mode
    }

    // parity: core/src/NativeSession.ts#NativeSession.getKittyImageTransport [status=implemented hash=e72ce8f6ea35]
    public func getKittyImageTransport() throws -> NativeSessionKittyImageTransportStatus {
        try checkOpen()
        return kittyTransport
    }

    // parity: core/src/NativeSession.ts#NativeSession.pollKittyImageTransport [status=implemented hash=432f620bec3a]
    public func pollKittyImageTransport() throws -> Bool {
        try checkOpen()
        _ = scheduler.now()
        return kittyTransport.pendingFiles > 0 || kittyFileProbeStarted
    }

    // parity: core/src/NativeSession.ts#NativeSession.cancelKittyImageTransport [status=implemented hash=d123aad67f56]
    public func cancelKittyImageTransport(failed: Bool) throws {
        try checkOpen()
        kittyTransport.pendingFiles = 0
        kittyTransport.pendingBytes = 0
        kittyFileProbeStarted = false
        if failed {
            kittyTransport.fallback = 1
        }
    }

    // parity: core/src/NativeSession.ts#NativeSession.processKittyImageReply [status=implemented hash=1f2d8e75a329]
    @discardableResult
    public func processKittyImageReply(_ bytes: [UInt8]) throws -> Int {
        try checkOpen()
        let text = String(decoding: bytes, as: UTF8.self)
        guard text.contains("\u{1B}_G") else { return 0 }
        kittyRepliesReceived += 1
        if kittyFileProbeStarted {
            kittyFileProbeStarted = false
            kittyTransport.fileState = text.contains("OK") ? 2 : 3
        }
        return kittyRepliesReceived
    }

    // parity: core/src/NativeSession.ts#NativeSession.startKittyFileProbe [status=implemented hash=1c94a8e3a2f2]
    public func startKittyFileProbe() throws {
        try checkOpen()
        kittyFileProbeStarted = true
        kittyTransport.fileState = 1
        _ = try enqueueAndFlush(Array("\u{1B}_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\u{1B}\\".utf8))
    }

    // MARK: Capabilities, Palette, Theme Mode & Input Stream

    // parity: core/src/NativeSession.ts#NativeSession.getCapabilities [status=implemented hash=bc7f206717dc]
    public func getCapabilities() throws -> NativeSessionCapabilities {
        try checkOpen()
        return capabilities
    }

    public func setCapabilities(_ newCapabilities: TerminalCapabilities) {
        capabilities.capabilities = newCapabilities
        if let renderer = diffRenderer {
            renderer.capabilities.rgb = newCapabilities.rgb
            renderer.capabilities.ansi256 = newCapabilities.ansi256
            renderer.capabilities.hyperlinks = newCapabilities.hyperlinks
            renderer.capabilities.explicitWidth = newCapabilities.explicitWidth
            renderer.capabilities.explicitCursorPositioning = newCapabilities.explicitCursorPositioning
        }
    }

    public func setPalette(_ newPalette: NormalizedTerminalPalette) {
        palette = newPalette
        diffRenderer?.setPalette(newPalette.palette)
    }

    public func setThemeMode(_ mode: ThemeMode?) {
        themeMode = mode
    }

    /// Attaches an input parser and event subscriber to receive decoded stdin events.
    public func attachInput(
        parser: StdinParser? = nil,
        onEvent: @escaping (StdinEvent) -> Void
    ) {
        if let parser {
            self.inputParser = parser
        } else if self.inputParser == nil {
            self.inputParser = StdinParser()
        }
        inputEventListeners.append(onEvent)
    }

    /// Feeds raw terminal input bytes into the attached parser and returns decoded events.
    @discardableResult
    public func feedInput(_ bytes: [UInt8]) -> [StdinEvent] {
        if inputParser == nil {
            inputParser = StdinParser()
        }
        applyCapabilityResponse(bytes)
        let nowMs = Double(scheduler.now()) / 1_000_000.0
        inputParser?.push(bytes, nowMs: nowMs)
        var events: [StdinEvent] = []
        inputParser?.drain { event in
            events.append(event)
            for listener in inputEventListeners {
                listener(event)
            }
        }
        return events
    }

    /// Feeds a UTF-8 input string into the attached parser and returns decoded events.
    @discardableResult
    public func feedInput(_ text: String) -> [StdinEvent] {
        feedInput(Array(text.utf8))
    }

    // MARK: Raw Output, Backpressure & Idle

    // parity: core/src/NativeSession.ts#NativeSession.write [status=implemented hash=438e26829215]
    @discardableResult
    public func write(_ bytes: [UInt8]) throws -> Bool {
        try checkOpen()
        if UInt64(bytes.count) > maxAtomicWriteBytes {
            throw NativeSessionError.writeExceedsLimit(requested: bytes.count, limit: maxAtomicWriteBytes)
        }
        if queuedByteCount + UInt64(bytes.count) > maxWriteBytes {
            metrics.backpressureEvents &+= 1
            return false
        }
        _ = enqueueBytes(bytes)
        return true
    }

    /// Flushes queued output bytes to the sink while unblocked.
    @discardableResult
    public func flushOutput() -> Int {
        var totalWritten = 0
        while !queuedOutput.isEmpty && !blocked && sink.isWritable && !sink.isDestroyed && !sink.isEnded {
            let chunk = queuedOutput.removeFirst()
            let count = UInt64(chunk.count)
            queuedByteCount = queuedByteCount >= count ? (queuedByteCount - count) : 0
            let ready = sink.write(chunk)
            totalWritten += chunk.count
            metrics.bytesWritten &+= count
            metrics.bytesQueued = queuedByteCount
            if !ready || sink.needsDrain {
                blocked = true
                metrics.backpressureEvents &+= 1
                break
            }
        }
        if queuedOutput.isEmpty && !blocked {
            if rendererState.framePending {
                rendererState.framePending = false
                metrics.framesPresented &+= 1
                completePresentationWaiters()
            }
            completeIdleWaiters()
        }
        return totalWritten
    }

    // parity: core/src/NativeSession.ts#NativeSession.idle [status=adapted hash=9b380c7b76dc]
    public func idle() async throws {
        try runtime.getYogaHost().assertMutable()
        if stopped {
            if let err = _error { throw err }
            return
        }
        if queuedOutput.isEmpty && !blocked {
            return
        }
        try await withCheckedThrowingContinuation { continuation in
            if queuedOutput.isEmpty && !blocked {
                continuation.resume()
            } else {
                idleContinuations.append(continuation)
            }
        }
    }

    // MARK: Close, Timeout, Dispose & Exit Restoration

    /// Synchronous graceful close helper (flushes restore sequences and releases resources).
    public func closeSync() throws {
        try runtime.getYogaHost().assertMutable()
        if stopped || closeRequested {
            if let err = _error { throw err }
            return
        }
        closeRequested = true
        state = .closing
        let now = scheduler.now()
        if closeDeadlineNs == nil { closeDeadlineNs = now &+ closeTimeoutNs }
        if closeCapNs == nil { closeCapNs = now &+ (10 &* closeTimeoutNs) }

        if terminalPhase == .active || terminalPhase == .suspended {
            terminalPhase = .closing
            let restoreSeq = buildRestoreSequence(clearScreen: terminalOptions.clearOnClose)
            if !restoreSeq.isEmpty && sink.isWritable && !sink.isDestroyed {
                _ = enqueueBytes(Array(restoreSeq.utf8))
            }
            terminalPhase = .restored
        }
        flushOutput()
        state = .closed
        finish(error: closeLate)
        if let err = _error { throw err }
    }

    // parity: core/src/NativeSession.ts#NativeSession.close [status=adapted hash=6f856c84c819]
    public func close() async throws {
        try closeSync()
    }

    // parity: core/src/NativeSession.ts#NativeSession.armCloseTimeout [status=implemented hash=ce4773ed4ea9]
    public func armCloseTimeout() throws {
        try checkOpen()
        let now = scheduler.now()
        if closeDeadlineNs == nil { closeDeadlineNs = now &+ closeTimeoutNs }
        if closeCapNs == nil { closeCapNs = now &+ (10 &* closeTimeoutNs) }
    }

    // parity: core/src/NativeSession.ts#NativeSession.isCloseInterruption [status=implemented hash=df7ba70fa398]
    public func isCloseInterruption(_ error: (any Error)?) -> Bool {
        guard let sessionError = error as? NativeSessionError else { return false }
        return sessionError == closeInterruption || sessionError == closeLate ||
            sessionError == .closeInterrupted || sessionError == .closeLate
    }

    // parity: core/src/NativeSession.ts#NativeSession.dispose [status=implemented hash=ff15e8429311]
    public func dispose() {
        try? runtime.getYogaHost().assertMutable()
        if state == .open { state = .cancelled }
        finish(error: _error ?? .disposedWithoutClose)
    }

    /// Convenience alias for `dispose()`.
    public func destroy() {
        dispose()
    }

    // parity: core/src/NativeSession.ts#NativeSession.restoreOnExit [status=adapted hash=f3a27328bd91]
    @discardableResult
    public func restoreOnExit() -> Bool {
        if _disposed || finishing { return false }
        exiting = true
        guard _error == nil && sink.isWritable && !sink.isDestroyed && !sink.isEnded else {
            return false
        }
        if closeCapNs != nil {
            queuedOutput.removeAll()
            queuedByteCount = 0
            metrics.bytesQueued = 0
        }
        let restoreSeq = buildRestoreSequence(clearScreen: terminalOptions.clearOnClose)
        if !restoreSeq.isEmpty {
            _ = sink.write(Array(restoreSeq.utf8))
            metrics.bytesWritten &+= UInt64(restoreSeq.utf8.count)
        }
        terminalPhase = .restored
        state = .closed
        return true
    }

    // MARK: Private Helpers

    private func checkOpen() throws {
        try runtime.getYogaHost().assertMutable()
        if let err = _error { throw err }
        if stopped || closeRequested || _disposed {
            throw closeLate ?? NativeSessionError.closingOrDisposed
        }
        if let owner {
            try owner.checkOpen()
        }
    }

    @discardableResult
    private func enqueueBytes(_ bytes: [UInt8]) -> Bool {
        guard !bytes.isEmpty else { return true }
        queuedOutput.append(bytes)
        queuedByteCount &+= UInt64(bytes.count)
        metrics.bytesQueued = queuedByteCount
        if !blocked {
            flushOutput()
        }
        return queuedOutput.isEmpty && !blocked
    }

    @discardableResult
    private func enqueueAndFlush(_ bytes: [UInt8]) throws -> Bool {
        if queuedByteCount + UInt64(bytes.count) > maxWriteBytes {
            metrics.backpressureEvents &+= 1
            return false
        }
        return enqueueBytes(bytes)
    }

    private func buildRestoreSequence(clearScreen: Bool) -> String {
        var seq = ""
        if terminalOptions.kittyKeyboardFlags != 0 {
            seq.append("\u{1B}[<u")
        }
        if terminalOptions.mouse {
            seq.append("\u{1B}[?1003l\u{1B}[?1002l\u{1B}[?1000l\u{1B}[?1006l")
        }
        seq.append("\u{1B}[?25h")
        seq.append(ANSI.reset)
        if clearScreen {
            seq.append(ANSI.clearScreen)
            seq.append(ANSI.home)
        }
        if terminalOptions.useAlternateScreen {
            seq.append(ANSI.switchToMainScreen)
        }
        return seq
    }

    private func applyCapabilityResponse(_ bytes: [UInt8]) {
        let text = String(decoding: bytes, as: UTF8.self)
        if text.contains("\u{1B}[?997;1n") {
            themeMode = .dark
        } else if text.contains("\u{1B}[?997;2n") {
            themeMode = .light
        }
        if text.contains("\u{1B}[?2026;1$y") || text.contains("\u{1B}[?2026;2$y") {
            capabilities.capabilities.sync = true
        }
        if text.contains("\u{1B}_G") && text.contains("OK") {
            capabilities.capabilities.kittyGraphics = true
        }
    }

    private func completePresentationWaiters() {
        guard !presentationContinuations.isEmpty else { return }
        let waiters = presentationContinuations
        presentationContinuations.removeAll()
        for waiter in waiters {
            if let err = _error {
                waiter.resume(throwing: err)
            } else {
                waiter.resume()
            }
        }
    }

    private func completeIdleWaiters() {
        guard !idleContinuations.isEmpty else { return }
        let waiters = idleContinuations
        idleContinuations.removeAll()
        for waiter in waiters {
            if let err = _error {
                waiter.resume(throwing: err)
            } else {
                waiter.resume()
            }
        }
    }

    private func finish(error: NativeSessionError?) {
        if finishing { return }
        if _disposed { return }
        finishing = true
        defer { finishing = false }

        stopped = true
        if _error == nil, error != closeLate {
            _error = error
        }

        // Dispose detached children first.
        let children = Array(detachedSessions.values)
        for child in children {
            child.dispose()
        }
        detachedSessions.removeAll()

        attachmentCleanup?()
        attachmentCleanup = nil

        inputParser?.destroy()
        inputParser = nil
        inputEventListeners.removeAll()

        if owner == nil && !resourceContext.disposed {
            resourceContext.destroy()
        }

        _disposed = true
        owner?.detachedSessions.removeValue(forKey: ObjectIdentifier(self))

        sink.onDrain = nil
        sink.onError = nil
        sink.onClose = nil

        if _error == nil {
            _error = error
        }
        if _error != nil && state != .closed {
            state = .failed
        }

        completePresentationWaiters()
        completeIdleWaiters()
    }
}
