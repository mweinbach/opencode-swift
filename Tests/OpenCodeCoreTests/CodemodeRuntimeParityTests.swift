import Testing
import OpenCodeCore
import OpenCodeSchema

/// test262-style coverage for the psychoscript v0.1.2 runtime/stdlib semantics ported into the Code Mode evaluator:
/// program accessors and property descriptors, the `withReads` read-ahead, error `stack`, the array-iteration
/// protector, Buffer/Uint8Array derivation and base64 options, locale-aware comparison and date formatting.
@Suite("Code Mode runtime & stdlib parity (psychoscript v0.1.2)")
struct CodemodeRuntimeParityTests {
    private func run(_ code: String) async throws -> [String: JSONValue] {
        let result = try await CodemodeEngine.execute(.init(code: code))
        guard case .success(let ok) = result, case .object(let dict) = ok.value else {
            Issue.record("Expected a success object, got \(result)")
            return [:]
        }
        return dict
    }

    private func failure(_ code: String) async throws -> String {
        let result = try await CodemodeEngine.execute(.init(code: code))
        guard case .failure(let f) = result else {
            Issue.record("Expected a failure, got \(result)")
            return ""
        }
        return f.error.message
    }

    @Test("defineProperty / getOwnPropertyDescriptor follow ValidateAndApplyPropertyDescriptor")
    func propertyDescriptors() async throws {
        let dict = try await run("""
        const o = {};
        Object.defineProperty(o, "fixed", { value: 1 });
        const d = Object.getOwnPropertyDescriptor(o, "fixed");
        let redefine = "";
        try { Object.defineProperty(o, "fixed", { value: 2 }); } catch (e) { redefine = e.message; }
        let same = "ok";
        try { Object.defineProperty(o, "fixed", { value: 1 }); } catch (e) { same = e.message; }
        let readonly = "";
        try { o.fixed = 3; } catch (e) { readonly = e.message; }
        let mixed = "";
        try { Object.defineProperty({}, "x", { value: 1, get: function () { return 1; } }); } catch (e) { mixed = e.message; }
        const created = Object.create({ inherited: true }, { own: { value: 5, enumerable: true } });
        const many = Object.defineProperties({}, { a: { value: 1, enumerable: true }, b: { value: 2 } });
        return {
          d, redefine, same, readonly, mixed,
          createdOwn: created.own, createdKeys: Object.keys(created), inherited: created.inherited,
          manyKeys: Object.keys(many), manyNames: Object.getOwnPropertyNames(many),
          strDesc: Object.getOwnPropertyDescriptor("hi", "length"),
          strNames: Object.getOwnPropertyNames("ab"),
        };
        """)
        #expect(dict["d"] == .object(["value": .int(1), "writable": .bool(false), "enumerable": .bool(false), "configurable": .bool(false)]))
        #expect(dict["redefine"] == .string("Cannot redefine property: fixed"))
        #expect(dict["same"] == .string("ok"))
        #expect(dict["readonly"] == .string("Cannot assign to read only property 'fixed'."))
        #expect(dict["mixed"] == .string("Invalid property descriptor. Cannot both specify accessors and a value or writable attribute."))
        #expect(dict["createdOwn"] == .int(5))
        #expect(dict["createdKeys"] == .array([.string("own")]))
        #expect(dict["inherited"] == .bool(true))
        #expect(dict["manyKeys"] == .array([.string("a")]))
        #expect(dict["manyNames"] == .array([.string("a"), .string("b")]))
        #expect(dict["strDesc"] == .object(["value": .int(2), "writable": .bool(false), "enumerable": .bool(false), "configurable": .bool(false)]))
        #expect(dict["strNames"] == .array([.string("0"), .string("1"), .string("length")]))
    }

