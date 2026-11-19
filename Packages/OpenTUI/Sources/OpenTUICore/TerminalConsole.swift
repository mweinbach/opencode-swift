/// Pure-Swift terminal debug console overlay with ring-buffered log storage,
/// keybinding & mouse selection handling, grapheme-safe wrapping, and `OptimizedBuffer` rendering,
/// matching `packages/core/src/console.ts`.

// MARK: - Console Capture

/// Captured output stream channel.
public enum ConsoleCaptureStream: String, Equatable, Hashable, Sendable, Codable {
    case stdout
    case stderr
}

/// Pure-Swift ring-buffered stdout/stderr capture store mirroring `packages/core/src/lib/output.capture.ts`.
public final class ConsoleCapture: @unchecked Sendable {
    public struct Chunk: Equatable, Hashable, Sendable {
        public let stream: ConsoleCaptureStream
        public let data: String

        public init(stream: ConsoleCaptureStream, data: String) {
            self.stream = stream
            self.data = data
        }
    }

    private var chunks: [Chunk] = []
    public let maxChunks: Int

    public init(maxChunks: Int = 2000) {
        self.maxChunks = max(1, maxChunks)
    }

    public var size: Int {
        chunks.count
    }

    public func write(stream: ConsoleCaptureStream, data: String) {
        if chunks.count >= maxChunks {
            chunks.removeFirst(chunks.count - maxChunks + 1)
        }
        chunks.append(Chunk(stream: stream, data: data))
    }

    public func read(stream: ConsoleCaptureStream? = nil) -> [Chunk] {
        guard let stream else { return chunks }
        return chunks.filter { $0.stream == stream }
    }

    public func readString(stream: ConsoleCaptureStream? = nil) -> String {
        read(stream: stream).map(\.data).joined()
    }

    public func clear() {
        chunks.removeAll()
    }
}

// parity: core/src/console.ts#capture [status=implemented hash=0e39db961338]
public let consoleCapture = ConsoleCapture()

// MARK: - Console Types & Options

// parity: core/src/console.ts#ConsolePosition [status=implemented hash=2934d81335ac]
public enum ConsolePosition: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
    case top
    case bottom
    case left
    case right
}

/// Log severity levels supported by `TerminalConsole`.
public enum ConsoleLogLevel: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
    case log = "LOG"
    case info = "INFO"
    case warn = "WARN"
    case error = "ERROR"
    case debug = "DEBUG"
}

/// Optional source-location metadata attached to log entries in debug mode.
public struct ConsoleCallerInfo: Equatable, Hashable, Sendable, Codable {
    public let functionName: String
    public let fullPath: String
    public let fileName: String
    public let lineNumber: Int
    public let columnNumber: Int

    public init(
        functionName: String = "<anonymous>",
        fullPath: String = "",
        fileName: String,
        lineNumber: Int,
        columnNumber: Int = 0
    ) {
        self.functionName = functionName
        self.fullPath = fullPath
        self.fileName = fileName
        self.lineNumber = lineNumber
        self.columnNumber = columnNumber
    }
}

/// A single structured log record stored in `ConsoleCache` / `TerminalConsole`.
public struct ConsoleLogEntry: Equatable, Hashable, Sendable, Codable {
    public let timestamp: String
    public let level: ConsoleLogLevel
    public let message: String
    public let callerInfo: ConsoleCallerInfo?

    public init(
        timestamp: String = "00:00:00",
        level: ConsoleLogLevel,
        message: String,
        callerInfo: ConsoleCallerInfo? = nil
    ) {
        self.timestamp = timestamp
        self.level = level
        self.message = message
        self.callerInfo = callerInfo
    }
}

/// A single wrapped display row rendered inside the console viewport.
public struct ConsoleDisplayLine: Equatable, Hashable, Sendable {
    public let text: String
    public let level: ConsoleLogLevel
    public let indent: Bool

    public init(text: String, level: ConsoleLogLevel, indent: Bool) {
        self.text = text
        self.level = level
        self.indent = indent
    }
}

/// Screen-space rectangle of the console overlay panel.
public struct ConsoleBounds: Equatable, Hashable, Sendable, Codable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// Normalized text selection in display-line coordinates.
public struct ConsoleSelection: Equatable, Hashable, Sendable {
    public let startLine: Int
    public let startCol: Int
    public let endLine: Int
    public let endCol: Int

    public init(startLine: Int, startCol: Int, endLine: Int, endCol: Int) {
        self.startLine = startLine
        self.startCol = startCol
        self.endLine = endLine
        self.endCol = endCol
    }
}

// parity: core/src/console.ts#ConsoleAction [status=implemented hash=1ca11ae5b350]
public enum ConsoleAction: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
    case scrollUp = "scroll-up"
    case scrollDown = "scroll-down"
    case scrollPageUp = "scroll-page-up"
    case scrollPageDown = "scroll-page-down"
    case scrollToTop = "scroll-to-top"
    case scrollToBottom = "scroll-to-bottom"
    case positionPrevious = "position-previous"
    case positionNext = "position-next"
    case sizeIncrease = "size-increase"
    case sizeDecrease = "size-decrease"
    case saveLogs = "save-logs"
    case copySelection = "copy-selection"
    case clear = "clear"
}

// parity: core/src/console.ts#ConsoleKeyBinding [status=implemented hash=23cfb60f2e98]
public struct ConsoleKeyBinding: Equatable, Hashable, Sendable, Codable {
    public var name: String
    public var ctrl: Bool
    public var shift: Bool
    public var meta: Bool
    public var `super`: Bool
    public var action: ConsoleAction

    public init(
        name: String,
        ctrl: Bool = false,
        shift: Bool = false,
        meta: Bool = false,
        `super`: Bool = false,
        action: ConsoleAction
    ) {
        self.name = name
        self.ctrl = ctrl
        self.shift = shift
        self.meta = meta
        self.`super` = `super`
        self.action = action
    }

    public var displayString: String {
        var parts: [String] = []
        if ctrl { parts.append("ctrl") }
        if shift { parts.append("shift") }
        if meta { parts.append("meta") }
        if `super` { parts.append("super") }
        parts.append(name)
        return parts.joined(separator: "+")
    }
}

// parity: core/src/console.ts#ConsoleOptions [status=implemented hash=01fa230e70f4]
public struct ConsoleOptions {
    public var position: ConsolePosition
    public var sizePercent: Int
    public var zIndex: Int
    public var colorInfo: RGBA
    public var colorWarn: RGBA
    public var colorError: RGBA
    public var colorDebug: RGBA
    public var colorDefault: RGBA
    public var backgroundColor: RGBA
    public var borderColor: RGBA
    public var showBorder: Bool
    public var startInDebugMode: Bool
    public var title: String
    public var titleBarColor: RGBA
    public var titleBarTextColor: RGBA
    public var cursorColor: RGBA
    public var maxStoredLogs: Int
    public var maxDisplayLines: Int
    public var onCopySelection: ((String) -> Void)?
    public var keyBindings: [ConsoleKeyBinding]
    public var keyAliasMap: [String: String]
    public var selectionColor: RGBA
    public var copyButtonColor: RGBA
    public var widthMethod: WidthMethod
    public var timestampProvider: (() -> String)?

