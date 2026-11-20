import OpenTUICore
import OpenTUIKeymap
import OpenTUILayout

// MARK: - Kitty Keyboard Options & Flags

/// Kitty keyboard protocol progressive enhancement flags.
// parity: core/src/renderer.ts#KittyKeyboardOptions [status=implemented hash=0ea09e0015e6]
public struct KittyKeyboardOptions: Equatable, Hashable, Sendable, Codable {
    public var disambiguate: Bool
    public var alternateKeys: Bool
    public var events: Bool
    public var allKeysAsEscapes: Bool
    public var reportText: Bool

    public init(
        disambiguate: Bool = true,
        alternateKeys: Bool = true,
        events: Bool = false,
        allKeysAsEscapes: Bool = false,
        reportText: Bool = false
    ) {
        self.disambiguate = disambiguate
        self.alternateKeys = alternateKeys
        self.events = events
        self.allKeysAsEscapes = allKeysAsEscapes
        self.reportText = reportText
    }
}

public let kittyFlagDisambiguate: UInt32 = 1 << 0
public let kittyFlagEventTypes: UInt32 = 1 << 1
public let kittyFlagAlternateKeys: UInt32 = 1 << 2
public let kittyFlagAllKeysAsEscapes: UInt32 = 1 << 3
public let kittyFlagReportText: UInt32 = 1 << 4

/// Builds Kitty keyboard protocol bitmask from configuration (`nil` returns `0`).
// parity: core/src/renderer.ts#buildKittyKeyboardFlags [status=implemented hash=5f9e03dd7f29]
public func buildKittyKeyboardFlags(_ config: KittyKeyboardOptions?) -> UInt32 {
    guard let config else { return 0 }
    var flags: UInt32 = 0
    if config.disambiguate { flags |= kittyFlagDisambiguate }
    if config.alternateKeys { flags |= kittyFlagAlternateKeys }
    if config.events { flags |= kittyFlagEventTypes }
    if config.allKeysAsEscapes { flags |= kittyFlagAllKeysAsEscapes }
    if config.reportText { flags |= kittyFlagReportText }
    return flags
}

// MARK: - Mouse Event & Buttons

// parity: core/src/renderer.ts#MouseButton [status=implemented hash=e14ca9792f72]
public enum MouseButton: Int, Equatable, Hashable, Sendable, Codable {
    case left = 0
    case middle = 1
    case right = 2
    case wheelUp = 4
    case wheelDown = 5
}

/// Dispatched mouse event carrying target, bubbling state, drag source, and scroll-chain token.
// parity: core/src/renderer.ts#MouseEvent [status=implemented hash=045cba25a6b6]
public final class MouseEvent {
    public let type: MouseEventType
    public let button: Int
    public let x: Int
    public let y: Int
    public let source: Renderable?
    public let modifiers: MouseModifiers
    public let scroll: ScrollInfo?
    public let target: Renderable?
    public internal(set) var currentTarget: Renderable? = nil
    public let isDragging: Bool
    public let scrollChainToken: ScrollChainToken

    private var _propagationStopped: Bool = false
    private var _defaultPrevented: Bool = false

    public init(
        target: Renderable?,
        raw: RawMouseEvent,
        source: Renderable? = nil,
        isDragging: Bool = false,
        scrollChainToken: ScrollChainToken = ScrollChainToken()
    ) {
        self.target = target
        self.type = raw.type
        self.button = raw.button
        self.x = raw.x
        self.y = raw.y
        self.modifiers = raw.modifiers
        self.scroll = raw.scroll
        self.source = source
        self.isDragging = isDragging
        self.scrollChainToken = scrollChainToken
    }

    // parity: core/src/renderer.ts#MouseEvent.propagationStopped [status=implemented hash=e1f44b4f22bf]
    public var propagationStopped: Bool { _propagationStopped }

    // parity: core/src/renderer.ts#MouseEvent.defaultPrevented [status=implemented hash=b9dce979775d]
    public var defaultPrevented: Bool { _defaultPrevented }

    // parity: core/src/renderer.ts#MouseEvent.stopPropagation [status=implemented hash=bee1e9e8ce5f]
    public func stopPropagation() {
        _propagationStopped = true
    }

    // parity: core/src/renderer.ts#MouseEvent.preventDefault [status=implemented hash=68a052b43ad6]
    public func preventDefault() {
        _defaultPrevented = true
    }
}

// MARK: - Modes, Events & Stats

// parity: core/src/renderer.ts#ScreenMode [status=implemented hash=3da5f3e033c6]
public typealias ScreenMode = RenderGeometryScreenMode

// parity: core/src/renderer.ts#ExternalOutputMode [status=implemented hash=bb34026d0960]
public enum ExternalOutputMode: String, Equatable, Hashable, Sendable, Codable {
    case captureStdout = "capture-stdout"
    case passthrough = "passthrough"
}

// parity: core/src/renderer.ts#ConsoleMode [status=implemented hash=7ac2382108ab]
public enum ConsoleMode: String, Equatable, Hashable, Sendable, Codable {
    case consoleOverlay = "console-overlay"
    case disabled = "disabled"
}

// parity: core/src/renderer.ts#CliRenderEvents [status=implemented hash=d95828021a43]
public enum CliRenderEvents: String, Equatable, Hashable, Sendable {
    case resize = "resize"
    case frame = "frame"
    case renderError = "render:error"
    case frameDropped = "frame:dropped"
    case handlerError = "handler:error"
    case externalOutput = "external_output"
    case focus = "focus"
    case blur = "blur"
    case focusedRenderable = "focused_renderable"
    case focusedEditor = "focused_editor"
    case themeMode = "theme_mode"
    case palette = "palette"
    case capabilities = "capabilities"
    case selection = "selection"
    case debugOverlayToggle = "debugOverlay:toggle"
    case destroy = "destroy"
    case memorySnapshot = "memory:snapshot"
}

// parity: core/src/renderer.ts#RendererControlState [status=implemented hash=680b01ef2837]
public enum RendererControlState: String, Equatable, Hashable, Sendable {
    case idle = "idle"
    case autoStarted = "auto_started"
    case explicitStarted = "explicit_started"
    case explicitPaused = "explicit_paused"
    case explicitSuspended = "explicit_suspended"
    case explicitStopped = "explicit_stopped"
}

// parity: core/src/renderer.ts#RendererSchedulerState [status=implemented hash=9548ad0bbff0]
public struct RendererSchedulerState: Equatable, Hashable, Sendable {
    public var isRunning: Bool
    public var isRendering: Bool
    public var hasScheduledRender: Bool

    public init(isRunning: Bool, isRendering: Bool, hasScheduledRender: Bool) {
        self.isRunning = isRunning
        self.isRendering = isRendering
        self.hasScheduledRender = hasScheduledRender
    }
}

// parity: core/src/renderer.ts#CliRendererFrameEvent [status=implemented hash=c516a750a891]
public struct CliRendererFrameEvent: Equatable, Hashable, Sendable {
    public var frameId: Int

    public init(frameId: Int) {
        self.frameId = frameId
    }
}

// parity: core/src/renderer.ts#CliRendererStats [status=adapted hash=6beeae868a2d]
public struct CliRendererStats: Equatable, Sendable {
    public var fps: Double
    public var frameCount: Int
    public var cellsUpdated: Int
    public var bytesEmitted: Int
    public var frameTimes: [Double]
    public var averageFrameTime: Double
    public var minFrameTime: Double
    public var maxFrameTime: Double
    public var frameCallbackTime: Double

    public init(
        fps: Double = 0,
        frameCount: Int = 0,
        cellsUpdated: Int = 0,
        bytesEmitted: Int = 0,
        frameTimes: [Double] = [],
        averageFrameTime: Double = 0,
        minFrameTime: Double = 0,
        maxFrameTime: Double = 0,
        frameCallbackTime: Double = 0
    ) {
        self.fps = fps
        self.frameCount = frameCount
        self.cellsUpdated = cellsUpdated
        self.bytesEmitted = bytesEmitted
        self.frameTimes = frameTimes
        self.averageFrameTime = averageFrameTime
        self.minFrameTime = minFrameTime
        self.maxFrameTime = maxFrameTime
        self.frameCallbackTime = frameCallbackTime
    }
}

// MARK: - CliRendererConfig

/// Configuration options for constructing a `CliRenderer`.
// parity: core/src/renderer.ts#CliRendererConfig [status=adapted hash=223b13c7f64c]
public struct CliRendererConfig {
    public var width: Int
    public var height: Int
    public var screenMode: ScreenMode
    public var footerHeight: Int
    public var externalOutputMode: ExternalOutputMode?
    public var consoleMode: ConsoleMode
    public var exitOnCtrlC: Bool
    public var clearOnShutdown: Bool
    public var debounceDelay: Double
    public var targetFps: Double
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
    public var postProcessFns: [(OptimizedBuffer, Double) -> Void]
    public var prependInputHandlers: [(String) -> Bool]
    public var clock: (any Clock)?
    public var outputWriter: ((String) -> Void)?
    public var onDestroy: (() -> Void)?

    public init(
        width: Int = 80,
        height: Int = 24,
        screenMode: ScreenMode = .alternateScreen,
        footerHeight: Int = 12,
        externalOutputMode: ExternalOutputMode? = nil,
        consoleMode: ConsoleMode = .disabled,
        exitOnCtrlC: Bool = true,
        clearOnShutdown: Bool = true,
        debounceDelay: Double = 100,
        targetFps: Double = 30,
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
        postProcessFns: [(OptimizedBuffer, Double) -> Void] = [],
        prependInputHandlers: [(String) -> Bool] = [],
        clock: (any Clock)? = nil,
        outputWriter: ((String) -> Void)? = nil,
        onDestroy: (() -> Void)? = nil
    ) {
        self.width = width
        self.height = height
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
        self.postProcessFns = postProcessFns
        self.prependInputHandlers = prependInputHandlers
        self.clock = clock
        self.outputWriter = outputWriter
        self.onDestroy = onDestroy
    }
}

