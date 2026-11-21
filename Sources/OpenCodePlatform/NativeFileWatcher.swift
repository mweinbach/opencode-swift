#if !os(WASI)
import Foundation
#endif
#if os(macOS)
import CoreServices
import CoreFoundation
import Dispatch
import Darwin
#elseif os(Linux)
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
#elseif os(Android)
#if canImport(Android)
import Android
#endif
#elseif os(Windows)
import WinSDK
#elseif canImport(Darwin)
import Darwin
#elseif os(FreeBSD) || os(OpenBSD)
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
#elseif os(WASI)
#if canImport(WASILibc)
import WASILibc
#endif
#endif
import Synchronization
import OpenCodeUtil

// MARK: - Public Event & Backend Types

/// Semantic filesystem mutation kind emitted by ``NativeFileWatcher``.
public enum NativeFileEventKind: String, Equatable, Hashable, Sendable, Codable {
    case created
    case modified
    case deleted
    case renamed
}

/// A single coalesced filesystem change event delivered by ``NativeFileWatcher``.
public struct NativeFileEvent: Equatable, Hashable, Sendable, Codable {
    public let path: String
    public let kind: NativeFileEventKind
    public let isDirectory: Bool

    public init(path: String, kind: NativeFileEventKind, isDirectory: Bool = false) {
        self.path = path
        self.kind = kind
        self.isDirectory = isDirectory
    }
}

/// Active OS filesystem watcher backend.
public enum NativeFileWatcherBackend: String, Equatable, Hashable, Sendable, Codable {
    case fsEvents = "fs-events"
    case inotify = "inotify"
    case windows = "windows"
    case kqueue = "kqueue"
    case polling = "polling"
    case fallback = "fallback"

    public static var current: NativeFileWatcherBackend {
        #if os(macOS)
        return .fsEvents
        #elseif (os(Linux) && (canImport(Glibc) || canImport(Musl))) || (os(Android) && canImport(Android))
        return .inotify
        #elseif os(Windows)
        return .windows
        #elseif (os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)) && canImport(Darwin)
        return .kqueue
        #elseif (os(FreeBSD) || os(OpenBSD)) && (canImport(Glibc) || canImport(Musl))
        return .kqueue
        #elseif os(WASI)
        #if canImport(WASILibc)
        return .polling
        #else
        return .fallback
        #endif
        #else
        return .polling
        #endif
    }
}

/// Errors thrown by ``NativeFileWatcher/start(onEvent:)``.
public enum NativeFileWatcherError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
    case pathNotFound(String)
    case notADirectory(String)
    case osFailure(String, errno: Int32? = nil)

    public var description: String {
        switch self {
        case .pathNotFound(let path):
            return "Watched path does not exist: \(path)"
        case .notADirectory(let path):
            return "Watched path is not a directory: \(path)"
        case let .osFailure(detail, code):
            if let code {
                return "NativeFileWatcher OS failure: \(detail) (errno=\(code))"
            }
            return "NativeFileWatcher OS failure: \(detail)"
        }
    }
}

// MARK: - NativeFileWatcher

/// Cross-platform OS filesystem watcher equivalent to `@parcel/watcher`.
///
/// - **macOS**: CoreServices `FSEventStream` (`kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer`)
///   scheduled on a dedicated serial `DispatchQueue`.
/// - **Linux / Android**: Native `inotify` (`inotify_init1(IN_NONBLOCK | IN_CLOEXEC)`) with recursive watch
///   registration, automatic watches on newly created subdirectories, and `poll()` + self-pipe wakeup on `stop()`.
/// - **Windows**: Native `ReadDirectoryChangesW` (`FILE_NOTIFY_CHANGE_FILE_NAME | DIR_NAME | LAST_WRITE | SIZE`)
///   with overlapped I/O and an explicit stop event handle wakeup.
/// - **iOS / tvOS / watchOS / visionOS / FreeBSD / OpenBSD**: Native `kqueue` (`EVFILT_VNODE`) with directory and
///   bounded file vnode watches and a self-pipe wakeup on `stop()`.
/// - **WASI / other platforms without a native watch API**: Cooperative `Task`-based polling fallback (using
///   `WASILibc` or `FileManager` directory snapshots), tearing down cleanly on `stop()`.
public final class NativeFileWatcher: Sendable {
    internal enum DriverOverride: Sendable {
        case automatic
        case kqueue
        case polling(intervalMs: Int)
    }

    public struct Configuration: Equatable, Hashable, Sendable {
        /// Directory names ignored at any depth when ``includeDefaultIgnores`` is `true`.
        public static let defaultIgnoredDirectories: [String] = [
            ".git",
            "node_modules",
            ".build",
            ".swiftpm",
        ]

        public let path: String
        public let recursive: Bool
        public let ignore: [String]
        public let includeDefaultIgnores: Bool
        public let coalesceIntervalMs: Int

        public init(
            path: String,
            recursive: Bool = true,
            ignore: [String] = [],
            includeDefaultIgnores: Bool = true,
            coalesceIntervalMs: Int = 25
        ) {
            self.path = path
            self.recursive = recursive
            self.ignore = ignore
            self.includeDefaultIgnores = includeDefaultIgnores
            self.coalesceIntervalMs = max(0, coalesceIntervalMs)
        }
    }

    /// Active backend selected at compile time for the host OS.
    public static var backend: NativeFileWatcherBackend { NativeFileWatcherBackend.current }

    /// Whether the current platform has a real native zero-polling OS filesystem watcher backend.
    public static var isNativelySupported: Bool {
        backend != .fallback && backend != .polling
    }

    /// Whether the current platform can deliver filesystem watch events (native OS API or polling fallback).
    public static var isSupported: Bool {
        backend != .fallback
    }

    public let configuration: Configuration

    /// Normalized root directory path requested by the caller.
    public var path: String { normalizedRoot }

    /// Whether the watcher is currently active.
    public var isRunning: Bool {
        state.withLock { $0.lifecycle == .running }
    }

    private enum Lifecycle: Sendable {
        case idle
        case starting
        case running
        case stopped
    }

    private struct State: Sendable {
        var lifecycle: Lifecycle = .idle
        var nextSubscriberID: UInt64 = 1
        var subscribers: [UInt64: AsyncStream<NativeFileEvent>.Continuation] = [:]
        var callbacks: [UInt64: @Sendable (NativeFileEvent) -> Void] = [:]
        var driver: (any NativeWatcherDriver)?
    }

    private let normalizedRoot: String
    private let canonicalRoot: String
    private let ignoreFilter: IgnoreFilter
    private let driverOverride: DriverOverride
    private let state = Mutex(State())

    public convenience init(configuration: Configuration) {
        self.init(configuration: configuration, driverOverride: .automatic)
    }

    internal init(configuration: Configuration, driverOverride: DriverOverride) {
        self.configuration = configuration
        self.driverOverride = driverOverride
        let normalized = Self.normalizePath(configuration.path)
        let canonical = Self.canonicalizePath(normalized)
        self.normalizedRoot = normalized
        self.canonicalRoot = canonical
        self.ignoreFilter = IgnoreFilter(
            requestedRoot: normalized,
            canonicalRoot: canonical,
            ignore: configuration.ignore,
            includeDefaultIgnores: configuration.includeDefaultIgnores
        )
    }

    public convenience init(
        path: String,
        recursive: Bool = true,
        ignore: [String] = [],
        includeDefaultIgnores: Bool = true,
        coalesceIntervalMs: Int = 25
    ) {
        self.init(
            configuration: Configuration(
                path: path,
                recursive: recursive,
                ignore: ignore,
                includeDefaultIgnores: includeDefaultIgnores,
                coalesceIntervalMs: coalesceIntervalMs
            )
        )
    }

    deinit {
        stop()
    }

    /// Stream of coalesced filesystem events.
    ///
    /// May be obtained before or after ``start(onEvent:)``. Multiple concurrent consumers are supported.
    /// All active streams finish cleanly when ``stop()`` is called.
    public var events: AsyncStream<NativeFileEvent> {
        AsyncStream { continuation in
            let registeredID: UInt64? = state.withLock { s in
                if s.lifecycle == .stopped {
                    return nil
                }
                let id = s.nextSubscriberID
                s.nextSubscriberID &+= 1
                s.subscribers[id] = continuation
                return id
            }
            guard let id = registeredID else {
                continuation.finish()
                return
            }
            continuation.onTermination = { [weak self] _ in
                self?.state.withLock { s in
                    _ = s.subscribers.removeValue(forKey: id)
                }
            }
        }
    }

    /// Starts native OS filesystem monitoring. Idempotent if already running.
    ///
    /// - Parameter onEvent: Optional callback invoked for every coalesced event in addition to ``events`` streams.
    public func start(onEvent: (@Sendable (NativeFileEvent) -> Void)? = nil) throws {
        enum StartAction {
            case alreadyRunning
            case proceed(callbackID: UInt64?, previousLifecycle: Lifecycle)
        }

        let action: StartAction = state.withLock { s in
            if s.lifecycle == .running || s.lifecycle == .starting {
                if let onEvent {
                    let id = s.nextSubscriberID
                    s.nextSubscriberID &+= 1
                    s.callbacks[id] = onEvent
                }
                return .alreadyRunning
            }
            let previous = s.lifecycle
            s.lifecycle = .starting
            var callbackID: UInt64?
            if let onEvent {
                let id = s.nextSubscriberID
                s.nextSubscriberID &+= 1
                s.callbacks[id] = onEvent
                callbackID = id
            }
            return .proceed(callbackID: callbackID, previousLifecycle: previous)
        }

        guard case let .proceed(addedCallbackID, previousLifecycle) = action else { return }

        // Refresh canonical path at start time in case the directory was created after init.
        let liveCanonical = Self.canonicalizePath(normalizedRoot)
        let liveFilter = IgnoreFilter(
            requestedRoot: normalizedRoot,
            canonicalRoot: liveCanonical,
            ignore: configuration.ignore,
            includeDefaultIgnores: configuration.includeDefaultIgnores
        )

        let emitBatch: @Sendable ([NativeFileEvent]) -> Void = { [weak self] batch in
            self?.deliver(batch)
        }

        let driver: any NativeWatcherDriver
        do {
            driver = try Self.makeDriver(
                requestedRoot: normalizedRoot,
                canonicalRoot: liveCanonical,
                recursive: configuration.recursive,
                ignoreFilter: liveFilter,
                coalesceIntervalMs: configuration.coalesceIntervalMs,
                driverOverride: driverOverride,
                emitBatch: emitBatch
            )
            try driver.start()
        } catch {
            state.withLock { s in
                if s.lifecycle == .starting {
                    s.lifecycle = previousLifecycle
                }
                if let addedCallbackID {
                    _ = s.callbacks.removeValue(forKey: addedCallbackID)
                }
            }
            throw error
        }

        let shouldStopImmediately: Bool = state.withLock { s in
            guard s.lifecycle == .starting else {
                return true
            }
            s.lifecycle = .running
            s.driver = driver
            return false
        }
        if shouldStopImmediately {
            driver.stop()
        }
    }

    /// Stops native OS filesystem monitoring, releases all OS handles/file descriptors, and finishes active streams.
    ///
    /// Safe to invoke multiple times, from any thread, or re-entrantly from inside an `onEvent` callback.
    public func stop() {
        let (driver, continuations): ((any NativeWatcherDriver)?, [AsyncStream<NativeFileEvent>.Continuation]) = state.withLock { s in
            let prevDriver = s.driver
            s.driver = nil
            s.lifecycle = .stopped
            let conts = Array(s.subscribers.values)
            s.subscribers.removeAll()
            s.callbacks.removeAll()
            return (prevDriver, conts)
        }

        driver?.stop()
        for continuation in continuations {
            continuation.finish()
        }
    }

    /// Evaluates whether `candidatePath` (absolute or relative to the watched root) is ignored.
    public func isIgnored(_ candidatePath: String) -> Bool {
        let liveCanonical = Self.canonicalizePath(normalizedRoot)
        let filter: IgnoreFilter
        if liveCanonical == canonicalRoot {
            filter = ignoreFilter
        } else {
            filter = IgnoreFilter(
                requestedRoot: normalizedRoot,
                canonicalRoot: liveCanonical,
                ignore: configuration.ignore,
                includeDefaultIgnores: configuration.includeDefaultIgnores
            )
        }
        let normalized = Self.normalizeSlashes(candidatePath)
        if Self.isAbsolutePath(normalized) {
            let cleanAbs = Self.collapsePath(normalized)
            if let mapped = Self.remapEventPath(cleanAbs, canonicalRoot: liveCanonical, requestedRoot: normalizedRoot) {
                return filter.shouldIgnore(
                    relativePath: mapped.relativePath,
                    reportedPath: mapped.reportedPath,
                    canonicalPath: cleanAbs
                )
            }
            return filter.shouldIgnore(
                relativePath: cleanAbs,
                reportedPath: cleanAbs,
                canonicalPath: cleanAbs
            )
        }
        let rel = Self.stripLeadingDotSlash(Self.stripTrailingSlashes(normalized))
        let reported = normalizedRoot == "/" ? "/\(rel)" : "\(normalizedRoot)/\(rel)"
        let canonical = liveCanonical == "/" ? "/\(rel)" : "\(liveCanonical)/\(rel)"
        return filter.shouldIgnore(relativePath: rel, reportedPath: reported, canonicalPath: canonical)
    }

