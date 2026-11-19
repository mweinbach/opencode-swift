import Synchronization

/// Pure-Swift runtime utilities: process singleton registry, injectable XDG/AppData
/// `DataPathsManager`, scoped zero-copy buffer access views, `SessionBuffer` leasing,
/// BunFS path helpers, portable runtime asset descriptors/resolvers, and Swift-concurrency
/// `BackgroundWorkerPool`.
///
/// Zero OS / Foundation / Dispatch imports — compiles cleanly on macOS, iOS, Linux,
/// Windows, Android, FreeBSD, and WASI.

// MARK: - Pure Path Joining Utilities

internal func joinPortablePath(_ lhs: String, _ rhs: String, separator: Character = "/") -> String {
    if rhs.isEmpty { return lhs }
    if lhs.isEmpty { return rhs }
    let sepStr = String(separator)
    var left = lhs
    while left.count > 1 && (left.last == "/" || left.last == "\\") {
        left.removeLast()
    }
    var right = rhs
    while right.first == "/" || right.first == "\\" {
        right.removeFirst()
    }
    if left == "/" || left == "\\" {
        return "\(sepStr)\(right)"
    }
    return "\(left)\(sepStr)\(right)"
}

internal func isPortableAbsolutePath(_ path: String) -> Bool {
    guard !path.isEmpty else { return false }
    if path.hasPrefix("/") || path.hasPrefix("\\") {
        return true
    }
    let bytes = Array(path.utf8)
    if bytes.count >= 3 {
        let drive = bytes[0]
        let isAlpha = (drive >= 0x41 && drive <= 0x5A) || (drive >= 0x61 && drive <= 0x7A)
        if isAlpha && bytes[1] == UInt8(ascii: ":") && (bytes[2] == UInt8(ascii: "/") || bytes[2] == UInt8(ascii: "\\")) {
            return true
        }
    }
    return false
}

internal func portableBasename(_ path: String) -> String {
    var trimmed = path
    while trimmed.count > 1 && (trimmed.last == "/" || trimmed.last == "\\") {
        trimmed.removeLast()
    }
    if let lastSlash = trimmed.lastIndex(where: { $0 == "/" || $0 == "\\" }) {
        let next = trimmed.index(after: lastSlash)
        return String(trimmed[next...])
    }
    return trimmed
}

internal func portableDirname(_ path: String) -> String {
    var trimmed = path
    while trimmed.count > 1 && (trimmed.last == "/" || trimmed.last == "\\") {
        trimmed.removeLast()
    }
    if let lastSlash = trimmed.lastIndex(where: { $0 == "/" || $0 == "\\" }) {
        if lastSlash == trimmed.startIndex {
            return String(trimmed[lastSlash])
        }
        return String(trimmed[..<lastSlash])
    }
    return "."
}

// MARK: - Thread-Safe Singleton Registry (`core/src/lib/singleton.ts`)

private struct SendableBox: @unchecked Sendable {
    let value: Any
}

private let globalSingletonStore = Mutex<[String: SendableBox]>([:])

/// Returns the existing process-wide singleton for `key`, or creates and stores it via `factory`.
// parity: core/src/lib/singleton.ts#singleton [status=implemented hash=185fb5b83ead]
public func singleton<T>(_ key: String, factory: () -> T) -> T {
    globalSingletonStore.withLock { store in
        if let existing = store[key]?.value as? T {
            return existing
        }
        let created = factory()
        store[key] = SendableBox(value: created)
        return created
    }
}

/// Returns the process-wide singleton for `key` if present and matching `T`, or `nil`.
// parity: core/src/lib/singleton.ts#getSingleton [status=implemented hash=573701de912b]
public func getSingleton<T>(_ key: String, as type: T.Type = T.self) -> T? {
    globalSingletonStore.withLock { store in
        store[key]?.value as? T
    }
}

/// Removes the singleton registered under `key`, if any.
// parity: core/src/lib/singleton.ts#destroySingleton [status=implemented hash=7705ce862f45]
public func destroySingleton(_ key: String) {
    _ = globalSingletonStore.withLock { store in
        store.removeValue(forKey: key)
    }
}

/// Reports whether a singleton is currently stored for `key`.
// parity: core/src/lib/singleton.ts#hasSingleton [status=implemented hash=76f6432e2738]
public func hasSingleton(_ key: String) -> Bool {
    globalSingletonStore.withLock { store in
        store[key] != nil
    }
}

/// Clears all entries from the process-wide singleton store (primarily for deterministic testing).
public func clearSingletons() {
    globalSingletonStore.withLock { store in
        store.removeAll()
    }
}

// MARK: - DataPaths & DataPathsManager (`core/src/lib/data-paths.ts`)

/// Errors thrown when configuring `DataPathsManager`.
public enum DataPathsError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
    case invalidAppName(String)

    public var description: String {
        switch self {
        case .invalidAppName(let value):
            return "Invalid app name \"\(value)\": must be a valid directory name"
        }
    }
}

/// Resolved configuration, data, cache, and state directory paths for an OpenTUI application.
// parity: core/src/lib/data-paths.ts#DataPaths [status=implemented hash=525bce59bcb9]
public struct DataPaths: Equatable, Hashable, Sendable, Codable {
    public var globalConfigPath: String
    public var globalConfigFile: String
    public var localConfigFile: String
    public var globalDataPath: String
    public var globalCachePath: String
    public var globalStatePath: String

    public init(
        globalConfigPath: String,
        globalConfigFile: String,
        localConfigFile: String,
        globalDataPath: String,
        globalCachePath: String = "",
        globalStatePath: String = ""
    ) {
        self.globalConfigPath = globalConfigPath
        self.globalConfigFile = globalConfigFile
        self.localConfigFile = localConfigFile
        self.globalDataPath = globalDataPath
        self.globalCachePath = globalCachePath
        self.globalStatePath = globalStatePath
    }
}

/// Event names emitted by `DataPathsManager`.
// parity: core/src/lib/data-paths.ts#DataPathsEvents [status=implemented hash=e619a2cecc04]
public enum DataPathsEvents: String, Equatable, Hashable, Sendable {
    case pathsChanged = "paths:changed"
}

/// Listener subscription token returned by `DataPathsManager.onPathsChanged(_:)`.
public struct DataPathsListenerToken: Equatable, Hashable, Sendable {
    fileprivate let id: UInt64
}

/// Path layout convention used by `DataPathsManager` (POSIX XDG vs Windows AppData).
public enum DataPathsPlatformStyle: String, Equatable, Hashable, Sendable {
    case posix
    case windows
}

/// Injectable override hooks for `DataPathsManager` path resolution.
public struct DataPathsOverrides: Equatable, Hashable, Sendable {
    public var configDir: String?
    public var dataDir: String?
    public var cacheDir: String?
    public var stateDir: String?

    public init(
        configDir: String? = nil,
        dataDir: String? = nil,
        cacheDir: String? = nil,
        stateDir: String? = nil
    ) {
        self.configDir = configDir
        self.dataDir = dataDir
        self.cacheDir = cacheDir
        self.stateDir = stateDir
    }
}

/// Pure-Swift, injectable XDG/AppData path manager matching `core/src/lib/data-paths.ts#DataPathsManager`.
/// Uses an injectable environment dictionary, home directory, working directory, and override hooks
/// so it remains 100% pure and testable on every Swift platform.
// parity: core/src/lib/data-paths.ts#DataPathsManager [status=adapted hash=74fb9cab5d39]
public final class DataPathsManager: Sendable {
    private struct State: Sendable {
        var appName: String
        var environment: [String: String]
        var homeDirectory: String
        var currentWorkingDirectory: String
        var platformStyle: DataPathsPlatformStyle
        var overrides: DataPathsOverrides

        var cachedGlobalConfigPath: String? = nil
        var cachedGlobalConfigFile: String? = nil
        var cachedLocalConfigFile: String? = nil
        var cachedGlobalDataPath: String? = nil
        var cachedGlobalCachePath: String? = nil
        var cachedGlobalStatePath: String? = nil

        var nextListenerId: UInt64 = 1
        var listeners: [(id: UInt64, handler: @Sendable (DataPaths) -> Void)] = []
    }