// MARK: - CliRenderer

/// Event subscription token returned by `CliRenderer` listener registration methods.
public struct CliRendererListenerToken: Equatable, Hashable, Sendable {
    fileprivate let id: UInt64
    fileprivate let event: String
}

/// Pure-Swift terminal UI renderer coordinating the `RootRenderable` scene graph, Flexbox layout,
/// double-buffered `AnsiDiffRenderer`, hit-test grid, `StdinParser` input routing, mouse/hover/drag/selection,
/// focus management, and theme-mode detection.
// parity: core/src/renderer.ts#CliRenderer [status=adapted hash=1e8ace8854c7]
public final class CliRenderer: RenderContext, RendererThemeModeHost, OscSubscriptionSource, @unchecked Sendable {
    private static let clickRepeatIntervalMs: Double = 500
    private static let animationTimerSlackMs: Double = 1

    private struct HitRect {
        let x: Int
        let y: Int
        let width: Int
        let height: Int
        let id: UInt32
    }

    private struct LastClickState {
        let count: Int
        let time: Double
        let x: Int
        let y: Int
        let renderableNum: UInt32
    }

    private final class AnimationTicker {
        let id: UInt64
        let fps: Double
        let window: Double
        var next: Int
        var last: Double
        let callback: AnimationTickCallback

        init(id: UInt64, fps: Double, window: Double, next: Int, last: Double, callback: @escaping AnimationTickCallback) {
            self.id = id
            self.fps = fps
            self.window = window
            self.next = next
            self.last = last
            self.callback = callback
        }
    }

    private struct InputHandlerEntry {
        let id: UInt64
        let handler: (String) -> Bool
    }

    private struct OscSubscriberEntry {
        let id: UInt64
        let handler: (String) -> Void
    }

    private struct PostProcessEntry {
        let id: UInt64
        let fn: (OptimizedBuffer, Double) -> Void
    }

    // Core owned subsystems
    public private(set) var root: RootRenderable!
    public let diffRenderer: AnsiDiffRenderer
    public var currentRenderBuffer: OptimizedBuffer { diffRenderer.currentBuffer }
    public var nextRenderBuffer: OptimizedBuffer { diffRenderer.nextBuffer }
    public var graphemePool: GraphemePool { diffRenderer.graphemePool }
    public var linkPool: LinkPool { diffRenderer.linkPool }

    public private(set) var hitGrid: [UInt32]
    private var activeFrameHitRects: [HitRect] = []
    private var presentedHitRects: [HitRect] = []

    public let internalKeyInput: InternalKeyHandler
    // parity: core/src/renderer.ts#CliRenderer.keyInput [status=implemented hash=c56ec834956f]
    public var keyInput: KeyHandler { internalKeyInput }

    public private(set) var stdinParser: StdinParser
    private var stdinTimeoutHandle: TimerHandle? = nil

    public let clock: any Clock
    public var outputWriter: ((String) -> Void)?

    public private(set) var themeModeState: RendererThemeMode!

    // Geometry & modes
    public private(set) var width: Int
    public private(set) var height: Int
    private var _terminalWidth: Int
    private var _terminalHeight: Int
    private var _screenMode: ScreenMode
    private var _footerHeight: Int
    private var _externalOutputMode: ExternalOutputMode
    private var _renderOffset: Int = 0
    private var _splitHeight: Int = 0
    private var _resolution: PixelResolution? = nil

    // Lifecycle & scheduler state
    private var _isDestroyed: Bool = false
    private var _isRunning: Bool = false
    private var _controlState: RendererControlState = .idle
    private var _previousControlState: RendererControlState = .idle
    private var _suspendedMouseEnabled: Bool = true
    private var rendering: Bool = false
    private var immediateRerenderRequested: Bool = false
    private var forceFullRepaintRequested: Bool = false
    private var renderTimeout: TimerHandle? = nil
    private var resizeTimeoutId: TimerHandle? = nil
    private var pendingResize: (width: Int, height: Int)? = nil
    private var resizeDebounceDelay: Double

    private var _frameId: Int = 0
    private var lastTime: Double = 0
    private var frameCount: Int = 0
    private var totalFrameCount: Int = 0
    private var lastFpsTime: Double = 0
    private var currentFps: Double = 0
    private var _targetFps: Double
    private var _maxFps: Double
    private var targetFrameTime: Double
    private var minTargetFrameTime: Double
    private var gatherStats: Bool
    private var maxStatSamples: Int
    private var frameTimes: [Double] = []
    private var lastFrameCallbackTime: Double = 0

    // Live requests & animation
    private var liveRequestCounter: Int = 0
    private var nextAnimationFrameId: Int = 1
    private var animationRequests: [(id: Int, callback: FrameRequestCallback)] = []
    private var nextAnimationTickerId: UInt64 = 1
    private var animationTickers: [AnimationTicker] = []
    private var animationTimer: TimerHandle? = nil
    private var frameCallbacks: [(Double) -> Void] = []

    // Post-process & lifecycle passes
    private var nextPostProcessId: UInt64 = 1
    private var postProcessEntries: [PostProcessEntry] = []
    private var lifecyclePasses: [Renderable] = []

    // Input & mouse & selection & focus
    private var exitOnCtrlC: Bool
    private var clearOnShutdown: Bool
    private var _useMouse: Bool
    private var enableMouseMovement: Bool
    private var autoFocus: Bool
    private var kittyKeyboardFlags: UInt32
    private var _capabilities: TerminalCapabilities?
    private var _currentMousePointerStyle: MousePointerStyle? = nil
    private var _terminalFocusState: Bool? = nil

    private var nextHandlerId: UInt64 = 1
    private var sequenceHandlers: [InputHandlerEntry] = []
    private var oscSubscribers: [OscSubscriberEntry] = []

    private var _currentFocusedRenderable: Renderable? = nil
    private var pressedRenderable: Renderable? = nil
    private var capturedRenderable: Renderable? = nil
    private var lastDrag: RawMouseEvent? = nil
    private var lastOverRenderableNum: UInt32 = 0
    private var lastOverRenderable: Renderable? = nil
    private var latestPointer: (x: Int, y: Int) = (0, 0)
    private var hasPointer: Bool = false
    private var lastPointerModifiers: MouseModifiers = MouseModifiers()

    private var currentSelection: Selection? = nil
    private var selectionContainers: [Renderable] = []
    private var lastClick: LastClickState? = nil

    private var paletteCache: [Int: TerminalColors] = [:]
    private var onDestroyCallback: (() -> Void)?

    // Typed event listeners
    private var nextListenerId: UInt64 = 1
    private var voidListeners: [String: [(id: UInt64, fn: () -> Void)]] = [:]
    private var frameListeners: [(id: UInt64, fn: (CliRendererFrameEvent) -> Void)] = []
    private var resizeListeners: [(id: UInt64, fn: (Int, Int) -> Void)] = []
    private var themeModeListeners: [(id: UInt64, fn: (ThemeMode) -> Void)] = []
    private var selectionListeners: [(id: UInt64, fn: (Selection) -> Void)] = []
    private var focusRenderableListeners: [(id: UInt64, fn: (Renderable?, Renderable?) -> Void)] = []

    public init(config: CliRendererConfig = CliRendererConfig()) {
        let initialWidth = max(1, config.width)
        let initialHeight = max(1, config.height)
        let normalizedFooterHeight = max(1, config.footerHeight)
        let geometry = calculateRenderGeometry(
            screenMode: config.screenMode,
            terminalWidth: initialWidth,
            terminalHeight: initialHeight,
            footerHeight: normalizedFooterHeight
        )
        let renderWidth = max(1, geometry.renderWidth)
        let renderHeight = max(1, geometry.renderHeight)

        self._terminalWidth = initialWidth
        self._terminalHeight = initialHeight
        self._screenMode = config.screenMode
        self._footerHeight = normalizedFooterHeight
        self._externalOutputMode = config.externalOutputMode ?? (config.screenMode == .splitFooter ? .captureStdout : .passthrough)
        self._splitHeight = geometry.effectiveFooterHeight
        self._renderOffset = geometry.renderOffset
        self.width = renderWidth
        self.height = renderHeight

        self.clock = config.clock ?? SystemClock()
        self.outputWriter = config.outputWriter
        self.exitOnCtrlC = config.exitOnCtrlC
        self.clearOnShutdown = config.clearOnShutdown
        self.resizeDebounceDelay = max(0, config.debounceDelay)
        self._targetFps = config.targetFps > 0 ? config.targetFps : 30
        self._maxFps = config.maxFps > 0 ? config.maxFps : 60
        self.targetFrameTime = 1000.0 / self._targetFps
        self.minTargetFrameTime = 1000.0 / self._maxFps
        self.gatherStats = config.gatherStats
        self.maxStatSamples = max(1, config.maxStatSamples)
        self.enableMouseMovement = config.enableMouseMovement
        self._useMouse = config.useMouse
        self.autoFocus = config.autoFocus
        self.kittyKeyboardFlags = buildKittyKeyboardFlags(config.useKittyKeyboard)
        self.onDestroyCallback = config.onDestroy

        self.diffRenderer = AnsiDiffRenderer(
            width: renderWidth,
            height: renderHeight,
            widthMethod: config.widthMethod,
            backgroundColor: config.backgroundColor,
            capabilities: config.rendererCapabilities
        )
        self.diffRenderer.renderOffset = self._renderOffset
        self.hitGrid = Array(repeating: 0, count: renderWidth * renderHeight)

        self.internalKeyInput = InternalKeyHandler()
        self.stdinParser = StdinParser(
            options: StdinParserOptions(
                protocolContext: StdinParserProtocolContext(
                    kittyKeyboardEnabled: self.kittyKeyboardFlags != 0
                )
            )
        )
        self._capabilities = TerminalCapabilities(
            kittyKeyboard: self.kittyKeyboardFlags != 0,
            rgb: config.rendererCapabilities.rgb,
            ansi256: config.rendererCapabilities.ansi256,
            unicode: config.widthMethod,
            explicitWidth: config.rendererCapabilities.explicitWidth,
            sync: config.rendererCapabilities.synchronizedOutput,
            hyperlinks: config.rendererCapabilities.hyperlinks,
            explicitCursorPositioning: config.rendererCapabilities.explicitCursorPositioning
        )

        self.lastTime = self.clock.now()
        self.lastFpsTime = self.lastTime

        self.themeModeState = RendererThemeMode(host: self, clock: self.clock)
        self.root = RootRenderable(ctx: self)

        for fn in config.postProcessFns {
            _ = addPostProcessFn(fn)
        }
        for handler in config.prependInputHandlers {
            _ = addInputHandler(handler)
        }

        _ = self.internalKeyInput.onKeypress { [weak self] event in
            guard let self, self.exitOnCtrlC else { return }
            let isBaseC = event.baseCode == 99 // 'c'
            if event.ctrl && (event.name.lowercased() == "c" || isBaseC) {
                self.destroy()
            }
        }
    }

