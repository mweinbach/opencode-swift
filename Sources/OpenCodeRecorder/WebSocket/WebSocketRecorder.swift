import OpenCodePlatform
import OpenCodeUtil
import Synchronization

// MARK: - Portable WebSocket Transport Abstractions

/// A single WebSocket payload frame (UTF-8 text or raw binary bytes).
public enum WebSocketFrame: Equatable, Hashable, Sendable {
    case text(String)
    case binary([UInt8])
}

/// Outbound message written to a WebSocket writer (a data frame or close frame).
public enum WebSocketWriteMessage: Equatable, Hashable, Sendable {
    case text(String)
    case binary([UInt8])
    case close(code: Int = 1000, reason: String = "")
}

/// Ready-state enum matching the W3C WebSocket specification.
public enum WebSocketReadyState: Int, Equatable, Hashable, Sendable {
    case connecting = 0
    case open = 1
    case closing = 2
    case closed = 3
}

/// Error raised when a WebSocket closes (mirrors Effect `SocketCloseError`).
public struct WebSocketCloseError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
    public let code: Int
    public let reason: String

    public init(code: Int = 1000, reason: String = "") {
        self.code = code
        self.reason = reason
    }

    public var isNormalClose: Bool {
        code == 1000
    }

    public var description: String {
        reason.isEmpty ? "WebSocket closed with code \(code)" : "WebSocket closed with code \(code): \(reason)"
    }
}

/// Error raised by WebSocket recording and replay invariants.
public struct WebSocketRecorderError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}

/// Portable frame-batch reader matching Effect `Socket.Reader`.
public protocol RecorderSocketReader: Sendable {
    func pull() async throws -> [WebSocketFrame]
}

/// Portable frame writer matching Effect `Socket.Writer`.
public protocol RecorderSocketWriter: Sendable {
    func write(_ message: WebSocketWriteMessage) async throws
    func writeAll(_ frames: [WebSocketFrame]) async throws
}

public extension RecorderSocketWriter {
    func writeAll(_ frames: [WebSocketFrame]) async throws {
        for frame in frames {
            switch frame {
            case .text(let s):
                try await write(.text(s))
            case .binary(let b):
                try await write(.binary(b))
            }
        }
    }
}

/// Portable bidirectional socket abstraction matching Effect `Socket.Socket`.
public protocol RecorderSocket: Sendable {
    /// Runs `body` within a scoped socket session, opening a reader/writer pair and cleaning up on exit.
    func run<T: Sendable>(
        _ body: @Sendable (_ reader: any RecorderSocketReader, _ writer: any RecorderSocketWriter) async throws -> T
    ) async throws -> T
}

/// Portable connection facade matching browser / Node / Effect `WebSocket` constructor instances.
public protocol RecorderWebSocketConnection: Sendable {
    var url: String { get }
    var protocols: [String] { get }
    var readyState: WebSocketReadyState { get }

    func open() async throws
    func send(_ frame: WebSocketFrame) async throws
    func receive() async throws -> WebSocketFrame?
    func close(code: Int, reason: String) async throws
    var terminalClose: WebSocketClose? { get }
}

public extension RecorderWebSocketConnection {
    func close(code: Int = 1000, reason: String = "") async throws {
        try await close(code: code, reason: reason)
    }
}

/// Factory closure opening a WebSocket connection for a dynamically chosen URL and subprotocol list.
public typealias WebSocketTransportConstructor = @Sendable (
    _ url: String,
    _ protocols: [String]
) async throws -> any RecorderWebSocketConnection

// MARK: - Event Encoding, Redaction & Canonical Comparison

private func encodeEvent(direction: WebSocketDirection, frame: WebSocketFrame) -> WebSocketEvent {
    switch frame {
    case .text(let text):
        return .text(direction: direction, body: text)
    case .binary(let bytes):
        return .binary(direction: direction, bytes: bytes)
    }
}

private func decodeEvent(_ event: WebSocketEvent) throws -> WebSocketFrame {
    switch event {
    case .text(_, let body):
        return .text(body)
    case .binary(_, let body):
        return .binary(try base64ToBytes(body))
    }
}

private func redactEvent(_ event: WebSocketEvent, redactor: Redactor) -> WebSocketEvent {
    switch event {
    case .binary:
        return event
    case let .text(direction, body):
        let redactedBody: String
        switch direction {
        case .client:
            redactedBody = redactor.request(
                RequestSnapshot(method: "WEBSOCKET", url: "", headers: [:], body: body)
            ).body
        case .server:
            redactedBody = redactor.response(
                ResponseSnapshot(status: 101, headers: [:], body: body)
            ).body
        }
        return .text(direction: direction, body: redactedBody)
    }
}

