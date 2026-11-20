import Testing
import OpenCodeCore
import OpenCodeSchema
import Synchronization

/// Classes, accessors, `super`, errors' `stack`, and the Code Mode job/instructions changes from the psychoscript
/// v0.1.2 / opencode 85951cb sync.
@Suite("Code Mode classes, accessors, super and stack (psychoscript v0.1.2)")
struct CodemodeClassesTests {
    private func run(_ code: String) async throws -> CodemodeEngine.ExecutionResult {
        try await CodemodeEngine.execute(.init(code: code))
    }

    private func value(_ code: String, sourceLocation: SourceLocation = #_sourceLocation) async throws -> JSONValue? {
        let result = try await run(code)
        guard case .success(let ok) = result else {
            Issue.record("Expected success, got \(result)", sourceLocation: sourceLocation)
            return nil
        }
        return ok.value
    }

    private func failure(_ code: String, sourceLocation: SourceLocation = #_sourceLocation) async throws -> CodemodeLanguage.Diagnostic? {
        let result = try await run(code)
        guard case .failure(let failed) = result else {
            Issue.record("Expected failure, got \(result)", sourceLocation: sourceLocation)
            return nil
        }
        return failed.error
    }

    // MARK: - Classes

    @Test("Class constructor, fields, methods, accessors, statics and instanceof")
    func classBasics() async throws {
        let result = try await value("""
        class Counter {
          count = 0;
          static created = 0;
          ["tag" + 1] = "computed";
          constructor(start) {
            this.count = start ?? 0;
            Counter.created++;
          }
          increment(by = 1) { this.count += by; return this }
          get doubled() { return this.count * 2 }
          set doubled(value) { this.count = value / 2 }
          static make() { return new Counter(10) }
        }
        const c = Counter.make().increment().increment(4);
        c.doubled = 40;
        const keys = Object.keys(c);
        const proto = Object.getPrototypeOf(c);
        ({
          count: c.count,
          doubled: c.doubled,
          created: Counter.created,
          tag: c.tag1,
          isCounter: c instanceof Counter,
          keys,
          methodEnumerable: Object.keys(proto).length,
          typeofClass: typeof Counter,
          name: Counter.name,
          length: Counter.length,
          protoCtor: proto.constructor === Counter,
        })
        """)
        guard case .object(let root) = result else { return }
        #expect(root["count"] == .int(20))
        #expect(root["doubled"] == .int(40))
        #expect(root["created"] == .int(1))
        #expect(root["tag"] == .string("computed"))
        #expect(root["isCounter"] == .bool(true))
        #expect(root["keys"] == .array([.string("count"), .string("tag1")]))
        #expect(root["methodEnumerable"] == .int(0))
        #expect(root["typeofClass"] == .string("function"))
        #expect(root["name"] == .string("Counter"))
        #expect(root["length"] == .int(1))
        #expect(root["protoCtor"] == .bool(true))
    }

    @Test("Inheritance: super(), super.method(), super property, static inheritance, field order")
    func inheritance() async throws {
        let result = try await value("""
        const log = [];
        class Animal {
          kind = (log.push("Animal field"), "animal");
          constructor(name) { log.push("Animal ctor"); this.name = name }
          speak() { return `${this.name} makes a sound` }
          get label() { return "animal:" + this.name }
          static create(name) { return new this(name) }
        }
        class Dog extends Animal {
          tricks = (log.push("Dog field"), []);
          constructor(name) {
            super(name);
            log.push("Dog ctor");
          }
          speak() { return super.speak() + " (woof)" }
          get label() { return super.label.toUpperCase() }
        }
        class Puppy extends Dog {}
        const p = Puppy.create("rex");
        ({
          speak: p.speak(),
          label: p.label,
          log,
          chain: [p instanceof Puppy, p instanceof Dog, p instanceof Animal],
          kind: p.kind,
          tricks: p.tricks,
          ctorName: p.constructor.name,
        })
        """)
        guard case .object(let root) = result else { return }
        #expect(root["speak"] == .string("rex makes a sound (woof)"))
        #expect(root["label"] == .string("ANIMAL:REX"))
        #expect(root["log"] == .array([.string("Animal field"), .string("Animal ctor"), .string("Dog field"), .string("Dog ctor")]))
        #expect(root["chain"] == .array([.bool(true), .bool(true), .bool(true)]))
        #expect(root["kind"] == .string("animal"))
        #expect(root["tricks"] == .array([]))
        #expect(root["ctorName"] == .string("Puppy"))
    }