    private func deliver(_ batch: [NativeFileEvent]) {
        guard !batch.isEmpty else { return }
        let (subscribers, callbacks): (
            [AsyncStream<NativeFileEvent>.Continuation],
            [@Sendable (NativeFileEvent) -> Void]
        ) = state.withLock { s in
            guard s.lifecycle == .running || s.lifecycle == .starting else { return ([], []) }
            return (Array(s.subscribers.values), Array(s.callbacks.values))
        }
        for event in batch {
            for continuation in subscribers {
                continuation.yield(event)
            }
            for callback in callbacks {
                callback(event)
            }
        }
    }

    private static func makeDriver(
        requestedRoot: String,
        canonicalRoot: String,
        recursive: Bool,
        ignoreFilter: IgnoreFilter,
        coalesceIntervalMs: Int,
        driverOverride: DriverOverride,
        emitBatch: @escaping @Sendable ([NativeFileEvent]) -> Void
    ) throws -> any NativeWatcherDriver {
        switch driverOverride {
        case .polling(let intervalMs):
            return PollingWatcherDriver(
                requestedRoot: requestedRoot,
                canonicalRoot: canonicalRoot,
                recursive: recursive,
                ignoreFilter: ignoreFilter,
                coalesceIntervalMs: coalesceIntervalMs,
                pollIntervalMs: intervalMs,
                emitBatch: emitBatch
            )
        case .kqueue:
            #if canImport(Darwin) || ((os(FreeBSD) || os(OpenBSD)) && (canImport(Glibc) || canImport(Musl)))
            return KqueueDriver(
                requestedRoot: requestedRoot,
                canonicalRoot: canonicalRoot,
                recursive: recursive,
                ignoreFilter: ignoreFilter,
                coalesceIntervalMs: coalesceIntervalMs,
                emitBatch: emitBatch
            )
            #else
            return PollingWatcherDriver(
                requestedRoot: requestedRoot,
                canonicalRoot: canonicalRoot,
                recursive: recursive,
                ignoreFilter: ignoreFilter,
                coalesceIntervalMs: coalesceIntervalMs,
                pollIntervalMs: 200,
                emitBatch: emitBatch
            )
            #endif
        case .automatic:
            break
        }
        #if os(macOS)
        return FSEventsDriver(
            requestedRoot: requestedRoot,
            canonicalRoot: canonicalRoot,
            recursive: recursive,
            ignoreFilter: ignoreFilter,
            coalesceIntervalMs: coalesceIntervalMs,
            emitBatch: emitBatch
        )
        #elseif (os(Linux) && (canImport(Glibc) || canImport(Musl))) || (os(Android) && canImport(Android))
        return InotifyDriver(
            requestedRoot: requestedRoot,
            canonicalRoot: canonicalRoot,
            recursive: recursive,
            ignoreFilter: ignoreFilter,
            coalesceIntervalMs: coalesceIntervalMs,
            emitBatch: emitBatch
        )
        #elseif os(Windows)
        return WindowsDirectoryWatcherDriver(
            requestedRoot: requestedRoot,
            canonicalRoot: canonicalRoot,
            recursive: recursive,
            ignoreFilter: ignoreFilter,
            coalesceIntervalMs: coalesceIntervalMs,
            emitBatch: emitBatch
        )
        #elseif (os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)) && canImport(Darwin)
        return KqueueDriver(
            requestedRoot: requestedRoot,
            canonicalRoot: canonicalRoot,
            recursive: recursive,
            ignoreFilter: ignoreFilter,
            coalesceIntervalMs: coalesceIntervalMs,
            emitBatch: emitBatch
        )
        #elseif (os(FreeBSD) || os(OpenBSD)) && (canImport(Glibc) || canImport(Musl))
        return KqueueDriver(
            requestedRoot: requestedRoot,
            canonicalRoot: canonicalRoot,
            recursive: recursive,
            ignoreFilter: ignoreFilter,
            coalesceIntervalMs: coalesceIntervalMs,
            emitBatch: emitBatch
        )
        #elseif os(WASI)
        #if canImport(WASILibc)
        return PollingWatcherDriver(
            requestedRoot: requestedRoot,
            canonicalRoot: canonicalRoot,
            recursive: recursive,
            ignoreFilter: ignoreFilter,
            coalesceIntervalMs: coalesceIntervalMs,
            pollIntervalMs: 250,
            emitBatch: emitBatch
        )
        #else
        return FallbackWatcherDriver(
            requestedRoot: requestedRoot,
            canonicalRoot: canonicalRoot,
            recursive: recursive,
            ignoreFilter: ignoreFilter,
            coalesceIntervalMs: coalesceIntervalMs,
            emitBatch: emitBatch
        )
        #endif
        #else
        return PollingWatcherDriver(
            requestedRoot: requestedRoot,
            canonicalRoot: canonicalRoot,
            recursive: recursive,
            ignoreFilter: ignoreFilter,
            coalesceIntervalMs: coalesceIntervalMs,
            pollIntervalMs: 250,
            emitBatch: emitBatch
        )
        #endif
    }

    // MARK: - Cross-Platform Path Helpers

    internal static func normalizeSlashes(_ path: String) -> String {
        var out = ""
        out.reserveCapacity(path.count)
        for ch in path {
            out.append(ch == "\\" ? "/" : ch)
        }
        return out
    }

    internal static func isWindowsDrivePath(_ path: String) -> Bool {
        let chars = Array(path)
        guard chars.count >= 2, let ascii = chars[0].asciiValue else { return false }
        let isAlpha = (ascii >= 65 && ascii <= 90) || (ascii >= 97 && ascii <= 122)
        return isAlpha && chars[1] == ":"
    }

    internal static func isAbsolutePath(_ path: String) -> Bool {
        path.hasPrefix("/") || isWindowsDrivePath(path)
    }

    internal static func stripTrailingSlashes(_ path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") {
            if p.count == 3 && isWindowsDrivePath(p) { break }
            p.removeLast()
        }
        return p
    }

    internal static func stripLeadingDotSlash(_ path: String) -> String {
        var p = path
        while p.hasPrefix("./") {
            p.removeFirst(2)
        }
        return p
    }

    internal static func collapsePath(_ raw: String) -> String {
        let slashed = normalizeSlashes(raw)
        var prefix = ""
        var remainder = slashed

        if isWindowsDrivePath(slashed) {
            let idx = slashed.index(slashed.startIndex, offsetBy: 2)
            prefix = String(slashed[..<idx]).uppercased()
            let rest = String(slashed[idx...])
            if rest.hasPrefix("/") {
                prefix += "/"
                remainder = String(rest.dropFirst())
            } else {
                prefix += "/"
                remainder = rest
            }
        } else if slashed.hasPrefix("/") {
            prefix = "/"
            remainder = String(slashed.dropFirst())
        }

        var parts: [String] = []
        for seg in remainder.split(separator: "/") {
            if seg.isEmpty || seg == "." { continue }
            if seg == ".." {
                if !parts.isEmpty { parts.removeLast() }
            } else {
                parts.append(String(seg))
            }
        }
        let joined = parts.joined(separator: "/")
        if prefix.isEmpty {
            return joined.isEmpty ? "." : joined
        }
        return stripTrailingSlashes(prefix + joined)
    }

    internal static func normalizePath(_ raw: String) -> String {
        let slashed = normalizeSlashes(FSPathUtil.windowsPath(raw))
        if isAbsolutePath(slashed) {
            return collapsePath(slashed)
        }
        #if os(WASI)
        return collapsePath("/" + slashed)
        #else
        let cwd = normalizeSlashes(FileManager.default.currentDirectoryPath)
        let joined = cwd.hasSuffix("/") ? cwd + slashed : "\(cwd)/\(slashed)"
        return collapsePath(joined)
        #endif
    }

    internal static func canonicalizePath(_ normalized: String) -> String {
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl) || canImport(Android)
        if let resolved = realpath(normalized, nil) {
            defer { free(resolved) }
            return stripTrailingSlashes(normalizeSlashes(String(cString: resolved)))
        }
        return normalized
        #elseif os(Windows)
        let wideInput = Array(normalized.utf16) + [0]
        let required = wideInput.withUnsafeBufferPointer { ptr in
            GetFullPathNameW(ptr.baseAddress, 0, nil, nil)
        }
        guard required > 0 else { return normalized }
        var buffer = [WCHAR](repeating: 0, count: Int(required))
        let written = wideInput.withUnsafeBufferPointer { inPtr in
            buffer.withUnsafeMutableBufferPointer { outPtr in
                GetFullPathNameW(inPtr.baseAddress, required, outPtr.baseAddress, nil)
            }
        }
        guard written > 0 else { return normalized }
        let decoded = String(decoding: buffer[0..<Int(written)], as: UTF16.self)
        return collapsePath(decoded)
        #else
        return normalized
        #endif
    }

    internal static func remapEventPath(
        _ rawEventPath: String,
        canonicalRoot: String,
        requestedRoot: String
    ) -> (reportedPath: String, relativePath: String)? {
        let clean = stripTrailingSlashes(normalizeSlashes(rawEventPath))

        if let rel = relativeSuffix(of: clean, under: canonicalRoot) {
            let reported = joinPath(requestedRoot, rel)
            return (reported, rel)
        }
        if canonicalRoot != requestedRoot, let rel = relativeSuffix(of: clean, under: requestedRoot) {
            let reported = joinPath(requestedRoot, rel)
            return (reported, rel)
        }
        return nil
    }

    internal static func relativeSuffix(of path: String, under root: String) -> String? {
        if path == root { return "" }
        if root == "/" {
            guard path.hasPrefix("/") else { return nil }
            return String(path.dropFirst())
        }
        if root.hasSuffix("/") {
            guard path.hasPrefix(root) else { return nil }
            return String(path.dropFirst(root.count))
        }
        let prefix = root + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    internal static func joinPath(_ base: String, _ relative: String) -> String {
        if relative.isEmpty { return base }
        if base == "/" { return "/\(relative)" }
        if base.hasSuffix("/") { return base + relative }
        return "\(base)/\(relative)"
    }
}

// MARK: - Ignore Filter

extension NativeFileWatcher {
    internal struct IgnoreFilter: Sendable {
        private enum CompiledRule: Sendable {
            case absoluteLiteral(requested: String, canonical: String)
            case relativeLiteral(String)
            case glob(pattern: String, isAbsolute: Bool, isNegated: Bool)
        }

        private let defaultIgnoredNames: Set<String>
        private let rules: [CompiledRule]

        init(
            requestedRoot: String,
            canonicalRoot: String,
            ignore: [String],
            includeDefaultIgnores: Bool
        ) {
            self.defaultIgnoredNames = includeDefaultIgnores
                ? Set(Configuration.defaultIgnoredDirectories)
                : []

            var compiled: [CompiledRule] = []
            compiled.reserveCapacity(ignore.count)
            for raw in ignore {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let normalized = NativeFileWatcher.stripTrailingSlashes(NativeFileWatcher.normalizeSlashes(trimmed))
                guard !normalized.isEmpty else { continue }

                if Self.containsGlobSyntax(normalized) {
                    let isNegated = normalized.hasPrefix("!") && !normalized.hasPrefix("!(")
                    let isAbs = NativeFileWatcher.isAbsolutePath(normalized)
                    compiled.append(.glob(pattern: normalized, isAbsolute: isAbs, isNegated: isNegated))
                } else if NativeFileWatcher.isAbsolutePath(normalized) {
                    let collapsed = NativeFileWatcher.collapsePath(normalized)
                    let canonical = NativeFileWatcher.canonicalizePath(collapsed)
                    compiled.append(.absoluteLiteral(requested: collapsed, canonical: canonical))
                } else {
                    let cleanRel = NativeFileWatcher.stripLeadingDotSlash(normalized)
                    if !cleanRel.isEmpty {
                        compiled.append(.relativeLiteral(cleanRel))
                    }
                }
            }
            self.rules = compiled
            _ = (requestedRoot, canonicalRoot)
        }

