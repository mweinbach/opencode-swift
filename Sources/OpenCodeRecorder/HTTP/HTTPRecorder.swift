import OpenCodePlatform
import OpenCodeUtil

/// Recording/replaying operational mode matching `packages/http-recorder/src/http/recorder.ts#RecordReplayMode`.
// parity: http-recorder/src/http/recorder.ts#RecordReplayMode [status=implemented hash=7c5a855afd2e]
public enum RecordReplayMode: String, Equatable, Hashable, Sendable, Codable {
    case auto
    case record
    case replay
    case passthrough
}

/// Strategy controlling how incoming HTTP requests match recorded cassette entries during replay.
public enum ReplayMatchStrategy: Equatable, Hashable, Sendable {
    /// Upstream default: claims the first unused matching interaction (distinct requests in any order;
    /// repeated identical requests in cassette order).
    case pool
    /// Strict FIFO order: each incoming request must match the next unconsumed interaction at `index == used.count`.
    case sequential
    /// Strict pool matching: claims first unused match and rejects any mismatch or unconsumed interaction.
    case strict
    /// Attempts to replay a matching recorded interaction; on miss or missing cassette, falls back to upstream
    /// (optionally recording the fallback interaction into the cassette).
    case fallback(recordMissing: Bool = false)
}

/// Configuration for `RecordingHTTPTransport` matching `packages/http-recorder/src/http/recorder.ts#RecordReplayOptions`.
// parity: http-recorder/src/http/recorder.ts#RecordReplayOptions [status=implemented hash=e6afed12a070]
public struct RecordReplayOptions: Sendable {
    public let mode: RecordReplayMode?
    public let directory: String?
    public let metadata: CassetteMetadata?
    public let redactor: Redactor?
    public let match: RequestMatcher?
    public let replayStrategy: ReplayMatchStrategy

    public init(
        mode: RecordReplayMode? = nil,
        directory: String? = nil,
        metadata: CassetteMetadata? = nil,
        redactor: Redactor? = nil,
        match: RequestMatcher? = nil,
        replayStrategy: ReplayMatchStrategy = .pool
    ) {
        self.mode = mode
        self.directory = directory
        self.metadata = metadata
        self.redactor = redactor
        self.match = match
        self.replayStrategy = replayStrategy
    }
}

/// Transport error surfaced by `RecordingHTTPTransport` with redacted request metadata.
public struct RecorderTransportError: Error, Equatable, Sendable, CustomStringConvertible {
    public let request: HTTPRequest
    public let detail: String

    public init(request: HTTPRequest, description: String) {
        self.request = request
        self.detail = description
    }

    public var message: String { detail }
    public var description: String { detail }
}

/// Returns a sanitized copy of `request` containing only its method and redacted URL (no headers or body).
// parity: http-recorder/src/http/recorder.ts#redactedErrorRequest [status=implemented hash=58c585c835ef]
public func redactedErrorRequest(
    _ request: HTTPRequest,
    redactedUrl: String? = nil
) -> HTTPRequest {
    HTTPRequest(
        method: request.method,
        url: redactedUrl ?? redactUrl(request.url),
        headers: [:],
        body: nil
    )
}

private let textContentTypes: Set<String> = [
    "application/graphql",
    "application/javascript",
    "application/json",
    "application/sql",
    "application/x-www-form-urlencoded",
    "application/xml",
    "application/yaml",
    "image/svg+xml",
]

internal func isTextContentType(_ contentType: String?) -> Bool {
    guard let contentType else { return false }
    let mediaPart = contentType.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
    var trimmed = Substring(mediaPart)
    while let first = trimmed.first, first.isWhitespace {
        trimmed = trimmed.dropFirst()
    }
    while let last = trimmed.last, last.isWhitespace {
        trimmed = trimmed.dropLast()
    }
    let mediaType = trimmed.lowercased()
    guard !mediaType.isEmpty else { return false }
    return mediaType.hasPrefix("text/")
        || mediaType.hasSuffix("+json")
        || mediaType.hasSuffix("+xml")
        || textContentTypes.contains(mediaType)
}

private func headerValue(in headers: [String: String], named target: String) -> String? {
    let lowerTarget = target.lowercased()
    for (key, value) in headers where key.lowercased() == lowerTarget {
        return value
    }
    return nil
}

