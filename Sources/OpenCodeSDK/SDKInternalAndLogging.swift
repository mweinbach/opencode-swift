#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(WinSDK)
import WinSDK
#endif
import Synchronization
import OpenCodeClient
import OpenCodeCore
import OpenCodePlatform
import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeServer
import OpenCodeUtil

// MARK: - Structured SDK Logging (`packages/sdk/src/logging.ts`)

/// Scoped structured logging surface for embedded OpenCode hosts (`packages/sdk/src/logging.ts`).
///
/// Embedded hosts are silent by default (`log == nil`). Providing `LogOptions` emits structured
/// `LogEntry` records filtered by `level` (defaulting to `.info`) with strict error containment so
/// host loggers never disrupt OpenCode operations.
public enum SDKLogging {
    /// Severity levels supported by embedded SDK hosts.
    // parity: sdk/src/logging.ts#LogLevel [status=implemented hash=8806f873ee65]
    public enum LogLevel: String, Equatable, Hashable, Sendable, Codable, CaseIterable, Comparable {
        case trace
        case debug
        case info
        case warn
        case error
        case fatal

        private var rank: Int {
            switch self {
            case .trace: return 0
            case .debug: return 1
            case .info: return 2
            case .warn: return 3
            case .error: return 4
            case .fatal: return 5
            }
        }

        public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
            lhs.rank < rhs.rank
        }

        /// Canonical Effect/OpenCode level label (`Trace`, `Debug`, `Info`, `Warn`, `Error`, `Fatal`).
        public var effectLevelName: String {
            switch self {
            case .trace: return "Trace"
            case .debug: return "Debug"
            case .info: return "Info"
            case .warn: return "Warn"
            case .error: return "Error"
            case .fatal: return "Fatal"
            }
        }

        /// Maps an Effect/OpenCode log level name (e.g. `"Trace"`, `"Warn"`, `"Warning"`) to `LogLevel`.
        public init?(effectLevelName: String) {
            switch effectLevelName {
            case "Trace", "trace": self = .trace
            case "Debug", "debug": self = .debug
            case "Info", "info": self = .info
            case "Warn", "Warning", "warn", "warning": self = .warn
            case "Error", "error": self = .error
            case "Fatal", "fatal": self = .fatal
            default: return nil
            }
        }
    }

    /// Structured log entry delivered to an embedded host's `LogWriter`.
    // parity: sdk/src/logging.ts#LogEntry [status=implemented hash=ac433d998026]
    public struct LogEntry: Equatable, Hashable, Sendable, Codable {
        public let level: LogLevel
        public let message: String
        public let attributes: [String: JSONValue]?
        public let cause: JSONValue?

        public init(
            level: LogLevel,
            message: String,
            attributes: [String: JSONValue]? = nil,
            cause: JSONValue? = nil
        ) {
            self.level = level
            self.message = message
            self.attributes = attributes
            self.cause = cause
        }
    }

    /// Host callback receiving structured `LogEntry` records.
    // parity: sdk/src/logging.ts#LogWriter [status=implemented hash=0aa3b3b4cd50]
    public typealias LogWriter = @Sendable (LogEntry) -> Void

    /// Throwing host callback overload; failures are caught and ignored so logging never breaks operations.
    public typealias ThrowingLogWriter = @Sendable (LogEntry) throws -> Void

    /// Configuration for embedded host structured logging.
    // parity: sdk/src/logging.ts#LogOptions [status=implemented hash=6813bcec3fc1]
    public struct LogOptions: Sendable {
        public let level: LogLevel?
        public let emit: LogWriter
        private let throwingEmit: ThrowingLogWriter?

        public init(level: LogLevel? = nil, emit: @escaping LogWriter) {
            self.level = level
            self.emit = emit
            self.throwingEmit = nil
        }

        /// Convenience initializer accepting a throwing emitter whose errors are safely contained.
        public init(level: LogLevel? = nil, catchingEmit: @escaping ThrowingLogWriter) {
            self.level = level
            self.emit = { entry in
                try? catchingEmit(entry)
            }
            self.throwingEmit = catchingEmit
        }

        internal func safelyEmit(_ entry: LogEntry) {
            if let throwingEmit {
                do {
                    try throwingEmit(entry)
                } catch {
                    // A host logger must not break OpenCode operations.
                }
            } else {
                emit(entry)
            }
        }
    }

    /// Service key under which the configured SDK logger is stored in `LayerNode.Output`.
    public static let currentLoggersKey = "@opencode/sdk/CurrentLoggers"

    /// Service key under which the minimum `LogLevel` is stored in `LayerNode.Output`.
    public static let minimumLogLevelKey = "@opencode/sdk/MinimumLogLevel"

    /// Runtime logger service filtering by `minimumLevel` and formatting structured messages,
    /// annotations, spans, extra data, and causes matching `packages/sdk/src/logging.ts`.
    public final class LoggerService: Sendable {
        public let minimumLevel: LogLevel
        private let options: LogOptions?

        public init(options: LogOptions?) {
            self.options = options
            self.minimumLevel = options?.level ?? .info
        }

        /// Logs a structured message payload matching Effect's `Logger.formatStructured` normalization.
        public func log(
            level: LogLevel,
            values: [JSONValue],
            annotations: [String: JSONValue] = [:],
            spans: [String: Int64] = [:],
            cause: JSONValue? = nil
        ) {
            guard let options else { return }
            guard level >= minimumLevel else { return }

            let firstValue = values.first ?? .string("")
            let data = values.count > 1 ? Array(values.dropFirst()) : []

            let details: [String: JSONValue]?
            if data.count == 1, case .object(let dict) = data[0] {
                details = dict
            } else {
                details = nil
            }

            let detailCause = details?["cause"]
            var attributes: [String: JSONValue] = annotations
            if let details {
                for (key, value) in details where key != "cause" {
                    attributes[key] = value
                }
            }
            if !spans.isEmpty {
                var spanObj: [String: JSONValue] = [:]
                for (name, ms) in spans {
                    spanObj[name] = .int(ms)
                }
                attributes["spans"] = .object(spanObj)
            }
            if details == nil, !data.isEmpty {
                attributes["data"] = data.count == 1 ? data[0] : .array(data)
            }

            let message: String
            if case .string(let text) = firstValue {
                message = text
            } else {
                message = formatJSONValue(firstValue)
            }

            let resolvedCause = cause ?? detailCause
            let entry = LogEntry(
                level: level,
                message: message,
                attributes: attributes.isEmpty ? nil : attributes,
                cause: resolvedCause
            )
            options.safelyEmit(entry)
        }

        /// Logs by Effect log level name (e.g. `"Trace"`, `"Debug"`, `"Info"`, `"Warn"`, `"Error"`, `"Fatal"`).
        public func log(
            effectLevelName: String,
            message: String,
            details: [String: JSONValue]? = nil,
            annotations: [String: JSONValue] = [:],
            spans: [String: Int64] = [:],
            cause: JSONValue? = nil
        ) {
            guard let level = LogLevel(effectLevelName: effectLevelName) else { return }
            var values: [JSONValue] = [.string(message)]
            if let details {
                values.append(.object(details))
            }
            log(level: level, values: values, annotations: annotations, spans: spans, cause: cause)
        }

        public func trace(_ message: String, attributes: [String: JSONValue] = [:], cause: JSONValue? = nil) {
            log(level: .trace, values: [.string(message)], annotations: attributes, cause: cause)
        }

        public func debug(_ message: String, attributes: [String: JSONValue] = [:], cause: JSONValue? = nil) {
            log(level: .debug, values: [.string(message)], annotations: attributes, cause: cause)
        }

        public func info(_ message: String, attributes: [String: JSONValue] = [:], cause: JSONValue? = nil) {
            log(level: .info, values: [.string(message)], annotations: attributes, cause: cause)
        }

        public func warn(_ message: String, attributes: [String: JSONValue] = [:], cause: JSONValue? = nil) {
            log(level: .warn, values: [.string(message)], annotations: attributes, cause: cause)
        }

        public func error(_ message: String, attributes: [String: JSONValue] = [:], cause: JSONValue? = nil) {
            log(level: .error, values: [.string(message)], annotations: attributes, cause: cause)
        }

        public func fatal(_ message: String, attributes: [String: JSONValue] = [:], cause: JSONValue? = nil) {
            log(level: .fatal, values: [.string(message)], annotations: attributes, cause: cause)
        }

        private func formatJSONValue(_ value: JSONValue) -> String {
            switch value {
            case .string(let s): return s
            case .null: return "null"
            case .bool(let b): return b ? "true" : "false"
            case .int(let i): return String(i)
            case .double(let d): return String(d)
            case .array, .object:
                return (try? ClientCodec.encodeString(value)) ?? String(describing: value)
            }
        }
    }

    /// Builds a `LayerNode.ExecutableLayer` replacing default logging with the SDK logger
    /// and setting `MinimumLogLevel` (default `.info`).
    // parity: sdk/src/logging.ts#layer [status=implemented hash=8f502ada6a1e]
    public static func layer(_ log: LogOptions? = nil) -> LayerNode.ExecutableLayer {
        let logger = LoggerService(options: log)
        let minimumLevel = log?.level ?? .info
        return LayerNode.ExecutableLayer { _, _ in
            LayerNode.Output([
                currentLoggersKey: logger,
                minimumLogLevelKey: minimumLevel,
            ])
        }
    }

    /// Extracts only the logger and minimum log level entries from `source` into a minimal context.
    // parity: sdk/src/logging.ts#context [status=implemented hash=20dc4cc1d34b]
    public static func context(_ source: LayerNode.Output) -> LayerNode.Output {
        var services: [String: any Sendable] = [:]
        if let logger = source.get(currentLoggersKey, as: LoggerService.self) {
            services[currentLoggersKey] = logger
        }
        if let minLevel = source.get(minimumLogLevelKey, as: LogLevel.self) {
            services[minimumLogLevelKey] = minLevel
        }
        return LayerNode.Output(services)
    }
}

// MARK: - Owned In-Process Fetch Transport (`packages/sdk/src/internal/fetch.ts`)

/// Request-tracking in-process HTTP/streaming transport owning request cancellation,
/// response stream tracking, and ordered host teardown (`packages/sdk/src/internal/fetch.ts`).
public enum OwnedFetch {
    /// Sentinel error thrown when sending requests to a closed host or aborting in-flight requests on shutdown.
    public struct ClosedError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public let message: String

        public init(message: String = "OpenCode host is closed") {
            self.message = message
        }

        public var description: String { message }