        func shouldIgnore(relativePath: String, reportedPath: String, canonicalPath: String) -> Bool {
            guard !relativePath.isEmpty else { return false }

            // 1. Built-in ignored directory names at any depth (.git, node_modules, .build, .swiftpm)
            if !defaultIgnoredNames.isEmpty {
                for segment in relativePath.split(separator: "/") {
                    if defaultIgnoredNames.contains(String(segment)) {
                        return true
                    }
                }
            }

            // 2. Caller-provided ignore rules (literal subpaths, absolute paths, and glob patterns)
            for rule in rules {
                switch rule {
                case let .absoluteLiteral(requested, canonical):
                    if FSPathUtil.contains(parent: requested, child: reportedPath)
                        || FSPathUtil.contains(parent: canonical, child: canonicalPath)
                        || FSPathUtil.contains(parent: requested, child: canonicalPath)
                        || FSPathUtil.contains(parent: canonical, child: reportedPath)
                    {
                        return true
                    }

                case .relativeLiteral(let subpath):
                    if relativePath == subpath || relativePath.hasPrefix(subpath + "/") {
                        return true
                    }

                case let .glob(pattern, isAbsolute, isNegated):
                    if isAbsolute {
                        if Glob.match(pattern, filepath: reportedPath, dot: true)
                            || Glob.match(pattern, filepath: canonicalPath, dot: true)
                        {
                            return true
                        }
                    } else {
                        if Glob.match(pattern, filepath: relativePath, dot: true) {
                            return true
                        }
                        // Also check directory ancestor prefixes for positive globs so ignoring a directory
                        // glob (e.g. "*.cache" or "**/dist") excludes descendants inside that directory.
                        if !isNegated, relativePath.contains("/") {
                            var searchEnd = relativePath.startIndex
                            while let slash = relativePath[searchEnd...].firstIndex(of: "/") {
                                let ancestor = String(relativePath[..<slash])
                                if !ancestor.isEmpty && Glob.match(pattern, filepath: ancestor, dot: true) {
                                    return true
                                }
                                searchEnd = relativePath.index(after: slash)
                            }
                        }
                    }
                }
            }
            return false
        }

        private static func containsGlobSyntax(_ pattern: String) -> Bool {
            for ch in pattern {
                if ch == "*" || ch == "?" || ch == "[" || ch == "{" || ch == "!" {
                    return true
                }
            }
            if pattern.contains("@(") || pattern.contains("+(") {
                return true
            }
            return false
        }
    }
}

// MARK: - Burst Event Coalescer

/// Coalesces rapid bursts of events for the same path while preserving deterministic delivery order.
internal struct NativeFileEventCoalescer: Sendable {
    private var order: [String] = []
    private var eventsByPath: [String: NativeFileEvent] = [:]

    var isEmpty: Bool { eventsByPath.isEmpty }

    mutating func clear() {
        order.removeAll(keepingCapacity: false)
        eventsByPath.removeAll(keepingCapacity: false)
    }

    mutating func push(_ event: NativeFileEvent) {
        guard let existing = eventsByPath[event.path] else {
            order.append(event.path)
            eventsByPath[event.path] = event
            return
        }

        if let mergedKind = Self.merge(previous: existing.kind, incoming: event.kind) {
            eventsByPath[event.path] = NativeFileEvent(
                path: event.path,
                kind: mergedKind,
                isDirectory: event.isDirectory || existing.isDirectory
            )
        } else {
            // Transient create followed immediately by delete within the same burst cancels out.
            eventsByPath.removeValue(forKey: event.path)
            order.removeAll { $0 == event.path }
        }
    }

    mutating func drain() -> [NativeFileEvent] {
        guard !eventsByPath.isEmpty else { return [] }
        var out: [NativeFileEvent] = []
        out.reserveCapacity(order.count)
        for path in order {
            if let event = eventsByPath[path] {
                out.append(event)
            }
        }
        order.removeAll(keepingCapacity: true)
        eventsByPath.removeAll(keepingCapacity: true)
        return out
    }

    internal static func merge(
        previous: NativeFileEventKind,
        incoming: NativeFileEventKind
    ) -> NativeFileEventKind? {
        switch (previous, incoming) {
        case (.created, .created): return .created
        case (.created, .modified): return .created
        case (.created, .renamed): return .renamed
        case (.created, .deleted): return nil

        case (.modified, .created): return .modified
        case (.modified, .modified): return .modified
        case (.modified, .renamed): return .renamed
        case (.modified, .deleted): return .deleted

        case (.deleted, .created): return .modified
        case (.deleted, .modified): return .modified
        case (.deleted, .renamed): return .renamed
        case (.deleted, .deleted): return .deleted

        case (.renamed, .created): return .renamed
        case (.renamed, .modified): return .renamed
        case (.renamed, .renamed): return .renamed
        case (.renamed, .deleted): return .deleted
        }
    }
}

// MARK: - Internal Driver Protocol

private protocol NativeWatcherDriver: Sendable {
    func start() throws
    func stop()
}

// MARK: - macOS CoreServices FSEventStream Backend

#if os(macOS)

private func fsEventsStreamCallback(
    _ streamRef: ConstFSEventStreamRef,
    _ clientCallBackInfo: UnsafeMutableRawPointer?,
    _ numEvents: Int,
    _ eventPaths: UnsafeMutableRawPointer,
    _ eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    _ eventIds: UnsafePointer<FSEventStreamEventId>
) {
    _ = streamRef
    guard let info = clientCallBackInfo, numEvents > 0 else { return }
    let driver = Unmanaged<FSEventsDriver>.fromOpaque(info).takeUnretainedValue()
    driver.handleFSEvents(
        numEvents: numEvents,
        eventPaths: eventPaths,
        eventFlags: eventFlags,
        eventIds: eventIds
    )
}

private final class FSEventsDriver: NativeWatcherDriver, @unchecked Sendable {
    private struct KnownStat {
        var ino: UInt64
        var mtimeSec: Int
        var mtimeNsec: Int
        var ctimeSec: Int
        var ctimeNsec: Int
        var size: Int64
        var fromSeed: Bool

        func matchesMetadata(_ other: KnownStat) -> Bool {
            ino == other.ino
                && mtimeSec == other.mtimeSec
                && mtimeNsec == other.mtimeNsec
                && ctimeSec == other.ctimeSec
                && ctimeNsec == other.ctimeNsec
                && size == other.size
        }
    }

    private static let maxTrackedEntries = 16_384

    private let requestedRoot: String
    private let canonicalRoot: String
    private let recursive: Bool
    private let ignoreFilter: NativeFileWatcher.IgnoreFilter
    private let coalesceIntervalMs: Int
    private let emitBatch: @Sendable ([NativeFileEvent]) -> Void

    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let stoppedFlag = Mutex(false)

    // Guarded strictly by `queue` (never accessed from any other thread once started).
    private var stream: FSEventStreamRef?
    private var stoppedOnQueue: Bool = false
    private var knownStats: [String: KnownStat] = [:]
    private var knownOrder: [String] = []
    private var coalescer = NativeFileEventCoalescer()
    private var pendingFlush: DispatchWorkItem?

    init(
        requestedRoot: String,
        canonicalRoot: String,
        recursive: Bool,
        ignoreFilter: NativeFileWatcher.IgnoreFilter,
        coalesceIntervalMs: Int,
        emitBatch: @escaping @Sendable ([NativeFileEvent]) -> Void
    ) {
        self.requestedRoot = requestedRoot
        self.canonicalRoot = canonicalRoot
        self.recursive = recursive
        self.ignoreFilter = ignoreFilter
        self.coalesceIntervalMs = coalesceIntervalMs
        self.emitBatch = emitBatch
        self.queue = DispatchQueue(
            label: "ai.opencode.native-file-watcher.fsevents",
            qos: .utility
        )
        self.queue.setSpecific(key: queueKey, value: 1)
    }

    deinit {
        stop()
    }

    func start() throws {
        var st = Darwin.stat()
        guard Darwin.fstatat(AT_FDCWD, canonicalRoot, &st, 0) == 0 else {
            let err = errno
            if err == ENOENT || err == ENOTDIR {
                throw NativeFileWatcherError.pathNotFound(requestedRoot)
            }
            throw NativeFileWatcherError.osFailure("stat failed for '\(requestedRoot)'", errno: err)
        }
        guard (st.st_mode & S_IFMT) == S_IFDIR else {
            throw NativeFileWatcherError.notADirectory(requestedRoot)
        }

        // Seed known entry stats up to maxTrackedEntries so pre-existing files modified right
        // after start() are accurately classified as `.modified` even if FSEvents carries sticky
        // `ItemCreated` flags across APFS coalescing windows.
        seedKnownStats(directory: canonicalRoot)

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: { ptr in
                guard let ptr else { return nil }
                _ = Unmanaged<FSEventsDriver>.fromOpaque(ptr).retain()
                return ptr
            },
            release: { ptr in
                guard let ptr else { return }
                Unmanaged<FSEventsDriver>.fromOpaque(ptr).release()
            },
            copyDescription: nil
        )

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
        )
        let latency: CFTimeInterval = coalesceIntervalMs > 0
            ? min(0.02, Double(coalesceIntervalMs) / 1_000.0)
            : 0.0
        let pathsToWatch = [canonicalRoot as CFString] as CFArray

        guard let createdStream = FSEventStreamCreate(
            kCFAllocatorDefault,
            fsEventsStreamCallback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            throw NativeFileWatcherError.osFailure("FSEventStreamCreate failed for '\(requestedRoot)'")
        }

        FSEventStreamSetDispatchQueue(createdStream, queue)
        guard FSEventStreamStart(createdStream) else {
            FSEventStreamInvalidate(createdStream)
            FSEventStreamRelease(createdStream)
            throw NativeFileWatcherError.osFailure("FSEventStreamStart failed for '\(requestedRoot)'")
        }

        queue.sync {
            self.stream = createdStream
        }
    }

    func stop() {
        stoppedFlag.withLock { $0 = true }

        let teardown: () -> Void = {
            guard !self.stoppedOnQueue else { return }
            self.stoppedOnQueue = true
            self.pendingFlush?.cancel()
            self.pendingFlush = nil
            self.coalescer.clear()
            if let s = self.stream {
                self.stream = nil
                FSEventStreamStop(s)
                FSEventStreamInvalidate(s)
                FSEventStreamRelease(s)
            }
        }

        if DispatchQueue.getSpecific(key: queueKey) != nil {
            teardown()
        } else {
            queue.sync {
                teardown()
            }
        }
    }

    func handleFSEvents(
        numEvents: Int,
        eventPaths: UnsafeMutableRawPointer,
        eventFlags: UnsafePointer<FSEventStreamEventFlags>,
        eventIds: UnsafePointer<FSEventStreamEventId>
    ) {
        _ = eventIds
        if stoppedOnQueue || stoppedFlag.withLock({ $0 }) { return }

        let cPaths = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
        var pushedAny = false

        for idx in 0..<numEvents {
            if stoppedOnQueue || stoppedFlag.withLock({ $0 }) { return }

            let flags = eventFlags[idx]
            if (flags & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone)) != 0 {
                continue
            }
            if (flags & FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped)) != 0 {
                continue
            }

            let rawPath = String(cString: cPaths[idx])
            guard let mapped = NativeFileWatcher.remapEventPath(
                rawPath,
                canonicalRoot: canonicalRoot,
                requestedRoot: requestedRoot
            ) else {
                continue
            }

            // Skip root directory startup/metadata chatter unless the root itself disappeared.
            if mapped.relativePath.isEmpty {
                if (flags & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)) != 0 {
                    var st = Darwin.stat()
                    if Darwin.lstat(canonicalRoot, &st) != 0 {
                        coalescer.push(NativeFileEvent(path: requestedRoot, kind: .deleted, isDirectory: true))
                        pushedAny = true
                    }
                }
                continue
            }

            // Non-recursive watches only report direct children of the watched directory.
            if !recursive && mapped.relativePath.contains("/") {
                continue
            }

            if ignoreFilter.shouldIgnore(
                relativePath: mapped.relativePath,
                reportedPath: mapped.reportedPath,
                canonicalPath: rawPath
            ) {
                continue
            }

            if let event = classifyFSEvent(rawPath: rawPath, reportedPath: mapped.reportedPath, flags: flags) {
                coalescer.push(event)
                pushedAny = true
            }
        }

        guard pushedAny else { return }

        if coalesceIntervalMs <= 0 {
            flushCoalescerOnQueue()
        } else if pendingFlush == nil {
            let work = DispatchWorkItem { [weak self] in
                self?.flushCoalescerOnQueue()
            }
            pendingFlush = work
            queue.asyncAfter(deadline: .now() + .milliseconds(coalesceIntervalMs), execute: work)
        }
    }

    private func flushCoalescerOnQueue() {
        pendingFlush = nil
        if stoppedOnQueue || stoppedFlag.withLock({ $0 }) {
            coalescer.clear()
            return
        }
        let batch = coalescer.drain()
        guard !batch.isEmpty else { return }
        emitBatch(batch)
    }

    private func classifyFSEvent(
        rawPath: String,
        reportedPath: String,
        flags: FSEventStreamEventFlags
    ) -> NativeFileEvent? {
        let isRemovedFlag = (flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved)) != 0
        let isRenamedFlag = (flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed)) != 0
        let isCreatedFlag = (flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)) != 0
        let isModifiedFlag = (flags & FSEventStreamEventFlags(
            kFSEventStreamEventFlagItemModified
                | kFSEventStreamEventFlagItemInodeMetaMod
                | kFSEventStreamEventFlagItemFinderInfoMod
                | kFSEventStreamEventFlagItemChangeOwner
                | kFSEventStreamEventFlagItemXattrMod
        )) != 0
        let flagIsDir = (flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir)) != 0
        let flagIsFile = (flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile)) != 0

        var st = Darwin.stat()
        let exists = Darwin.lstat(rawPath, &st) == 0
        let isDir = exists ? ((st.st_mode & S_IFMT) == S_IFDIR) : (flagIsDir && !flagIsFile)

        if !exists {
            forgetKnownStat(for: reportedPath, isDirectory: isDir)
            if isRemovedFlag || isRenamedFlag || isCreatedFlag {
                return NativeFileEvent(path: reportedPath, kind: .deleted, isDirectory: isDir)
            }
            return nil
        }

        let currentStat = KnownStat(
            ino: UInt64(st.st_ino),
            mtimeSec: st.st_mtimespec.tv_sec,
            mtimeNsec: st.st_mtimespec.tv_nsec,
            ctimeSec: st.st_ctimespec.tv_sec,
            ctimeNsec: st.st_ctimespec.tv_nsec,
            size: Int64(st.st_size),
            fromSeed: false
        )
        let previous = knownStats[reportedPath]

        // Suppress stale delayed startup events for entries that existed unchanged prior to start().
        if let prev = previous, prev.fromSeed, prev.matchesMetadata(currentStat),
           !isRenamedFlag, !isRemovedFlag
        {
            recordKnownStat(currentStat, for: reportedPath)
            return nil
        }

        recordKnownStat(currentStat, for: reportedPath)

        // Rename destination (or atomic replace with a new inode).
        if isRenamedFlag {
            if let prev = previous, prev.ino == currentStat.ino, isModifiedFlag {
                return NativeFileEvent(path: reportedPath, kind: .modified, isDirectory: isDir)
            }
            return NativeFileEvent(path: reportedPath, kind: .renamed, isDirectory: isDir)
        }

        // Removed flag while path still exists implies remove + recreate.
        if isRemovedFlag {
            if isCreatedFlag {
                return NativeFileEvent(path: reportedPath, kind: .created, isDirectory: isDir)
            }
            return NativeFileEvent(path: reportedPath, kind: .modified, isDirectory: isDir)
        }

        if isCreatedFlag {
            if let prev = previous, prev.ino == currentStat.ino {
                // Sticky macOS FSEvents ItemCreated bit on an already-known file -> modification.
                if isModifiedFlag || !prev.matchesMetadata(currentStat) {
                    return NativeFileEvent(path: reportedPath, kind: .modified, isDirectory: isDir)
                }
                return nil
            }
            return NativeFileEvent(path: reportedPath, kind: .created, isDirectory: isDir)
        }

        if isModifiedFlag {
            return NativeFileEvent(path: reportedPath, kind: .modified, isDirectory: isDir)
        }

        return nil
    }

    private func recordKnownStat(_ stat: KnownStat, for path: String) {
        if knownStats[path] == nil {
            if knownStats.count >= Self.maxTrackedEntries {
                let evictCount = Self.maxTrackedEntries / 4
                let removeSlice = knownOrder.prefix(evictCount)
                for key in removeSlice {
                    knownStats.removeValue(forKey: key)
                }
                knownOrder.removeFirst(min(evictCount, knownOrder.count))
            }
            knownOrder.append(path)
        }
        knownStats[path] = stat
    }

    private func forgetKnownStat(for path: String, isDirectory: Bool) {
        knownStats.removeValue(forKey: path)
        if isDirectory {
            let prefix = path.hasSuffix("/") ? path : path + "/"
            let staleKeys = knownStats.keys.filter { $0.hasPrefix(prefix) }
            for key in staleKeys {
                knownStats.removeValue(forKey: key)
            }
        }
    }

    private func seedKnownStats(directory: String) {
        var stack: [String] = [directory]
        while let currentDir = stack.popLast(), knownStats.count < Self.maxTrackedEntries {
            guard let dirHandle = Darwin.opendir(currentDir) else { continue }
            defer { Darwin.closedir(dirHandle) }

            while knownStats.count < Self.maxTrackedEntries, let entryPtr = Darwin.readdir(dirHandle) {
                var entry = entryPtr.pointee
                let name = withUnsafePointer(to: &entry.d_name) { ptr in
                    ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { cStr in
                        String(cString: cStr)
                    }
                }
                if name == "." || name == ".." { continue }

                let rawChild = NativeFileWatcher.joinPath(currentDir, name)
                guard let mapped = NativeFileWatcher.remapEventPath(
                    rawChild,
                    canonicalRoot: canonicalRoot,
                    requestedRoot: requestedRoot
                ) else {
                    continue
                }
                if ignoreFilter.shouldIgnore(
                    relativePath: mapped.relativePath,
                    reportedPath: mapped.reportedPath,
                    canonicalPath: rawChild
                ) {
                    continue
                }

                var st = Darwin.stat()
                guard Darwin.lstat(rawChild, &st) == 0 else { continue }
                let stat = KnownStat(
                    ino: UInt64(st.st_ino),
                    mtimeSec: st.st_mtimespec.tv_sec,
                    mtimeNsec: st.st_mtimespec.tv_nsec,
                    ctimeSec: st.st_ctimespec.tv_sec,
                    ctimeNsec: st.st_ctimespec.tv_nsec,
                    size: Int64(st.st_size),
                    fromSeed: true
                )
                recordKnownStat(stat, for: mapped.reportedPath)

                if recursive && (st.st_mode & S_IFMT) == S_IFDIR {
                    stack.append(rawChild)
                }
            }
        }
    }
}

