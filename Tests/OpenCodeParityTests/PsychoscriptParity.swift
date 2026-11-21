import OpenCodeCore
import OpenCodeSchema
import Synchronization

// Swift half of the psychoscript (Code Mode language) differential corpus, vector function
// `psychoscript/src/runtime.ts#execute` (`parity/vectors/psychoscript.json`).
//
// Mirrors `Tools/parity/psychoscript-oracle.ts`: the same fixed Promise-API and Effect-API host globals, the same
// limits/translate/mode options, and the same canonical outcome. This is a copy of `PsychoscriptParity` in
// `Sources/OpenCodeParityRunner/main.swift` (an executable target the tests cannot import), used by the Bun-free
// golden snapshot test; keep the copies (and the oracle) in sync.
enum PsychoscriptParity {
    static let executeFunction = "psychoscript/src/runtime.ts#execute"

    typealias Language = CodemodeLanguage

    final class CounterService: Sendable {
        private struct State: Sendable { var count = 0 }
        private let state = Mutex(State())
        func next() -> Int {
            state.withLock { s in
                s.count += 1
                return s.count
            }
        }
    }

    static let counterKey = Language.EffectServiceKey<CounterService>("Counter")

    struct Options: Sendable {
        var mode: String = "promise"
        var timeoutMs: Int?
        var maxOutputBytes: Int?
        var functions: Language.Translate.FunctionPolicy = .error
        var promises: Language.Translate.PromisePolicy = .error

        init(_ raw: OpenCodeSchema.JSONValue?) {
            guard case .object(let o)? = raw else { return }
            if case .string(let m)? = o["mode"] { mode = m }
            timeoutMs = Self.int(o["timeoutMs"])
            maxOutputBytes = Self.int(o["maxOutputBytes"])
            if case .object(let t)? = o["translate"] {
                if case .string(let f)? = t["functions"], let p = Language.Translate.FunctionPolicy(rawValue: f) { functions = p }
                if case .string(let p)? = t["promises"], let q = Language.Translate.PromisePolicy(rawValue: p) { promises = q }
            }
        }

        private static func int(_ v: OpenCodeSchema.JSONValue?) -> Int? {
            switch v {
            case .int(let i)?: return Int(i)
            case .double(let d)?: return Int(d)
            default: return nil
            }
        }
    }

    /// JS `Number(v)` for the primitive copies the corpus passes to host functions.
    private static func number(_ v: Language.Value?) -> Double {
        switch v {
        case .number(let d)?: return d
        case .bool(let b)?: return b ? 1 : 0
        case .null?: return 0
        case .string(let s)?:
            guard let wf = s.wellFormedString else { return .nan }
            return wf.isEmpty ? 0 : (Double(wf) ?? .nan)
        default: return .nan
        }
    }

    private static func showPrimitive(_ v: Language.Value?) -> String {
        switch v {
        case .string(let s)?: return s.toHostString()
        case .number(let d)?: return d == d.rounded() && abs(d) < 1e15 ? String(Int64(d)) : String(d)
        case .null?: return "null"
        case .bool(let b)?: return b ? "true" : "false"
        default: return "undefined"
        }
    }