private func comparableEvent(_ event: WebSocketEvent, asJson: Bool) -> String {
    let encoded = WebSocketEventSchema.encode(event)
    if !asJson || event.kind == .binary {
        return PureJSON.stringifyCompact(canonicalizeJson(encoded))
    }
    let bodyValue: PureJSONValue
    if let parsed = decodeJson(event.body) {
        bodyValue = canonicalizeJson(parsed)
    } else {
        bodyValue = .string(event.body)
    }
    let adjusted: PureJSONValue = .object([
        ("direction", .string(event.direction.rawValue)),
        ("kind", .string("text")),
        ("body", bodyValue),
    ])
    return PureJSON.stringifyCompact(canonicalizeJson(adjusted))
}

private func assertEvent(
    actual: WebSocketEvent,
    expected: WebSocketEvent?,
    index: Int,
    asJson: Bool,
    environment: any EnvironmentProviding
) throws {
    if let expected, comparableEvent(actual, asJson: asJson) == comparableEvent(expected, asJson: asJson) {
        return
    }
    let expText = safeText(expected.map(WebSocketEventSchema.encode), environment: environment)
    let actText = safeText(WebSocketEventSchema.encode(actual), environment: environment)
    throw WebSocketRecorderError("WebSocket event \(index + 1): expected \(expText), received \(actText)")
}

private func isNormalCloseError(_ error: any Error) -> Bool {
    guard let closeError = error as? WebSocketCloseError else { return false }
    return closeError.code == 1000
}

// MARK: - Recording & Replay Socket (`layerSocket` / `layerSocketWithMode`)

private actor RecordingSocketSession {
    private var active = false
    private var events: [WebSocketEvent] = []
    private var accepting = false
    private var opened = false
    private var clientClosed = false
    private var valid = true

    func beginSession() throws {
        if active {
            throw WebSocketRecorderError("Concurrent runs of a recorded WebSocket are not supported")
        }
        active = true
        events = []
        accepting = true
        opened = false
        clientClosed = false
        valid = true
    }

    func markOpened() {
        opened = true
    }

    func recordServerFrames(_ frames: [WebSocketFrame], redactor: Redactor) throws {
        guard accepting else {
            throw WebSocketRecorderError("WebSocket received a frame after closing")
        }
        for frame in frames {
            events.append(redactEvent(encodeEvent(direction: .server, frame: frame), redactor: redactor))
        }
    }

    func markInvalid() {
        valid = false
    }

    func recordClientFrames(_ frames: [WebSocketFrame], redactor: Redactor) throws {
        guard active && accepting else {
            throw WebSocketRecorderError("WebSocket writer used without an active socket run")
        }
        if clientClosed {
            throw WebSocketRecorderError("WebSocket writer used after the client closed")
        }
        for frame in frames {
            events.append(redactEvent(encodeEvent(direction: .client, frame: frame), redactor: redactor))
        }
    }

    func markClientClosed() {
        clientClosed = true
    }

    func finishSession(normalExit: Bool) -> [WebSocketEvent]? {
        accepting = false
        active = false
        let shouldPersist = opened && valid && normalExit
        let snapshot = events
        events = []
        return shouldPersist ? snapshot : nil
    }
}

private final class RecordingSocketReaderProxy: RecorderSocketReader, Sendable {
    private let upstream: any RecorderSocketReader
    private let session: RecordingSocketSession
    private let redactor: Redactor

    init(upstream: any RecorderSocketReader, session: RecordingSocketSession, redactor: Redactor) {
        self.upstream = upstream
        self.session = session
        self.redactor = redactor
    }

    func pull() async throws -> [WebSocketFrame] {
        do {
            let frames = try await upstream.pull()
            try await session.recordServerFrames(frames, redactor: redactor)
            return frames
        } catch {
            if !isNormalCloseError(error) {
                await session.markInvalid()
            }
            throw error
        }
    }
}

private final class RecordingSocketWriterProxy: RecorderSocketWriter, Sendable {
    private let upstream: any RecorderSocketWriter
    private let session: RecordingSocketSession
    private let redactor: Redactor

    init(upstream: any RecorderSocketWriter, session: RecordingSocketSession, redactor: Redactor) {
        self.upstream = upstream
        self.session = session
        self.redactor = redactor
    }

    func write(_ message: WebSocketWriteMessage) async throws {
        switch message {
        case .close:
            await session.markClientClosed()
            do {
                try await upstream.write(message)
            } catch {
                await session.markInvalid()
                throw error
            }
        case .text(let s):
            try await session.recordClientFrames([.text(s)], redactor: redactor)
            do {
                try await upstream.write(message)
            } catch {
                await session.markInvalid()
                throw error
            }
        case .binary(let b):
            try await session.recordClientFrames([.binary(b)], redactor: redactor)
            do {
                try await upstream.write(message)
            } catch {
                await session.markInvalid()
                throw error
            }
        }
    }

    func writeAll(_ frames: [WebSocketFrame]) async throws {
        try await session.recordClientFrames(frames, redactor: redactor)
        do {
            try await upstream.writeAll(frames)
        } catch {
            await session.markInvalid()
            throw error
        }
    }
}

