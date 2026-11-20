import Synchronization

/// Classes, `super`, program accessors in literals, and the program call stack behind errors' `stack`, for the
/// tree-walking evaluator. Ports the class parts of psychoscript's `compiler/compile.ts` and `vm.ts` (`execClass`,
/// `execSuperCall`, `execSuperBind`, `execGetSuper`, `execPutSuper`, `execDefineMethod`, `execSetFields`,
/// `execInitFields`, `constructClass`, `stackTrace`, `redoRead`) onto the evaluator's async walk of the AST.
extension CodemodeLanguage {
    // MARK: - Program call stack (vm.ts frames, for `stackTrace`)

    /// One program frame on the evaluator's call stack: the function running (none for the program) and the site
    /// it is at, which is the call or `new` it is making when an inner frame is above it.
    public final class EvalFrame: Sendable {
        public let function: Fn?
        public let parent: EvalFrame?
        private let siteBox = Mutex<AstNode?>(nil)

        public init(function: Fn?, parent: EvalFrame?) {
            self.function = function
            self.parent = parent
        }

        public var site: AstNode? {
            get { siteBox.withLock { $0 } }
            set { siteBox.withLock { $0 = newValue } }
        }
    }

    /// The program frames of the running task, innermost first. A job (an async function's task) inherits the
    /// frames of the code that started it.
    public enum EvalFrames {
        @TaskLocal public static var current: EvalFrame?
    }

    static let THIS_BEFORE_SUPER =
        "Must call super constructor in derived class before accessing 'this' or returning from derived constructor"

    /// The `this` a derived constructor runs with until `super()` binds one: reading `this` then reads the
    /// constructor's `%this` binding, which is uninitialized (a ReferenceError) until `super()` returns.
    final class DerivedThis: Opaque, @unchecked Sendable {}

    static let derivedThis = DerivedThis(proto: nil)

    /// A class's fields, kept in its field initializer's closure: each field in order, and for a computed one the
    /// hidden class-scope binding its key was evaluated into when the class was defined.
    final class ClassFields: Opaque, @unchecked Sendable {
        let members: [ClassMember]
        let keyBindings: [Int: String]

        init(members: [ClassMember], keyBindings: [Int: String]) {
            self.members = members
            self.keyBindings = keyBindings
            super.init(proto: nil)
        }
    }

    // MARK: - Iterator ops meeting program getters (vm.ts)

    public struct RedoSentinel: Equatable, Hashable, Sendable, CustomStringConvertible {
        public init() {}

        public var description: String { "Symbol(vm.redo)" }
    }

    /// `redoRead`'s answer once it met a program getter: the read has to run the getter (as program code) first.
    // parity: psychoscript/src/vm.ts#REDO [status=adapted hash=31b9751ba435]
    public static let REDO = RedoSentinel()

    /// The iterator ops' answer once a getter was entered (a negative pc, so the op runs again).
    // parity: psychoscript/src/vm.ts#REDO_ENTERED [status=implemented hash=8e6495ef9093]
    public static let REDO_ENTERED: Int = -1

    // MARK: - Class helpers (vm.ts)

    /// A property key as the value it came from (a string or a symbol).
    static func keyValue(_ key: PropertyKey) -> Value {
        switch key {
        case .string(let s): return .string(s)
        case .symbol(let sym): return .symbol(sym)
        }
    }

    /// How a method or accessor keyed by `key` is named: the key, or `[description]` for a symbol.
    static func methodName(_ key: PropertyKey) -> JSString {
        switch key {
        case .string(let s): return s
        case .symbol(let sym):
            if sym == IteratorSymbol { return "[Symbol.iterator]" }
            if sym == AsyncIteratorSymbol { return "[Symbol.asyncIterator]" }
            return JSString("[\(sym.description)]")
        }
    }

    /// A non-computed class or object key's name.
    static func literalKeyName(_ key: PropertyKeyExpr) -> JSString {
        switch key {
        case .identifier(let s, _): return JSString(s)
        case .string(let s, _): return s
        case .number(let n, _): return JSString(formatJSNumber(n))
        case .computed: return ""
        }
    }

