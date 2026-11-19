import OpenTUICore
import OpenTUIKeymap
import OpenTUILayout
import Synchronization

/// Pure-Swift API parity completions for `OpenTUIRenderables`:
/// - `core/src/types.ts` (`ProgramStatusKind`, `ProgramStatus`, `RendererEvents`)
/// - `core/src/Renderable.ts` (`NativeRenderableIntegration`, `Renderable` Yoga style getters,
///   lifecycle/mutation guards, `refreshHooks`, typed scene listener helpers, `RenderableTreeNode`)
/// - `core/src/renderer.ts` (`createCliRenderer`, `KittyImageTransport*`, `Scrollback*`,
///   `SplitFooterReplayResetOptions`, `CliRenderer*Event`, `CliRenderer` console, debug overlay,
///   OSC 52 clipboard, OSC 2/111/9/777/7501 controls, scrollback surfaces/writers, tracked frame
///   callbacks, native stats, and palette detection status)
///
/// Zero Foundation or OS-specific imports — compiles on every Swift 6 platform.

// MARK: - Types Completions (`core/src/types.ts`)

/// Memory telemetry payload emitted on `CliRenderEvents.memorySnapshot`.
public struct MemorySnapshot: Equatable, Hashable, Sendable, Codable {
    public var heapUsed: Int
    public var heapTotal: Int
    public var arrayBuffers: Int

    public init(heapUsed: Int = 0, heapTotal: Int = 0, arrayBuffers: Int = 0) {
        self.heapUsed = heapUsed
        self.heapTotal = heapTotal
        self.arrayBuffers = arrayBuffers
    }
}

// parity: core/src/types.ts#ProgramStatusKind [status=implemented hash=234ce067b524]
public extension ProgramStatusKind {
    /// Wire value sent in OSC 7501 `kind=...` fields.
    var oscFieldValue: String { rawValue }
}

// parity: core/src/types.ts#ProgramStatus [status=implemented hash=b22154cfe8e4]
public extension ProgramStatus {
    static func idle(id: String? = nil, app: String? = nil, title: String? = nil, message: String? = nil) -> ProgramStatus {
        ProgramStatus(state: .idle, id: id, app: app, title: title, message: message)
    }

    static func working(
        id: String? = nil,
        app: String? = nil,
        title: String? = nil,
        message: String? = nil,
        progress: Double? = nil
    ) -> ProgramStatus {
        ProgramStatus(state: .working, id: id, app: app, title: title, message: message, progress: progress)
    }

    static func blocked(
        id: String? = nil,
        app: String? = nil,
        title: String? = nil,
        message: String? = nil,
        kind: ProgramStatusKind? = nil,
        progress: Double? = nil
    ) -> ProgramStatus {
        ProgramStatus(state: .blocked, id: id, app: app, title: title, message: message, kind: kind, progress: progress)
    }

    static func done(id: String? = nil, app: String? = nil, title: String? = nil, message: String? = nil) -> ProgramStatus {
        ProgramStatus(state: .done, id: id, app: app, title: title, message: message)
    }

    static func error(id: String? = nil, app: String? = nil, title: String? = nil, message: String? = nil) -> ProgramStatus {
        ProgramStatus(state: .error, id: id, app: app, title: title, message: message)
    }

    static func clear(id: String? = nil) -> ProgramStatus {
        ProgramStatus(state: .clear, id: id)
    }
}

/// Typed event callback container matching `core/src/types.ts#RendererEvents`.
// parity: core/src/types.ts#RendererEvents [status=adapted hash=0441db3514fd]
public struct RendererEvents {
    public var resize: ((Int, Int) -> Void)?
    public var key: (([UInt8]) -> Void)?
    public var memorySnapshot: ((MemorySnapshot) -> Void)?
    public var capabilities: ((TerminalCapabilities) -> Void)?
    public var selection: ((Selection) -> Void)?
    public var focusedRenderable: ((Renderable?, Renderable?) -> Void)?
    public var focusedEditor: ((EditBufferRenderable?, EditBufferRenderable?) -> Void)?
    public var debugOverlayToggle: ((Bool) -> Void)?
    public var themeMode: ((ThemeMode) -> Void)?

    public init(
        resize: ((Int, Int) -> Void)? = nil,
        key: (([UInt8]) -> Void)? = nil,
        memorySnapshot: ((MemorySnapshot) -> Void)? = nil,
        capabilities: ((TerminalCapabilities) -> Void)? = nil,
        selection: ((Selection) -> Void)? = nil,
        focusedRenderable: ((Renderable?, Renderable?) -> Void)? = nil,
        focusedEditor: ((EditBufferRenderable?, EditBufferRenderable?) -> Void)? = nil,
        debugOverlayToggle: ((Bool) -> Void)? = nil,
        themeMode: ((ThemeMode) -> Void)? = nil
    ) {
        self.resize = resize
        self.key = key
        self.memorySnapshot = memorySnapshot
        self.capabilities = capabilities
        self.selection = selection
        self.focusedRenderable = focusedRenderable
        self.focusedEditor = focusedEditor
        self.debugOverlayToggle = debugOverlayToggle
        self.themeMode = themeMode
    }
}

// MARK: - Renderable Parity Completions (`core/src/Renderable.ts`)

/// Errors raised when mutating a destroyed `Renderable`.
public enum RenderableMutationError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
    case destroyed(id: String)

    public var description: String {
        switch self {
        case .destroyed(let id):
            return "Renderable '\(id)' is destroyed and no longer mutable"
        }
    }
}

/// Body rendering mode declared by `NativeRenderableIntegration`.
public enum NativeRenderableBodyMode: @unchecked Sendable {
    case host
    case native(draw: (OptimizedBuffer, Double) -> Void, buffered: Bool = false)
}

/// Optional lifecycle hook descriptors declared by `NativeRenderableIntegration`.
public struct NativeRenderableLifecycle: @unchecked Sendable {
    public var resize: ((Int, Int) -> Void)?
    public var updateIdle: ((Double) -> Void)?
    public var updateActive: ((Renderable) -> Bool)?
    public var scrollActive: ((Renderable) -> Bool)?
    public var scrollNotify: ((Renderable) -> Void)?

    public init(
        resize: ((Int, Int) -> Void)? = nil,
        updateIdle: ((Double) -> Void)? = nil,
        updateActive: ((Renderable) -> Bool)? = nil,
        scrollActive: ((Renderable) -> Bool)? = nil,
        scrollNotify: ((Renderable) -> Void)? = nil
    ) {
        self.resize = resize
        self.updateIdle = updateIdle
        self.updateActive = updateActive
        self.scrollActive = scrollActive
        self.scrollNotify = scrollNotify
    }
}

/// Class-owned native scene integration metadata matching `core/src/Renderable.ts#NativeRenderableIntegration`.
// parity: core/src/Renderable.ts#NativeRenderableIntegration [status=adapted hash=18c332053b6f]
public struct NativeRenderableIntegration: @unchecked Sendable {
    public var kind: String
    public var body: NativeRenderableBodyMode
    public var lifecycle: NativeRenderableLifecycle?
    public var beforeAfter: Bool
    public var paintBufferDestination: Bool
    public var nativeBufferComposition: Bool
    public var lineInfo: Bool
    public var measure: FlexMeasureFunc?