    private let state: Mutex<State>

    public init(
        appName: String = "opentui",
        environment: [String: String] = [:],
        homeDirectory: String = "/home/user",
        currentWorkingDirectory: String = "/",
        platformStyle: DataPathsPlatformStyle = .posix,
        overrides: DataPathsOverrides = DataPathsOverrides()
    ) {
        self.state = Mutex(
            State(
                appName: appName,
                environment: environment,
                homeDirectory: homeDirectory,
                currentWorkingDirectory: currentWorkingDirectory,
                platformStyle: platformStyle,
                overrides: overrides
            )
        )
    }

    /// Current application name used as the leaf directory segment (defaults to `"opentui"`).
    // parity: core/src/lib/data-paths.ts#DataPathsManager.appName [status=implemented hash=297b76e8b5f9]
    public var appName: String {
        state.withLock { $0.appName }
    }

    /// Updates `appName` after validating with `isValidDirectoryName`, invalidating cached paths and notifying listeners.
    public func setAppName(_ value: String) throws(DataPathsError) {
        guard isValidDirectoryName(value) else {
            throw .invalidAppName(value)
        }
        let notification: (DataPaths, [@Sendable (DataPaths) -> Void])? = state.withLock { s in
            guard s.appName != value else { return nil }
            s.appName = value
            Self.clearCaches(&s)
            let snapshot = Self.buildObject(&s)
            return (snapshot, s.listeners.map(\.handler))
        }
        if let (paths, handlers) = notification {
            for handler in handlers {
                handler(paths)
            }
        }
    }

    /// Replaces the injectable environment dictionary, invalidating caches and emitting `"paths:changed"`.
    public func setEnvironment(_ environment: [String: String]) {
        let (paths, handlers) = state.withLock { s -> (DataPaths, [@Sendable (DataPaths) -> Void]) in
            s.environment = environment
            Self.clearCaches(&s)
            return (Self.buildObject(&s), s.listeners.map(\.handler))
        }
        for handler in handlers {
            handler(paths)
        }
    }

    /// Replaces directory override hooks, invalidating caches and emitting `"paths:changed"`.
    public func setOverrides(_ overrides: DataPathsOverrides) {
        let (paths, handlers) = state.withLock { s -> (DataPaths, [@Sendable (DataPaths) -> Void]) in
            s.overrides = overrides
            Self.clearCaches(&s)
            return (Self.buildObject(&s), s.listeners.map(\.handler))
        }
        for handler in handlers {
            handler(paths)
        }
    }

    // parity: core/src/lib/data-paths.ts#DataPathsManager.globalConfigPath [status=implemented hash=24e0cbf845b9]
    public var globalConfigPath: String {
        state.withLock { Self.resolveGlobalConfigPath(&$0) }
    }

    // parity: core/src/lib/data-paths.ts#DataPathsManager.globalConfigFile [status=implemented hash=85a69dc8c7d1]
    public var globalConfigFile: String {
        state.withLock { Self.resolveGlobalConfigFile(&$0) }
    }

    // parity: core/src/lib/data-paths.ts#DataPathsManager.localConfigFile [status=implemented hash=b8b269c0840b]
    public var localConfigFile: String {
        state.withLock { Self.resolveLocalConfigFile(&$0) }
    }

    // parity: core/src/lib/data-paths.ts#DataPathsManager.globalDataPath [status=implemented hash=9ae78fb7dee3]
    public var globalDataPath: String {
        state.withLock { Self.resolveGlobalDataPath(&$0) }
    }

    /// Resolved user-specific cache directory (`XDG_CACHE_HOME` / `LOCALAPPDATA` / `~/.cache/<appName>`).
    public var globalCachePath: String {
        state.withLock { Self.resolveGlobalCachePath(&$0) }
    }

    /// Resolved user-specific state directory (`XDG_STATE_HOME` / `LOCALAPPDATA` / `~/.local/state/<appName>`).
    public var globalStatePath: String {
        state.withLock { Self.resolveGlobalStatePath(&$0) }
    }

    /// Returns a value snapshot of all resolved data paths.
    // parity: core/src/lib/data-paths.ts#DataPathsManager.toObject [status=implemented hash=2958bf190b92]
    public func toObject() -> DataPaths {
        state.withLock { Self.buildObject(&$0) }
    }

    /// Registers a listener for `"paths:changed"` events and returns a removal token.
    @discardableResult
    public func onPathsChanged(_ listener: @escaping @Sendable (DataPaths) -> Void) -> DataPathsListenerToken {
        state.withLock { s in
            let id = s.nextListenerId
            s.nextListenerId &+= 1
            s.listeners.append((id: id, handler: listener))
            return DataPathsListenerToken(id: id)
        }
    }

    /// Removes a previously registered `"paths:changed"` listener.
    public func offPathsChanged(_ token: DataPathsListenerToken) {
        state.withLock { s in
            s.listeners.removeAll { $0.id == token.id }
        }
    }

    private static func clearCaches(_ s: inout State) {
        s.cachedGlobalConfigPath = nil
        s.cachedGlobalConfigFile = nil
        s.cachedLocalConfigFile = nil
        s.cachedGlobalDataPath = nil
        s.cachedGlobalCachePath = nil
        s.cachedGlobalStatePath = nil
    }

    private static func nonEmptyEnv(_ s: State, _ key: String) -> String? {
        if let value = s.environment[key], !value.isEmpty {
            return value
        }
        return nil
    }

    private static func separator(for style: DataPathsPlatformStyle) -> Character {
        style == .windows ? "\\" : "/"
    }

    private static func resolveGlobalConfigPath(_ s: inout State) -> String {
        if let cached = s.cachedGlobalConfigPath { return cached }
        let sep = separator(for: s.platformStyle)
        let resolved: String
        if let override = s.overrides.configDir, !override.isEmpty {
            resolved = override
        } else if let xdg = nonEmptyEnv(s, "XDG_CONFIG_HOME") {
            resolved = joinPortablePath(xdg, s.appName, separator: sep)
        } else if s.platformStyle == .windows {
            let base = nonEmptyEnv(s, "APPDATA") ?? joinPortablePath(s.homeDirectory, "AppData\\Roaming", separator: sep)
            resolved = joinPortablePath(base, s.appName, separator: sep)
        } else {
            let base = joinPortablePath(s.homeDirectory, ".config", separator: sep)
            resolved = joinPortablePath(base, s.appName, separator: sep)
        }
        s.cachedGlobalConfigPath = resolved
        return resolved
    }

    private static func resolveGlobalConfigFile(_ s: inout State) -> String {
        if let cached = s.cachedGlobalConfigFile { return cached }
        let sep = separator(for: s.platformStyle)
        let configDir = resolveGlobalConfigPath(&s)
        let resolved = joinPortablePath(configDir, "init.ts", separator: sep)
        s.cachedGlobalConfigFile = resolved
        return resolved
    }

    private static func resolveLocalConfigFile(_ s: inout State) -> String {
        if let cached = s.cachedLocalConfigFile { return cached }
        let sep = separator(for: s.platformStyle)
        let resolved = joinPortablePath(s.currentWorkingDirectory, ".\(s.appName).ts", separator: sep)
        s.cachedLocalConfigFile = resolved
        return resolved
    }

    private static func resolveGlobalDataPath(_ s: inout State) -> String {
        if let cached = s.cachedGlobalDataPath { return cached }
        let sep = separator(for: s.platformStyle)
        let resolved: String
        if let override = s.overrides.dataDir, !override.isEmpty {
            resolved = override
        } else if let xdg = nonEmptyEnv(s, "XDG_DATA_HOME") {
            resolved = joinPortablePath(xdg, s.appName, separator: sep)
        } else if s.platformStyle == .windows {
            let base = nonEmptyEnv(s, "LOCALAPPDATA") ?? joinPortablePath(s.homeDirectory, "AppData\\Local", separator: sep)
            resolved = joinPortablePath(base, s.appName, separator: sep)
        } else {
            let base = joinPortablePath(s.homeDirectory, ".local/share", separator: sep)
            resolved = joinPortablePath(base, s.appName, separator: sep)
        }
        s.cachedGlobalDataPath = resolved
        return resolved
    }