private func captureResponseSnapshot(
    head: HTTPResponseHead,
    bodyBytes: [UInt8]
) -> ResponseSnapshot {
    let contentType = headerValue(in: head.headers, named: "content-type")
    if isTextContentType(contentType) {
        return ResponseSnapshot(
            status: head.statusCode,
            headers: head.headers,
            body: String(decoding: bodyBytes, as: UTF8.self),
            bodyEncoding: nil
        )
    }
    return ResponseSnapshot(
        status: head.statusCode,
        headers: head.headers,
        body: bytesToBase64(bodyBytes),
        bodyEncoding: .base64
    )
}

private func decodeResponseBody(_ snapshot: ResponseSnapshot) throws -> [UInt8] {
    if snapshot.bodyEncoding == .base64 {
        return try base64ToBytes(snapshot.body)
    }
    return Array(snapshot.body.utf8)
}

private func responseFromSnapshot(
    request: HTTPRequest,
    snapshot: ResponseSnapshot
) throws -> HTTPResponse {
    let isNullBody = request.method.uppercased() == "HEAD"
        || snapshot.status == 204
        || snapshot.status == 205
        || snapshot.status == 304
    let body = isNullBody ? [] : try decodeResponseBody(snapshot)
    return HTTPResponse(
        head: HTTPResponseHead(statusCode: snapshot.status, headers: snapshot.headers),
        body: body
    )
}

private func snapshotFromRequest(_ request: HTTPRequest) -> RequestSnapshot {
    RequestSnapshot(
        method: request.method,
        url: request.url,
        headers: request.headers,
        body: request.body.map { String(decoding: $0, as: UTF8.self) } ?? ""
    )
}

private func transportError(
    _ request: HTTPRequest,
    description: String,
    redactedUrl: String? = nil
) -> RecorderTransportError {
    RecorderTransportError(
        request: redactedErrorRequest(request, redactedUrl: redactedUrl),
        description: description
    )
}

// MARK: - Request-Start Ordering Queue