    public init(
        kind: String = "host",
        body: NativeRenderableBodyMode = .host,
        lifecycle: NativeRenderableLifecycle? = nil,
        beforeAfter: Bool = false,
        paintBufferDestination: Bool = false,
        nativeBufferComposition: Bool = false,
        lineInfo: Bool = false,
        measure: FlexMeasureFunc? = nil
    ) {
        self.kind = kind
        self.body = body
        self.lifecycle = lifecycle
        self.beforeAfter = beforeAfter
        self.paintBufferDestination = paintBufferDestination
        self.nativeBufferComposition = nativeBufferComposition
        self.lineInfo = lineInfo
        self.measure = measure
    }
}

extension Renderable: RenderableTreeNode {
    public func treeChildren() -> [any RenderableTreeNode] {
        getChildren()
    }
}

public extension Renderable {
    /// Accessor returning the owning `RenderContext` (`ctx` stored property).
    // parity: core/src/Renderable.ts#Renderable.ctx [status=implemented hash=8f0ec387c020]
    func getRenderContext() -> any RenderContext {
        ctx
    }

    /// Returns `true` after this renderable has been destroyed and its layout node freed.
    // parity: core/src/Renderable.ts#Renderable.isFreed [status=implemented hash=5fe22d39c36f]
    func isFreed() -> Bool {
        isDestroyed
    }

    /// Throws `RenderableMutationError.destroyed` if this renderable has been destroyed.
    // parity: core/src/Renderable.ts#Renderable.assertMutable [status=implemented hash=0397286ed8d6]
    func assertMutable() throws(RenderableMutationError) {
        if isFreed() {
            throw .destroyed(id: id)
        }
    }

    /// Executes `operation` when alive, or returns `nil` as a no-op if the renderable is destroyed.
    // parity: core/src/Renderable.ts#Renderable.runMutation [status=implemented hash=97ea2b5c37c2]
    @discardableResult
    func runMutation<T>(_ operation: () throws -> T) rethrows -> T? {
        guard !isFreed() else { return nil }
        return try operation()
    }

    /// Void convenience overload of `runMutation(_:)` that skips `operation` when destroyed.
    func runMutation(_ operation: () throws -> Void) rethrows {
        guard !isFreed() else { return }
        try operation()
    }

    // MARK: Yoga Style Getters

    // parity: core/src/Renderable.ts#Renderable.getFlexDirection [status=implemented hash=53d9103a6862]
    func getFlexDirection() -> FlexDirection {
        isFreed() ? .column : layoutNode.style.flexDirection
    }

    // parity: core/src/Renderable.ts#Renderable.getMargin [status=implemented hash=1932af44c800]
    func getMargin(_ edge: Edge) -> FlexValue {
        isFreed() ? .undefined : layoutNode.style.margin.value(for: edge)
    }

    // parity: core/src/Renderable.ts#Renderable.getWidth [status=implemented hash=1aeed5dae52d]
    func getWidth() -> FlexValue {
        isFreed() ? .undefined : layoutNode.style.width
    }

    // parity: core/src/Renderable.ts#Renderable.getFlexWrap [status=implemented hash=71687ca3791f]
    func getFlexWrap() -> Wrap {
        isFreed() ? .noWrap : layoutNode.style.flexWrap
    }

    // parity: core/src/Renderable.ts#Renderable.getAlignItems [status=implemented hash=406811d38406]
    func getAlignItems() -> Align {
        isFreed() ? .stretch : layoutNode.style.alignItems
    }

    // parity: core/src/Renderable.ts#Renderable.getAlignContent [status=implemented hash=db9a5d821356]
    func getAlignContent() -> Align {
        isFreed() ? .flexStart : layoutNode.style.alignContent
    }

    // parity: core/src/Renderable.ts#Renderable.getAspectRatio [status=implemented hash=264e10314059]
    func getAspectRatio() -> Float {
        isFreed() ? .nan : (layoutNode.style.aspectRatio ?? .nan)
    }

    // parity: core/src/Renderable.ts#Renderable.getJustifyContent [status=implemented hash=77159ea3ac4c]
    func getJustifyContent() -> Justify {
        isFreed() ? .flexStart : layoutNode.style.justifyContent
    }

    // parity: core/src/Renderable.ts#Renderable.getAlignSelf [status=implemented hash=008d75d5a737]
    func getAlignSelf() -> Align {
        isFreed() ? .auto : layoutNode.style.alignSelf
    }

    // parity: core/src/Renderable.ts#Renderable.getPositionType [status=implemented hash=e3c38b59129b]
    func getPositionType() -> PositionType {
        isFreed() ? .relative : layoutNode.style.positionType
    }

    // parity: core/src/Renderable.ts#Renderable.getFlexGrow [status=implemented hash=a1b8a1823815]
    func getFlexGrow() -> Float {
        isFreed() ? .nan : layoutNode.style.flexGrow
    }

    // parity: core/src/Renderable.ts#Renderable.getFlexShrink [status=implemented hash=5c752b1ca27a]
    func getFlexShrink() -> Float {
        isFreed() ? .nan : layoutNode.style.flexShrink
    }

    // parity: core/src/Renderable.ts#Renderable.getFlexBasis [status=implemented hash=66864e7205df]
    func getFlexBasis() -> FlexValue {
        isFreed() ? .undefined : layoutNode.style.flexBasis
    }

    // parity: core/src/Renderable.ts#Renderable.getHeight [status=implemented hash=45f9dec4dd9e]
    func getHeight() -> FlexValue {
        isFreed() ? .undefined : layoutNode.style.height
    }

    // parity: core/src/Renderable.ts#Renderable.getMinWidth [status=implemented hash=4f9e354f9b7e]
    func getMinWidth() -> FlexValue {
        isFreed() ? .undefined : layoutNode.style.minWidth
    }

    // parity: core/src/Renderable.ts#Renderable.getMinHeight [status=implemented hash=6db2bf58564e]
    func getMinHeight() -> FlexValue {
        isFreed() ? .undefined : layoutNode.style.minHeight
    }

    // parity: core/src/Renderable.ts#Renderable.getMaxWidth [status=implemented hash=c284210db727]
    func getMaxWidth() -> FlexValue {
        isFreed() ? .undefined : layoutNode.style.maxWidth
    }

    // parity: core/src/Renderable.ts#Renderable.getMaxHeight [status=implemented hash=d6f7b3df4e7b]
    func getMaxHeight() -> FlexValue {
        isFreed() ? .undefined : layoutNode.style.maxHeight
    }

    // parity: core/src/Renderable.ts#Renderable.getPadding [status=implemented hash=01cf419aef7e]
    func getPadding(_ edge: Edge) -> FlexValue {
        isFreed() ? .undefined : layoutNode.style.padding.value(for: edge)
    }

    // parity: core/src/Renderable.ts#Renderable.getGap [status=implemented hash=9ae671fea45e]
    func getGap(_ gutter: Gutter) -> FlexValue {
        isFreed() ? .undefined : layoutNode.style.gap.value(for: gutter)
    }

    // MARK: Hook Refresh & Scene Event Listener Helpers

    /// Re-synchronizes lifecycle pass registration and schedules a render after hook updates.
    // parity: core/src/Renderable.ts#Renderable.refreshHooks [status=implemented hash=35ad8fce31c4]
    func refreshHooks() {
        guard !isDestroyed else { return }
        if !needsLifecyclePass {
            ctx.unregisterLifecyclePass(self)
        } else if parent != nil || self is RootRenderable {
            ctx.registerLifecyclePass(self)
        }
        requestRender()
    }

    /// Registers a scene event listener on this `Renderable`.
    // parity: core/src/Renderable.ts#Renderable.on [status=implemented hash=e4f420a3c452]
    @discardableResult
    func on(sceneEvent event: String, _ listener: @escaping () -> Void) -> RenderableListenerToken {
        on(event, listener)
    }