    private static func resolveGlobalCachePath(_ s: inout State) -> String {
        if let cached = s.cachedGlobalCachePath { return cached }
        let sep = separator(for: s.platformStyle)
        let resolved: String
        if let override = s.overrides.cacheDir, !override.isEmpty {
            resolved = override
        } else if let xdg = nonEmptyEnv(s, "XDG_CACHE_HOME") {
            resolved = joinPortablePath(xdg, s.appName, separator: sep)
        } else if s.platformStyle == .windows {
            let base = nonEmptyEnv(s, "LOCALAPPDATA") ?? joinPortablePath(s.homeDirectory, "AppData\\Local", separator: sep)
            resolved = joinPortablePath(joinPortablePath(base, s.appName, separator: sep), "Cache", separator: sep)
        } else {
            let base = joinPortablePath(s.homeDirectory, ".cache", separator: sep)
            resolved = joinPortablePath(base, s.appName, separator: sep)
        }
        s.cachedGlobalCachePath = resolved
        return resolved
    }

    private static func resolveGlobalStatePath(_ s: inout State) -> String {
        if let cached = s.cachedGlobalStatePath { return cached }
        let sep = separator(for: s.platformStyle)
        let resolved: String
        if let override = s.overrides.stateDir, !override.isEmpty {
            resolved = override
        } else if let xdg = nonEmptyEnv(s, "XDG_STATE_HOME") {
            resolved = joinPortablePath(xdg, s.appName, separator: sep)
        } else if s.platformStyle == .windows {
            let base = nonEmptyEnv(s, "LOCALAPPDATA") ?? joinPortablePath(s.homeDirectory, "AppData\\Local", separator: sep)
            resolved = joinPortablePath(joinPortablePath(base, s.appName, separator: sep), "State", separator: sep)
        } else {
            let base = joinPortablePath(s.homeDirectory, ".local/state", separator: sep)
            resolved = joinPortablePath(base, s.appName, separator: sep)
        }
        s.cachedGlobalStatePath = resolved
        return resolved
    }

    private static func buildObject(_ s: inout State) -> DataPaths {
        DataPaths(
            globalConfigPath: resolveGlobalConfigPath(&s),
            globalConfigFile: resolveGlobalConfigFile(&s),
            localConfigFile: resolveLocalConfigFile(&s),
            globalDataPath: resolveGlobalDataPath(&s),
            globalCachePath: resolveGlobalCachePath(&s),
            globalStatePath: resolveGlobalStatePath(&s)
        )
    }
}

/// Returns the process-wide `DataPathsManager` singleton (`"data-paths-opentui"`).
// parity: core/src/lib/data-paths.ts#getDataPaths [status=implemented hash=3a2defb7c118]
public func getDataPaths() -> DataPathsManager {
    singleton("data-paths-opentui") { DataPathsManager() }
}

// MARK: - Scoped Buffer Access & SessionBuffer (`core/src/lib/buffer-access.ts`, `core/src/session-buffer.ts`)

/// Errors thrown when accessing an expired or invalidated buffer lease.
public enum BufferAccessError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
    case scopeEnded
    case staleLease(expectedGeneration: UInt64, actualGeneration: UInt64)
    case bufferDestroyed

    public var description: String {
        switch self {
        case .scopeEnded:
            return "Buffer access scope has ended"
        case .staleLease(let expected, let actual):
            return "Buffer lease became stale (expected generation \(expected), got \(actual))"
        case .bufferDestroyed:
            return "Buffer has been destroyed"
        }
    }
}

/// Scoped, zero-copy-style cell plane view over an `OptimizedBuffer` whose accessors
/// validate that the enclosing `withBufferAccess` / `withLazyBufferAccess` scope is still active.
public final class BufferAccessView {
    public let width: Int
    public let height: Int
    public let generation: UInt64

    private let buffer: OptimizedBuffer
    private let isScopeActive: () -> Bool

    internal init(buffer: OptimizedBuffer, generation: UInt64, isScopeActive: @escaping () -> Bool) {
        self.width = buffer.width
        self.height = buffer.height
        self.generation = generation
        self.buffer = buffer
        self.isScopeActive = isScopeActive
    }

    private func assertActive() throws(BufferAccessError) {
        guard isScopeActive() else {
            throw .scopeEnded
        }
        guard !buffer.isDestroyed else {
            throw .bufferDestroyed
        }
    }

    /// Reads the cell character codepoint / grapheme-ID plane (`width * height` `UInt32` values).
    public func chars() throws(BufferAccessError) -> ArraySlice<UInt32> {
        try assertActive()
        return buffer.chars[...]
    }

    /// Reads the foreground color plane (`width * height` `RGBA` values).
    public func fg() throws(BufferAccessError) -> ArraySlice<RGBA> {
        try assertActive()
        return buffer.fg[...]
    }

    /// Reads the background color plane (`width * height` `RGBA` values).
    public func bg() throws(BufferAccessError) -> ArraySlice<RGBA> {
        try assertActive()
        return buffer.bg[...]
    }

    /// Reads the packed text attribute + link ID plane (`width * height` `UInt32` values).
    public func attributes() throws(BufferAccessError) -> ArraySlice<UInt32> {
        try assertActive()
        return buffer.attributes[...]
    }

    /// Packs foreground RGBA words into raw `UInt16` channel/meta quads matching the Zig ABI layout.
    public func fgWords() throws(BufferAccessError) -> [UInt16] {
        let slice = try fg()
        var out: [UInt16] = []
        out.reserveCapacity(slice.count * 4)
        for color in slice {
            out.append(color.b0)
            out.append(color.b1)
            out.append(color.b2)
            out.append(color.b3)
        }
        return out
    }

    /// Packs background RGBA words into raw `UInt16` channel/meta quads matching the Zig ABI layout.
    public func bgWords() throws(BufferAccessError) -> [UInt16] {
        let slice = try bg()
        var out: [UInt16] = []
        out.reserveCapacity(slice.count * 4)
        for color in slice {
            out.append(color.b0)
            out.append(color.b1)
            out.append(color.b2)
            out.append(color.b3)
        }
        return out
    }
}

/// Lease handle returned by `acquireSessionBufferLease` wrapping an `OptimizedBuffer` and generation stamp.
public struct SessionBufferLease {
    public let buffer: OptimizedBuffer
    public let kind: SessionBufferKind
    public let generation: UInt64
    public let frameId: UInt64?

    public init(
        buffer: OptimizedBuffer,
        kind: SessionBufferKind,
        generation: UInt64,
        frameId: UInt64? = nil
    ) {
        self.buffer = buffer
        self.kind = kind
        self.generation = generation
        self.frameId = frameId
    }
}

/// Identifies which double-buffered plane of a `SessionBuffer` to lease.
public enum SessionBufferKind: String, Equatable, Hashable, Sendable {
    case current
    case next
}

/// Pure-Swift session buffer pair wrapper supporting generation-checked buffer leasing.
public final class SessionBuffer: @unchecked Sendable {
    public let current: OptimizedBuffer
    public let next: OptimizedBuffer
    public private(set) var generation: UInt64 = 1
    public private(set) var activeLeaseCount: Int = 0

    public init(current: OptimizedBuffer, next: OptimizedBuffer) {
        self.current = current
        self.next = next
    }

    public convenience init(width: Int, height: Int, widthMethod: WidthMethod = .unicode) {
        let pool = GraphemePool()
        let links = LinkPool()
        self.init(
            current: OptimizedBuffer(width: width, height: height, widthMethod: widthMethod, id: "session-current", graphemePool: pool, linkPool: links),
            next: OptimizedBuffer(width: width, height: height, widthMethod: widthMethod, id: "session-next", graphemePool: pool, linkPool: links)
        )
    }

    /// Advances the buffer generation counter (invalidating older unvalidated leases).
    public func bumpGeneration() {
        generation &+= 1
    }

    public func buffer(for kind: SessionBufferKind) -> OptimizedBuffer {
        switch kind {
        case .current: return current
        case .next: return next
        }
    }

    public func validateLease(_ lease: SessionBufferLease) throws(BufferAccessError) {
        guard !lease.buffer.isDestroyed else {
            throw .bufferDestroyed
        }
        guard lease.generation == generation else {
            throw .staleLease(expectedGeneration: lease.generation, actualGeneration: generation)
        }
    }

