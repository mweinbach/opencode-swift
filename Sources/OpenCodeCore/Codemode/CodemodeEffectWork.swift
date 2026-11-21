import OpenCodeSchema
import Synchronization

// Effect work bridge for the optional `psychoscript/effect` API (mirrors `psychoscript/src/effect/work.ts`).
extension CodemodeLanguage {
    /// Typed key identifying a service stored in `EffectServices` (analogous to Effect's `Context.Service`).
    public struct EffectServiceKey<Service: Sendable>: Hashable, Sendable {
        public let id: String

        public init(_ id: String) {
            self.id = id
        }
    }

    /// Immutable service context passed into `EffectRuntime` runs (analogous to Effect's `Context.Context<R>`),
    /// carrying typed host services plus current span name and log annotations.
    public struct EffectServices: Sendable {
        private var storage: [String: any Sendable]
        public var spanName: String?
        public var logAnnotations: [String: JSONValue]

        public init(
            spanName: String? = nil,
            logAnnotations: [String: JSONValue] = [:]
        ) {
            self.storage = [:]
            self.spanName = spanName
            self.logAnnotations = logAnnotations
        }

        public static let empty = EffectServices()

        public func providing<S: Sendable>(_ key: EffectServiceKey<S>, _ value: S) -> EffectServices {
            var copy = self
            copy.storage[key.id] = value
            return copy
        }

        public func get<S: Sendable>(_ key: EffectServiceKey<S>) -> S? {
            storage[key.id] as? S
        }

        public func withSpan(_ name: String) -> EffectServices {
            var copy = self
            copy.spanName = name
            return copy
        }

        public func annotatingLog(_ key: String, _ value: JSONValue) -> EffectServices {
            var copy = self
            copy.logAnnotations[key] = value
            return copy
        }
    }

    /// Outcome of running an `EffectTask` (mirrors Effect's `Exit` / `Cause` distinctions).
    public enum EffectExit<A: Sendable>: Sendable {
        case success(A)
        /// Typed failure (`Effect.fail(...)`): preserves `HostFailure` or maps to `ExecutionFailure` without a call site.
        case fail(any Error)
        /// Defect (`Effect.die(...)` or thrown inside `Effect.sync`): wrapped in `HostDefect` so the call site attaches.
        case die(any Error)
        /// Interruption (`Effect.interrupt` or fiber cancellation): wrapped in `Contract.Interrupted`.
        case interrupt
    }

    /// Composable lazy Effect value for the `psychoscript/effect` API (`EffectHost` / `EffectRuntime`).
    public struct EffectTask<A: Sendable>: Sendable {
        private let execute: @Sendable (EffectServices, AbortSignal) async -> EffectExit<A>

        public init(_ execute: @escaping @Sendable (EffectServices, AbortSignal) async -> EffectExit<A>) {
            self.execute = execute
        }

        public static func succeed(_ value: A) -> EffectTask<A> {
            EffectTask { _, _ in .success(value) }
        }

        public static func fail(_ error: any Error) -> EffectTask<A> {
            EffectTask { _, _ in .fail(error) }
        }

        public static func die(_ error: any Error) -> EffectTask<A> {
            EffectTask { _, _ in .die(error) }
        }

        public static var interrupt: EffectTask<A> {
            EffectTask { _, _ in .interrupt }
        }

        /// Never completes until its `AbortSignal` aborts, then exits with `.interrupt`.
        public static var never: EffectTask<A> {
            EffectTask { _, signal in
                await signal.waitUntilAborted()
                return .interrupt
            }
        }

        /// Synchronous thunk: any thrown error becomes a defect (`.die`), matching `Effect.sync`.
        public static func sync(_ body: @escaping @Sendable () throws -> A) -> EffectTask<A> {
            EffectTask { _, signal in
                if signal.aborted { return .interrupt }
                do {
                    return .success(try body())
                } catch {
                    return .die(error)
                }
            }
        }

        /// Deferred Effect construction (`Effect.suspend`): a synchronous throw becomes a defect.
        public static func suspend(_ body: @escaping @Sendable () throws -> EffectTask<A>) -> EffectTask<A> {
            EffectTask { services, signal in
                if signal.aborted { return .interrupt }
                do {
                    let inner = try body()
                    return await inner.runExit(services: services, signal: signal)
                } catch {
                    return .die(error)
                }
            }
        }

        /// Reads a service from `EffectServices` and computes a result.
        public static func service<S: Sendable>(
            _ key: EffectServiceKey<S>,
            _ body: @escaping @Sendable (S) throws -> A
        ) -> EffectTask<A> {
            EffectTask { services, signal in
                if signal.aborted { return .interrupt }
                guard let svc = services.get(key) else {
                    return .die(HostFailure(kind: "ExecutionFailure", message: "Service not found: \(key.id)"))
                }
                do {
                    return .success(try body(svc))
                } catch {
                    return .die(error)
                }
            }
        }