    // MARK: - Event Listeners

    @discardableResult
    public func on(_ event: CliRenderEvents, _ listener: @escaping () -> Void) -> CliRendererListenerToken {
        let id = nextListenerId
        nextListenerId &+= 1
        voidListeners[event.rawValue, default: []].append((id: id, fn: listener))
        return CliRendererListenerToken(id: id, event: event.rawValue)
    }

    @discardableResult
    public func onFrame(_ listener: @escaping (CliRendererFrameEvent) -> Void) -> CliRendererListenerToken {
        let id = nextListenerId
        nextListenerId &+= 1
        frameListeners.append((id: id, fn: listener))
        return CliRendererListenerToken(id: id, event: CliRenderEvents.frame.rawValue)
    }

    @discardableResult
    public func onResize(_ listener: @escaping (Int, Int) -> Void) -> CliRendererListenerToken {
        let id = nextListenerId
        nextListenerId &+= 1
        resizeListeners.append((id: id, fn: listener))
        return CliRendererListenerToken(id: id, event: CliRenderEvents.resize.rawValue)
    }

    @discardableResult
    public func onThemeMode(_ listener: @escaping (ThemeMode) -> Void) -> CliRendererListenerToken {
        let id = nextListenerId
        nextListenerId &+= 1
        themeModeListeners.append((id: id, fn: listener))
        return CliRendererListenerToken(id: id, event: CliRenderEvents.themeMode.rawValue)
    }

    @discardableResult
    public func onSelection(_ listener: @escaping (Selection) -> Void) -> CliRendererListenerToken {
        let id = nextListenerId
        nextListenerId &+= 1
        selectionListeners.append((id: id, fn: listener))
        return CliRendererListenerToken(id: id, event: CliRenderEvents.selection.rawValue)
    }

    @discardableResult
    public func onFocusedRenderable(_ listener: @escaping (Renderable?, Renderable?) -> Void) -> CliRendererListenerToken {
        let id = nextListenerId
        nextListenerId &+= 1
        focusRenderableListeners.append((id: id, fn: listener))
        return CliRendererListenerToken(id: id, event: CliRenderEvents.focusedRenderable.rawValue)
    }

    public func off(_ token: CliRendererListenerToken) {
        voidListeners[token.event]?.removeAll { $0.id == token.id }
        frameListeners.removeAll { $0.id == token.id }
        resizeListeners.removeAll { $0.id == token.id }
        themeModeListeners.removeAll { $0.id == token.id }
        selectionListeners.removeAll { $0.id == token.id }
        focusRenderableListeners.removeAll { $0.id == token.id }
    }

    private func emitVoid(_ event: CliRenderEvents) {
        guard let entries = voidListeners[event.rawValue] else { return }
        for entry in entries {
            entry.fn()
        }
    }

    // MARK: - Properties

    // parity: core/src/renderer.ts#CliRenderer.controlState [status=implemented hash=48ac5bfd2195]
    public var controlState: RendererControlState { _controlState }

    // parity: core/src/renderer.ts#CliRenderer.isDestroyed [status=implemented hash=13eff164cad8]
    public var isDestroyed: Bool { _isDestroyed }

    // parity: core/src/renderer.ts#CliRenderer.isRunning [status=implemented hash=32de5a5bf07e]
    public var isRunning: Bool { _isRunning }

    // parity: core/src/renderer.ts#CliRenderer.frameId [status=implemented hash=94e91d782fe5]
    public var frameId: Int { _frameId }

    // parity: core/src/renderer.ts#CliRenderer.terminalWidth [status=implemented hash=0772fb06f774]
    public var terminalWidth: Int { _terminalWidth }

    // parity: core/src/renderer.ts#CliRenderer.terminalHeight [status=implemented hash=aa7fd1bbe2a2]
    public var terminalHeight: Int { _terminalHeight }

    // parity: core/src/renderer.ts#CliRenderer.resolution [status=implemented hash=eccedc06a936]
    public var resolution: PixelResolution? { _resolution }

    // parity: core/src/renderer.ts#CliRenderer.widthMethod [status=implemented hash=77ccf80f9bba]
    public var widthMethod: WidthMethod {
        _capabilities?.unicode ?? nextRenderBuffer.widthMethod
    }

    // parity: core/src/renderer.ts#CliRenderer.capabilities [status=implemented hash=733edf53abc2]
    public var capabilities: TerminalCapabilities? { _capabilities }

    // parity: core/src/renderer.ts#CliRenderer.targetFps [status=implemented hash=81b7aaf2af70]
    public var targetFps: Double {
        get { _targetFps }
        set {
            guard newValue > 0 && newValue.isFinite else { return }
            _targetFps = newValue
            targetFrameTime = 1000.0 / newValue
        }
    }

    // parity: core/src/renderer.ts#CliRenderer.maxFps [status=implemented hash=0b796274dee6]
    public var maxFps: Double {
        get { _maxFps }
        set {
            guard newValue > 0 && newValue.isFinite else { return }
            _maxFps = newValue
            minTargetFrameTime = 1000.0 / newValue
        }
    }

    // parity: core/src/renderer.ts#CliRenderer.useMouse [status=implemented hash=9984dc8ff1c8]
    public var useMouse: Bool {
        get { _useMouse }
        set {
            guard _useMouse != newValue else { return }
            _useMouse = newValue
            requestRender()
        }
    }

    // parity: core/src/renderer.ts#CliRenderer.screenMode [status=implemented hash=0a8a5a006d53]
    public var screenMode: ScreenMode { _screenMode }

    // parity: core/src/renderer.ts#CliRenderer.footerHeight [status=implemented hash=5cd8b3f51c4f]
    public var footerHeight: Int { _footerHeight }

    // parity: core/src/renderer.ts#CliRenderer.liveRequestCount [status=implemented hash=8f2667a7cd05]
    public var liveRequestCount: Int { liveRequestCounter }

    // parity: core/src/renderer.ts#CliRenderer.themeMode [status=implemented hash=11787a7cf432]
    public var themeMode: ThemeMode? { themeModeState.themeMode }

    // parity: core/src/renderer.ts#CliRenderer.useKittyKeyboard [status=implemented hash=07dbbef5d5c0]
    public var useKittyKeyboard: Bool {
        get { kittyKeyboardFlags != 0 }
        set {
            if newValue {
                enableKittyKeyboard(flags: kittyFlagDisambiguate | kittyFlagAlternateKeys)
            } else {
                disableKittyKeyboard()
            }
        }
    }

    /// Active Kitty keyboard protocol enhancement bitmask (`0` when disabled).
    public var activeKittyKeyboardFlags: UInt32 {
        kittyKeyboardFlags
    }

    // parity: core/src/renderer.ts#CliRenderer.enableKittyKeyboard [status=implemented hash=60b9e808d6c9]
    public func enableKittyKeyboard(flags: UInt32 = kittyFlagDisambiguate | kittyFlagEventTypes) {
        kittyKeyboardFlags = flags
        _capabilities?.kittyKeyboard = flags != 0
        stdinParser.updateProtocolContext(nowMs: clock.now()) { ctx in
            ctx.kittyKeyboardEnabled = flags != 0
        }
    }

    // parity: core/src/renderer.ts#CliRenderer.disableKittyKeyboard [status=implemented hash=b10dc2b54df8]
    public func disableKittyKeyboard() {
        kittyKeyboardFlags = 0
        _capabilities?.kittyKeyboard = false
        stdinParser.updateProtocolContext(nowMs: clock.now()) { ctx in
            ctx.kittyKeyboardEnabled = false
        }
    }

    // parity: core/src/renderer.ts#CliRenderer.waitForThemeMode [status=implemented hash=024923693e16]
    public func waitForThemeMode(timeoutMs: Double = 1000) async -> ThemeMode? {
        await themeModeState.waitForThemeMode(timeoutMs: max(0, timeoutMs), isDestroyed: _isDestroyed)
    }

    /// RendererThemeModeHost conformance: writes OSC 10/11 query sequences to `outputWriter`.
    public func queryThemeColors() -> Bool {
        outputWriter?("\u{1B}]10;?\u{07}\u{1B}]11;?\u{07}")
        return false
    }

    // MARK: - Lifecycle Passes

    // parity: core/src/renderer.ts#CliRenderer.registerLifecyclePass [status=implemented hash=1c3bcf940c24]
    public func registerLifecyclePass(_ renderable: Renderable) {
        if !lifecyclePasses.contains(where: { $0 === renderable }) {
            lifecyclePasses.append(renderable)
        }
    }

    // parity: core/src/renderer.ts#CliRenderer.unregisterLifecyclePass [status=implemented hash=acc385e40d39]
    public func unregisterLifecyclePass(_ renderable: Renderable) {
        lifecyclePasses.removeAll { $0 === renderable }
    }

    // parity: core/src/renderer.ts#CliRenderer.getLifecyclePasses [status=implemented hash=af8f2f8fcba0]
    public func getLifecyclePasses() -> [Renderable] {
        lifecyclePasses
    }