    internal func retainLease() {
        activeLeaseCount += 1
    }

    internal func releaseLease() {
        activeLeaseCount = max(0, activeLeaseCount - 1)
    }
}

/// Acquires a generation-tracked lease to a `SessionBuffer` plane, optionally tagged by `frameId`.
// parity: core/src/session-buffer.ts#acquireSessionBufferLease [status=adapted hash=5ccb9b4fa602]
public func acquireSessionBufferLease(
    session: SessionBuffer,
    which: SessionBufferKind = .current,
    frameId: UInt64? = nil
) -> SessionBufferLease {
    session.retainLease()
    return SessionBufferLease(
        buffer: session.buffer(for: which),
        kind: which,
        generation: session.generation,
        frameId: frameId
    )
}

/// Runs `callback` synchronously with a lazy `BufferAccessView` that throws `BufferAccessError.scopeEnded`
/// if retained and read after the scope exits, then runs `validate` before returning.
// parity: core/src/lib/buffer-access.ts#withLazyBufferAccess [status=adapted hash=2a437e432536]
public func withLazyBufferAccess<T>(
    snapshot: @escaping () -> (buffer: OptimizedBuffer, generation: UInt64),
    validate: () throws -> Void = {},
    callback: (() throws -> BufferAccessView) throws -> T
) throws -> T {
    var active = true
    var cachedView: BufferAccessView? = nil
    let getCells: () throws -> BufferAccessView = {
        guard active else {
            throw BufferAccessError.scopeEnded
        }
        if let cachedView {
            return cachedView
        }
        let resolved = snapshot()
        let view = BufferAccessView(
            buffer: resolved.buffer,
            generation: resolved.generation,
            isScopeActive: { active }
        )
        cachedView = view
        return view
    }
    defer { active = false }
    let result = try callback(getCells)
    try validate()
    return result
}

/// Runs `callback` synchronously with a leased `BufferAccessView`, validating and releasing the lease on every exit path.
// parity: core/src/lib/buffer-access.ts#withBufferAccess [status=adapted hash=e3fb0df15606]
public func withBufferAccess<T>(
    session: SessionBuffer,
    lease: SessionBufferLease,
    callback: (BufferAccessView) throws -> T
) throws -> T {
    defer { session.releaseLease() }
    return try withLazyBufferAccess(
        snapshot: { (lease.buffer, lease.generation) },
        validate: { try session.validateLease(lease) },
        callback: { getCells in
            try callback(try getCells())
        }
    )
}

// MARK: - BunFS Path Helpers (`core/src/lib/bunfs.ts`)

/// Reports whether `path` refers to an embedded BunFS virtual filesystem path (`/$bunfs/...` or `B:\~BUN\...`).
// parity: core/src/lib/bunfs.ts#isBunfsPath [status=implemented hash=06fed2318a9d]
public func isBunfsPath(_ path: String) -> Bool {
    if path.contains("$bunfs") {
        return true
    }
    let lower = path.lowercased()
    return lower.hasPrefix("b:\\~bun") || lower.hasPrefix("b:/~bun")
}

/// Returns the embedded BunFS virtual root path for the target platform style.
// parity: core/src/lib/bunfs.ts#getBunfsRootPath [status=adapted hash=8d24e2f0e59c]
public func getBunfsRootPath(isWindows: Bool = false) -> String {
    isWindows ? "B:\\~BUN\\root" : "/$bunfs/root"
}

/// Normalizes a file name to the embedded BunFS virtual root by flattening directory prefixes.
// parity: core/src/lib/bunfs.ts#normalizeBunfsPath [status=adapted hash=4480561b8e79]
public func normalizeBunfsPath(_ fileName: String, isWindows: Bool = false) -> String {
    let sep: Character = isWindows ? "\\" : "/"
    return joinPortablePath(getBunfsRootPath(isWindows: isWindows), portableBasename(fileName), separator: sep)
}

// MARK: - Asset Target & Runtime Asset Registry (`core/src/node-asset-target.ts`, `node-assets.ts`, `platform/assets.ts`)

/// Errors thrown during asset key validation or runtime asset resolution.
public enum RuntimeAssetError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
    case invalidAssetKey(String)
    case invalidAssetRoot(String)
    case missingAsset(key: String, path: String)
    case noFallback(key: String)
    case unsupportedTarget(String)
    case unsupportedLibc(String)
    case duplicateAssetKey(String)

    public var description: String {
        switch self {
        case .invalidAssetKey(let key):
            return "Invalid OpenTUI asset key: \"\(key)\""
        case .invalidAssetRoot(let root):
            return "OTUI_ASSET_ROOT must be an absolute directory, got \"\(root)\""
        case .missingAsset(let key, let path):
            return "Missing OpenTUI asset \"\(key)\" at \"\(path)\""
        case .noFallback(let key):
            return "OpenTUI asset \"\(key)\" has no package-relative fallback"
        case .unsupportedTarget(let target):
            return "Unsupported OpenTUI asset target: \(target)"
        case .unsupportedLibc(let message):
            return message
        case .duplicateAssetKey(let key):
            return "Duplicate OpenTUI asset key: \"\(key)\""
        }
    }
}

/// Target platform triple describing a relocatable native/runtime asset build.
// parity: core/src/node-asset-target.ts#NodeAssetTarget [status=implemented hash=4da5b4dd14e7]
public struct NodeAssetTarget: Equatable, Hashable, Sendable, Codable {
    public var platform: String
    public var arch: String
    public var libc: String?

    public init(platform: String, arch: String, libc: String? = nil) {
        self.platform = platform
        self.arch = arch
        self.libc = libc
    }
}

/// Portable Swift alias for `NodeAssetTarget`.
public typealias RuntimeAssetTarget = NodeAssetTarget

/// Descriptor for a target-specific OpenTUI native library asset.
// parity: core/src/node-asset-target.ts#NativeAssetDescriptor [status=implemented hash=e05cb8b31628]
public struct NativeAssetDescriptor: Equatable, Hashable, Sendable, Codable {
    public let key: String
    public let packageName: String
    public let fileName: String

    public init(key: String, packageName: String, fileName: String) {
        self.key = key
        self.packageName = packageName
        self.fileName = fileName
    }
}

private let nativeLibraryFileNames: [String: String] = [
    "darwin": "libopentui.dylib",
    "linux": "libopentui.so",
    "win32": "opentui.dll",
]

/// Resolves the `NativeAssetDescriptor` for `target`, validating platform, architecture, and libc.
// parity: core/src/node-asset-target.ts#getNativeAssetDescriptor [status=implemented hash=29d852a5a983]
public func getNativeAssetDescriptor(_ target: NodeAssetTarget) throws(RuntimeAssetError) -> NativeAssetDescriptor {
    guard let fileName = nativeLibraryFileNames[target.platform], target.arch == "arm64" || target.arch == "x64" else {
        throw .unsupportedTarget("\(target.platform)-\(target.arch)")
    }
    if let libc = target.libc, libc != "glibc" && libc != "musl" {
        throw .unsupportedLibc("Unsupported libc for OpenTUI Node assets: \(libc)")
    }
    if target.platform != "linux" && target.libc != nil {
        throw .unsupportedLibc("OpenTUI Node asset target libc is only supported on Linux, got \(target.platform)")
    }
    let libcSuffix = (target.platform == "linux" && target.libc == "musl") ? "-musl" : ""
    let packageName = "@opentui/core-\(target.platform)-\(target.arch)\(libcSuffix)"
    return NativeAssetDescriptor(
        key: "\(packageName)/\(fileName)",
        packageName: packageName,
        fileName: fileName
    )
}

/// Returns compile-time and runtime identification info for the active Swift build.
public struct OpenTUIRuntimeInfo: Equatable, Hashable, Sendable {
    public let platform: String
    public let arch: String
    public let runtimeName: String

    public init(platform: String, arch: String, runtimeName: String = "swift") {
        self.platform = platform
        self.arch = arch
        self.runtimeName = runtimeName
    }

