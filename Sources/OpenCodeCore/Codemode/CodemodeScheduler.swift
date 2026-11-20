import Synchronization

// Deterministic, cooperative execution for Code Mode programs, matching psychoscript's single-threaded VM
// (`src/vm.ts#Vm.run`, `src/async.ts#VmScheduler`, `src/runtime/driver.ts#Driver`).
//
// Upstream runs every program on one logical thread: microtask jobs run FIFO, an `await` parks the frames of the
// async function until a reaction job continues them, a generator's body runs only while `next()` is on the stack,
// and host work completes into an inbox the VM drains only when no job is queued. The Swift evaluator is a recursive
// `async` tree walker, so program coroutines (async function bodies, generator bodies, the program body itself) run
// as `Fiber`s: Swift tasks that hand a single baton back and forth through continuations, so exactly one of them runs
// program code at a time and the order of every step is the upstream order.
extension CodemodeLanguage {
    /// What a parked fiber is resumed with.
    public enum FiberInput: Sendable {
        /// An awaited promise settled (`await`), or the value `next(v)` sends into a generator.
        case outcome(PromiseOutcome)
        /// `generator.return(v)`: completes the generator from its `yield`, running `finally` blocks.
        case returning(Value)
        /// The run ended: unwind without running any more program code.
        case abort
    }

    /// Why a fiber handed the baton back.
    public enum FiberSignal: Sendable {
        /// Parked on an `await`; a reaction job resumes it.
        case awaiting
        /// A generator body yielded this value.
        case yielded(Value)
        /// The body completed (its result is kept by whoever started it).
        case finished
    }

    /// A program coroutine. `start` runs a body until it first parks or finishes; `resume` continues it the same way.
    /// The resumer is suspended for exactly as long as the fiber runs, so program code never runs concurrently.
    public final class Fiber: @unchecked Sendable {
        @TaskLocal public static var current: Fiber?

        private struct State {
            var resume: CheckedContinuation<FiberInput, Never>?
            var park: CheckedContinuation<FiberSignal, Never>?
            var finished = false
        }

        private let state = Mutex(State())
        /// Whether `await` parks this fiber (async functions, async generators, the program body). A synchronous
        /// generator's body cannot await; a host call waiting on its arguments there drives the scheduler instead.
        public let allowsAwait: Bool
        /// The generator whose body this fiber runs, if any (`yield` finds it here).
        public let generator: GeneratorObj?

        public init(allowsAwait: Bool, generator: GeneratorObj? = nil) {
            self.allowsAwait = allowsAwait
            self.generator = generator
        }

        public var isFinished: Bool { state.withLock { $0.finished } }

        public var isParked: Bool { state.withLock { $0.resume != nil } }

        /// Runs `body` as this fiber until it parks or finishes.
        public func start(scheduler: ProgramScheduler, _ body: @escaping @Sendable () async -> Void) async -> FiberSignal {
            scheduler.register(self)
            return await withCheckedContinuation { (continuation: CheckedContinuation<FiberSignal, Never>) in
                state.withLock { $0.park = continuation }
                Task {
                    await Fiber.$current.withValue(self) {
                        await body()
                    }
                    self.finish(scheduler: scheduler)
                }
            }
        }

        private func finish(scheduler: ProgramScheduler) {
            scheduler.unregister(self)
            let parked = state.withLock { s -> CheckedContinuation<FiberSignal, Never>? in
                s.finished = true
                let p = s.park
                s.park = nil
                return p
            }
            parked?.resume(returning: .finished)
        }

        /// Inside the fiber: hands the baton back to the resumer with `signal`, and waits to be resumed.
        public func park(_ signal: FiberSignal) async -> FiberInput {
            await withCheckedContinuation { (continuation: CheckedContinuation<FiberInput, Never>) in
                let resumer = state.withLock { s -> CheckedContinuation<FiberSignal, Never>? in
                    s.resume = continuation
                    let p = s.park
                    s.park = nil
                    return p
                }
                resumer?.resume(returning: signal)
            }
        }