    /// A class with its own static `name` member keeps it when it is named.
    static func hasStaticName(_ fn: Fn) -> Bool {
        guard let slot = own(fn, .string("name")) else { return false }
        if case .data(.string, _, _, _) = slot { return false }
        return true
    }

    /// Whether `value` is one of the error constructors, which a class may extend.
    static func isErrorConstructor(_ value: Value, builtins: Builtins) -> Builtin? {
        guard case .object(let obj) = value, let builtin = obj as? Builtin,
              case .string(let name) = peek(builtin, .string("name")),
              let type = ErrorType(rawValue: name.toWellFormedString()),
              case .object(let ctor) = peek(builtins.errorProto(type), .string("constructor")),
              ctor === builtin
        else { return nil }
        return builtin
    }

    /// What a class may extend: another class or an error constructor. Other built-ins and `null` are refused.
    static func classParent(_ parent: Value, node: AstNode?, builtins: Builtins) throws -> Callable {
        if case .null = parent { throw typeError("Classes extending null are not supported.", node: node) }
        if case .object(let fn as Fn) = parent, fn.klass != nil { return fn }
        if let errorCtor = isErrorConstructor(parent, builtins: builtins) { return errorCtor }
        if case .object(let builtin as Builtin) = parent, builtin.constructFn != nil {
            let name = coerceToString(peek(builtin, .string("name")))
            throw typeError(
                "Extending the built-in \(name) is not supported. Only classes and Error types can be extended.",
                node: node
            )
        }
        throw typeError("Class extends value \(describeValue(parent)) is not a constructor or null.", node: node)
    }
}

extension CodemodeLanguage.LexEnv {
    /// Initializes the nearest binding named `name` once: false when it is initialized already.
    func initializeOnce(_ name: String, value: CodemodeLanguage.Value) -> Bool {
        var current: CodemodeLanguage.LexEnv? = self
        while let env = current {
            if let initialized = env.initializedState(name) {
                if initialized { return false }
                env.initialize(name, value: value)
                return true
            }
            current = env.parent
        }
        return false
    }
}

extension CodemodeLanguage.Evaluator {
    // MARK: - Program call stack

    /// Runs `body` as a new innermost program frame for `function` (none for the program itself).
    func withFrame<T: Sendable>(_ function: CodemodeLanguage.Fn?, _ body: () async throws -> T) async rethrows -> T {
        let frame = CodemodeLanguage.EvalFrame(function: function, parent: CodemodeLanguage.EvalFrames.current)
        return try await CodemodeLanguage.EvalFrames.$current.withValue(frame) {
            try await body()
        }
    }

    /// Records the site the innermost program frame is at: the call, `new` or `await` it is making.
    func markSite(_ site: CodemodeLanguage.AstNode?) {
        guard let site, site.location != nil else { return }
        CodemodeLanguage.EvalFrames.current?.site = site
    }

    /// The program frames on the stack as `stack` lines, innermost first, at most 10 as V8's
    /// `Error.stackTraceLimit`.
    public func stackTrace() -> String {
        var trace = ""
        var shown = 0
        var frame = CodemodeLanguage.EvalFrames.current
        while let current = frame, shown < 10 {
            frame = current.parent
            guard let site = current.site, site.location != nil, !CodemodeLanguage.inPrelude(site) else { continue }
            let name: String? = current.function.map { fn in
                if case .string(let s) = CodemodeLanguage.peek(fn, .string("name")), !s.isEmpty { return s.toWellFormedString() }
                return "<anonymous>"
            }
            trace += CodemodeLanguage.stackFrame(site, name: name)
            shown += 1
        }
        return trace
    }

    // MARK: - `this`