    /// Promise-API host globals (mirrors `psychoscript-oracle.ts#promiseGlobals`).
    static func promiseGlobals() -> [String: Language.HostGlobalValue] {
        let double = Language.Host.fn({ args, _, _ in .number(number(args.first) * 2) }, options: .init(length: 1))
        let echo = Language.Host.fn({ args, _, _ in
            guard let first = args.first, !first.isUndefined else { return .null }
            return first
        }, options: .init(length: 1))
        let asyncDouble = Language.Host.fn({ args, _, _ in .number(number(args.first) * 2) }, options: .init(type: .async, length: 1))
        let lookup = Language.Host.fn({ args, _, _ in
            if case .string(let name)? = args.first, name == "a" || name == "b" { return .string("item:\(name)") }
            throw Language.Host.fail("NotFound", "No item \(showPrimitive(args.first))", suggestions: ["a", "b"])
        }, options: .init(length: 1))
        let add = Language.Host.fn({ args, _, _ in
            .number(number(args.first) + number(args.count > 1 ? args[1] : nil))
        }, options: .init(length: 1))
        let namedFn = Language.Host.fn({ args, _, _ in .number(Double(args.count)) }, options: .init(name: "original", length: 2))
        let declaredFn = Language.Host.fn({ args, _, _ in .number(number(args.first) + 1) }, options: .init(name: "customAdd", length: 1))
        let later = Language.Host.fnReturn({ args, _, builtins in
            let result = Language.Value.number(number(args.first) + 1)
            let p = Language.PromiseObj(proto: builtins.Promise)
            p.attachTask(Task { .fulfilled(result) })
            return .promise(p)
        }, options: .init(length: 1))
        let refuse = Language.Host.fnReturn({ _, _, builtins in
            let hf = Language.Host.fail("Refused", "no", suggestions: ["retry"])
            let p = Language.PromiseObj(proto: builtins.Promise)
            p.attachHostTask(Task { (.rejected(Language.materialize(builtins, hf)), hf) })
            return .promise(p)
        }, options: .init(length: 0))
        let boom = Language.Host.fn({ _, _, _ in
            throw Language.HostError("boom")
        }, options: .init(length: 0))
        let plainGreet = Language.Host.plainFn(name: "plainGreet", length: 1) { args, _ in
            .value(.string(Language.JSString("hi:\(showPrimitive(args.first))")))
        }
        let box = Language.Host.fn({ args, _, builtins in
            let label = showPrimitive(args.first)
            let obj = Language.Obj(proto: builtins.Object)
            Language.define(obj, "read", Language.Host.plainValue(builtins: builtins, name: "read", length: 0) { _, _ in
                .value(.string(Language.JSString("box:\(label)")))
            })
            Language.define(obj, "anon", Language.Host.plainValue(builtins: builtins, name: "", length: 2) { innerArgs, innerBuiltins in
                let a: Language.Value = (innerArgs.count > 0 && !innerArgs[0].isNullish) ? innerArgs[0] : .null
                let b: Language.Value = (innerArgs.count > 1 && !innerArgs[1].isNullish) ? innerArgs[1] : .null
                return .value(.object(Language.Arr(proto: innerBuiltins.Array, items: [a, b])))
            })
            return .object(obj)
        }, options: .init(type: .syncThenable, length: 1))
        return [
            "double": .fn(double),
            "echo": .fn(echo),
            "asyncDouble": .fn(asyncDouble),
            "lookup": .fn(lookup),
            "math2": .object(["add": .fn(add)]),
            "namedFn": .fn(namedFn),
            "declaredFn": .fn(declaredFn),
            "later": .fn(later),
            "refuse": .fn(refuse),
            "boom": .fn(boom),
            "plainGreet": .plainFn(plainGreet),
            "box": .fn(box),
        ]
    }

    /// Effect-API host globals (mirrors `psychoscript-oracle.ts#effectGlobals`).
    static func effectGlobals() -> [String: Language.HostGlobalValue] {
        @Sendable func readEffect(_ arg: Language.Value?) -> Language.EffectTask<Language.HostReturn> {
            let p = showPrimitive(arg)
            if p == "missing" {
                return .fail(Language.EffectHost.fail("NotFound", "no missing"))
            }
            if p == "die" {
                return .die(Language.HostError("plain-boom"))
            }
            return .service(counterKey) { counter in
                .value(.string(Language.JSString("\(p):\(counter.next())")))
            }
        }
        let double = Language.EffectHost.fn({ args, _, _ in .value(.number(number(args.first) * 2)) }, options: .init(length: 1))
        let echo = Language.EffectHost.fn({ args, _, _ in
            guard let first = args.first, !first.isUndefined else { return .value(.null) }
            return .value(first)
        }, options: .init(length: 1))
        let asyncDouble = Language.EffectHost.fn({ args, _, _ in
            Language.EffectTask.succeed(.number(number(args.first) * 2))
        }, options: .init(type: .async, length: 1))
        let lookup = Language.EffectHost.fn({ args, _, _ in
            if case .string(let name)? = args.first, name == "a" || name == "b" { return .value(.string("item:\(name)")) }
            throw Language.EffectHost.fail("NotFound", "No item \(showPrimitive(args.first))", suggestions: ["a", "b"])
        }, options: .init(length: 1))
        let add = Language.EffectHost.fn({ args, _, _ in
            .value(.number(number(args.first) + number(args.count > 1 ? args[1] : nil)))
        }, options: .init(length: 1))
        let effectNamed = Language.EffectHost.fn({ args, _, _ in
            Language.EffectTask.succeed(.number(Double(args.count)))
        }, options: .init(name: "original", length: 2))
        let effectDeclared = Language.EffectHost.fn({ _, _, _ in
            Language.EffectTask.succeed(.number(1))
        }, options: .init(name: "named", length: 1))
        let effectNext = Language.EffectHost.fn({ _, _, _ in
            Language.EffectTask.service(counterKey) { .number(Double($0.next())) }
        }, options: .init(type: .async, idempotent: true, length: 0))
        let effectFail = Language.EffectHost.fn({ _, _, _ in
            Language.EffectTask.fail(Language.EffectHost.fail("NotFound", "no such thing", suggestions: ["try another"]))
        }, options: .init(length: 0))
        let effectTypedFail = Language.EffectHost.fn({ _, _, _ in
            Language.EffectTask.fail(Language.HostError("tagged"))
        }, options: .init(length: 0))
        let effectDie = Language.EffectHost.fn({ _, _, _ in
            Language.EffectTask.die(Language.HostError("kaboom"))
        }, options: .init(length: 0))
        let effectThrown = Language.EffectHost.fn({ _, _, _ in
            Language.EffectTask.sync { throw Language.HostError("thrown") }
        }, options: .init(length: 0))
        let fileFn = Language.EffectHost.fn({ args, _, builtins in
            let p = args.first
            let obj = Language.Obj(proto: builtins.Object)
            Language.define(obj, "text", Language.Host.plainValue(builtins: builtins, name: "text", length: 0) { _, _ in
                .effect(readEffect(p))
            })
            Language.define(obj, "size", Language.Host.plainValue(builtins: builtins, name: "size", length: 0) { _, _ in
                .effect(.succeed(.value(.number(3))))
            })
            return .value(.object(obj))
        }, options: .init(type: .syncThenable, length: 1))
        let globFn = Language.EffectHost.fn({ args, _, builtins in
            let pattern = showPrimitive(args.first)
            let obj = Language.Obj(proto: builtins.Object)
            Language.define(obj, "scan", Language.Host.plainValue(builtins: builtins, name: "scan", length: 0) { _, innerBuiltins in
                .effect(.succeed(.value(.object(Language.Arr(proto: innerBuiltins.Array, items: [.string(Language.JSString(pattern))])))))
            })
            return .value(.object(obj))
        }, options: .init(constructible: true, length: 1))
        let plainRead = Language.Host.plainFn(name: "read", length: 1) { args, _ in
            .effect(readEffect(args.first))
        }
        return [
            "double": .fn(double),
            "echo": .fn(echo),
            "asyncDouble": .fn(asyncDouble),
            "lookup": .fn(lookup),
            "math2": .object(["add": .fn(add)]),
            "effectNamed": .fn(effectNamed),
            "effectDeclared": .fn(effectDeclared),
            "effectNext": .fn(effectNext),
            "effectFail": .fn(effectFail),
            "effectTypedFail": .fn(effectTypedFail),
            "effectDie": .fn(effectDie),
            "effectThrown": .fn(effectThrown),
            "fsBox": .object([
                "file": .fn(fileFn),
                "Glob": .fn(globFn),
                "read": .plainFn(plainRead),
            ]),
        ]
    }