private actor ReplaySocketSession {
    private let interaction: WebSocketInteraction
    private let redactor: Redactor
    private let compareAsJson: Bool
    private let environment: any EnvironmentProviding

    private var position: Int = 0
    private var closed: Bool = false
    private var nextWaiterID: Int = 0
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]

    init(
        interaction: WebSocketInteraction,
        redactor: Redactor,
        compareAsJson: Bool,
        environment: any EnvironmentProviding
    ) {
        self.interaction = interaction
        self.redactor = redactor
        self.compareAsJson = compareAsJson
        self.environment = environment
    }

    private func notifyWaiters() {
        let pending = waiters
        waiters.removeAll()
        for waiter in pending.values {
            waiter.resume()
        }
    }

    private func cancelWaiter(_ id: Int) {
        if let waiter = waiters.removeValue(forKey: id) {
            waiter.resume()
        }
    }

    private func allocateWaiterID() -> Int {
        let id = nextWaiterID
        nextWaiterID += 1
        return id
    }

    private func registerWaiter(id: Int, continuation: CheckedContinuation<Void, Never>) {
        if closed || Task.isCancelled {
            continuation.resume()
        } else {
            waiters[id] = continuation
        }
    }

    func pull() async throws -> [WebSocketFrame] {
        while true {
            try Task.checkCancellation()
            let remaining = interaction.events[position...]
            var serverEvents: [WebSocketEvent] = []
            for event in remaining {
                if event.direction == .client { break }
                serverEvents.append(event)
            }
            if !closed && !serverEvents.isEmpty {
                position += serverEvents.count
                return try serverEvents.map(decodeEvent)
            }
            if closed || remaining.isEmpty {
                throw WebSocketCloseError(code: 1000, reason: "")
            }
            let waiterID = allocateWaiterID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    registerWaiter(id: waiterID, continuation: continuation)
                }
            } onCancel: {
                Task { await self.cancelWaiter(waiterID) }
            }
        }
    }

    func write(_ message: WebSocketWriteMessage) throws {
        switch message {
        case .close:
            closed = true
            notifyWaiters()
            if position != interaction.events.count {
                throw WebSocketRecorderError(
                    "WebSocket closed with unconsumed events: used \(position) of \(interaction.events.count)"
                )
            }
        case .text(let s):
            try validateAndAdvance(.text(s))
        case .binary(let b):
            try validateAndAdvance(.binary(b))
        }
    }

    private func validateAndAdvance(_ frame: WebSocketFrame) throws {
        let actual = redactEvent(encodeEvent(direction: .client, frame: frame), redactor: redactor)
        let expected = position < interaction.events.count ? interaction.events[position] : nil
        try assertEvent(
            actual: actual,
            expected: expected,
            index: position,
            asJson: compareAsJson,
            environment: environment
        )
        position += 1
        notifyWaiters()
    }

    func closeFromShutdown() {
        closed = true
        notifyWaiters()
    }
}

private final class ReplaySocketReaderProxy: RecorderSocketReader, Sendable {
    private let session: ReplaySocketSession

    init(session: ReplaySocketSession) {
        self.session = session
    }

    func pull() async throws -> [WebSocketFrame] {
        try await session.pull()
    }
}

private final class ReplaySocketWriterProxy: RecorderSocketWriter, Sendable {
    private let session: ReplaySocketSession

    init(session: ReplaySocketSession) {
        self.session = session
    }

    func write(_ message: WebSocketWriteMessage) async throws {
        try await session.write(message)
    }
}

/// Recorded or replayed lower-level WebSocket matching Effect `layerSocket` / `layerSocketWithMode`.
public final class RecordingWebSocket: RecorderSocket, Sendable {
    private actor RuntimeState {
        private let cassette: any CassetteStoreInterface
        private let name: String
        private let forcedMode: RecordReplayMode?
        private let environment: any EnvironmentProviding

        private var resolveTask: Task<RecordReplayMode, Never>?
        private var replayState: ReplayState<WebSocketInteraction>?
        private var replayBusy = false

        init(
            cassette: any CassetteStoreInterface,
            name: String,
            forcedMode: RecordReplayMode?,
            environment: any EnvironmentProviding
        ) {
            self.cassette = cassette
            self.name = name
            self.forcedMode = forcedMode
            self.environment = environment
        }

        func effectiveMode() async -> RecordReplayMode {
            let task: Task<RecordReplayMode, Never>
            if let existing = resolveTask {
                task = existing
            } else {
                let forced = self.forcedMode
                let cassetteRef = self.cassette
                let cassetteName = self.name
                let envRef = self.environment
                let created = Task<RecordReplayMode, Never> {
                    if let forced, forced != .auto {
                        return forced
                    }
                    return await resolveAutoMode(cassette: cassetteRef, name: cassetteName, environment: envRef)
                }
                resolveTask = created
                task = created
            }
            let mode = await task.value
            if mode == .replay && replayState == nil {
                replayState = makeReplayState(cassette: cassette, name: name, project: webSocketInteractions)
            }
            return mode
        }

        func acquireReplayLock() throws {
            if replayBusy {
                throw WebSocketRecorderError("Concurrent runs of a replayed WebSocket are not supported")
            }
            replayBusy = true
        }

        func releaseReplayLock() {
            replayBusy = false
        }

        func claimNextReplay() async throws -> WebSocketInteraction {
            _ = await effectiveMode()
            guard let replayState else {
                throw WebSocketRecorderError("Replay state unavailable")
            }
            let claimed = try await replayState.claim { interaction, _, _ in
                if interaction == nil {
                    throw WebSocketRecorderError("Missing recorded WebSocket interaction")
                }
            }
            return claimed.interaction
        }

        func verifyAllConsumed() async throws {
            if let replayState {
                try await replayState.verifyAllConsumed()
            }
        }
    }