    public init(
        position: ConsolePosition = .bottom,
        sizePercent: Int = 30,
        zIndex: Int = Int.max,
        colorInfo: RGBA = parseColor("#00FFFF"),
        colorWarn: RGBA = parseColor("#FFFF00"),
        colorError: RGBA = parseColor("#FF0000"),
        colorDebug: RGBA = parseColor("#808080"),
        colorDefault: RGBA = parseColor("#FFFFFF"),
        backgroundColor: RGBA = RGBA.fromValues(0.1, 0.1, 0.1, 0.7),
        borderColor: RGBA = RGBA.fromValues(0.45, 0.45, 0.45, 1.0),
        showBorder: Bool = true,
        startInDebugMode: Bool = false,
        title: String = "Console",
        titleBarColor: RGBA = RGBA.fromValues(0.05, 0.05, 0.05, 0.7),
        titleBarTextColor: RGBA = parseColor("#FFFFFF"),
        cursorColor: RGBA = parseColor("#00A0FF"),
        maxStoredLogs: Int = 2000,
        maxDisplayLines: Int = 3000,
        onCopySelection: ((String) -> Void)? = nil,
        keyBindings: [ConsoleKeyBinding] = [],
        keyAliasMap: [String: String] = [:],
        selectionColor: RGBA = RGBA.fromValues(0.3, 0.5, 0.8, 0.5),
        copyButtonColor: RGBA = parseColor("#00A0FF"),
        widthMethod: WidthMethod = .unicode,
        timestampProvider: (() -> String)? = nil
    ) {
        self.position = position
        self.sizePercent = max(10, min(100, sizePercent))
        self.zIndex = zIndex
        self.colorInfo = colorInfo
        self.colorWarn = colorWarn
        self.colorError = colorError
        self.colorDebug = colorDebug
        self.colorDefault = colorDefault
        self.backgroundColor = backgroundColor
        self.borderColor = borderColor
        self.showBorder = showBorder
        self.startInDebugMode = startInDebugMode
        self.title = title
        self.titleBarColor = titleBarColor
        self.titleBarTextColor = titleBarTextColor
        self.cursorColor = cursorColor
        self.maxStoredLogs = max(1, maxStoredLogs)
        self.maxDisplayLines = max(1, maxDisplayLines)
        self.onCopySelection = onCopySelection
        self.keyBindings = keyBindings
        self.keyAliasMap = keyAliasMap
        self.selectionColor = selectionColor
        self.copyButtonColor = copyButtonColor
        self.widthMethod = widthMethod
        self.timestampProvider = timestampProvider
    }
}

// MARK: - Default Keybindings & Aliases

public let defaultConsoleKeyBindings: [ConsoleKeyBinding] = [
    ConsoleKeyBinding(name: "up", action: .scrollUp),
    ConsoleKeyBinding(name: "down", action: .scrollDown),
    ConsoleKeyBinding(name: "pageup", action: .scrollPageUp),
    ConsoleKeyBinding(name: "pagedown", action: .scrollPageDown),
    ConsoleKeyBinding(name: "home", action: .scrollToTop),
    ConsoleKeyBinding(name: "end", action: .scrollToBottom),
    ConsoleKeyBinding(name: "up", shift: true, action: .scrollToTop),
    ConsoleKeyBinding(name: "down", shift: true, action: .scrollToBottom),
    ConsoleKeyBinding(name: "p", ctrl: true, action: .positionPrevious),
    ConsoleKeyBinding(name: "o", ctrl: true, action: .positionNext),
    ConsoleKeyBinding(name: "+", action: .sizeIncrease),
    ConsoleKeyBinding(name: "=", shift: true, action: .sizeIncrease),
    ConsoleKeyBinding(name: "-", action: .sizeDecrease),
    ConsoleKeyBinding(name: "s", ctrl: true, action: .saveLogs),
    ConsoleKeyBinding(name: "c", ctrl: true, shift: true, action: .copySelection),
    ConsoleKeyBinding(name: "l", ctrl: true, action: .clear),
]

private let defaultConsoleKeyAliases: [String: String] = [
    "enter": "return",
    "esc": "escape",
    "kp0": "0",
    "kp1": "1",
    "kp2": "2",
    "kp3": "3",
    "kp4": "4",
    "kp5": "5",
    "kp6": "6",
    "kp7": "7",
    "kp8": "8",
    "kp9": "9",
    "kpdecimal": ".",
    "kpdivide": "/",
    "kpmultiply": "*",
    "kpminus": "-",
    "kpplus": "+",
    "kpenter": "enter",
    "kpequal": "=",
    "kpseparator": ",",
    "kpleft": "left",
    "kpright": "right",
    "kpup": "up",
    "kpdown": "down",
    "kppageup": "pageup",
    "kppagedown": "pagedown",
    "kphome": "home",
    "kpend": "end",
    "kpinsert": "insert",
    "kpdelete": "delete",
]

// MARK: - ConsoleCache

/// Opaque listener handle returned by `ConsoleCache.addEntryListener(_:)`.
public struct ConsoleCacheListenerToken: Equatable, Hashable, Sendable {
    fileprivate let id: UInt64
}

/// Ring-buffered log entry cache shared by one or more `TerminalConsole` instances.
public final class ConsoleCache: @unchecked Sendable {
    private struct ListenerEntry {
        let id: UInt64
        let handler: (ConsoleLogEntry) -> Void
    }

    public let maxCacheSize: Int
    private var _cachedLogs: [ConsoleLogEntry] = []
    private var _collectCallerInfo: Bool = false
    private var _cachingEnabled: Bool = true
    private var _isActive: Bool = false
    private var nextListenerId: UInt64 = 1
    private var listeners: [ListenerEntry] = []

    public init(maxCacheSize: Int = 1000) {
        self.maxCacheSize = max(1, maxCacheSize)
    }

    public var cachedLogs: [ConsoleLogEntry] {
        _cachedLogs
    }

    public var isActive: Bool {
        _isActive
    }

    public var isCachingEnabled: Bool {
        _cachingEnabled
    }

    public var collectCallerInfo: Bool {
        _collectCallerInfo
    }

    public func activate() {
        _isActive = true
    }

    public func deactivate() {
        _isActive = false
    }

    public func setCollectCallerInfo(_ enabled: Bool) {
        _collectCallerInfo = enabled
    }

    public func setCachingEnabled(_ enabled: Bool) {
        _cachingEnabled = enabled
    }

    public func clearConsole() {
        _cachedLogs.removeAll()
    }

    @discardableResult
    public func addEntryListener(_ handler: @escaping (ConsoleLogEntry) -> Void) -> ConsoleCacheListenerToken {
        let id = nextListenerId
        nextListenerId &+= 1
        listeners.append(ListenerEntry(id: id, handler: handler))
        return ConsoleCacheListenerToken(id: id)
    }

    public func removeEntryListener(_ token: ConsoleCacheListenerToken) {
        listeners.removeAll { $0.id == token.id }
    }

