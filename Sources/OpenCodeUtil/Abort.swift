import Synchronization

/// Shared sentinel error matching upstream `util/src/abort.ts`'s pre-allocated `DOMException("AbortError")`.
public struct AbortError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
    public let name: String
    public let message: String

    public init(message: String = "signal is aborted without reason", name: String = "AbortError") {
        self.name = name
        self.message = message
    }

    public var description: String { "\(name): \(message)" }

    /// Single shared abort reason instance so repeated aborts do not allocate new error payloads.
    public static let sharedReason = AbortError()
}

/// Thread-safe, pure-Swift cancellation signal mirroring the Web / Node `AbortSignal` contract.
public final class AbortSignal: Sendable {
    private struct State: Sendable {
        var aborted: Bool = false
        var reason: (any Error & Sendable)? = nil
        var nextID: UInt64 = 1
        var listeners: [UInt64: @Sendable () -> Void] = [:]
    }

    private let state = Mutex(State())

    internal init() {}

    /// Creates an already-aborted signal with the provided reason.
    public static func aborted(reason: any Error & Sendable = AbortError.sharedReason) -> AbortSignal {
        let signal = AbortSignal()
        signal.trigger(reason: reason)
        return signal
    }

    public var isAborted: Bool {
        state.withLock { $0.aborted }
    }

    public var reason: (any Error & Sendable)? {
        state.withLock { $0.reason }
    }

    /// Registers a listener fired once when the signal aborts. Returns a removal token.
    /// If the signal is already aborted, the listener is invoked immediately.
    @discardableResult
    public func onAbort(_ listener: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        let registration: (alreadyAborted: Bool, id: UInt64) = state.withLock { s in
            if s.aborted {
                return (true, 0)
            }
            let id = s.nextID
            s.nextID += 1
            s.listeners[id] = listener
            return (false, id)
        }
        if registration.alreadyAborted {
            listener()
            return {}
        }
        let id = registration.id
        return { [weak self] in
            self?.state.withLock { _ = $0.listeners.removeValue(forKey: id) }
        }
    }

    internal func trigger(reason: any Error & Sendable) {
        let callbacks: [@Sendable () -> Void] = state.withLock { s in
            if s.aborted { return [] }
            s.aborted = true
            s.reason = reason
            let ordered = s.listeners.sorted { $0.key < $1.key }.map(\.value)
            s.listeners.removeAll()
            return ordered
        }
        for callback in callbacks {
            callback()
        }
    }
}

/// Thread-safe, pure-Swift cancellation controller mirroring the Web / Node `AbortController` contract.
public final class AbortController: Sendable {
    public let signal: AbortSignal

    public init() {
        self.signal = AbortSignal()
    }

    public func abort(reason: any Error & Sendable = AbortError.sharedReason) {
        signal.trigger(reason: reason)
    }
}

/// Aborts `controller` using the shared pre-allocated `AbortError` reason.
// parity: util/src/abort.ts#abort [status=implemented hash=683b597a1861]
public func abort(_ controller: AbortController?) {
    controller?.abort(reason: AbortError.sharedReason)
}