#elseif (os(Linux) && (canImport(Glibc) || canImport(Musl))) || (os(Android) && canImport(Android))

// MARK: - Linux & Android Native inotify + poll() + Self-Pipe Backend

private final class InotifyDriver: NativeWatcherDriver, @unchecked Sendable {
    private static let watchMask: UInt32 = UInt32(
        IN_CREATE
            | IN_MODIFY
            | IN_CLOSE_WRITE
            | IN_DELETE
            | IN_MOVED_FROM
            | IN_MOVED_TO
            | IN_DELETE_SELF
            | IN_MOVE_SELF
            | IN_ATTRIB
    )

    private struct LifecycleState {
        var started: Bool = false
        var stopRequested: Bool = false
        var readerExited: Bool = false
        var wakeWriteFD: Int32 = -1
        var readerThread: pthread_t?
    }

    private let requestedRoot: String
    private let canonicalRoot: String
    private let recursive: Bool
    private let ignoreFilter: NativeFileWatcher.IgnoreFilter
    private let coalesceIntervalMs: Int
    private let emitBatch: @Sendable ([NativeFileEvent]) -> Void

    private let cond = NSCondition()
    private var lifecycle = LifecycleState()

    // Owned strictly by the background reader thread once started.
    private var inotifyFD: Int32 = -1
    private var wakeReadFD: Int32 = -1
    private var wdToPath: [Int32: String] = [:]
    private var pathToWd: [String: Int32] = [:]
    private var coalescer = NativeFileEventCoalescer()

    init(
        requestedRoot: String,
        canonicalRoot: String,
        recursive: Bool,
        ignoreFilter: NativeFileWatcher.IgnoreFilter,
        coalesceIntervalMs: Int,
        emitBatch: @escaping @Sendable ([NativeFileEvent]) -> Void
    ) {
        self.requestedRoot = requestedRoot
        self.canonicalRoot = canonicalRoot
        self.recursive = recursive
        self.ignoreFilter = ignoreFilter
        self.coalesceIntervalMs = coalesceIntervalMs
        self.emitBatch = emitBatch
    }

    deinit {
        stop()
    }

    func start() throws {
        var st = stat()
        guard fstatat(AT_FDCWD, canonicalRoot, &st, 0) == 0 else {
            let err = errno
            if err == ENOENT || err == ENOTDIR {
                throw NativeFileWatcherError.pathNotFound(requestedRoot)
            }
            throw NativeFileWatcherError.osFailure("stat failed for '\(requestedRoot)'", errno: err)
        }
        guard (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
            throw NativeFileWatcherError.notADirectory(requestedRoot)
        }

        let fd = inotify_init1(Int32(IN_NONBLOCK) | Int32(IN_CLOEXEC))
        guard fd >= 0 else {
            throw NativeFileWatcherError.osFailure("inotify_init1 failed", errno: errno)
        }

        var pipeFDs: [Int32] = [-1, -1]
        guard pipe(&pipeFDs) == 0 else {
            let err = errno
            _ = close(fd)
            throw NativeFileWatcherError.osFailure("pipe failed", errno: err)
        }
        for pfd in pipeFDs {
            _ = fcntl(pfd, F_SETFD, FD_CLOEXEC)
            let fl = fcntl(pfd, F_GETFL, 0)
            if fl >= 0 {
                _ = fcntl(pfd, F_SETFL, fl | O_NONBLOCK)
            }
        }

        self.inotifyFD = fd
        self.wakeReadFD = pipeFDs[0]
        let writeFD = pipeFDs[1]

        do {
            try registerWatchTree(at: canonicalRoot, emitInitialEntries: false)
        } catch {
            _ = close(fd)
            _ = close(pipeFDs[0])
            _ = close(writeFD)
            self.inotifyFD = -1
            self.wakeReadFD = -1
            self.wdToPath.removeAll()
            self.pathToWd.removeAll()
            throw error
        }

        cond.lock()
        lifecycle.started = true
        lifecycle.stopRequested = false
        lifecycle.readerExited = false
        lifecycle.wakeWriteFD = writeFD
        cond.unlock()

        Thread.detachNewThread { [self] in
            self.runEventLoop()
        }
    }

    func stop() {
        cond.lock()
        guard lifecycle.started else {
            cond.unlock()
            return
        }
        lifecycle.stopRequested = true
        if lifecycle.wakeWriteFD >= 0 {
            var byte: UInt8 = 1
            _ = write(lifecycle.wakeWriteFD, &byte, 1)
        }
        let onReaderThread: Bool
        if let readerTid = lifecycle.readerThread {
            onReaderThread = pthread_equal(pthread_self(), readerTid) != 0
        } else {
            onReaderThread = false
        }
        if onReaderThread {
            cond.unlock()
            return
        }

        while !lifecycle.readerExited {
            cond.wait()
        }
        if lifecycle.wakeWriteFD >= 0 {
            _ = close(lifecycle.wakeWriteFD)
            lifecycle.wakeWriteFD = -1
        }
        cond.unlock()
    }

    private func runEventLoop() {
        cond.lock()
        lifecycle.readerThread = pthread_self()
        cond.unlock()

        defer {
            coalescer.clear()
            for wd in wdToPath.keys {
                _ = inotify_rm_watch(inotifyFD, wd)
            }
            wdToPath.removeAll()
            pathToWd.removeAll()
            if inotifyFD >= 0 {
                _ = close(inotifyFD)
                inotifyFD = -1
            }
            if wakeReadFD >= 0 {
                _ = close(wakeReadFD)
                wakeReadFD = -1
            }

            cond.lock()
            lifecycle.readerExited = true
            if lifecycle.stopRequested && lifecycle.wakeWriteFD >= 0 {
                _ = close(lifecycle.wakeWriteFD)
                lifecycle.wakeWriteFD = -1
            }
            cond.broadcast()
            cond.unlock()
        }

        var pollFDs: [pollfd] = [
            pollfd(fd: inotifyFD, events: Int16(POLLIN), revents: 0),
            pollfd(fd: wakeReadFD, events: Int16(POLLIN), revents: 0),
        ]
        var readBuffer = [UInt8](repeating: 0, count: 65_536)
        var flushDeadlineMs: UInt64?

        while !isStopRequested() {
            let timeoutMs: Int32
            if let deadline = flushDeadlineMs {
                let now = Self.monotonicNowMs()
                timeoutMs = now >= deadline ? 0 : Int32(min(UInt64(Int32.max), deadline - now))
            } else {
                // Zero-polling idle wait: block cleanly in the kernel until an event or stop wakeup.
                timeoutMs = -1
            }

            pollFDs[0].revents = 0
            pollFDs[1].revents = 0
            let rc = poll(&pollFDs, nfds_t(pollFDs.count), timeoutMs)

            if rc < 0 {
                if errno == EINTR { continue }
                break
            }

            if (pollFDs[1].revents & Int16(POLLIN | POLLHUP | POLLERR)) != 0 {
                break
            }

            if rc > 0 && (pollFDs[0].revents & Int16(POLLIN)) != 0 {
                let pushed = drainInotifyFD(buffer: &readBuffer)
                if pushed {
                    if coalesceIntervalMs <= 0 {
                        flushCoalescer()
                        flushDeadlineMs = nil
                    } else if flushDeadlineMs == nil {
                        flushDeadlineMs = Self.monotonicNowMs() + UInt64(coalesceIntervalMs)
                    }
                }
            }

            if let deadline = flushDeadlineMs, Self.monotonicNowMs() >= deadline {
                flushCoalescer()
                flushDeadlineMs = nil
            }
        }
    }

    private func isStopRequested() -> Bool {
        cond.lock()
        let flag = lifecycle.stopRequested
        cond.unlock()
        return flag
    }

    private func flushCoalescer() {
        guard !isStopRequested() else {
            coalescer.clear()
            return
        }
        let batch = coalescer.drain()
        guard !batch.isEmpty else { return }
        emitBatch(batch)
    }