    @Test("Arrow functions keep `this`; anonymous classes and functions take their binding's name")
    func lexicalThisAndNames() async throws {
        let result = try await value("""
        class Box {
          items = [1, 2, 3];
          factor = 10;
          scaled() { return this.items.map((n) => n * this.factor) }
          handler = () => this.factor;
        }
        const b = new Box();
        const detached = b.handler;
        const Anon = class {};
        const fn = () => 1;
        const obj = { method() {}, arrow: () => 2 };
        ({ scaled: b.scaled(), detached: detached(), names: [Anon.name, fn.name, obj.method.name, obj.arrow.name] })
        """)
        guard case .object(let root) = result else { return }
        #expect(root["scaled"] == .array([.int(10), .int(20), .int(30)]))
        #expect(root["detached"] == .int(10))
        #expect(root["names"] == .array([.string("Anon"), .string("fn"), .string("method"), .string("arrow")]))
    }

    @Test("Class errors: call without new, this before super, extends null/built-ins, return rules")
    func classErrors() async throws {
        let noNew = try await failure("class A {}; A()")
        #expect(noNew?.message.contains("Class constructor A cannot be invoked without 'new'") == true)

        let thisFirst = try await failure("class A {}; class B extends A { constructor() { this.x = 1; super() } }; new B()")
        #expect(thisFirst?.message.contains("Must call super constructor in derived class") == true)

        let noSuper = try await failure("class A {}; class B extends A { constructor() {} }; new B()")
        #expect(noSuper?.message.contains("Must call super constructor in derived class") == true)

        let twice = try await failure("class A {}; class B extends A { constructor() { super(); super() } }; new B()")
        #expect(twice?.message.contains("Super constructor may only be called once") == true)

        let extendsNull = try await failure("class A extends null {}")
        #expect(extendsNull?.message.contains("Classes extending null are not supported.") == true)

        let extendsMap = try await failure("class M extends Map {}")
        #expect(extendsMap?.message.contains("Extending the built-in Map is not supported") == true)

        let badReturn = try await failure("class A {}; class B extends A { constructor() { super(); return 1 } }; new B()")
        #expect(badReturn?.message.contains("Derived constructors may only return object or undefined") == true)

        let returnsObject = try await value("class A { constructor() { return { replaced: true } } }; new A()")
        #expect(returnsObject == .object(["replaced": .bool(true)]))

        let sealedField = try await failure("class E { constructor() { return Object.freeze({}) } }; class F extends E { z = 1 }; new F()")
        #expect(sealedField?.message.contains("Cannot define property z.") == true, "\(String(describing: sealedField))")
    }

    @Test("Unsupported class syntax is refused with upstream's messages")
    func unsupportedClassSyntax() async throws {
        let privateMember = try await failure("class A { #secret = 1 }")
        #expect(privateMember?.kind == "UnsupportedSyntax")
        #expect(privateMember?.message.contains("Private class members (#name) are not supported.") == true)

        let staticBlock = try await failure("class A { static { } }")
        #expect(staticBlock?.message.contains("Class static blocks are not supported.") == true)

        let superOutside = try await failure("function f() { return super.x }")
        #expect(superOutside?.message.contains("'super' is only supported in class methods.") == true)

        let superArrow = try await failure("class A {}; class B extends A { constructor() { const f = () => super(); f() } }")
        #expect(superArrow?.message.contains("super() inside an arrow function is not supported.") == true)

        let newTarget = try await failure("function f() { return new.target }")
        #expect(newTarget?.message.contains("new.target is not supported.") == true)

        let destructure = try await failure("class A extends Object { m() { [super.x] = [1] } }")
        #expect(destructure?.message.contains("Destructuring into super.x is not supported.") == true)
    }