    // MARK: - Focus Management

    // parity: core/src/renderer.ts#CliRenderer.currentFocusedRenderable [status=implemented hash=a6b39115c33f]
    public var currentFocusedRenderable: Renderable? {
        _currentFocusedRenderable
    }

    // parity: core/src/renderer.ts#CliRenderer.focusRenderable [status=implemented hash=7a9e7d659f38]
    public func focusRenderable(_ renderable: Renderable) {
        guard renderable.ctx === self else { return }
        changeFocus(to: renderable)
    }

    // parity: core/src/renderer.ts#CliRenderer.blurRenderable [status=implemented hash=7a38af9a41a7]
    public func blurRenderable(_ renderable: Renderable) {
        guard _currentFocusedRenderable === renderable else { return }
        changeFocus(to: nil)
    }

    private func changeFocus(to renderable: Renderable?) {
        if _currentFocusedRenderable === renderable { return }
        let previous = _currentFocusedRenderable
        _currentFocusedRenderable = renderable
        if renderable != nil {
            previous?.blur()
        }
        if _currentFocusedRenderable === renderable && (renderable == nil || renderable?.isDestroyed == false) {
            for entry in focusRenderableListeners {
                entry.fn(renderable, previous)
            }
            emitVoid(.focusedRenderable)
        }
    }

    // MARK: - Hit Grid

    public func addToHitGrid(x: Int, y: Int, width rectWidth: Int, height rectHeight: Int, id: UInt32) {
        guard rectWidth > 0 && rectHeight > 0 else { return }
        nextRenderBuffer.fillHitRect(x: x, y: y, width: rectWidth, height: rectHeight, hitId: id)
        if let clipped = nextRenderBuffer.clipRectToScissor(x: x, y: y, width: rectWidth, height: rectHeight) {
            let cx = max(0, clipped.x)
            let cy = max(0, clipped.y)
            let cx2 = min(width, clipped.x + clipped.width)
            let cy2 = min(height, clipped.y + clipped.height)
            if cx < cx2 && cy < cy2 {
                activeFrameHitRects.append(HitRect(x: cx, y: cy, width: cx2 - cx, height: cy2 - cy, id: id))
            }
        }
    }

    /// Returns the topmost renderable `num` at `(x, y)` in the presented frame, or `0` if empty.
    /// When `excluding != 0`, skips the excluded renderable (used during drag-over / drop-through).
    // parity: core/src/renderer.ts#CliRenderer.hitTest [status=implemented hash=057b0e59d774]
    public func hitTest(x: Int, y: Int, excluding: UInt32 = 0) -> UInt32 {
        guard x >= 0 && x < width && y >= 0 && y < height else { return 0 }
        let idx = y * width + x
        let direct = idx < hitGrid.count ? hitGrid[idx] : 0
        if excluding == 0 || direct != excluding {
            return direct
        }
        for rect in presentedHitRects.reversed() {
            if rect.id == excluding { continue }
            if x >= rect.x && x < rect.x + rect.width && y >= rect.y && y < rect.y + rect.height {
                return rect.id
            }
        }
        return 0
    }

    // MARK: - Background, Cursor & Links

    // parity: core/src/renderer.ts#CliRenderer.setBackgroundColor [status=implemented hash=40cd4521cfd8]
    public func setBackgroundColor(_ color: RGBA) {
        diffRenderer.setBackgroundColor(color)
        requestRender()
    }

    public func setBackgroundColor(_ colorString: String) {
        setBackgroundColor(parseColor(colorString))
    }

    // parity: core/src/renderer.ts#CliRenderer.setCursorPosition [status=implemented hash=a9f549c8a864]
    public func setCursorPosition(x: Int, y: Int, visible: Bool = true) {
        diffRenderer.cursorState.x = x
        diffRenderer.cursorState.y = y
        diffRenderer.cursorState.visible = visible
    }

    // parity: core/src/renderer.ts#CliRenderer.setCursorStyle [status=implemented hash=a7859851fa48]
    public func setCursorStyle(_ options: CursorStyleOptions) {
        if let style = options.style {
            diffRenderer.cursorState.style = style.renderStyle
        }
        if let blinking = options.blinking {
            diffRenderer.cursorState.blinking = blinking
        }
        if let color = options.color {
            diffRenderer.cursorState.color = color
        }
        if let pointer = options.cursor {
            _currentMousePointerStyle = pointer
        }
    }

    // parity: core/src/renderer.ts#CliRenderer.setCursorColor [status=implemented hash=f4fe27c53894]
    public func setCursorColor(_ color: RGBA) {
        diffRenderer.cursorState.color = color
    }

    // parity: core/src/renderer.ts#CliRenderer.setMousePointer [status=implemented hash=ed654c181cd2]
    public func setMousePointer(_ shape: MousePointerStyle) {
        setCursorStyle(CursorStyleOptions(cursor: shape))
    }

    public var currentMousePointerStyle: MousePointerStyle? {
        _currentMousePointerStyle
    }

    // parity: core/src/renderer.ts#CliRenderer.getCursorState [status=implemented hash=13cd4ed0b556]
    public func getCursorState() -> CursorRenderState {
        diffRenderer.cursorState
    }

    // parity: core/src/renderer.ts#CliRenderer.getLinkIdAt [status=implemented hash=5076dbc0a0e8]
    public func getLinkIdAt(x: Int, y: Int) -> UInt32 {
        guard !_isDestroyed, x >= 0, y >= 0, x < currentRenderBuffer.width, y < currentRenderBuffer.height else {
            return 0
        }
        guard let cell = currentRenderBuffer.cell(atX: x, y: y) else { return 0 }
        return getLinkId(cell.attributes)
    }

    // parity: core/src/renderer.ts#CliRenderer.getLinkAt [status=implemented hash=9416fecbb04a]
    public func getLinkAt(x: Int, y: Int) -> String? {
        let linkId = getLinkIdAt(x: x, y: y)
        guard linkId != 0 else { return nil }
        return try? linkPool.get(linkId)
    }

    // MARK: - Palette

    // parity: core/src/renderer.ts#CliRenderer.clearPaletteCache [status=implemented hash=90e5eb53eaa2]
    public func clearPaletteCache() {
        paletteCache.removeAll()
    }

    // parity: core/src/renderer.ts#CliRenderer.getPalette [status=adapted hash=0df0b66643d8]
    public func getPalette(options: GetPaletteOptions = GetPaletteOptions()) -> TerminalColors {
        let size = max(1, min(options.size, 256))
        if let cached = paletteCache[size] {
            return cached
        }
        var palette: [String?] = []
        palette.reserveCapacity(size)
        for index in 0..<size {
            if let rgb = try? ansi256IndexToRgb(index) {
                palette.append(rgbToHex(RGBA.fromInts(Int(rgb.r), Int(rgb.g), Int(rgb.b), 255)))
            } else {
                palette.append(nil)
            }
        }
        let colors = TerminalColors(
            palette: palette,
            defaultForeground: rgbToHex(.defaultForeground()),
            defaultBackground: rgbToHex(.defaultBackground())
        )
        paletteCache[size] = colors
        return colors
    }

    // MARK: - Post-Process, Frame Callbacks & Animation

    // parity: core/src/renderer.ts#CliRenderer.addPostProcessFn [status=implemented hash=5000158e68e6]
    @discardableResult
    public func addPostProcessFn(_ processFn: @escaping (OptimizedBuffer, Double) -> Void) -> UInt64 {
        let id = nextPostProcessId
        nextPostProcessId &+= 1
        postProcessEntries.append(PostProcessEntry(id: id, fn: processFn))
        return id
    }

    // parity: core/src/renderer.ts#CliRenderer.removePostProcessFn [status=implemented hash=aed2810b4142]
    public func removePostProcessFn(id: UInt64) {
        postProcessEntries.removeAll { $0.id == id }
    }

    // parity: core/src/renderer.ts#CliRenderer.clearPostProcessFns [status=implemented hash=e36b284ed792]
    public func clearPostProcessFns() {
        postProcessEntries.removeAll()
    }

    public func setFrameCallback(_ callback: @escaping (Double) -> Void) {
        frameCallbacks.append(callback)
    }

    public func clearFrameCallbacks() {
        frameCallbacks.removeAll()
    }

    // parity: core/src/renderer.ts#CliRenderer.requestAnimationFrame [status=implemented hash=8b75533eb774]
    @discardableResult
    public func requestAnimationFrame(_ callback: @escaping FrameRequestCallback) -> Int {
        guard !_isDestroyed else { return -1 }
        let id = nextAnimationFrameId
        nextAnimationFrameId += 1
        animationRequests.append((id: id, callback: callback))
        requestLive()
        return id
    }

    // parity: core/src/renderer.ts#CliRenderer.cancelAnimationFrame [status=implemented hash=39a6e5ff7650]
    public func cancelAnimationFrame(_ handle: Int) {
        let before = animationRequests.count
        animationRequests.removeAll { $0.id == handle }
        if animationRequests.count < before {
            dropLive()
        }
    }

    // parity: core/src/renderer.ts#CliRenderer.onAnimationTick [status=implemented hash=abedb9da4e85]
    @discardableResult
    public func onAnimationTick(
        fps: Double,
        callback: @escaping AnimationTickCallback,
        options: AnimationTickOptions = AnimationTickOptions()
    ) -> () -> Void {
        let interval = 1000.0 / fps
        guard interval > 0 && interval.isFinite, !_isDestroyed else { return {} }
        if let tolerance = options.tolerance, !(tolerance >= 0 && tolerance < interval) {
            return {}
        }

        let now = clock.now()
        let window = max(options.tolerance.map { $0 * fps } ?? 500.0, Self.animationTimerSlackMs * fps)
        let firstNext = Int(((now * fps + window) / 1000.0).rounded(.down)) + 1
        let id = nextAnimationTickerId
        nextAnimationTickerId &+= 1
        let ticker = AnimationTicker(id: id, fps: fps, window: window, next: firstNext, last: now, callback: callback)
        animationTickers.append(ticker)
        scheduleAnimationTick()

        return { [weak self] in
            guard let self else { return }
            let before = self.animationTickers.count
            self.animationTickers.removeAll { $0.id == id }
            if self.animationTickers.count < before {
                self.scheduleAnimationTick()
            }
        }
    }