    /// `this` where `thisValue` is the running function's: a derived constructor's binding before `super()` throws.
    func resolveThis(_ env: CodemodeLanguage.LexEnv, _ thisValue: CodemodeLanguage.Value, node: CodemodeLanguage.AstNode?) throws -> CodemodeLanguage.Value {
        guard case .object(let marker) = thisValue, marker === CodemodeLanguage.derivedThis else { return thisValue }
        do {
            return try env.get("%this", node: node)
        } catch {
            throw CodemodeLanguage.referenceError(CodemodeLanguage.THIS_BEFORE_SUPER, node: node)
        }
    }

    // MARK: - Named evaluation

    /// An anonymous function or class gets the name of what it is assigned to.
    func evalNamedExpression(
        _ expr: CodemodeLanguage.Expression,
        name: CodemodeLanguage.JSString,
        env: CodemodeLanguage.LexEnv,
        thisValue: CodemodeLanguage.Value
    ) async throws -> CodemodeLanguage.Value {
        switch expr {
        case .classExpr(let cls) where cls.name == nil:
            return try await evalClass(cls, env: env, thisValue: thisValue, nameHint: name)
        case .function(let payload) where payload.name == nil:
            let value = try await evalExpression(expr, env: env, thisValue: thisValue)
            if case .object(let fn as CodemodeLanguage.Fn) = value {
                CodemodeLanguage.define(fn, "name", .string(name), CodemodeLanguage.readonly)
            }
            return value
        default:
            return try await evalExpression(expr, env: env, thisValue: thisValue)
        }
    }

    // MARK: - Methods and accessors

    /// A method of `home` (an object literal, a class prototype or constructor): its closure binds `%home`, the
    /// object `super` reads from the prototype of.
    func makeMethod(
        _ payload: CodemodeLanguage.FunctionPayload,
        home: CodemodeLanguage.Obj,
        env: CodemodeLanguage.LexEnv
    ) -> CodemodeLanguage.Fn {
        let methodEnv = CodemodeLanguage.LexEnv(parent: env, isFunctionScope: false)
        methodEnv.declare("%home", value: .object(home), isConst: true)
        let fn = CodemodeLanguage.Fn(proto: builtins.Function, payload: payload.with(kind: .method), closure: methodEnv)
        fn.home = home
        CodemodeLanguage.define(fn, "length", .number(Double(payload.expectedArgumentCount)), CodemodeLanguage.readonly)
        return fn
    }

    // MARK: - Classes

