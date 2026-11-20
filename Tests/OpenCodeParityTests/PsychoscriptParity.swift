import OpenCodeCore
import OpenCodeSchema

// Swift half of the psychoscript (Code Mode language) differential corpus, vector function
// `psychoscript/src/runtime.ts#execute` (`parity/vectors/psychoscript.json`).
//
// Mirrors `Tools/parity/psychoscript-oracle.ts`: the same fixed host globals, the same limits/translate options, and
// the same canonical outcome. This is a copy of `PsychoscriptParity` in `Sources/OpenCodeParityRunner/main.swift` (an
// executable target the tests cannot import), used by the Bun-free golden snapshot test; keep the copies (and the
// oracle) in sync.
enum PsychoscriptParity {
    static let executeFunction = "psychoscript/src/runtime.ts#execute"

    typealias Language = CodemodeLanguage

    struct Options: Sendable {
        var timeoutMs: Int?
        var maxOutputBytes: Int?
        var functions: Language.Translate.FunctionPolicy = .error
        var promises: Language.Translate.PromisePolicy = .error

        init(_ raw: OpenCodeSchema.JSONValue?) {
            guard case .object(let o)? = raw else { return }
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
            return s.isEmpty ? 0 : (Double(s) ?? .nan)
        default: return .nan
        }
    }

    /// The fixed host globals every corpus program sees (see `psychoscript-oracle.ts#globals`).
    static func globals() -> [String: Language.HostGlobalValue] {
        let double = Language.Host.fn({ args, _, _ in .number(number(args.first) * 2) })
        let echo = Language.Host.fn({ args, _, _ in
            guard let first = args.first, !first.isUndefined else { return .null }
            return first
        })
        let asyncDouble = Language.Host.fn({ args, _, _ in .number(number(args.first) * 2) }, options: .init(type: .async))
        let lookup = Language.Host.fn({ args, _, _ in
            if case .string(let name)? = args.first, name == "a" || name == "b" { return .string("item:\(name)") }
            let shown: String
            switch args.first {
            case .string(let s)?: shown = s
            case .number(let d)?: shown = d == d.rounded() && abs(d) < 1e15 ? String(Int64(d)) : String(d)
            case .null?: shown = "null"
            case .bool(let b)?: shown = b ? "true" : "false"
            default: shown = "undefined"
            }
            throw Language.Host.fail("NotFound", "No item \(shown)", suggestions: ["a", "b"])
        })
        let add = Language.Host.fn({ args, _, _ in
            .number(number(args.first) + number(args.count > 1 ? args[1] : nil))
        })
        return [
            "double": .fn(double),
            "echo": .fn(echo),
            "asyncDouble": .fn(asyncDouble),
            "lookup": .fn(lookup),
            "math2": .object(["add": .fn(add)]),
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

    /// Runs `program` through `CodemodeLanguage.makeRuntime(...).execute` and returns the canonical outcome.
    static func execute(_ program: String, options raw: OpenCodeSchema.JSONValue?) async throws -> OpenCodeSchema.JSONValue {
        let options = Options(raw)
        let runtime = try Language.makeRuntime(Language.RuntimeOptions(
            globals: { _ in globals() },
            limits: Language.Limits(timeoutMs: options.timeoutMs, maxOutputBytes: options.maxOutputBytes),
            translate: Language.Translate(functions: options.functions, promises: options.promises)
        ))
        let result = await runtime.execute(program, nil)
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
}