    private func scheduleAnimationTick() {
        if let timer = animationTimer {
            clock.clearTimeout(timer)
            animationTimer = nil
        }
        guard !animationTickers.isEmpty, !_isDestroyed else { return }
        var fastest: Double = 0
        for ticker in animationTickers {
            fastest = max(fastest, ticker.fps)
        }
        var due = Double.infinity
        for ticker in animationTickers {
            let late = ticker.fps == fastest ? 0.0 : ticker.window
            due = min(due, (Double(ticker.next) * 1000.0 + late) / ticker.fps)
        }
        guard due.isFinite else { return }
        let delay = max(0.0, due - clock.now())
        animationTimer = clock.setTimeout({ [weak self] in
            guard let self else { return }
            self.animationTimer = nil
            self.requestRender()
        }, delayMs: delay)
    }

    private func runAnimationTicks(time: Double) {
        guard !animationTickers.isEmpty else { return }
        let snapshot = animationTickers
        for ticker in snapshot {
            let reach = Int(((time * ticker.fps + ticker.window) / 1000.0).rounded(.down))
            if reach < ticker.next { continue }
            let ticks = reach + 1 - ticker.next
            let deltaTime = max(0.0, time - ticker.last)
            ticker.next = reach + 1
            ticker.last = time
            ticker.callback(deltaTime, ticks, time)
        }
        scheduleAnimationTick()
    }

    // MARK: - Scheduling & Control State

    // parity: core/src/renderer.ts#CliRenderer.getSchedulerState [status=implemented hash=b84ff85df12c]
    public func getSchedulerState() -> RendererSchedulerState {
        RendererSchedulerState(
            isRunning: _isRunning,
            isRendering: rendering,
            hasScheduledRender: renderTimeout != nil || immediateRerenderRequested || pendingResize != nil
        )
    }

    private func clearFrameTimer() {
        if let handle = renderTimeout {
            clock.clearTimeout(handle)
            renderTimeout = nil
        }
    }

    private func nextFrameDelay() -> Double {
        let now = clock.now()
        let elapsed = max(0.0, now - lastTime)
        return max(0.0, minTargetFrameTime - elapsed)
    }

    private func scheduleFrame(delayMs: Double) {
        clearFrameTimer()
        renderTimeout = clock.setTimeout({ [weak self] in
            guard let self else { return }
            self.renderTimeout = nil
            self.render(force: false)
        }, delayMs: delayMs)
    }

    // parity: core/src/renderer.ts#CliRenderer.requestRender [status=adapted hash=2d715cff57e8]
    public func requestRender() {
        guard !_isDestroyed && _controlState != .explicitSuspended else { return }
        if rendering {
            immediateRerenderRequested = true
            return
        }
        if renderTimeout == nil {
            scheduleFrame(delayMs: nextFrameDelay())
        }
    }

    // parity: core/src/renderer.ts#CliRenderer.requestLive [status=implemented hash=17c519306989]
    public func requestLive() {
        guard !_isDestroyed else { return }
        liveRequestCounter += 1
        if _controlState == .idle && liveRequestCounter > 0 {
            _controlState = .autoStarted
            internalStart()
        } else if _controlState == .explicitSuspended && _previousControlState == .idle {
            _previousControlState = .autoStarted
        }
    }

    // parity: core/src/renderer.ts#CliRenderer.dropLive [status=implemented hash=71024f905e29]
    public func dropLive() {
        guard liveRequestCounter > 0 else { return }
        liveRequestCounter -= 1
        if liveRequestCounter == 0 && _controlState == .explicitSuspended && _previousControlState == .autoStarted {
            _previousControlState = .idle
        }
        if _controlState == .autoStarted && liveRequestCounter == 0 {
            _controlState = .idle
            _isRunning = false
        }
    }

    // parity: core/src/renderer.ts#CliRenderer.start [status=implemented hash=893a7425427e]
    public func start() {
        _controlState = .explicitStarted
        internalStart()
    }

    // parity: core/src/renderer.ts#CliRenderer.auto [status=implemented hash=aaef7391dbb5]
    public func auto() {
        _controlState = _isRunning ? .autoStarted : .idle
    }

    private func internalStart() {
        guard !_isRunning && !_isDestroyed else { return }
        _isRunning = true
        lastTime = clock.now()
        frameCount = 0
        lastFpsTime = lastTime
        currentFps = 0
        scheduleFrame(delayMs: 0)
    }

    // parity: core/src/renderer.ts#CliRenderer.pause [status=implemented hash=de444aae67b7]
    public func pause() {
        _controlState = .explicitPaused
        halt()
    }

    // parity: core/src/renderer.ts#CliRenderer.stop [status=implemented hash=5fea38374d73]
    public func stop() {
        _controlState = .explicitStopped
        halt()
    }

    private func halt() {
        _isRunning = false
        immediateRerenderRequested = false
        clearFrameTimer()
    }

    // parity: core/src/renderer.ts#CliRenderer.suspend [status=adapted hash=c9457002c990]
    public func suspend() {
        guard !_isDestroyed else { return }
        if _controlState != .explicitSuspended {
            _previousControlState = _controlState
            _suspendedMouseEnabled = _useMouse
        }
        _controlState = .explicitSuspended
        halt()
        _useMouse = false
        stdinParser.suspend()
        clearStdinTimeout()
        themeModeState.cancelRefresh()
    }

    /// Reads the terminal's current size (columns, rows), or `nil` when the host cannot tell. ``resume()`` reads it
    /// because a stopped process gets no `SIGWINCH`.
    public var terminalSizeProvider: (@Sendable () -> (width: Int, height: Int)?)?

    /// A stopped process gets no SIGWINCH (its shell owns the terminal, and `fg` sends only SIGCONT), so resume reads
    /// the terminal size again: a new terminal size, or else a size requested while suspended, applies first. A size
    /// the renderer rejects (not positive) is dropped, as for a live resize.
    // parity: core/src/renderer.ts#CliRenderer.resume [status=adapted hash=5bef600c34d8]
    public func resume() {
        guard !_isDestroyed && _controlState == .explicitSuspended else { return }
        stdinParser.resume()
        _useMouse = _suspendedMouseEnabled
        forceFullRepaintRequested = true
        _controlState = _previousControlState
        let fresh = terminalSizeProvider?()
        let resized = fresh.map { $0.width > 0 && $0.height > 0 && ($0.width != _terminalWidth || $0.height != _terminalHeight) } ?? false
        let size = resized ? fresh : pendingResize
        pendingResize = nil
        if let handle = resizeTimeoutId {
            clock.clearTimeout(handle)
            resizeTimeoutId = nil
        }
        if let size, size.width > 0, size.height > 0 {
            processResize(width: size.width, height: size.height)
        }
        if _controlState == .autoStarted || _controlState == .explicitStarted {
            internalStart()
        } else {
            requestRender()
        }
    }

    // parity: core/src/renderer.ts#CliRenderer.destroy [status=adapted hash=071c4c2ff365]
    public func destroy() {
        guard !_isDestroyed else { return }
        _isDestroyed = true

        halt()
        clearStdinTimeout()
        if let handle = resizeTimeoutId {
            clock.clearTimeout(handle)
            resizeTimeoutId = nil
        }
        if let handle = animationTimer {
            clock.clearTimeout(handle)
            animationTimer = nil
        }

        pendingResize = nil
        animationRequests.removeAll()
        animationTickers.removeAll()
        frameCallbacks.removeAll()
        liveRequestCounter = 0
        _useMouse = false
        capturedRenderable = nil
        pressedRenderable = nil
        lastOverRenderable = nil
        lastOverRenderableNum = 0

        clearSelection()
        paletteCache.removeAll()
        themeModeState.dispose()

        emitVoid(.destroy)

        root.destroyRecursively()
        stdinParser.destroy()
        oscSubscribers.removeAll()
        sequenceHandlers.removeAll()
        internalKeyInput.removeAllListeners()

        onDestroyCallback?()
        onDestroyCallback = nil
    }

    // MARK: - Frame Rendering Pipeline

    /// Synchronously executes one complete frame pass: lifecycle passes -> Flexbox layout ->
    /// `updateFromLayout()` -> buffer/hit-grid clear -> scene render -> post-process ->
    /// ANSI diff & emit -> hover recheck -> stats & frame event.
    public func renderOnce(force: Bool = false) {
        render(force: force)
    }

    // parity: core/src/renderer.ts#CliRenderer.intermediateRender [status=adapted hash=8a8067a3f647]
    public func intermediateRender() {
        immediateRerenderRequested = true
        render(force: false)
    }