    /// Registers a typed `RenderableEvents` listener.
    // parity: core/src/Renderable.ts#Renderable.addListener [status=implemented hash=58b07d25f276]
    @discardableResult
    func addListener(_ event: RenderableEvents, _ listener: @escaping () -> Void) -> RenderableListenerToken {
        on(event, listener)
    }

    /// Prepends a typed `RenderableEvents` listener so it runs before existing listeners.
    // parity: core/src/Renderable.ts#Renderable.prependListener [status=implemented hash=b8f5a22a8050]
    @discardableResult
    func prependListener(_ event: RenderableEvents, _ listener: @escaping () -> Void) -> RenderableListenerToken {
        prependListener(event.rawValue, listener)
    }

    /// Unregisters a previously added listener token.
    // parity: core/src/Renderable.ts#Renderable.off [status=implemented hash=699fe3ec2c29]
    func off(listener token: RenderableListenerToken) {
        off(token)
    }

    /// Removes a previously added listener token.
    // parity: core/src/Renderable.ts#Renderable.removeListener [status=implemented hash=c1d306efad8f]
    func removeListener(token: RenderableListenerToken) {
        removeListener(token)
    }

    /// Removes all listeners registered for a typed `RenderableEvents` event.
    // parity: core/src/Renderable.ts#Renderable.removeAllListeners [status=implemented hash=ff8c14b63db5]
    func removeAllListeners(_ event: RenderableEvents) {
        removeAllListeners(for: event.rawValue)
    }
}

// MARK: - CliRenderer Supporting Types (`core/src/renderer.ts`)

/// Kitty Graphics Protocol transmission transport mode.
// parity: core/src/renderer.ts#KittyImageTransport [status=implemented hash=2fc9d49fdd7e]
public enum KittyImageTransport: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case raw
    case zlib
    case file
}

/// Active effective transport mode reported by `KittyImageTransportStatus`.
public enum KittyImageEffectiveTransport: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case raw
    case zlib
    case png
    case file
}

/// File-transfer probe/readiness state reported by `KittyImageTransportStatus`.
public enum KittyImageFileState: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case disabled
    case probing
    case ready
    case unsupported
    case timeout
    case ioError = "io-error"
    case cancelled
}

/// Fallback reason reported by `KittyImageTransportStatus`.
public enum KittyImageFallbackReason: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case none
    case notReady = "not-ready"
    case unavailable
    case budget
    case busy
    case preparation
    case compression
}

/// Runtime telemetry for Kitty Graphics image transport.
// parity: core/src/renderer.ts#KittyImageTransportStatus [status=implemented hash=68875d232aa9]
public struct KittyImageTransportStatus: Equatable, Hashable, Sendable, Codable {
    public var requested: KittyImageTransport
    public var effective: KittyImageEffectiveTransport
    public var fileState: KittyImageFileState
    public var fallback: KittyImageFallbackReason
    public var pendingFiles: Int
    public var pendingBytes: Int

    public init(
        requested: KittyImageTransport = .raw,
        effective: KittyImageEffectiveTransport = .raw,
        fileState: KittyImageFileState = .disabled,
        fallback: KittyImageFallbackReason = .none,
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

/// Event payload emitted when captured external output or scrollback commits a snapshot buffer.
// parity: core/src/renderer.ts#CliRendererExternalOutputEvent [status=implemented hash=7f79766af46a]
public struct CliRendererExternalOutputEvent: @unchecked Sendable {
    public var snapshot: OptimizedBuffer
    public var rowColumns: Int
    public var startOnNewLine: Bool
    public var trailingNewline: Bool

    public init(
        snapshot: OptimizedBuffer,
        rowColumns: Int,
        startOnNewLine: Bool = true,
        trailingNewline: Bool = true
    ) {
        self.snapshot = snapshot
        self.rowColumns = rowColumns
        self.startOnNewLine = startOnNewLine
        self.trailingNewline = trailingNewline
    }
}

// parity: core/src/renderer.ts#PixelResolution [status=implemented hash=5572b9324fb5]
public extension PixelResolution {
    /// Width-to-height aspect ratio in pixels (0 if height is 0).
    var pixelAspectRatio: Double {
        height > 0 ? Double(width) / Double(height) : 0
    }

    /// Computes approximate single-cell dimensions in pixels for a terminal grid of `(cols, rows)`.
    func cellPixelSize(cols: Int, rows: Int) -> (width: Double, height: Double)? {
        guard cols > 0 && rows > 0 && width > 0 && height > 0 else { return nil }
        return (Double(width) / Double(cols), Double(height) / Double(rows))
    }
}

/// Event payload emitted when a renderable throws during frame rendering.
// parity: core/src/renderer.ts#CliRendererErrorEvent [status=implemented hash=398c90129e29]
public struct CliRendererErrorEvent: @unchecked Sendable {
    public var error: any Error
    public var renderable: Renderable?

    public init(error: any Error, renderable: Renderable? = nil) {
        self.error = error
        self.renderable = renderable
    }
}

/// Event payload emitted when an encoded frame exceeds the per-frame output byte budget.
// parity: core/src/renderer.ts#CliRendererFrameDroppedEvent [status=implemented hash=52425f5371bb]
public struct CliRendererFrameDroppedEvent: Equatable, Hashable, Sendable, Codable {
    public var bytes: Int
    public var limit: Int

    public init(bytes: Int, limit: Int) {
        self.bytes = bytes
        self.limit = limit
    }
}

/// Event payload emitted when a mouse event handler throws an error.
// parity: core/src/renderer.ts#CliRendererHandlerErrorEvent [status=implemented hash=910a95433e04]
public struct CliRendererHandlerErrorEvent {
    public var error: any Error
    public var event: MouseEvent

    public init(error: any Error, event: MouseEvent) {
        self.error = error
        self.event = event
    }
}

/// Context passed to a `ScrollbackWriter` closure when committing rendered output to scrollback.
// parity: core/src/renderer.ts#ScrollbackRenderContext [status=implemented hash=1012ee64f588]
public struct ScrollbackRenderContext {
    public var width: Int
    public var widthMethod: WidthMethod
    public var tailColumn: Int
    public var renderContext: any RenderContext

    public init(width: Int, widthMethod: WidthMethod, tailColumn: Int, renderContext: any RenderContext) {
        self.width = width
        self.widthMethod = widthMethod
        self.tailColumn = tailColumn
        self.renderContext = renderContext
    }
}

/// Rendered renderable tree descriptor returned by a `ScrollbackWriter`.
// parity: core/src/renderer.ts#ScrollbackSnapshot [status=implemented hash=bafb407fa831]
public struct ScrollbackSnapshot {
    public var root: Renderable
    public var width: Int?
    public var height: Int?
    public var rowColumns: Int?
    public var startOnNewLine: Bool?
    public var trailingNewline: Bool?
    public var teardown: (() -> Void)?

    public init(
        root: Renderable,
        width: Int? = nil,
        height: Int? = nil,
        rowColumns: Int? = nil,
        startOnNewLine: Bool? = nil,
        trailingNewline: Bool? = nil,
        teardown: (() -> Void)? = nil
    ) {
        self.root = root
        self.width = width
        self.height = height
        self.rowColumns = rowColumns
        self.startOnNewLine = startOnNewLine
        self.trailingNewline = trailingNewline
        self.teardown = teardown
    }
}

/// Closure producing a `ScrollbackSnapshot` for `CliRenderer.writeToScrollback(_:)`.
// parity: core/src/renderer.ts#ScrollbackWriter [status=implemented hash=e6882f4aa1bb]
public typealias ScrollbackWriter = (ScrollbackRenderContext) -> ScrollbackSnapshot

/// Configuration options for `CliRenderer.createScrollbackSurface(options:)`.
// parity: core/src/renderer.ts#ScrollbackSurfaceOptions [status=implemented hash=256ca61ccebe]
public struct ScrollbackSurfaceOptions: Equatable, Hashable, Sendable, Codable {
    public var startOnNewLine: Bool

    public init(startOnNewLine: Bool = true) {
        self.startOnNewLine = startOnNewLine
    }
}

/// Row commitment options for `ScrollbackSurface.commitRows(...)`.
// parity: core/src/renderer.ts#ScrollbackSurfaceCommitOptions [status=implemented hash=0300c6d39fff]
public struct ScrollbackSurfaceCommitOptions: Equatable, Hashable, Sendable, Codable {
    public var rowColumns: Int?
    public var trailingNewline: Bool?

    public init(rowColumns: Int? = nil, trailingNewline: Bool? = nil) {
        self.rowColumns = rowColumns
        self.trailingNewline = trailingNewline
    }
}

/// Incremental offscreen render surface for committing rows to split-footer scrollback.
// parity: core/src/renderer.ts#ScrollbackSurface [status=implemented hash=3841bba83f19]
public protocol ScrollbackSurface: AnyObject {
    var renderContext: any RenderContext { get }
    var root: Renderable { get }
    var width: Int { get }
    var height: Int { get }
    var isDestroyed: Bool { get }

    func render()
    func settle(timeoutMs: Double?) async
    func commitRows(startRow: Int, endRowExclusive: Int, options: ScrollbackSurfaceCommitOptions)
    func destroy()
}

public extension ScrollbackSurface {
    func settle() async {
        await settle(timeoutMs: nil)
    }

    func commitRows(startRow: Int, endRowExclusive: Int) {
        commitRows(startRow: startRow, endRowExclusive: endRowExclusive, options: ScrollbackSurfaceCommitOptions())
    }
}

/// Options for `CliRenderer.resetSplitFooterForReplay(options:)`.
// parity: core/src/renderer.ts#SplitFooterReplayResetOptions [status=implemented hash=636a0db7151a]
public struct SplitFooterReplayResetOptions: Equatable, Hashable, Sendable, Codable {
    public var clearSavedLines: Bool

    public init(clearSavedLines: Bool = false) {
        self.clearSavedLines = clearSavedLines
    }
}

/// Recorded raw input entry returned by `CliRenderer.getDebugInputs()`.
public struct DebugInputEntry: Equatable, Hashable, Sendable, Codable {
    public var timestamp: String
    public var sequence: String

    public init(timestamp: String, sequence: String) {
        self.timestamp = timestamp
        self.sequence = sequence
    }
}

/// Low-level renderer statistics returned by `CliRenderer.getNativeStats()`.
public struct NativeRenderStats: Equatable, Hashable, Sendable, Codable {
    public var frameCount: UInt64
    public var cellsUpdated: Int
    public var rowsCompared: Int
    public var rowsDiffed: Int
    public var bytesEmitted: Int
    public var memoryUsed: Int
    public var memoryAllocated: Int
    public var memoryBuffers: Int

    public init(
        frameCount: UInt64 = 0,
        cellsUpdated: Int = 0,
        rowsCompared: Int = 0,
        rowsDiffed: Int = 0,
        bytesEmitted: Int = 0,
        memoryUsed: Int = 0,
        memoryAllocated: Int = 0,
        memoryBuffers: Int = 2
    ) {
        self.frameCount = frameCount
        self.cellsUpdated = cellsUpdated
        self.rowsCompared = rowsCompared
        self.rowsDiffed = rowsDiffed
        self.bytesEmitted = bytesEmitted
        self.memoryUsed = memoryUsed
        self.memoryAllocated = memoryAllocated
        self.memoryBuffers = memoryBuffers
    }
}

/// Status of terminal palette detection on `CliRenderer`.
public enum PaletteDetectionStatus: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case idle
    case detecting
    case cached
}

/// Errors thrown by split-footer scrollback and mode validation APIs.
public enum CliRendererOperationError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
    case rendererDestroyed
    case requiresSplitFooterCapture(operation: String)
    case requiresActiveTerminal(operation: String)
    case invalidSnapshotDimension(axis: String)