        /// Reads the full `EffectServices` (including span name and log annotations).
        public static func withServices(_ body: @escaping @Sendable (EffectServices) async -> EffectExit<A>) -> EffectTask<A> {
            EffectTask { services, signal in
                if signal.aborted { return .interrupt }
                return await body(services)
            }
        }

        public func map<B: Sendable>(_ transform: @escaping @Sendable (A) -> B) -> EffectTask<B> {
            let base = self.execute
            return EffectTask<B> { services, signal in
                switch await base(services, signal) {
                case .success(let a): return .success(transform(a))
                case .fail(let e): return .fail(e)
                case .die(let e): return .die(e)
                case .interrupt: return .interrupt
                }
            }
        }

        public func flatMap<B: Sendable>(_ transform: @escaping @Sendable (A) -> EffectTask<B>) -> EffectTask<B> {
            let base = self.execute
            return EffectTask<B> { services, signal in
                switch await base(services, signal) {
                case .success(let a):
                    if signal.aborted { return .interrupt }
                    return await transform(a).runExit(services: services, signal: signal)
                case .fail(let e): return .fail(e)
                case .die(let e): return .die(e)
                case .interrupt: return .interrupt
                }
            }
        }

        /// Registers cleanup that runs when this Effect exits with `.interrupt`.
        public func onInterrupt(_ cleanup: @escaping @Sendable () async -> Void) -> EffectTask<A> {
            let base = self.execute
            return EffectTask { services, signal in
                let exit = await base(services, signal)
                if case .interrupt = exit {
                    await cleanup()
                }
                return exit
            }
        }

        public func provideService<S: Sendable>(_ key: EffectServiceKey<S>, _ value: S) -> EffectTask<A> {
            let base = self.execute
            return EffectTask { services, signal in
                await base(services.providing(key, value), signal)
            }
        }

        public func provideServices(_ provided: EffectServices) -> EffectTask<A> {
            let base = self.execute
            return EffectTask { _, signal in
                await base(provided, signal)
            }
        }

        public func withSpan(_ name: String) -> EffectTask<A> {
            let base = self.execute
            return EffectTask { services, signal in
                await base(services.withSpan(name), signal)
            }
        }

        public func annotateLog(_ key: String, _ value: JSONValue) -> EffectTask<A> {
            let base = self.execute
            return EffectTask { services, signal in
                await base(services.annotatingLog(key, value), signal)
            }
        }

        public func runExit(
            services: EffectServices = .empty,
            signal: AbortSignal = AbortSignal()
        ) async -> EffectExit<A> {
            await execute(services, signal)
        }

        public func run(
            services: EffectServices = .empty,
            signal: AbortSignal = AbortSignal()
        ) async throws -> A {
            switch await execute(services, signal) {
            case .success(let a): return a
            case .fail(let err): throw err
            case .die(let err): throw err
            case .interrupt: throw Contract.Interrupted()
            }
        }
    }

    /// Helpers bridging `EffectTask` into `Contract.HostWork` (`psychoscript/src/effect/work.ts`).
    public enum EffectWork {
        /// What a host function returned, with an Effect adapted into `HostWork`.
        // parity: psychoscript/src/effect/work.ts#adapt [status=implemented hash=ed9972732940]
        public static func adapt(_ value: HostReturn) -> HostReturn {
            switch value {
            case .effect(let task):
                return .work(work(task))
            case .value, .work, .promise:
                return value
            }
        }

        /// An Effect as host work: runs with the run's services when the driver starts it,
        /// an abort interrupts it, and its exit settles the call. An interruption stays one
        /// (`Contract.Interrupted`), and a defect gets the call's location (`Contract.HostDefect`).
        // parity: psychoscript/src/effect/work.ts#work [status=implemented hash=37c64fd30796]
        public static func work(_ effect: EffectTask<HostReturn>) -> Contract.HostWork {
            Contract.HostWork { context, done in
                let services = (context as? EffectServices) ?? .empty
                let controller = AbortController()
                let task = Task {
                    let exit = await effect.runExit(services: services, signal: controller.signal)
                    switch exit {
                    case .success(let value):
                        done(.ok(adapt(value)))
                    case .fail(let error):
                        done(.error(error))
                    case .die(let error):
                        done(.error(Contract.HostDefect(error)))
                    case .interrupt:
                        done(.error(Contract.Interrupted()))
                    }
                }
                return {
                    controller.abort()
                    task.cancel()
                }
            }
        }
    }
}