    public func render(force: Bool = false) {
        guard !_isDestroyed && _controlState != .explicitSuspended else { return }
        guard !rendering else {
            immediateRerenderRequested = true
            return
        }

        clearFrameTimer()
        rendering = true
        defer {
            rendering = false
            applyPendingResizeIfNeeded()
        }

        _frameId += 1
        let now = clock.now()
        let deltaTime = max(0.0, now - lastTime)
        lastTime = now
        totalFrameCount += 1

        // 1. Shared animation ticks & animation frames
        let requestedBeforeTicks = immediateRerenderRequested
        runAnimationTicks(time: now)
        immediateRerenderRequested = requestedBeforeTicks

        if !animationRequests.isEmpty {
            let currentRequests = animationRequests
            animationRequests.removeAll(keepingCapacity: true)
            for req in currentRequests {
                if _isDestroyed || _controlState == .explicitSuspended { break }
                req.callback(deltaTime)
                dropLive()
            }
        }

        let callbackStart = clock.now()
        if !frameCallbacks.isEmpty {
            let snapshot = frameCallbacks
            for cb in snapshot {
                if _isDestroyed || _controlState == .explicitSuspended { break }
                cb(deltaTime)
            }
        }
        lastFrameCallbackTime = max(0.0, clock.now() - callbackStart)

        guard !_isDestroyed && _controlState != .explicitSuspended else { return }

        // 2. Lifecycle passes
        if !lifecyclePasses.isEmpty {
            let passes = lifecyclePasses
            for renderable in passes {
                if _isDestroyed { return }
                if !renderable.isDestroyed {
                    renderable.runLifecyclePass()
                }
            }
        }

        // 3. Flexbox layout pass
        FlexSolver.calculateLayout(
            root: root.layoutNode,
            availableWidth: Float(width),
            availableHeight: Float(height),
            direction: .ltr
        )
        root.updateFromLayout()

        guard !_isDestroyed else { return }

        // 4. Clear back buffer & hit grid
        nextRenderBuffer.clear(bg: diffRenderer.backgroundColor, char: defaultSpaceChar)
        nextRenderBuffer.clearScissorRects()
        nextRenderBuffer.clearOpacity()
        nextRenderBuffer.clearHitGrid()
        activeFrameHitRects.removeAll(keepingCapacity: true)

        // 5. Render scene tree
        root.render(buffer: nextRenderBuffer, deltaTime: deltaTime)
        guard !_isDestroyed else { return }

        // 6. Post-process passes
        for entry in postProcessEntries {
            if _isDestroyed { return }
            entry.fn(nextRenderBuffer, deltaTime)
        }

        // 7. Commit hit grid snapshot for presented frame
        hitGrid = nextRenderBuffer.hitGrid
        presentedHitRects = activeFrameHitRects

        // 8. Diff front/back buffers, emit ANSI, and sync currentRenderBuffer
        let ansi = diffRenderer.render(force: force || forceFullRepaintRequested, clearNextAfterRender: true)
        forceFullRepaintRequested = false
        if !ansi.isEmpty {
            outputWriter?(ansi)
        }

        // 9. Recheck hover state against new presented hit grid
        if _useMouse {
            recheckHoverState()
        }
        guard !_isDestroyed else { return }

        // 10. Update FPS & stats
        frameCount += 1
        if now - lastFpsTime >= 1000.0 {
            currentFps = Double(frameCount)
            frameCount = 0
            lastFpsTime = now
        }
        if gatherStats {
            let frameDuration = max(0.0, clock.now() - now)
            frameTimes.append(frameDuration)
            if frameTimes.count > maxStatSamples {
                frameTimes.removeFirst()
            }
        }

        // 11. Emit frame event
        let frameEvent = CliRendererFrameEvent(frameId: _frameId)
        for entry in frameListeners {
            entry.fn(frameEvent)
        }
        emitVoid(.frame)
        guard !_isDestroyed else { return }

        // 12. Schedule next frame when running or re-render requested during render
        if _isRunning || immediateRerenderRequested {
            let immediate = immediateRerenderRequested
            let interval = immediate ? minTargetFrameTime : targetFrameTime
            let remaining = max(0.0, interval - max(0.0, clock.now() - now))
            immediateRerenderRequested = false
            scheduleFrame(delayMs: immediate ? remaining : max(1.0, remaining))
        }
    }

    // MARK: - Resize

    // parity: core/src/renderer.ts#CliRenderer.requestResize [status=implemented hash=a89e6c2e20bc]
    public func requestResize(width newWidth: Int, height newHeight: Int) {
        guard !_isDestroyed else { return }
        pendingResize = (width: newWidth, height: newHeight)
        if let handle = resizeTimeoutId {
            clock.clearTimeout(handle)
            resizeTimeoutId = nil
        }
        if _splitHeight > 0 || resizeDebounceDelay <= 0 {
            applyPendingResizeIfNeeded()
            return
        }
        resizeTimeoutId = clock.setTimeout({ [weak self] in
            guard let self else { return }
            self.resizeTimeoutId = nil
            self.applyPendingResizeIfNeeded()
        }, delayMs: resizeDebounceDelay)
    }

    // parity: core/src/renderer.ts#CliRenderer.resize [status=implemented hash=2483c242dd29]
    public func resize(width newWidth: Int, height newHeight: Int) {
        guard !_isDestroyed else { return }
        if let handle = resizeTimeoutId {
            clock.clearTimeout(handle)
            resizeTimeoutId = nil
        }
        if rendering || _controlState == .explicitSuspended {
            pendingResize = (width: newWidth, height: newHeight)
            return
        }
        pendingResize = nil
        processResize(width: newWidth, height: newHeight)
    }

    private func applyPendingResizeIfNeeded() {
        guard let pending = pendingResize,
              !_isDestroyed,
              !rendering,
              resizeTimeoutId == nil,
              _controlState != .explicitSuspended
        else {
            return
        }
        pendingResize = nil
        processResize(width: pending.width, height: pending.height)
    }

    private func processResize(width newWidth: Int, height newHeight: Int) {
        let safeW = max(1, newWidth)
        let safeH = max(1, newHeight)
        guard safeW != _terminalWidth || safeH != _terminalHeight else { return }

        let nextGeometry = calculateRenderGeometry(
            screenMode: _screenMode,
            terminalWidth: safeW,
            terminalHeight: safeH,
            footerHeight: _footerHeight
        )
        let renderW = max(1, nextGeometry.renderWidth)
        let renderH = max(1, nextGeometry.renderHeight)

        _terminalWidth = safeW
        _terminalHeight = safeH
        _splitHeight = nextGeometry.effectiveFooterHeight
        _renderOffset = nextGeometry.renderOffset
        width = renderW
        height = renderH

        diffRenderer.renderOffset = _renderOffset
        try? diffRenderer.resize(width: renderW, height: renderH)
        hitGrid = Array(repeating: 0, count: renderW * renderH)
        presentedHitRects.removeAll(keepingCapacity: true)
        _resolution = nil
        capturedRenderable = nil
        forceFullRepaintRequested = true

        root.resize(width: renderW, height: renderH)

        for entry in resizeListeners {
            entry.fn(renderW, renderH)
        }
        emitVoid(.resize)
        requestRender()
    }

    // MARK: - Input Dispatch

    // parity: core/src/renderer.ts#CliRenderer.addInputHandler [status=implemented hash=1d179714981e]
    @discardableResult
    public func addInputHandler(_ handler: @escaping (String) -> Bool) -> UInt64 {
        let id = nextHandlerId
        nextHandlerId &+= 1
        sequenceHandlers.append(InputHandlerEntry(id: id, handler: handler))
        return id
    }

    // parity: core/src/renderer.ts#CliRenderer.prependInputHandler [status=implemented hash=cda456067cd8]
    @discardableResult
    public func prependInputHandler(_ handler: @escaping (String) -> Bool) -> UInt64 {
        let id = nextHandlerId
        nextHandlerId &+= 1
        sequenceHandlers.insert(InputHandlerEntry(id: id, handler: handler), at: 0)
        return id
    }

    // parity: core/src/renderer.ts#CliRenderer.removeInputHandler [status=implemented hash=22369b4a86a5]
    public func removeInputHandler(id: UInt64) {
        sequenceHandlers.removeAll { $0.id == id }
    }

    // parity: core/src/renderer.ts#CliRenderer.subscribeOsc [status=implemented hash=c68807724e18]
    public func subscribeOsc(_ handler: @escaping (String) -> Void) -> () -> Void {
        let id = nextHandlerId
        nextHandlerId &+= 1
        oscSubscribers.append(OscSubscriberEntry(id: id, handler: handler))
        return { [weak self] in
            self?.oscSubscribers.removeAll { $0.id == id }
        }
    }

    /// Feeds raw terminal stdin bytes into `stdinParser` and dispatches all resulting events.
    public func feedInput(_ bytes: [UInt8]) {
        guard !_isDestroyed else { return }
        stdinParser.push(bytes, nowMs: clock.now())
        drainStdinParser()
        armStdinTimeoutIfNeeded()
    }

    /// Feeds a UTF-8 terminal stdin string into `stdinParser` and dispatches all resulting events.
    public func feedInput(_ string: String) {
        feedInput(Array(string.utf8))
    }

    /// Flushes any pending escape/sequence timeout on `stdinParser` using the current clock time.
    public func flushInputTimeout() {
        guard !_isDestroyed else { return }
        clearStdinTimeout()
        stdinParser.flushTimeout(nowMs: clock.now())
        drainStdinParser()
        armStdinTimeoutIfNeeded()
    }

    private func clearStdinTimeout() {
        if let handle = stdinTimeoutHandle {
            clock.clearTimeout(handle)
            stdinTimeoutHandle = nil
        }
    }

    private func armStdinTimeoutIfNeeded() {
        clearStdinTimeout()
        guard !_isDestroyed, _controlState != .explicitSuspended, let deadlineNs = stdinParser.deadlineNs else {
            return
        }
        let deadlineMs = Double(deadlineNs) / 1_000_000.0
        let delayMs = max(0.0, deadlineMs - clock.now())
        stdinTimeoutHandle = clock.setTimeout({ [weak self] in
            guard let self else { return }
            self.stdinTimeoutHandle = nil
            self.stdinParser.flushTimeout(nowMs: self.clock.now())
            self.drainStdinParser()
            self.armStdinTimeoutIfNeeded()
        }, delayMs: delayMs)
    }

    private func drainStdinParser() {
        stdinParser.drain { event in
            if !self._isDestroyed {
                self.handleStdinEvent(event)
            }
        }
    }

    private func dispatchSequenceHandlers(_ sequence: String) -> Bool {
        let handlers = sequenceHandlers
        for entry in handlers {
            if entry.handler(sequence) {
                return true
            }
        }
        return false
    }