    public let name: String
    public let options: SocketRecorderOptions
    public let compareClientMessagesAsJson: Bool

    private let upstream: any RecorderSocket
    private let cassette: any CassetteStoreInterface
    private let redactor: Redactor
    private let environment: any EnvironmentProviding
    private let runtime: RuntimeState
    private let recordingSession = RecordingSocketSession()

    public init(
        name: String,
        upstream: any RecorderSocket,
        cassette: any CassetteStoreInterface,
        options: SocketRecorderOptions = SocketRecorderOptions(),
        mode: RecordReplayMode? = nil,
        compareClientMessagesAsJson: Bool = true,
        environment: any EnvironmentProviding = SystemEnvironment.shared
    ) {
        self.name = name
        self.options = options
        self.compareClientMessagesAsJson = compareClientMessagesAsJson
        self.upstream = upstream
        self.cassette = cassette
        self.redactor = Redactor.make(options.redact ?? RedactOptions())
        self.environment = environment
        self.runtime = RuntimeState(
            cassette: cassette,
            name: name,
            forcedMode: mode,
            environment: environment
        )
    }

    public func resolvedMode() async -> RecordReplayMode {
        await runtime.effectiveMode()
    }

    public func run<T: Sendable>(
        _ body: @Sendable (_ reader: any RecorderSocketReader, _ writer: any RecorderSocketWriter) async throws -> T
    ) async throws -> T {
        let mode = await runtime.effectiveMode()
        switch mode {
        case .passthrough:
            return try await upstream.run(body)
        case .record:
            return try await runRecording(body)
        case .replay, .auto:
            return try await runReplay(body)
        }
    }

    /// Verifies that all recorded WebSocket interactions were consumed in replay mode.
    public func finish() async throws {
        let mode = await runtime.effectiveMode()
        if mode == .replay {
            try await runtime.verifyAllConsumed()
        }
    }

    private func runRecording<T: Sendable>(
        _ body: @Sendable (_ reader: any RecorderSocketReader, _ writer: any RecorderSocketWriter) async throws -> T
    ) async throws -> T {
        try await recordingSession.beginSession()
        let session = self.recordingSession
        let redactor = self.redactor
        var exitError: (any Error)?
        var result: T?

        do {
            result = try await upstream.run { upstreamReader, upstreamWriter in
                await session.markOpened()
                let readerProxy = RecordingSocketReaderProxy(
                    upstream: upstreamReader,
                    session: session,
                    redactor: redactor
                )
                let writerProxy = RecordingSocketWriterProxy(
                    upstream: upstreamWriter,
                    session: session,
                    redactor: redactor
                )
                return try await body(readerProxy, writerProxy)
            }
        } catch {
            exitError = error
        }

        let normalExit: Bool
        if let exitError {
            normalExit = isNormalCloseError(exitError)
        } else {
            normalExit = true
        }

        if let recordedEvents = await session.finishSession(normalExit: normalExit) {
            let interaction = WebSocketInteraction(connection: nil, events: recordedEvents)
            try await cassette.append(name, interaction: .websocket(interaction), metadata: options.metadata)
        }

        if let exitError {
            throw exitError
        }
        return result!
    }

    private func runReplay<T: Sendable>(
        _ body: @Sendable (_ reader: any RecorderSocketReader, _ writer: any RecorderSocketWriter) async throws -> T
    ) async throws -> T {
        try await runtime.acquireReplayLock()
        let interaction: WebSocketInteraction
        do {
            interaction = try await runtime.claimNextReplay()
        } catch {
            await runtime.releaseReplayLock()
            throw error
        }

        let session = ReplaySocketSession(
            interaction: interaction,
            redactor: redactor,
            compareAsJson: compareClientMessagesAsJson,
            environment: environment
        )
        let readerProxy = ReplaySocketReaderProxy(session: session)
        let writerProxy = ReplaySocketWriterProxy(session: session)

        do {
            let value = try await body(readerProxy, writerProxy)
            await session.closeFromShutdown()
            await runtime.releaseReplayLock()
            return value
        } catch {
            await session.closeFromShutdown()
            await runtime.releaseReplayLock()
            throw error
        }
    }
}