    @discardableResult
    public func addLogEntry(
        level: ConsoleLogLevel,
        message: String,
        timestamp: String = "00:00:00",
        callerInfo: ConsoleCallerInfo? = nil
    ) -> ConsoleLogEntry {
        let resolvedCaller = _collectCallerInfo ? callerInfo : nil
        let entry = ConsoleLogEntry(
            timestamp: timestamp,
            level: level,
            message: message,
            callerInfo: resolvedCaller
        )

        if _cachingEnabled {
            if _cachedLogs.count >= maxCacheSize {
                _cachedLogs.removeFirst(_cachedLogs.count - maxCacheSize + 1)
            }
            _cachedLogs.append(entry)
        }

        return entry
    }

    @discardableResult
    public func appendToConsole(
        level: ConsoleLogLevel,
        message: String,
        timestamp: String = "00:00:00",
        callerInfo: ConsoleCallerInfo? = nil
    ) -> ConsoleLogEntry {
        let entry = addLogEntry(level: level, message: message, timestamp: timestamp, callerInfo: callerInfo)
        let snapshot = listeners
        for listener in snapshot {
            listener.handler(entry)
        }
        return entry
    }

    public func getCachedLogsAsString() -> String {
        _cachedLogs.map { entry in
            "\(entry.timestamp) \(entry.level.rawValue) \(entry.message)"
        }.joined(separator: "\n")
    }

    public func destroy() {
        deactivate()
        listeners.removeAll()
    }
}

// MARK: - Formatting & Wrapping Helpers

private let consoleIndentWidth = 2

private let consoleHexDigits: [UInt8] = Array("0123456789abcdef".utf8)

private func sanitizeConsoleMessage(_ text: String) -> String {
    var result = ""
    result.reserveCapacity(text.utf8.count)
    var scalars = text.unicodeScalars.makeIterator()
    var pendingCR = false

    func appendEscaped(_ value: UInt32) {
        let hi = Int((value >> 4) & 0xF)
        let lo = Int(value & 0xF)
        result.append("\\x")
        result.append(Character(Unicode.Scalar(consoleHexDigits[hi])))
        result.append(Character(Unicode.Scalar(consoleHexDigits[lo])))
    }

    while let scalar = scalars.next() {
        let v = scalar.value
        if pendingCR {
            if v == 0x0A {
                result.append("\n")
                pendingCR = false
                continue
            } else {
                appendEscaped(0x0D)
                pendingCR = false
            }
        }
        if v == 0x0D {
            pendingCR = true
            continue
        }
        if v == 0x0A {
            result.append("\n")
        } else if (v <= 0x08) || (v >= 0x0B && v <= 0x1F) || (v >= 0x7F && v <= 0x9F) {
            appendEscaped(v)
        } else {
            result.unicodeScalars.append(scalar)
        }
    }

    if pendingCR {
        appendEscaped(0x0D)
    }

    return result
}

/// Splits `text` at grapheme boundaries into segments of at most `firstCells` display cells,
/// then `restCells` display cells, matching `console.ts#wrapDisplayCells`.
internal func wrapConsoleDisplayCells(
    _ text: String,
    firstCells: Int,
    restCells: Int,
    widthMethod: WidthMethod = .unicode
) -> [String] {
    let firstBudget = max(1, firstCells)
    let restBudget = max(1, restCells)
    var segments: [String] = []
    var segment = ""
    var cells = 0

    for ch in text {
        let chStr = String(ch)
        let width = Int(calculateTextWidth(chStr, tabWidth: 2, controlDisplay: .hidden, widthMethod: widthMethod))
        let budget = segments.isEmpty ? firstBudget : restBudget
        if !segment.isEmpty && cells + width > budget {
            segments.append(segment)
            segment = ""
            cells = 0
        }
        segment.append(ch)
        cells += width
    }

    if !segment.isEmpty {
        segments.append(segment)
    }

    return segments
}

private func consoleBindingKey(name: String, ctrl: Bool, shift: Bool, meta: Bool, superKey: Bool) -> String {
    "\(name):\(ctrl ? 1 : 0):\(shift ? 1 : 0):\(meta ? 1 : 0):\(superKey ? 1 : 0)"
}

private func consoleBaseCodeKeyName(name: String, baseCode: UInt32?) -> String? {
    guard let baseCode, baseCode > 32, baseCode != 127 else { return nil }
    let isSingleNonAscii = name.unicodeScalars.count == 1 && (name.unicodeScalars.first?.value ?? 0) > 0x7F
    if !isSingleNonAscii && (baseCode < 48 || baseCode > 57) {
        return nil
    }
    guard let scalar = Unicode.Scalar(baseCode) else { return nil }
    if baseCode >= 0x41 && baseCode <= 0x5A {
        return String(Unicode.Scalar(baseCode + 0x20)!)
    }
    return String(scalar)
}

// MARK: - TerminalConsole

// parity: core/src/console.ts#TerminalConsole [status=implemented hash=0676372a0af8]
public final class TerminalConsole: @unchecked Sendable {
    private var _isVisible: Bool = false
    private var _isFocused: Bool = false
    private var _isDestroyed: Bool = false
    private var _debugModeEnabled: Bool = false

    private var options: ConsoleOptions
    private let cache: ConsoleCache
    private var cacheListenerToken: ConsoleCacheListenerToken?

    private var terminalWidth: Int
    private var terminalHeight: Int
    private var consoleX: Int = 0
    private var consoleY: Int = 0
    private var consoleWidth: Int = 0
    private var consoleHeight: Int = 0

    private var scrollTopIndex: Int = 0
    private var isScrolledToBottom: Bool = true
    private var currentLineIndex: Int = 0

    private var _displayLines: [ConsoleDisplayLine] = []
    private var _allLogEntries: [ConsoleLogEntry] = []
    private var _needsFrameBufferUpdate: Bool = true
    private var frameBuffer: OptimizedBuffer?

    private var _selectionStart: (line: Int, col: Int)? = nil
    private var _selectionEnd: (line: Int, col: Int)? = nil
    private var _isDragging: Bool = false
    private var _copyButtonBounds: ConsoleBounds = ConsoleBounds(x: -1, y: -1, width: 0, height: 0)

    private var _keyBindings: [ConsoleKeyBinding] = []
    private var _mergedKeyBindings: [ConsoleKeyBinding] = []
    private var _keyAliasMap: [String: String] = [:]
    private var _keyBindingsMap: [String: ConsoleAction] = [:]

    private let onRequestRender: (() -> Void)?
    private let onSaveLogs: ((String) -> Void)?

    private static let positionCycle: [ConsolePosition] = [.top, .right, .bottom, .left]

    public init(
        width: Int = 80,
        height: Int = 24,
        options: ConsoleOptions = ConsoleOptions(),
        cache: ConsoleCache? = nil,
        onRequestRender: (() -> Void)? = nil,
        onSaveLogs: ((String) -> Void)? = nil
    ) {
        self.terminalWidth = max(1, width)
        self.terminalHeight = max(1, height)
        self.options = options
        self.cache = cache ?? ConsoleCache(maxCacheSize: options.maxStoredLogs)
        self.onRequestRender = onRequestRender
        self.onSaveLogs = onSaveLogs
        self._debugModeEnabled = options.startInDebugMode
        self.cache.setCollectCallerInfo(self._debugModeEnabled)

        self._keyBindings = options.keyBindings
        self._keyAliasMap = Self.mergeAliases(defaultConsoleKeyAliases, options.keyAliasMap)
        self._mergedKeyBindings = Self.mergeBindings(defaultConsoleKeyBindings, self._keyBindings)
        self._keyBindingsMap = Self.buildBindingsMap(self._mergedKeyBindings, aliases: self._keyAliasMap)

        updateConsoleDimensions(termWidth: self.terminalWidth, termHeight: self.terminalHeight)
        scrollToBottomInternal(forceCursorToLastLine: true)

        self.cacheListenerToken = self.cache.addEntryListener { [weak self] entry in
            self?.handleNewLogEntry(entry)
        }
    }