    @Test("Extending Error: instanceof, name, message and a stack naming the subclass")
    func extendingError() async throws {
        let result = try await value("""
        class HttpError extends Error {
          constructor(status, message) {
            super(message);
            this.name = "HttpError";
            this.status = status;
          }
        }
        function fail() { throw new HttpError(404, "missing") }
        try {
          fail();
        } catch (e) {
          ({ isError: e instanceof Error, isHttp: e instanceof HttpError, name: e.name, message: e.message, status: e.status, stack: e.stack })
        }
        """)
        guard case .object(let root) = result else { return }
        #expect(root["isError"] == .bool(true))
        #expect(root["isHttp"] == .bool(true))
        #expect(root["name"] == .string("HttpError"))
        #expect(root["message"] == .string("missing"))
        #expect(root["status"] == .int(404))
        guard case .string(let stack) = root["stack"] else {
            Issue.record("Expected a string stack, got \(String(describing: root["stack"]))")
            return
        }
        #expect(stack.hasPrefix("HttpError: missing\n    at "))
        #expect(stack.contains("at fail (<program>:"))
    }

    @Test("Errors get a V8-style stack of program frames, innermost first")
    func errorStack() async throws {
        let result = try await value("""
        function inner() { return new Error("boom") }
        function outer() { return inner() }
        outer().stack
        """)
        guard case .string(let stack) = result else {
            Issue.record("Expected a stack string, got \(String(describing: result))")
            return
        }
        let lines = stack.split(separator: "\n").map(String.init)
        #expect(lines.first == "Error: boom")
        #expect(lines.count == 4)
        #expect(lines.dropFirst().first?.hasPrefix("    at inner (<program>:1:") == true)
        #expect(lines.dropFirst(2).first?.hasPrefix("    at outer (<program>:2:") == true)
        #expect(lines.last?.hasPrefix("    at <program>:3:") == true)
    }

    // MARK: - Accessors

    @Test("Object literal getters and setters run as program code, with spread and destructuring")
    func objectAccessors() async throws {
        let result = try await value("""
        const reads = [];
        const temp = {
          celsius: 20,
          get fahrenheit() { reads.push("get"); return this.celsius * 9 / 5 + 32 },
          set fahrenheit(f) { this.celsius = (f - 32) * 5 / 9 },
          ["get" + "ter"]: 1,
        };
        temp.fahrenheit = 212;
        const { fahrenheit } = temp;
        const copy = { ...temp };
        const getter = Object.getOwnPropertyDescriptor(temp, "fahrenheit").get;
        ({ celsius: temp.celsius, fahrenheit, copied: copy.fahrenheit, reads: reads.length, getterName: getter.name, plain: temp.getter })
        """)
        guard case .object(let root) = result else { return }
        #expect(root["celsius"] == .int(100))
        #expect(root["fahrenheit"] == .int(212))
        #expect(root["copied"] == .int(212))
        #expect(root["reads"] == .int(2))
        #expect(root["getterName"] == .string("get fahrenheit"))
        #expect(root["plain"] == .int(1))
    }

    @Test("super in object literal methods and compound assignment through super")
    func superInObjectsAndCompound() async throws {
        let result = try await value("""
        class Base {
          constructor() { this._total = 1 }
          get total() { return this._total }
          set total(value) { this._total = value }
          get bonus() { return 5 }
        }
        class Derived extends Base {
          bump() { super.total += 10; super.total++; return this.total + super.bonus }
        }
        const viaSuper = { greet() { return super.toString === Object.prototype.toString ? "has super" : "no super" } };
        ({ bumped: new Derived().bump(), viaSuper: viaSuper.greet() })
        """)
        guard case .object(let root) = result else { return }
        #expect(root["bumped"] == .int(17))
        #expect(root["viaSuper"] == .string("has super"))
    }

    @Test("Iterator protocol reads run program getters (redoRead)")
    func iteratorGetters() async throws {
        let result = try await value("""
        let n = 0;
        const iterable = {
          [Symbol.iterator]() {
            return {
              next() {
                n++;
                return { get done() { return n > 3 }, get value() { return n * 10 } };
              },
            };
          },
        };
        [...iterable]
        """)
        #expect(result == .array([.int(10), .int(20), .int(30)]))
    }

    @Test("Program getters in tool arguments cross as data, read before the call")
    func getterArgumentsCrossToHost() async throws {
        let received = CodemodeHostRecorder()
        let tools: CodemodeEngine.Tools = [
            "echo": .tool(CodemodeEngine.Tool.make(.init(
                description: "Echo",
                input: ["type": .string("object")],
                execute: { input, _ in
                    received.record(input)
                    return input
                }
            ))),
        ]
        let runtime = try CodemodeEngine.make(.init(tools: tools))
        let result = await runtime.execute("""
        const order = [];
        const arg = { get id() { order.push("id"); return 7 }, name: "x" };
        const echoed = await tools.echo(arg);
        ({ echoed, order })
        """, nil, nil)
        guard case .success(let ok) = result, case .object(let root) = ok.value else {
            Issue.record("Expected success, got \(result)")
            return
        }
        #expect(root["order"] == .array([.string("id")]))
        #expect(received.last == .object(["id": .int(7), "name": .string("x")]))
    }

