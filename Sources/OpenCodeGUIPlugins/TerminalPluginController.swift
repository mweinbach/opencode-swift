import Foundation
import OpenCodeClient
import OpenCodeSchema
import OpenCodeUtil

// MARK: - Shared Terminal Types (`terminal/connection-machine.ts`)

public struct TerminalSize: Equatable, Hashable, Sendable, Codable {
    public let cols: Int
    public let rows: Int

    public init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
    }
}

public enum TerminalFailure: String, Equatable, Hashable, Sendable, Codable {
    case disconnected
    case failed
    case outdated
}

public enum TerminalConnectionRole: String, Equatable, Hashable, Sendable, Codable {
    case controller
    case observer
}

// MARK: - Terminal Connection Machine (`terminal/connection-machine.ts`)

public enum TerminalConnectionMachine: GUIStateMachine {
    public enum LivePane: Equatable, Sendable {
        case unsized(wantsControl: Bool, pendingInput: [[UInt8]])
        case sized(size: TerminalSize)
    }

    public enum State: Equatable, Sendable {
        case restoring(
            attachmentID: String,
            desired: TerminalSize?,
            wantsControl: Bool,
            pendingInput: [[UInt8]]
        )
        case replaying(
            attachmentID: String,
            role: TerminalConnectionRole,
            replayComplete: Bool,
            desired: TerminalSize?,
            wantsControl: Bool,
            pendingInput: [[UInt8]]
        )
        case live(attachmentID: String, role: TerminalConnectionRole, pane: LivePane)
        case exited
        case failed(failure: TerminalFailure)
        case disposed
    }

    public enum Event: Equatable, Sendable {
        case snapshotRestored(size: TerminalSize, checkpoint: String)
        case socketMessage(text: String)
        case replayDrained
        case input(data: [UInt8])
        case interacted
        case sizeChanged(size: TerminalSize)
        case socketClosed
        case socketErrored
        case disposed
    }

    public enum Effect: Equatable, Sendable {
        case queueResize(size: TerminalSize, checkpoint: String?, reset: Bool)
        case queueReplayEnd
        case send(frame: [UInt8])
        case fail(failure: TerminalFailure)
        case clearWriter
    }

    public static func createState(attachmentID: String) -> State {
        .restoring(attachmentID: attachmentID, desired: nil, wantsControl: false, pendingInput: [])
    }

    public static func canAcceptOutput(_ state: State) -> Bool {
        switch state {
        case .failed, .disposed: return false
        default: return true
        }
    }

    public static func reduce(state: State, event: Event) -> GUIStateTransition<State, Effect> {
        if case .disposed = state { return GUIStateTransition(state: state) }

        switch event {
        case .disposed:
            return GUIStateTransition(state: .disposed, effects: [.clearWriter])

        case .socketMessage(let text):
            guard let message = decodePersistentPtyMessage(text) else {
                return GUIStateTransition(state: state)
            }
            return receive(state: state, message: message)

        case .snapshotRestored(let size, let checkpoint):
            if case .restoring = state {
                return GUIStateTransition(
                    state: state,
                    effects: [.queueResize(size: size, checkpoint: checkpoint, reset: false)]
                )
            }
            return GUIStateTransition(state: state)

        case .replayDrained:
            return handleDrained(state)

        case .input(let data):
            return handleInput(state: state, data: data)

        case .interacted:
            return handleInteracted(state)

        case .sizeChanged(let size):
            return handleSized(state: state, size: size)

        case .socketClosed, .socketErrored:
            switch state {
            case .exited, .failed, .disposed:
                return GUIStateTransition(state: state)
            default:
                let failure: TerminalFailure = (event == .socketClosed) ? .disconnected : .failed
                return GUIStateTransition(state: .failed(failure: failure), effects: [.fail(failure: failure)])
            }
        }
    }

    private static func receive(state: State, message: PersistentPtyMessage) -> GUIStateTransition<State, Effect> {
        switch message {
        case .attached(let inputProtocol, let info, let role):
            guard case .restoring(let attachmentID, let desired, let wantsControl, let pendingInput) = state else {
                return GUIStateTransition(state: state)
            }
            if inputProtocol != 1 {
                return GUIStateTransition(state: .failed(failure: .outdated), effects: [.fail(failure: .outdated)])
            }
            let mappedRole: TerminalConnectionRole = (role == .controller) ? .controller : .observer
            let size = TerminalSize(cols: info.size.cols.rawValue, rows: info.size.rows.rawValue)
            return GUIStateTransition(
                state: .replaying(
                    attachmentID: attachmentID,
                    role: mappedRole,
                    replayComplete: false,
                    desired: desired,
                    wantsControl: wantsControl,
                    pendingInput: pendingInput
                ),
                effects: [.queueResize(size: size, checkpoint: nil, reset: false)]
            )

        case .resized(let cols, let rows, let checkpoint):
            guard isReplayingOrLive(state) else { return GUIStateTransition(state: state) }
            return GUIStateTransition(
                state: state,
                effects: [.queueResize(size: TerminalSize(cols: cols, rows: rows), checkpoint: checkpoint, reset: true)]
            )

        case .replayComplete:
            guard case .replaying(let attachmentID, let role, false, let desired, let wantsControl, let pendingInput) = state else {
                return GUIStateTransition(state: state)
            }
            return GUIStateTransition(
                state: .replaying(
                    attachmentID: attachmentID,
                    role: role,
                    replayComplete: true,
                    desired: desired,
                    wantsControl: wantsControl,
                    pendingInput: pendingInput
                ),
                effects: [.queueReplayEnd]
            )

        case .exited:
            guard isReplayingOrLive(state) else { return GUIStateTransition(state: state) }
            return GUIStateTransition(state: .exited)

        case .controllerChanged(let targetAttachmentID):
            switch state {
            case .replaying(let attachmentID, let role, let replayComplete, let desired, let wantsControl, let pendingInput):
                let nextRole: TerminalConnectionRole = (targetAttachmentID == attachmentID) ? .controller : .observer
                if nextRole == role { return GUIStateTransition(state: state) }
                return GUIStateTransition(
                    state: .replaying(
                        attachmentID: attachmentID,
                        role: nextRole,
                        replayComplete: replayComplete,
                        desired: desired,
                        wantsControl: wantsControl,
                        pendingInput: pendingInput
                    )
                )
            case .live(let attachmentID, let role, let pane):
                let nextRole: TerminalConnectionRole = (targetAttachmentID == attachmentID) ? .controller : .observer
                if nextRole == role { return GUIStateTransition(state: state) }
                let effects: [Effect]
                if nextRole == .controller, case .sized(let size) = pane {
                    effects = [sendFrame(size: size)]
                } else {
                    effects = []
                }
                return GUIStateTransition(state: .live(attachmentID: attachmentID, role: nextRole, pane: pane), effects: effects)
            default:
                return GUIStateTransition(state: state)
            }

        case .titleChanged, .foregroundProcessChanged:
            return GUIStateTransition(state: state)
        }
    }

    private static func handleDrained(_ state: State) -> GUIStateTransition<State, Effect> {
        guard case .replaying(let attachmentID, let role, true, let desired, let wantsControl, let pendingInput) = state else {
            return GUIStateTransition(state: state)
        }
        guard let desired else {
            return GUIStateTransition(
                state: .live(
                    attachmentID: attachmentID,
                    role: role,
                    pane: .unsized(wantsControl: wantsControl, pendingInput: pendingInput)
                )
            )
        }
        return GUIStateTransition(
            state: .live(attachmentID: attachmentID, role: role, pane: .sized(size: desired)),
            effects: flush(size: desired, role: role, wantsControl: wantsControl, pendingInput: pendingInput)
        )
    }

    private static func handleInput(state: State, data: [UInt8]) -> GUIStateTransition<State, Effect> {
        guard !data.isEmpty else { return GUIStateTransition(state: state) }
        switch state {
        case .restoring(let id, let desired, let wantsControl, let pending):
            return GUIStateTransition(
                state: .restoring(attachmentID: id, desired: desired, wantsControl: wantsControl, pendingInput: pending + [data])
            )
        case .replaying(let id, let role, let complete, let desired, let wantsControl, let pending):
            return GUIStateTransition(
                state: .replaying(
                    attachmentID: id,
                    role: role,
                    replayComplete: complete,
                    desired: desired,
                    wantsControl: wantsControl,
                    pendingInput: pending + [data]
                )
            )
        case .live(let id, let role, let pane):
            switch pane {
            case .sized(let size):
                return GUIStateTransition(state: state, effects: [sendFrame(size: size, data: data)])
            case .unsized(let wantsControl, let pending):
                return GUIStateTransition(
                    state: .live(attachmentID: id, role: role, pane: .unsized(wantsControl: wantsControl, pendingInput: pending + [data]))
                )
            }
        default:
            return GUIStateTransition(state: state)
        }
    }

    private static func handleInteracted(_ state: State) -> GUIStateTransition<State, Effect> {
        switch state {
        case .restoring(let id, let desired, let wantsControl, let pending):
            if wantsControl { return GUIStateTransition(state: state) }
            return GUIStateTransition(
                state: .restoring(attachmentID: id, desired: desired, wantsControl: true, pendingInput: pending)
            )
        case .replaying(let id, let role, let complete, let desired, let wantsControl, let pending):
            if wantsControl { return GUIStateTransition(state: state) }
            return GUIStateTransition(
                state: .replaying(
                    attachmentID: id,
                    role: role,
                    replayComplete: complete,
                    desired: desired,
                    wantsControl: true,
                    pendingInput: pending
                )
            )
        case .live(let id, let role, let pane):
            switch pane {
            case .sized(let size):
                return GUIStateTransition(state: state, effects: [sendFrame(size: size)])
            case .unsized(let wantsControl, let pending):
                if wantsControl { return GUIStateTransition(state: state) }
                return GUIStateTransition(
                    state: .live(attachmentID: id, role: role, pane: .unsized(wantsControl: true, pendingInput: pending))
                )
            }
        default:
            return GUIStateTransition(state: state)
        }
    }

    private static func handleSized(state: State, size: TerminalSize) -> GUIStateTransition<State, Effect> {
        guard size.cols > 0 && size.rows > 0 else { return GUIStateTransition(state: state) }
        switch state {
        case .restoring(let id, let desired, let wantsControl, let pending):
            if desired == size { return GUIStateTransition(state: state) }
            return GUIStateTransition(
                state: .restoring(attachmentID: id, desired: size, wantsControl: wantsControl, pendingInput: pending)
            )
        case .replaying(let id, let role, let complete, let desired, let wantsControl, let pending):
            if desired == size { return GUIStateTransition(state: state) }
            return GUIStateTransition(
                state: .replaying(
                    attachmentID: id,
                    role: role,
                    replayComplete: complete,
                    desired: size,
                    wantsControl: wantsControl,
                    pendingInput: pending
                )
            )
        case .live(let id, let role, let pane):
            switch pane {
            case .unsized(let wantsControl, let pending):
                return GUIStateTransition(
                    state: .live(attachmentID: id, role: role, pane: .sized(size: size)),
                    effects: flush(size: size, role: role, wantsControl: wantsControl, pendingInput: pending)
                )
            case .sized(let currentSize):
                if currentSize == size { return GUIStateTransition(state: state) }
                let effects: [Effect] = (role == .controller) ? [sendFrame(size: size)] : []
                return GUIStateTransition(state: .live(attachmentID: id, role: role, pane: .sized(size: size)), effects: effects)
            }
        default:
            return GUIStateTransition(state: state)
        }
    }