    /// A class declaration's or expression's constructor (vm.ts `execClass` and the members after it): the
    /// prototype, methods and accessors, the instance field initializer, the class name, then static fields.
    func evalClass(
        _ cls: CodemodeLanguage.ClassPayload,
        env: CodemodeLanguage.LexEnv,
        thisValue: CodemodeLanguage.Value,
        nameHint: CodemodeLanguage.JSString? = nil
    ) async throws -> CodemodeLanguage.Value {
        let node = CodemodeLanguage.AstNode(type: "ClassExpression", location: cls.loc)
        let classEnv = CodemodeLanguage.LexEnv(parent: env, isFunctionScope: false)
        if let name = cls.name {
            classEnv.declare(name, value: .undefined, isConst: true, initialized: false)
        }
        var parent: CodemodeLanguage.Callable? = nil
        var protoParent: CodemodeLanguage.Obj? = builtins.Object
        if let superExpr = cls.superClass {
            let value = try await evalExpression(superExpr, env: classEnv, thisValue: thisValue)
            let heritage = CodemodeLanguage.AstNode(type: "ClassHeritage", location: superExpr.location ?? cls.loc)
            let found = try CodemodeLanguage.classParent(value, node: heritage, builtins: builtins)
            parent = found
            switch CodemodeLanguage.peek(found, .string("prototype")) {
            case .object(let proto): protoParent = proto
            case .null: protoParent = nil
            default: protoParent = builtins.Object
            }
        }
        let derived = parent != nil
        let proto = CodemodeLanguage.Obj(proto: protoParent)
        let ctorEnv = CodemodeLanguage.LexEnv(parent: classEnv, isFunctionScope: false)
        ctorEnv.declare("%home", value: .object(proto), isConst: true)
        let ctorPayload = cls.constructor.with(kind: .classConstructor(derived: derived), name: cls.name ?? "")
        let ctor = CodemodeLanguage.Fn(proto: parent ?? builtins.Function, payload: ctorPayload, closure: ctorEnv)
        CodemodeLanguage.define(ctor, "length", .number(Double(ctorPayload.expectedArgumentCount)), CodemodeLanguage.readonly)
        let errorBase: CodemodeLanguage.Callable? = parent.flatMap {
            CodemodeLanguage.isErrorConstructor(.object($0), builtins: builtins)
        }
        ctor.klass = CodemodeLanguage.ClassInfo(derived: derived, errorBase: errorBase)
        ctor.home = proto
        CodemodeLanguage.define(ctor, "prototype", .object(proto), CodemodeLanguage.frozen)
        CodemodeLanguage.define(proto, "constructor", .object(ctor), CodemodeLanguage.hidden)

        // Member keys are evaluated once, in order; a computed field's key is kept in its hidden binding.
        var fieldKeys: [Int: String] = [:]
        for (index, member) in cls.members.enumerated() {
            let memberNode = CodemodeLanguage.AstNode(type: "MethodDefinition", location: member.loc)
            if member.kind == .field {
                guard case .computed(let keyExpr, _) = member.key else { continue }
                let raw = try await evalExpression(keyExpr, env: classEnv, thisValue: thisValue)
                let binding = "%key\(fieldKeys.count)"
                classEnv.declare(binding, value: CodemodeLanguage.keyValue(CodemodeLanguage.propertyKey(raw)), isConst: true)
                fieldKeys[index] = binding
                continue
            }
            guard let fnPayload = member.function else { continue }
            let key = try await evalPropertyKey(member.key, env: classEnv, thisValue: thisValue)
            let home: CodemodeLanguage.Obj = member.isStatic ? ctor : proto
            if member.isStatic, key == .string("prototype") {
                throw CodemodeLanguage.typeError("Classes may not have a static property named 'prototype'.", node: memberNode)
            }
            let fn = makeMethod(fnPayload, home: home, env: classEnv)
            let name = CodemodeLanguage.methodName(key)
            switch member.kind {
            case .method:
                CodemodeLanguage.define(fn, "name", .string(name), CodemodeLanguage.readonly)
                CodemodeLanguage.define(home, key, .object(fn), CodemodeLanguage.hidden)
            case .getter:
                CodemodeLanguage.define(fn, "name", .string("get \(name)"), CodemodeLanguage.readonly)
                CodemodeLanguage.defineAccessorHalf(home, key, half: .get, fn: fn, enumerable: false)
            case .setter:
                CodemodeLanguage.define(fn, "name", .string("set \(name)"), CodemodeLanguage.readonly)
                CodemodeLanguage.defineAccessorHalf(home, key, half: .set, fn: fn, enumerable: false)
            case .field:
                break
            }
        }

        func fieldInitializer(isStatic: Bool, home: CodemodeLanguage.Obj, name: String) -> CodemodeLanguage.Fn? {
            var members: [CodemodeLanguage.ClassMember] = []
            var bindings: [Int: String] = [:]
            for (index, member) in cls.members.enumerated() where member.kind == .field && member.isStatic == isStatic {
                if let binding = fieldKeys[index] { bindings[members.count] = binding }
                members.append(member)
            }
            if members.isEmpty { return nil }
            let fieldsEnv = CodemodeLanguage.LexEnv(parent: classEnv, isFunctionScope: false)
            fieldsEnv.declare("%home", value: .object(home), isConst: true)
            fieldsEnv.declare("%fields", value: .object(CodemodeLanguage.ClassFields(members: members, keyBindings: bindings)), isConst: true)
            let payload = CodemodeLanguage.FunctionPayload(
                name: name,
                params: [],
                body: .block([]),
                isAsync: false,
                isGenerator: false,
                isArrow: false,
                loc: cls.loc,
                kind: .fieldInit
            )
            let fn = CodemodeLanguage.Fn(proto: builtins.Function, payload: payload, closure: fieldsEnv)
            fn.home = home
            return fn
        }

        ctor.klass?.fields = fieldInitializer(isStatic: false, home: proto, name: "<instance_members_initializer>")
        if cls.name == nil, let nameHint, !CodemodeLanguage.hasStaticName(ctor) {
            CodemodeLanguage.define(ctor, "name", .string(nameHint), CodemodeLanguage.readonly)
        }
        if let name = cls.name {
            classEnv.initialize(name, value: .object(ctor))
        }
        if let statics = fieldInitializer(isStatic: true, home: ctor, name: "<static_initializer>") {
            _ = try await callCallable(.object(statics), thisValue: .object(ctor), args: [], site: node)
        }
        return .object(ctor)
    }