    @Test("Program getters are read ahead by built-ins (withReads) and by the result copy-out")
    func programGettersReadAhead() async throws {
        let dict = try await run("""
        let calls = 0;
        const o = { plain: 1 };
        Object.defineProperty(o, "x", { get: function () { calls++; return this.plain + 41; }, enumerable: true, configurable: true });
        Object.defineProperty(o, "onlySet", { set: function (v) {}, enumerable: true });
        const entries = Object.entries(o);
        const values = Object.values(o);
        const assigned = Object.assign({}, o);
        const cloned = structuredClone({ inner: o });
        const desc = Object.getOwnPropertyDescriptor(o, "x");
        const viaDescriptor = desc.get.call(o);
        return {
          entries, values, assigned, cloned, viaDescriptor,
          getterType: typeof desc.get, setterType: typeof desc.set, onlySetDesc: typeof Object.getOwnPropertyDescriptor(o, "onlySet").set,
          copied: o, calledAtLeast: calls >= 4,
        };
        """)
        #expect(dict["entries"] == .array([.array([.string("plain"), .int(1)]), .array([.string("x"), .int(42)]), .array([.string("onlySet"), .null])]))
        #expect(dict["values"] == .array([.int(1), .int(42), .null]))
        #expect(dict["assigned"] == .object(["plain": .int(1), "x": .int(42)]))
        #expect(dict["cloned"] == .object(["inner": .object(["plain": .int(1), "x": .int(42)])]))
        #expect(dict["viaDescriptor"] == .int(42))
        #expect(dict["getterType"] == .string("function"))
        #expect(dict["setterType"] == .string("undefined"))
        #expect(dict["onlySetDesc"] == .string("function"))
        // A getter's value crosses as data; a setter-only property is left out.
        #expect(dict["copied"] == .object(["plain": .int(1), "x": .int(42)]))
        #expect(dict["calledAtLeast"] == .bool(true))
    }

    @Test("Program setters run through Object.assign; a getter-only property refuses writes")
    func programSettersAndFailedAssignment() async throws {
        let dict = try await run("""
        const log = [];
        const target = {};
        Object.defineProperty(target, "v", { set: function (x) { log.push(x * 2); }, get: function () { return log.length; } });
        Object.assign(target, { v: 21 });
        const ro = Object.defineProperty({}, "x", { get: function () { return 1; } });
        let message = "";
        try { ro.x = 2; } catch (e) { message = e.message; }
        return { log, message };
        """)
        #expect(dict["log"] == .array([.int(42)]))
        #expect(dict["message"] == .string("Cannot set property 'x' of a data object which has only a getter."))
    }

    @Test("Native accessor halves have named companion functions; display labels program accessors")
    func companionsAndDisplay() async throws {
        let result = try await CodemodeEngine.execute(.init(code: """
        const size = Object.getOwnPropertyDescriptor(Map.prototype, "size");
        const o = { a: 1 };
        Object.defineProperty(o, "g", { get: function () { return 2; }, enumerable: true });
        Object.defineProperty(o, "gs", { get: function () { return 2; }, set: function (v) {}, enumerable: true });
        console.log(o);
        return { name: size.get.name, value: size.get.call(new Map([[1, 2], [3, 4]])), hasSet: size.set === undefined };
        """))
        guard case .success(let ok) = result, case .object(let dict) = ok.value else {
            Issue.record("Expected success, got \(result)")
            return
        }
        #expect(dict["name"] == .string("get size"))
        #expect(dict["value"] == .int(2))
        #expect(dict["hasSet"] == .bool(true))
        #expect(ok.logs == [#"{"a":1,"g":[Getter],"gs":[Getter/Setter]}"#])
    }

    @Test("Errors carry a lazily formatted stack; Error.prototype.toString reads program getters")
    func errorStack() async throws {
        let dict = try await run("""
        const e = new Error("boom");
        e.name = "Custom";
        const first = e.stack;
        e.name = "Later";
        const fixed = e.stack;
        let runtime = "";
        try { null.x; } catch (err) { runtime = err.stack; }
        const w = new TypeError("t");
        w.stack = "replaced";
        const named = new Error("m");
        Object.defineProperty(named, "name", { get: function () { return "G"; } });
        return {
          first, fixed, runtimeHead: runtime.split("\\n")[0], runtimeFrame: runtime.includes("\\n    at <program>:"),
          replaced: w.stack, enumerable: Object.getOwnPropertyDescriptor(e, "stack").enumerable,
          keys: Object.keys(e), toStringGetter: named.toString(),
        };
        """)
        // Upstream psychoscript v0.1.2: the header is formatted on first read (later `name` edits don't
        // change it) and `new Error` captures the construction site as a program frame.
        #expect(dict["first"] == .string("Custom: boom\n    at <program>:1:11"))
        #expect(dict["fixed"] == .string("Custom: boom\n    at <program>:1:11"))
        #expect(dict["runtimeHead"] == .string("TypeError: Cannot read properties of null (reading 'x')."))
        #expect(dict["runtimeFrame"] == .bool(true))
        #expect(dict["replaced"] == .string("replaced"))
        #expect(dict["enumerable"] == .bool(false))
        // `e.name = ...` made an own enumerable `name`; `message` and `stack` stay hidden.
        #expect(dict["keys"] == .array([.string("name")]))
        #expect(dict["toStringGetter"] == .string("G: m"))
    }