    private static func flush(
        size: TerminalSize,
        role: TerminalConnectionRole,
        wantsControl: Bool,
        pendingInput: [[UInt8]]
    ) -> [Effect] {
        if !pendingInput.isEmpty {
            return pendingInput.map { sendFrame(size: size, data: $0) }
        }
        return (role == .controller || wantsControl) ? [sendFrame(size: size)] : []
    }

    private static func sendFrame(size: TerminalSize, data: [UInt8]? = nil) -> Effect {
        .send(frame: persistentPtyFrame(cols: size.cols, rows: size.rows, data: data))
    }

    private static func isReplayingOrLive(_ state: State) -> Bool {
        switch state {
        case .replaying, .live: return true
        default: return false
        }
    }
}

// MARK: - Ordered Coalescing Terminal Writer (`terminal/writer.ts` & `terminal/connection.ts`)

/// Coalesces consecutive byte writes while preserving strict ordering relative to step callbacks (resizes, replay end).
public final class TerminalWriter {
    public enum Item {
        case data([UInt8])
        case step(() -> Void)
    }

    private enum Status {
        case idle
        case writing
        case cleared
    }

    private var queue: [Item] = []
    private var status: Status = .idle
    private let writeHandler: ([UInt8], @escaping () -> Void) -> Void

    public init(write: @escaping ([UInt8], @escaping () -> Void) -> Void) {
        self.writeHandler = write
    }

    public func pushData(_ data: [UInt8]) {
        guard status != .cleared, !data.isEmpty else { return }
        queue.append(.data(data))
        drain()
    }

    public func pushStep(_ step: @escaping () -> Void) {
        guard status != .cleared else { return }
        queue.append(.step(step))
        drain()
    }

    public func clear() {
        status = .cleared
        queue.removeAll()
    }

    private func drain() {
        while status == .idle, !queue.isEmpty {
            let first = queue.removeFirst()
            switch first {
            case .step(let action):
                action()
            case .data(let bytes):
                let coalesced = coalesceData(startingWith: bytes)
                status = .writing
                var finishedSynchronously = false
                let done: () -> Void = { [weak self] in
                    guard let self, self.status == .writing else { return }
                    self.status = .idle
                    finishedSynchronously = true
                    self.drain()
                }
                writeHandler(coalesced, done)
                if !finishedSynchronously && status == .writing {
                    return
                }
            }
        }
    }

    private func coalesceData(startingWith first: [UInt8]) -> [UInt8] {
        var count = 0
        var total = first.count
        while count < queue.count {
            if case .data(let chunk) = queue[count] {
                total += chunk.count
                count += 1
            } else {
                break
            }
        }
        if count == 0 { return first }
        var combined: [UInt8] = []
        combined.reserveCapacity(total)
        combined.append(contentsOf: first)
        for _ in 0..<count {
            if case .data(let chunk) = queue.removeFirst() {
                combined.append(contentsOf: chunk)
            }
        }
        return combined
    }
}

/// Non-DOM connection driver coordinating `TerminalConnectionMachine`, `TerminalWriter`, and write-echo suppression.
public final class TerminalConnectionDriver {
    public private(set) var state: TerminalConnectionMachine.State
    private var writing = false
    private var writer: TerminalWriter!
    private let onResize: (TerminalSize) -> Void
    private let onSend: ([UInt8]) -> Void
    private let onFail: (TerminalFailure) -> Void

    public init(
        attachmentID: String,
        write: @escaping ([UInt8], @escaping () -> Void) -> Void,
        resize: @escaping (TerminalSize) -> Void,
        send: @escaping ([UInt8]) -> Void,
        fail: @escaping (TerminalFailure) -> Void
    ) {
        self.state = TerminalConnectionMachine.createState(attachmentID: attachmentID)
        self.onResize = resize
        self.onSend = send
        self.onFail = fail
        self.writer = TerminalWriter { [weak self] data, done in
            guard let self else { return }
            self.writing = true
            defer { self.writing = false }
            write(data, done)
        }
    }

    public func restore(size: TerminalSize, checkpoint: String) {
        dispatch(.snapshotRestored(size: size, checkpoint: checkpoint))
    }

    public func output(_ data: [UInt8]) {
        if TerminalConnectionMachine.canAcceptOutput(state) {
            writer.pushData(data)
        }
    }

    public func message(_ text: String) {
        dispatch(.socketMessage(text: text))
    }

    public func input(_ text: String) {
        guard !writing else { return }
        dispatch(.input(data: Array(text.utf8)))
    }

    public func interact() {
        dispatch(.interacted)
    }

    public func resize(_ size: TerminalSize) {
        dispatch(.sizeChanged(size: size))
    }

    public func close() {
        dispatch(.socketClosed)
    }

    public func error() {
        dispatch(.socketErrored)
    }

    public func dispose() {
        dispatch(.disposed)
    }

    private func dispatch(_ event: TerminalConnectionMachine.Event) {
        let transition = TerminalConnectionMachine.reduce(state: state, event: event)
        state = transition.state
        for effect in transition.effects {
            perform(effect)
        }
    }

    private func perform(_ effect: TerminalConnectionMachine.Effect) {
        switch effect {
        case .queueResize(let size, let checkpoint, let reset):
            writer.pushStep { [onResize] in onResize(size) }
            if let checkpoint {
                var bytes: [UInt8] = reset ? [0x1B, 0x63] : [] // ESC c (RIS)
                if let decoded = try? base64ToBytes(checkpoint) {
                    bytes.append(contentsOf: decoded)
                }
                writer.pushData(bytes)
            }
        case .queueReplayEnd:
            writer.pushStep { [weak self] in
                self?.dispatch(.replayDrained)
            }
        case .send(let frame):
            onSend(frame)
        case .fail(let failure):
            onFail(failure)
        case .clearWriter:
            writer.clear()
        }
    }
}

// MARK: - Terminal Focus Machine (`terminal/focus-machine.ts` & `terminal/focus.ts`)

public protocol TerminalFocusHost: Sendable {
    @discardableResult
    func focusTerminal(id: String) async -> Bool
}

public enum TerminalFocusMachine {
    public enum FocusDestination: String, Equatable, Hashable, Sendable {
        case panel
        case field
        case outside
    }

    public enum State: Equatable, Sendable {
        case idle(request: Int)
        case pending(request: Int, session: String, overlay: Bool)
        case target(request: Int, session: String, id: String, overlay: Bool)

        public var request: Int {
            switch self {
            case .idle(let r), .pending(let r, _, _), .target(let r, _, _, _):
                return r
            }
        }
    }

    public enum Event: Equatable, Sendable {
        case requestPending(session: String, overlay: Bool)
        case requestTarget(session: String, id: String, overlay: Bool)
        case pendingResolved(request: Int, id: String)
        case pendingFailed(request: Int)
        case consumed(session: String, id: String)
        case focusMoved(into: FocusDestination, leavingOverlay: Bool)
        case pointerOutside
        case cancelled(session: String?)
    }

    public static let initialState: State = .idle(request: 0)

    public static func reduce(state: State, event: Event) -> State {
        switch event {
        case .requestPending(let session, let overlay):
            if case .pending(let request, let currentSession, let currentOverlay) = state, currentSession == session {
                return (overlay && !currentOverlay)
                    ? .pending(request: request, session: session, overlay: true)
                    : state
            }
            return .pending(request: state.request + 1, session: session, overlay: overlay)

        case .requestTarget(let session, let id, let overlay):
            if case .target(let request, let currentSession, let currentID, let currentOverlay) = state,
               currentSession == session, currentID == id
            {
                return (overlay && !currentOverlay)
                    ? .target(request: request, session: session, id: id, overlay: true)
                    : state
            }
            return .target(request: state.request + 1, session: session, id: id, overlay: overlay)

        case .pendingResolved(let request, let id):
            guard case .pending(let currentRequest, let session, let overlay) = state, currentRequest == request else {
                return state
            }
            return .target(request: currentRequest, session: session, id: id, overlay: overlay)

        case .pendingFailed(let request):
            guard case .pending(let currentRequest, _, _) = state, currentRequest == request else {
                return state
            }
            return .idle(request: currentRequest)

        case .consumed(let session, let id):
            guard case .target(let request, let currentSession, let currentID, _) = state,
                  currentSession == session, currentID == id
            else {
                return state
            }
            return .idle(request: request)

        case .focusMoved(let into, let leavingOverlay):
            switch state {
            case .idle:
                return state
            case .pending(let request, let session, let overlay):
                if into == .panel { return state }
                if into == .outside && overlay && leavingOverlay {
                    return .pending(request: request, session: session, overlay: false)
                }
                return .idle(request: request)
            case .target(let request, let session, let id, let overlay):
                if into == .panel { return state }
                if into == .outside && overlay && leavingOverlay {
                    return .target(request: request, session: session, id: id, overlay: false)
                }
                return .idle(request: request)
            }

        case .pointerOutside:
            if case .idle = state { return state }
            return .idle(request: state.request)

        case .cancelled(let session):
            switch state {
            case .idle:
                return state
            case .pending(let request, let currentSession, _),
                 .target(let request, let currentSession, _, _):
                return (session == nil || session == currentSession) ? .idle(request: request) : state
            }
        }
    }

    public static func hasFocusRequest(_ state: State) -> Bool {
        if case .idle = state { return false }
        return true
    }

    public static func isFocusRequested(_ state: State, session: String, id: String) -> Bool {
        if case .target(_, let s, let targetID, _) = state {
            return s == session && targetID == id
        }
        return false
    }

    public static func focusRequestToken(_ state: State, session: String, id: String) -> Int? {
        if case .target(let request, let s, let targetID, _) = state, s == session && targetID == id {
            return request
        }
        return nil
    }
}

// MARK: - Multi-Terminal Session Machine (`terminal/machine.ts`)

public enum TerminalSessionMachine: GUIStateMachine {
    public static let requestTimeoutMs = 15_000

    public enum SessionList: Equatable, Sendable {
        case loading(attempt: Int)
        case ready(connection: Int, items: [PersistentPtySchema.Info])
        case refreshing(connection: Int, items: [PersistentPtySchema.Info], attempt: Int)
        case failed(error: String)
    }

    public enum HeldList: Equatable, Sendable {
        case waiting
        case ready(connection: Int, items: [PersistentPtySchema.Info])
    }

    public struct PendingRename: Equatable, Sendable {
        public let attempt: Int
        public let title: String?

        public init(attempt: Int, title: String?) {
            self.attempt = attempt
            self.title = title
        }
    }

    public struct Mutations: Equatable, Sendable {
        public var creating: Int?
        public var closing: [String: Int]
        public var renames: [String: PendingRename]