    /// A class's field initializer run on `thisValue` (vm.ts `execInitFields`): defines each field in order, as
    /// CreateDataPropertyOrThrow does, which fails on a frozen or non-extensible target.
    func runFieldInitializer(_ fnObj: CodemodeLanguage.Fn, thisValue: CodemodeLanguage.Value) async throws -> CodemodeLanguage.Value {
        guard case .object(let box as CodemodeLanguage.ClassFields) = try fnObj.closure.get("%fields") else { return .undefined }
        let env = CodemodeLanguage.LexEnv(parent: fnObj.closure, isFunctionScope: true)
        for (index, field) in box.members.enumerated() {
            let fieldNode = CodemodeLanguage.AstNode(type: "PropertyDefinition", location: field.loc)
            let key: CodemodeLanguage.PropertyKey
            if let binding = box.keyBindings[index] {
                key = CodemodeLanguage.propertyKey(try env.get(binding, node: fieldNode))
            } else {
                key = .string(CodemodeLanguage.literalKeyName(field.key))
            }
            let value: CodemodeLanguage.Value
            if let initializer = field.value {
                value = try await evalNamedExpression(initializer, name: CodemodeLanguage.methodName(key), env: env, thisValue: thisValue)
            } else {
                value = .undefined
            }
            guard case .object(let target) = thisValue else {
                throw CodemodeLanguage.typeError("Cannot define property \(CodemodeLanguage.keyLabel(key)).", node: fieldNode)
            }
            let desc = CodemodeLanguage.Descriptor(value: value, writable: true, enumerable: true, configurable: true)
            guard try CodemodeLanguage.defineOwnProperty(target, key, desc) else {
                throw CodemodeLanguage.typeError("Cannot define property \(CodemodeLanguage.keyLabel(key)).", node: fieldNode)
            }
        }
        return .undefined
    }

    /// Runs the class constructor `ctor`'s instance field initializer on `instance`, when the class has fields.
    func initFields(_ ctor: CodemodeLanguage.Fn, instance: CodemodeLanguage.Value, site: CodemodeLanguage.AstNode?) async throws {
        guard let fields = ctor.klass?.fields else { return }
        _ = try await callCallable(.object(fields), thisValue: instance, args: [], site: site)
    }

