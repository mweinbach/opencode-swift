import Testing
import OpenCodeCore
import OpenCodeSchema

/// Regression tests for the Code Mode language bugs the psychoscript differential corpus
/// (`parity/vectors/psychoscript.json`) found; each asserts upstream psychoscript v0.1.2's behavior.
@Suite("Code Mode language: psychoscript corpus regressions")
struct CodemodeCorpusRegressionTests {
    private struct Outcome {
        let ok: Bool
        let value: JSONValue
        let error: String
        let kind: String
        let logs: [String]
        let warnings: [String]
    }

    private func run(_ code: String, timeoutMs: Int? = nil, globals: CodemodeLanguage.Globals = [:]) async throws -> Outcome {
        let runtime = try CodemodeLanguage.makeRuntime(CodemodeLanguage.RuntimeOptions(
            globals: { _ in globals },
            limits: CodemodeLanguage.Limits(timeoutMs: timeoutMs)
        ))
        switch await runtime.execute(code, nil) {
        case .success(let value, let warnings, let logs, _, _):
            return Outcome(ok: true, value: value, error: "", kind: "", logs: logs ?? [], warnings: (warnings ?? []).map(\.message))
        case .failure(let error, let logs, _, _):
            return Outcome(ok: false, value: .null, error: error.message, kind: error.kind, logs: logs ?? [], warnings: [])
        }
    }

    private func strings(_ items: String...) -> JSONValue { .array(items.map { .string($0) }) }

    @Test("Microtasks run in order across await and then; async bodies start synchronously")
    func microtaskOrder() async throws {
        let out = try await run("""
        const log = [];
        Promise.resolve().then(() => log.push("then1")).then(() => log.push("then2"));
        (async () => { log.push("start"); await null; log.push("after1"); await null; log.push("after2") })();
        log.push("sync");
        await null; await null; await null; await null;
        return log;
        """)
        #expect(out.value == strings("start", "sync", "then1", "after1", "then2", "after2"))
    }