        public init(
            creating: Int? = nil,
            closing: [String: Int] = [:],
            renames: [String: PendingRename] = [:]
        ) {
            self.creating = creating
            self.closing = closing
            self.renames = renames
        }

        public var isIdle: Bool {
            creating == nil && closing.isEmpty && renames.isEmpty
        }
    }

    public enum CreateFailure: String, Equatable, Hashable, Sendable {
        case unsupported
        case failed
        case cancelled
    }

    public enum MutationFailureKind: String, Equatable, Hashable, Sendable {
        case unsupported
        case failed
    }

    public enum CreateOutcome: Equatable, Sendable {
        case succeeded(terminal: PersistentPtySchema.Info)
        case failed(kind: CreateFailure, error: String?)
    }

    public enum State: Equatable, Sendable {
        case unknown
        case checking(
            connections: Int,
            attempt: Int,
            issued: Int,
            sessions: [String: HeldList],
            mutations: [String: Mutations]
        )
        case unsupported(connections: Int, issued: Int, sessions: [String])
        case failed(connections: Int, issued: Int, sessions: [String], error: String)
        case supported(
            connections: Int,
            issued: Int,
            sessions: [String: SessionList],
            mutations: [String: Mutations]
        )
    }

    public enum Event: Equatable, Sendable {
        case serverConnected
        case capabilityChecked(attempt: Int, supported: Bool)
        case capabilityFailed(attempt: Int, error: String)
        case sessionLoaded(sessionID: String)
        case sessionRefresh(sessionID: String)
        case sessionRetry(sessionID: String)
        case listLoaded(sessionID: String, attempt: Int, items: [PersistentPtySchema.Info])
        case listUnavailable(sessionID: String, attempt: Int)
        case listFailed(sessionID: String, attempt: Int, error: String)
        case terminalUpdated(sessionID: String, terminal: PersistentPtySchema.Info)
        case createRequested(sessionID: String)
        case createSucceeded(sessionID: String, attempt: Int, terminal: PersistentPtySchema.Info)
        case createFailed(sessionID: String, attempt: Int, kind: MutationFailureKind, error: String)
        case closeRequested(sessionID: String, ptyID: String)
        case closeSucceeded(sessionID: String, ptyID: String, attempt: Int)
        case closeFailed(sessionID: String, ptyID: String, attempt: Int, error: String)
        case renameRequested(sessionID: String, ptyID: String, title: String?)
        case renameSucceeded(sessionID: String, ptyID: String, attempt: Int, terminal: PersistentPtySchema.Info)
        case renameFailed(sessionID: String, ptyID: String, attempt: Int, kind: MutationFailureKind, error: String)
        case sessionsRemoved(sessionIDs: [String])
        case instanceStopped
    }

    public enum Effect: Equatable, Sendable {
        case checkCapability(attempt: Int)
        case loadList(sessionID: String, attempt: Int)
        case createTerminal(sessionID: String, attempt: Int, known: [PersistentPtySchema.Info]?)
        case closeTerminal(sessionID: String, ptyID: String, attempt: Int)
        case renameTerminal(sessionID: String, ptyID: String, title: String?, attempt: Int)
        case abort(attempts: [Int])
        case syncTabs(sessionID: String, items: [PersistentPtySchema.Info])
        case settleCreate(sessionID: String, outcome: CreateOutcome)
        case toastCloseFailed(error: String)
        case toastRenameFailed(kind: MutationFailureKind, error: String)
    }

    public enum View: Equatable, Sendable {
        case loading
        case unsupported
        case failed(error: String)
        case ready(items: [PersistentPtySchema.Info])
    }

    public static let initialState: State = .unknown

    public static func serverAvailable(_ state: State) -> Bool {
        switch state {
        case .unsupported, .failed: return false
        default: return true
        }
    }

    public static func sessionView(_ state: State, sessionID: String) -> View {
        switch state {
        case .unknown:
            return .loading
        case .unsupported:
            return .unsupported
        case .failed(_, _, _, let error):
            return .failed(error: error)
        case .checking(_, _, _, let sessions, let mutations):
            guard case .ready(_, let items) = sessions[sessionID] else { return .loading }
            return .ready(items: applyingRenames(items, mutations: mutations[sessionID]))
        case .supported(_, _, let sessions, let mutations):
            guard let list = sessions[sessionID] else { return .loading }
            switch list {
            case .loading: return .loading
            case .failed(let error): return .failed(error: error)
            case .ready(_, let items), .refreshing(_, let items, _):
                return .ready(items: applyingRenames(items, mutations: mutations[sessionID]))
            }
        }
    }

    public static func sessionCreating(_ state: State, sessionID: String) -> Bool {
        switch state {
        case .checking(_, _, _, _, let mutations), .supported(_, _, _, let mutations):
            return mutations[sessionID]?.creating != nil
        default:
            return false
        }
    }

    public static func sessionConnection(_ state: State, sessionID: String) -> Int {
        switch state {
        case .checking(_, _, _, let sessions, _):
            if case .ready(let connection, _) = sessions[sessionID] { return connection }
            return 0
        case .supported(_, _, let sessions, _):
            switch sessions[sessionID] {
            case .ready(let connection, _), .refreshing(let connection, _, _):
                return connection
            default:
                return 0
            }
        default:
            return 0
        }
    }

    public static func viewItems(_ view: View) -> [PersistentPtySchema.Info] {
        if case .ready(let items) = view { return items }
        return []
    }

    public static func viewTabs(_ view: View, open: [String]) -> [String] {
        func deduplicate(_ list: [String]) -> [String] {
            var seen: Set<String> = []
            var out: [String] = []
            for item in list where seen.insert(item).inserted {
                out.append(item)
            }
            return out
        }
        guard case .ready(let items) = view else {
            return deduplicate(open)
        }
        let liveIDs = items.map(\.id.rawValue)
        let liveSet = Set(liveIDs)
        return deduplicate(open.filter { liveSet.contains($0) } + liveIDs)
    }

    public static func tabHidden(_ view: View) -> Bool {
        switch view {
        case .loading, .unsupported: return true
        case .failed, .ready: return false
        }
    }

    public static func tabTargetable(_ view: View, id: String) -> Bool {
        guard case .ready(let items) = view else { return true }
        return items.contains { $0.id.rawValue == id }
    }

    public static func reduce(state: State, event: Event) -> GUIStateTransition<State, Effect> {
        switch state {
        case .unknown:
            switch event {
            case .serverConnected:
                return GUIStateTransition(
                    state: .checking(connections: 1, attempt: 1, issued: 1, sessions: [:], mutations: [:]),
                    effects: [.checkCapability(attempt: 1)]
                )
            case .sessionLoaded(let sessionID):
                return GUIStateTransition(
                    state: .checking(
                        connections: 1,
                        attempt: 1,
                        issued: 1,
                        sessions: [sessionID: .waiting],
                        mutations: [:]
                    ),
                    effects: [.checkCapability(attempt: 1)]
                )
            case .createRequested(let sessionID):
                return GUIStateTransition(
                    state: state,
                    effects: [.settleCreate(sessionID: sessionID, outcome: .failed(kind: .cancelled, error: nil))]
                )
            default:
                return GUIStateTransition(state: state)
            }

        case .unsupported(let connections, let issued, var sessions):
            switch event {
            case .serverConnected:
                let nextAttempt = issued + 1
                let held = Dictionary(uniqueKeysWithValues: sessions.map { ($0, HeldList.waiting) })
                return GUIStateTransition(
                    state: .checking(connections: connections + 1, attempt: nextAttempt, issued: nextAttempt, sessions: held, mutations: [:]),
                    effects: [.checkCapability(attempt: nextAttempt)]
                )
            case .sessionLoaded(let sessionID) where !sessions.contains(sessionID):
                sessions.append(sessionID)
                return GUIStateTransition(state: .unsupported(connections: connections, issued: issued, sessions: sessions))
            case .sessionsRemoved(let ids):
                let idSet = Set(ids)
                let filtered = sessions.filter { !idSet.contains($0) }
                if filtered.count == sessions.count { return GUIStateTransition(state: state) }
                return GUIStateTransition(state: .unsupported(connections: connections, issued: issued, sessions: filtered))
            case .createRequested(let sessionID):
                return GUIStateTransition(
                    state: state,
                    effects: [.settleCreate(sessionID: sessionID, outcome: .failed(kind: .unsupported, error: nil))]
                )
            default:
                return GUIStateTransition(state: state)
            }

        case .failed(let connections, let issued, var sessions, let error):
            switch event {
            case .serverConnected:
                let nextAttempt = issued + 1
                let held = Dictionary(uniqueKeysWithValues: sessions.map { ($0, HeldList.waiting) })
                return GUIStateTransition(
                    state: .checking(connections: connections + 1, attempt: nextAttempt, issued: nextAttempt, sessions: held, mutations: [:]),
                    effects: [.checkCapability(attempt: nextAttempt)]
                )
            case .sessionRetry:
                let nextAttempt = issued + 1
                let held = Dictionary(uniqueKeysWithValues: sessions.map { ($0, HeldList.waiting) })
                return GUIStateTransition(
                    state: .checking(connections: connections, attempt: nextAttempt, issued: nextAttempt, sessions: held, mutations: [:]),
                    effects: [.checkCapability(attempt: nextAttempt)]
                )
            case .sessionLoaded(let sessionID) where !sessions.contains(sessionID):
                sessions.append(sessionID)
                return GUIStateTransition(state: .failed(connections: connections, issued: issued, sessions: sessions, error: error))
            case .sessionsRemoved(let ids):
                let idSet = Set(ids)
                let filtered = sessions.filter { !idSet.contains($0) }
                if filtered.count == sessions.count { return GUIStateTransition(state: state) }
                return GUIStateTransition(state: .failed(connections: connections, issued: issued, sessions: filtered, error: error))
            case .createRequested(let sessionID):
                return GUIStateTransition(
                    state: state,
                    effects: [.settleCreate(sessionID: sessionID, outcome: .failed(kind: .failed, error: error))]
                )
            default:
                return GUIStateTransition(state: state)
            }

        case .checking, .supported:
            if case .instanceStopped = event {
                return handleStopped(state)
            }
            if case .sessionsRemoved(let ids) = event {
                return handleRemoved(state, ids: ids)
            }
            if let mutated = handleMutation(state, event: event) {
                return mutated
            }
            if case .checking = state {
                return reduceChecking(state, event: event)
            }
            return reduceSupported(state, event: event)
        }
    }