    // MARK: - Compiler tables

    @Test("Opcodes, code flags and compiler version follow psychoscript v0.1.2")
    func compilerTables() {
        #expect(CodemodeLanguage.Op.DEFINE_ACCESSOR == 88)
        #expect(CodemodeLanguage.Op.SUPER_BIND == 94)
        #expect(CodemodeLanguage.Op.SET_HOME == 98)
        #expect(CodemodeLanguage.OpNames[98] == "SET_HOME")
        #expect(CodemodeLanguage.OpNames[Int(CodemodeLanguage.Op.CLASS)] == "CLASS")
        #expect(CodemodeLanguage.CodeFlags.CLASS_CONSTRUCTOR == 1 << 8)
        #expect(CodemodeLanguage.CodeFlags.FIELD_INIT == 1 << 12)
        #expect(CodemodeLanguage.COMPILER_VERSION == 3)
        #expect(CodemodeLanguage.HOLE.description == "Symbol(psychoscript.hole)")
        #expect(CodemodeLanguage.REDO_ENTERED == -1)
        #expect(CodemodeLanguage.Mode.redo.rawValue == 7)
    }

    @Test("Scope analysis records class constructors, field initializers, computed field keys and super")
    func scopeAnalysisOfClasses() throws {
        let code = """
        class A { m() { return 1 } }
        class B extends A {
          x = 1;
          [k] = 2;
          static s = 3;
          m() { return () => super.m() }
        }
        """
        let parsed = CodemodeLanguage.parseProgram(code)
        guard case .ok(let program, _) = parsed else {
            Issue.record("Expected parse success")
            return
        }
        let analysis = CodemodeLanguage.analyzeScopes(CodemodeLanguage.Source(id: "s", code: code, program: program))
        #expect(analysis.classConstructors.count == 2)
        let ctorB = analysis.functions[analysis.classConstructors[1]]
        #expect((ctorB.flags & CodemodeLanguage.CodeFlags.DERIVED) != 0)
        #expect((ctorB.flags & CodemodeLanguage.CodeFlags.CLASS_CONSTRUCTOR) != 0)
        #expect(ctorB.newTargetDecl?.name == "%newTarget")
        #expect(analysis.classFieldInits[1]?.instance != nil)
        #expect(analysis.classFieldInits[1]?.static != nil)
        #expect(analysis.fieldKeys["1:1"] == "%key0")
        #expect(analysis.superRefs.count == 1)
        let owner = analysis.functions[analysis.superRefs[0].ownerIndex]
        #expect((owner.flags & CodemodeLanguage.CodeFlags.METHOD) != 0)
        #expect(owner.homeDecl?.name == "%home")
        #expect(CodemodeLanguage.defaultSuperCalls(.superCall(arguments: [], passThrough: true, loc: nil)))
    }

    @Test("The prelude and the internal prelude compile, and internal helpers are found by name")
    func preludesCompile() {
        #expect(!CodemodeLanguage.compiledPrelude().isEmpty)
        #expect(CodemodeLanguage.internalCode("$vmReplay") != nil)
        #expect(CodemodeLanguage.internalCode("$vmThenableGet") != nil)
        var registry: [String: CodemodeLanguage.VmIntrinsic] = [:]
        CodemodeLanguage.registerVmIntrinsics(&registry)
        #expect(registry["$ArraySet"] != nil)
        #expect(CodemodeLanguage.helpers()["$OwnKeys"] == "internal:$OwnKeys")
    }

    @Test("Tool scan finds calls inside class bodies")
    func scanInsideClasses() throws {
        let found = CodemodeEngine.scanCodeModeTools("""
        class Client {
          field = tools.config.load();
          async fetch() { return tools.github.issues() }
          static get helper() { return tools.misc.help() }
        }
        """)
        #expect(try found.get() == ["config.load", "github.issues", "misc.help"])
    }