    private func handleStdinEvent(_ event: StdinEvent) {
        if _controlState == .explicitSuspended {
            if case .response(_, let sequence) = event, isPixelResolutionResponse(sequence) {
                if let res = parsePixelResolution(sequence) {
                    _resolution = res
                }
            }
            return
        }

        switch event {
        case .key(let raw, let key):
            if dispatchSequenceHandlers(raw) {
                return
            }
            _ = internalKeyInput.processParsedKey(key)

        case .mouse(let raw, _, let mouseEvent):
            if _useMouse && processSingleMouseEvent(mouseEvent) {
                return
            }
            _ = dispatchSequenceHandlers(raw)

        case .paste(let bytes):
            internalKeyInput.processPaste(bytes)

        case .response(let proto, let sequence):
            if proto == .osc {
                let subscribers = oscSubscribers
                for entry in subscribers {
                    entry.handler(sequence)
                }
            }

            if dispatchSequenceHandlers(sequence) {
                return
            }

            if handleBuiltInResponse(protocol: proto, sequence: sequence) {
                return
            }
        }
    }

    private func handleBuiltInResponse(protocol proto: StdinResponseProtocol, sequence: String) -> Bool {
        if sequence == "\u{1B}[I" {
            if _terminalFocusState != true {
                _terminalFocusState = true
                emitVoid(.focus)
            }
            return true
        }
        if sequence == "\u{1B}[O" {
            if _terminalFocusState != false {
                _terminalFocusState = false
                emitVoid(.blur)
            }
            return true
        }

        if isPixelResolutionResponse(sequence), let res = parsePixelResolution(sequence) {
            _resolution = res
            requestRender()
            return true
        }

        let themeResult = themeModeState.handleSequence(sequence)
        if themeResult.handled {
            if let mode = themeResult.changedMode {
                clearPaletteCache()
                for entry in themeModeListeners {
                    entry.fn(mode)
                }
                emitVoid(.themeMode)
            }
            return true
        }

        if isCapabilityResponse(sequence) || (proto == .cpr && isExplicitWidthReport(sequence)) {
            emitVoid(.capabilities)
            return true
        }

        return false
    }

    // MARK: - Mouse, Hover, Drag & Scroll Dispatch

    private func dispatchMouseEvent(
        target: Renderable,
        raw: RawMouseEvent,
        source: Renderable? = nil,
        isDragging: Bool = false
    ) -> MouseEvent {
        let event = MouseEvent(target: target, raw: raw, source: source, isDragging: isDragging)
        sendMouseEvent(target: target, event: event)
        guard !_isDestroyed && !target.isDestroyed else { return event }

        if autoFocus && event.type == .down && event.button == MouseButton.left.rawValue && !event.defaultPrevented {
            var current: Renderable? = target
            while let node = current {
                if node.focusable {
                    node.focus()
                    break
                }
                current = node.parent
            }
        }
        return event
    }

    private func sendMouseEvent(target: Renderable, event: MouseEvent) {
        guard !_isDestroyed && !target.isDestroyed else { return }
        target.processMouseEvent(event)
    }

    private func processSingleMouseEvent(_ rawInput: RawMouseEvent) -> Bool {
        var mouseEvent = rawInput
        let pressed = pressedRenderable
        let isLeft = mouseEvent.button == MouseButton.left.rawValue
        let isPress = isLeft && mouseEvent.type == .down

        if isPress || (isLeft && mouseEvent.type == .up) {
            pressedRenderable = nil
        }

        if _splitHeight > 0 {
            if mouseEvent.y < _renderOffset {
                return false
            }
            mouseEvent.y -= _renderOffset
        }

        if isLeft && mouseEvent.type == .drag {
            lastDrag = mouseEvent
        }

        // Lost-release recovery: end previous drag gesture before delivering new left press.
        let lost = isPress ? capturedRenderable : nil
        if isPress, let sel = currentSelection {
            sel.isDragging = false
        }
        if let lost {
            capturedRenderable = nil
            let base = lastDrag ?? mouseEvent
            let dragEndRaw = RawMouseEvent(
                type: .dragEnd,
                button: base.button,
                x: base.x,
                y: base.y,
                modifiers: base.modifiers,
                scroll: base.scroll
            )
            let upRaw = RawMouseEvent(
                type: .up,
                button: base.button,
                x: base.x,
                y: base.y,
                modifiers: base.modifiers,
                scroll: base.scroll
            )
            sendMouseEvent(target: lost, event: MouseEvent(target: lost, raw: dragEndRaw))
            sendMouseEvent(target: lost, event: MouseEvent(target: lost, raw: upRaw))
            if _isDestroyed { return true }
            requestRender()
        }

        latestPointer = (x: mouseEvent.x, y: mouseEvent.y)
        hasPointer = true
        lastPointerModifiers = mouseEvent.modifiers

        // Scroll events hit-test (fallback to focused renderable) and bubble with a fresh ScrollChainToken.
        if mouseEvent.type == .scroll {
            let hitId = hitTest(x: mouseEvent.x, y: mouseEvent.y)
            let hitRenderable = hitId != 0 ? Renderable.renderable(forNumber: hitId) : nil
            let fallback: Renderable? = {
                if let focused = _currentFocusedRenderable, !focused.isDestroyed, focused.focused {
                    return focused
                }
                return nil
            }()
            if let scrollTarget = hitRenderable ?? fallback {
                let event = MouseEvent(target: scrollTarget, raw: mouseEvent, scrollChainToken: ScrollChainToken())
                sendMouseEvent(target: scrollTarget, event: event)
            }
            return true
        }

        let excludedNum = capturedRenderable?.num ?? 0
        let hitId = hitTest(x: mouseEvent.x, y: mouseEvent.y, excluding: excludedNum)
        let sameElement = hitId == lastOverRenderableNum
        let maybeRenderable = hitId != 0 ? Renderable.renderable(forNumber: hitId) : nil

        // Start text selection on left press over selectable renderable
        if isPress && !mouseEvent.modifiers.ctrl {
            if let candidate = maybeRenderable,
               candidate.selectable,
               !candidate.isDestroyed,
               candidate.shouldStartSelection(x: mouseEvent.x, y: mouseEvent.y)
            {
                let behavior = nextClickBehavior(renderable: candidate, x: mouseEvent.x, y: mouseEvent.y)
                startSelection(candidate, x: mouseEvent.x, y: mouseEvent.y, behavior: behavior)
                _ = dispatchMouseEvent(target: candidate, raw: mouseEvent)
                return true
            }
        }

        // Update active dragging selection
        if mouseEvent.type == .drag, currentSelection?.isDragging == true {
            updateSelection(maybeRenderable, x: mouseEvent.x, y: mouseEvent.y)
            if let candidate = maybeRenderable {
                let event = MouseEvent(target: candidate, raw: mouseEvent, isDragging: true)
                sendMouseEvent(target: candidate, event: event)
            }
            return true
        }

        // Finish active dragging selection
        if mouseEvent.type == .up && isLeft && currentSelection?.isDragging == true {
            if let candidate = maybeRenderable {
                let event = MouseEvent(target: candidate, raw: mouseEvent, isDragging: true)
                sendMouseEvent(target: candidate, event: event)
            }
            finishSelection()
            return true
        }

        // Ctrl+click extends existing selection
        if isPress, let sel = currentSelection, mouseEvent.modifiers.ctrl {
            sel.isDragging = true
            updateSelection(maybeRenderable, x: mouseEvent.x, y: mouseEvent.y)
            return true
        }

        // Hover transitions (out / over)
        if !sameElement && (mouseEvent.type == .drag || mouseEvent.type == .move) {
            lastOverRenderableNum = hitId
            if let prevOver = lastOverRenderable,
               prevOver !== capturedRenderable,
               !prevOver.isDestroyed
            {
                let outRaw = RawMouseEvent(
                    type: .out,
                    button: mouseEvent.button,
                    x: mouseEvent.x,
                    y: mouseEvent.y,
                    modifiers: mouseEvent.modifiers
                )
                sendMouseEvent(target: prevOver, event: MouseEvent(target: prevOver, raw: outRaw))
            }
            lastOverRenderable = maybeRenderable
            if let nextOver = maybeRenderable {
                let overRaw = RawMouseEvent(
                    type: .over,
                    button: mouseEvent.button,
                    x: mouseEvent.x,
                    y: mouseEvent.y,
                    modifiers: mouseEvent.modifiers
                )
                sendMouseEvent(
                    target: nextOver,
                    event: MouseEvent(target: nextOver, raw: overRaw, source: capturedRenderable)
                )
            }
        }

        // Forward non-up events to captured drag source
        if let captured = capturedRenderable, mouseEvent.type != .up {
            sendMouseEvent(target: captured, event: MouseEvent(target: captured, raw: mouseEvent))
            return true
        }

        // Release captured drag source and emit dragEnd + up + drop
        if let source = capturedRenderable, mouseEvent.type == .up {
            let dragEndRaw = RawMouseEvent(
                type: .dragEnd,
                button: mouseEvent.button,
                x: mouseEvent.x,
                y: mouseEvent.y,
                modifiers: mouseEvent.modifiers
            )
            sendMouseEvent(target: source, event: MouseEvent(target: source, raw: dragEndRaw))
            sendMouseEvent(target: source, event: MouseEvent(target: source, raw: mouseEvent))
            lastOverRenderable = source
            lastOverRenderableNum = source.num
            capturedRenderable = nil
            requestRender()
            if let dropTarget = maybeRenderable, !isWithinContainer(dropTarget, container: source) {
                let dropRaw = RawMouseEvent(
                    type: .drop,
                    button: mouseEvent.button,
                    x: mouseEvent.x,
                    y: mouseEvent.y,
                    modifiers: mouseEvent.modifiers
                )
                sendMouseEvent(
                    target: dropTarget,
                    event: MouseEvent(target: dropTarget, raw: dropRaw, source: source)
                )
            }
            return true
        }

        // Normal dispatch (and begin capture on left drag)
        let isLeftDrag = isLeft && mouseEvent.type == .drag
        let target: Renderable? = (isLeftDrag && pressed != nil && pressed?.isDestroyed == false) ? pressed : maybeRenderable
        var dispatchedEvent: MouseEvent? = nil
        if let target {
            if isLeftDrag {
                capturedRenderable = target
            } else if isPress {
                pressedRenderable = target
            }
            dispatchedEvent = dispatchMouseEvent(target: target, raw: mouseEvent)
        } else {
            lastOverRenderable = nil
        }

        if isPress && currentSelection != nil && dispatchedEvent?.defaultPrevented != true {
            clearSelection()
        }
        return true
    }