    private static func reduceChecking(_ state: State, event: Event) -> GUIStateTransition<State, Effect> {
        guard case .checking(let connections, let attempt, let issued, var sessions, let mutations) = state else {
            return GUIStateTransition(state: state)
        }
        switch event {
        case .serverConnected:
            let nextAttempt = issued + 1
            return GUIStateTransition(
                state: .checking(
                    connections: connections + 1,
                    attempt: nextAttempt,
                    issued: nextAttempt,
                    sessions: sessions,
                    mutations: mutations
                ),
                effects: [.abort(attempts: [attempt]), .checkCapability(attempt: nextAttempt)]
            )

        case .capabilityChecked(let eventAttempt, let supported) where eventAttempt == attempt:
            if !supported {
                return handleLost(state: state, error: nil)
            }
            let ids = sessions.keys.sorted()
            var nextSessions: [String: SessionList] = [:]
            var effects: [Effect] = []
            var nextIssued = issued
            for id in ids {
                nextIssued += 1
                if case .ready(let conn, let items) = sessions[id] {
                    nextSessions[id] = .refreshing(connection: conn, items: items, attempt: nextIssued)
                } else {
                    nextSessions[id] = .loading(attempt: nextIssued)
                }
                effects.append(.loadList(sessionID: id, attempt: nextIssued))
            }
            return GUIStateTransition(
                state: .supported(connections: connections, issued: nextIssued, sessions: nextSessions, mutations: mutations),
                effects: effects
            )

        case .capabilityFailed(let eventAttempt, let error) where eventAttempt == attempt:
            return handleLost(state: state, error: error)

        case .sessionLoaded(let sessionID) where sessions[sessionID] == nil:
            sessions[sessionID] = .waiting
            return GUIStateTransition(
                state: .checking(connections: connections, attempt: attempt, issued: issued, sessions: sessions, mutations: mutations)
            )

        case .terminalUpdated(let sessionID, let terminal):
            return GUIStateTransition(
                state: updatingItems(state, sessionID: sessionID) { replaceItem($0, with: terminal) }
            )

        default:
            return GUIStateTransition(state: state)
        }
    }

    private static func reduceSupported(_ state: State, event: Event) -> GUIStateTransition<State, Effect> {
        guard case .supported(let connections, let issued, var sessions, let mutations) = state else {
            return GUIStateTransition(state: state)
        }
        switch event {
        case .serverConnected:
            let nextAttempt = issued + 1
            var held: [String: HeldList] = [:]
            var abortIDs: [Int] = []
            for key in sessions.keys.sorted() {
                guard let list = sessions[key] else { continue }
                switch list {
                case .ready(let conn, let items):
                    held[key] = .ready(connection: conn, items: items)
                case .refreshing(let conn, let items, let attempt):
                    held[key] = .ready(connection: conn, items: items)
                    abortIDs.append(attempt)
                case .loading(let attempt):
                    held[key] = .waiting
                    abortIDs.append(attempt)
                case .failed:
                    held[key] = .waiting
                }
            }
            var effects: [Effect] = []
            if !abortIDs.isEmpty { effects.append(.abort(attempts: abortIDs)) }
            effects.append(.checkCapability(attempt: nextAttempt))
            return GUIStateTransition(
                state: .checking(connections: connections + 1, attempt: nextAttempt, issued: nextAttempt, sessions: held, mutations: mutations),
                effects: effects
            )

        case .sessionLoaded(let sessionID):
            return sessions[sessionID] != nil ? GUIStateTransition(state: state) : loadList(state, sessionID: sessionID)

        case .sessionRefresh(let sessionID):
            return sessions[sessionID] != nil ? loadList(state, sessionID: sessionID) : GUIStateTransition(state: state)

        case .sessionRetry(let sessionID):
            if case .failed = sessions[sessionID] {
                return loadList(state, sessionID: sessionID)
            }
            return GUIStateTransition(state: state)

        case .listLoaded(let sessionID, let attempt, let items):
            guard let list = sessions[sessionID], listAttempt(list) == attempt else {
                return GUIStateTransition(state: state)
            }
            sessions[sessionID] = .ready(connection: connections, items: items)
            return GUIStateTransition(
                state: .supported(connections: connections, issued: issued, sessions: sessions, mutations: mutations),
                effects: [.syncTabs(sessionID: sessionID, items: items)]
            )

        case .listUnavailable(let sessionID, let attempt):
            guard let list = sessions[sessionID], listAttempt(list) == attempt else {
                return GUIStateTransition(state: state)
            }
            return handleLost(state: state, error: nil)

        case .listFailed(let sessionID, let attempt, let error):
            guard let list = sessions[sessionID], listAttempt(list) == attempt else {
                return GUIStateTransition(state: state)
            }
            if case .refreshing(let conn, let items, _) = list {
                sessions[sessionID] = .ready(connection: conn, items: items)
            } else {
                sessions[sessionID] = .failed(error: error)
            }
            return GUIStateTransition(
                state: .supported(connections: connections, issued: issued, sessions: sessions, mutations: mutations)
            )

        case .terminalUpdated(let sessionID, let terminal):
            guard let list = sessions[sessionID] else { return GUIStateTransition(state: state) }
            switch list {
            case .ready(let conn, let items) where items.contains(where: { $0.id == terminal.id }):
                sessions[sessionID] = .ready(connection: conn, items: replaceItem(items, with: terminal))
                return GUIStateTransition(
                    state: .supported(connections: connections, issued: issued, sessions: sessions, mutations: mutations)
                )
            case .refreshing(let conn, let items, let attempt) where items.contains(where: { $0.id == terminal.id }):
                sessions[sessionID] = .refreshing(connection: conn, items: replaceItem(items, with: terminal), attempt: attempt)
                return GUIStateTransition(
                    state: .supported(connections: connections, issued: issued, sessions: sessions, mutations: mutations)
                )
            default:
                return loadList(state, sessionID: sessionID)
            }

        default:
            return GUIStateTransition(state: state)
        }
    }

    private static func handleMutation(_ state: State, event: Event) -> GUIStateTransition<State, Effect>? {
        switch event {
        case .createRequested(let sessionID):
            var current = mutationsOf(state, sessionID: sessionID)
            if current.creating != nil { return GUIStateTransition(state: state) }
            let attempt = issuedOf(state) + 1
            current.creating = attempt
            let nextState = settingMutations(settingIssued(state, issued: attempt), sessionID: sessionID, mutations: current)
            return GUIStateTransition(
                state: nextState,
                effects: [.createTerminal(sessionID: sessionID, attempt: attempt, known: knownItems(state, sessionID: sessionID))]
            )

        case .createSucceeded(let sessionID, let attempt, let terminal):
            var current = mutationsOf(state, sessionID: sessionID)
            if current.creating != attempt {
                return refreshIfSupported(state, sessionID: sessionID)
            }
            current.creating = nil
            let updatedState = updatingItems(
                settingMutations(state, sessionID: sessionID, mutations: current),
                sessionID: sessionID
            ) { items in
                items.contains(where: { $0.id == terminal.id }) ? items : items + [terminal]
            }
            let refreshed = refreshIfSupported(updatedState, sessionID: sessionID)
            return GUIStateTransition(
                state: refreshed.state,
                effects: [.settleCreate(sessionID: sessionID, outcome: .succeeded(terminal: terminal))] + refreshed.effects
            )

        case .createFailed(let sessionID, let attempt, let kind, let error):
            var current = mutationsOf(state, sessionID: sessionID)
            if current.creating != attempt { return GUIStateTransition(state: state) }
            current.creating = nil
            let failureKind: CreateFailure = (kind == .unsupported) ? .unsupported : .failed
            return GUIStateTransition(
                state: settingMutations(state, sessionID: sessionID, mutations: current),
                effects: [.settleCreate(sessionID: sessionID, outcome: .failed(kind: failureKind, error: error))]
            )

        case .closeRequested(let sessionID, let ptyID):
            var current = mutationsOf(state, sessionID: sessionID)
            if current.closing[ptyID] != nil { return GUIStateTransition(state: state) }
            let attempt = issuedOf(state) + 1
            let pendingRename = current.renames.removeValue(forKey: ptyID)
            current.closing[ptyID] = attempt
            let nextState = settingMutations(settingIssued(state, issued: attempt), sessionID: sessionID, mutations: current)
            var effects: [Effect] = []
            if let pendingRename {
                effects.append(.abort(attempts: [pendingRename.attempt]))
            }
            effects.append(.closeTerminal(sessionID: sessionID, ptyID: ptyID, attempt: attempt))
            return GUIStateTransition(state: nextState, effects: effects)

        case .closeSucceeded(let sessionID, let ptyID, let attempt):
            var current = mutationsOf(state, sessionID: sessionID)
            if current.closing[ptyID] != attempt { return GUIStateTransition(state: state) }
            current.closing.removeValue(forKey: ptyID)
            let updatedState = updatingItems(
                settingMutations(state, sessionID: sessionID, mutations: current),
                sessionID: sessionID
            ) { items in
                items.filter { $0.id.rawValue != ptyID }
            }
            return refreshIfSupported(updatedState, sessionID: sessionID)

        case .closeFailed(let sessionID, let ptyID, let attempt, let error):
            var current = mutationsOf(state, sessionID: sessionID)
            if current.closing[ptyID] != attempt { return GUIStateTransition(state: state) }
            current.closing.removeValue(forKey: ptyID)
            var effects: [Effect] = []
            if let items = knownItems(state, sessionID: sessionID) {
                effects.append(.syncTabs(sessionID: sessionID, items: items))
            }
            effects.append(.toastCloseFailed(error: error))
            return GUIStateTransition(
                state: settingMutations(state, sessionID: sessionID, mutations: current),
                effects: effects
            )

        case .renameRequested(let sessionID, let ptyID, let title):
            var current = mutationsOf(state, sessionID: sessionID)
            guard let item = knownItems(state, sessionID: sessionID)?.first(where: { $0.id.rawValue == ptyID }),
                  current.closing[ptyID] == nil
            else {
                return GUIStateTransition(state: state)
            }
            if let pending = current.renames[ptyID] {
                if pending.title == title { return GUIStateTransition(state: state) }
            } else if title == item.title || (title == nil && item.userTitle == nil) {
                return GUIStateTransition(state: state)
            }
            let attempt = issuedOf(state) + 1
            let previousRename = current.renames[ptyID]
            current.renames[ptyID] = PendingRename(attempt: attempt, title: title)
            let nextState = settingMutations(settingIssued(state, issued: attempt), sessionID: sessionID, mutations: current)
            var effects: [Effect] = []
            if let previousRename {
                effects.append(.abort(attempts: [previousRename.attempt]))
            }
            effects.append(.renameTerminal(sessionID: sessionID, ptyID: ptyID, title: title, attempt: attempt))
            return GUIStateTransition(state: nextState, effects: effects)

        case .renameSucceeded(let sessionID, let ptyID, let attempt, let terminal):
            var current = mutationsOf(state, sessionID: sessionID)
            guard current.renames[ptyID]?.attempt == attempt else { return GUIStateTransition(state: state) }
            current.renames.removeValue(forKey: ptyID)
            let nextState = updatingItems(
                settingMutations(state, sessionID: sessionID, mutations: current),
                sessionID: sessionID
            ) { replaceItem($0, with: terminal) }
            return GUIStateTransition(state: nextState)

        case .renameFailed(let sessionID, let ptyID, let attempt, let kind, let error):
            var current = mutationsOf(state, sessionID: sessionID)
            guard current.renames[ptyID]?.attempt == attempt else { return GUIStateTransition(state: state) }
            current.renames.removeValue(forKey: ptyID)
            return GUIStateTransition(
                state: settingMutations(state, sessionID: sessionID, mutations: current),
                effects: [.toastRenameFailed(kind: kind, error: error)]
            )

        default:
            return nil
        }
    }