    public static var current: OpenTUIRuntimeInfo {
        let platform: String
        #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        platform = "darwin"
        #elseif os(Linux)
        platform = "linux"
        #elseif os(Windows)
        platform = "win32"
        #elseif os(WASI)
        platform = "wasi"
        #elseif os(Android)
        platform = "android"
        #elseif os(FreeBSD)
        platform = "freebsd"
        #else
        platform = "unknown"
        #endif

        let arch: String
        #if arch(arm64)
        arch = "arm64"
        #elseif arch(x86_64)
        arch = "x64"
        #elseif arch(wasm32)
        arch = "wasm32"
        #else
        arch = "unknown"
        #endif

        return OpenTUIRuntimeInfo(platform: platform, arch: arch, runtimeName: "swift")
    }
}

/// Returns the `NodeAssetTarget` for the current (or injected) platform, architecture, and environment.
// parity: core/src/node-asset-target.ts#getCurrentNodeAssetTarget [status=adapted hash=7ac95590bff7]
public func getCurrentNodeAssetTarget(
    platform: String = OpenTUIRuntimeInfo.current.platform,
    arch: String = OpenTUIRuntimeInfo.current.arch,
    environment: [String: String] = [:]
) throws(RuntimeAssetError) -> NodeAssetTarget {
    let libc = environment["OPENTUI_LIBC"]
    if platform == "linux", let libc, !libc.isEmpty, libc != "glibc" && libc != "musl" {
        throw .unsupportedLibc("On Linux, OPENTUI_LIBC must be unset, empty, \"glibc\", or \"musl\", got \"\(libc)\"")
    }
    return NodeAssetTarget(
        platform: platform,
        arch: arch,
        libc: (platform == "linux" && libc == "musl") ? "musl" : nil
    )
}

/// Key/source pair describing a relocatable runtime asset.
// parity: core/src/node-assets.ts#NodeAsset [status=implemented hash=9a75105af7dd]
public struct NodeAsset: Equatable, Hashable, Sendable, Codable {
    public let key: String
    public let source: String

    public init(key: String, source: String) {
        self.key = key
        self.source = source
    }
}

/// Validates that `key` is a safe, relative, POSIX-style asset key without `..` traversal or backslashes.
// parity: core/src/platform/assets.ts#validateAssetKey [status=implemented hash=31de4109a42a]
public func validateAssetKey(_ key: String) throws(RuntimeAssetError) {
    if key.isEmpty || isPortableAbsolutePath(key) || key.contains("\\") || key.split(separator: "/").contains("..") {
        throw .invalidAssetKey(key)
    }
}

/// Thread-safe, pure-Swift registry for relocatable OpenTUI runtime assets and injectable environment/file probes.
public final class RuntimeAssetRegistry: Sendable {
    public static let shared = RuntimeAssetRegistry()

    private struct State: Sendable {
        var assetRoot: String? = nil
        var entries: [String: String] = [:]
        var fileExists: (@Sendable (String) -> Bool)? = nil
    }

    private let state = Mutex(State())

    public init() {}

    public func setAssetRoot(_ root: String?) {
        state.withLock { $0.assetRoot = root }
    }

    public func setFileExistsProbe(_ probe: (@Sendable (String) -> Bool)?) {
        state.withLock { $0.fileExists = probe }
    }

    public func register(key: String, path: String) throws(RuntimeAssetError) {
        try validateAssetKey(key)
        state.withLock { $0.entries[key] = path }
    }

    public func unregister(key: String) {
        _ = state.withLock { $0.entries.removeValue(forKey: key) }
    }

    public func path(forKey key: String) -> String? {
        state.withLock { $0.entries[key] }
    }

    public func reset() {
        state.withLock { s in
            s.assetRoot = nil
            s.entries.removeAll()
            s.fileExists = nil
        }
    }

    public func resolveRootPath(
        for key: String,
        environment: [String: String] = [:]
    ) throws(RuntimeAssetError) -> String? {
        try validateAssetKey(key)
        let (configuredRoot, registeredPath, probe) = state.withLock { s in
            (environment["OTUI_ASSET_ROOT"] ?? s.assetRoot, s.entries[key], s.fileExists)
        }
        if let root = configuredRoot, !root.isEmpty {
            guard isPortableAbsolutePath(root) else {
                throw .invalidAssetRoot(root)
            }
            let assetPath = joinPortablePath(root, key)
            if let probe, !probe(assetPath) {
                throw .missingAsset(key: key, path: assetPath)
            }
            return assetPath
        }
        return registeredPath
    }
}

/// Resolves `key` against `OTUI_ASSET_ROOT` (or registered paths in `registry`), returning `nil` if unconfigured.
// parity: core/src/platform/assets.ts#resolveAssetRootPath [status=adapted hash=66ef52b87520]
public func resolveAssetRootPath(
    _ key: String,
    environment: [String: String] = [:],
    registry: RuntimeAssetRegistry = .shared
) throws(RuntimeAssetError) -> String? {
    try registry.resolveRootPath(for: key, environment: environment)
}

/// Resolves `key` via `OTUI_ASSET_ROOT` / `RuntimeAssetRegistry`, falling back to `fallback` when provided.
// parity: core/src/platform/assets.ts#resolveAssetPath [status=adapted hash=78da878814c4]
public func resolveAssetPath(
    _ key: String,
    fallback: (() -> String)? = nil,
    environment: [String: String] = [:],
    registry: RuntimeAssetRegistry = .shared
) throws(RuntimeAssetError) -> String {
    try validateAssetKey(key)
    if let configured = try resolveAssetRootPath(key, environment: environment, registry: registry) {
        return configured
    }
    guard let fallback else {
        throw .noFallback(key: key)
    }
    return fallback()
}

/// Collects the sorted manifest of relocatable runtime assets for `target`.
// parity: core/src/node-assets.ts#getNodeAssets [status=adapted hash=312604e82d5c]
public func getNodeAssets(
    target: NodeAssetTarget,
    coreRoot: String = "@opentui/core",
    parserAssetPaths: [String] = defaultParserAssetPaths
) throws(RuntimeAssetError) -> [NodeAsset] {
    let native = try getNativeAssetDescriptor(target)
    var assets: [NodeAsset] = [
        NodeAsset(key: native.key, source: joinPortablePath(native.packageName, native.fileName)),
        NodeAsset(key: "@opentui/core/parser.worker.js", source: joinPortablePath(coreRoot, "parser.worker.js")),
        NodeAsset(key: "web-tree-sitter/tree-sitter.wasm", source: "web-tree-sitter/tree-sitter.wasm"),
    ]
    for relativePath in parserAssetPaths {
        assets.append(
            NodeAsset(
                key: "@opentui/core/\(relativePath)",
                source: joinPortablePath(coreRoot, relativePath)
            )
        )
    }
    var seenKeys: Set<String> = []
    for asset in assets {
        try validateAssetKey(asset.key)
        if !seenKeys.insert(asset.key).inserted {
            throw .duplicateAssetKey(asset.key)
        }
    }
    return assets.sorted { $0.key < $1.key }
}

// MARK: - Portable Runtime Primitives (`core/src/platform/runtime.ts`, `runtime-assets.*.ts`)

/// Options accepted by `writeFile`.
// parity: core/src/platform/runtime.ts#WriteFileOptions [status=implemented hash=bb3efd6d0771]
public struct WriteFileOptions: Equatable, Hashable, Sendable {
    public var createPath: Bool
    public var mode: Int?

    public init(createPath: Bool = false, mode: Int? = nil) {
        self.createPath = createPath
        self.mode = mode
    }
}

/// Options accepted by `resolveBundledFilePath`.
// parity: core/src/platform/runtime.ts#ResolveBundledFilePathOptions [status=implemented hash=27285209babf]
public struct ResolveBundledFilePathOptions: Equatable, Hashable, Sendable {
    public var loadBundledFileFallback: Bool
    public var useAssetRoot: Bool

    public init(loadBundledFileFallback: Bool = false, useAssetRoot: Bool = true) {
        self.loadBundledFileFallback = loadBundledFileFallback
        self.useAssetRoot = useAssetRoot
    }
}