        /// From outside: resumes the parked fiber with `input`, and waits until it parks again or finishes.
        public func resume(_ input: FiberInput) async -> FiberSignal {
            await withCheckedContinuation { (continuation: CheckedContinuation<FiberSignal, Never>) in
                let parked = state.withLock { s -> CheckedContinuation<FiberInput, Never>? in
                    guard let r = s.resume, !s.finished else { return nil }
                    s.resume = nil
                    s.park = continuation
                    return r
                }
                if let parked {
                    parked.resume(returning: input)
                } else {
                    continuation.resume(returning: .finished)
                }
            }
        }
    }

    /// One run's job queue, host inbox, promise bookkeeping and live fibers (upstream `VmScheduler` plus the parts of
    /// `HostCalls` and `Driver` that order host completions).
    public final class ProgramScheduler: @unchecked Sendable {
        @TaskLocal public static var current: ProgramScheduler?

        public typealias Job = @Sendable () async -> Void

        private struct Delivery {
            let seq: Int
            let deliver: @Sendable () -> Void
        }

        private struct ParkedAwait {
            let promise: PromiseObj
            let node: AstNode?
            let result: Value
        }

        private struct State {
            var queue: [Job] = []
            var head = 0
            var inbox: [Delivery] = []
            var nextSeq = 0
            var running = 0
            /// Host work started and not yet completed (its completion not delivered to the inbox).
            var inFlight = Set<Int>()
            var wake: CheckedContinuation<Void, Never>?
            var nextPromiseId = 0
            var pendingPromises = 0
            var unhandled: [ObjectIdentifier: (id: Int, diagnostic: Diagnostic)] = [:]
            var parked: [ObjectIdentifier: ParkedAwait] = [:]
            var parkOrder: [ObjectIdentifier] = []
            var fibers: [ObjectIdentifier: Fiber] = [:]
            var tornDown = false
        }

        private let state = Mutex(State())

        public init() {}

        // MARK: Jobs

        public func enqueue(_ job: @escaping Job) {
            state.withLock { $0.queue.append(job) }
        }

        public func dequeue() -> Job? {
            state.withLock { s -> Job? in
                guard s.head < s.queue.count else {
                    if s.head > 0 {
                        s.queue.removeAll(keepingCapacity: true)
                        s.head = 0
                    }
                    return nil
                }
                let job = s.queue[s.head]
                s.head += 1
                if s.head > 4096 && s.head * 2 > s.queue.count {
                    s.queue.removeFirst(s.head)
                    s.head = 0
                }
                return job
            }
        }

        public var hasJobs: Bool { state.withLock { $0.head < $0.queue.count } }

        public var isTornDown: Bool { state.withLock { $0.tornDown } }

        // MARK: Host work

        /// A host call starts: its completion arrives later through `deliver`.
        public func beginHostWork() -> Int {
            state.withLock { s -> Int in
                s.running += 1
                let seq = s.nextSeq
                s.nextSeq += 1
                s.inFlight.insert(seq)
                return seq
            }
        }

        /// Host work completed (from any task): `apply` runs in the job loop, when no job is queued.
        public func deliver(seq: Int, _ apply: @escaping @Sendable () -> Void) {
            let wake = state.withLock { s -> CheckedContinuation<Void, Never>? in
                s.inbox.append(Delivery(seq: seq, deliver: apply))
                s.inFlight.remove(seq)
                let w = s.wake
                s.wake = nil
                return w
            }
            wake?.resume()
        }

        public var hasRunningHostWork: Bool { state.withLock { $0.running > 0 } }

        /// The next inbox completion: of those already delivered, the earliest started, so host work that completes at
        /// once settles in call order (upstream's Effect fibers deliver instant results in launch order).
        public func takeDelivery() -> (@Sendable () -> Void)? {
            state.withLock { s -> (@Sendable () -> Void)? in
                guard !s.inbox.isEmpty else { return nil }
                var best = 0
                for i in s.inbox.indices where s.inbox[i].seq < s.inbox[best].seq { best = i }
                let d = s.inbox.remove(at: best)
                s.running -= 1
                return d.deliver
            }
        }