    private static func handleLost(state: State, error: String?) -> GUIStateTransition<State, Effect> {
        let connections: Int
        let issued: Int
        let sessionIDs: [String]
        let mutations: [String: Mutations]
        switch state {
        case .checking(let c, _, let i, let s, let m):
            connections = c
            issued = i
            sessionIDs = s.keys.sorted()
            mutations = m
        case .supported(let c, let i, let s, let m):
            connections = c
            issued = i
            sessionIDs = s.keys.sorted()
            mutations = m
        default:
            return GUIStateTransition(state: state)
        }

        let allIDs = Array(Set(sessionIDs).union(mutations.keys)).sorted()
        let abortIDs = collectAttempts(state: state, ids: allIDs)
        let outcome: CreateOutcome = error.map { .failed(kind: .failed, error: $0) } ?? .failed(kind: .unsupported, error: nil)
        let settles = settleCreates(mutations: mutations, ids: mutations.keys.sorted(), outcome: outcome)
        var effects: [Effect] = []
        if !abortIDs.isEmpty { effects.append(.abort(attempts: abortIDs)) }
        effects.append(contentsOf: settles)

        let nextState: State = error.map {
            .failed(connections: connections, issued: issued, sessions: sessionIDs, error: $0)
        } ?? .unsupported(connections: connections, issued: issued, sessions: sessionIDs)
        return GUIStateTransition(state: nextState, effects: effects)
    }

    private static func handleRemoved(_ state: State, ids: [String]) -> GUIStateTransition<State, Effect> {
        let idSet = Set(ids)
        switch state {
        case .checking(let connections, let attempt, let issued, var sessions, var mutations):
            let touches = ids.contains { sessions[$0] != nil || mutations[$0] != nil }
            if !touches { return GUIStateTransition(state: state) }
            let abortIDs = collectAttempts(state: state, ids: ids)
            let settles = settleCreates(mutations: mutations, ids: ids, outcome: .failed(kind: .cancelled, error: nil))
            for id in idSet {
                sessions.removeValue(forKey: id)
                mutations.removeValue(forKey: id)
            }
            var effects: [Effect] = []
            if !abortIDs.isEmpty { effects.append(.abort(attempts: abortIDs)) }
            effects.append(contentsOf: settles)
            return GUIStateTransition(
                state: .checking(connections: connections, attempt: attempt, issued: issued, sessions: sessions, mutations: mutations),
                effects: effects
            )

        case .supported(let connections, let issued, var sessions, var mutations):
            let touches = ids.contains { sessions[$0] != nil || mutations[$0] != nil }
            if !touches { return GUIStateTransition(state: state) }
            let abortIDs = collectAttempts(state: state, ids: ids)
            let settles = settleCreates(mutations: mutations, ids: ids, outcome: .failed(kind: .cancelled, error: nil))
            for id in idSet {
                sessions.removeValue(forKey: id)
                mutations.removeValue(forKey: id)
            }
            var effects: [Effect] = []
            if !abortIDs.isEmpty { effects.append(.abort(attempts: abortIDs)) }
            effects.append(contentsOf: settles)
            return GUIStateTransition(
                state: .supported(connections: connections, issued: issued, sessions: sessions, mutations: mutations),
                effects: effects
            )

        default:
            return GUIStateTransition(state: state)
        }
    }

    private static func handleStopped(_ state: State) -> GUIStateTransition<State, Effect> {
        switch state {
        case .checking(let c, let a, let i, let s, let m):
            if m.isEmpty { return GUIStateTransition(state: state) }
            return GUIStateTransition(
                state: .checking(connections: c, attempt: a, issued: i, sessions: s, mutations: [:]),
                effects: settleCreates(mutations: m, ids: m.keys.sorted(), outcome: .failed(kind: .cancelled, error: nil))
            )
        case .supported(let c, let i, let s, let m):
            if m.isEmpty { return GUIStateTransition(state: state) }
            return GUIStateTransition(
                state: .supported(connections: c, issued: i, sessions: s, mutations: [:]),
                effects: settleCreates(mutations: m, ids: m.keys.sorted(), outcome: .failed(kind: .cancelled, error: nil))
            )
        default:
            return GUIStateTransition(state: state)
        }
    }

    private static func loadList(_ state: State, sessionID: String) -> GUIStateTransition<State, Effect> {
        guard case .supported(let connections, let issued, var sessions, let mutations) = state else {
            return GUIStateTransition(state: state)
        }
        let attempt = issued + 1
        let existing = sessions[sessionID]
        var effects: [Effect] = []
        if let existing, let existingAttempt = listAttempt(existing) {
            effects.append(.abort(attempts: [existingAttempt]))
        }
        switch existing {
        case .ready(let conn, let items), .refreshing(let conn, let items, _):
            sessions[sessionID] = .refreshing(connection: conn, items: items, attempt: attempt)
        default:
            sessions[sessionID] = .loading(attempt: attempt)
        }
        effects.append(.loadList(sessionID: sessionID, attempt: attempt))
        return GUIStateTransition(
            state: .supported(connections: connections, issued: attempt, sessions: sessions, mutations: mutations),
            effects: effects
        )
    }

    private static func refreshIfSupported(_ state: State, sessionID: String) -> GUIStateTransition<State, Effect> {
        if case .supported(_, _, let sessions, _) = state, sessions[sessionID] != nil {
            return loadList(state, sessionID: sessionID)
        }
        return GUIStateTransition(state: state)
    }

    private static func listAttempt(_ list: SessionList) -> Int? {
        switch list {
        case .loading(let a), .refreshing(_, _, let a): return a
        case .ready, .failed: return nil
        }
    }

    private static func collectAttempts(state: State, ids: [String]) -> [Int] {
        var out: [Int] = []
        for id in ids {
            if case .supported(_, _, let sessions, _) = state, let list = sessions[id], let a = listAttempt(list) {
                out.append(a)
            }
            let m = mutationsOf(state, sessionID: id)
            if let creating = m.creating { out.append(creating) }
            out.append(contentsOf: m.closing.values.sorted())
            out.append(contentsOf: m.renames.values.map(\.attempt).sorted())
        }
        return out
    }

    private static func settleCreates(
        mutations: [String: Mutations],
        ids: [String],
        outcome: CreateOutcome
    ) -> [Effect] {
        ids.compactMap { sessionID in
            mutations[sessionID]?.creating != nil ? .settleCreate(sessionID: sessionID, outcome: outcome) : nil
        }
    }

    private static func issuedOf(_ state: State) -> Int {
        switch state {
        case .checking(_, _, let i, _, _), .supported(_, let i, _, _), .unsupported(_, let i, _), .failed(_, let i, _, _):
            return i
        case .unknown:
            return 0
        }
    }

    private static func settingIssued(_ state: State, issued: Int) -> State {
        switch state {
        case .checking(let c, let a, _, let s, let m):
            return .checking(connections: c, attempt: a, issued: issued, sessions: s, mutations: m)
        case .supported(let c, _, let s, let m):
            return .supported(connections: c, issued: issued, sessions: s, mutations: m)
        default:
            return state
        }
    }

    private static func mutationsOf(_ state: State, sessionID: String) -> Mutations {
        switch state {
        case .checking(_, _, _, _, let m), .supported(_, _, _, let m):
            return m[sessionID] ?? Mutations()
        default:
            return Mutations()
        }
    }

    private static func settingMutations(_ state: State, sessionID: String, mutations next: Mutations) -> State {
        switch state {
        case .checking(let c, let a, let i, let s, var m):
            if next.isIdle { m.removeValue(forKey: sessionID) } else { m[sessionID] = next }
            return .checking(connections: c, attempt: a, issued: i, sessions: s, mutations: m)
        case .supported(let c, let i, let s, var m):
            if next.isIdle { m.removeValue(forKey: sessionID) } else { m[sessionID] = next }
            return .supported(connections: c, issued: i, sessions: s, mutations: m)
        default:
            return state
        }
    }

    private static func knownItems(_ state: State, sessionID: String) -> [PersistentPtySchema.Info]? {
        switch state {
        case .checking(_, _, _, let sessions, _):
            if case .ready(_, let items) = sessions[sessionID] { return items }
            return nil
        case .supported(_, _, let sessions, _):
            switch sessions[sessionID] {
            case .ready(_, let items), .refreshing(_, let items, _): return items
            default: return nil
            }
        default:
            return nil
        }
    }

    private static func updatingItems(
        _ state: State,
        sessionID: String,
        transform: ([PersistentPtySchema.Info]) -> [PersistentPtySchema.Info]
    ) -> State {
        switch state {
        case .checking(let c, let a, let i, var sessions, let m):
            guard case .ready(let conn, let items) = sessions[sessionID] else { return state }
            sessions[sessionID] = .ready(connection: conn, items: transform(items))
            return .checking(connections: c, attempt: a, issued: i, sessions: sessions, mutations: m)
        case .supported(let c, let i, var sessions, let m):
            switch sessions[sessionID] {
            case .ready(let conn, let items):
                sessions[sessionID] = .ready(connection: conn, items: transform(items))
                return .supported(connections: c, issued: i, sessions: sessions, mutations: m)
            case .refreshing(let conn, let items, let attempt):
                sessions[sessionID] = .refreshing(connection: conn, items: transform(items), attempt: attempt)
                return .supported(connections: c, issued: i, sessions: sessions, mutations: m)
            default:
                return state
            }
        default:
            return state
        }
    }

    private static func replaceItem(
        _ items: [PersistentPtySchema.Info],
        with terminal: PersistentPtySchema.Info
    ) -> [PersistentPtySchema.Info] {
        guard items.contains(where: { $0.id == terminal.id }) else { return items }
        return items.map { $0.id == terminal.id ? terminal : $0 }
    }

    private static func applyingRenames(
        _ items: [PersistentPtySchema.Info],
        mutations: Mutations?
    ) -> [PersistentPtySchema.Info] {
        guard let mutations, mutations.renames.values.contains(where: { $0.title != nil }) else {
            return items
        }
        return items.map { info in
            guard let title = mutations.renames[info.id.rawValue]?.title else { return info }
            return PersistentPtySchema.Info(
                id: info.id,
                title: title,
                command: info.command,
                args: info.args,
                cwd: info.cwd,
                status: info.status,
                pid: info.pid,
                exitCode: info.exitCode,
                sessionID: info.sessionID,
                userTitle: title,
                foregroundProcess: info.foregroundProcess,
                size: info.size,
                output: info.output
            )
        }
    }
}

// MARK: - Terminal Pane, Surface, Rename, Quote Machines & Title (`terminal/{pane,surface,rename,quote}-machine.ts`, `title.ts`)

public enum TerminalPaneMachine {
    public static let ghosttyLoadTimeoutMs = 30_000
    public static let connectTimeoutMs = 15_000
    public static let sizeDebounceMs = 100

    public enum Phase: String, Equatable, Hashable, Sendable {
        case loading
        case connecting
    }