    public var description: String {
        switch self {
        case .rendererDestroyed:
            return "Renderer is destroyed"
        case .requiresSplitFooterCapture(let operation):
            return "\(operation) requires screenMode \"split-footer\" and externalOutputMode \"capture-stdout\""
        case .requiresActiveTerminal(let operation):
            return "\(operation) requires an active terminal"
        case .invalidSnapshotDimension(let axis):
            return "writeToScrollback produced a non-finite \(axis)"
        }
    }
}

/// Identity-tracked frame callback handle for `setFrameCallback`/`hasFrameCallback`/`removeFrameCallback`.
public final class FrameCallbackHandle: Equatable, Hashable, @unchecked Sendable {
    private static let nextIdLock = Mutex<UInt64>(1)

    public let id: UInt64
    public let callback: (Double) -> Void

    public init(_ callback: @escaping (Double) -> Void) {
        self.id = Self.nextIdLock.withLock { current in
            let allocated = current
            current &+= 1
            if current == 0 { current = 1 }
            return allocated
        }
        self.callback = callback
    }

    public static func == (lhs: FrameCallbackHandle, rhs: FrameCallbackHandle) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - Associated Per-Renderer Extended State

private final class CliRendererExtraState: @unchecked Sendable {
    weak var renderer: CliRenderer?

    var lastSceneTimeMs: Double = 0
    var terminalIsSetup: Bool = false
    var consoleMode: ConsoleMode = .disabled
    var console: TerminalConsole? = nil
    var externalOutputMode: ExternalOutputMode
    var kittyImageTransport: KittyImageTransport = .raw
    var kittyFileState: KittyImageFileState = .disabled
    var kittyFallback: KittyImageFallbackReason = .none
    var kittyPendingFiles: Int = 0
    var kittyPendingBytes: Int = 0
    var debugOverlayEnabled: Bool = false
    var debugOverlayCorner: DebugOverlayCorner = .bottomRight
    var automaticMemorySnapshot: Bool = false
    var memorySnapshotInterval: Double = 0
    var memorySnapshotTimer: TimerHandle? = nil
    var lastMemorySnapshot: MemorySnapshot = MemorySnapshot()
    var lastProgramStatus: ProgramStatus? = nil
    var terminalTitle: String = ""
    var debugInputs: [DebugInputEntry] = []
    var gatherStats: Bool = false
    var paletteStatus: PaletteDetectionStatus = .idle
    var pendingSplitTailColumn: Int = 0
    var committedScrollbackEvents: [CliRendererExternalOutputEvent] = []
    var trackedFrameCallbacks: [FrameCallbackHandle] = []
    var trackedCallbackBridgeInstalled: Bool = false
    var closedContinuations: [CheckedContinuation<Void, Never>] = []
    var isClosed: Bool = false

    init(renderer: CliRenderer) {
        self.renderer = renderer
        self.externalOutputMode = (renderer.screenMode == .splitFooter) ? .captureStdout : .passthrough
        self.isClosed = renderer.isDestroyed
    }