        /// Wakes a `waitForDelivery` (the run's deadline passed).
        public func wakeUp() {
            let w = state.withLock { s -> CheckedContinuation<Void, Never>? in
                let w = s.wake
                s.wake = nil
                return w
            }
            w?.resume()
        }

        /// Waits until some host work completes, or until `deadlineMs` (epoch milliseconds) passes.
        public func waitForDelivery(deadlineMs: Double?) async {
            guard let deadlineMs else { return await waitForDelivery() }
            let remaining = max(0, deadlineMs - CodemodeLanguage.currentEpochMs())
            let sleeper = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(Int(remaining.rounded(.up)) + 1))
                self?.wakeUp()
            }
            await waitForDelivery()
            sleeper.cancel()
        }

        /// Waits until some host work completes.
        public func waitForDelivery() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let ready = state.withLock { s -> Bool in
                    if !s.inbox.isEmpty || s.tornDown { return true }
                    s.wake = continuation
                    return false
                }
                if ready { continuation.resume() }
            }
            // Host work started earlier that is completing at the same moment arrives first, so results that are
            // ready at once keep call order (upstream's Effect fibers deliver instant results in launch order). A call
            // still running after a brief grace is not waited for: completions stay in completion order.
            let start = CodemodeLanguage.currentEpochMs()
            while true {
                let earlierRunning = state.withLock { s -> Bool in
                    guard !s.tornDown, let first = s.inbox.map(\.seq).min() else { return false }
                    return s.inFlight.contains { $0 < first }
                }
                if !earlierRunning || CodemodeLanguage.currentEpochMs() - start > 5 { break }
                await Task.yield()
            }
        }

        // MARK: Promises

        public func newPromiseId() -> Int {
            state.withLock { s -> Int in
                let id = s.nextPromiseId
                s.nextPromiseId += 1
                return id
            }
        }

        func noteUnhandled(_ promise: PromiseObj, _ reason: Value) {
            let failure = normalizeError(Throw(reason))
            let diagnostic = Diagnostic(
                kind: failure.kind,
                message: "Unhandled rejection from an un-awaited promise: \(failure.message)",
                location: failure.location,
                suggestions: failure.suggestions
            )
            state.withLock { $0.unhandled[ObjectIdentifier(promise)] = (promise.id, diagnostic) }
        }

        func noteHandled(_ promise: PromiseObj) {
            _ = state.withLock { $0.unhandled.removeValue(forKey: ObjectIdentifier(promise)) }
        }

        /// Unhandled rejections, in promise creation order (upstream `VmScheduler.diagnostics`).
        public func diagnostics() -> [Diagnostic] {
            state.withLock { s in s.unhandled.values.sorted { $0.id < $1.id }.map(\.diagnostic) }
        }

        // MARK: Fibers

        func register(_ fiber: Fiber) {
            state.withLock { $0.fibers[ObjectIdentifier(fiber)] = fiber }
        }

        func unregister(_ fiber: Fiber) {
            state.withLock { s in
                s.fibers.removeValue(forKey: ObjectIdentifier(fiber))
                s.parked.removeValue(forKey: ObjectIdentifier(fiber))
            }
        }

        /// Records the `await` a fiber parks on, for the stuck diagnostic.
        func noteAwait(_ fiber: Fiber, promise: PromiseObj, node: AstNode?, result: Value) {
            state.withLock { s in
                let key = ObjectIdentifier(fiber)
                if s.parked[key] == nil { s.parkOrder.append(key) }
                s.parked[key] = ParkedAwait(promise: promise, node: node, result: result)
            }
        }

        func clearAwait(_ fiber: Fiber) {
            _ = state.withLock { $0.parked.removeValue(forKey: ObjectIdentifier(fiber)) }
        }

        /// The `await` to blame when nothing can run (upstream `VmScheduler.stuckAwait`): one whose promise is not just
        /// another parked await's result, else the first.
        public func stuckAwait() -> AstNode? {
            state.withLock { s -> AstNode? in
                let entries = s.parkOrder.compactMap { s.parked[$0] }
                var results = Set<ObjectIdentifier>()
                for e in entries { if case .object(let p as PromiseObj) = e.result { results.insert(ObjectIdentifier(p)) } }
                let located = entries.filter { $0.node != nil }
                return (located.first { !results.contains(ObjectIdentifier($0.promise)) } ?? located.first)?.node
            }
        }

        /// Ends the run: every parked fiber unwinds (an `Interruption` skips `catch` and `finally`), and no more jobs run.
        public func tearDown() async {
            let fibers = state.withLock { s -> [Fiber] in
                s.tornDown = true
                s.queue.removeAll()
                s.head = 0
                let w = s.wake
                s.wake = nil
                w?.resume()
                return Array(s.fibers.values)
            }
            for fiber in fibers {
                // A fiber that parks again while unwinding is resumed until it finishes.
                var rounds = 0
                while fiber.isParked && rounds < 64 {
                    _ = await fiber.resume(.abort)
                    rounds += 1
                }
            }
        }
    }
}