    private func drainInotifyFD(buffer: inout [UInt8]) -> Bool {
        var pushedAny = false
        var movedDirCookies: [UInt32: String] = [:]

        while !isStopRequested() {
            let bytesRead: Int = buffer.withUnsafeMutableBytes { rawBuf in
                guard let base = rawBuf.baseAddress else { return -1 }
                return read(inotifyFD, base, rawBuf.count)
            }
            if bytesRead <= 0 {
                if bytesRead < 0 && errno == EINTR { continue }
                break
            }

            var offset = 0
            let headerSize = MemoryLayout<inotify_event>.size
            while offset + headerSize <= bytesRead {
                let ev = buffer.withUnsafeBytes { rawBuf in
                    rawBuf.loadUnaligned(fromByteOffset: offset, as: inotify_event.self)
                }
                let nameLen = Int(ev.len)
                let entrySize = headerSize + nameLen
                guard offset + entrySize <= bytesRead else { break }

                var name = ""
                if nameLen > 0 {
                    name = buffer.withUnsafeBytes { rawBuf -> String in
                        let start = rawBuf.baseAddress!.advanced(by: offset + headerSize)
                            .assumingMemoryBound(to: UInt8.self)
                        let slice = UnsafeBufferPointer(start: start, count: nameLen)
                        let nulIdx = slice.firstIndex(of: 0) ?? nameLen
                        return String(decoding: slice[0..<nulIdx], as: UTF8.self)
                    }
                }
                offset += entrySize

                let mask = ev.mask
                if (mask & UInt32(IN_Q_OVERFLOW)) != 0 {
                    continue
                }
                if (mask & UInt32(IN_IGNORED)) != 0 {
                    if let removedPath = wdToPath.removeValue(forKey: ev.wd) {
                        if pathToWd[removedPath] == ev.wd {
                            pathToWd.removeValue(forKey: removedPath)
                        }
                    }
                    continue
                }

                guard let parentDir = wdToPath[ev.wd] else { continue }
                let rawPath = name.isEmpty ? parentDir : NativeFileWatcher.joinPath(parentDir, name)
                let isDir = (mask & UInt32(IN_ISDIR)) != 0

                guard let mapped = NativeFileWatcher.remapEventPath(
                    rawPath,
                    canonicalRoot: canonicalRoot,
                    requestedRoot: requestedRoot
                ) else {
                    continue
                }

                if mapped.relativePath.isEmpty {
                    if (mask & UInt32(IN_DELETE_SELF)) != 0 {
                        coalescer.push(NativeFileEvent(path: requestedRoot, kind: .deleted, isDirectory: true))
                        pushedAny = true
                    }
                    continue
                }

                if !recursive && mapped.relativePath.contains("/") {
                    continue
                }

                if ignoreFilter.shouldIgnore(
                    relativePath: mapped.relativePath,
                    reportedPath: mapped.reportedPath,
                    canonicalPath: rawPath
                ) {
                    continue
                }

                if (mask & UInt32(IN_MOVED_FROM)) != 0 {
                    if isDir && ev.cookie != 0 {
                        movedDirCookies[ev.cookie] = rawPath
                    }
                    coalescer.push(NativeFileEvent(path: mapped.reportedPath, kind: .deleted, isDirectory: isDir))
                    pushedAny = true
                    continue
                }

                if (mask & UInt32(IN_MOVED_TO)) != 0 {
                    if isDir {
                        if ev.cookie != 0, let oldDir = movedDirCookies.removeValue(forKey: ev.cookie) {
                            remapWatchedDirectoryPrefix(from: oldDir, to: rawPath)
                        } else if recursive {
                            try? registerWatchTree(at: rawPath, emitInitialEntries: true)
                        }
                    }
                    coalescer.push(NativeFileEvent(path: mapped.reportedPath, kind: .renamed, isDirectory: isDir))
                    pushedAny = true
                    continue
                }

                if (mask & UInt32(IN_CREATE)) != 0 {
                    coalescer.push(NativeFileEvent(path: mapped.reportedPath, kind: .created, isDirectory: isDir))
                    pushedAny = true
                    if recursive && isDir {
                        // Automatically watch newly created subdirectories and catch files created before
                        // `inotify_add_watch` completed.
                        try? registerWatchTree(at: rawPath, emitInitialEntries: true)
                    }
                    continue
                }

                if (mask & UInt32(IN_DELETE | IN_DELETE_SELF)) != 0 {
                    if isDir {
                        removeWatchedDirectoryPrefix(rawPath)
                    }
                    coalescer.push(NativeFileEvent(path: mapped.reportedPath, kind: .deleted, isDirectory: isDir))
                    pushedAny = true
                    continue
                }

                if (mask & UInt32(IN_MOVE_SELF)) != 0 {
                    coalescer.push(NativeFileEvent(path: mapped.reportedPath, kind: .renamed, isDirectory: isDir))
                    pushedAny = true
                    continue
                }

                if (mask & UInt32(IN_MODIFY | IN_CLOSE_WRITE | IN_ATTRIB)) != 0 {
                    coalescer.push(NativeFileEvent(path: mapped.reportedPath, kind: .modified, isDirectory: isDir))
                    pushedAny = true
                }
            }
        }

        // Any unmatched moved-out directories left the watched tree; prune their stale watch descriptors.
        for oldDir in movedDirCookies.values {
            removeWatchedDirectoryPrefix(oldDir)
        }

        return pushedAny
    }

    private func registerWatchTree(at rootDirectory: String, emitInitialEntries: Bool) throws {
        var stack: [String] = [rootDirectory]
        var isRootCall = true

        while let currentDir = stack.popLast() {
            if pathToWd[currentDir] == nil {
                let wd = inotify_add_watch(inotifyFD, currentDir, Self.watchMask)
                if wd < 0 {
                    if isRootCall && !emitInitialEntries {
                        throw NativeFileWatcherError.osFailure(
                            "inotify_add_watch failed for '\(currentDir)'",
                            errno: errno
                        )
                    }
                    continue
                }
                wdToPath[wd] = currentDir
                pathToWd[currentDir] = wd
            }
            isRootCall = false

            guard recursive else { break }
            guard let dirHandle = opendir(currentDir) else { continue }
            defer { closedir(dirHandle) }

            while let entryPtr = readdir(dirHandle) {
                #if canImport(WASILibc)
                // wasi-libc `struct dirent` declares `char d_name[]` as a flexible array member right after `d_type`.
                guard let typeOffset = MemoryLayout<dirent>.offset(of: \.d_type) else { continue }
                let namePtr = UnsafeRawPointer(entryPtr)
                    .advanced(by: typeOffset + MemoryLayout<UInt8>.size)
                    .assumingMemoryBound(to: CChar.self)
                let name = String(cString: namePtr)
                #else
                var entry = entryPtr.pointee
                let nameCapacity = MemoryLayout.size(ofValue: entry.d_name)
                let name = withUnsafePointer(to: &entry.d_name) { ptr in
                    ptr.withMemoryRebound(to: CChar.self, capacity: nameCapacity) { cStr in
                        String(cString: cStr)
                    }
                }
                #endif
                if name == "." || name == ".." { continue }

                let childPath = NativeFileWatcher.joinPath(currentDir, name)
                guard let mapped = NativeFileWatcher.remapEventPath(
                    childPath,
                    canonicalRoot: canonicalRoot,
                    requestedRoot: requestedRoot
                ) else {
                    continue
                }
                if ignoreFilter.shouldIgnore(
                    relativePath: mapped.relativePath,
                    reportedPath: mapped.reportedPath,
                    canonicalPath: childPath
                ) {
                    continue
                }

                var st = stat()
                guard lstat(childPath, &st) == 0 else { continue }
                let childIsDir = (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
                if emitInitialEntries {
                    coalescer.push(
                        NativeFileEvent(path: mapped.reportedPath, kind: .created, isDirectory: childIsDir)
                    )
                }
                if childIsDir {
                    stack.append(childPath)
                }
            }
        }
    }

    private func remapWatchedDirectoryPrefix(from oldDir: String, to newDir: String) {
        let oldPrefix = oldDir.hasSuffix("/") ? oldDir : oldDir + "/"
        var updates: [(Int32, String, String)] = []
        for (wd, path) in wdToPath {
            if path == oldDir {
                updates.append((wd, path, newDir))
            } else if path.hasPrefix(oldPrefix) {
                let suffix = String(path.dropFirst(oldPrefix.count))
                updates.append((wd, path, NativeFileWatcher.joinPath(newDir, suffix)))
            }
        }
        for (wd, oldPath, updatedPath) in updates {
            wdToPath[wd] = updatedPath
            if pathToWd[oldPath] == wd {
                pathToWd.removeValue(forKey: oldPath)
            }
            pathToWd[updatedPath] = wd
        }
    }

    private func removeWatchedDirectoryPrefix(_ dir: String) {
        let prefix = dir.hasSuffix("/") ? dir : dir + "/"
        var toRemove: [(Int32, String)] = []
        for (wd, path) in wdToPath where path == dir || path.hasPrefix(prefix) {
            toRemove.append((wd, path))
        }
        for (wd, path) in toRemove {
            _ = inotify_rm_watch(inotifyFD, wd)
            wdToPath.removeValue(forKey: wd)
            if pathToWd[path] == wd {
                pathToWd.removeValue(forKey: path)
            }
        }
    }

    private static func monotonicNowMs() -> UInt64 {
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return UInt64(max(0, ts.tv_sec)) * 1_000 + UInt64(max(0, ts.tv_nsec)) / 1_000_000
    }
}

#elseif os(Windows)

// MARK: - Windows Native ReadDirectoryChangesW Backend

private final class WindowsDirectoryWatcherDriver: NativeWatcherDriver, @unchecked Sendable {
    private static let notifyFilter: DWORD = DWORD(
        FILE_NOTIFY_CHANGE_FILE_NAME
            | FILE_NOTIFY_CHANGE_DIR_NAME
            | FILE_NOTIFY_CHANGE_LAST_WRITE
            | FILE_NOTIFY_CHANGE_SIZE
    )

    private struct LifecycleState {
        var started: Bool = false
        var stopRequested: Bool = false
        var readerExited: Bool = false
        var stopEvent: HANDLE?
        var readerThreadID: DWORD = 0
    }

    private let requestedRoot: String
    private let canonicalRoot: String
    private let recursive: Bool
    private let ignoreFilter: NativeFileWatcher.IgnoreFilter
    private let coalesceIntervalMs: Int
    private let emitBatch: @Sendable ([NativeFileEvent]) -> Void

    private let cond = NSCondition()
    private var lifecycle = LifecycleState()

    // Owned strictly by the background reader thread once started.
    private var dirHandle: HANDLE?
    private var ioEvent: HANDLE?
    private var coalescer = NativeFileEventCoalescer()

    init(
        requestedRoot: String,
        canonicalRoot: String,
        recursive: Bool,
        ignoreFilter: NativeFileWatcher.IgnoreFilter,
        coalesceIntervalMs: Int,
        emitBatch: @escaping @Sendable ([NativeFileEvent]) -> Void
    ) {
        self.requestedRoot = requestedRoot
        self.canonicalRoot = canonicalRoot
        self.recursive = recursive
        self.ignoreFilter = ignoreFilter
        self.coalesceIntervalMs = coalesceIntervalMs
        self.emitBatch = emitBatch
    }

    deinit {
        stop()
    }

    func start() throws {
        let winPath = canonicalRoot.replacing("/", with: "\\")
        let widePath = Array(winPath.utf16) + [0]
        let attrs = widePath.withUnsafeBufferPointer { ptr in
            GetFileAttributesW(ptr.baseAddress)
        }
        guard attrs != INVALID_FILE_ATTRIBUTES else {
            throw NativeFileWatcherError.pathNotFound(requestedRoot)
        }
        guard (attrs & DWORD(FILE_ATTRIBUTE_DIRECTORY)) != 0 else {
            throw NativeFileWatcherError.notADirectory(requestedRoot)
        }

        let opened: HANDLE? = widePath.withUnsafeBufferPointer { ptr in
            CreateFileW(
                ptr.baseAddress,
                DWORD(FILE_LIST_DIRECTORY),
                DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE),
                nil,
                DWORD(OPEN_EXISTING),
                DWORD(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OVERLAPPED),
                nil
            )
        }
        guard let dir = opened, dir != INVALID_HANDLE_VALUE else {
            throw NativeFileWatcherError.osFailure(
                "CreateFileW failed for '\(requestedRoot)'",
                errno: Int32(bitPattern: GetLastError())
            )
        }

        guard let ioEv = CreateEventW(nil, true, false, nil) else {
            let err = Int32(bitPattern: GetLastError())
            _ = CloseHandle(dir)
            throw NativeFileWatcherError.osFailure("CreateEventW(io) failed", errno: err)
        }
        guard let stopEv = CreateEventW(nil, true, false, nil) else {
            let err = Int32(bitPattern: GetLastError())
            _ = CloseHandle(ioEv)
            _ = CloseHandle(dir)
            throw NativeFileWatcherError.osFailure("CreateEventW(stop) failed", errno: err)
        }

        self.dirHandle = dir
        self.ioEvent = ioEv

