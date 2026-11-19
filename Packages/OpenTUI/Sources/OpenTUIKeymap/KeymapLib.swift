// Pure Swift 6 port of keymap/src/lib/emitter.ts, keymap/src/lib/registry.ts,
// and keymap/src/lib/runtime-utils.ts.

// MARK: - Typed Event Emitter (lib/emitter.ts)

// parity: keymap/src/lib/emitter.ts#EmitterListener [status=implemented hash=343a9811ba6e]
public typealias EmitterListener<Value: Sendable> = @Sendable (Value) throws -> Void

/// Opaque handle returned when subscribing to an `Emitter`, allowing explicit removal via `off`.
public struct EmitterListenerToken: Equatable, Hashable, Sendable {
    public let id: Int

    public init(id: Int) {
        self.id = id
    }
}

/// Copy-on-write typed event emitter supporting `hook`, `on`, `once`, `has`, `off`, `clear`,
/// `emit`, and `listenerCount`.
// parity: keymap/src/lib/emitter.ts#Emitter [status=implemented hash=3b0504b10821]
public final class Emitter<EventName: Hashable & Sendable, Value: Sendable>: @unchecked Sendable {
    private struct Subscription: Sendable {
        let token: EmitterListenerToken
        let listener: EmitterListener<Value>
        let once: Bool
    }

    private var listeners: [EventName: [Subscription]] = [:]
    private var nextTokenID: Int = 0
    private let onError: @Sendable (EventName, any Error) -> Void

    public init(onError: @escaping @Sendable (EventName, any Error) -> Void = { _, _ in }) {
        self.onError = onError
    }

    /// Registers a listener for `name` and returns a disposer closure (matching upstream `hook`).
    // parity: keymap/src/lib/emitter.ts#Emitter.hook [status=implemented hash=8aaece526eb0]
    @discardableResult
    public func hook(_ name: EventName, _ listener: @escaping EmitterListener<Value>) -> @Sendable () -> Void {
        let token = addSubscription(name, listener: listener, once: false)
        return { [weak self] in
            self?.off(name, token: token)
        }
    }

    /// Registers a listener for `name` and returns both a token and disposer.
    @discardableResult
    public func on(_ name: EventName, _ listener: @escaping EmitterListener<Value>) -> EmitterListenerToken {
        addSubscription(name, listener: listener, once: false)
    }

    /// Registers a one-shot listener that automatically unsubscribes on its first emission.
    @discardableResult
    public func once(_ name: EventName, _ listener: @escaping EmitterListener<Value>) -> @Sendable () -> Void {
        let token = addSubscription(name, listener: listener, once: true)
        return { [weak self] in
            self?.off(name, token: token)
        }
    }

    /// Returns `true` when at least one listener is registered for `name`.
    // parity: keymap/src/lib/emitter.ts#Emitter.has [status=implemented hash=852ab678e0af]
    public func has(_ name: EventName) -> Bool {
        guard let current = listeners[name] else {
            return false
        }
        return !current.isEmpty
    }

    /// Returns the number of active listeners for `name`.
    public func listenerCount(_ name: EventName) -> Int {
        listeners[name]?.count ?? 0
    }

    /// Removes the subscription identified by `token` for `name`.
    // parity: keymap/src/lib/emitter.ts#Emitter.off [status=implemented hash=07a848295f71]
    public func off(_ name: EventName, token: EmitterListenerToken) {
        guard let current = listeners[name], !current.isEmpty else {
            return
        }
        let next = current.filter { $0.token != token }
        if next.count == current.count {
            return
        }
        if next.isEmpty {
            listeners.removeValue(forKey: name)
        } else {
            listeners[name] = next
        }
    }

    /// Removes all listeners for all events.
    // parity: keymap/src/lib/emitter.ts#Emitter.clear [status=implemented hash=a5722019b535]
    public func clear() {
        listeners.removeAll()
    }

    /// Dispatches `value` to a copy-on-write snapshot of listeners registered for `name`.
    // parity: keymap/src/lib/emitter.ts#Emitter.emit [status=implemented hash=005176f04819]
    public func emit(_ name: EventName, _ value: Value) {
        guard let snapshot = listeners[name], !snapshot.isEmpty else {
            return
        }

        for subscription in snapshot {
            if subscription.once {
                off(name, token: subscription.token)
            }
            do {
                try subscription.listener(value)
            } catch {
                onError(name, error)
            }
        }
    }

    public func emit(_ name: EventName) where Value == Void {
        emit(name, ())
    }

    private func addSubscription(
        _ name: EventName,
        listener: @escaping EmitterListener<Value>,
        once: Bool
    ) -> EmitterListenerToken {
        let token = EmitterListenerToken(id: nextTokenID)
        nextTokenID += 1
        var updated = listeners[name] ?? []
        updated.append(Subscription(token: token, listener: listener, once: once))
        listeners[name] = updated
        return token
    }
}

// MARK: - Ordered & Priority Registries (lib/registry.ts)

/// Immutable priority-ordered registration record carrying its insertion `order` for stable tie-breaking.
// parity: keymap/src/lib/registry.ts#PriorityRegistration [status=implemented hash=2ac50621d3b3]
public struct PriorityRegistration<Listener: Sendable, Meta: Sendable>: Sendable {
    public let priority: Int
    public let order: Int
    public let listener: Listener
    public let meta: Meta

    public init(priority: Int, order: Int, listener: Listener, meta: Meta) {
        self.priority = priority
        self.order = order
        self.listener = listener
        self.meta = meta
    }
}