    @Test("Generators run lazily: next(v) feeds yield, return() runs finally, infinite generators work")
    func lazyGenerators() async throws {
        let out = try await run("""
        function* g() { const x = yield 1; try { yield x * 2 } finally { yield "cleanup" } }
        const a = g();
        const steps = [a.next().value, a.next(5).value, a.return("r").value, a.next().value];
        function* nat() { let i = 0; while (true) yield i++ }
        const taken = nat().filter(x => x % 2).map(x => x * x).take(3).toArray();
        const log = [];
        function* closing() { try { yield 1; yield 2 } finally { log.push("closed") } }
        for (const x of closing()) { log.push(x); break }
        return { steps, taken, log };
        """)
        #expect(out.value == .object([
            "steps": .array([.int(1), .int(10), .string("cleanup"), .string("r")]),
            "taken": .array([.int(1), .int(9), .int(25)]),
            "log": .array([.int(1), .string("closed")]),
        ]))
    }

    @Test("A promise that can never settle fails at once instead of hanging; timeouts cannot be caught")
    func stuckAndTimeout() async throws {
        let stuck = try await run("await new Promise(() => {})")
        #expect(!stuck.ok)
        #expect(stuck.error.hasPrefix("Error: The program is waiting on a promise that can never settle"))
        let timeout = try await run("try { while (true) {} } catch (e) { return 'caught' }", timeoutMs: 50)
        #expect(timeout.kind == "TimeoutExceeded")
        #expect(timeout.error == "Execution timed out after 50ms.")
        let long = try await run("let s = 0; for (let i = 0; i < 1200000; i++) s += 1; return s")
        #expect(long.value == .int(1_200_000))
    }

    @Test("Unhandled rejections warn; un-awaited host work does not")
    func warnings() async throws {
        let out = try await run("Promise.reject(new Error('floating')); await null; new Promise(() => {}); return 1")
        #expect(out.warnings == ["Unhandled rejection from an un-awaited promise: Error: floating"])
    }

    @Test("Unsupported syntax and BigInt fail only where they run")
    func unsupportedAtRunTime() async throws {
        let unreached = try await run("function f() { with (x) {} } function g() { return 5n } return typeof f")
        #expect(unreached.value == .string("function"))
        let reached = try await run("console.log('before'); class A { #x = 1 }")
        #expect(reached.kind == "UnsupportedSyntax")
        #expect(reached.logs == ["before"])
        #expect(reached.error.hasPrefix("SyntaxError: Private class members (#name) are not supported."))
        let bigint = try await run("const n = 10n")
        #expect(bigint.error == "TypeError: BigInt literals are not supported. (line 1, col 11)")
    }

    @Test("Number parsing and formatting follow ECMA-262")
    func numbers() async throws {
        let out = try await run("""
        return [Number("0x1f"), Number("0b101"), Number("nan"), (1.005).toFixed(2), (-1.5).toFixed(0),
          (123.456).toPrecision(4), (1234.5678).toExponential(2), (0.5).toString(2), (-255).toString(36), Math.round(-0.4) === 0 && 1 / Math.round(-0.4)].map(String)
        """)
        #expect(out.value == strings("31", "5", "NaN", "1.00", "-2", "123.5", "1.23e+3", "0.1", "-73", "-Infinity"))
    }

    @Test("Callee errors name the chain and point at its start")
    func calleeErrors() async throws {
        let out = try await run("const o = { a: 1 };\no.a()")
        #expect(out.error == "TypeError: o.a is not a function. (line 2, col 1)")
        let missing = try await run("try { missingName } catch (e) { return e.message }")
        #expect(missing.value == .string("Unknown identifier 'missingName'."))
    }

    @Test("Host arguments are copies with depth, function and promise checks")
    func hostArguments() async throws {
        let echo = CodemodeLanguage.Host.fn({ args, _, _ in args.first ?? .null })
        let globals: CodemodeLanguage.Globals = ["echo": .fn(echo)]
        let copied = try await run("const o = { n: 1 }; const r = echo(o); r.n = 2; return [o.n, r === o]", globals: globals)
        #expect(copied.value == .array([.int(1), .bool(false)]))
        let fn = try await run("echo({ f() {} })", globals: globals)
        #expect(fn.error == "TypeError: Argument 1 to echo contains a function, which cannot be passed to the host. (line 1, col 1)")
        let deep = try await run("let o = 1; for (let i = 0; i < 40; i++) o = [o]; try { echo(o) } catch (e) { return e.message }", globals: globals)
        #expect(deep.value == .string("Argument 1 to echo exceeds the maximum value depth of 32."))
    }

    @Test("RegExp named groups, replacement patterns and split with captures")
    func regexps() async throws {
        let out = try await run("""
        const m = /(?<y>\\d{4})-(?<m>\\d{2})/.exec("on 2024-05!");
        return [m.groups.y, "2024-05".replace(/(?<y>\\d+)-(?<m>\\d+)/, "$<m>/$<y>"), "abc".replace("b", "[$&]"),
          "a1b2".split(/(\\d)/).join("|"), "abc".split(/(?:)/u).join("|"), String(new RegExp("x/y", "g")), new RegExp("").source]
        """)
        #expect(out.value == strings("2024", "05/2024", "a[b]c", "a|1|b|2|", "a|b|c", "/x\\/y/g", "(?:)"))
    }

    @Test("JSON.stringify runs replacers, toJSON and getters, and indents with strings")
    func json() async throws {
        let out = try await run("""
        const e = new Error("m"); e.code = 7;
        return [JSON.stringify({ a: 1, b: 2, c: { a: 3 } }, ["a", "c"]), JSON.stringify([1, 2], null, "--"),
          JSON.stringify(e), JSON.stringify({ get v() { return 5 } }), JSON.parse('{"a":1}', (k, v) => (typeof v === "number" ? v + 1 : v)).a]
        """)
        #expect(out.value == .array([
            .string(#"{"a":1,"c":{"a":3}}"#), .string("[\n--1,\n--2\n]"), .string(#"{"name":"Error","message":"m","code":7}"#),
            .string(#"{"v":5}"#), .int(2),
        ]))
    }

    @Test("Objects convert through program valueOf/toString; arrays keep holes")
    func conversionsAndHoles() async throws {
        let out = try await run("""
        const o = { valueOf() { return 42 }, toString() { return "str" } };
        const a = [1, , 3];
        return [o + 1, `${o}`, o * 2, 1 in a, Object.keys(a), a.indexOf(undefined)];
        """)
        #expect(out.value == .array([.int(43), .string("str"), .int(84), .bool(false), strings("0", "2"), .int(-1)]))
    }

    @Test("Dates parse offsets and clip times; Buffers decode encodings and share memory with views")
    func datesAndBytes() async throws {
        let out = try await run("""
        const u = new Uint8Array([1, 2, 3]); u.subarray(1)[0] = 9;
        return [Date.parse("2020-01-01T00:00:00.000+02:00"), String(new Date(8.64e15 + 1).getTime()),
          new Date(0).toUTCString(), Buffer.from("6869", "hex").toString(), Buffer.from("héllo").toString("base64url"), Array.from(u)];
        """)
        #expect(out.value == .array([
            .int(1_577_829_600_000), .string("NaN"), .string("Thu, 01 Jan 1970 00:00:00 GMT"), .string("hi"), .string("aMOpbGxv"),
            .array([.int(1), .int(9), .int(3)]),
        ]))
    }
}