        cond.lock()
        lifecycle.started = true
        lifecycle.stopRequested = false
        lifecycle.readerExited = false
        lifecycle.stopEvent = stopEv
        cond.unlock()

        let stopEvBits = UInt(bitPattern: stopEv)
        Thread.detachNewThread { [self] in
            if let ev = HANDLE(bitPattern: stopEvBits) {
                self.runEventLoop(stopEvent: ev)
            }
        }
    }

    func stop() {
        cond.lock()
        guard lifecycle.started else {
            cond.unlock()
            return
        }
        lifecycle.stopRequested = true
        if let stopEv = lifecycle.stopEvent {
            _ = SetEvent(stopEv)
        }
        let onReaderThread = lifecycle.readerThreadID != 0 && lifecycle.readerThreadID == GetCurrentThreadId()
        if onReaderThread {
            cond.unlock()
            return
        }

        while !lifecycle.readerExited {
            cond.wait()
        }
        if let ev = lifecycle.stopEvent {
            _ = CloseHandle(ev)
            lifecycle.stopEvent = nil
        }
        cond.unlock()
    }

    private func runEventLoop(stopEvent: HANDLE) {
        cond.lock()
        lifecycle.readerThreadID = GetCurrentThreadId()
        cond.unlock()

        defer {
            coalescer.clear()
            if let ioEv = ioEvent {
                _ = CloseHandle(ioEv)
                ioEvent = nil
            }
            if let dir = dirHandle {
                _ = CloseHandle(dir)
                dirHandle = nil
            }

            cond.lock()
            lifecycle.readerExited = true
            if lifecycle.stopRequested, let ev = lifecycle.stopEvent {
                _ = CloseHandle(ev)
                lifecycle.stopEvent = nil
            }
            cond.broadcast()
            cond.unlock()
        }

        guard let dir = dirHandle, let ioEv = ioEvent else { return }

        // Allocate stable DWORD-aligned heap memory for overlapped ReadDirectoryChangesW I/O.
        // Passing a Swift local Array or inout OVERLAPPED to async Win32 I/O is undefined behavior
        // because the kernel writes to both addresses asynchronously after ReadDirectoryChangesW returns.
        let bufferByteCount = 64 * 1024
        let rawBuffer = UnsafeMutableRawPointer.allocate(
            byteCount: bufferByteCount,
            alignment: MemoryLayout<DWORD>.alignment
        )
        let overlappedPtr = UnsafeMutablePointer<OVERLAPPED>.allocate(capacity: 1)
        overlappedPtr.initialize(to: OVERLAPPED())
        var ioPending = false
        defer {
            if ioPending {
                _ = CancelIoEx(dir, overlappedPtr)
                var ignoredBytes: DWORD = 0
                _ = GetOverlappedResult(dir, overlappedPtr, &ignoredBytes, true)
                ioPending = false
            }
            overlappedPtr.deinitialize(count: 1)
            overlappedPtr.deallocate()
            rawBuffer.deallocate()
        }

        var flushDeadlineMs: UInt64?

        while !isStopRequested() {
            if !ioPending {
                _ = ResetEvent(ioEv)
                overlappedPtr.pointee = OVERLAPPED()
                overlappedPtr.pointee.hEvent = ioEv

                let issued = ReadDirectoryChangesW(
                    dir,
                    rawBuffer,
                    DWORD(bufferByteCount),
                    recursive,
                    Self.notifyFilter,
                    nil,
                    overlappedPtr,
                    nil
                )
                if !issued {
                    let err = GetLastError()
                    if err != DWORD(ERROR_IO_PENDING) {
                        break
                    }
                }
                ioPending = true
            }

            let waitTimeout: DWORD
            if let deadline = flushDeadlineMs {
                let now = GetTickCount64()
                waitTimeout = now >= deadline ? 0 : DWORD(min(UInt64(DWORD.max - 1), deadline - now))
            } else {
                // Zero-polling idle wait: kernel sleeps until I/O completion or stopEvent signal.
                waitTimeout = INFINITE
            }

            var handles: [HANDLE?] = [stopEvent, ioEv]
            let waitResult = WaitForMultipleObjects(
                DWORD(handles.count),
                &handles,
                false,
                waitTimeout
            )

            if waitResult == DWORD(WAIT_OBJECT_0) {
                if ioPending {
                    _ = CancelIoEx(dir, overlappedPtr)
                    var ignoredBytes: DWORD = 0
                    _ = GetOverlappedResult(dir, overlappedPtr, &ignoredBytes, true)
                    ioPending = false
                }
                break
            }

            if waitResult == DWORD(WAIT_OBJECT_0) + 1 {
                ioPending = false
                var bytesTransferred: DWORD = 0
                if GetOverlappedResult(dir, overlappedPtr, &bytesTransferred, false),
                   bytesTransferred > 0
                {
                    let validCount = min(Int(bytesTransferred), bufferByteCount)
                    let notifyBytes = UnsafeRawBufferPointer(start: rawBuffer, count: validCount)
                    let pushed = parseNotifyBuffer(notifyBytes)
                    if pushed {
                        if coalesceIntervalMs <= 0 {
                            flushCoalescer()
                            flushDeadlineMs = nil
                        } else if flushDeadlineMs == nil {
                            flushDeadlineMs = GetTickCount64() + UInt64(coalesceIntervalMs)
                        }
                    }
                }
            } else if waitResult == DWORD(WAIT_TIMEOUT) {
                flushCoalescer()
                flushDeadlineMs = nil
            } else {
                break
            }

            if let deadline = flushDeadlineMs, GetTickCount64() >= deadline {
                flushCoalescer()
                flushDeadlineMs = nil
            }
        }
    }

    private func isStopRequested() -> Bool {
        cond.lock()
        let flag = lifecycle.stopRequested
        cond.unlock()
        return flag
    }

    private func flushCoalescer() {
        guard !isStopRequested() else {
            coalescer.clear()
            return
        }
        let batch = coalescer.drain()
        guard !batch.isEmpty else { return }
        emitBatch(batch)
    }

    private func parseNotifyBuffer(_ rawBuf: UnsafeRawBufferPointer) -> Bool {
        var pushedAny = false
        guard let nameFieldOffset = MemoryLayout<FILE_NOTIFY_INFORMATION>.offset(of: \.FileName) else {
            return false
        }

        let byteCount = rawBuf.count
        var offset = 0
        while offset + nameFieldOffset <= byteCount {
            let info = rawBuf.loadUnaligned(fromByteOffset: offset, as: FILE_NOTIFY_INFORMATION.self)
            let nameBytes = Int(info.FileNameLength)
            let nameStart = offset + nameFieldOffset
            guard nameStart + nameBytes <= byteCount else { break }

            let codeUnitCount = nameBytes / MemoryLayout<WCHAR>.size
            var utf16: [UInt16] = []
            utf16.reserveCapacity(codeUnitCount)
            for i in 0..<codeUnitCount {
                utf16.append(rawBuf.loadUnaligned(fromByteOffset: nameStart + i * 2, as: UInt16.self))
            }
            let rawRel = NativeFileWatcher.normalizeSlashes(String(decoding: utf16, as: UTF16.self))
            let rawFull = NativeFileWatcher.joinPath(canonicalRoot, rawRel)

            if let mapped = NativeFileWatcher.remapEventPath(
                rawFull,
                canonicalRoot: canonicalRoot,
                requestedRoot: requestedRoot
            ), !mapped.relativePath.isEmpty {
                if (recursive || !mapped.relativePath.contains("/"))
                    && !ignoreFilter.shouldIgnore(
                        relativePath: mapped.relativePath,
                        reportedPath: mapped.reportedPath,
                        canonicalPath: rawFull
                    )
                {
                    let kind: NativeFileEventKind?
                    switch info.Action {
                    case DWORD(FILE_ACTION_ADDED): kind = .created
                    case DWORD(FILE_ACTION_REMOVED): kind = .deleted
                    case DWORD(FILE_ACTION_MODIFIED): kind = .modified
                    case DWORD(FILE_ACTION_RENAMED_OLD_NAME): kind = .deleted
                    case DWORD(FILE_ACTION_RENAMED_NEW_NAME): kind = .renamed
                    default: kind = nil
                    }
                    if let kind {
                        let isDir = Self.queryIsDirectory(rawFull)
                        coalescer.push(
                            NativeFileEvent(path: mapped.reportedPath, kind: kind, isDirectory: isDir)
                        )
                        pushedAny = true
                    }
                }
            }

            if info.NextEntryOffset == 0 { break }
            offset += Int(info.NextEntryOffset)
        }
        return pushedAny
    }

    private static func queryIsDirectory(_ path: String) -> Bool {
        let winPath = path.replacing("/", with: "\\")
        let wide = Array(winPath.utf16) + [0]
        let attrs = wide.withUnsafeBufferPointer { GetFileAttributesW($0.baseAddress) }
        guard attrs != INVALID_FILE_ATTRIBUTES else { return false }
        return (attrs & DWORD(FILE_ATTRIBUTE_DIRECTORY)) != 0
    }
}

#endif

// MARK: - BSD / Apple Non-macOS Native kqueue (EVFILT_VNODE) + Self-Pipe Backend

#if canImport(Darwin) || ((os(FreeBSD) || os(OpenBSD)) && (canImport(Glibc) || canImport(Musl)))

private final class KqueueDriver: NativeWatcherDriver, @unchecked Sendable {
    #if canImport(Darwin)
    private typealias KEvent = Darwin.kevent
    #else
    private typealias KEvent = kevent
    #endif

    private struct EntrySnapshot: Equatable {
        var ino: UInt64
        var size: Int64
        var mtimeSec: Int
        var mtimeNsec: Int
        var ctimeSec: Int
        var ctimeNsec: Int
        var isDirectory: Bool

        func metadataChanged(from other: EntrySnapshot) -> Bool {
            ino != other.ino
                || size != other.size
                || mtimeSec != other.mtimeSec
                || mtimeNsec != other.mtimeNsec
                || ctimeSec != other.ctimeSec
                || ctimeNsec != other.ctimeNsec
                || isDirectory != other.isDirectory
        }
    }

    private struct WatchedFD {
        let path: String
        let isDirectory: Bool
    }

    private struct LifecycleState {
        var started: Bool = false
        var stopRequested: Bool = false
        var readerExited: Bool = false
        var wakeWriteFD: Int32 = -1
        var readerThread: pthread_t?
    }

    private static let maxTrackedFileFDs = 256
    private static let vnodeFlags: UInt32 = UInt32(
        NOTE_WRITE | NOTE_DELETE | NOTE_RENAME | NOTE_EXTEND | NOTE_ATTRIB | NOTE_LINK | NOTE_REVOKE
    )

    private let requestedRoot: String
    private let canonicalRoot: String
    private let recursive: Bool
    private let ignoreFilter: NativeFileWatcher.IgnoreFilter
    private let coalesceIntervalMs: Int
    private let emitBatch: @Sendable ([NativeFileEvent]) -> Void

    private let cond = NSCondition()
    private var lifecycle = LifecycleState()

    // Owned strictly by the background event loop thread once started.
    private var kqFD: Int32 = -1
    private var wakeReadFD: Int32 = -1
    private var fdToWatch: [Int32: WatchedFD] = [:]
    private var pathToFD: [String: Int32] = [:]
    private var trackedFileCount: Int = 0
    private var knownEntries: [String: EntrySnapshot] = [:]
    private var coalescer = NativeFileEventCoalescer()

    init(
        requestedRoot: String,
        canonicalRoot: String,
        recursive: Bool,
        ignoreFilter: NativeFileWatcher.IgnoreFilter,
        coalesceIntervalMs: Int,
        emitBatch: @escaping @Sendable ([NativeFileEvent]) -> Void
    ) {
        self.requestedRoot = requestedRoot
        self.canonicalRoot = canonicalRoot
        self.recursive = recursive
        self.ignoreFilter = ignoreFilter
        self.coalesceIntervalMs = coalesceIntervalMs
        self.emitBatch = emitBatch
    }

    deinit {
        stop()
    }