    func finishClose() {
        guard !isClosed else { return }
        isClosed = true
        if let timer = memorySnapshotTimer, let r = renderer {
            r.clock.clearInterval(timer)
        }
        memorySnapshotTimer = nil
        console?.destroy()
        console = nil
        trackedFrameCallbacks.removeAll()
        let continuations = closedContinuations
        closedContinuations.removeAll()
        for cont in continuations {
            cont.resume()
        }
    }
}

private final class CliRendererExtraStore: Sendable {
    static let shared = CliRendererExtraStore()
    private let map = Mutex<[ObjectIdentifier: CliRendererExtraState]>([:])

    func state(for renderer: CliRenderer) -> CliRendererExtraState {
        let key = ObjectIdentifier(renderer)
        let (state, created): (CliRendererExtraState, Bool) = map.withLock { store in
            if store.count > 64 {
                store = store.filter { $0.value.renderer != nil }
            }
            if let existing = store[key], existing.renderer === renderer {
                return (existing, false)
            }
            let fresh = CliRendererExtraState(renderer: renderer)
            store[key] = fresh
            return (fresh, true)
        }
        if created && !renderer.isDestroyed {
            _ = renderer.on(.destroy) { [weak renderer] in
                if let renderer {
                    CliRendererExtraStore.shared.cleanup(for: renderer)
                } else {
                    state.finishClose()
                }
            }
        }
        return state
    }

    func cleanup(for renderer: CliRenderer) {
        let key = ObjectIdentifier(renderer)
        let removed: CliRendererExtraState? = map.withLock { store in
            store.removeValue(forKey: key)
        }
        removed?.finishClose()
    }
}

// MARK: - Concrete ScrollbackSurface Implementation

private final class CliScrollbackSurface: ScrollbackSurface {
    private weak var owner: CliRenderer?
    private let internalRoot: RootRenderable
    private let publicRoot: BoxRenderable
    private var backingBuffer: OptimizedBuffer
    private let startOnNewLine: Bool
    private var _isDestroyed: Bool = false

    public let renderContext: any RenderContext

    public var root: Renderable { publicRoot }
    public var width: Int { backingBuffer.width }
    public var height: Int { backingBuffer.height }
    public var isDestroyed: Bool { _isDestroyed }

    init(owner: CliRenderer, options: ScrollbackSurfaceOptions) {
        self.owner = owner
        self.renderContext = owner
        self.startOnNewLine = options.startOnNewLine
        let initialWidth = max(1, owner.width)
        self.internalRoot = RootRenderable(ctx: owner)
        self.publicRoot = BoxRenderable(
            ctx: owner,
            options: BoxOptions(
                id: "scrollback-surface-root",
                width: .point(Float(initialWidth)),
                position: .absolute,
                top: .point(0),
                left: .point(0)
            )
        )
        self.internalRoot.add(self.publicRoot)
        self.backingBuffer = OptimizedBuffer(
            width: initialWidth,
            height: 1,
            widthMethod: owner.widthMethod,
            id: "scrollback-surface-buffer",
            graphemePool: owner.graphemePool,
            linkPool: owner.linkPool
        )
    }

    func render() {
        guard !_isDestroyed, let owner else { return }
        let targetW = max(1, owner.width)
        FlexSolver.calculateLayout(
            root: internalRoot.layoutNode,
            availableWidth: Float(targetW),
            availableHeight: Float.nan,
            direction: .ltr
        )
        internalRoot.updateFromLayout()
        let computedH = max(1, publicRoot.height)
        if backingBuffer.width != targetW || backingBuffer.height != computedH {
            try? backingBuffer.resize(width: targetW, height: computedH)
        }
        backingBuffer.clear(bg: RGBA.fromValues(0, 0, 0, 0), char: defaultSpaceChar)
        internalRoot.render(buffer: backingBuffer, deltaTime: 0)
    }

    func settle(timeoutMs: Double?) async {
        _ = timeoutMs
        render()
        await Task.yield()
    }

    func commitRows(startRow: Int, endRowExclusive: Int, options: ScrollbackSurfaceCommitOptions) {
        guard !_isDestroyed, let owner, !owner.isDestroyed else { return }
        let lo = max(0, min(startRow, backingBuffer.height))
        let hi = max(lo, min(endRowExclusive, backingBuffer.height))
        guard lo < hi else { return }

        let sliceHeight = hi - lo
        let sliceBuffer = OptimizedBuffer(
            width: backingBuffer.width,
            height: sliceHeight,
            widthMethod: backingBuffer.widthMethod,
            id: "scrollback-surface-commit",
            graphemePool: owner.graphemePool,
            linkPool: owner.linkPool
        )
        sliceBuffer.drawFrameBuffer(
            destX: 0,
            destY: 0,
            frameBuffer: backingBuffer,
            sourceX: 0,
            sourceY: lo,
            sourceWidth: backingBuffer.width,
            sourceHeight: sliceHeight
        )

        let text = sliceBuffer.getPlainText(trimTrailingSpaces: true)
        let trailingNewline = options.trailingNewline ?? true
        let prefix = startOnNewLine ? "\n" : ""
        let suffix = trailingNewline ? "\n" : ""
        owner.outputWriter?("\(prefix)\(text)\(suffix)")

        let event = CliRendererExternalOutputEvent(
            snapshot: sliceBuffer,
            rowColumns: options.rowColumns ?? sliceBuffer.width,
            startOnNewLine: startOnNewLine,
            trailingNewline: trailingNewline
        )
        let extra = CliRendererExtraStore.shared.state(for: owner)
        extra.committedScrollbackEvents.append(event)
        extra.pendingSplitTailColumn = trailingNewline ? 0 : (options.rowColumns ?? sliceBuffer.width) % max(1, owner.width)
    }

    func destroy() {
        guard !_isDestroyed else { return }
        _isDestroyed = true
        internalRoot.destroyRecursively()
        backingBuffer.destroy()
    }
}

// MARK: - Factory Function (`core/src/renderer.ts#createCliRenderer`)

/// Creates a `CliRenderer` and runs its async `setupTerminal()` initialization.
// parity: core/src/renderer.ts#createCliRenderer [status=adapted hash=39b4f67a1582]
public func createCliRenderer(config: CliRendererConfig = CliRendererConfig()) async -> CliRenderer {
    let renderer = CliRenderer(config: config)
    await renderer.setupTerminal()
    return renderer
}

// MARK: - CliRenderer Parity Completions (`core/src/renderer.ts`)

public extension CliRenderer {
    /// Duration (in milliseconds) of the most recent scene update/render pass.
    // parity: core/src/renderer.ts#CliRenderer.lastSceneTimeMs [status=implemented hash=627de62d58a4]
    var lastSceneTimeMs: Double {
        CliRendererExtraStore.shared.state(for: self).lastSceneTimeMs
    }

    /// Async task that completes once `destroy()` has finished tearing down this renderer.
    // parity: core/src/renderer.ts#CliRenderer.closed [status=adapted hash=8da6dfd5f30e]
    var closed: Task<Void, Never> {
        let extra = CliRendererExtraStore.shared.state(for: self)
        if isDestroyed || extra.isClosed {
            return Task {}
        }
        return Task {
            await withCheckedContinuation { continuation in
                if self.isDestroyed || extra.isClosed {
                    continuation.resume()
                } else {
                    extra.closedContinuations.append(continuation)
                }
            }
        }
    }

    /// Currently focused `EditBufferRenderable`, or `nil` if focus is absent or on another renderable type.
    // parity: core/src/renderer.ts#CliRenderer.currentFocusedEditor [status=implemented hash=6846da017d7c]
    var currentFocusedEditor: EditBufferRenderable? {
        currentFocusedRenderable as? EditBufferRenderable
    }