        public static let shared = ClosedError()
    }

    /// Handler result returned by an in-process router: either a buffered response or a streaming response.
    public enum HandlerResponse: Sendable {
        case buffered(HTTPResponse)
        case streaming(HTTPStreamingResponse)
    }

    /// Request handler accepting an `HTTPRequest` and a host-owned per-request `AbortSignal`.
    public typealias RequestHandler = @Sendable (HTTPRequest, AbortSignal) async throws -> HandlerResponse

    /// Simple buffered-only handler overload matching Web `fetch` handlers returning a single response.
    public typealias BufferedHandler = @Sendable (HTTPRequest, AbortSignal) async throws -> HTTPResponse

    /// In-process `HTTPTransport` whose active requests and open streaming bodies are cancelled and
    /// drained before `dispose()` runs on `close()`.
    public final class Transport: HTTPTransport, Sendable {
        private final class RequestLifetime: Sendable {
            private struct State: Sendable {
                var finished: Bool = false
                var waiters: [CheckedContinuation<Void, Never>] = []
            }

            let controller: AbortController
            private let state = Mutex(State())

            init(controller: AbortController) {
                self.controller = controller
            }

            func finish() -> Bool {
                let waiters: [CheckedContinuation<Void, Never>]? = state.withLock { s in
                    if s.finished { return nil }
                    s.finished = true
                    let list = s.waiters
                    s.waiters.removeAll()
                    return list
                }
                guard let waiters else { return false }
                for waiter in waiters {
                    waiter.resume()
                }
                return true
            }

            func awaitCompletion() async {
                if state.withLock({ $0.finished }) { return }
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    let resumeNow: Bool = state.withLock { s in
                        if s.finished { return true }
                        s.waiters.append(continuation)
                        return false
                    }
                    if resumeNow {
                        continuation.resume()
                    }
                }
            }
        }

        private struct State: Sendable {
            var nextID: UInt64 = 1
            var requests: [UInt64: RequestLifetime] = [:]
            var isClosing: Bool = false
            var closeTask: Task<Void, Never>? = nil
        }

        private let handler: RequestHandler
        private let dispose: @Sendable () async -> Void
        private let state = Mutex(State())

        internal init(
            handler: @escaping RequestHandler,
            dispose: @escaping @Sendable () async -> Void
        ) {
            self.handler = handler
            self.dispose = dispose
        }

        /// Number of currently active (in-flight or open-stream) requests tracked by this transport.
        public var activeRequestCount: Int {
            state.withLock { $0.requests.count }
        }

        /// Whether `close()` has been initiated on this transport.
        public var isClosed: Bool {
            state.withLock { $0.isClosing }
        }

        /// Sends a buffered HTTP request with optional caller `AbortSignal`.
        public func fetch(_ request: HTTPRequest, signal sourceSignal: AbortSignal? = nil) async throws -> HTTPResponse {
            let outcome = try await execute(request, signal: sourceSignal)
            switch outcome.response {
            case .buffered(let response):
                outcome.finish()
                return response
            case .streaming(let streaming):
                let tracked = trackResponse(streaming, signal: outcome.signal, finish: outcome.finish)
                var body: [UInt8] = []
                for try await chunk in tracked.chunks {
                    body.append(contentsOf: chunk)
                }
                return HTTPResponse(head: tracked.head, body: body)
            }
        }

        /// Sends a streaming HTTP request with optional caller `AbortSignal`, tracking the response body
        /// until fully consumed, cancelled by the caller, or aborted by host shutdown.
        public func fetchStream(
            _ request: HTTPRequest,
            signal sourceSignal: AbortSignal? = nil
        ) async throws -> HTTPStreamingResponse {
            let outcome = try await execute(request, signal: sourceSignal)
            switch outcome.response {
            case .buffered(let response):
                outcome.finish()
                let body = response.body
                let chunks = AsyncThrowingStream<[UInt8], Error> { continuation in
                    if !body.isEmpty {
                        continuation.yield(body)
                    }
                    continuation.finish()
                }
                return HTTPStreamingResponse(head: response.head, chunks: chunks)
            case .streaming(let streaming):
                return trackResponse(streaming, signal: outcome.signal, finish: outcome.finish)
            }
        }

        // MARK: HTTPTransport

        public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            try await fetch(request, signal: nil)
        }

        public func stream(_ request: HTTPRequest) async throws -> HTTPStreamingResponse {
            try await fetchStream(request, signal: nil)
        }

        /// Idempotently closes this transport: rejects new requests, aborts every in-flight request
        /// and open streaming body with `ClosedError("OpenCode host is closed")`, waits for all
        /// tracked requests to settle, and finally runs `dispose()`.
        public func close() async {
            let task: Task<Void, Never> = state.withLock { s in
                if let existing = s.closeTask {
                    return existing
                }
                s.isClosing = true
                let active = Array(s.requests.values)
                let disposeFn = self.dispose
                let created = Task {
                    for lifetime in active {
                        lifetime.controller.abort(reason: ClosedError.shared)
                    }
                    for lifetime in active {
                        await lifetime.awaitCompletion()
                    }
                    await disposeFn()
                }
                s.closeTask = created
                return created
            }
            await task.value
        }

        private struct ExecuteOutcome: Sendable {
            let response: HandlerResponse
            let signal: AbortSignal
            let finish: @Sendable () -> Void
        }

        private func execute(
            _ request: HTTPRequest,
            signal sourceSignal: AbortSignal?
        ) async throws -> ExecuteOutcome {
            if let sourceSignal, sourceSignal.isAborted {
                throw sourceSignal.reason ?? AbortError.sharedReason
            }

            let controller = AbortController()
            let lifetime = RequestLifetime(controller: controller)
            let requestID: UInt64? = state.withLock { s in
                if s.isClosing { return nil }
                let id = s.nextID
                s.nextID &+= 1
                s.requests[id] = lifetime
                return id
            }
            guard let requestID else {
                throw ClosedError.shared
            }

            let removeSourceListener: @Sendable () -> Void
            if let sourceSignal {
                removeSourceListener = sourceSignal.onAbort {
                    controller.abort(reason: sourceSignal.reason ?? AbortError.sharedReason)
                }
            } else {
                removeSourceListener = {}
            }

            let finish: @Sendable () -> Void = { [weak self] in
                if lifetime.finish() {
                    removeSourceListener()
                    _ = self?.state.withLock { $0.requests.removeValue(forKey: requestID) }
                }
            }

            let handlerFn = self.handler
            let handledTask = Task<HandlerResponse, any Error> {
                try await handlerFn(request, controller.signal)
            }

            do {
                let response = try await rejectOnAbort(task: handledTask, signal: controller.signal)
                return ExecuteOutcome(response: response, signal: controller.signal, finish: finish)
            } catch {
                // Keep request tracked until the underlying handler task settles (matching `void handled.then(finish, finish)`).
                Task {
                    _ = await handledTask.result
                    finish()
                }
                throw error
            }
        }

        private func rejectOnAbort(
            task: Task<HandlerResponse, any Error>,
            signal: AbortSignal
        ) async throws -> HandlerResponse {
            if signal.isAborted {
                throw signal.reason ?? AbortError.sharedReason
            }
            return try await withCheckedThrowingContinuation { continuation in
                let gate = Mutex(false)
                let resumeOnce: @Sendable (Result<HandlerResponse, any Error>) -> Void = { result in
                    let shouldResume = gate.withLock { resumed -> Bool in
                        if resumed { return false }
                        resumed = true
                        return true
                    }
                    if shouldResume {
                        continuation.resume(with: result)
                    }
                }
                let removeAbort = signal.onAbort {
                    resumeOnce(.failure(signal.reason ?? AbortError.sharedReason))
                }
                Task {
                    let result = await task.result
                    removeAbort()
                    resumeOnce(result)
                }
            }
        }

        private func trackResponse(
            _ response: HTTPStreamingResponse,
            signal: AbortSignal,
            finish: @escaping @Sendable () -> Void
        ) -> HTTPStreamingResponse {
            let upstream = response.chunks
            let wrapped = AsyncThrowingStream<[UInt8], Error> { continuation in
                let done = Mutex(false)
                let pumpHolder = Mutex<Task<Void, Never>?>(nil)
                let removeAbortHolder = Mutex<(@Sendable () -> Void)?>(nil)

                let completeOnce: @Sendable () -> Bool = {
                    let shouldComplete = done.withLock { flag -> Bool in
                        if flag { return false }
                        flag = true
                        return true
                    }
                    if shouldComplete {
                        let remove = removeAbortHolder.withLock { fn -> (@Sendable () -> Void)? in
                            let copy = fn
                            fn = nil
                            return copy
                        }
                        remove?()
                    }
                    return shouldComplete
                }

                let abortAction: @Sendable () -> Void = {
                    guard completeOnce() else { return }
                    let reason = signal.reason ?? AbortError.sharedReason
                    continuation.finish(throwing: reason)
                    let pump = pumpHolder.withLock { $0 }
                    pump?.cancel()
                    Task {
                        if let pump {
                            _ = await pump.value
                        }
                        finish()
                    }
                }

                let pump = Task {
                    do {
                        for try await chunk in upstream {
                            if Task.isCancelled || signal.isAborted { break }
                            continuation.yield(chunk)
                        }
                        if completeOnce() {
                            continuation.finish()
                            finish()
                        }
                    } catch {
                        if completeOnce() {
                            continuation.finish(throwing: error)
                            finish()
                        }
                    }
                }
                pumpHolder.withLock { $0 = pump }

                if signal.isAborted {
                    abortAction()
                } else {
                    let remove = signal.onAbort(abortAction)
                    removeAbortHolder.withLock { $0 = remove }
                    if signal.isAborted {
                        abortAction()
                    }
                }

                continuation.onTermination = { _ in
                    guard completeOnce() else { return }
                    let activePump = pumpHolder.withLock { $0 }
                    activePump?.cancel()
                    Task {
                        if let activePump {
                            _ = await activePump.value
                        }
                        finish()
                    }
                }
            }
            return HTTPStreamingResponse(head: response.head, chunks: wrapped)
        }
    }

    /// Creates a request-tracking in-process `Transport` wrapping `handler` and `dispose`.
    // parity: sdk/src/internal/fetch.ts#make [status=implemented hash=fd82c48966d1]
    public static func make(
        handler: @escaping RequestHandler,
        dispose: @escaping @Sendable () async -> Void
    ) -> Transport {
        Transport(handler: handler, dispose: dispose)
    }

    /// Convenience overload for handlers that return buffered `HTTPResponse` values.
    public static func make(
        bufferedHandler: @escaping BufferedHandler,
        dispose: @escaping @Sendable () async -> Void
    ) -> Transport {
        Transport(
            handler: { request, signal in
                .buffered(try await bufferedHandler(request, signal))
            },
            dispose: dispose
        )
    }
}

// MARK: - Session-Selected Instances (`packages/sdk/src/internal/instances.ts`)

/// Session-keyed instance selector and cache (`packages/sdk/src/internal/instances.ts`).
///
/// Sessions sharing the same `(applicationKey, canonical(location))` share one live instance;
/// different directories or workspace IDs always acquire separate instances. Configuration or
/// instance-plugin failures (including ID collisions with host plugins) reject acquisition,
/// tear down the failed generation, and evict the cache entry so subsequent requests can retry.
public enum SdkInstances {
    /// Error thrown when one or more configured instance plugins fail activation or collide with host plugin IDs.
    public struct InstancePluginSetupError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public let failedIDs: [String]

        public init(failedIDs: [String]) {
            self.failedIDs = failedIDs
        }

        public var message: String {
            "Instance plugin setup failed: \(failedIDs.joined(separator: ", "))"
        }

