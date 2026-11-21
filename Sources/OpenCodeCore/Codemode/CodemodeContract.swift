import OpenCodeSchema
import Synchronization

// The host-call contract the interpreter runs on (mirrors `psychoscript/src/runtime/contract.ts`).
// It knows nothing about Effect: a host function returns a value, a Promise, or `HostWork`, or throws.
// The Effect API (`CodemodeEffectHost.swift`, `CodemodeEffectWork.swift`) wraps its functions into this
// contract before the interpreter sees them.
extension CodemodeLanguage {
    /// A `DOMException`-style abort error thrown by the Promise-based API (`Runtime.execute`, `Program.run`)
    /// when a run's `AbortSignal` aborts. Its `name` is `"AbortError"` and `cause` is the signal's reason.
    public final class AbortError: Error, Sendable, CustomStringConvertible {
        public let name: String = "AbortError"
        public let message: String
        public let cause: (any Sendable)?

        public init(_ message: String = "The run was aborted.", cause: (any Sendable)? = nil) {
            self.message = message
            self.cause = cause
        }

        public var description: String { "\(name): \(message)" }
    }

    /// Cooperative cancellation signal passed to every host call (`call.signal`) and to `Runtime.execute` /
    /// `Program.run` via `RunOptions` / `ExecuteOptions`.
    public final class AbortSignal: Sendable {
        private struct State: Sendable {
            var aborted: Bool = false
            var reason: (any Sendable)? = nil
            var nextId: Int = 1
            var listeners: [Int: @Sendable () -> Void] = [:]
        }

        private let state: Mutex<State>

        public init(aborted: Bool = false, reason: (any Sendable)? = nil) {
            self.state = Mutex(State(aborted: aborted, reason: reason))
        }

        /// Returns an already-aborted signal with the given optional reason (like `AbortSignal.abort(reason)`).
        public static func abort(_ reason: (any Sendable)? = nil) -> AbortSignal {
            AbortSignal(aborted: true, reason: reason)
        }

        public var aborted: Bool {
            state.withLock { $0.aborted }
        }

        public var reason: (any Sendable)? {
            state.withLock { $0.reason }
        }

        /// Registers a callback invoked when the signal aborts. Returns a token for `removeEventListener`.
        /// If already aborted, does not queue; check `aborted` or use `onAbort(_:)` to fire immediately.
        @discardableResult
        public func addEventListener(_ listener: @escaping @Sendable () -> Void) -> Int {
            state.withLock { s in
                if s.aborted { return 0 }
                let id = s.nextId
                s.nextId += 1
                s.listeners[id] = listener
                return id
            }
        }

        /// Registers a callback invoked on abort, or immediately if already aborted.
        @discardableResult
        public func onAbort(_ listener: @escaping @Sendable () -> Void) -> Int {
            let (already, id) = state.withLock { s -> (Bool, Int) in
                if s.aborted { return (true, 0) }
                let id = s.nextId
                s.nextId += 1
                s.listeners[id] = listener
                return (false, id)
            }
            if already { listener() }
            return id
        }

        public func removeEventListener(_ id: Int) {
            guard id != 0 else { return }
            _ = state.withLock { $0.listeners.removeValue(forKey: id) }
        }

        /// Suspends until this signal aborts or the enclosing Swift task is cancelled.
        public func waitUntilAborted() async {
            if aborted || Task.isCancelled { return }
            final class Waiter: Sendable {
                private struct S: Sendable {
                    var done: Bool = false
                    var continuation: CheckedContinuation<Void, Never>? = nil
                    var listenerId: Int = 0
                }
                private let m = Mutex(S())
                func resume(signal: AbortSignal) {
                    let (cont, lid) = m.withLock { s -> (CheckedContinuation<Void, Never>?, Int) in
                        if s.done { return (nil, 0) }
                        s.done = true
                        let c = s.continuation
                        s.continuation = nil
                        let id = s.listenerId
                        s.listenerId = 0
                        return (c, id)
                    }
                    if lid != 0 { signal.removeEventListener(lid) }
                    cont?.resume()
                }
                func wait(on signal: AbortSignal) async {
                    let lid = signal.addEventListener { [weak self] in
                        self?.resume(signal: signal)
                    }
                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        let already = m.withLock { s -> Bool in
                            if s.done || signal.aborted || Task.isCancelled {
                                s.done = true
                                return true
                            }
                            s.continuation = cont
                            s.listenerId = lid
                            return false
                        }
                        if already {
                            if lid != 0 { signal.removeEventListener(lid) }
                            cont.resume()
                        }
                    }
                }
            }
            let waiter = Waiter()
            await withTaskCancellationHandler {
                await waiter.wait(on: self)
            } onCancel: {
                waiter.resume(signal: self)
            }
        }