    // MARK: - Core Code Mode

    @Test("Code Mode instructions tell the model execute is gone when it is removed")
    func instructionsRemoved() async throws {
        let list = CoreCodemode.Instructions.make()
        let source = try #require(list.first)
        #expect(list.count == 1)
        #expect(source.key.rawValue == "core/codemode")
        guard case .removed = await source.read() else {
            Issue.record("Without a catalog the Code Mode source must read as removed")
            return
        }
        let previous: JSONValue = .object(["total": .int(0), "namespaces": .array([])])
        #expect(source.removed(previous) == "The `execute` tool is no longer available. Permitted tools are now available as direct tool calls.")
    }

    @Test("Catalog pins and describes tools by their codemode settings; nested calls run with codemode: true")
    func codemodeToolSettings() async throws {
        let inventory = CoreCodemode.Tool.Inventory(tools: [
            "lookup": CoreCodemode.Tool.ToolRegistration(
                name: "lookup",
                description: "Direct lookup",
                options: ToolSchema.Options(
                    namespace: nil,
                    permission: nil,
                    codemodeSetting: .configured(ToolSchema.CodeModeOptions(pinned: true, description: "Code Mode lookup")),
                    legacyPinned: nil
                ),
                execute: { _, context in
                    ToolSchema.Result(output: .object(["inside": .bool(context.codemode == true)]))
                }
            ),
        ])
        let catalog = CoreCodemode.Tool.catalog(inventory)
        guard case .tool(let entry)? = catalog.tools.first else {
            Issue.record("Expected a tool entry, got \(catalog.tools)")
            return
        }
        #expect(entry.pinned == true)
        #expect(entry.description == "Code Mode lookup")

        let transport = CodemodeTestHelper.MockHTTPTransport { _ in
            CodemodeTestHelper.makeResponse(status: 200, body: "{}")
        }
        let tool = CoreCodemode.Tool.create(inventory: inventory, transport: transport)
        let result = try await tool.execute(.init(code: "return await tools.lookup({})"), CodemodeTestHelper.makeToolContext { _ in })
        #expect(result.output?.output.contains("\"inside\": true") == true || result.output?.output.contains("\"inside\":true") == true)
    }

    @Test("A full Code Mode script blocks, then moves to the background and reports through a notice")
    func jobMovesToBackground() async throws {
        let notices = CodemodeHostRecorder()
        let progress = CodemodeHostRecorder()
        let runFn = CoreCodemode.Job.make(fullCodemode: true, blockTimeoutMs: 20) { notice in
            notices.record(.string(notice.text))
        }
        let context = ToolSchema.Context(
            sessionID: SessionID.create(),
            agent: AgentSchema.ID(rawValue: "build"),
            messageID: "msg_1",
            id: ToolSchema.CallID(rawValue: "call_1"),
            progress: { update in progress.record(.object(update)) }
        )
        let fast = try await runFn(context) { _ in ToolSchema.Result(output: .string("done"), content: .text("done")) }
        #expect(fast.output == .string("done"))
        #expect(progress.last == .object(["background": .bool(true)]))

        let slow = try await runFn(context) { _ in
            try await Task.sleep(for: .milliseconds(200))
            return ToolSchema.Result(output: .string("late"), content: .text("late result"))
        }
        guard case .text(let text) = slow.content else {
            Issue.record("Expected a text result, got \(String(describing: slow.content))")
            return
        }
        #expect(text.hasPrefix("Script cm_"))
        #expect(text.hasSuffix("is still running; its result will arrive in this session."))
        #expect(slow.metadata?["jobID"] != nil)
        for _ in 0..<100 where notices.count == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard case .string(let notice)? = notices.last else {
            Issue.record("Expected a background notice")
            return
        }
        #expect(notice.hasPrefix("<background-result kind=\"codemode\" id=\"cm_"))
        #expect(notice.contains("state=\"completed\">\nlate result\n</background-result>"))
        #expect(notices.count == 1)
    }
}

/// Records values handed to the host (tool inputs, notices, progress) for assertions.
final class CodemodeHostRecorder: Sendable {
    private let values = Mutex<[JSONValue]>([])

    func record(_ value: JSONValue) {
        values.withLock { $0.append(value) }
    }

    var last: JSONValue? { values.withLock { $0.last } }
    var count: Int { values.withLock { $0.count } }
}