    private static func diagnostic(_ d: Language.Diagnostic) -> OpenCodeSchema.JSONValue {
        var out: [String: OpenCodeSchema.JSONValue] = ["kind": .string(d.kind), "message": .string(d.message)]
        if let loc = d.location {
            out["location"] = .object(["line": .int(Int64(loc.line)), "column": .int(Int64(loc.column))])
        }
        if let s = d.suggestions, !s.isEmpty {
            out["suggestions"] = .array(s.map { .string($0) })
        }
        return .object(out)
    }

    private static func canonicalResult(_ result: Language.Result) -> OpenCodeSchema.JSONValue {
        switch result {
        case .success(let value, let warnings, let logs, let truncated, _):
            var out: [String: OpenCodeSchema.JSONValue] = [
                "ok": .bool(true),
                "value": value,
                "logs": .array((logs ?? []).map { .string($0) }),
                "warnings": .array((warnings ?? []).map(diagnostic)),
            ]
            if truncated == true { out["truncated"] = .bool(true) }
            return .object(out)
        case .failure(let error, let logs, let truncated, _):
            var out: [String: OpenCodeSchema.JSONValue] = [
                "ok": .bool(false),
                "error": diagnostic(error),
                "logs": .array((logs ?? []).map { .string($0) }),
            ]
            if truncated == true { out["truncated"] = .bool(true) }
            return .object(out)
        }
    }

    /// Runs `program` through `CodemodeLanguage.makeRuntime` (or `EffectRuntime.make` when `mode == "effect"`)
    /// and returns the canonical outcome.
    static func execute(_ program: String, options raw: OpenCodeSchema.JSONValue?) async throws -> OpenCodeSchema.JSONValue {
        let options = Options(raw)
        if options.mode == "effect" {
            let runtime = try Language.EffectRuntime.make(Language.RuntimeOptions(
                globals: { _ in effectGlobals() },
                limits: Language.Limits(timeoutMs: options.timeoutMs, maxOutputBytes: options.maxOutputBytes),
                translate: Language.Translate(functions: options.functions, promises: options.promises)
            ))
            let services = Language.EffectServices.empty.providing(counterKey, CounterService())
            let result = try await runtime.execute(program, nil).run(services: services)
            return canonicalResult(result)
        }
        let runtime = try Language.makeRuntime(Language.RuntimeOptions(
            globals: { _ in promiseGlobals() },
            limits: Language.Limits(timeoutMs: options.timeoutMs, maxOutputBytes: options.maxOutputBytes),
            translate: Language.Translate(functions: options.functions, promises: options.promises)
        ))
        let result = await runtime.execute(program, nil)
        return canonicalResult(result)
    }
}