// parity: keymap/src/lib/registry.ts#OrderedRegistry [status=implemented hash=7714e379c8a6]
public extension OrderedRegistry {
    /// Appends every element of `items` in order and returns a disposer removing them.
    // parity: keymap/src/lib/registry.ts#OrderedRegistry.append [status=implemented hash=fd6bc7767285]
    @discardableResult
    func append(contentsOf items: [T]) -> @Sendable () -> Void {
        let disposers = items.map { append($0) }
        return {
            for off in disposers {
                off()
            }
        }
    }

    /// Prepends `items` while preserving their relative order and returns a disposer removing them.
    // parity: keymap/src/lib/registry.ts#OrderedRegistry.prepend [status=implemented hash=9ee9c359be4f]
    @discardableResult
    func prepend(contentsOf items: [T]) -> @Sendable () -> Void {
        let disposers = items.reversed().map { prepend($0) }
        return {
            for off in disposers {
                off()
            }
        }
    }

    /// Removes all occurrences equal to `value`, returning `true` if any item was removed.
    // parity: keymap/src/lib/registry.ts#OrderedRegistry.remove [status=implemented hash=36ad32c61ae9]
    @discardableResult
    func remove(_ value: T) -> Bool where T: Equatable {
        let current = values()
        let filtered = current.filter { $0 != value }
        if filtered.count == current.count {
            return false
        }
        clear()
        for item in filtered {
            _ = append(item)
        }
        return true
    }

    /// Returns a snapshot of registered values matching `predicate`.
    // parity: keymap/src/lib/registry.ts#OrderedRegistry.values [status=implemented hash=3c5ff43ce2e2]
    func values(where predicate: (T) -> Bool) -> [T] {
        values().filter(predicate)
    }
}

// parity: keymap/src/lib/registry.ts#PriorityRegistry [status=implemented hash=a57cb6b10e1e]
public extension PriorityRegistry {
    /// Returns `true` when at least one listener is registered.
    func has() -> Bool {
        !isEmpty
    }

    /// Returns priority-sorted `PriorityRegistration` snapshots.
    func registrations() -> [PriorityRegistration<Listener, Meta>] {
        entries().map { entry in
            PriorityRegistration(
                priority: entry.priority,
                order: entry.id,
                listener: entry.listener,
                meta: entry.meta
            )
        }
    }

    /// Convenience registration overload for registries with `Void` metadata.
    @discardableResult
    func register(_ listener: Listener, priority: Int = 0) -> @Sendable () -> Void where Meta == Void {
        register(listener, priority: priority, meta: ())
    }
}

// MARK: - Runtime Emitter & Registry Helpers (lib/runtime-utils.ts)

// parity: keymap/src/lib/runtime-utils.ts#RuntimeEmitterListener [status=implemented hash=deb175f1f837]
public typealias RuntimeEmitterListener<Value: Sendable> = EmitterListener<Value>

// parity: keymap/src/lib/runtime-utils.ts#RuntimeEmitter [status=implemented hash=4adf49270c9b]
public protocol RuntimeEmitter<EventName, Value>: AnyObject, Sendable {
    associatedtype EventName: Hashable & Sendable
    associatedtype Value: Sendable

    @discardableResult
    func hook(_ name: EventName, _ listener: @escaping RuntimeEmitterListener<Value>) -> @Sendable () -> Void
    func has(_ name: EventName) -> Bool
    func emit(_ name: EventName, _ value: Value)
}

extension Emitter: RuntimeEmitter {}

// parity: keymap/src/lib/runtime-utils.ts#createRuntimeEmitter [status=implemented hash=783eef621b47]
public func createRuntimeEmitter<EventName: Hashable & Sendable, Value: Sendable>(
    onError: @escaping @Sendable (EventName, any Error) -> Void = { _, _ in }
) -> Emitter<EventName, Value> {
    Emitter(onError: onError)
}

// parity: keymap/src/lib/runtime-utils.ts#RuntimePriorityRegistration [status=implemented hash=d9f934d8ab10]
public typealias RuntimePriorityRegistration<Listener: Sendable, Meta: Sendable> = PriorityRegistration<Listener, Meta>

// parity: keymap/src/lib/runtime-utils.ts#RuntimeOrderedRegistry [status=implemented hash=ed69d2c4928c]
public protocol RuntimeOrderedRegistry<Value>: AnyObject, Sendable {
    associatedtype Value: Sendable

    @discardableResult
    func append(_ value: Value) -> @Sendable () -> Void
    @discardableResult
    func prepend(_ value: Value) -> @Sendable () -> Void
    func values() -> [Value]
    func has() -> Bool
    func clear()
}

extension OrderedRegistry: RuntimeOrderedRegistry {
    public typealias Value = T
}

// parity: keymap/src/lib/runtime-utils.ts#RuntimePriorityRegistry [status=implemented hash=e55a4be21cf0]
public protocol RuntimePriorityRegistry<Listener, Meta>: AnyObject, Sendable {
    associatedtype Listener: Sendable
    associatedtype Meta: Sendable

    @discardableResult
    func register(_ listener: Listener, priority: Int, meta: Meta) -> @Sendable () -> Void
    func registrations() -> [RuntimePriorityRegistration<Listener, Meta>]
    func has() -> Bool
    func clear()
}

extension PriorityRegistry: RuntimePriorityRegistry {}

// parity: keymap/src/lib/runtime-utils.ts#createRuntimeOrderedRegistry [status=implemented hash=ba3c5686714b]
public func createRuntimeOrderedRegistry<Value: Sendable>(
    _ initial: [Value] = []
) -> OrderedRegistry<Value> {
    OrderedRegistry(initial)
}

// parity: keymap/src/lib/runtime-utils.ts#createRuntimePriorityRegistry [status=implemented hash=5031a636d0f2]
public func createRuntimePriorityRegistry<Listener: Sendable, Meta: Sendable>() -> PriorityRegistry<Listener, Meta> {
    PriorityRegistry()
}