        internal func triggerAbort(_ reason: (any Sendable)?) {
            let callbacks = state.withLock { s -> [@Sendable () -> Void] in
                if s.aborted { return [] }
                s.aborted = true
                s.reason = reason
                let list = Array(s.listeners.values)
                s.listeners.removeAll()
                return list
            }
            for cb in callbacks {
                cb()
            }
        }
    }

    /// Owner of an `AbortSignal`, aborting it once when `abort(_:)` is called.
    public final class AbortController: Sendable {
        public let signal: AbortSignal

        public init() {
            self.signal = AbortSignal()
        }

        public func abort(_ reason: (any Sendable)? = nil) {
            signal.triggerAbort(reason)
        }
    }

    /// What a host function (or plain host function) returned across the host boundary.
    public enum HostReturn: Sendable {
        /// A plain value crossing back into the program.
        case value(Value)
        /// Lazy host work started and awaited by the driver (`Contract.HostWork`).
        case work(Contract.HostWork)
        /// An Effect value returned by a host function or plain function (adapted by `EffectRuntime`).
        case effect(EffectTask<HostReturn>)
        /// A pending program promise produced by a synchronous host call.
        case promise(PromiseObj)
    }

    /// A plain host function placed among globals or inside a host function's result.
    /// Carries its own `name` and `length` and may return a value, Promise, `HostWork`, or `EffectTask`.
    public final class PlainHostFn: Sendable {
        public let name: String
        public let length: Int
        public let run: @Sendable ([Value], Builtins) async throws -> HostReturn

        public init(
            name: String = "",
            length: Int = 0,
            _ run: @escaping @Sendable ([Value], Builtins) async throws -> HostReturn
        ) {
            self.name = name
            self.length = max(0, length)
            self.run = run
        }
    }

    /// Value carrier for a plain host function embedded inside an object or array returned by a host function.
    /// When crossing back into the program, `adaptReturnedHostValues` wraps it with the run's `adapt` hook
    /// and preserves its `name` and `length`.
    public final class PlainHostFnObj: Obj, @unchecked Sendable {
        public let plainFn: PlainHostFn

        public init(proto: Obj?, plainFn: PlainHostFn) {
            self.plainFn = plainFn
            super.init(proto: proto)
        }
    }

    /// Thread-safe registry mapping a `PromiseObj`'s identity to the lazy `AbortController` of the sync
    /// host call that produced it (`src/runtime/contract.ts#promiseControllers`).
    public final class PromiseControllerRegistry: Sendable {
        private struct State: Sendable {
            var controllers: [ObjectIdentifier: @Sendable () -> AbortController?] = [:]
        }

        private let state = Mutex(State())

        public init() {}

        public func set(_ promise: PromiseObj, provider: @escaping @Sendable () -> AbortController?) {
            state.withLock { $0.controllers[ObjectIdentifier(promise)] = provider }
        }

        public func get(_ promise: PromiseObj) -> (@Sendable () -> AbortController?)? {
            state.withLock { $0.controllers[ObjectIdentifier(promise)] }
        }

        public func remove(_ promise: PromiseObj) {
            _ = state.withLock { $0.controllers.removeValue(forKey: ObjectIdentifier(promise)) }
        }
    }

    /// The Effect-free host-call contract (`psychoscript/src/runtime/contract.ts`).
    public enum Contract {
        /// What every call of a host function gets.
        // parity: psychoscript/src/runtime/contract.ts#Call [status=implemented hash=b44d896af6a7]
        public struct Call: Sendable {
            /// The call's key, `<runId>:<callId>`: the same across a suspended run's resumes.
            public let key: String
            /// Whether the run is being suspended: an interruption now detaches the call instead of ending it.
            public let suspending: @Sendable () -> Bool
            /// Aborted when the call is stopped: the run ended, was interrupted, or is being suspended.
            public let signal: AbortSignal
            /// The run's opaque context, as given to `execute`, `run`, or `resume`.
            public let context: (any Sendable)?

            public init(
                key: String,
                suspending: @escaping @Sendable () -> Bool = { false },
                signal: AbortSignal = AbortSignal(),
                context: (any Sendable)? = nil
            ) {
                self.key = key
                self.suspending = suspending
                self.signal = signal
                self.context = context
            }

            public var hostCall: Host.Call {
                Host.Call(key: key, suspending: suspending, signal: signal)
            }
        }

        /// What every call of a durable function gets: also the arguments it was called with, as they crossed.
        // parity: psychoscript/src/runtime/contract.ts#DurableCall [status=implemented hash=6a779cb9b1f9]
        public struct DurableCall: Sendable {
            public let key: String
            public let suspending: @Sendable () -> Bool
            public let signal: AbortSignal
            public let context: (any Sendable)?
            public let args: [Value]

            public init(
                key: String,
                args: [Value],
                suspending: @escaping @Sendable () -> Bool = { false },
                signal: AbortSignal = AbortSignal(),
                context: (any Sendable)? = nil
            ) {
                self.key = key
                self.args = args
                self.suspending = suspending
                self.signal = signal
                self.context = context
            }

            public var hostDurableCall: Host.DurableCall {
                Host.DurableCall(key: key, args: args, suspending: suspending, signal: signal)
            }
        }

        /// Lets a saved run keep the functions inside values a host function returned.
        // parity: psychoscript/src/runtime/contract.ts#Snapshot [status=implemented hash=d8607566a4b1]
        public struct Snapshot: Sendable {
            public let encode: @Sendable (Value) throws -> JSONValue
            public let decode: @Sendable (JSONValue) throws -> Value

            public init(
                encode: @escaping @Sendable (Value) throws -> JSONValue,
                decode: @escaping @Sendable (JSONValue) throws -> Value
            ) {
                self.encode = encode
                self.decode = decode
            }
        }

        /// How a call reaches the program (`sync`, `async`, or `sync-thenable`).
        // parity: psychoscript/src/runtime/contract.ts#Type [status=implemented hash=8aa5f1d97099]
        public enum CallType: String, Equatable, Hashable, Sendable, Codable {
            case sync
            case async
            case syncThenable = "sync-thenable"
        }

        /// How host work ended.
        // parity: psychoscript/src/runtime/contract.ts#Settled [status=implemented hash=cdaddeebf43b]
        public enum Settled: Sendable {
            case ok(HostReturn)
            case error(any Error)
        }

        /// Host work that starts only when the driver runs it, and that the run waits for when it stops it:
        /// `start` begins it with the run's context, calls `done` once (possibly at once) when it ends,
        /// and may return a function that asks it to stop.
        // parity: psychoscript/src/runtime/contract.ts#HostWork [status=implemented hash=d55a3cd00fa4]
        public final class HostWork: Sendable {
            public let start: @Sendable ((any Sendable)?, @escaping @Sendable (Settled) -> Void) -> (@Sendable () -> Void)?

            public init(
                _ start: @escaping @Sendable ((any Sendable)?, @escaping @Sendable (Settled) -> Void) -> (@Sendable () -> Void)?
            ) {
                self.start = start
            }

            /// Runs this `HostWork` to settlement under `context`, registering an optional stop callback with `signal`.
            /// When `signal` aborts, calls `stop()` and still awaits `done` so Effect finalizers (`onInterrupt`) finish.
            public func run(context: (any Sendable)?, signal: AbortSignal? = nil) async -> Settled {
                final class Gate: Sendable {
                    private struct State: Sendable {
                        var done: Bool = false
                        var continuation: CheckedContinuation<Settled, Never>? = nil
                        var stop: (@Sendable () -> Void)? = nil
                        var listenerId: Int = 0
                    }
                    private let state = Mutex(State())
                    func settle(_ result: Settled, signal: AbortSignal?) {
                        let (cont, listenerId) = state.withLock { s -> (CheckedContinuation<Settled, Never>?, Int) in
                            if s.done { return (nil, 0) }
                            s.done = true
                            let c = s.continuation
                            s.continuation = nil
                            let lid = s.listenerId
                            s.listenerId = 0
                            s.stop = nil
                            return (c, lid)
                        }
                        if listenerId != 0 { signal?.removeEventListener(listenerId) }
                        cont?.resume(returning: result)
                    }
                    func installContinuation(_ cont: CheckedContinuation<Settled, Never>) -> Bool {
                        state.withLock { s in
                            if s.done { return false }
                            s.continuation = cont
                            return true
                        }
                    }
                    func installStop(_ stop: (@Sendable () -> Void)?, signal: AbortSignal?) {
                        guard let stop else { return }
                        let lid = signal?.addEventListener { [weak self] in
                            self?.triggerStop()
                        } ?? 0
                        let (shouldStopNow, cleanupLid) = state.withLock { s -> (Bool, Int) in
                            if s.done { return (false, lid) }
                            if signal?.aborted == true { return (true, lid) }
                            s.stop = stop
                            s.listenerId = lid
                            return (false, 0)
                        }
                        if cleanupLid != 0 { signal?.removeEventListener(cleanupLid) }
                        if shouldStopNow { stop() }
                    }
                    func triggerStop() {
                        let stopFn = state.withLock { s -> (@Sendable () -> Void)? in
                            if s.done { return nil }
                            let fn = s.stop
                            s.stop = nil
                            return fn
                        }
                        stopFn?()
                    }
                }

                let gate = Gate()
                final class ImmediateBox: Sendable {
                    private struct S: Sendable { var value: Settled? = nil }
                    private let m = Mutex(S())
                    func set(_ v: Settled) { m.withLock { $0.value = v } }
                    func get() -> Settled? { m.withLock { $0.value } }
                }
                let immediate = ImmediateBox()

                return await withCheckedContinuation { continuation in
                    let installed = gate.installContinuation(continuation)
                    if !installed, let imm = immediate.get() {
                        continuation.resume(returning: imm)
                        return
                    }
                    let stop = start(context) { settled in
                        immediate.set(settled)
                        gate.settle(settled, signal: signal)
                    }
                    gate.installStop(stop, signal: signal)
                }
            }
        }

        /// The abort controller of the call that returned a Promise, for calls the VM makes before the driver
        /// adopts their work: the driver aborts it when it stops the call.
        // parity: psychoscript/src/runtime/contract.ts#promiseControllers [status=implemented hash=9c2c8740d3b7]
        public static let promiseControllers = PromiseControllerRegistry()

        /// A host failure that is a defect, not a failure the host meant: it gets the call's source location.
        // parity: psychoscript/src/runtime/contract.ts#HostDefect [status=implemented hash=1e9d07f49179]
        public final class HostDefect: Error, Sendable {
            public let error: any Error

            public init(_ error: any Error) {
                self.error = error
            }
        }

        /// Host work, or a run, that was interrupted.
        // parity: psychoscript/src/runtime/contract.ts#Interrupted [status=implemented hash=6943f659341f]
        public final class Interrupted: Error, Sendable, CustomStringConvertible {
            public let name: String = "Interrupted"
            public let message: String = "Interrupted"

            public init() {}

            public var description: String { message }
        }

        /// A host function; see `Host.fn` and `EffectHost.fn`.
        // parity: psychoscript/src/runtime/contract.ts#Fn [status=implemented hash=8aaa43043c43]
        public final class Fn: Sendable {
            public let run: @Sendable ([Value], Host.Call, Builtins) async throws -> Value
            /// Optional full contract invocation supporting `HostWork`, `Effect`, `PromiseObj`, and `Contract.Call.context`.
            public let runReturn: (@Sendable ([Value], Call, Builtins) async throws -> HostReturn)?
            public let type: CallType
            public let idempotent: Bool
            public let snapshot: Snapshot?
            public let constructible: Bool
            public let takesFunctions: Bool
            /// Own name of the underlying function (`source`), preserved across Effect/wrapper layers.
            public let sourceName: String?
            /// Own parameter count (`length`) of the underlying function (`source`).
            public let sourceLength: Int?
            /// True when wrapping a plain host function (so an empty `sourceName` stays `""` rather than taking the label suffix).
            public let isPlainSource: Bool

            public init(
                run: @escaping @Sendable ([Value], Host.Call, Builtins) async throws -> Value,
                type: CallType = .sync,
                idempotent: Bool = false,
                snapshot: Snapshot? = nil,
                constructible: Bool = false,
                takesFunctions: Bool = false,
                sourceName: String? = nil,
                sourceLength: Int? = nil,
                isPlainSource: Bool = false
            ) {
                self.run = run
                self.runReturn = nil
                self.type = type
                self.idempotent = idempotent
                self.snapshot = snapshot
                self.constructible = constructible
                self.takesFunctions = takesFunctions
                self.sourceName = sourceName
                self.sourceLength = sourceLength
                self.isPlainSource = isPlainSource
            }

            public init(
                runReturn: @escaping @Sendable ([Value], Call, Builtins) async throws -> HostReturn,
                type: CallType = .sync,
                idempotent: Bool = false,
                snapshot: Snapshot? = nil,
                constructible: Bool = false,
                takesFunctions: Bool = false,
                sourceName: String? = nil,
                sourceLength: Int? = nil,
                isPlainSource: Bool = false
            ) {
                self.runReturn = runReturn
                self.run = { args, hostCall, builtins in
                    let call = Call(key: hostCall.key, suspending: hostCall.suspending, signal: hostCall.signal)
                    switch try await runReturn(args, call, builtins) {
                    case .value(let v): return v
                    case .promise(let p): return .object(p)
                    case .work(let w):
                        switch await w.run(context: nil, signal: hostCall.signal) {
                        case .ok(.value(let v)): return v
                        case .ok(.promise(let p)): return .object(p)
                        case .ok: return .undefined
                        case .error(let err): throw err
                        }
                    case .effect(let eff):
                        let w = EffectWork.work(eff)
                        switch await w.run(context: nil, signal: hostCall.signal) {
                        case .ok(.value(let v)): return v
                        case .ok(.promise(let p)): return .object(p)
                        case .ok: return .undefined
                        case .error(let err): throw err
                        }
                    }
                }
                self.type = type
                self.idempotent = idempotent
                self.snapshot = snapshot
                self.constructible = constructible
                self.takesFunctions = takesFunctions
                self.sourceName = sourceName
                self.sourceLength = sourceLength
                self.isPlainSource = isPlainSource
            }
        }

        /// A host function whose work keeps running across a suspend; see `Host.durableFn`.
        // parity: psychoscript/src/runtime/contract.ts#DurableFn [status=implemented hash=776878a8681f]
        public final class DurableFn: Sendable {
            public let start: @Sendable ([Value], Host.Call) async throws -> JSONValue
            public let wait: @Sendable (JSONValue, Host.DurableCall, Builtins) async throws -> Value
            public let cancel: @Sendable (JSONValue, Host.DurableCall) async throws -> Void
            /// Optional full contract hooks returning `HostWork` (used by `EffectHost.durableFn`).
            public let startWork: (@Sendable ([Value], Call) -> HostWork)?
            public let waitWork: (@Sendable (JSONValue, DurableCall, Builtins) -> HostWork)?
            public let cancelWork: (@Sendable (JSONValue, DurableCall) -> HostWork)?

            public init(
                start: @escaping @Sendable ([Value], Host.Call) async throws -> JSONValue,
                wait: @escaping @Sendable (JSONValue, Host.DurableCall, Builtins) async throws -> Value,
                cancel: @escaping @Sendable (JSONValue, Host.DurableCall) async throws -> Void
            ) {
                self.start = start
                self.wait = wait
                self.cancel = cancel
                self.startWork = nil
                self.waitWork = nil
                self.cancelWork = nil
            }

            public init(
                startWork: @escaping @Sendable ([Value], Call) -> HostWork,
                waitWork: @escaping @Sendable (JSONValue, DurableCall, Builtins) -> HostWork,
                cancelWork: @escaping @Sendable (JSONValue, DurableCall) -> HostWork
            ) {
                self.startWork = startWork
                self.waitWork = waitWork
                self.cancelWork = cancelWork
                self.start = { args, call in
                    let w = startWork(args, Call(key: call.key, suspending: call.suspending, signal: call.signal))
                    switch await w.run(context: nil, signal: call.signal) {
                    case .ok(.value(let v)): return (try? CodemodeLanguage.toJsonValue(v, dropFunctions: true)) ?? .null
                    case .ok: return .null
                    case .error(let err): throw err
                    }
                }
                self.wait = { data, call, builtins in
                    let w = waitWork(data, DurableCall(key: call.key, args: call.args, suspending: call.suspending, signal: call.signal), builtins)
                    switch await w.run(context: nil, signal: call.signal) {
                    case .ok(.value(let v)): return v
                    case .ok(.promise(let p)): return .object(p)
                    case .ok: return .undefined
                    case .error(let err): throw err
                    }
                }
                self.cancel = { data, call in
                    let w = cancelWork(data, DurableCall(key: call.key, args: call.args, suspending: call.suspending, signal: call.signal))
                    _ = await w.run(context: nil, signal: call.signal)
                }
            }
        }

        /// A lazy object of host functions, addressed by path; see `Host.namespace`.
        // parity: psychoscript/src/runtime/contract.ts#Namespace [status=implemented hash=d6d3cc3d2e47]
        public final class Namespace: Sendable {
            public let keys: @Sendable ([String]) throws -> [String]
            public let resolve: @Sendable ([String]) -> Host.ResolvedTarget

            public init(
                keys: @escaping @Sendable ([String]) throws -> [String],
                resolve: @escaping @Sendable ([String]) -> Host.ResolvedTarget
            ) {
                self.keys = keys
                self.resolve = resolve
            }
        }
    }
}