    /// `new C(...)`, or `super(...)` for `newTarget` (vm.ts `constructClass`): a base class's constructor runs on a
    /// new instance of `newTarget.prototype` after its fields; a derived one starts without `this` until `super()`
    /// binds one. The result is the constructor's object return value, else its `this`.
    func constructClass(
        _ ctor: CodemodeLanguage.Fn,
        args: [CodemodeLanguage.Value],
        newTarget: CodemodeLanguage.Callable,
        site: CodemodeLanguage.AstNode?
    ) async throws -> CodemodeLanguage.Value {
        markSite(site)
        try enterCall(site: site)
        defer { exitCall() }
        guard let klass = ctor.klass else {
            throw CodemodeLanguage.notConstructible(.object(ctor), node: site)
        }
        if !klass.derived {
            let protoObj: CodemodeLanguage.Obj
            if case .object(let p) = CodemodeLanguage.peek(newTarget, .string("prototype")) { protoObj = p } else { protoObj = builtins.Object }
            let instance = CodemodeLanguage.Obj(proto: protoObj)
            let (result, _) = try await runFunctionBody(ctor, thisValue: .object(instance), args: args, beforeBody: { _ in
                try await self.initFields(ctor, instance: .object(instance), site: site)
            })
            if case .object = result { return result }
            return .object(instance)
        }
        let (result, fnEnv) = try await runFunctionBody(
            ctor,
            thisValue: .object(CodemodeLanguage.derivedThis),
            args: args,
            prepare: { env in
                env.declare("%this", value: .undefined, isConst: false, initialized: false)
                env.declare("%newTarget", value: .object(newTarget), isConst: true)
                env.declare("%ctor", value: .object(ctor), isConst: true)
            }
        )
        // A derived constructor's return rules apply once it has returned.
        if case .object = result { return result }
        if !result.isUndefined {
            throw CodemodeLanguage.typeError("Derived constructors may only return object or undefined", node: site)
        }
        guard let bound = try? fnEnv.get("%this") else {
            throw CodemodeLanguage.referenceError(CodemodeLanguage.THIS_BEFORE_SUPER, node: site)
        }
        return bound
    }

    /// `super(...)` in a derived constructor (vm.ts `execSuperCall`, `execSuperBind`, then `execInitFields`):
    /// constructs the parent for the new target, binds `this` once, then defines the class's fields.
    func evalSuperCall(
        _ arguments: [CodemodeLanguage.CallArgument],
        passThrough: Bool,
        env: CodemodeLanguage.LexEnv,
        thisValue: CodemodeLanguage.Value,
        loc: CodemodeLanguage.SourceLocation?
    ) async throws -> CodemodeLanguage.Value {
        let node = CodemodeLanguage.AstNode(type: "CallExpression", location: loc)
        guard case .object(let ctorObj) = try env.get("%ctor", node: node), let ctor = ctorObj as? CodemodeLanguage.Fn,
              case .object(let targetObj) = try env.get("%newTarget", node: node), let newTarget = targetObj as? CodemodeLanguage.Callable
        else {
            throw CodemodeLanguage.syntaxError("'super' keyword unexpected here", node: node)
        }
        let values: [CodemodeLanguage.Value]
        if passThrough, case .spread(let spread, _)? = arguments.first {
            // The default constructor's `super(...args)` hands its arguments on without iterating them.
            let rest = try await evalExpression(spread, env: env, thisValue: thisValue)
            if case .object(let arr as CodemodeLanguage.Arr) = rest { values = arr.items } else { values = [] }
        } else {
            values = try await evalCallArgs(arguments, env: env, thisValue: thisValue)
        }
        markSite(node)
        let parentValue: CodemodeLanguage.Value = ctor.proto.map { .object($0) } ?? .null
        let instance: CodemodeLanguage.Value
        if let errorCtor = CodemodeLanguage.isErrorConstructor(parentValue, builtins: builtins), let construct = errorCtor.constructFn {
            do {
                instance = try await construct(values, newTarget, self)
            } catch {
                throw CodemodeLanguage.locate(error, node: node)
            }
        } else if case .object(let parentFn as CodemodeLanguage.Fn) = parentValue, parentFn.klass != nil {
            instance = try await constructClass(parentFn, args: values, newTarget: newTarget, site: node)
        } else {
            throw CodemodeLanguage.typeError(
                "Super constructor \(CodemodeLanguage.describeValue(parentValue)) of anonymous class is not a constructor",
                node: node
            )
        }
        guard env.initializeOnce("%this", value: instance) else {
            throw CodemodeLanguage.referenceError("Super constructor may only be called once", node: node)
        }
        try await initFields(ctor, instance: instance, site: node)
        return instance
    }

    // MARK: - `super.x`

