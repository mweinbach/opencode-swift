import OpenCodeCore
import OpenCodeSchema
import Synchronization
import Testing

/// Comprehensive Swift Testing coverage for psychoscript v0.2.0 and v0.2.1 runtime & host-boundary parity:
/// Promise-based root API, `AbortSignal`/`AbortError`, sync-Promise signal abort, `HostWork`, `DurableFn`
/// suspend/resume/cancel, single-run `Program` + concurrent `suspend`, optional `EffectRuntime`/`EffectHost`
/// with services/defects/interrupts, Effect-from-plain-host-fn semantics, and `Host.fn` `name`/`length` preservation.
@Suite("Psychoscript v0.2.x Promise & Effect API parity")
struct CodemodePsychoscriptV02Tests {
    typealias L = CodemodeLanguage

    private final class Counter: Sendable {
        private struct S: Sendable { var n = 0 }
        private let m = Mutex(S())
        func next() -> Int {
            m.withLock { s in
                s.n += 1
                return s.n
            }
        }
    }

    private final class StringLog: Sendable {
        private struct S: Sendable { var items: [String] = [] }
        private let m = Mutex(S())
        func append(_ item: String) { m.withLock { $0.items.append(item) } }
        var items: [String] { m.withLock { $0.items } }
    }

    private final class Box<T: Sendable>: Sendable {
        private struct S: Sendable { var value: T }
        private let m: Mutex<S>
        init(_ initial: T) { self.m = Mutex(S(value: initial)) }
        var value: T {
            get { m.withLock { $0.value } }
            set { m.withLock { $0.value = newValue } }
        }
    }

    private static let counterKey = L.EffectServiceKey<Counter>("Counter")

    private static func number(_ v: L.Value?) -> Double {
        switch v {
        case .number(let d)?: return d
        case .string(let s)?: return s.wellFormedString.flatMap(Double.init) ?? .nan
        default: return .nan
        }
    }

    // MARK: - Promise API (v0.2.0)

    @Test("Promise API: execute, values, Promises, throws, and Host.fail rejections")
    func promiseApiExecuteAndHostFunctions() async throws {
        let bare = try L.makeRuntime()
        let simple = await bare.execute("return 1 + 2", nil)
        #expect(simple == .success(value: .int(3), warnings: nil, logs: nil, truncated: nil, metadata: .null))

        let runtime = try L.makeRuntime(L.RuntimeOptions(globals: { _ in
            [
                "double": .fn(L.Host.fn({ args, _, _ in .number(Self.number(args.first) * 2) }, options: .init(length: 1))),
                "later": .fn(L.Host.fnReturn({ args, _, builtins in
                    let p = L.PromiseObj(proto: builtins.Promise)
                    let out = L.Value.number(Self.number(args.first) + 1)
                    p.attachTask(Task { .fulfilled(out) })
                    return .promise(p)
                }, options: .init(length: 1))),
                "boom": .fn(L.Host.fn({ _, _, _ in throw L.HostError("boom") })),
                "refuse": .fn(L.Host.fnReturn({ _, _, builtins in
                    let hf = L.Host.fail("Refused", "no")
                    let p = L.PromiseObj(proto: builtins.Promise)
                    p.attachHostTask(Task { (.rejected(L.materialize(builtins, hf)), hf) })
                    return .promise(p)
                })),
            ]
        }))

        let r1 = await runtime.execute("return [double(21), await later(1)]", nil)
        guard case .success(let v1, _, _, _, _) = r1 else {
            Issue.record("Expected success, got \(r1)")
            return
        }
        #expect(v1 == .array([.int(42), .int(2)]))

        let r2 = await runtime.execute("try { boom() } catch (e) { return e.message }", nil)
        guard case .success(let v2, _, _, _, _) = r2 else {
            Issue.record("Expected caught boom, got \(r2)")
            return
        }
        #expect(v2 == .string("boom"))

        let r3 = await runtime.execute("await refuse()", nil)
        guard case .failure(let err3, _, _, _) = r3 else {
            Issue.record("Expected refusal failure, got \(r3)")
            return
        }
        #expect(err3.kind == "Refused")
        #expect(err3.message == "no")
    }