    public struct PaneSizing: Equatable, Sendable {
        public let seq: Int
        public let size: TerminalSize?
        public let pending: TerminalSize?

        public init(seq: Int = 0, size: TerminalSize? = nil, pending: TerminalSize? = nil) {
            self.seq = seq
            self.size = size
            self.pending = pending
        }
    }

    public enum State<Term: Sendable>: Sendable {
        case idle
        case loading
        case opening
        case connecting(term: Term, sizing: PaneSizing, shown: Bool)
        case live(term: Term, sizing: PaneSizing)
        case failed(failure: TerminalFailure, term: Term?)
        case disposed
    }

    public enum Event<Loaded: Sendable, Term: Sendable>: Sendable {
        case mounted
        case ghosttyLoaded(loaded: Loaded)
        case ghosttyFailed
        case terminalOpened(term: Term, initialSize: TerminalSize?)
        case screenWritten
        case socketOpened
        case connectionFailed(failure: TerminalFailure)
        case phaseTimedOut(phase: Phase)
        case measureRequested
        case measureSampled(proposed: TerminalSize?)
        case sizeDebounced(seq: Int)
        case disposed
    }

    public enum Effect<Loaded: Sendable>: Sendable {
        case loadGhostty(timeoutMs: Int)
        case cancelPhaseTimer
        case openTerminal(loaded: Loaded)
        case startConnect(timeoutMs: Int)
        case applySize(size: TerminalSize)
        case scheduleMeasure
        case scheduleSizeTimer(seq: Int, delayMs: Int)
        case cancelSizeTimer
        case stop
        case notifyFailure
        case release
    }

    public static func reduce<Loaded: Sendable, Term: Sendable>(
        state: State<Term>,
        event: Event<Loaded, Term>
    ) -> GUIStateTransition<State<Term>, Effect<Loaded>> {
        if case .disposed = state { return GUIStateTransition(state: state) }

        if case .disposed = event {
            if case .idle = state {
                return GUIStateTransition(state: .disposed)
            }
            return GUIStateTransition(state: .disposed, effects: [.release])
        }

        switch state {
        case .idle:
            guard case .mounted = event else { return GUIStateTransition(state: state) }
            return GUIStateTransition(state: .loading, effects: [.loadGhostty(timeoutMs: ghosttyLoadTimeoutMs)])

        case .loading:
            switch event {
            case .ghosttyLoaded(let loaded):
                return GUIStateTransition(state: .opening, effects: [.cancelPhaseTimer, .openTerminal(loaded: loaded)])
            case .ghosttyFailed, .phaseTimedOut(.loading):
                return GUIStateTransition(state: .failed(failure: .failed, term: nil), effects: [.stop, .notifyFailure])
            default:
                return GUIStateTransition(state: state)
            }

        case .opening:
            switch event {
            case .terminalOpened(let term, let initialSize):
                var effects: [Effect<Loaded>] = []
                if let initialSize { effects.append(.applySize(size: initialSize)) }
                effects.append(.startConnect(timeoutMs: connectTimeoutMs))
                return GUIStateTransition(
                    state: .connecting(term: term, sizing: PaneSizing(seq: 0, size: initialSize, pending: nil), shown: false),
                    effects: effects
                )
            case .connectionFailed(let failure):
                return GUIStateTransition(state: .failed(failure: failure, term: nil), effects: [.release, .notifyFailure])
            default:
                return GUIStateTransition(state: state)
            }

        case .failed, .disposed:
            return GUIStateTransition(state: state)

        case .connecting(let term, let sizing, let shown):
            switch event {
            case .connectionFailed(let failure):
                return GUIStateTransition(state: .failed(failure: failure, term: term), effects: [.stop, .notifyFailure])
            case .measureRequested:
                return GUIStateTransition(state: state, effects: [.scheduleMeasure])
            case .measureSampled(let proposed):
                return handleSampled(term: term, sizing: sizing, isLive: false, shown: shown, proposed: proposed)
            case .sizeDebounced(let seq):
                guard let pending = sizing.pending, sizing.seq == seq else { return GUIStateTransition(state: state) }
                return GUIStateTransition(
                    state: .connecting(term: term, sizing: PaneSizing(seq: sizing.seq, size: pending, pending: nil), shown: shown),
                    effects: [.applySize(size: pending)]
                )
            case .screenWritten:
                return shown ? GUIStateTransition(state: state) : GUIStateTransition(state: .connecting(term: term, sizing: sizing, shown: true))
            case .socketOpened:
                return GUIStateTransition(state: .live(term: term, sizing: sizing), effects: [.cancelPhaseTimer])
            case .phaseTimedOut(.connecting):
                return GUIStateTransition(state: .failed(failure: .failed, term: term), effects: [.stop, .notifyFailure])
            default:
                return GUIStateTransition(state: state)
            }

        case .live(let term, let sizing):
            switch event {
            case .connectionFailed(let failure):
                return GUIStateTransition(state: .failed(failure: failure, term: term), effects: [.stop, .notifyFailure])
            case .measureRequested:
                return GUIStateTransition(state: state, effects: [.scheduleMeasure])
            case .measureSampled(let proposed):
                return handleSampled(term: term, sizing: sizing, isLive: true, shown: true, proposed: proposed)
            case .sizeDebounced(let seq):
                guard let pending = sizing.pending, sizing.seq == seq else { return GUIStateTransition(state: state) }
                return GUIStateTransition(
                    state: .live(term: term, sizing: PaneSizing(seq: sizing.seq, size: pending, pending: nil)),
                    effects: [.applySize(size: pending)]
                )
            default:
                return GUIStateTransition(state: state)
            }
        }
    }

    public static func paneRevealed<Term: Sendable>(_ state: State<Term>) -> Bool {
        switch state {
        case .connecting(_, _, let shown): return shown
        case .live, .failed: return true
        default: return false
        }
    }

    public static func paneFailure<Term: Sendable>(_ state: State<Term>) -> TerminalFailure? {
        if case .failed(let failure, _) = state { return failure }
        return nil
    }

    public static func paneTerm<Term: Sendable>(_ state: State<Term>) -> Term? {
        switch state {
        case .connecting(let term, _, _), .live(let term, _): return term
        case .failed(_, let term): return term
        default: return nil
        }
    }

    public static func effectFailed<Loaded: Sendable, Term: Sendable>(_ effect: Effect<Loaded>) -> Event<Loaded, Term>? {
        switch effect {
        case .loadGhostty: return .ghosttyFailed
        case .openTerminal, .startConnect: return .connectionFailed(failure: .failed)
        default: return nil
        }
    }

    private static func handleSampled<Loaded: Sendable, Term: Sendable>(
        term: Term,
        sizing: PaneSizing,
        isLive: Bool,
        shown: Bool,
        proposed: TerminalSize?
    ) -> GUIStateTransition<State<Term>, Effect<Loaded>> {
        func wrap(_ nextSizing: PaneSizing) -> State<Term> {
            isLive ? .live(term: term, sizing: nextSizing) : .connecting(term: term, sizing: nextSizing, shown: shown)
        }
        guard let proposed, proposed != sizing.size else {
            guard sizing.pending != nil else { return GUIStateTransition(state: wrap(sizing)) }
            return GUIStateTransition(
                state: wrap(PaneSizing(seq: sizing.seq, size: sizing.size, pending: nil)),
                effects: [.cancelSizeTimer]
            )
        }
        if sizing.size == nil {
            return GUIStateTransition(
                state: wrap(PaneSizing(seq: sizing.seq, size: proposed, pending: nil)),
                effects: [.applySize(size: proposed)]
            )
        }
        if proposed == sizing.pending {
            return GUIStateTransition(state: wrap(sizing))
        }
        let nextSeq = sizing.seq + 1
        return GUIStateTransition(
            state: wrap(PaneSizing(seq: nextSeq, size: sizing.size, pending: proposed)),
            effects: [.scheduleSizeTimer(seq: nextSeq, delayMs: sizeDebounceMs)]
        )
    }
}

extension TerminalPaneMachine.State: Equatable where Term: Equatable {}
extension TerminalPaneMachine.Event: Equatable where Loaded: Equatable, Term: Equatable {}
extension TerminalPaneMachine.Effect: Equatable where Loaded: Equatable {}

public enum TerminalSurfaceMachine: GUIStateMachine {
    public enum SurfaceStatus: String, Equatable, Hashable, Sendable {
        case live
        case failed
    }

    public struct Surface: Equatable, Hashable, Sendable {
        public let session: String
        public let id: String
        public let mount: Int
        public let connection: Int
        public let status: SurfaceStatus

        public init(session: String, id: String, mount: Int, connection: Int, status: SurfaceStatus) {
            self.session = session
            self.id = id
            self.mount = mount
            self.connection = connection
            self.status = status
        }
    }

    public enum State: Equatable, Sendable {
        case idle(issued: Int, seeded: String?)
        case ready(
            issued: Int,
            session: String,
            connection: Int,
            opened: Bool,
            active: String?,
            seeded: String?,
            surfaces: [Surface]
        )
    }

    public enum Event: Equatable, Sendable {
        case sync(
            session: String,
            ready: Bool,
            connection: Int,
            opened: Bool,
            mobile: Bool,
            active: String?,
            terminalIDs: [String],
            elsewhere: Set<String>
        )
        case surfaceFailed(mount: Int)
    }

    public enum Effect: Equatable, Sendable {
        case createTerminal
    }

    public static let initialState: State = .idle(issued: 0, seeded: nil)

    public static func reduce(state: State, event: Event) -> GUIStateTransition<State, Effect> {
        switch event {
        case .surfaceFailed(let mount):
            return GUIStateTransition(state: handleFailed(state: state, mount: mount))

        case .sync(let session, let isReady, let connection, let opened, let mobile, let active, let terminalIDs, let elsewhere):
            let currentSeeded: String?
            let currentIssued: Int
            let previousSurfaces: [Surface]
            switch state {
            case .idle(let issued, let seeded):
                currentIssued = issued
                currentSeeded = seeded
                previousSurfaces = []
            case .ready(let issued, let prevSession, _, _, _, let seeded, let surfaces):
                currentIssued = issued
                currentSeeded = seeded
                previousSurfaces = (prevSession == session) ? surfaces : []
            }

            let nextSeeded: String? = (opened && mobile) ? (isReady ? session : currentSeeded) : nil
            let effects: [Effect] = (opened && mobile && isReady && currentSeeded != session && terminalIDs.isEmpty)
                ? [.createTerminal]
                : []

            if !isReady {
                return GUIStateTransition(state: .idle(issued: currentIssued, seeded: nextSeeded), effects: effects)
            }

            let idSet = Set(terminalIDs)
            let isHere: (String) -> Bool = { idSet.contains($0) && !elsewhere.contains($0) }
            let shown: String? = (opened && active != nil && isHere(active!)) ? active : nil

            let kept = previousSurfaces.filter { surface in
                isHere(surface.id) && (surface.status == .live || (surface.id == shown && connection <= surface.connection))
            }

            let needsNew = shown != nil && !kept.contains(where: { $0.id == shown })
            let nextIssued = needsNew ? currentIssued + 1 : currentIssued
            let nextSurfaces: [Surface]
            if let shown, needsNew {
                nextSurfaces = kept + [Surface(session: session, id: shown, mount: nextIssued, connection: connection, status: .live)]
            } else {
                nextSurfaces = kept
            }

            return GUIStateTransition(
                state: .ready(
                    issued: nextIssued,
                    session: session,
                    connection: connection,
                    opened: opened,
                    active: active,
                    seeded: nextSeeded,
                    surfaces: nextSurfaces
                ),
                effects: effects
            )
        }
    }