        public var description: String { message }
    }

    /// Cache key pairing an application-selected key with a canonicalized `LocationSchema.Ref`.
    public struct InstanceKey: Equatable, Hashable, Sendable {
        public let key: String
        public let location: LocationSchema.Ref

        public init(key: String, location: LocationSchema.Ref) {
            self.key = key
            self.location = CoreLocation.ServiceMap.canonical(location)
        }
    }

    /// Per-instance plugin configuration returned by `Options.configure`.
    // parity: sdk/src/internal/instances.ts#Configuration [status=implemented hash=bb8c73c0d5b2]
    public struct Configuration: Sendable {
        public let plugins: CorePlugin.InstancePlugins.List

        public init(plugins: CorePlugin.InstancePlugins.List = []) {
            self.plugins = plugins
        }
    }

    /// Session-selected instance selector and lazy factory.
    // parity: sdk/src/internal/instances.ts#Options [status=adapted hash=0274a2ddfb4b]
    public struct Options: Sendable {
        /// Select a sharing key within the Session's current Location. Must not initialize plugins.
        public let key: @Sendable (SessionSchema.Info) throws -> String
        /// Reconstruct configuration on a cache miss, including after a host restart.
        /// Resources added to `scope` belong to the instance Scope; `services` carries the services
        /// provided where the SDK entrypoint was built.
        public let configure: @Sendable (
            _ key: String,
            _ scope: LayerNode.ResourceScope,
            _ services: LayerNode.Output
        ) async throws -> Configuration

        public init(
            key: @escaping @Sendable (SessionSchema.Info) throws -> String,
            configure: @escaping @Sendable (
                _ key: String,
                _ scope: LayerNode.ResourceScope,
                _ services: LayerNode.Output
            ) async throws -> Configuration
        ) {
            self.key = key
            self.configure = configure
        }

        /// Convenience initializer when `configure` needs only the key and instance `ResourceScope`.
        public init(
            key: @escaping @Sendable (SessionSchema.Info) throws -> String,
            configure: @escaping @Sendable (_ key: String, _ scope: LayerNode.ResourceScope) async throws -> Configuration
        ) {
            self.key = key
            self.configure = { key, scope, _ in
                try await configure(key, scope)
            }
        }

        /// Convenience initializer when `configure` depends only on the key.
        public init(
            key: @escaping @Sendable (SessionSchema.Info) throws -> String,
            configure: @escaping @Sendable (_ key: String) async throws -> Configuration
        ) {
            self.key = key
            self.configure = { key, _, _ in
                try await configure(key)
            }
        }
    }

    /// Closes `configure` over services captured where the SDK entrypoint was built; ambient
    /// services merge on top so the instance `ResourceScope` always owns configured resources.
    // parity: sdk/src/internal/instances.ts#provide [status=adapted hash=96afa6324656]
    public static func provide(_ options: Options, context: LayerNode.Output) -> Options {
        Options(
            key: options.key,
            configure: { key, scope, ambient in
                try await options.configure(key, scope, context.merging(ambient))
            }
        )
    }

    /// Live service container managed per `(key, canonical(location))` entry.
    public final class InstanceContainer: Sendable {
        public let instanceKey: InstanceKey
        public let services: LayerNode.Output
        public let pluginEnvironment: CorePlugin.Host.Environment
        public let pluginService: CorePlugin.Service
        public let scope: LayerNode.ResourceScope

        internal init(
            instanceKey: InstanceKey,
            services: LayerNode.Output,
            pluginEnvironment: CorePlugin.Host.Environment,
            pluginService: CorePlugin.Service,
            scope: LayerNode.ResourceScope
        ) {
            self.instanceKey = instanceKey
            self.services = services
            self.pluginEnvironment = pluginEnvironment
            self.pluginService = pluginService
            self.scope = scope
        }

        internal func close() async {
            await pluginService.close()
            await scope.close()
        }
    }

    /// Process-host instance selector caching live per-`(key, location)` instances with
    /// single-flight construction, cancelled-borrower isolation, activation validation, and eviction on failure.
    public final class SelectorService: CoreLocation.Instance.Interface, Sendable {
        public static let serviceKey = CoreLocation.Instance.Service.serviceKey

        private struct State: Sendable {
            var cached: [InstanceKey: InstanceContainer] = [:]
            var inFlight: [InstanceKey: Task<InstanceContainer, any Error>] = [:]
            var closed: Bool = false
        }

        private let options: Options
        private let locations: CoreLocation.ServiceMap.Service
        private let replacements: @Sendable () -> LayerNode.Replacements
        private let sdkPlugins: CorePlugin.SdkPlugins.Service?
        private let appInfo: PluginContract.App
        private let fileSystem: any OpenCodeFileSystem
        private let state = Mutex(State())

        public init(
            options: Options,
            locations: CoreLocation.ServiceMap.Service,
            replacements: @escaping @Sendable () -> LayerNode.Replacements,
            sdkPlugins: CorePlugin.SdkPlugins.Service? = nil,
            appInfo: PluginContract.App = PluginContract.App(name: "sdk", version: "unknown", channel: "unknown"),
            fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared
        ) {
            self.options = options
            self.locations = locations
            self.replacements = replacements
            self.sdkPlugins = sdkPlugins
            self.appInfo = appInfo
            self.fileSystem = fileSystem
        }

        public func instanceKey(for session: SessionSchema.Info) throws -> InstanceKey {
            let appKey = try options.key(session)
            let locationRef = LocationSchema.Ref(
                directory: SchemaPrimitive.AbsolutePath(rawValue: session.location.directory),
                workspaceID: session.location.workspaceID
            )
            return InstanceKey(key: appKey, location: locationRef)
        }

        /// Returns whether an instance for `session` is currently cached and live.
        public func live(session: SessionSchema.Info) -> Bool {
            guard let key = try? instanceKey(for: session) else { return false }
            return state.withLock { $0.cached[key] != nil }
        }

        /// Acquires (or returns cached) instance container for `session`.
        public func acquire(session: SessionSchema.Info) async throws -> InstanceContainer {
            let key = try instanceKey(for: session)
            return try await acquire(key: key)
        }

        /// Runs `operation` with the acquired instance services for `session`.
        public func provide<T: Sendable>(
            session: SessionSchema.Info,
            operation: @Sendable (InstanceContainer) async throws -> T
        ) async throws -> T {
            let container = try await acquire(session: session)
            return try await operation(container)
        }

        // MARK: CoreLocation.Instance.Interface

        public func provide<T: Sendable>(
            location: LocationSchema.Ref,
            operation: @Sendable (CoreLocation.Instance.Services) async throws -> T
        ) async throws -> T {
            let services = try await locations.get(location)
            return try await operation(services)
        }

        public func live(location: LocationSchema.Ref) async -> Bool {
            locations.has(location)
        }

        /// Invalidates and tears down the cached instance for `key`, if present.
        public func invalidate(_ key: InstanceKey) async {
            let removed = state.withLock { $0.cached.removeValue(forKey: key) }
            if let removed {
                await removed.close()
            }
        }

        /// Tears down all cached instances and drains any in-flight constructions on host shutdown.
        public func closeAll() async {
            let (cached, inFlight): ([InstanceContainer], [Task<InstanceContainer, any Error>]) = state.withLock { s in
                s.closed = true
                let c = Array(s.cached.values)
                let f = Array(s.inFlight.values)
                s.cached.removeAll()
                s.inFlight.removeAll()
                return (c, f)
            }
            for task in inFlight {
                if let container = try? await task.value {
                    await container.close()
                }
            }
            for container in cached {
                await container.close()
            }
        }

        private func acquire(key: InstanceKey) async throws -> InstanceContainer {
            if Task.isCancelled {
                throw CancellationError()
            }

            enum Lookup {
                case closed
                case hit(InstanceContainer)
                case wait(Task<InstanceContainer, any Error>)
            }

            let lookup: Lookup = state.withLock { s in
                if s.closed { return .closed }
                if let existing = s.cached[key] {
                    return .hit(existing)
                }
                if let existingTask = s.inFlight[key] {
                    return .wait(existingTask)
                }
                // Spawn construction decoupled from any single borrower's Task cancellation so a
                // cancelled borrower cannot strand a later failed construction (`instances-lifecycle.test.ts`).
                let buildTask = Task<InstanceContainer, any Error> { [self] in
                    try await self.construct(key: key)
                }
                s.inFlight[key] = buildTask
                return .wait(buildTask)
            }

            switch lookup {
            case .closed:
                throw OwnedFetch.ClosedError.shared
            case .hit(let container):
                return container
            case .wait(let task):
                return try await awaitCancellable(task)
            }
        }

        private func awaitCancellable(_ task: Task<InstanceContainer, any Error>) async throws -> InstanceContainer {
            if Task.isCancelled {
                throw CancellationError()
            }

            final class WaitBox: Sendable {
                private struct WaitState: Sendable {
                    var cancelled: Bool = false
                    var resumed: Bool = false
                    var continuation: CheckedContinuation<InstanceContainer, any Error>? = nil
                    var watcher: Task<Void, Never>? = nil
                }

                private let state = Mutex(WaitState())

                func install(
                    continuation: CheckedContinuation<InstanceContainer, any Error>,
                    task: Task<InstanceContainer, any Error>
                ) {
                    let alreadyCancelled: Bool = state.withLock { s in
                        if s.cancelled {
                            s.resumed = true
                            return true
                        }
                        s.continuation = continuation
                        return false
                    }
                    if alreadyCancelled {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    let watcher = Task { [self] in
                        let result = await task.result
                        let cont: CheckedContinuation<InstanceContainer, any Error>? = self.state.withLock { s in
                            if s.resumed { return nil }
                            s.resumed = true
                            let c = s.continuation
                            s.continuation = nil
                            return c
                        }
                        cont?.resume(with: result)
                    }
                    state.withLock { s in
                        if s.resumed {
                            watcher.cancel()
                        } else {
                            s.watcher = watcher
                        }
                    }
                }

                func cancel() {
                    let (cont, watcher): (CheckedContinuation<InstanceContainer, any Error>?, Task<Void, Never>?) = state.withLock { s in
                        s.cancelled = true
                        let w = s.watcher
                        s.watcher = nil
                        if s.resumed {
                            return (nil, w)
                        }
                        s.resumed = true
                        let c = s.continuation
                        s.continuation = nil
                        return (c, w)
                    }
                    watcher?.cancel()
                    cont?.resume(throwing: CancellationError())
                }
            }

            let box = WaitBox()
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    box.install(continuation: continuation, task: task)
                }
            } onCancel: {
                // Cancel only this borrower's wait; construction `task` owns its own cleanup and eviction.
                box.cancel()
            }
        }

        private func construct(key: InstanceKey) async throws -> InstanceContainer {
            let instanceScope = LayerNode.ResourceScope()
            var pluginService: CorePlugin.Service? = nil

            do {
                let configuration = try await options.configure(key.key, instanceScope, LayerNode.Output())
                let boundInstancePlugins = try CorePlugin.InstancePlugins.bound(configuration.plugins)

                let locationInfo = LocationSchema.Info(
                    directory: key.location.directory,
                    workspaceID: key.location.workspaceID,
                    project: LocationSchema.ProjectRef(
                        id: ProjectID.global,
                        directory: key.location.directory,
                        canonical: key.location.directory
                    )
                )
                let env = CorePlugin.Host.Environment(
                    app: appInfo,
                    location: locationInfo
                )
                let service = CorePlugin.Service(
                    fileSystem: fileSystem,
                    contextFactory: { pluginID, listInventory, addFinalizer in
                        CorePlugin.Host.make(
                            environment: env,
                            pluginID: pluginID,
                            listPlugins: listInventory,
                            addFinalizer: addFinalizer
                        )
                    }
                )
                pluginService = service

                // Host plugins activate first so host IDs win on collision; colliding instance plugins
                // are reported failed in the inventory and reject instance acquisition.
                let hostGenerations = sdkPlugins?.all() ?? []
                let instanceGenerations = boundInstancePlugins.all()
                var seenIDs: Set<String> = []
                var uniquePlugins: [CorePlugin.Generation] = []
                var failures: [CorePlugin.Failure] = []
                for gen in hostGenerations + instanceGenerations {
                    if seenIDs.insert(gen.id).inserted {
                        uniquePlugins.append(gen)
                    } else {
                        failures.append(
                            CorePlugin.Failure(
                                id: PluginSchema.ID(rawValue: gen.id),
                                source: gen.source ?? .sdk,
                                features: gen.features ?? PluginSchema.Features(server: true),
                                error: "Duplicate plugin ID: \(gen.id)"
                            )
                        )
                    }
                }

                try await service.activate(uniquePlugins, failures: failures)
                await service.awaitActivation()

                let configuredIDs = Set(configuration.plugins.map(\.id))
                let failedIDs = service.list().compactMap { info -> String? in
                    guard case .failed = info.state, let id = info.id?.rawValue, configuredIDs.contains(id) else {
                        return nil
                    }
                    return id
                }
                if !failedIDs.isEmpty {
                    throw InstancePluginSetupError(failedIDs: failedIDs)
                }

                // Borrow this selector and the host's Location map without retaining their scopes.
                var allReplacements = replacements()
                allReplacements.append(
                    CoreLocation.Instance.node.replace(
                        with: LayerNode.ExecutableLayer.succeed(key: CoreLocation.Instance.Service.serviceKey, value: self)
                    )
                )
                allReplacements.append(
                    CoreLocation.ServiceMap.node.replace(
                        with: LayerNode.ExecutableLayer.succeed(key: CoreLocation.ServiceMap.Service.serviceKey, value: locations)
                    )
                )
                allReplacements.append(
                    CorePlugin.InstancePlugins.node.replace(
                        with: LayerNode.ExecutableLayer.succeed(key: CorePlugin.InstancePlugins.Service.serviceKey, value: boundInstancePlugins)
                    )
                )
                allReplacements.append(
                    CorePlugin.node.replace(
                        with: LayerNode.ExecutableLayer.succeed(key: CorePlugin.Service.serviceKey, value: service)
                    )
                )

                let compiled = try CoreLocation.Instance.layer(
                    key.location,
                    options: CoreLocation.Instance.Options(discovery: false, replacements: allReplacements)
                )
                let builtServices = try await compiled.build(scope: instanceScope)
                let enriched = builtServices.merging(
                    LayerNode.Output([
                        CorePlugin.Service.serviceKey: service,
                        CorePlugin.Hooks.Service.serviceKey: env.hooks,
                        CorePlugin.InstancePlugins.Service.serviceKey: boundInstancePlugins,
                    ])
                )

                let container = InstanceContainer(
                    instanceKey: key,
                    services: enriched,
                    pluginEnvironment: env,
                    pluginService: service,
                    scope: instanceScope
                )

                let shouldDisposeImmediately: Bool = state.withLock { s in
                    s.inFlight.removeValue(forKey: key)
                    if s.closed {
                        return true
                    }
                    s.cached[key] = container
                    return false
                }
                if shouldDisposeImmediately {
                    await container.close()
                    throw OwnedFetch.ClosedError.shared
                }
                return container
            } catch {
                // Evict failed construction and release any resources acquired during `configure` or partial activation.
                state.withLock { s in
                    s.inFlight.removeValue(forKey: key)
                    s.cached.removeValue(forKey: key)
                }
                if let pluginService {
                    await pluginService.close()
                }
                await instanceScope.close()
                throw error
            }
        }
    }

    /// Replaces the host's `Instance.node`; `replacements` resolves lazily so instances inherit the final host graph.
    // parity: sdk/src/internal/instances.ts#node [status=adapted hash=312e0c13be53]
    public static func node(
        _ options: Options,
        replacements: @escaping @Sendable () -> LayerNode.Replacements
    ) -> LayerNode.Provider {
        AppNode.makeGlobalNode(
            CoreLocation.Instance.Service.serviceKey,
            layer(options, replacements: replacements),
            [CoreLocation.ServiceMap.node]
        )
    }

    /// Builds a `LayerNode.ExecutableLayer` producing a `SelectorService` scoped to the host's `ResourceScope`.
    // parity: sdk/src/internal/instances.ts#layer [status=adapted hash=58ac0ac8e40d]
    public static func layer(
        _ options: Options,
        replacements: @escaping @Sendable () -> LayerNode.Replacements
    ) -> LayerNode.ExecutableLayer {
        LayerNode.ExecutableLayer { deps, scope in
            let locations = deps.get(CoreLocation.ServiceMap.Service.serviceKey, as: CoreLocation.ServiceMap.Service.self)
                ?? CoreLocation.ServiceMap.Service { ref, locScope in
                    let compiled = try CoreLocation.Instance.layer(ref, options: CoreLocation.Instance.Options(discovery: false))
                    return try await compiled.build(scope: locScope)
                }
            let sdkPlugins = deps.get(CorePlugin.SdkPlugins.Service.serviceKey, as: CorePlugin.SdkPlugins.Service.self)
            let app = deps.get(CoreSubsystems.App.Service.serviceKey, as: CoreSubsystems.App.Service.self)?.info
                ?? CoreSubsystems.App.make(name: "sdk")
            let fs = deps.get(LayerNodePlatform.fileSystemKey, as: (any OpenCodeFileSystem).self) ?? LocalFileSystem.shared
            let selector = SelectorService(
                options: options,
                locations: locations,
                replacements: replacements,
                sdkPlugins: sdkPlugins,
                appInfo: PluginContract.App(name: app.name, version: app.version, channel: app.channel),
                fileSystem: fs
            )
            scope.addFinalizer {
                await selector.closeAll()
            }
            return LayerNode.Output([
                CoreLocation.Instance.Service.serviceKey: selector,
            ])
        }
    }
}