    @Test("Promise API: idempotent async call suspends to bytes and resumes in a fresh runtime with same key")
    func promiseApiIdempotentSuspendAndResume() async throws {
        let calls = StringLog()
        let entered = L.AbortController()
        @Sendable func makeRuntime(hang: Bool) throws -> L.Runtime {
            try L.makeRuntime(L.RuntimeOptions(globals: { _ in
                [
                    "fetchNumber": .fn(L.Host.fn({ args, call, _ in
                        calls.append(call.key)
                        if hang {
                            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                                _ = call.signal.onAbort { cont.resume() }
                                entered.abort()
                            }
                            throw L.Contract.Interrupted()
                        }
                        return .number(Self.number(args.first) * 10)
                    }, options: .init(type: .async, idempotent: true, length: 2))),
                ]
            }))
        }

        let program = try makeRuntime(hang: true).program("const a = await fetchNumber(1); return a + 1", L.ProgramOptions(runId: "r"))
        let runningTask = Task { try await program.run() }
        await entered.signal.waitUntilAborted()
        let suspended = try await program.suspend()
        let runOutcome = try await runningTask.value
        #expect(runOutcome == suspended)
        guard case .suspended(let saved) = suspended else {
            Issue.record("Expected suspended outcome, got \(suspended)")
            return
        }