    func start() throws {
        var st = Self.emptyStat()
        guard fstatat(AT_FDCWD, canonicalRoot, &st, 0) == 0 else {
            let err = errno
            if err == ENOENT || err == ENOTDIR {
                throw NativeFileWatcherError.pathNotFound(requestedRoot)
            }
            throw NativeFileWatcherError.osFailure("stat failed for '\(requestedRoot)'", errno: err)
        }
        guard (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
            throw NativeFileWatcherError.notADirectory(requestedRoot)
        }

        let kq = kqueue()
        guard kq >= 0 else {
            throw NativeFileWatcherError.osFailure("kqueue failed", errno: errno)
        }
        _ = fcntl(kq, F_SETFD, FD_CLOEXEC)

        var pipeFDs: [Int32] = [-1, -1]
        guard pipe(&pipeFDs) == 0 else {
            let err = errno
            _ = close(kq)
            throw NativeFileWatcherError.osFailure("pipe failed", errno: err)
        }
        for pfd in pipeFDs {
            _ = fcntl(pfd, F_SETFD, FD_CLOEXEC)
            let fl = fcntl(pfd, F_GETFL, 0)
            if fl >= 0 {
                _ = fcntl(pfd, F_SETFL, fl | O_NONBLOCK)
            }
        }

        var wakeEv = KEvent(
            ident: UInt(pipeFDs[0]),
            filter: Int16(EVFILT_READ),
            flags: UInt16(EV_ADD | EV_CLEAR),
            fflags: 0,
            data: 0,
            udata: nil
        )
        let regRc = kevent(kq, &wakeEv, 1, nil, 0, nil)
        guard regRc >= 0 else {
            let err = errno
            _ = close(kq)
            _ = close(pipeFDs[0])
            _ = close(pipeFDs[1])
            throw NativeFileWatcherError.osFailure("kevent(wake) registration failed", errno: err)
        }

        self.kqFD = kq
        self.wakeReadFD = pipeFDs[0]
        let writeFD = pipeFDs[1]

        do {
            try registerDirectoryTree(at: canonicalRoot, emitInitial: false)
        } catch {
            cleanupFDs()
            _ = close(writeFD)
            throw error
        }

        cond.lock()
        lifecycle.started = true
        lifecycle.stopRequested = false
        lifecycle.readerExited = false
        lifecycle.wakeWriteFD = writeFD
        cond.unlock()

        Thread.detachNewThread { [self] in
            self.runEventLoop()
        }
    }

    func stop() {
        cond.lock()
        guard lifecycle.started else {
            cond.unlock()
            return
        }
        lifecycle.stopRequested = true
        if lifecycle.wakeWriteFD >= 0 {
            var byte: UInt8 = 1
            _ = write(lifecycle.wakeWriteFD, &byte, 1)
        }
        let onReaderThread: Bool
        if let readerTid = lifecycle.readerThread {
            onReaderThread = pthread_equal(pthread_self(), readerTid) != 0
        } else {
            onReaderThread = false
        }
        if onReaderThread {
            cond.unlock()
            return
        }

        while !lifecycle.readerExited {
            cond.wait()
        }
        if lifecycle.wakeWriteFD >= 0 {
            _ = close(lifecycle.wakeWriteFD)
            lifecycle.wakeWriteFD = -1
        }
        cond.unlock()
    }

    private func runEventLoop() {
        cond.lock()
        lifecycle.readerThread = pthread_self()
        cond.unlock()

        defer {
            coalescer.clear()
            cleanupFDs()

            cond.lock()
            lifecycle.readerExited = true
            if lifecycle.stopRequested && lifecycle.wakeWriteFD >= 0 {
                _ = close(lifecycle.wakeWriteFD)
                lifecycle.wakeWriteFD = -1
            }
            cond.broadcast()
            cond.unlock()
        }

        var events = Array<KEvent>(repeating: KEvent(), count: 64)
        var flushDeadlineMs: UInt64?

        while !isStopRequested() {
            let count: Int32
            if let deadline = flushDeadlineMs {
                let now = Self.monotonicNowMs()
                let remMs = now >= deadline ? 0 : (deadline - now)
                var ts = timespec(tv_sec: Int(remMs / 1_000), tv_nsec: Int((remMs % 1_000) * 1_000_000))
                count = kevent(kqFD, nil, 0, &events, Int32(events.count), &ts)
            } else {
                // Zero-polling idle wait: kernel sleeps until vnode change or stop self-pipe wakeup.
                count = kevent(kqFD, nil, 0, &events, Int32(events.count), nil)
            }

            if count < 0 {
                if errno == EINTR { continue }
                break
            }

            var pushedAny = false
            var shouldExit = false
            for idx in 0..<Int(count) {
                let ev = events[idx]
                if ev.filter == Int16(EVFILT_READ) && Int32(ev.ident) == wakeReadFD {
                    shouldExit = true
                    break
                }
                if ev.filter == Int16(EVFILT_VNODE) {
                    if handleVnodeEvent(fd: Int32(ev.ident), fflags: ev.fflags) {
                        pushedAny = true
                    }
                }
            }
            if shouldExit { break }

            if pushedAny {
                if coalesceIntervalMs <= 0 {
                    flushCoalescer()
                    flushDeadlineMs = nil
                } else if flushDeadlineMs == nil {
                    flushDeadlineMs = Self.monotonicNowMs() + UInt64(coalesceIntervalMs)
                }
            }

            if let deadline = flushDeadlineMs, Self.monotonicNowMs() >= deadline {
                flushCoalescer()
                flushDeadlineMs = nil
            }
        }
    }

    private func handleVnodeEvent(fd: Int32, fflags: UInt32) -> Bool {
        guard let watched = fdToWatch[fd] else { return false }
        var pushedAny = false

        if watched.isDirectory {
            let deletedOrMoved = (fflags & UInt32(NOTE_DELETE | NOTE_RENAME | NOTE_REVOKE)) != 0
            if deletedOrMoved {
                var st = Self.emptyStat()
                if lstat(watched.path, &st) != 0 {
                    closeWatchedFD(forPath: watched.path)
                    if watched.path == canonicalRoot {
                        coalescer.push(NativeFileEvent(path: requestedRoot, kind: .deleted, isDirectory: true))
                        return true
                    }
                    if let mapped = NativeFileWatcher.remapEventPath(
                        watched.path,
                        canonicalRoot: canonicalRoot,
                        requestedRoot: requestedRoot
                    ), !mapped.relativePath.isEmpty {
                        coalescer.push(NativeFileEvent(path: mapped.reportedPath, kind: .deleted, isDirectory: true))
                        pushedAny = true
                    }
                    pruneEntries(under: watched.path)
                    return pushedAny
                }
            }
            if rescanDirectory(watched.path) {
                pushedAny = true
            }
        } else {
            let removedFlag = (fflags & UInt32(NOTE_DELETE | NOTE_RENAME | NOTE_REVOKE)) != 0
            let parent = Self.dirname(watched.path)
            if let mapped = NativeFileWatcher.remapEventPath(
                watched.path,
                canonicalRoot: canonicalRoot,
                requestedRoot: requestedRoot
            ), !mapped.relativePath.isEmpty {
                var st = Self.emptyStat()
                if lstat(watched.path, &st) == 0 {
                    let snap = Self.snapshot(from: st)
                    let prev = knownEntries[watched.path]
                    knownEntries[watched.path] = snap
                    if removedFlag {
                        closeWatchedFD(forPath: watched.path)
                        openVnodeWatch(path: watched.path, isDirectory: false)
                        let kind: NativeFileEventKind = (prev != nil && prev?.ino != snap.ino) ? .renamed : .modified
                        coalescer.push(NativeFileEvent(path: mapped.reportedPath, kind: kind, isDirectory: false))
                        pushedAny = true
                    } else if prev == nil || prev!.metadataChanged(from: snap) {
                        coalescer.push(NativeFileEvent(path: mapped.reportedPath, kind: .modified, isDirectory: false))
                        pushedAny = true
                    }
                } else {
                    closeWatchedFD(forPath: watched.path)
                    knownEntries.removeValue(forKey: watched.path)
                    coalescer.push(NativeFileEvent(path: mapped.reportedPath, kind: .deleted, isDirectory: false))
                    pushedAny = true
                }
            }
            if removedFlag, pathToFD[parent] != nil, rescanDirectory(parent) {
                pushedAny = true
            }
        }

        return pushedAny
    }

    private func rescanDirectory(_ dir: String) -> Bool {
        var pushedAny = false
        let currentChildren = Self.listDirectChildren(
            in: dir,
            canonicalRoot: canonicalRoot,
            requestedRoot: requestedRoot,
            ignoreFilter: ignoreFilter
        )

        let prefix = dir == "/" ? "/" : dir + "/"
        var previousChildren: [String: EntrySnapshot] = [:]
        for (path, snap) in knownEntries {
            guard path.hasPrefix(prefix) else { continue }
            let rest = path.dropFirst(prefix.count)
            if !rest.contains("/") {
                previousChildren[path] = snap
            }
        }

        // Detect deleted entries (sorted for determinism)
        for oldPath in previousChildren.keys.sorted() where currentChildren[oldPath] == nil {
            let oldSnap = previousChildren[oldPath]!
            knownEntries.removeValue(forKey: oldPath)
            closeWatchedFD(forPath: oldPath)
            if oldSnap.isDirectory {
                pruneEntries(under: oldPath)
            }
            if let mapped = NativeFileWatcher.remapEventPath(
                oldPath,
                canonicalRoot: canonicalRoot,
                requestedRoot: requestedRoot
            ), !mapped.relativePath.isEmpty {
                coalescer.push(NativeFileEvent(path: mapped.reportedPath, kind: .deleted, isDirectory: oldSnap.isDirectory))
                pushedAny = true
            }
        }

        // Detect created and modified/replaced entries
        for newPath in currentChildren.keys.sorted() {
            let newSnap = currentChildren[newPath]!
            guard let mapped = NativeFileWatcher.remapEventPath(
                newPath,
                canonicalRoot: canonicalRoot,
                requestedRoot: requestedRoot
            ), !mapped.relativePath.isEmpty else {
                continue
            }

            if let prev = previousChildren[newPath] {
                if prev.metadataChanged(from: newSnap) {
                    knownEntries[newPath] = newSnap
                    let kind: NativeFileEventKind = (!newSnap.isDirectory && prev.ino != newSnap.ino) ? .renamed : .modified
                    if !newSnap.isDirectory && prev.ino != newSnap.ino {
                        closeWatchedFD(forPath: newPath)
                        openVnodeWatch(path: newPath, isDirectory: false)
                    }
                    coalescer.push(NativeFileEvent(path: mapped.reportedPath, kind: kind, isDirectory: newSnap.isDirectory))
                    pushedAny = true
                }
            } else {
                knownEntries[newPath] = newSnap
                coalescer.push(NativeFileEvent(path: mapped.reportedPath, kind: .created, isDirectory: newSnap.isDirectory))
                pushedAny = true
                if newSnap.isDirectory {
                    if recursive {
                        try? registerDirectoryTree(at: newPath, emitInitial: true)
                    }
                } else {
                    openVnodeWatch(path: newPath, isDirectory: false)
                }
            }
        }

        return pushedAny
    }

    private func registerDirectoryTree(at rootDirectory: String, emitInitial: Bool) throws {
        var stack: [String] = [rootDirectory]
        var isRootCall = true

        while let currentDir = stack.popLast() {
            if pathToFD[currentDir] == nil {
                let opened = openVnodeWatch(path: currentDir, isDirectory: true)
                if !opened && isRootCall && !emitInitial {
                    throw NativeFileWatcherError.osFailure(
                        "kqueue open/register failed for '\(currentDir)'",
                        errno: errno
                    )
                }
            }
            isRootCall = false

            let children = Self.listDirectChildren(
                in: currentDir,
                canonicalRoot: canonicalRoot,
                requestedRoot: requestedRoot,
                ignoreFilter: ignoreFilter
            )
            for childPath in children.keys.sorted() {
                let snap = children[childPath]!
                let wasKnown = knownEntries[childPath] != nil
                knownEntries[childPath] = snap
                if emitInitial && !wasKnown,
                   let mapped = NativeFileWatcher.remapEventPath(
                       childPath,
                       canonicalRoot: canonicalRoot,
                       requestedRoot: requestedRoot
                   ), !mapped.relativePath.isEmpty
                {
                    coalescer.push(NativeFileEvent(path: mapped.reportedPath, kind: .created, isDirectory: snap.isDirectory))
                }
                if snap.isDirectory {
                    if recursive {
                        stack.append(childPath)
                    }
                } else {
                    openVnodeWatch(path: childPath, isDirectory: false)
                }
            }
        }
    }

    @discardableResult
    private func openVnodeWatch(path: String, isDirectory: Bool) -> Bool {
        if pathToFD[path] != nil { return true }
        if !isDirectory && trackedFileCount >= Self.maxTrackedFileFDs { return false }

        #if canImport(Darwin)
        let flags = O_EVTONLY | O_CLOEXEC
        #else
        let flags = (isDirectory ? (O_RDONLY | O_DIRECTORY) : O_RDONLY) | O_CLOEXEC
        #endif
        let fd = open(path, flags)
        guard fd >= 0 else { return false }

        var ev = KEvent(
            ident: UInt(fd),
            filter: Int16(EVFILT_VNODE),
            flags: UInt16(EV_ADD | EV_CLEAR),
            fflags: Self.vnodeFlags,
            data: 0,
            udata: nil
        )
        guard kevent(kqFD, &ev, 1, nil, 0, nil) >= 0 else {
            _ = close(fd)
            return false
        }

        fdToWatch[fd] = WatchedFD(path: path, isDirectory: isDirectory)
        pathToFD[path] = fd
        if !isDirectory {
            trackedFileCount += 1
        }
        return true
    }

    private func closeWatchedFD(forPath path: String) {
        guard let fd = pathToFD.removeValue(forKey: path) else { return }
        if let entry = fdToWatch.removeValue(forKey: fd), !entry.isDirectory {
            trackedFileCount = max(0, trackedFileCount - 1)
        }
        _ = close(fd)
    }