// MARK: - Embedded Server Options (Decoupled from Parallel `OpenCodeServer` Worktree)

/// Embedded host configuration mirroring `Omit<ServerOptions, "hostname" | "port" | "password">`.
/// Defined in `OpenCodeSDK` so SDK compiles standalone while `OpenCodeServer` evolves independently.
public struct EmbeddedServerOptions: Sendable {
    public struct AppOptions: Equatable, Hashable, Sendable, Codable {
        public let name: String?
        public let version: String?
        public let channel: String?

        public init(name: String? = nil, version: String? = nil, channel: String? = nil) {
            self.name = name
            self.version = version
            self.channel = channel
        }
    }

    public struct EventsOptions: Equatable, Hashable, Sendable, Codable {
        public let persist: Bool?

        public init(persist: Bool? = nil) {
            self.persist = persist
        }
    }

    public struct ConfigOptions: Equatable, Hashable, Sendable, Codable {
        public let directory: String?
        public let project: Bool?
        public let claude: Bool?
        public let file: String?
        public let content: String?

        public init(
            directory: String? = nil,
            project: Bool? = nil,
            claude: Bool? = nil,
            file: String? = nil,
            content: String? = nil
        ) {
            self.directory = directory
            self.project = project
            self.claude = claude
            self.file = file
            self.content = content
        }
    }

    public struct InstructionsOptions: Equatable, Hashable, Sendable, Codable {
        public let claude: Bool?

        public init(claude: Bool? = nil) {
            self.claude = claude
        }
    }

    public struct WindowsOptions: Equatable, Hashable, Sendable, Codable {
        public let gitbash: String?

        public init(gitbash: String? = nil) {
            self.gitbash = gitbash
        }
    }

    public struct FileSystemOptions: Equatable, Hashable, Sendable, Codable {
        public let filewatcher: Bool?
        public let fff: Bool?

        public init(filewatcher: Bool? = nil, fff: Bool? = nil) {
            self.filewatcher = filewatcher
            self.fff = fff
        }
    }

    public var app: AppOptions?
    public var cors: [String]?
    public var simulation: Bool?
    public var database: CoreDatabaseStore.Options?
    public var pty: CorePty.Persistent.Options?
    public var events: EventsOptions?
    public var models: CoreModel.ModelsDev.Options?
    public var fetch: LayerNodePlatform.Fetch?
    public var config: ConfigOptions?
    public var instructions: InstructionsOptions?
    public var windows: WindowsOptions?
    public var fs: FileSystemOptions?

    public init(
        app: AppOptions? = nil,
        cors: [String]? = nil,
        simulation: Bool? = nil,
        database: CoreDatabaseStore.Options? = nil,
        pty: CorePty.Persistent.Options? = nil,
        events: EventsOptions? = nil,
        models: CoreModel.ModelsDev.Options? = nil,
        fetch: LayerNodePlatform.Fetch? = nil,
        config: ConfigOptions? = nil,
        instructions: InstructionsOptions? = nil,
        windows: WindowsOptions? = nil,
        fs: FileSystemOptions? = nil
    ) {
        self.app = app
        self.cors = cors
        self.simulation = simulation
        self.database = database
        self.pty = pty
        self.events = events
        self.models = models
        self.fetch = fetch
        self.config = config
        self.instructions = instructions
        self.windows = windows
        self.fs = fs
    }
}

// MARK: - Workerd Runtime Profile (`packages/sdk/src/internal/workerd.ts`)

/// Cloudflare Workers / Durable Object runtime profile (`packages/sdk/src/internal/workerd.ts`).
public enum WorkerdProfile {
    /// Typed inline configuration omitting disk-discovered `plugins` (`Omit<Config.Info, "plugins">`).
    // parity: sdk/src/internal/workerd.ts#Configuration [status=implemented hash=9e37b006263b]
    public struct Configuration: Equatable, Hashable, Sendable, Codable {
        public var schema: String?
        public var shell: String?
        public var model: ConfigModelSchema.Selection?
        public var defaultAgent: String?
        public var update: ConfigSchema.UpdateMode?
        public var share: ConfigSchema.ShareMode?
        public var enterprise: ConfigSchema.Enterprise?
        public var username: String?
        public var timezone: String?
        public var permissions: PermissionSchema.Ruleset?
        public var policies: [ConfigPolicySchema.Info]?
        public var agents: [String: ConfigAgentSchema.Info]?
        public var snapshots: Bool?
        public var watcher: ConfigWatcherSchema.Info?
        public var formatter: ConfigFormatterSchema.Info?
        public var lsp: ConfigLSPSchema.Info?
        public var media: ConfigMediaSchema.Info?
        public var toolOutput: ConfigToolOutputSchema.Info?
        public var mcp: ConfigMCPSchema.Info?
        public var compaction: ConfigCompactionSchema.Info?
        public var skills: [String]?
        public var commands: [String: ConfigCommandSchema.Info]?
        public var instructions: [String]?
        public var references: ConfigReferenceSchema.Info?
        public var websearch: ConfigWebSearchSchema.Selection?
        public var worktree: ConfigWorktreeSchema.Info?
        public var warming: ConfigWarmingSchema.Warming?
        public var providers: [String: ConfigProviderSchema.Info]?
        public var experimental: ConfigExperimentalSchema.Info?

        public init(
            schema: String? = nil,
            shell: String? = nil,
            model: ConfigModelSchema.Selection? = nil,
            defaultAgent: String? = nil,
            update: ConfigSchema.UpdateMode? = nil,
            share: ConfigSchema.ShareMode? = nil,
            enterprise: ConfigSchema.Enterprise? = nil,
            username: String? = nil,
            timezone: String? = nil,
            permissions: PermissionSchema.Ruleset? = nil,
            policies: [ConfigPolicySchema.Info]? = nil,
            agents: [String: ConfigAgentSchema.Info]? = nil,
            snapshots: Bool? = nil,
            watcher: ConfigWatcherSchema.Info? = nil,
            formatter: ConfigFormatterSchema.Info? = nil,
            lsp: ConfigLSPSchema.Info? = nil,
            media: ConfigMediaSchema.Info? = nil,
            toolOutput: ConfigToolOutputSchema.Info? = nil,
            mcp: ConfigMCPSchema.Info? = nil,
            compaction: ConfigCompactionSchema.Info? = nil,
            skills: [String]? = nil,
            commands: [String: ConfigCommandSchema.Info]? = nil,
            instructions: [String]? = nil,
            references: ConfigReferenceSchema.Info? = nil,
            websearch: ConfigWebSearchSchema.Selection? = nil,
            worktree: ConfigWorktreeSchema.Info? = nil,
            warming: ConfigWarmingSchema.Warming? = nil,
            providers: [String: ConfigProviderSchema.Info]? = nil,
            experimental: ConfigExperimentalSchema.Info? = nil
        ) {
            self.schema = schema
            self.shell = shell
            self.model = model
            self.defaultAgent = defaultAgent
            self.update = update
            self.share = share
            self.enterprise = enterprise
            self.username = username
            self.timezone = timezone
            self.permissions = permissions
            self.policies = policies
            self.agents = agents
            self.snapshots = snapshots
            self.watcher = watcher
            self.formatter = formatter
            self.lsp = lsp
            self.media = media
            self.toolOutput = toolOutput
            self.mcp = mcp
            self.compaction = compaction
            self.skills = skills
            self.commands = commands
            self.instructions = instructions
            self.references = references
            self.websearch = websearch
            self.worktree = worktree
            self.warming = warming
            self.providers = providers
            self.experimental = experimental
        }

        private enum CodingKeys: String, CodingKey {
            case schema = "$schema"
            case shell
            case model
            case defaultAgent = "default_agent"
            case update
            case share
            case enterprise
            case username
            case timezone
            case permissions
            case policies
            case agents
            case snapshots
            case watcher
            case formatter
            case lsp
            case media
            case toolOutput = "tool_output"
            case mcp
            case compaction
            case skills
            case commands
            case instructions
            case references
            case websearch
            case worktree
            case warming
            case providers
            case experimental
        }
    }

    /// Input options for building a Workerd runtime profile.
    // parity: sdk/src/internal/workerd.ts#Options [status=implemented hash=2013d656b70c]
    public struct Options: Sendable {
        /// Durable Object storage whose SQLite database backs the opencode database.
        public let storage: any CoreDatabaseWorkerdSQLite.DurableObjectStorage
        public let app: EmbeddedServerOptions.AppOptions?
        public let config: Configuration?
        public let models: CoreModel.ModelsDev.Options?
        public let fetch: LayerNodePlatform.Fetch?
        public let routerFactory: EmbeddedHost.RouterFactory?

        public init(
            storage: any CoreDatabaseWorkerdSQLite.DurableObjectStorage,
            app: EmbeddedServerOptions.AppOptions? = nil,
            config: Configuration? = nil,
            models: CoreModel.ModelsDev.Options? = nil,
            fetch: LayerNodePlatform.Fetch? = nil,
            routerFactory: EmbeddedHost.RouterFactory? = nil
        ) {
            self.storage = storage
            self.app = app
            self.config = config
            self.models = models
            self.fetch = fetch
            self.routerFactory = routerFactory
        }
    }

    /// Result produced by `WorkerdProfile.make(_:)`, bundling normalized `EmbeddedServerOptions`
    /// and the workerd `LayerNode.Replacements` graph.
    public struct BuiltProfile: Sendable {
        public let options: EmbeddedServerOptions
        public let replacements: LayerNode.Replacements
        public let storage: any CoreDatabaseWorkerdSQLite.DurableObjectStorage

        public init(
            options: EmbeddedServerOptions,
            replacements: LayerNode.Replacements,
            storage: any CoreDatabaseWorkerdSQLite.DurableObjectStorage
        ) {
            self.options = options
            self.replacements = replacements
            self.storage = storage
        }
    }

