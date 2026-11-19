// Pure Swift 6 port of keymap/src/services/dispatch-decisions.ts and dispatch-patterns.ts.

// MARK: - Pure-Swift Abort Signal / Controller

/// Lightweight pure-Swift abort signal matching the Web `AbortSignal` contract used by deferred disambiguation.
public final class KeymapAbortSignal: @unchecked Sendable {
    public private(set) var isAborted: Bool = false
    private var nextListenerID: Int = 0
    private var listeners: [(id: Int, callback: @Sendable () -> Void)] = []

    internal init() {}

    @discardableResult
    public func addAbortListener(_ listener: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        if isAborted {
            listener()
            return {}
        }
        let id = nextListenerID
        nextListenerID += 1
        listeners.append((id: id, callback: listener))
        return { [weak self] in
            self?.removeAbortListener(id: id)
        }
    }

    private func removeAbortListener(id: Int) {
        listeners.removeAll { $0.id == id }
    }

    internal func triggerAbort() {
        if isAborted {
            return
        }
        isAborted = true
        let pending = listeners
        listeners.removeAll()
        for entry in pending {
            entry.callback()
        }
    }
}

/// Controller paired with a `KeymapAbortSignal`.
public final class KeymapAbortController: @unchecked Sendable {
    public let signal: KeymapAbortSignal

    public init() {
        self.signal = KeymapAbortSignal()
    }

    public func abort() {
        signal.triggerAbort()
    }
}

// MARK: - Dispatch Disambiguation Decisions (dispatch-decisions.ts)

// parity: keymap/src/services/dispatch-decisions.ts#SyncDecisionAction [status=implemented hash=00837a1ea032]
public enum SyncDecisionAction: String, Equatable, Hashable, Sendable {
    case runExact = "run-exact"
    case continueSequence = "continue-sequence"
    case clear = "clear"
    case `defer` = "defer"
}

// parity: keymap/src/services/dispatch-decisions.ts#DeferredDecisionAction [status=implemented hash=8ff3f3944847]
public enum DeferredDecisionAction: String, Equatable, Hashable, Sendable {
    case runExact = "run-exact"
    case continueSequence = "continue-sequence"
    case clear = "clear"
}

/// Marker protocol matching upstream `KEY_DISAMBIGUATION_DECISION` brand.
public protocol KeyDisambiguationDecision: Sendable {
    var action: SyncDecisionAction { get }
}

/// Marker protocol matching upstream `KEY_DEFERRED_DISAMBIGUATION_DECISION` brand.
public protocol KeyDeferredDisambiguationDecision: Sendable {
    var action: DeferredDecisionAction { get }
}

public struct KeyDeferredDisambiguationContext: Sendable {
    public let signal: KeymapAbortSignal
    public let sequence: [KeySequencePart]
    public let focused: (any Hashable & Sendable)?

    public init(
        signal: KeymapAbortSignal,
        sequence: [KeySequencePart],
        focused: (any Hashable & Sendable)? = nil
    ) {
        self.signal = signal
        self.sequence = sequence
        self.focused = focused
    }

    public func sleep(_ ms: Int) async -> Bool {
        await sleepWithSignal(ms, signal: signal)
    }

    public func runExact() -> InternalDeferredDisambiguationDecision {
        createDeferredDecision(.runExact)
    }

    public func continueSequence() -> InternalDeferredDisambiguationDecision {
        createDeferredDecision(.continueSequence)
    }

    public func clear() -> InternalDeferredDisambiguationDecision {
        createDeferredDecision(.clear)
    }
}

public typealias KeyDeferredDisambiguationHandler =
    @Sendable (KeyDeferredDisambiguationContext) async -> InternalDeferredDisambiguationDecision?

// parity: keymap/src/services/dispatch-decisions.ts#InternalDisambiguationDecision [status=implemented hash=87d5920bd6ac]
public struct InternalDisambiguationDecision: KeyDisambiguationDecision, Sendable {
    public let action: SyncDecisionAction
    public let handler: KeyDeferredDisambiguationHandler?

    public init(action: SyncDecisionAction, handler: KeyDeferredDisambiguationHandler? = nil) {
        self.action = action
        self.handler = handler
    }
}

// parity: keymap/src/services/dispatch-decisions.ts#InternalDeferredDisambiguationDecision [status=implemented hash=4cdab1cdfc32]
public struct InternalDeferredDisambiguationDecision: KeyDeferredDisambiguationDecision, Equatable, Hashable, Sendable {
    public let action: DeferredDecisionAction

    public init(action: DeferredDecisionAction) {
        self.action = action
    }
}

// parity: keymap/src/services/dispatch-decisions.ts#PendingDisambiguation [status=implemented hash=8fb10d090be9]
public struct PendingDisambiguation<Target: Hashable & Sendable, Event: KeymapEvent>: Sendable {
    public let id: Int
    public let controller: KeymapAbortController
    public let captures: [PendingSequenceCapture<Target, Event>]
    public let apply: @Sendable (InternalDeferredDisambiguationDecision?) -> Void

    public init(
        id: Int,
        controller: KeymapAbortController,
        captures: [PendingSequenceCapture<Target, Event>],
        apply: @escaping @Sendable (InternalDeferredDisambiguationDecision?) -> Void
    ) {
        self.id = id
        self.controller = controller
        self.captures = captures
        self.apply = apply
    }
}