    private func recheckHoverState() {
        guard !_isDestroyed && hasPointer && capturedRenderable == nil else { return }

        let hitId = hitTest(x: latestPointer.x, y: latestPointer.y)
        let hitRenderable = hitId != 0 ? Renderable.renderable(forNumber: hitId) : nil
        let lastOver = lastOverRenderable

        if lastOver?.num == hitId {
            lastOverRenderableNum = hitId
            return
        }

        if let lastOver, !lastOver.isDestroyed {
            let outRaw = RawMouseEvent(
                type: .out,
                button: 0,
                x: latestPointer.x,
                y: latestPointer.y,
                modifiers: lastPointerModifiers
            )
            sendMouseEvent(target: lastOver, event: MouseEvent(target: lastOver, raw: outRaw))
        }
        guard !_isDestroyed && capturedRenderable == nil && lastOverRenderable === lastOver else { return }

        lastOverRenderable = (hitRenderable?.isDestroyed == true) ? nil : hitRenderable
        lastOverRenderableNum = lastOverRenderable?.num ?? 0

        if let hitRenderable, !hitRenderable.isDestroyed {
            let overRaw = RawMouseEvent(
                type: .over,
                button: 0,
                x: latestPointer.x,
                y: latestPointer.y,
                modifiers: lastPointerModifiers
            )
            sendMouseEvent(target: hitRenderable, event: MouseEvent(target: hitRenderable, raw: overRaw))
            if lastOverRenderable === hitRenderable && (_isDestroyed || hitRenderable.isDestroyed) {
                lastOverRenderable = nil
                lastOverRenderableNum = 0
            }
        }
    }

    // MARK: - Selection Management

    public var selection: Selection? { currentSelection }

    // parity: core/src/renderer.ts#CliRenderer.getSelection [status=implemented hash=fe09fa2252a1]
    public func getSelection() -> Selection? { currentSelection }

    // parity: core/src/renderer.ts#CliRenderer.hasSelection [status=implemented hash=0702f7e8fda1]
    public var hasSelection: Bool { currentSelection != nil }

    // parity: core/src/renderer.ts#CliRenderer.getSelectionContainer [status=implemented hash=9735ff8408ae]
    public func getSelectionContainer() -> Renderable? {
        selectionContainers.last
    }

    // parity: core/src/renderer.ts#CliRenderer.clearSelection [status=implemented hash=7c6bc83f3cf8]
    public func clearSelection() {
        clearSelectionState()
        lastClick = nil
    }

    private func clearSelectionState() {
        if let sel = currentSelection {
            for selectable in sel.touchedRenderables {
                if let r = selectable as? Renderable, r.selectable, !r.isDestroyed {
                    _ = r.onSelectionChanged(nil)
                }
            }
            currentSelection = nil
        }
        selectionContainers.removeAll()
    }

    // parity: core/src/renderer.ts#CliRenderer.startSelection [status=implemented hash=60cd569bfd97]
    public func startSelection(_ renderable: Renderable, x: Int, y: Int, behavior: SelectionBehavior = .cell) {
        guard renderable.selectable else { return }
        clearSelectionState()
        selectionContainers.append(renderable.parent ?? root)
        let sel = Selection(
            anchorRenderable: renderable,
            anchor: SelectionPoint(x: x, y: y),
            focus: SelectionPoint(x: x, y: y),
            behavior: behavior
        )
        sel.isStart = true
        currentSelection = sel
        notifySelectablesOfSelectionChange()
    }

    private func nextClickBehavior(renderable: Renderable, x: Int, y: Int) -> SelectionBehavior {
        let now = clock.now()
        let count: Int
        if let last = lastClick,
           renderable.num == last.renderableNum,
           now - last.time <= Self.clickRepeatIntervalMs,
           max(abs(x - last.x), abs(y - last.y)) <= 1
        {
            count = min(last.count + 1, 3)
        } else {
            count = 1
        }
        lastClick = LastClickState(count: count, time: now, x: x, y: y, renderableNum: renderable.num)
        switch count {
        case 1: return .cell
        case 2: return .word
        default: return .line
        }
    }

    // parity: core/src/renderer.ts#CliRenderer.updateSelection [status=implemented hash=a95ac9d857b7]
    public func updateSelection(
        _ currentRenderable: Renderable?,
        x: Int,
        y: Int,
        finishDragging: Bool = false
    ) {
        guard let sel = currentSelection else { return }
        sel.isStart = false
        sel.focus = SelectionPoint(x: x, y: y)
        if finishDragging {
            sel.isDragging = false
        }

        if let currentContainer = selectionContainers.last {
            if let currentRenderable, isWithinContainer(currentRenderable, container: currentContainer) {
                if selectionContainers.count > 1 {
                    var containerIndex = selectionContainers.firstIndex(where: { $0 === currentRenderable })
                    if containerIndex == nil {
                        let immediateParent = currentRenderable.parent ?? root!
                        containerIndex = selectionContainers.firstIndex(where: { $0 === immediateParent })
                    }
                    if let idx = containerIndex, idx < selectionContainers.count - 1 {
                        selectionContainers = Array(selectionContainers.prefix(idx + 1))
                    }
                }
            } else {
                let parentContainer = currentContainer.parent ?? root!
                selectionContainers.append(parentContainer)
            }
        }

        notifySelectablesOfSelectionChange()
    }

    // parity: core/src/renderer.ts#CliRenderer.requestSelectionUpdate [status=implemented hash=f1f5a852ea6a]
    public func requestSelectionUpdate() {
        guard currentSelection?.isDragging == true else { return }
        let hitId = hitTest(x: latestPointer.x, y: latestPointer.y)
        let hitRenderable = hitId != 0 ? Renderable.renderable(forNumber: hitId) : nil
        updateSelection(hitRenderable, x: latestPointer.x, y: latestPointer.y)
    }

    private func isWithinContainer(_ renderable: Renderable, container: Renderable) -> Bool {
        var current: Renderable? = renderable
        while let node = current {
            if node === container { return true }
            current = node.parent
        }
        return false
    }

    private func finishSelection() {
        guard let sel = currentSelection else { return }
        sel.isDragging = false
        for entry in selectionListeners {
            entry.fn(sel)
        }
        emitVoid(.selection)
        notifySelectablesOfSelectionChange()
    }

    private func notifySelectablesOfSelectionChange() {
        guard let sel = currentSelection else { return }
        var selectedRenderables: [Renderable] = []
        var touchedRenderables: [Renderable] = []
        let container = selectionContainers.last ?? root!

        walkSelectableRenderables(
            container: container,
            selectionBounds: sel.bounds,
            selectedRenderables: &selectedRenderables,
            touchedRenderables: &touchedRenderables
        )

        for prev in sel.touchedRenderables {
            if let r = prev as? Renderable,
               !r.isDestroyed,
               !touchedRenderables.contains(where: { $0 === r })
            {
                _ = r.onSelectionChanged(nil)
            }
        }

        sel.updateSelectedRenderables(selectedRenderables)
        sel.updateTouchedRenderables(touchedRenderables)
    }

    private func walkSelectableRenderables(
        container: Renderable,
        selectionBounds: ViewportBounds,
        selectedRenderables: inout [Renderable],
        touchedRenderables: inout [Renderable]
    ) {
        let children = getObjectsInViewport(
            viewport: selectionBounds,
            objects: container.getChildrenSortedByPrimaryAxis(),
            direction: container.primaryAxis,
            padding: 0,
            minTriggerSize: 0
        )

        for child in children {
            if child.selectable {
                if child.onSelectionChanged(currentSelection) {
                    selectedRenderables.append(child)
                }
                touchedRenderables.append(child)
            }
            if child.getChildrenCount() > 0 {
                walkSelectableRenderables(
                    container: child,
                    selectionBounds: selectionBounds,
                    selectedRenderables: &selectedRenderables,
                    touchedRenderables: &touchedRenderables
                )
            }
        }
    }

    // MARK: - Stats & Frame Capture

    // parity: core/src/renderer.ts#CliRenderer.getStats [status=adapted hash=12e9dfd08cab]
    public func getStats() -> CliRendererStats {
        let sum = frameTimes.reduce(0.0, +)
        let avg = frameTimes.isEmpty ? 0.0 : sum / Double(frameTimes.count)
        let minVal = frameTimes.min() ?? 0.0
        let maxVal = frameTimes.max() ?? 0.0
        return CliRendererStats(
            fps: currentFps,
            frameCount: totalFrameCount,
            cellsUpdated: diffRenderer.stats.cellsUpdated,
            bytesEmitted: diffRenderer.stats.bytesEmitted,
            frameTimes: frameTimes,
            averageFrameTime: avg,
            minFrameTime: minVal,
            maxFrameTime: maxVal,
            frameCallbackTime: lastFrameCallbackTime
        )
    }

    // parity: core/src/renderer.ts#CliRenderer.resetStats [status=implemented hash=87f448a8eeba]
    public func resetStats() {
        frameTimes.removeAll()
        totalFrameCount = 0
    }

    /// Captures the currently presented frame as a newline-separated plain-text string.
    public func captureCharFrame() -> String {
        String(decoding: currentRenderBuffer.getRealCharBytes(addLineBreaks: true), as: UTF8.self)
    }

    /// Captures the currently presented frame with full styled span runs and cursor position.
    public func captureSpans() -> CapturedFrame {
        let cursor = getCursorState()
        return CapturedFrame(
            cols: currentRenderBuffer.width,
            rows: currentRenderBuffer.height,
            cursor: [cursor.x, cursor.y],
            lines: currentRenderBuffer.getSpanLines()
        )
    }
}
