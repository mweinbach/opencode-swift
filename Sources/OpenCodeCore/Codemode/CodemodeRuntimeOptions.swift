import OpenCodeSchema

// Shared runtime option types and setup builder (mirrors `psychoscript/src/runtime/options.ts`).
extension CodemodeLanguage {
    /// Budgets enforced on each run. Time counts active time only, across every resume of a run.
    // parity: psychoscript/src/runtime/options.ts#Limits [status=implemented hash=0d7dd5af1236]
    public typealias Limits = ExecuteLimits

    /// How a host call's arguments carry program values the host can't hold. Every host function in the runtime
    /// gets its arguments this way; results are not affected.
    // parity: psychoscript/src/runtime/options.ts#Translate [status=implemented hash=69a2bee33650]
    public struct Translate: Equatable, Hashable, Sendable, Codable {
        public enum FunctionPolicy: String, Equatable, Hashable, Sendable, Codable {
            case error
            case drop
        }

        public enum PromisePolicy: String, Equatable, Hashable, Sendable, Codable {
            case error
            case `await`
        }

        public let functions: FunctionPolicy
        public let promises: PromisePolicy

        public init(functions: FunctionPolicy = .error, promises: PromisePolicy = .error) {
            self.functions = functions
            self.promises = promises
        }
    }

    /// A runtime's host globals for one run: `Host.fn`, `Host.durableFn`, `Host.namespace`, and plain values of them.
    // parity: psychoscript/src/runtime/options.ts#Globals [status=implemented hash=a53794fae07b]
    public typealias Globals = [String: HostGlobalValue]

    /// How `Runtime.make` sets up a runtime: its host globals, module aliases, limits, and argument translation.
    // parity: psychoscript/src/runtime/options.ts#Options [status=implemented hash=711bf87070b1]
    public struct RuntimeOptions: Sendable {
        public let globals: (@Sendable (Run) -> Globals)?
        public let modules: [String: String]
        public let limits: Limits
        public let translate: Translate

        public init(
            globals: (@Sendable (Run) -> Globals)? = nil,
            modules: [String: String] = [:],
            limits: Limits = Limits(),
            translate: Translate = Translate()
        ) {
            self.globals = globals
            self.modules = modules
            self.limits = limits
            self.translate = translate
        }
    }

    /// Options for `Runtime.program`.
    // parity: psychoscript/src/runtime/options.ts#ProgramOptions [status=implemented hash=f61a9d8217cf]
    public struct ProgramOptions: Sendable {
        public let bindings: [String: Json]?
        public let runId: String?

        public init(bindings: [String: Json]? = nil, runId: String? = nil) {
            self.bindings = bindings
            self.runId = runId
        }
    }

    /// How `program.suspend` saves a run's state.
    // parity: psychoscript/src/runtime/options.ts#SuspendOptions [status=implemented hash=4d826935ccbe]
    public struct SuspendOptions: Equatable, Hashable, Sendable, Codable {
        public let maxBytes: Int?

        public init(maxBytes: Int? = nil) {
            self.maxBytes = maxBytes
        }
    }

    /// A runtime's setup from its options. Throws a `RangeError` for invalid limits.
    // parity: psychoscript/src/runtime/options.ts#makeSetup [status=implemented hash=9895c2153199]
    public static func makeSetup(_ options: RuntimeOptions = RuntimeOptions()) throws -> Setup {
        let timeoutMs = try validateLimit("timeoutMs", options.limits.timeoutMs, minimum: 1)
        let maxOutputBytes = try validateLimit("maxOutputBytes", options.limits.maxOutputBytes, minimum: 0)
        let maxSteps = try validateLimit("maxSteps", options.limits.maxSteps, minimum: 1)
        return Setup(
            limits: ExecuteLimits(timeoutMs: timeoutMs, maxOutputBytes: maxOutputBytes, maxSteps: maxSteps),
            translate: options.translate,
            globals: options.globals,
            modules: options.modules
        )
    }
}