    /// The object `super.x` reads from: the home object's prototype.
    func superBase(_ env: CodemodeLanguage.LexEnv, node: CodemodeLanguage.AstNode?) throws -> CodemodeLanguage.Obj {
        guard case .object(let home) = try env.get("%home", node: node) else {
            throw CodemodeLanguage.syntaxError("'super' is only supported in class methods.", node: node)
        }
        guard let proto = home.proto else {
            throw CodemodeLanguage.typeError("Cannot use 'super' here: the home object has no prototype.", node: node)
        }
        return proto
    }

    /// `super.x` / `super[key]` (vm.ts `execGetSuper`): reads from the home object's prototype with `this` as the
    /// receiver, running a program getter there. Answers the value and that receiver (for `super.m()`).
    func readSuper(
        _ property: CodemodeLanguage.PropertyKeyExpr,
        env: CodemodeLanguage.LexEnv,
        thisValue: CodemodeLanguage.Value,
        loc: CodemodeLanguage.SourceLocation?
    ) async throws -> (value: CodemodeLanguage.Value, receiver: CodemodeLanguage.Value) {
        let node = CodemodeLanguage.AstNode(type: "MemberExpression", location: loc)
        let receiver = try resolveThis(env, thisValue, node: node)
        let key = try await evalPropertyKey(property, env: env, thisValue: thisValue)
        let base = try superBase(env, node: node)
        let value = try await getValue(base, key, receiver: receiver)
        return (value, receiver)
    }

    /// The reference of `super.x = v` before the write: its `this`, key and base, evaluated in that order.
    func superReference(
        _ property: CodemodeLanguage.PropertyKeyExpr,
        env: CodemodeLanguage.LexEnv,
        thisValue: CodemodeLanguage.Value,
        node: CodemodeLanguage.AstNode
    ) async throws -> (receiver: CodemodeLanguage.Value, key: CodemodeLanguage.PropertyKey, base: CodemodeLanguage.Obj) {
        let receiver = try resolveThis(env, thisValue, node: node)
        let key = try await evalPropertyKey(property, env: env, thisValue: thisValue)
        return (receiver, key, try superBase(env, node: node))
    }

    /// `super.x = v` (vm.ts `execPutSuper`): a setter on the home object's prototype chain runs with `this`;
    /// otherwise `this` takes the write.
    func writeSuper(
        base: CodemodeLanguage.Obj,
        key: CodemodeLanguage.PropertyKey,
        receiver: CodemodeLanguage.Value,
        value: CodemodeLanguage.Value,
        node: CodemodeLanguage.AstNode
    ) async throws {
        if case .accessor(_, let setHalf, _, _)? = CodemodeLanguage.lookup(base, key) {
            switch setHalf {
            case nil:
                throw CodemodeLanguage.typeError("Cannot set property \(CodemodeLanguage.keyLabel(key)), which has only a getter.", node: node)
            case .native(let setter, _)?:
                do { try setter(receiver, value) } catch { throw CodemodeLanguage.locate(error, node: node) }
            case .program(let fn)?:
                _ = try await callCallable(.object(fn), thisValue: receiver, args: [value], site: node)
            }
            return
        }
        guard case .object = receiver else {
            throw CodemodeLanguage.typeError(
                "Cannot set property \(CodemodeLanguage.keyLabel(key)) of \(CodemodeLanguage.describeValue(receiver)).",
                node: node
            )
        }
        try await writeMember(receiver, key, value, node: node)
    }

    // MARK: - Iterator ops

    /// One property read of an iterator op that may meet a program getter (vm.ts `redoRead`): the value, running
    /// the getter as program code first when there is one.
    // parity: psychoscript/src/vm.ts#Vm.redoRead [status=adapted hash=2e8a4a237803]
    public func redoRead(
        _ target: CodemodeLanguage.Obj,
        _ key: CodemodeLanguage.PropertyKey,
        receiver: CodemodeLanguage.Value,
        site: CodemodeLanguage.AstNode? = nil
    ) async throws -> CodemodeLanguage.Value {
        switch try CodemodeLanguage.access(target, key, receiver: receiver) {
        case .value(let value):
            return value
        case .getter(let call):
            return try await callCallable(.object(call.getter), thisValue: receiver, args: [], site: site)
        }
    }
}