    /// Active built-in console overlay mode (`.consoleOverlay` or `.disabled`).
    // parity: core/src/renderer.ts#CliRenderer.consoleMode [status=implemented hash=19a337866c2a]
    var consoleMode: ConsoleMode {
        get {
            CliRendererExtraStore.shared.state(for: self).consoleMode
        }
        set {
            let extra = CliRendererExtraStore.shared.state(for: self)
            extra.consoleMode = newValue
            if newValue == .consoleOverlay {
                console.activate()
            } else {
                extra.console?.deactivate()
            }
        }
    }

    /// Resolves once the renderer has no active frame loop or pending scheduled frame work.
    // parity: core/src/renderer.ts#CliRenderer.idle [status=adapted hash=74e3d4a43958]
    func idle() async {
        if isDestroyed {
            await closed.value
            return
        }
        var spins = 0
        while !isDestroyed && spins < 64 {
            let sched = getSchedulerState()
            if !sched.isRunning && !sched.isRendering && !sched.hasScheduledRender {
                return
            }
            spins += 1
            await Task.yield()
        }
    }

    /// Built-in terminal debug console overlay owned by this renderer.
    // parity: core/src/renderer.ts#CliRenderer.console [status=implemented hash=e38e444a5e5d]
    var console: TerminalConsole {
        let extra = CliRendererExtraStore.shared.state(for: self)
        if let existing = extra.console {
            return existing
        }
        let created = TerminalConsole(
            width: width,
            height: height,
            options: ConsoleOptions(widthMethod: widthMethod),
            onRequestRender: { [weak self] in
                self?.requestRender()
            }
        )
        extra.console = created
        return created
    }

    /// Controls whether external stdout output is captured for split-footer replay or passed through.
    // parity: core/src/renderer.ts#CliRenderer.externalOutputMode [status=implemented hash=7275e3b831af]
    var externalOutputMode: ExternalOutputMode {
        get {
            CliRendererExtraStore.shared.state(for: self).externalOutputMode
        }
        set {
            if newValue == .captureStdout && screenMode != .splitFooter {
                preconditionFailure("externalOutputMode \"capture-stdout\" requires screenMode \"split-footer\"")
            }
            let extra = CliRendererExtraStore.shared.state(for: self)
            extra.externalOutputMode = newValue
            requestRender()
        }
    }

    /// String representation of the current `controlState` (e.g. `"idle"`, `"explicit_started"`).
    // parity: core/src/renderer.ts#CliRenderer.currentControlState [status=implemented hash=199959606930]
    var currentControlState: String {
        controlState.rawValue
    }

    /// Requested Kitty Graphics Protocol image transport mode (`.raw`, `.zlib`, `.file`).
    // parity: core/src/renderer.ts#CliRenderer.kittyImageTransport [status=implemented hash=bb0391f3139e]
    var kittyImageTransport: KittyImageTransport {
        get {
            CliRendererExtraStore.shared.state(for: self).kittyImageTransport
        }
        set {
            guard !isDestroyed else { return }
            let extra = CliRendererExtraStore.shared.state(for: self)
            guard extra.kittyImageTransport != newValue else { return }
            extra.kittyImageTransport = newValue
            extra.kittyFileState = (newValue == .file) ? .probing : .disabled
            extra.kittyFallback = (newValue == .file) ? .notReady : .none
            requestRender()
        }
    }

    /// Snapshot of Kitty Graphics image transport state and pending transfer counts.
    // parity: core/src/renderer.ts#CliRenderer.kittyImageTransportStatus [status=implemented hash=c71add6829e1]
    var kittyImageTransportStatus: KittyImageTransportStatus {
        let extra = CliRendererExtraStore.shared.state(for: self)
        let effective: KittyImageEffectiveTransport
        switch extra.kittyImageTransport {
        case .raw:
            effective = .raw
        case .zlib:
            effective = .zlib
        case .file:
            effective = (extra.kittyFileState == .ready) ? .file : .raw
        }
        return KittyImageTransportStatus(
            requested: extra.kittyImageTransport,
            effective: effective,
            fileState: extra.kittyFileState,
            fallback: extra.kittyFallback,
            pendingFiles: extra.kittyPendingFiles,
            pendingBytes: extra.kittyPendingBytes
        )
    }

    /// Cancels any active Kitty image file transfers and requests a re-render.
    // parity: core/src/renderer.ts#CliRenderer.cancelKittyImageTransport [status=implemented hash=f227d6d212c8]
    func cancelKittyImageTransport() {
        guard !isDestroyed else { return }
        let extra = CliRendererExtraStore.shared.state(for: self)
        if extra.kittyImageTransport == .file || extra.kittyFileState == .probing || extra.kittyPendingFiles > 0 {
            extra.kittyFileState = .cancelled
        }
        extra.kittyPendingFiles = 0
        extra.kittyPendingBytes = 0
        requestRender()
    }

    /// Emits a terminal desktop notification via OSC 777 (when `title` is given) or OSC 9.
    // parity: core/src/renderer.ts#CliRenderer.triggerNotification [status=implemented hash=57b26dec6570]
    @discardableResult
    func triggerNotification(_ message: String, title: String? = nil) -> Bool {
        guard !isDestroyed else { return false }
        let seq: String
        if let title, !title.isEmpty {
            seq = "\u{1B}]777;notify;\(title);\(message)\u{07}"
        } else {
            seq = "\u{1B}]9;\(message)\u{07}"
        }
        outputWriter?(seq)
        return true
    }

    /// Emits an OSC 7501 Program Status Protocol report via `outputWriter`.
    // parity: core/src/renderer.ts#CliRenderer.setProgramStatus [status=implemented hash=783d05ab9f35]
    @discardableResult
    func setProgramStatus(_ status: ProgramStatus) -> Bool {
        guard !isDestroyed && controlState != .explicitSuspended else { return false }
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
        outputWriter?(seq)
        CliRendererExtraStore.shared.state(for: self).lastProgramStatus = status
        return true
    }

    /// Records a raw input sequence for diagnostic retrieval via `getDebugInputs()`.
    func recordDebugInput(_ sequence: String, timestamp: String? = nil) {
        let extra = CliRendererExtraStore.shared.state(for: self)
        let ts = timestamp ?? "\(Int(clock.now()))ms"
        extra.debugInputs.append(DebugInputEntry(timestamp: ts, sequence: sequence))
    }

    /// Returns a copy of recorded debug input entries.
    // parity: core/src/renderer.ts#CliRenderer.getDebugInputs [status=implemented hash=16895391269b]
    func getDebugInputs() -> [DebugInputEntry] {
        CliRendererExtraStore.shared.state(for: self).debugInputs
    }

    /// Creates an incremental offscreen scrollback surface for `split-footer` + `capture-stdout` mode.
    // parity: core/src/renderer.ts#CliRenderer.createScrollbackSurface [status=adapted hash=75746783b8b3]
    func createScrollbackSurface(
        options: ScrollbackSurfaceOptions = ScrollbackSurfaceOptions()
    ) throws -> any ScrollbackSurface {
        guard !isDestroyed else {
            throw CliRendererOperationError.rendererDestroyed
        }
        guard screenMode == .splitFooter && externalOutputMode == .captureStdout else {
            throw CliRendererOperationError.requiresSplitFooterCapture(operation: "createScrollbackSurface")
        }
        return CliScrollbackSurface(owner: self, options: options)
    }