    // MARK: - Inspectable State

    // parity: core/src/console.ts#TerminalConsole.visible [status=implemented hash=98cee99745b1]
    public var visible: Bool {
        _isVisible
    }

    public var isFocused: Bool {
        _isFocused
    }

    public var isActive: Bool {
        cache.isActive
    }

    public var isDebugModeEnabled: Bool {
        _debugModeEnabled
    }

    public var position: ConsolePosition {
        options.position
    }

    public var sizePercent: Int {
        options.sizePercent
    }

    public var scrollOffset: Int {
        scrollTopIndex
    }

    public var cursorLineIndex: Int {
        currentLineIndex
    }

    public var entries: [ConsoleLogEntry] {
        _allLogEntries
    }

    public var displayLines: [ConsoleDisplayLine] {
        _displayLines
    }

    public var logCount: Int {
        _allLogEntries.count + cache.cachedLogs.count
    }

    // parity: core/src/console.ts#TerminalConsole.bounds [status=implemented hash=00de73881129]
    public var bounds: ConsoleBounds {
        ConsoleBounds(x: consoleX, y: consoleY, width: consoleWidth, height: consoleHeight)
    }

    // parity: core/src/console.ts#TerminalConsole.keyBindings [status=implemented hash=798d959b0fe5]
    public var keyBindings: [ConsoleKeyBinding] {
        get { _keyBindings }
        set {
            _keyBindings = newValue
            _mergedKeyBindings = Self.mergeBindings(defaultConsoleKeyBindings, newValue)
            _keyBindingsMap = Self.buildBindingsMap(_mergedKeyBindings, aliases: _keyAliasMap)
            markNeedsRerender()
        }
    }

    // parity: core/src/console.ts#TerminalConsole.keyAliasMap [status=implemented hash=aa5f3d69a2bf]
    public var keyAliasMap: [String: String] {
        get { _keyAliasMap }
        set {
            _keyAliasMap = Self.mergeAliases(defaultConsoleKeyAliases, newValue)
            _mergedKeyBindings = Self.mergeBindings(defaultConsoleKeyBindings, _keyBindings)
            _keyBindingsMap = Self.buildBindingsMap(_mergedKeyBindings, aliases: _keyAliasMap)
            markNeedsRerender()
        }
    }

    // parity: core/src/console.ts#TerminalConsole.onCopySelection [status=implemented hash=09ab49a94b7e]
    public var onCopySelection: ((String) -> Void)? {
        get { options.onCopySelection }
        set { options.onCopySelection = newValue }
    }

    // MARK: - Logging API

    @discardableResult
    public func append(
        level: ConsoleLogLevel,
        message: String,
        timestamp: String? = nil,
        callerInfo: ConsoleCallerInfo? = nil
    ) -> ConsoleLogEntry {
        let ts = timestamp ?? options.timestampProvider?() ?? "00:00:00"
        return cache.appendToConsole(level: level, message: message, timestamp: ts, callerInfo: callerInfo)
    }

    @discardableResult
    public func log(_ message: String, callerInfo: ConsoleCallerInfo? = nil) -> ConsoleLogEntry {
        append(level: .log, message: message, callerInfo: callerInfo)
    }

    @discardableResult
    public func info(_ message: String, callerInfo: ConsoleCallerInfo? = nil) -> ConsoleLogEntry {
        append(level: .info, message: message, callerInfo: callerInfo)
    }

    @discardableResult
    public func warn(_ message: String, callerInfo: ConsoleCallerInfo? = nil) -> ConsoleLogEntry {
        append(level: .warn, message: message, callerInfo: callerInfo)
    }

    @discardableResult
    public func error(_ message: String, callerInfo: ConsoleCallerInfo? = nil) -> ConsoleLogEntry {
        append(level: .error, message: message, callerInfo: callerInfo)
    }

    @discardableResult
    public func debug(_ message: String, callerInfo: ConsoleCallerInfo? = nil) -> ConsoleLogEntry {
        append(level: .debug, message: message, callerInfo: callerInfo)
    }

    // MARK: - Lifecycle & Visibility

    // parity: core/src/console.ts#TerminalConsole.activate [status=implemented hash=29fe0f927729]
    public func activate() {
        cache.activate()
    }

    // parity: core/src/console.ts#TerminalConsole.deactivate [status=implemented hash=3a1b30e05eff]
    public func deactivate() {
        cache.deactivate()
    }

    // parity: core/src/console.ts#TerminalConsole.show [status=implemented hash=62a1651cee88]
    public func show() {
        guard !_isDestroyed else { return }
        guard !_isVisible else { return }

        if frameBuffer == nil && consoleWidth > 0 && consoleHeight > 0 {
            frameBuffer = OptimizedBuffer(
                width: consoleWidth,
                height: consoleHeight,
                widthMethod: options.widthMethod,
                respectAlpha: options.backgroundColor.a < 1.0,
                id: "console framebuffer"
            )
        }

        _isVisible = true
        processCachedLogs()
        cache.setCachingEnabled(false)

        let visibleLogLines = min(logAreaHeight, _displayLines.count)
        currentLineIndex = max(0, visibleLogLines - 1)
        scrollTopIndex = 0
        scrollToBottomInternal(forceCursorToLastLine: true)

        focus()
        markNeedsRerender()
    }

    // parity: core/src/console.ts#TerminalConsole.hide [status=implemented hash=5945cc1ac84e]
    public func hide() {
        guard _isVisible else { return }
        _isVisible = false
        blur()
        cache.setCachingEnabled(true)
    }

    // parity: core/src/console.ts#TerminalConsole.toggle [status=implemented hash=ab8599c44108]
    public func toggle() {
        if _isVisible {
            if _isFocused {
                hide()
            } else {
                focus()
            }
        } else {
            show()
        }
        onRequestRender?()
    }

    // parity: core/src/console.ts#TerminalConsole.focus [status=implemented hash=9f82f69abdd3]
    public func focus() {
        _isFocused = true
        scrollToBottomInternal(forceCursorToLastLine: true)
        markNeedsRerender()
    }

    // parity: core/src/console.ts#TerminalConsole.blur [status=implemented hash=ed4fa76f5230]
    public func blur() {
        _isFocused = false
        markNeedsRerender()
    }

    // parity: core/src/console.ts#TerminalConsole.clear [status=implemented hash=4899c6b5fae5]
    public func clear() {
        cache.clearConsole()
        _allLogEntries.removeAll()
        _displayLines.removeAll()
        scrollTopIndex = 0
        currentLineIndex = 0
        isScrolledToBottom = true
        clearSelection()
        markNeedsRerender()
    }

