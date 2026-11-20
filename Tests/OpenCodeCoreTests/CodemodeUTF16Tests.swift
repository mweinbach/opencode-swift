import Testing
import OpenCodeCore
import OpenCodeSchema

/// Tests for Code Mode's UTF-16 `JSString` semantics and Swift host/JSON boundary safety.
/// (No `Foundation` import in this file per macOS CLT cross-import rule.)
@Suite("Code Mode UTF-16 string & host boundary")
struct CodemodeUTF16Tests {
    private func run(
        _ code: String,
        globals: CodemodeLanguage.Globals = [:],
        maxOutputBytes: Int? = nil
    ) async throws -> CodemodeLanguage.Result {
        let runtime = try CodemodeLanguage.makeRuntime(CodemodeLanguage.RuntimeOptions(
            globals: { _ in globals },
            limits: CodemodeLanguage.Limits(maxOutputBytes: maxOutputBytes)
        ))
        return await runtime.execute(code, nil)
    }

    @Test("JSString hybrid storage canonicalizes well-formed and re-paired strings")
    func jsStringCanonicalization() {
        let hi = CodemodeLanguage.JSString(unit: 0xD83D)
        let lo = CodemodeLanguage.JSString(unit: 0xDE00)
        #expect(!hi.isWellFormed)
        #expect(!lo.isWellFormed)
        #expect(hi.utf16Count == 1)
        #expect(hi.unit(at: 0) == 0xD83D)

        let repaired = hi + lo
        #expect(repaired.isWellFormed)
        #expect(repaired == "😀")
        #expect(repaired.utf16Count == 2)

        // Exact UTF-16 equality vs Swift canonical equivalence
        let composed = CodemodeLanguage.JSString("\u{00E9}")
        let decomposed = CodemodeLanguage.JSString("e\u{0301}")
        #expect(composed != decomposed)
        #expect(CodemodeLanguage.JSString.compareUTF16(composed, decomposed) != 0)

        // Lone surrogates are distinct from U+FFFD and from each other
        let fffd = CodemodeLanguage.JSString("\u{FFFD}")
        let d800 = CodemodeLanguage.JSString(unit: 0xD800)
        let d801 = CodemodeLanguage.JSString(unit: 0xD801)
        #expect(d800 != fffd)
        #expect(d800 != d801)
        #expect(d800 < d801)
        #expect(d800.toWellFormedString() == "\u{FFFD}")
        #expect(d800.toWellFormed() == fffd)
    }

    @Test("Host boundary: returning lone surrogates to Swift JSONValue never crashes and replaces unpaired units with U+FFFD")
    func hostBoundaryReturnValues() async throws {
        // Direct top-level lone surrogate return
        let res1 = try await run(#"return "\ud800""#)
        guard case .success(let val1, _, _, _, _) = res1 else {
            Issue.record("Expected success returning lone surrogate")
            return
        }
        #expect(val1 == .string("\u{FFFD}"))

        // Object with lone surrogate keys and values, plus valid pair
        let res2 = try await run(#"return { ["\ud800"]: "\udc00", ok: "\ud83d\ude00", mixed: "a\ud800b" }"#)
        guard case .success(let val2, _, _, _, _) = res2 else {
            Issue.record("Expected success returning object with lone surrogates")
            return
        }
        #expect(val2 == .object([
            "\u{FFFD}": .string("\u{FFFD}"),
            "ok": .string("😀"),
            "mixed": .string("a\u{FFFD}b"),
        ]))

        // maxOutputBytes truncation on a lone-surrogate return value stays safe
        let res3 = try await run(#"return "\ud800".repeat(20)"#, maxOutputBytes: 12)
        guard case .success(let val3, _, _, let truncated, _) = res3 else {
            Issue.record("Expected success with truncation")
            return
        }
        #expect(truncated == true)
        if case .string(let s) = val3 {
            #expect(s.contains("[result truncated:"))
        } else {
            Issue.record("Expected truncated string value")
        }
    }

    @Test("Host boundary: Host.Fn receives and returns lone surrogates losslessly; console.log and thrown errors sanitize safely")
    func hostBoundaryCallbacksLogsAndErrors() async throws {
        // Host.Fn operates on CodemodeLanguage.Value (JSString), preserving lone surrogates round-trip
        let echo = CodemodeLanguage.Host.fn({ args, _, _ in args.first ?? .null })
        let res1 = try await run(
            #"const r = echo({ ["\ud800"]: "\ud83d" }); return [r["\ud800"].charCodeAt(0), (r["\ud800"] + "\ude00") === "😀", r["\ud800"].isWellFormed()]"#,
            globals: ["echo": .fn(echo)]
        )
        guard case .success(let val1, _, _, _, _) = res1 else {
            Issue.record("Expected success for Host.Fn round-trip")
            return
        }
        #expect(val1 == .array([.int(0xD83D), .bool(true), .bool(false)]))

        // console.log top-level lone surrogate becomes U+FFFD at Swift logs: [String] boundary; nested object stays JSON-escaped
        let res2 = try await run(#"console.log("\ud800", { ["\ud800"]: "\udc00" }); return true"#)
        guard case .success(_, _, let logs, _, _) = res2 else {
            Issue.record("Expected success for console.log")
            return
        }
        #expect(logs == ["\u{FFFD} {\"\\ud800\":\"\\udc00\"}"])

        // Throwing a lone surrogate string or Error with lone surrogate message never crashes
        let res3 = try await run(#"throw new Error("bad:\ud800")"#)
        guard case .failure(let err3, _, _, _) = res3 else {
            Issue.record("Expected failure for thrown error")
            return
        }
        #expect(err3.message == "Error: bad:\u{FFFD}")

        let res4 = try await run(#"throw "\udc00""#)
        guard case .failure(let err4, _, _, _) = res4 else {
            Issue.record("Expected failure for thrown lone surrogate string")
            return
        }
        #expect(err4.message == "Uncaught: \u{FFFD}")
    }

    @Test("RegExp built-ins continue working cleanly on strings containing lone surrogates")
    func regexCallSiteCompatibility() async throws {
        let res = try await run(#"""
        const s = "a\ud800b123c\udc00d";
        const m = s.match(/b(\d+)c/);
        const rep = s.replace(/\d+/, "X");
        const sp = "x\ud800,y\udc00".split(/,/);
        return [
            m[0], m[1], m.index, m.input.charCodeAt(1),
            rep.charCodeAt(1), rep.slice(2, 5), rep.charCodeAt(5),
            sp.length, sp[0].charCodeAt(1), sp[1].charCodeAt(1),
            /\d+/.test(s), s.search(/\d+/)
        ];
        """#)
        guard case .success(let val, _, _, _, _) = res else {
            Issue.record("Expected regex interop to succeed, got \(res)")
            return
        }
        #expect(val == .array([
            .string("b123c"), .string("123"), .int(2), .int(0xD800),
            .int(0xD800), .string("bXc"), .int(0xDC00),
            .int(2), .int(0xD800), .int(0xDC00),
            .bool(true), .int(3),
        ]))
    }
}