    /// Produces normalized workerd `EmbeddedServerOptions` (filewatcher/fff disabled, durable events enabled,
    /// JSON-serialized inline config) and the workerd `LayerNode.Replacements` graph.
    // parity: sdk/src/internal/workerd.ts#make [status=implemented hash=d30e3fc452fd]
    public static func make(_ options: Options) throws -> BuiltProfile {
        let encodedConfig: String?
        if let config = options.config {
            encodedConfig = try ClientCodec.encodeString(config)
        } else {
            encodedConfig = nil
        }

        let serverOptions = EmbeddedServerOptions(
            app: options.app,
            events: EmbeddedServerOptions.EventsOptions(persist: true),
            models: options.models,
            fetch: options.fetch,
            config: EmbeddedServerOptions.ConfigOptions(content: encodedConfig),
            fs: EmbeddedServerOptions.FileSystemOptions(filewatcher: false, fff: false)
        )

        let adapter = CoreDatabaseWorkerdSQLite.StorageClientAdapter(storage: options.storage)
        let replacements: LayerNode.Replacements = [
            try CoreDatabaseStore.node.replace(with: CoreDatabaseStore.configuredClient(adapter)),
            CrossSpawnSpawner.node.replace(with: CoreLocation.Environment.unavailableLayer),
            CoreSnapshot.node.replace(with: CoreSnapshot.noopLayer),
            CoreBlobStore.node.replace(with: CoreBlobStore.unsupportedLayer),
            CoreIntegration.VideoGeneration.node.replace(with: CoreIntegration.VideoGeneration.unsupportedLayer),
            try CoreConfigPlugin.Source.node.replace(with: CoreConfigPlugin.Source.empty),
        ]

        return BuiltProfile(
            options: serverOptions,
            replacements: replacements,
            storage: options.storage
        )
    }
}

// MARK: - Embedded In-Process Host (`packages/sdk/src/internal/host.ts`)

/// In-process OpenCode host composing Core services, scoped logging, plugin wiring,
/// session-selected instances, startup suspension recovery, and an in-memory HTTP router
/// (`packages/sdk/src/internal/host.ts`).
public enum EmbeddedHost {
    /// Context handed to an injectable `RouterFactory` (such as `OpenCodeServer`'s router)
    /// or the default built-in `EmbeddedCoreRouter`.
    public struct RouterContext: Sendable {
        public let appInfo: CoreSubsystems.App.Info
        public let serverOptions: EmbeddedServerOptions
        public let services: LayerNode.Output
        public let loggingContext: LayerNode.Output
        public let logger: SDKLogging.LoggerService
        public let database: CoreDatabaseStore.Service
        public let bus: CoreBus.Service
        public let sessions: CoreSession.Service
        public let sessionStore: CoreSessionStore.Service
        public let sessionInbox: CoreSessionInbox.Service
        public let sessionMove: CoreSessionMove.Service
        public let instructionEntries: CoreSessionInstructionEntry.Service
        public let workspace: CoreProject.Workspace.Service
        public let sdkPlugins: CorePlugin.SdkPlugins.Service
        public let locations: CoreLocation.ServiceMap.Service
        public let instances: SdkInstances.SelectorService?
        public let defaultPluginEnvironment: CorePlugin.Host.Environment
        public let defaultPluginService: CorePlugin.Service
        public let isWorkerd: Bool
        public let tmpDirectory: String

        public init(
            appInfo: CoreSubsystems.App.Info,
            serverOptions: EmbeddedServerOptions,
            services: LayerNode.Output,
            loggingContext: LayerNode.Output,
            logger: SDKLogging.LoggerService,
            database: CoreDatabaseStore.Service,
            bus: CoreBus.Service,
            sessions: CoreSession.Service,
            sessionStore: CoreSessionStore.Service,
            sessionInbox: CoreSessionInbox.Service,
            sessionMove: CoreSessionMove.Service,
            instructionEntries: CoreSessionInstructionEntry.Service,
            workspace: CoreProject.Workspace.Service,
            sdkPlugins: CorePlugin.SdkPlugins.Service,
            locations: CoreLocation.ServiceMap.Service,
            instances: SdkInstances.SelectorService?,
            defaultPluginEnvironment: CorePlugin.Host.Environment,
            defaultPluginService: CorePlugin.Service,
            isWorkerd: Bool,
            tmpDirectory: String
        ) {
            self.appInfo = appInfo
            self.serverOptions = serverOptions
            self.services = services
            self.loggingContext = loggingContext
            self.logger = logger
            self.database = database
            self.bus = bus
            self.sessions = sessions
            self.sessionStore = sessionStore
            self.sessionInbox = sessionInbox
            self.sessionMove = sessionMove
            self.instructionEntries = instructionEntries
            self.workspace = workspace
            self.sdkPlugins = sdkPlugins
            self.locations = locations
            self.instances = instances
            self.defaultPluginEnvironment = defaultPluginEnvironment
            self.defaultPluginService = defaultPluginService
            self.isWorkerd = isWorkerd
            self.tmpDirectory = tmpDirectory
        }
    }

    /// Injectable hook allowing `OpenCodeServer` (or custom embedders) to supply the HTTP router handler.
    public typealias RouterFactory = @Sendable (RouterContext) -> OwnedFetch.RequestHandler

    /// Managed runtime owning the host's `ResourceScope`, service context, and background tasks.
    public final class Runtime: Sendable {
        private struct State: Sendable {
            var backgroundTasks: [Task<Void, Never>] = []
            var disposed: Bool = false
        }

        public let services: LayerNode.Output
        public let loggingContext: LayerNode.Output
        public let scope: LayerNode.ResourceScope
        private let state = Mutex(State())

        internal init(
            services: LayerNode.Output,
            loggingContext: LayerNode.Output,
            scope: LayerNode.ResourceScope
        ) {
            self.services = services
            self.loggingContext = loggingContext
            self.scope = scope
        }

        /// Runs a background task owned by this host runtime; cancelled automatically on `dispose()`.
        public func runFork(_ operation: @escaping @Sendable () async -> Void) {
            let task = Task {
                await operation()
            }
            let cancelImmediately: Bool = state.withLock { s in
                if s.disposed { return true }
                s.backgroundTasks.append(task)
                return false
            }
            if cancelImmediately {
                task.cancel()
            }
        }

        /// Disposes all background tasks and closes the host's `ResourceScope` in LIFO order.
        public func dispose() async {
            let tasksToCancel: [Task<Void, Never>] = state.withLock { s in
                if s.disposed { return [] }
                s.disposed = true
                let copy = s.backgroundTasks
                s.backgroundTasks.removeAll()
                return copy
            }
            for task in tasksToCancel {
                task.cancel()
            }
            for task in tasksToCancel {
                _ = await task.value
            }
            await scope.close()
        }
    }

    /// Options for booting an embedded OpenCode host.
    // parity: sdk/src/internal/host.ts#CreateOptions [status=implemented hash=35a02e1b7b2e]
    public struct CreateOptions: Sendable {
        public var server: EmbeddedServerOptions
        public var log: SDKLogging.LogOptions?
        public var plugins: [PluginEffect.Plugin]?
        public var workspaceProviders: [String: any CoreProject.Workspace.Driver.Interface]?
        public var instances: SdkInstances.Options?
        /// Services captured from the caller's environment to feed `SdkInstances.provide`.
        public var services: LayerNode.Output

        public init(
            server: EmbeddedServerOptions = EmbeddedServerOptions(),
            log: SDKLogging.LogOptions? = nil,
            plugins: [PluginEffect.Plugin]? = nil,
            workspaceProviders: [String: any CoreProject.Workspace.Driver.Interface]? = nil,
            instances: SdkInstances.Options? = nil,
            services: LayerNode.Output = LayerNode.Output()
        ) {
            self.server = server
            self.log = log
            self.plugins = plugins
            self.workspaceProviders = workspaceProviders
            self.instances = instances
            self.services = services
        }

        public init(
            app: EmbeddedServerOptions.AppOptions? = nil,
            cors: [String]? = nil,
            simulation: Bool? = nil,
            database: CoreDatabaseStore.Options? = nil,
            pty: CorePty.Persistent.Options? = nil,
            events: EmbeddedServerOptions.EventsOptions? = nil,
            models: CoreModel.ModelsDev.Options? = nil,
            fetch: LayerNodePlatform.Fetch? = nil,
            config: EmbeddedServerOptions.ConfigOptions? = nil,
            instructions: EmbeddedServerOptions.InstructionsOptions? = nil,
            windows: EmbeddedServerOptions.WindowsOptions? = nil,
            fs: EmbeddedServerOptions.FileSystemOptions? = nil,
            log: SDKLogging.LogOptions? = nil,
            plugins: [PluginEffect.Plugin]? = nil,
            workspaceProviders: [String: any CoreProject.Workspace.Driver.Interface]? = nil,
            instances: SdkInstances.Options? = nil,
            services: LayerNode.Output = LayerNode.Output()
        ) {
            self.server = EmbeddedServerOptions(
                app: app,
                cors: cors,
                simulation: simulation,
                database: database,
                pty: pty,
                events: events,
                models: models,
                fetch: fetch,
                config: config,
                instructions: instructions,
                windows: windows,
                fs: fs
            )
            self.log = log
            self.plugins = plugins
            self.workspaceProviders = workspaceProviders
            self.instances = instances
            self.services = services
        }
    }

    /// Host hooks for embedding OpenCode on a non-default runtime profile (e.g. workerd or custom router/overrides).
    // parity: sdk/src/internal/host.ts#EmbedOptions [status=implemented hash=65183dbc94db]
    public struct EmbedOptions: Sendable {
        public var overrides: LayerNode.Replacements
        public var durableObjectStorage: (any CoreDatabaseWorkerdSQLite.DurableObjectStorage)?
        public var routerFactory: RouterFactory?
        public var fileSystem: (any OpenCodeFileSystem)?

        public init(
            overrides: LayerNode.Replacements = [],
            durableObjectStorage: (any CoreDatabaseWorkerdSQLite.DurableObjectStorage)? = nil,
            routerFactory: RouterFactory? = nil,
            fileSystem: (any OpenCodeFileSystem)? = nil
        ) {
            self.overrides = overrides
            self.durableObjectStorage = durableObjectStorage
            self.routerFactory = routerFactory
            self.fileSystem = fileSystem
        }
    }

    /// Running in-process OpenCode host exposing its runtime, tracked fetch transport,
    /// plugin registry, core session/workspace services, and idempotent `close`.
    // parity: sdk/src/internal/host.ts#Interface [status=adapted hash=016515e9b4a2]
    public final class Interface: Sendable {
        public let runtime: Runtime
        public let fetch: OwnedFetch.Transport
        public let plugins: CorePlugin.SdkPlugins.Service
        public let sessions: CoreSession.Service
        public let sessionMove: CoreSessionMove.Service
        public let workspace: CoreProject.Workspace.Service
        public let bus: CoreBus.Service
        public let database: CoreDatabaseStore.Service
        public let instances: SdkInstances.SelectorService?
        public let logger: SDKLogging.LoggerService
        public let defaultPluginService: CorePlugin.Service
        public let close: @Sendable () async -> Void

        internal init(
            runtime: Runtime,
            fetch: OwnedFetch.Transport,
            plugins: CorePlugin.SdkPlugins.Service,
            sessions: CoreSession.Service,
            sessionMove: CoreSessionMove.Service,
            workspace: CoreProject.Workspace.Service,
            bus: CoreBus.Service,
            database: CoreDatabaseStore.Service,
            instances: SdkInstances.SelectorService?,
            logger: SDKLogging.LoggerService,
            defaultPluginService: CorePlugin.Service
        ) {
            self.runtime = runtime
            self.fetch = fetch
            self.plugins = plugins
            self.sessions = sessions
            self.sessionMove = sessionMove
            self.workspace = workspace
            self.bus = bus
            self.database = database
            self.instances = instances
            self.logger = logger
            self.defaultPluginService = defaultPluginService
            self.close = { [fetch] in
                await fetch.close()
            }
        }
    }