    public static func surfaceMounts(_ state: State) -> [Int] {
        if case .ready(_, _, _, _, _, _, let surfaces) = state {
            return surfaces.map(\.mount)
        }
        return []
    }

    public static func surfaceAt(_ state: State, mount: Int) -> Surface? {
        if case .ready(_, _, _, _, _, _, let surfaces) = state {
            return surfaces.first { $0.mount == mount }
        }
        return nil
    }

    public static func surfaceShown(_ state: State, surface: Surface) -> Bool {
        if case .ready(_, let session, _, _, let active, _, _) = state {
            return session == surface.session && active == surface.id
        }
        return false
    }

    private static func handleFailed(state: State, mount: Int) -> State {
        guard case .ready(let issued, let session, let connection, let opened, let active, let seeded, let surfaces) = state,
              let index = surfaces.firstIndex(where: { $0.mount == mount })
        else {
            return state
        }
        let current = surfaces[index]
        if current.status == .failed { return state }

        if !opened || active != current.id {
            var next = surfaces
            next.remove(at: index)
            return .ready(
                issued: issued,
                session: session,
                connection: connection,
                opened: opened,
                active: active,
                seeded: seeded,
                surfaces: next
            )
        }

        if connection > current.connection {
            let nextIssued = issued + 1
            var next = surfaces
            next[index] = Surface(session: session, id: current.id, mount: nextIssued, connection: connection, status: .live)
            return .ready(
                issued: nextIssued,
                session: session,
                connection: connection,
                opened: opened,
                active: active,
                seeded: seeded,
                surfaces: next
            )
        }

        var next = surfaces
        next[index] = Surface(
            session: current.session,
            id: current.id,
            mount: current.mount,
            connection: current.connection,
            status: .failed
        )
        return .ready(
            issued: issued,
            session: session,
            connection: connection,
            opened: opened,
            active: active,
            seeded: seeded,
            surfaces: next
        )
    }
}

public enum TerminalRenameMachine: GUIStateMachine {
    public enum Source: String, Equatable, Hashable, Sendable {
        case pointer
        case menu
    }

    public enum State: Equatable, Sendable {
        case idle(issued: Int)
        case arming(issued: Int, attempt: Int, source: Source, draft: String, edited: Bool)
        case editing(issued: Int, draft: String)
    }

    public enum Event: Equatable, Sendable {
        case start(title: String, source: Source, enabled: Bool)
        case armed(attempt: Int)
        case change(value: String)
        case submit
        case blur
        case cancel
    }

    public enum Effect: Equatable, Sendable {
        case arm(attempt: Int, source: Source)
        case disarm
        case save(title: String?)
    }

    public static let initialState: State = .idle(issued: 0)

    public static func reduce(state: State, event: Event) -> GUIStateTransition<State, Effect> {
        switch event {
        case .start(let title, let source, let enabled):
            guard case .idle(let issued) = state, enabled else { return GUIStateTransition(state: state) }
            let attempt = issued + 1
            return GUIStateTransition(
                state: .arming(issued: attempt, attempt: attempt, source: source, draft: title, edited: false),
                effects: [.arm(attempt: attempt, source: source)]
            )

        case .armed(let attempt):
            guard case .arming(let issued, let currentAttempt, _, let draft, _) = state, currentAttempt == attempt else {
                return GUIStateTransition(state: state)
            }
            return GUIStateTransition(state: .editing(issued: issued, draft: draft))

        case .change(let value):
            switch state {
            case .idle:
                return GUIStateTransition(state: state)
            case .arming(let issued, let attempt, let source, let draft, _):
                if draft == value { return GUIStateTransition(state: state) }
                return GUIStateTransition(
                    state: .arming(issued: issued, attempt: attempt, source: source, draft: value, edited: true)
                )
            case .editing(let issued, let draft):
                if draft == value { return GUIStateTransition(state: state) }
                return GUIStateTransition(state: .editing(issued: issued, draft: value))
            }

        case .blur:
            switch state {
            case .idle, .arming:
                return GUIStateTransition(state: state)
            case .editing(let issued, let draft):
                let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                return GUIStateTransition(state: .idle(issued: issued), effects: [.save(title: trimmed.isEmpty ? nil : trimmed)])
            }

        case .cancel:
            switch state {
            case .idle:
                return GUIStateTransition(state: state)
            case .arming(let issued, _, _, _, _):
                return GUIStateTransition(state: .idle(issued: issued), effects: [.disarm])
            case .editing(let issued, _):
                return GUIStateTransition(state: .idle(issued: issued))
            }

        case .submit:
            switch state {
            case .idle:
                return GUIStateTransition(state: state)
            case .arming(let issued, _, _, let draft, _):
                let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                return GUIStateTransition(
                    state: .idle(issued: issued),
                    effects: [.disarm, .save(title: trimmed.isEmpty ? nil : trimmed)]
                )
            case .editing(let issued, let draft):
                let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                return GUIStateTransition(state: .idle(issued: issued), effects: [.save(title: trimmed.isEmpty ? nil : trimmed)])
            }
        }
    }

    public static func isRenaming(_ state: State) -> Bool {
        if case .idle = state { return false }
        return true
    }

    public static func draft(_ state: State) -> String {
        switch state {
        case .idle: return ""
        case .arming(_, _, _, let draft, _), .editing(_, let draft): return draft
        }
    }
}

public enum TerminalQuoteMachine: GUIStateMachine {
    public static let settleMs = 150
    public static let gapPx: Double = 8
    public static let maxLength = 20_000

    public struct Place: Equatable, Sendable {
        public let top: Double
        public let left: Double

        public init(top: Double, left: Double) {
            self.top = top
            self.left = left
        }
    }

    public struct Size: Equatable, Sendable {
        public let width: Double
        public let height: Double

        public init(width: Double, height: Double) {
            self.width = width
            self.height = height
        }
    }

    public struct Rect: Equatable, Sendable {
        public let top: Double
        public let bottom: Double
        public let left: Double
        public let right: Double
        public let width: Double
        public let height: Double

        public init(top: Double, bottom: Double, left: Double, right: Double, width: Double, height: Double) {
            self.top = top
            self.bottom = bottom
            self.left = left
            self.right = right
            self.width = width
            self.height = height
        }
    }

    public struct CellPoint: Equatable, Hashable, Sendable {
        public let x: Int
        public let y: Int

        public init(x: Int, y: Int) {
            self.x = x
            self.y = y
        }
    }

    public struct Cells: Equatable, Hashable, Sendable {
        public let start: CellPoint
        public let end: CellPoint

        public init(start: CellPoint, end: CellPoint) {
            self.start = start
            self.end = end
        }
    }

    public struct Anchor: Equatable, Sendable {
        public let top: Double
        public let bottom: Double
        public let start: Double
        public let end: Double
        public let single: Bool

        public init(top: Double, bottom: Double, start: Double, end: Double, single: Bool) {
            self.top = top
            self.bottom = bottom
            self.start = start
            self.end = end
            self.single = single
        }
    }

    public struct Placement: Equatable, Sendable {
        public let bounds: Rect
        public let anchor: Anchor

        public init(bounds: Rect, anchor: Anchor) {
            self.bounds = bounds
            self.anchor = anchor
        }
    }

    public struct Source: Equatable, Sendable {
        public let cells: Cells?
        public let offset: Int
        public let written: Int
        public let resized: Int

        public init(cells: Cells?, offset: Int, written: Int, resized: Int) {
            self.cells = cells
            self.offset = offset
            self.written = written
            self.resized = resized
        }
    }

    public struct Sample: Equatable, Sendable {
        public let cells: Cells?
        public let offset: Int
        public let written: Int
        public let bounds: Rect
        public let origin: Place?
        public let metrics: Size?

        public init(cells: Cells?, offset: Int, written: Int, bounds: Rect, origin: Place?, metrics: Size?) {
            self.cells = cells
            self.offset = offset
            self.written = written
            self.bounds = bounds
            self.origin = origin
            self.metrics = metrics
        }
    }

    public struct Meta: Equatable, Sendable {
        public let issued: Int
        public let revision: Int
        public let resized: Int

        public init(issued: Int = 0, revision: Int = 0, resized: Int = 0) {
            self.issued = issued
            self.revision = revision
            self.resized = resized
        }
    }

    public enum State: Equatable, Sendable {
        case idle(meta: Meta)
        case pressing(meta: Meta)
        case settling(meta: Meta, attempt: Int)
        case shown(
            meta: Meta,
            text: String,
            truncated: Bool,
            source: Source,
            placement: Placement?,
            toolbarSize: Size,
            placeAttempt: Int?
        )
        case disposed
    }

    public enum Event: Equatable, Sendable {
        case pointerDown(button: Int)
        case pointerReleased
        case selectionChanged
        case settleSampled(attempt: Int, text: String, sample: Sample?)
        case keyPressed(key: String, modified: Bool)
        case layoutChanged(resized: Bool)
        case placeSampled(attempt: Int, sample: Sample?)
        case toolbarMeasured(size: Size)
        case quoteAdded(skipComment: Bool)
        case disposed
    }

    public enum Effect: Equatable, Sendable {
        case scheduleSettle(attempt: Int, delayMs: Int)
        case cancelSettle
        case schedulePlace(attempt: Int)
        case cancelPlace
        case clearSelection
        case commitQuote(text: String, source: Source?)
    }

    public static func createState() -> State {
        .idle(meta: Meta())
    }