        let bytes = try L.toBytes(saved.state)
        let resumed1 = try await makeRuntime(hang: false).resume(try L.fromBytes(bytes)).run()
        let resumed2 = try await makeRuntime(hang: false).resume(bytes).run()
        guard case .result(.success(let val1, _, _, _, _)) = resumed1,
              case .result(.success(let val2, _, _, _, _)) = resumed2 else {
            Issue.record("Expected resumed successes, got \(resumed1) and \(resumed2)")
            return
        }
        #expect(val1 == .int(11))
        #expect(val2 == .int(11))
        #expect(calls.items == ["r:0", "r:0", "r:0"])
    }

    @Test("Promise API: bad snapshot bytes throw SnapshotError, and Program runs only once")
    func promiseApiBadSnapshotAndRunOnce() async throws {
        let runtime = try L.makeRuntime()
        await #expect(throws: L.SnapshotError.self) {
            _ = try await runtime.resume([1, 2, 3]).run()
        }

        let prog = runtime.program("return 1")
        let first = try await prog.run()
        guard case .result(.success(let v, _, _, _, _)) = first else {
            Issue.record("Expected first run success")
            return
        }
        #expect(v == .int(1))
        await #expect(throws: (any Error).self) {
            _ = try await prog.run()
        }

        await #expect(throws: (any Error).self) {
            _ = try await runtime.program("return 1").suspend(L.SuspendOptions(maxBytes: -1))
        }
    }

    @Test("Promise API: durable function start, wait, cancel span suspend and abort")
    func promiseApiDurableSuspendAndCancel() async throws {
        let log = StringLog()
        let releaseBox = Box<(@Sendable (String) -> Void)?>(nil)
        let waitEntered = Box<L.AbortController>(L.AbortController())

        @Sendable func makeRuntime() throws -> L.Runtime {
            try L.makeRuntime(L.RuntimeOptions(globals: { _ in
                [
                    "job": .durableFn(L.Host.durableFn(
                        start: { args, _ in
                            let id = Int(Self.number(args.first))
                            log.append("start \(id)")
                            return .object(["id": .int(Int64(id))])
                        },
                        wait: { data, call, _ in
                            let id: Int
                            if case .object(let o) = data, case .int(let i) = o["id"] { id = Int(i) } else { id = 0 }
                            log.append("wait \(id)")
                            return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<L.Value, any Error>) in
                                final class Once: Sendable {
                                    private struct S: Sendable { var done = false }
                                    private let m = Mutex(S())
                                    func claim() -> Bool {
                                        m.withLock { s in
                                            if s.done { return false }
                                            s.done = true
                                            return true
                                        }
                                    }
                                }
                                let once = Once()
                                releaseBox.value = { text in
                                    if once.claim() { cont.resume(returning: .string(L.JSString(text))) }
                                }
                                _ = call.signal.onAbort {
                                    log.append("aborted wait")
                                    if once.claim() { cont.resume(throwing: L.Contract.Interrupted()) }
                                }
                                waitEntered.value.abort()
                            }
                        },
                        cancel: { data, _ in
                            let id: Int
                            if case .object(let o) = data, case .int(let i) = o["id"] { id = Int(i) } else { id = 0 }
                            log.append("cancel \(id)")
                        }
                    )),
                ]
            }))
        }

        let program = try makeRuntime().program("return await job(7)")
        let running = Task { try await program.run() }
        await waitEntered.value.signal.waitUntilAborted()
        let suspended = try await program.suspend()
        #expect(try await running.value == suspended)
        guard case .suspended(let saved) = suspended else {
            Issue.record("Expected suspended durable run")
            return
        }

        waitEntered.value = L.AbortController()
        let resumedTask = Task { try await makeRuntime().resume(try L.toBytes(saved.state)).run() }
        await waitEntered.value.signal.waitUntilAborted()
        releaseBox.value?("done")
        let resumed = try await resumedTask.value
        guard case .result(.success(let v, _, _, _, _)) = resumed else {
            Issue.record("Expected resumed durable success, got \(resumed)")
            return
        }
        #expect(v == .string("done"))
        #expect(log.items == ["start 7", "wait 7", "aborted wait", "wait 7"])

        waitEntered.value = L.AbortController()
        let controller = L.AbortController()
        let abortedTask = Task {
            try await makeRuntime().execute("return await job(8)", L.ExecuteOptions(signal: controller.signal))
        }
        await waitEntered.value.signal.waitUntilAborted()
        controller.abort("stop")
        await #expect(throws: L.AbortError.self) {
            _ = try await abortedTask.value
        }
        #expect(log.items.contains("cancel 8"))
    }

    @Test("Promise API: aborting rejects with AbortError with cause, and sync-Promise call sees signal aborted")
    func promiseApiAbortSignal() async throws {
        let seenSignal = Box<L.AbortSignal?>(nil)
        let entered = L.AbortController()
        let runtime = try L.makeRuntime(L.RuntimeOptions(globals: { _ in
            [
                "hang": .fn(L.Host.fnReturn({ _, call, builtins in
                    seenSignal.value = call.signal
                    entered.abort()
                    // A Promise that never settles (ignores signal): abort must not hang waiting for it.
                    return .promise(L.PromiseObj(proto: builtins.Promise))
                })),
            ]
        }))

        let controller = L.AbortController()
        let task = Task {
            try await runtime.execute("await hang()", L.ExecuteOptions(signal: controller.signal))
        }
        await entered.signal.waitUntilAborted()
        controller.abort("stop")
        do {
            _ = try await task.value
            Issue.record("Expected AbortError")
        } catch let abortErr as L.AbortError {
            #expect(abortErr.name == "AbortError")
            #expect((abortErr.cause as? String) == "stop")
        }
        #expect(seenSignal.value?.aborted == true)

        let program = runtime.program("await hang()")
        await #expect(throws: L.AbortError.self) {
            _ = try await program.run(L.RunOptions(signal: L.AbortSignal.abort("pre-aborted")))
        }
    }

    @Test("Promise API: timeout limit and translate option")
    func promiseApiTimeoutAndTranslate() async throws {
        let timeoutRuntime = try L.makeRuntime(L.RuntimeOptions(
            globals: { _ in
                ["hang": .fn(L.Host.fnReturn({ _, _, builtins in .promise(L.PromiseObj(proto: builtins.Promise)) }))]
            },
            limits: L.Limits(timeoutMs: 25)
        ))
        let timedOut = await timeoutRuntime.execute("await hang()", nil)
        guard case .failure(let err, _, _, _) = timedOut else {
            Issue.record("Expected timeout failure, got \(timedOut)")
            return
        }
        #expect(err.kind == "TimeoutExceeded")

        let globals: @Sendable (L.Run) -> L.Globals = { _ in
            ["echo": .fn(L.Host.fn({ args, _, _ in args.first ?? .null }))]
        }
        let code = "return echo({ a: 1, f() {} })"
        let rejected = await (try L.makeRuntime(L.RuntimeOptions(globals: globals))).execute(code, nil)
        #expect(!rejected.ok)
        let dropped = await (try L.makeRuntime(L.RuntimeOptions(
            globals: globals,
            translate: L.Translate(functions: .drop)
        ))).execute(code, nil)
        guard case .success(let val, _, _, _, _) = dropped else {
            Issue.record("Expected dropped success, got \(dropped)")
            return
        }
        #expect(val == .object(["a": .int(1)]))
    }

    // MARK: - Effect API (v0.2.0 & v0.2.1)

    @Test("Effect API: services reach host functions in execute, program.run, and resume.run")
    func effectApiServices() async throws {
        @Sendable func makeRuntime() throws -> L.EffectRuntime.Runtime {
            try L.EffectRuntime.make(L.RuntimeOptions(globals: { _ in
                [
                    "next": .fn(L.EffectHost.fn({ _, _, _ in
                        L.EffectTask.service(Self.counterKey) { .number(Double($0.next())) }
                    }, options: .init(type: .async, idempotent: true))),
                ]
            }))
        }

        let runtime = try makeRuntime()
        let r1 = try await runtime.execute("return [await next(), await next()]")
            .provideService(Self.counterKey, Counter())
            .run()
        guard case .success(let v1, _, _, _, _) = r1 else {
            Issue.record("Expected success, got \(r1)")
            return
        }
        #expect(v1 == .array([.int(1), .int(2)]))

        let r2 = try await runtime.program("return await next()").run()
            .provideService(Self.counterKey, Counter())
            .run()
        guard case .result(.success(let v2, _, _, _, _)) = r2 else {
            Issue.record("Expected program.run success, got \(r2)")
            return
        }
        #expect(v2 == .int(1))

        let hangEntered = L.AbortController()
        let hangRuntime = try L.EffectRuntime.make(L.RuntimeOptions(globals: { _ in
            ["next": .fn(L.EffectHost.fn({ _, _, _ in
                L.EffectTask<L.Value> { _, signal in
                    hangEntered.abort()
                    await signal.waitUntilAborted()
                    return .interrupt
                }
            }, options: .init(type: .async, idempotent: true)))]
        }))
        let prog = hangRuntime.program("return (await next()) + 10", L.ProgramOptions(runId: "r"))
        let runTask = Task { try await prog.run().run() }
        await hangEntered.signal.waitUntilAborted()
        let suspended = try await prog.suspend().run()
        #expect(try await runTask.value == suspended)
        guard case .suspended(let saved) = suspended else {
            Issue.record("Expected suspended outcome")
            return
        }

        let resumed = try await makeRuntime().resume(saved.state).run()
            .provideService(Self.counterKey, Counter())
            .run()
        guard case .result(.success(let v3, _, _, _, _)) = resumed else {
            Issue.record("Expected resumed success, got \(resumed)")
            return
        }
        #expect(v3 == .int(11))
    }

    @Test("Effect API: services reach durable start, wait, and cancel; failing cancel keeps run result")
    func effectApiDurableServicesAndFailures() async throws {
        let seen = StringLog()
        @Sendable func tag(_ part: String) -> L.EffectTask<Void> {
            .service(Self.counterKey) { c in seen.append("\(part)\(c.next())") }
        }
        let runtime = try L.EffectRuntime.make(L.RuntimeOptions(globals: { _ in
            [
                "job": .durableFn(L.EffectHost.durableFn(
                    start: { _, _ in tag("start").map { .string("d") } },
                    wait: { data, _, _ in tag("wait").map { .string(L.JSString(data == .string("d") ? "d" : "")) } },
                    cancel: { _, _ in tag("cancel") }
                )),
                "hang": .durableFn(L.EffectHost.durableFn(
                    start: { _, _ in tag("start").map { .string("h") } },
                    wait: { _, _, _ in .never },
                    cancel: { _, _ in tag("cancel") }
                )),
                "badCancel": .durableFn(L.EffectHost.durableFn(
                    start: { _, _ in .succeed(.string("d")) },
                    wait: { _, _, _ in .never },
                    cancel: { _, _ in
                        L.EffectTask { _, _ in
                            seen.append("badCancel")
                            return .fail(L.EffectHost.fail("CancelFailed", "c"))
                        }
                    }
                )),
            ]
        }))

        let r1 = try await runtime.execute("return await job()").provideService(Self.counterKey, Counter()).run()
        guard case .success(let v1, _, _, _, _) = r1 else { Issue.record("Expected d"); return }
        #expect(v1 == .string("d"))

        let r2 = try await runtime.execute("hang(); return 1").provideService(Self.counterKey, Counter()).run()
        guard case .success(let v2, _, _, _, _) = r2 else { Issue.record("Expected 1"); return }
        #expect(v2 == .int(1))
        #expect(seen.items == ["start1", "wait2", "start1", "cancel2"])

        let r3 = try await runtime.execute("badCancel(); return 1").provideService(Self.counterKey, Counter()).run()
        guard case .success(let v3, _, _, _, _) = r3 else { Issue.record("Expected 1 despite failing cancel"); return }
        #expect(v3 == .int(1))
        #expect(seen.items.contains("badCancel"))
    }

    @Test("Effect API: host failures, typed errors, defects, interrupts, onInterrupt, and span/log annotations")
    func effectApiErrorMappingInterruptsAndContext() async throws {
        let interruptLog = StringLog()
        let contextSeen = StringLog()
        let hangStarted = L.AbortController()
        let runtime = try L.EffectRuntime.make(L.RuntimeOptions(globals: { _ in
            [
                "missing": .fn(L.EffectHost.fn({ _, _, _ in
                    .fail(L.EffectHost.fail("NotFound", "no such thing", suggestions: ["try another"]))
                })),
                "tagged": .fn(L.EffectHost.fn({ _, _, _ in
                    .fail(L.HostError("tagged"))
                })),
                "die": .fn(L.EffectHost.fn({ _, _, _ in
                    .die(L.HostError("kaboom"))
                })),
                "thrown": .fn(L.EffectHost.fn({ _, _, _ in
                    .sync { throw L.HostError("thrown") }
                })),
                "interrupt": .fn(L.EffectHost.fn({ _, _, _ in
                    L.EffectTask<L.Value>.interrupt
                })),
                "hang": .fn(L.EffectHost.fn({ _, _, _ in
                    L.EffectTask<L.Value> { _, signal in
                        hangStarted.abort()
                        await signal.waitUntilAborted()
                        return .interrupt
                    }.onInterrupt { interruptLog.append("interrupted") }
                })),
                "probe": .fn(L.EffectHost.fn({ _, _, _ in
                    L.EffectTask<L.Value>.withServices { services in
                        contextSeen.append(services.spanName ?? "none")
                        if case .string(let req)? = services.logAnnotations["request"] {
                            contextSeen.append(req)
                        }
                        return .success(.undefined)
                    }
                })),
            ]
        }))

        // HostFailure, typed error, defect, sync throw
        let rMissing = try await runtime.execute("\nmissing()").run()
        guard case .failure(let eMissing, _, _, _) = rMissing else { Issue.record("Expected failure"); return }
        #expect(eMissing.kind == "NotFound")
        #expect(eMissing.message == "no such thing")
        #expect(eMissing.location == nil)
        #expect(eMissing.suggestions == ["try another"])

        let rTagged = try await runtime.execute("tagged()").run()
        guard case .failure(let eTagged, _, _, _) = rTagged else { Issue.record("Expected failure"); return }
        #expect(eTagged.kind == "ExecutionFailure")
        #expect(eTagged.message == "Error: tagged")
        #expect(eTagged.location == nil)

        for name in ["die", "thrown"] {
            let res = try await runtime.execute("\n\(name)()").run()
            guard case .failure(let err, _, _, _) = res else { Issue.record("Expected defect failure"); return }
            #expect(err.kind == "ExecutionFailure")
            #expect(err.location == L.SourceLocation(line: 2, column: 1))
        }

        // Effect.interrupt bypasses try/catch and finally
        for code in ["interrupt()", "try { interrupt() } catch { return 1 }", "try { interrupt() } finally { console.log('ran') }"] {
            let exit = await runtime.execute(code).runExit()
            guard case .interrupt = exit else {
                Issue.record("Expected .interrupt for \(code), got \(exit)")
                return
            }
        }

        // Interrupting execute interrupts the in-flight Effect and waits for onInterrupt cleanup
        let ctrl = L.AbortController()
        let execTask = Task { await runtime.execute("hang()").runExit(signal: ctrl.signal) }
        await hangStarted.signal.waitUntilAborted()
        ctrl.abort()
        let hangExit = await execTask.value
        guard case .interrupt = hangExit else {
            Issue.record("Expected .interrupt when aborting hang(), got \(hangExit)")
            return
        }
        #expect(interruptLog.items == ["interrupted"])

        // Span and log annotations reach host functions via EffectServices
        _ = try await runtime.execute("probe()")
            .annotateLog("request", .string("r1"))
            .withSpan("outer")
            .run()
        #expect(contextSeen.items == ["outer", "r1"])
    }

    @Test("v0.2.1: plain host functions inside results and globals run Effects with services, and host fn name/length are kept")
    func effectFromPlainHostFnsAndHostFnNameLength() async throws {
        @Sendable func read(_ arg: L.Value?) -> L.EffectTask<L.HostReturn> {
            let path: String
            if case .string(let s)? = arg { path = s.toHostString() } else { path = "" }
            if path == "missing" {
                return .fail(L.EffectHost.fail("NotFound", "no missing"))
            }
            return .service(Self.counterKey) { c in
                .value(.string(L.JSString("\(path):\(c.next())")))
            }
        }

        let effectRuntime = try L.EffectRuntime.make(L.RuntimeOptions(globals: { _ in
            [
                "f": .fn(L.EffectHost.fn({ args, _, _ in .succeed(.number(Double(args.count))) }, options: .init(name: "original", length: 2))),
                "g": .fn(L.EffectHost.fn({ _, _, _ in .succeed(.number(1)) }, options: .init(name: "named", length: 1))),
                "Bun": .object([
                    "file": .fn(L.EffectHost.fn({ args, _, builtins in
                        let path = args.first
                        let obj = L.Obj(proto: builtins.Object)
                        L.define(obj, "text", L.Host.plainValue(builtins: builtins, name: "text", length: 0) { _, _ in .effect(read(path)) })
                        L.define(obj, "size", L.Host.plainValue(builtins: builtins, name: "size", length: 0) { _, _ in .effect(.succeed(.value(.number(3)))) })
                        return .value(.object(obj))
                    }, options: .init(type: .syncThenable, length: 1))),
                    "Glob": .fn(L.EffectHost.fn({ args, _, builtins in
                        let pat = args.first ?? .string("")
                        let obj = L.Obj(proto: builtins.Object)
                        L.define(obj, "scan", L.Host.plainValue(builtins: builtins, name: "scan", length: 0) { _, b in
                            .effect(.succeed(.value(.object(L.Arr(proto: b.Array, items: [pat])))))
                        })
                        return .value(.object(obj))
                    }, options: .init(constructible: true, length: 1))),
                    "read": .plainFn(L.Host.plainFn(name: "read", length: 1) { args, _ in .effect(read(args.first)) }),
                ]),
            ]
        }))

        let promiseRuntime = try L.makeRuntime(L.RuntimeOptions(globals: { _ in
            [
                "f": .fn(L.Host.fn({ args, _, _ in .number(Double(args.count)) }, options: .init(name: "original", length: 2))),
                "g": .fn(L.Host.fn({ _, _, _ in .number(1) }, options: .init(name: "named", length: 1))),
            ]
        }))

        let metaCode = "return [f.name, f.length, g.name, g.length]"
        let effMeta = try await effectRuntime.execute(metaCode).run()
        let promMeta = await promiseRuntime.execute(metaCode, nil)
        guard case .success(let ev, _, _, _, _) = effMeta,
              case .success(let pv, _, _, _, _) = promMeta else {
            Issue.record("Expected metadata successes")
            return
        }
        #expect(ev == .array([.string("original"), .int(2), .string("named"), .int(1)]))
        #expect(pv == .array([.string("original"), .int(2), .string("named"), .int(1)]))

        @Sendable func exec(_ code: String) async throws -> L.Result {
            try await effectRuntime.execute(code).provideService(Self.counterKey, Counter()).run()
        }

        if case .success(let v, _, _, _, _) = try await exec("return await Bun.file('a').text()") {
            #expect(v == .string("a:1"))
        } else { Issue.record("Expected a:1") }

        if case .success(let v, _, _, _, _) = try await exec("const f = Bun.file('a'); return [f.text(), f.text(), f.size()]") {
            #expect(v == .array([.string("a:1"), .string("a:2"), .int(3)]))
        } else { Issue.record("Expected [a:1, a:2, 3]") }

        if case .success(let v, _, _, _, _) = try await exec("return (await Bun.file('b')).text()") {
            #expect(v == .string("b:1"))
        } else { Issue.record("Expected b:1") }

        if case .success(let v, _, _, _, _) = try await exec("return Bun.read('c')") {
            #expect(v == .string("c:1"))
        } else { Issue.record("Expected c:1") }

        if case .success(let v, _, _, _, _) = try await exec("return new Bun.Glob('*.ts').scan()") {
            #expect(v == .array([.string("*.ts")]))
        } else { Issue.record("Expected [*.ts]") }

        if case .success(let v, _, _, _, _) = try await exec("try { Bun.file('missing').text() } catch (e) { return e.message }") {
            #expect(v == .string("no missing"))
        } else { Issue.record("Expected caught no missing") }

        if case .failure(let err, _, _, _) = try await exec("await Bun.file('missing').text()") {
            #expect(err.kind == "NotFound")
            #expect(err.message == "no missing")
        } else { Issue.record("Expected NotFound failure") }
    }
}