    // parity: core/src/console.ts#TerminalConsole.destroy [status=implemented hash=60adcf1b5474]
    public func destroy() {
        guard !_isDestroyed else { return }
        _isDestroyed = true
        hide()
        deactivate()
        if let token = cacheListenerToken {
            cache.removeEntryListener(token)
            cacheListenerToken = nil
        }
        frameBuffer?.destroy()
        frameBuffer = nil
    }

    // parity: core/src/console.ts#TerminalConsole.setDebugMode [status=implemented hash=78a016cfb645]
    public func setDebugMode(_ enabled: Bool) {
        _debugModeEnabled = enabled
        cache.setCollectCallerInfo(enabled)
        if _isVisible {
            rebuildDisplayLines()
            markNeedsRerender()
        }
    }

    // parity: core/src/console.ts#TerminalConsole.toggleDebugMode [status=implemented hash=605d42e54d1c]
    public func toggleDebugMode() {
        setDebugMode(!_debugModeEnabled)
    }

    // MARK: - Positioning & Resizing

    public func setPosition(_ position: ConsolePosition) {
        options.position = position
        resize(width: terminalWidth, height: terminalHeight)
    }

    public func setSizePercent(_ percent: Int) {
        options.sizePercent = max(10, min(100, percent))
        resize(width: terminalWidth, height: terminalHeight)
    }

    // parity: core/src/console.ts#TerminalConsole.resize [status=implemented hash=87959e356999]
    public func resize(width: Int, height: Int) {
        terminalWidth = max(1, width)
        terminalHeight = max(1, height)
        updateConsoleDimensions(termWidth: terminalWidth, termHeight: terminalHeight)

        if let fb = frameBuffer, consoleWidth > 0, consoleHeight > 0 {
            try? fb.resize(width: consoleWidth, height: consoleHeight)
        }

        if !_allLogEntries.isEmpty {
            rebuildDisplayLines()
        }

        let displayLineCount = _displayLines.count
        let maxScrollTop = max(0, displayLineCount - logAreaHeight)
        scrollTopIndex = min(scrollTopIndex, maxScrollTop)
        isScrolledToBottom = (scrollTopIndex == maxScrollTop)
        let visibleLineCount = min(logAreaHeight, max(0, displayLineCount - scrollTopIndex))
        currentLineIndex = max(0, min(currentLineIndex, max(0, visibleLineCount - 1)))

        if _isVisible {
            markNeedsRerender()
        }
    }

    // MARK: - Scrolling

    /// Scrolls the log viewport by `delta` lines (negative = up toward older entries, positive = down).
    public func scroll(delta: Int) {
        guard delta != 0 else { return }
        let displayLineCount = _displayLines.count
        let maxScrollTop = max(0, displayLineCount - logAreaHeight)
        let nextScrollTop = max(0, min(maxScrollTop, scrollTopIndex + delta))
        scrollTopIndex = nextScrollTop
        isScrolledToBottom = (scrollTopIndex == maxScrollTop)
        let visibleLineCount = min(logAreaHeight, max(0, displayLineCount - scrollTopIndex))
        currentLineIndex = max(0, min(currentLineIndex, max(0, visibleLineCount - 1)))
        markNeedsRerender()
    }

    @discardableResult
    public func scrollUp() -> Bool {
        if currentLineIndex > 0 {
            currentLineIndex -= 1
            markNeedsRerender()
        } else if scrollTopIndex > 0 {
            scrollTopIndex -= 1
            isScrolledToBottom = false
            markNeedsRerender()
        }
        return true
    }

    @discardableResult
    public func scrollDown() -> Bool {
        let displayLineCount = _displayLines.count
        let areaHeight = logAreaHeight
        let maxScrollTop = max(0, displayLineCount - areaHeight)
        let canCursorMoveDown =
            currentLineIndex < areaHeight - 1 && scrollTopIndex + currentLineIndex < displayLineCount - 1

        if canCursorMoveDown {
            currentLineIndex += 1
            markNeedsRerender()
        } else if scrollTopIndex < maxScrollTop {
            scrollTopIndex += 1
            isScrolledToBottom = (scrollTopIndex == maxScrollTop)
            markNeedsRerender()
        }
        return true
    }

    @discardableResult
    public func scrollPageUp() -> Bool {
        let step = max(1, logAreaHeight)
        scroll(delta: -step)
        return true
    }

    @discardableResult
    public func scrollPageDown() -> Bool {
        let step = max(1, logAreaHeight)
        scroll(delta: step)
        return true
    }

    @discardableResult
    public func scrollToTop() -> Bool {
        if scrollTopIndex > 0 || currentLineIndex > 0 {
            scrollTopIndex = 0
            currentLineIndex = 0
            isScrolledToBottom = (_displayLines.count <= logAreaHeight)
            markNeedsRerender()
        }
        return true
    }

    @discardableResult
    public func scrollToBottom() -> Bool {
        let maxScrollPossible = max(0, _displayLines.count - logAreaHeight)
        if scrollTopIndex < maxScrollPossible || !isScrolledToBottom {
            scrollToBottomInternal(forceCursorToLastLine: true)
            markNeedsRerender()
        }
        return true
    }

    // MARK: - Log Export & Selection

    // parity: core/src/console.ts#TerminalConsole.getCachedLogs [status=implemented hash=075b732a7983]
    public func getCachedLogs() -> String {
        getCachedLogsAsString()
    }

    public func getCachedLogsAsString() -> String {
        let combined = _allLogEntries + cache.cachedLogs
        return combined.map { entry in
            "[\(entry.timestamp)] [\(entry.level.rawValue)] \(entry.message)"
        }.joined(separator: "\n")
    }

    public var hasSelection: Bool {
        guard let start = _selectionStart, let end = _selectionEnd else { return false }
        return start.line != end.line || start.col != end.col
    }

    public var selection: ConsoleSelection? {
        normalizeSelection()
    }

    public func select(startLine: Int, startCol: Int, endLine: Int, endCol: Int) {
        _selectionStart = (startLine, max(0, startCol))
        _selectionEnd = (endLine, max(0, endCol))
        _isDragging = false
        markNeedsRerender()
    }

    public func clearSelection() {
        _selectionStart = nil
        _selectionEnd = nil
        _isDragging = false
    }

    public var selectedText: String {
        guard let sel = normalizeSelection() else { return "" }
        var lines: [String] = []
        guard sel.startLine <= sel.endLine else { return "" }
        for i in sel.startLine...sel.endLine {
            guard i >= 0 && i < _displayLines.count else { continue }
            let line = _displayLines[i]
            let fullText = (line.indent ? String(repeating: " ", count: consoleIndentWidth) : "") + line.text
            let chars = Array(fullText)
            let count = chars.count
            let sliceStart: Int
            let sliceEnd: Int
            if i == sel.startLine && i == sel.endLine {
                sliceStart = max(0, min(sel.startCol, count))
                sliceEnd = max(sliceStart, min(sel.endCol, count))
            } else if i == sel.startLine {
                sliceStart = max(0, min(sel.startCol, count))
                sliceEnd = count
            } else if i == sel.endLine {
                sliceStart = 0
                sliceEnd = max(0, min(sel.endCol, count))
            } else {
                sliceStart = 0
                sliceEnd = count
            }
            lines.append(String(chars[sliceStart..<sliceEnd]))
        }
        return lines.joined(separator: "\n")
    }