    /// Boots an embedded in-process OpenCode host with scoped logging, SQLite store, event bus,
    /// Session Core, Workspace service, non-blocking SDK plugin activation, optional session-selected
    /// instances, background suspension recovery, and an owned in-process fetch transport.
    // parity: sdk/src/internal/host.ts#create [status=adapted hash=4ff4bda715cd]
    public static func create(
        _ options: CreateOptions = CreateOptions(),
        embed: EmbedOptions = EmbedOptions()
    ) async throws -> Interface {
        let scope = LayerNode.ResourceScope()
        do {
            let appInfo = CoreSubsystems.App.make(
                name: options.server.app?.name ?? "sdk",
                version: options.server.app?.version,
                channel: options.server.app?.channel
            )
            let fileSystem = embed.fileSystem ?? LocalFileSystem.shared

            // 1. Logging layer & isolated logging context
            let loggingOutput = try await SDKLogging.layer(options.log).build(LayerNode.Output(), scope)
            let loggingContext = SDKLogging.context(loggingOutput)
            let logger = loggingOutput.get(SDKLogging.currentLoggersKey, as: SDKLogging.LoggerService.self)
                ?? SDKLogging.LoggerService(options: options.log)

            // 2. Database (workerd DurableObjectStorage or SQLite WAL / :memory:)
            let database: CoreDatabaseStore.Service
            if let doStorage = embed.durableObjectStorage {
                let adapter = CoreDatabaseWorkerdSQLite.StorageClientAdapter(storage: doStorage)
                database = try CoreDatabaseStore.bootstrap(
                    client: adapter,
                    fileSystem: fileSystem,
                    legacyCredentials: false
                )
            } else {
                let dbOptions = CoreDatabaseStore.Options(path: options.server.database?.path ?? ":memory:")
                database = try await CoreDatabaseStore.open(
                    options: dbOptions,
                    fileSystem: fileSystem
                )
            }
            scope.addFinalizer {
                try? database.db.close()
            }

            // 3. Event bus + durable session projections
            let bus = CoreBus.Service(
                db: database.db,
                options: CoreBus.Options(persist: options.server.events?.persist ?? false)
            )
            CoreSessionProjector.register(bus: bus, db: database.db)

            // 4. Session store, inbox, execution, session facade, move, instruction entries, restart
            let sessionStore = CoreSessionStore.Service(db: database.db)
            let sessionInbox = CoreSessionInbox.Service(db: database.db, bus: bus)
            let sessionExecution: any CoreSessionExecution.Interface = CoreSessionExecution.NoopService()
            let sessions = CoreSession.Service(
                db: database.db,
                bus: bus,
                store: sessionStore,
                inbox: sessionInbox,
                execution: sessionExecution,
                fileSystem: fileSystem,
                version: appInfo.version
            )
            let sessionMove = CoreSessionMove.Service(
                db: database.db,
                bus: bus,
                store: sessionStore,
                inbox: sessionInbox,
                execution: sessionExecution,
                fileSystem: fileSystem
            )
            let instructionEntries = CoreSessionInstructionEntry.Service(db: database.db)
            let sessionRestart = CoreSessionRestart.Service(
                db: database.db,
                store: sessionStore,
                execution: sessionExecution,
                bus: bus
            )

            // 5. Workspace registry & service
            let workspaceRegistry = CoreProject.Workspace.Driver.RegistryService(options.workspaceProviders ?? [:])
            let workspace = try CoreProject.Workspace.Service(database: database.db, registry: workspaceRegistry)

            // 6. Default Location plugin host & host-global SDK plugin store
            let defaultDir = options.server.config?.directory ?? "/"
            let defaultLocationInfo = LocationSchema.Info(
                directory: SchemaPrimitive.AbsolutePath(rawValue: defaultDir),
                workspaceID: nil,
                project: LocationSchema.ProjectRef(
                    id: ProjectID.global,
                    directory: SchemaPrimitive.AbsolutePath(rawValue: defaultDir),
                    canonical: SchemaPrimitive.AbsolutePath(rawValue: defaultDir)
                )
            )
            let pluginApp = PluginContract.App(name: appInfo.name, version: appInfo.version, channel: appInfo.channel)
            let defaultPluginEnvironment = CorePlugin.Host.Environment(
                app: pluginApp,
                location: defaultLocationInfo
            )
            let defaultPluginService = CorePlugin.Service(
                fileSystem: fileSystem,
                contextFactory: { pluginID, listInventory, addFinalizer in
                    CorePlugin.Host.make(
                        environment: defaultPluginEnvironment,
                        pluginID: pluginID,
                        listPlugins: listInventory,
                        addFinalizer: addFinalizer
                    )
                }
            )
            scope.addFinalizer {
                await defaultPluginService.close()
            }

            let sdkPluginsBox = Mutex<CorePlugin.SdkPlugins.Service?>(nil)
            let sdkPlugins = CorePlugin.SdkPlugins.Service {
                // CRITICAL INVARIANT: Plugin activation runs asynchronously in the background so
                // host/server handlers NEVER block waiting for slow plugin loads.
                guard let registry = sdkPluginsBox.withLock({ $0 }) else { return }
                let generations = registry.all()
                defaultPluginService.startBackgroundActivation(generations, failures: [])
            }
            sdkPluginsBox.withLock { $0 = sdkPlugins }

            // 7. Overrides + LocationServiceMap + optional session-selected Instance selector
            var hostOverrides = embed.overrides
            if let workspaceProviders = options.workspaceProviders {
                hostOverrides.append(
                    try CoreProject.Workspace.Driver.node.replace(
                        with: CoreProject.Workspace.Driver.registryNode(workspaceProviders)
                    )
                )
            }
            let finalOverrides = hostOverrides

            let locations = CoreLocation.ServiceMap.Service { ref, locScope in
                let compiled = try CoreLocation.Instance.layer(
                    ref,
                    options: CoreLocation.Instance.Options(discovery: false, replacements: finalOverrides)
                )
                return try await compiled.build(scope: locScope)
            }
            scope.addFinalizer {
                await locations.closeAll()
            }

            // Install the selector BEFORE automatic recovery starts (README: Restart and Lifetime).
            let selector: SdkInstances.SelectorService?
            if let rawInstances = options.instances {
                let provided = SdkInstances.provide(rawInstances, context: options.services)
                let service = SdkInstances.SelectorService(
                    options: provided,
                    locations: locations,
                    replacements: { finalOverrides },
                    sdkPlugins: sdkPlugins,
                    appInfo: pluginApp,
                    fileSystem: fileSystem
                )
                scope.addFinalizer {
                    await service.closeAll()
                }
                selector = service
            } else {
                selector = nil
            }

            // 8. Seed initial host plugins (registers into SdkPlugins and kicks off non-blocking activation)
            for plugin in options.plugins ?? [] {
                sdkPlugins.register(plugin)
            }

            // 9. Assemble host service map and ManagedRuntime
            var serviceMap: [String: any Sendable] = [
                CoreSubsystems.App.Service.serviceKey: CoreSubsystems.App.Service(info: appInfo),
                CoreDatabaseStore.Service.serviceKey: database,
                CoreBus.Service.serviceKey: bus,
                CoreSession.Service.serviceKey: sessions,
                CoreSessionMove.Service.serviceKey: sessionMove,
                CoreSessionRestart.Service.serviceKey: sessionRestart,
                CoreProject.Workspace.Service.serviceKey: workspace,
                CoreProject.Workspace.Driver.RegistryService.serviceKey: workspaceRegistry,
                CorePlugin.SdkPlugins.Service.serviceKey: sdkPlugins,
                CoreLocation.ServiceMap.Service.serviceKey: locations,
                CorePlugin.Service.serviceKey: defaultPluginService,
                SDKLogging.currentLoggersKey: logger,
                SDKLogging.minimumLogLevelKey: logger.minimumLevel,
            ]
            if let selector {
                serviceMap[CoreLocation.Instance.Service.serviceKey] = selector
            } else {
                serviceMap[CoreLocation.Instance.Service.serviceKey] = CoreLocation.Instance.Service(locations: locations)
            }

            let runtime = Runtime(
                services: LayerNode.Output(serviceMap),
                loggingContext: loggingContext,
                scope: scope
            )

            // 10. Kick off non-blocking startup sweep for any suspended sessions; owned by runtime so it stops on close.
            runtime.runFork {
                try? await sessionRestart.resumeSuspendedSessions()
            }

            // 11. Build in-process HTTP router (injectable via embed.routerFactory, defaulting to EmbeddedCoreRouter).
            let routerContext = RouterContext(
                appInfo: appInfo,
                serverOptions: options.server,
                services: runtime.services,
                loggingContext: loggingContext,
                logger: logger,
                database: database,
                bus: bus,
                sessions: sessions,
                sessionStore: sessionStore,
                sessionInbox: sessionInbox,
                sessionMove: sessionMove,
                instructionEntries: instructionEntries,
                workspace: workspace,
                sdkPlugins: sdkPlugins,
                locations: locations,
                instances: selector,
                defaultPluginEnvironment: defaultPluginEnvironment,
                defaultPluginService: defaultPluginService,
                isWorkerd: embed.durableObjectStorage != nil,
                tmpDirectory: defaultDir
            )
            let handler = embed.routerFactory?(routerContext) ?? EmbeddedCoreRouter.make(routerContext)
            let transport = OwnedFetch.make(handler: handler) {
                await runtime.dispose()
            }

            return Interface(
                runtime: runtime,
                fetch: transport,
                plugins: sdkPlugins,
                sessions: sessions,
                sessionMove: sessionMove,
                workspace: workspace,
                bus: bus,
                database: database,
                instances: selector,
                logger: logger,
                defaultPluginService: defaultPluginService
            )
        } catch {
            await scope.close()
            throw error
        }
    }
}

// MARK: - Default In-Process Core HTTP Router (Zero-Conflict Bridge Until Full OpenCodeServer Merges)

internal enum EmbeddedCoreRouter {
    static func make(_ ctx: EmbeddedHost.RouterContext) -> OwnedFetch.RequestHandler {
        { request, signal in
            try await handle(request: request, signal: signal, ctx: ctx)
        }
    }

    private static func currentPID(isWorkerd: Bool) -> Int {
        if isWorkerd { return 0 }
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        return Int(getpid())
        #elseif canImport(WinSDK)
        return Int(GetCurrentProcessId())
        #else
        return 0
        #endif
    }