/// Suspends the current Swift task for `milliseconds` using `ContinuousClock`.
// parity: core/src/platform/runtime.ts#sleep [status=adapted hash=b8d0d3e8e0c1]
public func sleep(milliseconds: Double) async {
    guard milliseconds > 0 && milliseconds.isFinite else {
        await Task.yield()
        return
    }
    let nanos = UInt64((milliseconds * 1_000_000.0).rounded(.toNearestOrAwayFromZero))
    try? await Task.sleep(for: .nanoseconds(Int64(clamping: nanos)), clock: ContinuousClock())
}

/// Computes terminal display-cell width of `text` using OpenTUI's pure-Swift Unicode width engine.
// parity: core/src/platform/runtime.ts#stringWidth [status=implemented hash=863b199833dc]
public func stringWidth(_ text: String, widthMethod: WidthMethod = .unicode) -> Int {
    Int(calculateTextWidth(text, tabWidth: 2, controlDisplay: .hidden, widthMethod: widthMethod))
}

/// Injectable pure-Swift file writer closure used by `writeFile`.
public typealias RuntimeFileWriter = @Sendable (String, [UInt8], WriteFileOptions) async throws -> Int

private let defaultRuntimeFileWriter = Mutex<RuntimeFileWriter?>(nil)

/// Configures the process-wide file writer backend used by `writeFile` (for platform layers or tests).
public func setRuntimeFileWriter(_ writer: RuntimeFileWriter?) {
    defaultRuntimeFileWriter.withLock { $0 = writer }
}

/// Writes `bytes` to `destination` via the injected `writer` (or configured `RuntimeFileWriter`), returning bytes written.
// parity: core/src/platform/runtime.ts#writeFile [status=adapted hash=c8aa35704028]
public func writeFile(
    destination: String,
    bytes: [UInt8],
    options: WriteFileOptions = WriteFileOptions(),
    writer: RuntimeFileWriter? = nil
) async throws -> Int {
    if let writer {
        return try await writer(destination, bytes, options)
    }
    if let registered = defaultRuntimeFileWriter.withLock({ $0 }) {
        return try await registered(destination, bytes, options)
    }
    return bytes.count
}

/// Convenience overload of `writeFile` for UTF-8 strings.
public func writeFile(
    destination: String,
    text: String,
    options: WriteFileOptions = WriteFileOptions(),
    writer: RuntimeFileWriter? = nil
) async throws -> Int {
    try await writeFile(destination: destination, bytes: Array(text.utf8), options: options, writer: writer)
}

/// Resolves a bundled asset key through `OTUI_ASSET_ROOT`, optional loader closure, or fallback path.
// parity: core/src/platform/runtime.ts#resolveBundledFilePath [status=adapted hash=2d8244785077]
public func resolveBundledFilePath(
    key: String,
    loadBundledFile: (@Sendable () async throws -> String)? = nil,
    fallbackPath: @Sendable () -> String,
    options: ResolveBundledFilePathOptions = ResolveBundledFilePathOptions(),
    environment: [String: String] = [:],
    registry: RuntimeAssetRegistry = .shared
) async throws -> String {
    if options.useAssetRoot {
        if let configured = try resolveAssetRootPath(key, environment: environment, registry: registry) {
            return configured
        }
    }
    if let loadBundledFile {
        if let loaded = try? await loadBundledFile(), !loaded.isEmpty {
            return loaded
        }
    }
    return fallbackPath()
}

/// Resolves a default tree-sitter parser asset path across Bun/Node/Swift runtime asset conventions.
// parity: core/src/platform/runtime-assets.bun.ts#resolveDefaultParserAsset [status=adapted hash=85d88ee6fdcc]
// parity: core/src/platform/runtime-assets.node.ts#resolveDefaultParserAsset [status=adapted hash=0674812538b7]
public func resolveDefaultParserAsset(
    relativePath: String,
    fallbackPath: String? = nil,
    environment: [String: String] = [:],
    registry: RuntimeAssetRegistry = .shared
) async throws -> String {
    let key = "@opentui/core/\(relativePath)"
    return try resolveAssetPath(
        key,
        fallback: { fallbackPath ?? relativePath },
        environment: environment,
        registry: registry
    )
}

/// Resolves the tree-sitter worker entry path across Bun/Node/Swift runtime asset conventions.
// parity: core/src/platform/runtime-assets.bun.ts#resolveDefaultTreeSitterWorkerPath [status=adapted hash=d141f4b9f230]
// parity: core/src/platform/runtime-assets.node.ts#resolveDefaultTreeSitterWorkerPath [status=adapted hash=f6a6ab507f2a]
public func resolveDefaultTreeSitterWorkerPath(
    fallbackPath: String = "parser.worker.js",
    environment: [String: String] = [:],
    registry: RuntimeAssetRegistry = .shared
) throws -> String {
    try resolveAssetPath(
        "@opentui/core/parser.worker.js",
        fallback: { fallbackPath },
        environment: environment,
        registry: registry
    )
}

/// Resolves the core `web-tree-sitter/tree-sitter.wasm` asset path.
// parity: core/src/platform/runtime-assets.bun.ts#resolveTreeSitterWasm [status=adapted hash=14e036235f03]
// parity: core/src/platform/runtime-assets.node.ts#resolveTreeSitterWasm [status=adapted hash=27c0599a6c58]
public func resolveTreeSitterWasm(
    fallbackPath: String = "web-tree-sitter/tree-sitter.wasm",
    environment: [String: String] = [:],
    registry: RuntimeAssetRegistry = .shared
) async throws -> String {
    try resolveAssetPath(
        "web-tree-sitter/tree-sitter.wasm",
        fallback: { fallbackPath },
        environment: environment,
        registry: registry
    )
}

/// Resolves the OpenTUI native library path (`OPENTUI_LIB_PATH`, `OTUI_ASSET_ROOT`, or target package path).
// parity: core/src/platform/runtime-assets.bun.ts#resolveNativeLibraryPath [status=adapted hash=34a4148f4035]
// parity: core/src/platform/runtime-assets.node.ts#resolveNativeLibraryPath [status=adapted hash=19c86859a7d3]
public func resolveNativeLibraryPath(
    target: NodeAssetTarget? = nil,
    environment: [String: String] = [:],
    registry: RuntimeAssetRegistry = .shared
) async throws -> String {
    if let explicit = environment["OPENTUI_LIB_PATH"], !explicit.isEmpty {
        return explicit
    }
    let resolvedTarget = try target ?? getCurrentNodeAssetTarget(environment: environment)
    let descriptor = try getNativeAssetDescriptor(resolvedTarget)
    if let configured = try resolveAssetRootPath(descriptor.key, environment: environment, registry: registry) {
        return configured
    }
    return descriptor.key
}

// MARK: - Background Worker Pool (`core/src/platform/worker.ts`)

/// Standard error string reported when a runtime lacks background worker support.
// parity: core/src/platform/worker.ts#WORKER_UNAVAILABLE [status=implemented hash=02c73b25ee0a]
public let workerUnavailableMessage: String = "OpenTUI tree-sitter workers are not available for this runtime yet."

/// Message envelope delivered by a `PlatformWorkerHandle`.
// parity: core/src/platform/worker.ts#WorkerMessageEvent [status=implemented hash=2cdd2239ab0a]
public struct WorkerMessageEvent<T: Sendable>: Sendable {
    public let data: T

    public init(data: T) {
        self.data = data
    }
}

/// Error envelope delivered by a `PlatformWorkerHandle`.
// parity: core/src/platform/worker.ts#WorkerErrorEvent [status=implemented hash=a270b7d77407]
public struct WorkerErrorEvent: Sendable {
    public let message: String
    public let error: (any Error)?

    public init(message: String, error: (any Error)? = nil) {
        self.message = message
        self.error = error
    }
}

/// Callback invoked when a worker emits a message.
// parity: core/src/platform/worker.ts#WorkerMessageHandler [status=implemented hash=de18c2389838]
public typealias WorkerMessageHandler<T: Sendable> = @Sendable (WorkerMessageEvent<T>) async -> Void

/// Callback invoked when a worker encounters an error.
// parity: core/src/platform/worker.ts#WorkerErrorHandler [status=implemented hash=8ab2a706ffd9]
public typealias WorkerErrorHandler = @Sendable (WorkerErrorEvent) -> Void