    @Test("Overridden array iterators drive spread and destructuring (array-iteration protector)")
    func arrayIteratorProtector() async throws {
        let dict = try await run("""
        const before = [...[1, 2, 3]];
        Array.prototype[Symbol.iterator] = function* () { yield "a"; yield "b"; };
        const spread = [...[9, 9, 9]];
        const [x, y, z] = [7, 8, 9];
        let loop = [];
        for (const v of [5, 6]) loop.push(v);
        return { before, spread, x, y, z: z === undefined, loop };
        """)
        #expect(dict["before"] == .array([.int(1), .int(2), .int(3)]))
        #expect(dict["spread"] == .array([.string("a"), .string("b")]))
        #expect(dict["x"] == .string("a"))
        #expect(dict["y"] == .string("b"))
        #expect(dict["z"] == .bool(true))
        #expect(dict["loop"] == .array([.string("a"), .string("b")]))
    }

    @Test("Function.prototype.bind names and sizes the bound function; new on a plain function explains classes")
    func bindAndConstruct() async throws {
        let dict = try await run("""
        function f(a, b, c) {}
        const g = f.bind(null, 1);
        const h = g.bind(null, 2, 3, 4);
        return { name: g.name, length: g.length, hName: h.name, hLength: h.length };
        """)
        #expect(dict["name"] == .string("bound f"))
        #expect(dict["length"] == .int(2))
        #expect(dict["hName"] == .string("bound bound f"))
        #expect(dict["hLength"] == .int(0))
        let message = try await failure("function F() {} new F();")
        #expect(message.contains("is not a constructor: only classes can be constructed with new."))
    }