    private func pruneEntries(under dir: String) {
        let prefix = dir == "/" ? "/" : dir + "/"
        let stalePaths = knownEntries.keys.filter { $0.hasPrefix(prefix) }
        for path in stalePaths {
            knownEntries.removeValue(forKey: path)
            closeWatchedFD(forPath: path)
        }
        let staleFDs = pathToFD.keys.filter { $0.hasPrefix(prefix) }
        for path in staleFDs {
            closeWatchedFD(forPath: path)
        }
    }

    private func cleanupFDs() {
        for fd in fdToWatch.keys {
            _ = close(fd)
        }
        fdToWatch.removeAll()
        pathToFD.removeAll()
        trackedFileCount = 0
        knownEntries.removeAll()
        if kqFD >= 0 {
            _ = close(kqFD)
            kqFD = -1
        }
        if wakeReadFD >= 0 {
            _ = close(wakeReadFD)
            wakeReadFD = -1
        }
    }

    private func isStopRequested() -> Bool {
        cond.lock()
        let flag = lifecycle.stopRequested
        cond.unlock()
        return flag
    }

    private func flushCoalescer() {
        guard !isStopRequested() else {
            coalescer.clear()
            return
        }
        let batch = coalescer.drain()
        guard !batch.isEmpty else { return }
        emitBatch(batch)
    }

    private static func listDirectChildren(
        in directory: String,
        canonicalRoot: String,
        requestedRoot: String,
        ignoreFilter: NativeFileWatcher.IgnoreFilter
    ) -> [String: EntrySnapshot] {
        var result: [String: EntrySnapshot] = [:]
        guard let dirHandle = opendir(directory) else { return result }
        defer { closedir(dirHandle) }

        while let entryPtr = readdir(dirHandle) {
            var entry = entryPtr.pointee
            let nameCapacity = MemoryLayout.size(ofValue: entry.d_name)
            let name = withUnsafePointer(to: &entry.d_name) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: nameCapacity) { cStr in
                    String(cString: cStr)
                }
            }
            if name == "." || name == ".." { continue }

            let childPath = NativeFileWatcher.joinPath(directory, name)
            guard let mapped = NativeFileWatcher.remapEventPath(
                childPath,
                canonicalRoot: canonicalRoot,
                requestedRoot: requestedRoot
            ) else {
                continue
            }
            if ignoreFilter.shouldIgnore(
                relativePath: mapped.relativePath,
                reportedPath: mapped.reportedPath,
                canonicalPath: childPath
            ) {
                continue
            }

            var st = emptyStat()
            guard lstat(childPath, &st) == 0 else { continue }
            result[childPath] = snapshot(from: st)
        }
        return result
    }

    #if canImport(Darwin)
    private static func emptyStat() -> Darwin.stat { Darwin.stat() }
    private static func snapshot(from st: Darwin.stat) -> EntrySnapshot {
        EntrySnapshot(
            ino: UInt64(st.st_ino),
            size: Int64(st.st_size),
            mtimeSec: st.st_mtimespec.tv_sec,
            mtimeNsec: st.st_mtimespec.tv_nsec,
            ctimeSec: st.st_ctimespec.tv_sec,
            ctimeNsec: st.st_ctimespec.tv_nsec,
            isDirectory: (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
        )
    }
    #else
    private static func emptyStat() -> stat { stat() }
    private static func snapshot(from st: stat) -> EntrySnapshot {
        EntrySnapshot(
            ino: UInt64(st.st_ino),
            size: Int64(st.st_size),
            mtimeSec: st.st_mtimespec.tv_sec,
            mtimeNsec: st.st_mtimespec.tv_nsec,
            ctimeSec: st.st_ctimespec.tv_sec,
            ctimeNsec: st.st_ctimespec.tv_nsec,
            isDirectory: (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
        )
    }
    #endif

    private static func dirname(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "." }
        if slash == path.startIndex { return "/" }
        return String(path[..<slash])
    }

    private static func monotonicNowMs() -> UInt64 {
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return UInt64(max(0, ts.tv_sec)) * 1_000 + UInt64(max(0, ts.tv_nsec)) / 1_000_000
    }
}

#endif

// MARK: - Portable Polling Fallback Backend (WASI & Platforms Without Native OS Watch APIs)

private final class PollingWatcherDriver: NativeWatcherDriver, Sendable {
    private struct EntryMeta: Equatable, Sendable {
        let ino: UInt64
        let size: Int64
        let mtimeSec: Int64
        let mtimeNsec: Int64
        let isDirectory: Bool
    }

    private struct LoopState: Sendable {
        var stopped: Bool = false
        var task: Task<Void, Never>?
        var known: [String: EntryMeta] = [:]
    }

    private let requestedRoot: String
    private let canonicalRoot: String
    private let recursive: Bool
    private let ignoreFilter: NativeFileWatcher.IgnoreFilter
    private let coalesceIntervalMs: Int
    private let pollIntervalMs: Int
    private let emitBatch: @Sendable ([NativeFileEvent]) -> Void
    private let state = Mutex(LoopState())

    init(
        requestedRoot: String,
        canonicalRoot: String,
        recursive: Bool,
        ignoreFilter: NativeFileWatcher.IgnoreFilter,
        coalesceIntervalMs: Int,
        pollIntervalMs: Int,
        emitBatch: @escaping @Sendable ([NativeFileEvent]) -> Void
    ) {
        self.requestedRoot = requestedRoot
        self.canonicalRoot = canonicalRoot
        self.recursive = recursive
        self.ignoreFilter = ignoreFilter
        self.coalesceIntervalMs = coalesceIntervalMs
        self.pollIntervalMs = max(10, pollIntervalMs)
        self.emitBatch = emitBatch
    }

    deinit {
        stop()
    }

    func start() throws {
        try validateRootDirectory()
        let initial = scanTree()
        let interval = pollIntervalMs
        let task = Task.detached(priority: .utility) { [weak self] in
            while let self, !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(interval))
                } catch {
                    break
                }
                if self.state.withLock({ $0.stopped }) || Task.isCancelled { break }
                self.pollOnce()
            }
        }
        state.withLock { s in
            s.stopped = false
            s.known = initial
            s.task = task
        }
    }

    func stop() {
        let task = state.withLock { s -> Task<Void, Never>? in
            s.stopped = true
            let current = s.task
            s.task = nil
            s.known.removeAll()
            return current
        }
        task?.cancel()
    }

    private func pollOnce() {
        let current = scanTree()
        let previous = state.withLock { s -> [String: EntryMeta]? in
            guard !s.stopped else { return nil }
            let prev = s.known
            s.known = current
            return prev
        }
        guard let previous else { return }

        var coalescer = NativeFileEventCoalescer()
        for path in previous.keys.sorted() where current[path] == nil {
            if let meta = previous[path] {
                coalescer.push(NativeFileEvent(path: path, kind: .deleted, isDirectory: meta.isDirectory))
            }
        }
        for path in current.keys.sorted() {
            guard let nowMeta = current[path] else { continue }
            if let prevMeta = previous[path] {
                if prevMeta != nowMeta {
                    let kind: NativeFileEventKind = (!nowMeta.isDirectory && prevMeta.ino != 0 && nowMeta.ino != 0 && prevMeta.ino != nowMeta.ino)
                        ? .renamed
                        : .modified
                    coalescer.push(NativeFileEvent(path: path, kind: kind, isDirectory: nowMeta.isDirectory))
                }
            } else {
                coalescer.push(NativeFileEvent(path: path, kind: .created, isDirectory: nowMeta.isDirectory))
            }
        }
        let batch = coalescer.drain()
        if !batch.isEmpty && !state.withLock({ $0.stopped }) {
            emitBatch(batch)
        }
    }

    private func validateRootDirectory() throws {
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl) || canImport(Android) || canImport(WASILibc)
        #if canImport(Darwin)
        var st = Darwin.stat()
        #else
        var st = stat()
        #endif
        guard lstat(canonicalRoot, &st) == 0 else {
            let err = errno
            if err == ENOENT || err == ENOTDIR {
                throw NativeFileWatcherError.pathNotFound(requestedRoot)
            }
            throw NativeFileWatcherError.osFailure("stat failed for '\(requestedRoot)'", errno: err)
        }
        guard (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
            throw NativeFileWatcherError.notADirectory(requestedRoot)
        }
        #elseif !os(WASI)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonicalRoot, isDirectory: &isDir) else {
            throw NativeFileWatcherError.pathNotFound(requestedRoot)
        }
        guard isDir.boolValue else {
            throw NativeFileWatcherError.notADirectory(requestedRoot)
        }
        #endif
    }

    private func scanTree() -> [String: EntryMeta] {
        var result: [String: EntryMeta] = [:]
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl) || canImport(Android) || canImport(WASILibc)
        var stack: [String] = [canonicalRoot]
        while let currentDir = stack.popLast() {
            guard let dirHandle = opendir(currentDir) else { continue }
            defer { closedir(dirHandle) }
            while let entryPtr = readdir(dirHandle) {
                #if canImport(WASILibc)
                // wasi-libc `struct dirent` declares `char d_name[]` as a flexible array member right after `d_type`.
                guard let typeOffset = MemoryLayout<dirent>.offset(of: \.d_type) else { continue }
                let namePtr = UnsafeRawPointer(entryPtr)
                    .advanced(by: typeOffset + MemoryLayout<UInt8>.size)
                    .assumingMemoryBound(to: CChar.self)
                let name = String(cString: namePtr)
                #else
                var entry = entryPtr.pointee
                let nameCapacity = MemoryLayout.size(ofValue: entry.d_name)
                let name = withUnsafePointer(to: &entry.d_name) { ptr in
                    ptr.withMemoryRebound(to: CChar.self, capacity: nameCapacity) { cStr in
                        String(cString: cStr)
                    }
                }
                #endif
                if name == "." || name == ".." { continue }
                let rawChild = NativeFileWatcher.joinPath(currentDir, name)
                guard let mapped = NativeFileWatcher.remapEventPath(
                    rawChild,
                    canonicalRoot: canonicalRoot,
                    requestedRoot: requestedRoot
                ), !mapped.relativePath.isEmpty else {
                    continue
                }
                if !recursive && mapped.relativePath.contains("/") { continue }
                if ignoreFilter.shouldIgnore(
                    relativePath: mapped.relativePath,
                    reportedPath: mapped.reportedPath,
                    canonicalPath: rawChild
                ) {
                    continue
                }
                #if canImport(Darwin)
                var st = Darwin.stat()
                #else
                var st = stat()
                #endif
                guard lstat(rawChild, &st) == 0 else { continue }
                let isDir = (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
                #if canImport(Darwin) || os(FreeBSD) || os(OpenBSD)
                let mSec = Int64(st.st_mtimespec.tv_sec)
                let mNsec = Int64(st.st_mtimespec.tv_nsec)
                #else
                let mSec = Int64(st.st_mtim.tv_sec)
                let mNsec = Int64(st.st_mtim.tv_nsec)
                #endif
                result[mapped.reportedPath] = EntryMeta(
                    ino: UInt64(st.st_ino),
                    size: Int64(st.st_size),
                    mtimeSec: mSec,
                    mtimeNsec: mNsec,
                    isDirectory: isDir
                )
                if recursive && isDir {
                    stack.append(rawChild)
                }
            }
        }
        #elseif !os(WASI)
        var stack: [String] = [canonicalRoot]
        while let currentDir = stack.popLast() {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: currentDir) else { continue }
            for name in names {
                let rawChild = NativeFileWatcher.joinPath(currentDir, name)
                guard let mapped = NativeFileWatcher.remapEventPath(
                    rawChild,
                    canonicalRoot: canonicalRoot,
                    requestedRoot: requestedRoot
                ), !mapped.relativePath.isEmpty else {
                    continue
                }
                if !recursive && mapped.relativePath.contains("/") { continue }
                if ignoreFilter.shouldIgnore(
                    relativePath: mapped.relativePath,
                    reportedPath: mapped.reportedPath,
                    canonicalPath: rawChild
                ) {
                    continue
                }
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: rawChild) else { continue }
                let isDir = (attrs[.type] as? FileAttributeType) == .typeDirectory
                let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                let modDate = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                let mSec = Int64(modDate)
                let mNsec = Int64((modDate - Double(mSec)) * 1_000_000_000.0)
                result[mapped.reportedPath] = EntryMeta(
                    ino: 0,
                    size: size,
                    mtimeSec: mSec,
                    mtimeNsec: mNsec,
                    isDirectory: isDir
                )
                if recursive && isDir {
                    stack.append(rawChild)
                }
            }
        }
        #endif
        return result
    }
}

// MARK: - No-Op Fallback Backend (Only When No Filesystem API Exists)

private final class FallbackWatcherDriver: NativeWatcherDriver, Sendable {
    init(
        requestedRoot: String,
        canonicalRoot: String,
        recursive: Bool,
        ignoreFilter: NativeFileWatcher.IgnoreFilter,
        coalesceIntervalMs: Int,
        emitBatch: @escaping @Sendable ([NativeFileEvent]) -> Void
    ) {
        _ = (requestedRoot, canonicalRoot, recursive, ignoreFilter, coalesceIntervalMs, emitBatch)
    }

    func start() throws {}
    func stop() {}
}