// parity: keymap/src/services/dispatch-decisions.ts#createSyncDecision [status=implemented hash=98b95d176321]
public func createSyncDecision(
    _ action: SyncDecisionAction,
    handler: KeyDeferredDisambiguationHandler? = nil
) -> InternalDisambiguationDecision {
    InternalDisambiguationDecision(action: action, handler: handler)
}

// parity: keymap/src/services/dispatch-decisions.ts#createDeferredDecision [status=implemented hash=d98519c50a73]
public func createDeferredDecision(
    _ action: DeferredDecisionAction
) -> InternalDeferredDisambiguationDecision {
    InternalDeferredDisambiguationDecision(action: action)
}

// parity: keymap/src/services/dispatch-decisions.ts#isSyncDecision [status=implemented hash=6b0fe8422513]
public func isSyncDecision(_ value: Any?) -> Bool {
    value is any KeyDisambiguationDecision
}

// parity: keymap/src/services/dispatch-decisions.ts#isDeferredDecision [status=implemented hash=1a6d8ea06b5c]
public func isDeferredDecision(_ value: Any?) -> Bool {
    value is any KeyDeferredDisambiguationDecision
}

// parity: keymap/src/services/dispatch-decisions.ts#sleepWithSignal [status=implemented hash=c5fb60d7599f]
public func sleepWithSignal(_ ms: Int, signal: KeymapAbortSignal) async -> Bool {
    if signal.isAborted {
        return false
    }

    let delay = max(0, ms)
    let sleeper = Task<Bool, Never> {
        do {
            try await Task.sleep(for: .milliseconds(delay))
            return true
        } catch {
            return false
        }
    }

    let unsubscribe = signal.addAbortListener {
        sleeper.cancel()
    }
    defer {
        unsubscribe()
    }

    let completed = await sleeper.value
    return completed && !signal.isAborted
}

// MARK: - Dispatch Sequence Pattern Helpers (dispatch-patterns.ts)

// parity: keymap/src/services/dispatch-patterns.ts#matchSequencePattern [status=implemented hash=4ddc9f835117]
public func matchSequencePattern<Event: KeymapEvent>(
    patterns: [String: ResolvedSequencePattern<Event>],
    notify: KeymapNotifier,
    patternName: String,
    event: Event
) -> SequencePatternMatch? {
    guard let pattern = patterns[patternName] else {
        return nil
    }

    do {
        return try pattern.matcher(event)
    } catch {
        notify.emitError(
            "sequence-pattern-match-error",
            error: error,
            message: "[Keymap] Error matching sequence pattern \"\(pattern.name)\":"
        )
        return nil
    }
}

// parity: keymap/src/services/dispatch-patterns.ts#createPatternEventPart [status=implemented hash=462906ac47f6]
public func createPatternEventPart<Event: KeymapEvent>(
    patterns: [String: ResolvedSequencePattern<Event>],
    event: Event,
    patternName: String,
    match: SequencePatternMatch
) throws(KeymapError) -> KeySequencePart {
    let pattern = patterns[patternName]
    let payloadKey = pattern?.payloadKey ?? patternName
    let display = match.display ?? match.value?.stringDescription ?? event.name
    let part = try createKeySequencePart(
        KeyStrokeInput(
            name: event.name,
            ctrl: event.ctrl,
            shift: event.shift,
            meta: event.meta,
            super: event.`super` ?? false,
            hyper: event.hyper == true ? true : nil
        ),
        display: display
    )

    return KeySequencePart(
        stroke: part.stroke,
        display: part.display,
        match: part.match,
        tokenName: part.tokenName,
        patternName: patternName,
        payloadKey: payloadKey
    )
}

// parity: keymap/src/services/dispatch-patterns.ts#createSequencePayload [status=implemented hash=a6f19aa432ed]
public func createSequencePayload<Target: Hashable & Sendable, Event: KeymapEvent>(
    patterns: [String: ResolvedSequencePattern<Event>],
    notify: KeymapNotifier,
    capture: PendingSequenceCapture<Target, Event>?
) -> KeymapValue? {
    guard let capturedPatterns = capture?.patterns, !capturedPatterns.isEmpty else {
        return nil
    }

    var payload: [String: KeymapValue] = [:]
    var hasPayload = false

    for captured in capturedPatterns {
        let pattern = patterns[captured.name]
        let value: KeymapValue

        do {
            if let finalize = pattern?.finalize {
                value = try finalize(captured.values)
            } else if captured.values.count == 1 {
                value = captured.values[0]
            } else {
                value = .array(captured.values)
            }
        } catch {
            notify.emitError(
                "sequence-pattern-finalize-error",
                error: error,
                message: "[Keymap] Error finalizing sequence pattern \"\(captured.name)\":"
            )
            continue
        }

        if let existing = payload[captured.payloadKey] {
            if case .array(var items) = existing {
                items.append(value)
                payload[captured.payloadKey] = .array(items)
            } else {
                payload[captured.payloadKey] = .array([existing, value])
            }
        } else {
            payload[captured.payloadKey] = value
            hasPayload = true
        }
    }

    return hasPayload ? .object(payload) : nil
}