    public static func reduce(state: State, event: Event) -> GUIStateTransition<State, Effect> {
        if case .disposed = state { return GUIStateTransition(state: state) }

        if case .disposed = event {
            return GUIStateTransition(state: .disposed, effects: cancelEffects(state))
        }

        switch event {
        case .layoutChanged(let resized):
            return handleLayout(state: state, resized: resized)

        case .pointerDown(let button):
            if button != 0 { return GUIStateTransition(state: state) }
            if case .pressing = state { return GUIStateTransition(state: state) }
            guard let meta = metaOf(state) else { return GUIStateTransition(state: state) }
            return GUIStateTransition(state: .pressing(meta: meta), effects: cancelEffects(state))

        case .pointerReleased:
            guard case .pressing(let meta) = state else { return GUIStateTransition(state: state) }
            return startSettle(meta: meta, priorEffects: [])

        case .selectionChanged:
            if case .pressing = state { return GUIStateTransition(state: state) }
            guard let meta = metaOf(state) else { return GUIStateTransition(state: state) }
            let prior: [Effect] = if case .shown = state { cancelEffects(state) } else { [] }
            return startSettle(meta: meta, priorEffects: prior)

        case .settleSampled(let attempt, let rawText, let sample):
            guard case .settling(let meta, let currentAttempt) = state, currentAttempt == attempt else {
                return GUIStateTransition(state: state)
            }
            let text = trimQuoteSelection(rawText)
            guard let sample, !text.isEmpty else {
                return GUIStateTransition(state: .idle(meta: meta))
            }
            return GUIStateTransition(
                state: .shown(
                    meta: meta,
                    text: text,
                    truncated: text.utf16.count > maxLength,
                    source: Source(cells: sample.cells, offset: sample.offset, written: sample.written, resized: meta.resized),
                    placement: placementOf(sample),
                    toolbarSize: Size(width: 0, height: 0),
                    placeAttempt: nil
                )
            )

        case .keyPressed(let key, let modified):
            let modifiers: Set<String> = ["Shift", "Control", "Alt", "Meta"]
            if modified || modifiers.contains(key) { return GUIStateTransition(state: state) }
            switch state {
            case .settling(let meta, _), .shown(let meta, _, _, _, _, _, _):
                return GUIStateTransition(state: .idle(meta: meta), effects: cancelEffects(state))
            default:
                return GUIStateTransition(state: state)
            }

        case .placeSampled(let attempt, let sample):
            guard case .shown(let meta, let text, let truncated, let source, _, let toolbarSize, let placeAttempt) = state,
                  placeAttempt == attempt
            else {
                return GUIStateTransition(state: state)
            }
            guard let sample else {
                return GUIStateTransition(state: .idle(meta: meta))
            }
            let nextPlacement = placementOf(sample)
            let nextSource: Source
            if source.cells == nil, let sampleCells = sample.cells, sample.written == source.written, meta.resized == source.resized {
                nextSource = Source(cells: sampleCells, offset: sample.offset, written: source.written, resized: source.resized)
            } else {
                nextSource = source
            }
            return GUIStateTransition(
                state: .shown(
                    meta: meta,
                    text: text,
                    truncated: truncated,
                    source: nextSource,
                    placement: nextPlacement,
                    toolbarSize: toolbarSize,
                    placeAttempt: nil
                )
            )

        case .toolbarMeasured(let size):
            guard case .shown(let meta, let text, let truncated, let source, let placement, let currentSize, let placeAttempt) = state,
                  currentSize != size
            else {
                return GUIStateTransition(state: state)
            }
            return GUIStateTransition(
                state: .shown(
                    meta: meta,
                    text: text,
                    truncated: truncated,
                    source: source,
                    placement: placement,
                    toolbarSize: size,
                    placeAttempt: placeAttempt
                )
            )

        case .quoteAdded(let skipComment):
            guard case .shown(let meta, let text, let truncated, let source, _, _, _) = state, !truncated else {
                return GUIStateTransition(state: state)
            }
            return GUIStateTransition(
                state: .idle(meta: meta),
                effects: cancelEffects(state) + [.clearSelection, .commitQuote(text: text, source: skipComment ? nil : source)]
            )

        case .disposed:
            return GUIStateTransition(state: state)
        }
    }

    public static func quotePosition(size: Size, bounds: Rect, anchor: Anchor) -> Place {
        let above = anchor.top - size.height - gapPx
        let below = anchor.bottom + gapPx
        let fitsAbove = above >= bounds.top + gapPx && anchor.top <= bounds.bottom
        let fitsBelow = below + size.height <= bounds.bottom - gapPx && anchor.bottom >= bounds.top
        let candidates: [(Bool, Double)] = anchor.single
            ? [(fitsAbove, above), (fitsBelow, below)]
            : [(fitsBelow, below), (fitsAbove, above)]
        let top = candidates.first(where: \.0)?.1 ?? (bounds.bottom - size.height - gapPx)
        let center = anchor.single ? (anchor.start + anchor.end - size.width) / 2.0 : (anchor.end - size.width / 2.0)
        let minLeft = bounds.left + gapPx
        let maxLeft = bounds.right - size.width - gapPx
        return Place(top: top, left: max(minLeft, min(center, maxLeft)))
    }

    private static func handleLayout(state: State, resized: Bool) -> GUIStateTransition<State, Effect> {
        guard let meta = metaOf(state) else { return GUIStateTransition(state: state) }
        let ticked = Meta(issued: meta.issued, revision: meta.revision + 1, resized: meta.resized + (resized ? 1 : 0))
        switch state {
        case .idle:
            return GUIStateTransition(state: .idle(meta: ticked))
        case .pressing:
            return GUIStateTransition(state: .pressing(meta: ticked))
        case .settling(_, let attempt):
            return GUIStateTransition(state: .settling(meta: ticked, attempt: attempt))
        case .shown(_, let text, let truncated, let source, let placement, let toolbarSize, let placeAttempt):
            if placeAttempt != nil {
                return GUIStateTransition(
                    state: .shown(
                        meta: ticked,
                        text: text,
                        truncated: truncated,
                        source: source,
                        placement: placement,
                        toolbarSize: toolbarSize,
                        placeAttempt: placeAttempt
                    )
                )
            }
            let nextAttempt = ticked.issued + 1
            let nextMeta = Meta(issued: nextAttempt, revision: ticked.revision, resized: ticked.resized)
            return GUIStateTransition(
                state: .shown(
                    meta: nextMeta,
                    text: text,
                    truncated: truncated,
                    source: source,
                    placement: placement,
                    toolbarSize: toolbarSize,
                    placeAttempt: nextAttempt
                ),
                effects: [.schedulePlace(attempt: nextAttempt)]
            )
        case .disposed:
            return GUIStateTransition(state: state)
        }
    }

    private static func startSettle(meta: Meta, priorEffects: [Effect]) -> GUIStateTransition<State, Effect> {
        let attempt = meta.issued + 1
        let nextMeta = Meta(issued: attempt, revision: meta.revision, resized: meta.resized)
        return GUIStateTransition(
            state: .settling(meta: nextMeta, attempt: attempt),
            effects: priorEffects + [.scheduleSettle(attempt: attempt, delayMs: settleMs)]
        )
    }

    private static func cancelEffects(_ state: State) -> [Effect] {
        switch state {
        case .settling: return [.cancelSettle]
        case .shown(_, _, _, _, _, _, let placeAttempt) where placeAttempt != nil: return [.cancelPlace]
        default: return []
        }
    }

    private static func metaOf(_ state: State) -> Meta? {
        switch state {
        case .idle(let m), .pressing(let m), .settling(let m, _), .shown(let m, _, _, _, _, _, _): return m
        case .disposed: return nil
        }
    }

    private static func placementOf(_ sample: Sample) -> Placement? {
        guard let cells = sample.cells, let origin = sample.origin, let metrics = sample.metrics, sample.bounds.height != 0 else {
            return nil
        }
        let anchor = Anchor(
            top: origin.top + Double(cells.start.y) * metrics.height,
            bottom: origin.top + Double(cells.end.y + 1) * metrics.height,
            start: origin.left + Double(cells.start.x) * metrics.width,
            end: origin.left + Double(cells.end.x + 1) * metrics.width,
            single: cells.start.y == cells.end.y
        )
        return Placement(bounds: sample.bounds, anchor: anchor)
    }

    private static func trimQuoteSelection(_ raw: String) -> String {
        var start = raw.startIndex
        while start < raw.endIndex && raw[start] == "\n" {
            start = raw.index(after: start)
        }
        var end = raw.endIndex
        while end > start {
            let prev = raw.index(before: end)
            if raw[prev].isWhitespace {
                end = prev
            } else {
                break
            }
        }
        return String(raw[start..<end])
    }
}

public enum TerminalTitle {
    private static let templates: [(before: String, after: String)] = [
        ("Terminal ", ""),
        ("محطة طرفية ", ""),
        ("Терминал ", ""),
        ("ターミナル ", ""),
        ("터미널 ", ""),
        ("เทอร์มินัล ", ""),
        ("终端 ", ""),
        ("終端機 ", ""),
    ]

    public static func defaultTitle(number: Int) -> String {
        "Terminal \(number)"
    }

    public static func titleNumber(_ title: String) -> Int? {
        for (before, after) in templates {
            guard title.hasPrefix(before), title.hasSuffix(after) else { continue }
            let start = title.index(title.startIndex, offsetBy: before.count)
            let end = title.index(title.endIndex, offsetBy: -after.count)
            guard start <= end else { continue }
            let digits = String(title[start..<end])
            guard let first = digits.first, first >= "1" && first <= "9",
                  digits.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
                  let number = Int(digits)
            else { continue }
            return number
        }
        return nil
    }

    public static func tabLabel(
        title: String?,
        numberedFormat: (Int) -> String,
        fallbackTitle: String
    ) -> String {
        let value = title ?? ""
        if let number = titleNumber(value) {
            return numberedFormat(number)
        }
        return value.isEmpty ? fallbackTitle : value
    }
}

// MARK: - Terminal Controller Actor

/// Actor uniting multi-session terminal tabs, mounted surfaces, and focus coordination.
public actor TerminalController {
    private var sessionState: TerminalSessionMachine.State = TerminalSessionMachine.initialState
    private var surfaceState: TerminalSurfaceMachine.State = TerminalSurfaceMachine.initialState
    private var focusState: TerminalFocusMachine.State = TerminalFocusMachine.initialState
    private let focusHost: (any TerminalFocusHost)?

    public init(focusHost: (any TerminalFocusHost)? = nil) {
        self.focusHost = focusHost
    }

    public func dispatchSession(_ event: TerminalSessionMachine.Event) -> [TerminalSessionMachine.Effect] {
        let transition = TerminalSessionMachine.reduce(state: sessionState, event: event)
        sessionState = transition.state
        return transition.effects
    }

    public func dispatchSurface(_ event: TerminalSurfaceMachine.Event) -> [TerminalSurfaceMachine.Effect] {
        let transition = TerminalSurfaceMachine.reduce(state: surfaceState, event: event)
        surfaceState = transition.state
        return transition.effects
    }

    public func dispatchFocus(_ event: TerminalFocusMachine.Event) -> TerminalFocusMachine.State {
        focusState = TerminalFocusMachine.reduce(state: focusState, event: event)
        return focusState
    }

    public func view(forSession sessionID: String) -> TerminalSessionMachine.View {
        TerminalSessionMachine.sessionView(sessionState, sessionID: sessionID)
    }

    public func currentSurfaces() -> TerminalSurfaceMachine.State {
        surfaceState
    }

    public func currentFocus() -> TerminalFocusMachine.State {
        focusState
    }

    /// Consumes a pending focus target if it matches `(session, id)` and delegates focus to `focusHost`.
    @discardableResult
    public func applyFocusIfRequested(session: String, id: String) async -> Bool {
        guard TerminalFocusMachine.isFocusRequested(focusState, session: session, id: id) else {
            return false
        }
        let focused = await focusHost?.focusTerminal(id: id) ?? true
        if focused {
            focusState = TerminalFocusMachine.reduce(state: focusState, event: .consumed(session: session, id: id))
        }
        return focused
    }
}