private actor CommitSignal {
    private var completed = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if completed { return }
        await withCheckedContinuation { continuation in
            if completed {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }

    func complete() {
        guard !completed else { return }
        completed = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}

private actor OrderedCommitQueue {
    private var tail: CommitSignal?

    func reserve() -> (previous: CommitSignal?, current: CommitSignal) {
        let current = CommitSignal()
        let previous = tail
        tail = current
        return (previous, current)
    }

    func waitForAll() async {
        if let tail {
            await tail.wait()
        }
    }
}

// MARK: - RecordingHTTPTransport

/// Portable `HTTPTransport` wrapper that records live HTTP & streaming responses to JSON cassettes,
/// automatically redacts credentials, and replays cassettes deterministically with rich mismatch diffs.
public final class RecordingHTTPTransport: HTTPTransport, Sendable {
    private actor RuntimeState {
        private let upstream: any HTTPTransport
        private let cassette: any CassetteStoreInterface
        private let name: String
        private let options: RecordReplayOptions
        private let environment: any EnvironmentProviding

        private var resolveTask: Task<RecordReplayMode, Never>?
        private var replayPool: ReplayPoolState<HttpInteraction>?
        private var replaySequential: ReplayState<HttpInteraction>?

        init(
            upstream: any HTTPTransport,
            cassette: any CassetteStoreInterface,
            name: String,
            options: RecordReplayOptions,
            environment: any EnvironmentProviding
        ) {
            self.upstream = upstream
            self.cassette = cassette
            self.name = name
            self.options = options
            self.environment = environment
        }

        func effectiveMode() async -> RecordReplayMode {
            let task: Task<RecordReplayMode, Never>
            if let existing = resolveTask {
                task = existing
            } else {
                let requested = options.mode ?? .auto
                let cassetteRef = self.cassette
                let cassetteName = self.name
                let envRef = self.environment
                let created = Task<RecordReplayMode, Never> {
                    if requested == .auto {
                        return await resolveAutoMode(cassette: cassetteRef, name: cassetteName, environment: envRef)
                    }
                    return requested
                }
                resolveTask = created
                task = created
            }
            let mode = await task.value
            if mode == .replay && replayPool == nil {
                let pool = makeReplayPoolState(cassette: cassette, name: name, project: httpInteractions)
                replayPool = pool
                replaySequential = ReplayState(pool: pool)
            }
            return mode
        }

        func pool() async -> ReplayPoolState<HttpInteraction> {
            _ = await effectiveMode()
            if let replayPool {
                return replayPool
            }
            let pool = makeReplayPoolState(cassette: cassette, name: name, project: httpInteractions)
            replayPool = pool
            replaySequential = ReplayState(pool: pool)
            return pool
        }

        func sequential() async -> ReplayState<HttpInteraction> {
            let poolState = await pool()
            if let replaySequential {
                return replaySequential
            }
            let seq = ReplayState(pool: poolState)
            replaySequential = seq
            return seq
        }
    }

    public let name: String
    public let options: RecordReplayOptions

    private let upstream: any HTTPTransport
    private let cassette: any CassetteStoreInterface
    private let redactor: Redactor
    private let matcher: RequestMatcher
    private let environment: any EnvironmentProviding
    private let runtime: RuntimeState
    private let commitQueue = OrderedCommitQueue()

    public init(
        name: String,
        upstream: any HTTPTransport,
        cassette: any CassetteStoreInterface,
        options: RecordReplayOptions = RecordReplayOptions(),
        environment: any EnvironmentProviding = SystemEnvironment.shared
    ) {
        self.name = name
        self.options = options
        self.upstream = upstream
        self.cassette = cassette
        self.redactor = options.redactor ?? Redactor.make()
        self.matcher = options.match ?? defaultMatcher
        self.environment = environment
        self.runtime = RuntimeState(
            upstream: upstream,
            cassette: cassette,
            name: name,
            options: options,
            environment: environment
        )
    }

    /// Resolves and returns the active operating mode (`.record`, `.replay`, or `.passthrough`).
    public func resolvedMode() async -> RecordReplayMode {
        await runtime.effectiveMode()
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let mode = await runtime.effectiveMode()
        switch mode {
        case .passthrough:
            return try await upstream.send(request)
        case .record:
            return try await recordSend(request)
        case .replay, .auto:
            return try await replaySend(request)
        }
    }

    public func stream(_ request: HTTPRequest) async throws -> HTTPStreamingResponse {
        let mode = await runtime.effectiveMode()
        switch mode {
        case .passthrough:
            return try await upstream.stream(request)
        case .record:
            return try await recordStream(request)
        case .replay, .auto:
            return try await replayStream(request)
        }
    }

    /// Finalizes the recording/replaying scope: awaits pending cassette writes in record mode,
    /// and verifies all recorded interactions were consumed in replay mode (except `.fallback`).
    public func finish() async throws {
        let mode = await runtime.effectiveMode()
        switch mode {
        case .passthrough:
            return
        case .record:
            await commitQueue.waitForAll()
        case .replay, .auto:
            if case .fallback = options.replayStrategy {
                await commitQueue.waitForAll()
                return
            }
            let pool = await runtime.pool()
            try await pool.verifyAllConsumed()
        }
    }

    /// Executes `body` with this transport and validates completion via `finish()` when `body` succeeds.
    public func withScope<T: Sendable>(
        _ body: (RecordingHTTPTransport) async throws -> T
    ) async throws -> T {
        let result = try await body(self)
        try await finish()
        return result
    }

    // MARK: - Record Path

    private func recordSend(_ request: HTTPRequest) async throws -> HTTPResponse {
        let (previous, current) = await commitQueue.reserve()
        do {
            let incoming = redactor.request(snapshotFromRequest(request))
            let live = try await upstream.send(request)
            let responseSnapshot = captureResponseSnapshot(head: live.head, bodyBytes: live.body)
            let interaction = HttpInteraction(
                request: incoming,
                response: redactor.response(responseSnapshot)
            )
            if let previous {
                await previous.wait()
            }
            do {
                try await cassette.append(name, interaction: .http(interaction), metadata: options.metadata)
            } catch let error as UnsafeCassetteError {
                throw transportError(request, description: error.message, redactedUrl: incoming.url)
            }
            await current.complete()
            return live
        } catch {
            await current.complete()
            throw error
        }
    }

    private func recordStream(_ request: HTTPRequest) async throws -> HTTPStreamingResponse {
        let (previous, current) = await commitQueue.reserve()
        let incoming = redactor.request(snapshotFromRequest(request))
        let live: HTTPStreamingResponse
        do {
            live = try await upstream.stream(request)
        } catch {
            await current.complete()
            throw error
        }

        let (stream, continuation) = AsyncThrowingStream<[UInt8], Error>.makeStream(bufferingPolicy: .unbounded)
        let cassetteStore = self.cassette
        let cassetteName = self.name
        let metadata = self.options.metadata
        let redactor = self.redactor

        let pump = Task {
            var buffered: [UInt8] = []
            do {
                for try await chunk in live.chunks {
                    buffered.append(contentsOf: chunk)
                    continuation.yield(chunk)
                }
                let responseSnapshot = captureResponseSnapshot(head: live.head, bodyBytes: buffered)
                let interaction = HttpInteraction(
                    request: incoming,
                    response: redactor.response(responseSnapshot)
                )
                if let previous {
                    await previous.wait()
                }
                do {
                    try await cassetteStore.append(cassetteName, interaction: .http(interaction), metadata: metadata)
                } catch let error as UnsafeCassetteError {
                    await current.complete()
                    continuation.finish(
                        throwing: transportError(request, description: error.message, redactedUrl: incoming.url)
                    )
                    return
                }
                await current.complete()
                continuation.finish()
            } catch {
                await current.complete()
                continuation.finish(throwing: error)
            }
        }

        continuation.onTermination = { termination in
            if case .cancelled = termination {
                pump.cancel()
            }
        }

        return HTTPStreamingResponse(head: live.head, chunks: stream)
    }

    // MARK: - Replay Path

    private func replaySend(_ request: HTTPRequest) async throws -> HTTPResponse {
        let incoming = redactor.request(snapshotFromRequest(request))
        switch options.replayStrategy {
        case .pool, .strict:
            let interaction = try await claimPool(request: request, incoming: incoming)
            return try responseFromSnapshot(request: request, snapshot: interaction.response)

        case .sequential:
            let interaction = try await claimSequential(request: request, incoming: incoming)
            return try responseFromSnapshot(request: request, snapshot: interaction.response)

        case .fallback(let recordMissing):
            do {
                let interaction = try await claimPool(request: request, incoming: incoming)
                return try responseFromSnapshot(request: request, snapshot: interaction.response)
            } catch is RecorderTransportError {
                if recordMissing {
                    return try await recordSend(request)
                }
                return try await upstream.send(request)
            }
        }
    }

    private func replayStream(_ request: HTTPRequest) async throws -> HTTPStreamingResponse {
        if case .fallback(let recordMissing) = options.replayStrategy {
            let incoming = redactor.request(snapshotFromRequest(request))
            do {
                let interaction = try await claimPool(request: request, incoming: incoming)
                let response = try responseFromSnapshot(request: request, snapshot: interaction.response)
                return streamingFromResponse(response)
            } catch is RecorderTransportError {
                if recordMissing {
                    return try await recordStream(request)
                }
                return try await upstream.stream(request)
            }
        }
        let response = try await replaySend(request)
        return streamingFromResponse(response)
    }

    private func streamingFromResponse(_ response: HTTPResponse) -> HTTPStreamingResponse {
        let (stream, continuation) = AsyncThrowingStream<[UInt8], Error>.makeStream()
        if !response.body.isEmpty {
            continuation.yield(response.body)
        }
        continuation.finish()
        return HTTPStreamingResponse(head: response.head, chunks: stream)
    }

    private func claimPool(request: HTTPRequest, incoming: RequestSnapshot) async throws -> HttpInteraction {
        let pool = await runtime.pool()
        let matcher = self.matcher
        let env = self.environment
        let cassetteName = self.name
        do {
            let claimed = try await pool.claim { interactions, used in
                switch selectFirstMatching(
                    interactions: interactions,
                    incoming: incoming,
                    match: matcher,
                    used: used,
                    environment: env
                ) {
                case .matched(let index):
                    return index
                case .unmatched(let detail):
                    throw transportError(
                        request,
                        description: "Fixture \"\(cassetteName)\" does not match the current request: \(detail).",
                        redactedUrl: incoming.url
                    )
                }
            }
            return claimed.interaction
        } catch let error as RecorderTransportError {
            throw error
        } catch is CassetteNotFoundError {
            throw transportError(
                request,
                description: "Fixture \"\(cassetteName)\" not found. Run locally to record it (CI=true forces replay).",
                redactedUrl: incoming.url
            )
        } catch let error as InvalidCassetteError {
            throw transportError(request, description: error.message, redactedUrl: incoming.url)
        } catch {
            throw transportError(request, description: String(describing: error), redactedUrl: incoming.url)
        }
    }

    private func claimSequential(request: HTTPRequest, incoming: RequestSnapshot) async throws -> HttpInteraction {
        let seq = await runtime.sequential()
        let matcher = self.matcher
        let env = self.environment
        let cassetteName = self.name
        do {
            let claimed = try await seq.claim { candidate, _, interactions in
                guard let candidate else {
                    throw transportError(
                        request,
                        description: "Fixture \"\(cassetteName)\" does not match the current request: all \(interactions.count) recorded interactions have already been consumed.",
                        redactedUrl: incoming.url
                    )
                }
                if !matcher(incoming, candidate.request) {
                    let detail = requestDiff(
                        expected: candidate.request,
                        received: incoming,
                        environment: env
                    ).joined(separator: "\n")
                    throw transportError(
                        request,
                        description: "Fixture \"\(cassetteName)\" does not match the current request: \(detail).",
                        redactedUrl: incoming.url
                    )
                }
            }
            return claimed.interaction
        } catch let error as RecorderTransportError {
            throw error
        } catch is CassetteNotFoundError {
            throw transportError(
                request,
                description: "Fixture \"\(cassetteName)\" not found. Run locally to record it (CI=true forces replay).",
                redactedUrl: incoming.url
            )
        } catch let error as InvalidCassetteError {
            throw transportError(request, description: error.message, redactedUrl: incoming.url)
        } catch {
            throw transportError(request, description: String(describing: error), redactedUrl: incoming.url)
        }
    }
}

// MARK: - HTTP Recorder Layer Factories

/// Factory namespace mirroring `packages/http-recorder/src/http/recorder.ts`.
public enum HTTPRecorder {
    /// Re-export of `defaultMatcher` matching `packages/http-recorder/src/http/recorder.ts#defaultMatcher`.
    // parity: http-recorder/src/http/recorder.ts#defaultMatcher [status=implemented hash=eb0658b90498]
    public static let defaultMatcher: RequestMatcher = OpenCodeRecorder.defaultMatcher

    /// Wraps an explicit `HTTPTransport` and `CassetteStoreInterface` into a `RecordingHTTPTransport`.
    // parity: http-recorder/src/http/recorder.ts#recordingLayer [status=implemented hash=e95fbdc0abd0]
    public static func recordingLayer(
        _ name: String,
        options: RecordReplayOptions = RecordReplayOptions(),
        upstream: any HTTPTransport,
        cassette: any CassetteStoreInterface,
        environment: any EnvironmentProviding = SystemEnvironment.shared
    ) -> RecordingHTTPTransport {
        RecordingHTTPTransport(
            name: name,
            upstream: upstream,
            cassette: cassette,
            options: options,
            environment: environment
        )
    }

    /// Creates a filesystem-backed `RecordingHTTPTransport` with explicit mode/options and default fetch transport.
    // parity: http-recorder/src/http/recorder.ts#cassetteLayer [status=implemented hash=5d14516d1644]
    public static func cassetteLayer(
        _ name: String,
        options: RecordReplayOptions = RecordReplayOptions(),
        upstream: any HTTPTransport = URLSessionHTTPTransport.shared,
        fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
        environment: any EnvironmentProviding = SystemEnvironment.shared
    ) -> RecordingHTTPTransport {
        let store = CassetteStoreService.fileSystem(
            directory: options.directory,
            fileSystem: fileSystem,
            environment: environment
        )
        return recordingLayer(
            name,
            options: options,
            upstream: upstream,
            cassette: store,
            environment: environment
        )
    }

    /// Decorates a caller-provided `HTTPTransport` with auto record/replay backed by a filesystem cassette store.
    // parity: http-recorder/src/http/recorder.ts#layer [status=implemented hash=a48bf3a138b9]
    public static func layer(
        _ name: String,
        options: RecorderOptions = RecorderOptions(),
        upstream: any HTTPTransport,
        fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
        environment: any EnvironmentProviding = SystemEnvironment.shared
    ) -> RecordingHTTPTransport {
        let store = CassetteStoreService.fileSystem(
            directory: options.directory,
            fileSystem: fileSystem,
            environment: environment
        )
        let replayOptions = RecordReplayOptions(
            mode: .auto,
            directory: options.directory,
            metadata: options.metadata,
            redactor: Redactor.make(options.redact ?? RedactOptions()),
            match: options.match
        )
        return recordingLayer(
            name,
            options: replayOptions,
            upstream: upstream,
            cassette: store,
            environment: environment
        )
    }

    /// Convenience layer wiring `URLSessionHTTPTransport.shared` with auto record/replay cassette persistence.
    // parity: http-recorder/src/http/recorder.ts#layerFetch [status=implemented hash=f4d197fac8ac]
    public static func layerFetch(
        _ name: String,
        options: RecorderOptions = RecorderOptions(),
        fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
        environment: any EnvironmentProviding = SystemEnvironment.shared
    ) -> RecordingHTTPTransport {
        layer(
            name,
            options: options,
            upstream: URLSessionHTTPTransport.shared,
            fileSystem: fileSystem,
            environment: environment
        )
    }
}
