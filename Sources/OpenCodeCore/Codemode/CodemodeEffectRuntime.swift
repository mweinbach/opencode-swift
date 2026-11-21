import OpenCodeSchema
import OpenCodeUtil

// Effect-based Runtime API (mirrors `psychoscript/src/effect/runtime.ts`).
extension CodemodeLanguage {
    /// Legacy alias kept for source compatibility with callers of `CodemodeLanguage.Services`.
    public typealias Services = EffectServices

    public enum EffectRuntime {
        // parity: psychoscript/src/effect/runtime.ts#SuspendError [status=implemented hash=d6d958471836]
        public typealias SuspendError = CodemodeLanguage.SuspendError

        // parity: psychoscript/src/effect/runtime.ts#Outcome [status=implemented hash=0fa9789cd012]
        public typealias Outcome = CodemodeLanguage.Outcome

        // parity: psychoscript/src/effect/runtime.ts#Result [status=implemented hash=0fa9789cd012]
        public typealias Result = CodemodeLanguage.Result

        // parity: psychoscript/src/effect/runtime.ts#Run [status=implemented hash=0fa9789cd012]
        public typealias Run = CodemodeLanguage.Run

        // parity: psychoscript/src/effect/runtime.ts#Suspended [status=implemented hash=0fa9789cd012]
        public typealias Suspended = CodemodeLanguage.Suspended

        /// The Effect environment the host functions among a runtime's globals need.
        // parity: psychoscript/src/effect/runtime.ts#Services [status=implemented hash=c07e941bb3e4]
        public typealias Services = EffectServices

        /// One run of a program under Effect: `run()` runs it with the caller's services,
        /// and interrupting `run()` interrupts its host calls.
        // parity: psychoscript/src/effect/runtime.ts#Program [status=implemented hash=a26101024aed]
        public struct Program: Sendable {
            private let runFn: @Sendable () -> EffectTask<Outcome>
            private let suspendFn: @Sendable (SuspendOptions?) throws -> EffectTask<Outcome>

            public init(
                run: @escaping @Sendable () -> EffectTask<Outcome>,
                suspend: @escaping @Sendable (SuspendOptions?) throws -> EffectTask<Outcome>
            ) {
                self.runFn = run
                self.suspendFn = suspend
            }

            public func run() -> EffectTask<Outcome> {
                runFn()
            }

            public func suspend(_ options: SuspendOptions? = nil) throws -> EffectTask<Outcome> {
                try suspendFn(options)
            }
        }

        /// A reusable confined runtime over Effect host globals.
        // parity: psychoscript/src/effect/runtime.ts#Runtime [status=implemented hash=39fdf7de6941]
        public struct Runtime: Sendable {
            private let executeFn: @Sendable (String, ProgramOptions?) -> EffectTask<Result>
            private let programFn: @Sendable (String, ProgramOptions?) -> Program
            private let resumeSnapshotFn: @Sendable (Snapshot) -> Program
            private let resumeBytesFn: @Sendable ([UInt8]) -> Program

            public init(
                execute: @escaping @Sendable (String, ProgramOptions?) -> EffectTask<Result>,
                program: @escaping @Sendable (String, ProgramOptions?) -> Program,
                resumeSnapshot: @escaping @Sendable (Snapshot) -> Program,
                resumeBytes: @escaping @Sendable ([UInt8]) -> Program
            ) {
                self.executeFn = execute
                self.programFn = program
                self.resumeSnapshotFn = resumeSnapshot
                self.resumeBytesFn = resumeBytes
            }

            public func execute(_ code: String, _ options: ProgramOptions? = nil) -> EffectTask<Result> {
                executeFn(code, options)
            }

            public func program(_ code: String, _ options: ProgramOptions? = nil) -> Program {
                programFn(code, options)
            }

            public func resume(_ state: Snapshot) -> Program {
                resumeSnapshotFn(state)
            }

            public func resume(_ bytes: [UInt8]) -> Program {
                resumeBytesFn(bytes)
            }
        }

        /// Creates a runtime whose programs reach the host globals `options.globals` makes for each run,
        /// adapting Effects returned from both `EffectHost.fn` and plain host functions.
        /// Throws a `RangeError` for invalid limits.
        // parity: psychoscript/src/effect/runtime.ts#make [status=implemented hash=60ba3176937b]
        public static func make(_ options: RuntimeOptions = RuntimeOptions()) throws -> Runtime {
            let baseSetup = try makeSetup(options)
            let setup = Setup(
                limits: baseSetup.limits,
                translate: baseSetup.translate,
                globals: baseSetup.globals,
                modules: baseSetup.modules,
                adapt: { value, _ in EffectWork.adapt(value) }
            )
            let makeWrappedProgram: @Sendable (String, ProgramOptions?) -> Program = { code, programOptions in
                wrap(makeProgram {
                    startProgram(
                        setup: setup,
                        code: code,
                        bindings: programOptions?.bindings,
                        runId: programOptions?.runId ?? OpenCodeUtil.uuid()
                    )
                })
            }
            return Runtime(
                execute: { code, programOptions in
                    EffectTask { services, outerSignal in
                        await fromPromise(outerSignal: outerSignal) { signal in
                            let managed = makeProgram {
                                startProgram(
                                    setup: setup,
                                    code: code,
                                    bindings: programOptions?.bindings,
                                    runId: programOptions?.runId ?? OpenCodeUtil.uuid()
                                )
                            }
                            let outcome = try await managed.run(ExecuteRunOptions(signal: signal, context: services))
                            return finishExecution(outcome)
                        }
                    }
                },
                program: makeWrappedProgram,
                resumeSnapshot: { state in
                    wrap(makeProgram { try resumeProgram(setup: setup, saved: state) })
                },
                resumeBytes: { bytes in
                    wrap(makeProgram { try resumeProgram(setup: setup, savedBytes: bytes) })
                }
            )
        }

        private static func wrap(_ program: ManagedProgram) -> Program {
            Program(
                run: {
                    EffectTask { services, outerSignal in
                        await fromPromise(outerSignal: outerSignal) { signal in
                            try await program.run(ExecuteRunOptions(signal: signal, context: services))
                        }
                    }
                },
                suspend: { options in
                    let maxBytes = options?.maxBytes
                    try checkMaxBytes(maxBytes)
                    return EffectTask { _, outerSignal in
                        await fromPromise(outerSignal: outerSignal) { _ in
                            try await program.suspend(maxBytes)
                        }
                    }
                }
            )
        }

        /// Bridges an async throwing run into `EffectExit`: `Contract.Interrupted` -> `.interrupt`,
        /// `SuspendError` or `SnapshotError` -> `.fail`, anything else -> `.die`.
        /// When `outerSignal` aborts, aborts the inner controller and awaits settlement so cleanup finishes.
        private static func fromPromise<A: Sendable>(
            outerSignal: AbortSignal,
            _ start: @escaping @Sendable (AbortSignal) async throws -> A
        ) async -> EffectExit<A> {
            let controller = AbortController()
            let listenerId = outerSignal.onAbort {
                controller.abort(outerSignal.reason)
            }
            defer { outerSignal.removeEventListener(listenerId) }
            do {
                let value = try await start(controller.signal)
                return .success(value)
            } catch is Contract.Interrupted {
                return .interrupt
            } catch let err as SuspendError {
                return .fail(err)
            } catch let err as SnapshotError {
                return .fail(err)
            } catch {
                return .die(error)
            }
        }
    }
}