// MARK: - Constructor-Level WebSocket Recorder & Replayer (`layerWebSocketConstructor`)

private func constructorWebSocketInteractions(_ interactions: [Interaction]) -> [WebSocketInteraction] {
    let indexed = webSocketInteractions(interactions)
        .filter { $0.connection != nil }
        .enumerated()
        .map { (index: $0.offset, interaction: $0.element) }
    return indexed
        .sorted { lhs, rhs in
            let lSeq = lhs.interaction.connection!.sequence
            let rSeq = rhs.interaction.connection!.sequence
            if lSeq != rSeq { return lSeq < rSeq }
            return lhs.index < rhs.index
        }
        .map(\.interaction)
}

private final class RecordingWebSocketConnectionProxy: RecorderWebSocketConnection, Sendable {
    private actor State {
        var events: [WebSocketEvent] = []
        var opened = false
        var failed = false
        var closed = false
        var persisted = false
        var terminalClose: WebSocketClose?

        func markOpened() { opened = true }
        func markFailed() { failed = true }

        func append(_ event: WebSocketEvent) {
            guard !failed && !closed else { return }
            events.append(event)
        }

        func finishClose(code: Int, reason: String) -> (shouldPersist: Bool, events: [WebSocketEvent], close: WebSocketClose) {
            if persisted {
                return (false, [], terminalClose ?? WebSocketClose(code: code, reason: reason))
            }
            closed = true
            persisted = true
            let close = WebSocketClose(code: code, reason: reason)
            terminalClose = close
            let snapshot = events
            events = []
            return (opened && !failed, snapshot, close)
        }
    }

    let url: String
    let protocols: [String]

    private let sequence: Int
    private let upstream: any RecorderWebSocketConnection
    private let cassette: any CassetteStoreInterface
    private let name: String
    private let metadata: CassetteMetadata?
    private let redactor: Redactor
    private let onPersistFinished: @Sendable ((any Error)?) async -> Void
    private let state = State()
    private let cachedTerminalClose = Mutex<WebSocketClose?>(nil)

    init(
        sequence: Int,
        url: String,
        protocols: [String],
        upstream: any RecorderWebSocketConnection,
        cassette: any CassetteStoreInterface,
        name: String,
        metadata: CassetteMetadata?,
        redactor: Redactor,
        onPersistFinished: @escaping @Sendable ((any Error)?) async -> Void
    ) {
        self.sequence = sequence
        self.url = url
        self.protocols = protocols
        self.upstream = upstream
        self.cassette = cassette
        self.name = name
        self.metadata = metadata
        self.redactor = redactor
        self.onPersistFinished = onPersistFinished
    }

    var readyState: WebSocketReadyState {
        upstream.readyState
    }

    var terminalClose: WebSocketClose? {
        cachedTerminalClose.withLock { $0 } ?? upstream.terminalClose
    }

    func open() async throws {
        do {
            try await upstream.open()
            await state.markOpened()
        } catch {
            await state.markFailed()
            throw error
        }
    }

    func send(_ frame: WebSocketFrame) async throws {
        do {
            try await upstream.send(frame)
            let event = redactEvent(encodeEvent(direction: .client, frame: frame), redactor: redactor)
            await state.append(event)
        } catch {
            await state.markFailed()
            throw error
        }
    }

    func receive() async throws -> WebSocketFrame? {
        do {
            guard let frame = try await upstream.receive() else {
                let closeInfo = upstream.terminalClose ?? WebSocketClose(code: 1000, reason: "")
                try await finalizeAndPersist(code: closeInfo.code, reason: closeInfo.reason)
                return nil
            }
            let event = redactEvent(encodeEvent(direction: .server, frame: frame), redactor: redactor)
            await state.append(event)
            return frame
        } catch let closeError as WebSocketCloseError {
            try await finalizeAndPersist(code: closeError.code, reason: closeError.reason)
            throw closeError
        } catch {
            await state.markFailed()
            throw error
        }
    }

    func close(code: Int, reason: String) async throws {
        try await upstream.close(code: code, reason: reason)
        let closeInfo = upstream.terminalClose ?? WebSocketClose(code: code, reason: reason)
        try await finalizeAndPersist(code: closeInfo.code, reason: closeInfo.reason)
    }

    private func finalizeAndPersist(code: Int, reason: String) async throws {
        let outcome = await state.finishClose(code: code, reason: reason)
        cachedTerminalClose.withLock { $0 = outcome.close }
        guard outcome.shouldPersist else {
            await onPersistFinished(nil)
            return
        }
        let redactedReq = redactor.request(RequestSnapshot(method: "WEBSOCKET", url: url, headers: [:], body: ""))
        let interaction = WebSocketInteraction(
            connection: WebSocketConnection(
                sequence: sequence,
                url: redactedReq.url,
                protocols: protocols,
                close: outcome.close
            ),
            events: outcome.events
        )
        do {
            try await cassette.append(name, interaction: .websocket(interaction), metadata: metadata)
            await onPersistFinished(nil)
        } catch {
            await onPersistFinished(error)
            throw error
        }
    }
}