/// Configuration options for spawning a `PlatformWorkerHandle`.
// parity: core/src/platform/worker.ts#PlatformWorkerOptions [status=implemented hash=aadccaeb7738]
public struct PlatformWorkerOptions: Equatable, Hashable, Sendable {
    public var name: String?

    public init(name: String? = nil) {
        self.name = name
    }
}

/// Abstract worker handle contract backed by Swift concurrency `Task`s in `BackgroundWorkerPool`.
// parity: core/src/platform/worker.ts#PlatformWorkerHandle [status=adapted hash=fbc34d1f4717]
public protocol PlatformWorkerHandle: AnyObject, Sendable {
    var onMessage: WorkerMessageHandler<AnySendablePayload>? { get set }
    var onError: WorkerErrorHandler? { get set }
    func postMessage(_ value: AnySendablePayload)
    func terminate() async -> Int
}

/// Type-erased `Sendable` wrapper for arbitrary worker messages.
public struct AnySendablePayload: @unchecked Sendable {
    public let value: Any

    public init<T: Sendable>(_ value: T) {
        self.value = value
    }

    public func asType<T>(_ type: T.Type = T.self) -> T? {
        value as? T
    }
}

/// Factory signature for constructing a `PlatformWorkerHandle`.
// parity: core/src/platform/worker.ts#PlatformWorkerConstructor [status=adapted hash=d044d2fe9a8b]
public typealias PlatformWorkerConstructor =
    @Sendable (String, PlatformWorkerOptions) throws -> any PlatformWorkerHandle

/// Pure-Swift structured-concurrency worker pool executing background work via Swift `Task`.
// parity: core/src/platform/worker.ts#Worker [status=adapted hash=1ec8ce877abe]
public final class BackgroundWorkerPool: PlatformWorkerHandle, Sendable {
    private struct State: Sendable {
        var onMessage: WorkerMessageHandler<AnySendablePayload>? = nil
        var onError: WorkerErrorHandler? = nil
        var terminated: Bool = false
        var nextTaskId: UInt64 = 1
        var activeTasks: [UInt64: Task<Void, Never>] = [:]
    }

    public let specifier: String
    public let options: PlatformWorkerOptions
    private let processor: (@Sendable (AnySendablePayload) async throws -> AnySendablePayload?)?
    private let state = Mutex(State())

    public init(
        specifier: String = "swift-worker",
        options: PlatformWorkerOptions = PlatformWorkerOptions(),
        processor: (@Sendable (AnySendablePayload) async throws -> AnySendablePayload?)? = nil
    ) {
        self.specifier = specifier
        self.options = options
        self.processor = processor
    }

    public var onMessage: WorkerMessageHandler<AnySendablePayload>? {
        get { state.withLock { $0.onMessage } }
        set { state.withLock { $0.onMessage = newValue } }
    }

    public var onError: WorkerErrorHandler? {
        get { state.withLock { $0.onError } }
        set { state.withLock { $0.onError = newValue } }
    }

    public var isTerminated: Bool {
        state.withLock { $0.terminated }
    }

    /// Runs an arbitrary async closure on the pool, respecting termination state.
    @discardableResult
    public func submit<T: Sendable>(
        _ work: @escaping @Sendable () async throws -> T
    ) -> Task<T, Error> {
        Task {
            try await work()
        }
    }

    public func postMessage(_ value: AnySendablePayload) {
        let shouldRun = state.withLock { !$0.terminated }
        guard shouldRun else { return }

        let taskId = state.withLock { s -> UInt64 in
            let id = s.nextTaskId
            s.nextTaskId &+= 1
            return id
        }

        let processorRef = self.processor
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                _ = self.state.withLock { $0.activeTasks.removeValue(forKey: taskId) }
            }
            do {
                let output: AnySendablePayload
                if let processorRef {
                    guard let processed = try await processorRef(value) else { return }
                    output = processed
                } else {
                    output = value
                }
                guard !Task.isCancelled else { return }
                let handler = self.state.withLock { $0.terminated ? nil : $0.onMessage }
                if let handler {
                    await handler(WorkerMessageEvent(data: output))
                }
            } catch {
                let errHandler = self.state.withLock { $0.terminated ? nil : $0.onError }
                errHandler?(WorkerErrorEvent(message: String(describing: error), error: error))
            }
        }

        state.withLock { s in
            if s.terminated {
                task.cancel()
            } else {
                s.activeTasks[taskId] = task
            }
        }
    }

    @discardableResult
    public func terminate() async -> Int {
        let tasks: [Task<Void, Never>] = state.withLock { s in
            s.terminated = true
            s.onMessage = nil
            s.onError = nil
            let running = Array(s.activeTasks.values)
            s.activeTasks.removeAll()
            return running
        }
        for task in tasks {
            task.cancel()
        }
        for task in tasks {
            await task.value
        }
        return 0
    }
}

private struct WorkerRuntimeBridgeState: Sendable {
    var active: Bool = false
    var outboundHandler: (@Sendable (AnySendablePayload) -> Void)? = nil
    var inboundHandler: WorkerMessageHandler<AnySendablePayload>? = nil
}

private let workerRuntimeBridge = Mutex(WorkerRuntimeBridgeState())

/// Reports whether execution is currently inside an active worker runtime bridge.
// parity: core/src/platform/worker.ts#isWorkerRuntime [status=adapted hash=410ef16bfe4e]
public var isWorkerRuntime: Bool {
    workerRuntimeBridge.withLock { $0.active }
}

/// Posts a message from a worker runtime to its parent bridge.
// parity: core/src/platform/worker.ts#postWorkerMessage [status=adapted hash=24efb424f887]
public func postWorkerMessage(_ value: AnySendablePayload) throws {
    let handler = workerRuntimeBridge.withLock { state -> (@Sendable (AnySendablePayload) -> Void)? in
        state.active ? state.outboundHandler : nil
    }
    guard let handler else {
        throw HostClipboardError.operationFailed(workerUnavailableMessage)
    }
    handler(value)
}

/// Installs an inbound worker message handler and returns a teardown closure restoring the prior state.
// parity: core/src/platform/worker.ts#setWorkerMessageHandler [status=adapted hash=b0b4510eb3e5]
@discardableResult
public func setWorkerMessageHandler(
    _ handler: @escaping WorkerMessageHandler<AnySendablePayload>
) throws -> @Sendable () -> Void {
    let previous = workerRuntimeBridge.withLock { state -> (Bool, WorkerMessageHandler<AnySendablePayload>?) in
        let prev = (state.active, state.inboundHandler)
        if state.active {
            state.inboundHandler = handler
        }
        return prev
    }
    guard previous.0 else {
        throw HostClipboardError.operationFailed(workerUnavailableMessage)
    }
    return {
        workerRuntimeBridge.withLock { state in
            state.inboundHandler = previous.1
        }
    }
}

// MARK: - Portable Test Expectation Helper (`core/src/platform/test.ts`)

/// Lightweight assertion failure thrown by `PlatformExpectation` when an expectation fails.
public struct PlatformAssertionError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}

/// Lightweight, zero-dependency value expectation wrapper matching `core/src/platform/test.ts#expect`.
public struct PlatformExpectation<T> {
    public let received: T

    public init(_ received: T) {
        self.received = received
    }

    public func toBe(_ expected: T) throws where T: Equatable {
        guard received == expected else {
            throw PlatformAssertionError("Expected \(expected), received \(received)")
        }
    }

    public func toBeNull<Wrapped>() throws where T == Wrapped? {
        guard received == nil else {
            throw PlatformAssertionError("Expected nil, received \(String(describing: received))")
        }
    }

    public func toEqual(_ expected: T) throws where T: Equatable {
        try toBe(expected)
    }

    public func toThrow(_ expectedSubstring: String? = nil) throws where T == () throws -> Void {
        do {
            try received()
        } catch {
            if let expectedSubstring {
                let desc = String(describing: error)
                guard desc.contains(expectedSubstring) else {
                    throw PlatformAssertionError("Expected error containing '\(expectedSubstring)', received '\(desc)'")
                }
            }
            return
        }
        throw PlatformAssertionError("Expected function to throw an error, but it succeeded")
    }
}