    @discardableResult
    public func copySelection() -> String {
        guard hasSelection else { return "" }
        let text = selectedText
        if !text.isEmpty {
            options.onCopySelection?(text)
            clearSelection()
            markNeedsRerender()
        }
        return text
    }

    // MARK: - Key & Mouse Input Handling

    @discardableResult
    public func handleKeyPress(_ event: KeyEvent) -> Bool {
        if event.name == "escape" {
            blur()
            return true
        }

        if let action = lookupKeyAction(
            name: event.name,
            ctrl: event.ctrl,
            shift: event.shift,
            meta: event.meta,
            superKey: event.`super` ?? false,
            baseCode: event.baseCode
        ) {
            return performAction(action)
        }
        return false
    }

    @discardableResult
    public func handleKeyPress(_ key: ParsedKey) -> Bool {
        handleKeyPress(KeyEvent(key))
    }

    // parity: core/src/console.ts#TerminalConsole.handleMouse [status=implemented hash=ce980a45e0f1]
    @discardableResult
    public func handleMouse(_ event: RawMouseEvent) -> Bool {
        guard _isVisible else { return false }

        let localX = event.x - consoleX
        let localY = event.y - consoleY

        guard localX >= 0 && localX < consoleWidth && localY >= 0 && localY < consoleHeight else {
            return false
        }

        if event.type == .scroll, let scrollInfo = event.scroll {
            switch scrollInfo.direction {
            case .up:
                scrollUp()
            case .down:
                scrollDown()
            case .left, .right:
                break
            }
            return true
        }

        if localY == 0 {
            if event.type == .down,
               event.button == 0,
               localX >= _copyButtonBounds.x,
               localX < _copyButtonBounds.x + _copyButtonBounds.width
            {
                _ = copySelection()
                return true
            }
            return true
        }

        let lineIndex = scrollTopIndex + (localY - 1)
        let colIndex = max(0, localX - (logContentLeft + 1))

        if event.type == .down && event.button == 0 {
            clearSelection()
            _selectionStart = (lineIndex, colIndex)
            _selectionEnd = (lineIndex, colIndex)
            _isDragging = true
            markNeedsRerender()
            return true
        }

        if event.type == .drag && _isDragging {
            _selectionEnd = (lineIndex, colIndex)
            markNeedsRerender()
            return true
        }

        if event.type == .up {
            if _isDragging {
                _selectionEnd = (lineIndex, colIndex)
                _isDragging = false
                markNeedsRerender()
            }
            return true
        }

        return true
    }

    // MARK: - Rendering

    /// Renders the console overlay panel into `buffer`.
    public func render(into buffer: OptimizedBuffer) {
        renderToBuffer(buffer)
    }

    // parity: core/src/console.ts#TerminalConsole.renderToBuffer [status=implemented hash=d8a4a032ac54]
    public func renderToBuffer(_ buffer: OptimizedBuffer) {
        guard _isVisible else { return }

        if frameBuffer == nil && consoleWidth > 0 && consoleHeight > 0 {
            frameBuffer = OptimizedBuffer(
                width: consoleWidth,
                height: consoleHeight,
                widthMethod: options.widthMethod,
                respectAlpha: options.backgroundColor.a < 1.0,
                id: "console framebuffer"
            )
            _needsFrameBufferUpdate = true
        }

        guard let fb = frameBuffer else { return }

        if fb.width != consoleWidth || fb.height != consoleHeight {
            try? fb.resize(width: max(1, consoleWidth), height: max(1, consoleHeight))
            _needsFrameBufferUpdate = true
        }

        if _needsFrameBufferUpdate {
            updateFrameBuffer(fb)
            _needsFrameBufferUpdate = false
        }

        buffer.drawFrameBuffer(destX: consoleX, destY: consoleY, frameBuffer: fb)
    }

    // MARK: - Private Layout & Rendering Helpers

    private var hasVisibleBorder: Bool {
        options.showBorder && consoleWidth >= 4 && consoleHeight >= 3
    }

    private var logAreaHeight: Int {
        hasVisibleBorder ? max(1, consoleHeight - 2) : max(1, consoleHeight - 1)
    }

    private var logContentLeft: Int {
        hasVisibleBorder ? 1 : 0
    }

    private var logTextWidth: Int {
        hasVisibleBorder ? max(1, consoleWidth - 3) : max(1, consoleWidth - 1)
    }

    private func markNeedsRerender() {
        _needsFrameBufferUpdate = true
        onRequestRender?()
    }

    private func updateConsoleDimensions(termWidth: Int, termHeight: Int) {
        let pct = Double(options.sizePercent) / 100.0
        switch options.position {
        case .top:
            consoleX = 0
            consoleY = 0
            consoleWidth = termWidth
            consoleHeight = max(1, Int((Double(termHeight) * pct).rounded(.down)))
        case .bottom:
            consoleHeight = max(1, Int((Double(termHeight) * pct).rounded(.down)))
            consoleWidth = termWidth
            consoleX = 0
            consoleY = max(0, termHeight - consoleHeight)
        case .left:
            consoleWidth = max(1, Int((Double(termWidth) * pct).rounded(.down)))
            consoleHeight = termHeight
            consoleX = 0
            consoleY = 0
        case .right:
            consoleWidth = max(1, Int((Double(termWidth) * pct).rounded(.down)))
            consoleHeight = termHeight
            consoleY = 0
            consoleX = max(0, termWidth - consoleWidth)
        }
        currentLineIndex = max(0, min(currentLineIndex, max(0, logAreaHeight - 1)))
    }