// MARK: - Evaluator: promises, await, coroutines

extension CodemodeLanguage.Evaluator {
    public typealias L = CodemodeLanguage

    /// PromiseResolve(%Promise%, value) (upstream `VmScheduler.promiseResolve`): a promise as is, else a new promise
    /// resolved with the value (a thenable adopted in a later job).
    public func promiseResolve(_ value: L.Value) -> L.PromiseObj {
        if case .object(let p as L.PromiseObj) = value { return p }
        let promise = L.PromiseObj(proto: builtins.Promise)
        resolvePromise(promise, with: value)
        return promise
    }

    /// Resolves `promise` with `resolution` (upstream `VmScheduler.resolveWith`): a non-thenable fulfills it now; a
    /// thenable's `then` is called in a job of its own (NewPromiseResolveThenableJob), and a native promise is
    /// adopted through a reaction, one job later.
    public func resolvePromise(_ promise: L.PromiseObj, with resolution: L.Value) {
        guard case .object(let obj) = resolution else {
            promise.fulfill(resolution)
            return
        }
        if obj === promise {
            promise.reject(L.materialize(builtins, L.typeError("Chaining cycle detected: a promise cannot resolve with itself.")))
            return
        }
        let builtins = self.builtins
        // A program `then` getter is program code, so it runs in a job of its own.
        if let slot = L.lookup(obj, .string("then")), L.isProgramAccessor(slot) {
            scheduler.enqueue { [self] in
                do {
                    let then = try await redoRead(obj, .string("then"), receiver: resolution)
                    callThen(promise, thenable: obj, then: then)
                } catch is L.Interruption {
                } catch {
                    promise.reject(L.materialize(builtins, error))
                }
            }
            return
        }
        let then = L.get(obj, "then")
        guard case .object(let thenObj) = then, thenObj is L.Callable else {
            promise.fulfill(resolution)
            return
        }
        scheduler.enqueue { [self] in
            if let thenable = obj as? L.PromiseObj, isIntrinsicThen(thenObj) {
                // Adopting a native promise through the intrinsic `then` takes the same jobs as calling it.
                thenable.addReaction { outcome in promise.settle(outcome) }
                return
            }
            await callThenNow(promise, thenable: obj, then: then)
        }
    }

    private func isIntrinsicThen(_ fn: L.Obj) -> Bool {
        if case .object(let intrinsic) = L.get(builtins.Promise, "then") { return intrinsic === fn }
        return false
    }

    private func callThen(_ promise: L.PromiseObj, thenable: L.Obj, then: L.Value) {
        guard case .object(let thenObj) = then, thenObj is L.Callable else {
            promise.fulfill(.object(thenable))
            return
        }
        scheduler.enqueue { [self] in await callThenNow(promise, thenable: thenable, then: then) }
    }

    private func callThenNow(_ promise: L.PromiseObj, thenable: L.Obj, then: L.Value) async {
        let flag = L.ResolvingFlag()
        let resolve = L.Resolver(proto: builtins.Function, promise: promise, isReject: false, flag: flag)
        let reject = L.Resolver(proto: builtins.Function, promise: promise, isReject: true, flag: flag)
        do {
            _ = try await callCallable(then, thisValue: .object(thenable), args: [.object(resolve), .object(reject)], site: nil)
        } catch is L.Interruption {
        } catch {
            if flag.claim() { promise.reject(L.materialize(builtins, error)) }
        }
    }