    /// Renders a renderable snapshot produced by `write` into scrollback output in split-footer capture mode.
    // parity: core/src/renderer.ts#CliRenderer.writeToScrollback [status=adapted hash=b7d2e06b4f5d]
    func writeToScrollback(_ write: ScrollbackWriter) throws {
        guard !isDestroyed else {
            throw CliRendererOperationError.rendererDestroyed
        }
        guard screenMode == .splitFooter && externalOutputMode == .captureStdout else {
            throw CliRendererOperationError.requiresSplitFooterCapture(operation: "writeToScrollback")
        }

        let extra = CliRendererExtraStore.shared.state(for: self)
        let ctx = ScrollbackRenderContext(
            width: width,
            widthMethod: widthMethod,
            tailColumn: extra.pendingSplitTailColumn,
            renderContext: self
        )
        let snapshot = write(ctx)
        defer { snapshot.teardown?() }

        let targetW = max(1, min(width, snapshot.width ?? (snapshot.root.width > 0 ? snapshot.root.width : width)))
        let snapshotRoot = RootRenderable(ctx: self)
        defer { snapshotRoot.destroyRecursively() }

        snapshotRoot.add(snapshot.root)
        FlexSolver.calculateLayout(
            root: snapshotRoot.layoutNode,
            availableWidth: Float(targetW),
            availableHeight: snapshot.height.map { Float(max(1, $0)) } ?? Float.nan,
            direction: .ltr
        )
        snapshotRoot.updateFromLayout()

        let resolvedH = max(1, snapshot.height ?? max(1, snapshot.root.height))
        let snapshotBuffer = OptimizedBuffer(
            width: targetW,
            height: resolvedH,
            widthMethod: widthMethod,
            id: "scrollback-snapshot-commit",
            graphemePool: graphemePool,
            linkPool: linkPool
        )
        snapshotBuffer.clear(bg: RGBA.fromValues(0, 0, 0, 0), char: defaultSpaceChar)
        snapshotRoot.render(buffer: snapshotBuffer, deltaTime: 0)

        let text = snapshotBuffer.getPlainText(trimTrailingSpaces: true)
        let startOnNewLine = snapshot.startOnNewLine ?? true
        let trailingNewline = snapshot.trailingNewline ?? true
        outputWriter?("\(startOnNewLine ? "\n" : "")\(text)\(trailingNewline ? "\n" : "")")

        let event = CliRendererExternalOutputEvent(
            snapshot: snapshotBuffer,
            rowColumns: snapshot.rowColumns ?? targetW,
            startOnNewLine: startOnNewLine,
            trailingNewline: trailingNewline
        )
        extra.committedScrollbackEvents.append(event)
        extra.pendingSplitTailColumn = trailingNewline ? 0 : (snapshot.rowColumns ?? targetW) % max(1, width)
    }

    /// Resets the terminal screen/scrollback region for split-footer replay.
    // parity: core/src/renderer.ts#CliRenderer.resetSplitFooterForReplay [status=implemented hash=d4f1950d3c3d]
    func resetSplitFooterForReplay(
        options: SplitFooterReplayResetOptions = SplitFooterReplayResetOptions()
    ) throws {
        guard !isDestroyed else { return }
        guard screenMode == .splitFooter && externalOutputMode == .captureStdout else {
            throw CliRendererOperationError.requiresSplitFooterCapture(operation: "resetSplitFooterForReplay")
        }
        let extra = CliRendererExtraStore.shared.state(for: self)
        guard extra.terminalIsSetup && controlState != .explicitSuspended else {
            throw CliRendererOperationError.requiresActiveTerminal(operation: "resetSplitFooterForReplay")
        }

        let seq = ANSI.resetScrollRegion
            + ANSI.reset
            + ANSI.home
            + ANSI.clearScreen
            + (options.clearSavedLines ? ANSI.clearSavedLines : "")
            + ANSI.home
        outputWriter?(seq)
        extra.pendingSplitTailColumn = 0
        extra.committedScrollbackEvents.removeAll()
        diffRenderer.invalidate()
        requestRender()
    }

    /// Performs idempotent terminal startup configuration (alternate screen, mouse, debug overlay timer).
    // parity: core/src/renderer.ts#CliRenderer.setupTerminal [status=adapted hash=0e7611955808]
    func setupTerminal() async {
        guard !isDestroyed else { return }
        let extra = CliRendererExtraStore.shared.state(for: self)
        if extra.terminalIsSetup { return }
        extra.terminalIsSetup = true

        if screenMode == .alternateScreen {
            outputWriter?(ANSI.switchToAlternateScreen)
        }
        if extra.debugOverlayEnabled {
            configureDebugOverlay()
            if extra.memorySnapshotInterval <= 0 {
                extra.automaticMemorySnapshot = true
                setMemorySnapshotInterval(3000)
            }
        }
    }

    /// Configures periodic memory snapshot sampling (in ms); values `<= 0` disable the timer.
    // parity: core/src/renderer.ts#CliRenderer.setMemorySnapshotInterval [status=implemented hash=d32bdc98adaf]
    func setMemorySnapshotInterval(_ intervalMs: Double) {
        let extra = CliRendererExtraStore.shared.state(for: self)
        extra.memorySnapshotInterval = intervalMs

        if let existing = extra.memorySnapshotTimer {
            clock.clearInterval(existing)
            extra.memorySnapshotTimer = nil
        }

        guard intervalMs > 0 && !isDestroyed else { return }
        let cellCount = width * height
        extra.memorySnapshotTimer = clock.setInterval({ [weak self] in
            guard let self, !self.isDestroyed else { return }
            let estimatedBufferBytes = cellCount * 24 * 2
            extra.lastMemorySnapshot = MemorySnapshot(
                heapUsed: estimatedBufferBytes,
                heapTotal: estimatedBufferBytes * 2,
                arrayBuffers: estimatedBufferBytes
            )
        }, delayMs: intervalMs)
    }

    /// Current debug overlay visibility and corner configuration.
    var debugOverlayConfig: (enabled: Bool, corner: DebugOverlayCorner) {
        let extra = CliRendererExtraStore.shared.state(for: self)
        return (extra.debugOverlayEnabled, extra.debugOverlayCorner)
    }

    /// Toggles the debug overlay on/off and manages the automatic memory snapshot timer.
    // parity: core/src/renderer.ts#CliRenderer.toggleDebugOverlay [status=implemented hash=d667ddc8d36f]
    func toggleDebugOverlay() {
        let extra = CliRendererExtraStore.shared.state(for: self)
        let willBeEnabled = !extra.debugOverlayEnabled
        configureDebugOverlay(enabled: willBeEnabled)

        if willBeEnabled && extra.memorySnapshotInterval <= 0 {
            extra.automaticMemorySnapshot = true
            setMemorySnapshotInterval(3000)
        } else if !willBeEnabled && extra.automaticMemorySnapshot {
            setMemorySnapshotInterval(0)
            extra.automaticMemorySnapshot = false
        }
    }

    /// Updates debug overlay visibility and corner placement, then schedules a render.
    // parity: core/src/renderer.ts#CliRenderer.configureDebugOverlay [status=implemented hash=41a5b6119c3b]
    func configureDebugOverlay(enabled: Bool? = nil, corner: DebugOverlayCorner? = nil) {
        let extra = CliRendererExtraStore.shared.state(for: self)
        if let enabled {
            extra.debugOverlayEnabled = enabled
        }
        if let corner {
            extra.debugOverlayCorner = corner
        }
        requestRender()
    }