private final class ReplayWebSocketConnection: RecorderWebSocketConnection, Sendable {
    private actor State {
        var readyState: WebSocketReadyState = .connecting
        var interaction: WebSocketInteraction?
        var position: Int = 0
        var finished: Bool = false
        var closeRequested: Bool = false
        var terminalClose: WebSocketClose?
        var nextWaiterID: Int = 0
        var waiters: [Int: CheckedContinuation<Void, Never>] = [:]

        func notifyWaiters() {
            let pending = waiters
            waiters.removeAll()
            for waiter in pending.values {
                waiter.resume()
            }
        }

        func cancelWaiter(_ id: Int) {
            if let waiter = waiters.removeValue(forKey: id) {
                waiter.resume()
            }
        }

        func allocateWaiterID() -> Int {
            let id = nextWaiterID
            nextWaiterID += 1
            return id
        }

        func registerWaiter(id: Int, continuation: CheckedContinuation<Void, Never>) {
            if finished || closeRequested || Task.isCancelled {
                continuation.resume()
            } else {
                waiters[id] = continuation
            }
        }

        func setOpened(_ interaction: WebSocketInteraction) throws {
            if closeRequested {
                readyState = .closed
                finished = true
                notifyWaiters()
                throw WebSocketRecorderError("WebSocket closed before it opened")
            }
            self.interaction = interaction
            self.readyState = .open
        }

        func sendClientFrame(
            _ frame: WebSocketFrame,
            redactor: Redactor,
            environment: any EnvironmentProviding
        ) throws {
            guard let interaction, readyState == .open, !closeRequested else {
                throw WebSocketRecorderError("WebSocket is not open")
            }
            let actual = redactEvent(encodeEvent(direction: .client, frame: frame), redactor: redactor)
            let expected = position < interaction.events.count ? interaction.events[position] : nil
            try assertEvent(
                actual: actual,
                expected: expected,
                index: position,
                asJson: true,
                environment: environment
            )
            position += 1
            notifyWaiters()
        }

        func nextServerFrame() async throws -> WebSocketFrame? {
            while true {
                guard let interaction else {
                    throw WebSocketRecorderError("WebSocket is not open")
                }
                if position < interaction.events.count {
                    let next = interaction.events[position]
                    if next.direction == .server {
                        position += 1
                        return try decodeEvent(next)
                    }
                    if finished || closeRequested {
                        return nil
                    }
                    try Task.checkCancellation()
                    let waiterID = allocateWaiterID()
                    await withTaskCancellationHandler {
                        await withCheckedContinuation { continuation in
                            registerWaiter(id: waiterID, continuation: continuation)
                        }
                    } onCancel: {
                        Task { await self.cancelWaiter(waiterID) }
                    }
                } else {
                    finished = true
                    readyState = .closed
                    terminalClose = interaction.connection?.close ?? WebSocketClose(code: 1000, reason: "")
                    return nil
                }
            }
        }

        func closeConnection() throws -> WebSocketClose {
            if finished, let terminalClose {
                return terminalClose
            }
            closeRequested = true
            readyState = .closing
            defer { notifyWaiters() }
            if let interaction {
                if position != interaction.events.count {
                    finished = true
                    readyState = .closed
                    throw WebSocketRecorderError(
                        "WebSocket closed with unconsumed events: used \(position) of \(interaction.events.count)"
                    )
                }
                let close = interaction.connection?.close ?? WebSocketClose(code: 1000, reason: "")
                terminalClose = close
                finished = true
                readyState = .closed
                return close
            }
            let close = WebSocketClose(code: 1000, reason: "")
            terminalClose = close
            finished = true
            readyState = .closed
            return close
        }
    }

    let url: String
    let protocols: [String]

    private let replay: ReplayState<WebSocketInteraction>
    private let redactor: Redactor
    private let environment: any EnvironmentProviding
    private let state = State()
    private let cachedReadyState = Mutex<WebSocketReadyState>(.connecting)
    private let cachedTerminalClose = Mutex<WebSocketClose?>(nil)

    init(
        url: String,
        protocols: [String],
        replay: ReplayState<WebSocketInteraction>,
        redactor: Redactor,
        environment: any EnvironmentProviding
    ) {
        self.url = url
        self.protocols = protocols
        self.replay = replay
        self.redactor = redactor
        self.environment = environment
    }

    var readyState: WebSocketReadyState {
        cachedReadyState.withLock { $0 }
    }

    var terminalClose: WebSocketClose? {
        cachedTerminalClose.withLock { $0 }
    }