    /// A `resolve`/`reject` function was called: only the pair's first call settles, and `resolve` adopts thenables.
    func callResolver(_ resolver: L.Resolver, _ arg: L.Value) {
        guard resolver.flag.claim() else { return }
        if resolver.isReject {
            resolver.promise.reject(arg)
        } else {
            resolvePromise(resolver.promise, with: arg)
        }
    }

    /// `await value` (upstream `VmScheduler.park`): the running fiber parks until a reaction job continues it with the
    /// promise's outcome. Outside a fiber that can await (a synchronous generator's body, a job), the run's job loop
    /// is driven here until the promise settles: the whole job waits, as upstream's does for a host call's arguments.
    public func awaitValue(_ value: L.Value, node: L.AstNode? = nil) async throws -> L.Value {
        let promise = promiseResolve(value)
        guard let fiber = L.Fiber.current, fiber.allowsAwait, !scheduler.isTornDown else {
            return try await drive(until: promise)
        }
        let scheduler = self.scheduler
        let builtins = self.builtins
        scheduler.noteAwait(fiber, promise: promise, node: node ?? currentSiteNode(), result: value)
        promise.addReaction { [self] outcome in
            scheduler.clearAwait(fiber)
            let signal = await fiber.resume(.outcome(outcome))
            if let generator = fiber.generator, generator.isAsync {
                await generator.handleAsyncSignal(signal, builtins: builtins, eval: self)
            }
        }
        switch await fiber.park(.awaiting) {
        case .outcome(.fulfilled(let v)): return v
        case .outcome(.rejected(let r)): throw L.Throw(r)
        case .returning(let v): throw L.ControlSignal.returnValue(v)
        case .abort: throw L.Interruption("aborted")
        }
    }

    /// The node of the innermost site the program is at, for diagnostics that have no node of their own.
    func currentSiteNode() -> L.AstNode? {
        L.EvalFrames.current?.site
    }

    /// Runs the job loop until `promise` settles (used where program code waits outside an awaiting fiber).
    func drive(until promise: L.PromiseObj) async throws -> L.Value {
        while true {
            switch promise.status {
            case .fulfilled(let v):
                return v
            case .rejected(let r):
                promise.isObserved = true
                throw L.Throw(r)
            case .pending:
                break
            }
            if scheduler.isTornDown { throw L.Interruption("aborted") }
            try checkDeadline()
            if let job = scheduler.dequeue() {
                await job()
                continue
            }
            if let delivery = scheduler.takeDelivery() {
                delivery()
                continue
            }
            if scheduler.hasRunningHostWork {
                await scheduler.waitForDelivery(deadlineMs: deadlineMs)
                continue
            }
            throw stuckError()
        }
    }

    /// Runs the program body as the root fiber and the job loop until the body completes (upstream `Driver.run`):
    /// jobs run in order; host completions are delivered one at a time when no job is queued; when nothing can run
    /// and no host work is in flight, the awaited promise can never settle. Jobs still queued when the body ends do
    /// not run, and parked fibers are unwound without running program code.
    public func runProgram(_ program: L.ProgramAST) async throws -> L.Value {
        final class Outcome: @unchecked Sendable {
            var result: Swift.Result<L.Value, Error>?
        }
        let outcome = Outcome()
        let main = L.Fiber(allowsAwait: true)
        _ = await main.start(scheduler: scheduler) { [self] in
            do {
                let value = try await evaluateProgram(program)
                // The body is an async function body: a returned promise or thenable is adopted.
                if case .object(let obj) = value, obj is L.PromiseObj || L.isThenable(value) {
                    outcome.result = .success(try await awaitValue(value))
                } else {
                    outcome.result = .success(value)
                }
            } catch {
                outcome.result = .failure(error)
            }
        }
        do {
            while outcome.result == nil {
                try checkDeadline()
                if let job = scheduler.dequeue() {
                    await job()
                    continue
                }
                if let delivery = scheduler.takeDelivery() {
                    delivery()
                    continue
                }
                if scheduler.hasRunningHostWork {
                    await scheduler.waitForDelivery(deadlineMs: deadlineMs)
                    continue
                }
                throw stuckError()
            }
        } catch {
            await scheduler.tearDown()
            throw error
        }
        await scheduler.tearDown()
        switch outcome.result {
        case .success(let v)?: return v
        case .failure(let e)?: throw e
        case nil: throw L.Interruption("aborted")
        }
    }