    /// Sets the terminal window title via OSC 2 (`ESC ] 2 ; <title> BEL`).
    // parity: core/src/renderer.ts#CliRenderer.setTerminalTitle [status=implemented hash=4d173515bcda]
    func setTerminalTitle(_ title: String) {
        guard !isDestroyed else { return }
        let sanitized = String(title.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F })
        CliRendererExtraStore.shared.state(for: self).terminalTitle = sanitized
        outputWriter?("\u{1B}]2;\(sanitized)\u{07}")
    }

    /// Resets the terminal default background color via OSC 111 (`ESC ] 111 ; BEL`).
    // parity: core/src/renderer.ts#CliRenderer.resetTerminalBgColor [status=implemented hash=f3bb0eb98059]
    func resetTerminalBgColor() {
        guard !isDestroyed else { return }
        outputWriter?("\u{1B}]111;\u{07}")
    }

    private var effectiveClipboardPassthrough: ClipboardPassthrough {
        switch capabilities?.multiplexer {
        case .tmux: return .tmux
        case .screen: return .screen
        default: return .none
        }
    }

    /// Copies `text` to the terminal clipboard via OSC 52 if supported.
    // parity: core/src/renderer.ts#CliRenderer.copyToClipboardOSC52 [status=implemented hash=27edbcdc64a5]
    @discardableResult
    func copyToClipboardOSC52(_ text: String, target: ClipboardTarget = .clipboard) -> Bool {
        guard !isDestroyed && isOsc52Supported() else { return false }
        let seq = Osc52Clipboard.encodeCopy(text, target: target, passthrough: effectiveClipboardPassthrough)
        outputWriter?(seq)
        return true
    }

    /// Clears the terminal clipboard selection via OSC 52.
    // parity: core/src/renderer.ts#CliRenderer.clearClipboardOSC52 [status=implemented hash=64e1ab8de551]
    @discardableResult
    func clearClipboardOSC52(target: ClipboardTarget = .clipboard) -> Bool {
        guard !isDestroyed else { return false }
        let seq = Osc52Clipboard.encodeClear(target: target, passthrough: effectiveClipboardPassthrough)
        outputWriter?(seq)
        return true
    }

    /// Reports whether OSC 52 clipboard emission is permitted by the detected terminal capabilities.
    // parity: core/src/renderer.ts#CliRenderer.isOsc52Supported [status=implemented hash=b9599129c76d]
    func isOsc52Supported() -> Bool {
        capabilities?.osc52Support != .unsupported
    }

    /// Formats the current hit-test grid for diagnostics and logs it to `console`.
    // parity: core/src/renderer.ts#CliRenderer.dumpHitGrid [status=implemented hash=9f14fa30da0d]
    @discardableResult
    func dumpHitGrid() -> String {
        var rows: [String] = []
        rows.reserveCapacity(height)
        for y in 0..<height {
            var cols: [String] = []
            cols.reserveCapacity(width)
            let rowStart = y * width
            for x in 0..<width {
                let idx = rowStart + x
                let id = idx < hitGrid.count ? hitGrid[idx] : 0
                cols.append(id == 0 ? "." : "\(id)")
            }
            rows.append(cols.joined(separator: " "))
        }
        let dump = rows.joined(separator: "\n")
        console.debug(dump)
        return dump
    }

    /// Registers an identity-tracked frame callback executed on every rendered frame.
    // parity: core/src/renderer.ts#CliRenderer.setFrameCallback [status=adapted hash=cec17e92fdcd]
    func setFrameCallback(_ handle: FrameCallbackHandle) {
        let extra = CliRendererExtraStore.shared.state(for: self)
        if !extra.trackedFrameCallbacks.contains(handle) {
            extra.trackedFrameCallbacks.append(handle)
        }
        if !extra.trackedCallbackBridgeInstalled {
            extra.trackedCallbackBridgeInstalled = true
            setFrameCallback { [weak self] deltaTime in
                guard let self else { return }
                let state = CliRendererExtraStore.shared.state(for: self)
                let start = self.clock.now()
                let snapshot = state.trackedFrameCallbacks
                for item in snapshot {
                    if self.isDestroyed { break }
                    item.callback(deltaTime)
                }
                state.lastSceneTimeMs = max(0, self.clock.now() - start)
            }
        }
    }

    /// Reports whether `handle` is currently registered as a tracked frame callback.
    // parity: core/src/renderer.ts#CliRenderer.hasFrameCallback [status=implemented hash=a95fa4c9a5ac]
    func hasFrameCallback(_ handle: FrameCallbackHandle) -> Bool {
        CliRendererExtraStore.shared.state(for: self).trackedFrameCallbacks.contains(handle)
    }

    /// Removes `handle` from the tracked frame callbacks list.
    // parity: core/src/renderer.ts#CliRenderer.removeFrameCallback [status=implemented hash=45694abf2a2d]
    func removeFrameCallback(_ handle: FrameCallbackHandle) {
        CliRendererExtraStore.shared.state(for: self).trackedFrameCallbacks.removeAll { $0 == handle }
    }

    /// Clears all tracked and untracked frame callbacks registered on this renderer.
    // parity: core/src/renderer.ts#CliRenderer.clearFrameCallbacks [status=implemented hash=fe4ee46a8e32]
    func clearAllFrameCallbacks() {
        let extra = CliRendererExtraStore.shared.state(for: self)
        extra.trackedFrameCallbacks.removeAll()
        extra.trackedCallbackBridgeInstalled = false
        clearFrameCallbacks()
    }

    /// Returns low-level frame and buffer memory statistics from `diffRenderer`.
    // parity: core/src/renderer.ts#CliRenderer.getNativeStats [status=adapted hash=066c89436789]
    func getNativeStats() -> NativeRenderStats {
        let diffStats = diffRenderer.stats
        let cellCount = currentRenderBuffer.width * currentRenderBuffer.height
        let bytesPerBuffer = cellCount * 24
        return NativeRenderStats(
            frameCount: diffStats.frameCount,
            cellsUpdated: diffStats.cellsUpdated,
            rowsCompared: diffStats.rowsCompared,
            rowsDiffed: diffStats.rowsDiffed,
            bytesEmitted: diffStats.bytesEmitted,
            memoryUsed: bytesPerBuffer * 2,
            memoryAllocated: bytesPerBuffer * 2,
            memoryBuffers: 2
        )
    }

    /// Enables or disables frame-time statistics gathering (clearing samples when disabled).
    // parity: core/src/renderer.ts#CliRenderer.setGatherStats [status=implemented hash=5f7c0e69c19c]
    func setGatherStats(_ enabled: Bool) {
        let extra = CliRendererExtraStore.shared.state(for: self)
        extra.gatherStats = enabled
        if !enabled {
            resetStats()
        }
    }

    /// Reports whether statistics gathering was enabled via `setGatherStats(_:)`.
    var isGatheringStats: Bool {
        CliRendererExtraStore.shared.state(for: self).gatherStats
    }

    /// Updates the tracked terminal palette detection status.
    func setPaletteDetectionStatus(_ status: PaletteDetectionStatus) {
        CliRendererExtraStore.shared.state(for: self).paletteStatus = status
    }

    /// Current terminal palette detection lifecycle status (`.idle`, `.detecting`, or `.cached`).
    // parity: core/src/renderer.ts#CliRenderer.paletteDetectionStatus [status=implemented hash=8f7e5ef7cde7]
    var paletteDetectionStatus: PaletteDetectionStatus {
        CliRendererExtraStore.shared.state(for: self).paletteStatus
    }
}