    private func updateFrameBuffer(_ fb: OptimizedBuffer) {
        fb.clear(bg: options.backgroundColor)

        if hasVisibleBorder {
            fb.drawBox(
                x: 0,
                y: 0,
                width: consoleWidth,
                height: consoleHeight,
                borderStyle: .single,
                borderSides: BorderSidesConfig(top: true, right: true, bottom: true, left: true),
                borderColor: options.borderColor,
                backgroundColor: options.backgroundColor,
                shouldFill: true
            )
        } else {
            fb.fillRect(x: 0, y: 0, width: consoleWidth, height: 1, bg: options.titleBarColor)
        }

        // Compute copy button placement first so the title never collides with it
        let copyLabel = copyButtonLabel()
        let rightMargin = hasVisibleBorder ? 2 : 1
        let copyButtonMinX = hasVisibleBorder ? 1 : 0
        let copyButtonX = consoleWidth - copyLabel.count - rightMargin
        let hasCopyButton = copyButtonX >= copyButtonMinX

        // Title bar text (centered when space allows, shifted/clipped before copy button)
        let baseTitle = "\(options.title)\(_isFocused ? " (Focused)" : "")"
        let displayTitle = hasVisibleBorder ? " \(baseTitle) " : baseTitle
        let titleStartX = hasVisibleBorder ? 1 : 0
        let titleRightEdge = hasCopyButton ? max(titleStartX, copyButtonX - 1) : (hasVisibleBorder ? max(titleStartX, consoleWidth - 1) : consoleWidth)
        let titleAvailWidth = max(0, titleRightEdge - titleStartX)

        if titleAvailWidth > 0 {
            let fullWidth = hasVisibleBorder ? max(0, consoleWidth - 2) : consoleWidth
            let centeredX = titleStartX + max(0, (fullWidth - displayTitle.count) / 2)
            let titleX: Int
            if centeredX + displayTitle.count <= titleRightEdge {
                titleX = centeredX
            } else {
                titleX = titleStartX
            }
            let drawMaxWidth = max(1, titleRightEdge - titleX)
            let clearWidth = min(displayTitle.count, drawMaxWidth)
            if hasVisibleBorder {
                for cx in titleX..<(titleX + clearWidth) {
                    fb.setCell(x: cx, y: 0, cell: TerminalCell(scalar: defaultSpaceChar, foreground: options.titleBarTextColor, background: options.titleBarColor))
                }
            }
            fb.drawTextFit(
                displayTitle,
                x: titleX,
                y: 0,
                maxWidth: drawMaxWidth,
                fg: options.titleBarTextColor,
                bg: options.titleBarColor
            )
        }

        // Copy button on right side of row 0
        if hasCopyButton {
            let disabledColor = RGBA.fromInts(100, 100, 100, 255)
            let copyColor = hasSelection ? options.copyButtonColor : disabledColor
            if hasVisibleBorder {
                for cx in copyButtonX..<(copyButtonX + copyLabel.count) {
                    fb.setCell(x: cx, y: 0, cell: TerminalCell(scalar: defaultSpaceChar, foreground: copyColor, background: options.titleBarColor))
                }
            }
            fb.drawText(copyLabel, x: copyButtonX, y: 0, fg: copyColor, bg: options.titleBarColor)
            _copyButtonBounds = ConsoleBounds(x: copyButtonX, y: 0, width: copyLabel.count, height: 1)
        } else {
            _copyButtonBounds = ConsoleBounds(x: -1, y: -1, width: 0, height: 0)
        }

        // Visible log lines
        let areaHeight = logAreaHeight
        let startIndex = min(scrollTopIndex, _displayLines.count)
        let endIndex = min(startIndex + areaHeight, _displayLines.count)
        let maxRowY = hasVisibleBorder ? consoleHeight - 1 : consoleHeight
        let textStartX = logContentLeft + 1
        let maxTextWidth = logTextWidth

        var lineY = 1
        if startIndex < endIndex {
            for absoluteLineIndex in startIndex..<endIndex {
                if lineY >= maxRowY { break }
                let displayLine = _displayLines[absoluteLineIndex]
                let levelColor = colorForLevel(displayLine.level)
                let showCursor = _isFocused && (lineY - 1 == currentLineIndex)

                if showCursor {
                    fb.drawText(">", x: logContentLeft, y: lineY, fg: options.cursorColor, bg: options.backgroundColor)
                } else {
                    fb.drawText(" ", x: logContentLeft, y: lineY, fg: options.colorDefault, bg: options.backgroundColor)
                }

                let fullText = (displayLine.indent ? String(repeating: " ", count: consoleIndentWidth) : "") + displayLine.text
                if let range = lineSelectionRange(lineIndex: absoluteLineIndex) {
                    let chars = Array(fullText)
                    let adjustedStart = max(0, min(range.start, chars.count))
                    let adjustedEnd = max(adjustedStart, min(range.end, chars.count))

                    if adjustedStart > 0 {
                        let before = String(chars[0..<adjustedStart])
                        fb.drawTextFit(before, x: textStartX, y: lineY, maxWidth: maxTextWidth, fg: levelColor)
                    }
                    if adjustedStart < adjustedEnd {
                        let selStr = String(chars[adjustedStart..<adjustedEnd])
                        let selX = textStartX + adjustedStart
                        let selAvail = max(0, (textStartX + maxTextWidth) - selX)
                        if selAvail > 0 {
                            fb.fillRect(
                                x: selX,
                                y: lineY,
                                width: min(adjustedEnd - adjustedStart, selAvail),
                                height: 1,
                                bg: options.selectionColor
                            )
                            fb.drawTextFit(
                                selStr,
                                x: selX,
                                y: lineY,
                                maxWidth: selAvail,
                                fg: levelColor,
                                bg: options.selectionColor
                            )
                        }
                    }
                    if adjustedEnd < chars.count {
                        let after = String(chars[adjustedEnd..<chars.count])
                        let afterX = textStartX + adjustedEnd
                        let afterAvail = max(0, (textStartX + maxTextWidth) - afterX)
                        if afterAvail > 0 {
                            fb.drawTextFit(after, x: afterX, y: lineY, maxWidth: afterAvail, fg: levelColor)
                        }
                    }
                } else {
                    fb.drawTextFit(fullText, x: textStartX, y: lineY, maxWidth: maxTextWidth, fg: levelColor)
                }

                lineY += 1
            }
        }
    }

    private func colorForLevel(_ level: ConsoleLogLevel) -> RGBA {
        switch level {
        case .log: return options.colorDefault
        case .info: return options.colorInfo
        case .warn: return options.colorWarn
        case .error: return options.colorError
        case .debug: return options.colorDebug
        }
    }

    private func copyButtonLabel() -> String {
        if let copyBinding = _mergedKeyBindings.last(where: { $0.action == .copySelection }) {
            return "[Copy (\(copyBinding.displayString))]"
        }
        return "[Copy]"
    }

    // MARK: - Log Processing

    private func handleNewLogEntry(_ entry: ConsoleLogEntry) {
        guard _isVisible else { return }

        _allLogEntries.append(entry)
        if _allLogEntries.count > options.maxStoredLogs {
            _allLogEntries.removeFirst(_allLogEntries.count - options.maxStoredLogs)
        }

        let newLines = processLogEntry(entry)
        _displayLines.append(contentsOf: newLines)

        if _displayLines.count > options.maxDisplayLines {
            let linesRemoved = _displayLines.count - options.maxDisplayLines
            _displayLines.removeFirst(linesRemoved)
            scrollTopIndex = max(0, scrollTopIndex - linesRemoved)
        }

        if isScrolledToBottom {
            scrollToBottomInternal(forceCursorToLastLine: false)
        }
        markNeedsRerender()
    }

    private func processLogEntry(_ entry: ConsoleLogEntry) -> [ConsoleDisplayLine] {
        var result: [ConsoleDisplayLine] = []
        let callerPart: String
        if _debugModeEnabled {
            let source = entry.callerInfo.map { "\($0.fileName):\($0.lineNumber)" } ?? "unknown"
            callerPart = " [\(source)]"
        } else {
            callerPart = ""
        }
        let prefix = "[\(entry.timestamp)] [\(entry.level.rawValue)]\(callerPart) "
        let sanitized = sanitizeConsoleMessage(entry.message)
        let initialLines = sanitized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let cells = max(1, logTextWidth)
        let indentedCells = max(1, logTextWidth - consoleIndentWidth)

        for (i, line) in initialLines.enumerated() {
            let isFirstLine = (i == 0)
            let wrapped = isFirstLine
                ? wrapConsoleDisplayCells(prefix + line, firstCells: cells, restCells: indentedCells, widthMethod: options.widthMethod)
                : wrapConsoleDisplayCells(line, firstCells: indentedCells, restCells: indentedCells, widthMethod: options.widthMethod)
            if wrapped.isEmpty {
                result.append(ConsoleDisplayLine(text: "", level: entry.level, indent: !isFirstLine))
            } else {
                for (segIdx, seg) in wrapped.enumerated() {
                    result.append(ConsoleDisplayLine(text: seg, level: entry.level, indent: !isFirstLine || segIdx > 0))
                }
            }
        }

        return result
    }