    /// The program waits on something nothing can settle (upstream `Driver.run`'s `stuck` stop).
    func stuckError() -> L.PendingThrow {
        L.PendingThrow(
            type: .error,
            message: "The program is waiting on a promise that can never settle: nothing else is running, so nothing can resolve it. There are no timers or sleep, so don't wait or poll inside a program.",
            node: scheduler.stuckAwait()
        )
    }

    /// Calls an async function: its body runs as a fiber until its first `await`, and the call answers its promise.
    func startAsyncFunction(_ body: @escaping @Sendable () async throws -> L.Value) async -> L.PromiseObj {
        let promise = L.PromiseObj(proto: builtins.Promise)
        let fiber = L.Fiber(allowsAwait: true)
        let builtins = self.builtins
        _ = await fiber.start(scheduler: scheduler) { [self] in
            do {
                let result = try await body()
                resolvePromise(promise, with: result)
            } catch is L.Interruption {
            } catch {
                promise.reject(L.materialize(builtins, error))
            }
        }
        return promise
    }

    /// `yield value` in a generator body: parks the body's fiber until `next`/`return`/`throw` resumes it.
    func yieldValue(_ value: L.Value, isAsync: Bool) async throws -> L.Value {
        guard let fiber = L.Fiber.current, let generator = fiber.generator else {
            throw L.syntaxError("yield is only valid in a generator.")
        }
        // An async generator awaits what it yields.
        let yielded = isAsync ? try await awaitValue(value) : value
        switch await generator.yieldFromBody(yielded, fiber: fiber) {
        case .outcome(.fulfilled(let v)): return v
        case .outcome(.rejected(let r)): throw L.Throw(r)
        case .returning(let v):
            // `return(v)` completes from the `yield`, through `finally` blocks; an async generator awaits `v`.
            throw L.ControlSignal.returnValue(isAsync ? try await awaitValue(v) : v)
        case .abort:
            throw L.Interruption("aborted")
        }
    }