    func open() async throws {
        let redactedReq = redactor.request(RequestSnapshot(method: "WEBSOCKET", url: url, headers: [:], body: ""))
        let requestedProtocols = self.protocols
        let env = self.environment

        do {
            let claimed = try await replay.claim { recorded, index, _ in
                guard let recorded else {
                    throw WebSocketRecorderError("Missing recorded WebSocket connection \(index + 1)")
                }
                guard let connection = recorded.connection else {
                    throw WebSocketRecorderError("WebSocket interaction \(index + 1) has no connection metadata")
                }
                if connection.url != redactedReq.url {
                    let exp = safeText(connection.url, environment: env)
                    let rec = safeText(redactedReq.url, environment: env)
                    throw WebSocketRecorderError("WebSocket connection \(index + 1): expected URL \(exp), received \(rec)")
                }
                if connection.protocols != requestedProtocols {
                    let exp = safeText(connection.protocols, environment: env)
                    let rec = safeText(requestedProtocols, environment: env)
                    throw WebSocketRecorderError("WebSocket connection \(index + 1): expected protocols \(exp), received \(rec)")
                }
            }
            try await state.setOpened(claimed.interaction)
            cachedReadyState.withLock { $0 = .open }
        } catch {
            cachedReadyState.withLock { $0 = .closed }
            throw error
        }
    }

    func send(_ frame: WebSocketFrame) async throws {
        try await state.sendClientFrame(frame, redactor: redactor, environment: environment)
    }

    func receive() async throws -> WebSocketFrame? {
        let frame = try await state.nextServerFrame()
        if frame == nil {
            let close = await state.terminalClose
            cachedTerminalClose.withLock { $0 = close }
            cachedReadyState.withLock { $0 = .closed }
        }
        return frame
    }

    func close(code: Int, reason: String) async throws {
        let close = try await state.closeConnection()
        cachedTerminalClose.withLock { $0 = close }
        cachedReadyState.withLock { $0 = .closed }
    }
}

/// Constructor-level WebSocket recorder & replayer mirroring `layerWebSocketConstructor`.
public final class RecordingWebSocketConstructor: Sendable {
    private actor RuntimeState {
        private let cassette: any CassetteStoreInterface
        private let name: String
        private let environment: any EnvironmentProviding

        private var resolveTask: Task<RecordReplayMode, Never>?
        private var replayState: ReplayState<WebSocketInteraction>?
        private var nextSequence: Int = 0
        private var openConnections: [Int: RecordingWebSocketConnectionProxy] = [:]
        private var errors: [any Error] = []

        init(
            cassette: any CassetteStoreInterface,
            name: String,
            environment: any EnvironmentProviding
        ) {
            self.cassette = cassette
            self.name = name
            self.environment = environment
        }

        func effectiveMode() async -> RecordReplayMode {
            let task: Task<RecordReplayMode, Never>
            if let existing = resolveTask {
                task = existing
            } else {
                let cassetteRef = self.cassette
                let cassetteName = self.name
                let envRef = self.environment
                let created = Task<RecordReplayMode, Never> {
                    await resolveAutoMode(cassette: cassetteRef, name: cassetteName, environment: envRef)
                }
                resolveTask = created
                task = created
            }
            let mode = await task.value
            if mode == .replay && replayState == nil {
                replayState = makeReplayState(
                    cassette: cassette,
                    name: name,
                    project: constructorWebSocketInteractions
                )
            }
            return mode
        }

        func allocateSequence() -> Int {
            let seq = nextSequence
            nextSequence += 1
            return seq
        }

        func registerOpen(_ seq: Int, connection: RecordingWebSocketConnectionProxy) {
            openConnections[seq] = connection
        }

        func markFinished(_ seq: Int, error: (any Error)?) {
            openConnections.removeValue(forKey: seq)
            if let error {
                errors.append(error)
            }
        }

        func drainOpenConnections() -> [RecordingWebSocketConnectionProxy] {
            let all = Array(openConnections.values)
            openConnections.removeAll()
            return all
        }

        func takeFirstError() -> (any Error)? {
            errors.first
        }

        func currentReplayState() async -> ReplayState<WebSocketInteraction> {
            _ = await effectiveMode()
            if let replayState {
                return replayState
            }
            let state = makeReplayState(
                cassette: cassette,
                name: name,
                project: constructorWebSocketInteractions
            )
            replayState = state
            return state
        }
    }

    public let name: String
    public let options: SocketRecorderOptions

    private let upstream: WebSocketTransportConstructor
    private let cassette: any CassetteStoreInterface
    private let redactor: Redactor
    private let environment: any EnvironmentProviding
    private let runtime: RuntimeState

    public init(
        name: String,
        upstream: @escaping WebSocketTransportConstructor,
        cassette: any CassetteStoreInterface,
        options: SocketRecorderOptions = SocketRecorderOptions(),
        environment: any EnvironmentProviding = SystemEnvironment.shared
    ) {
        self.name = name
        self.options = options
        self.upstream = upstream
        self.cassette = cassette
        self.redactor = Redactor.make(options.redact ?? RedactOptions())
        self.environment = environment
        self.runtime = RuntimeState(cassette: cassette, name: name, environment: environment)
    }

    public func resolvedMode() async -> RecordReplayMode {
        await runtime.effectiveMode()
    }