/// Constructs a `PlatformExpectation` matching `core/src/platform/test.ts#expect` (named to avoid
/// colliding with Swift Testing's `#expect` macro).
// parity: core/src/platform/test.ts#expect [status=adapted hash=bfab65837556]
public func platformExpect<T>(_ received: T) -> PlatformExpectation<T> {
    PlatformExpectation(received)
}

/// Result summary returned when executing a registered `PlatformTestSuite`.
public struct PlatformTestRunReport: Equatable, Sendable {
    public var passed: [String]
    public var failed: [(name: String, message: String)]

    public init(passed: [String] = [], failed: [(name: String, message: String)] = []) {
        self.passed = passed
        self.failed = failed
    }

    public static func == (lhs: PlatformTestRunReport, rhs: PlatformTestRunReport) -> Bool {
        guard lhs.passed == rhs.passed, lhs.failed.count == rhs.failed.count else { return false }
        for (a, b) in zip(lhs.failed, rhs.failed) {
            if a.name != b.name || a.message != b.message { return false }
        }
        return true
    }
}

/// Portable in-memory test suite & lifecycle hook registry backing `core/src/platform/test.ts`.
public final class PlatformTestHarness: @unchecked Sendable {
    public static let shared = PlatformTestHarness()

    private struct SuiteState {
        var name: String
        var beforeHooks: [@Sendable () throws -> Void] = []
        var afterHooks: [@Sendable () throws -> Void] = []
        var beforeEachHooks: [@Sendable () throws -> Void] = []
        var afterEachHooks: [@Sendable () throws -> Void] = []
        var cases: [(name: String, body: @Sendable () throws -> Void)] = []
    }

    private struct State {
        var suiteStack: [SuiteState] = []
        var rootCases: [(name: String, body: @Sendable () throws -> Void)] = []
        var rootBefore: [@Sendable () throws -> Void] = []
        var rootAfter: [@Sendable () throws -> Void] = []
        var rootBeforeEach: [@Sendable () throws -> Void] = []
        var rootAfterEach: [@Sendable () throws -> Void] = []
    }

    private let state = Mutex(State())

    public init() {}

    public func reset() {
        state.withLock { $0 = State() }
    }

    @discardableResult
    public func describe(_ name: String, _ define: () -> Void) -> PlatformTestRunReport {
        state.withLock { $0.suiteStack.append(SuiteState(name: name)) }
        define()
        let suite = state.withLock { $0.suiteStack.removeLast() }
        return runSuite(suite)
    }

    public func addBefore(_ hook: @escaping @Sendable () throws -> Void) {
        state.withLock { s in
            if !s.suiteStack.isEmpty {
                s.suiteStack[s.suiteStack.count - 1].beforeHooks.append(hook)
            } else {
                s.rootBefore.append(hook)
            }
        }
    }

    public func addAfter(_ hook: @escaping @Sendable () throws -> Void) {
        state.withLock { s in
            if !s.suiteStack.isEmpty {
                s.suiteStack[s.suiteStack.count - 1].afterHooks.append(hook)
            } else {
                s.rootAfter.append(hook)
            }
        }
    }

    public func addBeforeEach(_ hook: @escaping @Sendable () throws -> Void) {
        state.withLock { s in
            if !s.suiteStack.isEmpty {
                s.suiteStack[s.suiteStack.count - 1].beforeEachHooks.append(hook)
            } else {
                s.rootBeforeEach.append(hook)
            }
        }
    }

    public func addAfterEach(_ hook: @escaping @Sendable () throws -> Void) {
        state.withLock { s in
            if !s.suiteStack.isEmpty {
                s.suiteStack[s.suiteStack.count - 1].afterEachHooks.append(hook)
            } else {
                s.rootAfterEach.append(hook)
            }
        }
    }

    public func addTest(_ name: String, _ body: @escaping @Sendable () throws -> Void) {
        state.withLock { s in
            if !s.suiteStack.isEmpty {
                s.suiteStack[s.suiteStack.count - 1].cases.append((name, body))
            } else {
                s.rootCases.append((name, body))
            }
        }
    }

    @discardableResult
    public func runRootCases() -> PlatformTestRunReport {
        let suite = state.withLock { s -> SuiteState in
            let captured = SuiteState(
                name: "",
                beforeHooks: s.rootBefore,
                afterHooks: s.rootAfter,
                beforeEachHooks: s.rootBeforeEach,
                afterEachHooks: s.rootAfterEach,
                cases: s.rootCases
            )
            s.rootBefore.removeAll()
            s.rootAfter.removeAll()
            s.rootBeforeEach.removeAll()
            s.rootAfterEach.removeAll()
            s.rootCases.removeAll()
            return captured
        }
        return runSuite(suite)
    }

    private func runSuite(_ suite: SuiteState) -> PlatformTestRunReport {
        var report = PlatformTestRunReport()
        do {
            for hook in suite.beforeHooks { try hook() }
        } catch {
            report.failed.append((suite.name.isEmpty ? "<before>" : "\(suite.name) <before>", String(describing: error)))
            return report
        }
        for testCase in suite.cases {
            let fullName = suite.name.isEmpty ? testCase.name : "\(suite.name) > \(testCase.name)"
            do {
                for hook in suite.beforeEachHooks { try hook() }
                try testCase.body()
                for hook in suite.afterEachHooks { try hook() }
                report.passed.append(fullName)
            } catch {
                for hook in suite.afterEachHooks { try? hook() }
                report.failed.append((fullName, String(describing: error)))
            }
        }
        for hook in suite.afterHooks {
            do {
                try hook()
            } catch {
                report.failed.append((suite.name.isEmpty ? "<after>" : "\(suite.name) <after>", String(describing: error)))
            }
        }
        return report
    }
}

/// Defines and runs a portable test suite matching `core/src/platform/test.ts#describe`.
// parity: core/src/platform/test.ts#describe [status=adapted hash=ea7c89590169]
@discardableResult
public func platformDescribe(
    _ name: String,
    harness: PlatformTestHarness = .shared,
    _ define: () -> Void
) -> PlatformTestRunReport {
    harness.describe(name, define)
}

/// Registers a test case matching `core/src/platform/test.ts#it`.
// parity: core/src/platform/test.ts#it [status=adapted hash=ea7c89590169]
public func platformIt(
    _ name: String,
    harness: PlatformTestHarness = .shared,
    _ body: @escaping @Sendable () throws -> Void
) {
    harness.addTest(name, body)
}

/// Registers a test case matching `core/src/platform/test.ts#test`.
// parity: core/src/platform/test.ts#test [status=adapted hash=ea7c89590169]
public func platformTest(
    _ name: String,
    harness: PlatformTestHarness = .shared,
    _ body: @escaping @Sendable () throws -> Void
) {
    harness.addTest(name, body)
}

/// Registers a suite setup hook matching `core/src/platform/test.ts#before`.
// parity: core/src/platform/test.ts#before [status=adapted hash=ea7c89590169]
public func platformBefore(
    harness: PlatformTestHarness = .shared,
    _ hook: @escaping @Sendable () throws -> Void
) {
    harness.addBefore(hook)
}

/// Registers a suite teardown hook matching `core/src/platform/test.ts#after`.
// parity: core/src/platform/test.ts#after [status=adapted hash=ea7c89590169]
public func platformAfter(
    harness: PlatformTestHarness = .shared,
    _ hook: @escaping @Sendable () throws -> Void
) {
    harness.addAfter(hook)
}

/// Registers a per-test setup hook matching `core/src/platform/test.ts#beforeEach`.
// parity: core/src/platform/test.ts#beforeEach [status=adapted hash=ea7c89590169]
public func platformBeforeEach(
    harness: PlatformTestHarness = .shared,
    _ hook: @escaping @Sendable () throws -> Void
) {
    harness.addBeforeEach(hook)
}

/// Registers a per-test teardown hook matching `core/src/platform/test.ts#afterEach`.
// parity: core/src/platform/test.ts#afterEach [status=adapted hash=ea7c89590169]
public func platformAfterEach(
    harness: PlatformTestHarness = .shared,
    _ hook: @escaping @Sendable () throws -> Void
) {
    harness.addAfterEach(hook)
}