    /// `yield* iterable`: delegates `next`/`throw`/`return` to the inner iterator until it is done; its final value
    /// is the expression's value.
    func yieldDelegate(_ iterable: L.Value, isAsync: Bool) async throws -> L.Value {
        guard let fiber = L.Fiber.current, let generator = fiber.generator else {
            throw L.syntaxError("yield is only valid in a generator.")
        }
        guard case .object(let source) = iterable else {
            throw L.typeError("\(L.describeValue(iterable)) is not iterable.")
        }
        var method: L.Value = .undefined
        if isAsync { method = try await redoRead(source, .symbol(L.AsyncIteratorSymbol), receiver: iterable) }
        if method.isNullish { method = try await redoRead(source, .symbol(L.IteratorSymbol), receiver: iterable) }
        guard L.isCallableValue(method) else { throw L.typeError("\(L.describeValue(iterable)) is not iterable.") }
        let iterator = try await callCallable(method, thisValue: iterable, args: [], site: nil)
        let iterObj = try L.requireIteratorObject(iterator)
        let next = try await redoRead(iterObj, .string("next"), receiver: iterator)
        var received: L.FiberInput = .outcome(.fulfilled(.undefined))
        while true {
            var result: L.Value
            switch received {
            case .outcome(.fulfilled(let v)):
                result = try await callCallable(next, thisValue: iterator, args: [v], site: nil)
            case .outcome(.rejected(let r)):
                let thrower = try await redoRead(iterObj, .string("throw"), receiver: iterator)
                guard L.isCallableValue(thrower) else {
                    let closer = try await redoRead(iterObj, .string("return"), receiver: iterator)
                    if L.isCallableValue(closer) { _ = try await callCallable(closer, thisValue: iterator, args: [], site: nil) }
                    _ = r
                    throw L.typeError("The iterator does not provide a 'throw' method.")
                }
                result = try await callCallable(thrower, thisValue: iterator, args: [r], site: nil)
            case .returning(let v):
                let closer = try await redoRead(iterObj, .string("return"), receiver: iterator)
                guard L.isCallableValue(closer) else { throw L.ControlSignal.returnValue(v) }
                result = try await callCallable(closer, thisValue: iterator, args: [v], site: nil)
                if isAsync { result = try await awaitValue(result) }
                let resultObj = try L.requireIteratorObject(result)
                if try await redoRead(resultObj, .string("done"), receiver: result).isTruthy {
                    throw L.ControlSignal.returnValue(try await redoRead(resultObj, .string("value"), receiver: result))
                }
                received = await generator.yieldFromBody(try await redoRead(resultObj, .string("value"), receiver: result), fiber: fiber)
                continue
            case .abort:
                throw L.Interruption("aborted")
            }
            if isAsync { result = try await awaitValue(result) }
            let resultObj = try L.requireIteratorObject(result)
            let done = try await redoRead(resultObj, .string("done"), receiver: result).isTruthy
            if done { return try await redoRead(resultObj, .string("value"), receiver: result) }
            let value = try await redoRead(resultObj, .string("value"), receiver: result)
            received = await generator.yieldFromBody(value, fiber: fiber)
        }
    }
}

// MARK: - Evaluator: ToPrimitive with program methods

extension CodemodeLanguage.Evaluator {
    /// Whether converting `obj` runs program code: a program `valueOf`/`toString` on its chain, or an array (whose
    /// join converts each element).
    func convertsInProgram(_ obj: L.Obj) -> Bool {
        if obj is L.Callable { return false }
        if obj is L.Arr { return true }
        for name in ["valueOf", "toString"] {
            if let slot = L.lookup(obj, .string(name)) {
                if L.isProgramAccessor(slot) { return true }
                if case .data(.object(let fn), _, _, _) = slot, fn is L.Fn { return true }
            }
        }
        return false
    }

    /// ToPrimitive (OrdinaryToPrimitive) that calls program `valueOf`/`toString` methods as program code; built-in
    /// objects keep their native conversion.
    public func toPrimitive(_ value: L.Value, hint: L.Hint) async throws -> L.Value {
        guard case .object(let obj) = value, convertsInProgram(obj) else {
            if case .object(let obj) = value { return obj.toPrimitive(hint: hint) }
            return value
        }
        let order = hint == .string ? ["toString", "valueOf"] : ["valueOf", "toString"]
        for name in order {
            let method = try await getValue(obj, .string(name), receiver: value)
            guard case .object(let fnObj) = method, fnObj is L.Callable else { continue }
            if let arr = obj as? L.Arr, fnObj is L.Builtin, name == "toString" {
                // Array.prototype.toString joins the elements, each converted as a string.
                var parts: [String] = []
                for item in arr.items {
                    parts.append(item.isNullish ? "" : try await toStringValue(item))
                }
                return .string(parts.joined(separator: ","))
            }
            let result = try await callCallable(method, thisValue: value, args: [], site: nil)
            if case .object = result { continue }
            return result
        }
        throw L.typeError("Cannot convert object to primitive value.")
    }

    /// ToString, running program conversions.
    public func toStringValue(_ value: L.Value) async throws -> String {
        if case .object(let obj) = value, convertsInProgram(obj) {
            return L.coerceToString(try await toPrimitive(value, hint: .string))
        }
        return L.coerceToString(value)
    }

    /// ToNumber, running program conversions.
    public func toNumberValue(_ value: L.Value) async throws -> Double {
        if case .object(let obj) = value, convertsInProgram(obj) {
            return L.coerceToNumber(try await toPrimitive(value, hint: .number))
        }
        return L.coerceToNumber(value)
    }
}