    /// Creates a new recorded or replayed WebSocket connection for `url` and `protocols`.
    public func connect(url: String, protocols: [String] = []) async throws -> any RecorderWebSocketConnection {
        let mode = await runtime.effectiveMode()
        if mode == .replay {
            let replay = await runtime.currentReplayState()
            return ReplayWebSocketConnection(
                url: url,
                protocols: protocols,
                replay: replay,
                redactor: redactor,
                environment: environment
            )
        }
        let sequence = await runtime.allocateSequence()
        let live = try await upstream(url, protocols)
        let runtimeRef = self.runtime
        let proxy = RecordingWebSocketConnectionProxy(
            sequence: sequence,
            url: url,
            protocols: protocols,
            upstream: live,
            cassette: cassette,
            name: name,
            metadata: options.metadata,
            redactor: redactor,
            onPersistFinished: { error in
                await runtimeRef.markFinished(sequence, error: error)
            }
        )
        await runtime.registerOpen(sequence, connection: proxy)
        return proxy
    }

    /// Finalizes the constructor recorder/replayer scope: closes open live connections in record mode,
    /// or verifies all recorded connections were consumed in replay mode.
    public func finish() async throws {
        let mode = await runtime.effectiveMode()
        if mode == .replay {
            let replay = await runtime.currentReplayState()
            try await replay.verifyAllConsumed()
            return
        }
        let openList = await runtime.drainOpenConnections()
        for conn in openList where conn.readyState != .closing && conn.readyState != .closed {
            try await conn.close(code: 1000, reason: "")
        }
        if let firstError = await runtime.takeFirstError() {
            throw firstError
        }
    }

    /// Runs `body` within a constructor scope and calls `finish()` on normal exit.
    public func withScope<T: Sendable>(
        _ body: (RecordingWebSocketConstructor) async throws -> T
    ) async throws -> T {
        let value = try await body(self)
        try await finish()
        return value
    }
}

// MARK: - WebSocket Recorder Layer Factories

/// Factory namespace mirroring `packages/http-recorder/src/websocket/recorder.ts`.
public enum WebSocketRecorder {
    /// Decorates a lower-level `RecorderSocket` with auto record/replay and canonical JSON client comparison.
    // parity: http-recorder/src/websocket/recorder.ts#layerSocket [status=implemented hash=3d6d20fd3a1d]
    public static func layerSocket(
        _ name: String,
        options: SocketRecorderOptions = SocketRecorderOptions(),
        upstream: any RecorderSocket,
        cassette: (any CassetteStoreInterface)? = nil,
        fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
        environment: any EnvironmentProviding = SystemEnvironment.shared
    ) -> RecordingWebSocket {
        let store = cassette ?? CassetteStoreService.fileSystem(
            directory: options.directory,
            fileSystem: fileSystem,
            environment: environment
        )
        return RecordingWebSocket(
            name: name,
            upstream: upstream,
            cassette: store,
            options: options,
            mode: .auto,
            compareClientMessagesAsJson: true,
            environment: environment
        )
    }

    /// Decorates a lower-level `RecorderSocket` with an explicit `"record"` or `"replay"` mode.
    // parity: http-recorder/src/websocket/recorder.ts#layerSocketWithMode [status=implemented hash=1fd8bb42841b]
    public static func layerSocketWithMode(
        _ name: String,
        mode: RecordReplayMode,
        options: SocketRecorderOptions = SocketRecorderOptions(),
        compareClientMessagesAsJson: Bool = false,
        upstream: any RecorderSocket,
        cassette: (any CassetteStoreInterface)? = nil,
        fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
        environment: any EnvironmentProviding = SystemEnvironment.shared
    ) -> RecordingWebSocket {
        let store = cassette ?? CassetteStoreService.fileSystem(
            directory: options.directory,
            fileSystem: fileSystem,
            environment: environment
        )
        return RecordingWebSocket(
            name: name,
            upstream: upstream,
            cassette: store,
            options: options,
            mode: mode,
            compareClientMessagesAsJson: compareClientMessagesAsJson,
            environment: environment
        )
    }

    /// Decorates a dynamic WebSocket constructor with auto record/replay of URL, protocols, frames, and close metadata.
    // parity: http-recorder/src/websocket/recorder.ts#layerWebSocketConstructor [status=implemented hash=0765cd106c84]
    public static func layerWebSocketConstructor(
        _ name: String,
        options: SocketRecorderOptions = SocketRecorderOptions(),
        upstream: @escaping WebSocketTransportConstructor,
        cassette: (any CassetteStoreInterface)? = nil,
        fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
        environment: any EnvironmentProviding = SystemEnvironment.shared
    ) -> RecordingWebSocketConstructor {
        let store = cassette ?? CassetteStoreService.fileSystem(
            directory: options.directory,
            fileSystem: fileSystem,
            environment: environment
        )
        return RecordingWebSocketConstructor(
            name: name,
            upstream: upstream,
            cassette: store,
            options: options,
            environment: environment
        )
    }
}