    @Test("Uint8Array/Buffer: BYTES_PER_ELEMENT, derived kinds, and base64 alphabet/omitPadding/lastChunkHandling")
    func bytesAndBase64() async throws {
        let dict = try await run("""
        const buf = Buffer.from("hello");
        const bytes = new Uint8Array([251, 255, 1]);
        const results = {
          perElement: [Uint8Array.BYTES_PER_ELEMENT, bytes.BYTES_PER_ELEMENT, Buffer.BYTES_PER_ELEMENT],
          sliceIsBuffer: Buffer.isBuffer(buf.slice(1, 3)), subarrayIsBuffer: Buffer.isBuffer(buf.subarray(1)),
          mapIsBuffer: Buffer.isBuffer(buf.map((b) => b + 1)), filterIsBuffer: Buffer.isBuffer(buf.filter((b) => b > 104)),
          mapped: [...bytes.map((b) => b + 1)], plainMapIsBuffer: Buffer.isBuffer(bytes.map((b) => b)),
          slicedText: buf.slice(1, 3).toString(),
          url: new Uint8Array([251, 255]).toBase64({ alphabet: "base64url", omitPadding: true }),
          std: new Uint8Array([251, 255]).toBase64(),
          fromUrl: [...Uint8Array.fromBase64("-_8", { alphabet: "base64url" })],
          loose: [...Uint8Array.fromBase64("AAA")],
          partial: [...Uint8Array.fromBase64("AAAAAA", { lastChunkHandling: "stop-before-partial" })],
          fromJSON: [...Buffer.from({ type: "Buffer", data: [1, 2, 3] })],
        };
        const errors = [];
        for (const attempt of [
          () => Uint8Array.fromBase64("AA", { lastChunkHandling: "strict" }),
          () => Uint8Array.fromBase64("-_8"),
          () => Uint8Array.fromBase64("AAAA", { alphabet: "hex" }),
          () => Uint8Array.fromBase64(12),
          () => new Uint8Array([1]).toBase64("x"),
        ]) {
          try { attempt(); errors.push("none"); } catch (e) { errors.push(e.name + ": " + e.message); }
        }
        results.errors = errors;
        return results;
        """)
        #expect(dict["perElement"] == .array([.int(1), .int(1), .int(1)]))
        #expect(dict["sliceIsBuffer"] == .bool(true))
        #expect(dict["subarrayIsBuffer"] == .bool(true))
        #expect(dict["mapIsBuffer"] == .bool(true))
        #expect(dict["filterIsBuffer"] == .bool(true))
        #expect(dict["mapped"] == .array([.int(252), .int(0), .int(2)]))
        #expect(dict["plainMapIsBuffer"] == .bool(false))
        #expect(dict["slicedText"] == .string("el"))
        #expect(dict["url"] == .string("-_8"))
        #expect(dict["std"] == .string("+/8="))
        #expect(dict["fromUrl"] == .array([.int(251), .int(255)]))
        #expect(dict["loose"] == .array([.int(0), .int(0)]))
        #expect(dict["partial"] == .array([.int(0), .int(0), .int(0)]))
        #expect(dict["fromJSON"] == .array([.int(1), .int(2), .int(3)]))
        #expect(dict["errors"] == .array([
            .string("SyntaxError: Uint8Array.fromBase64: the string is not valid base64."),
            .string("SyntaxError: Uint8Array.fromBase64: the string is not valid base64."),
            .string("TypeError: Uint8Array.fromBase64 requires that alphabet be \"base64\" or \"base64url\"."),
            .string("TypeError: Uint8Array.fromBase64 expects a string."),
            .string("TypeError: Uint8Array.prototype.toBase64 requires that options be an object."),
        ]))
    }

    @Test("TextDecoder.decode streams split UTF-8 sequences; String.raw reads the raw strings")
    func textDecoderAndRaw() async throws {
        let dict = try await run("""
        const d = new TextDecoder();
        const a = d.decode(new Uint8Array([0xE2, 0x82]), { stream: true });
        const b = d.decode(new Uint8Array([0xAC]));
        return { a, b, raw: String.raw`a\\nb${1}c`, rawCall: String.raw({ raw: ["x", "y", "z"] }, 1) };
        """)
        #expect(dict["a"] == .string(""))
        #expect(dict["b"] == .string("€"))
        #expect(dict["raw"] == .string("a\\nb1c"))
        #expect(dict["rawCall"] == .string("x1yz"))
    }

    @Test("localeCompare honours locales and collator options")
    func localeCompare() async throws {
        let dict = try await run("""
        let nullError = "";
        try { "a".localeCompare("b", null); } catch (e) { nullError = e.name; }
        let badLocale = "";
        try { "a".localeCompare("b", "not a locale!"); } catch (e) { badLocale = e.name; }
        let badOption = "";
        try { "a".localeCompare("b", "en", { sensitivity: "loud" }); } catch (e) { badOption = e.name; }
        return {
          cased: "a".localeCompare("B", "en"),
          base: "a".localeCompare("A", "en", { sensitivity: "base" }),
          accentBase: "é".localeCompare("e", "en", { sensitivity: "base" }),
          numeric: "2".localeCompare("10", "en", { numeric: true }),
          lexical: "2".localeCompare("10", "en"),
          arrayLocales: "a".localeCompare("b", ["en-US"]),
          nullError, badLocale, badOption,
        };
        """)
        #expect(dict["cased"] == .int(-1))
        #expect(dict["base"] == .int(0))
        #expect(dict["accentBase"] == .int(0))
        #expect(dict["numeric"] == .int(-1))
        #expect(dict["lexical"] == .int(1))
        #expect(dict["arrayLocales"] == .int(-1))
        #expect(dict["nullError"] == .string("TypeError"))
        #expect(dict["badLocale"] == .string("RangeError"))
        #expect(dict["badOption"] == .string("RangeError"))
    }

    @Test("Date toLocale* take locales and Intl.DateTimeFormat options")
    func dateLocaleFormatting() async throws {
        let dict = try await run("""
        const d = new Date(Date.UTC(2024, 0, 5, 13, 4, 9));
        let zoneError = "";
        try { d.toLocaleString("en-US", { timeZone: "Mars/Olympus" }); } catch (e) { zoneError = e.name; }
        let styleError = "";
        try { d.toLocaleDateString("en-US", { timeStyle: "short" }); } catch (e) { styleError = e.name; }
        return {
          date: d.toLocaleDateString("en-US", { timeZone: "UTC" }),
          long: d.toLocaleDateString("en-US", { timeZone: "UTC", year: "numeric", month: "long", day: "numeric" }),
          time24: d.toLocaleTimeString("en-US", { timeZone: "UTC", hour12: false }),
          german: d.toLocaleDateString("de-DE", { timeZone: "UTC" }),
          invalid: new Date(NaN).toLocaleString(),
          zoneError, styleError,
        };
        """)
        #expect(dict["date"] == .string("1/5/2024"))
        #expect(dict["long"] == .string("January 5, 2024"))
        #expect(dict["time24"] == .string("13:04:09"))
        #expect(dict["german"] == .string("5.1.2024"))
        #expect(dict["invalid"] == .string("Invalid Date"))
        #expect(dict["zoneError"] == .string("RangeError"))
        #expect(dict["styleError"] == .string("TypeError"))
    }

    @Test("Assignments reject circular data; Object.prototype.toLocaleString calls toString")
    func circularAndToLocaleString() async throws {
        let message = try await failure("const a = {}; a.self = a; a")
        #expect(message.contains("Object assignment result contains a circular value."))
        let dict = try await run("""
        return { plain: ({}).toLocaleString(), custom: ({ toString() { return "mine"; } }).toLocaleString() };
        """)
        #expect(dict["plain"] == .string("[object Object]"))
        #expect(dict["custom"] == .string("mine"))
    }
}