    private func processCachedLogs() {
        let logsToProcess = cache.cachedLogs
        cache.clearConsole()
        guard !logsToProcess.isEmpty else { return }

        _allLogEntries.append(contentsOf: logsToProcess)
        if _allLogEntries.count > options.maxStoredLogs {
            _allLogEntries.removeFirst(_allLogEntries.count - options.maxStoredLogs)
        }

        for entry in logsToProcess {
            _displayLines.append(contentsOf: processLogEntry(entry))
        }

        if _displayLines.count > options.maxDisplayLines {
            _displayLines.removeFirst(_displayLines.count - options.maxDisplayLines)
        }
    }

    private func rebuildDisplayLines() {
        _displayLines.removeAll(keepingCapacity: true)
        for entry in _allLogEntries {
            _displayLines.append(contentsOf: processLogEntry(entry))
        }
        if _displayLines.count > options.maxDisplayLines {
            _displayLines.removeFirst(_displayLines.count - options.maxDisplayLines)
        }
    }

    private func scrollToBottomInternal(forceCursorToLastLine: Bool) {
        let displayLineCount = _displayLines.count
        let areaHeight = logAreaHeight
        let maxScrollTop = max(0, displayLineCount - areaHeight)
        scrollTopIndex = maxScrollTop
        isScrolledToBottom = true

        let visibleLineCount = min(areaHeight, max(0, displayLineCount - scrollTopIndex))
        if forceCursorToLastLine || currentLineIndex >= visibleLineCount {
            currentLineIndex = max(0, visibleLineCount - 1)
        }
    }

    // MARK: - Selection Helpers

    private func normalizeSelection() -> ConsoleSelection? {
        guard let start = _selectionStart, let end = _selectionEnd else { return nil }
        let startBeforeEnd = start.line < end.line || (start.line == end.line && start.col <= end.col)
        if startBeforeEnd {
            return ConsoleSelection(startLine: start.line, startCol: start.col, endLine: end.line, endCol: end.col)
        }
        return ConsoleSelection(startLine: end.line, startCol: end.col, endLine: start.line, endCol: start.col)
    }

    private func lineSelectionRange(lineIndex: Int) -> (start: Int, end: Int)? {
        guard let sel = normalizeSelection() else { return nil }
        guard lineIndex >= sel.startLine && lineIndex <= sel.endLine else { return nil }
        guard lineIndex >= 0 && lineIndex < _displayLines.count else { return nil }

        let line = _displayLines[lineIndex]
        let fullLen = (line.indent ? consoleIndentWidth : 0) + line.text.count
        var start = 0
        var end = fullLen
        if lineIndex == sel.startLine {
            start = max(0, sel.startCol)
        }
        if lineIndex == sel.endLine {
            end = min(fullLen, sel.endCol)
        }
        guard start < end else { return nil }
        return (start, end)
    }

    // MARK: - Keybinding Resolution & Action Dispatch

    private func performAction(_ action: ConsoleAction) -> Bool {
        switch action {
        case .scrollUp:
            return scrollUp()
        case .scrollDown:
            return scrollDown()
        case .scrollPageUp:
            return scrollPageUp()
        case .scrollPageDown:
            return scrollPageDown()
        case .scrollToTop:
            return scrollToTop()
        case .scrollToBottom:
            return scrollToBottom()
        case .positionPrevious:
            let idx = Self.positionCycle.firstIndex(of: options.position) ?? 0
            let prevIdx = (idx - 1 + Self.positionCycle.count) % Self.positionCycle.count
            setPosition(Self.positionCycle[prevIdx])
            return true
        case .positionNext:
            let idx = Self.positionCycle.firstIndex(of: options.position) ?? 0
            let nextIdx = (idx + 1) % Self.positionCycle.count
            setPosition(Self.positionCycle[nextIdx])
            return true
        case .sizeIncrease:
            setSizePercent(options.sizePercent + 5)
            return true
        case .sizeDecrease:
            setSizePercent(options.sizePercent - 5)
            return true
        case .saveLogs:
            let content = getCachedLogsAsString()
            onSaveLogs?(content)
            return true
        case .copySelection:
            _ = copySelection()
            return true
        case .clear:
            clear()
            return true
        }
    }

    private func lookupKeyAction(
        name: String,
        ctrl: Bool,
        shift: Bool,
        meta: Bool,
        superKey: Bool,
        baseCode: UInt32?
    ) -> ConsoleAction? {
        let primaryKey = consoleBindingKey(name: name, ctrl: ctrl, shift: shift, meta: meta, superKey: superKey)
        if let action = _keyBindingsMap[primaryKey] {
            return action
        }
        if let baseName = consoleBaseCodeKeyName(name: name, baseCode: baseCode) {
            let fallbackKey = consoleBindingKey(name: baseName, ctrl: ctrl, shift: shift, meta: meta, superKey: superKey)
            if let action = _keyBindingsMap[fallbackKey] {
                return action
            }
        }
        return nil
    }

    private static func mergeAliases(_ defaults: [String: String], _ custom: [String: String]) -> [String: String] {
        var merged = defaults
        for (k, v) in custom {
            merged[k] = v
        }
        return merged
    }

    private static func mergeBindings(
        _ defaults: [ConsoleKeyBinding],
        _ custom: [ConsoleKeyBinding]
    ) -> [ConsoleKeyBinding] {
        var order: [String] = []
        var map: [String: ConsoleKeyBinding] = [:]
        for binding in defaults + custom {
            let key = consoleBindingKey(
                name: binding.name,
                ctrl: binding.ctrl,
                shift: binding.shift,
                meta: binding.meta,
                superKey: binding.`super`
            )
            if map[key] == nil {
                order.append(key)
            }
            map[key] = binding
        }
        return order.compactMap { map[$0] }
    }

    private static func buildBindingsMap(
        _ bindings: [ConsoleKeyBinding],
        aliases: [String: String]
    ) -> [String: ConsoleAction] {
        var map: [String: ConsoleAction] = [:]
        for binding in bindings {
            let key = consoleBindingKey(
                name: binding.name,
                ctrl: binding.ctrl,
                shift: binding.shift,
                meta: binding.meta,
                superKey: binding.`super`
            )
            map[key] = binding.action
        }
        for binding in bindings {
            let normalized = aliases[binding.name] ?? binding.name
            if normalized != binding.name {
                let aliasedKey = consoleBindingKey(
                    name: normalized,
                    ctrl: binding.ctrl,
                    shift: binding.shift,
                    meta: binding.meta,
                    superKey: binding.`super`
                )
                map[aliasedKey] = binding.action
            }
        }
        return map
    }
}
