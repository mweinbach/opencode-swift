import OpenCodeSchema

// Effect-based host function factories (mirrors `psychoscript/src/effect/host-function.ts`).
extension CodemodeLanguage {
    public enum EffectHost {
        // parity: psychoscript/src/effect/host-function.ts#Call [status=implemented hash=3537cee4062f]
        public typealias Call = Contract.Call

        // parity: psychoscript/src/effect/host-function.ts#DurableCall [status=implemented hash=3537cee4062f]
        public typealias DurableCall = Contract.DurableCall

        // parity: psychoscript/src/effect/host-function.ts#Snapshot [status=implemented hash=3537cee4062f]
        public typealias Snapshot = Contract.Snapshot

        // parity: psychoscript/src/effect/host-function.ts#Type [status=implemented hash=3537cee4062f]
        public typealias CallType = Contract.CallType

        // parity: psychoscript/src/effect/host-function.ts#DurableFn [status=implemented hash=6e0f5b70b88a]
        public typealias DurableFn = Contract.DurableFn

        // parity: psychoscript/src/effect/host-function.ts#Fn [status=implemented hash=6e0f5b70b88a]
        public typealias Fn = Contract.Fn

        // parity: psychoscript/src/effect/host-function.ts#Namespace [status=implemented hash=6e0f5b70b88a]
        public typealias Namespace = Contract.Namespace

        // parity: psychoscript/src/effect/host-function.ts#Options [status=implemented hash=e22db77005cd]
        public struct Options: Sendable {
            public let type: CallType
            public let idempotent: Bool
            public let snapshot: Snapshot?
            public let constructible: Bool
            public let takesFunctions: Bool
            public let name: String?
            public let length: Int?

            public init(
                type: CallType = .sync,
                idempotent: Bool = false,
                snapshot: Snapshot? = nil,
                constructible: Bool = false,
                takesFunctions: Bool = false,
                name: String? = nil,
                length: Int? = nil
            ) {
                self.type = type
                self.idempotent = type == .async && idempotent
                self.snapshot = snapshot
                self.constructible = constructible
                self.takesFunctions = takesFunctions
                self.name = name
                self.length = length
            }
        }

        // parity: psychoscript/src/effect/host-function.ts#Failure [status=implemented hash=5dd2dd1d91c8]
        public typealias Failure = HostFailure

        /// A host function returning a value, Promise, or `EffectTask`.
        /// Adapts returned Effects into `HostWork` while preserving the source function's `name` and `length`.
        // parity: psychoscript/src/effect/host-function.ts#fn [status=implemented hash=f115d98d5d7f]
        public static func fn(
            _ f: @escaping @Sendable ([Value], Call, Builtins) throws -> HostReturn,
            options: Options = Options()
        ) -> Fn {
            Fn(
                runReturn: { args, call, builtins in
                    EffectWork.adapt(try f(args, call, builtins))
                },
                type: options.type,
                idempotent: options.type == .async && options.idempotent,
                snapshot: options.snapshot,
                constructible: options.constructible,
                takesFunctions: options.takesFunctions,
                sourceName: options.name,
                sourceLength: options.length
            )
        }

        /// Convenience overload for an Effect-returning host function.
        public static func fn(
            _ f: @escaping @Sendable ([Value], Call, Builtins) -> EffectTask<Value>,
            options: Options = Options()
        ) -> Fn {
            fn({ args, call, builtins in
                .effect(f(args, call, builtins).map { .value($0) })
            }, options: options)
        }

        /// A durable host function whose `start`, `wait`, and `cancel` are Effects running with the run's services.
        // parity: psychoscript/src/effect/host-function.ts#durableFn [status=implemented hash=67efa4e5f482]
        public static func durableFn(
            start: @escaping @Sendable ([Value], Call) -> EffectTask<JSONValue>,
            wait: @escaping @Sendable (JSONValue, DurableCall, Builtins) -> EffectTask<Value>,
            cancel: @escaping @Sendable (JSONValue, DurableCall) -> EffectTask<Void>
        ) -> DurableFn {
            DurableFn(
                startWork: { args, call in
                    EffectWork.work(EffectTask.suspend {
                        start(args, call).map { json in
                            let val = (try? CodemodeLanguage.fromJson(CodemodeLanguage.createBuiltins(), json)) ?? .null
                            return .value(val)
                        }
                    })
                },
                waitWork: { data, call, builtins in
                    EffectWork.work(EffectTask.suspend {
                        wait(data, call, builtins).map { .value($0) }
                    })
                },
                cancelWork: { data, call in
                    EffectWork.work(EffectTask.suspend {
                        cancel(data, call).map { .value(.undefined) }
                    })
                }
            )
        }

        /// A lazy object of host functions addressed by path.
        // parity: psychoscript/src/effect/host-function.ts#namespace [status=implemented hash=64d87709c204]
        public static func namespace(
            keys: @escaping @Sendable ([String]) throws -> [String],
            resolve: @escaping @Sendable ([String]) -> Host.ResolvedTarget
        ) -> Namespace {
            Namespace(keys: keys, resolve: resolve)
        }

        /// A failure with its own diagnostic `kind` and `suggestions`, to throw or fail with from a host function.
        // parity: psychoscript/src/effect/host-function.ts#fail [status=implemented hash=9b85a78dcc5c]
        public static func fail(_ kind: String, _ message: String, suggestions: [String] = []) -> HostFailure {
            HostFailure(kind: kind, message: message, suggestions: suggestions)
        }

        /// What `resolve` gives for a path with no function: calling it throws this failure.
        // parity: psychoscript/src/effect/host-function.ts#missing [status=implemented hash=1689a7fa6fe6]
        public static func missing(_ message: String, suggestions: [String] = [], kind: String = "ExecutionFailure") -> HostFailure {
            HostFailure(kind: kind, message: message, suggestions: suggestions)
        }
    }
}