    private static func handle(
        request: HTTPRequest,
        signal: AbortSignal,
        ctx: EmbeddedHost.RouterContext
    ) async throws -> OwnedFetch.HandlerResponse {
        let (path, query) = parseURL(request.url)
        let method = request.method.uppercased()

        // 1. GET /api/info
        if method == "GET", path == "/api/info" {
            let info = OpenCodeProtocol.ServerInfo(
                version: ctx.appInfo.version,
                pid: currentPID(isWorkerd: ctx.isWorkerd),
                hostname: ctx.isWorkerd ? nil : "opencode.local",
                urls: [],
                paths: .init(tmp: ctx.tmpDirectory),
                capabilities: .init(persistentPty: false)
            )
            return try jsonResponse(info)
        }

        // 2. GET /api/event (SSE live event stream)
        if method == "GET", path == "/api/event" {
            let filterTypes = query["types"].map { raw -> Set<String> in
                Set(raw.split(separator: ",").map(String.init))
            }
            return .streaming(makeEventStream(bus: ctx.bus, types: filterTypes, signal: signal))
        }

        // 3. GET /api/plugin (Non-blocking immediate snapshot — NEVER awaits plugin activation)
        if method == "GET", path == "/api/plugin" {
            let locRef = parsePublicLocationQuery(query) ?? defaultPublicLocationRef(ctx)
            let list = ctx.defaultPluginService.list()
            let envelope = LocationSchema.ResponseEnvelope(location: locRef, data: list)
            return try jsonResponse(envelope)
        }

        // 4. GET /api/permission/request (acquires session's instance when sessionID is provided)
        if method == "GET", path == "/api/permission/request" {
            if let sidStr = query["sessionID"], let sid = SessionID(rawValue: sidStr) {
                if let session = try ctx.sessionStore.get(sid), let selector = ctx.instances {
                    _ = try await selector.acquire(session: session)
                }
            }
            let locRef = parsePublicLocationQuery(query) ?? defaultPublicLocationRef(ctx)
            let envelope = LocationSchema.ResponseEnvelope<[PermissionSchema.Request]>(location: locRef, data: [])
            return try jsonResponse(envelope)
        }

        // 5. GET /api/message
        if method == "GET", path == "/api/message" {
            guard let sidStr = query["sessionID"], let sid = SessionID(rawValue: sidStr) else {
                return try jsonResponse(SessionMessagesResponse(data: []))
            }
            do {
                let messages = try ctx.sessions.messages(CoreSessionStore.MessagesInput(sessionID: sid))
                return try jsonResponse(SessionMessagesResponse(data: messages))
            } catch let err as CoreSessionErrors.NotFoundError {
                return try sessionNotFoundResponse(err.sessionID)
            }
        }

        // 6. GET /api/websearch/provider & POST /api/websearch
        if method == "GET", path == "/api/websearch/provider" {
            let locRef = parsePublicLocationQuery(query) ?? defaultPublicLocationRef(ctx)
            let providers = ctx.defaultPluginEnvironment.registeredWebSearchProviders()
            let envelope = LocationSchema.ResponseEnvelope(location: locRef, data: providers)
            return try jsonResponse(envelope)
        }

        // 7. Session collection endpoints: GET /api/session, POST /api/session, GET /api/session/active
        if path == "/api/session" {
            if method == "GET" {
                let parentFilter: SessionSchema.ParentFilter? = query["parentID"].flatMap { raw in
                    if raw == "root" || raw == "null" { return .root }
                    return SessionID(rawValue: raw).map { .session($0) }
                }
                let input = CoreSession.ListInput(
                    directory: query["directory"],
                    project: query["project"].map { ProjectID(rawValue: $0) },
                    subpath: query["subpath"],
                    search: query["search"],
                    limit: query["limit"].flatMap(Int.init),
                    order: query["order"].flatMap { SessionSchema.SortOrder(rawValue: $0) },
                    parentID: parentFilter,
                    archived: query["archived"].map { $0 == "true" }
                )
                let page = try ctx.sessions.list(input)
                return try jsonResponse(SessionsResponse(data: page.data))
            }
            if method == "POST" {
                let bodyObj = try decodeJSONObject(request.body)
                let id = stringField(bodyObj, "id").flatMap { SessionID(rawValue: $0) }
                let parentID = stringField(bodyObj, "parentID").flatMap { SessionID(rawValue: $0) }
                let title = stringField(bodyObj, "title")
                let agent = stringField(bodyObj, "agent")
                let model: SessionSchema.ModelRef? = try decodeField(bodyObj, "model")
                let location: OpenCodeLocation? = decodeLocationField(bodyObj)
                let metadata: SessionSchema.Metadata? = objectField(bodyObj, "metadata")
                let permissions: SessionSchema.PermissionRuleset? = try decodeField(bodyObj, "permissions")

                let created = try await ctx.sessions.create(
                    CoreSession.CreateInput(
                        id: id,
                        location: location,
                        parentID: parentID,
                        title: title,
                        agent: agent,
                        model: model,
                        metadata: metadata,
                        permissions: permissions
                    )
                )
                return try jsonDataResponse(created)
            }
        }

        if method == "GET", path == "/api/session/active" {
            let active: [String: SessionActiveInfo] = [:]
            return try jsonDataResponse(active)
        }

        // 8. Per-session endpoints: /api/session/:id[...]
        if path.hasPrefix("/api/session/") {
            let remainder = String(path.dropFirst("/api/session/".count))
            let parts = remainder.split(separator: "/", omittingEmptySubsequences: false).map { decodeURIComponent(String($0)) }
            if let rawID = parts.first, !rawID.isEmpty, let sessionID = SessionID(rawValue: rawID) {
                return try await handleSessionRoute(
                    method: method,
                    sessionID: sessionID,
                    subpath: Array(parts.dropFirst()),
                    query: query,
                    body: request.body,
                    ctx: ctx
                )
            }
        }

        // 9. Experimental session routes: /api/experimental/session/:id/...
        if path.hasPrefix("/api/experimental/session/") {
            let remainder = String(path.dropFirst("/api/experimental/session/".count))
            let parts = remainder.split(separator: "/", omittingEmptySubsequences: false).map { decodeURIComponent(String($0)) }
            if let rawID = parts.first, !rawID.isEmpty, let sessionID = SessionID(rawValue: rawID) {
                return try await handleExperimentalSessionRoute(
                    method: method,
                    sessionID: sessionID,
                    subpath: Array(parts.dropFirst()),
                    query: query,
                    body: request.body,
                    signal: signal,
                    ctx: ctx
                )
            }
        }

        return .buffered(
            HTTPResponse(
                head: HTTPResponseHead(statusCode: 404, headers: ["content-type": "application/json"]),
                body: Array(#"{"_tag":"NotFoundError","message":"Route not found"}"#.utf8)
            )
        )
    }

    private static func handleSessionRoute(
        method: String,
        sessionID: SessionID,
        subpath: [String],
        query: [String: String],
        body: [UInt8]?,
        ctx: EmbeddedHost.RouterContext
    ) async throws -> OwnedFetch.HandlerResponse {
        do {
            // /api/session/:id
            if subpath.isEmpty {
                switch method {
                case "GET":
                    let info = try ctx.sessions.get(sessionID)
                    return try jsonDataResponse(info)
                case "DELETE":
                    try await ctx.sessions.remove(sessionID)
                    return emptyResponse(204)
                case "PATCH":
                    let obj = try decodeJSONObject(body)
                    if let title = stringField(obj, "title") {
                        try await ctx.sessions.rename(sessionID: sessionID, title: title)
                    }
                    if case .bool(let archived) = obj["archived"] {
                        if archived {
                            try await ctx.sessions.archive(sessionID)
                        } else {
                            try await ctx.sessions.unarchive(sessionID)
                        }
                    }
                    return emptyResponse(204)
                default:
                    break
                }
            }

            // /api/session/:id/inbox
            if subpath == ["inbox"], method == "GET" {
                _ = try ctx.sessions.get(sessionID)
                let items = try ctx.sessionInbox.list(sessionID)
                return try jsonDataResponse(items)
            }

            // /api/session/:id/context
            if subpath == ["context"], method == "GET" {
                _ = try ctx.sessions.get(sessionID)
                let items = try ctx.sessionStore.context(sessionID)
                return try jsonDataResponse(items)
            }

            // /api/session/:id/message (MessageClientAPI.list)
            if subpath == ["message"], method == "GET" {
                let messages = try ctx.sessions.messages(
                    CoreSessionStore.MessagesInput(
                        sessionID: sessionID,
                        limit: query["limit"].flatMap(Int.init),
                        order: query["order"].flatMap { SessionSchema.SortOrder(rawValue: $0) }
                    )
                )
                return try jsonResponse(SessionMessagesResponse(data: messages))
            }

            // /api/session/:id/permission (PermissionClientAPI.list — acquires session's instance!)
            if subpath == ["permission"], method == "GET" {
                let session = try ctx.sessions.get(sessionID)
                if let selector = ctx.instances {
                    _ = try await selector.acquire(session: session)
                }
                let requests: [PermissionSchema.Request] = []
                return try jsonDataResponse(requests)
            }

            // /api/session/:id/form (acquires session's instance!)
            if subpath == ["form"], method == "GET" {
                let session = try ctx.sessions.get(sessionID)
                if let selector = ctx.instances {
                    _ = try await selector.acquire(session: session)
                }
                let forms: [FormSchema.Info] = []
                return try jsonDataResponse(forms)
            }

            // /api/session/:id/message/:messageID
            if subpath.count == 2, subpath[0] == "message", method == "GET" {
                _ = try ctx.sessions.get(sessionID)
                guard let msgID = SessionMessageSchema.ID(rawValue: subpath[1]),
                      let found = try ctx.sessionStore.message(msgID),
                      found.sessionID == sessionID
                else {
                    return try messageNotFoundResponse(sessionID: sessionID, messageID: subpath[1])
                }
                return try jsonDataResponse(found.message)
            }

            // /api/session/:id/agent
            if subpath == ["agent"], method == "POST" {
                let obj = try decodeJSONObject(body)
                let agent = stringField(obj, "agent") ?? ""
                try await ctx.sessions.selectAgent(sessionID: sessionID, agent: agent)
                return emptyResponse(204)
            }

            // /api/session/:id/model
            if subpath == ["model"], method == "POST" {
                let obj = try decodeJSONObject(body)
                guard let model: SessionSchema.ModelRef = try decodeField(obj, "model") else {
                    return badRequestResponse("Missing model")
                }
                try await ctx.sessions.selectModel(sessionID: sessionID, model: model)
                return emptyResponse(204)
            }

            // /api/session/:id/move
            if subpath == ["move"], method == "POST" {
                let obj = try decodeJSONObject(body)
                let directory = stringField(obj, "directory") ?? "/"
                let workspaceID = stringField(obj, "workspaceID").flatMap { WorkspaceID(rawValue: $0) }
                let delivery = stringField(obj, "delivery").flatMap { SessionInboxSchema.Delivery(rawValue: $0) }
                try await ctx.sessionMove.move(
                    CoreSessionMove.MoveInput(
                        sessionID: sessionID,
                        directory: directory,
                        workspaceID: workspaceID,
                        delivery: delivery
                    )
                )
                return emptyResponse(204)
            }

            // /api/session/:id/fork
            if subpath == ["fork"], method == "POST" {
                let obj = try decodeJSONObject(body)
                let before = stringField(obj, "before").flatMap { SessionMessageSchema.ID(rawValue: $0) }
                let forked = try await ctx.sessions.fork(sessionID: sessionID, before: before)
                // Trigger currently registered fork hooks with error containment so a throwing hook
                // still returns the saved fork (`instances.test.ts:148-170`).
                if let selector = ctx.instances, let container = try? await selector.acquire(session: forked) {
                    _ = await container.pluginEnvironment.hooks.triggerSession(.fork(sessionID: forked.id))
                } else {
                    _ = await ctx.defaultPluginEnvironment.hooks.triggerSession(.fork(sessionID: forked.id))
                }
                return try jsonDataResponse(forked)
            }

            // /api/session/:id/interrupt
            if subpath == ["interrupt"], method == "POST" {
                let resume = query["resume"] == "true"
                let interrupted = try await ctx.sessions.interrupt(sessionID, resume: resume)
                return try jsonResponse(SessionInterruptResponse(interrupted: interrupted))
            }

            // /api/session/:id/prompt
            if subpath == ["prompt"], method == "POST" {
                let session = try ctx.sessions.get(sessionID)

                // Acquire Session-selected instance BEFORE prompt preparation/admission.
                // Configuration or instance-plugin failure rejects with 500 and admits nothing.
                let hooks: CorePlugin.Hooks.Service
                if let selector = ctx.instances {
                    do {
                        let container = try await selector.acquire(session: session)
                        hooks = container.pluginEnvironment.hooks
                    } catch {
                        ctx.logger.error(
                            "Instance acquisition failed during prompt",
                            attributes: ["sessionID": .string(sessionID.rawValue)],
                            cause: .string(String(describing: error))
                        )
                        return internalErrorResponse(String(describing: error))
                    }
                } else {
                    hooks = ctx.defaultPluginEnvironment.hooks
                }

                let obj = try decodeJSONObject(body)
                let id = stringField(obj, "id").flatMap { SessionMessageSchema.ID(rawValue: $0) }
                let text = stringField(obj, "text") ?? ""
                let files: [PromptInputSchema.FileAttachment]? = try decodeField(obj, "files")
                let agents: [PromptSchema.AgentAttachment]? = try decodeField(obj, "agents")
                let skills: [PromptInputSchema.SkillAttachment]? = try decodeField(obj, "skills")
                let metadata: [String: JSONValue]? = objectField(obj, "metadata")
                let delivery = stringField(obj, "delivery").flatMap { SessionInboxSchema.Delivery(rawValue: $0) }
                let resume: Bool? = {
                    if case .bool(let b) = obj["resume"] { return b }
                    return nil
                }()

                let resolvedMessageID = id ?? SessionMessageSchema.ID.create()
                let resolvedDelivery = delivery ?? .steer

                // Check idempotency BEFORE running prompt hooks so retries return the original admission unchanged.
                if let existing = try ctx.sessionInbox.reconcile(
                    id: resolvedMessageID,
                    sessionID: session.id,
                    type: "user",
                    delivery: resolvedDelivery
                ), case .user(let userItem) = existing {
                    return try jsonDataResponse(userItem)
                }

                // Trigger currently registered prompt hooks (without blocking on unloaded plugins).
                let promptEvent = PluginEffect.SessionPrompt(
                    sessionID: session.id,
                    messageID: resolvedMessageID,
                    prompt: PromptInputSchema.Prompt(
                        text: text,
                        files: files,
                        agents: agents,
                        skills: skills
                    ),
                    metadata: metadata,
                    delivery: resolvedDelivery
                )
                let triggered = await hooks.triggerSession(.prompt(promptEvent))
                let finalPrompt: PluginEffect.SessionPrompt
                if case .prompt(let updated) = triggered {
                    finalPrompt = updated
                } else {
                    finalPrompt = promptEvent
                }

                let admitted = try await ctx.sessions.prompt(
                    CoreSession.PromptRequest(
                        sessionID: session.id,
                        id: resolvedMessageID,
                        input: CoreSessionPrompt.Input(
                            text: finalPrompt.prompt.text,
                            files: finalPrompt.prompt.files,
                            agents: finalPrompt.prompt.agents,
                            skills: finalPrompt.prompt.skills,
                            metadata: finalPrompt.metadata,
                            delivery: finalPrompt.delivery
                        ),
                        resume: resume
                    )
                )
                guard case .user(let userItem) = admitted else {
                    return internalErrorResponse("Unexpected non-user inbox item")
                }
                return try jsonDataResponse(userItem)
            }
        } catch let err as CoreSessionErrors.NotFoundError {
            return try sessionNotFoundResponse(err.sessionID)
        } catch let err as CoreSessionErrors.MessageNotFoundError {
            return try messageNotFoundResponse(sessionID: err.sessionID, messageID: err.messageID.rawValue)
        }

        return .buffered(
            HTTPResponse(
                head: HTTPResponseHead(statusCode: 404, headers: ["content-type": "application/json"]),
                body: Array(#"{"_tag":"NotFoundError","message":"Session route not found"}"#.utf8)
            )
        )
    }

    private static func handleExperimentalSessionRoute(
        method: String,
        sessionID: SessionID,
        subpath: [String],
        query: [String: String],
        body: [UInt8]?,
        signal: AbortSignal,
        ctx: EmbeddedHost.RouterContext
    ) async throws -> OwnedFetch.HandlerResponse {
        do {
            _ = try ctx.sessions.get(sessionID)
        } catch let err as CoreSessionErrors.NotFoundError {
            return try sessionNotFoundResponse(err.sessionID)
        }

        // GET /api/experimental/session/:id/log
        if subpath == ["log"], method == "GET" {
            let after = query["after"].flatMap(Int64.init)
            let follow = query["follow"] == "true"
            return .streaming(makeSessionLogStream(bus: ctx.bus, sessionID: sessionID, after: after, follow: follow, signal: signal))
        }

        // GET /api/experimental/session/:id/export
        if subpath == ["export"], method == "GET" {
            let info = try ctx.sessions.get(sessionID)
            let messages = try ctx.sessions.messages(CoreSessionStore.MessagesInput(sessionID: sessionID))
            let payload: [String: JSONValue] = [
                "info": try ClientCodec.toJSONValue(info),
                "messages": try ClientCodec.toJSONValue(messages),
            ]
            return try jsonDataResponse(payload)
        }

        // POST /api/experimental/session/:id/wait
        if subpath == ["wait"], method == "POST" {
            try await ctx.sessions.awaitIdle(sessionID)
            return emptyResponse(204)
        }

        // /api/experimental/session/:id/instructions/entries[/:key]
        if subpath.count >= 2, subpath[0] == "instructions", subpath[1] == "entries" {
            if subpath.count == 2, method == "GET" {
                let entries = try ctx.instructionEntries.list(sessionID)
                return try jsonDataResponse(entries)
            }
            if subpath.count == 3 {
                let key = subpath[2]
                if method == "PUT" {
                    let obj = try decodeJSONObject(body)
                    let value = obj["value"] ?? .null
                    do {
                        try ctx.instructionEntries.put(sessionID: sessionID, key: key, value: value)
                        return emptyResponse(204)
                    } catch let err as CoreSessionInstructionEntry.ValueTooLargeError {
                        let schemaErr = InstructionEntrySchema.ValueTooLargeError(
                            actualBytes: err.actualBytes,
                            maxBytes: err.maxBytes,
                            message: err.description
                        )
                        return try jsonResponse(schemaErr, statusCode: 413)
                    }
                }
                if method == "DELETE" {
                    try ctx.instructionEntries.remove(sessionID: sessionID, key: key)
                    return emptyResponse(204)
                }
            }
        }

        return .buffered(
            HTTPResponse(
                head: HTTPResponseHead(statusCode: 404, headers: ["content-type": "application/json"]),
                body: Array(#"{"_tag":"NotFoundError","message":"Experimental session route not found"}"#.utf8)
            )
        )
    }

    private static func makeEventStream(
        bus: CoreBus.Service,
        types: Set<String>?,
        signal: AbortSignal
    ) -> HTTPStreamingResponse {
        let chunks = AsyncThrowingStream<[UInt8], Error> { continuation in
            let task = Task {
                // Emit initial `server.connected` handshake event immediately.
                let connected = OpenCodeEvent(
                    id: "evt_\(OpenCodeUtil.uuid().replacing("-", with: ""))",
                    type: "server.connected",
                    data: .object([:])
                )
                if let frame = encodeSSEFrame(connected) {
                    continuation.yield(frame)
                }

                let subscription: AsyncStream<CoreBus.SubscribePayload>
                if let types, !types.isEmpty {
                    subscription = bus.subscribe(types: types, location: nil)
                } else {
                    subscription = bus.subscribe(location: nil)
                }
                for await payload in subscription {
                    if Task.isCancelled || signal.isAborted { break }
                    let event = OpenCodeEvent(
                        id: payload.id.rawValue,
                        type: payload.type,
                        created: Double(payload.created),
                        metadata: payload.metadata,
                        location: payload.location,
                        data: payload.data
                    )
                    if let frame = encodeSSEFrame(event) {
                        continuation.yield(frame)
                    }
                }
                continuation.finish()
            }
            let removeAbort = signal.onAbort {
                task.cancel()
                continuation.finish(throwing: signal.reason ?? AbortError.sharedReason)
            }
            continuation.onTermination = { _ in
                removeAbort()
                task.cancel()
            }
        }
        return HTTPStreamingResponse(
            head: HTTPResponseHead(statusCode: 200, headers: ["content-type": "text/event-stream"]),
            chunks: chunks
        )
    }

    private static func makeSessionLogStream(
        bus: CoreBus.Service,
        sessionID: SessionID,
        after: Int64?,
        follow: Bool,
        signal: AbortSignal
    ) -> HTTPStreamingResponse {
        let chunks = AsyncThrowingStream<[UInt8], Error> { continuation in
            let task = Task {
                let stream = bus.log(CoreBus.LogInput(aggregateID: sessionID.rawValue, after: after, follow: follow))
                for await item in stream {
                    if Task.isCancelled || signal.isAborted { break }
                    switch item {
                    case .event(let anyEvent):
                        if let frame = encodeSSEFrame(anyEvent) {
                            continuation.yield(frame)
                        }
                    case .synced(let synced):
                        if let frame = encodeSSEFrame(synced) {
                            continuation.yield(frame)
                        }
                    }
                }
                continuation.finish()
            }
            let removeAbort = signal.onAbort {
                task.cancel()
                continuation.finish(throwing: signal.reason ?? AbortError.sharedReason)
            }
            continuation.onTermination = { _ in
                removeAbort()
                task.cancel()
            }
        }
        return HTTPStreamingResponse(
            head: HTTPResponseHead(statusCode: 200, headers: ["content-type": "text/event-stream"]),
            chunks: chunks
        )
    }

    private static func encodeSSEFrame<T: Encodable>(_ value: T) -> [UInt8]? {
        guard let encoded = try? ClientCodec.encodeString(value) else { return nil }
        return Array("data: \(encoded)\n\n".utf8)
    }

    private static func jsonResponse<T: Encodable>(
        _ value: T,
        statusCode: Int = 200
    ) throws -> OwnedFetch.HandlerResponse {
        let bytes = try ClientCodec.encode(value)
        return .buffered(
            HTTPResponse(
                head: HTTPResponseHead(statusCode: statusCode, headers: ["content-type": "application/json"]),
                body: bytes
            )
        )
    }

    private static func jsonDataResponse<T: Equatable & Hashable & Sendable & Codable>(
        _ value: T,
        statusCode: Int = 200
    ) throws -> OwnedFetch.HandlerResponse {
        try jsonResponse(ClientDataEnvelope(data: value), statusCode: statusCode)
    }

    private static func emptyResponse(_ statusCode: Int) -> OwnedFetch.HandlerResponse {
        .buffered(HTTPResponse(head: HTTPResponseHead(statusCode: statusCode, headers: [:]), body: []))
    }

    private static func sessionNotFoundResponse(_ sessionID: SessionID) throws -> OwnedFetch.HandlerResponse {
        let err = OpenCodeProtocol.SessionNotFoundError(
            sessionID: sessionID.rawValue,
            message: "Session not found: \(sessionID.rawValue)"
        )
        return try jsonResponse(err, statusCode: 404)
    }

    private static func messageNotFoundResponse(sessionID: SessionID, messageID: String) throws -> OwnedFetch.HandlerResponse {
        let err = OpenCodeProtocol.MessageNotFoundError(
            sessionID: sessionID.rawValue,
            messageID: messageID,
            message: "Message \(messageID) not found in session \(sessionID.rawValue)"
        )
        return try jsonResponse(err, statusCode: 404)
    }

    private static func badRequestResponse(_ message: String) -> OwnedFetch.HandlerResponse {
        let body = (try? ClientCodec.encode(["_tag": "BadRequestError", "message": message])) ?? []
        return .buffered(HTTPResponse(head: HTTPResponseHead(statusCode: 400, headers: ["content-type": "application/json"]), body: body))
    }

    private static func internalErrorResponse(_ message: String) -> OwnedFetch.HandlerResponse {
        let body = (try? ClientCodec.encode(["_tag": "InternalError", "message": message])) ?? []
        return .buffered(HTTPResponse(head: HTTPResponseHead(statusCode: 500, headers: ["content-type": "application/json"]), body: body))
    }

    private static func defaultPublicLocationRef(_ ctx: EmbeddedHost.RouterContext) -> LocationSchema.PublicRef {
        LocationSchema.PublicRef(
            directory: SchemaPrimitive.AbsolutePath(rawValue: ctx.serverOptions.config?.directory ?? "/")
        )
    }

    private static func parsePublicLocationQuery(_ query: [String: String]) -> LocationSchema.PublicRef? {
        guard let dir = query["location[directory]"], !dir.isEmpty else { return nil }
        return LocationSchema.PublicRef(directory: SchemaPrimitive.AbsolutePath(rawValue: dir))
    }

    private static func decodeJSONObject(_ bytes: [UInt8]?) throws -> [String: JSONValue] {
        guard let bytes, !bytes.isEmpty else { return [:] }
        let value = try ClientCodec.decode(JSONValue.self, from: bytes)
        guard case .object(let dict) = value else { return [:] }
        return dict
    }

    private static func stringField(_ obj: [String: JSONValue], _ key: String) -> String? {
        if case .string(let s) = obj[key] { return s }
        return nil
    }

    private static func objectField(_ obj: [String: JSONValue], _ key: String) -> [String: JSONValue]? {
        if case .object(let dict) = obj[key] { return dict }
        return nil
    }

    private static func decodeField<T: Decodable>(_ obj: [String: JSONValue], _ key: String) throws -> T? {
        guard let raw = obj[key], raw != .null else { return nil }
        return try ClientCodec.fromJSONValue(T.self, value: raw)
    }

    private static func decodeLocationField(_ obj: [String: JSONValue]) -> OpenCodeLocation? {
        guard case .object(let locObj) = obj["location"],
              case .string(let dir) = locObj["directory"]
        else { return nil }
        let wid: WorkspaceID? = {
            if case .string(let w) = locObj["workspaceID"] { return WorkspaceID(rawValue: w) }
            return nil
        }()
        return OpenCodeLocation(directory: dir, workspaceID: wid)
    }

    private static func parseURL(_ rawURL: String) -> (path: String, query: [String: String]) {
        let withoutFragment = rawURL.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? rawURL
        let parts = withoutFragment.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let prefix = String(parts[0])
        let queryString = parts.count > 1 ? String(parts[1]) : ""

        let path: String
        if let schemeRange = prefix.range(of: "://") {
            let afterScheme = prefix[schemeRange.upperBound...]
            if let slash = afterScheme.firstIndex(of: "/") {
                path = String(afterScheme[slash...])
            } else {
                path = "/"
            }
        } else {
            path = prefix.isEmpty ? "/" : prefix
        }

        var query: [String: String] = [:]
        if !queryString.isEmpty {
            for pair in queryString.split(separator: "&", omittingEmptySubsequences: true) {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let key = decodeURIComponent(String(kv[0]).replacing("+", with: " "))
                let value = kv.count > 1 ? decodeURIComponent(String(kv[1]).replacing("+", with: " ")) : ""
                query[key] = value
            }
        }
        return (path, query)
    }

    private static func decodeURIComponent(_ value: String) -> String {
        let bytes = Array(value.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x25, i + 2 < bytes.count,
               let hi = hexVal(bytes[i + 1]),
               let lo = hexVal(bytes[i + 2])
            {
                out.append((hi << 4) | lo)
                i += 3
            } else {
                out.append(bytes[i])
                i += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func hexVal(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30
        case 0x41...0x46: return byte - 0x41 + 10
        case 0x61...0x66: return byte - 0x61 + 10
        default: return nil
        }
    }
}
